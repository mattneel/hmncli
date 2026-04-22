const std = @import("std");
const c = @import("capstone_c");
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

pub const StatusFlags = struct {
    n: bool,
    z: bool,
    c: bool,
    v: bool,
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
    bl: struct {
        target: u32,
    },
    bx_lr,
    msr_cpsr_f_imm: StatusFlags,
    swi: struct {
        imm24: u24,
    },
};

pub fn decode(word: u32, address: u32) DecodeError!DecodedInstruction {
    const insn = try capstone_api.disassembleOneArm32(word, address);

    return switch (insn.id) {
        c.ARM_INS_MOV => parseMov(insn),
        c.ARM_INS_ORR => parseAlu3(.orr_imm, insn),
        c.ARM_INS_ADD => parseAlu3(.add_imm, insn),
        c.ARM_INS_SUB, c.ARM_INS_SUBS => if (insn.update_flags)
            parseAlu3(.subs_imm, insn)
        else
            error.UnsupportedOpcode,
        c.ARM_INS_STR => parseStore(insn, .word),
        c.ARM_INS_STRB => parseStore(insn, .byte),
        c.ARM_INS_STRH => parseStore(insn, .halfword),
        c.ARM_INS_B => parseBranch(insn),
        c.ARM_INS_BL => parseBl(word, insn),
        c.ARM_INS_BX => parseBx(insn),
        c.ARM_INS_MSR => parseMsr(word),
        c.ARM_INS_SVC => parseSwi(insn),
        else => error.UnsupportedOpcode,
    };
}

pub fn readWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn parseMov(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    return .{ .mov_imm = .{
        .rd = try operandRegister(insn, 0),
        .imm = try operandImmediateU32(insn, 1),
    } };
}

fn parseAlu3(
    comptime tag: enum { orr_imm, add_imm, subs_imm },
    insn: capstone_api.ArmInstruction,
) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const rn = try operandRegister(insn, 1);
    const imm = try operandImmediateU32(insn, 2);

    return switch (tag) {
        .orr_imm => .{ .orr_imm = .{ .rd = rd, .rn = rn, .imm = imm } },
        .add_imm => .{ .add_imm = .{ .rd = rd, .rn = rn, .imm = imm } },
        .subs_imm => .{ .subs_imm = .{ .rd = rd, .rn = rn, .imm = imm } },
    };
}

fn parseStore(insn: capstone_api.ArmInstruction, size: StoreSize) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;

    const src = try operandRegister(insn, 0);
    const mem_op = operandAt(insn, 1);
    if (mem_op.subtracted) return error.UnsupportedOpcode;

    const mem = switch (mem_op.value) {
        .mem => |value| value,
        else => return error.UnsupportedOpcode,
    };

    const base = try parseRegisterId(mem.base);
    const offset = try parseMemoryOffset(mem);
    return .{ .store = .{
        .src = src,
        .base = base,
        .offset = offset,
        .size = size,
    } };
}

fn parseBranch(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 1) return error.UnsupportedOpcode;
    const cond: Cond = switch (insn.cc) {
        c.ARMCC_AL => .al,
        c.ARMCC_NE => .ne,
        else => return error.UnsupportedOpcode,
    };
    return .{ .branch = .{
        .cond = cond,
        .target = try operandImmediateU32(insn, 0),
    } };
}

fn parseSwi(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 1) return error.UnsupportedOpcode;
    const imm = try operandImmediateU32(insn, 0);
    if (imm > 0x00FF_FFFF) return error.UnsupportedOpcode;
    return .{ .swi = .{
        .imm24 = @truncate(imm),
    } };
}

fn parseBl(word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 1) return error.UnsupportedOpcode;
    if ((word >> 28) != 0xE) return error.UnsupportedOpcode;
    return .{ .bl = .{
        .target = try operandImmediateU32(insn, 0),
    } };
}

fn parseBx(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 1) return error.UnsupportedOpcode;
    const reg = try operandRegister(insn, 0);
    if (reg != 14) return error.UnsupportedOpcode;
    return .bx_lr;
}

