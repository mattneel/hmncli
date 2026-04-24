const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FileHandle;
extern fn fwrite(buffer: *const anyopaque, size: usize, count: usize, stream: *FileHandle) usize;
extern fn fclose(stream: *FileHandle) c_int;
extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern fn dlclose(handle: *anyopaque) c_int;

const FileHandle = opaque {};
const standalone_build_cmd_test = builtin.is_test and !@hasDecl(@import("root"), "cli");

pub const frame_width = 240;
pub const frame_height = 160;
pub const rgba_len = frame_width * frame_height * 4;
pub const dump_ok: c_int = 0;
pub const dump_error_missing_output_path: c_int = 1;
pub const dump_error_unsupported_video_mode: c_int = 2;
pub const dump_error_write_failed: c_int = 3;
pub const dump_error_sdl3_missing: c_int = 4;
pub const dump_error_sdl3_init_failed: c_int = 5;
pub const dump_error_sdl3_window_failed: c_int = 6;
pub const dump_error_sdl3_renderer_failed: c_int = 7;
pub const dump_error_sdl3_texture_failed: c_int = 8;
pub const dump_error_sdl3_render_failed: c_int = 9;
pub const dump_window_quit: c_int = 10;

const rtld_now: c_int = 2;
const sdl_init_video: u32 = 0x0000_0020;
const sdl_window_resizable: u64 = 0x0000_0000_0000_0020;
const sdl_window_high_pixel_density: u64 = 0x0000_0000_0000_2000;
const sdl_pixelformat_rgba32: u32 = 0x1676_2004;
const sdl_textureaccess_streaming: c_int = 1;
const sdl_event_quit: u32 = 0x0000_0100;

pub const FrameError = error{
    UnsupportedVideoMode,
};

const LayerPixel = struct {
    priority: u8,
    tie: u8,
    written: bool,
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

fn writeObjPaletteColor(
    rgba: *[rgba_len]u8,
    palette: *const [1024]u8,
    x: usize,
    y: usize,
    palette_index: usize,
) void {
    const color_offset = 0x200 + (palette_index * 2);
    const color = std.mem.readInt(u16, palette[color_offset..][0..2], .little);
    const rgba_offset = ((y * frame_width) + x) * 4;
    rgba[rgba_offset + 0] = expand5(@truncate(color & 0x1F));
    rgba[rgba_offset + 1] = expand5(@truncate((color >> 5) & 0x1F));
    rgba[rgba_offset + 2] = expand5(@truncate((color >> 10) & 0x1F));
    rgba[rgba_offset + 3] = 255;
}

fn shouldWriteLayerPixel(pixel: LayerPixel, priority: u8, tie: u8) bool {
    if (!pixel.written) return true;
    if (priority < pixel.priority) return true;
    if (priority > pixel.priority) return false;
    return tie < pixel.tie;
}

fn writeCompositedBgPaletteColor(
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
    palette: *const [1024]u8,
    x: usize,
    y: usize,
    palette_index: usize,
    priority: u8,
    tie: u8,
) void {
    const pixel_index = (y * frame_width) + x;
    if (!shouldWriteLayerPixel(layers[pixel_index], priority, tie)) return;
    layers[pixel_index] = .{ .priority = priority, .tie = tie, .written = true };
    writePaletteColor(rgba, palette, x, y, palette_index);
}

fn writeCompositedObjPaletteColor(
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
    palette: *const [1024]u8,
    x: usize,
    y: usize,
    palette_index: usize,
    priority: u8,
    tie: u8,
) void {
    const pixel_index = (y * frame_width) + x;
    if (!shouldWriteLayerPixel(layers[pixel_index], priority, tie)) return;
    layers[pixel_index] = .{ .priority = priority, .tie = tie, .written = true };
    writeObjPaletteColor(rgba, palette, x, y, palette_index);
}

fn fillBackdrop(
    palette: *const [1024]u8,
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
) void {
    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            layers[(y * frame_width) + x] = .{ .priority = 4, .tie = 0xFF, .written = true };
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

fn tilePixel8bpp(
    vram: *const [98304]u8,
    charblock: usize,
    tile_id: u16,
    x: usize,
    y: usize,
) u8 {
    const tile_base = (charblock * 0x4000) + (@as(usize, tile_id) * 64);
    return vram[tile_base + (y * 8) + x];
}

fn regularBgScreenblockOffset(size: u2, tile_x: usize, tile_y: usize) usize {
    return switch (size) {
        0 => 0,
        1 => if (tile_x >= 32) 1 else 0,
        2 => if (tile_y >= 32) 1 else 0,
        3 => (if (tile_x >= 32) @as(usize, 1) else 0) + (if (tile_y >= 32) @as(usize, 2) else 0),
    };
}

fn renderRegularBg(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
    bg_index: usize,
) void {
    const bgcnt_offset = 0x08 + (bg_index * 2);
    const hofs_offset = 0x10 + (bg_index * 4);
    const vofs_offset = hofs_offset + 2;
    const bgcnt = std.mem.readInt(u16, io[bgcnt_offset..][0..2], .little);
    const cbb: usize = @intCast((bgcnt >> 2) & 0x3);
    const sbb: usize = @intCast((bgcnt >> 8) & 0x1F);
    const color_256 = (bgcnt & 0x0080) != 0;
    const priority: u8 = @intCast(bgcnt & 0x0003);
    const tie: u8 = 1 + @as(u8, @intCast(bg_index));
    const size: u2 = @truncate((bgcnt >> 14) & 0x3);
    const hofs = std.mem.readInt(u16, io[hofs_offset..][0..2], .little) & 0x01FF;
    const vofs = std.mem.readInt(u16, io[vofs_offset..][0..2], .little) & 0x01FF;

    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            const bg_x = (x + hofs) & 0x01FF;
            const bg_y = (y + vofs) & 0x01FF;
            const tile_x = bg_x >> 3;
            const tile_y = bg_y >> 3;
            const screenblock = sbb + regularBgScreenblockOffset(size, tile_x, tile_y);
            const entry_offset = ((tile_y & 31) * 32) + (tile_x & 31);
            const entry_addr = (screenblock * 0x800) + (entry_offset * 2);
            const entry = std.mem.readInt(u16, vram[entry_addr..][0..2], .little);
            const tile_id: u16 = @truncate(entry & 0x03FF);
            const palbank: usize = @intCast((entry >> 12) & 0x0F);
            const source_x = if ((entry & 0x0400) != 0) 7 - (bg_x & 7) else bg_x & 7;
            const source_y = if ((entry & 0x0800) != 0) 7 - (bg_y & 7) else bg_y & 7;
            const color_index = if (color_256)
                tilePixel8bpp(vram, cbb, tile_id, source_x, source_y)
            else
                tilePixel4bpp(vram, cbb, tile_id, source_x, source_y);
            if (color_index == 0) continue;
            const palette_index = if (color_256) color_index else (palbank * 16) + color_index;
            writeCompositedBgPaletteColor(rgba, layers, palette, x, y, palette_index, priority, tie);
        }
    }
}

