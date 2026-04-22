# Tonc Demo Ladder Design

## Milestone Shape

The next milestone is not "implement Mode 0" or "implement interrupts." It is "make specific tonc demos pass." The fixture is the stopping rule.

Scope:

- Mandatory demos: `sbb_reg`, `obj_demo`, `key_demo`
- Conditional demo: `irq_demo`
- `irq_demo` remains in scope only if fixture ingestion shows it builds cleanly and fits a minimal VBlank-only interrupt model
- If `irq_demo` violates that scope, it slips to a follow-on tonc slice with its reason for deferral recorded explicitly

Success criteria:

- Each mandatory demo has its own bring-up slice with a binary pass criterion
- Bring-up means the named demo builds, runs through `hmncli`, and passes sparse smoke assertions
- Smoke assertions are deliberately narrow:
  - not byte-exact goldens
  - not exhaustive pixel grids
  - not visual inspection alone
- After all bring-up slices are green, a separate parity slice adds oracle-backed goldens for the whole tonc set
- Kirby planning begins only after the tonc exit criteria are green

Corollary:

- Each system is implemented to exactly what the targeted demo requires, not to completeness
- If `sbb_reg` only needs one background configuration, that is what Mode 0 supports after this milestone
- Any non-required hardware variants fail structurally rather than being guessed at
- No bring-up slice lands in a known-partially-broken state; the smoke assertions either pass or the slice is not green

Why this shape:

- "Make `sbb_reg` pass" is falsifiable
- "Implement Mode 0" is not
- The demos are the scope lock, not just the test inputs

## Fixture Ingestion

The first tonc slice is fixture ingestion, not renderer work.

Outputs of this slice:

- committed ROM fixtures under `tests/fixtures/real/tonc/`
- `PROVENANCE.md` beside them
- `INGESTION.md` beside them
- `scripts/rebuild-tonc-fixtures.sh`
- a hash check that fails tests if the committed ROMs no longer match their recorded SHA-256 values

What gets pinned:

- `gbadev-org/libtonc-examples` commit SHA
- relevant submodule SHA(s), especially `libtonc`
- devkitARM version used to produce the committed ROMs
- exact build commands or a containerized rebuild recipe
- SHA-256 for each committed `.gba`
- ROM sizes for cheap sanity checking alongside hashes

Hash-check rule:

- Fixture verification fails at test time, not as a warning
- The failure message must tell the contributor to rebuild via `scripts/rebuild-tonc-fixtures.sh` and update provenance if the change is intentional
- A hash-mismatched fixture is never acceptable as an incidental diff

What gets measured during ingestion:

1. Build `sbb_reg`, `obj_demo`, `key_demo`, and `irq_demo` from the pinned source and toolchain.
2. Record which demos actually build cleanly.
3. Attempt to build each successful ROM through the current `hmncli build` path.
4. Record the first real failure surface for each demo in `INGESTION.md`.

Expected failure categories:

- unsupported opcode
- unsupported MMIO behavior
- missing renderer feature
- missing input-injection capability
- interrupt/runtime gap
- any other structured failure the current framework surfaces

Ingestion is expected-to-fail work. The failure is the measurement. If a demo already passes at ingestion time, that demo is not a milestone; it is already green.

What ingestion decides:

- Which demo fixtures are real, buildable inputs
- Whether `irq_demo` remains in scope for the first tonc milestone
- Which shared prerequisites block multiple demos
- The implementation order, which is derived from measured dependency minimization rather than assumed tutorial order

Ordering rule after ingestion:

- Start with the smallest additional surface implied by `INGESTION.md`
- If two demos share a subsystem, do the one that proves that subsystem with less extra complexity
- If multiple demos first fail on a shared non-graphics prerequisite, that prerequisite may land before the first named demo slice
- The named demo remains the binary pass criterion; prerequisite work only exists to make that criterion reachable

Why this slice exists:

- It turns the tonc milestone from anticipated work into measured work
- It locks the artifacts before implementation starts
- It prevents the spec from being shaped by memory or tutorial assumptions instead of actual ROM behavior

## Bring-Up Slices

After ingestion, the milestone becomes a sequence of demo-specific bring-up slices.

Per-demo shape:

- one slice per demo
- one binary success criterion per slice: the named demo passes its smoke assertions
- no partial-green commits
- no parity work in the same slice

Bring-up verification for each demo:

- build the committed ROM fixture with `hmncli build`
- run the produced native binary
- capture the output artifact the demo currently exposes
  - raw frame dump for visual demos
  - stdout or structured state if that is the simpler signal
- assert a small number of high-signal facts

Examples of acceptable bring-up assertions:

- `sbb_reg`: exact pixels that prove tile decode, palette decode, and screenblock placement are working
- `obj_demo`: exact pixels that prove the sprite is present in the expected position over the background
- `key_demo`: deterministic state after injected input at cap-time, not demo termination
- `irq_demo` if included: post-execution state only reachable through the interrupt-handler path, or a visible effect gated on handler execution

Input rule:

- `key_demo` requires deterministic input injection
- Input injection is a real runtime capability, not a test hack
- If the design of input injection turns out to be load-bearing, it becomes its own pre-slice rather than being absorbed silently into `key_demo`

