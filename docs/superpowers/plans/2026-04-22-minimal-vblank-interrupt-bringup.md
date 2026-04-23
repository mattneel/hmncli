# Minimal VBlank Interrupt Milestone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one minimal VBlank-only interrupt fixture pass under a deterministic runtime model while preserving byte-exact parity for `sbb_reg`, `obj_demo`, and `key_demo`.

**Architecture:** Start by pinning a synthetic VBlank fixture because the published `tonc` scan did not yield a real VBlank-only demo with a non-NULL handler. Keep the implementation narrow: intercept only the `IME`/`IE`/`IF` MMIO writes the fixture and the negative tests actually use, keep VBlank dispatch inside the existing `VBlankIntrWait` shim path, and preserve the standing tonc parity invariant on every checkpoint.

**Tech Stack:** Zig `0.17.0-dev.56+a8226cd53`, existing LLVM IR code generator, Capstone-backed ARM/Thumb decode, host-exported Zig runtime helpers, `arm-none-eabi` binutils for the synthetic ROM rebuild recipe.

---

## Scope Check

This plan covers only the minimal VBlank bring-up slice from [2026-04-22-minimal-vblank-interrupt-design.md](/home/autark/src/hmncli/docs/superpowers/specs/2026-04-22-minimal-vblank-interrupt-design.md). It deliberately does **not** cover:

- `irq_demo`
- HBlank or VCount interrupt support
- nested interrupt semantics beyond explicit structural rejection
- interrupt priority handling
- new parity goldens
- Kirby or any commercial-title work

## File Structure

**Files:**
- Create: `tests/fixtures/synthetic/vblank/frame_irq.s`
- Create: `tests/fixtures/synthetic/vblank/frame_irq.gba`
- Create: `tests/fixtures/synthetic/vblank/PROVENANCE.md`
- Create: `tests/fixtures/synthetic/vblank/DISCOVERY.md`
- Create: `scripts/rebuild-vblank-fixture.sh`
- Create: `src/interrupt_fixture_support.zig`
- Modify: `src/root.zig`
- Modify: `src/build_cmd.zig`
- Modify: `src/llvm_codegen.zig`
- Modify: `tests/fixtures/real/tonc/INGESTION.md`
- Modify: `README.md`

**Responsibilities:**
- `tests/fixtures/synthetic/vblank/frame_irq.s`: source-of-truth synthetic VBlank fixture proving that a handler can make one visible Mode 4 pixel change.
- `tests/fixtures/synthetic/vblank/frame_irq.gba`: pinned binary built from the assembly fixture at ROM base `0x08000000`.
- `tests/fixtures/synthetic/vblank/PROVENANCE.md`: exact rebuild command, file size, and SHA-256 for the committed fixture.
- `tests/fixtures/synthetic/vblank/DISCOVERY.md`: published-fixture scan results and the explicit reason the milestone uses a synthetic fallback.
- `scripts/rebuild-vblank-fixture.sh`: deliberate rebuild path for the committed synthetic fixture.
- `src/interrupt_fixture_support.zig`: test-only metadata for the synthetic fixture path, hash, size, instruction cap, and signal pixel.
- `src/root.zig`: imports the new support module so its tests are included in `zig build test`.
- `src/build_cmd.zig`: committed-red interrupt tests, temporary negative-fixture ROM writers, runtime-capture helpers, positive fixture verification, and `irq_demo` remeasurement.
- `src/llvm_codegen.zig`: minimal interrupt guest-state fields, MMIO interception for `IE`/`IF`/`IME`, structured runtime diagnostics, and deterministic VBlank dispatch from `VBlankIntrWait`.
- `tests/fixtures/real/tonc/INGESTION.md`: live record of the current `irq_demo` blocker after this slice lands.
- `README.md`: current-status note that the minimal synthetic VBlank milestone is green while `irq_demo` remains deferred.

## Measured Starting Point

- Published `libtonc-examples` scan on `2026-04-22` found no demo that both:
  - installs a non-NULL `II_VBLANK` handler, and
  - avoids widening scope past the approved minimal model.
- Rejected published candidates:
  - `ext/swi_vsync`: uses `irq_add(II_VBLANK, NULL)` only and adds affine OBJ work.
  - `basic/brin_demo`: uses `irq_add(II_VBLANK, NULL)` only and adds keypad/scrolling.
  - `lab/template`: uses `irq_add(II_VBLANK, NULL)` only and adds TTE text setup.
  - `ext/irq_demo`: requires HBlank, VCount, nested enable, and priority switching.
