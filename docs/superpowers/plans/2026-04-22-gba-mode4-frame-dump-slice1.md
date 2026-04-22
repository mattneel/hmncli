# GBA Mode 4 Frame Dump Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first GBA graphics output path: deterministic raw Mode 4 frame dumps from final guest memory state, with a sparse smoke test for the real Mode 4 ROM `ppu-hello.gba`.

**Architecture:** Keep rendering semantics inside a GBA runtime helper module and keep `hmncli` responsible for output-policy selection. The generated binary gets a small environment-variable contract for `frame_raw` and instruction-budget execution, then calls into a host-side Mode 4 rasterizer over emulated `IO`, BG palette RAM, and `VRAM`.

**Tech Stack:** Zig 0.17 dev toolchain, existing LLVM-IR code generator, host-side exported Zig runtime helpers linked into the emitted native binary, `std.testing`, real `jsmolka/gba-tests` ROM fixtures.

---

## File Structure

**Files:**
- Modify: `src/cli/parse.zig`
- Modify: `src/main.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `src/root.zig`
- Create: `src/gba_ppu.zig`
- Create: `src/frame_test_support.zig`

**Responsibilities:**
- `src/cli/parse.zig`: parse `--output` and `--max-instructions` for the `build` command.
- `src/build_cmd.zig`: carry slice-1 build options, compile/link the runtime helper, and hold real-ROM acceptance tests.
- `src/llvm_codegen.zig`: add `frame_raw`, instruction-budget stop plumbing, env-contract reads, and final-output dispatch.
- `src/gba_ppu.zig`: exported host runtime helpers for frame-dump policy and Mode 4 rasterization.
- `src/frame_test_support.zig`: test-only helpers for reading `.rgba`, validating exact size, sampling pixels, and writing scratch artifacts.
- `src/root.zig`: export new modules through the package root.

## Scope Guardrails

- In scope: Background Mode 4 only, BG palette only, final-state snapshot dump, explicit instruction cap for `frame_raw`, sparse exact-pixel smoke assertions.
- Out of scope: eggvance goldens, tile modes, sprites, scanline timing, frame-`N`, PNG fixtures in git, declaration-schema changes.
- Fixture note: `ppu-stripes.gba` and `ppu-shades.gba` remain real graphics fixtures, but they set BG0 in mode 0 rather than Mode 4. Slice 1 uses `ppu-hello.gba`, which goes through the shared Mode 4 text helper path.
- Stop after Slice 1 is green. Do not start golden generation or eggvance integration.

### Task 1: Extend Build Parsing For `frame_raw`

**Files:**
- Modify: `src/cli/parse.zig`
- Test: `src/cli/parse.zig`

- [ ] **Step 1: Write the failing parser tests**

```zig
test "parse accepts build output mode and instruction cap" {
    try std.testing.expectEqualDeep(
        Command{ .build = .{
            .rom_path = "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "zig-out/bin/ppu-stripes",
            .output_mode = .frame_raw,
            .max_instructions = 1_000_000,
        } },
        try parse(&.{
            "hmncli",
            "build",
            "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            "--machine",
            "gba",
            "--target",
            "x86_64-linux",
            "--output",
            "frame_raw",
            "--max-instructions",
            "1000000",
            "-o",
            "zig-out/bin/ppu-stripes",
        }),
    );
}

test "parse rejects frame_raw build without instruction cap" {
    try std.testing.expectError(
        error.InvalidCommand,
        parse(&.{
            "hmncli",
            "build",
            "tests/fixtures/real/jsmolka/ppu-stripes.gba",
            "--machine",
            "gba",
            "--output",
            "frame_raw",
            "-o",
            "zig-out/bin/ppu-stripes",
        }),
    );
}
```

- [ ] **Step 2: Run the parser tests to verify they fail**

Run: `zig test src/cli/parse.zig`
Expected: FAIL because `BuildCommand` does not yet have `output_mode` or `max_instructions`.

- [ ] **Step 3: Implement the minimal parser support**

```zig
pub const OutputMode = enum {
    auto,
    frame_raw,
};

pub const BuildCommand = struct {
    rom_path: []const u8,
    machine_name: []const u8,
    output_path: []const u8,
    target: ?[]const u8 = null,
    output_mode: OutputMode = .auto,
    max_instructions: ?u64 = null,
};
```

```zig
if (std.mem.eql(u8, flag, "--output")) {
    if (std.mem.eql(u8, value, "frame_raw")) {
        build.output_mode = .frame_raw;
        continue;
    }
    return error.InvalidCommand;
}
if (std.mem.eql(u8, flag, "--max-instructions")) {
    build.max_instructions = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidCommand;
    continue;
}
```

```zig
if (build.output_mode == .frame_raw and build.max_instructions == null) return error.InvalidCommand;
```

- [ ] **Step 4: Run the parser tests to verify they pass**

Run: `zig test src/cli/parse.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/cli/parse.zig
git commit -m "feat(cli): parse frame_raw build options"
```

### Task 2: Add The Failing Runtime And Framebuffer Tests

**Files:**
- Create: `src/gba_ppu.zig`
- Create: `src/frame_test_support.zig`
- Modify: `src/root.zig`
- Test: `src/gba_ppu.zig`
- Test: `src/frame_test_support.zig`

- [ ] **Step 1: Write the failing Mode 4 rasterizer tests**

```zig
const std = @import("std");
const gba_ppu = @import("gba_ppu.zig");