fn dumpMode0Rgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
) void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    var layers: [frame_width * frame_height]LayerPixel = undefined;
    fillBackdrop(palette, rgba, &layers);
    var priority: i32 = 3;
    while (priority >= 0) : (priority -= 1) {
        var bg_index: i32 = 3;
        while (bg_index >= 0) : (bg_index -= 1) {
            const bg: usize = @intCast(bg_index);
            const enable_bit = @as(u16, 0x0100) << @intCast(bg);
            if ((dispcnt & enable_bit) == 0) continue;
            const bgcnt_offset = 0x08 + (bg * 2);
            const bgcnt = std.mem.readInt(u16, io[bgcnt_offset..][0..2], .little);
            if (@as(i32, @intCast(bgcnt & 0x0003)) != priority) continue;
            renderRegularBg(io, palette, vram, rgba, &layers, bg);
        }
    }
    if ((dispcnt & 0x1000) != 0) {
        renderObjLayer(io, palette, vram, oam, rgba, &layers);
    }
}

fn decodeRegularObjSize(attr0: u16, attr1: u16) ?struct { width: usize, height: usize } {
    const shape = (attr0 >> 14) & 0x3;
    const size = (attr1 >> 14) & 0x3;
    return switch (shape) {
        0 => switch (size) {
            0 => .{ .width = 8, .height = 8 },
            1 => .{ .width = 16, .height = 16 },
            2 => .{ .width = 32, .height = 32 },
            3 => .{ .width = 64, .height = 64 },
            else => unreachable,
        },
        1 => switch (size) {
            0 => .{ .width = 16, .height = 8 },
            1 => .{ .width = 32, .height = 8 },
            2 => .{ .width = 32, .height = 16 },
            3 => .{ .width = 64, .height = 32 },
            else => unreachable,
        },
        2 => switch (size) {
            0 => .{ .width = 8, .height = 16 },
            1 => .{ .width = 8, .height = 32 },
            2 => .{ .width = 16, .height = 32 },
            3 => .{ .width = 32, .height = 64 },
            else => unreachable,
        },
        else => null,
    };
}

fn signedObjX(raw_x: u16) i32 {
    const x: i32 = @intCast(raw_x & 0x01FF);
    return if (x >= 256) x - 512 else x;
}

fn signedObjY(raw_y: u16) i32 {
    const y: i32 = @intCast(raw_y & 0x00FF);
    return if (y >= 160) y - 256 else y;
}

