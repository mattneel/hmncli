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

    while (true) {
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

        const linked_table_added = try enqueueLinkedThumbPointerTableTargets(
            allocator,
            &pending_functions,
            image,
            functions.items,
        );
        const kirby_overlay_added = try enqueueMeasuredKirbyOverlayRuntimeTargets(
            allocator,
            &pending_functions,
            image,
            functions.items,
        );
        const kirby_irq_added = try enqueueMeasuredKirbyIrqHandlerRuntimeTarget(
            allocator,
            &pending_functions,
            image,
            functions.items,
        );
        const kirby_callback_added = try enqueueMeasuredKirbyInterworkingCallbackTarget(
            allocator,
            &pending_functions,
            image,
            functions.items,
        );
        const kirby_resume_added = try enqueueMeasuredKirbyCoroutineResumeTargets(
            allocator,
            &pending_functions,
            image,
            functions.items,
        );
        if (!linked_table_added and !kirby_overlay_added and !kirby_irq_added and !kirby_callback_added and !kirby_resume_added) break;
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
        .window => .window,
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
        .instruction_limit = if (requested_output_mode == .frame_raw or requested_output_mode == .retired_count or requested_output_mode == .window)
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
        .and_shift_reg => _ = try catalog.lookupInstruction("armv4t", "and_reg_shift"),
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
        .sub_reg => _ = try catalog.lookupInstruction("armv4t", "sub_reg"),
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
        .ldr_signed_byte_post_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_byte_post_imm"),
        .ldr_signed_byte_pre_index_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_byte_pre_imm"),
        .ldr_signed_byte_pre_index_reg => _ = try catalog.lookupInstruction("armv4t", "ldr_signed_byte_pre_reg"),
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
        .bx_reg => _ = try catalog.lookupInstruction("armv4t", "bx_reg"),
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
        .bx_reg => |bx| {
            _ = try enqueueMeasuredThumbMovPcJumpTableTargets(allocator, writer, pending_functions, image, isa, address, bx.reg);
            return;
        },
        .bx_lr => return,
        .thumb_saved_lr_return => return,
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
        .swi => |swi| {
            if (swiEndsFunction(swi.imm24)) return;
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
    if (!isMeasuredLocalThumbBlxVeneerNop(image, address + 0x1E)) return false;

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

fn enqueueLinkedThumbPointerTableTargets(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    functions: []const llvm_codegen.Function,
) std.mem.Allocator.Error!bool {
    var added = false;
    var offset: usize = 0;
    while (offset + 4 <= image.bytes.len) {
        const run_start = offset;
        var run_len: usize = 0;
        var linked_to_lifted_function = false;
        while (offset + 4 <= image.bytes.len) {
            const raw_target = armv4t_decode.readWord(image.bytes, offset);
            const target = normalizeCodeTarget(raw_target);
            if ((raw_target & 1) == 0 or target.isa != .thumb or offsetForAddress(image, target.address, target.isa) == null) break;
            if (containsFunction(functions, target)) linked_to_lifted_function = true;
            run_len += 1;
            offset += 4;
        }

        if (run_len >= 4 and linked_to_lifted_function) {
            for (0..run_len) |index| {
                const raw_target = armv4t_decode.readWord(image.bytes, run_start + index * 4);
                const target = normalizeCodeTarget(raw_target);
                if (containsFunction(functions, target)) continue;
                if (containsCodeAddress(pending.items, target)) continue;
                try pending.append(allocator, target);
                added = true;
            }
        }

        offset = if (run_len == 0) run_start + 4 else offset;
    }
    return added;
}

fn enqueueMeasuredKirbyOverlayRuntimeTargets(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    functions: []const llvm_codegen.Function,
) std.mem.Allocator.Error!bool {
    const span = measuredKirbyIwramOverlayCodeSpan(image) orelse return false;
    const targets = [_]armv4t_decode.CodeAddress{
        .{ .address = 0x0300_7DF4, .isa = .thumb },
    };

    var added = false;
    for (targets) |target| {
        if (!span.contains(target.address)) continue;
        if (offsetForAddress(image, target.address, target.isa) == null) continue;
        if (containsFunction(functions, target)) continue;
        if (containsCodeAddress(pending.items, target)) continue;
        try pending.append(allocator, target);
        added = true;
    }
    return added;
}

fn enqueueMeasuredKirbyIrqHandlerRuntimeTarget(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    functions: []const llvm_codegen.Function,
) std.mem.Allocator.Error!bool {
    const span = measuredKirbyIrqHandlerCodeSpan(image) orelse return false;
    const target = armv4t_decode.CodeAddress{ .address = 0x0300_1030, .isa = .arm };
    if (!span.contains(target.address)) return false;
    if (offsetForAddress(image, target.address, target.isa) == null) return false;
    if (containsFunction(functions, target)) return false;
    if (containsCodeAddress(pending.items, target)) return false;
    try pending.append(allocator, target);
    return true;
}

fn enqueueMeasuredKirbyInterworkingCallbackTarget(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    functions: []const llvm_codegen.Function,
) std.mem.Allocator.Error!bool {
    const targets = [_]?armv4t_decode.CodeAddress{
        measuredKirbyInterworkingCallbackTarget(image),
        measuredKirbyMotionUpdateCallbackTarget(image),
        measuredKirbyCollisionCallbackTarget(image),
        measuredKirbyTitleSetupCallbackTarget(image),
    };

    var added = false;
    for (targets) |maybe_target| {
        const target = maybe_target orelse continue;
        if (containsFunction(functions, target)) continue;
        if (containsCodeAddress(pending.items, target)) continue;
        try pending.append(allocator, target);
        added = true;
    }
    return added;
}

fn measuredKirbyInterworkingCallbackTarget(image: gba_loader.RomImage) ?armv4t_decode.CodeAddress {
    const source_offset = romOffsetForAddress(image, image.base_address + 0x72FF34, .arm) orelse return null;
    if (source_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, source_offset);
    if (raw_target != image.base_address + 0x93FD) return null;

    const target = normalizeCodeTarget(raw_target);
    if (target.isa != .thumb) return null;
    if (offsetForAddress(image, target.address, target.isa) == null) return null;
    return target;
}

fn measuredKirbyMotionUpdateCallbackTarget(image: gba_loader.RomImage) ?armv4t_decode.CodeAddress {
    if (mappedThumbHalfword(image, image.base_address + 0x9640) != 0xB510) return null;

    const source_offset = romOffsetForAddress(image, image.base_address + 0x9678, .thumb) orelse return null;
    if (source_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, source_offset);
    if (raw_target != image.base_address + 0x59D9) return null;

    const target = normalizeCodeTarget(raw_target);
    if (target.isa != .thumb) return null;
    if (mappedThumbHalfword(image, target.address) != 0xB500) return null;
    return target;
}

fn measuredKirbyCollisionCallbackTarget(image: gba_loader.RomImage) ?armv4t_decode.CodeAddress {
    if (mappedThumbHalfword(image, image.base_address + 0x9640) != 0xB510) return null;

    const source_offset = romOffsetForAddress(image, image.base_address + 0x967C, .thumb) orelse return null;
    if (source_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, source_offset);
    if (raw_target != image.base_address + 0x5CA1) return null;

    const target = normalizeCodeTarget(raw_target);
    if (target.isa != .thumb) return null;
    if (mappedThumbHalfword(image, target.address) != 0xB570) return null;
    return target;
}

fn measuredKirbyTitleSetupCallbackTarget(image: gba_loader.RomImage) ?armv4t_decode.CodeAddress {
    const selector_offset = romOffsetForAddress(image, image.base_address + 0x730698, .arm) orelse return null;
    const source_offset = romOffsetForAddress(image, image.base_address + 0x73069C, .arm) orelse return null;
    if (selector_offset + 4 > image.bytes.len or source_offset + 4 > image.bytes.len) return null;

    const selector = armv4t_decode.readWord(image.bytes, selector_offset);
    if (selector != 0x0000_0004) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, source_offset);
    if (raw_target != image.base_address + 0x99FD) return null;

    const target = normalizeCodeTarget(raw_target);
    if (target.isa != .thumb) return null;
    if (mappedThumbHalfword(image, target.address) != 0xB570) return null;
    return target;
}

fn enqueueMeasuredKirbyCoroutineResumeTargets(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    functions: []const llvm_codegen.Function,
) std.mem.Allocator.Error!bool {
    const targets = [_]armv4t_decode.CodeAddress{
        .{ .address = 0x0800_5368, .isa = .thumb },
        .{ .address = 0x0800_9412, .isa = .thumb },
        .{ .address = 0x0800_9418, .isa = .thumb },
        .{ .address = 0x0800_944E, .isa = .thumb },
        .{ .address = 0x0800_94CC, .isa = .thumb },
        .{ .address = 0x0800_9536, .isa = .thumb },
        .{ .address = 0x0800_958A, .isa = .thumb },
        .{ .address = 0x0800_95F0, .isa = .thumb },
        .{ .address = 0x0800_961C, .isa = .thumb },
        .{ .address = 0x0800_96A6, .isa = .thumb },
        .{ .address = 0x0800_96B4, .isa = .thumb },
        .{ .address = 0x0800_96C2, .isa = .thumb },
        .{ .address = 0x0800_96EC, .isa = .thumb },
        .{ .address = 0x0800_9862, .isa = .thumb },
        .{ .address = 0x0800_9874, .isa = .thumb },
        .{ .address = 0x0800_9896, .isa = .thumb },
        .{ .address = 0x0800_9932, .isa = .thumb },
        .{ .address = 0x0800_99EC, .isa = .thumb },
        .{ .address = 0x0800_22EA, .isa = .thumb },
        .{ .address = 0x0800_2D68, .isa = .thumb },
        .{ .address = 0x0800_2DC4, .isa = .thumb },
        .{ .address = 0x0800_929C, .isa = .thumb },
        .{ .address = 0x0800_92A8, .isa = .thumb },
        .{ .address = 0x0800_92B8, .isa = .thumb },
        .{ .address = 0x0800_92D6, .isa = .thumb },
        .{ .address = 0x0800_9344, .isa = .thumb },
        .{ .address = 0x0800_93BC, .isa = .thumb },
        .{ .address = 0x0800_91B2, .isa = .thumb },
        .{ .address = 0x0800_73A0, .isa = .thumb },
        .{ .address = 0x0800_95C0, .isa = .thumb },
    };

    var added = false;
    for (targets) |target| {
        if (!isMeasuredKirbyCoroutineResumeTarget(image, target)) continue;
        if (containsFunction(functions, target)) continue;
        if (containsCodeAddress(pending.items, target)) continue;
        try pending.append(allocator, target);
        added = true;
    }
    return added;
}

fn isMeasuredKirbyCoroutineResumeTarget(
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) bool {
    if (target.isa != .thumb) return false;
    if (offsetForAddress(image, target.address, target.isa) == null) return false;

    if (target.address == image.base_address + 0x22EA or
        target.address == image.base_address + 0x2D68 or
        target.address == image.base_address + 0x2DC4 or
        target.address == image.base_address + 0x929C or
        target.address == image.base_address + 0x92A8 or
        target.address == image.base_address + 0x92B8 or
        target.address == image.base_address + 0x92D6 or
        target.address == image.base_address + 0x9344 or
        target.address == image.base_address + 0x93BC or
        target.address == image.base_address + 0x91B2 or
        target.address == image.base_address + 0x96EC or
        target.address == image.base_address + 0x9862 or
        target.address == image.base_address + 0x9874 or
        target.address == image.base_address + 0x9896 or
        target.address == image.base_address + 0x9932 or
        target.address == image.base_address + 0x99EC)
    {
        return isMeasuredKirbyCoroutineCallerContinuationTarget(image, target);
    }
    if (target.address == image.base_address + 0x73A0) {
        return isMeasuredKirbyCoroutineDispatchContinuationTarget(image, target);
    }
    if (target.address == image.base_address + 0x95C0) {
        return isMeasuredKirbyCoroutineSwitchEntryTarget(image, target);
    }
    if (target.address == image.base_address + 0x9418) {
        return isMeasuredKirbyCoroutineLongLoopEntryTarget(image, target);
    }
    if (target.address == image.base_address + 0x944E or
        target.address == image.base_address + 0x94CC or
        target.address == image.base_address + 0x9536 or
        target.address == image.base_address + 0x958A or
        target.address == image.base_address + 0x95F0 or
        target.address == image.base_address + 0x961C or
        target.address == image.base_address + 0x96A6 or
        target.address == image.base_address + 0x96B4 or
        target.address == image.base_address + 0x96C2)
    {
        return isMeasuredKirbyCoroutineYieldContinuationTarget(image, target);
    }

    const trampoline = if (target.address == image.base_address + 0x5368)
        image.base_address + 0x0CFDC4
    else if (target.address == image.base_address + 0x9412)
        image.base_address + 0x0CFDCC
    else
        return false;
    const arm_switch_target = if (target.address == image.base_address + 0x5368)
        image.base_address + 0x0234
    else
        image.base_address + 0x0258;

    const yield_call = previousInstruction(image, .thumb, target.address) catch return false;
    const bl = switch (yield_call.instruction) {
        .bl => |bl| bl,
        else => return false,
    };
    if (bl.target.isa != .thumb or bl.target.address != trampoline) return false;

    const bx_pc = decodeImageInstructionUnchecked(image, .thumb, trampoline) catch return false;
    const bx = switch (bx_pc.instruction) {
        .bx_reg => |bx| bx,
        else => return false,
    };
    if (bx.reg != 15) return false;

    if (!isMeasuredLocalThumbBlxVeneerNop(image, trampoline + 2)) return false;

    const branch_to_switch = decodeImageInstructionUnchecked(image, .arm, trampoline + 4) catch return false;
    const branch = switch (branch_to_switch.instruction) {
        .branch => |branch| branch,
        else => return false,
    };
    return branch.cond == .al and branch.target == arm_switch_target;
}

fn isMeasuredKirbyCoroutineDispatchContinuationTarget(
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) bool {
    if (target.isa != .thumb) return false;
    if (target.address != image.base_address + 0x73A0) return false;

    const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
    const bl = switch (coroutine_call.instruction) {
        .bl => |bl| bl,
        else => return false,
    };
    return bl.target.isa == .thumb and bl.target.address == image.base_address + 0x91AC;
}

fn isMeasuredKirbyCoroutineSwitchEntryTarget(
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) bool {
    if (target.isa != .thumb) return false;
    if (target.address != image.base_address + 0x95C0) return false;

    const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x95C0) catch return false;
    const push_mask = switch (function_entry.instruction) {
        .push => |mask| mask,
        else => return false,
    };
    if (push_mask != 0x4000) return false;

    const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x95E0) catch return false;
    const pop_return_mask = switch (pop_return.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_return_mask != 0x0001) return false;

    const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x95E2) catch return false;
    const bx = switch (bx_return.instruction) {
        .bx_reg => |bx| bx,
        else => return false,
    };
    return bx.reg == 0;
}

fn isMeasuredKirbyCoroutineLongLoopEntryTarget(
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) bool {
    if (target.isa != .thumb) return false;
    if (target.address != image.base_address + 0x9418) return false;

    return mappedThumbHalfword(image, image.base_address + 0x9418) == 0xB5F0 and
        mappedThumbHalfword(image, image.base_address + 0x941A) == 0x4647 and
        mappedThumbHalfword(image, image.base_address + 0x941C) == 0xB480 and
        mappedThumbHalfword(image, image.base_address + 0x959C) == 0xE7D7;
}

fn isMeasuredKirbyCoroutineYieldContinuationTarget(
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) bool {
    if (target.isa != .thumb) return false;
    if (target.address != image.base_address + 0x944E and
        target.address != image.base_address + 0x94CC and
        target.address != image.base_address + 0x9536 and
        target.address != image.base_address + 0x958A and
        target.address != image.base_address + 0x95F0 and
        target.address != image.base_address + 0x961C and
        target.address != image.base_address + 0x96A6 and
        target.address != image.base_address + 0x96B4 and
        target.address != image.base_address + 0x96C2)
    {
        return false;
    }

    const yield_call = previousInstruction(image, .thumb, target.address) catch return false;
    const bl = switch (yield_call.instruction) {
        .bl => |bl| bl,
        else => return false,
    };
    if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x0CFDCC) return false;

    return mappedThumbHalfword(image, image.base_address + 0x0CFDCC) == 0x4778 and
        mappedThumbHalfword(image, image.base_address + 0x0CFDCE) == 0x46C0 and
        mappedThumbWord(image, image.base_address + 0x0CFDD0) == 0xEAFC_C120;
}

