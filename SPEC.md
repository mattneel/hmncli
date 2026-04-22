# Homonculi

A framework for ahead-of-time recompilation of guest binaries into native host executables, with High-Level Emulation of guest APIs. Point the CLI at a ROM, get a native program.

## Thesis

Emulators interpret. JIT recompilers translate at runtime. Homonculi does neither. Given a guest binary and a description of its machine, Homonculi produces a standalone native executable that *is* the guest program, rewritten in host code at build time, with guest OS/library/hardware APIs replaced by host-native implementations.

The output is not an emulator running a ROM. It is a program compiled from a ROM. The distinction matters: the output has no emulator overhead, no interpreter loop, no hot-path dispatch. It runs at native speed because it *is* native code.

Each output binary is a **homonculus** — a small artificial creation shaped in the image of the original, living independently of the workshop that made it. The framework is plural because its purpose is to produce many.

## Prior art and motivation

Homonculi's direct ancestor is **zxbox**, an attempted Xbox Classic → x86_64 static recompiler with D3D8-via-DXVK graphics HLE, targeting Knights of the Old Republic. zxbox did not survive contact with real engineering. The architecture was not the problem. The *authoring loop* was the problem: contributors (human and agent) could not reliably answer questions like "which API should I implement next," "did my shim fire," "is my implementation correct," or "did I break something that used to work." Without closing that loop, progress on a project of this depth is impossible.

Homonculi inverts the priority. The framework's first deliverable is not a recompiler. It is the authoring environment that makes recompiler development tractable. The recompiler is built inside that environment, not alongside it.

## Non-goals

Homonculi is not:

- **An emulator.** There is no runtime interpreter. No JIT. No dynamic recompilation. Output is static native code.
- **A preservation tool.** MAME exists and has 25 years of driver work. Homonculi does not compete on historical accuracy or machine coverage for its own sake.
- **A general-purpose binary translator.** Homonculi targets fixed guests with known machine descriptions. It does not handle self-modifying code, runtime JITs, or open-ended desktop binary ecosystems. Wine, FEX, and Rosetta exist and do that job.
- **Cycle-accurate.** Timing synchronization happens at block or frame boundaries, not per-cycle. Guests that require mid-instruction bus timing are out of scope.
- **A fallback-friendly design.** If static analysis cannot fully lift a ROM, the build fails with a structured diagnostic. There is no interpreter to silently paper over gaps. This is a feature, not a limitation: it keeps the "native program" story honest and prevents the framework from becoming an emulator by accident.
- **A ROM distributor.** Homonculi accepts a ROM path and produces a binary. It does not ship, download, or care about the provenance of ROMs. Users supply their own.

## Principles

Homonculi follows Tiger Style. The parts most load-bearing for this project specifically:

- **Safety first, then performance, then developer experience.**
- **Static allocation.** Guest address space is one fixed allocation at startup. No growth, no late allocation, no hidden malloc in hot paths.
- **Assertions everywhere, especially at boundaries.** Every guest↔shim crossing asserts calling-convention invariants (stack alignment, register preservation, shadow space, endianness). These catch ABI drift at the moment it occurs, not fifty milliseconds later when the bad value causes a crash somewhere unrelated.
- **70-line function limit.** Hard cap.
- **No hidden control flow.** Recompiled guest functions are plain Zig functions taking `*GuestContext`. No exceptions. No setjmp. No coroutines unless explicitly modeling a guest feature that requires them.
- **Explicit over implicit.** Machine descriptions are data. Shims are declared. Instructions are declared. "Not yet implemented" is a first-class state, not a panic.

Project-specific corollaries:

- **Comptime is the spine.** Machine descriptions are comptime data. Shim declarations are comptime data. The framework monomorphizes per-machine so the output pays for exactly what that machine uses, not for configurability.
- **Failure is structured, never silent.** Unknown opcodes, unimplemented shims, unresolved indirect branches — each is a typed, queryable, diagnostic-producing event. The framework never guesses when it doesn't know.

## Architecture

The pipeline, at a glance:

