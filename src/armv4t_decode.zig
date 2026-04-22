const std = @import("std");
const c = @import("capstone_c");
const capstone_api = @import("capstone_api.zig");

pub const DecodeError = error{
    UnsupportedOpcode,
} || capstone_api.DisassembleError;

pub const InstructionSet = enum {
    arm,
    thumb,
};

pub const CodeAddress = struct {
    address: u32,
    isa: InstructionSet,
};

pub const Cond = enum {
    eq,
    ne,
    hs,
    lo,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,
    al,
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
    mov_reg: struct {
        rd: u4,
        rm: u4,
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
    bx_reg: struct {
        reg: u4,
    },
    bx_target: CodeAddress,
    bx_lr,
    msr_cpsr_f_imm: StatusFlags,
    swi: struct {
        imm24: u24,
    },
};

pub fn decode(word: u32, address: u32) DecodeError!DecodedInstruction {
    const insn = try capstone_api.disassembleOneArm32(word, address);
    return decodeInstruction(word, insn);
}

pub fn decodeThumb(halfword: u16, address: u32) DecodeError!DecodedInstruction {
    const insn = try capstone_api.disassembleOneThumb16(halfword, address);
    return decodeInstruction(halfword, insn);
}

fn decodeInstruction(raw_word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    return switch (insn.id) {
        c.ARM_INS_MOV => parseMov(insn),
        c.ARM_INS_ADR => parseAdr(insn),
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
        c.ARM_INS_BL => parseBl(raw_word, insn),
        c.ARM_INS_BX => parseBx(insn),
        c.ARM_INS_MSR => parseMsr(raw_word),
        c.ARM_INS_SVC => parseSwi(insn),
        else => error.UnsupportedOpcode,
    };
}

pub fn readWord(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn readHalfword(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn parseMov(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const source = operandAt(insn, 1);
    if (source.subtracted) return error.UnsupportedOpcode;

    return switch (source.value) {
        .imm => |imm| .{ .mov_imm = .{
            .rd = rd,
            .imm = try parseU32Immediate(imm),
        } },
        .reg => |reg| .{ .mov_reg = .{
            .rd = rd,
            .rm = try parseRegisterId(reg),
        } },
        else => error.UnsupportedOpcode,
    };
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

fn parseAdr(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    const imm = try operandImmediateU32(insn, 1);
    return .{ .mov_imm = .{
        .rd = try operandRegister(insn, 0),
        .imm = adrTargetAddress(insn.address, insn.size, imm),
    } };
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
        c.ARMCC_EQ => .eq,
        c.ARMCC_NE => .ne,
        c.ARMCC_HS => .hs,
        c.ARMCC_LO => .lo,
        c.ARMCC_MI => .mi,
        c.ARMCC_PL => .pl,
        c.ARMCC_VS => .vs,
        c.ARMCC_VC => .vc,
        c.ARMCC_HI => .hi,
        c.ARMCC_LS => .ls,
        c.ARMCC_GE => .ge,
        c.ARMCC_LT => .lt,
        c.ARMCC_GT => .gt,
        c.ARMCC_LE => .le,
        c.ARMCC_AL => .al,
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
    if (reg == 14) return .bx_lr;
    return .{ .bx_reg = .{ .reg = reg } };
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

fn adrTargetAddress(address: u64, size: u16, imm: u32) u32 {
    const base_address: u32 = @intCast(address);
    const pc_value = switch (size) {
        2 => (base_address + 4) & ~@as(u32, 3),
        4 => base_address + 8,
        else => unreachable,
    };
    return pc_value + imm;
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

test "decode reads ARM conditional branch targets across the flag-only family" {
    const cases = [_]struct {
        word: u32,
        address: u32,
        cond: Cond,
        target: u32,
    }{
        .{ .word = 0x0A000002, .address = 0x080000FC, .cond = .eq, .target = 0x0800010C },
        .{ .word = 0x1A000002, .address = 0x08000110, .cond = .ne, .target = 0x08000120 },
        .{ .word = 0x2A000002, .address = 0x08000124, .cond = .hs, .target = 0x08000134 },
        .{ .word = 0x3A000002, .address = 0x08000138, .cond = .lo, .target = 0x08000148 },
        .{ .word = 0x4A000002, .address = 0x0800014C, .cond = .mi, .target = 0x0800015C },
        .{ .word = 0x5A000002, .address = 0x08000160, .cond = .pl, .target = 0x08000170 },
        .{ .word = 0x6A000002, .address = 0x08000174, .cond = .vs, .target = 0x08000184 },
        .{ .word = 0x7A000002, .address = 0x08000188, .cond = .vc, .target = 0x08000198 },
        .{ .word = 0x8A000002, .address = 0x0800019C, .cond = .hi, .target = 0x080001AC },
        .{ .word = 0x9A000002, .address = 0x080001B0, .cond = .ls, .target = 0x080001C0 },
        .{ .word = 0xAA000002, .address = 0x080001C4, .cond = .ge, .target = 0x080001D4 },
        .{ .word = 0xBA000002, .address = 0x080001EC, .cond = .lt, .target = 0x080001FC },
        .{ .word = 0xCA000002, .address = 0x08000214, .cond = .gt, .target = 0x08000224 },
        .{ .word = 0xDA000002, .address = 0x0800023C, .cond = .le, .target = 0x0800024C },
    };

    for (cases) |case| {
        const decoded = try decode(case.word, case.address);
        try std.testing.expectEqualDeep(
            DecodedInstruction{ .branch = .{
                .cond = case.cond,
                .target = case.target,
            } },
            decoded,
        );
    }
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

test "decode reads bx r0 for later target resolution" {
    const decoded = try decode(0xE12FFF10, 0x08000004);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .bx_reg = .{ .reg = 0 } },
        decoded,
    );
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

test "decode reads thumb mov immediate" {
    const decoded = try decodeThumb(0x2007, 0x08000008);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mov_imm = .{ .rd = 0, .imm = 7 } },
        decoded,
    );
}

test "decode reads thumb mov register" {
    const decoded = try decodeThumb(0x4684, 0x0800000A);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mov_reg = .{ .rd = 12, .rm = 0 } },
        decoded,
    );
}

test "decode reads thumb add pc immediate" {
    const decoded = try decodeThumb(0xA101, 0x0800000A);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mov_imm = .{
            .rd = 1,
            .imm = 0x08000010,
        } },
        decoded,
    );
}

test "decode reads thumb bx r1" {
    const decoded = try decodeThumb(0x4708, 0x0800000C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .bx_reg = .{ .reg = 1 } },
        decoded,
    );
}

test "decode rejects unsupported opcode" {
    try std.testing.expectError(error.UnsupportedOpcode, decode(0xE7F001F0, 0x08000000));
}