fn objTilePixel4bpp(
    vram: *const [98304]u8,
    tile_id: usize,
    obj_width: usize,
    one_dimensional: bool,
    x: usize,
    y: usize,
) u8 {
    const tile_x = x & 7;
    const tile_y = y & 7;
    const tile_index = if (one_dimensional) blk: {
        const tiles_per_row = obj_width / 8;
        break :blk tile_id + ((y / 8) * tiles_per_row) + (x / 8);
    } else tile_id + ((y / 8) * 32) + (x / 8);
    const tile_base = 0x10000 + (tile_index * 32);
    const row_offset = tile_base + (tile_y * 4) + (tile_x / 2);
    const packed_pixels = vram[row_offset];
    return if ((tile_x & 1) == 0) packed_pixels & 0x0F else packed_pixels >> 4;
}

fn objTilePixel8bpp(
    vram: *const [98304]u8,
    tile_id: usize,
    obj_width: usize,
    one_dimensional: bool,
    x: usize,
    y: usize,
) u8 {
    const tile_x = x & 7;
    const tile_y = y & 7;
    const tile_index = if (one_dimensional) blk: {
        const tiles_per_row = obj_width / 8;
        break :blk tile_id + (((y / 8) * tiles_per_row) + (x / 8)) * 2;
    } else tile_id + ((y / 8) * 32) + ((x / 8) * 2);
    const tile_base = 0x10000 + (tile_index * 32);
    return vram[tile_base + (tile_y * 8) + tile_x];
}

fn renderRegular4bppObj(
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
    attr0: u16,
    attr1: u16,
    attr2: u16,
    one_dimensional: bool,
) void {
    const size = decodeRegularObjSize(attr0, attr1) orelse return;
    const obj_x = signedObjX(attr1);
    const obj_y = signedObjY(attr0);
    const tile_id: usize = @intCast(attr2 & 0x03FF);
    const palbank: usize = @intCast((attr2 >> 12) & 0xF);
    const priority: u8 = @intCast((attr2 >> 10) & 0x3);
    const hflip = (attr1 & 0x1000) != 0;
    const vflip = (attr1 & 0x2000) != 0;

    for (0..size.height) |py| {
        for (0..size.width) |px| {
            const screen_x = obj_x + @as(i32, @intCast(px));
            const screen_y = obj_y + @as(i32, @intCast(py));
            if (screen_x < 0 or screen_x >= frame_width or screen_y < 0 or screen_y >= frame_height) continue;

            const source_x = if (hflip) size.width - 1 - px else px;
            const source_y = if (vflip) size.height - 1 - py else py;
            const color_index = objTilePixel4bpp(vram, tile_id, size.width, one_dimensional, source_x, source_y);
            if (color_index == 0) continue;
            writeCompositedObjPaletteColor(
                rgba,
                layers,
                palette,
                @intCast(screen_x),
                @intCast(screen_y),
                (palbank * 16) + color_index,
                priority,
                0,
            );
        }
    }
}

fn renderRegular8bppObj(
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
    attr0: u16,
    attr1: u16,
    attr2: u16,
    one_dimensional: bool,
) void {
    const size = decodeRegularObjSize(attr0, attr1) orelse return;
    const obj_x = signedObjX(attr1);
    const obj_y = signedObjY(attr0);
    const tile_id: usize = @intCast(attr2 & 0x03FF);
    const priority: u8 = @intCast((attr2 >> 10) & 0x3);
    const hflip = (attr1 & 0x1000) != 0;
    const vflip = (attr1 & 0x2000) != 0;

    for (0..size.height) |py| {
        for (0..size.width) |px| {
            const screen_x = obj_x + @as(i32, @intCast(px));
            const screen_y = obj_y + @as(i32, @intCast(py));
            if (screen_x < 0 or screen_x >= frame_width or screen_y < 0 or screen_y >= frame_height) continue;

            const source_x = if (hflip) size.width - 1 - px else px;
            const source_y = if (vflip) size.height - 1 - py else py;
            const color_index = objTilePixel8bpp(vram, tile_id, size.width, one_dimensional, source_x, source_y);
            if (color_index == 0) continue;
            writeCompositedObjPaletteColor(
                rgba,
                layers,
                palette,
                @intCast(screen_x),
                @intCast(screen_y),
                color_index,
                priority,
                0,
            );
        }
    }
}

fn objAffineParam(oam: *const [1024]u8, affine_index: usize, param_index: usize) i32 {
    const offsets = [_]usize{ 6, 14, 22, 30 };
    const offset = (affine_index * 32) + offsets[param_index];
    return @intCast(std.mem.readInt(i16, oam[offset..][0..2], .little));
}

