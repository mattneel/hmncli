# Kirby `CpuSet` First Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear Kirby's current `SWI 0x0B` / `CpuSet` blocker with a public synthetic proof, then re-probe the local-only ROM and record the next measured blocker.

**Architecture:** Keep this slice narrow. Add the GBA `CpuSet` shim declaration, map `SWI 0x0B` to a new `shim_gba_CpuSet` in the existing LLVM runtime emitter, and prove semantics with synthetic ROMs in the public test suite. Finish with a local-only Kirby re-probe and a spec update; do not attempt title-screen parity, `CpuFastSet`, or decompression in this slice.

**Tech Stack:** Zig `0.17.0-dev.56+a8226cd53`, existing GBA shim declaration catalog, LLVM IR emission in `src/llvm_codegen.zig`, public synthetic ROM tests in `src/build_cmd.zig`, local-only Kirby probes under `.zig-cache/local-commercial-roms/`.

---

## Scope Check

This plan covers only the first Kirby bring-up slice from [2026-04-23-kirby-title-screen-bios-shim-design.md](/home/autark/src/hmncli/docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md).

It deliberately does **not** cover:

- `CpuFastSet`
- BIOS decompression shims
- Kirby title-screen parity
- committed commercial ROM artifacts or goldens
- Advance Wars work in parallel
- Emerald loader-limit work in parallel
- generic BIOS completion beyond `CpuSet`

## File Structure

**Files:**
- Modify: `src/machines/gba.zig`
- Modify: `src/cli/doc.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md`

**Responsibilities:**
- `src/machines/gba.zig`: declare the `CpuSet` shim in the public GBA shim catalog using `guest_ptr` arguments and a memory-writing effect.
- `src/cli/doc.zig`: prove the declaration is discoverable through the deterministic doc surface.
- `src/build_cmd.zig`: map `SWI 0x0B` to `CpuSet`, add synthetic ROM writers, add build/run tests for copy, fill, and unsupported-control failure, and document the exact local-only Kirby re-probe commands.
- `src/llvm_codegen.zig`: emit `shim_gba_CpuSet`, wire SWI lowering to it, and add the LLVM emission checkpoint.
- `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md`: record the post-`CpuSet` re-probe, the next blocker, and the local-only performance note outcome.

## Measured Starting Point

Current local-only Kirby frontier:

- ROM path: `.zig-cache/local-commercial-roms/kirby-nightmare.gba`
- current first blocker: `Unsupported SWI 0x00000B at 0x080CFA58 for gba`
- supported GBA SWIs today: `SoftReset`, `VBlankIntrWait`, `Div`, `Sqrt`

Useful local commands for the engineer before coding:

```bash
arm-none-eabi-objdump -b binary -m armv4t -M force-thumb -D \
  --adjust-vma=0x08000000 \
  .zig-cache/local-commercial-roms/kirby-nightmare.gba \
  | rg -n "svc\\s+11|svc\\s+0xb" | sed -n '1,20p'

arm-none-eabi-objdump -b binary -m armv4t -M force-thumb -D \
  --adjust-vma=0x08000000 \
  --start-address=0x080CFA40 --stop-address=0x080CFA70 \
  .zig-cache/local-commercial-roms/kirby-nightmare.gba
```

Expected:

- the BIOS trampoline block still shows `80cfa58: df0b       svc 11`
- there are many `CpuSet` call sites in the ROM, but this slice only needs to clear the current first blocker and then re-measure

## Scope Guardrails

- Do **not** add Kirby ROMs or Kirby frame artifacts to the canonical test suite.
- Do **not** broaden this slice to `CpuFastSet` or decompression, even if Kirby reaches them next.
- Do **not** invent a new guest-memory API for shims; reuse the existing `hmn_load8/16/32` and `hmn_store8/16/32` helpers already emitted in `src/llvm_codegen.zig`.
- Do **not** refactor shim return-type handling in this slice. Keep `CpuSet` on the existing GBA shim convention: `i32` return type with no meaningful return value.
- The full public regression suite must remain green at every checkpoint. No skips.

### Task 1: Add The Public Red Checkpoints For `CpuSet`

