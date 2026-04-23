# Shared Commercial `pop {r0}; bx r0` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear the exact measured shared Thumb `pop {r0}; bx r0` blocker in Advance Wars and Kirby, then re-probe both titles and record the next measured frontier.

**Architecture:** Keep this slice entirely inside the existing build-time control-flow resolver in `src/build_cmd.zig`. Recognize only the exact Thumb function shape measured in both commercial ROMs: entry `push {lr}` paired with terminal `pop {r0}; bx r0`, and lower it through the existing `thumb_saved_lr_return` path instead of adding generic `bx r0` or generic epilogue modeling.

**Tech Stack:** Zig `0.17.0-dev.56+a8226cd53`, existing ARMv4T decode and resolver pipeline in `src/build_cmd.zig`, public synthetic resolver tests in the same file, local-only commercial ROM probes under `.zig-cache/local-commercial-roms/`.

---

## Scope Check

This plan implements only the shared prerequisite from [2026-04-23-shared-thumb-pop-r0-bx-r0-design.md](/home/autark/src/hmncli/docs/superpowers/specs/2026-04-23-shared-thumb-pop-r0-bx-r0-design.md).

It deliberately does **not** cover:

- generic Thumb `bx r0`
- generic `pop {rx}; bx rx`
- generic Thumb return or epilogue modeling
- Kirby title-screen bring-up or parity
- Advance Wars bring-up beyond clearing this exact blocker
- LLVM/runtime changes outside the existing `thumb_saved_lr_return` lowering path
- commercial ROM fixtures or commercial frame artifacts in the public suite

## File Structure

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `docs/superpowers/specs/2026-04-23-shared-thumb-pop-r0-bx-r0-design.md`

**Responsibilities:**
- `src/build_cmd.zig`: add the exact synthetic red/green checkpoints, implement the narrow measured matcher, and lock the boundary with near-miss rejections.
- `docs/superpowers/specs/2026-04-23-shared-thumb-pop-r0-bx-r0-design.md`: record the post-slice local re-probes for Advance Wars and Kirby, then state whether the next slice stays shared or returns to Kirby-specific work.

## Measured Starting Point

Current local-only commercial frontier:

- Advance Wars: `Unsupported opcode 0x00004700 at 0x0803885E for armv4t`
- Kirby: `Unsupported opcode 0x00004700 at 0x08001A2E for armv4t`

Measured surrounding disassembly:

- Advance Wars:
  - `0x08038848: b500       push {lr}`
  - `0x0803885C: bc01       pop  {r0}`
  - `0x0803885E: 4700       bx   r0`
- Kirby:
  - `0x08001A0C: b500       push {lr}`
  - `0x08001A2C: bc01       pop  {r0}`
  - `0x08001A2E: 4700       bx   r0`

Useful local commands for the engineer before coding:

```bash
arm-none-eabi-objdump -b binary -m armv4t -M force-thumb -D \
  --adjust-vma=0x08000000 \
  --start-address=0x08038848 --stop-address=0x08038860 \
  .zig-cache/local-commercial-roms/advance-wars.gba

arm-none-eabi-objdump -b binary -m armv4t -M force-thumb -D \
  --adjust-vma=0x08000000 \
  --start-address=0x08001A0C --stop-address=0x08001A30 \
  .zig-cache/local-commercial-roms/kirby-nightmare.gba
```

Expected:

- both sites show `push {lr}` at the measured function entry
- both sites end in the exact `pop {r0}; bx r0` tail
- the old shared `0x00004700` blocker is still the first build-time failure before this slice lands

## Scope Guardrails

- Do **not** broaden this slice to `pop {rx}; bx rx`.
- Do **not** treat arbitrary `push {lr}` / `bx r0` combinations as equivalent; require the measured `pop {r0}; bx r0` adjacency.
- Do **not** modify `src/llvm_codegen.zig`; the point of this slice is to reuse the existing `thumb_saved_lr_return` lowering once the exact shape is recognized.
- Do **not** add public tests that depend on local commercial ROMs.
- Do **not** update the Kirby-specific spec in this slice; record the next decision in the shared slice spec first.
- The full public suite must stay green throughout. No skips.

### Task 1: Add The Exact Public Red Checkpoint

**Files:**
- Modify: `src/build_cmd.zig`

- [ ] **Step 1: Add a synthetic ROM writer for the measured `push {lr} ... pop {r0}; bx r0` shape**

```zig
fn writeMeasuredThumbPopR0BxR0Rom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    body: []const u16,
) !void {
    const rom_len = 2 + body.len * 2 + 4;
    const rom = try std.testing.allocator.alloc(u8, rom_len);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);

    std.mem.writeInt(u16, rom[0..2], 0xB500, .little); // push {lr}
    for (body, 0..) |halfword, index| {
        const start = 2 + index * 2;
        std.mem.writeInt(u16, rom[start..][0..2], halfword, .little);
    }
    std.mem.writeInt(u16, rom[rom_len - 4 ..][0..2], 0xBC01, .little); // pop {r0}
    std.mem.writeInt(u16, rom[rom_len - 2 ..][0..2], 0x4700, .little); // bx r0
    try dir.writeFile(io, .{ .sub_path = path, .data = rom });
}
```