fn renderAffine8bppObj(
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
    attr0: u16,
    attr1: u16,
    attr2: u16,
    one_dimensional: bool,
) void {
    const size = decodeRegularObjSize(attr0, attr1) orelse return;
    const obj_x = signedObjX(attr1);
    const obj_y = signedObjY(attr0);
    const tile_id: usize = @intCast(attr2 & 0x03FF);
    const priority: u8 = @intCast((attr2 >> 10) & 0x3);
    const affine_index: usize = @intCast((attr1 >> 9) & 0x1F);
    const display_width = if ((attr0 & 0x0200) != 0) size.width * 2 else size.width;
    const display_height = if ((attr0 & 0x0200) != 0) size.height * 2 else size.height;
    const display_half_width: i32 = @intCast(display_width / 2);
    const display_half_height: i32 = @intCast(display_height / 2);
    const source_half_width: i32 = @intCast(size.width / 2);
    const source_half_height: i32 = @intCast(size.height / 2);
    const pa = objAffineParam(oam, affine_index, 0);
    const pb = objAffineParam(oam, affine_index, 1);
    const pc = objAffineParam(oam, affine_index, 2);
    const pd = objAffineParam(oam, affine_index, 3);

    for (0..display_height) |py| {
        for (0..display_width) |px| {
            const screen_x = obj_x + @as(i32, @intCast(px));
            const screen_y = obj_y + @as(i32, @intCast(py));
            if (screen_x < 0 or screen_x >= frame_width or screen_y < 0 or screen_y >= frame_height) continue;

            const local_x: i32 = @as(i32, @intCast(px)) - display_half_width;
            const local_y: i32 = @as(i32, @intCast(py)) - display_half_height;
            const source_x = ((pa * local_x + pb * local_y) >> 8) + source_half_width;
            const source_y = ((pc * local_x + pd * local_y) >> 8) + source_half_height;
            if (source_x < 0 or source_x >= size.width or source_y < 0 or source_y >= size.height) continue;

            const color_index = objTilePixel8bpp(
                vram,
                tile_id,
                size.width,
                one_dimensional,
                @intCast(source_x),
                @intCast(source_y),
            );
            if (color_index == 0) continue;
            writeCompositedObjPaletteColor(
                rgba,
                layers,
                palette,
                @intCast(screen_x),
                @intCast(screen_y),
                color_index,
                priority,
                0,
            );
        }
    }
}

fn renderObjLayer(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
    layers: *[frame_width * frame_height]LayerPixel,
) void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    const one_dimensional = (dispcnt & 0x0040) != 0;

    for (0..128) |obj_index| {
        const attr_offset = obj_index * 8;
        const attr0 = std.mem.readInt(u16, oam[attr_offset..][0..2], .little);
        const attr1 = std.mem.readInt(u16, oam[attr_offset + 2 ..][0..2], .little);
        const attr2 = std.mem.readInt(u16, oam[attr_offset + 4 ..][0..2], .little);

        const affine = (attr0 & 0x0100) != 0;
        if (!affine and (attr0 & 0x0200) != 0) continue; // regular OBJ disabled
        if (((attr0 >> 10) & 0x3) != 0) continue; // no semi-transparent / OBJ-window

        if (affine and (attr0 & 0x2000) != 0) {
            renderAffine8bppObj(palette, vram, oam, rgba, layers, attr0, attr1, attr2, one_dimensional);
        } else if ((attr0 & 0x2000) != 0) {
            renderRegular8bppObj(palette, vram, rgba, layers, attr0, attr1, attr2, one_dimensional);
        } else {
            renderRegular4bppObj(palette, vram, rgba, layers, attr0, attr1, attr2, one_dimensional);
        }
    }
}

pub fn dumpFrameRgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
) FrameError!void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    switch (dispcnt & 0x7) {
        0 => dumpMode0Rgba(io, palette, vram, oam, rgba),
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

fn envGetOwned(name: [:0]const u8) ?[]u8 {
    if (comptime standalone_build_cmd_test) {
        return std.testing.environ.getAlloc(std.heap.page_allocator, name) catch null;
    }

    const value = getenv(name) orelse return null;
    return std.heap.page_allocator.dupeZ(u8, std.mem.span(value)) catch null;
}

fn envEquals(name: [:0]const u8, expected: []const u8) bool {
    const value = envGetOwned(name) orelse return false;
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, expected);
}

pub export fn hm_runtime_output_mode_frame_raw() c_int {
    if (envGetOwned("HOMONCULI_OUTPUT_MODE")) |value| {
        defer std.heap.page_allocator.free(value);
        return if (envEquals("HOMONCULI_OUTPUT_MODE", "frame_raw")) 1 else 0;
    }
    return 1;
}

pub export fn hm_runtime_max_instructions(default_limit: u64) u64 {
    const value = envGetOwned("HOMONCULI_MAX_INSTRUCTIONS") orelse return default_limit;
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseUnsigned(u64, value, 10) catch default_limit;
}

