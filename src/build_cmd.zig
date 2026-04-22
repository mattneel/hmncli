const std = @import("std");
const Io = std.Io;
const armv4t_decode = @import("armv4t_decode.zig");
const catalog = @import("catalog.zig");
const frame_test_support = @import("frame_test_support.zig");
const gba_loader = @import("gba_loader.zig");
const llvm_codegen = @import("llvm_codegen.zig");
const parse = @import("cli/parse.zig");
const gba_ppu_source = @embedFile("gba_ppu.zig");

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
    const runtime_helper_obj = if (options.output_mode == .frame_raw or options.output_mode == .retired_count)
        try compileRuntimeHelper(io, allocator, cwd, writer, options)
    else
        null;
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
        const decoded = resolveDecodedInstruction(image, function_entry.isa, address, decoded_initial) catch {
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
            if (address < image.base_address + 4) return error.UnsupportedOpcode;
            return decodeImageInstructionUnchecked(image, isa, address - 4);
        },
        .thumb => {
            for ([_]u8{ 4, 2 }) |candidate_size| {
                if (address < image.base_address + candidate_size) continue;
                const candidate_address = address - candidate_size;
                const decoded = decodeImageInstructionUnchecked(image, isa, candidate_address) catch continue;
                if (candidate_address + decoded.size_bytes == address) return decoded;
            }
            return error.UnsupportedOpcode;
        },
    }
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

            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
            if (branch.target == address) {
                has_self_loop.* = true;
                return;
            }
            try enqueueBlockAddress(allocator, writer, pending_blocks, image, isa, branch.target);
        },
        .bl => |bl| {
            try enqueueFunctionAddress(allocator, writer, pending_functions, image, .{
                .address = bl.target,
                .isa = isa,
            });
            try enqueueFallthrough(allocator, pending_blocks, image, isa, address, size_bytes);
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

fn offsetForAddress(
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
    isa: armv4t_decode.InstructionSet,
    address: u32,
    decoded: armv4t_decode.DecodedInstruction,
) BuildError!armv4t_decode.DecodedInstruction {
    const resolved = switch (decoded) {
        .subs_imm => |sub| if (sub.rd == 15 and sub.rn == 15)
            blk: {
                const target = normalizePcWriteTarget(pcValueForInstruction(isa, address) - sub.imm, isa);
                if (offsetForAddress(image, target, isa) == null) return error.UnsupportedOpcode;
                break :blk armv4t_decode.DecodedInstruction{ .exception_return = .{
                    .target = target,
                } };
            }
        else
            decoded,
        .add_reg => |add| if (add.rd == 15)
            try resolveAddRegPcTarget(image, isa, address, add)
        else
            decoded,
        .bx_reg => |bx| try resolveBxTarget(image, isa, address, bx.reg),
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
        else => decoded,
    };

    if (writesUnsupportedPcDestination(resolved)) return error.UnsupportedOpcode;
    return resolved;
}

fn resolveBxTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!armv4t_decode.DecodedInstruction {
    return .{ .bx_target = normalizeCodeTarget(try resolvePreviousRegisterValue(image, isa, address, reg)) };
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

fn isSqrtSwi(imm24: u24) bool {
    return imm24 == 0x000008 or imm24 == 0x080000;
}

fn swiShimName(imm24: u24) ?[]const u8 {
    if (imm24 == 0x000000) return "SoftReset";
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

fn buildFixtureExpectFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom_path: []const u8,
) ![]u8 {
    var output: Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    run(io, allocator, dir, &output.writer, .{
        .rom_path = rom_path,
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_mode = .frame_raw,
        .max_instructions = 50_000,
        .output_path = ".zig-cache/tonc/should-not-exist",
        .optimize = .release,
    }) catch {
        return output.toOwnedSlice();
    };
    return error.ExpectedBuildFailure;
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

test "tonc sbb_reg no longer stops at startup soft reset swi" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stderr = try buildFixtureExpectFailure(
        std.testing.allocator,
        io,
        tmp.dir,
        "tests/fixtures/real/tonc/sbb_reg.gba",
    );
    defer std.testing.allocator.free(stderr);

    try std.testing.expect(std.mem.indexOf(u8, stderr, "Unsupported SWI 0x000000") == null);
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

test "build executes the real jsmolka stripes rom and produces the expected memory summary" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/ppu-stripes.gba",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "ppu-stripes.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "ppu-stripes.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "ppu-stripes-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./ppu-stripes-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(2048),
        .stderr_limit = .limited(2048),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings(
        "IO0=00000100 IO8=00000104 PAL0=0000560B PAL2=00006290 VRAM4000=11111111 MAP0800=00000001 MAP0804=00000001\n",
        result.stdout,
    );
}

test "build executes the real jsmolka shades rom and produces the expected memory summary" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/ppu-shades.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "ppu-shades.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "ppu-shades.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "ppu-shades-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./ppu-shades-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(2048),
        .stderr_limit = .limited(2048),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings(
        "IO0=00000100 IO8=00000104 PAL0=00000000 PAL2=00000800 VRAM4000=00000000 MAP0800=00000000 MAP0804=00000001\n",
        result.stdout,
    );
}

test "build executes the real jsmolka hello rom and produces the expected memory summary" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/ppu-hello.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
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
            .output_path = "ppu-hello-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./ppu-hello-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(2048),
        .stderr_limit = .limited(2048),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings(
        "IO0=00000404 IO8=00000000 PAL0=00000000 PAL2=0000FFFF VRAM4000=00000000 MAP0800=00000000 MAP0804=00000000\n",
        result.stdout,
    );
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

test "build uses the real jsmolka arm rom and reports the rom verdict" {
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

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "arm.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "arm-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./arm-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka thumb rom and reports the rom verdict" {
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

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "thumb.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "thumb-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./thumb-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka memory rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/memory.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "memory.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "memory.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "memory-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./memory-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka bios rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/bios.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "bios.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "bios.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "bios-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./bios-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka save-none rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/save-none.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "save-none.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "save-none.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "save-none-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./save-none-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka save-sram rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/save-sram.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "save-sram.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "save-sram.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "save-sram-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./save-sram-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka save-flash64 rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/save-flash64.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "save-flash64.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "save-flash64.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "save-flash64-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./save-flash64-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka save-flash128 rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/save-flash128.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "save-flash128.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "save-flash128.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "save-flash128-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./save-flash128-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
}

test "build uses the real jsmolka unsafe rom and reports the rom verdict" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/unsafe.gba",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "unsafe.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "unsafe.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "unsafe-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./unsafe-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("PASS\n", result.stdout);
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
