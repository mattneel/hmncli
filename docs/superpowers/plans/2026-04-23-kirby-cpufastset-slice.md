# Kirby `CpuFastSet` Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clear Kirby's current `SWI 0x0C` / `CpuFastSet` blocker with public synthetic proof, then re-probe the local-only ROM and record the next measured blocker.

**Architecture:** Follow the existing `CpuSet` slice shape. Add a `CpuFastSet` shim declaration, map `SWI 0x0C` to `shim_gba_CpuFastSet`, emit a minimal GBA word-copy/fill runtime shim over existing `hmn_load32` and `hmn_store32`, and keep unsupported control/count cases structurally diagnosed. Finish with a local-only Kirby re-probe and spec update; do not implement decompression, renderer work, or title-screen parity here.

**Tech Stack:** Zig `0.17.0-dev.56+a8226cd53`, existing GBA shim declaration catalog in `src/machines/gba.zig`, LLVM IR emission in `src/llvm_codegen.zig`, public synthetic ROM tests in `src/build_cmd.zig`, local-only Kirby probes under `.zig-cache/local-commercial-roms/`.

---

## Scope Check

This plan is the next measured slice under [2026-04-23-kirby-title-screen-bios-shim-design.md](/home/autark/src/hmncli/docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md) after the shared `pop {r0}; bx r0` prerequisite.

It deliberately does **not** cover:

- `LZ77UnComp*` or other decompression BIOS calls
- title-screen rendering or parity
- generic BIOS completion
- Advance Wars work in parallel
- Emerald or Fire Red work in parallel
- a generic memory-copy abstraction shared with `CpuSet` unless the code-review loop proves duplication is materially hurting the slice
- committed Kirby ROM bytes, frames, or goldens

## File Structure

**Files:**
- Modify: `src/machines/gba.zig`
- Modify: `src/cli/doc.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md`

**Responsibilities:**
- `src/machines/gba.zig`: declare `CpuFastSet` in the public GBA shim catalog.
- `src/cli/doc.zig`: prove the declaration is exposed through the deterministic doc renderer.
- `src/build_cmd.zig`: map `SWI 0x0C` to `CpuFastSet`, add synthetic ROM writers, add build/run tests for copy, fill, alignment, and structured failures, and record local-only Kirby re-probe commands.
- `src/llvm_codegen.zig`: emit `shim_gba_CpuFastSet`, its structural-failure helpers, and SWI lowering for `0x0C`.
- `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md`: record the post-`CpuFastSet` re-probe, the next blocker, and whether performance pressure changes.

## Measured Starting Point

Current local-only Kirby frontier:

- ROM path: `.zig-cache/local-commercial-roms/kirby-nightmare.gba`
- current first blocker: `Unsupported SWI 0x00000C at 0x080CFA54 for gba`
- supported GBA SWIs today: `SoftReset`, `VBlankIntrWait`, `Div`, `Sqrt`, `CpuSet`

Useful local commands before coding:

```bash
arm-none-eabi-objdump -b binary -m armv4t -M force-thumb -D \
  --adjust-vma=0x08000000 \
  --start-address=0x080CFA40 --stop-address=0x080CFA70 \
  .zig-cache/local-commercial-roms/kirby-nightmare.gba

sed -n '1,20p' .zig-cache/commercial-probes/kirby-pop-r0.stdout
```

Expected:

- the BIOS trampoline block contains `0x080CFA54: df0c svc 12`
- the recorded current frontier is exactly `Unsupported SWI 0x00000C at 0x080CFA54 for gba`

## `CpuFastSet` Scope

Minimum GBA `CpuFastSet` semantics for this slice:

- arguments are read from guest registers `r0` source, `r1` destination, and `r2` control
- lower 21 control bits are the 32-bit word count
- bit 24 selects fill mode when set and copy mode when clear
- source and destination are aligned down to 4-byte boundaries
- copy mode copies `count` 32-bit words from source to destination
- fill mode reads one 32-bit word from source and writes it to `count` destination words
- count zero returns immediately
- GBA count must be a multiple of 8 words; non-multiple counts fail structurally for this slice
- any control bits outside bits `0..20` and bit `24` fail structurally for this slice

Structured diagnostics:

