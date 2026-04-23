# Homonculi

Homonculi is a framework for ahead-of-time recompilation of guest binaries into native executables. The first proven target is Game Boy Advance: the bundled validation set derived from `jsmolka/gba-tests` passes in this repo, and a synthetic ARM tight loop sustains `3.54B` guest IPS in release builds on the current baseline host, roughly `210x` real GBA hardware.

This is not an emulator. There is no interpreter, no JIT, no runtime recompilation, and no fallback path that quietly papers over missing lift coverage. `hmncli` takes a ROM plus a machine description and produces a standalone native binary: a **homonculus**, a small artificial program shaped in the image of its guest. Guest APIs cross explicit HLE boundaries and are replaced with host-native implementations during lifting.

## Current Status

- Homonculi is intended to be a universal AoT recompilation framework. GBA is the first proven target, not the final one.
- The working build path today produces standalone `x86_64-linux` ELFs from GBA ROMs.
- The current CLI surface is `build`, `doc`, `status`, and `test`.
- The GBA path passes the bundled real-ROM validation set in this repo: `arm`, `thumb`, `bios`, `memory`, `save`, `unsafe`, and the `ppu` fixtures derived from `jsmolka/gba-tests`.
- The first `tonc` bring-up ladder is green for `sbb_reg`, `obj_demo`, and `key_demo`.
- `irq_demo` is intentionally deferred to the later interrupt milestone because its upstream shape exceeds the current minimal VBlank-only interrupt model.
- A limited `frame_raw` dump path exists for framebuffer inspection: Mode 4, Mode 0 regular BG0 tiles, and the minimal regular OBJ path needed by the current `tonc` demos.
- mGBA-backed raw frame goldens now exist for the green `tonc` demos: `sbb_reg`, `obj_demo`, and `key_demo`.
- Deterministic scripted KEYINPUT exists for bring-up smoke tests.
- There is still no audio backend and no second machine target.

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
