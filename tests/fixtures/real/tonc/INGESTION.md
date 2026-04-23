# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: now builds through the measured local `bx r3` frontiers
- `obj_demo`: now stops at `Unsupported opcode 0x00004718 at 0x080003B8 for armv4t`
- `key_demo`: now builds through the measured local `bx r3` frontiers
- `irq_demo`: now stops at `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## First Homonculi Failure Surface

- Re-measured after the exact local Thumb `blx r3` veneer slices on 2026-04-22.
- The shared Thumb zero-shift `movs` alias blocker is gone.
- The exact local `bx r3` veneer blockers are gone in `sbb_reg` and `key_demo`.
- The fixtures now diverge on their next blockers:
  - `sbb_reg`: no remaining build-time blocker in this ledger; bring-up now depends on smoke validation rather than control-flow clearing
  - `obj_demo`: `Unsupported opcode 0x00004718 at 0x080003B8 for armv4t`
  - `key_demo`: no remaining build-time blocker in this ledger; bring-up now depends on deterministic input plus smoke validation
  - `irq_demo`: `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source still uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
