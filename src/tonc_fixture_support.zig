const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    name: []const u8,
    path: []const u8,
    size: usize,
    sha256_hex: []const u8,
};

pub const PixelSample = struct {
    x: usize,
    y: usize,
    expected: [4]u8,
};

pub const RunFrameOptions = struct {
    max_instructions: u64 = 50_000,
    keyinput_script: ?[]const u8 = null,
};

pub const sbb_reg_samples = [_]PixelSample{
    .{ .x = 0, .y = 0, .expected = .{ 255, 0, 0, 255 } },
    .{ .x = 120, .y = 80, .expected = .{ 0, 0, 0, 255 } },
    .{ .x = 123, .y = 83, .expected = .{ 255, 0, 0, 255 } },
};

pub const fixtures = [_]Fixture{
    .{
        .name = "sbb_reg",
        .path = "tests/fixtures/real/tonc/sbb_reg.gba",
        .size = 2952,
        .sha256_hex = "7dfac2ef74f8152b69c54f6a090244a6c7e1671bf6fcd3fac36eb27abf57063d",
    },
    .{
        .name = "obj_demo",
        .path = "tests/fixtures/real/tonc/obj_demo.gba",
        .size = 5672,
        .sha256_hex = "53ed8c1837e08e8345df1c59a5bf6d6d5f8bb4f55708f77891cccb2a8a46de25",
    },
    .{
        .name = "key_demo",
        .path = "tests/fixtures/real/tonc/key_demo.gba",
        .size = 41736,
        .sha256_hex = "6a4f7ae7dcd83ef63fab33a5060e81e9eeb5feb88a9ff7bf57449061b27e0f71",
    },
    .{
        .name = "irq_demo",
        .path = "tests/fixtures/real/tonc/irq_demo.gba",
        .size = 80724,
        .sha256_hex = "0706b281ff79ee79f28f399652a4ac98e59d3e20a5ff2fe5f104f73fc8d9b387",
    },
};

test "tonc fixture hashes and sizes match provenance" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    for (fixtures) |fixture| {
        const bytes = try cwd.readFileAlloc(io, fixture.path, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(bytes);

        try std.testing.expectEqual(fixture.size, bytes.len);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

        const actual_hex = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualStrings(fixture.sha256_hex, &actual_hex);
    }
}
