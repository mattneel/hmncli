# Phase 0 Authoring Loop Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Homonculi's Phase 0 authoring environment: declaration types with comptime validation, three real machine descriptions that stress the schema, and declaration-backed `hmncli doc`, `hmncli status`, and `hmncli test`, with no loader/lifter/codegen work.

**Architecture:** Phase 0 stays entirely in a declarations-only world. `Machine`, `ShimDecl`, `InstructionDecl`, and `TraceEvent` live in focused Zig modules with tests beside them; real GBA, Xbox, and dual-CPU arcade examples exercise the schema; a small registry layer feeds CLI subcommands and synthetic trace fixtures. `build`, Capstone, LLVM, lifter, codegen, and emitted guest execution are explicitly deferred to Phase 1.

**Tech Stack:** Zig 0.17 dev toolchain, `std.testing`, comptime validation helpers, deterministic synthetic trace fixtures, small stdlib-based CLI parsing.

---

## Scope Guardrails

- In scope for Phase 0: declaration types, declaration metadata, comptime validation, synthetic trace parsing, real example machine declarations, real example shim/instruction declarations, `doc`, `status`, `test`, and an explicit phasing section in `SPEC.md`.
- Out of scope for Phase 0: `src/lifter/`, `src/codegen/`, Capstone, LLVM, loader/disassembler integration, emitted guest code, `hmncli build`, or any vertical slice that consumes a ROM.
- Phase 1 may only begin once Phase 0 can answer:
  - what declarations exist,
  - which ones are missing or stubbed,
  - how to read their docs,
  - how to run their isolated tests,
  - how the schema behaves across GBA, Xbox, and a second multi-CPU machine.

## File Structure

**Files:**
- Modify: `SPEC.md`
- Modify: `src/main.zig`
- Modify: `src/root.zig`
- Create: `src/cli/parse.zig`
- Create: `src/cli/doc.zig`
- Create: `src/cli/status.zig`
- Create: `src/cli/test.zig`
- Create: `src/decl/common.zig`
- Create: `src/decl/machine.zig`
- Create: `src/decl/shim.zig`
- Create: `src/decl/instruction.zig`
- Create: `src/trace/event.zig`
- Create: `src/trace/fixture.zig`
- Create: `src/catalog.zig`
- Create: `src/machines/gba.zig`
- Create: `src/machines/xbox.zig`
- Create: `src/machines/arcade_dualcpu.zig`
- Create: `tests/fixtures/phase0/gba-missing-div.tracebin`
- Create: `docs/schema-review/2026-04-21-machine-schema-checkpoint.md`

**Responsibilities:**
- `src/decl/common.zig`: shared declaration identifiers, states, effect flags, doc references, and small formatting helpers.
- `src/decl/machine.zig`: `Machine` schema, runtime validation used by tests, comptime validation used by real machine constants.
- `src/decl/shim.zig`: shim declaration schema, argument/return metadata, attached test vector support.
- `src/decl/instruction.zig`: instruction declaration schema, encoding metadata, semantic-model test vector support.
- `src/trace/event.zig`: binary trace header and event payload schema used by `status`.
- `src/trace/fixture.zig`: deterministic synthetic trace fixtures for tests and CLI smoke checks.
- `src/machines/*.zig`: the three concrete machine descriptions plus their real declaration arrays.
- `src/catalog.zig`: lookup and iteration across machines, shims, and instructions.
- `src/cli/*.zig`: command parsing plus the `doc`, `status`, and `test` command handlers.
- `docs/schema-review/...`: explicit keep / extension-point / rework checkpoint after the three-machine exercise.

## Phase Breakdown

## Phase 0: Authoring Environment
Duration: 2-4 days
Prerequisites: None

### Goals
- [ ] Phase 0 is explicit in `SPEC.md` and encoded in the CLI surface.
- [ ] `Machine`, `ShimDecl`, `InstructionDecl`, and `TraceEvent` exist as first-class types with tests.
- [ ] GBA, Xbox, and a hypothetical dual-CPU arcade board all compile against the same machine schema.
- [ ] `hmncli doc`, `hmncli test`, and `hmncli status` work against real declarations and synthetic traces.

### Tests Required
- [ ] Unit tests for all declaration schemas
- [ ] Validation tests for all three machine descriptions
- [ ] Encode/decode tests for binary trace records
- [ ] CLI tests for `doc`, `status`, and `test`

