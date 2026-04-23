const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const armv4t_decode = @import("armv4t_decode.zig");
const catalog = @import("catalog.zig");
const frame_test_support = @import("frame_test_support.zig");
const gba_loader = @import("gba_loader.zig");
const llvm_codegen = @import("llvm_codegen.zig");
const parse = @import("cli/parse.zig");
const interrupt_fixture_support = @import("interrupt_fixture_support.zig");
const tonc_fixture_support = @import("tonc_fixture_support.zig");
const gba_ppu_source = @embedFile("gba_ppu.zig");

const standalone_build_cmd_test = builtin.is_test and !@hasDecl(@import("root"), "cli");

pub const BuildOptions = parse.BuildCommand;

pub const BuildError = std.mem.Allocator.Error ||
    Io.Writer.Error ||
    Io.Dir.CreateDirPathOpenError ||
    Io.Dir.ReadFileAllocError ||
    Io.Dir.WriteFileError ||
    std.process.RunError ||
    armv4t_decode.DecodeError ||
    catalog.CatalogError ||
    error{
        UnsupportedMachine,
        EmptyRom,
        InvalidRomSize,
        UnsupportedOpcode,
        UnsupportedShim,
        ToolFailed,
    };

fn clangOptimizeFlag(optimize: parse.OptimizeMode) []const u8 {
    return switch (optimize) {
        .debug => "-O0",
        .release => "-O3",
        .small => "-Oz",
    };
}

fn zigOptimizeModeArg(optimize: parse.OptimizeMode) []const u8 {
    return switch (optimize) {
        .debug => "Debug",
        .release => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    writer: *Io.Writer,
    options: BuildOptions,
) BuildError!void {
    const machine = try catalog.lookupMachine(options.machine_name);
    if (!std.mem.eql(u8, machine.name, "gba")) {
        try writer.print("Phase 1 build only supports machine gba\n", .{});
        return error.UnsupportedMachine;
    }

    const image = gba_loader.loadFile(io, allocator, cwd, options.machine_name, options.rom_path) catch |err| switch (err) {
        error.EmptyRom => {
            try writer.print("ROM is empty\n", .{});
            return error.EmptyRom;
        },
        error.InvalidRomSize => {
            try writer.print("ROM size must be a multiple of 4 bytes for this ARM32 slice\n", .{});
            return error.InvalidRomSize;
        },
        error.UnsupportedMachine => unreachable,
        else => |other| return other,
    };
    defer image.deinit(allocator);

    const program = try liftRomWithOptions(allocator, writer, image, options.output_mode, options.max_instructions);
    defer program.deinit(allocator);

    try ensureParentDir(io, cwd, options.output_path);
    const llvm_path = try llvmPath(allocator, options.output_path);
    defer allocator.free(llvm_path);
    try ensureParentDir(io, cwd, llvm_path);
    try writeLlvmFile(io, allocator, cwd, llvm_path, program);
    const runtime_helper_obj = try compileRuntimeHelper(io, allocator, cwd, writer, options);
    defer if (runtime_helper_obj) |helper_path| allocator.free(helper_path);
    try compileLlvm(io, allocator, cwd, writer, llvm_path, runtime_helper_obj, options);
    try writer.print("Built {s}\n", .{options.output_path});
}

fn liftRom(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    image: gba_loader.RomImage,
) BuildError!llvm_codegen.Program {
    return liftRomWithOptions(allocator, writer, image, .auto, null);
}

fn liftRomWithOptions(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    image: gba_loader.RomImage,
    requested_output_mode: parse.OutputMode,
    max_instructions: ?u64,
) BuildError!llvm_codegen.Program {
    var pending_functions: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending_functions.deinit(allocator);

    var functions: std.ArrayList(llvm_codegen.Function) = .empty;
    errdefer {
        for (functions.items) |function| allocator.free(function.instructions);
        functions.deinit(allocator);
    }

    var has_store = false;
    var has_self_loop = false;

    try pending_functions.append(allocator, .{
        .address = image.base_address,
        .isa = .arm,
    });

    while (pending_functions.items.len != 0) {
        const function_entry = pending_functions.items[pending_functions.items.len - 1];
        pending_functions.items.len -= 1;

        if (containsFunction(functions.items, function_entry)) continue;
        try functions.append(allocator, try liftFunction(
            allocator,
            writer,
            image,
            function_entry,
            &pending_functions,
            &has_store,
            &has_self_loop,
        ));
    }

    sortFunctions(functions.items);
    const output_mode: llvm_codegen.OutputMode = switch (requested_output_mode) {
        .auto => if (hasArmReportRoutine(functions.items))
            .arm_report
        else if (has_store and has_self_loop)
            .memory_summary
        else
            .register_r0_decimal,
        .frame_raw => .frame_raw,
        .retired_count => .retired_count,
    };
    const owned_functions = try functions.toOwnedSlice(allocator);

    return .{
        .entry = .{
            .address = image.base_address,
            .isa = .arm,
        },
        .rom_base_address = image.base_address,
        .rom_bytes = image.bytes,
        .save_hardware = detectSaveHardware(image.bytes),
        .functions = owned_functions,
        .output_mode = output_mode,
        .instruction_limit = if (requested_output_mode == .frame_raw or requested_output_mode == .retired_count)
            max_instructions
        else
            null,
    };
}

fn detectSaveHardware(rom_bytes: []const u8) llvm_codegen.SaveHardware {
    if (std.mem.indexOf(u8, rom_bytes, "SRAM_V") != null) return .sram;
    if (std.mem.indexOf(u8, rom_bytes, "FLASH512_V") != null) return .flash64;
    if (std.mem.indexOf(u8, rom_bytes, "FLASH1M_V") != null) return .flash128;
    return .none;
}

fn liftFunction(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    pending_functions: *std.ArrayList(armv4t_decode.CodeAddress),
    has_store: *bool,
    has_self_loop: *bool,
) BuildError!llvm_codegen.Function {
    var pending_blocks: std.ArrayList(u32) = .empty;
    defer pending_blocks.deinit(allocator);

    var nodes: std.ArrayList(llvm_codegen.InstructionNode) = .empty;
    defer nodes.deinit(allocator);

    try pending_blocks.append(allocator, function_entry.address);

    while (pending_blocks.items.len != 0) {
        const address = pending_blocks.items[pending_blocks.items.len - 1];
        pending_blocks.items.len -= 1;

        if (containsAddress(nodes.items, address)) continue;
        const decoded_opcode = decodeImageInstruction(writer, image, function_entry.isa, address) catch |err| return switch (err) {
            error.UnsupportedOpcode => err,
            else => |other| return other,
        };
        const raw_opcode = decoded_opcode.raw_opcode;
        const size_bytes = decoded_opcode.size_bytes;
        const decoded_initial = decoded_opcode.instruction;
        const decoded = resolveDecodedInstruction(image, function_entry, address, decoded_initial) catch {
            try renderUnsupportedOpcode(writer, raw_opcode, address);
            return error.UnsupportedOpcode;
        };

        try ensureDeclared(writer, decoded, address);
        try maybeEnqueueVectorTarget(
            allocator,
            writer,
            pending_functions,
            image,
            function_entry.isa,
            address,
            decoded,
        );
        if (isStore(decoded)) has_store.* = true;

        try nodes.append(allocator, .{
            .address = address,
            .condition = try decodeCondition(raw_opcode, function_entry.isa),
            .size_bytes = size_bytes,
            .instruction = decoded,
        });

        try enqueueSuccessors(
            allocator,
            writer,
            &pending_blocks,
            pending_functions,
            image,
            function_entry.isa,
            address,
            size_bytes,
            decoded,
            has_self_loop,
        );
    }

    sortNodes(nodes.items);

    return .{
        .entry = function_entry,
        .instructions = try nodes.toOwnedSlice(allocator),
    };
}

const DecodedNode = struct {
    address: u32,
    raw_opcode: u32,
    size_bytes: u8,
    instruction: armv4t_decode.DecodedInstruction,
};

fn decodeImageInstruction(
    writer: *Io.Writer,
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) BuildError!DecodedNode {
    const offset = offsetForAddress(image, address, isa) orelse return error.UnsupportedOpcode;
    const decoded = armv4t_decode.decodeAt(image.bytes[offset..], isa, address) catch |err| return switch (err) {
        error.UnsupportedOpcode => {
            const raw_opcode = switch (isa) {
                .arm => if (offset + 4 <= image.bytes.len) armv4t_decode.readWord(image.bytes, offset) else 0,
                .thumb => if (offset + 2 <= image.bytes.len) armv4t_decode.readHalfword(image.bytes, offset) else 0,
            };
            try renderUnsupportedOpcode(writer, raw_opcode, address);
            return error.UnsupportedOpcode;
        },
        else => |other| return other,
    };

    return .{
        .address = address,
        .raw_opcode = decoded.raw_opcode,
        .size_bytes = decoded.size_bytes,
        .instruction = decoded.instruction,
    };
}

fn decodeImageInstructionUnchecked(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) BuildError!DecodedNode {
    const offset = offsetForAddress(image, address, isa) orelse return error.UnsupportedOpcode;
    const decoded = try armv4t_decode.decodeAt(image.bytes[offset..], isa, address);
    return .{
        .address = address,
        .raw_opcode = decoded.raw_opcode,
        .size_bytes = decoded.size_bytes,
        .instruction = decoded.instruction,
    };
}

fn previousInstruction(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) BuildError!DecodedNode {
    switch (isa) {
        .arm => {
            if (address < 4) return error.UnsupportedOpcode;
            return decodeImageInstructionUnchecked(image, isa, address - 4);
        },
        .thumb => {
            for ([_]u8{ 4, 2 }) |candidate_size| {
                if (address < candidate_size) continue;
                const candidate_address = address - candidate_size;
                const decoded = decodeImageInstructionUnchecked(image, isa, candidate_address) catch continue;
                if (candidate_address + decoded.size_bytes == address) return decoded;
            }
            return error.UnsupportedOpcode;
        },
    }
}

fn nextStartupThumbVeneerInstruction(
    image: gba_loader.RomImage,
    target_address: u32,
) BuildError!DecodedNode {
    return decodeImageInstructionUnchecked(image, .thumb, target_address + 2);
}

fn ensureDeclared(
    writer: *Io.Writer,
    decoded: armv4t_decode.DecodedInstruction,
    address: u32,
) BuildError!void {
    switch (decoded) {
        .nop => _ = try catalog.lookupInstruction("armv4t", "nop"),
        .mov_imm => _ = try catalog.lookupInstruction("armv4t", "mov_imm"),
        .mov_reg => _ = try catalog.lookupInstruction("armv4t", "mov_reg"),
        .movs_imm => _ = try catalog.lookupInstruction("armv4t", "movs_imm"),
        .mvn_imm => _ = try catalog.lookupInstruction("armv4t", "mvn_imm"),
        .mvn_reg => _ = try catalog.lookupInstruction("armv4t", "mvn_reg"),
        .movs_reg => _ = try catalog.lookupInstruction("armv4t", "movs_reg"),
        .orr_imm => _ = try catalog.lookupInstruction("armv4t", "orr_imm"),
        .orr_reg => _ = try catalog.lookupInstruction("armv4t", "orr_reg"),
        .eor_imm => _ = try catalog.lookupInstruction("armv4t", "eor_imm"),
        .eor_reg => _ = try catalog.lookupInstruction("armv4t", "eor_reg"),
        .bic_imm => _ = try catalog.lookupInstruction("armv4t", "bic_imm"),
        .bic_reg => _ = try catalog.lookupInstruction("armv4t", "bic_reg"),
        .orr_shift_reg => _ = try catalog.lookupInstruction("armv4t", "orr_reg_shift"),
        .and_imm => _ = try catalog.lookupInstruction("armv4t", "and_imm"),
        .and_reg => _ = try catalog.lookupInstruction("armv4t", "and_reg"),
        .add_imm => _ = try catalog.lookupInstruction("armv4t", "add_imm"),
        .adds_imm => _ = try catalog.lookupInstruction("armv4t", "adds_imm"),
        .adcs_imm => _ = try catalog.lookupInstruction("armv4t", "adcs_imm"),
        .adcs_shift_reg => _ = try catalog.lookupInstruction("armv4t", "adcs_reg_shift"),
        .adc_imm => _ = try catalog.lookupInstruction("armv4t", "adc_imm"),
        .sbcs_imm => _ = try catalog.lookupInstruction("armv4t", "sbcs_imm"),
        .sbcs_reg => _ = try catalog.lookupInstruction("armv4t", "sbcs_reg"),
        .sbc_imm => _ = try catalog.lookupInstruction("armv4t", "sbc_imm"),
        .add_reg => _ = try catalog.lookupInstruction("armv4t", "add_reg"),
        .add_reg_pc_target => _ = try catalog.lookupInstruction("armv4t", "add_reg"),
        .add_shift_reg => _ = try catalog.lookupInstruction("armv4t", "add_reg_shift"),
        .rsb_imm => _ = try catalog.lookupInstruction("armv4t", "rsb_imm"),
        .rsbs_imm => _ = try catalog.lookupInstruction("armv4t", "rsbs_imm"),
        .rsc_imm => _ = try catalog.lookupInstruction("armv4t", "rsc_imm"),
        .sub_imm => _ = try catalog.lookupInstruction("armv4t", "sub_imm"),
        .subs_imm => _ = try catalog.lookupInstruction("armv4t", "subs_imm"),
        .subs_reg => _ = try catalog.lookupInstruction("armv4t", "subs_reg"),
        .lsl_imm => _ = try catalog.lookupInstruction("armv4t", "lsl_imm"),
        .lsl_reg => _ = try catalog.lookupInstruction("armv4t", "lsl_reg"),
        .asr_imm => _ = try catalog.lookupInstruction("armv4t", "asr_imm"),
        .asr_reg => _ = try catalog.lookupInstruction("armv4t", "asr_reg"),
        .lsls_imm => _ = try catalog.lookupInstruction("armv4t", "lsls_imm"),
        .lsls_reg => _ = try catalog.lookupInstruction("armv4t", "lsls_reg"),
        .lsr_imm => _ = try catalog.lookupInstruction("armv4t", "lsr_imm"),
        .lsrs_imm => _ = try catalog.lookupInstruction("armv4t", "lsrs_imm"),
        .lsr_reg => _ = try catalog.lookupInstruction("armv4t", "lsr_reg"),
        .lsrs_reg => _ = try catalog.lookupInstruction("armv4t", "lsrs_reg"),
        .asrs_imm => _ = try catalog.lookupInstruction("armv4t", "asrs_imm"),
        .asrs_reg => _ = try catalog.lookupInstruction("armv4t", "asrs_reg"),
        .ror_imm => _ = try catalog.lookupInstruction("armv4t", "ror_imm"),
        .ror_reg => _ = try catalog.lookupInstruction("armv4t", "ror_reg"),
        .rors_imm => _ = try catalog.lookupInstruction("armv4t", "rors_imm"),
        .rors_reg => _ = try catalog.lookupInstruction("armv4t", "rors_reg"),
        .rrxs => _ = try catalog.lookupInstruction("armv4t", "rrxs"),
        .mul => _ = try catalog.lookupInstruction("armv4t", "mul"),
        .mla => _ = try catalog.lookupInstruction("armv4t", "mla"),
        .umull => _ = try catalog.lookupInstruction("armv4t", "umull"),
        .umlal => _ = try catalog.lookupInstruction("armv4t", "umlal"),
        .smull => _ = try catalog.lookupInstruction("armv4t", "smull"),
        .smlal => _ = try catalog.lookupInstruction("armv4t", "smlal"),
        .swp_word => _ = try catalog.lookupInstruction("armv4t", "swp_word"),
        .swp_byte => _ = try catalog.lookupInstruction("armv4t", "swp_byte"),
        .ldr_word_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_word_imm"),
        .ldr_word_imm_signed => _ = try catalog.lookupInstruction("armv4t", "ldr_word_imm_signed"),
        .ldr_byte_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_byte_imm"),
        .ldr_byte_post_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_byte_post_imm"),
        .ldr_byte_reg => _ = try catalog.lookupInstruction("armv4t", "ldr_byte_reg"),
        .ldr_halfword_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_halfword_imm"),
        .ldr_halfword_pre_index_reg => _ = try catalog.lookupInstruction("armv4t", "ldr_halfword_pre_reg"),
        .ldr_halfword_pre_index_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_halfword_pre_imm"),
        .ldr_halfword_post_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_halfword_post_imm"),
        .ldr_signed_halfword_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_halfword_imm"),
        .ldr_signed_halfword_reg => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_halfword_reg"),
        .ldr_signed_byte_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_byte_imm"),
        .ldr_signed_byte_reg => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_byte_reg"),
        .ldr_word_pre_index_reg_shift => _ = try catalog.lookupInstruction("armv4t", "ldr_word_pre_reg_shift"),
        .ldr_word_pre_index_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_word_pre_imm"),
        .ldr_word_post_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_word_post_imm"),
        .ldr_pc_post_imm_target => _ = try catalog.lookupInstruction("armv4t", "ldr_pc_post_imm"),
        .stm => |stm| switch (stm.mode) {
            .ia => _ = try catalog.lookupInstruction("armv4t", "stmia_regs"),
            .ib => _ = try catalog.lookupInstruction("armv4t", "stmib_regs"),
            .da => _ = try catalog.lookupInstruction("armv4t", "stmda_regs"),
            .db => _ = try catalog.lookupInstruction("armv4t", "stmdb_regs"),
        },
        .stm_empty => _ = try catalog.lookupInstruction("armv4t", "stm_empty"),
        .push => _ = try catalog.lookupInstruction("armv4t", "push_regs"),
        .pop => _ = try catalog.lookupInstruction("armv4t", "pop_regs"),
        .ldm => |ldm| switch (ldm.mode) {
            .ia => _ = try catalog.lookupInstruction("armv4t", "ldm_regs"),
            .ib => _ = try catalog.lookupInstruction("armv4t", "ldmib_regs"),
            .da => _ = try catalog.lookupInstruction("armv4t", "ldmda_regs"),
            .db => _ = try catalog.lookupInstruction("armv4t", "ldmdb_regs"),
        },
        .ldm_empty => _ = try catalog.lookupInstruction("armv4t", "ldm_empty"),
        .ldm_pc_target => |ldm| switch (ldm.mode) {
            .ia => _ = try catalog.lookupInstruction("armv4t", "ldm_regs"),
            .ib => _ = try catalog.lookupInstruction("armv4t", "ldmib_regs"),
            .da => _ = try catalog.lookupInstruction("armv4t", "ldmda_regs"),
            .db => _ = try catalog.lookupInstruction("armv4t", "ldmdb_regs"),
        },
        .ldm_empty_pc_target => _ = try catalog.lookupInstruction("armv4t", "ldm_empty"),
        .tst_imm => _ = try catalog.lookupInstruction("armv4t", "tst_imm"),
        .tst_reg => _ = try catalog.lookupInstruction("armv4t", "tst_reg"),
        .cmp_imm => _ = try catalog.lookupInstruction("armv4t", "cmp_imm"),
        .cmp_reg => _ = try catalog.lookupInstruction("armv4t", "cmp_reg"),
        .cmn_imm => _ = try catalog.lookupInstruction("armv4t", "cmn_imm"),
        .cmn_reg => _ = try catalog.lookupInstruction("armv4t", "cmn_reg"),
        .teq_imm => _ = try catalog.lookupInstruction("armv4t", "teq_imm"),
        .store => |store| switch (store.size) {
            .word => switch (store.addressing) {
                .post_index => _ = try catalog.lookupInstruction("armv4t", "str_word_post"),
                .pre_index => _ = try catalog.lookupInstruction("armv4t", "str_word_pre"),
                .offset => |offset| switch (offset.offset) {
                    .imm => _ = try catalog.lookupInstruction("armv4t", "str_word_imm"),
                    .reg => _ = try catalog.lookupInstruction("armv4t", "str_word_reg"),
                },
            },
            .halfword => switch (store.addressing) {
                .post_index => _ = try catalog.lookupInstruction("armv4t", "str_halfword_post"),
                .pre_index => _ = try catalog.lookupInstruction("armv4t", "str_halfword_pre"),
                .offset => _ = try catalog.lookupInstruction("armv4t", "str_halfword_imm"),
            },
            .byte => switch (store.addressing) {
                .post_index => _ = try catalog.lookupInstruction("armv4t", "str_byte_post"),
                .pre_index => return error.UnsupportedOpcode,
                .offset => _ = try catalog.lookupInstruction("armv4t", "str_byte_imm"),
            },
        },
        .branch => |branch| _ = try catalog.lookupInstruction("armv4t", branchInstructionName(branch.cond)),
        .bl => _ = try catalog.lookupInstruction("armv4t", "bl"),
        .bx_target => _ = try catalog.lookupInstruction("armv4t", "bx_reg"),
        .bx_reg => return error.UnsupportedOpcode,
        .bx_lr => _ = try catalog.lookupInstruction("armv4t", "bx_lr"),
        .thumb_saved_lr_return => _ = try catalog.lookupInstruction("armv4t", "thumb_saved_lr_return"),
        .mrs_psr => _ = try catalog.lookupInstruction("armv4t", "mrs_psr"),
        .msr_psr_imm => _ = try catalog.lookupInstruction("armv4t", "msr_psr_imm"),
        .msr_psr_reg => _ = try catalog.lookupInstruction("armv4t", "msr_psr_reg"),
        .exception_return => _ = try catalog.lookupInstruction("armv4t", "exception_return"),
        .swi => |swi| {
            const shim_name = swiShimName(swi.imm24) orelse {
                try renderUnsupportedShim(writer, address, swi.imm24);
                return error.UnsupportedShim;
            };
            _ = try catalog.lookupShim("gba", shim_name);
        },
    }
}

fn enqueueSuccessors(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    pending_blocks: *std.ArrayList(u32),
    pending_functions: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    size_bytes: u8,
    decoded: armv4t_decode.DecodedInstruction,
    has_self_loop: *bool,
) BuildError!void {
    switch (decoded) {
        .nop => try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes),
        .mov_reg => |mov| {
            if (mov.rd == 15 and mov.rm == 14) return;
            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
        },
        .movs_reg => |mov| {
            if (mov.rd == 15 and mov.rm == 14) return;
            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
        },
        .branch => |branch| {
            if (branch.cond == .al) {
                if (branch.target == address) {
                    has_self_loop.* = true;
                    return;
                }
                try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, branch.target);
                return;
            }

            if (try resolveDevkitArmCrt0HeaderCheckBranch(image, isa, address, branch)) |take_branch| {
                if (take_branch) {
                    if (branch.target == address) {
                        has_self_loop.* = true;
                        return;
                    }
                    try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, branch.target);
                } else {
                    try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
                }
                return;
            }

            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
            if (branch.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, branch.target);
        },
        .bl => |bl| {
            try enqueueFunctionAddress(allocator, writer, pending_functions, image, bl.target);
            if (!isExactObjDemoMainTailNoReturnCall(image, isa, address, bl)) {
                try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
            }
        },
        .add_reg_pc_target => |add| {
            if (add.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, add.target);
        },
        .bx_target => |target| {
            try enqueueFunctionAddress(allocator, writer, pending_functions, image, target);
        },
        .bx_lr => return,
        .thumb_saved_lr_return => return,
        .bx_reg => return error.UnsupportedOpcode,
        .exception_return => |ret| {
            if (ret.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, ret.target);
        },
        .ldr_pc_post_imm_target => |load| {
            if (load.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, load.target);
        },
        .ldm_pc_target => |ldm| {
            if (ldm.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, ldm.target);
        },
        .ldm_empty_pc_target => |ldm| {
            if (ldm.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, ldm.target);
        },
        .pop => |mask| {
            if ((mask & (@as(u16, 1) << 15)) != 0) return;
            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
        },
        else => {
            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
        },
    }
}

