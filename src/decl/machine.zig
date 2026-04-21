const std = @import("std");

pub const BinaryFormat = enum {
    raw_blob,
    gba_rom,
    xbe,
};

pub const Isa = enum {
    armv4t,
    x86_p3,
    m68k_68000,
    z80,
};

pub const Permissions = enum {
    read_only,
    read_write,
    read_write_execute,
};

pub const RegionKind = enum {
    ram,
    rom,
    mmio,
};

pub const DeviceKind = enum {
    graphics,
    audio,
};

pub const EntryRule = enum {
    reset_vector,
    image_header_entry,
    fixed_address,
};

pub const Cpu = struct {
    name: []const u8,
    isa: Isa,
    clock_hz: u64,
};

pub const MemoryRegion = struct {
    name: []const u8,
    start: u64,
    size: u64,
    kind: RegionKind,
    permissions: Permissions,
};

pub const Device = struct {
    name: []const u8,
    kind: DeviceKind,
};

pub const SaveStateLayout = struct {
    components: []const []const u8,
};

pub const MachineValidationError = error{
    MachineNeedsCpu,
    MachineNeedsMemory,
    DuplicateRegionName,
};

pub const Machine = struct {
    name: []const u8,
    binary_format: BinaryFormat,
    cpus: []const Cpu,
    memory_regions: []const MemoryRegion,
    devices: []const Device,
    entry: EntryRule,
    hle_surfaces: []const []const u8,
    save_state: SaveStateLayout,
};

pub fn validate(machine: Machine) MachineValidationError!void {
    if (machine.cpus.len == 0) return error.MachineNeedsCpu;
    if (machine.memory_regions.len == 0) return error.MachineNeedsMemory;

    for (machine.memory_regions, 0..) |left, left_index| {
        for (machine.memory_regions[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateRegionName;
        }
    }
}

pub fn validateComptime(comptime machine: Machine) void {
    validate(machine) catch |err| @compileError(@errorName(err));
}

test "machine validation rejects duplicate memory region names" {
    const duplicate = Machine{
        .name = "broken",
        .binary_format = .raw_blob,
        .cpus = &.{.{ .name = "main", .isa = .armv4t, .clock_hz = 16_777_216 }},
        .memory_regions = &.{
            .{ .name = "ram", .start = 0x0000, .size = 0x1000, .kind = .ram, .permissions = .read_write },
            .{ .name = "ram", .start = 0x1000, .size = 0x1000, .kind = .ram, .permissions = .read_write },
        },
        .devices = &.{},
        .entry = .reset_vector,
        .hle_surfaces = &.{},
        .save_state = .{ .components = &.{"cpu", "ram"} },
    };
    try std.testing.expectError(error.DuplicateRegionName, validate(duplicate));
}