### Exit Criteria
- [ ] `zig build test` passes
- [ ] `zig build run -- doc shim/gba/Div` prints deterministic declaration docs
- [ ] `zig build run -- test --shim gba/Div` runs declaration-attached vectors without any pipeline code
- [ ] `zig build run -- status --trace <fixture>` ranks missing declarations from a synthetic trace fixture
- [ ] `docs/schema-review/2026-04-21-machine-schema-checkpoint.md` contains the keep / extension-point / rework decisions
- [ ] No files exist for lifter/codegen/Capstone/LLVM integration yet

### Phase 1 Entry Condition
- [ ] Only once all Phase 0 exit criteria are green may the repo add loader, disassembler, lifter, or codegen modules

### Task 1: Lock Phase 0 Into the Spec and CLI Surface

**Files:**
- Modify: `SPEC.md`
- Modify: `src/main.zig`
- Modify: `src/root.zig`
- Create: `src/cli/parse.zig`
- Test: `src/cli/parse.zig`

- [ ] **Step 1: Write the failing tests for the phase guardrail**

```zig
const std = @import("std");

pub const Command = union(enum) {
    doc: []const u8,
    status,
    test_decl: []const u8,
};

test "parse accepts declaration commands" {
    try std.testing.expectEqualDeep(
        Command{ .doc = "shim/gba/Div" },
        try parse(&.{"hmncli", "doc", "shim/gba/Div"}),
    );
    try std.testing.expectEqualDeep(
        Command{ .test_decl = "instruction/armv4t/mov_imm" },
        try parse(&.{"hmncli", "test", "--instruction", "armv4t/mov_imm"}),
    );
}

test "build command is explicitly deferred to phase 1" {
    try std.testing.expectError(
        error.DeferredToPhase1,
        parse(&.{"hmncli", "build", "arm.gba"}),
    );
}
```

- [ ] **Step 2: Run the parser test to verify it fails**

Run: `zig test src/cli/parse.zig`
Expected: FAIL with `use of undeclared identifier 'parse'` or equivalent missing implementation error.

- [ ] **Step 3: Write the minimal parser implementation and wire it into `main.zig`**

```zig
const std = @import("std");

pub const Command = union(enum) {
    doc: []const u8,
    status: ?[]const u8,
    test_shim: []const u8,
    test_instruction: []const u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len < 2) return error.InvalidCommand;
    if (std.mem.eql(u8, args[1], "build")) return error.DeferredToPhase1;
    if (std.mem.eql(u8, args[1], "doc") and args.len == 3) return .{ .doc = args[2] };
    if (std.mem.eql(u8, args[1], "status")) {
        if (args.len == 4 and std.mem.eql(u8, args[2], "--trace")) return .{ .status = args[3] };
        if (args.len == 2) return .{ .status = null };
    }
    if (std.mem.eql(u8, args[1], "test") and args.len == 4 and std.mem.eql(u8, args[2], "--shim")) {
        return .{ .test_shim = args[3] };
    }
    if (std.mem.eql(u8, args[1], "test") and args.len == 4 and std.mem.eql(u8, args[2], "--instruction")) {
        return .{ .test_instruction = args[3] };
    }
    return error.InvalidCommand;
}
```

```zig
const cli_parse = @import("cli/parse.zig");

pub const cli = struct {
    pub const parse = cli_parse.parse;
    pub const Command = cli_parse.Command;
};
```

```zig
const parse = @import("cli/parse.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    _ = try parse.parse(args);
    return;
}
```

- [ ] **Step 4: Run the parser tests to verify they pass**

Run: `zig test src/cli/parse.zig && zig build test`
Expected: PASS for the parser tests and the existing package tests.

- [ ] **Step 5: Add an explicit phasing section to `SPEC.md`**

```md
## Bootstrap Phases

- **Phase 0 — Authoring environment only.** In scope: declaration types, comptime validation, three concrete machine descriptions, trace schema, and `hmncli doc`, `hmncli status`, `hmncli test`.
- **Phase 0 out of scope.** No loader, disassembler, Capstone, LLVM, lifter, codegen, linker, or `hmncli build`.
- **Phase 1 — First pipeline slice.** Begins only after Phase 0 exit criteria are green.
```

- [ ] **Step 6: Commit**

```bash
git add SPEC.md src/main.zig src/root.zig src/cli/parse.zig
git commit -m "docs(spec): lock phase 0 authoring-loop scope"
```

### Task 2: Define Shared Declaration Vocabulary and Machine Schema

**Files:**
- Create: `src/decl/common.zig`
- Create: `src/decl/machine.zig`
- Modify: `src/root.zig`
- Test: `src/decl/common.zig`
- Test: `src/decl/machine.zig`

