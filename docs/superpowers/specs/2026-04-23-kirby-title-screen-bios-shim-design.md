# Kirby Title-Screen BIOS Shim Milestone Design

## Milestone Shape

The next commercial milestone is not "make Kirby work" and it is not "implement the BIOS." It is "make Kirby become the first named commercial title with a title-screen parity target." The title screen is the stopping rule.

Overall stopping rule:

- Kirby reaches a deterministic title-screen capture point under `hmncli`
- that capture point renders with byte-exact `frame_raw` parity against the pinned local mGBA oracle
- existing public fixtures remain green throughout
- gameplay, post-title content, audio correctness, and save behavior remain out of scope

Immediate next slice:

- the first bring-up slice no longer fails first on `Unsupported SWI 0x00000B at 0x080CFA58 for gba`
- the next first blocker is re-measured and recorded before any further Kirby scope is chosen

Why this shape:

- title-screen parity is a binary commercial milestone
- at slice start, Kirby's frontier was BIOS shim work, which compounds across future ROMs
- "make Kirby pass" is not falsifiable, but "make Kirby title-screen parity green" is
- at slice start, the first bring-up slice could stay small by targeting the initial `SWI 0x0B` blocker only

## Measured Starting Point

This spec is downstream of the completed commercial startup shared-prerequisite slice and its post-slice re-probe.

Measured facts:

- the local-only ROM under test is `.zig-cache/local-commercial-roms/kirby-nightmare.gba`
- Kirby's startup `bx r1` handoff blocker is cleared
- Kirby's initial measured blocker for this slice was `Unsupported SWI 0x00000B at 0x080CFA58 for gba`
- the blocker sits inside the BIOS trampoline block around `0x080CFA50-0x080CFA5A`
- currently supported SWIs already include `SoftReset`, `VBlankIntrWait`, `Div`, and `Sqrt`

Interpretation:

- that initial `SWI 0x0B` blocker is `CpuSet`
- the next framework investment is therefore not more indirect-branch modeling
- it is the first non-trivial BIOS memory shim on the commercial path

Why Kirby wins over Advance Wars:

- Advance Wars now fails on `Unsupported opcode 0x00004700 at 0x0803885E for armv4t`
- that is new Thumb indirect-control-flow modeling work (`pop {r0}; bx r0`)
- Kirby instead asks for BIOS shim expansion, which has broader reuse across commercial GBA titles
- the smaller next-blocker surface is therefore Kirby, even though Advance Wars has the smaller ROM

## Bring-Up Shape

Kirby bring-up follows the same pattern tonc used successfully: bring-up first, parity second, one measured blocker at a time.

Bring-up rule:

- each bring-up slice targets exactly one measured first blocker
- each slice ends by re-probing Kirby and recording the next first blocker
- no slice speculates ahead into "implement the BIOS" or "implement all startup shims"

The first bring-up slice was `CpuSet`.

Stopping rule for the `CpuSet` slice:

- Kirby no longer fails first on `Unsupported SWI 0x00000B at 0x080CFA58 for gba`
- the next first blocker is recorded from a fresh local re-probe
- no unrelated SWI or title-specific renderer work is absorbed into the same slice

Expected shape after `CpuSet`:

- Kirby may progress to another BIOS SWI such as `CpuFastSet` or one of the decompression calls
- Kirby may progress to a title-specific data or rendering blocker
- whichever one appears first becomes the next slice; nothing is pre-selected in advance

Why one blocker at a time:

- BIOS shim work compounds, but the measured next blocker still decides the order
- per-blocker slices keep the commercial path falsifiable and bisectable
- this prevents the commercial milestone from becoming "implement enough of the BIOS and hope"

## CpuSet Slice

`CpuSet` is not just "one more SWI." It is the first commercial BIOS shim that materially exercises host-side memory work over guest-visible regions.

The `CpuSet` slice must prove three things:

- the shim declaration system can express a real memory-touching BIOS call cleanly
- the runtime can read and write guest memory correctly from host-side shim code
- the call is not so expensive in practice that it forces the deferred bitcode/LTO question immediately

Minimum `CpuSet` scope:

- enough argument marshaling to support the measured Kirby call sites
- enough control-word handling to distinguish copy vs. fill and the measured transfer size semantics Kirby actually uses
- correct guest-memory reads and writes through the existing emulated memory regions
- structured failure for unsupported `CpuSet` modes that Kirby has not yet proven necessary

