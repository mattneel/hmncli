const std = @import("std");

pub const TraceCodecError = error{
    BufferTooSmall,
    UnexpectedEof,
    UnknownEventTag,
    StringTooLong,
};

pub const TraceEvent = union(enum) {
    shim_called: struct {
        shim: []const u8,
        pc: u32,
    },
    shim_returned: struct {
        shim: []const u8,
        pc: u32,
    },
    instruction_missing: struct {
        instruction: []const u8,
        pc: u32,
    },
    unresolved_indirect_branch: struct {
        pc: u32,
        target_register: []const u8,
    },
};

pub const DecodedEvent = struct {
    event: TraceEvent,
    bytes_read: usize,
};

pub fn encodeOne(buffer: []u8, event: TraceEvent) TraceCodecError!usize {
    var offset: usize = 0;
    try writeByte(buffer, &offset, @intFromEnum(std.meta.activeTag(event)));

    switch (event) {
        .shim_called => |payload| {
            try writeInt(buffer, &offset, payload.pc);
            try writeString(buffer, &offset, payload.shim);
        },
        .shim_returned => |payload| {
            try writeInt(buffer, &offset, payload.pc);
            try writeString(buffer, &offset, payload.shim);
        },
        .instruction_missing => |payload| {
            try writeInt(buffer, &offset, payload.pc);
            try writeString(buffer, &offset, payload.instruction);
        },
        .unresolved_indirect_branch => |payload| {
            try writeInt(buffer, &offset, payload.pc);
            try writeString(buffer, &offset, payload.target_register);
        },
    }

    return offset;
}

pub fn decodeOne(buffer: []const u8) TraceCodecError!DecodedEvent {
    var offset: usize = 0;
    const tag_value = try readByte(buffer, &offset);
    const tag: std.meta.Tag(TraceEvent) = switch (tag_value) {
        @intFromEnum(std.meta.Tag(TraceEvent).shim_called) => .shim_called,
        @intFromEnum(std.meta.Tag(TraceEvent).shim_returned) => .shim_returned,
        @intFromEnum(std.meta.Tag(TraceEvent).instruction_missing) => .instruction_missing,
        @intFromEnum(std.meta.Tag(TraceEvent).unresolved_indirect_branch) => .unresolved_indirect_branch,
        else => return error.UnknownEventTag,
    };

    const event: TraceEvent = switch (tag) {
        .shim_called => .{
            .shim_called = .{
                .pc = try readInt(buffer, &offset),
                .shim = try readString(buffer, &offset),
            },
        },
        .shim_returned => .{
            .shim_returned = .{
                .pc = try readInt(buffer, &offset),
                .shim = try readString(buffer, &offset),
            },
        },
        .instruction_missing => .{
            .instruction_missing = .{
                .pc = try readInt(buffer, &offset),
                .instruction = try readString(buffer, &offset),
            },
        },
        .unresolved_indirect_branch => .{
            .unresolved_indirect_branch = .{
                .pc = try readInt(buffer, &offset),
                .target_register = try readString(buffer, &offset),
            },
        },
    };

    return .{
        .event = event,
        .bytes_read = offset,
    };
}

fn writeByte(buffer: []u8, offset: *usize, value: u8) TraceCodecError!void {
    if (offset.* >= buffer.len) return error.BufferTooSmall;
    buffer[offset.*] = value;
    offset.* += 1;
}

fn writeInt(buffer: []u8, offset: *usize, value: u32) TraceCodecError!void {
    if (buffer.len - offset.* < @sizeOf(u32)) return error.BufferTooSmall;
    std.mem.writeInt(u32, buffer[offset.* ..][0..@sizeOf(u32)], value, .little);
    offset.* += @sizeOf(u32);
}

fn writeString(buffer: []u8, offset: *usize, value: []const u8) TraceCodecError!void {
    if (value.len > std.math.maxInt(u8)) return error.StringTooLong;
    try writeByte(buffer, offset, @intCast(value.len));
    if (buffer.len - offset.* < value.len) return error.BufferTooSmall;
    @memcpy(buffer[offset.* ..][0..value.len], value);
    offset.* += value.len;
}

fn readByte(buffer: []const u8, offset: *usize) TraceCodecError!u8 {
    if (offset.* >= buffer.len) return error.UnexpectedEof;
    const value = buffer[offset.*];
    offset.* += 1;
    return value;
}

fn readInt(buffer: []const u8, offset: *usize) TraceCodecError!u32 {
    if (buffer.len - offset.* < @sizeOf(u32)) return error.UnexpectedEof;
    const value = std.mem.readInt(u32, buffer[offset.* ..][0..@sizeOf(u32)], .little);
    offset.* += @sizeOf(u32);
    return value;
}

fn readString(buffer: []const u8, offset: *usize) TraceCodecError![]const u8 {
    const len = try readByte(buffer, offset);
    if (buffer.len - offset.* < len) return error.UnexpectedEof;
    const value = buffer[offset.* ..][0..len];
    offset.* += len;
    return value;
}

test "trace encode decode roundtrip preserves shim-called payload" {
    const event = TraceEvent{
        .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000100 },
    };
    var buffer: [256]u8 = undefined;
    const used = try encodeOne(buffer[0..], event);
    const decoded = try decodeOne(buffer[0..used]);
    try std.testing.expectEqualDeep(event, decoded.event);
}
