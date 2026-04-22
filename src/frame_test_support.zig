const std = @import("std");
const Io = std.Io;
const gba_ppu = @import("gba_ppu.zig");

pub const FrameSupportError = Io.Dir.ReadFileAllocError || error{
    InvalidFrameSize,
};

pub fn readExactFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: Io.Dir,
    path: []const u8,
) FrameSupportError![]u8 {
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(gba_ppu.rgba_len + 1));
    errdefer allocator.free(bytes);
    if (bytes.len != gba_ppu.rgba_len) return error.InvalidFrameSize;
    return bytes;
}

pub fn expectPixel(
    frame: []const u8,
    x: usize,
    y: usize,
    expected: [4]u8,
) !void {
    if (frame.len != gba_ppu.rgba_len) return error.InvalidFrameSize;
    std.debug.assert(x < gba_ppu.frame_width);
    std.debug.assert(y < gba_ppu.frame_height);

    const pixel_offset = ((y * gba_ppu.frame_width) + x) * 4;
    try std.testing.expectEqualSlices(u8, &expected, frame[pixel_offset..][0..4]);
}

test "frame test support reads rgba and validates exact gba frame size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = [_]u8{0} ** (240 * 160 * 4);
    try tmp.dir.writeFile(io, .{ .sub_path = "frame.rgba", .data = &bytes });

    const loaded = try readExactFrame(std.testing.allocator, io, tmp.dir, "frame.rgba");
    defer std.testing.allocator.free(loaded);

    try std.testing.expectEqual(@as(usize, 240 * 160 * 4), loaded.len);
}

test "frame test support samples an exact rgba pixel" {
    var frame = [_]u8{0} ** gba_ppu.rgba_len;
    const pixel_offset = ((@as(usize, 12) * gba_ppu.frame_width) + 34) * 4;
    frame[pixel_offset + 0] = 1;
    frame[pixel_offset + 1] = 2;
    frame[pixel_offset + 2] = 3;
    frame[pixel_offset + 3] = 255;

    try expectPixel(&frame, 34, 12, .{ 1, 2, 3, 255 });
}
