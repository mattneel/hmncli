//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const build_module = @import("build_cmd.zig");
const cli_doc = @import("cli/doc.zig");
const cli_parse = @import("cli/parse.zig");
const cli_status = @import("cli/status.zig");
const cli_test = @import("cli/test.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub const cli = struct {
    pub const build_cmd = build_module;
    pub const doc = cli_doc;
    pub const parse = cli_parse.parse;
    pub const status = cli_status;
    pub const test_cmd = cli_test;
    pub const Command = cli_parse.Command;
    pub const ParseError = cli_parse.ParseError;
};

pub const decl = struct {
    pub const common = @import("decl/common.zig");
    pub const machine = @import("decl/machine.zig");
    pub const shim = @import("decl/shim.zig");
    pub const instruction = @import("decl/instruction.zig");
};

pub const trace = struct {
    pub const event = @import("trace/event.zig");
    pub const fixture = @import("trace/fixture.zig");
};

pub const machines = struct {
    pub const gba = @import("machines/gba.zig");
    pub const xbox = @import("machines/xbox.zig");
    pub const arcade_dualcpu = @import("machines/arcade_dualcpu.zig");
};

pub const catalog = @import("catalog.zig");
pub const capstone_api = @import("capstone_api.zig");
pub const gba_ppu = @import("gba_ppu.zig");
pub const frame_test_support = @import("frame_test_support.zig");

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "aggregator" {
    std.testing.refAllDecls(@This());
}

test "phase 0 machine examples validate against the shared schema" {
    try decl.machine.validate(machines.gba.machine);
    try decl.machine.validate(machines.xbox.machine);
    try decl.machine.validate(machines.arcade_dualcpu.machine);
}

test "arcade example proves multi-cpu machines fit without bespoke fields" {
    try std.testing.expectEqual(@as(usize, 2), machines.arcade_dualcpu.machine.cpus.len);
}

test "doc command renders shim declaration metadata" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.doc.render(&output.writer, "shim/gba/Div");
    try std.testing.expectEqualStrings(
        "ID: shim/gba/Div\nState: verified\nEffects: pure\nReference: GBATEK BIOS Div\n",
        output.writer.buffered(),
    );
}

test "declaration-backed test commands run vectors" {
    var shim_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer shim_output.deinit();
    try cli.test_cmd.runShim(&shim_output.writer, "gba/Div");
    try std.testing.expectEqualStrings(
        "PASS 2/2 shim tests for gba/Div\n",
        shim_output.writer.buffered(),
    );

    var instruction_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer instruction_output.deinit();
    try cli.test_cmd.runInstruction(&instruction_output.writer, "armv4t/mov_imm");
    try std.testing.expectEqualStrings(
        "PASS 1/1 instruction tests for armv4t/mov_imm\n",
        instruction_output.writer.buffered(),
    );
}

test "fixture-backed status report renders deterministic counts" {
    const bytes = try trace.fixture.gbaMissingDiv(std.testing.allocator);
    defer std.testing.allocator.free(bytes);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.status.render(&output.writer, bytes);
    try std.testing.expectEqualStrings(
        "Unimplemented shims:\n1. shim/gba/Div (3)\nUnimplemented instructions:\n1. instruction/armv4t/unknown_e7f001f0 (1)\nUnresolved indirect branches:\n1. pc=0x00000120 register=r12\n",
        output.writer.buffered(),
    );
}

test "build emits guest-state llvm with a separate guest entry function" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3,
        0x02, 0x10, 0xA0, 0xE3,
        0x06, 0x00, 0x00, 0xEF,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "div.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "div.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-div-native",
        },
    );

    const llvm_bytes = try tmp.dir.readFileAlloc(
        io,
        "gba-div-native.ll",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(llvm_bytes);

    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "%GuestState = type") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "define void @guest_arm_08000000(ptr %state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_bytes, "call void @guest_arm_08000000(ptr %state)") != null);
}