fn parseMsr(word: u32) DecodeError!DecodedInstruction {
    const is_immediate = ((word >> 25) & 0x1) == 1;
    const writes_spsr = ((word >> 22) & 0x1) == 1;
    const field_mask: u4 = @truncate((word >> 16) & 0xF);

    if (!is_immediate or writes_spsr) return error.UnsupportedOpcode;
    if (field_mask != 0x8) return error.UnsupportedOpcode;

    return .{ .msr_cpsr_f_imm = unpackStatusFlags(decodeArmImmediate(word)) };
}

fn operandAt(insn: capstone_api.ArmInstruction, index: usize) capstone_api.ArmOperand {
    return insn.operands[index];
}

fn operandRegister(insn: capstone_api.ArmInstruction, index: usize) DecodeError!u4 {
    const operand = operandAt(insn, index);
    if (operand.subtracted) return error.UnsupportedOpcode;
    return switch (operand.value) {
        .reg => |reg| parseRegisterId(reg),
        else => error.UnsupportedOpcode,
    };
}

fn operandImmediateU32(insn: capstone_api.ArmInstruction, index: usize) DecodeError!u32 {
    const operand = operandAt(insn, index);
    if (operand.subtracted) return error.UnsupportedOpcode;
    return switch (operand.value) {
        .imm => |imm| parseU32Immediate(imm),
        else => error.UnsupportedOpcode,
    };
}

fn parseMemoryOffset(mem: capstone_api.ArmMemoryOperand) DecodeError!Offset {
    if (mem.disp < 0) return error.UnsupportedOpcode;
    if (mem.index == c.ARM_REG_INVALID) {
        return .{ .imm = @intCast(mem.disp) };
    }

    if (mem.disp != 0) return error.UnsupportedOpcode;
    if (mem.scale != 0 and mem.scale != 1) return error.UnsupportedOpcode;
    return .{ .reg = try parseRegisterId(mem.index) };
}

fn parseRegisterId(reg: u32) DecodeError!u4 {
    if (reg >= c.ARM_REG_R0 and reg <= c.ARM_REG_R12) {
        return @intCast(reg - c.ARM_REG_R0);
    }

    return switch (reg) {
        c.ARM_REG_SP => 13,
        c.ARM_REG_LR => 14,
        c.ARM_REG_PC => 15,
        else => error.UnsupportedOpcode,
    };
}

fn parseU32Immediate(imm: i64) DecodeError!u32 {
    if (imm < 0 or imm > std.math.maxInt(u32)) return error.UnsupportedOpcode;
    return @intCast(imm);
}

fn decodeArmImmediate(word: u32) u32 {
    const imm8 = word & 0xFF;
    const rotate = ((word >> 8) & 0xF) * 2;
    return std.math.rotr(u32, imm8, rotate);
}

fn unpackStatusFlags(value: u32) StatusFlags {
    return .{
        .n = (value & 0x8000_0000) != 0,
        .z = (value & 0x4000_0000) != 0,
        .c = (value & 0x2000_0000) != 0,
        .v = (value & 0x1000_0000) != 0,
    };
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

test "decode reads direct bl target" {
    const decoded = try decode(0xEB000001, 0x08000004);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .bl = .{ .target = 0x08000010 } },
        decoded,
    );
}

test "decode reads bx lr" {
    const decoded = try decode(0xE12FFF1E, 0x08000014);
    try std.testing.expectEqualDeep(DecodedInstruction.bx_lr, decoded);
}

test "decode reads msr cpsr_f immediate" {
    const decoded = try decode(0xE328F101, 0x080000F8);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .msr_cpsr_f_imm = .{
            .n = false,
            .z = true,
            .c = false,
            .v = false,
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

test "decode reads subs immediate" {
    const decoded = try decode(0xE2522004, 0x08000114);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .subs_imm = .{
            .rd = 2,
            .rn = 2,
            .imm = 4,
        } },
        decoded,
    );
}

test "decode rejects unsupported opcode" {
    try std.testing.expectError(error.UnsupportedOpcode, decode(0xE7F001F0, 0x08000000));
}