fn isMeasuredKirbyCoroutineCallerContinuationTarget(
    image: gba_loader.RomImage,
    target: armv4t_decode.CodeAddress,
) bool {
    if (target.isa != .thumb) return false;
    if (target.address == image.base_address + 0x22EA) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x22E4) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4000) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x5228) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x22F6) catch return false;
        const pop_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_mask != 0x0001) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x22F8) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 0;
    }

    if (target.address == image.base_address + 0x2D68) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2D54) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4030) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x22E4) return false;

        const pop_saved = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2D6E) catch return false;
        const pop_saved_mask = switch (pop_saved.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_mask != 0x0030) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2D70) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0001) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2D72) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 0;
    }

    if (target.address == image.base_address + 0x2DC4) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2DB4) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4010) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x22E4) return false;

        const pop_saved = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2DD0) catch return false;
        const pop_saved_mask = switch (pop_saved.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_mask != 0x0010) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2DD2) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0001) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x2DD4) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 0;
    }

    if (target.address == image.base_address + 0x91B2) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x91AC) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4030) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x9200) return false;

        const pop_saved = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x91F6) catch return false;
        const pop_saved_mask = switch (pop_saved.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_mask != 0x0030) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x91F8) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0001) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x91FA) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 0;
    }

    if (target.address == image.base_address + 0x929C or
        target.address == image.base_address + 0x92A8 or
        target.address == image.base_address + 0x92B8 or
        target.address == image.base_address + 0x92D6 or
        target.address == image.base_address + 0x9344)
    {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9200) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4070) return false;

        const save_r10 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9202) catch return false;
        const save_r10_mov = switch (save_r10.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r10_mov.rd != 6 or save_r10_mov.rm != 10) return false;

        const save_r9 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9204) catch return false;
        const save_r9_mov = switch (save_r9.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r9_mov.rd != 5 or save_r9_mov.rm != 9) return false;

        const save_r8 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9206) catch return false;
        const save_r8_mov = switch (save_r8.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r8_mov.rd != 4 or save_r8_mov.rm != 8) return false;

        const push_high_saves = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9208) catch return false;
        const push_high_saves_mask = switch (push_high_saves.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_high_saves_mask != 0x0070) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        const expected_call_target = if (target.address == image.base_address + 0x929C)
            image.base_address + 0x2D54
        else if (target.address == image.base_address + 0x9344)
            image.base_address + 0x22E4
        else
            image.base_address + 0x9398;
        if (bl.target.isa != .thumb or bl.target.address != expected_call_target) return false;

        const pop_saved_high = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x936C) catch return false;
        const pop_saved_high_mask = switch (pop_saved_high.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_high_mask != 0x0038) return false;

        const restore_r8 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x936E) catch return false;
        const restore_r8_mov = switch (restore_r8.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r8_mov.rd != 8 or restore_r8_mov.rm != 3) return false;

        const restore_r9 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9370) catch return false;
        const restore_r9_mov = switch (restore_r9.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r9_mov.rd != 9 or restore_r9_mov.rm != 4) return false;

        const restore_r10 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9372) catch return false;
        const restore_r10_mov = switch (restore_r10.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r10_mov.rd != 10 or restore_r10_mov.rm != 5) return false;

        const pop_saved_low = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9374) catch return false;
        const pop_saved_low_mask = switch (pop_saved_low.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_low_mask != 0x0070) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9376) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0002) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9378) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 1;
    }

    if (target.address == image.base_address + 0x93BC) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9398) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4030) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x22E4) return false;

        const pop_saved = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x93C4) catch return false;
        const pop_saved_mask = switch (pop_saved.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_mask != 0x0030) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x93C6) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0002) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x93C8) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 1;
    }

    if (target.address == image.base_address + 0x96EC) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x96E0) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4000) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x973C) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x971C) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0001) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x971E) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 0;
    }

    if (target.address == image.base_address + 0x9862 or
        target.address == image.base_address + 0x9874 or
        target.address == image.base_address + 0x9896)
    {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x973C) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x40F0) return false;

        const save_r9 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x973E) catch return false;
        const save_r9_mov = switch (save_r9.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r9_mov.rd != 7 or save_r9_mov.rm != 9) return false;

        const save_r8 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9740) catch return false;
        const save_r8_mov = switch (save_r8.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r8_mov.rd != 6 or save_r8_mov.rm != 8) return false;

        const push_high_saves = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9742) catch return false;
        const push_high_saves_mask = switch (push_high_saves.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_high_saves_mask != 0x00C0) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        const expected_call_target = if (target.address == image.base_address + 0x9862)
            image.base_address + 0x2D54
        else if (target.address == image.base_address + 0x9874)
            image.base_address + 0x22E4
        else
            image.base_address + 0x2DB4;
        if (bl.target.isa != .thumb or bl.target.address != expected_call_target) return false;

        const pop_saved_high = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9898) catch return false;
        const pop_saved_high_mask = switch (pop_saved_high.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_high_mask != 0x0018) return false;

        const restore_r8 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x989A) catch return false;
        const restore_r8_mov = switch (restore_r8.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r8_mov.rd != 8 or restore_r8_mov.rm != 3) return false;

        const restore_r9 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x989C) catch return false;
        const restore_r9_mov = switch (restore_r9.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r9_mov.rd != 9 or restore_r9_mov.rm != 4) return false;

        const pop_saved_low = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x989E) catch return false;
        const pop_saved_low_mask = switch (pop_saved_low.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_low_mask != 0x00F0) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98A0) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0002) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98A2) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 1;
    }

    if (target.address == image.base_address + 0x99EC) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x99C8) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x4030) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x22E4) return false;

        const pop_saved = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x99F4) catch return false;
        const pop_saved_mask = switch (pop_saved.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_mask != 0x0030) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x99F6) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0002) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x99F8) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 1;
    }

    if (target.address == image.base_address + 0x9932) {
        const function_entry = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98A8) catch return false;
        const push_mask = switch (function_entry.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_mask != 0x40F0) return false;

        const save_r10 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98AA) catch return false;
        const save_r10_mov = switch (save_r10.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r10_mov.rd != 7 or save_r10_mov.rm != 10) return false;

        const save_r9 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98AC) catch return false;
        const save_r9_mov = switch (save_r9.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r9_mov.rd != 6 or save_r9_mov.rm != 9) return false;

        const save_r8 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98AE) catch return false;
        const save_r8_mov = switch (save_r8.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (save_r8_mov.rd != 5 or save_r8_mov.rm != 8) return false;

        const push_high_saves = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x98B0) catch return false;
        const push_high_saves_mask = switch (push_high_saves.instruction) {
            .push => |mask| mask,
            else => return false,
        };
        if (push_high_saves_mask != 0x00E0) return false;

        const coroutine_call = previousInstruction(image, .thumb, target.address) catch return false;
        const bl = switch (coroutine_call.instruction) {
            .bl => |bl| bl,
            else => return false,
        };
        if (bl.target.isa != .thumb or bl.target.address != image.base_address + 0x99C8) return false;

        const pop_saved_high = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9994) catch return false;
        const pop_saved_high_mask = switch (pop_saved_high.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_high_mask != 0x0038) return false;

        const restore_r8 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9996) catch return false;
        const restore_r8_mov = switch (restore_r8.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r8_mov.rd != 8 or restore_r8_mov.rm != 3) return false;

        const restore_r9 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x9998) catch return false;
        const restore_r9_mov = switch (restore_r9.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r9_mov.rd != 9 or restore_r9_mov.rm != 4) return false;

        const restore_r10 = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x999A) catch return false;
        const restore_r10_mov = switch (restore_r10.instruction) {
            .mov_reg => |mov| mov,
            else => return false,
        };
        if (restore_r10_mov.rd != 10 or restore_r10_mov.rm != 5) return false;

        const pop_saved_low = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x999C) catch return false;
        const pop_saved_low_mask = switch (pop_saved_low.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_saved_low_mask != 0x00F0) return false;

        const pop_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x999E) catch return false;
        const pop_return_mask = switch (pop_return.instruction) {
            .pop => |mask| mask,
            else => return false,
        };
        if (pop_return_mask != 0x0001) return false;

        const bx_return = decodeImageInstructionUnchecked(image, .thumb, image.base_address + 0x99A0) catch return false;
        const bx = switch (bx_return.instruction) {
            .bx_reg => |bx| bx,
            else => return false,
        };
        return bx.reg == 0;
    }

    return false;
}

const ThumbMovPcJumpTable = struct {
    table_base: u32,
    entry_count: u32,
};

fn measureThumbMovPcJumpTable(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!?ThumbMovPcJumpTable {
    if (isa != .thumb) return null;

    const load_target_insn = previousInstruction(image, isa, address) catch return null;
    const load_target = switch (load_target_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (load_target.rd != reg or load_target.base != reg or load_target.offset != 0) return null;

    const add_insn = previousInstruction(image, isa, load_target_insn.address) catch return null;
    const add = switch (add_insn.instruction) {
        .add_reg => |add| add,
        else => return null,
    };
    if (add.rd != reg or add.rn != reg) return null;
    const table_base_reg = add.rm;

    const table_load_insn = previousInstruction(image, isa, add_insn.address) catch return null;
    const table_load = switch (table_load_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (table_load.rd != table_base_reg or table_load.base != 15) return null;

    const shift_insn = previousInstruction(image, isa, table_load_insn.address) catch return null;
    const shift = switch (shift_insn.instruction) {
        .lsls_imm => |shift| shift,
        else => return null,
    };
    if (shift.rd != reg or shift.imm != 2) return null;
    const index_reg = shift.rm;

    var scan_address = shift_insn.address;
    var entry_count: ?u32 = null;
    var scanned: usize = 0;
    while (scanned < 8 and scan_address > image.base_address) : (scanned += 1) {
        const candidate = previousInstruction(image, isa, scan_address) catch break;
        scan_address = candidate.address;
        switch (candidate.instruction) {
            .cmp_imm => |cmp| {
                if (cmp.rn == index_reg) {
                    entry_count = cmp.imm + 1;
                    break;
                }
            },
            else => {},
        }
    }
    const count = entry_count orelse return null;
    if (count == 0 or count > 64) return null;

    return .{
        .table_base = try resolveLiteralWordFromRom(image, isa, table_load_insn.address, table_load.offset),
        .entry_count = count,
    };
}

fn enqueueMeasuredThumbMovPcJumpTableTargets(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    pending: *std.ArrayList(armv4t_decode.CodeAddress),
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!bool {
    const table = try measureThumbMovPcJumpTable(image, isa, address, reg) orelse return false;
    var index: u32 = 0;
    while (index < table.entry_count) : (index += 1) {
        const entry_address = table.table_base + index * 4;
        const entry_offset = romOffsetForAddress(image, entry_address, .arm) orelse return false;
        if (entry_offset + 4 > image.bytes.len) return false;

        const raw_target = armv4t_decode.readWord(image.bytes, entry_offset);
        if ((raw_target & 1) != 0) return false;
        const target = armv4t_decode.CodeAddress{ .address = raw_target & ~@as(u32, 1), .isa = .thumb };
        if (offsetForAddress(image, target.address, target.isa) == null) {
            try writer.print("Unsupported control flow target 0x{X:0>8} for gba\n", .{target.address});
            return error.UnsupportedOpcode;
        }
        if (containsCodeAddress(pending.items, target)) continue;
        try pending.append(allocator, target);
    }
    return true;
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

    if (measuredDevkitArmIwramCodeSpan(image)) |iwram_span| {
        if (iwram_span.contains(address)) {
            return romOffsetForAddress(image, iwram_span.romAddressFor(address), isa);
        }
    }

    if (measuredKirbyIrqHandlerCodeSpan(image)) |kirby_irq_span| {
        if (kirby_irq_span.contains(address)) {
            return romOffsetForAddress(image, kirby_irq_span.romAddressFor(address), isa);
        }
    }

    if (measuredKirbyIwramOverlayCodeSpan(image)) |kirby_span| {
        if (kirby_span.contains(address)) {
            return romOffsetForAddress(image, kirby_span.romAddressFor(address), isa);
        }
    }

    return null;
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

fn measuredKirbyIrqHandlerCodeSpan(image: gba_loader.RomImage) ?MeasuredDevkitArmCopySpan {
    const source_offset = romOffsetForAddress(image, image.base_address + 0x0730, .arm) orelse return null;
    const dest_offset = romOffsetForAddress(image, image.base_address + 0x0734, .arm) orelse return null;
    const vector_offset = romOffsetForAddress(image, image.base_address + 0x0738, .arm) orelse return null;
    if (source_offset + 4 > image.bytes.len or dest_offset + 4 > image.bytes.len or vector_offset + 4 > image.bytes.len) return null;

    const source = armv4t_decode.readWord(image.bytes, source_offset);
    const dest = armv4t_decode.readWord(image.bytes, dest_offset);
    const vector_slot = armv4t_decode.readWord(image.bytes, vector_offset);
    if (source != image.base_address + 0x0108) return null;
    if (dest != 0x0300_1030) return null;
    if (vector_slot != 0x0300_7FFC) return null;

    return .{
        .rom_lma = source,
        .iwram_vma_start = dest,
        .size = 0x130,
    };
}

fn measuredKirbyIwramOverlayCodeSpan(image: gba_loader.RomImage) ?MeasuredDevkitArmCopySpan {
    const table_offset = romOffsetForAddress(image, image.base_address + 0x0CE5B0, .arm) orelse return null;
    const iwram_end_literal_offset = romOffsetForAddress(image, image.base_address + 0x0CD918, .arm) orelse return null;
    if (table_offset + 12 > image.bytes.len) return null;
    if (iwram_end_literal_offset + 4 > image.bytes.len) return null;

    const raw_source = armv4t_decode.readWord(image.bytes, table_offset);
    const dest = armv4t_decode.readWord(image.bytes, table_offset + 4);
    const next_word = armv4t_decode.readWord(image.bytes, table_offset + 8);
    const iwram_end = armv4t_decode.readWord(image.bytes, iwram_end_literal_offset);

    // Exact measured Kirby overlay table. The source is a Thumb entry in ROM
    // copied to IWRAM before being branched to through a literal target. The
    // copied span starts at the Thumb prologue immediately before that internal
    // entry point; the nearby IWRAM-end literal bounds later runtime-dispatched
    // overlay helpers.
    if (raw_source != image.base_address + 0x0CD931) return null;
    if (dest != 0x0300_7150) return null;
    if (next_word != 0x0400_0100) return null;
    if (iwram_end != 0x0300_7FF0) return null;

    const rom_start = image.base_address + 0x0CD8AC;
    const iwram_start = 0x0300_70CC;
    if (iwram_end <= iwram_start) return null;

    return .{
        .rom_lma = rom_start,
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

fn containsCodeAddress(entries: []const armv4t_decode.CodeAddress, entry: armv4t_decode.CodeAddress) bool {
    for (entries) |candidate| {
        if (codeAddressEqual(candidate, entry)) return true;
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
        .bx_reg => |bx| resolveBxTarget(image, function_entry, address, bx.reg) catch |err| switch (err) {
            error.UnsupportedOpcode => if (try isDynamicBxRegister(image, function_entry, address, bx.reg))
                decoded
            else
                return err,
            else => |other| return other,
        },
        .mov_reg => |mov| if (mov.rd == 15 and mov.rm != 14)
            resolveMovPcTarget(image, isa, address, mov.rm) catch |err| switch (err) {
                error.UnsupportedOpcode => if (try isRuntimeLoadedBxRegister(image, isa, address, mov.rm))
                    armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = mov.rm } }
                else
                    return err,
                else => |other| return other,
            }
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
        .bl => |bl| if (try resolveThumbBxPcArmBranchVeneerTarget(image, isa, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else if (try resolveExactLocalThumbBlxR3VeneerTarget(image, isa, address, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else if (try resolveExactObjDemoLocalThumbBlxR9VeneerTarget(image, isa, address, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else if (try resolveDevkitArmCrt0StartupThumbBlxR3Target(image, isa, address, bl.target.address)) |resolved_target|
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = resolved_target } }
        else if (try resolveLocalThumbBlxRegVeneerTarget(image, isa, address, bl.target.address)) |resolved_target|
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
    if (isMeasuredKirbyCoroutineResumePoppedReturn(image, function_entry, address, reg)) {
        return .{ .bx_reg = .{ .reg = reg } };
    }
    if (isMeasuredKirbyCoroutineSwitchEntryPoppedReturn(image, function_entry, address, reg)) {
        return .{ .bx_reg = .{ .reg = reg } };
    }
    if (isMeasuredKirbyArmCoroutinePopR1BxR1Exit(image, function_entry, address, reg)) {
        return .{ .bx_reg = .{ .reg = reg } };
    }
    if (isMeasuredKirbyCoroutineCallerContinuationPoppedReturn(image, function_entry, address, reg)) {
        return .{ .bx_reg = .{ .reg = reg } };
    }
    if (isExactThumbSavedLrInterworkingReturnEpilogue(image, function_entry, address, reg)) {
        // This is the exact `sbb_reg`-style Thumb interworking return shape:
        // an entry `push {saved_regs..., lr}` paired with `pop {saved_regs...};
        // pop {return_reg}; bx return_reg`.
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isExactThumbPushLrPopR0BxR0ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isMeasuredThumbPopR0BxR0ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isMeasuredThumbPopR4R5PopR0BxR0ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isMeasuredThumbR8SavePopR0BxR0ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isMeasuredThumbSharedFramePopR0BxR0ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isMeasuredThumbOverlayHighRegsPopR3BxR3ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isExactThumbMovIpLrBxIpReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (function_entry.isa == .thumb and reg == 0) {
        // Reject only the exact local near-miss `push {lr}; pop {r0}; movs r0,
        // #0; bx r0`. Other `push {lr}` / `bx r0` flows still fall through to
        // the generic register-value resolver below.
        const entry = try decodeImageInstructionUnchecked(image, .thumb, function_entry.address);
        const entry_is_push_lr = switch (entry.instruction) {
            .push => |mask| mask == 0x4000,
            else => false,
        };
        if (entry_is_push_lr) {
            const previous = try previousInstruction(image, function_entry.isa, address);
            const previous_is_mov_r0_0 = switch (previous.instruction) {
                .movs_imm => |mov| mov.rd == 0 and mov.imm == 0,
                else => false,
            };
            if (previous_is_mov_r0_0) {
                const prior = try previousInstruction(image, function_entry.isa, previous.address);
                const prior_is_pop_r0 = switch (prior.instruction) {
                    .pop => |mask| mask == 0x0001,
                    else => false,
                };
                if (prior_is_pop_r0) return .{ .bx_reg = .{ .reg = reg } };
            }
        }
    }
    if (function_entry.isa == .arm and reg == 1) {
        if (try resolveMeasuredArmStartupBxR1LiteralTarget(image, function_entry, address)) |target| {
            return .{ .bl = .{ .target = target } };
        }
    }
    if (function_entry.isa == .arm and reg == 12) {
        if (try resolveMeasuredKirbyArmBxIpLiteralVeneerTarget(image, function_entry, address)) |target| {
            return .{ .bx_target = target };
        }
    }
    if (function_entry.isa == .arm and reg == 0) {
        if (try resolveMeasuredKirbyVBlankIrqDispatcherBxR0Target(image, function_entry, address)) |target| {
            return .{ .bl = .{ .target = target } };
        }
    }
    if (function_entry.isa == .thumb and reg == 6) {
        const previous = try previousInstruction(image, function_entry.isa, address);
        if (previous.instruction == .bl) {
            return .{ .bx_target = normalizeCodeTarget(try resolveStartupThumbBxR6TargetValue(image, function_entry.isa, address)) };
        }
    }
    const raw_target = resolvePreviousRegisterValue(image, function_entry.isa, address, reg) catch
        return .{ .bx_reg = .{ .reg = reg } };
    const target = normalizeCodeTarget(raw_target);
    if (offsetForAddress(image, target.address, target.isa) == null) {
        return .{ .bx_reg = .{ .reg = reg } };
    }
    return .{ .bx_target = target };
}

fn isRuntimeLoadedBxRegister(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!bool {
    const previous = try previousInstruction(image, isa, address);
    return switch (previous.instruction) {
        .ldr_word_imm => |load| load.rd == reg and load.base != 15,
        else => false,
    };
}

fn isDynamicBxRegister(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) BuildError!bool {
    if (isMeasuredKirbyArmInterworkingArgumentBxR1(image, function_entry, address, reg) catch false) return true;
    if (isRuntimeLoadedBxRegister(image, function_entry.isa, address, reg) catch false) return true;
    return function_entry.isa == .thumb and
        function_entry.address == address and
        isMeasuredLocalThumbBlxVeneerNop(image, address + 2);
}

fn isMeasuredKirbyArmCoroutinePopR1BxR1Exit(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .arm) return false;
    if (function_entry.address == image.base_address + 0x0258) {
        if (address != image.base_address + 0x0284 and address != image.base_address + 0x02A4) return false;
    } else if (function_entry.address == image.base_address + 0x0288) {
        if (address != image.base_address + 0x02A4) return false;
    } else {
        return false;
    }
    if (reg != 1) return false;

    const previous = previousInstruction(image, .arm, address) catch return false;
    return switch (previous.instruction) {
        .pop => |mask| mask == 0x0002,
        else => false,
    };
}

fn isMeasuredKirbyCoroutineResumePoppedReturn(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (function_entry.address != image.base_address + 0x5368) return false;
    if (address != image.base_address + 0x559E) return false;
    if (reg != 0) return false;

    const previous = previousInstruction(image, .thumb, address) catch return false;
    return switch (previous.instruction) {
        .pop => |mask| mask == 0x0001,
        else => false,
    };
}

fn isMeasuredKirbyCoroutineSwitchEntryPoppedReturn(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (function_entry.address != image.base_address + 0x95C0) return false;
    if (address != image.base_address + 0x95E2) return false;
    if (reg != 0) return false;
    if (!isMeasuredKirbyCoroutineSwitchEntryTarget(image, function_entry)) return false;

    const previous = previousInstruction(image, .thumb, address) catch return false;
    return switch (previous.instruction) {
        .pop => |mask| mask == 0x0001,
        else => false,
    };
}

fn isMeasuredKirbyCoroutineCallerContinuationPoppedReturn(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;

    if (function_entry.address == image.base_address + 0x22EA) {
        if (reg != 0) return false;
        if (address != image.base_address + 0x22F8) return false;
    } else if (function_entry.address == image.base_address + 0x2D68) {
        if (reg != 0) return false;
        if (address != image.base_address + 0x2D72) return false;
    } else if (function_entry.address == image.base_address + 0x2DC4) {
        if (reg != 0) return false;
        if (address != image.base_address + 0x2DD4) return false;
    } else if (function_entry.address == image.base_address + 0x929C) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x9378) return false;
    } else if (function_entry.address == image.base_address + 0x92A8) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x9378) return false;
    } else if (function_entry.address == image.base_address + 0x92B8) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x9378) return false;
    } else if (function_entry.address == image.base_address + 0x92D6) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x9378) return false;
    } else if (function_entry.address == image.base_address + 0x9344) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x9378) return false;
    } else if (function_entry.address == image.base_address + 0x93BC) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x93C8) return false;
    } else if (function_entry.address == image.base_address + 0x91B2) {
        if (reg != 0) return false;
        if (address != image.base_address + 0x91FA) return false;
    } else if (function_entry.address == image.base_address + 0x96EC) {
        if (reg != 0) return false;
        if (address != image.base_address + 0x971E) return false;
    } else if (function_entry.address == image.base_address + 0x9862) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x98A2) return false;
    } else if (function_entry.address == image.base_address + 0x9874) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x98A2) return false;
    } else if (function_entry.address == image.base_address + 0x9896) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x98A2) return false;
    } else if (function_entry.address == image.base_address + 0x9932) {
        if (reg != 0) return false;
        if (address != image.base_address + 0x99A0) return false;
    } else if (function_entry.address == image.base_address + 0x99EC) {
        if (reg != 1) return false;
        if (address != image.base_address + 0x99F8) return false;
    } else {
        return false;
    }

    if (!isMeasuredKirbyCoroutineCallerContinuationTarget(image, function_entry)) return false;

    const previous = previousInstruction(image, .thumb, address) catch return false;
    return switch (previous.instruction) {
        .pop => |mask| mask == (@as(u16, 1) << reg),
        else => false,
    };
}