- [ ] **Step 2: Add the failing exact matcher test**

```zig
test "thumb push-lr pop-r0 bx-r0 resolves the measured commercial return shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        path: []const u8,
        body: []const u16,
    }{
        .{
            .path = "advance-wars-pop-r0-bx-r0.gba",
            .body = &.{ 0x2000, 0x2001, 0x1C08 }, // harmless Thumb body
        },
        .{
            .path = "kirby-pop-r0-bx-r0.gba",
            .body = &.{ 0x2000, 0x3008, 0x2800, 0xD1FC, 0x2001 },
        },
    };

    for (cases) |case| {
        try writeMeasuredThumbPopR0BxR0Rom(tmp.dir, io, case.path, case.body);

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", case.path);
        defer image.deinit(std.testing.allocator);
        const bx_address = 0x0800_0000 + 2 + @as(u32, @intCast(case.body.len * 2)) + 2;

        try std.testing.expectEqualDeep(
            armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} },
            try resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, bx_address, 0),
        );
    }
}
```

- [ ] **Step 3: Run the new test to verify it fails red**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "thumb push-lr pop-r0 bx-r0 resolves the measured commercial return shape"
```

Expected:

- FAIL
- the test fails with `error.UnsupportedOpcode` through the current generic `resolvePreviousRegisterValue(...)` fallback

- [ ] **Step 4: Commit the red checkpoint**

```bash
git add src/build_cmd.zig
git commit -m "test(commercial): add pop-r0 bx-r0 red checkpoint"
```

### Task 2: Implement The Narrow Exact Matcher

**Files:**
- Modify: `src/build_cmd.zig`

- [ ] **Step 1: Add the exact measured helper and wire it into `resolveBxTarget(...)`**

```zig
fn isExactThumbPushLrPopR0BxR0ReturnEpilogue(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) bool {
    if (function_entry.isa != .thumb) return false;
    if (reg != 0) return false;

    const entry = decodeImageInstructionUnchecked(image, .thumb, function_entry.address) catch return false;
    if (entry.size_bytes != 2) return false;
    const push_mask = switch (entry.instruction) {
        .push => |mask| mask,
        else => return false,
    };
    if (push_mask != 0x4000) return false; // exact measured `push {lr}`

    const previous = previousInstruction(image, .thumb, address) catch return false;
    const pop_mask = switch (previous.instruction) {
        .pop => |mask| mask,
        else => return false,
    };
    if (pop_mask != 0x0001) return false; // exact measured `pop {r0}`

    return true;
}