pub export fn hmgba_sample_keyinput_for_frame(frame_index: u64) u16 {
    const script = envGetOwned("HOMONCULI_KEYINPUT_SCRIPT") orelse return 0x03FF;
    defer std.heap.page_allocator.free(script);
    return hmgbaSampleKeyinput(script, frame_index);
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

const SdlWindow = opaque {};
const SdlRenderer = opaque {};
const SdlTexture = opaque {};

const SdlEvent = extern struct {
    type: u32,
    padding: [252]u8,
};

const SdlInitFn = *const fn (u32) callconv(.c) bool;
const SdlQuitFn = *const fn () callconv(.c) void;
const SdlCreateWindowFn = *const fn ([*:0]const u8, c_int, c_int, u64) callconv(.c) ?*SdlWindow;
const SdlDestroyWindowFn = *const fn (?*SdlWindow) callconv(.c) void;
const SdlCreateRendererFn = *const fn (?*SdlWindow, ?[*:0]const u8) callconv(.c) ?*SdlRenderer;
const SdlDestroyRendererFn = *const fn (?*SdlRenderer) callconv(.c) void;
const SdlCreateTextureFn = *const fn (?*SdlRenderer, u32, c_int, c_int, c_int) callconv(.c) ?*SdlTexture;
const SdlDestroyTextureFn = *const fn (?*SdlTexture) callconv(.c) void;
const SdlUpdateTextureFn = *const fn (?*SdlTexture, ?*const anyopaque, *const anyopaque, c_int) callconv(.c) bool;
const SdlSetRenderDrawColorFn = *const fn (?*SdlRenderer, u8, u8, u8, u8) callconv(.c) bool;
const SdlRenderClearFn = *const fn (?*SdlRenderer) callconv(.c) bool;
const SdlRenderTextureFn = *const fn (?*SdlRenderer, ?*SdlTexture, ?*const anyopaque, ?*const anyopaque) callconv(.c) bool;
const SdlRenderPresentFn = *const fn (?*SdlRenderer) callconv(.c) bool;
const SdlPollEventFn = *const fn (*SdlEvent) callconv(.c) bool;
const SdlDelayFn = *const fn (u32) callconv(.c) void;

const SdlApi = struct {
    library: *anyopaque,
    init: SdlInitFn,
    quit: SdlQuitFn,
    create_window: SdlCreateWindowFn,
    destroy_window: SdlDestroyWindowFn,
    create_renderer: SdlCreateRendererFn,
    destroy_renderer: SdlDestroyRendererFn,
    create_texture: SdlCreateTextureFn,
    destroy_texture: SdlDestroyTextureFn,
    update_texture: SdlUpdateTextureFn,
    set_render_draw_color: SdlSetRenderDrawColorFn,
    render_clear: SdlRenderClearFn,
    render_texture: SdlRenderTextureFn,
    render_present: SdlRenderPresentFn,
    poll_event: SdlPollEventFn,
    delay: SdlDelayFn,

    fn load() ?SdlApi {
        const library = openSdl3Library() orelse return null;
        return .{
            .library = library,
            .init = loadSdlSymbol(SdlInitFn, library, "SDL_Init") orelse return closeAndFail(library),
            .quit = loadSdlSymbol(SdlQuitFn, library, "SDL_Quit") orelse return closeAndFail(library),
            .create_window = loadSdlSymbol(SdlCreateWindowFn, library, "SDL_CreateWindow") orelse return closeAndFail(library),
            .destroy_window = loadSdlSymbol(SdlDestroyWindowFn, library, "SDL_DestroyWindow") orelse return closeAndFail(library),
            .create_renderer = loadSdlSymbol(SdlCreateRendererFn, library, "SDL_CreateRenderer") orelse return closeAndFail(library),
            .destroy_renderer = loadSdlSymbol(SdlDestroyRendererFn, library, "SDL_DestroyRenderer") orelse return closeAndFail(library),
            .create_texture = loadSdlSymbol(SdlCreateTextureFn, library, "SDL_CreateTexture") orelse return closeAndFail(library),
            .destroy_texture = loadSdlSymbol(SdlDestroyTextureFn, library, "SDL_DestroyTexture") orelse return closeAndFail(library),
            .update_texture = loadSdlSymbol(SdlUpdateTextureFn, library, "SDL_UpdateTexture") orelse return closeAndFail(library),
            .set_render_draw_color = loadSdlSymbol(SdlSetRenderDrawColorFn, library, "SDL_SetRenderDrawColor") orelse return closeAndFail(library),
            .render_clear = loadSdlSymbol(SdlRenderClearFn, library, "SDL_RenderClear") orelse return closeAndFail(library),
            .render_texture = loadSdlSymbol(SdlRenderTextureFn, library, "SDL_RenderTexture") orelse return closeAndFail(library),
            .render_present = loadSdlSymbol(SdlRenderPresentFn, library, "SDL_RenderPresent") orelse return closeAndFail(library),
            .poll_event = loadSdlSymbol(SdlPollEventFn, library, "SDL_PollEvent") orelse return closeAndFail(library),
            .delay = loadSdlSymbol(SdlDelayFn, library, "SDL_Delay") orelse return closeAndFail(library),
        };
    }
};

var window_sdl: ?SdlApi = null;
var window_sdl_initialized = false;
var window_handle: ?*SdlWindow = null;
var window_renderer: ?*SdlRenderer = null;
var window_texture: ?*SdlTexture = null;
var window_frames_presented: u64 = 0;

fn closeAndFail(library: *anyopaque) ?SdlApi {
    _ = dlclose(library);
    return null;
}

fn loadSdlSymbol(comptime T: type, library: *anyopaque, name: [:0]const u8) ?T {
    const symbol = dlsym(library, name.ptr) orelse return null;
    return @ptrCast(symbol);
}

fn openSdl3Library() ?*anyopaque {
    if (envGetOwned("HOMONCULI_SDL3_PATH")) |path| {
        defer std.heap.page_allocator.free(path);
        const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return null;
        defer std.heap.page_allocator.free(path_z);
        return dlopen(path_z.ptr, rtld_now);
    }
    return dlopen("libSDL3.so.0", rtld_now) orelse dlopen("libSDL3.so", rtld_now);
}

pub export fn hmgba_dump_frame_raw(
    io: [*]const u8,
    palette: [*]const u8,
    vram: [*]const u8,
    oam: [*]const u8,
) c_int {
    const output_path = envGetOwned("HOMONCULI_OUTPUT_PATH") orelse return dump_error_missing_output_path;
    defer std.heap.page_allocator.free(output_path);
    const io_bytes: *const [1024]u8 = @ptrCast(io);
    const palette_bytes: *const [1024]u8 = @ptrCast(palette);
    const vram_bytes: *const [98304]u8 = @ptrCast(vram);
    const oam_bytes: *const [1024]u8 = @ptrCast(oam);
    var rgba: [rgba_len]u8 = undefined;
    dumpFrameRgba(io_bytes, palette_bytes, vram_bytes, oam_bytes, &rgba) catch return dump_error_unsupported_video_mode;

    if (comptime standalone_build_cmd_test) {
        Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = output_path, .data = &rgba }) catch return dump_error_write_failed;
    } else {
        const output_path_z = std.heap.page_allocator.dupeZ(u8, output_path) catch return dump_error_write_failed;
        defer std.heap.page_allocator.free(output_path_z);

        const file = fopen(output_path_z, "wb") orelse return dump_error_write_failed;
        defer _ = fclose(file);

        const written = fwrite(&rgba, 1, rgba.len, file);
        if (written != rgba.len) return dump_error_write_failed;
    }
    return dump_ok;
}