- [ ] **Step 1: Write the failing declaration schema tests**

```zig
const std = @import("std");
const common = @import("common.zig");

test "decl id parses kind namespace and name" {
    const id = try common.DeclId.parse("shim/gba/Div");
    try std.testing.expectEqual(common.DeclKind.shim, id.kind);
    try std.testing.expectEqualStrings("gba", id.namespace);
    try std.testing.expectEqualStrings("Div", id.name);
}
```

```zig
const std = @import("std");
const machine_mod = @import("machine.zig");

test "machine validation rejects duplicate memory region names" {
    const duplicate = machine_mod.Machine{
        .name = "broken",
        .binary_format = .raw_blob,
        .cpus = &.{.{ .name = "main", .isa = .armv4t, .clock_hz = 16_777_216 }},
        .memory_regions = &.{
            .{ .name = "ram", .start = 0x0000, .size = 0x1000, .kind = .ram, .permissions = .read_write },
            .{ .name = "ram", .start = 0x1000, .size = 0x1000, .kind = .ram, .permissions = .read_write },
        },
        .devices = &.{},
        .entry = .reset_vector,
        .hle_surfaces = &.{},
        .save_state = .{ .components = &.{"cpu", "ram"} },
    };
    try std.testing.expectError(error.DuplicateRegionName, machine_mod.validate(duplicate));
}
```

- [ ] **Step 2: Run the declaration schema tests to verify they fail**

Run: `zig test src/decl/common.zig && zig test src/decl/machine.zig`
Expected: FAIL because the modules and types do not exist yet.

- [ ] **Step 3: Write the minimal shared vocabulary and machine schema**

```zig
pub const DeclKind = enum { machine, shim, instruction };

pub const DeclId = struct {
    kind: DeclKind,
    namespace: []const u8,
    name: []const u8,

    pub fn parse(input: []const u8) !DeclId {
        var it = std.mem.splitScalar(u8, input, '/');
        const kind_text = it.next() orelse return error.InvalidDeclId;
        const namespace = it.next() orelse return error.InvalidDeclId;
        const name = it.next() orelse return error.InvalidDeclId;
        if (it.next() != null) return error.InvalidDeclId;
        return .{
            .kind = std.meta.stringToEnum(DeclKind, kind_text) orelse return error.InvalidDeclId,
            .namespace = namespace,
            .name = name,
        };
    }

    pub fn mustParse(comptime input: []const u8) DeclId {
        return parse(input) catch @compileError("invalid declaration id: " ++ input);
    }
};

pub const DeclState = enum {
    declared,
    stubbed,
    implemented,
    verified,
};

pub const DocRef = struct {
    label: []const u8,
    url: []const u8,
};
```

```zig
pub const Isa = enum {
    armv4t,
    x86_p3,
    m68k_68000,
    z80,
};

pub const Machine = struct {
    name: []const u8,
    binary_format: BinaryFormat,
    cpus: []const Cpu,
    memory_regions: []const MemoryRegion,
    devices: []const Device,
    entry: EntryRule,
    hle_surfaces: []const []const u8,
    save_state: SaveStateLayout,
};

pub fn validate(machine: Machine) !void {
    if (machine.cpus.len == 0) return error.MachineNeedsCpu;
    if (machine.memory_regions.len == 0) return error.MachineNeedsMemory;
    for (machine.memory_regions, 0..) |left, i| {
        for (machine.memory_regions[i + 1 ..]) |right| {
            if (std.mem.eql(u8, left.name, right.name)) return error.DuplicateRegionName;
        }
    }
}

pub fn validateComptime(comptime machine: Machine) void {
    validate(machine) catch |err| @compileError(@errorName(err));
}
```

- [ ] **Step 4: Export the declaration modules from `src/root.zig`**

```zig
pub const decl = struct {
    pub const common = @import("decl/common.zig");
    pub const machine = @import("decl/machine.zig");
};
```

- [ ] **Step 5: Run the declaration schema tests to verify they pass**

Run: `zig test src/decl/common.zig && zig test src/decl/machine.zig && zig build test`
Expected: PASS, with duplicate-region validation failing only in the targeted negative test.

- [ ] **Step 6: Commit**

```bash
git add src/root.zig src/decl/common.zig src/decl/machine.zig
git commit -m "feat(decl): add shared ids and machine schema"
```

### Task 3: Define Shim, Instruction, and Trace Event Declarations

**Files:**
- Create: `src/decl/shim.zig`
- Create: `src/decl/instruction.zig`
- Create: `src/trace/event.zig`
- Modify: `src/root.zig`
- Test: `src/decl/shim.zig`
- Test: `src/decl/instruction.zig`
- Test: `src/trace/event.zig`