fn resolveBxTarget(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) BuildError!armv4t_decode.DecodedInstruction {
    if (isExactThumbSavedLrInterworkingReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (isExactThumbPushLrPopR0BxR0ReturnEpilogue(image, function_entry, address, reg)) {
        return .{ .thumb_saved_lr_return = {} };
    }
    if (function_entry.isa == .arm and reg == 1) {
        if (try resolveMeasuredArmStartupBxR1LiteralTarget(image, function_entry, address)) |target| {
            return .{ .bx_target = target };
        }
    }
    if (function_entry.isa == .thumb and reg == 6) {
        const previous = try previousInstruction(image, function_entry.isa, address);
        if (previous.instruction == .bl) {
            return .{ .bx_target = normalizeCodeTarget(try resolveStartupThumbBxR6TargetValue(image, function_entry.isa, address)) };
        }
    }
    return .{ .bx_target = normalizeCodeTarget(try resolvePreviousRegisterValue(image, function_entry.isa, address, reg)) };
}
```

- [ ] **Step 2: Run the focused checkpoint and then the full public suite**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "thumb push-lr pop-r0 bx-r0 resolves the measured commercial return shape"
timeout 300s zig build test --summary all
```

Expected:

- PASS
- the new exact matcher test is green
- the full suite remains green with no skips

- [ ] **Step 3: Commit the exact matcher**

```bash
git add src/build_cmd.zig
git commit -m "feat(commercial): resolve measured pop-r0 bx-r0 returns"
```

### Task 3: Lock The Boundary So The Slice Stays Measured

**Files:**
- Modify: `src/build_cmd.zig`

- [ ] **Step 1: Add near-miss tests that must remain rejected**

```zig
test "thumb push-lr pop-r0 bx-r0 resolver rejects near-miss shapes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        path: []const u8,
        rom_bytes: []const u8,
        bx_address: u32,
        bx_reg: u4,
    }{
        .{
            .path = "missing-push-lr.gba",
            .rom_bytes = &.{ 0x00, 0x20, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0004,
            .bx_reg = 0,
        },
        .{
            .path = "pop-r1-bx-r1.gba",
            .rom_bytes = &.{ 0x00, 0xB5, 0x02, 0xBC, 0x08, 0x47 },
            .bx_address = 0x0800_0004,
            .bx_reg = 1,
        },
        .{
            .path = "push-r4-lr-pop-r0.gba",
            .rom_bytes = &.{ 0x10, 0xB5, 0x01, 0xBC, 0x00, 0x47 },
            .bx_address = 0x0800_0004,
            .bx_reg = 0,
        },
        .{
            .path = "extra-insn-before-bx.gba",
            .rom_bytes = &.{ 0x00, 0xB5, 0x01, 0xBC, 0x00, 0x20, 0x00, 0x47 },
            .bx_address = 0x0800_0006,
            .bx_reg = 0,
        },
    };

    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = case.path, .data = case.rom_bytes });
        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", case.path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectError(
            error.UnsupportedOpcode,
            resolveBxTarget(image, .{ .address = 0x0800_0000, .isa = .thumb }, case.bx_address, case.bx_reg),
        );
    }
}
```

- [ ] **Step 2: Run the focused boundary test and the full public suite**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "thumb push-lr pop-r0 bx-r0 resolver rejects near-miss shapes"
timeout 300s zig build test --summary all
```

Expected:

- PASS
- the measured exact shape still passes
- the near-miss variants still fail closed as `error.UnsupportedOpcode`

- [ ] **Step 3: Commit the boundary lock**

```bash
git add src/build_cmd.zig
git commit -m "test(commercial): lock pop-r0 bx-r0 boundary"
```

### Task 4: Re-Probe Both Commercial Titles And Refresh The Shared Spec

**Files:**
- Modify: `docs/superpowers/specs/2026-04-23-shared-thumb-pop-r0-bx-r0-design.md`

- [ ] **Step 1: Re-run both local-only commercial probes**

Run:

```bash
mkdir -p .zig-cache/commercial-probes

zig build run -- build ".zig-cache/local-commercial-roms/advance-wars.gba" \
  --machine gba \
  --target x86_64-linux \
  --output frame_raw \
  --max-instructions 500000 \
  -o ".zig-cache/commercial-probes/advance-wars-pop-r0-native" \
  > ".zig-cache/commercial-probes/advance-wars-pop-r0.stdout" \
  2> ".zig-cache/commercial-probes/advance-wars-pop-r0.stderr" || true

zig build run -- build ".zig-cache/local-commercial-roms/kirby-nightmare.gba" \
  --machine gba \
  --target x86_64-linux \
  --output frame_raw \
  --max-instructions 500000 \
  -o ".zig-cache/commercial-probes/kirby-pop-r0-native" \
  > ".zig-cache/commercial-probes/kirby-pop-r0.stdout" \
  2> ".zig-cache/commercial-probes/kirby-pop-r0.stderr" || true

sed -n '1,20p' ".zig-cache/commercial-probes/advance-wars-pop-r0.stdout"
sed -n '1,20p' ".zig-cache/commercial-probes/kirby-pop-r0.stdout"
```

Expected:

- the old `Unsupported opcode 0x00004700 ...` line is gone in both probes
- each stdout file now contains one new first meaningful blocker line

- [ ] **Step 2: Update the shared spec with the post-slice frontier**

Append a new `## Post pop {r0}; bx r0 Re-Probe` section to `docs/superpowers/specs/2026-04-23-shared-thumb-pop-r0-bx-r0-design.md` containing:

- one bullet stating that the old shared `0x00004700` blocker is cleared in both Advance Wars and Kirby
- one bullet copying the exact new first meaningful blocker line from `.zig-cache/commercial-probes/advance-wars-pop-r0.stdout`
- one bullet copying the exact new first meaningful blocker line from `.zig-cache/commercial-probes/kirby-pop-r0.stdout`
- one bullet stating the next slice decision: either work returns to Kirby specifically, or another shared prerequisite has appeared

- [ ] **Step 3: Re-run the full public suite after the spec update**

Run:

```bash
timeout 300s zig build test --summary all
```

Expected:

- PASS
- no skipped tests

- [ ] **Step 4: Commit the shared frontier refresh**

```bash
git add docs/superpowers/specs/2026-04-23-shared-thumb-pop-r0-bx-r0-design.md
git commit -m "docs(commercial): refresh shared pop-r0 bx-r0 frontier"
```

## Self-Review

Spec coverage:

- the slice stays shared, not Kirby-only: Tasks 1-4
- the slice is exact measured `pop {r0}; bx r0`, not `pop {rx}; bx rx`: Tasks 1-3
- the resolver remains fail-closed outside the measured shape: Task 3
- no LLVM/runtime broadening happens in this slice: Tasks 2-3 stay entirely in `src/build_cmd.zig`
- both commercial titles are re-probed immediately after the slice: Task 4
- the next slice decision is recorded from measured blockers, not assumed: Task 4

Placeholder scan:

- no `TODO`/`TBD` markers
- every public code change step includes concrete Zig code and concrete commands
- the local-only re-probe step names exact paths, exact commands, and exact outputs to record

Type consistency:

- the new matcher uses `armv4t_decode.CodeAddress`, `gba_loader.RomImage`, and `BuildError` exactly as the current resolver does
- the public tests keep using `resolveBxTarget(...)` and `armv4t_decode.DecodedInstruction{ .thumb_saved_lr_return = {} }`
- the plan reuses the existing `thumb_saved_lr_return` lowering path instead of inventing a new decoded instruction kind
