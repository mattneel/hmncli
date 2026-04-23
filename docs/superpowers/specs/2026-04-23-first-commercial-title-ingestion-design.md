# First Commercial Title Ingestion Milestone Design

## Pre-Spec Findings

This spec is downstream of measured local probing, not upstream of planned ingestion. The three candidate ROMs were supplied locally by the developer, extracted only under `.zig-cache/local-commercial-roms/`, and probed through the current `hmncli build` path on 2026-04-23.

Measured findings:

- `Advance Wars (USA) (Rev 1)` is a 4 MiB GBA ROM with game code `AWRE`.
- Its first blocker is `Unsupported opcode 0xE12FFF11 at 0x080000E0 for armv4t`.
- The failing instruction is ARM `bx r1` after startup literal loading, with `r1` pointing at Thumb target `0x0807AD11`.

- `Kirby - Nightmare in Dream Land (USA)` is an 8 MiB GBA ROM with game code `A7KE`.
- Its first blocker is `Unsupported opcode 0xE12FFF11 at 0x080000EC for armv4t`.
- The failing instruction is the same ARM `bx r1` startup handoff class, with the first measured Thumb target at `0x08000311`.
- Kirby immediately contains a second instance of the same pattern at `0x080000F8`, this time targeting `0x08007301`.

- `Pokemon - Emerald Version (USA, Europe)` is a 16 MiB GBA ROM with game code `BPEE`.
- It does not reach guest decoding.
- Its first blocker is loader-level: `StreamTooLong` from the exact 16 MiB read limit in the current GBA loader.

Interpretation:

- Advance Wars and Kirby share the same first blocker class.
- The first commercial-title slice is therefore not "make Kirby pass" or "make Advance Wars pass."
- It is "support the measured ARM `bx r1` startup pattern observed in both commercial candidates."
- Emerald's blocker is real, but it is a framework-wide loader limit, not a commercial-title milestone concern.

Why these findings matter:

- The tonc ingestion rule applies again at the commercial boundary: if multiple candidates fail first on a shared prerequisite, the first slice is that prerequisite, not the named title.
- The framework should not pick a title-shaped stopping rule until the shared blocker is cleared and the next measured blockers are visible.

## Shared Prerequisite Slice

The next commercial-title slice is a measured shared-prerequisite slice.

Scope:

- support the observed ARM startup handoff pattern `ldr r1, [pc, ...]` -> `mov lr, pc` -> `bx r1`
- require the target to be an odd Thumb code pointer, as measured in the probes
- handle only the startup literal-target form actually observed in Advance Wars and Kirby
- keep the resolver narrow and provenance-based

Stopping rule:

- Advance Wars no longer fails first on `0xE12FFF11` at `0x080000E0`
- Kirby no longer fails first on `0xE12FFF11` at `0x080000EC`
- both titles are re-probed immediately after the slice lands
- the next first blocker for each title is recorded before any named-title milestone starts

Corollary:

- This slice is not "general ARM indirect branches"
- This slice is not "support all `bx r1`"
- This slice is not "commercial title bring-up"
- It is a measured startup-pattern expansion, no wider

Why this shape:

- it unlocks both commercial candidates at once
- it preserves the project's dependency-minimization rule
- it prevents the first commercial milestone from being chosen on recognizability instead of measured scope

## Named-Title Selection After The Shared Slice

The first named commercial title is selected only after the shared `bx r1` prerequisite slice is green and both candidates have been re-probed.

Selection rule:

- pick the title whose next blocker implies the smallest additional framework surface
- prefer simpler blockers over more recognizable titles
- prefer shorter authoring loops when blockers are otherwise comparable

Tie-breaker:

- if Advance Wars and Kirby expose similarly sized next blockers, prefer Advance Wars
- the reason is mechanical, not sentimental: 4 MiB ROM size is cheaper to rebuild and probe than 8 MiB

Expected immediate output of the shared slice:

- one updated probe note for Advance Wars
- one updated probe note for Kirby
- one explicit decision naming which title becomes the first commercial stopping rule

Likely first named-title stopping rule:

- not "playable"
- not "full boot"
- not "audio works"
- likely "builds and reaches a stable early visible frame" or equivalent measured checkpoint chosen after the re-probe

## Post Shared-Prerequisite Re-Probe

