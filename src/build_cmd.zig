const std = @import("std");
const Io = std.Io;
const armv4t_decode = @import("armv4t_decode.zig");
const catalog = @import("catalog.zig");
const gba_loader = @import("gba_loader.zig");
const llvm_codegen = @import("llvm_codegen.zig");
const parse = @import("cli/parse.zig");

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

    const program = try liftRom(allocator, writer, image);
    defer program.deinit(allocator);

    try ensureParentDir(io, cwd, options.output_path);
    const llvm_path = try llvmPath(allocator, options.output_path);
    defer allocator.free(llvm_path);
    try ensureParentDir(io, cwd, llvm_path);
    try writeLlvmFile(io, allocator, cwd, llvm_path, program);
    try compileLlvm(io, allocator, cwd, writer, llvm_path, options);
    try writer.print("Built {s}\n", .{options.output_path});
}

fn liftRom(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    image: gba_loader.RomImage,
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

    return .{
        .entry = .{
            .address = image.base_address,
            .isa = .arm,
        },
        .rom_base_address = image.base_address,
        .rom_bytes = image.bytes,
        .functions = try functions.toOwnedSlice(allocator),
        .output_mode = if (has_store and has_self_loop) .memory_summary else .register_r0_decimal,
    };
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
        const offset = offsetForAddress(image, address, function_entry.isa) orelse {
            try writer.print("Unsupported control flow target 0x{X:0>8} for gba\n", .{address});
            return error.UnsupportedOpcode;
        };

        const size_bytes = instructionSizeBytes(function_entry.isa);
        const raw_opcode, const decoded_initial = switch (function_entry.isa) {
            .arm => blk: {
                const word = armv4t_decode.readWord(image.bytes, offset);
                break :blk .{ word, armv4t_decode.decode(word, address) catch |err| return switch (err) {
                    error.UnsupportedOpcode => {
                        try renderUnsupportedOpcode(writer, word, address);
                        return error.UnsupportedOpcode;
                    },
                    else => |other| return other,
                } };
            },
            .thumb => blk: {
                const halfword = armv4t_decode.readHalfword(image.bytes, offset);
                break :blk .{ @as(u32, halfword), armv4t_decode.decodeThumb(halfword, address) catch |err| return switch (err) {
                    error.UnsupportedOpcode => {
                        try renderUnsupportedOpcode(writer, halfword, address);
                        return error.UnsupportedOpcode;
                    },
                    else => |other| return other,
                } };
            },
        };
        const decoded = resolveDecodedInstruction(image, function_entry.isa, address, decoded_initial) catch {
            try renderUnsupportedOpcode(writer, raw_opcode, address);
            return error.UnsupportedOpcode;
        };

        try ensureDeclared(writer, decoded, address);
        if (isStore(decoded)) has_store.* = true;

        try nodes.append(allocator, .{
            .address = address,
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

fn ensureDeclared(
    writer: *Io.Writer,
    decoded: armv4t_decode.DecodedInstruction,
    address: u32,
) BuildError!void {
    switch (decoded) {
        .mov_imm => _ = try catalog.lookupInstruction("armv4t", "mov_imm"),
        .mov_reg => _ = try catalog.lookupInstruction("armv4t", "mov_reg"),
        .movs_imm => _ = try catalog.lookupInstruction("armv4t", "movs_imm"),
        .movs_reg => _ = try catalog.lookupInstruction("armv4t", "movs_reg"),
        .orr_imm => _ = try catalog.lookupInstruction("armv4t", "orr_imm"),
        .add_imm => _ = try catalog.lookupInstruction("armv4t", "add_imm"),
        .add_reg => _ = try catalog.lookupInstruction("armv4t", "add_reg"),
        .sub_imm => _ = try catalog.lookupInstruction("armv4t", "sub_imm"),
        .subs_imm => _ = try catalog.lookupInstruction("armv4t", "subs_imm"),
        .lsl_imm => _ = try catalog.lookupInstruction("armv4t", "lsl_imm"),
        .mla => _ = try catalog.lookupInstruction("armv4t", "mla"),
        .ldr_word_imm => _ = try catalog.lookupInstruction("armv4t", "ldr_word_imm"),
        .push => _ = try catalog.lookupInstruction("armv4t", "push_regs"),
        .pop => _ = try catalog.lookupInstruction("armv4t", "pop_regs"),
        .ldm => _ = try catalog.lookupInstruction("armv4t", "ldm_regs"),
        .tst_imm => _ = try catalog.lookupInstruction("armv4t", "tst_imm"),
        .store => |store| switch (store.size) {
            .word => switch (store.offset) {
                .imm => _ = try catalog.lookupInstruction("armv4t", "str_word_imm"),
                .reg => _ = try catalog.lookupInstruction("armv4t", "str_word_reg"),
            },
            .halfword => _ = try catalog.lookupInstruction("armv4t", "str_halfword_imm"),
            .byte => _ = try catalog.lookupInstruction("armv4t", "str_byte_imm"),
        },
        .branch => |branch| _ = try catalog.lookupInstruction("armv4t", branchInstructionName(branch.cond)),
        .bl => _ = try catalog.lookupInstruction("armv4t", "bl"),
        .bx_target => _ = try catalog.lookupInstruction("armv4t", "bx_reg"),
        .bx_reg => return error.UnsupportedOpcode,
        .bx_lr => _ = try catalog.lookupInstruction("armv4t", "bx_lr"),
        .msr_cpsr_f_imm => _ = try catalog.lookupInstruction("armv4t", "msr_cpsr_f_imm"),
        .swi => |swi| {
            if (!isDivSwi(swi.imm24)) {
                try renderUnsupportedShim(writer, address, swi.imm24);
                return error.UnsupportedShim;
            }
            _ = try catalog.lookupShim("gba", "Div");
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
        .bx_target => |target| {
            try enqueueFunctionAddress(allocator, writer, pending_functions, image, target);
        },
        .bx_lr => return,
        .bx_reg => return error.UnsupportedOpcode,
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
    return switch (decoded) {
        .bx_reg => |bx| try resolveBxTarget(image, isa, address, bx.reg),
        else => decoded,
    };
}

fn resolveBxTarget(
    image: gba_loader.RomImage,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    reg: u4,
) BuildError!armv4t_decode.DecodedInstruction {
    const previous_size = instructionSizeBytes(isa);
    if (address < image.base_address + previous_size) return error.UnsupportedOpcode;
    const previous_address = address - previous_size;
    const offset = offsetForAddress(image, previous_address, isa) orelse return error.UnsupportedOpcode;
    const previous_decoded = switch (isa) {
        .arm => try armv4t_decode.decode(armv4t_decode.readWord(image.bytes, offset), previous_address),
        .thumb => try armv4t_decode.decodeThumb(armv4t_decode.readHalfword(image.bytes, offset), previous_address),
    };

    return switch (previous_decoded) {
        .add_imm => |add| blk: {
            if (add.rd != reg or add.rn != 15) return error.UnsupportedOpcode;
            const target_value = pcValueForInstruction(isa, previous_address) + add.imm;
            break :blk .{ .bx_target = normalizeCodeTarget(target_value) };
        },
        .mov_imm => |mov| blk: {
            if (mov.rd != reg) return error.UnsupportedOpcode;
            break :blk .{ .bx_target = normalizeCodeTarget(mov.imm) };
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

fn isStore(decoded: armv4t_decode.DecodedInstruction) bool {
    return switch (decoded) {
        .store => true,
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
    try argv.append(allocator, "-O0");
    try argv.append(allocator, "-x");
    try argv.append(allocator, "ir");
    try argv.append(allocator, llvm_path);
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

test "build uses the real jsmolka arm rom and reports the next unsupported surface honestly" {
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

    try std.testing.expectError(
        error.UnsupportedOpcode,
        run(
            io,
            std.testing.allocator,
            tmp.dir,
            &output.writer,
            .{
                .rom_path = "arm.gba",
                .machine_name = "gba",
                .output_path = "arm-native",
            },
        ),
    );
    try std.testing.expectStringStartsWith(
        output.writer.buffered(),
        "Unsupported opcode 0xE2003001 at 0x08001EFC for armv4t\n",
    );
}