fn resolveDevkitArmCrt0HeaderCheckBranch(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    branch: @FieldType(armv4t_decode.DecodedInstruction, "branch"),
) BuildError!?bool {
    if (isa != .thumb) return null;
    if (branch.cond != .hs and branch.cond != .lo) return null;

    const previous = previousInstruction(image, isa, address) catch return null;
    const shift = switch (previous.instruction) {
        .lsls_imm => |shift| shift,
        else => return null,
    };

    if (shift.rd != shift.rm or shift.imm == 0) return null;

    const source = previousInstruction(image, isa, previous.address) catch return null;
    const load = switch (source.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (load.rd != shift.rm or load.base != 15) return null;

    const literal_address = pcValueForInstruction(.thumb, source.address) + load.offset;
    const literal_offset = if (literal_address < image.base_address) return null else literal_address - image.base_address;
    if (literal_offset + 4 > image.bytes.len) return null;

    // Narrowly recognize the devkitARM crt0 header check: the literal must be
    // the ROM base itself before the carry-setting shift proves this branch.
    const source_value = armv4t_decode.readWord(image.bytes, literal_offset);
    if (source_value != image.base_address) return null;
    const carry_set = lslImmediateCarryOut(source_value, shift.imm) orelse return null;
    return if (branch.cond == .hs) carry_set else !carry_set;
}

fn isExactObjDemoMainTailNoReturnCall(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    bl: @FieldType(armv4t_decode.DecodedInstruction, "bl"),
) bool {
    if (isa != .thumb) return false;
    if (address != image.base_address + 0x39C) return false;
    if (bl.target.address != image.base_address + 0x26C or bl.target.isa != .thumb) return false;

    const expected_literals = [_]u32{
        0x0300_00A4,
        0x0800_0AAC,
        0x0601_0000,
        0x0800_12AC,
        0x0500_0200,
        0x0300_0144,
    };

    for (expected_literals, 0..) |expected_literal, index| {
        const literal_address = address + 4 + @as(u32, @intCast(index * 4));
        const literal_offset = romOffsetForAddress(image, literal_address, .thumb) orelse return false;
        if (literal_offset + 4 > image.bytes.len) return false;
        if (armv4t_decode.readWord(image.bytes, literal_offset) != expected_literal) return false;
    }

    const stub = decodeImageInstructionUnchecked(image, .thumb, address + 0x1C) catch return false;
    const bx = switch (stub.instruction) {
        .bx_reg => |bx| bx,
        else => return false,
    };
    if (bx.reg != 3) return false;
    if (!isMeasuredLocalThumbBlxR3VeneerNop(image, address + 0x1E)) return false;

    const next_function = decodeImageInstructionUnchecked(image, .thumb, address + 0x20) catch return false;
    return switch (next_function.instruction) {
        .push => |mask| mask == ((@as(u16, 1) << 4) | (@as(u16, 1) << 14)),
        else => false,
    };
}

fn lslImmediateCarryOut(value: u32, amount: u32) ?bool {
    if (amount == 0 or amount > 32) return null;
    const carry_bit_index = 32 - amount;
    return ((value >> @as(u5, @intCast(carry_bit_index))) & 1) != 0;
}

fn enqueueFallthrough(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(u32),
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    size_bytes: u8,
) std.mem.Allocator.Error!void {
    const next_address = address + size_bytes;
    if (offsetForAddress(image, next_address, isa) != null) {
        try pending.append(allocator, next_address);
    }
}

fn enqueueBlockAddress(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    pending: *std.ArrayList(u32),
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) BuildError!void {
    if (offsetForAddress(image, address, isa) == null) {
        try writer.print("Unsupported control flow target 0x{X:0>8} for gba\n", .{address});
        return error.UnsupportedOpcode;
    }
    try pending.append(allocator, address);
}

fn enqueueFunctionAddress(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) BuildError!void {
    if (offsetForAddress(image, target.address, target.isa) == null) {
        try writer.print("Unsupported control flow target 0x{X:0>8} for gba\n", .{target.address});
        return error.UnsupportedOpcode;
    }
    try pending.append(allocator, target);
}

const MeasuredDevkitArmCopySpan = struct {
    rom_lma: u32,
    iwram_vma_start: u32,
    size: u32,

    fn contains(self: MeasuredDevkitArmCopySpan, address: u32) bool {
        return address >= self.iwram_vma_start and address < self.iwram_vma_start + self.size;
    }

    fn romAddressFor(self: MeasuredDevkitArmCopySpan, address: u32) u32 {
        return self.rom_lma + (address - self.iwram_vma_start);
    }
};

fn romOffsetForAddress(
    image: gba_loader.RomImage,
    address: u32,
    isa: armv4t_decode.InstructionSet,
) ?usize {
    if (address < image.base_address) return null;
    const offset = address - image.base_address;
    if ((offset % instructionSizeBytes(isa)) != 0) return null;
    if (offset + instructionSizeBytes(isa) > image.bytes.len) return null;
    return offset;
}

fn offsetForAddress(
    image: gba_loader.RomImage,
    address: u32,
    isa: armv4t_decode.InstructionSet,
) ?usize {
    if (romOffsetForAddress(image, address, isa)) |offset| return offset;

    const iwram_span = measuredDevkitArmIwramCodeSpan(image) orelse return null;
    if (!iwram_span.contains(address)) return null;
    return romOffsetForAddress(image, iwram_span.romAddressFor(address), isa);
}

fn measuredDevkitArmIwramCodeSpan(image: gba_loader.RomImage) ?MeasuredDevkitArmCopySpan {
    const iwram_lma_load = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x14E) catch return null;
    const iwram_start_load = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x150) catch return null;
    const iwram_end_load = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x152) catch return null;
    const size_check_call = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x154) catch return null;

    const iwram_lma_ldr = switch (iwram_lma_load.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (iwram_lma_ldr.rd != 1 or iwram_lma_ldr.base != 15) return null;

    const iwram_start_ldr = switch (iwram_start_load.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (iwram_start_ldr.rd != 2 or iwram_start_ldr.base != 15) return null;

    const iwram_end_ldr = switch (iwram_end_load.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (iwram_end_ldr.rd != 4 or iwram_end_ldr.base != 15) return null;

    const bl = switch (size_check_call.instruction) {
        .bl => |bl| bl,
        else => return null,
    };
    if (bl.target.address != image.base_address + 0x19C or bl.target.isa != .thumb) return null;

    const iwram_lma = resolveThumbLiteralWordFromRom(image, iwram_lma_load.address, iwram_lma_ldr) orelse return null;
    const iwram_start = resolveThumbLiteralWordFromRom(image, iwram_start_load.address, iwram_start_ldr) orelse return null;
    const iwram_end = resolveThumbLiteralWordFromRom(image, iwram_end_load.address, iwram_end_ldr) orelse return null;

    if (iwram_start != 0x0300_0000) return null;
    if (iwram_end <= iwram_start) return null;
    if (romOffsetForAddress(image, iwram_lma, .arm) == null) return null;

    return .{
        .rom_lma = iwram_lma,
        .iwram_vma_start = iwram_start,
        .size = iwram_end - iwram_start,
    };
}

fn measuredDevkitArmIwramDataSpan(image: gba_loader.RomImage) ?MeasuredDevkitArmCopySpan {
    const data_lma_load = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x144) catch return null;
    const data_start_load = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x146) catch return null;
    const data_end_load = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x148) catch return null;
    const copy_check_call = decodeRomInstructionUnchecked(image, .thumb, image.base_address + 0x14A) catch return null;

    const data_lma_ldr = switch (data_lma_load.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (data_lma_ldr.rd != 1 or data_lma_ldr.base != 15) return null;

    const data_start_ldr = switch (data_start_load.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (data_start_ldr.rd != 2 or data_start_ldr.base != 15) return null;

    const data_end_ldr = switch (data_end_load.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (data_end_ldr.rd != 4 or data_end_ldr.base != 15) return null;

    const bl = switch (copy_check_call.instruction) {
        .bl => |bl| bl,
        else => return null,
    };
    if (bl.target.address != image.base_address + 0x19C or bl.target.isa != .thumb) return null;

    const data_lma = resolveThumbLiteralWordFromRom(image, data_lma_load.address, data_lma_ldr) orelse return null;
    const data_start = resolveThumbLiteralWordFromRom(image, data_start_load.address, data_start_ldr) orelse return null;
    const data_end = resolveThumbLiteralWordFromRom(image, data_end_load.address, data_end_ldr) orelse return null;

    if (data_start < 0x0300_0000 or data_end > 0x0300_8000 or data_end <= data_start) return null;
    const size = data_end - data_start;
    if (data_lma < image.base_address) return null;
    const data_offset = data_lma - image.base_address;
    if (data_offset + size > image.bytes.len) return null;

    return .{
        .rom_lma = data_lma,
        .iwram_vma_start = data_start,
        .size = size,
    };
}

fn measuredDevkitArmIwramDataWord(image: gba_loader.RomImage, address: u32) ?u32 {
    const data_span = measuredDevkitArmIwramDataSpan(image) orelse return null;
    if (!data_span.contains(address)) return null;
    const word_offset = data_span.romAddressFor(address) - image.base_address;
    if (word_offset + 4 > image.bytes.len) return null;
    return armv4t_decode.readWord(image.bytes, word_offset);
}

fn decodeRomInstructionUnchecked(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) BuildError!DecodedNode {
    const offset = romOffsetForAddress(image, address, isa) orelse return error.UnsupportedOpcode;
    const decoded = try armv4t_decode.decodeAt(image.bytes[offset..], isa, address);
    return .{
        .address = address,
        .raw_opcode = decoded.raw_opcode,
        .size_bytes = decoded.size_bytes,
        .instruction = decoded.instruction,
    };
}

fn resolveThumbLiteralWordFromRom(
    image: gba_loader.RomImage,
    load_address: u32,
    load: @FieldType(armv4t_decode.DecodedInstruction, "ldr_word_imm"),
) ?u32 {
    const literal_address = pcValueForInstruction(.thumb, load_address) + load.offset;
    const literal_offset = romOffsetForAddress(image, literal_address, .thumb) orelse return null;
    if (literal_offset + 4 > image.bytes.len) return null;
    return armv4t_decode.readWord(image.bytes, literal_offset);
}

fn containsAddress(nodes: []const llvm_codegen.InstructionNode, address: u32) bool {
    for (nodes) |node| {
        if (node.address == address) return true;
    }
    return false;
}

fn containsFunction(functions: []const llvm_codegen.Function, entry: armv4t_decode.CodeAddress) bool {
    for (functions) |function| {
        if (codeAddressEqual(function.entry, entry)) return true;
    }
    return false;
}

fn hasInstructionAddress(functions: []const llvm_codegen.Function, address: u32) bool {
    for (functions) |function| {
        if (containsAddress(function.instructions, address)) return true;
    }
    return false;
}

fn hasArmReportRoutine(functions: []const llvm_codegen.Function) bool {
    for (functions) |function| {
        if (function.entry.isa != .arm) continue;
        if (functionHasArmReportRoutine(function.instructions)) return true;
    }
    return false;
}

fn functionHasArmReportRoutine(nodes: []const llvm_codegen.InstructionNode) bool {
    var saw_wait_loop_push = false;
    var saw_wait_loop_pop = false;

    for (nodes, 0..) |node, index| {
        switch (node.instruction) {
            .push => |mask| {
                if (mask == 0x0003) {
                    saw_wait_loop_push = true;
                    continue;
                }

                if (!saw_wait_loop_pop or mask != 0x1FFF) continue;
                if (index + 1 >= nodes.len) continue;

                switch (nodes[index + 1].instruction) {
                    .movs_reg => |mov| if (mov.rd == 12) return true,
                    else => {},
                }
            },
            .pop => |mask| {
                if (saw_wait_loop_push and mask == 0x0003) {
                    saw_wait_loop_pop = true;
                }
            },
            else => {},
        }
    }

    return false;
}

fn sortNodes(nodes: []llvm_codegen.InstructionNode) void {
    var i: usize = 0;
    while (i < nodes.len) : (i += 1) {
        var min_index = i;
        var j: usize = i + 1;
        while (j < nodes.len) : (j += 1) {
            if (nodes[j].address < nodes[min_index].address) min_index = j;
        }
        if (min_index != i) std.mem.swap(llvm_codegen.InstructionNode, &nodes[i], &nodes[min_index]);
    }
}

fn sortFunctions(functions: []llvm_codegen.Function) void {
    var i: usize = 0;
    while (i < functions.len) : (i += 1) {
        var min_index = i;
        var j: usize = i + 1;
        while (j < functions.len) : (j += 1) {
            if (codeAddressLessThan(functions[j].entry, functions[min_index].entry)) min_index = j;
        }
        if (min_index != i) std.mem.swap(llvm_codegen.Function, &functions[i], &functions[min_index]);
    }
}

fn resolveDecodedInstruction(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    decoded: armv4t_decode.DecodedInstruction,
) BuildError!armv4t_decode.DecodedInstruction {
    const isa = function_entry.isa;
    const resolved = switch (decoded) {
        .subs_imm => |sub| if (sub.rd == 15 and sub.rn == 15) blk: {
            const target = normalizePcWriteTarget(pcValueForInstruction(isa, address) - sub.imm, isa);
            if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
            break :blk armv4t_decode.DecodedInstruction{ .exception_return = .{
                .target = target,
            } };
        } else decoded,
        .add_reg => |add| if (add.rd == 15)
            try resolveAddRegPcTarget(image, isa, address, add)
        else
            decoded,
        .bx_reg => |bx| try resolveBxTarget(image, function_entry, address, bx.reg),
        .mov_reg => |mov| if (mov.rd == 15 and mov.rm != 14)
            try resolveMovPcTarget(image, isa, address, mov.rm)
        else
            decoded,
        .ldm_empty => |ldm| try resolveLdmEmptyPcTarget(image, isa, address, ldm),
        .ldm => |ldm| if (registerMaskIncludesPc(ldm.mask))
            try resolveLdmPcTarget(image, isa, address, ldm)
        else
            decoded,
        .ldr_word_post_imm => |load| if (load.rd == 15)
            try resolveLdrPcPostImmTarget(image, isa, address, load)
        else
            decoded,
        .bl => |bl| if (try resolveExactLocalThumbBlxR3VeneerTarget(image, isa, address, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else if (try resolveExactObjDemoLocalThumbBlxR9VeneerTarget(image, isa, address, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else if (try resolveDevkitArmCrt0StartupThumbBlxR3Target(image, isa, address, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else
            decoded,
        else => decoded,
    };

    if (writesUnsupportedPcDestination(resolved)) return error.UnsupportedOpcode;
    return resolved;
}

fn resolveBxTarget(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) BuildError!armv4t_decode.DecodedInstruction {
    if (isExactThumbSavedLrInterworkingReturnEpilogue(image, function_entry, address, reg)) {
        // This is the exact `sbb_reg`-style Thumb interworking return shape:
        // an entry `push {saved_regs..., lr}` paired with `pop {saved_regs...};
        // pop {return_reg}; bx return_reg`.
        return .{ .thumb_saved_lr_return = {} };
    }
    if (function_entry.isa == .thumb and reg == 6) {
        const previous = try previousInstruction(image, function_entry.isa, address);
        if (previous.instruction == .bl) {
            return .{ .bx_target = normalizeCodeTarget(try resolveStartupThumbBxR6TargetValue(image, function_entry.isa, address)) };
        }
    }
    return .{ .bx_target = normalizeCodeTarget(try resolvePreviousRegisterValue(image, function_entry.isa, address, reg)) };
}

fn isExactThumbSavedLrInterworkingReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    const isa = function_entry.isa;
    if (isa != .thumb) return false;
    if (reg == 15) return false;

    const saved_regs_mask = thumbEntrySavedRegsMask(image, function_entry) orelse return false;
    if ((saved_regs_mask & (@as(u16, 1) << @intCast(reg))) != 0) return false;

    const previous = previousInstruction(image, isa, address) catch return false;
    _ = switch (previous.instruction) {
        .pop => |mask| if (mask == (@as(u16, 1) << reg)) reg else return false,
        else => return false,
    };

    const prior = previousInstruction(image, isa, previous.address) catch return false;
    _ = switch (prior.instruction) {
        .pop => |mask| if (mask == saved_regs_mask) mask else return false,
        else => return false,
    };

    // Keep this self-limiting: only the exact `push {saved_regs..., lr}`
    // prologue paired with `pop {saved_regs...}; pop {return_reg};
    // bx return_reg` is recognized as a return surface.
    return true;
}

fn thumbEntrySavedRegsMask(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
) ?u16 {
    if (function_entry.isa != .thumb) return null;

    var address = function_entry.address;
    const entry = decodeImageInstructionUnchecked(image, .thumb, address) catch return null;
    switch (entry.instruction) {
        .movs_imm => |mov| {
            // Exact carve-out for the measured `sbb_reg` prologue:
            // `movs r2, #0` + `ldr r3, [pc, #44]` + `push {r4, lr}`.
            if (entry.size_bytes != 2) return null;
            if (mov.rd != 2 or mov.imm != 0) return null;

            const first = decodeImageInstructionUnchecked(image, .thumb, address + entry.size_bytes) catch return null;
            const first_load = switch (first.instruction) {
                .ldr_word_imm => |load| load,
                else => return null,
            };
            if (first.size_bytes != 2) return null;
            if (first_load.rd != 3 or first_load.base != 15 or first_load.offset != 44) return null;

            address += entry.size_bytes + first.size_bytes;
            const push = decodeImageInstructionUnchecked(image, .thumb, address) catch return null;
            if (push.size_bytes != 2) return null;
            const push_mask = switch (push.instruction) {
                .push => |mask| mask,
                else => return null,
            };
            if (push_mask != 0x4010) return null;
            return 0x0010;
        },
        else => {},
    }

    var literal_prefix_count: u2 = 0;
    while (true) {
        const decoded = decodeImageInstructionUnchecked(image, .thumb, address) catch return null;
        switch (decoded.instruction) {
            .ldr_word_imm => |load| {
                // Keep this narrow: allow the exact Thumb literal-load prefix
                // seen before the prologue in `sbb_reg`, but nothing broader.
                if (decoded.size_bytes != 2) return null;
                if (literal_prefix_count == 2) return null;
                if (load.base != 15 or load.rd >= 8) return null;
                literal_prefix_count += 1;
                address += decoded.size_bytes;
            },
            .push => |mask| {
                if (decoded.size_bytes != 2) return null;
                const saved_mask = mask & 0x00FF;
                const has_lr = (mask & (@as(u16, 1) << 14)) != 0;
                if (!has_lr) return null;
                if ((mask & ~@as(u16, 0x40FF)) != 0) return null;
                if (saved_mask == 0) return null;
                return saved_mask;
            },
            else => return null,
        }
    }
}

fn resolveDevkitArmCrt0StartupThumbBlxR3Target(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
    target_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const target = decodeImageInstructionUnchecked(image, .thumb, target_address) catch return null;
    const bx = switch (target.instruction) {
        .bx_reg => |bx| bx,
        else => return null,
    };
    if (bx.reg != 3) return null;

    // This is the devkitARM crt0 veneer shape: `_blx_r3_stub` is wrapped by
    // `bx lr` before it and `subs r3, r4, r2` after it, so the caller-side
    // `ldr r3, [pc, #imm]` can be resolved directly without a general analysis.
    const previous_target = previousInstruction(image, isa, target_address) catch return null;
    if (previous_target.instruction != .bx_lr) return null;

    const next_target = nextStartupThumbVeneerInstruction(image, target_address) catch return null;
    const subs = switch (next_target.instruction) {
        .subs_reg => |subs| subs,
        else => return null,
    };
    if (subs.rd != 3 or subs.rn != 4 or subs.rm != 2) return null;

    const previous = try previousInstruction(image, isa, bl_address);
    const load = switch (previous.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (load.rd != 3 or load.base != 15) return null;

    return try resolveThumbPcRelativeLiteralCodeTarget(image, previous.address, load);
}

fn resolveExactLocalThumbBlxR3VeneerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
    target_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const target = decodeImageInstructionUnchecked(image, .thumb, target_address) catch return null;
    const bx = switch (target.instruction) {
        .bx_reg => |bx| bx,
        else => return null,
    };
    if (bx.reg != 3) return null;

    if (!isMeasuredLocalThumbBlxR3VeneerNop(image, target_address + 2)) return null;
    if (try resolveExactSimpleLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactObjDemoLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactKeyDemoLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactKeyDemoAddsLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactLibcInitArrayLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    return try resolveExactSbbRegLocalThumbBlxR3CallerTarget(image, isa, bl_address);
}

fn isMeasuredLocalThumbBlxR3VeneerNop(image: gba_loader.RomImage, address: u32) bool {
    const offset = offsetForAddress(image, address, .thumb) orelse return false;
    if (offset + 2 > image.bytes.len) return false;

    const raw_halfword = armv4t_decode.readHalfword(image.bytes, offset);
    // Keep this family exact and measured: the current local veneers end in
    // either `mov r8, r8` or the Thumb zero-shift alias `movs r0, r0`,
    // which is a nop at these veneer sites.
    return raw_halfword == 0x46C0 or raw_halfword == 0x0000;
}

fn resolveExactSimpleLocalThumbBlxR3CallerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const previous = try previousInstruction(image, isa, bl_address);
    const load = switch (previous.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (load.rd != 3 or load.base != 15) return null;
    return resolveMeasuredLocalThumbBlxR3CallerLiteralTarget(image, previous.address, load);
}

fn resolveExactObjDemoLocalThumbBlxR3CallerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const lsls_insn = try previousInstruction(image, isa, bl_address);
    const lsls = switch (lsls_insn.instruction) {
        .lsls_imm => |shift| shift,
        else => return null,
    };
    if (lsls.rd != 2 or lsls.rm != 2 or lsls.imm != 2) return null;

    const ldr_r0_insn = try previousInstruction(image, isa, lsls_insn.address);
    const ldr_r0 = switch (ldr_r0_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r0.rd != 0 or ldr_r0.base != 15) return null;

    const ldr_r1_insn = try previousInstruction(image, isa, ldr_r0_insn.address);
    const ldr_r1 = switch (ldr_r1_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r1.rd != 1 or ldr_r1.base != 15) return null;

    const ldr_r3_insn = try previousInstruction(image, isa, ldr_r1_insn.address);
    const ldr_r3 = switch (ldr_r3_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r3.rd != 3 or ldr_r3.base != 15) return null;

    return resolveMeasuredLocalThumbBlxR3CallerLiteralTarget(image, ldr_r3_insn.address, ldr_r3);
}

fn resolveExactObjDemoLocalThumbBlxR9VeneerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
    target_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const target = decodeImageInstructionUnchecked(image, .thumb, target_address) catch return null;
    const bx = switch (target.instruction) {
        .bx_reg => |bx| bx,
        else => return null,
    };
    if (bx.reg != 9) return null;
    if (!isMeasuredLocalThumbBlxR3VeneerNop(image, target_address + 2)) return null;

    const store_insn = try previousInstruction(image, isa, bl_address);
    const store = switch (store_insn.instruction) {
        .store => |store| store,
        else => return null,
    };
    if (store.src != 3 or store.base != 5 or store.size != .word) return null;
    switch (store.addressing) {
        .offset => |offset| switch (offset.offset) {
            .imm => |imm| if (imm != 0 or offset.subtract) return null,
            else => return null,
        },
        else => return null,
    }

    const lsls_r0_insn = try previousInstruction(image, isa, store_insn.address);
    const lsls_r0 = switch (lsls_r0_insn.instruction) {
        .lsls_imm => |shift| shift,
        else => return null,
    };
    if (lsls_r0.rd != 0 or lsls_r0.rm != 0 or lsls_r0.imm != 19) return null;

    const movs_r2_insn = try previousInstruction(image, isa, lsls_r0_insn.address);
    const movs_r2 = switch (movs_r2_insn.instruction) {
        .movs_imm => |mov| mov,
        else => return null,
    };
    if (movs_r2.rd != 2 or movs_r2.imm != 2) return null;

    const movs_r1_insn = try previousInstruction(image, isa, movs_r2_insn.address);
    const movs_r1 = switch (movs_r1_insn.instruction) {
        .movs_reg => |mov| mov,
        else => return null,
    };
    if (movs_r1.rd != 1 or movs_r1.rm != 5) return null;

    const literal_offset = romOffsetForAddress(image, target_address - 0x0C, .thumb) orelse return null;
    if (literal_offset + 4 > image.bytes.len) return null;
    const raw_target = armv4t_decode.readWord(image.bytes, literal_offset);
    const code_target = normalizeCodeTarget(raw_target);
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return null;
    return code_target;
}

fn resolveExactKeyDemoLocalThumbBlxR3CallerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const lsls_r0_insn = try previousInstruction(image, isa, bl_address);
    const lsls_r0 = switch (lsls_r0_insn.instruction) {
        .lsls_imm => |shift| shift,
        else => return null,
    };
    if (lsls_r0.rd != 0 or lsls_r0.rm != 0 or lsls_r0.imm != 19) return null;

    const lsls_r2_insn = try previousInstruction(image, isa, lsls_r0_insn.address);
    const lsls_r2 = switch (lsls_r2_insn.instruction) {
        .lsls_imm => |shift| shift,
        else => return null,
    };
    if (lsls_r2.rd != 2 or lsls_r2.rm != 2 or lsls_r2.imm != 6) return null;

    const ldr_r1_insn = try previousInstruction(image, isa, lsls_r2_insn.address);
    const ldr_r1 = switch (ldr_r1_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r1.rd != 1 or ldr_r1.base != 15) return null;

    const ldr_r3_insn = try previousInstruction(image, isa, ldr_r1_insn.address);
    const ldr_r3 = switch (ldr_r3_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r3.rd != 3 or ldr_r3.base != 15) return null;

    return resolveMeasuredLocalThumbBlxR3CallerLiteralTarget(image, ldr_r3_insn.address, ldr_r3);
}

fn resolveExactKeyDemoAddsLocalThumbBlxR3CallerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const adds_r2_insn = try previousInstruction(image, isa, bl_address);
    const adds_r2 = switch (adds_r2_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r2.rd != 2 or adds_r2.rn != 2 or adds_r2.imm != 30) return null;

    const ldr_r3_insn = try previousInstruction(image, isa, adds_r2_insn.address);
    const ldr_r3 = switch (ldr_r3_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r3.rd != 3 or ldr_r3.base != 15) return null;

    const ldr_r0_insn = try previousInstruction(image, isa, ldr_r3_insn.address);
    const ldr_r0 = switch (ldr_r0_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r0.rd != 0 or ldr_r0.base != 15) return null;

    return resolveMeasuredLocalThumbBlxR3CallerLiteralTarget(image, ldr_r3_insn.address, ldr_r3);
}

fn resolveExactSbbRegLocalThumbBlxR3CallerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const adds_r2_insn = try previousInstruction(image, isa, bl_address);
    const adds_r2 = switch (adds_r2_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r2.rd != 2 or adds_r2.rn != 2 or adds_r2.imm != 30) return null;

    const ldr_r3_insn = try previousInstruction(image, isa, adds_r2_insn.address);
    const ldr_r3 = switch (ldr_r3_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r3.rd != 3 or ldr_r3.base != 15) return null;

    const ldr_r0_insn = try previousInstruction(image, isa, ldr_r3_insn.address);
    const ldr_r0 = switch (ldr_r0_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r0.rd != 0 or ldr_r0.base != 15) return null;

    return resolveMeasuredLocalThumbBlxR3CallerLiteralTarget(image, ldr_r3_insn.address, ldr_r3);
}

fn resolveExactLibcInitArrayLocalThumbBlxR3CallerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const adds_r4_insn = try previousInstruction(image, isa, bl_address);
    const adds_r4 = switch (adds_r4_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r4.rd != 4 or adds_r4.rn != 4 or adds_r4.imm != 1) return null;

    const ldmia_insn = try previousInstruction(image, isa, adds_r4_insn.address);
    const ldmia = switch (ldmia_insn.instruction) {
        .ldm => |ldm| ldm,
        else => return null,
    };
    if (ldmia.base != 5 or ldmia.mask != (@as(u16, 1) << 3) or !ldmia.writeback or ldmia.mode != .ia) return null;

    const asrs_r6_insn = try previousInstruction(image, isa, ldmia_insn.address);
    const asrs_r6 = switch (asrs_r6_insn.instruction) {
        .asrs_imm => |shift| shift,
        else => return null,
    };
    if (asrs_r6.rd != 6 or asrs_r6.rm != 6 or asrs_r6.imm != 2) return null;

    const subs_r6_insn = try previousInstruction(image, isa, asrs_r6_insn.address);
    const subs_r6 = switch (subs_r6_insn.instruction) {
        .subs_reg => |sub| sub,
        else => return null,
    };
    if (subs_r6.rd != 6 or subs_r6.rn != 6 or subs_r6.rm != 5) return null;

    const movs_r4_insn = try previousInstruction(image, isa, subs_r6_insn.address);
    const movs_r4 = switch (movs_r4_insn.instruction) {
        .movs_imm => |mov| mov,
        else => return null,
    };
    if (movs_r4.rd != 4 or movs_r4.imm != 0) return null;

    const beq_insn = try previousInstruction(image, isa, movs_r4_insn.address);
    const beq = switch (beq_insn.instruction) {
        .branch => |branch| branch,
        else => return null,
    };
    if (beq.cond != .eq) return null;

    const cmp_insn = try previousInstruction(image, isa, beq_insn.address);
    const cmp = switch (cmp_insn.instruction) {
        .cmp_reg => |cmp| cmp,
        else => return null,
    };
    if (cmp.rn != 6 or cmp.rm != 5) return null;

    const ldr_r5_insn = try previousInstruction(image, isa, cmp_insn.address);
    const ldr_r5 = switch (ldr_r5_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r5.rd != 5 or ldr_r5.base != 15) return null;

    const ldr_r6_insn = try previousInstruction(image, isa, ldr_r5_insn.address);
    const ldr_r6 = switch (ldr_r6_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r6.rd != 6 or ldr_r6.base != 15) return null;

    const source_address = resolveThumbLiteralWordFromRom(image, ldr_r5_insn.address, ldr_r5) orelse return null;
    const source_end = resolveThumbLiteralWordFromRom(image, ldr_r6_insn.address, ldr_r6) orelse return null;
    const data_span = measuredDevkitArmIwramDataSpan(image) orelse return null;
    if (!data_span.contains(source_address)) return null;
    if (source_address & 3 != 0) return null;
    if (source_end != source_address and source_end != source_address + 4) return null;
    if (source_end > data_span.iwram_vma_start + data_span.size) return null;

    const raw_target = measuredDevkitArmIwramDataWord(image, source_address) orelse return null;
    const code_target = normalizeCodeTarget(raw_target);
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return null;
    return code_target;
}

// Resolve only the measured local caller literal family: in-ROM Thumb targets
// plus ARM targets that sit inside the measured startup-copied IWRAM code
// span, not generic indirect branches.
fn resolveMeasuredLocalThumbBlxR3CallerLiteralTarget(
    image: gba_loader.RomImage,
    load_address: u32,
    load: @FieldType(armv4t_decode.DecodedInstruction, "ldr_word_imm"),
) ?armv4t_decode.CodeAddress {
    const literal_address = pcValueForInstruction(.thumb, load_address) + load.offset;
    if (literal_address < image.base_address) return null;
    const literal_offset = literal_address - image.base_address;
    if (literal_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, literal_offset);
    if (offsetForAddress(image, raw_target, .arm) != null) return .{
        .address = raw_target,
        .isa = .arm,
    };

    const code_target = normalizeCodeTarget(raw_target);
    if (code_target.isa != .thumb) return null;
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return null;
    return code_target;
}

fn resolveThumbPcRelativeLiteralCodeTarget(
    image: gba_loader.RomImage,
    load_address: u32,
    load: @FieldType(armv4t_decode.DecodedInstruction, "ldr_word_imm"),
) BuildError!armv4t_decode.CodeAddress {
    const literal_address = pcValueForInstruction(.thumb, load_address) + load.offset;
    if (literal_address < image.base_address) return error.UnsupportedOpcode;
    const literal_offset = literal_address - image.base_address;
    if (literal_offset + 4 > image.bytes.len) return error.UnsupportedOpcode;

    const raw_target = armv4t_decode.readWord(image.bytes, literal_offset);
    const code_target = normalizeCodeTarget(raw_target);
    if (code_target.isa != .thumb) return error.UnsupportedOpcode;
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return error.UnsupportedOpcode;
    return code_target;
}

fn writeStartupThumbBlxR3VeneerRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    caller_load: u16,
    before_stub: u16,
    stub: u16,
    after_stub: u16,
    literal: u32,
) !void {
    var rom: [32]u8 = std.mem.zeroes([32]u8);
    std.mem.writeInt(u16, rom[2..4], caller_load, .little);
    std.mem.writeInt(u16, rom[6..8], before_stub, .little);
    std.mem.writeInt(u16, rom[8..10], stub, .little);
    std.mem.writeInt(u16, rom[10..12], after_stub, .little);
    std.mem.writeInt(u32, rom[16..20], literal, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeLocalThumbBlxR3VeneerRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    caller_load: u16,
    stub: u16,
    after_stub: u16,
    literal: u32,
) !void {
    var rom: [24]u8 = std.mem.zeroes([24]u8);
    std.mem.writeInt(u16, rom[2..4], caller_load, .little);
    std.mem.writeInt(u16, rom[8..10], stub, .little);
    std.mem.writeInt(u16, rom[10..12], after_stub, .little);
    std.mem.writeInt(u32, rom[16..20], literal, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeSeparatedLocalThumbBlxR3VeneerRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    caller_load: u16,
    between: [3]u16,
    stub: u16,
    after_stub: u16,
    literal: u32,
) !void {
    var rom: [28]u8 = std.mem.zeroes([28]u8);
    std.mem.writeInt(u16, rom[2..4], caller_load, .little);
    std.mem.writeInt(u16, rom[4..6], between[0], .little);
    std.mem.writeInt(u16, rom[6..8], between[1], .little);
    std.mem.writeInt(u16, rom[8..10], between[2], .little);
    std.mem.writeInt(u16, rom[12..14], stub, .little);
    std.mem.writeInt(u16, rom[14..16], after_stub, .little);
    std.mem.writeInt(u32, rom[20..24], literal, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn resolveStartupThumbBxR6TargetValue(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) BuildError!u32 {
    const previous = try previousInstruction(image, isa, address);

    return switch (previous.instruction) {
        .bl => try resolveStartupThumbBxR6TargetValue(image, isa, previous.address),
        .store => try resolveStartupThumbBxR6TargetValue(image, isa, previous.address),
        .ldr_word_imm => |load| if (load.rd != 6)
            try resolveStartupThumbBxR6TargetValue(image, isa, previous.address)
        else
            return error.UnsupportedOpcode,
        .subs_reg => |sub| if (sub.rd != 6)
            try resolveStartupThumbBxR6TargetValue(image, isa, previous.address)
        else
            return error.UnsupportedOpcode,
        .add_imm => |add| blk: {
            if (add.rd != 6 or add.imm != 0) return error.UnsupportedOpcode;
            break :blk switch (add.rn) {
                2 => try resolveStartupThumbBxR6TargetValue(image, isa, previous.address),
                else => return error.UnsupportedOpcode,
            };
        },
        .adds_imm => |add| blk: {
            if (add.rd != 6 or add.imm != 0) return error.UnsupportedOpcode;
            break :blk switch (add.rn) {
                2 => try resolveStartupThumbBxR6TargetValue(image, isa, previous.address),
                else => return error.UnsupportedOpcode,
            };
        },
        .movs_imm => |mov| if (mov.rd == 2)
            mov.imm
        else
            return error.UnsupportedOpcode,
        .lsls_imm => |shift| if (shift.rd == 2 and shift.rm == 2 and shift.imm == 24)
            try resolveStartupThumbBxR6TargetValue(image, isa, previous.address) << @as(u5, @intCast(shift.imm))
        else if (shift.rd != 6)
            try resolveStartupThumbBxR6TargetValue(image, isa, previous.address)
        else
            return error.UnsupportedOpcode,
        else => return error.UnsupportedOpcode,
    };
}

fn resolveMovPcTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!armv4t_decode.DecodedInstruction {
    const target = normalizePcWriteTarget(try resolvePreviousRegisterValue(image, isa, address, reg), isa);
    if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
    return .{ .branch = .{
        .cond = .al,
        .target = target,
    } };
}

fn resolveAddRegPcTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    add: @FieldType(armv4t_decode.DecodedInstruction, "add_reg"),
) BuildError!armv4t_decode.DecodedInstruction {
    const lhs = if (add.rn == 15)
        pcValueForInstruction(isa, address)
    else
        try resolvePreviousRegisterValue(image, isa, address, add.rn);
    const rhs = if (add.rm == 15)
        pcValueForInstruction(isa, address)
    else
        try resolvePreviousRegisterValue(image, isa, address, add.rm);
    const target = normalizePcWriteTarget(lhs + rhs, isa);
    if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
    return .{ .add_reg_pc_target = .{ .target = target } };
}

fn resolveLdrPcPostImmTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    load: @FieldType(armv4t_decode.DecodedInstruction, "ldr_word_post_imm"),
) BuildError!armv4t_decode.DecodedInstruction {
    const raw_target = try resolvePreviousStoredWordValue(image, isa, address, load.base);
    const target = normalizePcWriteTarget(raw_target, isa);
    if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
    return .{ .ldr_pc_post_imm_target = .{
        .base = load.base,
        .offset = load.offset,
        .subtract = load.subtract,
        .target = target,
    } };
}

fn resolveLdmPcTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    ldm: @FieldType(armv4t_decode.DecodedInstruction, "ldm"),
) BuildError!armv4t_decode.DecodedInstruction {
    const raw_target = try resolvePreviousStoredBlockValue(image, isa, address, ldm.base, ldm.mode, ldm.mask, 15);
    const target = normalizePcWriteTarget(raw_target, isa);
    if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
    return .{ .ldm_pc_target = .{
        .base = ldm.base,
        .mask = ldm.mask,
        .writeback = ldm.writeback,
        .mode = ldm.mode,
        .target = target,
    } };
}

fn resolveLdmEmptyPcTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    ldm: @FieldType(armv4t_decode.DecodedInstruction, "ldm_empty"),
) BuildError!armv4t_decode.DecodedInstruction {
    if (ldm.mode != .ia) return error.UnsupportedOpcode;
    const raw_target = try resolvePreviousStoredWordValue(image, isa, address, ldm.base);
    const target = normalizePcWriteTarget(raw_target, isa);
    if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
    return .{ .ldm_empty_pc_target = .{
        .base = ldm.base,
        .writeback = ldm.writeback,
        .mode = ldm.mode,
        .target = target,
    } };
}

fn resolvePreviousStoredWordValue(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    base_reg: u4,
) BuildError!u32 {
    const previous = try previousInstruction(image, isa, address);

    return switch (previous.instruction) {
        .store => |store| blk: {
            if (store.size != .word) return error.UnsupportedOpcode;
            if (store.base != base_reg) return error.UnsupportedOpcode;
            switch (store.addressing) {
                .offset => |offset_value| switch (offset_value.offset) {
                    .imm => |imm| if (imm == 0 and !offset_value.subtract) {} else return error.UnsupportedOpcode,
                    else => return error.UnsupportedOpcode,
                },
                else => return error.UnsupportedOpcode,
            }
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, store.src);
        },
        .mov_reg => |mov| blk: {
            if (mov.rd != base_reg or mov.rm == 15) return error.UnsupportedOpcode;
            break :blk try resolvePreviousStoredWordValue(image, isa, previous.address, mov.rm);
        },
        else => error.UnsupportedOpcode,
    };
}

