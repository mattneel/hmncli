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
    rrx,
};

pub const ShiftImm = struct {
    kind: ShiftKind,
    amount: u32,
};

pub const ShiftReg = struct {
    kind: ShiftKind,
    rs: u4,
};

pub const ShiftOperand = union(enum) {
    imm: ShiftImm,
    reg: ShiftReg,
};

pub const StoreIndex = struct {
    offset: Offset,
    subtract: bool,
};

pub const StoreAddressing = union(enum) {
    offset: StoreIndex,
    pre_index: StoreIndex,
    post_index: StoreIndex,
};

pub const BlockTransferMode = enum {
    ia,
    ib,
    da,
    db,
};

pub const StatusFlags = struct {
    n: bool,
    z: bool,
    c: bool,
    v: bool,
};

pub const PsrTarget = enum {
    cpsr,
    spsr,
};

pub const DecodedInstruction = union(enum) {
    nop,
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
        carry: ?bool,
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
    eor_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    bic_imm: struct {
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
    adcs_shift_reg: struct {
        rd: u4,
        rn: u4,
        rm: u4,
        shift: ShiftOperand,
    },
    adc_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    sbcs_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    sbc_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    add_reg: struct {
        rd: u4,
        rn: u4,
        rm: u4,
    },
    add_shift_reg: struct {
        rd: u4,
        rn: u4,
        rm: u4,
        shift: ShiftOperand,
    },
    rsb_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
    },
    rsc_imm: struct {
        rd: u4,
        rn: u4,
        imm: u32,
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
    lsl_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    asr_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    asr_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
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
    lsrs_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    lsr_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    lsrs_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    asrs_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    asrs_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    ror_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    ror_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    rors_imm: struct {
        rd: u4,
        rm: u4,
        imm: u32,
    },
    rors_reg: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    rrxs: struct {
        rd: u4,
        rm: u4,
    },
    mul: struct {
        rd: u4,
        rm: u4,
        rs: u4,
    },
    mla: struct {
        rd: u4,
        rm: u4,
        rs: u4,
        ra: u4,
    },
    umull: struct {
        rdlo: u4,
        rdhi: u4,
        rm: u4,
        rs: u4,
    },
    umlal: struct {
        rdlo: u4,
        rdhi: u4,
        rm: u4,
        rs: u4,
    },
    smull: struct {
        rdlo: u4,
        rdhi: u4,
        rm: u4,
        rs: u4,
    },
    smlal: struct {
        rdlo: u4,
        rdhi: u4,
        rm: u4,
        rs: u4,
    },
    swp_word: struct {
        rd: u4,
        rm: u4,
        base: u4,
    },
    swp_byte: struct {
        rd: u4,
        rm: u4,
        base: u4,
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
    ldr_word_imm_signed: struct {
        rd: u4,
        base: u4,
        offset: u32,
    },
    ldr_byte_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
    },
    ldr_halfword_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
    },
    ldr_halfword_pre_index_reg: struct {
        rd: u4,
        base: u4,
        rm: u4,
        subtract: bool,
    },
    ldr_halfword_pre_index_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
        subtract: bool,
    },
    ldr_halfword_post_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
        subtract: bool,
    },
    ldr_signed_halfword_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
    },
    ldr_signed_byte_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
    },
    ldr_word_pre_index_reg_shift: struct {
        rd: u4,
        base: u4,
        rm: u4,
        shift: ShiftImm,
        subtract: bool,
    },
    ldr_word_pre_index_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
        subtract: bool,
    },
    ldr_word_post_imm: struct {
        rd: u4,
        base: u4,
        offset: u32,
        subtract: bool,
    },
    ldr_pc_post_imm_target: struct {
        base: u4,
        offset: u32,
        subtract: bool,
        target: u32,
    },
    stm: struct {
        base: u4,
        mask: u16,
        writeback: bool,
        mode: BlockTransferMode,
    },
    stm_empty: struct {
        base: u4,
        writeback: bool,
        mode: BlockTransferMode,
    },
    push: u16,
    pop: u16,
    ldm: struct {
        base: u4,
        mask: u16,
        writeback: bool,
        mode: BlockTransferMode,
    },
    ldm_empty: struct {
        base: u4,
        writeback: bool,
        mode: BlockTransferMode,
    },
    ldm_pc_target: struct {
        base: u4,
        mask: u16,
        writeback: bool,
        mode: BlockTransferMode,
        target: u32,
    },
    ldm_empty_pc_target: struct {
        base: u4,
        writeback: bool,
        mode: BlockTransferMode,
        target: u32,
    },
    tst_imm: struct {
        rn: u4,
        imm: u32,
        carry: ?bool,
    },
    cmp_imm: struct {
        rn: u4,
        imm: u32,
    },
    cmp_reg: struct {
        rn: u4,
        rm: u4,
    },
    cmn_imm: struct {
        rn: u4,
        imm: u32,
    },
    cmn_reg: struct {
        rn: u4,
        rm: u4,
    },
    teq_imm: struct {
        rn: u4,
        imm: u32,
        carry: ?bool,
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
    mrs_psr: struct {
        rd: u4,
        target: PsrTarget,
    },
    msr_psr_imm: struct {
        target: PsrTarget,
        field_mask: u4,
        value: u32,
    },
    msr_psr_reg: struct {
        target: PsrTarget,
        field_mask: u4,
        rm: u4,
    },
    exception_return: struct {
        target: u32,
    },
    swi: struct {
        imm24: u24,
    },
};

