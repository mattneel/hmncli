const std = @import("std");

pub const ParseError = error{
    InvalidCommand,
    DeferredToPhase1,
};

pub const Command = union(enum) {
    doc: []const u8,
    status: ?[]const u8,
    test_shim: []const u8,
    test_instruction: []const u8,
};

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return error.InvalidCommand;
    if (std.mem.eql(u8, args[1], "build")) return error.DeferredToPhase1;
    if (std.mem.eql(u8, args[1], "doc") and args.len == 3) return .{ .doc = args[2] };
    if (std.mem.eql(u8, args[1], "status")) {
        if (args.len == 2) return .{ .status = null };
        if (args.len == 4 and std.mem.eql(u8, args[2], "--trace")) return .{ .status = args[3] };
        return error.InvalidCommand;
    }
    if (std.mem.eql(u8, args[1], "test") and args.len == 4) {
        if (std.mem.eql(u8, args[2], "--shim")) return .{ .test_shim = args[3] };
        if (std.mem.eql(u8, args[2], "--instruction")) return .{ .test_instruction = args[3] };
    }
    return error.InvalidCommand;
}

test "parse accepts declaration commands" {
    try std.testing.expectEqualDeep(
        Command{ .doc = "shim/gba/Div" },
        try parse(&.{"hmncli", "doc", "shim/gba/Div"}),
    );
    try std.testing.expectEqualDeep(
        Command{ .test_instruction = "armv4t/mov_imm" },
        try parse(&.{"hmncli", "test", "--instruction", "armv4t/mov_imm"}),
    );
    try std.testing.expectEqualDeep(
        Command{ .test_shim = "gba/Div" },
        try parse(&.{"hmncli", "test", "--shim", "gba/Div"}),
    );
}

test "build command is explicitly deferred to phase 1" {
    try std.testing.expectError(
        error.DeferredToPhase1,
        parse(&.{"hmncli", "build", "arm.gba"}),
    );
}
