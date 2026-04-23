const std = @import("std");
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FileHandle;
extern fn fwrite(buffer: *const anyopaque, size: usize, count: usize, stream: *FileHandle) usize;
extern fn fclose(stream: *FileHandle) c_int;

const FileHandle = opaque {};

pub const frame_width = 240;
pub const frame_height = 160;
pub const rgba_len = frame_width * frame_height * 4;
pub const dump_ok: c_int = 0;
pub const dump_error_missing_output_path: c_int = 1;
pub const dump_error_unsupported_video_mode: c_int = 2;
pub const dump_error_write_failed: c_int = 3;

pub const FrameError = error{
    UnsupportedVideoMode,
};

fn expand5(value: u5) u8 {
    return (@as(u8, value) << 3) | (@as(u8, value) >> 2);
}

fn writePaletteColor(
    rgba: *[rgba_len]u8,
    palette: *const [1024]u8,
    x: usize,
    y: usize,
    palette_index: usize,
) void {
    const color_offset = palette_index * 2;
    const color = std.mem.readInt(u16, palette[color_offset..][0..2], .little);
    const rgba_offset = ((y * frame_width) + x) * 4;
    rgba[rgba_offset + 0] = expand5(@truncate(color & 0x1F));
    rgba[rgba_offset + 1] = expand5(@truncate((color >> 5) & 0x1F));
    rgba[rgba_offset + 2] = expand5(@truncate((color >> 10) & 0x1F));
    rgba[rgba_offset + 3] = 255;
}

fn fillBackdrop(
    palette: *const [1024]u8,
    rgba: *[rgba_len]u8,
) void {
    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            writePaletteColor(rgba, palette, x, y, 0);
        }
    }
}

fn tilePixel4bpp(
    vram: *const [98304]u8,
    charblock: usize,
    tile_id: u16,
    x: usize,
    y: usize,
) u8 {
    const tile_base = (charblock * 0x4000) + (@as(usize, tile_id) * 32);
    const row_offset = tile_base + (y * 4) + (x / 2);
    const packed_pixels = vram[row_offset];
    return if ((x & 1) == 0) packed_pixels & 0x0F else packed_pixels >> 4;
}

fn renderRegularBg0(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
) void {
    const bgcnt = std.mem.readInt(u16, io[8..10], .little);
    const cbb: usize = @intCast((bgcnt >> 2) & 0x3);
    const sbb: usize = @intCast((bgcnt >> 8) & 0x1F);
    const hofs = std.mem.readInt(u16, io[16..18], .little) & 0x01FF;
    const vofs = std.mem.readInt(u16, io[18..20], .little) & 0x01FF;

    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            const bg_x = (x + hofs) & 0x01FF;
            const bg_y = (y + vofs) & 0x01FF;
            const tile_x = bg_x >> 3;
            const tile_y = bg_y >> 3;
            const entry_offset = ((tile_y & 31) * 32) + (tile_x & 31);
            const entry_addr = (sbb * 0x800) + (entry_offset * 2);
            const entry = std.mem.readInt(u16, vram[entry_addr..][0..2], .little);
            const tile_id: u16 = @truncate(entry & 0x03FF);
            const palbank: usize = @intCast((entry >> 12) & 0x0F);
            const color_index = tilePixel4bpp(vram, cbb, tile_id, bg_x & 7, bg_y & 7);
            if (color_index == 0) continue;
            writePaletteColor(rgba, palette, x, y, (palbank * 16) + color_index);
        }
    }
}

fn dumpMode0Rgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
) void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    fillBackdrop(palette, rgba);
    if ((dispcnt & 0x0100) != 0) {
        renderRegularBg0(io, palette, vram, rgba);
    }
}

pub fn dumpFrameRgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
) FrameError!void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    switch (dispcnt & 0x7) {
        0 => dumpMode0Rgba(io, palette, vram, rgba),
        4 => try dumpMode4Rgba(io, palette, vram, rgba),
        else => return error.UnsupportedVideoMode,
    }
}

