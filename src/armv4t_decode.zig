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

pub const ShiftKind = enum {
    lsl,
    lsr,
    asr,
    ror,
};

pub const ShiftImm = struct {
    kind: ShiftKind,
    amount: u32,
};

pub const StoreAddressing = union(enum) {
    offset: Offset,
    post_index: Offset,
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
    movs_imm: struct {
        rd: u4,
        imm: u32,
    },
    mvn_imm: struct {
        rd: u4,
        imm: u32,
    },
    movs_reg: struct {
        rd: u4,
        rm: u4,
    },
    orr_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    orr_shift_reg: struct {
        rd: u4,
        rn: u4,
        rm: u4,
        shift: ShiftImm,
    },
    and_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    add_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    adds_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    adcs_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    sbcs_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    add_reg: struct {
        rd: u4,
        rn: u4,
        rm: u4,
    },
    sub_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    subs_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    lsl_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    lsls_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    lsls_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    lsr_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    mla: struct {
        rd: u4,
        rm: u4,
        rs: u4,
        ra: u4,
    },
    store: struct {
        src: u4,
        base: u4,
        addressing: StoreAddressing,
        size: StoreSize,
    },
    ldr_word_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
    },
    push: u16,
    pop: u16,
    ldm: struct {
        base: u4,
        mask: u16,
        writeback: bool,
    },
    tst_imm: struct {
        rn: u4,
        imm: u32,
    },
    cmp_imm: struct {
        rn: u4,
        imm: u32,
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
        c.ARM_INS_MOV => parseMov(raw_word, insn),
        c.ARM_INS_MVN => parseMvn(insn),
        c.ARM_INS_ADR => parseAdr(insn),
        c.ARM_INS_AND => parseAlu3(.and_imm, insn),
        c.ARM_INS_ORR => parseAlu3(.orr_imm, insn),
        c.ARM_INS_ADD => parseAdd(insn),
        c.ARM_INS_ADC => parseAdc(insn),
        c.ARM_INS_SBC => parseSbc(insn),
        c.ARM_INS_SUB, c.ARM_INS_SUBS => if (insn.update_flags)
            parseAlu3(.subs_imm, insn)
        else
            parseSub(insn),
        c.ARM_INS_LSL, c.ARM_INS_LSR => parseShift(insn),
        c.ARM_INS_MLA => parseMla(insn),
        c.ARM_INS_LDR => parseLoad(insn),
        c.ARM_INS_STR => parseStore(insn, .word),
        c.ARM_INS_STRB => parseStore(insn, .byte),
        c.ARM_INS_STRH => parseStore(insn, .halfword),
        c.ARM_INS_STMDB => parseStackTransfer(raw_word, insn, .push),
        c.ARM_INS_LDM => parseLdm(raw_word, insn),
        c.ARM_INS_TST => parseTst(insn),
        c.ARM_INS_CMP => parseCmp(insn),
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

fn parseMov(raw_word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.size == 4 and ((raw_word >> 25) & 1) == 0) {
        const bit4 = (raw_word >> 4) & 1;
        const shift_type = (raw_word >> 5) & 0x3;
        const shift_imm = (raw_word >> 7) & 0x1F;
        const rd: u4 = @truncate((raw_word >> 12) & 0xF);
        const rm: u4 = @truncate(raw_word & 0xF);
        if (bit4 == 1 and shift_type == 0) {
            return if (insn.update_flags)
                .{ .lsls_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = @truncate((raw_word >> 8) & 0xF),
                } }
            else
                error.UnsupportedOpcode;
        }
        if (shift_imm != 0) {
            return switch (shift_type) {
                0 => if (insn.update_flags)
                    .{ .lsls_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = shift_imm,
                    } }
                else
                    .{ .lsl_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = shift_imm,
                    } },
                1 => .{ .lsr_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = shift_imm,
                } },
                else => error.UnsupportedOpcode,
            };
        }
    }
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const source = operandAt(insn, 1);
    if (source.subtracted) return error.UnsupportedOpcode;
    return switch (source.value) {
        .imm => |imm| if (insn.update_flags)
            .{ .movs_imm = .{
                .rd = rd,
                .imm = try parseU32Immediate(imm),
            } }
        else
            .{ .mov_imm = .{
                .rd = rd,
                .imm = try parseU32Immediate(imm),
            } },
        .reg => |reg| if (insn.update_flags)
            .{ .movs_reg = .{
                .rd = rd,
                .rm = try parseRegisterId(reg),
            } }
        else
            .{ .mov_reg = .{
                .rd = rd,
                .rm = try parseRegisterId(reg),
            } },
        else => error.UnsupportedOpcode,
    };
}