- [ ] **Step 1: Write the failing schema tests**

```zig
const std = @import("std");
const shim_mod = @import("shim.zig");
const common = @import("common.zig");

test "shim test vectors are attached to the declaration" {
    const decl = shim_mod.ShimDecl{
        .id = common.DeclId.mustParse("shim/gba/Div"),
        .state = .verified,
        .args = &.{ .{ .name = "numerator", .ty = .i32 }, .{ .name = "denominator", .ty = .i32 } },
        .returns = .i32,
        .effects = .pure,
        .tests = &.{ .{ .name = "divides positive integers", .input = &.{10, 2}, .expected = 5 } },
        .doc_refs = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), decl.tests.len);
}
```

```zig
const std = @import("std");
const trace_mod = @import("../trace/event.zig");

test "trace encode decode roundtrip preserves shim-called payload" {
    const event = trace_mod.TraceEvent{
        .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000100 },
    };
    var buffer: [256]u8 = undefined;
    const used = try trace_mod.encodeOne(buffer[0..], event);
    const decoded = try trace_mod.decodeOne(buffer[0..used]);
    try std.testing.expectEqualDeep(event, decoded.event);
}
```

- [ ] **Step 2: Run the schema tests to verify they fail**

Run: `zig test src/decl/shim.zig && zig test src/decl/instruction.zig && zig test src/trace/event.zig`
Expected: FAIL because the modules do not exist.

- [ ] **Step 3: Write the minimal shim, instruction, and trace schemas**

```zig
pub const ShimValueType = enum { i32, u32, guest_ptr, void };
pub const ShimEffect = enum { pure, memory_read, memory_write, device_io };

pub const ShimTestCase = struct {
    name: []const u8,
    input: []const i32,
    expected: i32,
};

pub const ShimDecl = struct {
    id: common.DeclId,
    state: common.DeclState,
    args: []const Argument,
    returns: ShimValueType,
    effects: ShimEffect,
    tests: []const ShimTestCase,
    doc_refs: []const common.DocRef,
    notes: []const []const u8,
};
```

```zig
pub const EncodingKind = enum { fixed32, variable_x86, fixed16 };

pub const InstructionTestCase = struct {
    name: []const u8,
    input: []const u32,
    expected: []const u32,
};

pub const InstructionDecl = struct {
    id: common.DeclId,
    isa: machine_mod.Isa,
    mnemonic: []const u8,
    encoding: EncodingKind,
    state: common.DeclState,
    tests: []const InstructionTestCase,
    doc_refs: []const common.DocRef,
    notes: []const []const u8,
};
```

```zig
pub const TraceEvent = union(enum) {
    shim_called: struct { shim: []const u8, pc: u32 },
    shim_returned: struct { shim: []const u8, pc: u32 },
    instruction_missing: struct { instruction: []const u8, pc: u32 },
    unresolved_indirect_branch: struct { pc: u32, target_register: []const u8 },
};
```

- [ ] **Step 4: Add binary encode/decode helpers for one-record-at-a-time parsing**

```zig
pub fn encodeOne(buffer: []u8, event: TraceEvent) !usize {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    try writer.writeByte(@intFromEnum(std.meta.activeTag(event)));
    switch (event) {
        .shim_called => |payload| {
            try writer.writeInt(u32, payload.pc, .little);
            try writer.writeByte(@intCast(payload.shim.len));
            try writer.writeAll(payload.shim);
        },
        else => return error.UnsupportedEventForPhase0,
    }
    return stream.pos;
}
```

- [ ] **Step 5: Run the schema tests to verify they pass**

Run: `zig test src/decl/shim.zig && zig test src/decl/instruction.zig && zig test src/trace/event.zig && zig build test`
Expected: PASS, including trace roundtrip.

- [ ] **Step 6: Commit**

```bash
git add src/root.zig src/decl/shim.zig src/decl/instruction.zig src/trace/event.zig
git commit -m "feat(decl): add shim instruction and trace schemas"
```

### Task 4: Draft the Three Concrete Machines and Write the Schema Checkpoint

**Files:**
- Create: `src/machines/gba.zig`
- Create: `src/machines/xbox.zig`
- Create: `src/machines/arcade_dualcpu.zig`
- Create: `docs/schema-review/2026-04-21-machine-schema-checkpoint.md`
- Modify: `src/root.zig`
- Test: `src/machines/gba.zig`
- Test: `src/machines/xbox.zig`
- Test: `src/machines/arcade_dualcpu.zig`