pub fn decode(word: u32, address: u32) DecodeError!DecodedInstruction {
    if (isEmptyBlockTransfer(word)) return parseEmptyBlockTransfer(word);
    const insn = try capstone_api.disassembleOneArm32(word, address);
    return decodeInstruction(word, insn);
}

pub fn decodeThumb(halfword: u16, address: u32) DecodeError!DecodedInstruction {
    const insn = try capstone_api.disassembleOneThumb16(halfword, address);
    return decodeInstruction(halfword, insn);
}

fn decodeInstruction(raw_word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (raw_word == 0xE320F000) return .nop;
    return switch (insn.id) {
        c.ARM_INS_MOV => parseMov(raw_word, insn),
        c.ARM_INS_MVN => parseMvn(insn),
        c.ARM_INS_ADR => parseAdr(insn),
        c.ARM_INS_AND => parseAlu3(.and_imm, insn),
        c.ARM_INS_EOR => parseAlu3(.eor_imm, insn),
        c.ARM_INS_ORR => parseAlu3(.orr_imm, insn),
        c.ARM_INS_BIC => parseAlu3(.bic_imm, insn),
        c.ARM_INS_ADD => parseAdd(insn),
        c.ARM_INS_ADC => parseAdc(insn),
        c.ARM_INS_SBC => parseSbc(insn),
        c.ARM_INS_RSB => parseRsb(insn),
        c.ARM_INS_RSC => parseRsc(insn),
        c.ARM_INS_SUB, c.ARM_INS_SUBS => if (insn.update_flags)
            parseAlu3(.subs_imm, insn)
        else
            parseSub(insn),
        c.ARM_INS_LSL, c.ARM_INS_LSR, c.ARM_INS_ASR, c.ARM_INS_ROR => parseShift(insn),
        c.ARM_INS_MUL => parseMul(insn),
        c.ARM_INS_MLA => parseMla(insn),
        c.ARM_INS_UMULL => parseUmull(insn),
        c.ARM_INS_UMLAL => parseUmlal(insn),
        c.ARM_INS_SMULL => parseSmull(insn),
        c.ARM_INS_SMLAL => parseSmlal(insn),
        c.ARM_INS_SWP => parseSwp(insn, .word),
        c.ARM_INS_SWPB => parseSwp(insn, .byte),
        c.ARM_INS_LDR => parseLoad(raw_word, insn),
        c.ARM_INS_LDRB => parseByteLoad(insn),
        c.ARM_INS_LDRH => parseHalfwordLoad(raw_word, insn),
        c.ARM_INS_LDRSH => parseSignedHalfwordLoad(insn),
        c.ARM_INS_LDRSB => parseSignedByteLoad(insn),
        c.ARM_INS_STR => parseStore(raw_word, insn, .word),
        c.ARM_INS_STRB => parseStore(raw_word, insn, .byte),
        c.ARM_INS_STRH => parseStore(raw_word, insn, .halfword),
        c.ARM_INS_STM => parseStm(raw_word, insn, .ia),
        c.ARM_INS_STMDA => parseStm(raw_word, insn, .da),
        c.ARM_INS_STMDB => parseStmdb(raw_word, insn),
        c.ARM_INS_STMIB => parseStm(raw_word, insn, .ib),
        c.ARM_INS_LDM => parseLdm(raw_word, insn, .ia),
        c.ARM_INS_LDMDA => parseLdm(raw_word, insn, .da),
        c.ARM_INS_LDMDB => parseLdm(raw_word, insn, .db),
        c.ARM_INS_LDMIB => parseLdm(raw_word, insn, .ib),
        c.ARM_INS_TST => parseTst(raw_word, insn),
        c.ARM_INS_CMP => parseCmp(insn),
        c.ARM_INS_CMN => parseCmn(insn),
        c.ARM_INS_TEQ => parseTeq(raw_word, insn),
        c.ARM_INS_B => parseBranch(insn),
        c.ARM_INS_BL => parseBl(raw_word, insn),
        c.ARM_INS_BX => parseBx(insn),
        c.ARM_INS_MRS => parseMrs(raw_word),
        c.ARM_INS_MSR => parseMsr(raw_word),
        c.ARM_INS_SVC => parseSwi(insn),
        else => error.UnsupportedOpcode,
    };
}

fn isEmptyBlockTransfer(word: u32) bool {
    if (((word >> 25) & 0x7) != 0b100) return false;
    return (word & 0xFFFF) == 0;
}