fn isMeasuredKirbyArmInterworkingArgumentBxR1(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) BuildError!bool {
    if (function_entry.isa != .arm) return false;
    if (function_entry.address != image.base_address + 0x0234) return false;
    if (address != image.base_address + 0x0254) return false;
    if (reg != 1) return false;

    const orr_insn = try previousInstruction(image, .arm, address);
    const orr = switch (orr_insn.instruction) {
        .orr_reg => |orr| orr,
        else => return false,
    };
    if (orr.rd != 1 or orr.rn != 1 or orr.rm != 2 or orr.update_flags) return false;

    const mov_insn = try previousInstruction(image, .arm, orr_insn.address);
    const mov = switch (mov_insn.instruction) {
        .mov_imm => |mov| mov,
        else => return false,
    };
    return mov.rd == 2 and mov.imm == 1;
}

fn resolveMeasuredKirbyVBlankIrqDispatcherBxR0Target(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (function_entry.isa != .arm) return null;
    if (function_entry.address != 0x0300_1030) return null;
    if (address != 0x0300_10F8) return null;

    const span = measuredKirbyIrqHandlerCodeSpan(image) orelse return null;
    if (!span.contains(address)) return null;

    const add_lr_pc_insn = try previousInstruction(image, .arm, address);
    const add_lr_pc = switch (add_lr_pc_insn.instruction) {
        .add_imm => |add| add,
        else => return null,
    };
    if (add_lr_pc.rd != 14 or add_lr_pc.rn != 15 or add_lr_pc.imm != 0) return null;

    const push_lr_insn = try previousInstruction(image, .arm, add_lr_pc_insn.address);
    const push_lr = switch (push_lr_insn.instruction) {
        .push => |mask| mask,
        else => return null,
    };
    if (push_lr != 0x4000) return null;

    const default0_offset = romOffsetForAddress(image, image.base_address + 0x0CFDE8, .arm) orelse return null;
    const default1_offset = romOffsetForAddress(image, image.base_address + 0x0CFDEC, .arm) orelse return null;
    const vblank_offset = romOffsetForAddress(image, image.base_address + 0x0CFDF0, .arm) orelse return null;
    if (default0_offset + 4 > image.bytes.len or default1_offset + 4 > image.bytes.len or vblank_offset + 4 > image.bytes.len) return null;

    const default0_raw = armv4t_decode.readWord(image.bytes, default0_offset);
    const default1_raw = armv4t_decode.readWord(image.bytes, default1_offset);
    const vblank_raw = armv4t_decode.readWord(image.bytes, vblank_offset);
    if (default0_raw != image.base_address + 0x1519) return null;
    if (default1_raw != image.base_address + 0x1519) return null;
    if (vblank_raw != image.base_address + 0x10CD) return null;

    const target = normalizeCodeTarget(vblank_raw);
    if (target.isa != .thumb) return null;
    if (offsetForAddress(image, target.address, target.isa) == null) return null;
    return target;
}

fn resolveMeasuredArmStartupBxR1LiteralTarget(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (function_entry.isa != .arm) return null;
    if (function_entry.address != image.base_address) return null;
    if (address < image.base_address or address > image.base_address + 0x200) return null;

    const mov_lr_pc_insn = try previousInstruction(image, .arm, address);
    const mov_lr_pc = switch (mov_lr_pc_insn.instruction) {
        .mov_reg => |mov| mov,
        else => return null,
    };
    if (mov_lr_pc.rd != 14 or mov_lr_pc.rm != 15) return null;

    const ldr_r1_insn = try previousInstruction(image, .arm, mov_lr_pc_insn.address);
    const ldr_r1 = switch (ldr_r1_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r1.rd != 1 or ldr_r1.base != 15) return null;

    const literal_address = pcValueForInstruction(.arm, ldr_r1_insn.address) + ldr_r1.offset;
    const literal_offset = romOffsetForAddress(image, literal_address, .arm) orelse return null;
    if (literal_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, literal_offset);
    const code_target = normalizeCodeTarget(raw_target);
    if (code_target.isa != .thumb) return null;
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return null;
    return code_target;
}

fn resolveMeasuredKirbyArmBxIpLiteralVeneerTarget(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (function_entry.isa != .arm) return null;
    if (function_entry.address != image.base_address + 0x0CFDDC) return null;
    if (address != image.base_address + 0x0CFDE0) return null;

    const load_ip_insn = try previousInstruction(image, .arm, address);
    const load_ip = switch (load_ip_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (load_ip.rd != 12 or load_ip.base != 15) return null;

    const literal_address = pcValueForInstruction(.arm, load_ip_insn.address) + load_ip.offset;
    const literal_offset = romOffsetForAddress(image, literal_address, .arm) orelse return null;
    if (literal_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, literal_offset);
    const target = normalizeCodeTarget(raw_target);
    if (target.isa != .thumb) return null;
    if (offsetForAddress(image, target.address, target.isa) == null) return null;
    return target;
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

fn isExactThumbPushLrPopR0BxR0ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 0 and reg != 1) return false;

    const entry = decodeImageInstructionUnchecked(image, .thumb, function_entry.address) catch return false;
    if (entry.size_bytes != 2) return false;
    const push_mask = switch (entry.instruction) {
        .push => |mask| mask,
        else => return false,
    };
    if (push_mask != 0x4000) return false; // exact measured `push {lr}`

    const previous = previousInstruction(image, .thumb, address) catch return false;
    const pop_mask = switch (previous.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_mask != (@as(u16, 1) << reg)) return false; // exact measured `pop {r0}` / `pop {r1}`

    const prior = previousInstruction(image, .thumb, previous.address) catch return false;
    switch (prior.instruction) {
        .pop => return false,
        else => {},
    }

    return true;
}

fn isExactThumbMovIpLrBxIpReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 12) return false;
    if (address <= function_entry.address) return false;

    const entry = decodeImageInstructionUnchecked(image, .thumb, function_entry.address) catch return false;
    const mov = switch (entry.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };

    // Exact measured Kirby helper shape: `mov ip, lr` at entry, then later
    // `bx ip` to return after the helper body.
    return mov.rd == 12 and mov.rm == 14;
}

fn isMeasuredThumbPopR4R5PopR0BxR0ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 0 and reg != 1) return false;

    const previous = previousInstruction(image, .thumb, address) catch return false;
    const pop_return = switch (previous.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_return != (@as(u16, 1) << reg)) return false;

    const prior = previousInstruction(image, .thumb, previous.address) catch return false;
    const pop_saved = switch (prior.instruction) {
        .pop => |mask| mask,
        else => return false,
    };

    if (pop_saved == 0x0010) {
        const entry = decodeImageInstructionUnchecked(image, .thumb, function_entry.address) catch return false;
        const entry_push_mask = switch (entry.instruction) {
            .push => |mask| mask,
            else => 0,
        };
        if ((entry_push_mask & (@as(u16, 1) << 14)) != 0) return false;
        return true;
    }

    // Exact measured Kirby table-seeded helper tails.
    return pop_saved == 0x0030 or pop_saved == 0x0070 or pop_saved == 0x00F0;
}

fn isMeasuredThumbPopR0BxR0ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 0) return false;

    const previous = previousInstruction(image, .thumb, address) catch return false;
    const pop_return = switch (previous.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_return != 0x0001) return false;

    const prior = previousInstruction(image, .thumb, previous.address) catch return false;
    const store = switch (prior.instruction) {
        .store => |store| store,
        else => return false,
    };
    if (store.src != 0 or store.base != 1 or store.size != .word) return false;

    const index = switch (store.addressing) {
        .offset => |index| index,
        else => return false,
    };
    if (index.subtract) return false;

    const offset = switch (index.offset) {
        .imm => |imm| imm,
        else => return false,
    };

    // Exact measured Kirby table helper tail: `str r0, [r1, #64];
    // pop {r0}; bx r0`.
    return offset == 64;
}