fn resolvePreviousStoredBlockValue(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    base_reg: u4,
    load_mode: armv4t_decode.BlockTransferMode,
    load_mask: u16,
    target_reg: u4,
) BuildError!u32 {
    const previous = try previousInstruction(image, isa, address);

    const current_slot_index = registerMaskSlotIndex(load_mask, target_reg) orelse return error.UnsupportedOpcode;
    const current_relative = blockTransferRelativeOffset(load_mode, load_mask, current_slot_index);

    return switch (previous.instruction) {
        .stm => |stm| blk: {
            if (!stm.writeback) return error.UnsupportedOpcode;
            if (stm.base != base_reg) return error.UnsupportedOpcode;
            const previous_slot_index = findBlockTransferSlotIndexForRelative(stm.mode, stm.mask, current_relative, true) orelse return error.UnsupportedOpcode;
            const previous_reg = registerAtMaskSlot(stm.mask, previous_slot_index) orelse return error.UnsupportedOpcode;
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, previous_reg);
        },
        .push => |mask| blk: {
            if (base_reg != 13) return error.UnsupportedOpcode;
            const previous_slot_index = findBlockTransferSlotIndexForRelative(.db, mask, current_relative, true) orelse return error.UnsupportedOpcode;
            const previous_reg = registerAtMaskSlot(mask, previous_slot_index) orelse return error.UnsupportedOpcode;
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, previous_reg);
        },
        else => error.UnsupportedOpcode,
    };
}