**Files:**
- Modify: `src/cli/doc.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `src/build_cmd.zig`

- [ ] **Step 1: Add a failing doc-render test for the new shim declaration**

```zig
test "doc renders CpuSet shim declaration metadata deterministically" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try render(&output.writer, "shim/gba/CpuSet");

    try std.testing.expectEqualStrings(
        "ID: shim/gba/CpuSet\nState: implemented\nEffects: memory_write\nReference: GBATEK BIOS CpuSet\n",
        output.writer.buffered(),
    );
}
```

- [ ] **Step 2: Add a failing LLVM-emission test for `SWI 0x0B` lowering**

```zig
test "llvm emission lowers gba CpuSet swi to the CpuSet shim call" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .swi = .{ .imm24 = 0x00000B } } },
                },
            },
        },
        .output_mode = .register_r0_decimal,
        .instruction_limit = null,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call i32 @shim_gba_CpuSet(ptr %state)") != null);
}
```

- [ ] **Step 3: Add a failing synthetic build/run test for `CpuSet` copy semantics**

```zig
fn writeCpuSetCopyRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000B, // swi 0x0B (CpuSet)
        0xE5910000, // ldr r0, [r1]
        0xEF000000, // swi 0x00 (SoftReset)
        0x08000020, // source literal
        0x03000000, // dest literal
        0x04000001, // one 32-bit unit, copy mode
        42,         // source word
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

test "build executes CpuSet copy semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetCopyRom(tmp.dir, io, "cpuset-copy.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpuset-copy.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpuset-copy-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpuset-copy-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
```

- [ ] **Step 4: Run the suite to verify the `CpuSet` checkpoints fail red**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "CpuSet"
```

Expected:

- FAIL
- the doc-render test fails because `shim/gba/CpuSet` is not yet declared
- the LLVM-emission or synthetic runtime test fails because `SWI 0x0B` is still unsupported

- [ ] **Step 5: Commit the red checkpoint**

```bash
git add src/cli/doc.zig src/llvm_codegen.zig src/build_cmd.zig
git commit -m "test(kirby): add CpuSet red checkpoint"
```

### Task 2: Declare `CpuSet` And Implement Minimal Runtime Support

**Files:**
- Modify: `src/machines/gba.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`

- [ ] **Step 1: Add the `CpuSet` shim declaration to the GBA machine**

```zig
    .{
        .id = .{
            .kind = .shim,
            .namespace = "gba",
            .name = "CpuSet",
        },
        .state = .implemented,
        .args = &.{
            .{ .name = "source", .ty = .guest_ptr },
            .{ .name = "dest", .ty = .guest_ptr },
            .{ .name = "control", .ty = .u32 },
        },
        .returns = .i32,
        .effects = .memory_write,
        .tests = &.{},
        .doc_refs = &.{
            .{
                .label = "GBATEK BIOS CpuSet",
                .url = "https://problemkaputt.de/gbatek.htm#biosmemorycopy",
            },
        },
        .notes = &.{
            "Commercial BIOS memory-copy shim used first by Kirby; implemented via existing guest-memory load/store helpers.",
        },
    },
```

- [ ] **Step 2: Wire `SWI 0x0B` to `CpuSet` in the build-time SWI resolver**

```zig
fn isCpuSetSwi(imm24: u24) bool {
    return imm24 == 0x00000B or imm24 == 0x0B0000;
}

fn swiShimName(imm24: u24) ?[]const u8 {
    if (imm24 == 0x000000) return "SoftReset";
    if (isVBlankIntrWaitSwi(imm24)) return "VBlankIntrWait";
    if (isDivSwi(imm24)) return "Div";
    if (isSqrtSwi(imm24)) return "Sqrt";
    if (isCpuSetSwi(imm24)) return "CpuSet";
    return null;
}
```

- [ ] **Step 3: Emit the `CpuSet` shim body and lower `SWI 0x0B` to it**

```zig
const cpuset_fill_bit: u32 = 1 << 24;
const cpuset_word_bit: u32 = 1 << 26;
const cpuset_count_mask: u32 = 0x001F_FFFF;
const cpuset_supported_mask: u32 = cpuset_fill_bit | cpuset_word_bit | cpuset_count_mask;

fn emitGbaCpuSetShim(writer: *Io.Writer) Io.Writer.Error! {
    // Mirror the existing GBA shim emitter style:
    // - load r0/r1/r2 from GuestState as source, dest, and control
    // - reject any control bits outside cpuset_supported_mask through
    //   @hmn_cpuset_fail_bad_control
    // - decode count, fill-vs-copy, and halfword-vs-word width
    // - iterate count units using the existing @hmn_load16/@hmn_load32 and
    //   @hmn_store16/@hmn_store32 helpers
    // - in copy mode, advance source and dest each iteration
    // - in fill mode, read the source value once and replicate it across the
    //   destination span
    // - return i32 0 on success, matching the existing GBA shim ABI
}
```

