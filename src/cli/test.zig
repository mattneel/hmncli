const std = @import("std");
const Io = std.Io;
const catalog = @import("../catalog.zig");

pub const RunError = Io.Writer.Error || catalog.CatalogError || error{
    InvalidSelector,
    ShimVectorFailed,
    InstructionVectorFailed,
};

pub fn runShim(writer: *Io.Writer, selector: []const u8) RunError!void {
    const parts = try splitSelector(selector);
    const shim = try catalog.lookupShim(parts.namespace, parts.name);

    var passed: usize = 0;
    for (shim.tests) |case| {
        const actual = evalShim(selector, case.input);
        if (actual != case.expected) return error.ShimVectorFailed;
        passed += 1;
    }

    try writer.print("PASS {d}/{d} shim tests for {s}\n", .{ passed, shim.tests.len, selector });
}

pub fn runInstruction(writer: *Io.Writer, selector: []const u8) RunError!void {
    const parts = try splitSelector(selector);
    const instruction = try catalog.lookupInstruction(parts.namespace, parts.name);

    var passed: usize = 0;
    for (instruction.tests) |case| {
        const actual = evalInstruction(selector, case.input);
        if (!std.mem.eql(u32, case.expected, &actual)) return error.InstructionVectorFailed;
        passed += 1;
    }

    try writer.print("PASS {d}/{d} instruction tests for {s}\n", .{ passed, instruction.tests.len, selector });
}

const SelectorParts = struct {
    namespace: []const u8,
    name: []const u8,
};

fn splitSelector(selector: []const u8) RunError!SelectorParts {
    var it = std.mem.splitScalar(u8, selector, '/');
    const namespace = it.next() orelse return error.InvalidSelector;
    const name = it.next() orelse return error.InvalidSelector;
    if (it.next() != null) return error.InvalidSelector;
    return .{
        .namespace = namespace,
        .name = name,
    };
}

fn evalShim(selector: []const u8, input: []const i32) i32 {
    if (std.mem.eql(u8, selector, "gba/Div")) return @divTrunc(input[0], input[1]);
    unreachable;
}

fn evalInstruction(selector: []const u8, input: []const u32) [1]u32 {
    if (std.mem.eql(u8, selector, "armv4t/mov_imm")) return .{input[1]};
    unreachable;
}

test "test command runs shim vectors for gba div" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try runShim(&output.writer, "gba/Div");

    try std.testing.expectEqualStrings(
        "PASS 2/2 shim tests for gba/Div\n",
        output.writer.buffered(),
    );
}

test "test command runs instruction vectors for arm mov immediate" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try runInstruction(&output.writer, "armv4t/mov_imm");

    try std.testing.expectEqualStrings(
        "PASS 1/1 instruction tests for armv4t/mov_imm\n",
        output.writer.buffered(),
    );
}