fn resolvePreviousRegisterValue(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!u32 {
    const previous = try previousInstruction(image, isa, address);

    return switch (previous.instruction) {
        .add_imm => |add| blk: {
            if (add.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            if (add.rn == 15) break :blk pcValueForInstruction(isa, previous.address) + add.imm;
            if (add.rn != reg) return error.UnsupportedOpcode;
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg) + add.imm;
        },
        .adds_imm => |add| blk: {
            if (add.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            if (add.rn == 15) break :blk pcValueForInstruction(isa, previous.address) + add.imm;
            if (add.rn != reg) return error.UnsupportedOpcode;
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg) + add.imm;
        },
        .mov_imm => |mov| blk: {
            if (mov.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            break :blk mov.imm;
        },
        .movs_imm => |mov| blk: {
            if (mov.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            break :blk mov.imm;
        },
        .mov_reg => |mov| blk: {
            if (mov.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            if (mov.rm == 15) return error.UnsupportedOpcode;
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, mov.rm);
        },
        .orr_imm => |orr| blk: {
            if (orr.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            if (orr.rn == 15) break :blk pcValueForInstruction(isa, previous.address) | orr.imm;
            if (orr.rn != reg) return error.UnsupportedOpcode;
            break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg) | orr.imm;
        },
        else => error.UnsupportedOpcode,
    };
}

fn normalizeCodeTarget(raw_target: u32) armv4t_decode.CodeAddress {
    return .{
        .address = raw_target & ~@as(u32, 1),
        .isa = if ((raw_target & 1) == 0) .arm else .thumb,
    };
}

fn normalizePcWriteTarget(raw_target: u32, isa: armv4t_decode.InstructionSet) u32 {
    return switch (isa) {
        .arm => raw_target & ~@as(u32, 3),
        .thumb => raw_target & ~@as(u32, 1),
    };
}

fn maybeEnqueueVectorTarget(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    pending_functions: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    decoded: armv4t_decode.DecodedInstruction,
) BuildError!void {
    const store = switch (decoded) {
        .store => |store| store,
        else => return,
    };

    if (store.size != .word) return;

    const absolute_address = switch (store.addressing) {
        .offset => |offset_value| switch (offset_value.offset) {
            .imm => |imm| blk: {
                const base = resolvePreviousRegisterValue(image, isa, address, store.base) catch return;
                const offset = if (offset_value.subtract) -@as(i64, imm) else @as(i64, imm);
                break :blk @as(u32, @intCast(@as(i64, base) + offset));
            },
            else => return,
        },
        else => return,
    };

    if (absolute_address != 0x0300_7FFC) return;

    const raw_target = resolvePreviousRegisterValue(image, isa, address, store.src) catch return;
    try enqueueFunctionAddress(allocator, writer, pending_functions, image, normalizeCodeTarget(raw_target));
}

fn blockTransferRelativeOffset(
    mode: armv4t_decode.BlockTransferMode,
    mask: u16,
    slot_index: u16,
) i32 {
    const reg_count = registerMaskCount(mask);
    return blockTransferStartOffset(mode, reg_count) + @as(i32, @intCast(slot_index * 4));
}

fn blockTransferStartOffset(mode: armv4t_decode.BlockTransferMode, reg_count: u16) i32 {
    return switch (mode) {
        .ia => 0,
        .ib => 4,
        .da => -@as(i32, @intCast((reg_count - 1) * 4)),
        .db => -@as(i32, @intCast(reg_count * 4)),
    };
}

fn blockTransferWritebackOffset(mode: armv4t_decode.BlockTransferMode, reg_count: u16) i32 {
    return switch (mode) {
        .ia, .ib => @intCast(reg_count * 4),
        .da, .db => -@as(i32, @intCast(reg_count * 4)),
    };
}

fn registerMaskCount(mask: u16) u16 {
    return @popCount(mask);
}

fn registerMaskSlotIndex(mask: u16, reg: u4) ?u16 {
    if ((mask & (@as(u16, 1) << reg)) == 0) return null;
    var slot: u16 = 0;
    var reg_index: u4 = 0;
    while (reg_index < reg) : (reg_index += 1) {
        if ((mask & (@as(u16, 1) << reg_index)) != 0) slot += 1;
    }
    return slot;
}

fn registerAtMaskSlot(mask: u16, slot: u16) ?u4 {
    var current_slot: u16 = 0;
    for (0..16) |reg_index_usize| {
        const reg_index: u4 = @intCast(reg_index_usize);
        if ((mask & (@as(u16, 1) << reg_index)) == 0) continue;
        if (current_slot == slot) return reg_index;
        current_slot += 1;
    }
    return null;
}

fn findBlockTransferSlotIndexForRelative(
    mode: armv4t_decode.BlockTransferMode,
    mask: u16,
    relative_offset: i32,
    relative_to_writeback_base: bool,
) ?u16 {
    const reg_count = registerMaskCount(mask);
    for (0..reg_count) |slot_usize| {
        const slot: u16 = @intCast(slot_usize);
        var slot_relative = blockTransferRelativeOffset(mode, mask, slot);
        if (relative_to_writeback_base) {
            slot_relative -= blockTransferWritebackOffset(mode, reg_count);
        }
        if (slot_relative == relative_offset) return slot;
    }
    return null;
}

fn writesUnsupportedPcDestination(decoded: armv4t_decode.DecodedInstruction) bool {
    return switch (decoded) {
        .mov_imm => |mov| mov.rd == 15,
        .mov_reg => |mov| mov.rd == 15 and mov.rm != 14,
        .movs_imm => |mov| mov.rd == 15,
        .mvn_imm => |mvn| mvn.rd == 15,
        .mvn_reg => |mvn| mvn.rd == 15,
        .movs_reg => |mov| mov.rd == 15,
        .orr_imm => |orr| orr.rd == 15,
        .orr_reg => |orr| orr.rd == 15,
        .eor_imm => |eor| eor.rd == 15,
        .eor_reg => |eor| eor.rd == 15,
        .bic_imm => |bic| bic.rd == 15,
        .bic_reg => |bic| bic.rd == 15,
        .orr_shift_reg => |orr| orr.rd == 15,
        .and_imm => |and_op| and_op.rd == 15,
        .and_reg => |and_op| and_op.rd == 15,
        .add_imm => |add| add.rd == 15,
        .adds_imm => |add| add.rd == 15,
        .adcs_imm => |add| add.rd == 15,
        .adcs_shift_reg => |add| add.rd == 15,
        .adc_imm => |add| add.rd == 15,
        .sbcs_imm => |sub| sub.rd == 15,
        .sbcs_reg => |sub| sub.rd == 15,
        .sbc_imm => |sub| sub.rd == 15,
        .add_reg => |add| add.rd == 15,
        .add_shift_reg => |add| add.rd == 15,
        .rsb_imm => |sub| sub.rd == 15,
        .rsbs_imm => |sub| sub.rd == 15,
        .rsc_imm => |sub| sub.rd == 15,
        .sub_imm => |sub| sub.rd == 15,
        .subs_imm => |sub| sub.rd == 15,
        .subs_reg => |sub| sub.rd == 15,
        .lsl_imm => |shift| shift.rd == 15,
        .lsl_reg => |shift| shift.rd == 15,
        .asr_imm => |shift| shift.rd == 15,
        .asr_reg => |shift| shift.rd == 15,
        .lsls_imm => |shift| shift.rd == 15,
        .lsls_reg => |shift| shift.rd == 15,
        .lsr_imm => |shift| shift.rd == 15,
        .lsrs_imm => |shift| shift.rd == 15,
        .lsr_reg => |shift| shift.rd == 15,
        .lsrs_reg => |shift| shift.rd == 15,
        .asrs_imm => |shift| shift.rd == 15,
        .asrs_reg => |shift| shift.rd == 15,
        .ror_imm => |shift| shift.rd == 15,
        .ror_reg => |shift| shift.rd == 15,
        .rors_imm => |shift| shift.rd == 15,
        .rors_reg => |shift| shift.rd == 15,
        .rrxs => |rrx| rrx.rd == 15,
        .mul => |mul| mul.rd == 15,
        .mla => |mla| mla.rd == 15,
        .umull => |mul| mul.rdlo == 15 or mul.rdhi == 15,
        .umlal => |mul| mul.rdlo == 15 or mul.rdhi == 15,
        .smull => |mul| mul.rdlo == 15 or mul.rdhi == 15,
        .smlal => |mul| mul.rdlo == 15 or mul.rdhi == 15,
        .swp_word => |swp| swp.rd == 15,
        .swp_byte => |swp| swp.rd == 15,
        .ldr_word_imm => |load| load.rd == 15,
        .ldr_word_imm_signed => |load| load.rd == 15,
        .ldr_byte_imm => |load| load.rd == 15,
        .ldr_byte_post_imm => |load| load.rd == 15,
        .ldr_byte_reg => |load| load.rd == 15,
        .ldr_halfword_imm => |load| load.rd == 15,
        .ldr_halfword_pre_index_reg => |load| load.rd == 15,
        .ldr_halfword_pre_index_imm => |load| load.rd == 15,
        .ldr_halfword_post_imm => |load| load.rd == 15,
        .ldr_signed_halfword_imm => |load| load.rd == 15,
        .ldr_signed_halfword_reg => |load| load.rd == 15,
        .ldr_signed_byte_imm => |load| load.rd == 15,
        .ldr_signed_byte_reg => |load| load.rd == 15,
        .ldr_word_pre_index_reg_shift => |load| load.rd == 15,
        .ldr_word_pre_index_imm => |load| load.rd == 15,
        .ldr_word_post_imm => |load| load.rd == 15,
        .ldm => |ldm| registerMaskIncludesPc(ldm.mask),
        .ldm_empty => true,
        .mrs_psr => |mrs| mrs.rd == 15,
        else => false,
    };
}

fn registerMaskIncludesPc(mask: u16) bool {
    return (mask & (@as(u16, 1) << 15)) != 0;
}

fn pcValueForInstruction(isa: armv4t_decode.InstructionSet, address: u32) u32 {
    return switch (isa) {
        .arm => address + 8,
        .thumb => (address + 4) & ~@as(u32, 3),
    };
}

fn instructionSizeBytes(isa: armv4t_decode.InstructionSet) u8 {
    return switch (isa) {
        .arm => 4,
        .thumb => 2,
    };
}

fn decodeCondition(raw_opcode: u32, isa: armv4t_decode.InstructionSet) BuildError!armv4t_decode.Cond {
    if (isa == .thumb) return .al;
    return switch (raw_opcode >> 28) {
        0x0 => .eq,
        0x1 => .ne,
        0x2 => .hs,
        0x3 => .lo,
        0x4 => .mi,
        0x5 => .pl,
        0x6 => .vs,
        0x7 => .vc,
        0x8 => .hi,
        0x9 => .ls,
        0xA => .ge,
        0xB => .lt,
        0xC => .gt,
        0xD => .le,
        0xE => .al,
        else => error.UnsupportedOpcode,
    };
}

fn codeAddressEqual(a: armv4t_decode.CodeAddress, b: armv4t_decode.CodeAddress) bool {
    return a.address == b.address and a.isa == b.isa;
}

fn codeAddressLessThan(a: armv4t_decode.CodeAddress, b: armv4t_decode.CodeAddress) bool {
    if (a.address != b.address) return a.address < b.address;
    return @intFromEnum(a.isa) < @intFromEnum(b.isa);
}

fn branchInstructionName(cond: armv4t_decode.Cond) []const u8 {
    return switch (cond) {
        .eq => "beq",
        .ne => "bne",
        .hs => "bhs",
        .lo => "blo",
        .mi => "bmi",
        .pl => "bpl",
        .vs => "bvs",
        .vc => "bvc",
        .hi => "bhi",
        .ls => "bls",
        .ge => "bge",
        .lt => "blt",
        .gt => "bgt",
        .le => "ble",
        .al => "b",
    };
}

fn isDivSwi(imm24: u24) bool {
    return imm24 == 0x000006 or imm24 == 0x060000;
}

fn isVBlankIntrWaitSwi(imm24: u24) bool {
    return imm24 == 0x000005 or imm24 == 0x050000;
}

fn isSqrtSwi(imm24: u24) bool {
    return imm24 == 0x000008 or imm24 == 0x080000;
}

fn swiShimName(imm24: u24) ?[]const u8 {
    if (imm24 == 0x000000) return "SoftReset";
    if (isVBlankIntrWaitSwi(imm24)) return "VBlankIntrWait";
    if (isDivSwi(imm24)) return "Div";
    if (isSqrtSwi(imm24)) return "Sqrt";
    return null;
}

fn isStore(decoded: armv4t_decode.DecodedInstruction) bool {
    return switch (decoded) {
        .store => true,
        .stm => true,
        .stm_empty => true,
        else => false,
    };
}

fn renderUnsupportedOpcode(writer: *Io.Writer, word: u32, address: u32) Io.Writer.Error!void {
    try writer.print(
        "Unsupported opcode 0x{X:0>8} at 0x{X:0>8} for armv4t\n",
        .{ word, address },
    );
}

fn renderUnsupportedShim(writer: *Io.Writer, address: u32, imm24: u24) Io.Writer.Error!void {
    try writer.print(
        "Unsupported SWI 0x{X:0>6} at 0x{X:0>8} for gba\n",
        .{ imm24, address },
    );
}

fn llvmPath(allocator: std.mem.Allocator, output_path: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.ll", .{output_path});
}

fn ensureParentDir(io: std.Io, cwd: Io.Dir, sub_path: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |dirname| {
        var dir = try cwd.createDirPathOpen(io, dirname, .{});
        dir.close(io);
    }
}

fn writeLlvmFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    llvm_path: []const u8,
    program: llvm_codegen.Program,
) BuildError!void {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try llvm_codegen.emitModule(&output.writer, program);
    try cwd.writeFile(io, .{
        .sub_path = llvm_path,
        .data = output.writer.buffered(),
    });
}

fn compileLlvm(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    writer: *Io.Writer,
    llvm_path: []const u8,
    runtime_helper_obj: ?[]const u8,
    options: BuildOptions,
) BuildError!void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const maybe_target_flag = if (options.target) |target|
        try std.fmt.allocPrint(allocator, "--target={s}", .{target})
    else
        null;
    defer if (maybe_target_flag) |target_flag| allocator.free(target_flag);

    try argv.append(allocator, "clang");
    try argv.append(allocator, clangOptimizeFlag(options.optimize));
    try argv.append(allocator, "-x");
    try argv.append(allocator, "ir");
    try argv.append(allocator, llvm_path);
    if (runtime_helper_obj) |helper_obj| {
        try argv.append(allocator, "-x");
        try argv.append(allocator, "none");
        try argv.append(allocator, helper_obj);
    }
    if (maybe_target_flag) |target_flag| {
        try argv.append(allocator, target_flag);
    }
    try argv.append(allocator, "-o");
    try argv.append(allocator, options.output_path);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!std.meta.eql(result.term, std.process.Child.Term{ .exited = 0 })) {
        if (result.stderr.len != 0) {
            try writer.print("{s}", .{result.stderr});
        }
        return error.ToolFailed;
    }
}

