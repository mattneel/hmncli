//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const build_module = @import("build_cmd.zig");
const cli_doc = @import("cli/doc.zig");
const cli_parse = @import("cli/parse.zig");
const cli_status = @import("cli/status.zig");
const cli_test = @import("cli/test.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub const cli = struct {
    pub const build_cmd = build_module;
    pub const doc = cli_doc;
    pub const parse = cli_parse.parse;
    pub const status = cli_status;
    pub const test_cmd = cli_test;
    pub const Command = cli_parse.Command;
    pub const ParseError = cli_parse.ParseError;
};

pub const decl = struct {
    pub const common = @import("decl/common.zig");
    pub const machine = @import("decl/machine.zig");
    pub const shim = @import("decl/shim.zig");
    pub const instruction = @import("decl/instruction.zig");
};

pub const trace = struct {
    pub const event = @import("trace/event.zig");
    pub const fixture = @import("trace/fixture.zig");
};

pub const machines = struct {
    pub const gba = @import("machines/gba.zig");
    pub const xbox = @import("machines/xbox.zig");
    pub const arcade_dualcpu = @import("machines/arcade_dualcpu.zig");
};

pub const catalog = @import("catalog.zig");
pub const capstone_api = @import("capstone_api.zig");

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "aggregator" {
    std.testing.refAllDecls(@This());
}

test "phase 0 machine examples validate against the shared schema" {
    try decl.machine.validate(machines.gba.machine);
    try decl.machine.validate(machines.xbox.machine);
    try decl.machine.validate(machines.arcade_dualcpu.machine);
}

test "arcade example proves multi-cpu machines fit without bespoke fields" {
    try std.testing.expectEqual(@as(usize, 2), machines.arcade_dualcpu.machine.cpus.len);
}

test "doc command renders shim declaration metadata" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.doc.render(&output.writer, "shim/gba/Div");
    try std.testing.expectEqualStrings(
        "ID: shim/gba/Div\nState: verified\nEffects: pure\nReference: GBATEK BIOS Div\n",
        output.writer.buffered(),
    );
}

test "declaration-backed test commands run vectors" {
    var shim_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer shim_output.deinit();
    try cli.test_cmd.runShim(&shim_output.writer, "gba/Div");
    try std.testing.expectEqualStrings(
        "PASS 2/2 shim tests for gba/Div\n",
        shim_output.writer.buffered(),
    );

    var instruction_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer instruction_output.deinit();
    try cli.test_cmd.runInstruction(&instruction_output.writer, "armv4t/mov_imm");
    try std.testing.expectEqualStrings(
        "PASS 1/1 instruction tests for armv4t/mov_imm\n",
        instruction_output.writer.buffered(),
    );
}

test "fixture-backed status report renders deterministic counts" {
    const bytes = try trace.fixture.gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.status.render(&output.writer, bytes);
    try std.testing.expectEqualStrings(
        "Unimplemented shims:\n1. shim/gba/Div (3)\nUnimplemented instructions:\n1. instruction/armv4t/unknown_e7f001f0 (1)\nUnresolved indirect branches:\n1. pc=0x00000120 register=r12\n",
        output.writer.buffered(),
    );
}

test "build emits guest-state llvm with a separate guest entry function" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3,
        0x02, 0x10, 0xA0, 0xE3,
        0x06, 0x00, 0x00, 0xEF,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "div.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "div.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-div-native",
        },
    );

    const llvm_bytes = try tmp.dir.readFileAlloc(
        io,
        "gba-div-native.ll",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(llvm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "%GuestState = type") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "define void @guest_arm_08000000(ptr %state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "call void @guest_arm_08000000(ptr %state)") != null);
}

test "build executes a synthetic direct bl plus bx lr slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3, // mov r0, #10
        0x01, 0x00, 0x00, 0xEB, // bl  0x08000010
        0x02, 0x10, 0xA0, 0xE3, // mov r1, #2
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0x1E, 0xFF, 0x2F, 0xE1, // bx  lr
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "bl.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "bl.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-bl-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-bl-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic msr cpsr_f immediate slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0xF1, 0x28, 0xE3, // msr cpsr_f, #0x40000000
        0x01, 0x00, 0x00, 0x1A, // bne 0x08000010
        0x01, 0x00, 0xA0, 0xE3, // mov r0, #1
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "msr.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "msr.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-msr-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-msr-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "build executes a synthetic beq slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0xF1, 0x28, 0xE3, // msr cpsr_f, #0x40000000
        0x01, 0x00, 0x00, 0x0A, // beq 0x08000010
        0x01, 0x00, 0xA0, 0xE3, // mov r0, #1
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "beq.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "beq.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-beq-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-beq-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic arm-thumb-arm interworking slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0x00, 0x8F, 0xE2, // add r0, pc, #1
        0x10, 0xFF, 0x2F, 0xE1, // bx  r0
        0x07, 0x20, // movs r0, #7
        0x01, 0xA1, // adr  r1, 0x08000010
        0x08, 0x47, // bx   r1
        0xC0, 0x46, // nop
        0xFE, 0xFF, 0xFF, 0xEA, // b .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "interwork.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "interwork.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-interwork-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-interwork-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}