```
ROM + machine description → loader → disassembler → lifter → LLVM IR → LLVM passes → LLVM codegen → linker → homonculus
                                                       ↓
                                             HLE shim declarations (comptime)
                                                       ↓
                                         direct-call substitution at lift time
```

The stages:

1. **Loader.** Parses the guest's binary format (GBA ROM header, XBE, ELF, PE, raw binary + entry point). Produces a structured representation of sections, entry points, and initial memory layout.
2. **Disassembler.** Capstone handles decoding for supported ISAs. Homonculi's wrapper turns Capstone output into the framework's own instruction records with provenance (which address, discovered how, what confidence).
3. **Lifter.** Per-ISA. Translates decoded instructions directly into LLVM IR with conventions (guest registers in a fixed struct, flags as named SSA values, guest memory accessed through a small set of helper intrinsics). Every opcode is a declared entry; unknown opcodes are structured failures. HLE-marked call sites are replaced with direct shim invocations, not trampolines.
4. **Optimization.** LLVM's standard optimization passes plus optional Homonculi-specific passes attached to the pipeline (e.g., guest-flag elision based on convention recognition, ROM-constant propagation via metadata, dead-code elimination of unreached guest functions).
5. **Codegen.** LLVM lowers IR to the target triple specified on the command line. Every host LLVM supports is available via `--target`.
6. **Linker.** Combines LLVM-emitted object code, the Zig-written runtime (main loop, shim implementations, graphics/audio backends), and any per-machine glue into the final executable. Zig's build system drives the link.

### Dependencies

Homonculi accepts three load-bearing external dependencies:

