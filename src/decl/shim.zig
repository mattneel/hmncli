const std = @import("std");
const common = @import("common.zig");

pub const ShimValueType = enum {
    i32,
    u32,
    guest_ptr,
    void,
};

pub const ShimEffect = enum {
    pure,
    memory_read,
    memory_write,
    device_io,
};

pub const Argument = struct {
    name: []const u8,
    ty: ShimValueType,
};

pub const ShimTestCase = struct {
    name: []const u8,
    input: []const i32,
    expected: i32,
};

pub const ShimDecl = struct {
    id: common.DeclId,
    state: common.DeclState,
    args: []const Argument,
    returns: ShimValueType,
    effects: ShimEffect,
    tests: []const ShimTestCase,
    doc_refs: []const common.DocRef,
    notes: []const []const u8,
};

test "shim test vectors are attached to the declaration" {
    const decl_id = try common.DeclId.parse("shim/gba/Div");
    const decl = ShimDecl{
        .id = decl_id,
        .state = .verified,
        .args = &.{ .{ .name = "numerator", .ty = .i32 }, .{ .name = "denominator", .ty = .i32 } },
        .returns = .i32,
        .effects = .pure,
        .tests = &.{.{ .name = "divides positive integers", .input = &.{ 10, 2 }, .expected = 5 }},
        .doc_refs = &.{},
        .notes = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), decl.tests.len);
}
