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
    defer allocator.free(program.instructions);

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
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);

    var nodes: std.ArrayList(llvm_codegen.InstructionNode) = .empty;
    defer nodes.deinit(allocator);

    var has_store = false;
    var has_self_loop = false;

    try pending.append(allocator, image.base_address);

    while (pending.items.len != 0) {
        const address = pending.items[pending.items.len - 1];
        pending.items.len -= 1;

        if (containsAddress(nodes.items, address)) continue;
        const offset = offsetForAddress(image, address) orelse {
            try writer.print("Unsupported control flow target 0x{X:0>8} for gba\n", .{address});
            return error.UnsupportedOpcode;
        };

        const word = armv4t_decode.readWord(image.bytes, offset);
        const decoded = armv4t_decode.decode(word, address) catch {
            try renderUnsupportedOpcode(writer, word, address);
            return error.UnsupportedOpcode;
        };

        try ensureDeclared(writer, decoded, address);
        if (isStore(decoded)) has_store = true;

        try nodes.append(allocator, .{
            .address = address,
            .instruction = decoded,
        });

        try enqueueSuccessors(allocator, writer, &pending, image, address, decoded, &has_self_loop);
    }

    sortNodes(nodes.items);

    return .{
        .entry_address = image.base_address,
        .instructions = try nodes.toOwnedSlice(allocator),
        .output_mode = if (has_store and has_self_loop) .memory_summary else .register_r0_decimal,
    };
}

fn ensureDeclared(
    writer: *Io.Writer,
    decoded: armv4t_decode.DecodedInstruction,
    address: u32,
) BuildError!void {
    switch (decoded) {
        .mov_imm => _ = try catalog.lookupInstruction("armv4t", "mov_imm"),
        .orr_imm => _ = try catalog.lookupInstruction("armv4t", "orr_imm"),
        .add_imm => _ = try catalog.lookupInstruction("armv4t", "add_imm"),
        .subs_imm => _ = try catalog.lookupInstruction("armv4t", "subs_imm"),
        .store => |store| switch (store.size) {
            .word => switch (store.offset) {
                .imm => _ = try catalog.lookupInstruction("armv4t", "str_word_imm"),
                .reg => _ = try catalog.lookupInstruction("armv4t", "str_word_reg"),
            },
            .halfword => _ = try catalog.lookupInstruction("armv4t", "str_halfword_imm"),
            .byte => _ = try catalog.lookupInstruction("armv4t", "str_byte_imm"),
        },
        .branch => |branch| switch (branch.cond) {
            .al => _ = try catalog.lookupInstruction("armv4t", "b"),
            .ne => _ = try catalog.lookupInstruction("armv4t", "bne"),
        },
        .swi => |swi| {
            if (swi.imm24 != 0x000006) {
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
    pending: *std.ArrayList(u32),
    image: gba_loader.RomImage,
    address: u32,
    decoded: armv4t_decode.DecodedInstruction,
    has_self_loop: *bool,
) BuildError!void {
    switch (decoded) {
        .branch => |branch| switch (branch.cond) {
            .al => {
                if (branch.target == address) {
                    has_self_loop.* = true;
                    return;
                }
                try enqueueAddress(allocator, writer, pending, image, branch.target);
            },
            .ne => {
                try enqueueFallthrough(allocator, pending, image, address);
                if (branch.target == address) {
                    has_self_loop.* = true;
                    return;
                }
                try enqueueAddress(allocator, writer, pending, image, branch.target);
            },
        },
        else => {
            try enqueueFallthrough(allocator, pending, image, address);
        },
    }
}

fn enqueueFallthrough(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(u32),
    image: gba_loader.RomImage,
    address: u32,
) std.mem.Allocator.Error!void {
    const next_address = address + 4;
    if (offsetForAddress(image, next_address) != null) {
        try pending.append(allocator, next_address);
    }
}

fn enqueueAddress(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    pending: *std.ArrayList(u32),
    image: gba_loader.RomImage,
    address: u32,
) BuildError!void {
    if (offsetForAddress(image, address) == null) {
        try writer.print("Unsupported control flow target 0x{X:0>8} for gba\n", .{address});
        return error.UnsupportedOpcode;
    }
    try pending.append(allocator, address);
}

fn offsetForAddress(image: gba_loader.RomImage, address: u32) ?usize {
    if (address < image.base_address) return null;
    const offset = address - image.base_address;
    if ((offset % 4) != 0) return null;
    if (offset >= image.bytes.len) return null;
    return offset;
}

fn containsAddress(nodes: []const llvm_codegen.InstructionNode, address: u32) bool {
    for (nodes) |node| {
        if (node.address == address) return true;
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
        "Unsupported opcode 0xEB000780 at 0x080000C0 for armv4t\n",
    );
}
