# Machine Schema Checkpoint

## Keep

- `binary_format`: used by GBA, Xbox, and arcade
- `cpus`: used by all three; arcade proves multi-CPU fits the same shape
- `memory_regions`: used by all three
- `devices`: used by all three
- `entry`: used by all three
- `hle_surfaces`: used by all three
- `save_state`: used by all three

## Extension Points

- Xbox-specific XBE entry decoding details stay out of `Machine`; they belong in a later loader module
- GBA cartridge backup variations stay out of `Machine`; they can become per-machine extensions later
- Arcade inter-CPU mailboxes stay out of `Machine`; the base schema only needs named devices and regions

## Rework Trigger

- If the same concept requires different field shapes across machines, stop and redesign before adding pipeline code
- If only one machine uses a field, move it behind an extension record instead of baking it into the common shape