fn parseEmptyBlockTransfer(word: u32) DecodeError!DecodedInstruction {
    const base: u4 = @truncate((word >> 16) & 0xF);
    const writeback = ((word >> 21) & 0x1) == 1;
    const load = ((word >> 20) & 0x1) == 1;
    const p = ((word >> 24) & 0x1) == 1;
    const u = ((word >> 23) & 0x1) == 1;
    const mode: BlockTransferMode = switch ((@as(u2, @intFromBool(p)) << 1) | @as(u2, @intFromBool(u))) {
        0b01 => .ia,
        0b11 => .ib,
        0b00 => .da,
        0b10 => .db,
    };

    return if (load)
        .{ .ldm_empty = .{
            .base = base,
            .writeback = writeback,
            .mode = mode,
        } }
    else
        .{ .stm_empty = .{
            .base = base,
            .writeback = writeback,
            .mode = mode,
        } };
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
        if (bit4 == 1) {
            const rs: u4 = @truncate((raw_word >> 8) & 0xF);
            return switch (shift_type) {
                0 => if (insn.update_flags)
                    .{ .lsls_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } }
                else
                    .{ .lsl_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } },
                1 => if (insn.update_flags)
                    .{ .lsrs_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } }
                else
                    .{ .lsr_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } },
                2 => if (insn.update_flags)
                    .{ .asrs_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } }
                else
                    .{ .asr_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } },
                3 => if (insn.update_flags)
                    .{ .rors_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } }
                else
                    .{ .ror_reg = .{
                        .rd = rd,
                        .rm = rm,
                        .rs = rs,
                    } },
                else => error.UnsupportedOpcode,
            };
        }
        if (shift_type == 3 and shift_imm == 0) {
            return if (insn.update_flags)
                .{ .rrxs = .{
                    .rd = rd,
                    .rm = rm,
                } }
            else
                error.UnsupportedOpcode;
        }
        if (shift_imm != 0 or shift_type != 0) {
            const normalized_shift_imm = normalizeImmediateShiftAmount(shift_type, shift_imm);
            return switch (shift_type) {
                0 => if (insn.update_flags)
                    .{ .lsls_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } }
                else
                    .{ .lsl_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } },
                1 => if (insn.update_flags)
                    .{ .lsrs_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } }
                else
                    .{ .lsr_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } },
                2 => if (insn.update_flags)
                    .{ .asrs_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } }
                else
                    .{ .asr_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } },
                3 => if (insn.update_flags)
                    .{ .rors_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
                    } }
                else
                    .{ .ror_imm = .{
                        .rd = rd,
                        .rm = rm,
                        .imm = normalized_shift_imm,
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
                .carry = if (insn.size == 4 and ((raw_word >> 25) & 1) == 1)
                    armImmediateCarryOut(raw_word, try parseU32Immediate(imm))
                else
                    null,
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

fn normalizeImmediateShiftAmount(shift_type: u32, shift_imm: u32) u32 {
    return switch (shift_type) {
        1, 2 => if (shift_imm == 0) 32 else shift_imm,
        else => shift_imm,
    };
}

fn armImmediateCarryOut(raw_word: u32, imm: u32) ?bool {
    const rotate = ((raw_word >> 8) & 0xF) * 2;
    if (rotate == 0) return null;
    return ((imm >> 31) & 1) != 0;
}

fn parseAlu3(
    comptime tag: enum { orr_imm, and_imm, eor_imm, bic_imm, subs_imm },
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
        .eor_imm => .{ .eor_imm = .{
            .rd = rd,
            .rn = rn,
            .imm = try operandImmediateU32(insn, 2),
        } },
        .bic_imm => .{ .bic_imm = .{
            .rd = rd,
            .rn = rn,
            .imm = try operandImmediateU32(insn, 2),
        } },
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
        .reg => |reg| blk: {
            const rm = try parseRegisterId(reg);
            if (source.shift_type == c.ARM_SFT_INVALID) {
                break :blk .{ .add_reg = .{
                    .rd = rd,
                    .rn = rn,
                    .rm = rm,
                } };
            }
            break :blk .{ .add_shift_reg = .{
                .rd = rd,
                .rn = rn,
                .rm = rm,
                .shift = try parseShiftOperand(source),
            } };
        },
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
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    const source = operandAt(insn, 2);
    if (source.subtracted) return error.UnsupportedOpcode;

    if (insn.update_flags and source.value == .reg) {
        return .{ .adcs_shift_reg = .{
            .rd = try operandRegister(insn, 0),
            .rn = try operandRegister(insn, 1),
            .rm = try operandRegister(insn, 2),
            .shift = try parseShiftOperand(source),
        } };
    }

    return if (insn.update_flags)
        .{ .adcs_imm = .{
            .rd = try operandRegister(insn, 0),
            .rn = try operandRegister(insn, 1),
            .imm = try operandImmediateU32(insn, 2),
        } }
    else
        .{ .adc_imm = .{
            .rd = try operandRegister(insn, 0),
            .rn = try operandRegister(insn, 1),
            .imm = try operandImmediateU32(insn, 2),
        } };
}

fn parseSbc(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return if (insn.update_flags)
        .{ .sbcs_imm = .{
            .rd = try operandRegister(insn, 0),
            .rn = try operandRegister(insn, 1),
            .imm = try operandImmediateU32(insn, 2),
        } }
    else
        .{ .sbc_imm = .{
            .rd = try operandRegister(insn, 0),
            .rn = try operandRegister(insn, 1),
            .imm = try operandImmediateU32(insn, 2),
        } };
}

fn parseRsb(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.update_flags) return error.UnsupportedOpcode;
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return .{ .rsb_imm = .{
        .rd = try operandRegister(insn, 0),
        .rn = try operandRegister(insn, 1),
        .imm = try operandImmediateU32(insn, 2),
    } };
}

fn parseRsc(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.update_flags) return error.UnsupportedOpcode;
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return .{ .rsc_imm = .{
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
            c.ARM_INS_LSR => if (insn.update_flags)
                .{ .lsrs_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = normalizeImmediateShiftAmount(1, try parseU32Immediate(imm)),
                } }
            else
                .{ .lsr_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = normalizeImmediateShiftAmount(1, try parseU32Immediate(imm)),
                } },
            c.ARM_INS_ASR => if (insn.update_flags)
                .{ .asrs_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = normalizeImmediateShiftAmount(2, try parseU32Immediate(imm)),
                } }
            else
                .{ .asr_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = normalizeImmediateShiftAmount(2, try parseU32Immediate(imm)),
                } },
            c.ARM_INS_ROR => if (insn.update_flags)
                .{ .rors_imm = .{
                    .rd = rd,
                    .rm = rm,
                    .imm = try parseU32Immediate(imm),
                } }
            else
                .{ .ror_imm = .{
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
                .{ .lsl_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } },
            c.ARM_INS_LSR => if (insn.update_flags)
                .{ .lsrs_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } }
            else
                .{ .lsr_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } },
            c.ARM_INS_ASR => if (insn.update_flags)
                .{ .asrs_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } }
            else
                .{ .asr_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } },
            c.ARM_INS_ROR => if (insn.update_flags)
                .{ .rors_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } }
            else
                .{ .ror_reg = .{
                    .rd = rd,
                    .rm = rm,
                    .rs = try parseRegisterId(reg),
                } },
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