fn parseAlu3(
    comptime tag: enum { orr_imm, and_imm, subs_imm },
    insn: capstone_api.ArmInstruction,
) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const rn = try operandRegister(insn, 1);
    const source = operandAt(insn, 2);
    if (source.subtracted) return error.UnsupportedOpcode;

    return switch (tag) {
        .orr_imm => switch (source.value) {
            .imm => |imm| .{ .orr_imm = .{
                .rd = rd,
                .rn = rn,
                .imm = try parseU32Immediate(imm),
            } },
            .reg => |reg| .{ .orr_shift_reg = .{
                .rd = rd,
                .rn = rn,
                .rm = try parseRegisterId(reg),
                .shift = try parseShiftImm(source),
            } },
            else => error.UnsupportedOpcode,
        },
        .and_imm => .{ .and_imm = .{
            .rd = rd,
            .rn = rn,
            .imm = try operandImmediateU32(insn, 2),
        } },
        .subs_imm => .{ .subs_imm = .{
            .rd = rd,
            .rn = rn,
            .imm = try operandImmediateU32(insn, 2),
        } },
    };
}

fn parseAdd(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const rn = try operandRegister(insn, 1);
    const source = operandAt(insn, 2);
    if (source.subtracted) return error.UnsupportedOpcode;

    return switch (source.value) {
        .imm => |imm| if (insn.update_flags)
            .{ .adds_imm = .{
                .rd = rd,
                .rn = rn,
                .imm = try parseU32Immediate(imm),
            } }
        else
            .{ .add_imm = .{
                .rd = rd,
                .rn = rn,
                .imm = try parseU32Immediate(imm),
            } },
        .reg => |reg| .{ .add_reg = .{
            .rd = rd,
            .rn = rn,
            .rm = try parseRegisterId(reg),
        } },
        else => error.UnsupportedOpcode,
    };
}

fn parseMvn(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    return .{ .mvn_imm = .{
        .rd = try operandRegister(insn, 0),
        .imm = try operandImmediateU32(insn, 1),
    } };
}

fn parseAdc(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (!insn.update_flags) return error.UnsupportedOpcode;
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return .{ .adcs_imm = .{
        .rd = try operandRegister(insn, 0),
        .rn = try operandRegister(insn, 1),
        .imm = try operandImmediateU32(insn, 2),
    } };
}

fn parseSbc(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (!insn.update_flags) return error.UnsupportedOpcode;
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return .{ .sbcs_imm = .{
        .rd = try operandRegister(insn, 0),
        .rn = try operandRegister(insn, 1),
        .imm = try operandImmediateU32(insn, 2),
    } };
}

fn parseSub(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return .{ .sub_imm = .{
        .rd = try operandRegister(insn, 0),
        .rn = try operandRegister(insn, 1),
        .imm = try operandImmediateU32(insn, 2),
    } };
}

fn parseShift(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const rm = try operandRegister(insn, 1);
    const amount = operandAt(insn, 2);
    if (amount.subtracted) return error.UnsupportedOpcode;

    return switch (amount.value) {
        .imm => |imm| switch (insn.id) {
            c.ARM_INS_LSL => if (insn.update_flags)
                .{ .lsls_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = try parseU32Immediate(imm),
                } }
            else
                .{ .lsl_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = try parseU32Immediate(imm),
                } },
            c.ARM_INS_LSR => .{ .lsr_imm = .{
                .rd = rd,
                .rm = rm,
                .imm = try parseU32Immediate(imm),
            } },
            else => unreachable,
        },
        .reg => |reg| switch (insn.id) {
            c.ARM_INS_LSL => if (insn.update_flags)
                .{ .lsls_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } }
            else
                error.UnsupportedOpcode,
            else => error.UnsupportedOpcode,
        },
        else => error.UnsupportedOpcode,
    };
}