Then wire it into the existing SWI lowering switch:

```zig
        .swi => |swi| {
            const shim_name = switch (swi.imm24) {
                0x000000 => "SoftReset",
                0x000005, 0x050000 => "VBlankIntrWait",
                0x000006, 0x060000 => "Div",
                0x000008, 0x080000 => "Sqrt",
                0x00000B, 0x0B0000 => "CpuSet",
                else => unreachable,
            };
            try writer.print("  call i32 @shim_gba_{s}(ptr %state)\n", .{shim_name});
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
```

- [ ] **Step 4: Run the red checkpoints and full suite to make them go green**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "CpuSet"
timeout 300s zig build test --summary all
```

Expected:

- PASS
- the doc-render, LLVM-emission, and synthetic copy tests are green
- no skipped tests

- [ ] **Step 5: Commit the minimal `CpuSet` implementation**

```bash
git add src/machines/gba.zig src/build_cmd.zig src/llvm_codegen.zig src/cli/doc.zig
git commit -m "feat(kirby): add CpuSet BIOS shim"
```

### Task 3: Lock `CpuSet` Semantics For Fill Mode And Unsupported Control

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`

- [ ] **Step 1: Add a public synthetic test for fill semantics**

```zig
fn writeCpuSetFillRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0014, // ldr r0, [pc, #0x14] ; source
        0xE59F1014, // ldr r1, [pc, #0x14] ; dest
        0xE59F2014, // ldr r2, [pc, #0x14] ; control
        0xEF00000B, // swi 0x0B
        0xE1D100B2, // ldrh r0, [r1, #2]
        0xEF000000, // swi 0x00
        0x08000020, // source literal
        0x03000000, // dest literal
        0x01000002, // two 16-bit units, fill mode
        7,          // source halfword value in low bits
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

test "build executes CpuSet fill semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuSetFillRom(tmp.dir, io, "cpuset-fill.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpuset-fill.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpuset-fill-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpuset-fill-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
```

- [ ] **Step 2: Add a public synthetic test for unsupported control failure**

```zig
test "CpuSet rejects unsupported control bits structurally" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const words = [_]u32{
        0xE59F000C, // ldr r0, [pc, #0x0C]
        0xE59F100C, // ldr r1, [pc, #0x0C]
        0xE59F200C, // ldr r2, [pc, #0x0C]
        0xEF00000B, // swi 0x0B
        0xEF000000, // swi 0x00
        0x08000018,
        0x03000000,
        0x82000001, // reserved upper bit outside the supported CpuSet mask
        1,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "cpuset-bad-control.gba", .data = &rom });

    const native_path = try buildFixtureNativeViaCli(std.testing.allocator, io, &tmp, "cpuset-bad-control.gba", "cpuset-bad-control-native", .retired_count, 500_000);
    defer std.testing.allocator.free(native_path);

    const result = try runNativeCapture(std.testing.allocator, io, tmp.dir, native_path, "retired_count", 500_000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported CpuSet control 0x82000001 for gba") != null);
}
```

- [ ] **Step 3: Add the structured failure helper in the runtime**

```zig
    try writer.print("@.fmt_cpuset_bad_control = private unnamed_addr constant [45 x i8] c\"Unsupported CpuSet control 0x%08x for gba\\0A\\00\", align 1\n", .{});

define void @hmn_cpuset_fail_bad_control(ptr %state, i32 %value) {
entry:
  %cpuset_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {guest_state_stop_flag_field}
  call i32 (ptr, ...) @printf(ptr @.fmt_cpuset_bad_control, i32 %value)
  store i1 true, ptr %cpuset_stop_flag_ptr, align 1
  ret void
}
```