- [ ] **Step 1: Write the failing machine-validation tests**

```zig
const std = @import("std");
const machine_mod = @import("../decl/machine.zig");
const gba = @import("gba.zig");
const xbox = @import("xbox.zig");
const arcade = @import("arcade_dualcpu.zig");

test "all phase 0 machines validate against the shared schema" {
    try machine_mod.validate(gba.machine);
    try machine_mod.validate(xbox.machine);
    try machine_mod.validate(arcade.machine);
}

test "arcade example proves multi-cpu machines fit without bespoke fields" {
    try std.testing.expectEqual(@as(usize, 2), arcade.machine.cpus.len);
}
```

- [ ] **Step 2: Run the machine-validation tests to verify they fail**

Run: `zig test src/machines/gba.zig && zig test src/machines/xbox.zig && zig test src/machines/arcade_dualcpu.zig`
Expected: FAIL because the machine files do not exist yet.

- [ ] **Step 3: Write the three concrete machine descriptions**

```zig
pub const machine = machine_mod.Machine{
    .name = "gba",
    .binary_format = .gba_rom,
    .cpus = &.{.{ .name = "arm7tdmi", .isa = .armv4t, .clock_hz = 16_777_216 }},
    .memory_regions = &.{
        .{ .name = "bios", .start = 0x00000000, .size = 0x4000, .kind = .rom, .permissions = .read_only },
        .{ .name = "ewram", .start = 0x02000000, .size = 0x40000, .kind = .ram, .permissions = .read_write },
        .{ .name = "iwram", .start = 0x03000000, .size = 0x8000, .kind = .ram, .permissions = .read_write },
        .{ .name = "io", .start = 0x04000000, .size = 0x400, .kind = .mmio, .permissions = .read_write },
        .{ .name = "rom", .start = 0x08000000, .size = 0x2000000, .kind = .rom, .permissions = .read_only },
    },
    .devices = &.{.{ .name = "ppu", .kind = .graphics }, .{ .name = "apu", .kind = .audio }},
    .entry = .reset_vector,
    .hle_surfaces = &.{"bios_swi"},
    .save_state = .{ .components = &.{"cpu", "ewram", "iwram", "io"} },
};

comptime machine_mod.validateComptime(machine);
```

```zig
pub const machine = machine_mod.Machine{
    .name = "xbox",
    .binary_format = .xbe,
    .cpus = &.{.{ .name = "pentium3", .isa = .x86_p3, .clock_hz = 733_000_000 }},
    .memory_regions = &.{
        .{ .name = "title_ram", .start = 0x00010000, .size = 0x03ff0000, .kind = .ram, .permissions = .read_write_execute },
        .{ .name = "kernel_shared", .start = 0x80000000, .size = 0x04000000, .kind = .ram, .permissions = .read_write },
        .{ .name = "nv2a_mmio", .start = 0xf0000000, .size = 0x10000000, .kind = .mmio, .permissions = .read_write },
    },
    .devices = &.{.{ .name = "nv2a", .kind = .graphics }, .{ .name = "mcpx", .kind = .audio }},
    .entry = .image_header_entry,
    .hle_surfaces = &.{"xboxkrnl_exports", "nv2a_mmio"},
    .save_state = .{ .components = &.{"cpu", "ram", "kernel_shared"} },
};

comptime machine_mod.validateComptime(machine);
```

```zig
pub const machine = machine_mod.Machine{
    .name = "arcade_dualcpu",
    .binary_format = .raw_blob,
    .cpus = &.{
        .{ .name = "main68k", .isa = .m68k_68000, .clock_hz = 12_000_000 },
        .{ .name = "audioz80", .isa = .z80, .clock_hz = 4_000_000 },
    },
    .memory_regions = &.{
        .{ .name = "program_rom", .start = 0x000000, .size = 0x080000, .kind = .rom, .permissions = .read_only },
        .{ .name = "work_ram", .start = 0x100000, .size = 0x010000, .kind = .ram, .permissions = .read_write },
        .{ .name = "sound_latch", .start = 0x200000, .size = 0x000010, .kind = .mmio, .permissions = .read_write },
    },
    .devices = &.{.{ .name = "tile_renderer", .kind = .graphics }, .{ .name = "ym_sound", .kind = .audio }},
    .entry = .fixed_address,
    .hle_surfaces = &.{"service_calls", "sound_commands"},
    .save_state = .{ .components = &.{"main68k", "audioz80", "work_ram"} },
};

comptime machine_mod.validateComptime(machine);
```

