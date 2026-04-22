# Tonc Demo Ladder Bring-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest and pin the first `tonc` fixtures, then make `sbb_reg`, `obj_demo`, and `key_demo` pass as real bring-up checkpoints on the GBA target while explicitly deferring `irq_demo`.

**Architecture:** Treat the named `tonc` demos as the stopping rule rather than “implementing Mode 0” in the abstract. Start by checking in exact demo ROMs with provenance and measured failure surfaces, then clear the shared devkitARM startup blockers (`SWI 0` and `VBlankIntrWait`) before bringing up the smallest render/input slices needed for `sbb_reg`, `obj_demo`, and `key_demo`. Keep graphics semantics in the existing GBA runtime helper, keep policy in test orchestration, and stop after the bring-up milestone is green.

**Tech Stack:** Zig 0.17 dev toolchain, existing LLVM IR code generator, Capstone-backed ARM/Thumb decode, host-side exported Zig runtime helpers linked into emitted native binaries, devkitARM `r67.1-1`, `gbadev-org/libtonc-examples` at `db70fa29a0baae12c5c7603426d8535ebb5cc6ed`.

---

## Scope Check

This plan intentionally covers fixture ingestion plus the bring-up milestone only. The approved spec separates bring-up and oracle parity because they have different failure modes; write the parity plan after the bring-up exit criteria are green.

## File Structure

