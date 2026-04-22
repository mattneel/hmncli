const std = @import("std");
const Io = std.Io;

pub const RomImage = struct {
    bytes: []u8,
    base_address: u32 = 0x08000000,

    pub fn deinit(image: RomImage, allocator: std.mem.Allocator) void {
        allocator.free(image.bytes);
    }
};

pub const LoadError = Io.Dir.ReadFileAllocError || error{
    UnsupportedMachine,
    EmptyRom,
    InvalidRomSize,
};

pub fn loadFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    machine_name: []const u8,
    rom_path: []const u8,
) LoadError!RomImage {
    if (!std.mem.eql(u8, machine_name, "gba")) return error.UnsupportedMachine;

    const bytes = try cwd.readFileAlloc(io, rom_path, allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(bytes);
    try validate(bytes);
    return .{ .bytes = bytes };
}

fn validate(bytes: []const u8) LoadError!void {
    if (bytes.len == 0) return error.EmptyRom;
    if ((bytes.len % 4) != 0) return error.InvalidRomSize;
}

test "gba loader rejects rom sizes that are not 4-byte aligned" {
    try std.testing.expectError(error.InvalidRomSize, validate("abc"));
}