- [ ] **Step 4: Write the schema checkpoint deliverable**

```md
# Machine Schema Checkpoint

## Keep

- `binary_format`: used by GBA, Xbox, and arcade
- `cpus`: used by all three; arcade proves multi-cpu fits the same shape
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
```

- [ ] **Step 5: Run the machine tests to verify they pass**

Run: `zig test src/machines/gba.zig && zig test src/machines/xbox.zig && zig test src/machines/arcade_dualcpu.zig && zig build test`
Expected: PASS for all three machine modules and the root suite.

- [ ] **Step 6: Commit**

```bash
git add src/root.zig src/machines/gba.zig src/machines/xbox.zig src/machines/arcade_dualcpu.zig docs/schema-review/2026-04-21-machine-schema-checkpoint.md
git commit -m "feat(machine): add phase 0 schema exercise"
```

### Task 5: Create a Registry Backed by Real Declarations

**Files:**
- Create: `src/catalog.zig`
- Modify: `src/machines/gba.zig`
- Modify: `src/machines/xbox.zig`
- Modify: `src/machines/arcade_dualcpu.zig`
- Modify: `src/root.zig`
- Test: `src/catalog.zig`

- [ ] **Step 1: Write the failing registry lookup tests**

```zig
const std = @import("std");
const catalog = @import("catalog.zig");

test "catalog looks up real phase 0 declarations" {
    const div_shim = try catalog.lookupShim("gba", "Div");
    try std.testing.expectEqualStrings("Div", div_shim.id.name);

    const mov = try catalog.lookupInstruction("armv4t", "mov_imm");
    try std.testing.expectEqualStrings("mov", mov.mnemonic);

    const xbox = try catalog.lookupMachine("xbox");
    try std.testing.expectEqualStrings("xbox", xbox.name);
}
```

- [ ] **Step 2: Run the registry tests to verify they fail**

Run: `zig test src/catalog.zig`
Expected: FAIL because the catalog and declaration arrays do not exist.

- [ ] **Step 3: Add real declaration arrays to the machine modules and register them**

```zig
pub const shims = &.{
    shim_mod.ShimDecl{
        .id = common.DeclId.mustParse("shim/gba/Div"),
        .state = .verified,
        .args = &.{ .{ .name = "numerator", .ty = .i32 }, .{ .name = "denominator", .ty = .i32 } },
        .returns = .i32,
        .effects = .pure,
        .tests = &.{
            .{ .name = "positive division", .input = &.{10, 2}, .expected = 5 },
            .{ .name = "negative division", .input = &.{-9, 3}, .expected = -3 },
        },
        .doc_refs = &.{ .{ .label = "GBATEK BIOS Div", .url = "https://problemkaputt.de/gbatek.htm#biosarithmeticfunctions" } },
        .notes = &.{"Pure arithmetic BIOS helper used as the first shim test surface."},
    },
};

pub const instructions = &.{
    instruction_mod.InstructionDecl{
        .id = common.DeclId.mustParse("instruction/armv4t/mov_imm"),
        .isa = .armv4t,
        .mnemonic = "mov",
        .encoding = .fixed32,
        .state = .verified,
        .tests = &.{ .{ .name = "writes immediate into destination register", .input = &.{0, 42}, .expected = &.{42} } },
        .doc_refs = &.{ .{ .label = "ARM ARM MOV immediate", .url = "https://developer.arm.com/documentation" } },
        .notes = &.{"Tiny instruction surface for phase 0 declaration-backed testing."},
    },
};
```

```zig
pub fn lookupShim(namespace: []const u8, name: []const u8) !shim_mod.ShimDecl {
    const module = try lookupMachineModule(namespace);
    for (module.shims) |decl| {
        if (std.mem.eql(u8, decl.id.name, name)) return decl;
    }
    return error.ShimNotFound;
}
```

- [ ] **Step 4: Run the registry tests to verify they pass**

Run: `zig test src/catalog.zig && zig build test`
Expected: PASS with real lookups for GBA, Xbox, and at least one arcade declaration.

- [ ] **Step 5: Commit**

```bash
git add src/catalog.zig src/root.zig src/machines/gba.zig src/machines/xbox.zig src/machines/arcade_dualcpu.zig
git commit -m "feat(catalog): register real phase 0 declarations"
```

### Task 6: Implement `hmncli doc` on Top of Real Declarations

**Files:**
- Create: `src/cli/doc.zig`
- Modify: `src/main.zig`
- Modify: `src/root.zig`
- Test: `src/cli/doc.zig`