fn compileRuntimeHelper(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    writer: *Io.Writer,
    options: BuildOptions,
) BuildError!?[]u8 {
    const helper_dir = ".zig-cache";
    const helper_source_path = ".zig-cache/hm_gba_ppu_runtime.zig";
    const helper_object_path = try allocator.dupe(u8, ".zig-cache/hm_gba_ppu_runtime.o");
    errdefer allocator.free(helper_object_path);

    try cwd.createDirPath(io, helper_dir);
    try cwd.writeFile(io, .{ .sub_path = helper_source_path, .data = gba_ppu_source });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    const emit_bin_flag = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{helper_object_path});
    defer allocator.free(emit_bin_flag);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "build-obj");
    try argv.append(allocator, helper_source_path);
    try argv.append(allocator, "-O");
    try argv.append(allocator, zigOptimizeModeArg(options.optimize));
    try argv.append(allocator, "-fPIC");
    if (options.target) |target| {
        try argv.append(allocator, "-target");
        try argv.append(allocator, target);
    }
    try argv.append(allocator, emit_bin_flag);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!std.meta.eql(result.term, std.process.Child.Term{ .exited = 0 })) {
        if (result.stderr.len != 0) {
            try writer.print("{s}", .{result.stderr});
        }
        return error.ToolFailed;
    }
    return helper_object_path;
}