pub fn dumpMode4Rgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
) FrameError!void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    if ((dispcnt & 0x7) != 4) return error.UnsupportedVideoMode;

    const page_offset: usize = if ((dispcnt & 0x0010) != 0) 0xA000 else 0;
    for (0..frame_width * frame_height) |pixel_index| {
        const palette_index = vram[page_offset + pixel_index];
        const color_offset = @as(usize, palette_index) * 2;
        const color = std.mem.readInt(u16, palette[color_offset..][0..2], .little);
        const rgba_offset = pixel_index * 4;
        rgba[rgba_offset + 0] = expand5(@truncate(color & 0x1F));
        rgba[rgba_offset + 1] = expand5(@truncate((color >> 5) & 0x1F));
        rgba[rgba_offset + 2] = expand5(@truncate((color >> 10) & 0x1F));
        rgba[rgba_offset + 3] = 255;
    }
}

fn envEquals(name: [*:0]const u8, expected: []const u8) bool {
    const value = getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), expected);
}

pub export fn hm_runtime_output_mode_frame_raw() c_int {
    if (getenv("HOMONCULI_OUTPUT_MODE")) |_| {
        return if (envEquals("HOMONCULI_OUTPUT_MODE", "frame_raw")) 1 else 0;
    }
    return 1;
}

pub export fn hm_runtime_max_instructions(default_limit: u64) u64 {
    const value = getenv("HOMONCULI_MAX_INSTRUCTIONS") orelse return default_limit;
    return std.fmt.parseUnsigned(u64, std.mem.span(value), 10) catch default_limit;
}

pub export fn hmgba_sample_keyinput_for_frame(frame_index: u64) u16 {
    const script = getenv("HOMONCULI_KEYINPUT_SCRIPT") orelse return 0x03FF;
    return hmgbaSampleKeyinput(std.mem.span(script), frame_index);
}

pub fn hmgbaSampleKeyinput(script: []const u8, frame_index: u64) u16 {
    var iter = std.mem.tokenizeScalar(u8, script, ',');
    var current: u16 = 0x03FF;
    var index: u64 = 0;
    while (iter.next()) |token| {
        current = std.fmt.parseUnsigned(u16, token, 16) catch 0x03FF;
        if (index == frame_index) return current;
        index += 1;
    }
    return current;
}

pub export fn hmgba_dump_frame_raw(
    io: [*]const u8,
    palette: [*]const u8,
    vram: [*]const u8,
) c_int {
    const output_path = getenv("HOMONCULI_OUTPUT_PATH") orelse return dump_error_missing_output_path;
    const io_bytes: *const [1024]u8 = @ptrCast(io);
    const palette_bytes: *const [1024]u8 = @ptrCast(palette);
    const vram_bytes: *const [98304]u8 = @ptrCast(vram);
    var rgba: [rgba_len]u8 = undefined;
    dumpFrameRgba(io_bytes, palette_bytes, vram_bytes, &rgba) catch return dump_error_unsupported_video_mode;

    const file = fopen(output_path, "wb") orelse return dump_error_write_failed;
    defer _ = fclose(file);

    const written = fwrite(&rgba, 1, rgba.len, file);
    if (written != rgba.len) return dump_error_write_failed;
    return dump_ok;
}

test "mode4 renderer decodes active page into rgba pixels" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, palette[0..2], 0x001F, .little);
    std.mem.writeInt(u16, palette[2..4], 0x03E0, .little);
    io[0] = 4;
    vram[0] = 0;
    vram[1] = 1;

    try dumpMode4Rgba(&io, &palette, &vram, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[4..8]);
}

test "mode4 renderer rejects unsupported display mode" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var rgba: [rgba_len]u8 = undefined;

    io[0] = 3;
    try std.testing.expectError(error.UnsupportedVideoMode, dumpMode4Rgba(&io, &palette, &vram, &rgba));
}

test "mode0 renderer decodes a regular 4bpp bg0 tilemap" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0100, .little); // mode 0 + BG0
    std.mem.writeInt(u16, io[8..10], 0x0100, .little); // CBB0, SBB1, 4bpp
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little); // tile 0
    vram[0] = 0x10; // x=0 => color 0 backdrop, x=1 => color 1
    std.mem.writeInt(u16, palette[0..2], 0x0000, .little);
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);

    try dumpFrameRgba(&io, &palette, &vram, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[4..8]);
}

test "gba keyinput helper replays comma-separated active-low samples" {
    try std.testing.expectEqual(@as(u16, 0x03FF), hmgbaSampleKeyinput("03ff,03fe", 0));
    try std.testing.expectEqual(@as(u16, 0x03FE), hmgbaSampleKeyinput("03ff,03fe", 1));
    try std.testing.expectEqual(@as(u16, 0x03FE), hmgbaSampleKeyinput("03ff,03fe", 9));
}