test "mode4 renderer decodes active page into rgba pixels" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var rgba: [240 * 160 * 4]u8 = undefined;

    std.mem.writeInt(u16, palette[0..2], 0x001F, .little); // red
    std.mem.writeInt(u16, palette[2..4], 0x03E0, .little); // green
    io[0] = 4; // mode 4, page 0
    vram[0] = 0;
    vram[1] = 1;

    try gba_ppu.dumpMode4Rgba(&io, &palette, &vram, &rgba);

    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, rgba[4..8]);
}

test "mode4 renderer rejects unsupported display mode" {
    var io: [1024]u8 = std.mem.zeroes([1024]u8);
    var palette: [1024]u8 = std.mem.zeroes([1024]u8);
    var vram: [98304]u8 = std.mem.zeroes([98304]u8);
    var rgba: [240 * 160 * 4]u8 = undefined;

    io[0] = 3;
    try std.testing.expectError(error.UnsupportedVideoMode, gba_ppu.dumpMode4Rgba(&io, &palette, &vram, &rgba));
}
```

```zig
const std = @import("std");
const support = @import("frame_test_support.zig");

test "frame test support reads rgba and validates exact gba frame size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = [_]u8{0} ** (240 * 160 * 4);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "frame.rgba", .data = &bytes });

    const loaded = try support.readExactFrame(std.testing.allocator, std.testing.io, tmp.dir, "frame.rgba");
    defer std.testing.allocator.free(loaded);

    try std.testing.expectEqual(@as(usize, 240 * 160 * 4), loaded.len);
}
```

- [ ] **Step 2: Run the unit tests to verify they fail**

Run: `zig test src/gba_ppu.zig && zig test src/frame_test_support.zig`
Expected: FAIL because the files and helpers do not exist yet.

- [ ] **Step 3: Implement the minimal framebuffer helpers**

```zig
pub const FrameError = error{
    UnsupportedVideoMode,
};

pub fn dumpMode4Rgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[240 * 160 * 4]u8,
) FrameError!void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    if ((dispcnt & 0x7) != 4) return error.UnsupportedVideoMode;
    const page_offset: usize = if ((dispcnt & 0x0010) != 0) 0xA000 else 0;
    var pixel_index: usize = 0;
    while (pixel_index < 240 * 160) : (pixel_index += 1) {
        const palette_index = vram[page_offset + pixel_index];
        const color = std.mem.readInt(u16, palette[palette_index * 2 ..][0..2], .little);
        rgba[pixel_index * 4 + 0] = expand5(@intCast(color & 0x1F));
        rgba[pixel_index * 4 + 1] = expand5(@intCast((color >> 5) & 0x1F));
        rgba[pixel_index * 4 + 2] = expand5(@intCast((color >> 10) & 0x1F));
        rgba[pixel_index * 4 + 3] = 255;
    }
}
```

```zig
pub fn readExactFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ![]u8 {
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(240 * 160 * 4 + 1));
    errdefer allocator.free(bytes);
    if (bytes.len != 240 * 160 * 4) return error.InvalidFrameSize;
    return bytes;
}
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `zig test src/gba_ppu.zig && zig test src/frame_test_support.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/gba_ppu.zig src/frame_test_support.zig src/root.zig
git commit -m "feat(gba): add mode4 framebuffer helpers"
```

### Task 3: Wire `frame_raw` Through Build And Codegen

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Write the failing build/codegen tests**

```zig
test "build emits frame_raw llvm hooks when requested" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/real/jsmolka/ppu-stripes.gba",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(rom);
    try tmp.dir.writeFile(io, .{ .sub_path = "ppu-stripes.gba", .data = rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(io, std.testing.allocator, tmp.dir, &output.writer, .{
        .rom_path = "ppu-stripes.gba",
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_mode = .frame_raw,
        .max_instructions = 1_000_000,
        .output_path = "ppu-stripes-native",
    });

    const llvm_bytes = try tmp.dir.readFileAlloc(io, "ppu-stripes-native.ll", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(llvm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@hmgba_dump_frame_raw") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "HOMONCULI_MAX_INSTRUCTIONS") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "HOMONCULI_OUTPUT_PATH") != null);
}
```

- [ ] **Step 2: Run the build/codegen test to verify it fails**

Run: `zig test src/build_cmd.zig --test-filter "frame_raw llvm hooks"`
Expected: FAIL because there is no `frame_raw` output mode or runtime helper linkage yet.

- [ ] **Step 3: Implement the minimal build/codegen path**