System-scope rule during bring-up:

- Implement exactly what the targeted demo requires
- Anything outside that slice's demonstrated need fails structurally
- No "while we are here" expansion to adjacent hardware variants

Interrupt rule during bring-up:

- Interrupt assertions are existence-based, not timing-based
- The question is whether the handler ran, not whether exactly `N` vblanks fired
- Interrupts are checked and dispatched at explicit runtime synchronization points, not preemptively mid-basic-block
- Guest behavior that depends on mid-instruction interrupt delivery is outside this milestone's scope

Why this shape:

- It preserves the existing project discipline: named fixture, binary pass criterion, green checkpoint
- It keeps renderer/input/interrupt work localized instead of turning "graphics" into an open-ended subsystem project
- It gives Kirby a stack of already-green facts to build on later

## Parity Slice

After all bring-up slices are green, the next slice is oracle parity for the tonc set.

Scope of this slice:

- add oracle-backed raw frame goldens for every bring-up-green tonc demo
- add no new renderer, input, or interrupt features unless strictly required to make the oracle harness observable and deterministic

Pass criterion:

- each included demo produces byte-exact output matching its committed golden artifact
- failures produce scratch artifacts for investigation, not updated goldens

Artifact shape:

- committed raw frame goldens only, no PNGs in git
- per-demo goldens live beside the tonc fixtures
- provenance for goldens records:
  - which oracle produced them
  - exact command used
  - exact stop condition used during capture
  - hash of the golden artifact

Determinism rule:

- Golden capture must use a stop condition that produces the same guest-observable state on both oracle and homonculus
- Instruction-count stops are simplest
- Frame-count stops are valid only if both sides agree on what a frame is
- If oracle capture semantics do not align with Homonculi's, that alignment problem is part of oracle integration, not something to wave away in the parity slice

Harness rules:

- the comparison harness is oracle-agnostic
- tests compare `actual.rgba` to `expected.rgba`
- the oracle is used only to generate goldens, not to execute tests
- failures write scratch artifacts into a gitignored location
- tests must never write into committed golden paths
- goldens are regenerated only through a deliberate regeneration script

Oracle status:

- The oracle is not yet validated
- Eggvance is the preferred default because it is modern, open-source, and already part of the project's parity discussion
- If eggvance cannot produce deterministic raw-frame dumps in a scriptable way, the oracle choice is revisited deliberately
- Plausible alternatives include mGBA, NanoBoyAdvance, or another deterministic raw-frame source

Expected implementation order:

1. Validate oracle feasibility by measurement, not assumption.
2. If oracle integration is small, land it directly.
3. If oracle integration is substantial, split it into:
   - oracle integration
   - golden capture and test wiring
4. Commit goldens only after the harness is working and deterministic.

Golden process rule:

- A code change and a golden change do not land in the same commit
- Golden regeneration is always a separate reviewable commit explaining why the golden legitimately changed
- This keeps the golden a contract rather than a moving target that silently follows the code

Why this slice is separate:

- Bring-up answers whether the demo works at all
- Parity answers whether it matches a trusted implementation byte-for-byte
- Mixing them makes failures ambiguous and slows both kinds of work down

## Boundaries And Exit Criteria

Implementation boundaries:

- `tests/fixtures/real/tonc/` holds committed demo ROMs plus `PROVENANCE.md` and `INGESTION.md`
- rebuild and regeneration live in scripts, not in test execution
- smoke assertions live in shared test support, not in ad hoc demo-specific glue
- renderer semantics stay in the GBA runtime, not in CLI orchestration
- input injection, if needed, is a documented runtime contract

Minimal interrupt scope for this milestone:

- VBlank only
- single handler path
- IME, IE, and IF modeled as guest-visible registers
- no nesting
- no priority semantics
- no mid-basic-block preemption
- anything beyond that fails structurally until a later slice needs it

Non-goals for the tonc milestone:

- complete Mode 0 support
- affine sprites
- blending, windows, or mosaic unless a targeted demo requires them
- DMA, timer, HBlank, or serial interrupt work unless ingestion proves a mandatory demo cannot proceed without them
- commercial title work in parallel

Process rules:

- no code-plus-golden mixed commits
- no automatic golden regeneration during tests
- no partially-green bring-up checkpoints

Exit criteria for the tonc bring-up milestone:

- fixtures ingested with recorded provenance and enforced hash checks
- `sbb_reg`, `obj_demo`, and `key_demo` each have a green bring-up slice
- `irq_demo` is either green under the minimal interrupt model or explicitly deferred with a recorded reason
- every landed slice has a binary pass criterion and no known-partially-broken checkpoint

Exit criteria for the parity follow-up:

- oracle choice validated by measurement, not assumption
- deterministic capture contract defined on both sides
- committed raw goldens for every included tonc demo
- byte-exact parity tests green

What tonc hands forward:

- Kirby planning begins only after the tonc exit criteria are green
- Tonc exiting green does not mean the subsystems are complete
- It means the named demos pass and the remaining known gaps are documented
- Those findings are inputs to the Kirby spec and may reshape its scope without re-opening tonc itself
