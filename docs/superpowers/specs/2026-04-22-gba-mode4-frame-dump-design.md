# GBA Mode 4 Frame Dump Design

Date: 2026-04-22

## Goal

Add a first real graphics output path to `hmncli` for GBA guests by dumping raw `240x160` pixels for Background Mode 4. This is a native-output milestone, not a frontend milestone. The output is a deterministic raw RGBA artifact suitable for later byte-exact parity tests against an external oracle such as eggvance.

## Scope

This design covers the first two renderer slices:

1. Slice 1: `hmncli` can build and run a GBA homonculus that emits a raw Mode 4 frame dump from final guest memory state.
2. Slice 2: the same path is checked against committed eggvance-backed golden `.rgba` fixtures.

This design does not include tile modes, sprites, blending, windows, scanline timing, frame-`N` dump semantics, PNG fixtures, or declaration-schema changes.

## Design 1: Output Model

### Ownership split

- GBA runtime modules own rendering semantics.
- `hmncli` owns output policy and invocation.

The renderer is machine behavior, not CLI orchestration. The CLI decides whether output should be `frame_raw`, where it should be written, and what execution limit should apply. The GBA runtime decides how to interpret `DISPCNT`, palette RAM, and VRAM to produce pixels.

### Output mode

Add a new output mode, `frame_raw`, alongside the existing textual outputs.

Canonical artifact format:

- raw `.rgba`
- dimensions: `240x160`
- pixel format: `RGBA8`
- no header

PNG is not a source artifact and is never committed. PNG is a derived debugging view generated on demand outside version control.

### Mode support

Slice 1 supports Background Mode 4 only.

At dump time the runtime reads `DISPCNT` from `0x04000000`:

- mode field must be `4`
- page-select bit chooses `0x06000000` or `0x0600A000`
- pixels are 8-bit indices into BG palette RAM at `0x05000000`

Palette decode uses standard `BGR555 -> RGBA8` expansion:

- `r8 = (r5 << 3) | (r5 >> 2)`
- `g8 = (g5 << 3) | (g5 >> 2)`
- `b8 = (b5 << 3) | (b5 >> 2)`
- alpha is always `255`

Any unsupported display mode fails explicitly at runtime with a structured diagnostic. There is no approximation or fallback renderer.

## Design 2: Trigger Semantics And Test Strategy

### Dump trigger

The frame dump is produced:

- when the lifted entry function returns, or
- when the instruction cap is reached,

whichever happens first.

In practice:

- synthetic tests are expected to terminate naturally
- real GBA ROMs are expected to hit the instruction cap

Both paths produce the same final-output routine.

### Runtime policy contract

Slice 1 uses a small environment-variable contract to pass runtime policy from `hmncli` to the generated binary:

- `HOMONCULI_OUTPUT_MODE`
- `HOMONCULI_OUTPUT_PATH`
- `HOMONCULI_MAX_INSTRUCTIONS`

Supported value set for this slice:

- `HOMONCULI_OUTPUT_MODE=frame_raw`
- `HOMONCULI_OUTPUT_PATH=<filesystem path>`
- `HOMONCULI_MAX_INSTRUCTIONS=<decimal integer>`

These names are stable for this slice and should be documented next to the runtime reader. The bootstrap implementation should use exactly this contract rather than inventing ad-hoc names.

### CLI behavior

For `frame_raw`, `hmncli` requires an explicit instruction cap. That keeps renderer runs deterministic and makes the stop condition visible in tests.

Expected interface shape:

- `--output frame_raw`
- `-o <path>`
- `--max-instructions <count>`

General non-renderer execution can remain uncapped. `frame_raw` specifically should require the cap rather than guessing.

### Slice 1 tests

Slice 1 lands the renderer without any external oracle dependency.

Real-ROM acceptance targets:

- `ppu-stripes.gba`
- `ppu-shades.gba`
- `ppu-hello.gba`

For each ROM:

- run with `frame_raw`
- pass an explicit instruction cap
- assert output size is exactly `240 * 160 * 4`
- assert a small set of exact pixel values

The smoke assertions are intentionally sparse and hand-picked:

- `stripes`: representative band samples
- `shades`: representative palette/gradient samples
- `hello`: representative foreground/background samples

On failure, tests may write scratch artifacts under `.zig-cache/test-artifacts/`:

- `*.actual.rgba`
- derived `*.actual.png`
- `*.diff.png`

This directory is ignored by git and safe to overwrite between runs.

### Slice 2 tests

Slice 2 adds eggvance-backed goldens without changing the comparison harness shape.

Committed fixture format:

- `tests/fixtures/real/jsmolka/ppu-stripes.golden.rgba`
- `tests/fixtures/real/jsmolka/ppu-shades.golden.rgba`
- `tests/fixtures/real/jsmolka/ppu-hello.golden.rgba`

Pass criterion:

- byte-exact match between generated `.rgba` and committed `.golden.rgba`

The comparison harness remains oracle-agnostic:

- it compares `actual` to `expected`
- it does not know how the expected file was generated

eggvance is part of the golden-generation workflow, not part of the test execution path.

## Design 3: Implementation Boundaries

### `src/build_cmd.zig`

Responsibilities:

- parse build-time output configuration
- thread output mode and instruction-cap policy into codegen/runtime
- keep acceptance tests for real ROMs

Non-responsibilities:

- no pixel walking
- no palette decode
- no GBA display-mode logic

### `src/llvm_codegen.zig`

Responsibilities:

- add `OutputMode.frame_raw`
- emit runtime seams for instruction-cap stopping and final-output dispatch
- wire `%GuestState` and GBA runtime helpers together

Non-responsibilities:

- no inline Mode 4 renderer implementation

### `src/gba_ppu.zig`

This new module owns GBA frame-dump semantics.

Responsibilities:

- read `DISPCNT`
- validate video mode support
- select active Mode 4 page
- decode BG palette entries
- walk Mode 4 VRAM bytes
- produce raw `RGBA8` output

Slice 1 scope is Mode 4 only. Future graphics work can extend this module with additional modes rather than expanding CLI or build orchestration files.

### `src/machines/gba.zig`

Machine declarations remain declarative. Slice 1 may hardcode `frame_raw` support on the GBA path, but renderer implementation does not live here. The pattern remains the same as shim and instruction declarations: declarations describe capability, runtime modules implement it.

No declaration-schema change is part of this renderer slice.

### `src/frame_test_support.zig`

This new test-only helper module owns reusable framebuffer test helpers:

- raw-size validation
- pixel sampling helpers
- byte-exact frame comparison
- scratch artifact path helpers
- debug image conversion helpers

The purpose is to keep framebuffer-specific test logic out of `root.zig`.

## Non-Goals

- no tile or sprite compositor
- no Mode 3 or tile modes in slice 1
- no OBJ palette support in the Mode 4 path
- no scanline timing or mid-frame effects
- no frame-`N` dump support
- no committed PNG fixtures
- no eggvance dependency in the slice 1 test path
- no declaration-schema work

## Milestone Boundaries

### Slice 1 green criteria

- `hmncli` emits deterministic Mode 4 raw frame dumps for the three `ppu` ROMs
- real-ROM smoke tests pass
- failure mode for unsupported display modes is explicit
- human spot-check via derived PNG is possible

### Slice 2 green criteria

- committed `.golden.rgba` fixtures exist for the same ROM set
- tests compare actual output against goldens byte-for-byte
- smoke tests are replaced or reduced to helper-level unit tests

Implementation should stop after Slice 1 and wait for review before starting Slice 2.
