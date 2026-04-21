const std = @import("std");
const machine_mod = @import("../decl/machine.zig");
const instruction_mod = @import("../decl/instruction.zig");
const shim_mod = @import("../decl/shim.zig");

pub const machine = machine_mod.Machine{
    .name = "arcade_dualcpu",
    .binary_format = .raw_blob,
    .cpus = &.{
        .{
            .name = "main68k",
            .isa = .m68k_68000,
            .clock_hz = 12_000_000,
        },
        .{
            .name = "audioz80",
            .isa = .z80,
            .clock_hz = 4_000_000,
        },
    },
    .memory_regions = &.{
        .{
            .name = "program_rom",
            .start = 0x000000,
            .size = 0x080000,
            .kind = .rom,
            .permissions = .read_only,
        },
        .{
            .name = "work_ram",
            .start = 0x100000,
            .size = 0x010000,
            .kind = .ram,
            .permissions = .read_write,
        },
        .{
            .name = "sound_latch",
            .start = 0x200000,
            .size = 0x000010,
            .kind = .mmio,
            .permissions = .read_write,
        },
    },
    .devices = &.{
        .{ .name = "tile_renderer", .kind = .graphics },
        .{ .name = "ym_sound", .kind = .audio },
    },
    .entry = .fixed_address,
    .hle_surfaces = &.{ "service_calls", "sound_commands" },
    .save_state = .{ .components = &.{ "main68k", "audioz80", "work_ram" } },
};

comptime {
    machine_mod.validateComptime(machine);
}

pub const shims: []const shim_mod.ShimDecl = &.{};

pub const instructions: []const instruction_mod.InstructionDecl = &.{};

test "arcade dual cpu machine validates against the shared schema" {
    try machine_mod.validate(machine);
}

test "arcade example proves multi-cpu machines fit without bespoke fields" {
    try std.testing.expectEqual(@as(usize, 2), machine.cpus.len);
}
