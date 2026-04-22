# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: now stops at `Unsupported opcode 0x00004700 at 0x080004E8 for armv4t`
- `obj_demo`: still stops at `Unsupported opcode 0x00004718 at 0x080003B8 for armv4t`
- `key_demo`: now stops at `Unsupported opcode 0x00004718 at 0x0800081C for armv4t`
- `irq_demo`: now stops at `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## First Homonculi Failure Surface

- Re-measured after the narrow `thumb_saved_lr_return` multi-save expansion on 2026-04-22.
- The shared Thumb zero-shift `movs` alias blocker is gone.
- The fixtures now diverge on their next blockers:
  - `sbb_reg`: `Unsupported opcode 0x00004700 at 0x080004E8 for armv4t`
  - `obj_demo`: `Unsupported opcode 0x00004718 at 0x080003B8 for armv4t`
  - `key_demo`: `Unsupported opcode 0x00004718 at 0x0800081C for armv4t`
  - `irq_demo`: `Unsupported opcode 0x00004718 at 0x08003078 for armv4t`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source still uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