fn isMeasuredThumbR8SavePopR0BxR0ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 0) return false;

    const entry_push = decodeImageInstructionUnchecked(image, .thumb, function_entry.address) catch return false;
    const entry_push_mask = switch (entry_push.instruction) {
        .push => |mask| mask,
        else => return false,
    };
    if (entry_push_mask != 0x40F0) return false;

    const save_high = decodeImageInstructionUnchecked(image, .thumb, function_entry.address + 2) catch return false;
    const save_high_mov = switch (save_high.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (save_high_mov.rd != 7 or save_high_mov.rm != 8) return false;

    const push_saved_high = decodeImageInstructionUnchecked(image, .thumb, function_entry.address + 4) catch return false;
    const push_saved_high_mask = switch (push_saved_high.instruction) {
        .push => |mask| mask,
        else => return false,
    };
    if (push_saved_high_mask != 0x0080) return false;

    const pop_return = previousInstruction(image, .thumb, address) catch return false;
    const pop_return_mask = switch (pop_return.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_return_mask != 0x0001) return false;

    const pop_low = previousInstruction(image, .thumb, pop_return.address) catch return false;
    const pop_low_mask = switch (pop_low.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_low_mask != 0x00F0) return false;

    const restore_high = previousInstruction(image, .thumb, pop_low.address) catch return false;
    const restore_high_mov = switch (restore_high.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (restore_high_mov.rd != 8 or restore_high_mov.rm != 3) return false;

    const pop_saved_high = previousInstruction(image, .thumb, restore_high.address) catch return false;
    const pop_saved_high_mask = switch (pop_saved_high.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    return pop_saved_high_mask == 0x0008;
}

fn isMeasuredThumbSharedFramePopR0BxR0ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 0) return false;

    const pop_return = previousInstruction(image, .thumb, address) catch return false;
    const pop_return_mask = switch (pop_return.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_return_mask != 0x0001) return false;

    const pop_low = previousInstruction(image, .thumb, pop_return.address) catch return false;
    const pop_low_mask = switch (pop_low.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_low_mask != 0x00F0) return false;

    const restore_high = previousInstruction(image, .thumb, pop_low.address) catch return false;
    const restore_high_mov = switch (restore_high.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (restore_high_mov.rd != 8 or restore_high_mov.rm != 3) return false;

    const pop_saved_high = previousInstruction(image, .thumb, restore_high.address) catch return false;
    const pop_saved_high_mask = switch (pop_saved_high.instruction) {
        .pop => |mask| mask,
        else => return false,
    };

    // Exact measured Kirby jump-table case epilogue. The case labels are lifted
    // as separate dynamic-dispatch targets, so the local prologue is not visible
    // from their function entry.
    return pop_saved_high_mask == 0x0008;
}

fn isMeasuredThumbOverlayHighRegsPopR3BxR3ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 3) return false;

    const pop_return = previousInstruction(image, .thumb, address) catch return false;
    const pop_return_mask = switch (pop_return.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_return_mask != 0x0008) return false;

    const restore_fp = previousInstruction(image, .thumb, pop_return.address) catch return false;
    const restore_fp_mov = switch (restore_fp.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (restore_fp_mov.rd != 11 or restore_fp_mov.rm != 3) return false;

    const restore_sl = previousInstruction(image, .thumb, restore_fp.address) catch return false;
    const restore_sl_mov = switch (restore_sl.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (restore_sl_mov.rd != 10 or restore_sl_mov.rm != 2) return false;

    const restore_r9 = previousInstruction(image, .thumb, restore_sl.address) catch return false;
    const restore_r9_mov = switch (restore_r9.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (restore_r9_mov.rd != 9 or restore_r9_mov.rm != 1) return false;

    const restore_r8 = previousInstruction(image, .thumb, restore_r9.address) catch return false;
    const restore_r8_mov = switch (restore_r8.instruction) {
        .mov_reg => |mov| mov,
        else => return false,
    };
    if (restore_r8_mov.rd != 8 or restore_r8_mov.rm != 0) return false;

    const pop_low = previousInstruction(image, .thumb, restore_r8.address) catch return false;
    const pop_low_mask = switch (pop_low.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_low_mask != 0x00FF) return false;

    const add_sp = previousInstruction(image, .thumb, pop_low.address) catch return false;
    const add = switch (add_sp.instruction) {
        .add_imm => |add| add,
        else => return false,
    };

    // Exact measured Kirby IWRAM-overlay epilogue:
    // `add sp,#28; pop {r0-r7}; mov r8,r0; mov r9,r1; mov sl,r2;
    // mov fp,r3; pop {r3}; bx r3`.
    return add.rd == 13 and add.rn == 13 and add.imm == 28;
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

    if (!isMeasuredLocalThumbBlxVeneerNop(image, target_address + 2)) return null;
    if (try resolveExactSimpleLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactObjDemoLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactKeyDemoLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactKeyDemoAddsLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    if (try resolveExactLibcInitArrayLocalThumbBlxR3CallerTarget(image, isa, bl_address)) |resolved_target| return resolved_target;
    return try resolveExactSbbRegLocalThumbBlxR3CallerTarget(image, isa, bl_address);
}

fn isMeasuredLocalThumbBlxVeneerNop(image: gba_loader.RomImage, address: u32) bool {
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
    if (!isMeasuredLocalThumbBlxVeneerNop(image, target_address + 2)) return null;

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

fn resolveLocalThumbBlxRegVeneerTarget(
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
    if (!isMeasuredLocalThumbBlxVeneerNop(image, target_address + 2)) return null;

    if (bx.reg == 3) {
        if (try resolveMeasuredKirbyStackCopiedThumbThunkBlxR3Target(image, isa, bl_address)) |resolved_target| return resolved_target;
    }
    if (bx.reg == 0) {
        if (try resolveMeasuredKirbyIwramLiteralBlxR0Target(image, isa, bl_address)) |resolved_target| return resolved_target;
    }

    const raw_target = resolvePreviousRegisterValue(image, isa, bl_address, bx.reg) catch return null;
    const code_target = normalizeCodeTarget(raw_target);
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return null;
    return code_target;
}

fn resolveMeasuredKirbyIwramLiteralBlxR0Target(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const load_insn = try previousInstruction(image, isa, bl_address);
    const load = switch (load_insn.instruction) {
        .ldr_word_imm => |ldr| ldr,
        else => return null,
    };
    if (load.rd != 0 or load.base != 15) return null;

    const push_insn = try previousInstruction(image, isa, load_insn.address);
    const push = switch (push_insn.instruction) {
        .push => |mask| mask,
        else => return null,
    };
    if (push != 0x4000) return null;

    const pop_insn = try decodeImageInstructionUnchecked(image, isa, bl_address + 4);
    const pop = switch (pop_insn.instruction) {
        .pop => |mask| mask,
        else => return null,
    };
    if (pop != 0x0001) return null;

    const bx_insn = try decodeImageInstructionUnchecked(image, isa, bl_address + 6);
    const bx = switch (bx_insn.instruction) {
        .bx_reg => |bx| bx,
        else => return null,
    };
    if (bx.reg != 0) return null;

    const raw_target = resolveThumbLiteralWordFromRom(image, load_insn.address, load) orelse return null;
    const target = normalizeCodeTarget(raw_target);
    if (target.address != 0x0300_1F40 or target.isa != .thumb) return null;

    const source_offset = romOffsetForAddress(image, image.base_address + 0x878, .arm) orelse return null;
    const dest_offset = romOffsetForAddress(image, image.base_address + 0x87C, .arm) orelse return null;
    if (source_offset + 4 > image.bytes.len or dest_offset + 4 > image.bytes.len) return null;

    const source_raw = armv4t_decode.readWord(image.bytes, source_offset);
    const dest = armv4t_decode.readWord(image.bytes, dest_offset);
    if (source_raw != image.base_address + 0x1B09) return null;
    if (dest != target.address) return null;

    const source = normalizeCodeTarget(source_raw);
    if (source.isa != .thumb) return null;
    if (offsetForAddress(image, source.address, source.isa) == null) return null;
    return source;
}

fn resolveMeasuredKirbyStackCopiedThumbThunkBlxR3Target(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    bl_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;
    if (bl_address < 0x40) return null;

    const adds_r2_insn = try previousInstruction(image, isa, bl_address);
    const adds_r2 = switch (adds_r2_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r2.rd != 2 or adds_r2.rn != 6 or adds_r2.imm != 0) return null;

    const adds_r1_insn = try previousInstruction(image, isa, adds_r2_insn.address);
    const adds_r1 = switch (adds_r1_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r1.rd != 1 or adds_r1.rn != 5 or adds_r1.imm != 0) return null;

    const adds_r0_insn = try previousInstruction(image, isa, adds_r1_insn.address);
    const adds_r0 = switch (adds_r0_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r0.rd != 0 or adds_r0.rn != 4 or adds_r0.imm != 0) return null;

    const adds_r3_insn = try previousInstruction(image, isa, adds_r0_insn.address);
    const adds_r3 = switch (adds_r3_insn.instruction) {
        .adds_imm => |add| add,
        else => return null,
    };
    if (adds_r3.rd != 3 or adds_r3.rn != 3 or adds_r3.imm != 1) return null;

    const mov_sp_insn = try previousInstruction(image, isa, adds_r3_insn.address);
    const mov_sp = switch (mov_sp_insn.instruction) {
        .mov_reg => |mov| mov,
        else => return null,
    };
    if (mov_sp.rd != 3 or mov_sp.rm != 13) return null;

    const copy_start = bl_address - 0x40;
    if (mov_sp_insn.address != copy_start + 0x36) return null;

    const expected_halfwords = [_]struct {
        offset: u32,
        value: u16,
    }{
        .{ .offset = 0x00, .value = 0x4B06 }, // ldr r3, [pc, #24] ; copied source | thumb bit
        .{ .offset = 0x02, .value = 0x2001 }, // movs r0, #1
        .{ .offset = 0x04, .value = 0x4043 }, // eors r3, r0 ; clear thumb bit for data copy
        .{ .offset = 0x06, .value = 0x466A }, // mov r2, sp
        .{ .offset = 0x08, .value = 0x4805 }, // ldr r0, [pc, #20] ; copied source end | thumb bit
        .{ .offset = 0x0A, .value = 0x4904 }, // ldr r1, [pc, #16] ; copied source | thumb bit
        .{ .offset = 0x0C, .value = 0x1A40 }, // subs r0, r0, r1
        .{ .offset = 0x0E, .value = 0x03C0 }, // lsls r0, r0, #15
        .{ .offset = 0x10, .value = 0xE00E }, // branch to loop condition
        .{ .offset = 0x24, .value = 0x8818 }, // ldrh r0, [r3]
        .{ .offset = 0x26, .value = 0x8010 }, // strh r0, [r2]
        .{ .offset = 0x28, .value = 0x3302 }, // adds r3, #2
        .{ .offset = 0x2A, .value = 0x3202 }, // adds r2, #2
        .{ .offset = 0x2C, .value = 0x1E48 }, // subs r0, r1, #1
        .{ .offset = 0x2E, .value = 0x0400 }, // lsls r0, r0, #16
        .{ .offset = 0x30, .value = 0x0C01 }, // lsrs r1, r0, #16
        .{ .offset = 0x32, .value = 0x2900 }, // cmp r1, #0
        .{ .offset = 0x34, .value = 0xD1F6 }, // bne copy loop body
        .{ .offset = 0x36, .value = 0x466B }, // mov r3, sp
        .{ .offset = 0x38, .value = 0x3301 }, // adds r3, #1
    };

    for (expected_halfwords) |expected| {
        if (mappedThumbHalfword(image, copy_start + expected.offset) != expected.value) return null;
    }

    const source_raw = mappedThumbWord(image, copy_start + 0x1C) orelse return null;
    const end_raw = mappedThumbWord(image, copy_start + 0x20) orelse return null;
    if (source_raw == 0 or end_raw == 0) return null;
    if ((source_raw & 1) == 0 or (end_raw & 1) == 0) return null;
    if (end_raw <= source_raw or end_raw - source_raw > 0x100) return null;

    const copied_target = normalizeCodeTarget(source_raw);
    if (copied_target.isa != .thumb) return null;
    if (offsetForAddress(image, copied_target.address, copied_target.isa) == null) return null;
    return copied_target;
}

fn resolveThumbBxPcArmBranchVeneerTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    target_address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (isa != .thumb) return null;

    const bx_pc_insn = decodeImageInstructionUnchecked(image, .thumb, target_address) catch return null;
    const bx_pc = switch (bx_pc_insn.instruction) {
        .bx_reg => |bx| bx,
        else => return null,
    };
    if (bx_pc.reg != 15) return null;

    if (mappedThumbHalfword(image, target_address + 2) != 0x46C0) return null;

    const arm_branch_insn = decodeImageInstructionUnchecked(image, .arm, target_address + 4) catch return null;
    const arm_branch = switch (arm_branch_insn.instruction) {
        .branch => |branch| branch,
        else => return null,
    };
    if (arm_branch.cond != .al) return null;
    if (offsetForAddress(image, arm_branch.target, .arm) == null) return null;
    return .{ .address = arm_branch.target, .isa = .arm };
}

fn mappedThumbHalfword(image: gba_loader.RomImage, address: u32) ?u16 {
    const offset = offsetForAddress(image, address, .thumb) orelse return null;
    if (offset + 2 > image.bytes.len) return null;
    return armv4t_decode.readHalfword(image.bytes, offset);
}

fn mappedThumbWord(image: gba_loader.RomImage, address: u32) ?u32 {
    const offset = offsetForAddress(image, address, .thumb) orelse return null;
    if (offset + 4 > image.bytes.len) return null;
    return armv4t_decode.readWord(image.bytes, offset);
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

fn writeMeasuredCommercialStartupBxR1LiteralRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    startup_offset: usize,
    load_word: u32,
    literal_pc_offset: usize,
    literal: u32,
    thumb_target_address: u32,
    thumb_halfword: u16,
) !void {
    const literal_offset = startup_offset + 8 + literal_pc_offset;
    const thumb_target_offset = @as(usize, @intCast((thumb_target_address & ~@as(u32, 1)) - 0x0800_0000));
    const min_rom_len = @max(@as(usize, 1024), @max(literal_offset + 4, thumb_target_offset + 2));
    const rom_len = (min_rom_len + 3) & ~@as(usize, 3);
    const rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u32, rom[startup_offset..][0..4], load_word, .little);
    std.mem.writeInt(u32, rom[startup_offset + 4 ..][0..4], 0xE1A0E00F, .little);
    std.mem.writeInt(u32, rom[startup_offset + 8 ..][0..4], 0xE12FFF11, .little);
    std.mem.writeInt(u32, rom[literal_offset..][0..4], literal, .little);
    std.mem.writeInt(u16, rom[thumb_target_offset..][0..2], thumb_halfword, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = rom });
}

fn writeLocalThumbBlxRegVeneerRom(
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

fn writeMeasuredKirbyStackCopiedThunkRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    adds_r3_halfword: u16,
) !void {
    var rom: [0x70]u8 = std.mem.zeroes([0x70]u8);

    std.mem.writeInt(u16, rom[0x00..0x02], 0xB510, .little); // push {r4, lr}
    std.mem.writeInt(u16, rom[0x02..0x04], 0x1C04, .little); // adds r4, r0, #0
    std.mem.writeInt(u16, rom[0x04..0x06], 0xBC10, .little); // pop {r4}
    std.mem.writeInt(u16, rom[0x06..0x08], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x08..0x0A], 0x4700, .little); // bx r0

    const copy_start = 0x20;
    const halfwords = [_]struct {
        offset: usize,
        value: u16,
    }{
        .{ .offset = 0x00, .value = 0x4B06 },
        .{ .offset = 0x02, .value = 0x2001 },
        .{ .offset = 0x04, .value = 0x4043 },
        .{ .offset = 0x06, .value = 0x466A },
        .{ .offset = 0x08, .value = 0x4805 },
        .{ .offset = 0x0A, .value = 0x4904 },
        .{ .offset = 0x0C, .value = 0x1A40 },
        .{ .offset = 0x0E, .value = 0x03C0 },
        .{ .offset = 0x10, .value = 0xE00E },
        .{ .offset = 0x24, .value = 0x8818 },
        .{ .offset = 0x26, .value = 0x8010 },
        .{ .offset = 0x28, .value = 0x3302 },
        .{ .offset = 0x2A, .value = 0x3202 },
        .{ .offset = 0x2C, .value = 0x1E48 },
        .{ .offset = 0x2E, .value = 0x0400 },
        .{ .offset = 0x30, .value = 0x0C01 },
        .{ .offset = 0x32, .value = 0x2900 },
        .{ .offset = 0x34, .value = 0xD1F6 },
        .{ .offset = 0x36, .value = 0x466B },
        .{ .offset = 0x38, .value = adds_r3_halfword },
        .{ .offset = 0x3A, .value = 0x1C20 },
        .{ .offset = 0x3C, .value = 0x1C29 },
        .{ .offset = 0x3E, .value = 0x1C32 },
    };
    for (halfwords) |halfword| {
        const start = copy_start + halfword.offset;
        std.mem.writeInt(u16, rom[start..][0..2], halfword.value, .little);
    }

    std.mem.writeInt(u32, rom[copy_start + 0x1C ..][0..4], 0x0800_0001, .little);
    std.mem.writeInt(u32, rom[copy_start + 0x20 ..][0..4], 0x0800_000B, .little);
    std.mem.writeInt(u16, rom[0x68..0x6A], 0x4718, .little); // bx r3
    std.mem.writeInt(u16, rom[0x6A..0x6C], 0x46C0, .little); // nop

    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeMeasuredThumbPopR0BxR0Rom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    body: []const u16,
) !void {
    const rom_len = 2 + body.len * 2 + 4;
    const rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u16, rom[0..2], 0xB500, .little); // push {lr}
    for (body, 0..) |halfword, index| {
        const start = 2 + index * 2;
        std.mem.writeInt(u16, rom[start..][0..2], halfword, .little);
    }
    std.mem.writeInt(u16, rom[rom_len - 4 ..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[rom_len - 2 ..][0..2], 0x4700, .little); // bx r0
    try dir.writeFile(io, .{ .sub_path = path, .data = rom });
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
        .ldr_word_imm => |load| blk: {
            if (load.rd != reg) break :blk try resolvePreviousRegisterValue(image, isa, previous.address, reg);
            if (load.base != 15) return error.UnsupportedOpcode;
            if (isa != .thumb) return error.UnsupportedOpcode;
            break :blk try resolveLiteralWordFromRom(image, isa, previous.address, load.offset);
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

fn resolveLiteralWordFromRom(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    load_address: u32,
    offset: u32,
) BuildError!u32 {
    const literal_address = pcValueForInstruction(isa, load_address) + offset;
    const literal_offset = offsetForAddress(image, literal_address, isa) orelse return error.UnsupportedOpcode;
    if (literal_offset + 4 > image.bytes.len) return error.UnsupportedOpcode;
    return armv4t_decode.readWord(image.bytes, literal_offset);
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
        .and_shift_reg => |and_op| and_op.rd == 15,
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
        .sub_reg => |sub| sub.rd == 15,
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
        .ldr_signed_byte_post_imm => |load| load.rd == 15,
        .ldr_signed_byte_pre_index_imm => |load| load.rd == 15,
        .ldr_signed_byte_pre_index_reg => |load| load.rd == 15,
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

fn isCpuSetSwi(imm24: u24) bool {
    return imm24 == 0x00000B or imm24 == 0x0B0000;
}

fn isCpuFastSetSwi(imm24: u24) bool {
    return imm24 == 0x00000C or imm24 == 0x0C0000;
}

fn swiEndsFunction(imm24: u24) bool {
    return imm24 == 0x000000;
}

fn swiShimName(imm24: u24) ?[]const u8 {
    if (imm24 == 0x000000) return "SoftReset";
    if (imm24 == 0x000001 or imm24 == 0x010000) return "RegisterRamReset";
    if (isVBlankIntrWaitSwi(imm24)) return "VBlankIntrWait";
    if (isDivSwi(imm24)) return "Div";
    if (isSqrtSwi(imm24)) return "Sqrt";
    if (isCpuSetSwi(imm24)) return "CpuSet";
    if (isCpuFastSetSwi(imm24)) return "CpuFastSet";
    if (imm24 == 0x000011 or imm24 == 0x110000) return "LZ77UnCompWram";
    if (imm24 == 0x000012 or imm24 == 0x120000) return "LZ77UnCompVram";
    if (imm24 == 0x000013 or imm24 == 0x130000) return "HuffUnComp";
    if (imm24 == 0x000025 or imm24 == 0x250000) return "MultiBoot";
    if (imm24 == 0x000028 or imm24 == 0x280000) return "SoundDriverVSyncOff";
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
    if (shouldLinkDl(options)) {
        try argv.append(allocator, "-ldl");
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

fn shouldLinkDl(options: BuildOptions) bool {
    if (options.output_mode != .window) return false;
    const target = options.target orelse return true;
    return std.mem.indexOf(u8, target, "linux") != null;
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
        .window => "window",
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

fn writeCpuSetCopyRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000B, // swi 0x0B (CpuSet)
        0xE5910004, // ldr r0, [r1, #4]
        0xE12FFF1E, // bx lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x04000002, // two 32-bit units, copy mode
        42, // source word 0
        99, // source word 1
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuFastSetCopyRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xE591001C, // ldr r0, [r1, #28] ; eighth copied word
        0xE1A0F00E, // mov pc, lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x00000008, // eight 32-bit words, copy mode
        11,
        22,
        33,
        44,
        55,
        66,
        77,
        88,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeLz77UnCompVramLiteralRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xEF000012, // swi 0x12 (LZ77UnCompVram)
        0xE5D10000, // ldrb r0, [r1]
        0xEF000000, // swi 0x00 (SoftReset)
        0x00000000, // padding
        0x08000020, // source literal
        0x02000000, // dest literal
        0x00000310, // LZ77 header: type 0x10, decompressed size 3
        0x43424100, // flags=0, literals 'A', 'B', 'C'
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeLz77UnCompVramHalfwordRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xEF000012, // swi 0x12 (LZ77UnCompVram)
        0xE1D100B0, // ldrh r0, [r1]
        0xEF000000, // swi 0x00 (SoftReset)
        0x00000000, // padding
        0x08000020, // source literal
        0x06000000, // dest literal
        0x00000210, // LZ77 header: type 0x10, decompressed size 2
        0x00341200, // flags=0, literals 0x12, 0x34
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuFastSetFillRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xE591001C, // ldr r0, [r1, #28] ; eighth filled word
        0xE1A0F00E, // mov pc, lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x01000008, // eight 32-bit words, fill mode
        1234, // fill word
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuFastSetAlignRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0014, // ldr r0, [pc, #0x14] ; misaligned source
        0xE59F1014, // ldr r1, [pc, #0x14] ; misaligned dest
        0xE59F2014, // ldr r2, [pc, #0x14] ; control
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xE59F3010, // ldr r3, [pc, #0x10] ; aligned dest base
        0xE5930000, // ldr r0, [r3]
        0xE1A0F00E, // mov pc, lr
        0x0800002D, // source literal: align down to 0x0800002C
        0x03000002, // dest literal: align down to 0x03000000
        0x00000001, // one 32-bit word, copy mode
        0x03000000, // aligned dest base literal
        42,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuFastSetBadControlRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F000C, // ldr r0, [pc, #0x0C]
        0xE59F100C, // ldr r1, [pc, #0x0C]
        0xE59F200C, // ldr r2, [pc, #0x0C]
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xEAFFFFFE, // b . ; would spin until the instruction limit if stop_flag were ignored
        0x08000020,
        0x03000000,
        0x04000008, // bit 26 is valid for CpuSet, unsupported for CpuFastSet
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuFastSetWordCountRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    var words: [17]u32 = undefined;
    words[0] = 0xE59F0010; // ldr r0, [pc, #0x10] ; source
    words[1] = 0xE59F1010; // ldr r1, [pc, #0x10] ; dest
    words[2] = 0xE59F2010; // ldr r2, [pc, #0x10] ; control
    words[3] = 0xEF00000C; // swi 0x0C (CpuFastSet)
    words[4] = 0xE591001C; // ldr r0, [r1, #28] ; eighth word must remain untouched
    words[5] = 0xE1A0F00E; // mov pc, lr
    words[6] = 0x08000024; // source literal
    words[7] = 0x03000000; // dest literal
    words[8] = 0x00000007; // seven 32-bit words
    for (0..8) |index| {
        words[9 + index] = @intCast(index + 1);
    }

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeVCountPollRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F100C, // ldr r1, [pc, #0x0C] ; VCOUNT
        0xE5D10000, // ldrb r0, [r1]
        0xE3500003, // cmp r0, #3
        0x1AFFFFFC, // bne loop
        0xE12FFF1E, // bx lr
        0x04000006, // VCOUNT
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuSetCopyAutoProbeRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF000006, // swi 0x06 (Div) as a supported stand-in
        0xE5910004, // ldr r0, [r1, #4]
        0xE12FFF1E, // bx lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x04000002, // two 32-bit units, copy mode
        42, // source word 0
        99, // source word 1
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuSetFillRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000B, // swi 0x0B (CpuSet)
        0xE1D100B2, // ldrh r0, [r1, #2]
        0xE12FFF1E, // bx lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x01000002, // two 16-bit units, fill mode
        7, // source halfword value in low bits
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuSetBadControlRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F000C, // ldr r0, [pc, #0x0C]
        0xE59F100C, // ldr r1, [pc, #0x0C]
        0xE59F200C, // ldr r2, [pc, #0x0C]
        0xEF00000B, // swi 0x0B (CpuSet)
        0xEAFFFFFE, // b . ; would spin until the instruction limit if stop_flag were ignored
        0x08000020,
        0x03000000,
        0x82000001, // reserved upper bit outside the supported CpuSet mask
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuSetWordAlignRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0014, // ldr r0, [pc, #0x14] ; misaligned source
        0xE59F1014, // ldr r1, [pc, #0x14] ; misaligned dest
        0xE59F2014, // ldr r2, [pc, #0x14] ; control
        0xEF00000B, // swi 0x0B (CpuSet)
        0xE59F3010, // ldr r3, [pc, #0x10] ; aligned dest base
        0xE5930000, // ldr r0, [r3]
        0xE12FFF1E, // bx lr
        0x0800002D, // source literal: align down to 0x0800002C
        0x03000002, // dest literal: align down to 0x03000000
        0x04000001, // one 32-bit unit, copy mode
        0x03000000, // aligned dest base literal
        42, // source word at 0x08000030
        0x12345678, // padding so buggy unaligned source reads stay in range
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuSetHalfwordAlignRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0014, // ldr r0, [pc, #0x14] ; misaligned source
        0xE59F1014, // ldr r1, [pc, #0x14] ; misaligned dest
        0xE59F2014, // ldr r2, [pc, #0x14] ; control
        0xEF00000B, // swi 0x0B (CpuSet)
        0xE59F3010, // ldr r3, [pc, #0x10] ; aligned dest base
        0xE1D300B0, // ldrh r0, [r3]
        0xE12FFF1E, // bx lr
        0x0800002D, // source literal: align down to 0x0800002C
        0x03000001, // dest literal: align down to 0x03000000
        0x00000001, // one 16-bit unit, copy mode
        0x03000000, // aligned dest base literal
        7, // source halfword in low bits at 0x08000030
        0x12345678, // padding so buggy unaligned source reads stay in range
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

test "arm startup bx r1 literal target resolves the measured commercial handoff shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both measured Kirby bx r1 handoffs live inside the base ARM startup entry routine.
    const cases = [_]struct {
        path: []const u8,
        startup_offset: usize,
        load_word: u32,
        literal_pc_offset: usize,
        literal: u32,
        bx_address: u32,
        expected_target: armv4t_decode.CodeAddress,
    }{
        .{
            .path = "advance-wars-startup.gba",
            .startup_offset = 0xD8,
            .load_word = 0xE59F1010,
            .literal_pc_offset = 16,
            .literal = 0x0800_0101,
            .bx_address = 0x0800_00E0,
            .expected_target = .{ .address = 0x0800_0100, .isa = .thumb },
        },
        .{
            .path = "kirby-startup.gba",
            .startup_offset = 0xE4,
            .load_word = 0xE59F112C,
            .literal_pc_offset = 300,
            .literal = 0x0800_0121,
            .bx_address = 0x0800_00EC,
            .expected_target = .{ .address = 0x0800_0120, .isa = .thumb },
        },
        .{
            .path = "kirby-startup-second-handoff.gba",
            .startup_offset = 0xF0,
            .load_word = 0xE59F1124,
            .literal_pc_offset = 292,
            .literal = 0x0800_7301,
            .bx_address = 0x0800_00F8,
            .expected_target = .{ .address = 0x0800_7300, .isa = .thumb },
        },
    };

    for (cases) |case| {
        try writeMeasuredCommercialStartupBxR1LiteralRom(
            tmp.dir,
            io,
            case.path,
            case.startup_offset,
            case.load_word,
            case.literal_pc_offset,
            case.literal,
            case.literal,
            0x4770,
        );

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", case.path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .bl = .{ .target = case.expected_target } },
            try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .arm }, case.bx_address, 1),
        );
    }
}

test "arm startup bx r1 literal resolver rejects near-miss shapes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        name: []const u8,
        load_word: u32,
        middle_word: u32,
        literal: u32,
    }{
        .{
            .name = "even-target",
            .load_word = 0xE59F1004,
            .middle_word = 0xE1A0E00F,
            .literal = 0x0800_0010,
        },
        .{
            .name = "missing-mov-lr-pc",
            .load_word = 0xE59F1004,
            .middle_word = 0xE1A00000,
            .literal = 0x0800_0011,
        },
        .{
            .name = "non-pc-load-base",
            .load_word = 0xE5911004,
            .middle_word = 0xE1A0E00F,
            .literal = 0x0800_0011,
        },
    };

    for (cases, 0..) |case, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "arm-startup-bx-r1-near-miss-{d}.gba", .{index});
        defer std.testing.allocator.free(path);

        var rom: [24]u8 = std.mem.zeroes([24]u8);
        std.mem.writeInt(u32, rom[0..4], case.load_word, .little);
        std.mem.writeInt(u32, rom[4..8], case.middle_word, .little);
        std.mem.writeInt(u32, rom[8..12], 0xE12FFF11, .little);
        std.mem.writeInt(u32, rom[12..16], case.literal, .little);
        std.mem.writeInt(u16, rom[16..18], 0x4770, .little);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = &rom });

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
            try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .arm }, 0x0800_0008, 1),
        );
    }
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

    try writeLocalThumbBlxRegVeneerRom(
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

test "local thumb blx r1 veneer resolves the caller literal target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLocalThumbBlxRegVeneerRom(
        tmp.dir,
        io,
        "local-blx-r1.gba",
        0x4903, // ldr r1, [pc, #12]
        0x4708, // bx r1
        0x46C0, // nop
        0x0800_0015,
    );

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "local-blx-r1.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_0014, .isa = .thumb } } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_0000, .isa = .thumb },
            0x0800_0004,
            .{ .bl = .{ .target = .{ .address = 0x0800_0008, .isa = .thumb } } },
        ),
    );
}

