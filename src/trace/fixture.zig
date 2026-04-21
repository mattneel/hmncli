const std = @import("std");
const trace = @import("event.zig");

pub fn gbaMissingDiv(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendEvent(allocator, &bytes, .{
        .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000100 },
    });
    try appendEvent(allocator, &bytes, .{
        .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000104 },
    });
    try appendEvent(allocator, &bytes, .{
        .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000108 },
    });
    try appendEvent(allocator, &bytes, .{
        .instruction_missing = .{
            .instruction = "instruction/armv4t/unknown_e7f001f0",
            .pc = 0x00000110,
        },
    });
    try appendEvent(allocator, &bytes, .{
        .unresolved_indirect_branch = .{
            .pc = 0x00000120,
            .target_register = "r12",
        },
    });

    return bytes.toOwnedSlice(allocator);
}

fn appendEvent(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    event: trace.TraceEvent,
) !void {
    var encoded_buffer: [128]u8 = undefined;
    const used = try trace.encodeOne(encoded_buffer[0..], event);
    try bytes.appendSlice(allocator, encoded_buffer[0..used]);
}

test "fixture emits missing declaration events for gba div" {
    const bytes = try gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}
