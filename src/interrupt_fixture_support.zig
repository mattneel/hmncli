const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    name: []const u8,
    asm_path: []const u8,
    rom_path: []const u8,
    size: usize,
    sha256_hex: []const u8,
    max_instructions: u64,
    signal_pixel: [4]u8,
};

pub const minimal_vblank = Fixture{
    .name = "frame_irq",
    .asm_path = "tests/fixtures/synthetic/vblank/frame_irq.s",
    .rom_path = "tests/fixtures/synthetic/vblank/frame_irq.gba",
    .size = 176,
    .sha256_hex = "7beabadc06e6274af93b7fafb9312116ef1b91730e916a230b937039b3675646",
    .max_instructions = 500_000,
    .signal_pixel = .{ 0, 255, 0, 255 },
};

test "minimal vblank fixture hash and size match provenance" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    const bytes = try cwd.readFileAlloc(io, minimal_vblank.rom_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(minimal_vblank.size, bytes.len);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(minimal_vblank.sha256_hex, &actual_hex);
}