- Chosen synthetic fixture shape:
  - linked at ROM base `0x08000000`
  - writes Mode 4 pixel `(0, 0)` to palette index `1` from the VBlank handler
  - size `176` bytes
  - SHA-256 `7beabadc06e6274af93b7fafb9312116ef1b91730e916a230b937039b3675646`
- Current bad behavior against that fixture:
  - `frame_raw` at `500000` instructions produces pixel `(0, 0) = { 0, 0, 0, 255 }`
  - the desired signal pixel is `{ 0, 255, 0, 255 }`
  - the current runtime does not yet reject non-VBlank `IE` writes or `IME` re-enable inside a handler

## Scope Guardrails

- Reuse the existing `frame_raw` path as the observable-state signal. Do **not** add a new output mode for this milestone.
- Keep the interrupt MMIO seam as small as possible: only `IE`, `IF`, and `IME` 16-bit stores need interception in this slice.
- Keep `VBlankIntrWait` as the only frame-advance path in this milestone. Do **not** add host wallclock pacing or per-block interrupt polling.
- The existing tonc parity suite is a standing regression invariant. Every task that changes runtime behavior must rerun the relevant tonc parity tests.

### Task 1: Pin The Synthetic VBlank Fixture And Commit The Red Checkpoint

**Files:**
- Create: `tests/fixtures/synthetic/vblank/frame_irq.s`
- Create: `tests/fixtures/synthetic/vblank/frame_irq.gba`
- Create: `tests/fixtures/synthetic/vblank/PROVENANCE.md`
- Create: `tests/fixtures/synthetic/vblank/DISCOVERY.md`
- Create: `scripts/rebuild-vblank-fixture.sh`
- Create: `src/interrupt_fixture_support.zig`
- Modify: `src/root.zig`
- Modify: `src/build_cmd.zig`
- Test: `src/interrupt_fixture_support.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Add the pinned synthetic fixture artifacts and support metadata**

```asm
.syntax unified
.cpu arm7tdmi
.arm

.global _start

.equ REG_DISPCNT,  0x04000000
.equ REG_DISPSTAT, 0x04000004
.equ REG_IE,       0x04000200
.equ REG_IF,       0x04000202
.equ REG_IME,      0x04000208
.equ IRQ_VECTOR,   0x03007FFC
.equ PAL_BG,       0x05000000
.equ VRAM,         0x06000000

_start:
    bl handler

    ldr r0, =VRAM
    mov r1, #0
    strb r1, [r0]

    ldr r0, =PAL_BG
    mov r1, #0
    strh r1, [r0]
    add r0, r0, #2
    mov r1, #0xE0
    orr r1, r1, #0x0300
    strh r1, [r0]

    ldr r0, =IRQ_VECTOR
    ldr r1, =handler
    str r1, [r0]

    ldr r0, =REG_DISPCNT
    mov r1, #4
    orr r1, r1, #0x0400
    strh r1, [r0]

    ldr r0, =REG_DISPSTAT
    mov r1, #8
    strh r1, [r0]

    ldr r0, =REG_IE
    mov r1, #1
    strh r1, [r0]

    ldr r0, =REG_IME
    mov r1, #1
    strh r1, [r0]

loop:
    swi 0x05
    b loop

handler:
    stmfd sp!, {r0-r1, lr}
    ldr r0, =VRAM
    mov r1, #1
    strb r1, [r0]
    ldr r0, =REG_IF
    mov r1, #1
    strh r1, [r0]
    ldmfd sp!, {r0-r1, lr}
    bx lr
```

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$repo_root/tests/fixtures/synthetic/vblank"

arm-none-eabi-as -mcpu=arm7tdmi -o "$fixture_dir/frame_irq.o" "$fixture_dir/frame_irq.s"
arm-none-eabi-ld -Ttext=0x08000000 -nostdlib -o "$fixture_dir/frame_irq.elf" "$fixture_dir/frame_irq.o"
arm-none-eabi-objcopy -O binary "$fixture_dir/frame_irq.elf" "$fixture_dir/frame_irq.gba"

rm -f "$fixture_dir/frame_irq.o" "$fixture_dir/frame_irq.elf"

wc -c "$fixture_dir/frame_irq.gba"
sha256sum "$fixture_dir/frame_irq.gba"
```

