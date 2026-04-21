const std = @import("std");
const Io = std.Io;
const fixture = @import("../trace/fixture.zig");
const trace = @import("../trace/event.zig");

pub const RenderError = Io.Writer.Error || trace.TraceCodecError || std.mem.Allocator.Error;

pub fn render(writer: *Io.Writer, bytes: []const u8) RenderError!void {
    var shim_counts: std.ArrayList(CountEntry) = .empty;
    defer shim_counts.deinit(std.heap.page_allocator);

    var instruction_counts: std.ArrayList(CountEntry) = .empty;
    defer instruction_counts.deinit(std.heap.page_allocator);

    var branches: std.ArrayList(BranchEntry) = .empty;
    defer branches.deinit(std.heap.page_allocator);

    var offset: usize = 0;
    while (offset < bytes.len) {
        const decoded = try trace.decodeOne(bytes[offset..]);
        offset += decoded.bytes_read;

        switch (decoded.event) {
            .shim_called => |payload| try bumpCount(std.heap.page_allocator, &shim_counts, payload.shim),
            .instruction_missing => |payload| {
                try bumpCount(std.heap.page_allocator, &instruction_counts, payload.instruction);
            },
            .unresolved_indirect_branch => |payload| {
                try branches.append(std.heap.page_allocator, .{
                    .pc = payload.pc,
                    .target_register = payload.target_register,
                });
            },
            else => {},
        }
    }

    try writer.writeAll("Unimplemented shims:\n");
    for (shim_counts.items, 0..) |entry, index| {
        try writer.print("{d}. {s} ({d})\n", .{ index + 1, entry.key, entry.count });
    }

    try writer.writeAll("Unimplemented instructions:\n");
    for (instruction_counts.items, 0..) |entry, index| {
        try writer.print("{d}. {s} ({d})\n", .{ index + 1, entry.key, entry.count });
    }

    try writer.writeAll("Unresolved indirect branches:\n");
    for (branches.items, 0..) |entry, index| {
        try writer.print("{d}. pc=0x{x:0>8} register={s}\n", .{ index + 1, entry.pc, entry.target_register });
    }
}

const CountEntry = struct {
    key: []const u8,
    count: usize,
};

const BranchEntry = struct {
    pc: u32,
    target_register: []const u8,
};

fn bumpCount(
    allocator: std.mem.Allocator,
    counts: *std.ArrayList(CountEntry),
    key: []const u8,
) std.mem.Allocator.Error!void {
    for (counts.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.count += 1;
            return;
        }
    }

    try counts.append(allocator, .{
        .key = key,
        .count = 1,
    });
}

test "status ranks missing shims and instructions from trace bytes" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const bytes = try fixture.gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    try render(&output.writer, bytes);

    try std.testing.expectEqualStrings(
        "Unimplemented shims:\n1. shim/gba/Div (3)\nUnimplemented instructions:\n1. instruction/armv4t/unknown_e7f001f0 (1)\nUnresolved indirect branches:\n1. pc=0x00000120 register=r12\n",
        output.writer.buffered(),
    );
}