fn parseMul(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    return .{ .mul = .{
        .rd = try operandRegister(insn, 0),
        .rm = try operandRegister(insn, 1),
        .rs = try operandRegister(insn, 2),
    } };
}

fn parseUmull(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 4) return error.UnsupportedOpcode;
    return .{ .umull = .{
        .rdlo = try operandRegister(insn, 0),
        .rdhi = try operandRegister(insn, 1),
        .rm = try operandRegister(insn, 2),
        .rs = try operandRegister(insn, 3),
    } };
}

fn parseUmlal(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 4) return error.UnsupportedOpcode;
    return .{ .umlal = .{
        .rdlo = try operandRegister(insn, 0),
        .rdhi = try operandRegister(insn, 1),
        .rm = try operandRegister(insn, 2),
        .rs = try operandRegister(insn, 3),
    } };
}

fn parseSmull(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 4) return error.UnsupportedOpcode;
    return .{ .smull = .{
        .rdlo = try operandRegister(insn, 0),
        .rdhi = try operandRegister(insn, 1),
        .rm = try operandRegister(insn, 2),
        .rs = try operandRegister(insn, 3),
    } };
}

fn parseSmlal(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 4) return error.UnsupportedOpcode;
    return .{ .smlal = .{
        .rdlo = try operandRegister(insn, 0),
        .rdhi = try operandRegister(insn, 1),
        .rm = try operandRegister(insn, 2),
        .rs = try operandRegister(insn, 3),
    } };
}

fn parseSwp(insn: capstone_api.ArmInstruction, size: StoreSize) DecodeError!DecodedInstruction {
    if (insn.operand_count != 3) return error.UnsupportedOpcode;
    const mem_operand = operandAt(insn, 2);
    if (mem_operand.subtracted) return error.UnsupportedOpcode;
    const mem = switch (mem_operand.value) {
        .mem => |mem| mem,
        else => return error.UnsupportedOpcode,
    };
    if (mem.index != c.ARM_REG_INVALID) return error.UnsupportedOpcode;
    if (mem.disp != 0) return error.UnsupportedOpcode;
    const rd = try operandRegister(insn, 0);
    const rm = try operandRegister(insn, 1);
    const base = try parseRegisterId(mem.base);
    return switch (size) {
        .word => .{ .swp_word = .{
            .rd = rd,
            .rm = rm,
            .base = base,
        } },
        .byte => .{ .swp_byte = .{
            .rd = rd,
            .rm = rm,
            .base = base,
        } },
        .halfword => error.UnsupportedOpcode,
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

fn parseStore(raw_word: u32, insn: capstone_api.ArmInstruction, size: StoreSize) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;

    const src = try operandRegister(insn, 0);
    const mem_op = operandAt(insn, 1);
    const subtract = ((raw_word >> 23) & 1) == 0;

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
            .{ .post_index = .{ .offset = offset, .subtract = subtract } }
        else if (insn.writeback)
            .{ .pre_index = .{ .offset = offset, .subtract = subtract } }
        else
            .{ .offset = .{ .offset = offset, .subtract = subtract } },
        .size = size,
    } };
}

fn parseLoad(raw_word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;

    const rd = try operandRegister(insn, 0);
    const mem_op = operandAt(insn, 1);
    const subtract = ((raw_word >> 23) & 1) == 0;

    const mem = switch (mem_op.value) {
        .mem => |value| value,
        else => return error.UnsupportedOpcode,
    };

    if (mem.index != c.ARM_REG_INVALID) {
        if (mem.disp != 0) return error.UnsupportedOpcode;
        if (insn.post_index or !insn.writeback) return error.UnsupportedOpcode;
        return .{ .ldr_word_pre_index_reg_shift = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .rm = try parseRegisterId(mem.index),
            .shift = try parseShiftImm(mem_op),
            .subtract = subtract,
        } };
    }

    const offset: u32 = if (mem.disp < 0)
        @intCast(-mem.disp)
    else
        @intCast(mem.disp);
    if (mem.scale != 0 and mem.scale != 1) return error.UnsupportedOpcode;

    if (insn.post_index) {
        return .{ .ldr_word_post_imm = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .offset = offset,
            .subtract = subtract,
        } };
    }
    if (insn.writeback) {
        return .{ .ldr_word_pre_index_imm = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .offset = offset,
            .subtract = subtract,
        } };
    }
    if (subtract) {
        return .{ .ldr_word_imm_signed = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .offset = offset,
        } };
    }

    return .{ .ldr_word_imm = .{
        .rd = rd,
        .base = try parseRegisterId(mem.base),
        .offset = offset,
    } };
}