```markdown
# Minimal VBlank Fixture Provenance

- fixture source: `tests/fixtures/synthetic/vblank/frame_irq.s`
- rebuild script: `scripts/rebuild-vblank-fixture.sh`
- toolchain: `arm-none-eabi-as`, `arm-none-eabi-ld`, `arm-none-eabi-objcopy`
- link address: `0x08000000`

## Binary Hash

- `frame_irq.gba`: size `176`, SHA-256 `7beabadc06e6274af93b7fafb9312116ef1b91730e916a230b937039b3675646`
```

```markdown
# Minimal VBlank Fixture Discovery

## Published Scan Result

No published `libtonc-examples` demo fits the minimal stopping rule for this milestone.

### Rejected Candidates

- `ext/swi_vsync`
  - uses `irq_add(II_VBLANK, NULL)`, so it proves the wait path only, not a custom handler
  - adds affine OBJ setup that the interrupt milestone does not need
- `basic/brin_demo`
  - uses `irq_add(II_VBLANK, NULL)`
  - widens scope to keypad-driven scrolling and larger tilemap state
- `lab/template`
  - uses `irq_add(II_VBLANK, NULL)`
  - widens scope to TTE/text setup without proving a handler path
- `ext/irq_demo`
  - widens scope to `II_HBLANK`, `II_VCOUNT`, nested re-enable, and priority switching

## Selection

The milestone uses a synthetic fallback because the published scan produced no VBlank-only fixture with a non-NULL handler.
```

```zig
const std = @import("std");
const Io = std.Io;

pub const Fixture = struct {
    name: []const u8,
    asm_path: []const u8,
    rom_path: []const u8,
    size: usize,
    sha256_hex: []const u8,
    max_instructions: u64,
    signal_pixel: [4]u8,
};

pub const minimal_vblank = Fixture{
    .name = "frame_irq",
    .asm_path = "tests/fixtures/synthetic/vblank/frame_irq.s",
    .rom_path = "tests/fixtures/synthetic/vblank/frame_irq.gba",
    .size = 176,
    .sha256_hex = "7beabadc06e6274af93b7fafb9312116ef1b91730e916a230b937039b3675646",
    .max_instructions = 500_000,
    .signal_pixel = .{ 0, 255, 0, 255 },
};

test "minimal vblank fixture hash and size match provenance" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();

    const bytes = try cwd.readFileAlloc(io, minimal_vblank.rom_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(minimal_vblank.size, bytes.len);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(minimal_vblank.sha256_hex, &actual_hex);
}
```

```zig
const interrupt_fixture_support = @import("interrupt_fixture_support.zig");
```

- [ ] **Step 2: Add the committed-red interrupt tests and helper ROM writers**

