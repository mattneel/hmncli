# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: now stops at `Unsupported SWI 0x000005 at 0x08000820 for gba`
- `obj_demo`: still stops at `Unsupported opcode 0x00004718 at 0x080003B8 for armv4t`
- `key_demo`: still stops at `Unsupported SWI 0x000005 at 0x08000768 for gba`
- `irq_demo`: now stops at `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## First Homonculi Failure Surface

- Re-measured after the Thumb `movs` alias fix on 2026-04-22.
- The shared Thumb zero-shift `movs` alias blocker is gone.
- The fixtures now diverge on their next blockers:
  - `sbb_reg`: `Unsupported SWI 0x000005 at 0x08000820 for gba`
  - `obj_demo`: `Unsupported opcode 0x00004718 at 0x080003B8 for armv4t`
  - `key_demo`: `Unsupported SWI 0x000005 at 0x08000768 for gba`
  - `irq_demo`: `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