fn parseByteLoad(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
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

    return .{ .ldr_byte_imm = .{
        .rd = rd,
        .base = try parseRegisterId(mem.base),
        .offset = @intCast(mem.disp),
    } };
}

fn parseHalfwordLoad(raw_word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;

    const rd = try operandRegister(insn, 0);
    const mem_op = operandAt(insn, 1);
    const subtract = ((raw_word >> 23) & 1) == 0;

    const mem = switch (mem_op.value) {
        .mem => |value| value,
        else => return error.UnsupportedOpcode,
    };

    if (mem.index != c.ARM_REG_INVALID) {
        if (mem.disp != 0) return error.UnsupportedOpcode;
        if (insn.post_index or !insn.writeback) return error.UnsupportedOpcode;
        return .{ .ldr_halfword_pre_index_reg = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .rm = try parseRegisterId(mem.index),
            .subtract = subtract,
        } };
    }

    const offset: u32 = if (mem.disp < 0)
        @intCast(-mem.disp)
    else
        @intCast(mem.disp);
    if (mem.scale != 0 and mem.scale != 1) return error.UnsupportedOpcode;
    if (insn.post_index) {
        return .{ .ldr_halfword_post_imm = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .offset = offset,
            .subtract = subtract,
        } };
    }
    if (insn.writeback) {
        return .{ .ldr_halfword_pre_index_imm = .{
            .rd = rd,
            .base = try parseRegisterId(mem.base),
            .offset = offset,
            .subtract = subtract,
        } };
    }
    if (subtract) return error.UnsupportedOpcode;

    return .{ .ldr_halfword_imm = .{
        .rd = rd,
        .base = try parseRegisterId(mem.base),
        .offset = offset,
    } };
}

fn parseSignedHalfwordLoad(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
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
    if (insn.post_index or insn.writeback) return error.UnsupportedOpcode;

    return .{ .ldr_signed_halfword_imm = .{
        .rd = rd,
        .base = try parseRegisterId(mem.base),
        .offset = @intCast(mem.disp),
    } };
}

