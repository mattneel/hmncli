const std = @import("std");
const c = @import("capstone_c");

pub const CapstoneVersion = struct {
    major: u16,
    minor: u16,
};

pub const max_arm_operands = 36;

pub const ArmMemoryOperand = struct {
    base: u32,
    index: u32,
    scale: i32,
    disp: i32,
};

pub const ArmOperand = struct {
    subtracted: bool,
    access: u8,
    value: Value,

    pub const Value = union(enum) {
        reg: u32,
        imm: i64,
        mem: ArmMemoryOperand,
        unsupported: u32,
    };

    fn empty() ArmOperand {
        return .{
            .subtracted = false,
            .access = 0,
            .value = .{ .unsupported = 0 },
        };
    }
};

pub const ArmInstruction = struct {
    id: u32,
    address: u64,
    size: u16,
    cc: u32,
    update_flags: bool,
    post_index: bool,
    writeback: bool,
    operand_count: u8,
    operands: [max_arm_operands]ArmOperand,

    fn empty() ArmInstruction {
        var operands: [max_arm_operands]ArmOperand = undefined;
        for (&operands) |*operand| operand.* = ArmOperand.empty();
        return .{
            .id = 0,
            .address = 0,
            .size = 0,
            .cc = 0,
            .update_flags = false,
            .post_index = false,
            .writeback = false,
            .operand_count = 0,
            .operands = operands,
        };
    }
};

pub const DisassembleError = error{
    OpenFailed,
    OptionFailed,
    DisassembleFailed,
    MissingDetail,
};

pub fn version() CapstoneVersion {
    var major: c_int = 0;
    var minor: c_int = 0;
    _ = c.cs_version(&major, &minor);
    return .{
        .major = @intCast(major),
        .minor = @intCast(minor),
    };
}

pub fn disassembleOneArm32(word: u32, address: u64) DisassembleError!ArmInstruction {
    var word_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &word_bytes, word, .little);
    return disassembleOne(&word_bytes, address, c.CS_MODE_ARM);
}

pub fn disassembleOneThumb16(halfword: u16, address: u64) DisassembleError!ArmInstruction {
    var halfword_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &halfword_bytes, halfword, .little);
    return disassembleOne(&halfword_bytes, address, c.CS_MODE_THUMB);
}

fn disassembleOne(bytes: []const u8, address: u64, mode: u32) DisassembleError!ArmInstruction {
    var handle: usize = 0;
    if (c.cs_open(c.CS_ARCH_ARM, mode, &handle) != c.CS_ERR_OK) return error.OpenFailed;
    defer _ = c.cs_close(&handle);

    if (c.cs_option(handle, c.CS_OPT_DETAIL, c.CS_OPT_ON) != c.CS_ERR_OK) return error.OptionFailed;

    var insn_ptr: [*c]c.cs_insn = null;
    const decoded_count = c.cs_disasm(handle, bytes.ptr, bytes.len, address, 1, &insn_ptr);
    if (decoded_count != 1 or insn_ptr == null) return error.DisassembleFailed;
    defer c.cs_free(insn_ptr, decoded_count);

    const decoded = insn_ptr[0];
    if (decoded.detail == null) return error.MissingDetail;

    const detail = decoded.detail[0];
    const arm = detail.unnamed_0.arm;
    var result = ArmInstruction.empty();
    result.id = decoded.id;
    result.address = decoded.address;
    result.size = decoded.size;
    result.cc = @intCast(arm.cc);
    result.update_flags = arm.update_flags;
    result.post_index = arm.post_index;
    result.writeback = detail.writeback;
    result.operand_count = arm.op_count;

    for (0..arm.op_count) |index| {
        const operand = arm.operands[index];
        result.operands[index] = .{
            .subtracted = operand.subtracted,
            .access = operand.access,
            .value = switch (operand.type) {
                c.ARM_OP_REG => .{ .reg = @intCast(operand.unnamed_0.reg) },
                c.ARM_OP_IMM => .{ .imm = operand.unnamed_0.imm },
                c.ARM_OP_MEM => .{ .mem = .{
                    .base = @intCast(operand.unnamed_0.mem.base),
                    .index = @intCast(operand.unnamed_0.mem.index),
                    .scale = operand.unnamed_0.mem.scale,
                    .disp = operand.unnamed_0.mem.disp,
                } },
                else => .{ .unsupported = @intCast(operand.type) },
            },
        };
    }

    return result;
}

test "capstone library reports a usable major version" {
    const actual = version();
    try std.testing.expect(actual.major >= 5);
}

test "translated capstone module exposes ARM constants" {
    try std.testing.expectEqual(c.CS_ARCH_ARM, 0);
    try std.testing.expectEqual(c.CS_MODE_ARM, 0);
}

test "capstone exposes structured branch detail" {
    const actual = try disassembleOneArm32(0xEA00002E, 0x08000000);
    try std.testing.expectEqual(@as(u32, c.ARM_INS_B), actual.id);
    try std.testing.expectEqual(@as(u64, 0x08000000), actual.address);
    try std.testing.expectEqual(@as(u16, 4), actual.size);
    try std.testing.expectEqual(@as(u32, c.ARMCC_AL), actual.cc);
    try std.testing.expectEqual(@as(u8, 1), actual.operand_count);
    switch (actual.operands[0].value) {
        .imm => |imm| try std.testing.expectEqual(@as(i64, 0x080000C0), imm),
        else => return error.TestUnexpectedResult,
    }
}

test "capstone exposes structured store detail" {
    const actual = try disassembleOneArm32(0xE7810002, 0x08000118);
    try std.testing.expectEqual(@as(u32, c.ARM_INS_STR), actual.id);
    try std.testing.expectEqual(@as(u8, 2), actual.operand_count);
    switch (actual.operands[0].value) {
        .reg => |reg| try std.testing.expectEqual(@as(u32, c.ARM_REG_R0), reg),
        else => return error.TestUnexpectedResult,
    }
    switch (actual.operands[1].value) {
        .mem => |mem| {
            try std.testing.expectEqual(@as(u32, c.ARM_REG_R1), mem.base);
            try std.testing.expectEqual(@as(u32, c.ARM_REG_R2), mem.index);
            try std.testing.expectEqual(@as(i32, 0), mem.disp);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "capstone exposes structured thumb detail" {
    const actual = try disassembleOneThumb16(0x2007, 0x08000008);
    try std.testing.expectEqual(@as(u32, c.ARM_INS_MOV), actual.id);
    try std.testing.expectEqual(@as(u64, 0x08000008), actual.address);
    try std.testing.expectEqual(@as(u16, 2), actual.size);
    try std.testing.expectEqual(@as(u32, c.ARMCC_AL), actual.cc);
    try std.testing.expectEqual(@as(u8, 2), actual.operand_count);
    switch (actual.operands[0].value) {
        .reg => |reg| try std.testing.expectEqual(@as(u32, c.ARM_REG_R0), reg),
        else => return error.TestUnexpectedResult,
    }
    switch (actual.operands[1].value) {
        .imm => |imm| try std.testing.expectEqual(@as(i64, 7), imm),
        else => return error.TestUnexpectedResult,
    }
}
