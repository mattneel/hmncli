# Commercial Startup `bx r1` Shared Prerequisite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support the measured ARM startup `bx r1` handoff pattern shared by Advance Wars and Kirby, then re-probe both local-only commercial candidates and choose the first named commercial stopping rule.

**Architecture:** Keep the change entirely inside the build-time control-flow resolver in `src/build_cmd.zig`. Add one exact synthetic red test for the ARM `ldr r1, [pc, ...]` -> `mov lr, pc` -> `bx r1` startup shape, implement a narrow resolver that accepts only the measured odd Thumb literal-target form, then harden the boundary with near-miss tests and re-probe the two local commercial ROMs before updating the spec.

**Tech Stack:** Zig `0.17.0-dev.56+a8226cd53`, existing Capstone-backed ARM/Thumb decode, `zig build test --summary all`, local-only commercial ROM probes under `.zig-cache/local-commercial-roms/`.

---

## Scope Check

This plan covers only the shared prerequisite slice from [2026-04-23-first-commercial-title-ingestion-design.md](/home/autark/src/hmncli/docs/superpowers/specs/2026-04-23-first-commercial-title-ingestion-design.md).

It deliberately does **not** cover:

- named-title bring-up for Advance Wars or Kirby
- Emerald's 16 MiB loader limit
- generic ARM indirect-branch support
- README or quickstart updates
- committed commercial ROM fixtures
- Fire Red or Emerald planning

## File Structure

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `docs/superpowers/specs/2026-04-23-first-commercial-title-ingestion-design.md`

**Responsibilities:**
- `src/build_cmd.zig`: exact red test fixtures, narrow ARM startup `bx r1` resolver, boundary tests, and local re-probe verification commands.
- `docs/superpowers/specs/2026-04-23-first-commercial-title-ingestion-design.md`: living record of the commercial probe findings before and after the shared prerequisite slice, plus the first named-title selection decision.

## Measured Starting Point

Local-only ROM preparation used during the spec probe:

```bash
mkdir -p .zig-cache/local-commercial-roms
unzip -p '/mnt/c/Users/requi/Downloads/Advance Wars.zip' \
  'Advance Wars (USA) (Rev 1).gba' \
  > '.zig-cache/local-commercial-roms/advance-wars.gba'
unzip -p '/mnt/c/Users/requi/Downloads/Kirby_ Nightmare in Dream Land.zip' \
  'Kirby - Nightmare in Dream Land (USA).gba' \
  > '.zig-cache/local-commercial-roms/kirby-nightmare.gba'
unzip -p '/mnt/c/Users/requi/Downloads/Pokemon - Emerald Version (USA, Europe).zip' \
  'Pokemon - Emerald Version (USA, Europe).gba' \
  > '.zig-cache/local-commercial-roms/pokemon-emerald.gba'
```

Current measured blockers:

- Advance Wars: `Unsupported opcode 0xE12FFF11 at 0x080000E0 for armv4t`
- Kirby: `Unsupported opcode 0xE12FFF11 at 0x080000EC for armv4t`
- Emerald: loader `StreamTooLong` at exact 16 MiB

Startup disassembly already verified that:

- Advance Wars loads `r1` from a PC-relative literal containing `0x0807AD11`, then executes `mov lr, pc; bx r1`
- Kirby does the same at `0x080000EC` with literal `0x08000311`, then repeats the same startup family at `0x080000F8` with literal `0x08007301`

## Scope Guardrails

- Do not widen `resolvePreviousRegisterValue()` to generic ARM literal loads. The new support must stay as an exact startup-pattern carve-out.
- Do not touch `src/gba_loader.zig` in this slice. Emerald stays deferred.
- Do not add local-only commercial tests to the canonical suite. Re-probes are explicit post-implementation commands, not CI fixtures.
- The full standing regression suite must remain green at every checkpoint. No skipped tests.

### Task 1: Add The Exact Red Checkpoint For The Shared ARM Startup Shape

