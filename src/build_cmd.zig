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

    const operations = try liftRom(allocator, writer, image);
    defer allocator.free(operations);

    try ensureParentDir(io, cwd, options.output_path);
    const llvm_path = try llvmPath(allocator, options.output_path);
    defer allocator.free(llvm_path);
    try ensureParentDir(io, cwd, llvm_path);
    try writeLlvmFile(io, allocator, cwd, llvm_path, operations);
    try compileLlvm(io, allocator, cwd, writer, llvm_path, options);
    try writer.print("Built {s}\n", .{options.output_path});
}

fn liftRom(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    image: gba_loader.RomImage,
) BuildError![]llvm_codegen.Operation {
    var operations: std.ArrayList(llvm_codegen.Operation) = .empty;
    defer operations.deinit(allocator);

    var offset: usize = 0;
    while (offset < image.bytes.len) : (offset += 4) {
        const address = image.base_address + @as(u32, @intCast(offset));
        const word = armv4t_decode.readWord(image.bytes, offset);
        const decoded = armv4t_decode.decode(word) catch {
            try renderUnsupportedOpcode(writer, word, address);
            return error.UnsupportedOpcode;
        };
        try appendOperation(allocator, writer, &operations, decoded, address);
    }

    return try operations.toOwnedSlice(allocator);
}

fn appendOperation(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    operations: *std.ArrayList(llvm_codegen.Operation),
    decoded: armv4t_decode.DecodedInstruction,
    address: u32,
) BuildError!void {
    switch (decoded) {
        .mov_imm => |mov| {
            _ = try catalog.lookupInstruction("armv4t", "mov_imm");
            try operations.append(allocator, .{ .mov_imm = .{
                .rd = mov.rd,
                .imm = mov.imm,
            } });
        },
        .swi => |swi| {
            if (swi.imm24 != 0x000006) {
                try renderUnsupportedShim(writer, address, swi.imm24);
                return error.UnsupportedShim;
            }
            _ = try catalog.lookupShim("gba", "Div");
            try operations.append(allocator, .call_gba_div);
        },
    }
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
    operations: []const llvm_codegen.Operation,
) BuildError!void {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try llvm_codegen.emitModule(&output.writer, operations);
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
