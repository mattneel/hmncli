const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    name: []const u8,
    path: []const u8,
    size: usize,
    sha256_hex: []const u8,
};

pub const GoldenFixture = struct {
    name: []const u8,
    path: []const u8,
    size: usize,
    sha256_hex: []const u8,
    max_instructions: u64,
    stop_frames: u32,
    mgba_key_mask: u32 = 0,
    keyinput_script: ?[]const u8 = null,
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

pub const obj_demo_samples = [_]PixelSample{
    .{ .x = 20, .y = 20, .expected = .{ 0, 0, 0, 255 } },
    .{ .x = 123, .y = 40, .expected = .{ 0, 66, 0, 255 } },
};

pub const key_demo_hold_a_script =
    "03fe,03fe,03fe,03fe,03fe,03fe,03fe,03fe," ++
    "03fe,03fe,03fe,03fe,03fe,03fe,03fe,03fe";

pub const key_demo_samples = [_]PixelSample{
    .{ .x = 201, .y = 62, .expected = .{ 0, 255, 0, 255 } },
    .{ .x = 184, .y = 68, .expected = .{ 222, 222, 239, 255 } },
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

pub const golden_fixtures = [_]GoldenFixture{
    .{
        .name = "sbb_reg",
        .path = "tests/fixtures/real/tonc/sbb_reg.golden.rgba",
        .size = 153600,
        .sha256_hex = "08d15b57faf5802eea234e0065c17f3273ed072c559b48e27db66a574e4f6673",
        .max_instructions = 500_000,
        .stop_frames = 60,
    },
    .{
        .name = "obj_demo",
        .path = "tests/fixtures/real/tonc/obj_demo.golden.rgba",
        .size = 153600,
        .sha256_hex = "ab1027848c15ae55573e3a85b6bd651371931ee6eba0778ee11422f84e31f79a",
        .max_instructions = 500_000,
        .stop_frames = 60,
    },
    .{
        .name = "key_demo",
        .path = "tests/fixtures/real/tonc/key_demo.golden.rgba",
        .size = 153600,
        .sha256_hex = "99138f4eca3379e2a502e3c08733e023e78562c206fbd556e9b7fa5291cd205f",
        .max_instructions = 500_000,
        .stop_frames = 60,
        .mgba_key_mask = 1,
        .keyinput_script = key_demo_hold_a_script,
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

test "tonc golden hashes and sizes match recorded provenance" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    for (golden_fixtures) |fixture| {
        const bytes = try cwd.readFileAlloc(io, fixture.path, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(bytes);

        try std.testing.expectEqual(fixture.size, bytes.len);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

        const actual_hex = std.fmt.bytesToHex(digest, .lower);
        try std.testing.expectEqualStrings(fixture.sha256_hex, &actual_hex);
    }
}