fn parseSignedByteLoad(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
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
    if (insn.post_index or insn.writeback) return error.UnsupportedOpcode;

    return .{ .ldr_signed_byte_imm = .{
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

fn parseStmdb(word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    const base_reg: u4 = @truncate((word >> 16) & 0xF);
    if (base_reg == 13) return parseStackTransfer(word, insn, .push);
    return parseStm(word, insn, .db);
}

fn parseStm(
    word: u32,
    insn: capstone_api.ArmInstruction,
    mode: BlockTransferMode,
) DecodeError!DecodedInstruction {
    const base_reg: u4 = @truncate((word >> 16) & 0xF);
    const register_mask: u16 = @truncate(word & 0xFFFF);

    if (register_mask == 0) return error.UnsupportedOpcode;

    return .{ .stm = .{
        .base = base_reg,
        .mask = register_mask,
        .writeback = insn.writeback,
        .mode = mode,
    } };
}

fn parseLdm(
    word: u32,
    insn: capstone_api.ArmInstruction,
    mode: BlockTransferMode,
) DecodeError!DecodedInstruction {
    const base_reg: u4 = @truncate((word >> 16) & 0xF);
    const register_mask: u16 = @truncate(word & 0xFFFF);

    if (register_mask == 0) return error.UnsupportedOpcode;
    if (mode == .ia and base_reg == 13 and insn.writeback) {
        return .{ .pop = register_mask };
    }

    return .{ .ldm = .{
        .base = base_reg,
        .mask = register_mask,
        .writeback = insn.writeback,
        .mode = mode,
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

fn parseTst(word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    return .{ .tst_imm = .{
        .rn = try operandRegister(insn, 0),
        .imm = try operandImmediateU32(insn, 1),
        .carry = armImmediateCarryOut(word, try operandImmediateU32(insn, 1)),
    } };
}

fn parseCmp(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    const rn = try operandRegister(insn, 0);
    const source = operandAt(insn, 1);
    if (source.subtracted) return error.UnsupportedOpcode;
    return switch (source.value) {
        .imm => |imm| .{ .cmp_imm = .{
            .rn = rn,
            .imm = try parseU32Immediate(imm),
        } },
        .reg => |reg| .{ .cmp_reg = .{
            .rn = rn,
            .rm = try parseRegisterId(reg),
        } },
        else => error.UnsupportedOpcode,
    };
}

fn parseCmn(insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    const rn = try operandRegister(insn, 0);
    const source = operandAt(insn, 1);
    if (source.subtracted) return error.UnsupportedOpcode;
    return switch (source.value) {
        .imm => |imm| .{ .cmn_imm = .{
            .rn = rn,
            .imm = try parseU32Immediate(imm),
        } },
        .reg => |reg| .{ .cmn_reg = .{
            .rn = rn,
            .rm = try parseRegisterId(reg),
        } },
        else => error.UnsupportedOpcode,
    };
}

fn parseTeq(word: u32, insn: capstone_api.ArmInstruction) DecodeError!DecodedInstruction {
    if (insn.operand_count != 2) return error.UnsupportedOpcode;
    return .{ .teq_imm = .{
        .rn = try operandRegister(insn, 0),
        .imm = try operandImmediateU32(insn, 1),
        .carry = armImmediateCarryOut(word, try operandImmediateU32(insn, 1)),
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

fn parseMrs(word: u32) DecodeError!DecodedInstruction {
    const target: PsrTarget = if (((word >> 22) & 0x1) == 1) .spsr else .cpsr;
    const rd: u4 = @truncate((word >> 12) & 0xF);
    if (rd == 15) return error.UnsupportedOpcode;
    return .{ .mrs_psr = .{
        .rd = rd,
        .target = target,
    } };
}

fn parseMsr(word: u32) DecodeError!DecodedInstruction {
    const is_immediate = ((word >> 25) & 0x1) == 1;
    const target: PsrTarget = if (((word >> 22) & 0x1) == 1) .spsr else .cpsr;
    const field_mask: u4 = @truncate((word >> 16) & 0xF);

    if (field_mask == 0) return error.UnsupportedOpcode;
    if ((field_mask & 0x6) != 0) return error.UnsupportedOpcode;

    if (is_immediate) {
        return .{ .msr_psr_imm = .{
            .target = target,
            .field_mask = field_mask,
            .value = decodeArmImmediate(word),
        } };
    }

    return .{ .msr_psr_reg = .{
        .target = target,
        .field_mask = field_mask,
        .rm = @truncate(word & 0xF),
    } };
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
    if (mem.index == c.ARM_REG_INVALID) {
        const disp: u32 = if (mem.disp < 0)
            @intCast(-mem.disp)
        else
            @intCast(mem.disp);
        return .{ .imm = disp };
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
        c.ARM_SFT_RRX => ShiftKind.rrx,
        else => return error.UnsupportedOpcode,
    };
    return .{
        .kind = kind,
        .amount = operand.shift_value,
    };
}

fn parseShiftOperand(operand: capstone_api.ArmOperand) DecodeError!ShiftOperand {
    return switch (operand.shift_type) {
        c.ARM_SFT_INVALID => .{ .imm = .{ .kind = .lsl, .amount = 0 } },
        c.ARM_SFT_LSL, c.ARM_SFT_LSR, c.ARM_SFT_ASR, c.ARM_SFT_ROR => .{ .imm = try parseShiftImm(operand) },
        c.ARM_SFT_LSL_REG => .{ .reg = .{
            .kind = .lsl,
            .rs = try parseRegisterId(operand.shift_value),
        } },
        c.ARM_SFT_LSR_REG => .{ .reg = .{
            .kind = .lsr,
            .rs = try parseRegisterId(operand.shift_value),
        } },
        c.ARM_SFT_ASR_REG => .{ .reg = .{
            .kind = .asr,
            .rs = try parseRegisterId(operand.shift_value),
        } },
        c.ARM_SFT_ROR_REG => .{ .reg = .{
            .kind = .ror,
            .rs = try parseRegisterId(operand.shift_value),
        } },
        else => error.UnsupportedOpcode,
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
        if (imm > std.math.maxInt(u32)) return error.UnsupportedOpcode;
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
        DecodedInstruction{ .movs_imm = .{ .rd = 0, .imm = 0, .carry = null } },
        decoded,
    );
}

test "decode reads movs immediate with the high bit set" {
    const decoded = try decode(0xE3B00102, 0x080002F0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .movs_imm = .{
            .rd = 0,
            .imm = 0x8000_0000,
            .carry = true,
        } },
        decoded,
    );
}

test "decode reads movs immediate with rotated carry clear" {
    const decoded = try decode(0xE3B006FF, 0x08000A18);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .movs_imm = .{
            .rd = 0,
            .imm = 0x0FF0_0000,
            .carry = false,
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
            .addressing = .{ .offset = .{
                .offset = .{ .reg = 2 },
                .subtract = false,
            } },
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
            .mode = .ia,
        } },
        decoded,
    );
}

test "decode reads stmib register mask" {
    const decoded = try decode(0xE9AB0003, 0x08001758);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .stm = .{
            .base = 11,
            .mask = 0x0003,
            .writeback = true,
            .mode = .ib,
        } },
        decoded,
    );
}

test "decode reads ldmda register mask" {
    const decoded = try decode(0xE83B000C, 0x0800175C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldm = .{
            .base = 11,
            .mask = 0x000C,
            .writeback = true,
            .mode = .da,
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
        DecodedInstruction{ .msr_psr_imm = .{
            .target = .cpsr,
            .field_mask = 0x8,
            .value = 0x4000_0000,
        } },
        decoded,
    );
}

test "decode reads msr cpsr_fc immediate" {
    const decoded = try decode(0xE329F011, 0x08000AE4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .msr_psr_imm = .{
            .target = .cpsr,
            .field_mask = 0x9,
            .value = 0x0000_0011,
        } },
        decoded,
    );
}

test "decode reads msr spsr_fc immediate" {
    const decoded = try decode(0xE369F01F, 0x08000AEC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .msr_psr_imm = .{
            .target = .spsr,
            .field_mask = 0x9,
            .value = 0x0000_001F,
        } },
        decoded,
    );
}

test "decode reads mrs cpsr and msr cpsr_fc register forms" {
    const mrs = try decode(0xE10F0000, 0x08000D34);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mrs_psr = .{
            .rd = 0,
            .target = .cpsr,
        } },
        mrs,
    );

    const msr = try decode(0xE129F000, 0x08000D3C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .msr_psr_reg = .{
            .target = .cpsr,
            .field_mask = 0x9,
            .rm = 0,
        } },
        msr,
    );
}