test "local thumb blx r3 veneer resolves measured stack-copied thunk source" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeMeasuredKirbyStackCopiedThunkRom(tmp.dir, io, "stack-copied-thunk.gba", 0x3301);

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "stack-copied-thunk.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_0000, .isa = .thumb } } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_0020, .isa = .thumb },
            0x0800_0060,
            .{ .bl = .{ .target = .{ .address = 0x0800_0068, .isa = .thumb } } },
        ),
    );
}

test "local thumb blx r3 stack-copied thunk resolver rejects near misses" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeMeasuredKirbyStackCopiedThunkRom(tmp.dir, io, "stack-copied-thunk-near-miss.gba", 0x3302);

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "stack-copied-thunk-near-miss.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_0068, .isa = .thumb } } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_0020, .isa = .thumb },
            0x0800_0060,
            .{ .bl = .{ .target = .{ .address = 0x0800_0068, .isa = .thumb } } },
        ),
    );
}

test "local thumb blx r0 veneer resolves measured Kirby IWRAM literal target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [0x1B10]u8 = std.mem.zeroes([0x1B10]u8);
    std.mem.writeInt(u32, rom[0x0878..0x087C], 0x0800_1B09, .little);
    std.mem.writeInt(u32, rom[0x087C..0x0880], 0x0300_1F40, .little);
    std.mem.writeInt(u16, rom[0x1A84..0x1A86], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x1A86..0x1A88], 0x4802, .little); // ldr r0, [pc, #8]
    std.mem.writeInt(u16, rom[0x1A8C..0x1A8E], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x1A8E..0x1A90], 0x4700, .little); // bx r0
    std.mem.writeInt(u32, rom[0x1A90..0x1A94], 0x0300_1F41, .little);
    std.mem.writeInt(u16, rom[0x1AA0..0x1AA2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x1AA2..0x1AA4], 0x46C0, .little); // nop
    std.mem.writeInt(u16, rom[0x1B08..0x1B0A], 0xB500, .little); // copied function source
    std.mem.writeInt(u16, rom[0x1B0A..0x1B0C], 0x4770, .little);
    try tmp.dir.writeFile(io, .{ .sub_path = "kirby-iwram-r0-literal.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "kirby-iwram-r0-literal.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_1B08, .isa = .thumb } } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_1A84, .isa = .thumb },
            0x0800_1A88,
            .{ .bl = .{ .target = .{ .address = 0x0800_1AA0, .isa = .thumb } } },
        ),
    );
}

test "local thumb blx r0 Kirby IWRAM literal resolver rejects table mismatch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [0x1B10]u8 = std.mem.zeroes([0x1B10]u8);
    std.mem.writeInt(u32, rom[0x0878..0x087C], 0x0800_1B0D, .little);
    std.mem.writeInt(u32, rom[0x087C..0x0880], 0x0300_1F40, .little);
    std.mem.writeInt(u16, rom[0x1A84..0x1A86], 0xB500, .little);
    std.mem.writeInt(u16, rom[0x1A86..0x1A88], 0x4802, .little);
    std.mem.writeInt(u16, rom[0x1A8C..0x1A8E], 0xBC01, .little);
    std.mem.writeInt(u16, rom[0x1A8E..0x1A90], 0x4700, .little);
    std.mem.writeInt(u32, rom[0x1A90..0x1A94], 0x0300_1F41, .little);
    std.mem.writeInt(u16, rom[0x1AA0..0x1AA2], 0x4700, .little);
    std.mem.writeInt(u16, rom[0x1AA2..0x1AA4], 0x46C0, .little);
    try tmp.dir.writeFile(io, .{ .sub_path = "kirby-iwram-r0-literal-near-miss.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "kirby-iwram-r0-literal-near-miss.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_1AA0, .isa = .thumb } } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_1A84, .isa = .thumb },
            0x0800_1A88,
            .{ .bl = .{ .target = .{ .address = 0x0800_1AA0, .isa = .thumb } } },
        ),
    );
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

        try writeLocalThumbBlxRegVeneerRom(
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
            .local_occurrence = "Unsupported opcode 0x0000468F at 0x08002240 for armv4t",
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

test "kirby measured IWRAM overlay code span maps copied target to ROM" {
    const rom_len = 0x0CE5E0;
    var rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u32, rom[0x0CD918..][0..4], 0x0300_7FF0, .little);
    std.mem.writeInt(u32, rom[0x0CE5B0..][0..4], 0x080C_D931, .little);
    std.mem.writeInt(u32, rom[0x0CE5B4..][0..4], 0x0300_7150, .little);
    std.mem.writeInt(u32, rom[0x0CE5B8..][0..4], 0x0400_0100, .little);
    std.mem.writeInt(u16, rom[0x0CD912..][0..2], 0x4B03, .little); // ldr r3, [pc, #12]
    std.mem.writeInt(u16, rom[0x0CD914..][0..2], 0x4718, .little); // bx r3
    std.mem.writeInt(u32, rom[0x0CD920..][0..4], 0x0300_7151, .little);

    const image = gba_loader.RomImage{ .bytes = rom };
    try std.testing.expectEqual(@as(?usize, 0x0CD8AC), offsetForAddress(image, 0x0300_70CC, .thumb));
    try std.testing.expectEqual(@as(?usize, 0x0CD930), offsetForAddress(image, 0x0300_7150, .thumb));
    try std.testing.expectEqual(@as(?usize, 0x0CD93C), offsetForAddress(image, 0x0300_715C, .arm));
    try std.testing.expectEqual(@as(?usize, 0x0CE5D4), offsetForAddress(image, 0x0300_7DF4, .thumb));
    try std.testing.expectEqual(@as(?usize, null), offsetForAddress(image, 0x0300_7FF0, .thumb));
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_target = .{ .address = 0x0300_7150, .isa = .thumb } },
        try resolveBxTarget(image, .{ .address = 0x0300_70CC, .isa = .thumb }, 0x0300_7134, 3),
    );

    std.mem.writeInt(u32, rom[0x0CE5B4..][0..4], 0x0300_7154, .little);
    try std.testing.expectEqual(@as(?usize, null), offsetForAddress(image, 0x0300_7150, .thumb));
}