- [ ] **Step 4: Run the new `CpuSet` semantic and boundary tests**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "CpuSet"
timeout 300s zig build test --summary all
```

Expected:

- PASS
- the fill test is green
- the unsupported-control test is green
- the earlier copy/emission/doc checkpoints remain green

- [ ] **Step 5: Commit the semantic boundary lock**

```bash
git add src/build_cmd.zig src/llvm_codegen.zig
git commit -m "test(kirby): lock CpuSet boundary"
```

### Task 4: Re-Probe Kirby And Update The Kirby Spec

**Files:**
- Modify: `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md`

- [ ] **Step 1: Re-run the local-only Kirby probe after `CpuSet` lands**

Run:

```bash
mkdir -p .zig-cache/commercial-probes
zig build run -- build ".zig-cache/local-commercial-roms/kirby-nightmare.gba" \
  --machine gba \
  --target x86_64-linux \
  --output frame_raw \
  --max-instructions 500000 \
  -o ".zig-cache/commercial-probes/kirby-cpuset-native" \
  > ".zig-cache/commercial-probes/kirby-cpuset.stdout" \
  2> ".zig-cache/commercial-probes/kirby-cpuset.stderr" || true

sed -n '1,20p' ".zig-cache/commercial-probes/kirby-cpuset.stdout"
```

Expected:

- the old blocker `Unsupported SWI 0x00000B at 0x080CFA58 for gba` is gone
- one new first meaningful blocker line is visible in `kirby-cpuset.stdout`

- [ ] **Step 2: Attempt the local-only `CpuSet` performance note only if the build emitted a native binary**

Run:

```bash
if [ -x ".zig-cache/commercial-probes/kirby-cpuset-native" ]; then
  /usr/bin/time -f "kirby-cpuset-native %e sec" \
    env HOMONCULI_OUTPUT_MODE=frame_raw \
        HOMONCULI_OUTPUT_PATH=".zig-cache/commercial-probes/kirby-cpuset.rgba" \
        HOMONCULI_MAX_INSTRUCTIONS=500000 \
        ".zig-cache/commercial-probes/kirby-cpuset-native" \
        >/dev/null
else
  printf 'kirby-cpuset-native not emitted; performance note deferred because the next blocker is still build-time\n'
fi
```

Expected:

- either a local wall-clock line for the native run, or the explicit deferred note above
- no published benchmark numbers; this is only enough to decide whether `CpuSet` obviously dominates and whether bitcode/LTO pressure is immediate

- [ ] **Step 3: Update the Kirby spec with the post-`CpuSet` findings**

Append a new `## Post CpuSet Re-Probe` section to `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md` containing:

- one bullet stating the old `SWI 0x0B` blocker is cleared
- one bullet copying the exact new first meaningful blocker line from `.zig-cache/commercial-probes/kirby-cpuset.stdout`
- one bullet stating whether the `CpuSet` performance note shows immediate pressure for the deferred bitcode/LTO question, or whether it remains deferred
- one bullet reaffirming that Kirby remains the named commercial target and that the next slice is chosen by the new blocker

- [ ] **Step 4: Re-run the full public suite after the doc update**

Run:

```bash
timeout 300s zig build test --summary all
```

Expected:

- PASS
- no skipped tests

- [ ] **Step 5: Commit the finished `CpuSet` slice**

```bash
git add docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md
git commit -m "docs(kirby): record post-CpuSet frontier"
```

## Self-Review

Spec coverage:

- named commercial target remains Kirby: Task 4
- immediate `CpuSet` blocker is the only implementation target: Tasks 1-3
- declaration-system pressure is covered by the new shim declaration and deterministic doc checkpoint: Tasks 1-2
- guest-memory read/write from a host-side BIOS shim is covered by the synthetic copy/fill runtime tests: Tasks 1-3
- structured failure for unsupported `CpuSet` control is covered by Task 3
- local-only re-probe and performance note are covered by Task 4
- title-screen parity is intentionally not implemented in this plan

Placeholder scan:

- no `TODO`/`TBD` markers
- the public red/green steps use concrete tests, concrete commands, and named files
- the local-only re-probe step names exact paths and exact outputs to record

Type consistency:

- `CpuSet` stays on the existing GBA shim convention: `i32` return and `ptr %state` ABI
- public tests use `SWI 0x0B` consistently in both build-time mapping and LLVM lowering
- the new shim declaration uses the existing `guest_ptr` and `memory_write` declaration types instead of inventing new ones
