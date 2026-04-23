# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: now builds through the measured local `bx r3` frontiers
- `obj_demo`: now builds through the measured local `bx` veneer frontiers
- `key_demo`: now builds through the measured local `bx r3` frontiers
- `irq_demo`: now stops at `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## First Homonculi Failure Surface

- Re-measured after the exact local Thumb veneer slices on 2026-04-22.
- The shared Thumb zero-shift `movs` alias blocker is gone.
- The measured local `bx` veneer blockers are gone in `sbb_reg`, `obj_demo`, and `key_demo`.
- The fixtures now diverge on their next blockers:
  - `sbb_reg`: bring-up green at the measured `frame_raw` stop of `500000` retired guest instructions
  - `obj_demo`: bring-up green at the measured `frame_raw` stop of `500000` retired guest instructions
  - `key_demo`: bring-up green at the measured held-input `frame_raw` stop of `500000` retired guest instructions
  - `irq_demo`: `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source still uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