test "kirby measured IWRAM overlay runtime helper is enqueued for dispatch" {
    const rom_len = 0x0CE5E0;
    var rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u32, rom[0x0CD918..][0..4], 0x0300_7FF0, .little);
    std.mem.writeInt(u32, rom[0x0CE5B0..][0..4], 0x080C_D931, .little);
    std.mem.writeInt(u32, rom[0x0CE5B4..][0..4], 0x0300_7150, .little);
    std.mem.writeInt(u32, rom[0x0CE5B8..][0..4], 0x0400_0100, .little);

    const image = gba_loader.RomImage{ .bytes = rom };
    var pending: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending.deinit(std.testing.allocator);

    try std.testing.expect(try enqueueMeasuredKirbyOverlayRuntimeTargets(
        std.testing.allocator,
        &pending,
        image,
        &.{},
    ));
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0300_7DF4, .isa = .thumb },
        pending.items[0],
    );
}

test "kirby measured IRQ handler code span maps copied target to ROM" {
    var rom: [0x800]u8 = std.mem.zeroes([0x800]u8);
    std.mem.writeInt(u32, rom[0x0730..0x0734], 0x0800_0108, .little);
    std.mem.writeInt(u32, rom[0x0734..0x0738], 0x0300_1030, .little);
    std.mem.writeInt(u32, rom[0x0738..0x073C], 0x0300_7FFC, .little);
    std.mem.writeInt(u32, rom[0x0108..0x010C], 0xE3A0_0001, .little);

    const image = gba_loader.RomImage{ .bytes = &rom };
    try std.testing.expectEqual(@as(?usize, 0x0108), offsetForAddress(image, 0x0300_1030, .arm));
    try std.testing.expectEqual(@as(?usize, 0x0234), offsetForAddress(image, 0x0300_115C, .arm));
    try std.testing.expectEqual(@as(?usize, null), offsetForAddress(image, 0x0300_1160, .arm));

    std.mem.writeInt(u32, rom[0x0738..0x073C], 0x0300_7FF8, .little);
    try std.testing.expectEqual(@as(?usize, null), offsetForAddress(image, 0x0300_1030, .arm));
}

test "kirby measured IRQ handler runtime target is enqueued for dispatch" {
    var rom: [0x800]u8 = std.mem.zeroes([0x800]u8);
    std.mem.writeInt(u32, rom[0x0730..0x0734], 0x0800_0108, .little);
    std.mem.writeInt(u32, rom[0x0734..0x0738], 0x0300_1030, .little);
    std.mem.writeInt(u32, rom[0x0738..0x073C], 0x0300_7FFC, .little);

    const image = gba_loader.RomImage{ .bytes = &rom };
    var pending: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending.deinit(std.testing.allocator);

    try std.testing.expect(try enqueueMeasuredKirbyIrqHandlerRuntimeTarget(
        std.testing.allocator,
        &pending,
        image,
        &.{},
    ));
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0300_1030, .isa = .arm },
        pending.items[0],
    );
}

test "kirby measured interworking callback target is enqueued for dispatch" {
    const rom_len = 0x7306A0;
    var rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u32, rom[0x72FF34..][0..4], 0x0800_93FD, .little);
    std.mem.writeInt(u32, rom[0x730698..][0..4], 0x0000_0004, .little);
    std.mem.writeInt(u32, rom[0x73069C..][0..4], 0x0800_99FD, .little);
    std.mem.writeInt(u16, rom[0x93FC..][0..2], 0xB500, .little);
    std.mem.writeInt(u16, rom[0x9640..][0..2], 0xB510, .little);
    std.mem.writeInt(u32, rom[0x9678..][0..4], 0x0800_59D9, .little);
    std.mem.writeInt(u32, rom[0x967C..][0..4], 0x0800_5CA1, .little);
    std.mem.writeInt(u16, rom[0x59D8..][0..2], 0xB500, .little);
    std.mem.writeInt(u16, rom[0x5CA0..][0..2], 0xB570, .little);
    std.mem.writeInt(u16, rom[0x99FC..][0..2], 0xB570, .little);

    const image = gba_loader.RomImage{ .bytes = rom };
    var pending: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending.deinit(std.testing.allocator);

    try std.testing.expect(try enqueueMeasuredKirbyInterworkingCallbackTarget(
        std.testing.allocator,
        &pending,
        image,
        &.{},
    ));
    try std.testing.expectEqual(@as(usize, 4), pending.items.len);
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_93FC, .isa = .thumb },
        pending.items[0],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_59D8, .isa = .thumb },
        pending.items[1],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_5CA0, .isa = .thumb },
        pending.items[2],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_99FC, .isa = .thumb },
        pending.items[3],
    );

    std.mem.writeInt(u32, rom[0x72FF34..][0..4], 0x0800_9419, .little);
    std.mem.writeInt(u32, rom[0x9678..][0..4], 0x0800_9419, .little);
    std.mem.writeInt(u32, rom[0x967C..][0..4], 0x0800_9419, .little);
    std.mem.writeInt(u32, rom[0x73069C..][0..4], 0x0800_9419, .little);
    try std.testing.expect(!try enqueueMeasuredKirbyInterworkingCallbackTarget(
        std.testing.allocator,
        &pending,
        image,
        &.{},
    ));
}

test "kirby measured coroutine resume continuation target is enqueued for dispatch" {
    const rom_len = 0x0CFDD4;
    var rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u16, rom[0x5364..][0..2], 0xF0CA, .little); // bl 0x080CFDC4, first half
    std.mem.writeInt(u16, rom[0x5366..][0..2], 0xFD2E, .little); // bl 0x080CFDC4, second half
    std.mem.writeInt(u16, rom[0x0CFDC4..][0..2], 0x4778, .little); // bx pc
    std.mem.writeInt(u16, rom[0x0CFDC6..][0..2], 0x46C0, .little); // nop
    std.mem.writeInt(u32, rom[0x0CFDC8..][0..4], 0xEAFC_C119, .little); // b 0x08000234
    std.mem.writeInt(u16, rom[0x940E..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x9410..][0..2], 0xFCDD, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x0CFDCC..][0..2], 0x4778, .little); // bx pc
    std.mem.writeInt(u16, rom[0x0CFDCE..][0..2], 0x46C0, .little); // nop
    std.mem.writeInt(u32, rom[0x0CFDD0..][0..4], 0xEAFC_C120, .little); // b 0x08000258
    std.mem.writeInt(u16, rom[0x22E4..][0..2], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x22E6..][0..2], 0xF002, .little); // bl 0x08005228, first half
    std.mem.writeInt(u16, rom[0x22E8..][0..2], 0xFF9F, .little); // bl 0x08005228, second half
    std.mem.writeInt(u16, rom[0x22F6..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x22F8..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x91AC..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x91AE..][0..2], 0xF000, .little); // bl 0x08009200, first half
    std.mem.writeInt(u16, rom[0x91B0..][0..2], 0xF827, .little); // bl 0x08009200, second half
    std.mem.writeInt(u16, rom[0x91F6..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x91F8..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x91FA..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x739C..][0..2], 0xF001, .little); // bl 0x080091AC, first half
    std.mem.writeInt(u16, rom[0x739E..][0..2], 0xFF06, .little); // bl 0x080091AC, second half
    std.mem.writeInt(u16, rom[0x95C0..][0..2], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x95E0..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x95E2..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x2D54..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x2D64..][0..2], 0xF7FF, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x2D66..][0..2], 0xFABE, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x2D6E..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x2D70..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x2D72..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x2DB4..][0..2], 0xB510, .little); // push {r4, lr}
    std.mem.writeInt(u16, rom[0x2DC0..][0..2], 0xF7FF, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x2DC2..][0..2], 0xFA90, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x2DD0..][0..2], 0xBC10, .little); // pop {r4}
    std.mem.writeInt(u16, rom[0x2DD2..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x2DD4..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x9200..][0..2], 0xB570, .little); // push {r4, r5, r6, lr}
    std.mem.writeInt(u16, rom[0x9202..][0..2], 0x4656, .little); // mov r6, sl
    std.mem.writeInt(u16, rom[0x9204..][0..2], 0x464D, .little); // mov r5, r9
    std.mem.writeInt(u16, rom[0x9206..][0..2], 0x4644, .little); // mov r4, r8
    std.mem.writeInt(u16, rom[0x9208..][0..2], 0xB470, .little); // push {r4, r5, r6}
    std.mem.writeInt(u16, rom[0x9298..][0..2], 0xF7F9, .little); // bl 0x08002D54, first half
    std.mem.writeInt(u16, rom[0x929A..][0..2], 0xFD5C, .little); // bl 0x08002D54, second half
    std.mem.writeInt(u16, rom[0x92A4..][0..2], 0xF000, .little); // bl 0x08009398, first half
    std.mem.writeInt(u16, rom[0x92A6..][0..2], 0xF878, .little); // bl 0x08009398, second half
    std.mem.writeInt(u16, rom[0x92B4..][0..2], 0xF000, .little); // bl 0x08009398, first half
    std.mem.writeInt(u16, rom[0x92B6..][0..2], 0xF870, .little); // bl 0x08009398, second half
    std.mem.writeInt(u16, rom[0x92D2..][0..2], 0xF000, .little); // bl 0x08009398, first half
    std.mem.writeInt(u16, rom[0x92D4..][0..2], 0xF861, .little); // bl 0x08009398, second half
    std.mem.writeInt(u16, rom[0x9340..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x9342..][0..2], 0xFFD0, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x936C..][0..2], 0xBC38, .little); // pop {r3, r4, r5}
    std.mem.writeInt(u16, rom[0x936E..][0..2], 0x4698, .little); // mov r8, r3
    std.mem.writeInt(u16, rom[0x9370..][0..2], 0x46A1, .little); // mov r9, r4
    std.mem.writeInt(u16, rom[0x9372..][0..2], 0x46AA, .little); // mov sl, r5
    std.mem.writeInt(u16, rom[0x9374..][0..2], 0xBC70, .little); // pop {r4, r5, r6}
    std.mem.writeInt(u16, rom[0x9376..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x9378..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x9398..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x93B8..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x93BA..][0..2], 0xFF94, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x93C4..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x93C6..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x93C8..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x9418..][0..2], 0xB5F0, .little); // push {r4, r5, r6, r7, lr}
    std.mem.writeInt(u16, rom[0x941A..][0..2], 0x4647, .little); // mov r7, r8
    std.mem.writeInt(u16, rom[0x941C..][0..2], 0xB480, .little); // push {r7}
    std.mem.writeInt(u16, rom[0x944A..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x944C..][0..2], 0xFCBF, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x94C8..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x94CA..][0..2], 0xFC80, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x9532..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x9534..][0..2], 0xFC4B, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x9586..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x9588..][0..2], 0xFC21, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x95EC..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x95EE..][0..2], 0xFBEE, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x9618..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x961A..][0..2], 0xFBD8, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x96A2..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x96A4..][0..2], 0xFB93, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x96B0..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x96B2..][0..2], 0xFB8C, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x96BE..][0..2], 0xF0C6, .little); // bl 0x080CFDCC, first half
    std.mem.writeInt(u16, rom[0x96C0..][0..2], 0xFB85, .little); // bl 0x080CFDCC, second half
    std.mem.writeInt(u16, rom[0x96E0..][0..2], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x96E8..][0..2], 0xF000, .little); // bl 0x0800973C, first half
    std.mem.writeInt(u16, rom[0x96EA..][0..2], 0xF828, .little); // bl 0x0800973C, second half
    std.mem.writeInt(u16, rom[0x971C..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x971E..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x973C..][0..2], 0xB5F0, .little); // push {r4, r5, r6, r7, lr}
    std.mem.writeInt(u16, rom[0x973E..][0..2], 0x464F, .little); // mov r7, r9
    std.mem.writeInt(u16, rom[0x9740..][0..2], 0x4646, .little); // mov r6, r8
    std.mem.writeInt(u16, rom[0x9742..][0..2], 0xB4C0, .little); // push {r6, r7}
    std.mem.writeInt(u16, rom[0x985E..][0..2], 0xF7F9, .little); // bl 0x08002D54, first half
    std.mem.writeInt(u16, rom[0x9860..][0..2], 0xFA79, .little); // bl 0x08002D54, second half
    std.mem.writeInt(u16, rom[0x9870..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x9872..][0..2], 0xFD38, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x9892..][0..2], 0xF7F9, .little); // bl 0x08002DB4, first half
    std.mem.writeInt(u16, rom[0x9894..][0..2], 0xFA8F, .little); // bl 0x08002DB4, second half
    std.mem.writeInt(u16, rom[0x9898..][0..2], 0xBC18, .little); // pop {r3, r4}
    std.mem.writeInt(u16, rom[0x989A..][0..2], 0x4698, .little); // mov r8, r3
    std.mem.writeInt(u16, rom[0x989C..][0..2], 0x46A1, .little); // mov r9, r4
    std.mem.writeInt(u16, rom[0x989E..][0..2], 0xBCF0, .little); // pop {r4, r5, r6, r7}
    std.mem.writeInt(u16, rom[0x98A0..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x98A2..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x98A8..][0..2], 0xB5F0, .little); // push {r4, r5, r6, r7, lr}
    std.mem.writeInt(u16, rom[0x98AA..][0..2], 0x4657, .little); // mov r7, sl
    std.mem.writeInt(u16, rom[0x98AC..][0..2], 0x464E, .little); // mov r6, r9
    std.mem.writeInt(u16, rom[0x98AE..][0..2], 0x4645, .little); // mov r5, r8
    std.mem.writeInt(u16, rom[0x98B0..][0..2], 0xB4E0, .little); // push {r5, r6, r7}
    std.mem.writeInt(u16, rom[0x992E..][0..2], 0xF000, .little); // bl 0x080099C8, first half
    std.mem.writeInt(u16, rom[0x9930..][0..2], 0xF84B, .little); // bl 0x080099C8, second half
    std.mem.writeInt(u16, rom[0x9994..][0..2], 0xBC38, .little); // pop {r3, r4, r5}
    std.mem.writeInt(u16, rom[0x9996..][0..2], 0x4698, .little); // mov r8, r3
    std.mem.writeInt(u16, rom[0x9998..][0..2], 0x46A1, .little); // mov r9, r4
    std.mem.writeInt(u16, rom[0x999A..][0..2], 0x46AA, .little); // mov sl, r5
    std.mem.writeInt(u16, rom[0x999C..][0..2], 0xBCF0, .little); // pop {r4, r5, r6, r7}
    std.mem.writeInt(u16, rom[0x999E..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x99A0..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x99C8..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x99E8..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x99EA..][0..2], 0xFC7C, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x99F4..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x99F6..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x99F8..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x959C..][0..2], 0xE7D7, .little); // b 0x0800954E

    const image = gba_loader.RomImage{ .bytes = rom };
    var pending: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending.deinit(std.testing.allocator);

    try std.testing.expect(try enqueueMeasuredKirbyCoroutineResumeTargets(
        std.testing.allocator,
        &pending,
        image,
        &.{},
    ));
    try std.testing.expectEqual(@as(usize, 30), pending.items.len);
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_5368, .isa = .thumb },
        pending.items[0],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9412, .isa = .thumb },
        pending.items[1],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9418, .isa = .thumb },
        pending.items[2],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_944E, .isa = .thumb },
        pending.items[3],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_94CC, .isa = .thumb },
        pending.items[4],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9536, .isa = .thumb },
        pending.items[5],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_958A, .isa = .thumb },
        pending.items[6],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_95F0, .isa = .thumb },
        pending.items[7],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_961C, .isa = .thumb },
        pending.items[8],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_96A6, .isa = .thumb },
        pending.items[9],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_96B4, .isa = .thumb },
        pending.items[10],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_96C2, .isa = .thumb },
        pending.items[11],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_96EC, .isa = .thumb },
        pending.items[12],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9862, .isa = .thumb },
        pending.items[13],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9874, .isa = .thumb },
        pending.items[14],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9896, .isa = .thumb },
        pending.items[15],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9932, .isa = .thumb },
        pending.items[16],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_99EC, .isa = .thumb },
        pending.items[17],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_22EA, .isa = .thumb },
        pending.items[18],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_2D68, .isa = .thumb },
        pending.items[19],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_2DC4, .isa = .thumb },
        pending.items[20],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_929C, .isa = .thumb },
        pending.items[21],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_92A8, .isa = .thumb },
        pending.items[22],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_92B8, .isa = .thumb },
        pending.items[23],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_92D6, .isa = .thumb },
        pending.items[24],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_9344, .isa = .thumb },
        pending.items[25],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_93BC, .isa = .thumb },
        pending.items[26],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_91B2, .isa = .thumb },
        pending.items[27],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_73A0, .isa = .thumb },
        pending.items[28],
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.CodeAddress{ .address = 0x0800_95C0, .isa = .thumb },
        pending.items[29],
    );

    std.mem.writeInt(u16, rom[0x5366..][0..2], 0xFD2C, .little);
    try std.testing.expect(!try enqueueMeasuredKirbyCoroutineResumeTargets(
        std.testing.allocator,
        &pending,
        image,
        &.{},
    ));
}

