# Minimal VBlank Interrupt Milestone Design

## Milestone Shape

The next milestone is not "implement interrupts" and it is not "make `irq_demo` pass." It is "make one minimal VBlank-only interrupt fixture pass." The fixture is the stopping rule.

Scope:

- VBlank only
- guest-visible `IME`, `IE`, and `IF`
- one handler path
- runtime-controlled interrupt dispatch at explicit frame boundaries
- no nesting
- no priority semantics
- no HBlank, VCount, timer, DMA, serial, or multi-source arbitration

Stopping rule:

- one committed fixture proves that a VBlank handler actually runs
- the fixture's post-handler observable state is correct
- already-green tonc parity remains byte-exact
- any interrupt feature outside this scope fails structurally rather than being approximated

Deferred explicitly:

- `irq_demo`
- HBlank and VCount interrupt sources
- nested interrupt re-enable
- interrupt priority switching
- simultaneous multi-source arbitration
- commercial-title work in parallel with this interrupt slice

Why this shape:

- "Make this VBlank-only fixture pass" is falsifiable
- "Implement interrupts" is not
- `irq_demo` is already known to force more than this milestone should carry
- the project keeps winning by shrinking the stopping rule until it is binary and local

## Fixture Discovery

The first slice of this milestone is fixture discovery, not interrupt implementation.

Goal:

- find the smallest real fixture that proves "VBlank handler runs" without widening scope past the minimal contract above

Process:

1. Scan `libtonc-examples` and adjacent published fixtures for a candidate that uses only:
   - `IME`
   - `IE` with VBlank only
   - `IF`
   - one handler path
   - no nested re-enable
   - no priority switching
2. Build the candidate fixture or fixtures from pinned source and toolchain.
3. Inspect the source, not just the observed ROM behavior.
4. If a published fixture fits cleanly, commit it as the stopping rule.
5. If no published fixture fits, fall back to one tiny synthetic VBlank ROM.

Source-inspection rule:

- a candidate is rejected if its source contains writes to `IE` with non-VBlank bits
- a candidate is rejected if its source installs or enables non-VBlank interrupt sources, even on dormant or conditional paths
- a candidate is rejected if different inputs or paths would activate out-of-scope interrupt behavior later
- the target fixture must be VBlank-only in code, not just VBlank-only in one observed run

Synthetic fallback minimum shape:

- install a VBlank handler
- enable VBlank through `IME` and `IE`
- enter a main loop that waits for handler-modified state
- exit or expose observable state only when the handler has run at least once
- the smoke assertion is existence-based: handler-modified state is present after execution

Outputs of discovery:

- either a pinned published VBlank-only fixture or a committed synthetic fallback
- provenance for the chosen fixture
- a short discovery note recording:
  - which candidates were checked
  - why each rejected candidate widened scope
  - what future interrupt surface each rejected candidate would naturally force later

Selection rule:

- prefer published over synthetic
- prefer smallest behavioral surface over recognizability
- reject any fixture that widens scope, even if it is otherwise convenient

Why this slice exists:

- it prevents the interrupt milestone from being shaped by `irq_demo`'s oversized surface
- it gives the milestone a binary stopping rule before runtime work begins
- it keeps "implement interrupts" from becoming another open-ended subsystem task

## Interrupt Model

Once fixture discovery picks the stopping rule, the milestone implements the minimal VBlank-only interrupt contract needed for that fixture.

Runtime model:

- VBlank is a synthetic runtime event
- a frame boundary occurs every `280896` retired guest instructions on GBA
- host wallclock is not involved in frame timing for this milestone
- at each frame boundary:
  - VBlank becomes pending in `IF`
  - if `IME` is enabled and `IE` has VBlank enabled, the handler path may run
- no interrupt dispatch occurs mid-basic-block or mid-instruction
- handler execution is whole-handler only, then guest control returns to interrupted code

Guest-visible state:

- `IME`, `IE`, and `IF` are modeled explicitly in `%GuestState`
- reads and writes behave consistently with the VBlank-only contract
- `IF` uses write-1-to-clear semantics for the VBlank bit
- reads from `IF` return the pending set visible to guest code

`VBlankIntrWait` rule:

- `VBlankIntrWait` and equivalent wait-for-interrupt paths are modeled as synchronous runtime operations
- they advance frame state to the next frame boundary
- they may dispatch the VBlank handler if enabled
- they then return to guest code
- they do not sleep, yield, or depend on host wallclock