fn parseMla(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 4) return error.UnsupportedOpcode;
    return .{ .mla = .{
        .rd = try operandRegister(insn, 0),
        .rm = try operandRegister(insn, 1),
        .rs = try operandRegister(insn, 2),
        .ra = try operandRegister(insn, 3),
    } };
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
        .addressing = if (insn.post_index)
            .{ .post_index = offset }
        else if (insn.writeback)
            return error.UnsupportedOpcode
        else
            .{ .offset = offset },
        .size = size,
    } };
}

fn parseLoad(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;

    const rd = try operandRegister(insn, 0);
    const mem_op = operandAt(insn, 1);
    if (mem_op.subtracted) return error.UnsupportedOpcode;

    const mem = switch (mem_op.value) {
        .mem => |value| value,
        else => return error.UnsupportedOpcode,
    };

    if (mem.disp < 0) return error.UnsupportedOpcode;
    if (mem.index != c.ARM_REG_INVALID) return error.UnsupportedOpcode;
    if (mem.scale != 0 and mem.scale != 1) return error.UnsupportedOpcode;

    return .{ .ldr_word_imm = .{
        .rd = rd,
        .base = try parseRegisterId(mem.base),
        .offset = @intCast(mem.disp),
    } };
}

fn parseStackTransfer(
    word: u32,
    insn: capstone_api.ArmInstruction,
    comptime kind: enum { push, pop },
) DecodeError!DecodedInstruction {
    const base_reg: u4 = @truncate((word >> 16) & 0xF);
    const register_mask: u16 = @truncate(word & 0xFFFF);

    if (base_reg != 13) return error.UnsupportedOpcode;
    if (!insn.writeback) return error.UnsupportedOpcode;
    if (register_mask == 0) return error.UnsupportedOpcode;

    return switch (kind) {
        .push => .{ .push = register_mask },
        .pop => .{ .pop = register_mask },
    };
}

fn parseLdm(word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    const base_reg: u4 = @truncate((word >> 16) & 0xF);
    const register_mask: u16 = @truncate(word & 0xFFFF);

    if (register_mask == 0) return error.UnsupportedOpcode;
    if (base_reg == 13 and insn.writeback) {
        return .{ .pop = register_mask };
    }

    return .{ .ldm = .{
        .base = base_reg,
        .mask = register_mask,
        .writeback = insn.writeback,
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

fn parseTst(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    return .{ .tst_imm = .{
        .rn = try operandRegister(insn, 0),
        .imm = try operandImmediateU32(insn, 1),
    } };
}

fn parseCmp(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    return .{ .cmp_imm = .{
        .rn = try operandRegister(insn, 0),
        .imm = try operandImmediateU32(insn, 1),
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

fn parseShiftImm(operand: capstone_api.ArmOperand) DecodeError!ShiftImm {
    const kind = switch (operand.shift_type) {
        c.ARM_SFT_LSL => ShiftKind.lsl,
        c.ARM_SFT_LSR => ShiftKind.lsr,
        c.ARM_SFT_ASR => ShiftKind.asr,
        c.ARM_SFT_ROR => ShiftKind.ror,
        else => return error.UnsupportedOpcode,
    };
    return .{
        .kind = kind,
        .amount = operand.shift_value,
    };
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
    if (imm >= 0) {
        if (imm > std.math.maxInt(i32)) return error.UnsupportedOpcode;
        return @intCast(imm);
    }
    if (imm < std.math.minInt(i32)) return error.UnsupportedOpcode;
    return @bitCast(@as(i32, @intCast(imm)));
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

test "decode reads movs immediate" {
    const decoded = try decode(0xE3B00000, 0x080002D0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .movs_imm = .{ .rd = 0, .imm = 0 } },
        decoded,
    );
}

test "decode reads movs immediate with the high bit set" {
    const decoded = try decode(0xE3B00102, 0x080002F0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .movs_imm = .{
            .rd = 0,
            .imm = 0x8000_0000,
        } },
        decoded,
    );
}

test "decode reads mvn immediate" {
    const decoded = try decode(0xE3E00000, 0x08000310);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mvn_imm = .{
            .rd = 0,
            .imm = 0,
        } },
        decoded,
    );
}

test "decode reads sub immediate without flag updates" {
    const decoded = try decode(0xE2422020, 0x08001F58);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .sub_imm = .{
            .rd = 2,
            .rn = 2,
            .imm = 32,
        } },
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
            .addressing = .{ .offset = .{ .reg = 2 } },
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

test "decode reads push and pop register masks" {
    const push = try decode(0xE92D0003, 0x08001D4C);
    try std.testing.expectEqualDeep(DecodedInstruction{ .push = 0x0003 }, push);

    const pop = try decode(0xE8BD0003, 0x08001D6C);
    try std.testing.expectEqualDeep(DecodedInstruction{ .pop = 0x0003 }, pop);
}

test "decode reads generic ldm register mask" {
    const decoded = try decode(0xE893000C, 0x08001F68);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldm = .{
            .base = 3,
            .mask = 0x000C,
            .writeback = false,
        } },
        decoded,
    );
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
            .addressing = .{ .offset = .{ .imm = 2 } },
            .size = .halfword,
        } },
        decoded,
    );
}

