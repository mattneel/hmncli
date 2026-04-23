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
