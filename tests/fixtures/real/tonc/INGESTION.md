# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: built cleanly from `basic/sbb_reg`
- `obj_demo`: built cleanly from `basic/obj_demo`
- `key_demo`: built cleanly from `basic/key_demo`
- `irq_demo`: built cleanly from `ext/irq_demo`

## First Homonculi Failure Surface

- Re-measured after the startup trampoline veneer fix on 2026-04-22.
- The shared `0x0800019A / 0x4718` blocker is gone.
- The fixtures now diverge on their next blockers:
  - `sbb_reg`: `Unsupported opcode 0x0000001E at 0x080003FA for armv4t`
  - `obj_demo`: `Unsupported opcode 0x00000000 at 0x080003A8 for armv4t`
  - `key_demo`: `Unsupported opcode 0x00000021 at 0x080002F6 for armv4t`
  - `irq_demo`: `Unsupported opcode 0x00000017 at 0x08000374 for armv4t`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