```zig
fn writeNonVBlankIeRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xE59F0008, // ldr r0, [pc, #8]
        0xE3A01002, // mov r1, #2
        0xE1C010B0, // strh r1, [r0]
        0xEF000000, // swi 0x00
        0x04000200, // IE
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

fn writeNestedImeRom(
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
) !void {
    const words = [_]u32{
        0xEB00000D,
        0xE59F0054,
        0xE59F1054,
        0xE5801000,
        0xE59F0050,
        0xE3A01008,
        0xE1C010B0,
        0xE59F0048,
        0xE3A01001,
        0xE1C010B0,
        0xE59F0040,
        0xE3A01001,
        0xE1C010B0,
        0xEF000005,
        0xEAFFFFFD,
        0xE92D4003,
        0xE59F0028,
        0xE3A01001,
        0xE1C010B0,
        0xE59F0020,
        0xE3A01001,
        0xE1C010B0,
        0xE8BD4003,
        0xE12FFF1E,
        0x03007FFC,
        0x0800003C,
        0x04000004,
        0x04000200,
        0x04000208,
        0x04000202,
    };

    var rom: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, index| {
        std.mem.writeInt(u32, rom[index * 4 ..][0..4], word, .little);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = &rom });
}

const NativeRunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

fn runNativeCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    native_path: []const u8,
    output_mode: ?[]const u8,
    max_instructions: ?u64,
) !NativeRunResult {
    var environ_map = std.process.Environ.Map.init(allocator);
    errdefer environ_map.deinit();

    if (output_mode) |mode| try environ_map.put("HOMONCULI_OUTPUT_MODE", mode);
    if (max_instructions) |limit| {
        const rendered = try std.fmt.allocPrint(allocator, "{d}", .{limit});
        defer allocator.free(rendered);
        try environ_map.put("HOMONCULI_MAX_INSTRUCTIONS", rendered);
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{native_path},
        .cwd = .{ .dir = dir },
        .environ_map = &environ_map,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    environ_map.deinit();

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

test "minimal vblank fixture turns the signal pixel green" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const native_path = try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        interrupt_fixture_support.minimal_vblank.rom_path,
        "frame-irq-native",
        .frame_raw,
        interrupt_fixture_support.minimal_vblank.max_instructions,
    );
    defer std.testing.allocator.free(native_path);

    try runFrameFixture(io, tmp.dir, native_path, "frame_irq.rgba", .{
        .max_instructions = interrupt_fixture_support.minimal_vblank.max_instructions,
    });

    const frame = try frame_test_support.readExactFrame(std.testing.allocator, io, tmp.dir, "frame_irq.rgba");
    defer std.testing.allocator.free(frame);

    try frame_test_support.expectPixel(
        frame,
        0,
        0,
        interrupt_fixture_support.minimal_vblank.signal_pixel,
    );
}

test "minimal vblank model rejects non-vblank IE bits" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeNonVBlankIeRom(tmp.dir, io, "ie-bad.gba");
    const native_path = try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "ie-bad.gba",
        "ie-bad-native",
        .retired_count,
        500_000,
    );
    defer std.testing.allocator.free(native_path);

    const result = try runNativeCapture(std.testing.allocator, io, tmp.dir, native_path, "retired_count", 500_000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported interrupt source mask 0x0002 at 0x04000200 for gba") != null);
}

test "minimal vblank model rejects IME re-enable inside a handler" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeNestedImeRom(tmp.dir, io, "nested-ime.gba");
    const native_path = try buildFixtureNative(
        std.testing.allocator,
        io,
        tmp.dir,
        "nested-ime.gba",
        "nested-ime-native",
        .retired_count,
        500_000,
    );
    defer std.testing.allocator.free(native_path);

    const result = try runNativeCapture(std.testing.allocator, io, tmp.dir, native_path, "retired_count", 500_000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Unsupported nested IME enable at 0x04000208 for gba") != null);
}
```

- [ ] **Step 3: Run the new tests and verify the checkpoint is red**

Run: `zig test src/interrupt_fixture_support.zig && zig test src/build_cmd.zig --test-filter "minimal vblank"`

Expected:
- `src/interrupt_fixture_support.zig` passes because the pinned fixture hash is real.
- `src/build_cmd.zig` fails because:
  - the fixture still renders pixel `(0, 0)` as `{ 0, 0, 0, 255 }` instead of `{ 0, 255, 0, 255 }`
  - the runtime does not yet print `Unsupported interrupt source mask 0x0002 at 0x04000200 for gba`
  - the runtime does not yet print `Unsupported nested IME enable at 0x04000208 for gba`

- [ ] **Step 4: Commit the red checkpoint**

```bash
git add \
  tests/fixtures/synthetic/vblank/frame_irq.s \
  tests/fixtures/synthetic/vblank/frame_irq.gba \
  tests/fixtures/synthetic/vblank/PROVENANCE.md \
  tests/fixtures/synthetic/vblank/DISCOVERY.md \
  scripts/rebuild-vblank-fixture.sh \
  src/interrupt_fixture_support.zig \
  src/root.zig \
  src/build_cmd.zig
git commit -m "test(interrupts): add failing minimal vblank checks"
```

### Task 2: Add The Minimal `IE` / `IF` / `IME` MMIO Contract

**Files:**
- Modify: `src/llvm_codegen.zig`
- Modify: `src/build_cmd.zig`
- Test: `src/llvm_codegen.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Add a focused red LLVM-emission test for the interrupt MMIO seam**

```zig
test "build emits minimal vblank interrupt MMIO helpers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom_bytes = try Io.Dir.cwd().readFileAlloc(
        io,
        interrupt_fixture_support.minimal_vblank.rom_path,
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(rom_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "frame_irq.gba", .data = rom_bytes });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "frame_irq.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_mode = .retired_count,
            .max_instructions = 500_000,
            .output_path = "frame-irq-native",
            .optimize = .release,
        },
    );

    const llvm_bytes = try tmp.dir.readFileAlloc(io, "frame-irq-native.ll", std.testing.allocator, .limited(512 * 1024));
    defer std.testing.allocator.free(llvm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@.fmt_irq_bad_ie") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@.fmt_irq_nested_ime") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "@hmn_store_gba_io16") != null);
}
```

- [ ] **Step 2: Run the new LLVM-emission test to verify it fails**

Run: `zig test src/llvm_codegen.zig --test-filter "minimal vblank interrupt MMIO helpers"`

Expected: FAIL because the current IR still stores raw 16-bit IO writes directly and does not emit the named interrupt helper surface.

- [ ] **Step 3: Implement the typed MMIO interception and runtime diagnostics**

```zig
const guest_state_in_irq_handler_field = 25;