test "decode reads mrs spsr and msr spsr_fc register forms" {
    const mrs = try decode(0xE14F1000, 0x08000DF0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mrs_psr = .{
            .rd = 1,
            .target = .spsr,
        } },
        mrs,
    );

    const msr = try decode(0xE169F000, 0x08000DEC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .msr_psr_reg = .{
            .target = .spsr,
            .field_mask = 0x9,
            .rm = 0,
        } },
        msr,
    );
}

test "decode reads adcs with ror immediate and register shifts" {
    const imm = try decode(0xE0B00461, 0x08000C08);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .adcs_shift_reg = .{
            .rd = 0,
            .rn = 0,
            .rm = 1,
            .shift = .{ .imm = .{
                .kind = .ror,
                .amount = 8,
            } },
        } },
        imm,
    );

    const reg = try decode(0xE0B00271, 0x08000C74);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .adcs_shift_reg = .{
            .rd = 0,
            .rn = 0,
            .rm = 1,
            .shift = .{ .reg = .{
                .kind = .ror,
                .rs = 2,
            } },
        } },
        reg,
    );
}

test "decode reads mul and umull" {
    const mul = try decode(0xE0000091, 0x08000E18);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .mul = .{
            .rd = 0,
            .rm = 1,
            .rs = 0,
        } },
        mul,
    );

    const umull = try decode(0xE0832190, 0x08000ED4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .umull = .{
            .rdlo = 2,
            .rdhi = 3,
            .rm = 0,
            .rs = 1,
        } },
        umull,
    );
}

test "decode reads umlal smull and smlal" {
    const umlal = try decode(0xE0A32190, 0x08000F60);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .umlal = .{
            .rdlo = 2,
            .rdhi = 3,
            .rm = 0,
            .rs = 1,
        } },
        umlal,
    );

    const smull = try decode(0xE0C32190, 0x08000FC0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .smull = .{
            .rdlo = 2,
            .rdhi = 3,
            .rm = 0,
            .rs = 1,
        } },
        smull,
    );

    const smlal = try decode(0xE0E32190, 0x0800104C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .smlal = .{
            .rdlo = 2,
            .rdhi = 3,
            .rm = 0,
            .rs = 1,
        } },
        smlal,
    );
}

test "decode reads swp word detail" {
    const decoded = try decode(0xE10B1090, 0x08001678);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .swp_word = .{
            .rd = 1,
            .rm = 0,
            .base = 11,
        } },
        decoded,
    );
}

test "decode reads swp byte detail" {
    const decoded = try decode(0xE14B1090, 0x080016AC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .swp_byte = .{
            .rd = 1,
            .rm = 0,
            .base = 11,
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
            .addressing = .{ .offset = .{
                .offset = .{ .imm = 2 },
                .subtract = false,
            } },
            .size = .halfword,
        } },
        decoded,
    );
}

test "decode reads word store with subtracting immediate offset" {
    const decoded = try decode(0xE50B103C, 0x08001C94);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .store = .{
            .src = 1,
            .base = 11,
            .addressing = .{ .offset = .{
                .offset = .{ .imm = 60 },
                .subtract = true,
            } },
            .size = .word,
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
            .addressing = .{ .post_index = .{
                .offset = .{ .imm = 2 },
                .subtract = false,
            } },
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

test "decode reads ldr word signed immediate offset" {
    const decoded = try decode(0xE51F0008, 0x080013A8);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_word_imm_signed = .{
            .rd = 0,
            .base = 15,
            .offset = 8,
        } },
        decoded,
    );
}

test "decode reads ldr byte immediate" {
    const decoded = try decode(0xE5DB1000, 0x080011D0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_byte_imm = .{
            .rd = 1,
            .base = 11,
            .offset = 0,
        } },
        decoded,
    );
}

test "decode reads ldr halfword immediate" {
    const decoded = try decode(0xE1DB10B0, 0x08001414);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_halfword_imm = .{
            .rd = 1,
            .base = 11,
            .offset = 0,
        } },
        decoded,
    );
}

test "decode reads ldr halfword pre-index register" {
    const decoded = try decode(0xE13230B1, 0x080014EC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_halfword_pre_index_reg = .{
            .rd = 3,
            .base = 2,
            .rm = 1,
            .subtract = true,
        } },
        decoded,
    );
}

test "decode reads ldr halfword pre-index immediate" {
    const decoded = try decode(0xE1F000B4, 0x0800161C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_halfword_pre_index_imm = .{
            .rd = 0,
            .base = 0,
            .offset = 4,
            .subtract = false,
        } },
        decoded,
    );
}

test "decode reads ldr halfword post-index immediate" {
    const decoded = try decode(0xE0D000B4, 0x08001648);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_halfword_post_imm = .{
            .rd = 0,
            .base = 0,
            .offset = 4,
            .subtract = false,
        } },
        decoded,
    );
}

test "decode reads ldr signed halfword immediate" {
    const decoded = try decode(0xE1DB10F1, 0x08001570);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_signed_halfword_imm = .{
            .rd = 1,
            .base = 11,
            .offset = 1,
        } },
        decoded,
    );
}

test "decode reads ldr signed byte immediate" {
    const decoded = try decode(0xE1DB10D0, 0x08001490);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_signed_byte_imm = .{
            .rd = 1,
            .base = 11,
            .offset = 0,
        } },
        decoded,
    );
}