fn ensureSdl3Window() c_int {
    if (window_texture != null) return dump_ok;

    if (window_sdl == null) {
        window_sdl = SdlApi.load() orelse return dump_error_sdl3_missing;
    }
    const sdl = window_sdl.?;

    if (!window_sdl_initialized) {
        if (!sdl.init(sdl_init_video)) {
            hmgba_sdl3_shutdown();
            return dump_error_sdl3_init_failed;
        }
        window_sdl_initialized = true;
    }

    window_handle = sdl.create_window(
        "Homonculi GBA",
        frame_width * 3,
        frame_height * 3,
        sdl_window_resizable | sdl_window_high_pixel_density,
    ) orelse {
        hmgba_sdl3_shutdown();
        return dump_error_sdl3_window_failed;
    };

    window_renderer = sdl.create_renderer(window_handle, null) orelse {
        hmgba_sdl3_shutdown();
        return dump_error_sdl3_renderer_failed;
    };

    window_texture = sdl.create_texture(
        window_renderer,
        sdl_pixelformat_rgba32,
        sdl_textureaccess_streaming,
        frame_width,
        frame_height,
    ) orelse {
        hmgba_sdl3_shutdown();
        return dump_error_sdl3_texture_failed;
    };

    return dump_ok;
}

pub export fn hmgba_sdl3_present_frame(
    io: [*]const u8,
    palette: [*]const u8,
    vram: [*]const u8,
    oam: [*]const u8,
) c_int {
    const io_bytes: *const [1024]u8 = @ptrCast(io);
    const palette_bytes: *const [1024]u8 = @ptrCast(palette);
    const vram_bytes: *const [98304]u8 = @ptrCast(vram);
    const oam_bytes: *const [1024]u8 = @ptrCast(oam);
    var rgba: [rgba_len]u8 = undefined;
    dumpFrameRgba(io_bytes, palette_bytes, vram_bytes, oam_bytes, &rgba) catch return dump_error_unsupported_video_mode;

    const setup_result = ensureSdl3Window();
    if (setup_result != dump_ok) return setup_result;
    const sdl = window_sdl.?;

    var event: SdlEvent align(8) = undefined;
    while (sdl.poll_event(&event)) {
        if (event.type == sdl_event_quit) return dump_window_quit;
    }

    if (!sdl.update_texture(window_texture, null, &rgba, frame_width * 4)) return dump_error_sdl3_render_failed;
    if (!sdl.set_render_draw_color(window_renderer, 0, 0, 0, 255)) return dump_error_sdl3_render_failed;
    if (!sdl.render_clear(window_renderer)) return dump_error_sdl3_render_failed;
    if (!sdl.render_texture(window_renderer, window_texture, null, null)) return dump_error_sdl3_render_failed;
    if (!sdl.render_present(window_renderer)) return dump_error_sdl3_render_failed;

    window_frames_presented += 1;
    if (windowAutocloseFrames()) |limit| {
        if (window_frames_presented >= limit) return dump_window_quit;
    }
    sdl.delay(16);

    return dump_ok;
}