test "build executes a synthetic direct bl plus bx lr slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x0A, 0x00, 0xA0, 0xE3, // mov r0, #10
        0x01, 0x00, 0x00, 0xEB, // bl  0x08000010
        0x02, 0x10, 0xA0, 0xE3, // mov r1, #2
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0x1E, 0xFF, 0x2F, 0xE1, // bx  lr
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "bl.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "bl.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-bl-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-bl-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic msr cpsr_f immediate slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0xF1, 0x28, 0xE3, // msr cpsr_f, #0x40000000
        0x01, 0x00, 0x00, 0x1A, // bne 0x08000010
        0x01, 0x00, 0xA0, 0xE3, // mov r0, #1
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "msr.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "msr.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-msr-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-msr-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "build executes a synthetic beq slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0xF1, 0x28, 0xE3, // msr cpsr_f, #0x40000000
        0x01, 0x00, 0x00, 0x0A, // beq 0x08000010
        0x01, 0x00, 0xA0, 0xE3, // mov r0, #1
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0xFE, 0xFF, 0xFF, 0xEA, // b   .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "beq.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "beq.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-beq-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-beq-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic arm-thumb-arm interworking slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0x00, 0x8F, 0xE2, // add r0, pc, #1
        0x10, 0xFF, 0x2F, 0xE1, // bx  r0
        0x07, 0x20, // movs r0, #7
        0x01, 0xA1, // adr  r1, 0x08000010
        0x08, 0x47, // bx   r1
        0xC0, 0x46, // nop
        0xFE, 0xFF, 0xFF, 0xEA, // b .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "interwork.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "interwork.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-interwork-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-interwork-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic push pop stack slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0x03, 0x10, 0xA0, 0xE3, // mov r1, #3
        0x03, 0x00, 0x2D, 0xE9, // push {r0, r1}
        0x01, 0x00, 0xA0, 0xE3, // mov r0, #1
        0x02, 0x10, 0xA0, 0xE3, // mov r1, #2
        0x03, 0x00, 0xBD, 0xE8, // pop {r0, r1}
        0xFE, 0xFF, 0xFF, 0xEA, // b .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "stack.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "stack.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-stack-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-stack-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic mmio ldr tst branch slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x01, 0x03, 0xA0, 0xE3, // mov r0, #0x04000000
        0x04, 0x10, 0x90, 0xE5, // ldr r1, [r0, #4]
        0x01, 0x00, 0x11, 0xE3, // tst r1, #1
        0x01, 0x00, 0x00, 0x1A, // bne 0x08000018
        0x07, 0x00, 0xA0, 0xE3, // mov r0, #7
        0xFE, 0xFF, 0xFF, 0xEA, // b .
        0x01, 0x00, 0xA0, 0xE3, // mov r0, #1
        0xFE, 0xFF, 0xFF, 0xEA, // b .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "mmio.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "mmio.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-mmio-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-mmio-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("1\n", result.stdout);
}

test "build executes a synthetic arithmetic helper slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x24, 0x20, 0xA0, 0xE3, // mov r2, #36
        0x20, 0x20, 0x42, 0xE2, // sub r2, r2, #32
        0x82, 0x21, 0xA0, 0xE1, // lsl r2, r2, #3
        0x0A, 0x30, 0xA0, 0xE3, // mov r3, #10
        0x02, 0x00, 0x83, 0xE0, // add r0, r3, r2
        0xFE, 0xFF, 0xFF, 0xEA, // b .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "arith.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "arith.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-arith-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-arith-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n", result.stdout);
}

test "build executes a synthetic mla slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rom = [_]u8{
        0x02, 0x00, 0xA0, 0xE3, // mov r0, #2
        0x03, 0x10, 0xA0, 0xE3, // mov r1, #3
        0x04, 0x40, 0xA0, 0xE3, // mov r4, #4
        0x94, 0x01, 0x20, 0xE0, // mla r0, r4, r1, r0
        0xFE, 0xFF, 0xFF, 0xEA, // b .
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "mla.gba", .data = &rom });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "mla.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-mla-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-mla-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("14\n", result.stdout);
}