- [ ] **Step 1: Write the failing `doc` command tests**

```zig
const std = @import("std");
const doc_cmd = @import("doc.zig");

test "doc renders shim declaration metadata deterministically" {
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try doc_cmd.render(stream.writer().any(), "shim/gba/Div");
    try std.testing.expectEqualStrings(
        \\ID: shim/gba/Div
        \\State: verified
        \\Effects: pure
        \\Reference: GBATEK BIOS Div
        \\
    ,
        stream.getWritten(),
    );
}
```

- [ ] **Step 2: Run the `doc` tests to verify they fail**

Run: `zig test src/cli/doc.zig`
Expected: FAIL because `render` does not exist.

- [ ] **Step 3: Write the minimal `doc` renderer and wire it through `main.zig`**

```zig
pub fn render(writer: anytype, decl_id_text: []const u8) !void {
    const decl_id = try common.DeclId.parse(decl_id_text);
    switch (decl_id.kind) {
        .shim => {
            const shim = try catalog.lookupShim(decl_id.namespace, decl_id.name);
            try writer.print("ID: {s}/{s}/{s}\n", .{ "shim", decl_id.namespace, decl_id.name });
            try writer.print("State: {s}\n", .{@tagName(shim.state)});
            try writer.print("Effects: {s}\n", .{@tagName(shim.effects)});
            for (shim.doc_refs) |ref| try writer.print("Reference: {s}\n", .{ref.label});
        },
        else => return error.UnsupportedDeclKindForPhase0,
    }
}
```

- [ ] **Step 4: Run the `doc` tests to verify they pass**

Run: `zig test src/cli/doc.zig && zig build run -- doc shim/gba/Div`
Expected: PASS in tests and CLI output containing the deterministic declaration summary.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/root.zig src/cli/doc.zig
git commit -m "feat(cli): add declaration doc command"
```

### Task 7: Implement `hmncli test` Using Declaration-Attached Vectors

**Files:**
- Create: `src/cli/test.zig`
- Modify: `src/machines/gba.zig`
- Modify: `src/catalog.zig`
- Modify: `src/main.zig`
- Test: `src/cli/test.zig`

- [ ] **Step 1: Write the failing `test` command tests**

```zig
const std = @import("std");
const test_cmd = @import("test.zig");

test "test command runs shim vectors for gba div" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try test_cmd.runShim(stream.writer().any(), "gba/Div");
    try std.testing.expectEqualStrings("PASS 2/2 shim tests for gba/Div\n", stream.getWritten());
}

test "test command runs instruction vectors for arm mov immediate" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try test_cmd.runInstruction(stream.writer().any(), "armv4t/mov_imm");
    try std.testing.expectEqualStrings("PASS 1/1 instruction tests for armv4t/mov_imm\n", stream.getWritten());
}
```

- [ ] **Step 2: Run the `test` command tests to verify they fail**

Run: `zig test src/cli/test.zig`
Expected: FAIL because the command handlers and attached execution helpers do not exist.

- [ ] **Step 3: Write the minimal declaration-backed runners**

```zig
fn evalGbaDiv(input: []const i32) i32 {
    return @divTrunc(input[0], input[1]);
}

pub fn runShim(writer: anytype, selector: []const u8) !void {
    const shim = try catalog.lookupShimBySelector(selector);
    var passed: usize = 0;
    for (shim.tests) |case| {
        const actual = evalGbaDiv(case.input);
        if (actual != case.expected) return error.ShimVectorFailed;
        passed += 1;
    }
    try writer.print("PASS {d}/{d} shim tests for {s}\n", .{ passed, shim.tests.len, selector });
}
```

```zig
fn evalArmMovImm(input: []const u32) [1]u32 {
    _ = input[0];
    return .{input[1]};
}
```

- [ ] **Step 4: Run the `test` command tests to verify they pass**

Run: `zig test src/cli/test.zig && zig build run -- test --shim gba/Div && zig build run -- test --instruction armv4t/mov_imm`
Expected: PASS for both the unit tests and the CLI smoke checks.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/catalog.zig src/machines/gba.zig src/cli/test.zig
git commit -m "feat(cli): add declaration-backed test command"
```

### Task 8: Implement `hmncli status` Using Synthetic Trace Fixtures

**Files:**
- Create: `src/trace/fixture.zig`
- Create: `src/cli/status.zig`
- Create: `tests/fixtures/phase0/gba-missing-div.tracebin`
- Modify: `src/main.zig`
- Modify: `src/root.zig`
- Test: `src/trace/fixture.zig`
- Test: `src/cli/status.zig`

