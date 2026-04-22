const std = @import("std");

pub const ParseError = error{
    InvalidCommand,
    DeferredToPhase1,
};

pub const OutputMode = enum {
    auto,
    frame_raw,
};

pub const BuildCommand = struct {
    rom_path: []const u8,
    machine_name: []const u8,
    output_path: []const u8,
    target: ?[]const u8 = null,
    output_mode: OutputMode = .auto,
    max_instructions: ?u64 = null,
};

pub const Command = union(enum) {
    build: BuildCommand,
    doc: []const u8,
    status: ?[]const u8,
    test_shim: []const u8,
    test_instruction: []const u8,
};

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return error.InvalidCommand;
    if (std.mem.eql(u8, args[1], "build")) return parseBuild(args);
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

fn parseBuild(args: []const []const u8) ParseError!Command {
    if (args.len < 7) return error.InvalidCommand;

    var build = BuildCommand{
        .rom_path = args[2],
        .machine_name = "",
        .output_path = "",
    };

    var index: usize = 3;
    while (index < args.len) : (index += 2) {
        const flag = args[index];
        const value_index = index + 1;
        if (value_index >= args.len) return error.InvalidCommand;
        const value = args[value_index];

        if (std.mem.eql(u8, flag, "--machine")) {
            build.machine_name = value;
            continue;
        }
        if (std.mem.eql(u8, flag, "--target")) {
            build.target = value;
            continue;
        }
        if (std.mem.eql(u8, flag, "--output")) {
            if (std.mem.eql(u8, value, "frame_raw")) {
                build.output_mode = .frame_raw;
                continue;
            }
            return error.InvalidCommand;
        }
        if (std.mem.eql(u8, flag, "--max-instructions")) {
            build.max_instructions = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidCommand;
            continue;
        }
        if (std.mem.eql(u8, flag, "-o")) {
            build.output_path = value;
            continue;
        }
        return error.InvalidCommand;
    }

    if (build.machine_name.len == 0 or build.output_path.len == 0) return error.InvalidCommand;
    if (build.output_mode == .frame_raw and build.max_instructions == null) return error.InvalidCommand;
    return .{ .build = build };
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

test "parse accepts the first phase 1 build command shape" {
    try std.testing.expectEqualDeep(
        Command{ .build = .{
            .rom_path = "tests/fixtures/phase1/gba-div.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "zig-out/bin/gba-div",
        } },
        try parse(&.{
            "hmncli",
            "build",
            "tests/fixtures/phase1/gba-div.gba",
            "--machine",
            "gba",
            "--target",
            "x86_64-linux",
            "-o",
            "zig-out/bin/gba-div",
        }),
    );
}

test "parse accepts frame_raw build output and instruction cap" {
    try std.testing.expectEqualDeep(
        Command{ .build = .{
            .rom_path = "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "zig-out/bin/ppu-stripes",
            .output_mode = .frame_raw,
            .max_instructions = 1_000_000,
        } },
        try parse(&.{
            "hmncli",
            "build",
            "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            "--machine",
            "gba",
            "--target",
            "x86_64-linux",
            "--output",
            "frame_raw",
            "--max-instructions",
            "1000000",
            "-o",
            "zig-out/bin/ppu-stripes",
        }),
    );
}

test "parse rejects frame_raw build without an instruction cap" {
    try std.testing.expectError(
        error.InvalidCommand,
        parse(&.{
            "hmncli",
            "build",
            "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            "--machine",
            "gba",
            "--target",
            "x86_64-linux",
            "--output",
            "frame_raw",
            "-o",
            "zig-out/bin/ppu-stripes",
        }),
    );
}
