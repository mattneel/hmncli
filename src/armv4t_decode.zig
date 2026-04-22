const std = @import("std");

pub const DecodeError = error{
    UnsupportedOpcode,
};

pub const Cond = enum {
    al,
    ne,
};

pub const Offset = union(enum) {
    imm: u32,
    reg: u4,
};

pub const StoreSize = enum {
    byte,
    halfword,
    word,
};

pub const DecodedInstruction = union(enum) {
    mov_imm: struct {
        rd: u4,
        imm: u32,
    },
    orr_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    add_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    subs_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    store: struct {
        src: u4,
        base: u4,
        offset: Offset,
        size: StoreSize,
    },
    branch: struct {
        cond: Cond,
        target: u32,
    },
    swi: struct {
        imm24: u24,
    },
};

pub fn decode(word: u32, address: u32) DecodeError!DecodedInstruction {
    if (decodeBranch(word, address)) |branch| return branch;
    if (decodeStore(word)) |store| return store;
    if (decodeHalfwordStore(word)) |store| return store;
    if (decodeDataProcessingImmediate(word)) |instruction| return instruction;
    if (decodeSwi(word)) |swi| return swi;
    return error.UnsupportedOpcode;
}

pub fn readWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn decodeDataProcessingImmediate(word: u32) ?DecodedInstruction {
    if (decodeCond(word) != .al) return null;
    if (((word >> 25) & 0x7) != 0b001) return null;

    const opcode: u4 = @truncate((word >> 21) & 0xF);
    const sets_flags = ((word >> 20) & 0x1) == 1;
    const rn: u4 = @truncate((word >> 16) & 0xF);
    const rd: u4 = @truncate((word >> 12) & 0xF);
    const imm = decodeArmImmediate(word);

    return switch (opcode) {
        0xD => if (!sets_flags and rn == 0) .{ .mov_imm = .{ .rd = rd, .imm = imm } } else null,
        0xC => if (!sets_flags) .{ .orr_imm = .{ .rd = rd, .rn = rn, .imm = imm } } else null,
        0x4 => if (!sets_flags) .{ .add_imm = .{ .rd = rd, .rn = rn, .imm = imm } } else null,
        0x2 => if (sets_flags) .{ .subs_imm = .{ .rd = rd, .rn = rn, .imm = imm } } else null,
        else => null,
    };
}

fn decodeStore(word: u32) ?DecodedInstruction {
    if (decodeCond(word) != .al) return null;
    if (((word >> 26) & 0x3) != 0b01) return null;

    const pre_index = ((word >> 24) & 0x1) == 1;
    const add_offset = ((word >> 23) & 0x1) == 1;
    const is_byte = ((word >> 22) & 0x1) == 1;
    const reg_offset = ((word >> 25) & 0x1) == 1;
    const write_back = ((word >> 21) & 0x1) == 1;
    const load = ((word >> 20) & 0x1) == 1;

    if (!pre_index or !add_offset or write_back or load) return null;

    const src: u4 = @truncate((word >> 12) & 0xF);
    const base: u4 = @truncate((word >> 16) & 0xF);
    const size: StoreSize = if (is_byte) .byte else .word;
    const offset: Offset = if (reg_offset) blk: {
        if (((word >> 4) & 0x1) != 0) return null;
        if (((word >> 5) & 0x3) != 0) return null;
        if (((word >> 7) & 0x1F) != 0) return null;
        break :blk .{ .reg = @truncate(word & 0xF) };
    } else .{ .imm = word & 0xFFF };

    return .{ .store = .{
        .src = src,
        .base = base,
        .offset = offset,
        .size = size,
    } };
}

fn decodeHalfwordStore(word: u32) ?DecodedInstruction {
    if (decodeCond(word) != .al) return null;
    if (((word >> 25) & 0x7) != 0b000) return null;
    if (((word >> 22) & 0x1) != 1) return null;
    if (((word >> 20) & 0x1) != 0) return null;
    if (((word >> 24) & 0x1) != 1) return null;
    if (((word >> 23) & 0x1) != 1) return null;
    if (((word >> 21) & 0x1) != 0) return null;
    if (((word >> 4) & 0xF) != 0xB) return null;

    const src: u4 = @truncate((word >> 12) & 0xF);
    const base: u4 = @truncate((word >> 16) & 0xF);
    const offset = (((word >> 8) & 0xF) << 4) | (word & 0xF);

    return .{ .store = .{
        .src = src,
        .base = base,
        .offset = .{ .imm = offset },
        .size = .halfword,
    } };
}

fn decodeBranch(word: u32, address: u32) ?DecodedInstruction {
    const cond = decodeCond(word) orelse return null;
    if (((word >> 25) & 0x7) != 0b101) return null;
    if (((word >> 24) & 0x1) != 0) return null;

    return .{ .branch = .{
        .cond = cond,
        .target = branchTarget(word, address),
    } };
}

fn decodeSwi(word: u32) ?DecodedInstruction {
    if (decodeCond(word) != .al) return null;
    if (((word >> 24) & 0xF) != 0xF) return null;
    return .{ .swi = .{
        .imm24 = @truncate(word & 0x00FF_FFFF),
    } };
}

fn decodeCond(word: u32) ?Cond {
    return switch (word >> 28) {
        0xE => .al,
        0x1 => .ne,
        else => null,
    };
}

fn decodeArmImmediate(word: u32) u32 {
    const imm8: u32 = word & 0xFF;
    const rotate_bits: u5 = @intCast(((word >> 8) & 0xF) * 2);
    if (rotate_bits == 0) return imm8;
    const inverse_rotate: u5 = @intCast(32 - @as(u6, rotate_bits));
    return (imm8 >> rotate_bits) | (imm8 << inverse_rotate);
}

fn branchTarget(word: u32, address: u32) u32 {
    const imm24 = word & 0x00FF_FFFF;
    const offset_bits = imm24 << 2;
    const signed_offset: i32 = @bitCast(if ((imm24 & 0x0080_0000) != 0)
        offset_bits | 0xFC00_0000
    else
        offset_bits);
    const target: i64 = @as(i64, address) + 8 + signed_offset;
    return @intCast(target);
}

test "decode reads mov immediate" {
    const decoded = try decode(0xE3A0000A, 0x08000000);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mov_imm = .{ .rd = 0, .imm = 10 } },
        decoded,
    );
}

test "decode reads unconditional branch target" {
    const decoded = try decode(0xEA00002E, 0x08000000);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .branch = .{ .cond = .al, .target = 0x080000C0 } },
        decoded,
    );
}

test "decode reads word store with register offset" {
    const decoded = try decode(0xE7810002, 0x08000118);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .store = .{
            .src = 0,
            .base = 1,
            .offset = .{ .reg = 2 },
            .size = .word,
        } },
        decoded,
    );
}

test "decode reads halfword store with immediate offset" {
    const decoded = try decode(0xE1C100B2, 0x080000F4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .store = .{
            .src = 0,
            .base = 1,
            .offset = .{ .imm = 2 },
            .size = .halfword,
        } },
        decoded,
    );
}

test "decode rejects unsupported opcode" {
    try std.testing.expectError(error.UnsupportedOpcode, decode(0xE7F001F0, 0x08000000));
}
