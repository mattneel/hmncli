const machine_mod = @import("../decl/machine.zig");
const instruction_mod = @import("../decl/instruction.zig");
const shim_mod = @import("../decl/shim.zig");

pub const machine = machine_mod.Machine{
    .name = "xbox",
    .binary_format = .xbe,
    .cpus = &.{
        .{
            .name = "pentium3",
            .isa = .x86_p3,
            .clock_hz = 733_000_000,
        },
    },
    .memory_regions = &.{
        .{
            .name = "title_ram",
            .start = 0x00010000,
            .size = 0x03ff0000,
            .kind = .ram,
            .permissions = .read_write_execute,
        },
        .{
            .name = "kernel_shared",
            .start = 0x80000000,
            .size = 0x04000000,
            .kind = .ram,
            .permissions = .read_write,
        },
        .{
            .name = "nv2a_mmio",
            .start = 0xf0000000,
            .size = 0x10000000,
            .kind = .mmio,
            .permissions = .read_write,
        },
    },
    .devices = &.{
        .{ .name = "nv2a", .kind = .graphics },
        .{ .name = "mcpx", .kind = .audio },
    },
    .entry = .image_header_entry,
    .hle_surfaces = &.{ "xboxkrnl_exports", "nv2a_mmio" },
    .save_state = .{ .components = &.{ "cpu", "ram", "kernel_shared" } },
};

comptime {
    machine_mod.validateComptime(machine);
}

pub const shims: []const shim_mod.ShimDecl = &.{};

pub const instructions: []const instruction_mod.InstructionDecl = &.{};

test "xbox machine validates against the shared schema" {
    try machine_mod.validate(machine);
}