const FixtureBuildResult = struct {
    failed: bool,
    stderr: []u8,
};

fn readFixtureBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom_path: []const u8,
) ![]u8 {
    return dir.readFileAlloc(io, rom_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => Io.Dir.cwd().readFileAlloc(
            io,
            rom_path,
            allocator,
            .limited(16 * 1024 * 1024),
        ),
        else => err,
    };
}

fn buildFixtureCaptureOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom_path: []const u8,
) !FixtureBuildResult {
    const fixture_bytes = try readFixtureBytes(allocator, io, dir, rom_path);
    defer allocator.free(fixture_bytes);

    const rom_name = std.fs.path.basename(rom_path);
    try dir.writeFile(io, .{ .sub_path = rom_name, .data = fixture_bytes });

    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    run(io, allocator, dir, &output.writer, .{
        .rom_path = rom_name,
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_mode = .frame_raw,
        .max_instructions = 50_000,
        .output_path = ".zig-cache/tonc/should-not-exist",
        .optimize = .release,
    }) catch {
        return .{
            .failed = true,
            .stderr = try output.toOwnedSlice(),
        };
    };
    return .{
        .failed = false,
        .stderr = try output.toOwnedSlice(),
    };
}

fn buildFixtureNative(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom_path: []const u8,
    output_name: []const u8,
    output_mode: parse.OutputMode,
    max_instructions: u64,
) ![]u8 {
    const fixture_bytes = try readFixtureBytes(allocator, io, dir, rom_path);
    defer allocator.free(fixture_bytes);

    const rom_name = std.fs.path.basename(rom_path);
    try dir.writeFile(io, .{ .sub_path = rom_name, .data = fixture_bytes });

    const native_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ".zig-cache/tonc", output_name });
    errdefer allocator.free(native_path);

    var discard: Io.Writer.Allocating = .init(allocator);
    defer discard.deinit();

    try run(io, allocator, dir, &discard.writer, .{
        .rom_path = rom_name,
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_path = native_path,
        .output_mode = output_mode,
        .max_instructions = max_instructions,
        .optimize = .release,
    });
    return native_path;
}

fn runFrameFixture(
    io: std.Io,
    dir: std.Io.Dir,
    native_path: []const u8,
    frame_name: []const u8,
    options: tonc_fixture_support.RunFrameOptions,
) !void {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    try environ_map.put("HOMONCULI_OUTPUT_MODE", "frame_raw");
    try environ_map.put("HOMONCULI_OUTPUT_PATH", frame_name);
    const max_instructions = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{options.max_instructions});
    defer std.testing.allocator.free(max_instructions);
    try environ_map.put("HOMONCULI_MAX_INSTRUCTIONS", max_instructions);
    if (options.keyinput_script) |script| {
        try environ_map.put("HOMONCULI_KEYINPUT_SCRIPT", script);
    }

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{native_path},
        .cwd = .{ .dir = dir },
        .environ_map = &environ_map,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
}

const NativeRunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

fn runNativeCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    native_path: []const u8,
    output_mode: ?[]const u8,
    max_instructions: ?u64,
) !NativeRunResult {
    var environ_map = std.process.Environ.Map.init(allocator);
    errdefer environ_map.deinit();

    if (output_mode) |mode| try environ_map.put("HOMONCULI_OUTPUT_MODE", mode);
    if (max_instructions) |limit| {
        const rendered = try std.fmt.allocPrint(allocator, "{d}", .{limit});
        defer allocator.free(rendered);
        try environ_map.put("HOMONCULI_MAX_INSTRUCTIONS", rendered);
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{native_path},
        .cwd = .{ .dir = dir },
        .environ_map = &environ_map,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    environ_map.deinit();

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn repoRelativeTmpPath(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
    leaf: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], leaf });
}

fn buildFixtureNativeViaCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: *std.testing.TmpDir,
    rom_path: []const u8,
    output_name: []const u8,
    output_mode: parse.OutputMode,
    max_instructions: u64,
) ![]u8 {
    const fixture_bytes = try readFixtureBytes(allocator, io, tmp.dir, rom_path);
    defer allocator.free(fixture_bytes);

    const rom_name = std.fs.path.basename(rom_path);
    try tmp.dir.writeFile(io, .{ .sub_path = rom_name, .data = fixture_bytes });

    const native_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ".zig-cache/tonc", output_name });
    errdefer allocator.free(native_path);
    const repo_rom_path = try repoRelativeTmpPath(allocator, tmp, rom_name);
    defer allocator.free(repo_rom_path);
    const repo_native_path = try repoRelativeTmpPath(allocator, tmp, native_path);
    defer allocator.free(repo_native_path);

    const output_mode_arg = switch (output_mode) {
        .frame_raw => "frame_raw",
        .retired_count => "retired_count",
        .auto => unreachable,
    };
    const max_instructions_arg = try std.fmt.allocPrint(allocator, "{d}", .{max_instructions});
    defer allocator.free(max_instructions_arg);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "zig",
            "build",
            "run",
            "--",
            "build",
            repo_rom_path,
            "--machine",
            "gba",
            "--target",
            "x86_64-linux",
            "--output",
            output_mode_arg,
            "--max-instructions",
            max_instructions_arg,
            "--opt",
            "release",
            "-o",
            repo_native_path,
        },
        .cwd = .{ .dir = Io.Dir.cwd() },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!std.meta.eql(result.term, std.process.Child.Term{ .exited = 0 })) {
        if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        return error.ToolFailed;
    }
    return native_path;
}

fn expectToncGoldenFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    demo_name: []const u8,
    actual_frame: []const u8,
    fixture: tonc_fixture_support.GoldenFixture,
) !void {
    const expected_frame = try frame_test_support.readExactFrame(allocator, io, Io.Dir.cwd(), fixture.path);
    defer allocator.free(expected_frame);

    if (!std.mem.eql(u8, expected_frame, actual_frame)) {
        const scratch_dir = ".zig-cache/tonc-parity";
        const scratch_path = try std.fmt.allocPrint(allocator, "{s}/{s}.actual.rgba", .{ scratch_dir, demo_name });
        defer allocator.free(scratch_path);

        try Io.Dir.cwd().createDirPath(io, scratch_dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = scratch_path, .data = actual_frame });
        std.debug.print(
            "tonc parity mismatch for {s}; wrote actual frame to {s}; expected golden {s}\n",
            .{ demo_name, scratch_path, fixture.path },
        );
    }

    try std.testing.expectEqualSlices(u8, expected_frame, actual_frame);
}

fn writeThumbStartupBranchRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    literal: u32,
) !void {
    var rom: [180]u8 = std.mem.zeroes([180]u8);
    rom[0] = 0x2B;
    rom[1] = 0x48;
    rom[2] = 0x40;
    rom[3] = 0x01;
    rom[4] = 0x0B;
    rom[5] = 0xD2;
    std.mem.writeInt(u32, rom[176..180], literal, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeKeyinputReplayRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F4028, // ldr r4, [pc, #0x28]
        0xE1D410B0, // ldrh r1, [r4]
        0xEF000005, // swi 0x05
        0xE1D420B0, // ldrh r2, [r4]
        0xEF000005, // swi 0x05
        0xEF000005, // swi 0x05
        0xE1D430B0, // ldrh r3, [r4]
        0xE1A02502, // mov r2, r2, lsl #10
        0xE1820001, // orr r0, r2, r1
        0xE1A03A03, // mov r3, r3, lsl #20
        0xE1800003, // orr r0, r0, r3
        0xEF000000, // swi 0x00
        0x04000130, // KEYINPUT
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeNonVBlankIeRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0008, // ldr r0, [pc, #8]
        0xE3A01002, // mov r1, #2
        0xE1C010B0, // strh r1, [r0]
        0xEF000000, // swi 0x00
        0x04000200, // IE
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeInterruptByteStoreRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    address: u32,
) !void {
    const words = [_]u32{
        0xE59F0008, // ldr r0, [pc, #8]
        0xE3A01001, // mov r1, #1
        0xE5C01000, // strb r1, [r0]
        0xEF000000, // swi 0x00
        address,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeNestedImeRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xEB00000F,
        0xE59F005C,
        0xE59F105C,
        0xE5801000,
        0xE59F0058,
        0xE3A01008,
        0xE1C010B0,
        0xE59F0050,
        0xE3A01001,
        0xE1C010B0,
        0xE59F0048,
        0xE3A01001,
        0xE1C010B0,
        0xE59F0034,
        0xE5902000,
        0xEF000005,
        0xEAFFFFFD,
        0xE92D4003,
        0xE59F0028,
        0xE3A01001,
        0xE1C010B0,
        0xE59F0020,
        0xE3A01001,
        0xE1C010B0,
        0xE8BD4003,
        0xE12FFF1E,
        0x03007FFC,
        0x08000044,
        0x04000004,
        0x04000200,
        0x04000208,
        0x04000202,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

test "build emits a native executable for the first gba mov-plus-div slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3,
        0x02, 0x10, 0xA0, 0xE3,
        0x06, 0x00, 0x00, 0xEF,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "div.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "div.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-div-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-div-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("5\n", result.stdout);
}

test "gba keyinput startup state seeds frame 0 and VBlankIntrWait advances deterministically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeKeyinputReplayRom(tmp.dir, io, "keyinput-replay.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "keyinput-replay.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "keyinput-replay-native",
        },
    );

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOMONCULI_KEYINPUT_SCRIPT", "03ff,03fe,03fd,03fb");

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./keyinput-replay-native"},
        .cwd = .{ .dir = tmp.dir },
        .environ_map = &environ_map,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    const expected_value: u32 = 0x03FF | (0x03FE << 10) | (0x03FB << 20);
    const expected_stdout = try std.fmt.allocPrint(std.testing.allocator, "{d}\n", .{expected_value});
    defer std.testing.allocator.free(expected_stdout);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings(expected_stdout, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "devkitARM crt0 header-check pruning accepts the startup pattern" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeThumbStartupBranchRom(tmp.dir, io, "startup.gba", 0x0800_0000);

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "startup.gba");
    defer image.deinit(std.testing.allocator);

    const branch = @FieldType(armv4t_decode.DecodedInstruction, "branch"){
        .cond = .hs,
        .target = 0x0800_0100,
    };

    try std.testing.expectEqual(
        @as(?bool, true),
        try resolveDevkitArmCrt0HeaderCheckBranch(image, .thumb, 0x0800_0004, branch),
    );
}

test "devkitARM crt0 header-check pruning ignores near-miss literals" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeThumbStartupBranchRom(tmp.dir, io, "startup-near-miss.gba", 0x0400_0000);

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "startup-near-miss.gba");
    defer image.deinit(std.testing.allocator);

    const branch = @FieldType(armv4t_decode.DecodedInstruction, "branch"){
        .cond = .hs,
        .target = 0x0800_0100,
    };

    try std.testing.expectEqual(
        @as(?bool, null),
        try resolveDevkitArmCrt0HeaderCheckBranch(image, .thumb, 0x0800_0004, branch),
    );
}

test "devkitARM crt0 startup blx r3 veneer resolves the caller literal target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeStartupThumbBlxR3VeneerRom(
        tmp.dir,
        io,
        "startup-blx-r3.gba",
        0x4B03,
        0x4770,
        0x4718,
        0x1AA3,
        0x0800_0009,
    );

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "startup-blx-r3.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(
        @as(?armv4t_decode.CodeAddress, .{ .address = 0x0800_0008, .isa = .thumb }),
        try resolveDevkitArmCrt0StartupThumbBlxR3Target(image, .thumb, 0x0800_0004, 0x0800_0008),
    );
}

test "devkitARM crt0 startup blx r3 veneer rejects boundary mismatches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        caller_load: u16,
        before_stub: u16,
        stub: u16,
        after_stub: u16,
        expected: ?armv4t_decode.CodeAddress,
    }{
        .{
            .caller_load = 0x4A03,
            .before_stub = 0x4770,
            .stub = 0x4718,
            .after_stub = 0x1AA3,
            .expected = null,
        },
        .{
            .caller_load = 0x6803,
            .before_stub = 0x4770,
            .stub = 0x4718,
            .after_stub = 0x1AA3,
            .expected = null,
        },
        .{
            .caller_load = 0x4B03,
            .before_stub = 0x46C0,
            .stub = 0x4718,
            .after_stub = 0x1AA3,
            .expected = null,
        },
        .{
            .caller_load = 0x4B03,
            .before_stub = 0x4770,
            .stub = 0x4718,
            .after_stub = 0x46C0,
            .expected = null,
        },
    };

    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "startup-blx-r3-{d}.gba", .{index});
        defer std.testing.allocator.free(path);

        try writeStartupThumbBlxR3VeneerRom(
            tmp.dir,
            io,
            path,
            case.caller_load,
            case.before_stub,
            case.stub,
            case.after_stub,
            0x0800_0009,
        );

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqual(
            case.expected,
            try resolveDevkitArmCrt0StartupThumbBlxR3Target(image, .thumb, 0x0800_0004, 0x0800_0008),
        );
    }
}

test "devkitARM crt0 startup blx r3 veneer rejects invalid literal targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        literal: u32,
    }{
        .{
            .literal = 0x0800_0008,
        },
        .{
            .literal = 0x0800_0021,
        },
    };

    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "startup-blx-r3-invalid-{d}.gba", .{index});
        defer std.testing.allocator.free(path);

        try writeStartupThumbBlxR3VeneerRom(
            tmp.dir,
            io,
            path,
            0x4B03,
            0x4770,
            0x4718,
            0x1AA3,
            case.literal,
        );

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectError(
            error.UnsupportedOpcode,
            resolveDevkitArmCrt0StartupThumbBlxR3Target(image, .thumb, 0x0800_0004, 0x0800_0008),
        );
    }
}

test "local thumb blx r3 veneer resolves the measured caller literal targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLocalThumbBlxR3VeneerRom(
        tmp.dir,
        io,
        "local-blx-r3-key.gba",
        0x4B03,
        0x4718,
        0x0000,
        0x0800_0011,
    );

    try writeSeparatedLocalThumbBlxR3VeneerRom(
        tmp.dir,
        io,
        "local-blx-r3-obj.gba",
        0x4B04,
        .{ 0x4903, 0x4803, 0x0092 },
        0x4718,
        0x46C0,
        0x0800_0015,
    );

    const cases = [_]struct {
        path: []const u8,
        bl_address: u32,
        veneer_address: u32,
        expected_target: armv4t_decode.CodeAddress,
    }{
        .{
            .path = "local-blx-r3-key.gba",
            .bl_address = 0x0800_0004,
            .veneer_address = 0x0800_0008,
            .expected_target = .{ .address = 0x0800_0010, .isa = .thumb },
        },
        .{
            .path = "local-blx-r3-obj.gba",
            .bl_address = 0x0800_000A,
            .veneer_address = 0x0800_000C,
            .expected_target = .{ .address = 0x0800_0014, .isa = .thumb },
        },
    };

    for (cases) |case| {
        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", case.path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = case.expected_target } },
            try resolveDecodedInstruction(
                image,
                .{ .address = 0x0800_0000, .isa = .thumb },
                case.bl_address,
                .{ .bl = .{ .target = .{ .address = case.veneer_address, .isa = .thumb } } },
            ),
        );
    }
}

test "local thumb blx r3 veneer rejects near misses" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const key_cases = [_]struct {
        caller_load: u16,
        stub: u16,
        after_stub: u16,
    }{
        .{
            .caller_load = 0x4A03,
            .stub = 0x4718,
            .after_stub = 0x46C0,
        },
        .{
            .caller_load = 0x4B03,
            .stub = 0x4710,
            .after_stub = 0x46C0,
        },
        .{
            .caller_load = 0x4B03,
            .stub = 0x4718,
            .after_stub = 0x1C00,
        },
        .{
            .caller_load = 0x6803,
            .stub = 0x4718,
            .after_stub = 0x46C0,
        },
    };

    for (key_cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "local-blx-r3-key-near-miss-{d}.gba", .{index});
        defer std.testing.allocator.free(path);

        try writeLocalThumbBlxR3VeneerRom(
            tmp.dir,
            io,
            path,
            case.caller_load,
            case.stub,
            case.after_stub,
            0x0800_0011,
        );

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_0008, .isa = .thumb } } },
            try resolveDecodedInstruction(
                image,
                .{ .address = 0x0800_0000, .isa = .thumb },
                0x0800_0004,
                .{ .bl = .{ .target = .{ .address = 0x0800_0008, .isa = .thumb } } },
            ),
        );
    }
}