- unsupported control bits print `Unsupported CpuFastSet control 0x%08x for gba`
- unsupported non-multiple-of-8 counts print `Unsupported CpuFastSet count 0x%08x for gba`
- both diagnostics set `stop_flag` and return through the same runtime stop path as `CpuSet`

## Scope Guardrails

- Do **not** implement NDS-specific remainder behavior.
- Do **not** silently round non-multiple-of-8 counts.
- Do **not** implement 16-bit `CpuFastSet`; GBA `CpuFastSet` is word-only.
- Do **not** use host memory pointers directly; keep all memory access through `hmn_load32` and `hmn_store32`.
- Do **not** emit commercial ROM-dependent tests.
- Do **not** update the shared `pop {r0}; bx r0` spec in this slice.
- The public suite must stay green at every checkpoint. No skips.

### Task 1: Add The Public Red Checkpoints For `CpuFastSet`

**Files:**
- Modify: `src/cli/doc.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `src/build_cmd.zig`

- [ ] **Step 1: Add a failing doc-render test for `CpuFastSet`**

```zig
test "doc renders CpuFastSet shim declaration metadata deterministically" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try render(&output.writer, "shim/gba/CpuFastSet");

    try std.testing.expectEqualStrings(
        "ID: shim/gba/CpuFastSet\nState: implemented\nEffects: memory_write\nReference: GBATEK BIOS CpuFastSet\n",
        output.writer.buffered(),
    );
}
```

- [ ] **Step 2: Add a failing LLVM-emission test for `SWI 0x0C` lowering**

```zig
test "llvm emission lowers gba CpuFastSet swi to the CpuFastSet shim call" {
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
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .swi = .{ .imm24 = 0x00000C } } },
                },
            },
        },
        .output_mode = .register_r0_decimal,
        .instruction_limit = null,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call i32 @shim_gba_CpuFastSet(ptr %state)") != null);
}
```

- [ ] **Step 3: Add a failing synthetic build/run test for `CpuFastSet` copy semantics**

```zig
fn writeCpuFastSetCopyRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xE591001C, // ldr r0, [r1, #28] ; eighth copied word
        0xE12FFF1E, // bx lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x00000008, // eight 32-bit words, copy mode
        11, 22, 33, 44, 55, 66, 77, 88,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

test "build executes CpuFastSet copy semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetCopyRom(tmp.dir, io, "cpufastset-copy.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cpufastset-copy.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "cpufastset-copy-native",
            .output_mode = .auto,
            .optimize = .release,
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-copy-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("88\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
```

- [ ] **Step 4: Run the `CpuFastSet` checkpoints and verify they fail red**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "CpuFastSet"
```

Expected:

- FAIL
- the doc-render test fails because `shim/gba/CpuFastSet` is not yet declared
- the LLVM-emission or synthetic runtime test fails because `SWI 0x0C` is still unsupported

- [ ] **Step 5: Commit the red checkpoint**

```bash
git add src/cli/doc.zig src/llvm_codegen.zig src/build_cmd.zig
git commit -m "test(kirby): add CpuFastSet red checkpoint"
```

### Task 2: Declare `CpuFastSet` And Implement Minimal Runtime Support

**Files:**
- Modify: `src/machines/gba.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `src/cli/doc.zig`

- [ ] **Step 1: Add the `CpuFastSet` shim declaration to the GBA machine**

```zig
    .{
        .id = .{
            .kind = .shim,
            .namespace = "gba",
            .name = "CpuFastSet",
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
                .label = "GBATEK BIOS CpuFastSet",
                .url = "https://problemkaputt.de/gbatek.htm#biosmemorycopy",
            },
        },
        .notes = &.{
            "Commercial BIOS fast memory-copy shim used by Kirby; word-only GBA subset with count multiple-of-8 enforcement.",
        },
    },
```

- [ ] **Step 2: Wire `SWI 0x0C` to `CpuFastSet` in the build-time resolver**

```zig
fn isCpuFastSetSwi(imm24: u24) bool {
    return imm24 == 0x00000C or imm24 == 0x0C0000;
}