test "kirby measured coroutine resume function keeps popped return dynamic" {
    var rom: [0x55A0]u8 = std.mem.zeroes([0x55A0]u8);
    std.mem.writeInt(u16, rom[0x559C..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x559E..][0..2], 0x4700, .little); // bx r0

    const image = gba_loader.RomImage{ .bytes = &rom };
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_5368, .isa = .thumb }, 0x0800_559E, 0),
    );

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_5300, .isa = .thumb }, 0x0800_559E, 0),
    );
}

test "kirby measured coroutine switch entry keeps popped return dynamic" {
    var rom: [0x95E4]u8 = std.mem.zeroes([0x95E4]u8);
    std.mem.writeInt(u16, rom[0x95C0..][0..2], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x95E0..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x95E2..][0..2], 0x4700, .little); // bx r0

    const image = gba_loader.RomImage{ .bytes = &rom };
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_95C0, .isa = .thumb }, 0x0800_95E2, 0),
    );

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_95C2, .isa = .thumb }, 0x0800_95E2, 0),
    );
}

test "kirby measured coroutine caller continuations keep popped returns dynamic" {
    var rom: [0x99FA]u8 = std.mem.zeroes([0x99FA]u8);
    std.mem.writeInt(u16, rom[0x22E4..][0..2], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x22E6..][0..2], 0xF002, .little); // bl 0x08005228, first half
    std.mem.writeInt(u16, rom[0x22E8..][0..2], 0xFF9F, .little); // bl 0x08005228, second half
    std.mem.writeInt(u16, rom[0x22F6..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x22F8..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x91AC..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x91AE..][0..2], 0xF000, .little); // bl 0x08009200, first half
    std.mem.writeInt(u16, rom[0x91B0..][0..2], 0xF827, .little); // bl 0x08009200, second half
    std.mem.writeInt(u16, rom[0x91F6..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x91F8..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x91FA..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x2D54..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x2D64..][0..2], 0xF7FF, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x2D66..][0..2], 0xFABE, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x2D6E..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x2D70..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x2D72..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x2DB4..][0..2], 0xB510, .little); // push {r4, lr}
    std.mem.writeInt(u16, rom[0x2DC0..][0..2], 0xF7FF, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x2DC2..][0..2], 0xFA90, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x2DD0..][0..2], 0xBC10, .little); // pop {r4}
    std.mem.writeInt(u16, rom[0x2DD2..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x2DD4..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x96E0..][0..2], 0xB500, .little); // push {lr}
    std.mem.writeInt(u16, rom[0x96E8..][0..2], 0xF000, .little); // bl 0x0800973C, first half
    std.mem.writeInt(u16, rom[0x96EA..][0..2], 0xF828, .little); // bl 0x0800973C, second half
    std.mem.writeInt(u16, rom[0x971C..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x971E..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x9200..][0..2], 0xB570, .little); // push {r4, r5, r6, lr}
    std.mem.writeInt(u16, rom[0x9202..][0..2], 0x4656, .little); // mov r6, sl
    std.mem.writeInt(u16, rom[0x9204..][0..2], 0x464D, .little); // mov r5, r9
    std.mem.writeInt(u16, rom[0x9206..][0..2], 0x4644, .little); // mov r4, r8
    std.mem.writeInt(u16, rom[0x9208..][0..2], 0xB470, .little); // push {r4, r5, r6}
    std.mem.writeInt(u16, rom[0x9298..][0..2], 0xF7F9, .little); // bl 0x08002D54, first half
    std.mem.writeInt(u16, rom[0x929A..][0..2], 0xFD5C, .little); // bl 0x08002D54, second half
    std.mem.writeInt(u16, rom[0x92A4..][0..2], 0xF000, .little); // bl 0x08009398, first half
    std.mem.writeInt(u16, rom[0x92A6..][0..2], 0xF878, .little); // bl 0x08009398, second half
    std.mem.writeInt(u16, rom[0x92B4..][0..2], 0xF000, .little); // bl 0x08009398, first half
    std.mem.writeInt(u16, rom[0x92B6..][0..2], 0xF870, .little); // bl 0x08009398, second half
    std.mem.writeInt(u16, rom[0x92D2..][0..2], 0xF000, .little); // bl 0x08009398, first half
    std.mem.writeInt(u16, rom[0x92D4..][0..2], 0xF861, .little); // bl 0x08009398, second half
    std.mem.writeInt(u16, rom[0x9340..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x9342..][0..2], 0xFFD0, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x936C..][0..2], 0xBC38, .little); // pop {r3, r4, r5}
    std.mem.writeInt(u16, rom[0x936E..][0..2], 0x4698, .little); // mov r8, r3
    std.mem.writeInt(u16, rom[0x9370..][0..2], 0x46A1, .little); // mov r9, r4
    std.mem.writeInt(u16, rom[0x9372..][0..2], 0x46AA, .little); // mov sl, r5
    std.mem.writeInt(u16, rom[0x9374..][0..2], 0xBC70, .little); // pop {r4, r5, r6}
    std.mem.writeInt(u16, rom[0x9376..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x9378..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x9398..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x93B8..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x93BA..][0..2], 0xFF94, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x93C4..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x93C6..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x93C8..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x973C..][0..2], 0xB5F0, .little); // push {r4, r5, r6, r7, lr}
    std.mem.writeInt(u16, rom[0x973E..][0..2], 0x464F, .little); // mov r7, r9
    std.mem.writeInt(u16, rom[0x9740..][0..2], 0x4646, .little); // mov r6, r8
    std.mem.writeInt(u16, rom[0x9742..][0..2], 0xB4C0, .little); // push {r6, r7}
    std.mem.writeInt(u16, rom[0x985E..][0..2], 0xF7F9, .little); // bl 0x08002D54, first half
    std.mem.writeInt(u16, rom[0x9860..][0..2], 0xFA79, .little); // bl 0x08002D54, second half
    std.mem.writeInt(u16, rom[0x9870..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x9872..][0..2], 0xFD38, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x9892..][0..2], 0xF7F9, .little); // bl 0x08002DB4, first half
    std.mem.writeInt(u16, rom[0x9894..][0..2], 0xFA8F, .little); // bl 0x08002DB4, second half
    std.mem.writeInt(u16, rom[0x9898..][0..2], 0xBC18, .little); // pop {r3, r4}
    std.mem.writeInt(u16, rom[0x989A..][0..2], 0x4698, .little); // mov r8, r3
    std.mem.writeInt(u16, rom[0x989C..][0..2], 0x46A1, .little); // mov r9, r4
    std.mem.writeInt(u16, rom[0x989E..][0..2], 0xBCF0, .little); // pop {r4, r5, r6, r7}
    std.mem.writeInt(u16, rom[0x98A0..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x98A2..][0..2], 0x4708, .little); // bx r1
    std.mem.writeInt(u16, rom[0x98A8..][0..2], 0xB5F0, .little); // push {r4, r5, r6, r7, lr}
    std.mem.writeInt(u16, rom[0x98AA..][0..2], 0x4657, .little); // mov r7, sl
    std.mem.writeInt(u16, rom[0x98AC..][0..2], 0x464E, .little); // mov r6, r9
    std.mem.writeInt(u16, rom[0x98AE..][0..2], 0x4645, .little); // mov r5, r8
    std.mem.writeInt(u16, rom[0x98B0..][0..2], 0xB4E0, .little); // push {r5, r6, r7}
    std.mem.writeInt(u16, rom[0x992E..][0..2], 0xF000, .little); // bl 0x080099C8, first half
    std.mem.writeInt(u16, rom[0x9930..][0..2], 0xF84B, .little); // bl 0x080099C8, second half
    std.mem.writeInt(u16, rom[0x9994..][0..2], 0xBC38, .little); // pop {r3, r4, r5}
    std.mem.writeInt(u16, rom[0x9996..][0..2], 0x4698, .little); // mov r8, r3
    std.mem.writeInt(u16, rom[0x9998..][0..2], 0x46A1, .little); // mov r9, r4
    std.mem.writeInt(u16, rom[0x999A..][0..2], 0x46AA, .little); // mov sl, r5
    std.mem.writeInt(u16, rom[0x999C..][0..2], 0xBCF0, .little); // pop {r4, r5, r6, r7}
    std.mem.writeInt(u16, rom[0x999E..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[0x99A0..][0..2], 0x4700, .little); // bx r0
    std.mem.writeInt(u16, rom[0x99C8..][0..2], 0xB530, .little); // push {r4, r5, lr}
    std.mem.writeInt(u16, rom[0x99E8..][0..2], 0xF7F8, .little); // bl 0x080022E4, first half
    std.mem.writeInt(u16, rom[0x99EA..][0..2], 0xFC7C, .little); // bl 0x080022E4, second half
    std.mem.writeInt(u16, rom[0x99F4..][0..2], 0xBC30, .little); // pop {r4, r5}
    std.mem.writeInt(u16, rom[0x99F6..][0..2], 0xBC02, .little); // pop {r1}
    std.mem.writeInt(u16, rom[0x99F8..][0..2], 0x4708, .little); // bx r1

    const image = gba_loader.RomImage{ .bytes = &rom };
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_22EA, .isa = .thumb }, 0x0800_22F8, 0),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_2D68, .isa = .thumb }, 0x0800_2D72, 0),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_2DC4, .isa = .thumb }, 0x0800_2DD4, 0),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_96EC, .isa = .thumb }, 0x0800_971E, 0),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_91B2, .isa = .thumb }, 0x0800_91FA, 0),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_929C, .isa = .thumb }, 0x0800_9378, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_92A8, .isa = .thumb }, 0x0800_9378, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_92B8, .isa = .thumb }, 0x0800_9378, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_92D6, .isa = .thumb }, 0x0800_9378, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_9344, .isa = .thumb }, 0x0800_9378, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_93BC, .isa = .thumb }, 0x0800_93C8, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_9862, .isa = .thumb }, 0x0800_98A2, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_9874, .isa = .thumb }, 0x0800_98A2, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_9896, .isa = .thumb }, 0x0800_98A2, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_9932, .isa = .thumb }, 0x0800_99A0, 0),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_99EC, .isa = .thumb }, 0x0800_99F8, 1),
    );

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_22EC, .isa = .thumb }, 0x0800_22F8, 0),
    );
}

test "kirby measured IRQ dispatcher bx r0 resolves VBlank handler target" {
    const rom_len = 0x0CFE00;
    var rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u32, rom[0x0730..][0..4], 0x0800_0108, .little);
    std.mem.writeInt(u32, rom[0x0734..][0..4], 0x0300_1030, .little);
    std.mem.writeInt(u32, rom[0x0738..][0..4], 0x0300_7FFC, .little);
    std.mem.writeInt(u32, rom[0x01C8..][0..4], 0xE92D_4000, .little); // stmfd sp!, {lr}
    std.mem.writeInt(u32, rom[0x01CC..][0..4], 0xE28F_E000, .little); // add lr, pc, #0
    std.mem.writeInt(u32, rom[0x01D0..][0..4], 0xE12F_FF10, .little); // bx r0
    std.mem.writeInt(u32, rom[0x0CFDE8..][0..4], 0x0800_1519, .little);
    std.mem.writeInt(u32, rom[0x0CFDEC..][0..4], 0x0800_1519, .little);
    std.mem.writeInt(u32, rom[0x0CFDF0..][0..4], 0x0800_10CD, .little);
    std.mem.writeInt(u16, rom[0x10CC..][0..2], 0xB500, .little); // push {lr}

    const image = gba_loader.RomImage{ .bytes = rom };
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_10CC, .isa = .thumb } } },
        try resolveBxTarget(image, .{ .address = 0x0300_1030, .isa = .arm }, 0x0300_10F8, 0),
    );

    std.mem.writeInt(u32, rom[0x0738..][0..4], 0x0300_7FF8, .little);
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0300_1030, .isa = .arm }, 0x0300_10F8, 0),
    );
}

test "thumb bx-pc arm branch veneer resolves to the arm branch target" {
    var rom: [0x238]u8 = std.mem.zeroes([0x238]u8);
    std.mem.writeInt(u16, rom[0x08..][0..2], 0x4778, .little); // bx pc
    std.mem.writeInt(u16, rom[0x0A..][0..2], 0x46C0, .little); // nop
    std.mem.writeInt(u32, rom[0x0C..][0..4], 0xEA00_0088, .little); // b 0x08000234
    std.mem.writeInt(u32, rom[0x234..][0..4], 0xE12F_FF1E, .little); // bx lr

    const image = gba_loader.RomImage{ .bytes = &rom };
    const bl = armv4t_decode.DecodedInstruction{ .bl = .{
        .target = .{ .address = 0x0800_0008, .isa = .thumb },
    } };

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bl = .{ .target = .{ .address = 0x0800_0234, .isa = .arm } } },
        try resolveDecodedInstruction(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0000, bl),
    );

    std.mem.writeInt(u16, rom[0x0A..][0..2], 0x0000, .little);
    try std.testing.expectEqualDeep(
        bl,
        try resolveDecodedInstruction(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0000, bl),
    );
}

test "kirby arm interworking trampoline keeps bx r1 dynamic" {
    var rom: [0x258]u8 = std.mem.zeroes([0x258]u8);
    std.mem.writeInt(u32, rom[0x24C..][0..4], 0xE3A0_2001, .little); // mov r2, #1
    std.mem.writeInt(u32, rom[0x250..][0..4], 0xE181_1002, .little); // orr r1, r1, r2
    std.mem.writeInt(u32, rom[0x254..][0..4], 0xE12F_FF11, .little); // bx r1

    const image = gba_loader.RomImage{ .bytes = &rom };
    const decoded = armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } };
    try std.testing.expectEqualDeep(
        decoded,
        try resolveDecodedInstruction(image, .{ .address = 0x0800_0234, .isa = .arm }, 0x0800_0254, decoded),
    );

    try std.testing.expectEqualDeep(
        decoded,
        try resolveDecodedInstruction(image, .{ .address = 0x0800_0200, .isa = .arm }, 0x0800_0254, decoded),
    );
}

test "kirby arm coroutine pop-r1 bx-r1 exits stay dynamic" {
    var rom: [0x2A8]u8 = std.mem.zeroes([0x2A8]u8);
    std.mem.writeInt(u32, rom[0x280..][0..4], 0xE8BD_0002, .little); // ldmfd sp!, {r1}
    std.mem.writeInt(u32, rom[0x284..][0..4], 0xE12F_FF11, .little); // bx r1
    std.mem.writeInt(u32, rom[0x2A0..][0..4], 0xE8BD_0002, .little); // ldmfd sp!, {r1}
    std.mem.writeInt(u32, rom[0x2A4..][0..4], 0xE12F_FF11, .little); // bx r1

    const image = gba_loader.RomImage{ .bytes = &rom };
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_0258, .isa = .arm }, 0x0800_0284, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_0258, .isa = .arm }, 0x0800_02A4, 1),
    );
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_0288, .isa = .arm }, 0x0800_02A4, 1),
    );

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveBxTarget(image, .{ .address = 0x0800_0200, .isa = .arm }, 0x0800_0284, 1),
    );
}

test "kirby arm bx-ip literal veneer resolves measured target" {
    var rom: [0x0CFDE8]u8 = std.mem.zeroes([0x0CFDE8]u8);
    std.mem.writeInt(u32, rom[0x0CFDDC..][0..4], 0xE59F_C000, .little); // ldr ip, [pc]
    std.mem.writeInt(u32, rom[0x0CFDE0..][0..4], 0xE12F_FF1C, .little); // bx ip
    std.mem.writeInt(u32, rom[0x0CFDE4..][0..4], 0x0800_5655, .little);
    std.mem.writeInt(u16, rom[0x5654..][0..2], 0xB500, .little); // push {lr}

    const image = gba_loader.RomImage{ .bytes = &rom };
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_target = .{ .address = 0x0800_5654, .isa = .thumb } },
        try resolveBxTarget(image, .{ .address = 0x080C_FDDC, .isa = .arm }, 0x080C_FDE0, 12),
    );

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 12 } },
        try resolveBxTarget(image, .{ .address = 0x080C_FDD8, .isa = .arm }, 0x080C_FDE0, 12),
    );
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