const io_ie_offset: u32 = 512;
const io_if_offset: u32 = 514;
const io_ime_offset: u32 = 520;
const irq_vblank_mask: u16 = 0x0001;
```

```zig
try writer.print("@.fmt_irq_bad_ie = private unnamed_addr constant [57 x i8] c\"Unsupported interrupt source mask 0x%04x at 0x04000200 for gba\\0A\\00\", align 1\n", .{});
try writer.print("@.fmt_irq_nested_ime = private unnamed_addr constant [53 x i8] c\"Unsupported nested IME enable at 0x04000208 for gba\\0A\\00\", align 1\n", .{});
try writer.print("@.fmt_irq_multi_if = private unnamed_addr constant [49 x i8] c\"Unsupported simultaneous IF mask 0x%04x for gba\\0A\\00\", align 1\n", .{});
```

```llvm
define void @hmn_interrupt_fail_bad_ie(ptr %state, i16 %value) {
entry:
  %stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 21
  %value_i32 = zext i16 %value to i32
  call i32 (ptr, ...) @printf(ptr @.fmt_irq_bad_ie, i32 %value_i32)
  store i1 true, ptr %stop_flag_ptr, align 1
  ret void
}

define void @hmn_interrupt_fail_nested_ime(ptr %state) {
entry:
  %stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 21
  call i32 (ptr, ...) @printf(ptr @.fmt_irq_nested_ime)
  store i1 true, ptr %stop_flag_ptr, align 1
  ret void
}

define void @hmn_interrupt_fail_multi_if(ptr %state, i16 %value) {
entry:
  %stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 21
  %value_i32 = zext i16 %value to i32
  call i32 (ptr, ...) @printf(ptr @.fmt_irq_multi_if, i32 %value_i32)
  store i1 true, ptr %stop_flag_ptr, align 1
  ret void
}

define void @hmn_store_gba_io16(ptr %state, i32 %offset, i16 %value, ptr %raw_ptr) {
entry:
  switch i32 %offset, label %raw_store [
    i32 512, label %store_ie
    i32 514, label %store_if
    i32 520, label %store_ime
  ]

store_ie:
  %bad_ie_bits = and i16 %value, -2
  %bad_ie = icmp ne i16 %bad_ie_bits, 0
  br i1 %bad_ie, label %fail_ie, label %write_ie

fail_ie:
  call void @hmn_interrupt_fail_bad_ie(ptr %state, i16 %value)
  ret void

write_ie:
  store i16 %value, ptr %raw_ptr, align 1
  ret void

store_if:
  %if_curr = load i16, ptr %raw_ptr, align 1
  %if_clear_mask = and i16 %value, 1
  %if_keep_mask = xor i16 %if_clear_mask, -1
  %if_next = and i16 %if_curr, %if_keep_mask
  store i16 %if_next, ptr %raw_ptr, align 1
  ret void

store_ime:
  %in_irq_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 25
  %in_irq = load i1, ptr %in_irq_ptr, align 1
  %ime_enable = and i16 %value, 1
  %ime_enable_set = icmp ne i16 %ime_enable, 0
  %bad_nested = and i1 %in_irq, %ime_enable_set
  br i1 %bad_nested, label %fail_nested, label %write_ime

fail_nested:
  call void @hmn_interrupt_fail_nested_ime(ptr %state)
  ret void

write_ime:
  store i16 %ime_enable, ptr %raw_ptr, align 1
  ret void

raw_store:
  store i16 %value, ptr %raw_ptr, align 1
  ret void
}
```

```llvm
; inside emitRegionDispatch() for 16-bit IO stores only
%io_special_16 = icmp eq i32 %store16_offset_2, 512
%io_special_if = icmp eq i32 %store16_offset_2, 514
%io_special_ime = icmp eq i32 %store16_offset_2, 520
%io_special_any0 = or i1 %io_special_16, %io_special_if
%io_special_any = or i1 %io_special_any0, %io_special_ime
br i1 %io_special_any, label %io_store_special_16_2, label %io_store_raw_16_2

