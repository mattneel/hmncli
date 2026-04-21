const std = @import("std");
const Io = std.Io;
const catalog = @import("../catalog.zig");
const common = @import("../decl/common.zig");

pub const RenderError = common.DeclIdError || catalog.CatalogError || Io.Writer.Error || error{
    UnsupportedDeclKindForPhase0,
};

pub fn render(writer: *Io.Writer, decl_id_text: []const u8) RenderError!void {
    const decl_id = try common.DeclId.parse(decl_id_text);
    switch (decl_id.kind) {
        .shim => {
            const shim = try catalog.lookupShim(decl_id.namespace, decl_id.name);
            try writer.print("ID: shim/{s}/{s}\n", .{ decl_id.namespace, decl_id.name });
            try writer.print("State: {s}\n", .{@tagName(shim.state)});
            try writer.print("Effects: {s}\n", .{@tagName(shim.effects)});
            for (shim.doc_refs) |doc_ref| {
                try writer.print("Reference: {s}\n", .{doc_ref.label});
            }
        },
        else => return error.UnsupportedDeclKindForPhase0,
    }
}

test "doc renders shim declaration metadata deterministically" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try render(&output.writer, "shim/gba/Div");

    try std.testing.expectEqualStrings(
        "ID: shim/gba/Div\nState: verified\nEffects: pure\nReference: GBATEK BIOS Div\n",
        output.writer.buffered(),
    );
}
