const machine_mod = @import("../decl/machine.zig");
const common = @import("../decl/common.zig");
const instruction_mod = @import("../decl/instruction.zig");
const shim_mod = @import("../decl/shim.zig");

pub const machine = machine_mod.Machine{
    .name = "gba",
    .binary_format = .gba_rom,
    .cpus = &.{
        .{
            .name = "arm7tdmi",
            .isa = .armv4t,
            .clock_hz = 16_777_216,
        },
    },
    .memory_regions = &.{
        .{
            .name = "bios",
            .start = 0x00000000,
            .size = 0x00004000,
            .kind = .rom,
            .permissions = .read_only,
        },
        .{
            .name = "ewram",
            .start = 0x02000000,
            .size = 0x00040000,
            .kind = .ram,
            .permissions = .read_write,
        },
        .{
            .name = "iwram",
            .start = 0x03000000,
            .size = 0x00008000,
            .kind = .ram,
            .permissions = .read_write,
        },
        .{
            .name = "io",
            .start = 0x04000000,
            .size = 0x00000400,
            .kind = .mmio,
            .permissions = .read_write,
        },
        .{
            .name = "rom",
            .start = 0x08000000,
            .size = 0x02000000,
            .kind = .rom,
            .permissions = .read_only,
        },
    },
    .devices = &.{
        .{ .name = "ppu", .kind = .graphics },
        .{ .name = "apu", .kind = .audio },
    },
    .entry = .reset_vector,
    .hle_surfaces = &.{"bios_swi"},
    .save_state = .{ .components = &.{ "cpu", "ewram", "iwram", "io" } },
};

comptime {
    machine_mod.validateComptime(machine);
}

pub const shims: []const shim_mod.ShimDecl = &.{
    .{
        .id = .{
            .kind = .shim,
            .namespace = "gba",
            .name = "Div",
        },
        .state = .verified,
        .args = &.{
            .{ .name = "numerator", .ty = .i32 },
            .{ .name = "denominator", .ty = .i32 },
        },
        .returns = .i32,
        .effects = .pure,
        .tests = &.{
            .{ .name = "positive division", .input = &.{ 10, 2 }, .expected = 5 },
            .{ .name = "negative division", .input = &.{ -9, 3 }, .expected = -3 },
        },
        .doc_refs = &.{
            .{
                .label = "GBATEK BIOS Div",
                .url = "https://problemkaputt.de/gbatek.htm#biosarithmeticfunctions",
            },
        },
        .notes = &.{"Pure arithmetic BIOS helper used as the first shim test surface."},
    },
};

pub const instructions: []const instruction_mod.InstructionDecl = &.{
    .{
        .id = .{
            .kind = .instruction,
            .namespace = "armv4t",
            .name = "mov_imm",
        },
        .isa = .armv4t,
        .mnemonic = "mov",
        .encoding = .fixed32,
        .state = .verified,
        .tests = &.{
            .{
                .name = "writes immediate into destination register",
                .input = &.{ 0, 42 },
                .expected = &.{42},
            },
        },
        .doc_refs = &.{
            .{
                .label = "ARM ARM MOV immediate",
                .url = "https://developer.arm.com/documentation",
            },
        },
        .notes = &.{"Tiny instruction surface for phase 0 declaration-backed testing."},
    },
};

test "gba machine validates against the shared schema" {
    try machine_mod.validate(machine);
}