io_store_special_16_2:
  %value16_16_2 = trunc i32 %value to i16
  call void @hmn_store_gba_io16(ptr %state, i32 %store16_offset_2, i16 %value16_16_2, ptr %ptr_16_2)
  br label %store_ret_16

io_store_raw_16_2:
  %value16_16_2_raw = trunc i32 %value to i16
  store i16 %value16_16_2_raw, ptr %ptr_16_2, align 1
  br label %store_ret_16
```

- [ ] **Step 4: Run the targeted tests and verify the negative cases are green while the positive fixture is still red**

Run: `zig test src/llvm_codegen.zig --test-filter "minimal vblank interrupt MMIO helpers" && zig test src/build_cmd.zig --test-filter "minimal vblank model rejects"`

Expected:
- the LLVM-emission test passes
- both negative runtime tests pass
- `minimal vblank fixture turns the signal pixel green` is still failing because VBlank dispatch is not yet correct

- [ ] **Step 5: Commit the MMIO contract slice**

```bash
git add src/llvm_codegen.zig src/build_cmd.zig
git commit -m "feat(interrupts): add minimal vblank MMIO contract"
```

### Task 3: Make `VBlankIntrWait` Advance A Deterministic VBlank And Run The Handler

**Files:**
- Modify: `src/llvm_codegen.zig`
- Modify: `src/build_cmd.zig`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Re-run the positive fixture test alone to verify the handler path is still red**

Run: `zig test src/build_cmd.zig --test-filter "minimal vblank fixture turns the signal pixel green"`

Expected: FAIL because the current helper still leaves pixel `(0, 0)` black.

- [ ] **Step 2: Replace the current `DISPSTAT bit0` pseudo-check with an explicit VBlank event**

```llvm
define i64 @hmn_gba_advance_frame(ptr %state) {
entry:
  %vblank_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 24
  %vblank_curr = load i64, ptr %vblank_ptr, align 8
  %vblank_next = add i64 %vblank_curr, 1
  store i64 %vblank_next, ptr %vblank_ptr, align 8

  %io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 8
  %if_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 514
  %if_curr = load i16, ptr %if_ptr, align 1
  %if_next = or i16 %if_curr, 1
  store i16 %if_next, ptr %if_ptr, align 1
  ret i64 %vblank_next
}