Out-of-scope behavior and failure points:

- a write to `IE` enabling any non-VBlank source fails at the MMIO write
- a handler that re-enables `IME` while still inside the handler fails at that write
- any dispatch-time state with multiple pending interrupt sources fails at dispatch
- any attempt to depend on HBlank, VCount, timer, DMA, serial, priority, or nesting is rejected rather than approximated

Implementation boundary:

- event generation and dispatch policy live in the runtime and shim layer
- guest MMIO interrupt state remains explicit in `%GuestState`
- this milestone does not introduce a scanline scheduler
- this milestone does not introduce host-wallclock pacing
- this milestone does not widen `VBlankIntrWait` beyond what the chosen fixture proves necessary

Why this model:

- instruction-count frame timing is deterministic and golden-comparable
- frame-boundary dispatch matches the VBlank-only scope without dragging in scanline timing
- explicit failure points keep out-of-scope interrupt behavior honest

## Bring-Up And Verification

After fixture discovery and interrupt-model design are set, implementation proceeds as one bounded bring-up slice.

Bring-up sequence:

1. Add the chosen fixture plus provenance and discovery note.
2. Add failing tests for:
   - the fixture's handler-driven observable state
   - `IE` rejecting non-VBlank sources
   - `IME` re-enable inside a handler rejecting structurally
   - existing tonc parity remaining byte-exact
3. Verify those tests fail red against the current codebase.
4. Implement the minimal guest-visible `IME`/`IE`/`IF` state and frame-boundary VBlank dispatch.
5. Implement the minimal `VBlankIntrWait` behavior needed by the chosen fixture.
6. Re-run the fixture and the full existing tonc parity set.
7. Re-run `irq_demo` through the current pipeline and record its first blocker, whether it changed or not.

Test-first rule:

- tests are added in a committed-red state first
- the red state must be verified before implementation starts
- a test that lands already green is suspect and must be investigated before the slice proceeds

Verification rules:

- interrupt assertions are existence-based, not timing-based
- the question is whether the handler ran and changed observable state
- no assertion of "exactly N VBlanks fired"
- no partially-correct interrupt behavior is accepted
- tonc parity regressions fail the milestone immediately

Expected artifacts:

- a new fixture under `tests/fixtures/...` with provenance
- new tests in the existing Zig harness
- updates to interrupt-related machine and runtime declarations
- an updated note recording why `irq_demo` is still deferred or what its next blocker became

Why this shape:

- it keeps the milestone to one behavioral fact: VBlank handlers can run under a deterministic minimal model
- it avoids folding "more accurate interrupts" into the same slice
- it preserves the one-way ratchet: new green fact added, old green facts preserved

## Boundaries And Exit Criteria

Process rules:

- test-first is mandatory for this milestone
- the first committed checkpoint is the chosen fixture plus failing interrupt tests
- no code-plus-golden mixed commits
- deferred fixtures such as `irq_demo` are re-measured at the end of each relevant slice and their first blocker is recorded explicitly

Implementation boundaries:

- fixture provenance and discovery notes live beside the chosen interrupt fixture
- interrupt tests live in the existing Zig harness, not shell scripts
- guest-visible interrupt state lives explicitly in `%GuestState`
- frame-boundary event generation and dispatch policy live in the runtime and shim layer
- `VBlankIntrWait` remains a synchronous runtime operation, not a host sleep or event loop
- no scanline scheduler, no host-wallclock pacing, no generalized interrupt arbiter in this milestone

Standing regression invariant:

- `sbb_reg`, `obj_demo`, and `key_demo` parity remain byte-exact throughout this milestone and every later milestone
- this invariant is enforced by the full parity suite in `zig build test`
- no parity fixture is skipped or xfailed
- a regression in any already-green fixture is a hard stop, not an acceptable trade

Exit criteria for the minimal VBlank milestone:

- fixture discovery is complete and the stopping-rule fixture is pinned with provenance
- the fixture's handler-driven observable state is green under the minimal VBlank-only model
- `IME`, `IE`, and `IF` behavior required by that fixture are green
- out-of-scope interrupt features fail structurally at the earliest provable point
- existing tonc parity remains byte-exact
- `irq_demo` has been re-measured and its current first blocker is recorded, even if it remains deferred

Non-goals:

- making `irq_demo` pass
- HBlank, VCount, timer, DMA, serial, or nested interrupts
- interrupt priority semantics
- wallclock-driven frame pacing
- commercial-title work in parallel with this interrupt slice
