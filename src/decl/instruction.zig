const std = @import("std");
const common = @import("common.zig");
const machine_mod = @import("machine.zig");

pub const EncodingKind = enum {
    fixed32,
    variable_x86,
    fixed16,
};

pub const InstructionTestCase = struct {
    name: []const u8,
    input: []const u32,
    expected: []const u32,
};

pub const InstructionDecl = struct {
    id: common.DeclId,
    isa: machine_mod.Isa,
    mnemonic: []const u8,
    encoding: EncodingKind,
    state: common.DeclState,
    tests: []const InstructionTestCase,
    doc_refs: []const common.DocRef,
    notes: []const []const u8,
};

test "instruction test vectors are attached to the declaration" {
    const decl_id = try common.DeclId.parse("instruction/armv4t/mov_imm");
    const decl = InstructionDecl{
        .id = decl_id,
        .isa = .armv4t,
        .mnemonic = "mov",
        .encoding = .fixed32,
        .state = .verified,
        .tests = &.{.{ .name = "writes immediate into destination register", .input = &.{ 0, 42 }, .expected = &.{42} }},
        .doc_refs = &.{},
        .notes = &.{},
    };
    try std.testing.expectEqual(machine_mod.Isa.armv4t, decl.isa);
}
