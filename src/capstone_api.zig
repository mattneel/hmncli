const std = @import("std");
const c = @import("capstone_c");

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
    _ = c.cs_version(&major, &minor);
    return .{
        .major = @intCast(major),
        .minor = @intCast(minor),
    };
}

pub fn disassembleOneArm32(word: u32, address: u64) DisassembleError!InstructionText {
    var handle: usize = 0;
    if (c.cs_open(c.CS_ARCH_ARM, c.CS_MODE_ARM, &handle) != c.CS_ERR_OK) return error.OpenFailed;
    defer _ = c.cs_close(&handle);

    if (c.cs_option(handle, c.CS_OPT_DETAIL, c.CS_OPT_OFF) != c.CS_ERR_OK) return error.OptionFailed;

    var word_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &word_bytes, word, .little);

    var insn_ptr: [*c]c.cs_insn = null;
    const decoded_count = c.cs_disasm(handle, &word_bytes, word_bytes.len, address, 1, &insn_ptr);
    if (decoded_count != 1 or insn_ptr == null) return error.DisassembleFailed;
    defer c.cs_free(insn_ptr, decoded_count);

    const decoded = insn_ptr[0];
    return .{
        .address = decoded.address,
        .size = decoded.size,
        .mnemonic = copyCString(32, decoded.mnemonic),
        .mnemonic_len = cStringLen(decoded.mnemonic[0..]),
        .operands = copyCString(160, decoded.op_str),
        .operands_len = cStringLen(decoded.op_str[0..]),
    };
}

fn cStringLen(buffer: []const u8) u8 {
    var index: usize = 0;
    while (index < buffer.len and buffer[index] != 0) : (index += 1) {}
    return @intCast(index);
}

fn copyCString(comptime N: usize, source: [N]u8) [N]u8 {
    var output: [N]u8 = [_]u8{0} ** N;
    for (source, 0..) |value, index| {
        output[index] = value;
    }
    return output;
}

test "capstone library reports a usable major version" {
    const actual = version();
    try std.testing.expect(actual.major >= 5);
}

test "translated capstone module exposes ARM constants" {
    try std.testing.expectEqual(c.CS_ARCH_ARM, 0);
    try std.testing.expectEqual(c.CS_MODE_ARM, 0);
}

test "capstone disassembles an ARM branch mnemonic" {
    const actual = try disassembleOneArm32(0xEA00002E, 0x08000000);
    try std.testing.expectEqual(@as(u64, 0x08000000), actual.address);
    try std.testing.expectEqual(@as(u16, 4), actual.size);
    try std.testing.expectEqualStrings("b", actual.mnemonicSlice());
    try std.testing.expect(actual.operandsSlice().len != 0);
}