- **Zig toolchain** — the host language, build system, and FFI surface.
- **Capstone** — decode for supported guest ISAs. Well-maintained, covers every realistic guest we care about, mature C API.
- **LLVM** (via [`llvm-zig`](https://github.com/kassane/llvm-zig)) — optimization and host codegen. Accepted despite Tiger Style's zero-dependency preference because the alternative (writing a per-host backend for every target we want to support) is a larger project than Homonculi itself and would ship years later with worse codegen. The `@cImport` escape hatch is available for any LLVM C API surface `llvm-zig` doesn't cover.

All three dependencies are pinned via `build.zig.zon` and vendorable if any upstream disappears.

## Load-bearing abstractions

Four abstractions determine whether Homonculi succeeds. Each must be designed deliberately, documented thoroughly, and stable before dependent work begins.

### 1. Machine description

A single Zig source file per machine, exporting a `pub const machine` comptime value. Declares:

- Binary format and loader
- CPU cores (ISA, clock, entry-point rules)
- Memory map (regions, types, permissions)
- Devices and their address decoding
- HLE surfaces present on this machine
- Save-state layout

Three sample machine descriptions (GBA, Xbox, a hypothetical dual-CPU arcade board) should be drafted before the schema is committed. If all three look similar-shaped, the schema is good. If each needs bespoke fields, the schema needs another pass.

### 2. Shim declaration

Every HLE boundary entry is a declaration, not an implementation. A shim declaration specifies:

- Name (as known to the guest)
- Calling convention
- Argument and return types
- Side-effect classification
- Implementation body (if any)
- Unit tests (if any)
- Reference notes and source links
- Current state (declared / stubbed / implemented / verified)

From this declaration, comptime generates: the calling-convention adapter, the boundary trace wrapper, the coverage counter, the registry entry, the test harness scaffolding, the documentation stub. Contributors never write tracing code, never write marshaling code, never forget to register a shim. There is no unwrapped path from a guest call to a shim implementation.

This is the single highest-leverage abstraction in the framework. It is the authoring loop's foundation.

### 3. Instruction lifting declaration

Structurally identical to the shim declaration. Every guest opcode is declared with its ISA, encoding, semantic model, LLVM IR lowering rule, test vectors, and current state. Unknown opcodes encountered during lifting are structured diagnostics naming the opcode, the ISA, the address, and the likely cause. The framework always knows what it doesn't know.

Homonculi does not define a custom mid-level IR. Lifters emit LLVM IR directly, following documented conventions for representing guest state (register struct layout, flag-as-SSA-value naming, memory intrinsic signatures). This avoids the two-layer IR maintenance burden and gives lifted code immediate access to every LLVM analysis and pass. If guest-level analysis needs outgrow what LLVM metadata and conventions can cleanly express, a thin Homonculi layer can be added later as a typed view over LLVM IR — not up front.

### 4. Trace / event stream

A length-prefixed binary record format capturing guest-visible events: shim-called, shim-returned, block-entered (optional), memory-mapped-io-touched, interrupt-taken, frame-presented. One format, many tools. The tracer produces it, the replayer consumes it, the differ compares two of them, the coverage report summarizes it, the agent parses it.

Binary for speed, with a text-dump tool for human inspection. Schema declared in Zig comptime so all tools agree on the layout.

## The authoring loop

Homonculi's differentiator. The CLI exposes the loop directly:

- `hmncli build <rom> --machine <name> --target <triple> --gfx <backend>` — produce a homonculus.
- `hmncli status` — for the most recent run, report unimplemented shims hit (ranked by call count), unimplemented instructions encountered, unresolved indirect branches. Tells the contributor what to work on next.
- `hmncli trace <rom> [--shim <name>]` — run a homonculus and stream the event log, optionally filtered.
- `hmncli replay <trace-file>` — re-run a recorded session deterministically against a current build. Emit a new trace.
- `hmncli diff <trace-a> <trace-b>` — structural diff of two traces. First divergence is the change's effect.
- `hmncli test [--shim <name>] [--instruction <opcode>]` — run unit tests for a specific surface element, in isolation, without booting a full guest.
- `hmncli doc <shim-or-instruction>` — dump the reference material for a surface element, in terminal, ready for agent context.

The loop an agent or human runs:

1. `hmncli status` → pick highest-impact missing piece.
2. `hmncli doc <piece>` → read reference material, already in context.
3. Write declaration + implementation + tests.
4. `hmncli test --<piece>` → fast, isolated verification.
5. `hmncli replay <canonical-trace>` → regression check against known-good recording.
6. Commit. Return to step 1.

This loop closes in minutes, not hours. It closes on evidence, not vibes. It is as friendly to an agent with a bounded turn budget as it is to a human.

## Bootstrap phases

- **Phase 0 — Authoring environment only.** In scope: declaration types, comptime validation, three concrete machine descriptions, trace schema, and `hmncli doc`, `hmncli status`, `hmncli test`.
- **Phase 0 out of scope.** No loader, disassembler, Capstone, LLVM, lifter, codegen, linker, or `hmncli build`.
- **Phase 1 — First pipeline slice.** Begins only after the Phase 0 exit criteria are green.

## Milestone ladder

Each milestone is a falsifiable end-to-end state. No milestone is considered complete until the preceding ones stay green.

- **v0 — `arm.gba` passes.** GBA guest, x86_64-linux host, no graphics backend (framebuffer dump to PNG/stdout on exit). Capstone for ARM decode. Minimum viable lifter, codegen, runtime. One or two BIOS SWIs shimmed. The output binary runs natively, prints/writes the test ROM's pass result. Proves the entire pipeline works end-to-end on a trivial case.
- **v0.5 — `thumb.gba` passes.** Adds the Thumb decoder/lifter path and ARM↔Thumb mode transitions.
- **v1 — `jsmolka/gba-tests` full suite passes.** The lifter is demonstrably solid across the ARM7TDMI surface on realistic test programs. Memory and BIOS edge cases covered.
- **v1.5 — tonc demos render.** Adds the graphics subsystem at the tile/sprite level. Software rasterizer is fine at this stage; output via SDL2 window or framebuffer dump. VBlank interrupt dispatch. Basic MMIO.
- **v2 — a simple commercial GBA game boots to title screen.** Probably *Kirby: Nightmare in Dream Land* or equivalent. Proves Homonculi handles code it didn't control the structure of. HLE surface grows to cover what real games actually call.
- **v3 — Pokémon Fire Red playable.** North star for the GBA target. Demonstrates Homonculi handles a large, complex, beloved commercial ROM, including save RAM, RTC, and enough of the sound engine to not be mute.
- **v4+ — second guest machine.** Probably PS1 (MIPS R3000A) or revisit Xbox. Validates that the framework's abstractions generalize. Until this exists, the "framework" claim is provisional.

## v0 target in detail

**Guest:** Game Boy Advance. ARMv4T (ARM7TDMI). Little-endian, fixed-width, no segmentation, no FPU. Well-documented address space. Small ROM sizes. Rich existing test corpus. HLE surface (BIOS SWIs) is finite and well-specified.

**Host:** x86_64-linux. Framework produces a native ELF. Zig's cross-compilation will later enable x86_64-windows, aarch64-macos, etc., from the same codebase without per-host work.

**Graphics:** None yet. GBA VRAM is an emulated buffer dumped to PNG on exit, or to stdout as a checksum. Real graphics is v1.5.

**Audio:** None.

**Input:** None. Test ROMs don't need it.

**Test ROM:** `arm.gba` from the GBA homebrew community. Executes known ARM instructions and writes a structured pass/fail result. Golden output is known.

**Success criterion:** `hmncli build arm.gba --machine gba --target x86_64-linux -o arm-native && ./arm-native` produces output indicating the test ROM passed. Any unimplemented instruction or shim encountered during lifting fails the build with a structured diagnostic.

## Open questions

Pinned here so they don't fall out of context. Each needs a decision before the relevant machinery is committed.

- **Machine description: single Zig file exporting `pub const machine`, or multi-file convention?** Leaning single file for simplicity.
- **Shim declaration exact syntax.** Draft three or four concrete examples (trivial, buffer-marshaling, callback-taking, complex-error) before committing to the shape.
- **Shim linking strategy.** Object files (simple, opaque across boundary) or LLVM bitcode with LTO (cross-boundary inlining; hot shims like `Div` become free). Start with object files for v0; add bitcode path once the declaration shape is proven and build-time impact is measurable.
- **Trace event schema versioning.** Probably embed a schema hash in the file header; refuse mismatches rather than migrating.
- **Save state policy.** Per-machine layout declared in the machine description. Build-hash-stamped. Non-portable across builds. Stated policy, not a limitation.
- **Capstone allocation.** Capstone allocates internally, which cuts against static allocation. Acceptable at the decode boundary if we copy into our own static-layout instruction records and free immediately. Worth prototyping to confirm the overhead is bounded.
- **LLVM version pinning.** Pin to whatever version `llvm-zig` currently tracks, or pin to a specific LLVM major and only bump deliberately? The latter is safer for reproducibility; the former reduces maintenance. Decide once the first build works end-to-end and we know what surface area we actually use.
- **Target-specific IR passes.** LLVM's generic passes handle most optimization. Guest-specific passes (flag elision, ROM-constant propagation, guest-memory alias analysis) may be worth adding — but only when profiling shows they matter. Do not pre-optimize.
- **PC-as-destination and privileged state.** The `v0` checkpoint currently stays green with `PC` writes restricted to the modeled `BX LR` return path. Honest handling of `mov pc, rN`, `subs pc, pc, #N`, and related forms exposes `CPSR`/`SPSR` and banked-register semantics as a separate model-expansion pass. Until that pass exists, treat those forms as structured unsupported rather than silently approximating them. When `v0.5` (`thumb.gba`) work begins, re-verify `arm.gba` under honest `PC` handling.

## Terminology

- **Homonculi** — the project, always plural.
- **homonculus** — one output binary; a single crafted program.
- **hmncli** — the command-line tool, pronounced "homonculi."
- **machine** — a guest system description (CPUs, memory map, devices, HLE surfaces).
- **shim** — a single HLE boundary entry; one guest API function replaced by a host implementation.
- **lifter** — the per-ISA component that translates decoded guest instructions into LLVM IR following Homonculi's conventions.
- **guest** — the binary being recompiled and the machine it ran on.
- **host** — the target the homonculus is built for.

## License

TBD.