**Files:**
- Create: `tests/fixtures/real/tonc/sbb_reg.gba`
- Create: `tests/fixtures/real/tonc/obj_demo.gba`
- Create: `tests/fixtures/real/tonc/key_demo.gba`
- Create: `tests/fixtures/real/tonc/irq_demo.gba`
- Create: `tests/fixtures/real/tonc/PROVENANCE.md`
- Create: `tests/fixtures/real/tonc/INGESTION.md`
- Create: `scripts/rebuild-tonc-fixtures.sh`
- Create: `src/tonc_fixture_support.zig`
- Modify: `src/root.zig`
- Modify: `src/machines/gba.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `src/gba_ppu.zig`
- Modify: `src/frame_test_support.zig`

**Responsibilities:**
- `tests/fixtures/real/tonc/*.gba`: committed source-of-truth demo ROMs built from pinned `libtonc-examples`.
- `tests/fixtures/real/tonc/PROVENANCE.md`: exact source/toolchain/build recipe plus hashes and sizes.
- `tests/fixtures/real/tonc/INGESTION.md`: live measured record of build status, first failure surfaces, and the explicit `irq_demo` deferral.
- `scripts/rebuild-tonc-fixtures.sh`: deliberate rebuild path for the committed tonc ROMs.
- `src/tonc_fixture_support.zig`: test-only metadata for tonc fixture paths, hashes, sizes, instruction caps, scripted input strings, and smoke sample coordinates.
- `src/root.zig`: export the new support module so `zig build test` picks up its tests.
- `src/machines/gba.zig`: declare the new BIOS shim surfaces needed by devkitARM startup and tonc loops.
- `src/build_cmd.zig`: real-ROM acceptance tests, fixture hash enforcement, and tonc bring-up smoke checks.
- `src/llvm_codegen.zig`: lower the new BIOS shim surfaces and add the minimal guest-state fields they need.
- `src/gba_ppu.zig`: runtime helper exports for frame dumping and deterministic KEYINPUT sampling.
- `src/frame_test_support.zig`: generic exact-pixel and non-background-pixel helpers used by tonc smoke tests.

## Measured Starting Point

- `libtonc-examples` commit: `db70fa29a0baae12c5c7603426d8535ebb5cc6ed`
- toolchain: `devkitARM r67.1-1`
- built demo ROMs:
  - `sbb_reg.gba`: `2952` bytes, SHA-256 `7dfac2ef74f8152b69c54f6a090244a6c7e1671bf6fcd3fac36eb27abf57063d`
  - `obj_demo.gba`: `5672` bytes, SHA-256 `53ed8c1837e08e8345df1c59a5bf6d6d5f8bb4f55708f77891cccb2a8a46de25`
  - `key_demo.gba`: `41736` bytes, SHA-256 `6a4f7ae7dcd83ef63fab33a5060e81e9eeb5feb88a9ff7bf57449061b27e0f71`
  - `irq_demo.gba`: `80724` bytes, SHA-256 `0706b281ff79ee79f28f399652a4ac98e59d3e20a5ff2fe5f104f73fc8d9b387`
- current `hmncli` first failure for all four demos:

```text
Unsupported SWI 0x000000 at 0x08000186 for gba
```

- source inspection already shows `irq_demo` exceeds this milestone’s interrupt scope:
  - it uses `II_HBLANK`
  - it uses `II_VCOUNT`
  - it toggles interrupt priority
  - it enables nested interrupts inside the handler path

## Scope Guardrails

- In scope: fixture ingestion, hash enforcement, `SWI 0` startup exit, `VBlankIntrWait`, deterministic KEYINPUT scripting, Mode 0 BG0 regular-tile rendering for `sbb_reg`, minimal regular OBJ rendering for `obj_demo`, `key_demo` held-input smoke checks, explicit `irq_demo` deferral.
- Out of scope: parity goldens, HBlank/VCount IRQ behavior, nested or prioritized IRQ dispatch, affine OBJ, DMA, blending/window/mosaic, commercial titles, generalized input CLI flags.
- Runtime contract choice for this milestone: keep input injection as an environment contract on the produced native binary, just like `frame_raw` and `max-instructions`. Do not design a full `run` command in this slice.
- Stop when `sbb_reg`, `obj_demo`, and `key_demo` are green and `irq_demo` is explicitly deferred in `INGESTION.md`. Do not start parity work from this plan.

### Task 1: Ingest And Pin The Tonc Fixtures

**Files:**
- Create: `tests/fixtures/real/tonc/sbb_reg.gba`
- Create: `tests/fixtures/real/tonc/obj_demo.gba`
- Create: `tests/fixtures/real/tonc/key_demo.gba`
- Create: `tests/fixtures/real/tonc/irq_demo.gba`
- Create: `tests/fixtures/real/tonc/PROVENANCE.md`
- Create: `tests/fixtures/real/tonc/INGESTION.md`
- Create: `scripts/rebuild-tonc-fixtures.sh`
- Create: `src/tonc_fixture_support.zig`
- Modify: `src/root.zig`
- Test: `src/tonc_fixture_support.zig`

- [ ] **Step 1: Write the failing fixture verification test**

```zig
const std = @import("std");

pub const Fixture = struct {
    name: []const u8,
    path: []const u8,
    size: usize,
    sha256_hex: []const u8,
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
    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    for (fixtures) |fixture| {
        const bytes = try cwd.readFileAlloc(io, fixture.path, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(bytes);

        try std.testing.expectEqual(fixture.size, bytes.len);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

        var actual_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&actual_hex, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
        try std.testing.expectEqualStrings(fixture.sha256_hex, &actual_hex);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig test src/tonc_fixture_support.zig`
Expected: FAIL with `FileNotFound` because `tests/fixtures/real/tonc/*.gba` and `src/tonc_fixture_support.zig` do not exist yet.

- [ ] **Step 3: Implement fixture ingestion, provenance, and the live ingestion record**

```bash
#!/usr/bin/env bash
set -euo pipefail

source /etc/profile.d/devkit-env.sh

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/real/tonc"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone https://github.com/gbadev-org/libtonc-examples.git "$workdir/libtonc-examples"
cd "$workdir/libtonc-examples"
git checkout db70fa29a0baae12c5c7603426d8535ebb5cc6ed

for demo in basic/sbb_reg basic/obj_demo basic/key_demo ext/irq_demo; do
  make -C "$demo"
  cp "$demo/$(basename "$demo").gba" "$fixture_dir/$(basename "$demo").gba"
done
```

```markdown
# Tonc Fixture Provenance

- source repository: `https://github.com/gbadev-org/libtonc-examples`
- source commit: `db70fa29a0baae12c5c7603426d8535ebb5cc6ed`
- toolchain: `devkitARM r67.1-1`
- environment bootstrap: `source /etc/profile.d/devkit-env.sh`
- rebuild command: `scripts/rebuild-tonc-fixtures.sh`

## Fixture Hashes

- `sbb_reg.gba`: size `2952`, SHA-256 `7dfac2ef74f8152b69c54f6a090244a6c7e1671bf6fcd3fac36eb27abf57063d`
- `obj_demo.gba`: size `5672`, SHA-256 `53ed8c1837e08e8345df1c59a5bf6d6d5f8bb4f55708f77891cccb2a8a46de25`
- `key_demo.gba`: size `41736`, SHA-256 `6a4f7ae7dcd83ef63fab33a5060e81e9eeb5feb88a9ff7bf57449061b27e0f71`
- `irq_demo.gba`: size `80724`, SHA-256 `0706b281ff79ee79f28f399652a4ac98e59d3e20a5ff2fe5f104f73fc8d9b387`
```

```markdown
# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: built cleanly from `basic/sbb_reg`
- `obj_demo`: built cleanly from `basic/obj_demo`
- `key_demo`: built cleanly from `basic/key_demo`
- `irq_demo`: built cleanly from `ext/irq_demo`

## First Homonculi Failure Surface

- `sbb_reg`: `Unsupported SWI 0x000000 at 0x08000186 for gba`
- `obj_demo`: `Unsupported SWI 0x000000 at 0x08000186 for gba`
- `key_demo`: `Unsupported SWI 0x000000 at 0x08000186 for gba`
- `irq_demo`: `Unsupported SWI 0x000000 at 0x08000186 for gba`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
```

```zig
const std = @import("std");
pub const tonc_fixture_support = @import("tonc_fixture_support.zig");
```

- [ ] **Step 4: Run the rebuild script and the verification test**

Run:

```bash
scripts/rebuild-tonc-fixtures.sh
zig test src/tonc_fixture_support.zig
```

Expected: PASS. The fixtures are now checked in, hash-verified, and recorded in `PROVENANCE.md` and `INGESTION.md`.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/real/tonc scripts/rebuild-tonc-fixtures.sh src/tonc_fixture_support.zig src/root.zig
git commit -m "feat(fixtures): ingest pinned tonc demo roms"
```

### Task 2: Advance Past devkitARM Startup `SWI 0`

**Files:**
- Modify: `src/machines/gba.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `tests/fixtures/real/tonc/INGESTION.md`
- Test: `src/build_cmd.zig`
- Test: `src/llvm_codegen.zig`

- [ ] **Step 1: Write the failing shared-prerequisite tests**

```zig
test "tonc sbb_reg no longer stops at startup soft reset swi" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stderr = try buildFixtureExpectFailure(
        std.testing.allocator,
        io,
        tmp.dir,
        "tests/fixtures/real/tonc/sbb_reg.gba",
    );
    defer std.testing.allocator.free(stderr);

    try std.testing.expect(std.mem.indexOf(u8, stderr, "Unsupported SWI 0x000000") == null);
}
```

```zig
test "llvm emission includes gba soft reset shim" {
    var output = std.io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try emitPreamble(&output.writer, .{
        .machine_name = "gba",
        .output_mode = .retired_count,
        .instruction_limit = 8,
        .functions = &.{},
        .entry = 0x08000000,
    });

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@shim_gba_SoftReset") != null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
zig test src/build_cmd.zig --test-filter "tonc sbb_reg no longer stops at startup soft reset swi"
zig test src/llvm_codegen.zig --test-filter "soft reset shim"
```

Expected: FAIL. The fixture still dies on `Unsupported SWI 0x000000`, and the LLVM preamble does not declare `@shim_gba_SoftReset`.

- [ ] **Step 3: Implement the minimal `SoftReset` shim**

```zig
fn buildFixtureExpectFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom_path: []const u8,
) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    run(io, allocator, dir, &writer.writer, .{
        .rom_path = rom_path,
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_path = ".zig-cache/tonc/should-not-exist",
        .output_mode = .frame_raw,
        .max_instructions = 50_000,
        .optimize = .release,
    }) catch |err| {
        _ = err;
        return writer.toOwnedSlice();
    };
    return error.ExpectedBuildFailure;
}
```

```zig
.{
    .id = .{ .kind = .shim, .namespace = "gba", .name = "SoftReset" },
    .state = .implemented,
    .args = &.{},
    .returns = .i32,
    .effects = .impure,
    .tests = &.{},
    .doc_refs = &.{},
    .notes = &.{"Minimal devkitARM startup epilogue shim: stop the generated binary cleanly when main returns."},
},
```

```zig
fn swiShimName(imm24: u24) ?[]const u8 {
    if (imm24 == 0x000000) return "SoftReset";
    if (isDivSwi(imm24)) return "Div";
    if (isSqrtSwi(imm24)) return "Sqrt";
    return null;
}
```

```zig
define i32 @shim_gba_SoftReset(ptr %state) {
entry:
  %stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 21
  store i1 true, ptr %stop_flag_ptr, align 1
  ret i32 0
}
```

```zig
.swi => |swi| {
    const shim_name = switch (swi.imm24) {
        0x000000 => "SoftReset",
        0x000006, 0x060000 => "Div",
        0x000008, 0x080000 => "Sqrt",
        0x000005, 0x050000 => "VBlankIntrWait",
        else => unreachable,
    };
    try writer.print("  call i32 @shim_gba_{s}(ptr %state)\n", .{shim_name});
    try emitFallthrough(writer, function, node.address + node.size_bytes);
}
```

- [ ] **Step 4: Run the tests and refresh the ingestion record**

Run:

```bash
zig test src/llvm_codegen.zig --test-filter "soft reset shim"
zig test src/build_cmd.zig --test-filter "tonc sbb_reg no longer stops at startup soft reset swi"
zig build run -- build tests/fixtures/real/tonc/sbb_reg.gba --machine gba --target x86_64-linux --output frame_raw --max-instructions 50000 -o /tmp/sbb_reg-native
```

Expected:
- both tests PASS
- the build no longer fails on `Unsupported SWI 0x000000`
- update `tests/fixtures/real/tonc/INGESTION.md` with the next blocker the command reports

- [ ] **Step 5: Commit**

```bash
git add src/machines/gba.zig src/build_cmd.zig src/llvm_codegen.zig tests/fixtures/real/tonc/INGESTION.md
git commit -m "feat(gba): handle devkitarm startup soft reset"
```

### Task 3: Add Minimal `VBlankIntrWait` And Deterministic KEYINPUT Sampling

**Files:**
- Modify: `src/machines/gba.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `src/gba_ppu.zig`
- Modify: `src/build_cmd.zig`
- Modify: `tests/fixtures/real/tonc/INGESTION.md`
- Test: `src/gba_ppu.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Write the failing VBlank/input tests**

```zig
test "gba keyinput helper replays comma-separated active-low samples" {
    try std.testing.expectEqual(@as(u16, 0x03FF), hmgbaSampleKeyinput("03ff,03fe", 0));
    try std.testing.expectEqual(@as(u16, 0x03FE), hmgbaSampleKeyinput("03ff,03fe", 1));
    try std.testing.expectEqual(@as(u16, 0x03FE), hmgbaSampleKeyinput("03ff,03fe", 9));
}
```

```zig
test "tonc sbb_reg no longer stops at VBlankIntrWait swi" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stderr = try buildFixtureExpectFailure(
        std.testing.allocator,
        io,
        tmp.dir,
        "tests/fixtures/real/tonc/sbb_reg.gba",
    );
    defer std.testing.allocator.free(stderr);

    try std.testing.expect(std.mem.indexOf(u8, stderr, "Unsupported SWI 0x000005") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "Unsupported SWI 0x050000") == null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
zig test src/gba_ppu.zig --test-filter "keyinput helper"
zig test src/build_cmd.zig --test-filter "tonc sbb_reg no longer stops at VBlankIntrWait swi"
```

Expected: FAIL. There is no deterministic KEYINPUT sampler yet, and `sbb_reg` still dies on `VBlankIntrWait` once `SWI 0` is handled.

- [ ] **Step 3: Implement the minimal wait/input runtime**

```zig
.{
    .id = .{ .kind = .shim, .namespace = "gba", .name = "VBlankIntrWait" },
    .state = .implemented,
    .args = &.{},
    .returns = .i32,
    .effects = .impure,
    .tests = &.{},
    .doc_refs = &.{},
    .notes = &.{"Minimal tonc bring-up wait shim: advance the synthetic VBlank count, refresh KEYINPUT, optionally fire VBlank-side effects, then return."},
},
```

```zig
const guest_state_vblank_count_field = 24;
```

```zig
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
```

```zig
define i32 @shim_gba_VBlankIntrWait(ptr %state) {
entry:
  %vblank_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 24
  %vblank_curr = load i64, ptr %vblank_ptr, align 8
  %keyinput_value = call i16 @hmgba_sample_keyinput_for_frame(i64 %vblank_curr)
  %io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 16
  %keyinput_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 304
  store i16 %keyinput_value, ptr %keyinput_ptr, align 1
  %vblank_next = add i64 %vblank_curr, 1
  store i64 %vblank_next, ptr %vblank_ptr, align 8
  %dispstat_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 4
  %dispstat = load i16, ptr %dispstat_ptr, align 1
  %dispstat_i32 = zext i16 %dispstat to i32
  call void @hmn_maybe_fire_vblank_irq(ptr %state, i32 %dispstat_i32)
  ret i32 0
}
```

- [ ] **Step 4: Run the tests and record the next measured blocker**

Run:

```bash
zig test src/gba_ppu.zig --test-filter "keyinput helper"
zig test src/build_cmd.zig --test-filter "tonc sbb_reg no longer stops at VBlankIntrWait swi"
zig build run -- build tests/fixtures/real/tonc/sbb_reg.gba --machine gba --target x86_64-linux --output frame_raw --max-instructions 50000 -o /tmp/sbb_reg-native
HOMONCULI_OUTPUT_MODE=frame_raw HOMONCULI_OUTPUT_PATH=/tmp/sbb_reg.rgba HOMONCULI_MAX_INSTRUCTIONS=50000 /tmp/sbb_reg-native
```

Expected:
- both tests PASS
- the native binary now runs far enough to hit the renderer path
- the measured next blocker is the current `frame_raw requires GBA video mode 4` runtime failure
- record that blocker in `tests/fixtures/real/tonc/INGESTION.md`

- [ ] **Step 5: Commit**

```bash
git add src/machines/gba.zig src/llvm_codegen.zig src/gba_ppu.zig src/build_cmd.zig tests/fixtures/real/tonc/INGESTION.md
git commit -m "feat(gba): add minimal tonc vblank wait and keyinput sampling"
```

### Task 4: Make `sbb_reg` Render In Mode 0

**Files:**
- Modify: `src/gba_ppu.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/tonc_fixture_support.zig`
- Modify: `src/frame_test_support.zig`
- Test: `src/gba_ppu.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Write the failing `sbb_reg` smoke tests**

```zig
pub const PixelSample = struct {
    x: usize,
    y: usize,
    expected: [4]u8,
};

pub const RunFrameOptions = struct {
    keyinput_script: ?[]const u8 = null,
};

pub const sbb_reg_samples = [_]PixelSample{
    .{ .x = 0, .y = 0, .expected = .{ 255, 0, 0, 255 } },
    .{ .x = 120, .y = 80, .expected = .{ 0, 0, 0, 255 } },
    .{ .x = 123, .y = 83, .expected = .{ 255, 0, 0, 255 } },
};
```

```zig
fn buildFixtureNative(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rom_path: []const u8,
    output_name: []const u8,
    output_mode: cli_parse.OutputMode,
    max_instructions: u64,
) ![]u8 {
    const native_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ".zig-cache/tonc", output_name });
    errdefer allocator.free(native_path);
    var discard = std.io.Writer.Allocating.init(allocator);
    defer discard.deinit();
    try run(io, allocator, dir, &discard.writer, .{
        .rom_path = rom_path,
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_path = native_path,
        .output_mode = output_mode,
        .max_instructions = max_instructions,
        .optimize = .release,
    });
    return native_path;
}

fn runFrameFixture(
    io: std.Io,
    dir: std.Io.Dir,
    native_path: []const u8,
    frame_name: []const u8,
    options: RunFrameOptions,
) !void {
    var environ_map = std.process.EnvMap.init(std.testing.allocator);
    defer environ_map.deinit();

    try environ_map.put("HOMONCULI_OUTPUT_MODE", "frame_raw");
    try environ_map.put("HOMONCULI_OUTPUT_PATH", frame_name);
    try environ_map.put("HOMONCULI_MAX_INSTRUCTIONS", "50000");
    if (options.keyinput_script) |script|
        try environ_map.put("HOMONCULI_KEYINPUT_SCRIPT", script);

    var child = std.process.Child.init(&.{native_path}, std.testing.allocator);
    child.cwd_dir = dir;
    child.env_map = &environ_map;
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, try child.spawnAndWait());
}
```

```zig
test "tonc sbb_reg frame smoke test" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "tests/fixtures/real/tonc/sbb_reg.gba",
        "sbb_reg-native",
        .frame_raw,
        50_000,
    );
    defer std.testing.allocator.free(output_path);

    try runFrameFixture(io, tmp.dir, output_path, "sbb_reg.rgba", .{});
    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "sbb_reg.rgba");
    defer std.testing.allocator.free(frame);

    for (tonc_fixture_support.sbb_reg_samples) |sample|
        try frame_test_support.expectPixel(frame, sample.x, sample.y, sample.expected);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
zig test src/gba_ppu.zig --test-filter "mode0"
zig test src/build_cmd.zig --test-filter "tonc sbb_reg frame smoke test"
```

Expected: FAIL because `frame_raw` still rejects Mode 0 and there is no regular BG renderer yet.

- [ ] **Step 3: Implement the minimal regular-BG renderer**

```zig
pub fn dumpFrameRgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
) FrameError!void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    switch (dispcnt & 0x7) {
        0 => return dumpMode0Rgba(io, palette, vram, oam, rgba),
        4 => return dumpMode4Rgba(io, palette, vram, rgba),
        else => return error.UnsupportedVideoMode,
    }
}
```

```zig
fn dumpMode0Rgba(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
) FrameError!void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    const bg0_enabled = (dispcnt & 0x0100) != 0;

    fillBackdrop(palette, rgba);
    if (bg0_enabled)
        renderRegularBg0(io, palette, vram, rgba);
    if ((dispcnt & 0x1000) != 0)
        renderObjLayer(io, palette, vram, oam, rgba);
}
```

```zig
fn renderRegularBg0(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
) void {
    const bgcnt = std.mem.readInt(u16, io[8..10], .little);
    const cbb: usize = @intCast((bgcnt >> 2) & 0x3);
    const sbb: usize = @intCast((bgcnt >> 8) & 0x1F);
    const hofs = std.mem.readInt(u16, io[16..18], .little) & 0x1FF;
    const vofs = std.mem.readInt(u16, io[18..20], .little) & 0x1FF;

    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            const bg_x = (x + hofs) & 0x1FF;
            const bg_y = (y + vofs) & 0x1FF;
            const tile_x = bg_x >> 3;
            const tile_y = bg_y >> 3;
            const entry_offset = ((tile_y & 31) * 32) + (tile_x & 31);
            const entry_addr = (sbb * 0x800) + entry_offset * 2;
            const entry = std.mem.readInt(u16, vram[entry_addr..][0..2], .little);
            const tile_id = entry & 0x03FF;
            const palbank = (entry >> 12) & 0xF;
            const color_index = tilePixel4bpp(vram, cbb, tile_id, bg_x & 7, bg_y & 7);
            if (color_index == 0) continue;
            writePaletteColor(rgba, palette, x, y, palbank * 16 + color_index);
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify `sbb_reg` is green**

Run:

```bash
zig test src/gba_ppu.zig --test-filter "mode0"
zig test src/build_cmd.zig --test-filter "tonc sbb_reg frame smoke test"
zig build test --summary all
```

Expected: PASS. `sbb_reg` now produces a deterministic frame dump and the smoke assertions pass.

- [ ] **Step 5: Commit**

```bash
git add src/gba_ppu.zig src/build_cmd.zig src/tonc_fixture_support.zig src/frame_test_support.zig
git commit -m "feat(tonc): make sbb_reg pass"
```

### Task 5: Make `obj_demo` Render A Regular 4bpp Sprite

**Files:**
- Modify: `src/gba_ppu.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/tonc_fixture_support.zig`
- Modify: `src/frame_test_support.zig`
- Test: `src/gba_ppu.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Write the failing `obj_demo` smoke tests**

```zig
pub const obj_demo_samples = [_]PixelSample{
    .{ .x = 20, .y = 20, .expected = .{ 0, 0, 0, 255 } },
    .{ .x = 123, .y = 40, .expected = .{ 0, 66, 0, 255 } },
};
```

```zig
test "tonc obj_demo frame smoke test" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "tests/fixtures/real/tonc/obj_demo.gba",
        "obj_demo-native",
        .frame_raw,
        50_000,
    );
    defer std.testing.allocator.free(output_path);

    try runFrameFixture(io, tmp.dir, output_path, "obj_demo.rgba", .{});
    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "obj_demo.rgba");
    defer std.testing.allocator.free(frame);

    for (tonc_fixture_support.obj_demo_samples) |sample|
        try frame_test_support.expectPixel(frame, sample.x, sample.y, sample.expected);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
zig test src/gba_ppu.zig --test-filter "obj"
zig test src/build_cmd.zig --test-filter "tonc obj_demo frame smoke test"
```

Expected: FAIL because the Mode 0 path does not yet composite OBJ data.

- [ ] **Step 3: Implement the minimal OBJ renderer**

```zig
fn renderObjLayer(
    io: *const [1024]u8,
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    oam: *const [1024]u8,
    rgba: *[rgba_len]u8,
) void {
    const dispcnt = std.mem.readInt(u16, io[0..2], .little);
    const obj_1d = (dispcnt & 0x0040) != 0;
    if (!obj_1d) return;

    for (0..128) |obj_index| {
        const attr_offset = obj_index * 8;
        const attr0 = std.mem.readInt(u16, oam[attr_offset..][0..2], .little);
        const attr1 = std.mem.readInt(u16, oam[attr_offset + 2 ..][0..2], .little);
        const attr2 = std.mem.readInt(u16, oam[attr_offset + 4 ..][0..2], .little);

        if (((attr0 >> 8) & 0x3) != 0) continue; // regular only
        if ((attr0 & 0x0200) != 0) continue; // affine disabled in this slice

        renderRegular4bppObj(palette, vram, rgba, attr0, attr1, attr2);
    }
}
```

```zig
fn renderRegular4bppObj(
    palette: *const [1024]u8,
    vram: *const [98304]u8,
    rgba: *[rgba_len]u8,
    attr0: u16,
    attr1: u16,
    attr2: u16,
) void {
    const x: i32 = @intCast(attr1 & 0x1FF);
    const y: i32 = @intCast(attr0 & 0x00FF);
    const tile_id: usize = @intCast(attr2 & 0x03FF);
    const palbank: usize = @intCast((attr2 >> 12) & 0xF);

    for (0..64) |py| {
        for (0..64) |px| {
            const screen_x = x + @as(i32, @intCast(px));
            const screen_y = y + @as(i32, @intCast(py));
            if (screen_x < 0 or screen_x >= frame_width or screen_y < 0 or screen_y >= frame_height) continue;

            const color_index = objTilePixel4bpp(vram, tile_id, px, py);
            if (color_index == 0) continue;
            writeObjPaletteColor(rgba, palette, @intCast(screen_x), @intCast(screen_y), palbank * 16 + color_index);
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify `obj_demo` is green**

Run:

```bash
zig test src/gba_ppu.zig --test-filter "obj"
zig test src/build_cmd.zig --test-filter "tonc obj_demo frame smoke test"
zig build test --summary all
```

Expected: PASS. `obj_demo` now renders a sprite over the backdrop with the expected smoke pixels.

- [ ] **Step 5: Commit**

```bash
git add src/gba_ppu.zig src/build_cmd.zig src/tonc_fixture_support.zig src/frame_test_support.zig
git commit -m "feat(tonc): make obj_demo pass"
```

### Task 6: Make `key_demo` React To Deterministic Held Input

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `src/tonc_fixture_support.zig`
- Modify: `tests/fixtures/real/tonc/INGESTION.md`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Write the failing `key_demo` smoke tests**

```zig
pub const key_demo_hold_a_script =
    "03fe,03fe,03fe,03fe,03fe,03fe,03fe,03fe,"
    "03fe,03fe,03fe,03fe,03fe,03fe,03fe,03fe";

pub const key_demo_samples = [_]PixelSample{
    .{ .x = 201, .y = 62, .expected = .{ 0, 255, 0, 255 } },
    .{ .x = 184, .y = 68, .expected = .{ 222, 222, 239, 255 } },
};
```

```zig
test "tonc key_demo frame smoke test" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "tests/fixtures/real/tonc/key_demo.gba",
        "key_demo-native",
        .frame_raw,
        50_000,
    );
    defer std.testing.allocator.free(output_path);

    try runFrameFixture(io, tmp.dir, output_path, "key_demo.rgba", .{
        .keyinput_script = tonc_fixture_support.key_demo_hold_a_script,
    });

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "key_demo.rgba");
    defer std.testing.allocator.free(frame);

    for (tonc_fixture_support.key_demo_samples) |sample|
        try frame_test_support.expectPixel(frame, sample.x, sample.y, sample.expected);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig test src/build_cmd.zig --test-filter "tonc key_demo frame smoke test"`
Expected: FAIL because `runFrameFixture` does not yet thread `HOMONCULI_KEYINPUT_SCRIPT`, or the runtime does not yet keep the scripted held input visible at cap-time.

- [ ] **Step 3: Implement the minimal held-input smoke path**

```zig
if (options.keyinput_script) |script|
    try environ_map.put("HOMONCULI_KEYINPUT_SCRIPT", script);
```

- [ ] **Step 4: Run the tests to verify `key_demo` is green**

Run:

```bash
zig test src/build_cmd.zig --test-filter "tonc key_demo frame smoke test"
zig build test --summary all
```

Expected: PASS. `key_demo` now responds to a deterministic held-A script and the smoke pixels reflect one held key plus untouched keys.

- [ ] **Step 5: Commit**

```bash
git add src/build_cmd.zig src/tonc_fixture_support.zig tests/fixtures/real/tonc/INGESTION.md
git commit -m "feat(tonc): make key_demo pass"
```

### Task 7: Record The `irq_demo` Deferral And Stop Cleanly

**Files:**
- Modify: `tests/fixtures/real/tonc/INGESTION.md`
- Modify: `README.md`
- Test: none

- [ ] **Step 1: Write the failing documentation assertion as a review checklist**

```markdown
## Deferred Fixture

- `irq_demo`: deferred until a dedicated interrupt milestone.
- Required missing scope:
  - HBlank interrupts
  - VCount interrupts
  - nested interrupt enable/disable behavior
  - interrupt-priority switching
```

- [ ] **Step 2: Verify the docs do not yet reflect the explicit deferral**

Run:

```bash
rg -n "irq_demo|deferred until a dedicated interrupt milestone" tests/fixtures/real/tonc/INGESTION.md README.md
```

Expected: either no match or incomplete wording.

- [ ] **Step 3: Record the final bring-up boundary**

```markdown
## Deferred Fixture

- `irq_demo`: deferred until the dedicated interrupt milestone.
- Reason: upstream `ext/irq_demo` requires HBlank and VCount sources, nested interrupt enabling, and priority switching, all of which are outside the approved VBlank-only interrupt model for tonc bring-up.
```

```markdown
Current graphics/input bring-up target: pinned `tonc` demos `sbb_reg`, `obj_demo`, and `key_demo`. `irq_demo` is intentionally deferred to the future interrupt milestone rather than widened into this bring-up pass.
```

- [ ] **Step 4: Verify the docs and final bring-up state**

Run:

```bash
zig build test --summary all
rg -n "irq_demo|dedicated interrupt milestone" tests/fixtures/real/tonc/INGESTION.md README.md
```

Expected:
- test suite PASS
- both docs mention the explicit `irq_demo` deferral

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/real/tonc/INGESTION.md README.md
git commit -m "docs(tonc): defer irq_demo beyond bringup milestone"
```

## Self-Review Checklist

- Spec coverage:
  - fixture ingestion: Task 1
  - shared prerequisite discovery and measured progression: Tasks 2 and 3
  - `sbb_reg`, `obj_demo`, `key_demo` bring-up: Tasks 4, 5, and 6
  - explicit `irq_demo` deferral: Task 7
  - parity: intentionally excluded from this plan and deferred to a follow-up plan once the bring-up milestone is green
- Placeholder scan:
  - no `TODO` or `TBD`
  - all commands are concrete
  - all expected fixture hashes, sizes, and source/toolchain pins are concrete
- Type consistency:
  - shared fixture metadata lives in `src/tonc_fixture_support.zig`
  - build-time smoke orchestration stays in `src/build_cmd.zig`
  - runtime helper exports stay in `src/gba_ppu.zig`

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-22-tonc-demo-ladder-bringup.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