```zig
const output_mode: llvm_codegen.OutputMode = switch (options.output_mode) {
    .auto => if (hasArmReportRoutine(functions.items))
        .arm_report
    else if (has_store and has_self_loop)
        .memory_summary
    else
        .register_r0_decimal,
    .frame_raw => .frame_raw,
};
```

```zig
pub const OutputMode = enum {
    register_r0_decimal,
    memory_summary,
    arm_report,
    frame_raw,
};
```

```zig
const helper_obj = try compileRuntimeHelper(io, allocator, cwd, options.target, "src/gba_ppu.zig");
try argv.append(allocator, helper_obj);
```

```zig
try writer.print("declare i32 @hmgba_dump_frame_raw(ptr, ptr, ptr)\n", .{});
try writer.print("declare i64 @hm_runtime_max_instructions()\n", .{});
try writer.print("declare i32 @hm_runtime_output_mode_frame_raw()\n", .{});
```

Key implementation details:

- add a guest-state instruction-budget field and stop flag
- initialize the budget from `hm_runtime_max_instructions()` in `@main`
- decrement before each instruction block and return early once the budget is exhausted
- call `@hmgba_dump_frame_raw` from final output when `hm_runtime_output_mode_frame_raw() != 0`

- [ ] **Step 4: Run the focused build/codegen test to verify it passes**

Run: `zig test src/build_cmd.zig --test-filter "frame_raw llvm hooks"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/build_cmd.zig src/llvm_codegen.zig src/gba_ppu.zig
git commit -m "feat(gba): emit frame_raw runtime hooks"
```

### Task 4: Add A Real-ROM Smoke Test For Mode 4 Dumps

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `src/frame_test_support.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Write the failing real-ROM smoke tests**

```zig
test "build executes ppu-hello with frame_raw and writes exact sampled pixels" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try stageRom(std.testing.allocator, io, tmp.dir, "tests/fixtures/real/jsmolka/ppu-hello.gba", "ppu-hello.gba");
    try buildFrameRawRom(std.testing.allocator, io, tmp.dir, "ppu-hello.gba", "ppu-hello-native", 5_000);
    try runFrameRawBinary(std.testing.allocator, io, tmp.dir, "ppu-hello-native", "hello.rgba", 5_000);

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "hello.rgba");
    defer std.testing.allocator.free(frame);

    try frame_test_support.expectPixel(frame, 0, 0, .{ 0, 0, 0, 255 });
    try frame_test_support.expectPixel(frame, 73, 76, .{ 255, 255, 255, 255 });
    try frame_test_support.expectPixel(frame, 75, 76, .{ 0, 0, 0, 255 });
    try frame_test_support.expectPixel(frame, 82, 78, .{ 255, 255, 255, 255 });
    try frame_test_support.expectPixel(frame, 80, 78, .{ 0, 0, 0, 255 });
    try frame_test_support.expectPixel(frame, 120, 79, .{ 255, 255, 255, 255 });
}
```

- [ ] **Step 2: Run the smoke tests to verify they fail**

Run: `zig test src/build_cmd.zig --test-filter "frame_raw"`
Expected: FAIL because the binary does not yet write a `.rgba` output file.

- [ ] **Step 3: Implement the minimal test support and binary env setup**

```zig
pub fn expectPixel(frame: []const u8, x: usize, y: usize, rgba: [4]u8) !void {
    const offset = (y * 240 + x) * 4;
    try std.testing.expectEqualSlices(u8, &rgba, frame[offset .. offset + 4]);
}
```

```zig
var env_map = try std.process.EnvMap.init(std.testing.allocator);
defer env_map.deinit();
try env_map.put("HOMONCULI_OUTPUT_MODE", "frame_raw");
try env_map.put("HOMONCULI_OUTPUT_PATH", "stripes.rgba");
try env_map.put("HOMONCULI_MAX_INSTRUCTIONS", "1000000");
```

- [ ] **Step 4: Run the smoke tests and then the full suite**

Run: `zig test src/build_cmd.zig --test-filter "frame_raw"`
Expected: PASS

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/build_cmd.zig src/frame_test_support.zig
git commit -m "feat(gba): add mode4 frame dump smoke tests"
```

## Self-Review

- Spec coverage: this plan covers slice-1-only output mode, env contract, Mode 4 renderer, instruction-cap trigger, scratch test helpers, and one real-ROM smoke test through the shared Mode 4 text helper path. It intentionally does not include eggvance goldens.
- Placeholder scan: no `TODO`/`TBD` markers remain; the `ppu-hello.gba` pixel tuples are resolved during Task 4 from actual first-run output before that task is committed.
- Type consistency: `frame_raw`, `max_instructions`, `gba_ppu.dumpMode4Rgba`, and `frame_test_support.readExactFrame` are named consistently across tasks.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-22-gba-mode4-frame-dump-slice1.md`. Inline execution is selected for this session, so implementation should proceed task-by-task using `superpowers:executing-plans`, stop after Slice 1 is green, and wait for review before starting Slice 2.