- [ ] **Step 1: Write the failing synthetic trace and `status` tests**

```zig
const std = @import("std");
const fixture = @import("../trace/fixture.zig");
const status_cmd = @import("status.zig");

test "fixture emits missing declaration events for gba div" {
    const bytes = try fixture.gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
}

test "status ranks missing shims and instructions from a synthetic trace" {
    const bytes = try fixture.gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try status_cmd.render(stream.writer().any(), bytes);
    try std.testing.expectEqualStrings(
        \\Unimplemented shims:
        \\1. shim/gba/Div (3)
        \\Unimplemented instructions:
        \\1. instruction/armv4t/unknown_e7f001f0 (1)
        \\Unresolved indirect branches:
        \\1. pc=0x00000120 register=r12
        \\
    ,
        stream.getWritten(),
    );
}
```

- [ ] **Step 2: Run the fixture and `status` tests to verify they fail**

Run: `zig test src/trace/fixture.zig && zig test src/cli/status.zig`
Expected: FAIL because the fixture and renderer modules do not exist.

- [ ] **Step 3: Write the minimal fixture generator and `status` renderer**

```zig
pub fn gbaMissingDiv(allocator: std.mem.Allocator) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try appendEvent(&list, .{ .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000100 } });
    try appendEvent(&list, .{ .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000104 } });
    try appendEvent(&list, .{ .shim_called = .{ .shim = "shim/gba/Div", .pc = 0x00000108 } });
    try appendEvent(&list, .{ .instruction_missing = .{ .instruction = "instruction/armv4t/unknown_e7f001f0", .pc = 0x00000110 } });
    try appendEvent(&list, .{ .unresolved_indirect_branch = .{ .pc = 0x00000120, .target_register = "r12" } });

    return list.toOwnedSlice();
}
```

```zig
pub fn render(writer: anytype, bytes: []const u8) !void {
    var counts = Counts.init(std.heap.page_allocator);
    defer counts.deinit();
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const decoded = try trace.decodeOne(bytes[cursor..]);
        cursor += decoded.bytes_read;
        switch (decoded.event) {
            .shim_called => |payload| try counts.bumpShim(payload.shim),
            .instruction_missing => |payload| try counts.bumpInstruction(payload.instruction),
            .unresolved_indirect_branch => |payload| try counts.appendBranch(payload),
            else => {},
        }
    }
    try counts.writeReport(writer);
}
```

- [ ] **Step 4: Materialize the synthetic trace fixture used by CLI smoke checks**

```zig
test "write gba status fixture to disk" {
    const bytes = try gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    const cwd = std.fs.cwd();
    try cwd.makePath("tests/fixtures/phase0");
    try cwd.writeFile(.{
        .sub_path = "tests/fixtures/phase0/gba-missing-div.tracebin",
        .data = bytes,
    });
}
```

- [ ] **Step 5: Run the fixture and `status` tests to verify they pass**

Run: `zig test src/trace/fixture.zig && zig test src/cli/status.zig && zig build run -- status --trace tests/fixtures/phase0/gba-missing-div.tracebin`
Expected: PASS in unit tests and a ranked report in the CLI smoke check.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig src/root.zig src/trace/fixture.zig src/cli/status.zig tests/fixtures/phase0/gba-missing-div.tracebin
git commit -m "feat(cli): add fixture-backed status command"
```

## Spec Coverage Review

- `SPEC.md` "Load-bearing abstractions": covered by Tasks 2, 3, and 4.
- `SPEC.md` "authoring loop": covered by Tasks 6, 7, and 8.
- User-imposed Phase 0 constraint: covered by Task 1 phasing section and the command parser deferral for `build`.
- Three-machine schema checkpoint: covered by Task 4 and the checkpoint document.

## Placeholder Scan

- No task says "implement later" without a concrete file and command.
- No task introduces Capstone, LLVM, lifter, or codegen work.
- No task uses toy declarations detached from real machine content; the plan uses GBA, Xbox, and arcade declarations directly.

## Type Consistency Review

- Declaration IDs use the same `kind/namespace/name` shape across schema, registry, and CLI tasks.
- `Machine.validate` is introduced before any machine modules rely on `validateComptime`.
- `TraceEvent` is introduced before fixture generation and `status` rendering use it.

## Handoff

Phase 0 should end with a usable authoring environment and no recompiler. If a task attempts to add loader, disassembler, Capstone, LLVM, lifter, or codegen code before all eight tasks are green, stop and split that work into a separate Phase 1 plan.