test "local thumb blx r3 veneer matcher reports the measured tonc blockers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixtures = [_]struct {
        rom_path: []const u8,
        local_occurrence: ?[]const u8 = null,
        expect_cleared: bool,
        expect_failed: bool = true,
    }{
        .{
            .rom_path = "tests/fixtures/real/tonc/obj_demo.gba",
            .local_occurrence = "Unsupported control flow target 0x030000A4 for gba",
            .expect_cleared = true,
            .expect_failed = false,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .local_occurrence = "Unsupported control flow target 0x030000A4 for gba",
            .expect_cleared = true,
            .expect_failed = false,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/irq_demo.gba",
            .local_occurrence = "Unsupported opcode 0x00004718 at 0x08003078 for armv4t",
            .expect_cleared = false,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/sbb_reg.gba",
            .local_occurrence = "Unsupported opcode 0x00004718 at 0x08000808 for armv4t",
            .expect_cleared = true,
            .expect_failed = false,
        },
    };

    for (fixtures) |fixture| {
        const result = try buildFixtureCaptureOutput(std.testing.allocator, io, tmp.dir, fixture.rom_path);
        defer std.testing.allocator.free(result.stderr);

        try std.testing.expectEqual(fixture.expect_failed, result.failed);
        if (fixture.local_occurrence) |local_occurrence| {
            const found = std.mem.indexOf(u8, result.stderr, local_occurrence) != null;
            try std.testing.expectEqual(!fixture.expect_cleared, found);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unsupported opcode 0x00004718") == null);
        }
    }
}

test "tonc fixtures expose the measured devkitARM IWRAM code span" {
    const io = std.testing.io;
    const cases = [_]struct {
        rom_path: []const u8,
        guest_address: u32,
        isa: armv4t_decode.InstructionSet,
        expected_offset: usize,
    }{
        .{
            .rom_path = "tests/fixtures/real/tonc/obj_demo.gba",
            .guest_address = 0x0300_00A4,
            .isa = .arm,
            .expected_offset = 0x158C,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/sbb_reg.gba",
            .guest_address = 0x0300_00A4,
            .isa = .arm,
            .expected_offset = 0x0B20,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .guest_address = 0x0300_00A4,
            .isa = .arm,
            .expected_offset = 0x0A26C,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .guest_address = 0x0300_00DC,
            .isa = .arm,
            .expected_offset = 0x0A2A4,
        },
    };

    for (cases) |case| {
        const rom = try Io.Dir.cwd().readFileAlloc(
            io,
            case.rom_path,
            std.testing.allocator,
            .limited(16 * 1024 * 1024),
        );
        defer std.testing.allocator.free(rom);

        const image = gba_loader.RomImage{ .bytes = rom };
        try std.testing.expectEqual(@as(?usize, case.expected_offset), offsetForAddress(image, case.guest_address, case.isa));
    }
}

test "tonc measured devkitARM IWRAM code span rejects tampered startup metadata" {
    const io = std.testing.io;
    const rom_paths = [_][]const u8{
        "tests/fixtures/real/tonc/obj_demo.gba",
        "tests/fixtures/real/tonc/sbb_reg.gba",
        "tests/fixtures/real/tonc/key_demo.gba",
    };

    for (rom_paths) |rom_path| {
        var rom = try Io.Dir.cwd().readFileAlloc(
            io,
            rom_path,
            std.testing.allocator,
            .limited(16 * 1024 * 1024),
        );
        defer std.testing.allocator.free(rom);

        @memset(rom[0x154..0x158], 0x00);
        const image = gba_loader.RomImage{ .bytes = rom };
        try std.testing.expectEqual(@as(?usize, null), offsetForAddress(image, 0x0300_00A4, .arm));
    }
}

test "tonc sbb_reg exposes the measured devkitARM IWRAM data span" {
    const io = std.testing.io;
    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/tonc/sbb_reg.gba",
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);

    const image = gba_loader.RomImage{ .bytes = rom };
    try std.testing.expectEqual(@as(?u32, 0x0800_0249), measuredDevkitArmIwramDataWord(image, 0x0300_019C));
    try std.testing.expectEqual(@as(?u32, 0x0800_021D), measuredDevkitArmIwramDataWord(image, 0x0300_01A0));
}

test "real tonc local bx r3 stubs resolve to their measured exact targets" {
    const io = std.testing.io;
    const cases = [_]struct {
        rom_path: []const u8,
        bl_address: u32,
        stub_address: u32,
        expected_target: armv4t_decode.CodeAddress,
    }{
        .{
            .rom_path = "tests/fixtures/real/tonc/obj_demo.gba",
            .bl_address = 0x0800_037A,
            .stub_address = 0x0800_03B8,
            .expected_target = .{ .address = 0x0300_00A4, .isa = .arm },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/obj_demo.gba",
            .bl_address = 0x0800_0338,
            .stub_address = 0x0800_035C,
            .expected_target = .{ .address = 0x0300_00A4, .isa = .arm },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .bl_address = 0x0800_0294,
            .stub_address = 0x0800_0358,
            .expected_target = .{ .address = 0x0300_00A4, .isa = .arm },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .bl_address = 0x0800_041A,
            .stub_address = 0x0800_0750,
            .expected_target = .{ .address = 0x0300_00DC, .isa = .arm },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .bl_address = 0x0800_0838,
            .stub_address = 0x0800_0874,
            .expected_target = .{ .address = 0x0800_0248, .isa = .thumb },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .bl_address = 0x0800_0856,
            .stub_address = 0x0800_0874,
            .expected_target = .{ .address = 0x0800_0248, .isa = .thumb },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/sbb_reg.gba",
            .bl_address = 0x0800_04D2,
            .stub_address = 0x0800_0808,
            .expected_target = .{ .address = 0x0300_00A4, .isa = .arm },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/sbb_reg.gba",
            .bl_address = 0x0800_08AC,
            .stub_address = 0x0800_08E8,
            .expected_target = .{ .address = 0x0800_0248, .isa = .thumb },
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/sbb_reg.gba",
            .bl_address = 0x0800_08CA,
            .stub_address = 0x0800_08E8,
            .expected_target = .{ .address = 0x0800_0248, .isa = .thumb },
        },
    };

    for (cases) |case| {
        const rom = try Io.Dir.cwd().readFileAlloc(
            io,
            case.rom_path,
            std.testing.allocator,
            .limited(16 * 1024 * 1024),
        );
        defer std.testing.allocator.free(rom);

        const image = gba_loader.RomImage{ .bytes = rom };
        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = case.expected_target } },
            try resolveDecodedInstruction(
                image,
                .{ .address = 0x0800_0000, .isa = .thumb },
                case.bl_address,
                .{ .bl = .{ .target = .{
                    .address = case.stub_address,
                    .isa = .thumb,
                } } },
            ),
        );
    }
}

test "thumb saved-lr return epilogue resolves as a distinct return surface" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{ 0x10, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-bx-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-bx-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb saved-lr return epilogue resolves exact low-register multi-save shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{ 0x30, 0xB5, 0x30, 0xBC, 0x01, 0xBC, 0x00, 0x47 };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-bx-return-multi-save.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-bx-return-multi-save.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb saved-lr return epilogue resolves the exact sbb_reg prologue and tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [0x80C]u8 = undefined;
    @memset(&rom, 0);
    rom[0x04C0] = 0x00;
    rom[0x04C1] = 0x22;
    rom[0x04C2] = 0x0B;
    rom[0x04C3] = 0x4B;
    rom[0x04C4] = 0x10;
    rom[0x04C5] = 0xB5;
    rom[0x0804] = 0x10;
    rom[0x0805] = 0xBC;
    rom[0x0806] = 0x08;
    rom[0x0807] = 0xBC;
    rom[0x0808] = 0x18;
    rom[0x0809] = 0x47;

    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-sbb-reg-exact.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-sbb-reg-exact.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_04C0, .isa = .thumb }, 0x0800_0808, 3);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb saved-lr entry witness accepts the exact sbb_reg prologue" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x22,
        0x0B, 0x4B,
        0x10, 0xB5,
        0x00, 0x47,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-bx-return-multi-save-prefix.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-bx-return-multi-save-prefix.gba");
    defer image.deinit(std.testing.allocator);

    const mask = thumbEntrySavedRegsMask(image, .{ .address = 0x0800_0000, .isa = .thumb });
    try std.testing.expectEqual(@as(?u16, 0x0010), mask);
}

test "thumb saved-lr entry witness is anchored at function entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        rom_bytes: []const u8,
        function_entry: armv4t_decode.CodeAddress,
        expect_mask: ?u16,
    }{
        .{
            .rom_bytes = &.{ 0x10, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = 0x0010,
        },
        .{
            .rom_bytes = &.{ 0x30, 0xB5, 0x30, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = 0x0030,
        },
        .{
            .rom_bytes = &.{
                0x00, 0x22,
                0x0B, 0x4B,
                0x10, 0xB5,
                0x00, 0x47,
            },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = 0x0010,
        },
        .{
            .rom_bytes = &.{
                0x00, 0x22,
                0x0B, 0x4B,
                0x30, 0xB5,
                0x00, 0x47,
                0x00, 0x00,
                0x00, 0x00,
            },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = null,
        },
        .{
            .rom_bytes = &.{
                0x00, 0x22,
                0x10, 0xB5,
                0x00, 0x47,
                0x00, 0x00,
            },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = null,
        },
        .{
            .rom_bytes = &.{ 0x00, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = null,
        },
        .{
            .rom_bytes = &.{ 0x30, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .function_entry = .{ .address = 0x0800_0000, .isa = .thumb },
            .expect_mask = 0x0030,
        },
        .{
            .rom_bytes = &.{ 0x10, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .function_entry = .{ .address = 0x0800_0000, .isa = .arm },
            .expect_mask = null,
        },
    };

    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "thumb-saved-lr-entry-{d}.gba", .{index});
        defer std.testing.allocator.free(path);

        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = case.rom_bytes });
        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        const mask = thumbEntrySavedRegsMask(image, case.function_entry);
        if (case.expect_mask) |expected_mask| {
            try std.testing.expectEqual(@as(?u16, expected_mask), mask);
        } else {
            try std.testing.expectEqual(@as(?u16, null), mask);
        }
    }
}

test "thumb saved-lr return epilogue rejects local tail near-misses" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        rom_bytes: []const u8,
        bx_address: u32,
        bx_reg: u4,
        expect_error: bool,
    }{
        .{
            .rom_bytes = &.{ 0x10, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = false,
        },
        .{
            .rom_bytes = &.{ 0x00, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = true,
        },
        .{
            .rom_bytes = &.{ 0x10, 0xB5, 0x01, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = true,
        },
        .{
            .rom_bytes = &.{ 0x10, 0xB5, 0x03, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = true,
        },
        .{
            .rom_bytes = &.{ 0x10, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x08, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 1,
            .expect_error = true,
        },
        .{
            .rom_bytes = &.{ 0x30, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = true,
        },
        .{
            .rom_bytes = &.{ 0x30, 0xB5, 0x01, 0xBC, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = true,
        },
        .{
            .rom_bytes = &.{ 0x30, 0xB5, 0x30, 0xBC, 0x01, 0xBC, 0x40, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 8,
            .expect_error = true,
        },
    };

    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "thumb-saved-lr-tail-{d}.gba", .{index});
        defer std.testing.allocator.free(path);

        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = case.rom_bytes });
        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        const result = resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, case.bx_address, case.bx_reg);
        if (case.expect_error) {
            try std.testing.expectError(error.UnsupportedOpcode, result);
        } else {
            try std.testing.expectEqualDeep(
                armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} },
                try result,
            );
        }
    }
}

test "tonc fixture frontiers reflect the exact local thumb blx r3 veneer slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixtures = [_]struct {
        rom_path: []const u8,
        old_blocker: []const u8,
        cleared_blocker: ?[]const u8 = null,
        next_blocker: ?[]const u8,
        still_blocked_here: bool,
        expect_failed: bool = true,
    }{
        .{
            .rom_path = "tests/fixtures/real/tonc/sbb_reg.gba",
            .old_blocker = "Unsupported opcode 0x00004718 at 0x080008E8 for armv4t",
            .next_blocker = null,
            .still_blocked_here = false,
            .expect_failed = false,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/obj_demo.gba",
            .old_blocker = "Unsupported control flow target 0x030000A4 for gba",
            .next_blocker = null,
            .still_blocked_here = false,
            .expect_failed = false,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/key_demo.gba",
            .old_blocker = "Unsupported opcode 0x00004718 at 0x08000750 for armv4t",
            .next_blocker = null,
            .still_blocked_here = false,
            .expect_failed = false,
        },
        .{
            .rom_path = "tests/fixtures/real/tonc/irq_demo.gba",
            .old_blocker = "Unsupported opcode 0x00004708 at 0x080006C6 for armv4t",
            .next_blocker = "Unsupported opcode 0x00004718 at 0x08003078 for armv4t",
            .still_blocked_here = false,
        },
    };
    for (fixtures) |fixture| {
        const result = try buildFixtureCaptureOutput(std.testing.allocator, io, tmp.dir, fixture.rom_path);
        defer std.testing.allocator.free(result.stderr);

        try std.testing.expectEqual(fixture.expect_failed, result.failed);
        if (fixture.still_blocked_here) {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, fixture.old_blocker) != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, fixture.old_blocker) == null);
        }
        if (fixture.cleared_blocker) |cleared_blocker| {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, cleared_blocker) == null);
        }
        if (fixture.next_blocker) |next_blocker| {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, next_blocker) != null);
        }
    }
}

test "tonc sbb_reg and key_demo no longer stop at VBlankIntrWait swi" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_paths = [_][]const u8{
        "tests/fixtures/real/tonc/sbb_reg.gba",
        "tests/fixtures/real/tonc/key_demo.gba",
    };

    for (rom_paths) |rom_path| {
        const result = try buildFixtureCaptureOutput(std.testing.allocator, io, tmp.dir, rom_path);
        defer std.testing.allocator.free(result.stderr);

        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unsupported SWI 0x000005") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unsupported SWI 0x050000") == null);
    }
}

test "tonc obj_demo no longer falls through into the main tail bx r3 veneer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try buildFixtureCaptureOutput(std.testing.allocator, io, tmp.dir, "tests/fixtures/real/tonc/obj_demo.gba");
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unsupported opcode 0x00004718 at 0x080003B8 for armv4t") == null);
}

test "tonc obj_demo main tail call is measured as no-fallthrough" {
    const io = std.testing.io;
    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/tonc/obj_demo.gba",
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);

    const image = gba_loader.RomImage{ .bytes = rom };
    try std.testing.expect(isExactObjDemoMainTailNoReturnCall(
        image,
        .thumb,
        0x0800_039C,
        .{ .target = .{ .address = 0x0800_026C, .isa = .thumb } },
    ));
}

test "minimal vblank fixture turns the signal pixel green" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const native_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(
            std.testing.allocator,
            io,
            &tmp,
            interrupt_fixture_support.minimal_vblank.rom_path,
            "frame-irq-native",
            .frame_raw,
            interrupt_fixture_support.minimal_vblank.max_instructions,
        )
    else
        try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        interrupt_fixture_support.minimal_vblank.rom_path,
        "frame-irq-native",
        .frame_raw,
        interrupt_fixture_support.minimal_vblank.max_instructions,
    );
    defer std.testing.allocator.free(native_path);

    const frame_path = try std.testing.allocator.dupe(u8, "frame_irq.rgba");
    defer std.testing.allocator.free(frame_path);

    try runFrameFixture(io, tmp.dir, native_path, frame_path, .{
        .max_instructions = interrupt_fixture_support.minimal_vblank.max_instructions,
    });

    const frame = try frame_test_support.readExactFrame(
        std.testing.allocator,
        io,
        tmp.dir,
        frame_path,
    );
    defer std.testing.allocator.free(frame);

    try frame_test_support.expectPixel(
        frame,
        0,
        0,
        interrupt_fixture_support.minimal_vblank.signal_pixel,
    );
}