**Files:**
- Modify: `src/build_cmd.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Add a tiny ARM ROM writer for the measured startup `bx r1` literal pattern**

```zig
fn writeArmStartupBxR1LiteralRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    load_word: u32,
    literal: u32,
    thumb_halfword: u16,
) !void {
    var rom: [24]u8 = std.mem.zeroes([24]u8);
    std.mem.writeInt(u32, rom[0..4], load_word, .little);
    std.mem.writeInt(u32, rom[4..8], 0xE1A0E00F, .little); // mov lr, pc
    std.mem.writeInt(u32, rom[8..12], 0xE12FFF11, .little); // bx r1
    std.mem.writeInt(u32, rom[12..16], literal, .little);
    std.mem.writeInt(u16, rom[16..18], thumb_halfword, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}
```

- [ ] **Step 2: Add the positive red test that should resolve the exact commercial startup shape**

```zig
test "arm startup bx r1 literal target resolves the measured commercial handoff shape" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeArmStartupBxR1LiteralRom(
        tmp.dir,
        io,
        "arm-startup-bx-r1.gba",
        0xE59F1004, // ldr r1, [pc, #4]
        0x08000011, // odd Thumb literal target
        0x4770,     // bx lr
    );

    const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", "arm-startup-bx-r1.gba");
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(
        armv4t_decode.DecodedInstruction{ .bx_target = .{
            .address = 0x08000010,
            .isa = .thumb,
        } },
        try resolveBxTarget(image, .{ .address = 0x08000000, .isa = .arm }, 0x08000008, 1),
    );
}
```

- [ ] **Step 3: Run the suite to verify the new test fails red for the right reason**

Run: `timeout 300s zig build test --summary all`

Expected:
- FAIL
- the failing test is `arm startup bx r1 literal target resolves the measured commercial handoff shape`
- the failure is `error.UnsupportedOpcode` or an equivalent mismatch proving the resolver does not yet support the pattern

- [ ] **Step 4: Commit the red checkpoint**

```bash
git add src/build_cmd.zig
git commit -m "test(commercial): add bx-r1 startup red checkpoint"
```

### Task 2: Implement The Narrow ARM Startup `bx r1` Resolver

**Files:**
- Modify: `src/build_cmd.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Add a narrow helper that recognizes only the measured ARM startup handoff family**

```zig
fn resolveMeasuredArmStartupBxR1LiteralTarget(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
) BuildError!?armv4t_decode.CodeAddress {
    if (function_entry.isa != .arm) return null;
    if (address < image.base_address or address > image.base_address + 0x200) return null;

    const mov_lr_pc_insn = try previousInstruction(image, .arm, address);
    const mov_lr_pc = switch (mov_lr_pc_insn.instruction) {
        .mov_reg => |mov| mov,
        else => return null,
    };
    if (mov_lr_pc.rd != 14 or mov_lr_pc.rm != 15) return null;

    const ldr_r1_insn = try previousInstruction(image, .arm, mov_lr_pc_insn.address);
    const ldr_r1 = switch (ldr_r1_insn.instruction) {
        .ldr_word_imm => |load| load,
        else => return null,
    };
    if (ldr_r1.rd != 1 or ldr_r1.base != 15) return null;

    const literal_address = pcValueForInstruction(.arm, ldr_r1_insn.address) + ldr_r1.offset;
    const literal_offset = romOffsetForAddress(image, literal_address, .arm) orelse return null;
    if (literal_offset + 4 > image.bytes.len) return null;

    const raw_target = armv4t_decode.readWord(image.bytes, literal_offset);
    const code_target = normalizeCodeTarget(raw_target);
    if (code_target.isa != .thumb) return null;
    if (offsetForAddress(image, code_target.address, code_target.isa) == null) return null;
    return code_target;
}
```

- [ ] **Step 2: Wire the helper into `resolveBxTarget()` before the generic previous-register fallback**

```zig
fn resolveBxTarget(
    image: gba_loader.RomImage,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    reg: u4,
) BuildError!armv4t_decode.DecodedInstruction {
    if (isExactThumbSavedLrInterworkingReturnEpilogue(image, function_entry, address, reg)) {
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

- [ ] **Step 3: Run the suite to verify the red checkpoint goes green without regressions**

Run: `timeout 300s zig build test --summary all`

Expected:
- PASS
- no skipped tests
- the new `arm startup bx r1 literal target resolves the measured commercial handoff shape` test is green

- [ ] **Step 4: Commit the minimal implementation**

```bash
git add src/build_cmd.zig
git commit -m "feat(commercial): resolve measured arm bx-r1 startup handoff"
```

### Task 3: Lock The Resolver Boundary With Near-Miss Tests

**Files:**
- Modify: `src/build_cmd.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Add near-miss tests that prove the new helper stayed narrow**

