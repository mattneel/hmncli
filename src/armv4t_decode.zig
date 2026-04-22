const std = @import("std");

pub const DecodeError = error{
    UnsupportedOpcode,
};

pub const DecodedInstruction = union(enum) {
    mov_imm: struct {
        rd: u4,
        imm: u32,
    },
    swi: struct {
        imm24: u24,
    },
};

pub fn decode(word: u32) DecodeError!DecodedInstruction {
    if ((word >> 28) != 0xE) return error.UnsupportedOpcode;
    if (isMovImmediate(word)) return .{ .mov_imm = .{
        .rd = @truncate((word >> 12) & 0xF),
        .imm = decodeArmImmediate(word),
    } };
    if (((word >> 24) & 0xF) == 0xF) return .{ .swi = .{
        .imm24 = @truncate(word & 0x00FF_FFFF),
    } };
    return error.UnsupportedOpcode;
}

pub fn readWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn isMovImmediate(word: u32) bool {
    return ((word >> 25) & 0x7) == 0b001 and
        ((word >> 21) & 0xF) == 0xD and
        ((word >> 20) & 0x1) == 0 and
        ((word >> 16) & 0xF) == 0;
}

fn decodeArmImmediate(word: u32) u32 {
    const imm8: u32 = word & 0xFF;
    const rotate_bits: u5 = @intCast(((word >> 8) & 0xF) * 2);
    if (rotate_bits == 0) return imm8;
    const inverse_rotate: u5 = @intCast(32 - @as(u6, rotate_bits));
    return (imm8 >> rotate_bits) | (imm8 << inverse_rotate);
}

test "decode reads mov immediate" {
    const decoded = try decode(0xE3A0000A);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mov_imm = .{ .rd = 0, .imm = 10 } },
        decoded,
    );
}

test "decode rejects unsupported opcode" {
    try std.testing.expectError(error.UnsupportedOpcode, decode(0xE7F001F0));
}
