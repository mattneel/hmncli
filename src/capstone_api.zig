const std = @import("std");

extern fn cs_version(major: ?*c_int, minor: ?*c_int) c_uint;
extern fn cs_open(arch: c_int, mode: c_int, handle: *usize) c_int;
extern fn cs_option(handle: usize, option_type: c_int, value: usize) c_int;
extern fn cs_disasm(
    handle: usize,
    code: [*]const u8,
    code_size: usize,
    address: u64,
    count: usize,
    insn: *?[*]const CsInsn,
) usize;
extern fn cs_free(insn: [*]const CsInsn, count: usize) void;
extern fn cs_close(handle: *usize) c_int;

const cs_arch_arm = 0;
const cs_mode_arm = 0;
const cs_opt_detail = 2;
const cs_opt_off = 0;

const CsInsn = extern struct {
    id: c_uint,
    alias_id: u64,
    address: u64,
    size: u16,
    bytes: [24]u8,
    mnemonic: [32]c_char,
    op_str: [160]c_char,
    is_alias: bool,
    uses_alias_details: bool,
    detail: ?*anyopaque,
};

pub const CapstoneVersion = struct {
    major: u16,
    minor: u16,
};

pub const InstructionText = struct {
    address: u64,
    size: u16,
    mnemonic: [32]u8,
    mnemonic_len: u8,
    operands: [160]u8,
    operands_len: u8,

    pub fn mnemonicSlice(self: *const InstructionText) []const u8 {
        return self.mnemonic[0..self.mnemonic_len];
    }

    pub fn operandsSlice(self: *const InstructionText) []const u8 {
        return self.operands[0..self.operands_len];
    }
};

pub const DisassembleError = error{
    OpenFailed,
    OptionFailed,
    DisassembleFailed,
};

pub fn version() CapstoneVersion {
    var major: c_int = 0;
    var minor: c_int = 0;
    _ = cs_version(&major, &minor);
    return .{
        .major = @intCast(major),
        .minor = @intCast(minor),
    };
}

pub fn disassembleOneArm32(word: u32, address: u64) DisassembleError!InstructionText {
    var handle: usize = 0;
    if (cs_open(cs_arch_arm, cs_mode_arm, &handle) != 0) return error.OpenFailed;
    defer _ = cs_close(&handle);

    if (cs_option(handle, cs_opt_detail, cs_opt_off) != 0) return error.OptionFailed;

    var word_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &word_bytes, word, .little);

    var insn_ptr: ?[*]const CsInsn = null;
    const decoded_count = cs_disasm(handle, &word_bytes, word_bytes.len, address, 1, &insn_ptr);
    if (decoded_count != 1 or insn_ptr == null) return error.DisassembleFailed;
    defer cs_free(insn_ptr.?, decoded_count);

    const decoded = insn_ptr.?[0];
    return .{
        .address = decoded.address,
        .size = decoded.size,
        .mnemonic = copyCString(32, decoded.mnemonic),
        .mnemonic_len = cStringLen(&decoded.mnemonic),
        .operands = copyCString(160, decoded.op_str),
        .operands_len = cStringLen(&decoded.op_str),
    };
}

fn cStringLen(buffer: []const c_char) u8 {
    var index: usize = 0;
    while (index < buffer.len and buffer[index] != 0) : (index += 1) {}
    return @intCast(index);
}

fn copyCString(comptime N: usize, source: [N]c_char) [N]u8 {
    var output: [N]u8 = [_]u8{0} ** N;
    for (source, 0..) |value, index| {
        output[index] = @bitCast(value);
    }
    return output;
}

test "capstone library reports a usable major version" {
    const actual = version();
    try std.testing.expect(actual.major >= 5);
}

test "capstone disassembles an ARM branch mnemonic" {
    const actual = try disassembleOneArm32(0xEA00002E, 0x08000000);
    try std.testing.expectEqual(@as(u64, 0x08000000), actual.address);
    try std.testing.expectEqual(@as(u16, 4), actual.size);
    try std.testing.expectEqualStrings("b", actual.mnemonicSlice());
    try std.testing.expect(actual.operandsSlice().len != 0);
}