pub export fn hmgba_sdl3_shutdown() void {
    if (window_sdl) |sdl| {
        if (window_texture) |texture| sdl.destroy_texture(texture);
        if (window_renderer) |renderer| sdl.destroy_renderer(renderer);
        if (window_handle) |window| sdl.destroy_window(window);
        if (window_sdl_initialized) sdl.quit();
        _ = dlclose(sdl.library);
    }
    window_texture = null;
    window_renderer = null;
    window_handle = null;
    window_sdl_initialized = false;
    window_sdl = null;
    window_frames_presented = 0;
}

pub export fn hmgba_run_sdl3_window(
    io: [*]const u8,
    palette: [*]const u8,
    vram: [*]const u8,
    oam: [*]const u8,
) c_int {
    while (true) {
        const result = hmgba_sdl3_present_frame(io, palette, vram, oam);
        if (result == dump_window_quit) {
            hmgba_sdl3_shutdown();
            return dump_ok;
        }
        if (result != dump_ok) {
            hmgba_sdl3_shutdown();
            return result;
        }
    }
}

fn windowAutocloseFrames() ?u64 {
    const value = envGetOwned("HOMONCULI_WINDOW_AUTOCLOSE_FRAMES") orelse return null;
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
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
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0100, .little); // mode 0 + BG0
    std.mem.writeInt(u16, io[8..10], 0x0100, .little); // CBB0, SBB1, 4bpp
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little); // tile 0
    vram[0] = 0x10; // x=0 => color 0 backdrop, x=1 => color 1
    std.mem.writeInt(u16, palette[0..2], 0x0000, .little);
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[4..8]);
}

test "mode0 renderer decodes enabled bg1 tilemap" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0200, .little); // mode 0 + BG1
    std.mem.writeInt(u16, io[10..12], 0x0100, .little); // BG1: CBB0, SBB1, 4bpp
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little);
    vram[0] = 0x01;
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[0..4]);
}

test "mode0 renderer layers regular backgrounds by priority" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0300, .little); // mode 0 + BG0 + BG1
    std.mem.writeInt(u16, io[8..10], 0x0101, .little); // BG0: priority 1, SBB1
    std.mem.writeInt(u16, io[10..12], 0x0200, .little); // BG1: priority 0, SBB2
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little);
    std.mem.writeInt(u16, vram[0x1000..][0..2], 0x0001, .little);
    vram[0] = 0x01;
    vram[32] = 0x02;
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);
    std.mem.writeInt(u16, palette[4..6], 0x03E0, .little);

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[0..4]);
}

test "mode0 renderer decodes regular 8bpp background tiles" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0100, .little); // mode 0 + BG0
    std.mem.writeInt(u16, io[8..10], 0x0180, .little); // BG0: CBB0, SBB1, 8bpp
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little);
    vram[0] = 33;
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);
    std.mem.writeInt(u16, palette[66..68], 0x03E0, .little);

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[0..4]);
}

test "mode0 renderer selects screenblocks for 512-wide regular backgrounds" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0100, .little); // mode 0 + BG0
    std.mem.writeInt(u16, io[8..10], 0x4100, .little); // BG0: SBB1, size 512x256
    std.mem.writeInt(u16, io[16..18], 256, .little); // BG0HOFS
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little);
    std.mem.writeInt(u16, vram[0x1000..][0..2], 0x0001, .little);
    vram[0] = 0x01;
    vram[32] = 0x02;
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);
    std.mem.writeInt(u16, palette[4..6], 0x03E0, .little);

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[0..4]);
}