define void @hmn_dispatch_vblank_irq(ptr %state) {
entry:
  %io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 8
  %dispstat_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 4
  %dispstat = load i16, ptr %dispstat_ptr, align 1
  %dispstat_vblank_irq = and i16 %dispstat, 8
  %dispstat_enabled = icmp ne i16 %dispstat_vblank_irq, 0
  br i1 %dispstat_enabled, label %check_ime, label %done

check_ime:
  %ime_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 520
  %ime = load i16, ptr %ime_ptr, align 1
  %ime_enabled = icmp ne i16 %ime, 0
  br i1 %ime_enabled, label %check_ie, label %done

check_ie:
  %ie_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 512
  %ie = load i16, ptr %ie_ptr, align 1
  %ie_vblank = and i16 %ie, 1
  %ie_enabled = icmp ne i16 %ie_vblank, 0
  br i1 %ie_enabled, label %check_if, label %done

check_if:
  %if_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 514
  %if_value = load i16, ptr %if_ptr, align 1
  %if_multi = and i16 %if_value, -2
  %if_bad = icmp ne i16 %if_multi, 0
  br i1 %if_bad, label %fail_multi_if, label %check_vector

fail_multi_if:
  call void @hmn_interrupt_fail_multi_if(ptr %state, i16 %if_value)
  br label %done

check_vector:
  %iwram_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 7
  %vector_ptr = getelementptr inbounds [32768 x i8], ptr %iwram_ptr, i32 0, i32 32764
  %vector = load i32, ptr %vector_ptr, align 1
  %has_vector = icmp ne i32 %vector, 0
  br i1 %has_vector, label %fire, label %done

fire:
  %in_irq_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 25
  store i1 true, ptr %in_irq_ptr, align 1
  call void @hmn_call_guest(ptr %state, i32 %vector)
  store i1 false, ptr %in_irq_ptr, align 1
  br label %done

done:
  ret void
}
```

```llvm
define i32 @shim_gba_VBlankIntrWait(ptr %state) {
entry:
  %frame_index = call i64 @hmn_gba_advance_frame(ptr %state)
  %keyinput_value = call i16 @hmgba_sample_keyinput_for_frame(i64 %frame_index)
  %io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 8
  %keyinput_ptr = getelementptr inbounds [1024 x i8], ptr %io_ptr, i32 0, i32 304
  store i16 %keyinput_value, ptr %keyinput_ptr, align 1
  call void @hmn_dispatch_vblank_irq(ptr %state)
  ret i32 0
}
```

- [ ] **Step 3: Run the positive fixture and the standing tonc parity invariant**

Run: `zig test src/build_cmd.zig --test-filter "minimal vblank fixture turns the signal pixel green" && zig build test --summary all`

Expected:
- the positive fixture test passes with pixel `(0, 0) == { 0, 255, 0, 255 }`
- the negative interrupt tests still pass
- `sbb_reg`, `obj_demo`, and `key_demo` parity stay byte-exact

- [ ] **Step 4: Commit the dispatch slice**

```bash
git add src/llvm_codegen.zig src/build_cmd.zig
git commit -m "feat(interrupts): dispatch minimal vblank handlers"
```

### Task 4: Re-Measure `irq_demo` And Close The Milestone Honestly

**Files:**
- Modify: `tests/fixtures/real/tonc/INGESTION.md`
- Modify: `tests/fixtures/synthetic/vblank/DISCOVERY.md`
- Modify: `README.md`
- Test: `src/build_cmd.zig`

- [ ] **Step 1: Re-measure the deferred `irq_demo` blocker**

Run: `zig build run -- build tests/fixtures/real/tonc/irq_demo.gba --machine gba --target x86_64-linux --output frame_raw --max-instructions 500000 -o .zig-cache/tonc/irq-demo-native`

Expected: FAIL with the current first blocker printed during build. If the blocker changed from `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`, record the new exact string instead of guessing.

- [ ] **Step 2: Update the live notes with the post-slice measurement**

```markdown
## First Homonculi Failure Surface

- Re-measured after the minimal VBlank interrupt milestone on 2026-04-22.
- `sbb_reg`, `obj_demo`, and `key_demo` remain parity-green.
- The synthetic `frame_irq` fixture is green under the minimal VBlank-only model.
- `irq_demo`: `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`
```

```markdown
## Result

- The synthetic fallback is now green.
- Published `irq_demo` remains deferred because its first blocker is still outside this milestone’s scope and still precedes any HBlank/VCount work.
```

```markdown
- Current graphics/input/parity milestone: `sbb_reg`, `obj_demo`, and `key_demo` remain byte-exact against mGBA goldens.
- Minimal VBlank interrupt milestone: synthetic `frame_irq` fixture green under deterministic `VBlankIntrWait` dispatch.
- `irq_demo` remains deferred until a later interrupt-expansion slice.
```

- [ ] **Step 3: Run the full verification pass**

Run: `zig build test --summary all`

Expected: PASS with the existing tonc parity suite still green and the new interrupt tests included.

- [ ] **Step 4: Commit the milestone close-out**

```bash
git add tests/fixtures/real/tonc/INGESTION.md tests/fixtures/synthetic/vblank/DISCOVERY.md README.md
git commit -m "docs(interrupts): record minimal vblank milestone state"
```

## Self-Review

- Spec coverage:
  - fixture discovery and synthetic fallback: Task 1
  - explicit VBlank-only MMIO contract: Task 2
  - deterministic `VBlankIntrWait` dispatch and handler execution: Task 3
  - standing tonc parity invariant: Tasks 1-3 verification and Task 4 full test pass
  - `irq_demo` remeasurement and recorded deferral: Task 4
- Placeholder scan:
  - no `TODO`, `TBD`, or “implement later” markers remain
  - each task has concrete file paths, code snippets, commands, and commit messages
- Type and naming consistency:
  - `interrupt_fixture_support.minimal_vblank` is the single fixture metadata entry referenced across tasks
  - diagnostics use the same exact strings in tests and implementation
  - helper names are consistent between the build tests and LLVM emission (`hmn_store_gba_io16`, `hmn_gba_advance_frame`, `hmn_dispatch_vblank_irq`)