test "thumb mov-ip-lr bx-ip helper resolves as a saved-lr return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0xF4, 0x46, // mov ip, lr
        0x00, 0x20, // movs r0, #0
        0x60, 0x47, // bx ip
        0x00, 0x00,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-mov-ip-lr-bx-ip-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-mov-ip-lr-bx-ip-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0004, 12);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb pop-r4-r5 pop-r0 bx-r0 table helper tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x20, // movs r0, #0
        0x30, 0xBC, // pop {r4, r5}
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r4-r5-pop-r0-bx-r0-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r4-r5-pop-r0-bx-r0-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb pop-r4 pop-r0 bx-r0 table helper tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x20, // movs r0, #0
        0x10, 0xBC, // pop {r4}
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r4-pop-r0-bx-r0-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r4-pop-r0-bx-r0-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb pop-r4-r5-r6 pop-r0 bx-r0 table helper tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x20, // movs r0, #0
        0x70, 0xBC, // pop {r4, r5, r6}
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r4-r5-r6-pop-r0-bx-r0-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r4-r5-r6-pop-r0-bx-r0-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb pop-r4-r5-r6-r7 pop-r0 bx-r0 table helper tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x20, // movs r0, #0
        0xF0, 0xBC, // pop {r4, r5, r6, r7}
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r4-r5-r6-r7-pop-r0-bx-r0-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r4-r5-r6-r7-pop-r0-bx-r0-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb pop-r4-r5-r6 pop-r1 bx-r1 table helper tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x20, // movs r0, #0
        0x70, 0xBC, // pop {r4, r5, r6}
        0x02, 0xBC, // pop {r1}
        0x08, 0x47, // bx r1
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r4-r5-r6-pop-r1-bx-r1-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r4-r5-r6-pop-r1-bx-r1-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 1);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb saved-r8 pop-r0 bx-r0 commercial tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0xF0, 0xB5, // push {r4, r5, r6, r7, lr}
        0x47, 0x46, // mov r7, r8
        0x80, 0xB4, // push {r7}
        0x82, 0xB0, // sub sp, #8
        0x02, 0xB0, // add sp, #8
        0x08, 0xBC, // pop {r3}
        0x98, 0x46, // mov r8, r3
        0xF0, 0xBC, // pop {r4, r5, r6, r7}
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-saved-r8-pop-r0-bx-r0-return.gba", .data = rom_bytes });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-saved-r8-pop-r0-bx-r0-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0012, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb shared-frame jump-table case pop-r0 bx-r0 tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0x02, 0xB0, // add sp, #8
        0x08, 0xBC, // pop {r3}
        0x98, 0x46, // mov r8, r3
        0xF0, 0xBC, // pop {r4, r5, r6, r7}
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-shared-frame-pop-r0-bx-r0-return.gba", .data = rom_bytes });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-shared-frame-pop-r0-bx-r0-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_000A, 0);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);
}

test "thumb overlay high-register pop-r3 bx-r3 tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0x07, 0xB0, // add sp, #28
        0xFF, 0xBC, // pop {r0, r1, r2, r3, r4, r5, r6, r7}
        0x80, 0x46, // mov r8, r0
        0x89, 0x46, // mov r9, r1
        0x92, 0x46, // mov sl, r2
        0x9B, 0x46, // mov fp, r3
        0x08, 0xBC, // pop {r3}
        0x18, 0x47, // bx r3
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-overlay-high-regs-pop-r3-bx-r3-return.gba", .data = rom_bytes });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-overlay-high-regs-pop-r3-bx-r3-return.gba");
    defer image.deinit(std.testing.allocator);

    const resolved = try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_000E, 3);
    try std.testing.expectEqualDeep(armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }, resolved);

    const near_miss_bytes = &.{
        0x06, 0xB0, // add sp, #24
        0xFF, 0xBC, // pop {r0, r1, r2, r3, r4, r5, r6, r7}
        0x80, 0x46, // mov r8, r0
        0x89, 0x46, // mov r9, r1
        0x92, 0x46, // mov sl, r2
        0x9B, 0x46, // mov fp, r3
        0x08, 0xBC, // pop {r3}
        0x18, 0x47, // bx r3
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-overlay-high-regs-near-miss.gba", .data = near_miss_bytes });

    const near_miss = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-overlay-high-regs-near-miss.gba");
    defer near_miss.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 3 } },
        try resolveBxTarget(near_miss, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_000E, 3),
    );
}

test "thumb pop-r0 bx-r0 table helper tail resolves as return" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = .{
        0x00, 0x21, // movs r1, #0
        0x08, 0x64, // str r0, [r1, #64]
        0x01, 0xBC, // pop {r0}
        0x00, 0x47, // bx r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r0-bx-r0-return.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r0-bx-r0-return.gba");
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
            try std.testing.expectEqualDeep(
                armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = case.bx_reg } },
                try result,
            );
        } else {
            try std.testing.expectEqualDeep(
                armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} },
                try result,
            );
        }
    }
}

test "thumb push-lr pop-r0 bx-r0 resolves the measured commercial return shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        path: []const u8,
        body: []const u16,
    }{
        .{
            .path = "advance-wars-pop-r0-bx-r0.gba",
            .body = &.{ 0x2000, 0x2001, 0x1C08 }, // harmless Thumb body
        },
        .{
            .path = "kirby-pop-r0-bx-r0.gba",
            .body = &.{ 0x2000, 0x3008, 0x2800, 0xD1FC, 0x2001 },
        },
    };

    for (cases) |case| {
        try writeMeasuredThumbPopR0BxR0Rom(tmp.dir, io, case.path, case.body);

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", case.path);
        defer image.deinit(std.testing.allocator);
        const bx_address = 0x0800_0000 + 2 + @as(u32, @intCast(case.body.len * 2)) + 2;

        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} },
            try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, bx_address, 0),
        );
    }
}

test "thumb push-lr pop-r1 bx-r1 resolves the measured commercial return shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0x00, 0xB5, // push {lr}
        0x02, 0x1C, // adds r2, r0, #0
        0x10, 0x1C, // adds r0, r2, #0
        0x02, 0xBC, // pop {r1}
        0x08, 0x47, // bx r1
        0x00, 0x00,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-push-lr-pop-r1-bx-r1-return.gba", .data = rom_bytes });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-push-lr-pop-r1-bx-r1-return.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} },
        try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0008, 1),
    );
}

test "thumb push-lr movs-r0-imm bx-r0 still resolves through the generic path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{ 0x00, 0xB5, 0x00, 0x20, 0x00, 0x47, 0x00, 0x00 };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-push-lr-movs-r0-bx-r0-generic.gba", .data = rom_bytes });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-push-lr-movs-r0-bx-r0-generic.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0004, 0),
    );
}

test "thumb push-lr pop-r4 pop-r0 bx-r0 rejects the local near-miss" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{ 0x00, 0xB5, 0x10, 0xBC, 0x01, 0xBC, 0x00, 0x47 };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-pop-r4-pop-r0-bx-r0-near-miss.gba", .data = rom_bytes });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-pop-r4-pop-r0-bx-r0-near-miss.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, 0x0800_0006, 0),
    );
}

test "thumb push-lr pop-r0 bx-r0 resolver rejects near-miss shapes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        path: []const u8,
        rom_bytes: []const u8,
        bx_address: u32,
        bx_reg: u4,
        expect_error: bool,
    }{
        .{
            .path = "unrelated-movs-bx-r0.gba",
            .rom_bytes = &.{ 0x00, 0x20, 0x00, 0x47 },
            .bx_address = 0x0800_0002,
            .bx_reg = 0,
            .expect_error = false,
        },
        .{
            .path = "extra-insn-before-bx.gba",
            .rom_bytes = &.{ 0x00, 0xB5, 0x01, 0xBC, 0x00, 0x20, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
            .expect_error = true,
        },
    };

    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = case.path, .data = case.rom_bytes });
        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", case.path);
        defer image.deinit(std.testing.allocator);

        const result = resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, case.bx_address, case.bx_reg);
        if (case.expect_error) {
            try std.testing.expectEqualDeep(
                armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = case.bx_reg } },
                try result,
            );
        } else {
            try std.testing.expectEqualDeep(
                armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = case.bx_reg } },
                try result,
            );
        }
    }
}

test "unresolved bx register remains a dynamic dispatch instruction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0x01, 0x68, // ldr r1, [r0]
        0x08, 0x47, // bx r1
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-dynamic-bx-r1.gba", .data = rom_bytes });
    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-dynamic-bx-r1.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_0000, .isa = .thumb },
            0x0800_0002,
            .{ .bx_reg = .{ .reg = 1 } },
        ),
    );
}

test "function-entry bx register veneer remains a dynamic dispatch instruction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0x08, 0x47, // bx r1
        0xC0, 0x46, // nop
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-bx-r1-veneer.gba", .data = rom_bytes });
    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-bx-r1-veneer.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_0000, .isa = .thumb },
            0x0800_0000,
            .{ .bx_reg = .{ .reg = 1 } },
        ),
    );
}

test "thumb mov-pc runtime-loaded register remains a dynamic dispatch instruction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = &.{
        0x00, 0x68, // ldr r0, [r0]
        0x87, 0x46, // mov pc, r0
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "thumb-mov-pc-r0-dispatch.gba", .data = rom_bytes });
    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "thumb-mov-pc-r0-dispatch.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        try resolveDecodedInstruction(
            image,
            .{ .address = 0x0800_0000, .isa = .thumb },
            0x0800_0002,
            .{ .mov_reg = .{ .rd = 15, .rm = 0 } },
        ),
    );
}

test "linked thumb pointer table enqueues sibling dynamic targets" {
    var bytes: [0x50]u8 = std.mem.zeroes([0x50]u8);
    const targets = [_]u32{
        0x0800_0011,
        0x0800_0021,
        0x0800_0031,
        0x0800_0041,
    };
    for (targets, 0..) |target, index| {
        std.mem.writeInt(u32, bytes[index * 4 ..][0..4], target, .little);
    }

    const image = gba_loader.RomImage{ .bytes = &bytes };
    const lifted = [_]llvm_codegen.Function{
        .{
            .entry = .{ .address = 0x0800_0010, .isa = .thumb },
            .instructions = &.{},
        },
    };
    var pending: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending.deinit(std.testing.allocator);

    try std.testing.expect(try enqueueLinkedThumbPointerTableTargets(
        std.testing.allocator,
        &pending,
        image,
        &lifted,
    ));

    try std.testing.expectEqual(@as(usize, 3), pending.items.len);
    try std.testing.expect(containsCodeAddress(pending.items, .{ .address = 0x0800_0020, .isa = .thumb }));
    try std.testing.expect(containsCodeAddress(pending.items, .{ .address = 0x0800_0030, .isa = .thumb }));
    try std.testing.expect(containsCodeAddress(pending.items, .{ .address = 0x0800_0040, .isa = .thumb }));
}

test "thumb mov-pc jump table enqueues even thumb table targets" {
    var bytes: [0x30]u8 = std.mem.zeroes([0x30]u8);
    const halfwords = [_]u16{
        0x2D01, // cmp r5, #1
        0x00A8, // lsls r0, r5, #2
        0x4902, // ldr r1, [pc, #8]
        0x1840, // adds r0, r0, r1
        0x6800, // ldr r0, [r0]
        0x4687, // mov pc, r0
    };
    for (halfwords, 0..) |halfword, index| {
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], halfword, .little);
    }
    std.mem.writeInt(u32, bytes[0x10..][0..4], 0x0800_0018, .little);
    std.mem.writeInt(u32, bytes[0x18..][0..4], 0x0800_0020, .little);
    std.mem.writeInt(u32, bytes[0x1C..][0..4], 0x0800_0024, .little);

    const image = gba_loader.RomImage{ .bytes = &bytes };
    var pending: std.ArrayList(armv4t_decode.CodeAddress) = .empty;
    defer pending.deinit(std.testing.allocator);
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expect(try enqueueMeasuredThumbMovPcJumpTableTargets(
        std.testing.allocator,
        &output.writer,
        &pending,
        image,
        .thumb,
        0x0800_000A,
        0,
    ));
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);
    try std.testing.expect(containsCodeAddress(pending.items, .{ .address = 0x0800_0020, .isa = .thumb }));
    try std.testing.expect(containsCodeAddress(pending.items, .{ .address = 0x0800_0024, .isa = .thumb }));
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
            .cleared_blocker = "Unsupported opcode 0x00004718 at 0x08003078 for armv4t",
            .next_blocker = "Unsupported opcode 0x0000468F at 0x08002240 for armv4t",
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

test "minimal vblank model preserves non-vblank IE bits without firing them" {
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

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported interrupt source mask") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=") != null);
}

test "minimal vblank model allows IME restore inside a handler" {
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

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported nested IME enable at 0x04000208 for gba") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=") != null);
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

test "lift treats SoftReset swi as terminal control flow" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rom: [8]u8 = undefined;
    std.mem.writeInt(u32, rom[0..4], 0xEF000000, .little); // swi 0x00 (SoftReset)
    std.mem.writeInt(u32, rom[4..8], 0xE7F001F0, .little); // unsupported if decoded as fallthrough
    try tmp.dir.writeFile(io, .{ .sub_path = "softreset-terminal.gba", .data = &rom });

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "softreset-terminal.gba");
    defer image.deinit(std.testing.allocator);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = try liftRomWithOptions(std.testing.allocator, &output.writer, image, .retired_count, 10);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), program.functions[0].instructions.len);
    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .swi = .{ .imm24 = 0 } },
        program.functions[0].instructions[0].instruction,
    );
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "Unsupported opcode") == null);
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

test "build emits window llvm hooks when requested" {
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
            .output_mode = .window,
            .max_instructions = 1_000_000,
            .output_path = "ppu-hello-window-native",
        },
    );

    const llvm_bytes = try tmp.dir.readFileAlloc(
        io,
        "ppu-hello-window-native.ll",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(llvm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@hmgba_run_sdl3_window") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@hm_runtime_max_instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "call i32 @hmgba_run_sdl3_window") != null);
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

test "CpuSet copy fixture shape still defaults to register_r0_decimal under auto" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetCopyAutoProbeRom(tmp.dir, io, "cpuset-copy-auto-probe.gba");

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "cpuset-copy-auto-probe.gba");
    defer image.deinit(std.testing.allocator);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = try liftRom(std.testing.allocator, &output.writer, image);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(llvm_codegen.OutputMode.register_r0_decimal, program.output_mode);
}

test "build executes CpuSet copy semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetCopyRom(tmp.dir, io, "cpuset-copy.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpuset-copy.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpuset-copy-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpuset-copy-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("99\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build executes CpuFastSet copy semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetCopyRom(tmp.dir, io, "cpufastset-copy.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpufastset-copy.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpufastset-copy-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-copy-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("88\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build executes LZ77UnCompVram literal semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLz77UnCompVramLiteralRom(tmp.dir, io, "lz77-vram-literal.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "lz77-vram-literal.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "lz77-vram-literal-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./lz77-vram-literal-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("65\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build executes LZ77UnCompVram through halfword-visible VRAM writes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLz77UnCompVramHalfwordRom(tmp.dir, io, "lz77-vram-halfword.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "lz77-vram-halfword.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "lz77-vram-halfword-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./lz77-vram-halfword-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("13330\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build executes CpuFastSet fill semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetFillRom(tmp.dir, io, "cpufastset-fill.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpufastset-fill.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpufastset-fill-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-fill-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1234\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build executes CpuSet fill semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetFillRom(tmp.dir, io, "cpuset-fill.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpuset-fill.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpuset-fill-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpuset-fill-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "CpuSet rejects unsupported control bits structurally" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetBadControlRom(tmp.dir, io, "cpuset-bad-control.gba");

    const native_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, "cpuset-bad-control.gba", "cpuset-bad-control-native", .retired_count, 500_000)
    else
        try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            "cpuset-bad-control.gba",
            "cpuset-bad-control-native",
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

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported CpuSet control 0x82000001 for gba") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=500000\n") == null);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "CpuFastSet rejects unsupported control bits structurally" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetBadControlRom(tmp.dir, io, "cpufastset-bad-control.gba");

    const native_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, "cpufastset-bad-control.gba", "cpufastset-bad-control-native", .retired_count, 500_000)
    else
        try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            "cpufastset-bad-control.gba",
            "cpufastset-bad-control-native",
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

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported CpuFastSet control 0x04000008 for gba") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=500000\n") == null);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build treats CpuFastSet count as 32-bit words" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetWordCountRom(tmp.dir, io, "cpufastset-word-count.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpufastset-word-count.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpufastset-word-count-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-word-count-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "llvm emission treats CpuFastSet count as a word count" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = llvm_codegen.Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .swi = .{ .imm24 = 0x00000C } } },
                },
            },
        },
        .output_mode = .register_r0_decimal,
        .instruction_limit = null,
    };
    try llvm_codegen.emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%cpufastset_word_count = and i32 %cpufastset_control") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%cpufastset_copy_done = icmp uge i32 %cpufastset_copy_next_index, %cpufastset_word_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%cpufastset_word_count = shl i32 %cpufastset_count, 3") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%cpufastset_count_remainder") == null);
}

test "build advances VCOUNT byte reads deterministically" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeVCountPollRom(tmp.dir, io, "vcount-poll.gba");

    const native_path = if (standalone_build_cmd_test)
        try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, "vcount-poll.gba", "vcount-poll-native", .retired_count, 100)
    else
        try buildFixtureNative(
            std.testing.allocator,
            io,
            tmp.dir,
            "vcount-poll.gba",
            "vcount-poll-native",
            .retired_count,
            100,
        );
    defer std.testing.allocator.free(native_path);

    const result = try runNativeCapture(
        std.testing.allocator,
        io,
        tmp.dir,
        native_path,
        "retired_count",
        100,
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("retired=14\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build aligns CpuSet word-mode source and dest before copying" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetWordAlignRom(tmp.dir, io, "cpuset-align-word.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpuset-align-word.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpuset-align-word-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpuset-align-word-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build aligns CpuFastSet source and dest before copying" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetAlignRom(tmp.dir, io, "cpufastset-align.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpufastset-align.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpufastset-align-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-align-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "build aligns CpuSet halfword-mode source and dest before copying" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetHalfwordAlignRom(tmp.dir, io, "cpuset-align-halfword.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpuset-align-halfword.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpuset-align-halfword-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpuset-align-halfword-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