Measurement rule:

- the `CpuSet` slice records a local-only performance note for Kirby startup/title bring-up
- the note is observational, not a published benchmark
- only if `CpuSet` clearly dominates startup progress does the bitcode+LTO open question become urgent

Non-rule:

- this slice does not need to solve BIOS-shim performance in the abstract
- it only needs enough evidence to decide whether performance is already a blocker on the Kirby path

## Title-Screen Parity

Title-screen parity is a second phase, not part of the initial `CpuSet` slice.

Why it is separate:

- at `CpuSet` slice start, Kirby's blocker was still bring-up, not image parity
- the title screen is animated, so parity requires a measured deterministic capture point
- commercial ROM policy means parity cannot use the same committed-golden shape as tonc

Parity rule:

- once bring-up first reaches the title screen visually, measure a deterministic capture point using the existing instruction-cap and frame-boundary model
- record that capture point explicitly in the Kirby spec or follow-on plan
- compare `hmncli` `frame_raw` output against a local-only mGBA oracle capture at the same measured capture point

Commercial parity artifact rule:

- no Kirby ROM bytes are committed
- no committed Kirby `.rgba` goldens are added to the repository
- parity remains local-only, generated from the developer-supplied ROM and the pinned local mGBA oracle
- failures may emit scratch artifacts (`actual.rgba`, optional diff image) outside version control

Title-screen milestone stopping rule:

- Kirby reaches the agreed deterministic title-screen capture point
- the resulting frame matches mGBA byte-for-byte
- the local-only parity workflow is documented and reproducible for developers who have the ROM

## Boundaries And Exit Criteria

Process rules:

- the current measured blocker decides the next slice
- code and parity artifacts do not land in the same commit
- every Kirby-adjacent slice re-runs the standing public regression suite
- every Kirby bring-up slice ends with a fresh local re-probe and recorded next blocker

Standing regression invariant:

- all existing `226/226` tests remain green throughout Kirby work
- tonc parity, synthetic VBlank, ppu fixtures, and prior real-ROM validation remain hard-stop regressions

Local-only rule:

- Kirby remains a developer-supplied local ROM only
- open-source clones without the ROM must remain buildable and testable
- any Kirby-specific automated checks must skip clearly when the local ROM is absent

Exit criteria for the overall Kirby title-screen milestone:

- Kirby is the named commercial target
- per-blocker bring-up slices have advanced Kirby to a deterministic title-screen capture point
- a local-only mGBA parity check exists for that capture point
- the title-screen frame matches the oracle byte-for-byte
- all public non-commercial tests remain green

Immediate non-goals:

- gameplay or first-level playability
- audio correctness or music timing
- save RAM behavior
- post-title demo mode
- Advance Wars work in parallel
- Emerald loader-limit work in parallel
- generic BIOS completion beyond measured Kirby blockers

## Post CpuSet Re-Probe

- the old blocker `Unsupported SWI 0x00000B at 0x080CFA58 for gba` is cleared on a fresh local re-probe of `.zig-cache/local-commercial-roms/kirby-nightmare.gba`
- the new first meaningful blocker line is `Unsupported opcode 0x00004700 at 0x08001A2E for armv4t`
- the optional local `CpuSet` performance note remains deferred because `.zig-cache/commercial-probes/kirby-cpuset-native` was not emitted and the frontier is still build-time, so the bitcode/LTO question is not newly urgent from this slice
- Kirby remains the named commercial target, and the next bring-up slice is chosen by the new measured blocker above rather than by pre-selecting later BIOS or parity work

## Post CpuFastSet Re-Probe

- the old blocker `Unsupported SWI 0x00000C at 0x080CFA54 for gba` is cleared on a fresh local re-probe of `.zig-cache/local-commercial-roms/kirby-nightmare.gba`
- the new first meaningful blocker line is `Unsupported opcode 0x00004708 at 0x080CFC34 for armv4t`
- the optional local `CpuFastSet` performance note remains deferred because `.zig-cache/commercial-probes/kirby-cpufastset-native` was not emitted and the frontier is still build-time, so the bitcode/LTO question is not newly urgent from this slice
- Kirby remains the named commercial target, and the next bring-up slice is chosen by the new measured blocker above rather than by pre-selecting later BIOS or parity work