test "mode0 renderer applies regular background tile flips" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x0100, .little); // mode 0 + BG0
    std.mem.writeInt(u16, io[8..10], 0x0100, .little); // BG0: SBB1
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0400, .little); // tile 0, horizontal flip
    vram[0] = 0x01;
    vram[3] = 0x20;
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);
    std.mem.writeInt(u16, palette[4..6], 0x03E0, .little);

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[0..4]);
}

test "mode0 renderer composites a regular 4bpp obj in 1d mapping" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x1040, .little); // mode 0 + OBJ + 1D mapping
    std.mem.writeInt(u16, palette[0..2], 0x0000, .little);
    std.mem.writeInt(u16, palette[0x202..][0..2], 0x0100, .little);
    vram[0x10000] = 0x10; // x=0 transparent, x=1 palette index 1

    std.mem.writeInt(u16, oam[0..2], 20, .little); // y
    std.mem.writeInt(u16, oam[2..4], 10, .little); // x
    std.mem.writeInt(u16, oam[4..6], 0, .little); // tile 0, palette bank 0

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, rgba[((20 * frame_width) + 10) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 66, 0, 255 }, rgba[((20 * frame_width) + 11) * 4 ..][0..4]);
}

test "mode0 renderer keeps low-priority obj behind higher-priority bg" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x1140, .little); // mode 0 + BG0 + OBJ + 1D mapping
    std.mem.writeInt(u16, io[8..10], 0x0100, .little); // BG0 priority 0, SBB1
    std.mem.writeInt(u16, vram[0x800..][0..2], 0x0000, .little);
    vram[0] = 0x01;
    std.mem.writeInt(u16, palette[2..4], 0x001F, .little);

    for (0..128) |obj_index| {
        std.mem.writeInt(u16, oam[obj_index * 8 ..][0..2], 0x0200, .little); // regular OBJ disabled
    }
    vram[0x10000] = 0x01;
    std.mem.writeInt(u16, palette[0x202..][0..2], 0x03E0, .little);
    std.mem.writeInt(u16, oam[0..2], 0, .little); // y
    std.mem.writeInt(u16, oam[2..4], 0, .little); // x
    std.mem.writeInt(u16, oam[4..6], 0x0C00, .little); // tile 0, OBJ priority 3

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[0..4]);
}

test "mode0 renderer composites a regular 8bpp obj in 2d mapping" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x1000, .little); // mode 0 + OBJ, 2D mapping
    std.mem.writeInt(u16, palette[0..2], 0x0000, .little);
    std.mem.writeInt(u16, palette[0x202..][0..2], 0x001F, .little);
    vram[0x10000] = 0; // transparent
    vram[0x10001] = 1; // OBJ palette index 1

    std.mem.writeInt(u16, oam[0..2], 20 | 0x2000, .little); // y + 8bpp
    std.mem.writeInt(u16, oam[2..4], 10, .little); // x
    std.mem.writeInt(u16, oam[4..6], 0, .little); // tile 0

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, rgba[((20 * frame_width) + 10) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[((20 * frame_width) + 11) * 4 ..][0..4]);
}

test "mode0 renderer composites an identity affine 8bpp obj" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var oam: [1024]u8 = std.mem.zeroes([1024]u8);
    var rgba: [rgba_len]u8 = undefined;

    std.mem.writeInt(u16, io[0..2], 0x1000, .little); // mode 0 + OBJ, 2D mapping
    std.mem.writeInt(u16, palette[0..2], 0x0000, .little);
    std.mem.writeInt(u16, palette[0x202..][0..2], 0x03E0, .little);
    vram[0x10000] = 0;
    vram[0x10001] = 1;

    std.mem.writeInt(u16, oam[0..2], 20 | 0x0100 | 0x2000, .little); // y + affine + 8bpp
    std.mem.writeInt(u16, oam[2..4], 10, .little); // x, affine matrix 0
    std.mem.writeInt(u16, oam[4..6], 0, .little); // tile 0
    std.mem.writeInt(i16, oam[6..8], 0x0100, .little); // pa
    std.mem.writeInt(i16, oam[14..16], 0, .little); // pb
    std.mem.writeInt(i16, oam[22..24], 0, .little); // pc
    std.mem.writeInt(i16, oam[30..32], 0x0100, .little); // pd

    try dumpFrameRgba(&io, &palette, &vram, &oam, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, rgba[((20 * frame_width) + 10) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[((20 * frame_width) + 11) * 4 ..][0..4]);
}

test "gba keyinput helper replays comma-separated active-low samples" {
    try std.testing.expectEqual(@as(u16, 0x03FF), hmgbaSampleKeyinput("03ff,03fe", 0));
    try std.testing.expectEqual(@as(u16, 0x03FE), hmgbaSampleKeyinput("03ff,03fe", 1));
    try std.testing.expectEqual(@as(u16, 0x03FE), hmgbaSampleKeyinput("03ff,03fe", 9));
}