test "minimal vblank model rejects non-vblank IE bits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeNonVBlankIeRom(tmp.dir, io, "ie-bad.gba");

    const native_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, "ie-bad.gba", "ie-bad-native", .retired_count, 500_000)
    else
        try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "ie-bad.gba",
        "ie-bad-native",
        .retired_count,
        500_000,
    );
    defer std.testing.allocator.free(native_path);

    const result = try runNativeCapture(
        std.testing.allocator,
        io,
        tmp.dir,
        native_path,
        "retired_count",
        500_000,
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported interrupt source mask 0x0002 at 0x04000200 for gba") != null);
}

test "minimal vblank model rejects IME re-enable inside a handler" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeNestedImeRom(tmp.dir, io, "nested-ime.gba");

    const native_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, "nested-ime.gba", "nested-ime-native", .retired_count, 500_000)
    else
        try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "nested-ime.gba",
        "nested-ime-native",
        .retired_count,
        500_000,
    );
    defer std.testing.allocator.free(native_path);

    const result = try runNativeCapture(
        std.testing.allocator,
        io,
        tmp.dir,
        native_path,
        "retired_count",
        500_000,
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported nested IME enable at 0x04000208 for gba") != null);
}

test "minimal vblank model rejects byte writes to interrupt MMIO" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        rom_path: []const u8,
        native_path: []const u8,
        address: u32,
    }{
        .{ .rom_path = "ie-byte.gba", .native_path = "ie-byte-native", .address = 0x0400_0200 },
        .{ .rom_path = "ie-byte-hi.gba", .native_path = "ie-byte-hi-native", .address = 0x0400_0201 },
        .{ .rom_path = "if-byte.gba", .native_path = "if-byte-native", .address = 0x0400_0202 },
        .{ .rom_path = "if-byte-hi.gba", .native_path = "if-byte-hi-native", .address = 0x0400_0203 },
        .{ .rom_path = "ime-byte.gba", .native_path = "ime-byte-native", .address = 0x0400_0208 },
        .{ .rom_path = "ime-byte-hi.gba", .native_path = "ime-byte-hi-native", .address = 0x0400_0209 },
    };

    for (cases) |case| {
        try writeInterruptByteStoreRom(tmp.dir, io, case.rom_path, case.address);

        const native_path = if (standalone_build_cmd_test)
            try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, case.rom_path, case.native_path, .retired_count, 500_000)
        else
            try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            case.rom_path,
            case.native_path,
            .retired_count,
            500_000,
        );
        defer std.testing.allocator.free(native_path);

        const result = try runNativeCapture(
            std.testing.allocator,
            io,
            tmp.dir,
            native_path,
            "retired_count",
            500_000,
        );
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);

        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "Unsupported byte interrupt MMIO store at 0x{X:0>8} for gba",
            .{case.address},
        );
        defer std.testing.allocator.free(expected);

        try std.testing.expect(std.mem.indexOf(u8, result.stdout, expected) != null);
    }
}

test "tonc sbb_reg frame parity test" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(
            std.testing.allocator,
            io,
            &tmp,
            "tests/fixtures/real/tonc/sbb_reg.gba",
            "sbb_reg-native",
            .frame_raw,
            tonc_fixture_support.golden_fixtures[0].max_instructions,
        )
    else
        try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            "tests/fixtures/real/tonc/sbb_reg.gba",
            "sbb_reg-native",
            .frame_raw,
            tonc_fixture_support.golden_fixtures[0].max_instructions,
        );
    defer std.testing.allocator.free(output_path);

    try runFrameFixture(io, tmp.dir, output_path, "sbb_reg.rgba", .{
        .max_instructions = tonc_fixture_support.golden_fixtures[0].max_instructions,
    });

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "sbb_reg.rgba");
    defer std.testing.allocator.free(frame);

    try expectToncGoldenFrame(std.testing.allocator, io, "sbb_reg", frame, tonc_fixture_support.golden_fixtures[0]);
}

test "tonc obj_demo frame parity test" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(
            std.testing.allocator,
            io,
            &tmp,
            "tests/fixtures/real/tonc/obj_demo.gba",
            "obj_demo-native",
            .frame_raw,
            tonc_fixture_support.golden_fixtures[1].max_instructions,
        )
    else
        try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            "tests/fixtures/real/tonc/obj_demo.gba",
            "obj_demo-native",
            .frame_raw,
            tonc_fixture_support.golden_fixtures[1].max_instructions,
        );
    defer std.testing.allocator.free(output_path);

    try runFrameFixture(io, tmp.dir, output_path, "obj_demo.rgba", .{
        .max_instructions = tonc_fixture_support.golden_fixtures[1].max_instructions,
    });

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "obj_demo.rgba");
    defer std.testing.allocator.free(frame);

    try expectToncGoldenFrame(std.testing.allocator, io, "obj_demo", frame, tonc_fixture_support.golden_fixtures[1]);
}

test "tonc key_demo frame parity test" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(
            std.testing.allocator,
            io,
            &tmp,
            "tests/fixtures/real/tonc/key_demo.gba",
            "key_demo-native",
            .frame_raw,
            tonc_fixture_support.golden_fixtures[2].max_instructions,
        )
    else
        try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            "tests/fixtures/real/tonc/key_demo.gba",
            "key_demo-native",
            .frame_raw,
            tonc_fixture_support.golden_fixtures[2].max_instructions,
        );
    defer std.testing.allocator.free(output_path);

    try runFrameFixture(io, tmp.dir, output_path, "key_demo.rgba", .{
        .max_instructions = tonc_fixture_support.golden_fixtures[2].max_instructions,
        .keyinput_script = tonc_fixture_support.golden_fixtures[2].keyinput_script,
    });

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "key_demo.rgba");
    defer std.testing.allocator.free(frame);

    try expectToncGoldenFrame(std.testing.allocator, io, "key_demo", frame, tonc_fixture_support.golden_fixtures[2]);
}

test "build reports a structured diagnostic for an unsupported opcode" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{ 0xF0, 0x01, 0xF0, 0xE7 };
    try tmp.dir.writeFile(io, .{ .sub_path = "unsupported.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.UnsupportedOpcode,
        run(
            io,
            std.testing.allocator,
            tmp.dir,
            &output.writer,
            .{
                .rom_path = "unsupported.gba",
                .machine_name = "gba",
                .output_path = "should-not-exist",
            },
        ),
    );
    try std.testing.expectStringStartsWith(
        output.writer.buffered(),
        "Unsupported opcode 0xE7F001F0 at 0x08000000 for armv4t\n",
    );
}

test "lifted real jsmolka ppu fixtures still default to memory_summary" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        rom_path: []const u8,
    }{
        .{ .rom_path = "tests/fixtures/real/jsmolka/ppu-stripes.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/ppu-shades.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/ppu-hello.gba" },
    };

    for (cases) |case| {
        const rom = try readFixtureBytes(std.testing.allocator, io, tmp.dir, case.rom_path);
        defer std.testing.allocator.free(rom);

        const rom_name = std.fs.path.basename(case.rom_path);
        try tmp.dir.writeFile(io, .{ .sub_path = rom_name, .data = rom });

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", rom_name);
        defer image.deinit(std.testing.allocator);

        var output: Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();

        const program = try liftRom(std.testing.allocator, &output.writer, image);
        defer program.deinit(std.testing.allocator);

        try std.testing.expectEqual(llvm_codegen.OutputMode.memory_summary, program.output_mode);
    }
}

test "real jsmolka ppu fixtures exit deterministically under retired_count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const max_instructions: u64 = 5_000;
    const cases = [_]struct {
        rom_path: []const u8,
        native_path: []const u8,
        expected_stdout: []const u8,
    }{
        .{
            .rom_path = "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            .native_path = "ppu-stripes-retired-native",
            .expected_stdout = "retired=2099\n",
        },
        .{
            .rom_path = "tests/fixtures/real/jsmolka/ppu-shades.gba",
            .native_path = "ppu-shades-retired-native",
            .expected_stdout = "retired=5000\n",
        },
        .{
            .rom_path = "tests/fixtures/real/jsmolka/ppu-hello.gba",
            .native_path = "ppu-hello-retired-native",
            .expected_stdout = "retired=4580\n",
        },
    };

    for (cases) |case| {
        const native_path = try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            case.rom_path,
            case.native_path,
            .retired_count,
            max_instructions,
        );
        defer std.testing.allocator.free(native_path);

        const result = try runNativeCapture(
            std.testing.allocator,
            io,
            tmp.dir,
            native_path,
            "retired_count",
            max_instructions,
        );
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);

        try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings(case.expected_stdout, result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "lifted real arm rom reaches the report block" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/arm.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "arm.gba", .data = rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "arm.gba");
    defer image.deinit(std.testing.allocator);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = try liftRom(std.testing.allocator, &output.writer, image);
    defer program.deinit(std.testing.allocator);

    try std.testing.expect(hasInstructionAddress(program.functions, 0x0800_1D4C));
    try std.testing.expectEqual(llvm_codegen.OutputMode.arm_report, program.output_mode);
}

test "lifted real thumb rom reaches the report block" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/thumb.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb.gba", .data = rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb.gba");
    defer image.deinit(std.testing.allocator);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = try liftRom(std.testing.allocator, &output.writer, image);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(llvm_codegen.OutputMode.arm_report, program.output_mode);
}

test "build reports a structured diagnostic for unsupported subs pc immediate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{ 0x04, 0xF0, 0x5F, 0xE2 };
    try tmp.dir.writeFile(io, .{ .sub_path = "subs-pc.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.UnsupportedOpcode,
        run(
            io,
            std.testing.allocator,
            tmp.dir,
            &output.writer,
            .{
                .rom_path = "subs-pc.gba",
                .machine_name = "gba",
                .output_path = "should-not-exist",
            },
        ),
    );
    try std.testing.expectStringStartsWith(
        output.writer.buffered(),
        "Unsupported opcode 0xE25FF004 at 0x08000000 for armv4t\n",
    );
}

test "lifted real jsmolka verdict fixtures still default to arm_report" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        rom_path: []const u8,
    }{
        .{ .rom_path = "tests/fixtures/real/jsmolka/arm.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/thumb.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/memory.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/bios.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-none.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-sram.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-flash64.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-flash128.gba" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/unsafe.gba" },
    };

    for (cases) |case| {
        const rom = try readFixtureBytes(std.testing.allocator, io, tmp.dir, case.rom_path);
        defer std.testing.allocator.free(rom);

        const rom_name = std.fs.path.basename(case.rom_path);
        try tmp.dir.writeFile(io, .{ .sub_path = rom_name, .data = rom });

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", rom_name);
        defer image.deinit(std.testing.allocator);

        var output: Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();

        const program = try liftRom(std.testing.allocator, &output.writer, image);
        defer program.deinit(std.testing.allocator);

        try std.testing.expectEqual(llvm_codegen.OutputMode.arm_report, program.output_mode);
    }
}

test "real jsmolka verdict fixtures exit deterministically under retired_count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const max_instructions: u64 = 5_000;
    const cases = [_]struct {
        rom_path: []const u8,
        native_path: []const u8,
    }{
        .{ .rom_path = "tests/fixtures/real/jsmolka/arm.gba", .native_path = "arm-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/thumb.gba", .native_path = "thumb-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/memory.gba", .native_path = "memory-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/bios.gba", .native_path = "bios-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-none.gba", .native_path = "save-none-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-sram.gba", .native_path = "save-sram-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-flash64.gba", .native_path = "save-flash64-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/save-flash128.gba", .native_path = "save-flash128-retired-native" },
        .{ .rom_path = "tests/fixtures/real/jsmolka/unsafe.gba", .native_path = "unsafe-retired-native" },
    };

    for (cases) |case| {
        const native_path = try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            case.rom_path,
            case.native_path,
            .retired_count,
            max_instructions,
        );
        defer std.testing.allocator.free(native_path);

        const result = try runNativeCapture(
            std.testing.allocator,
            io,
            tmp.dir,
            native_path,
            "retired_count",
            max_instructions,
        );
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);

        try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("retired=5000\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "build emits frame_raw llvm hooks when requested" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/ppu-hello.gba",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "ppu-hello.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "ppu-hello.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .frame_raw,
            .max_instructions = 1_000_000,
            .output_path = "ppu-hello-native",
        },
    );

    const llvm_bytes = try tmp.dir.readFileAlloc(
        io,
        "ppu-hello-native.ll",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(llvm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@hmgba_dump_frame_raw") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@hm_runtime_max_instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "call i32 @hmgba_dump_frame_raw") != null);
}

test "build keeps frame_raw runtime helper artifacts under .zig-cache" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3,
        0x02, 0x10, 0xA0, 0xE3,
        0x06, 0x00, 0x00, 0xEF,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "div.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "div.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .frame_raw,
            .max_instructions = 5_000,
            .output_path = "div-frame-native",
        },
    );

    _ = try tmp.dir.statFile(io, ".zig-cache/hm_gba_ppu_runtime.o", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "hm_gba_ppu_runtime.o", .{}));
    _ = try tmp.dir.statFile(io, ".zig-cache/hm_gba_ppu_runtime.zig", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "hm_gba_ppu_runtime.zig", .{}));
}

test "build executes the real jsmolka hello rom and dumps the expected mode4 frame" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/ppu-hello.gba",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "ppu-hello.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "ppu-hello.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .frame_raw,
            .max_instructions = 5_000,
            .output_path = "ppu-hello-frame-native",
        },
    );

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOMONCULI_OUTPUT_MODE", "frame_raw");
    try environ_map.put("HOMONCULI_OUTPUT_PATH", "ppu-hello.rgba");
    try environ_map.put("HOMONCULI_MAX_INSTRUCTIONS", "5000");

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./ppu-hello-frame-native"},
        .cwd = .{ .dir = tmp.dir },
        .environ_map = &environ_map,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "ppu-hello.rgba");
    defer std.testing.allocator.free(frame);

    try frame_test_support.expectPixel(frame, 0, 0, .{ 0, 0, 0, 255 });
    try frame_test_support.expectPixel(frame, 73, 76, .{ 255, 255, 255, 255 });
    try frame_test_support.expectPixel(frame, 75, 76, .{ 0, 0, 0, 255 });
    try frame_test_support.expectPixel(frame, 82, 78, .{ 255, 255, 255, 255 });
    try frame_test_support.expectPixel(frame, 80, 78, .{ 0, 0, 0, 255 });
    try frame_test_support.expectPixel(frame, 120, 79, .{ 255, 255, 255, 255 });
}

test "build optimization levels map to toolchain flags" {
    try std.testing.expectEqualStrings("-O0", clangOptimizeFlag(.debug));
    try std.testing.expectEqualStrings("-O3", clangOptimizeFlag(.release));
    try std.testing.expectEqualStrings("-Oz", clangOptimizeFlag(.small));

    try std.testing.expectEqualStrings("Debug", zigOptimizeModeArg(.debug));
    try std.testing.expectEqualStrings("ReleaseFast", zigOptimizeModeArg(.release));
    try std.testing.expectEqualStrings("ReleaseSmall", zigOptimizeModeArg(.small));
}

test "build executes the synthetic tight-loop benchmark rom and reports retired instruction count" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/bench/arm-tight-loop.gba",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "arm-tight-loop.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "arm-tight-loop.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .retired_count,
            .max_instructions = 7,
            .output_path = "arm-tight-loop-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./arm-tight-loop-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("retired=7\n", result.stdout);
}

test "build retired counts accumulate across lifted function calls" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3, // mov r0, #10
        0x01, 0x00, 0x00, 0xEB, // bl  0x08000010
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x00, 0x00, 0x00, 0x00, // padding
        0x07, 0x00, 0x80, 0xE2, // add r0, r0, #7
        0x1E, 0xFF, 0x2F, 0xE1, // bx  lr
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "call-count.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "call-count.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .retired_count,
            .max_instructions = 5,
            .output_path = "call-count-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./call-count-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("retired=5\n", result.stdout);
}

test "build retired counts do not overcount when a block stops mid-execution" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x00, 0x00, 0xA0, 0xE3, // mov r0, #0
        0x01, 0x00, 0x80, 0xE2, // add r0, r0, #1
        0x01, 0x00, 0x80, 0xE2, // add r0, r0, #1
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "mid-block-stop.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "mid-block-stop.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .retired_count,
            .max_instructions = 2,
            .output_path = "mid-block-stop-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./mid-block-stop-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("retired=2\n", result.stdout);
}
