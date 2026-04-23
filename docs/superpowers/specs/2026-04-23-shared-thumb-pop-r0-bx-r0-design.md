# Shared Commercial `pop {r0}; bx r0` Slice Design

## Pre-Spec Findings

This spec is downstream of measured local re-probing that happened after the completed Kirby `CpuSet` slice. It is not planning a fresh discovery pass before work starts; it is recording the shared blocker that the latest probes already exposed.

Measured local probes:

- `Advance Wars (USA) (Rev 1)` now fails first on `Unsupported opcode 0x00004700 at 0x0803885E for armv4t`
- `Kirby - Nightmare in Dream Land (USA)` now fails first on `Unsupported opcode 0x00004700 at 0x08001A2E for armv4t`

Measured disassembly around those blockers:

- Advance Wars:
  - `0x0803885C: bc01       pop {r0}`
  - `0x0803885E: 4700       bx  r0`
- Kirby:
  - `0x08001A2C: bc01       pop {r0}`
  - `0x08001A2E: 4700       bx  r0`

Interpretation:

- both commercial candidates now fail on the same Thumb tail/return shape
- the next slice is therefore shared again, not Kirby-only
- the shape is narrower than "generic Thumb indirect branches" and narrower than "generic return modeling"

Why this matters:

- the same dependency-minimization rule that justified the earlier shared `bx r1` startup slice applies again here
- choosing a Kirby-only slice now would knowingly duplicate work on a blocker that is already measured as shared
- the framework should clear the exact shared blocker before it resumes any named-title stopping rule

## Shared Slice Shape

The next commercial slice is a measured shared-prerequisite slice for the exact Thumb tail/return pattern `pop {r0}; bx r0`.

Scope:

- support only the measured `pop {r0}; bx r0` shape observed in Advance Wars and Kirby
- require the `pop {r0}` to be immediately followed by `bx r0`
- treat the popped value as a code target and resolve it using the minimum additional provenance needed for the measured commercial sites
- keep the resolver narrow, explicit, and fail-closed outside the measured shape

Stopping rule:

- Advance Wars no longer fails first on `0x00004700` at `0x0803885E`
- Kirby no longer fails first on `0x00004700` at `0x08001A2E`
- both ROMs are re-probed immediately after the slice lands
- the next first meaningful blocker for each title is recorded before any further milestone choice is made

Corollary:

- this slice is not "support `bx r0`"
- this slice is not "support `pop {rx}; bx rx`"
- this slice is not "generic Thumb epilogues"
- this slice is not "make Kirby reach the title screen"

## Why Measured-Only

The user explicitly chose the measured-only option rather than broadening to a family like `pop {rx}; bx rx`.

That choice is correct here because:

- the exact measured pattern is already enough to unlock both titles
- broadening to `rx` would be speculation without a new forcing function
- indirect-branch work is open-ended; measured-only slices are what keeps it bounded
- when the next ROM or the next re-probe surfaces a different register or a different epilogue shape, that can become its own measured slice with its own evidence

The practical rule for this slice:

- prefer a structural rejection of unknown variants over a permissive resolver that silently accepts unmeasured shapes

## Relationship To Kirby

Kirby remains the first named commercial title for the overall title-screen milestone.

What changes here is implementation order, not the eventual named target:

- the Kirby title-screen milestone stays the long-range stopping rule
- named-title bring-up pauses while this shared prerequisite is cleared
- once the shared `pop {r0}; bx r0` slice is green, both titles are re-probed again
- after that re-probe, the project decides whether work returns to Kirby specifically or whether another shared prerequisite has appeared

This keeps the project honest:

- Kirby is still the title whose title-screen parity the framework is ultimately driving toward
- but the next actual implementation slice is still chosen by measured blocker reuse, not by title preference

## Local-Only Commercial Rule

This slice inherits the existing commercial-ROM policy already established by the commercial-ingestion and Kirby specs.

Practical consequences for this slice:

- no commercial ROM bytes are committed
- no public automated test depends on local commercial ROMs
- the canonical suite proves this slice with synthetic/public fixtures only
- the commercial ROMs are used only for local re-probes before and after the slice

Recording rule:

- the spec and follow-on notes must cite findings by opcode, address, and observed shape
- the record must remain useful to a contributor who does not possess either ROM

## Boundaries And Exit Criteria

Process rules:

- the first implementation slice is the exact shared `pop {r0}; bx r0` prerequisite, not named-title bring-up
- code changes and any future local-only parity artifacts do not land in the same commit
- both commercial titles are re-probed immediately after the slice, not later
- all public tests remain green throughout

Standing regression invariant:

- all existing public tests remain green throughout this slice
- tonc parity, synthetic VBlank, PPU fixtures, and the newly landed `CpuSet` coverage remain hard-stop regressions

Exit criteria:

- Advance Wars and Kirby both build past their current measured `0x00004700` blocker
- both titles are re-probed and their next first meaningful blocker lines are recorded
- the project explicitly decides whether the next slice is Kirby-only again or another shared prerequisite
- no commercial ROMs or commercial frame artifacts are committed

Non-goals:

- generic Thumb indirect-branch support
- `pop {rx}; bx rx` family support beyond `r0`
- generic return or epilogue modeling
- Kirby title-screen renderer or parity work in the same slice
- Advance Wars feature work beyond clearing the shared blocker
- Emerald or Fire Red work in parallel

## Post `pop {r0}; bx r0` Re-Probe

- the old shared `Unsupported opcode 0x00004700 ...` blocker is cleared in both Advance Wars and Kirby
- `Advance Wars (USA) (Rev 1)` now fails first on `Unsupported opcode 0x00004708 at 0x0807B450 for armv4t`
- `Kirby - Nightmare in Dream Land (USA)` now fails first on `Unsupported SWI 0x00000C at 0x080CFA54 for gba`
- the next slice decision returns to Kirby specifically because the two post-slice blockers diverge rather than exposing another shared prerequisite