test "decode reads halfword store with post-index immediate" {
    const decoded = try decode(0xE0C130B2, 0x08001F10);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .store = .{
            .src = 3,
            .base = 1,
            .addressing = .{ .post_index = .{ .imm = 2 } },
            .size = .halfword,
        } },
        decoded,
    );
}

test "decode reads ldr word immediate" {
    const decoded = try decode(0xE5901004, 0x08001D54);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_word_imm = .{
            .rd = 1,
            .base = 0,
            .offset = 4,
        } },
        decoded,
    );
}

test "decode reads lsl immediate" {
    const decoded = try decode(0xE1A02182, 0x08001F5C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsl_imm = .{
            .rd = 2,
            .rm = 2,
            .imm = 3,
        } },
        decoded,
    );
}

test "decode reads lsls immediate" {
    const decoded = try decode(0xE1B00F80, 0x080004E4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsls_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 31,
        } },
        decoded,
    );
}

test "decode reads lsls register" {
    const decoded = try decode(0xE1B00110, 0x08000504);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsls_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
        } },
        decoded,
    );
}

test "decode reads lsr immediate" {
    const decoded = try decode(0xE1A000A0, 0x08001F00);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsr_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 1,
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

test "decode reads and immediate" {
    const decoded = try decode(0xE2003001, 0x08001EFC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .and_imm = .{
            .rd = 3,
            .rn = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads tst immediate" {
    const decoded = try decode(0xE3110001, 0x08001D58);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .tst_imm = .{
            .rn = 1,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads cmp immediate" {
    const decoded = try decode(0xE3500001, 0x08000018);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .cmp_imm = .{
            .rn = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads add register" {
    const decoded = try decode(0xE0830002, 0x08001F64);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .add_reg = .{
            .rd = 0,
            .rn = 3,
            .rm = 2,
        } },
        decoded,
    );
}

test "decode reads adds immediate" {
    const decoded = try decode(0xE2900001, 0x08000314);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .adds_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads adcs immediate" {
    const decoded = try decode(0xE2B00001, 0x08000344);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .adcs_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads sbcs immediate" {
    const decoded = try decode(0xE2D00000, 0x080003A8);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .sbcs_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 0,
        } },
        decoded,
    );
}

test "decode reads mla" {
    const decoded = try decode(0xE0200194, 0x0800000C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mla = .{
            .rd = 0,
            .rm = 4,
            .rs = 1,
            .ra = 0,
        } },
        decoded,
    );
}

test "decode reads orr register with rotate-right immediate" {
    const decoded = try decode(0xE1833C64, 0x08001F0C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .orr_shift_reg = .{
            .rd = 3,
            .rn = 3,
            .rm = 4,
            .shift = .{
                .kind = .ror,
                .amount = 24,
            },
        } },
        decoded,
    );
}

test "decode reads movs register" {
    const decoded = try decode(0xE1B0C00C, 0x08001D74);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .movs_reg = .{
            .rd = 12,
            .rm = 12,
        } },
        decoded,
    );
}

test "decode reads thumb mov immediate" {
    const decoded = try decodeThumb(0x2007, 0x08000008);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .movs_imm = .{ .rd = 0, .imm = 7 } },
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