test "decode reads ldr word pre-index register shift" {
    const decoded = try decode(0xE7323101, 0x08001200);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_word_pre_index_reg_shift = .{
            .rd = 3,
            .base = 2,
            .rm = 1,
            .shift = .{
                .kind = .lsl,
                .amount = 2,
            },
            .subtract = true,
        } },
        decoded,
    );
}

test "decode reads ldr word post-index immediate" {
    const decoded = try decode(0xE49BF020, 0x080012A8);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_word_post_imm = .{
            .rd = 15,
            .base = 11,
            .offset = 32,
            .subtract = false,
        } },
        decoded,
    );
}

test "decode reads ldr word pre-index immediate" {
    const decoded = try decode(0xE5B00004, 0x0800132C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_word_pre_index_imm = .{
            .rd = 0,
            .base = 0,
            .offset = 4,
            .subtract = false,
        } },
        decoded,
    );
}

test "decode reads ldr word pre-index register rrx shift" {
    const decoded = try decode(0xE7B12060, 0x08001384);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ldr_word_pre_index_reg_shift = .{
            .rd = 2,
            .base = 1,
            .rm = 0,
            .shift = .{
                .kind = .rrx,
                .amount = 0,
            },
            .subtract = false,
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

test "decode reads asr immediate" {
    const decoded = try decode(0xE1A00340, 0x080005E4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .asr_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 6,
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

test "decode reads asrs immediate" {
    const decoded = try decode(0xE1B000C0, 0x08000618);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .asrs_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads asrs immediate with normalized #32 amount" {
    const decoded = try decode(0xE1B00040, 0x08000640);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .asrs_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 32,
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

test "decode reads ror immediate" {
    const decoded = try decode(0xE1A000E0, 0x08000678);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ror_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads rors immediate" {
    const decoded = try decode(0xE1B000E0, 0x08000698);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .rors_imm = .{
            .rd = 0,
            .rm = 0,
            .imm = 1,
        } },
        decoded,
    );
}

test "decode reads rrxs" {
    const decoded = try decode(0xE1B00060, 0x080006C4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .rrxs = .{
            .rd = 0,
            .rm = 0,
        } },
        decoded,
    );
}

test "decode reads rors register" {
    const decoded = try decode(0xE1B00170, 0x080006FC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .rors_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
        } },
        decoded,
    );
}

test "decode reads ror register" {
    const decoded = try decode(0xE1A00170, 0x08000724);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .ror_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
        } },
        decoded,
    );
}

test "decode reads lsl register" {
    const decoded = try decode(0xE1A00110, 0x08000780);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsl_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
        } },
        decoded,
    );
}

test "decode reads lsr register" {
    const decoded = try decode(0xE1A00130, 0x080007A4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsr_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
        } },
        decoded,
    );
}

test "decode reads lsrs register" {
    const decoded = try decode(0xE1B00130, 0x08000750);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .lsrs_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
        } },
        decoded,
    );
}

test "decode reads asrs register" {
    const decoded = try decode(0xE1B00150, 0x08000754);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .asrs_reg = .{
            .rd = 0,
            .rm = 0,
            .rs = 1,
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

test "decode reads eor immediate" {
    const decoded = try decode(0xE22000F0, 0x08000818);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .eor_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 0xF0,
        } },
        decoded,
    );
}

test "decode reads bic immediate" {
    const decoded = try decode(0xE3C0000F, 0x08000858);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .bic_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 0x0F,
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
            .carry = null,
        } },
        decoded,
    );
}

test "decode reads teq immediate" {
    const decoded = try decode(0xE33000FF, 0x080009D4);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .teq_imm = .{
            .rn = 0,
            .imm = 0xFF,
            .carry = null,
        } },
        decoded,
    );
}

test "decode reads tst immediate carry-out" {
    const decoded = try decode(0xE3100102, 0x08000CB0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .tst_imm = .{
            .rn = 0,
            .imm = 0x8000_0000,
            .carry = true,
        } },
        decoded,
    );
}

test "decode reads teq immediate carry-out" {
    const decoded = try decode(0xE3300102, 0x08000CBC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .teq_imm = .{
            .rn = 0,
            .imm = 0x8000_0000,
            .carry = true,
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

test "decode reads cmn register" {
    const decoded = try decode(0xE1700000, 0x0800099C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .cmn_reg = .{
            .rn = 0,
            .rm = 0,
        } },
        decoded,
    );
}

test "decode reads cmn immediate" {
    const decoded = try decode(0xE3700020, 0x08000E64);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .cmn_imm = .{
            .rn = 0,
            .imm = 32,
        } },
        decoded,
    );
}

test "decode reads cmp register" {
    const decoded = try decode(0xE1510000, 0x080005FC);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .cmp_reg = .{
            .rn = 1,
            .rm = 0,
        } },
        decoded,
    );
}

test "decode reads adc immediate" {
    const decoded = try decode(0xE2A00020, 0x0800089C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .adc_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 32,
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

test "decode reads rsb immediate" {
    const decoded = try decode(0xE2600040, 0x080008F0);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .rsb_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 64,
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

test "decode reads sbc immediate" {
    const decoded = try decode(0xE2C00020, 0x08000914);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .sbc_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 32,
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

test "decode reads rsc immediate" {
    const decoded = try decode(0xE2E00040, 0x0800094C);
    try std.testing.expectEqualDeep(
        DecodedInstruction{ .rsc_imm = .{
            .rd = 0,
            .rn = 0,
            .imm = 64,
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
        DecodedInstruction{ .movs_imm = .{ .rd = 0, .imm = 7, .carry = null } },
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
