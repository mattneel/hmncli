# Tonc Fixture Ingestion

## Build Status

- `sbb_reg`: built cleanly from `basic/sbb_reg`
- `obj_demo`: built cleanly from `basic/obj_demo`
- `key_demo`: built cleanly from `basic/key_demo`
- `irq_demo`: built cleanly from `ext/irq_demo`

## First Homonculi Failure Surface

- Re-measured after the startup trampoline fix and conditional startup-branch pruning on 2026-04-22.
- All four tonc demos now share the same next blocker:
  - `sbb_reg`: `Unsupported opcode 0x0000C901 at 0x080001A6 for armv4t`
  - `obj_demo`: `Unsupported opcode 0x0000C901 at 0x080001A6 for armv4t`
  - `key_demo`: `Unsupported opcode 0x0000C901 at 0x080001A6 for armv4t`
  - `irq_demo`: `Unsupported opcode 0x0000C901 at 0x080001A6 for armv4t`

## Scope Decisions

- `irq_demo` is deferred from the bring-up milestone.
- Reason: the current upstream source uses `II_HBLANK`, `II_VCOUNT`, nested interrupt enabling, and interrupt-priority switching, which exceeds the approved minimal VBlank-only interrupt model.