The post-slice re-probe was run locally against:

- `.zig-cache/local-commercial-roms/advance-wars.gba`
- `.zig-cache/local-commercial-roms/kirby-nightmare.gba`

Measured first meaningful blocker lines:

- Advance Wars: `Unsupported opcode 0x00004700 at 0x0803885E for armv4t`
- Kirby: `Unsupported SWI 0x00000B at 0x080CFA58 for gba`

Shared-slice result:

- the old shared startup blocker is cleared for both titles

Interpretation:

- Advance Wars blocker disassembly is Thumb `pop {r0}; bx r0` tail/return shape at `0x0803885C-0x0803885E`, which implies new control-flow modeling work
- at that re-probe point, Kirby blocker was BIOS `SWI 0x0B`, which fit the existing BIOS shim-expansion path; the then-supported SWIs were `SoftReset`, `VBlankIntrWait`, `Div`, and `Sqrt`

Decision:

- Kirby is the first named commercial stopping rule
- the reason is smaller next-blocker surface, not title preference

Current status after the completed Kirby `CpuSet` slice:

- `CpuSet` is now implemented in the public GBA shim surface
- Kirby's current first meaningful blocker is `Unsupported opcode 0x00004700 at 0x08001A2E for armv4t`
- the next commercial bring-up slice is therefore no longer BIOS-shim expansion by default; it is chosen from this new measured blocker

## Local-Only Commercial ROM Policy

Commercial ROM handling becomes an explicit project rule starting with this milestone.

Rules:

- commercial ROMs are never committed to the repository
- developer-supplied commercial ROMs may be extracted locally under `.zig-cache/local-commercial-roms/`
- commercial-title tests may only depend on local-only ROM paths
- if a required local ROM is absent, the test must skip with a clear message naming the expected local-only path and the relevant spec
- the open-source repository must remain buildable and testable without commercial ROMs present

Recording rule:

- specs, notes, and deferred-work records must describe commercial findings by measured opcode, address, and observed source pattern
- they should not depend on committed ROM bytes, hashes, or embedded content excerpts to remain useful
- the record must still make sense to a contributor who does not possess the ROM

Why this policy:

- it keeps the project legally and operationally clean
- it allows real commercial workloads to shape the framework without contaminating the repository
- it prevents "tests fail because you do not own this ROM" from becoming an undocumented trap

## Emerald Loader Limit

Pokemon Emerald is not part of the first commercial-title milestone.

Reason:

- its first blocker is not a guest startup pattern
- it is a framework-wide loader limit affecting exact 16 MiB GBA ROMs before guest decode begins

Scope decision:

- treat the Emerald `StreamTooLong` result as a small separate loader slice
- do not absorb that fix into the shared `bx r1` commercial startup slice
- fix it before Fire Red or any other 16 MiB commercial target is attempted

Implication:

- Emerald is recorded as a measured candidate probe, not a live milestone candidate
- its presence informs future loader work, not the next commercial-title checkpoint

## Boundaries And Exit Criteria

Process rules:

- this spec documents measured findings that already happened; it does not ask for another ingestion pass before work starts
- the next implementation slice is the shared ARM startup prerequisite, not a named-title bring-up
- no commercial-title work runs in parallel with unrelated loader expansion, Fire Red planning, or broad indirect-branch generalization

Standing regression invariant:

- all existing public tests remain green throughout the shared prerequisite slice and every later commercial-title slice
- tonc parity, synthetic VBlank, ppu fixtures, and prior real-ROM validation remain hard-stop regressions

Exit criteria for the shared commercial prerequisite slice:

- Advance Wars and Kirby both build past their current measured ARM `bx r1` startup blocker
- both titles are re-probed and their next first blockers are recorded
- one named title is selected as the first commercial stopping rule using the selection rule above
- Emerald remains explicitly out of scope for this milestone, with its loader limit recorded as separate follow-on work
- no commercial ROM is committed to the repository and the local-only ROM policy is preserved

Non-goals:

- making Kirby pass in the same slice
- making Advance Wars pass in the same slice
- fixing Emerald's 16 MiB loader limit in the same slice
- Fire Red or Emerald planning
- generic indirect-branch support beyond the measured startup pattern
- audio, save, decompression, or title-specific renderer work before the shared prerequisite is cleared