test "build executes a synthetic conditional store helper slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r0, #3
                \\  mov r1, #0x05000000
                \\  and r3, r0, #1
                \\  lsr r0, r0, #1
                \\  and r4, r0, #1
                \\  orr r3, r3, r4, ror #24
                \\  strh r3, [r1], #2
                \\  cmp r0, #1
                \\  addeq r1, r1, #2
                \\  strh r3, [r1], #2
                \\1:
                \\  b 1b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "cond-store.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "cond-store.o",
                    "cond-store.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "cond-store.o",
                    "cond-store.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "cond-store.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-cond-store-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-cond-store-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings(
        "IO0=00000000 IO8=00000000 PAL0=00000101 PAL2=00000000 VRAM4000=00000000 MAP0800=00000000 MAP0804=00000000\n",
        result.stdout,
    );
}

test "build executes a synthetic flag transition slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  movs r0, #0x80000000
                \\  bpl fail
                \\  mvn r0, #0
                \\  adds r0, r0, #1
                \\  bcc fail
                \\  bcs pass
                \\fail:
                \\  mov r0, #1
                \\1:
                \\  b 1b
                \\pass:
                \\  mov r0, #7
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "flag-transition.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "flag-transition.o",
                    "flag-transition.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "flag-transition.o",
                    "flag-transition.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "flag-transition.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-flag-transition-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-flag-transition-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic adc carry slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mvn r0, #0
                \\  msr cpsr_f, #0x20000000
                \\  adcs r0, r0, #1
                \\  bcc fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "adc-carry.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "adc-carry.o",
                    "adc-carry.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "adc-carry.o",
                    "adc-carry.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "adc-carry.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-adc-carry-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-adc-carry-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic sbc borrow slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r0, #2
                \\  msr cpsr_f, #0
                \\  sbcs r0, r0, #1
                \\  bcc fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "sbc-borrow.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "sbc-borrow.o",
                    "sbc-borrow.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "sbc-borrow.o",
                    "sbc-borrow.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "sbc-borrow.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-sbc-borrow-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-sbc-borrow-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic lsls carry edge slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r0, #1
                \\  mov r1, #32
                \\  lsls r0, r0, r1
                \\  bne fail
                \\  bcc fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "lsls-carry.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "lsls-carry.o",
                    "lsls-carry.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "lsls-carry.o",
                    "lsls-carry.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "lsls-carry.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-lsls-carry-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-lsls-carry-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic asr flag slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r0, #64
                \\  asr r0, r0, #6
                \\  cmp r0, #1
                \\  bne fail
                \\  mov r0, #0x80000000
                \\  asr r0, r0, #31
                \\  mvn r1, #0
                \\  cmp r1, r0
                \\  bne fail
                \\  mov r0, #2
                \\  asrs r0, r0, #1
                \\  bcs fail
                \\  mov r0, #1
                \\  asrs r0, r0, #1
                \\  bcc fail
                \\  mov r0, #1
                \\  asrs r0, r0, #32
                \\  bne fail
                \\  bcs fail
                \\  mov r0, #0x80000000
                \\  asrs r0, r0, #32
                \\  bcc fail
                \\  mvn r1, #0
                \\  cmp r1, r0
                \\  bne fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "asr-flags.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "asr-flags.o",
                    "asr-flags.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "asr-flags.o",
                    "asr-flags.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "asr-flags.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-asr-flags-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-asr-flags-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic rotate and register shift slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r0, #1
                \\  ror r0, r0, #1
                \\  cmp r0, #0x80000000
                \\  bne fail
                \\  mov r0, #2
                \\  rors r0, r0, #1
                \\  bcs fail
                \\  mov r0, #1
                \\  rors r0, r0, #1
                \\  bcc fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #1
                \\  rrxs r0, r0
                \\  bcc fail
                \\  bpl fail
                \\  msr CPSR_f, #0
                \\  mov r0, #1
                \\  rrxs r0, r0
                \\  bcc fail
                \\  bne fail
                \\  mov r0, #0x80000000
                \\  mov r1, #32
                \\  rors r0, r0, r1
                \\  bcc fail
                \\  cmp r0, #0x80000000
                \\  bne fail
                \\  mov r0, #2
                \\  mov r1, #33
                \\  ror r0, r0, r1
                \\  cmp r0, #1
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #1
                \\  mov r1, #0
                \\  lsls r0, r0, r1
                \\  lsrs r0, r0, r1
                \\  asrs r0, r0, r1
                \\  rors r0, r0, r1
                \\  bcc fail
                \\  cmp r0, #1
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #1
                \\  mov r1, #16
                \\  lsl r0, r0, r1
                \\  bcc fail
                \\  cmp r0, #0x10000
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #0x80000000
                \\  mov r1, #32
                \\  lsr r0, r0, r1
                \\  bcc fail
                \\  cmp r0, #0
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #0x80000000
                \\  mov r1, #32
                \\  asr r0, r0, r1
                \\  bcc fail
                \\  mvn r2, #0
                \\  cmp r0, r2
                \\  bne fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "rotate-shifts.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "rotate-shifts.o",
                    "rotate-shifts.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "rotate-shifts.o",
                    "rotate-shifts.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "rotate-shifts.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-rotate-shifts-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-rotate-shifts-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic bitwise and carry arithmetic slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r0, #0xff
                \\  eor r0, r0, #0xf0
                \\  cmp r0, #0x0f
                \\  bne fail
                \\  mov r0, #0xff
                \\  bic r0, r0, #0x0f
                \\  cmp r0, #0xf0
                \\  bne fail
                \\  msr CPSR_f, #0
                \\  movs r0, #32
                \\  adc r0, r0, #32
                \\  bcs fail
                \\  cmp r0, #64
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #32
                \\  adc r0, r0, #32
                \\  bcc fail
                \\  cmp r0, #65
                \\  bne fail
                \\  mov r0, #64
                \\  sub r0, r0, #32
                \\  cmp r0, #32
                \\  bne fail
                \\  mov r0, #32
                \\  rsb r0, r0, #64
                \\  cmp r0, #32
                \\  bne fail
                \\  msr CPSR_f, #0
                \\  mov r0, #64
                \\  sbc r0, r0, #32
                \\  bcs fail
                \\  cmp r0, #31
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #64
                \\  sbc r0, r0, #32
                \\  bcc fail
                \\  cmp r0, #32
                \\  bne fail
                \\  msr CPSR_f, #0
                \\  mov r0, #32
                \\  rsc r0, r0, #64
                \\  bcs fail
                \\  cmp r0, #31
                \\  bne fail
                \\  msr CPSR_f, #0x20000000
                \\  mov r0, #32
                \\  rsc r0, r0, #64
                \\  bcc fail
                \\  cmp r0, #32
                \\  bne fail
                \\  mov r0, #0x80000000
                \\  cmn r0, r0
                \\  bne fail
                \\  mov r0, #0xff
                \\  teq r0, #0xff
                \\  bne fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "bitwise-carry.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "bitwise-carry.o",
                    "bitwise-carry.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "bitwise-carry.o",
                    "bitwise-carry.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "bitwise-carry.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-bitwise-carry-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-bitwise-carry-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic movs immediate carry slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  msr CPSR_f, #0
                \\  movs r0, #0xF000000F
                \\  bcc fail
                \\  movs r0, #0x0FF00000
                \\  bcs fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "movs-carry.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "movs-carry.o",
                    "movs-carry.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "movs-carry.o",
                    "movs-carry.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "movs-carry.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-movs-carry-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-movs-carry-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic pc read slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  add r0, pc, #4
                \\  cmp r0, pc
                \\  bne fail
                \\  mov r1, pc
                \\  add r2, pc, #0
                \\  sub r2, r2, #4
                \\  cmp r1, r2
                \\  bne fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "pc-read.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "pc-read.o",
                    "pc-read.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "pc-read.o",
                    "pc-read.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "pc-read.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-pc-read-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-pc-read-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic mov pc register slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  add r0, pc, #16
                \\  mov pc, r0
                \\  mov r0, #1
                \\  cmp r0, #0
                \\  beq success
                \\  b end
                \\success:
                \\  mov r0, #7
                \\end:
                \\  b end
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "mov-pc.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "mov-pc.o",
                    "mov-pc.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "mov-pc.o",
                    "mov-pc.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "mov-pc.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-mov-pc-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-mov-pc-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic fiq exception-return slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov r8, #32
                \\  msr CPSR_fc, #17
                \\  mov r8, #64
                \\  msr SPSR_fc, #31
                \\  subs pc, pc, #4
                \\  cmp r8, #32
                \\  bne fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "fiq-return.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "fiq-return.o",
                    "fiq-return.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "fiq-return.o",
                    "fiq-return.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "fiq-return.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-fiq-return-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-fiq-return-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic mrs-plus-msr register slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  msr CPSR_f, #0x20000000
                \\  mrs r0, CPSR
                \\  bic r0, r0, #0xF0000000
                \\  msr CPSR_fc, r0
                \\  beq fail
                \\  bmi fail
                \\  bcs fail
                \\  bvs fail
                \\  mov r0, #7
                \\1:
                \\  b 1b
                \\fail:
                \\  mov r0, #1
                \\2:
                \\  b 2b
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "mrs-msr.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "mrs-msr.o",
                    "mrs-msr.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "mrs-msr.o",
                    "mrs-msr.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "mrs-msr.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-mrs-msr-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-mrs-msr-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic swp word-plus-byte slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov fp, #0x03000000
                \\  add fp, fp, #0x3000
                \\  mov r2, #5
                \\  str r2, [fp]
                \\  mov r0, #7
                \\  swp r1, r0, [fp]
                \\  cmp r1, #5
                \\  bne fail
                \\  ldr r2, [fp]
                \\  cmp r2, #7
                \\  bne fail
                \\  mvn r0, #0
                \\  str r0, [fp, #32]
                \\  mov r0, #7
                \\  add r2, fp, #32
                \\  swpb r1, r0, [r2]
                \\  cmp r1, #0xFF
                \\  bne fail
                \\  ldr r2, [fp, #32]
                \\  and r2, r2, #0xFF
                \\  cmp r2, #7
                \\  bne fail
                \\  mov r0, #7
                \\  mov pc, lr
                \\fail:
                \\  mov r0, #1
                \\  mov pc, lr
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "swp.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "swp.o",
                    "swp.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "swp.o",
                    "swp.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "swp.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-swp-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-swp-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "build executes a synthetic stmib plus ldmda slice" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const helper = struct {
        fn assemble(dir: std.testing.TmpDir, io_handle: std.Io) !void {
            const source =
                \\.syntax unified
                \\.arm
                \\_start:
                \\  mov fp, #0x03000000
                \\  add fp, fp, #0x4500
                \\  mov r0, #32
                \\  mov r1, #64
                \\  stmib fp!, {r0, r1}
                \\  ldmda fp!, {r2, r3}
                \\  cmp r0, r2
                \\  bne fail
                \\  cmp r1, r3
                \\  bne fail
                \\  mov r4, #0x03000000
                \\  add r4, r4, #0x4500
                \\  cmp fp, r4
                \\  bne fail
                \\  mov r0, #7
                \\  mov pc, lr
                \\fail:
                \\  mov r0, #1
                \\  mov pc, lr
                \\
            ;
            try dir.dir.writeFile(io_handle, .{
                .sub_path = "block-transfer.s",
                .data = source,
            });

            const assemble_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-as",
                    "-mcpu=arm7tdmi",
                    "-o",
                    "block-transfer.o",
                    "block-transfer.s",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(assemble_result.stdout);
            defer std.testing.allocator.free(assemble_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, assemble_result.term);

            const objcopy_result = try std.process.run(std.testing.allocator, io_handle, .{
                .argv = &.{
                    "arm-none-eabi-objcopy",
                    "-O",
                    "binary",
                    "block-transfer.o",
                    "block-transfer.gba",
                },
                .cwd = .{ .dir = dir.dir },
                .stdout_limit = .limited(1024),
                .stderr_limit = .limited(1024),
            });
            defer std.testing.allocator.free(objcopy_result.stdout);
            defer std.testing.allocator.free(objcopy_result.stderr);
            try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, objcopy_result.term);
        }
    };

    try helper.assemble(tmp, io);

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try cli.build_cmd.run(
        io,
        std.testing.allocator,
        tmp.dir,
        &output.writer,
        .{
            .rom_path = "block-transfer.gba",
            .machine_name = "gba",
            .target = "x86_64-linux",
            .output_path = "gba-block-transfer-native",
        },
    );

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{"./gba-block-transfer-native"},
        .cwd = .{ .dir = tmp.dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}