fn swiShimName(imm24: u24) ?[]const u8 {
    if (imm24 == 0x000000) return "SoftReset";
    if (isVBlankIntrWaitSwi(imm24)) return "VBlankIntrWait";
    if (isDivSwi(imm24)) return "Div";
    if (isSqrtSwi(imm24)) return "Sqrt";
    if (isCpuSetSwi(imm24)) return "CpuSet";
    if (isCpuFastSetSwi(imm24)) return "CpuFastSet";
    return null;
}
```

- [ ] **Step 3: Emit `CpuFastSet` diagnostics and shim body**

Add constants next to the existing `cpuset_*` constants:

```zig
const cpufastset_fill_bit: u32 = 1 << 24;
const cpufastset_count_mask: u32 = 0x001F_FFFF;
const cpufastset_supported_mask: u32 = cpufastset_fill_bit | cpufastset_count_mask;
const cpufastset_unsupported_mask: u32 = ~cpufastset_supported_mask;
```

Add format strings to `emitPrelude(...)`:

```zig
try writer.print("@.fmt_cpufastset_bad_control = private unnamed_addr constant [47 x i8] c\"Unsupported CpuFastSet control 0x%08x for gba\\0A\\00\", align 1\n", .{});
try writer.print("@.fmt_cpufastset_bad_count = private unnamed_addr constant [45 x i8] c\"Unsupported CpuFastSet count 0x%08x for gba\\0A\\00\", align 1\n", .{});
```

Add helpers mirroring `emitGbaCpuSetBadControlHelper(...)`:

```zig
fn emitGbaCpuFastSetBadControlHelper(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("define void @hmn_cpufastset_fail_bad_control(ptr %state, i32 %control) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %cpufastset_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_cpufastset_bad_control, i32 %control)\n", .{});
    try writer.print("  store i1 true, ptr %cpufastset_stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitGbaCpuFastSetBadCountHelper(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("define void @hmn_cpufastset_fail_bad_count(ptr %state, i32 %count) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %cpufastset_count_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_cpufastset_bad_count, i32 %count)\n", .{});
    try writer.print("  store i1 true, ptr %cpufastset_count_stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}
```

Emit `define i32 @shim_gba_CpuFastSet(ptr %state)` using the same register-loading pattern as `emitGbaCpuSetShim(...)`. The body must:

```llvm
; pseudo-IR shape to mirror exactly in the Zig writer.print calls
%source = load r0
%dest = load r1
%control = load r2
%bad_bits = and control, cpufastset_unsupported_mask
if bad_bits != 0: call @hmn_cpufastset_fail_bad_control; ret i32 0
%count = and control, cpufastset_count_mask
if count == 0: ret i32 0
%count_remainder = and count, 7
if count_remainder != 0: call @hmn_cpufastset_fail_bad_count; ret i32 0
%aligned_source = and source, -4
%aligned_dest = and dest, -4
%is_fill = (control & cpufastset_fill_bit) != 0
if fill: load one i32 from aligned_source, store it count times to aligned_dest + index * 4
if copy: for index in 0..count, load i32 from aligned_source + index * 4 and store to aligned_dest + index * 4
ret i32 0
```

Then call the new helpers and shim from `emitModule(...)` immediately after the existing `CpuSet` helper/shim emissions.

- [ ] **Step 4: Lower `SWI 0x0C` to the new shim call in LLVM emission**

```zig
        .swi => |swi| {
            const shim_name = switch (swi.imm24) {
                0x000000 => "SoftReset",
                0x000005, 0x050000 => "VBlankIntrWait",
                0x000006, 0x060000 => "Div",
                0x000008, 0x080000 => "Sqrt",
                0x00000B, 0x0B0000 => "CpuSet",
                0x00000C, 0x0C0000 => "CpuFastSet",
                else => unreachable,
            };
            try writer.print("  call i32 @shim_gba_{s}(ptr %state)\n", .{shim_name});
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
```

- [ ] **Step 5: Run focused tests and full suite**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "CpuFastSet"
timeout 300s zig build test --summary all
```

Expected:

- PASS
- doc-render, LLVM-emission, and copy semantics tests are green
- no skipped tests

- [ ] **Step 6: Commit the minimal `CpuFastSet` implementation**

```bash
git add src/machines/gba.zig src/build_cmd.zig src/llvm_codegen.zig src/cli/doc.zig
git commit -m "feat(kirby): add CpuFastSet BIOS shim"
```

### Task 3: Lock `CpuFastSet` Fill, Alignment, And Failure Boundaries

**Files:**
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`

- [ ] **Step 1: Add a synthetic fill-mode ROM and test**

```zig
fn writeCpuFastSetFillRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0010, // ldr r0, [pc, #0x10] ; source
        0xE59F1010, // ldr r1, [pc, #0x10] ; dest
        0xE59F2010, // ldr r2, [pc, #0x10] ; control
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xE591001C, // ldr r0, [r1, #28] ; eighth filled word
        0xE12FFF1E, // bx lr
        0x08000024, // source literal
        0x03000000, // dest literal
        0x01000008, // eight words, fill mode
        1234,       // fill word
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

test "build executes CpuFastSet fill semantics on a synthetic ROM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetFillRom(tmp.dir, io, "cpufastset-fill.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(io, std.testing.allocator, tmp.dir, &output.writer, .{
        .rom_path = "cpufastset-fill.gba",
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_path = "cpufastset-fill-native",
        .output_mode = .auto,
        .optimize = .release,
    });

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-fill-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1234\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
```

- [ ] **Step 2: Add source/destination alignment test**

```zig
fn writeCpuFastSetAlignRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0014, // ldr r0, [pc, #0x14] ; misaligned source
        0xE59F1014, // ldr r1, [pc, #0x14] ; misaligned dest
        0xE59F2014, // ldr r2, [pc, #0x14] ; control
        0xEF00000C, // swi 0x0C (CpuFastSet)
        0xE59F3010, // ldr r3, [pc, #0x10] ; aligned dest base
        0xE5930000, // ldr r0, [r3]
        0xE12FFF1E, // bx lr
        0x0800002D, // source literal: align down to 0x0800002C
        0x03000002, // dest literal: align down to 0x03000000
        0x00000008, // eight words, copy mode
        0x03000000, // aligned dest base literal
        42, 1, 2, 3, 4, 5, 6, 7,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

test "build aligns CpuFastSet source and dest before copying" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeCpuFastSetAlignRom(tmp.dir, io, "cpufastset-align.gba");

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(io, std.testing.allocator, tmp.dir, &output.writer, .{
        .rom_path = "cpufastset-align.gba",
        .machine_name = "gba",
        .target = "x86_64-linux",
        .output_path = "cpufastset-align-native",
        .output_mode = .auto,
        .optimize = .release,
    });

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./cpufastset-align-native"},
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

- [ ] **Step 3: Add structural failure tests for unsupported control bits and counts**

```zig
fn writeCpuFastSetBadControlRom(dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
    const words = [_]u32{
        0xE59F000C, 0xE59F100C, 0xE59F200C, 0xEF00000C,
        0xEAFFFFFE,
        0x08000020,
        0x03000000,
        0x04000008, // bit 26 is valid for CpuSet, unsupported for CpuFastSet
    };
    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeCpuFastSetBadCountRom(dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
    const words = [_]u32{
        0xE59F000C, 0xE59F100C, 0xE59F200C, 0xEF00000C,
        0xEAFFFFFE,
        0x08000020,
        0x03000000,
        0x00000007, // GBA CpuFastSet count must be a multiple of 8 words
    };
    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}
```

Add tests that build these ROMs in `retired_count` mode, run them with `HOMONCULI_MAX_INSTRUCTIONS=500000`, and assert:

```zig
try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported CpuFastSet control 0x04000008 for gba") != null);
try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=4\n") != null);
try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=500000\n") == null);
```

and:

```zig
try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported CpuFastSet count 0x00000007 for gba") != null);
try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=4\n") != null);
try std.testing.expect(std.mem.indexOf(u8, result.stdout, "retired=500000\n") == null);
```

- [ ] **Step 4: Run focused tests and full suite**

Run:

```bash
timeout 300s zig build test --summary all -- --test-filter "CpuFastSet"
timeout 300s zig build test --summary all
```

Expected:

- PASS
- fill, alignment, bad-control, and bad-count tests are green
- no skipped tests

- [ ] **Step 5: Commit the boundary tests**

```bash
git add src/build_cmd.zig src/llvm_codegen.zig
git commit -m "test(kirby): lock CpuFastSet boundary"
```

### Task 4: Re-Probe Kirby And Update The Kirby Spec

**Files:**
- Modify: `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md`

- [ ] **Step 1: Re-run the local-only Kirby probe after `CpuFastSet` lands**

Run:

```bash
mkdir -p .zig-cache/commercial-probes
zig build run -- build ".zig-cache/local-commercial-roms/kirby-nightmare.gba" \
  --machine gba \
  --target x86_64-linux \
  --output frame_raw \
  --max-instructions 500000 \
  -o ".zig-cache/commercial-probes/kirby-cpufastset-native" \
  > ".zig-cache/commercial-probes/kirby-cpufastset.stdout" \
  2> ".zig-cache/commercial-probes/kirby-cpufastset.stderr" || true

sed -n '1,20p' ".zig-cache/commercial-probes/kirby-cpufastset.stdout"
```

Expected:

- the old blocker `Unsupported SWI 0x00000C at 0x080CFA54 for gba` is gone
- one new first meaningful blocker line is visible in `kirby-cpufastset.stdout`

- [ ] **Step 2: Attempt the local-only performance note only if a native binary was emitted**

Run:

```bash
if [ -x ".zig-cache/commercial-probes/kirby-cpufastset-native" ]; then
  /usr/bin/time -f "kirby-cpufastset-native %e sec" \
    env HOMONCULI_OUTPUT_MODE=frame_raw \
        HOMONCULI_OUTPUT_PATH=".zig-cache/commercial-probes/kirby-cpufastset.rgba" \
        HOMONCULI_MAX_INSTRUCTIONS=500000 \
        ".zig-cache/commercial-probes/kirby-cpufastset-native" \
        >/dev/null
else
  printf 'kirby-cpufastset-native not emitted; performance note deferred because the next blocker is still build-time\n'
fi
```

Expected:

- either a local wall-clock line for the native run, or the explicit deferred note above
- no published benchmark numbers

- [ ] **Step 3: Update the Kirby spec with the post-`CpuFastSet` findings**

Append a new `## Post CpuFastSet Re-Probe` section to `docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md` containing:

- one bullet stating the old `SWI 0x0C` blocker is cleared
- one bullet copying the exact new first meaningful blocker line from `.zig-cache/commercial-probes/kirby-cpufastset.stdout`
- one bullet stating whether the local performance note shows immediate pressure for the deferred bitcode/LTO question, or whether it remains deferred
- one bullet reaffirming that Kirby remains the named commercial target and that the next slice is chosen by the new blocker

- [ ] **Step 4: Re-run the full public suite after the spec update**

Run:

```bash
timeout 300s zig build test --summary all
```

Expected:

- PASS
- no skipped tests

- [ ] **Step 5: Commit the finished `CpuFastSet` slice**

```bash
git add docs/superpowers/specs/2026-04-23-kirby-title-screen-bios-shim-design.md
git commit -m "docs(kirby): record post-CpuFastSet frontier"
```

## Self-Review

Spec coverage:

- current measured Kirby blocker is `SWI 0x0C`: Tasks 1-4
- `CpuFastSet` is implemented as one measured BIOS shim, not generic BIOS work: Tasks 1-3
- declaration and doc surface are covered: Tasks 1-2
- LLVM lowering is covered: Tasks 1-2
- copy, fill, alignment, bad-control, and bad-count behavior are covered: Tasks 1-3
- local-only re-probe and performance note are covered: Task 4
- title-screen parity and decompression are intentionally out of scope

Placeholder scan:

- no `TODO`/`TBD` markers
- every public code change step names exact files, tests, and commands
- the only pseudo-IR section is a direct translation guide for a verbose LLVM emitter and names exact control-flow checks, helper calls, and semantics to emit

Type consistency:

- `CpuFastSet` uses the same shim ABI as `CpuSet`: `i32 @shim_gba_CpuFastSet(ptr %state)`
- build-time resolver uses `isCpuFastSetSwi(...)` with `0x00000C` and `0x0C0000`
- LLVM lowering emits `call i32 @shim_gba_CpuFastSet(ptr %state)`
- public synthetic ROMs use ARM-form `0xEF00000C`
