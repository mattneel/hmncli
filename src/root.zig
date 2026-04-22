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