```zig
test "arm startup bx r1 literal resolver rejects near-miss shapes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct {
        name: []const u8,
        load_word: u32,
        middle_word: u32,
        literal: u32,
    }{
        .{
            .name = "even-target",
            .load_word = 0xE59F1004,
            .middle_word = 0xE1A0E00F,
            .literal = 0x08000010,
        },
        .{
            .name = "missing-mov-lr-pc",
            .load_word = 0xE59F1004,
            .middle_word = 0xE1A00000,
            .literal = 0x08000011,
        },
        .{
            .name = "non-pc-load-base",
            .load_word = 0xE5911004,
            .middle_word = 0xE1A0E00F,
            .literal = 0x08000011,
        },
    };

    for (cases) |case| {
        var rom: [24]u8 = std.mem.zeroes([24]u8);
        std.mem.writeInt(u32, rom[0..4], case.load_word, .little);
        std.mem.writeInt(u32, rom[4..8], case.middle_word, .little);
        std.mem.writeInt(u32, rom[8..12], 0xE12FFF11, .little);
        std.mem.writeInt(u32, rom[12..16], case.literal, .little);
        std.mem.writeInt(u16, rom[16..18], 0x4770, .little);

        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}.gba", .{case.name});
        defer std.testing.allocator.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = &rom });

        const image = try gba_loader.loadFile(io, std.testing.allocator, tmp.dir, "gba", path);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectError(
            error.UnsupportedOpcode,
            resolveBxTarget(image, .{ .address = 0x08000000, .isa = .arm }, 0x08000008, 1),
        );
    }
}
```

- [ ] **Step 2: Re-run the suite and confirm the boundary tests stay green**

Run: `timeout 300s zig build test --summary all`

Expected:
- PASS
- no skipped tests
- the near-miss test passes without changing any prior green result

- [ ] **Step 3: Commit the boundary lock**

```bash
git add src/build_cmd.zig
git commit -m "test(commercial): lock bx-r1 startup boundary"
```

### Task 4: Re-Probe Advance Wars And Kirby, Then Update The Spec

**Files:**
- Modify: `docs/superpowers/specs/2026-04-23-first-commercial-title-ingestion-design.md`

- [ ] **Step 1: Re-run the local-only commercial probes after the resolver lands**

Run:

```bash
for rom in advance-wars kirby-nightmare; do
  zig build run -- build ".zig-cache/local-commercial-roms/${rom}.gba" \
    --machine gba \
    --target x86_64-linux \
    --output frame_raw \
    --max-instructions 500000 \
    -o ".zig-cache/commercial-probes/${rom}-native" \
    > ".zig-cache/commercial-probes/${rom}.stdout" \
    2> ".zig-cache/commercial-probes/${rom}.stderr" || true
  printf '\n== %s ==\n' "$rom"
  sed -n '1,10p' ".zig-cache/commercial-probes/${rom}.stdout"
done
```

Expected:
- neither title reports `Unsupported opcode 0xE12FFF11` at its old startup address
- each title surfaces a new first blocker, or one title proceeds materially further than the other

- [ ] **Step 2: Update the commercial-title spec with the post-slice findings and the first named-title decision**

Edit `docs/superpowers/specs/2026-04-23-first-commercial-title-ingestion-design.md` and append a new `## Post Shared-Prerequisite Re-Probe` section containing:

- one bullet stating the Advance Wars old blocker is cleared
- one bullet stating the Kirby old blocker is cleared
- one bullet copying the exact first meaningful blocker line from `.zig-cache/commercial-probes/advance-wars.stdout`
- one bullet copying the exact first meaningful blocker line from `.zig-cache/commercial-probes/kirby-nightmare.stdout`
- one bullet naming the first commercial stopping rule chosen after comparing those two new blockers
- one bullet justifying the choice, using Advance Wars as the tie-breaker only if the next-blocker surface is genuinely comparable

- [ ] **Step 3: Run the full suite one last time after the doc update**

Run: `timeout 300s zig build test --summary all`

Expected:
- PASS
- no skipped tests

- [ ] **Step 4: Commit the finished slice**

```bash
git add docs/superpowers/specs/2026-04-23-first-commercial-title-ingestion-design.md
git commit -m "docs(commercial): record post-bx-r1 title frontiers"
```

## Self-Review

Spec coverage:

- shared ARM startup prerequisite is covered by Tasks 1-3
- named-title selection after the shared slice is covered by Task 4
- Emerald staying separate is enforced by the scope guardrails and the absence of `src/gba_loader.zig` changes
- local-only ROM policy is respected because there are no committed commercial fixtures or CI-skipped ROM tests in this plan

Placeholder scan:

- the post-slice documentation step now tells the engineer exactly which measured lines to copy from the probe output instead of leaving template placeholders in the plan
- no implementation step depends on an unnamed function or file outside this plan

Type consistency:

- all new resolver work stays in `src/build_cmd.zig`
- the test helper and resolver names are introduced before later tasks reference them
- the plan keeps the change set to one code file plus one spec file
