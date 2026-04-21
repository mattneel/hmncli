const std = @import("std");

pub const DeclKind = enum {
    machine,
    shim,
    instruction,
};

pub const DeclState = enum {
    declared,
    stubbed,
    implemented,
    verified,
};

pub const DocRef = struct {
    label: []const u8,
    url: []const u8,
};

pub const DeclIdError = error{
    InvalidDeclId,
};

pub const DeclId = struct {
    kind: DeclKind,
    namespace: []const u8,
    name: []const u8,

    pub fn parse(input: []const u8) DeclIdError!DeclId {
        var it = std.mem.splitScalar(u8, input, '/');
        const kind_text = it.next() orelse return error.InvalidDeclId;
        const namespace = it.next() orelse return error.InvalidDeclId;
        const name = it.next() orelse return error.InvalidDeclId;
        if (it.next() != null) return error.InvalidDeclId;

        return .{
            .kind = parseKind(kind_text) orelse return error.InvalidDeclId,
            .namespace = namespace,
            .name = name,
        };
    }

};

fn parseKind(input: []const u8) ?DeclKind {
    if (std.mem.eql(u8, input, "machine")) return .machine;
    if (std.mem.eql(u8, input, "shim")) return .shim;
    if (std.mem.eql(u8, input, "instruction")) return .instruction;
    return null;
}

test "decl id parses kind namespace and name" {
    const id = try DeclId.parse("shim/gba/Div");
    try std.testing.expectEqual(DeclKind.shim, id.kind);
    try std.testing.expectEqualStrings("gba", id.namespace);
    try std.testing.expectEqualStrings("Div", id.name);
}
