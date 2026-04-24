# Homonculi

Homonculi is a framework for ahead-of-time recompilation of guest binaries into native executables. The first proven target is Game Boy Advance: the bundled validation set derived from `jsmolka/gba-tests` passes in this repo, and a synthetic ARM tight loop sustains `3.54B` guest IPS in release builds on the current baseline host, roughly `210x` real GBA hardware.

This is not an emulator. There is no interpreter, no JIT, no runtime recompilation, and no fallback path that quietly papers over missing lift coverage. `hmncli` takes a ROM plus a machine description and produces a standalone native binary: a **homonculus**, a small artificial program shaped in the image of its guest. Guest APIs cross explicit HLE boundaries and are replaced with host-native implementations during lifting.

## Current Status

- Homonculi is intended to be a universal AoT recompilation framework. GBA is the first proven target, not the final one.
- The working build path today produces standalone `x86_64-linux` ELFs from GBA ROMs.
- The current CLI surface is `build`, `doc`, `status`, and `test`.
- The GBA path passes the bundled real-ROM validation set in this repo: `arm`, `thumb`, `bios`, `memory`, `save`, `unsafe`, and the `ppu` fixtures derived from `jsmolka/gba-tests`.
- The first `tonc` bring-up ladder is green for `sbb_reg`, `obj_demo`, and `key_demo`.
- The minimal synthetic VBlank interrupt fixture is green under deterministic `VBlankIntrWait` dispatch.
- `irq_demo` remains intentionally deferred: its current first blocker is `Unsupported opcode 0x0000468F at 0x08002240 for armv4t`, and its upstream shape exceeds the current VBlank-only interrupt model.
- A `frame_raw` dump path exists for framebuffer inspection: Mode 4, Mode 0 regular BG0-BG3 tile backgrounds, BG priority layering, 4bpp and 8bpp regular tiles, screenblock selection, tile flips, and the current regular/affine OBJ subset.
- Mode 0 rendering now uses a per-pixel layer compositor, so OBJ priority is resolved against BG priority instead of relying on incidental draw order.
- An SDL3 `window` output path now exists. It dynamically loads `libSDL3.so`/`libSDL3.so.0` or `HOMONCULI_SDL3_PATH`, frame-steps guest execution by a deterministic instruction budget, and presents each rendered GBA frame in a host window.
- mGBA-backed raw frame goldens now exist for the green `tonc` demos: `sbb_reg`, `obj_demo`, and `key_demo`.
- Deterministic scripted KEYINPUT exists for bring-up smoke tests.
- Local-only commercial probing is active. Developer-supplied commercial ROMs live under `.zig-cache/local-commercial-roms/` and are never committed.
- The current local Kirby probe reaches and renders the story/title sequence through `frame_raw`, including tiled BG layers and OAM sprites, and can run through the SDL3 frame-step window path. This is a local bring-up checkpoint, not a committed commercial fixture or compatibility claim.
- The SDL3 path is not a playable runtime yet. SDL keyboard input is not mapped into GBA KEYINPUT, there is no audio backend, and there is still no second machine target.

## Quickstart

### Requirements

- Zig `0.17.0-dev.56+a8226cd53`
- `clang` on `PATH`
- A Linux `x86_64` host is the path exercised by the current end-to-end tests

### Build the CLI

```bash
zig build
```

This installs `hmncli` to `zig-out/bin/hmncli`.

### Run the test suite

```bash
zig build test --summary all
```

### Build and run a real GBA test ROM

```bash
zig build run -- build tests/fixtures/real/jsmolka/arm.gba \
  --machine gba \
  --target x86_64-linux \
  --opt release \
  -o /tmp/arm-native

/tmp/arm-native
```

### Dump a raw Mode 4 framebuffer

```bash
zig build run -- build tests/fixtures/real/jsmolka/ppu-hello.gba \
  --machine gba \
  --target x86_64-linux \
  --output frame_raw \
  --max-instructions 5000 \
  -o /tmp/ppu-hello-native

HOMONCULI_OUTPUT_MODE=frame_raw \
HOMONCULI_OUTPUT_PATH=/tmp/ppu-hello.rgba \
/tmp/ppu-hello-native
```

If you want a PNG for inspection:

```bash
magick -size 240x160 -depth 8 rgba:/tmp/ppu-hello.rgba /tmp/ppu-hello.png
```

### Open a frame-stepped SDL3 window

```bash
zig build run -- build tests/fixtures/real/jsmolka/ppu-hello.gba \
  --machine gba \
  --target x86_64-linux \
  --output window \
  --max-instructions 280896 \
  --opt release \
  -o /tmp/ppu-hello-window

/tmp/ppu-hello-window
```

For `window`, `--max-instructions` is the per-present guest budget. `280896` is the current deterministic GBA frame-step interval.

If SDL3 is not on the system library path, point the generated binary at a local shared library:

```bash
HOMONCULI_SDL3_PATH=/path/to/libSDL3.so /tmp/ppu-hello-window
```

For scripted smoke runs that should not leave a window open:

```bash
HOMONCULI_WINDOW_AUTOCLOSE_FRAMES=1 /tmp/ppu-hello-window
```

## CLI

### `build`

Build a homonculus from a guest ROM:

```bash
zig-out/bin/hmncli build <rom> --machine <name> --target <triple> -o <output>
```

Supported output modes today:

- default numeric or verdict-style program output
- `--output frame_raw --max-instructions N`
- `--output retired_count --max-instructions N`
- `--output window --max-instructions N`

Optimization modes:

- `--opt debug`
- `--opt release`
- `--opt small`

### `doc`

Render declaration metadata for a shim or instruction:

```bash
zig-out/bin/hmncli doc shim/gba/Div
zig-out/bin/hmncli doc instruction/armv4t/mov_imm
```

### `status`

Summarize a recorded trace:

```bash
zig-out/bin/hmncli status --trace path/to/trace.bin
```

### `test`

Run isolated declaration-backed tests:

```bash
zig-out/bin/hmncli test --shim gba/Div
zig-out/bin/hmncli test --instruction armv4t/mov_imm
```

## Architecture

At a high level:

```text
ROM + machine description
  -> loader
  -> Capstone-backed decode
  -> lift directly to LLVM IR
  -> optimize
  -> codegen + link
  -> standalone native binary
```

The framework is built around explicit declarations:

- machines are declared
- shims are declared
- instruction lifting surfaces are declared
- missing coverage fails structurally instead of falling back to an interpreter

That design is deliberate. The project is as much about the authoring loop as it is about the generated binary: contributors need to know what to implement next, test it in isolation, and verify that it worked.

## Benchmarks

The first defensible throughput baseline is recorded in [BENCHMARKS.md](BENCHMARKS.md).

Current headline number on the baseline host:

- synthetic ARM tight loop, `10,000,000` retired guest instructions
- `release`: `3,539,898,821` guest IPS
- `debug`: `666,945,185` guest IPS

These are internal regression-tracking numbers, not game-FPS claims.

## Read Next

- [SPEC.md](SPEC.md): project thesis, architecture, milestone ladder, and open questions
- [BENCHMARKS.md](BENCHMARKS.md): benchmark methodology and current performance baseline

## Project State

Homonculi is already real enough to compile and run standalone native binaries from GBA ROMs. It is not yet broad enough to claim general machine coverage. The current work is about expanding proven surface area without compromising the core thesis: static recompilation, explicit HLE boundaries, structured failure when coverage is missing, and native-speed output when the lift succeeds.
