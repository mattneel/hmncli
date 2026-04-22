const std = @import("std");
const capstone_api = @import("capstone_api.zig");

pub const DecodeError = error{
    UnsupportedOpcode,
} || capstone_api.DisassembleError;

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
    const text = try capstone_api.disassembleOneArm32(word, address);
    const mnemonic = text.mnemonicSlice();
    const operands = text.operandsSlice();

    if (std.mem.eql(u8, mnemonic, "mov")) return parseMov(operands);
    if (std.mem.eql(u8, mnemonic, "orr")) return parseAlu3(.orr_imm, operands);
    if (std.mem.eql(u8, mnemonic, "add")) return parseAlu3(.add_imm, operands);
    if (std.mem.eql(u8, mnemonic, "subs")) return parseAlu3(.subs_imm, operands);
    if (std.mem.eql(u8, mnemonic, "str")) return parseStore(operands, .word);
    if (std.mem.eql(u8, mnemonic, "strb")) return parseStore(operands, .byte);
    if (std.mem.eql(u8, mnemonic, "strh")) return parseStore(operands, .halfword);
    if (std.mem.eql(u8, mnemonic, "b")) return parseBranch(operands, .al);
    if (std.mem.eql(u8, mnemonic, "bne")) return parseBranch(operands, .ne);
    if (std.mem.eql(u8, mnemonic, "swi") or std.mem.eql(u8, mnemonic, "svc")) return parseSwi(operands);
    return error.UnsupportedOpcode;
}

pub fn readWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn parseMov(operands: []const u8) DecodeError!DecodedInstruction {
    const split = try split3Operands(operands, 2);
    return .{ .mov_imm = .{
        .rd = try parseRegister(split.first),
        .imm = try parseImmediate(split.second),
    } };
}

fn parseAlu3(
    comptime tag: enum { orr_imm, add_imm, subs_imm },
    operands: []const u8,
) DecodeError!DecodedInstruction {
    const split = try split3Operands(operands, 3);
    const rd = try parseRegister(split.first);
    const rn = try parseRegister(split.second);
    const imm = try parseImmediate(split.third.?);

    return switch (tag) {
        .orr_imm => .{ .orr_imm = .{ .rd = rd, .rn = rn, .imm = imm } },
        .add_imm => .{ .add_imm = .{ .rd = rd, .rn = rn, .imm = imm } },
        .subs_imm => .{ .subs_imm = .{ .rd = rd, .rn = rn, .imm = imm } },
    };
}

fn parseStore(operands: []const u8, size: StoreSize) DecodeError!DecodedInstruction {
    const comma_index = std.mem.indexOfScalar(u8, operands, ',') orelse return error.UnsupportedOpcode;
    const src_text = trim(operands[0..comma_index]);
    const memory_text = trim(operands[comma_index + 1 ..]);
    const src = try parseRegister(src_text);

    const memory = try parseMemoryOperand(memory_text);
    return .{ .store = .{
        .src = src,
        .base = memory.base,
        .offset = memory.offset,
        .size = size,
    } };
}

fn parseBranch(operands: []const u8, cond: Cond) DecodeError!DecodedInstruction {
    return .{ .branch = .{
        .cond = cond,
        .target = try parseImmediate(operands),
    } };
}

fn parseSwi(operands: []const u8) DecodeError!DecodedInstruction {
    const imm = try parseImmediate(operands);
    if (imm > 0x00FF_FFFF) return error.UnsupportedOpcode;
    return .{ .swi = .{
        .imm24 = @truncate(imm),
    } };
}

const MemoryOperand = struct {
    base: u4,
    offset: Offset,
};

fn parseMemoryOperand(text: []const u8) DecodeError!MemoryOperand {
    const trimmed = trim(text);
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.UnsupportedOpcode;
    const inner = trim(trimmed[1 .. trimmed.len - 1]);
    const comma_index = std.mem.indexOfScalar(u8, inner, ',');
    if (comma_index == null) {
        return .{
            .base = try parseRegister(inner),
            .offset = .{ .imm = 0 },
        };
    }

    const base_text = trim(inner[0..comma_index.?]);
    const offset_text = trim(inner[comma_index.? + 1 ..]);
    return .{
        .base = try parseRegister(base_text),
        .offset = try parseOffset(offset_text),
    };
}

fn parseOffset(text: []const u8) DecodeError!Offset {
    const trimmed = trim(text);
    if (trimmed.len == 0) return error.UnsupportedOpcode;
    if (trimmed[0] == '#') return .{ .imm = try parseImmediate(trimmed) };
    if (trimmed[0] == 'r') return .{ .reg = try parseRegister(trimmed) };
    return error.UnsupportedOpcode;
}

const SplitOperands = struct {
    first: []const u8,
    second: []const u8,
    third: ?[]const u8,
};

fn split3Operands(text: []const u8, comptime expected_parts: comptime_int) DecodeError!SplitOperands {
    const first_comma = std.mem.indexOfScalar(u8, text, ',') orelse return error.UnsupportedOpcode;
    const first = trim(text[0..first_comma]);
    const tail = trim(text[first_comma + 1 ..]);
    if (expected_parts == 2) {
        return .{
            .first = first,
            .second = tail,
            .third = null,
        };
    }

    const second_comma = std.mem.indexOfScalar(u8, tail, ',') orelse return error.UnsupportedOpcode;
    return .{
        .first = first,
        .second = trim(tail[0..second_comma]),
        .third = trim(tail[second_comma + 1 ..]),
    };
}

fn parseRegister(text: []const u8) DecodeError!u4 {
    const trimmed = trim(text);
    if (trimmed.len < 2 or trimmed[0] != 'r') return error.UnsupportedOpcode;
    const index = std.fmt.parseInt(u8, trimmed[1..], 10) catch return error.UnsupportedOpcode;
    if (index > 15) return error.UnsupportedOpcode;
    return @intCast(index);
}

fn parseImmediate(text: []const u8) DecodeError!u32 {
    const trimmed = trim(text);
    const bare = if (trimmed.len != 0 and trimmed[0] == '#') trimmed[1..] else trimmed;
    return std.fmt.parseInt(u32, bare, 0) catch return error.UnsupportedOpcode;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
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
