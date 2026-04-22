const std = @import("std");
const Io = std.Io;
const build_cmd = @import("build_cmd.zig");
const doc = @import("cli/doc.zig");
const parse = @import("cli/parse.zig");
const status = @import("cli/status.zig");
const test_cmd = @import("cli/test.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command = try parse.parse(args);
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    switch (command) {
        .build => |build| try runBuildOrExit(io, arena, stdout_writer, build),
        .doc => |decl_id_text| try doc.render(stdout_writer, decl_id_text),
        .status => |maybe_trace_path| {
            const trace_path = maybe_trace_path orelse return error.TracePathRequired;
            const trace_bytes = try Io.Dir.cwd().readFileAlloc(io, trace_path, arena, .limited(1024 * 1024));
            try status.render(stdout_writer, trace_bytes);
        },
        .test_shim => |selector| try test_cmd.runShim(stdout_writer, selector),
        .test_instruction => |selector| try test_cmd.runInstruction(stdout_writer, selector),
    }

    try stdout_writer.flush();
}

fn runBuildOrExit(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    build: parse.BuildCommand,
) !void {
    build_cmd.run(io, allocator, Io.Dir.cwd(), writer, build) catch |err| switch (err) {
        error.UnsupportedMachine,
        error.EmptyRom,
        error.InvalidRomSize,
        error.UnsupportedOpcode,
        error.UnsupportedShim,
        error.ToolFailed,
        error.MachineNotFound,
        error.ShimNotFound,
        error.InstructionNotFound,
        => {
            try writer.flush();
            std.process.exit(1);
        },
        else => return err,
    };
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
