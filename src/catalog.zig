const std = @import("std");
const instruction_mod = @import("decl/instruction.zig");
const machine_mod = @import("decl/machine.zig");
const shim_mod = @import("decl/shim.zig");
const arcade_dualcpu = @import("machines/arcade_dualcpu.zig");
const gba = @import("machines/gba.zig");
const xbox = @import("machines/xbox.zig");

pub const CatalogError = error{
    MachineNotFound,
    ShimNotFound,
    InstructionNotFound,
};

pub fn lookupMachine(name: []const u8) CatalogError!machine_mod.Machine {
    if (std.mem.eql(u8, name, "gba")) return gba.machine;
    if (std.mem.eql(u8, name, "xbox")) return xbox.machine;
    if (std.mem.eql(u8, name, "arcade_dualcpu")) return arcade_dualcpu.machine;
    return error.MachineNotFound;
}

pub fn lookupShim(namespace: []const u8, name: []const u8) CatalogError!shim_mod.ShimDecl {
    const decls = switchShimNamespace(namespace) orelse return error.ShimNotFound;
    for (decls) |decl| {
        if (std.mem.eql(u8, decl.id.name, name)) return decl;
    }
    return error.ShimNotFound;
}

pub fn lookupInstruction(namespace: []const u8, name: []const u8) CatalogError!instruction_mod.InstructionDecl {
    const decls = switchInstructionNamespace(namespace) orelse return error.InstructionNotFound;
    for (decls) |decl| {
        if (std.mem.eql(u8, decl.id.name, name)) return decl;
    }
    return error.InstructionNotFound;
}

fn switchShimNamespace(namespace: []const u8) ?[]const shim_mod.ShimDecl {
    if (std.mem.eql(u8, namespace, "gba")) return gba.shims;
    if (std.mem.eql(u8, namespace, "xbox")) return xbox.shims;
    if (std.mem.eql(u8, namespace, "arcade_dualcpu")) return arcade_dualcpu.shims;
    return null;
}

fn switchInstructionNamespace(namespace: []const u8) ?[]const instruction_mod.InstructionDecl {
    if (std.mem.eql(u8, namespace, "armv4t")) return gba.instructions;
    if (std.mem.eql(u8, namespace, "x86_p3")) return xbox.instructions;
    if (std.mem.eql(u8, namespace, "m68k_68000")) return arcade_dualcpu.instructions;
    return null;
}

test "catalog looks up real phase 0 declarations" {
    const div_shim = try lookupShim("gba", "Div");
    try std.testing.expectEqualStrings("Div", div_shim.id.name);

    const mov = try lookupInstruction("armv4t", "mov_imm");
    try std.testing.expectEqualStrings("mov", mov.mnemonic);

    const xbox_machine = try lookupMachine("xbox");
    try std.testing.expectEqualStrings("xbox", xbox_machine.name);
}
