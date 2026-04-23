const std = @import("std");
const Io = std.Io;
const armv4t_decode = @import("armv4t_decode.zig");

pub const OutputMode = enum {
    register_r0_decimal,
    memory_summary,
    arm_report,
    frame_raw,
    retired_count,
};

pub const SaveHardware = enum {
    none,
    sram,
    flash64,
    flash128,
};

pub const InstructionNode = struct {
    address: u32,
    condition: armv4t_decode.Cond,
    size_bytes: u8,
    instruction: armv4t_decode.DecodedInstruction,
};

pub const Function = struct {
    entry: armv4t_decode.CodeAddress,
    instructions: []const InstructionNode,
};

pub const Program = struct {
    entry: armv4t_decode.CodeAddress,
    rom_base_address: u32,
    rom_bytes: []const u8,
    save_hardware: SaveHardware,
    functions: []const Function,
    output_mode: OutputMode,
    instruction_limit: ?u64 = null,

    pub fn deinit(self: Program, allocator: std.mem.Allocator) void {
        for (self.functions) |function| allocator.free(function.instructions);
        allocator.free(self.functions);
    }
};

const RetiredBlockInfo = struct {
    is_leader: bool,
    instruction_count: u32,
};

const RetiredCountMode = enum {
    regular,
    prepaid,
};

const guest_state_regs_field = 0;
const guest_state_flag_n_field = 1;
const guest_state_flag_z_field = 2;
const guest_state_flag_c_field = 3;
const guest_state_flag_v_field = 4;
const guest_state_bios_latch_field = 5;
const guest_state_ewram_field = 6;
const guest_state_iwram_field = 7;
const guest_state_io_field = 8;
const guest_state_palette_field = 9;
const guest_state_vram_field = 10;
const guest_state_oam_field = 11;
const guest_state_dispstat_toggle_field = 12;
const guest_state_mode_field = 13;
const guest_state_spsr_field = 14;
const guest_state_fiq_regs_field = 15;
const guest_state_save_field = 16;
const guest_state_flash_stage_field = 17;
const guest_state_flash_mode_field = 18;
const guest_state_flash_bank_field = 19;
const guest_state_instruction_budget_field = 20;
const guest_state_stop_flag_field = 21;
const guest_state_retired_count_field = 22;
const guest_state_retired_block_remaining_field = 23;
const guest_state_vblank_count_field = 24;
const guest_state_in_irq_handler_field = 25;

const io_dispstat_offset = 4;
const io_keyinput_offset = 304;
const io_ie_offset: u32 = 512;
const io_if_offset: u32 = 514;
const io_ime_offset: u32 = 520;
const irq_vblank_mask: u16 = 0x0001;

const mode_fiq: u32 = 0x11;
const mode_system: u32 = 0x1F;
const save_region_base: u32 = 0x0E00_0000;
const save_region_end: u32 = 0x1000_0000;
const save_region_len: u32 = 65_536;
const save_storage_len: u32 = 131_072;
const save_byte_fill16: u32 = 0x0101;
const save_byte_fill32: u32 = 0x0101_0101;
const flash_mode_read: u32 = 0;
const flash_mode_program: u32 = 1;
const flash_mode_erase: u32 = 2;
const flash_mode_bank: u32 = 3;

const RegionOffsetKind = enum {
    linear,
    mirror,
    vram,
};

const Region = struct {
    field_index: u8,
    field_name: []const u8,
    llvm_len: u32,
    base: u32,
    mapped_size: u32,
    offset_kind: RegionOffsetKind,
};

const ewram_region = Region{
    .field_index = guest_state_ewram_field,
    .field_name = "ewram",
    .llvm_len = 262_144,
    .base = 0x0200_0000,
    .mapped_size = 0x0100_0000,
    .offset_kind = .mirror,
};

const iwram_region = Region{
    .field_index = guest_state_iwram_field,
    .field_name = "iwram",
    .llvm_len = 32_768,
    .base = 0x0300_0000,
    .mapped_size = 0x0100_0000,
    .offset_kind = .mirror,
};
const io_region = Region{
    .field_index = guest_state_io_field,
    .field_name = "io",
    .llvm_len = 1024,
    .base = 0x0400_0000,
    .mapped_size = 0x400,
    .offset_kind = .linear,
};
const palette_region = Region{
    .field_index = guest_state_palette_field,
    .field_name = "palette",
    .llvm_len = 1024,
    .base = 0x0500_0000,
    .mapped_size = 0x0100_0000,
    .offset_kind = .mirror,
};
const vram_region = Region{
    .field_index = guest_state_vram_field,
    .field_name = "vram",
    .llvm_len = 98_304,
    .base = 0x0600_0000,
    .mapped_size = 0x0100_0000,
    .offset_kind = .vram,
};
const oam_region = Region{
    .field_index = guest_state_oam_field,
    .field_name = "oam",
    .llvm_len = 1024,
    .base = 0x0700_0000,
    .mapped_size = 0x0100_0000,
    .offset_kind = .mirror,
};
const memory_regions = [_]Region{ ewram_region, iwram_region, io_region, palette_region, vram_region, oam_region };

fn emitRegionNormalizedOffset(
    writer: *Io.Writer,
    addr_name: []const u8,
    prefix: []const u8,
    index: usize,
    region: Region,
) Io.Writer.Error!void {
    try writer.print("  %{s}_window_offset_{d} = sub i32 %{s}, {d}\n", .{ prefix, index, addr_name, region.base });

    switch (region.offset_kind) {
        .linear => try writer.print(
            "  %{s}_offset_{d} = or i32 %{s}_window_offset_{d}, 0\n",
            .{ prefix, index, prefix, index },
        ),
        .mirror => try writer.print(
            "  %{s}_offset_{d} = urem i32 %{s}_window_offset_{d}, {d}\n",
            .{ prefix, index, prefix, index, region.llvm_len },
        ),
        .vram => {
            try writer.print(
                "  %{s}_vram_page_{d} = urem i32 %{s}_window_offset_{d}, 131072\n",
                .{ prefix, index, prefix, index },
            );
            try writer.print(
                "  %{s}_vram_obj_{d} = icmp uge i32 %{s}_vram_page_{d}, 98304\n",
                .{ prefix, index, prefix, index },
            );
            try writer.print(
                "  %{s}_vram_obj_offset_{d} = sub i32 %{s}_vram_page_{d}, 32768\n",
                .{ prefix, index, prefix, index },
            );
            try writer.print(
                "  %{s}_offset_{d} = select i1 %{s}_vram_obj_{d}, i32 %{s}_vram_obj_offset_{d}, i32 %{s}_vram_page_{d}\n",
                .{ prefix, index, prefix, index, prefix, index, prefix, index },
            );
        },
    }
}

fn emitSaveNormalizedOffset(
    writer: *Io.Writer,
    addr_name: []const u8,
    prefix: []const u8,
    mirror_len: u32,
) Io.Writer.Error!void {
    try writer.print("  %{s}_save_window_offset = sub i32 %{s}, {d}\n", .{ prefix, addr_name, save_region_base });
    try writer.print("  %{s}_save_offset = and i32 %{s}_save_window_offset, {d}\n", .{
        prefix,
        prefix,
        mirror_len - 1,
    });
}

fn saveMirrorLen(hardware: SaveHardware) u32 {
    return switch (hardware) {
        .sram => 32_768,
        .none, .flash64, .flash128 => save_region_len,
    };
}

pub fn emitModule(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try emitPrelude(writer);
    try emitPsrHelpers(writer);
    try emitRomConstant(writer, program);
    try emitStoreHelpers(writer, program);
    try emitLoadHelper(writer, program);
    try emitLoad8Helper(writer, program);
    try emitLoad16Helper(writer, program);
    try emitLoad16SignedHelper(writer, program);
    try emitLoad8SignedHelper(writer, program);
    for (program.functions) |function| {
        try emitGuestFunction(writer, function);
    }
    try emitGuestCallDispatcher(writer, program);
    try emitMain(writer, program);
}

fn emitPrelude(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("; generated by hmncli phase1 slice\n", .{});
    try writer.print("%Registers = type [16 x i32]\n", .{});
    try writer.print("%BankedFiqRegisters = type [7 x i32]\n", .{});
    try writer.print("%GuestState = type {{ %Registers, i1, i1, i1, i1, i32, [262144 x i8], [32768 x i8], [1024 x i8], [1024 x i8], [98304 x i8], [1024 x i8], i1, i32, i32, %BankedFiqRegisters, [131072 x i8], i32, i32, i32, i64, i1, i64, i64, i64, i1 }}\n", .{});
    try writer.print("@.fmt_r0 = private unnamed_addr constant [4 x i8] c\"%d\\0A\\00\", align 1\n", .{});
    try writer.print(
        "@.fmt_mem = private unnamed_addr constant [79 x i8] c\"IO0=%08X IO8=%08X PAL0=%08X PAL2=%08X VRAM4000=%08X MAP0800=%08X MAP0804=%08X\\0A\\00\", align 1\n",
        .{},
    );
    try writer.print("@.fmt_arm_pass = private unnamed_addr constant [6 x i8] c\"PASS\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_arm_fail = private unnamed_addr constant [9 x i8] c\"FAIL %d\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_frame_missing_path = private unnamed_addr constant [42 x i8] c\"frame_raw requires HOMONCULI_OUTPUT_PATH\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_frame_bad_mode = private unnamed_addr constant [47 x i8] c\"frame_raw requires a supported GBA video mode\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_frame_write_failed = private unnamed_addr constant [24 x i8] c\"frame_raw write failed\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_retired = private unnamed_addr constant [14 x i8] c\"retired=%llu\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_irq_bad_ie = private unnamed_addr constant [64 x i8] c\"Unsupported interrupt source mask 0x%04x at 0x04000200 for gba\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_irq_nested_ime = private unnamed_addr constant [53 x i8] c\"Unsupported nested IME enable at 0x04000208 for gba\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_irq_multi_if = private unnamed_addr constant [58 x i8] c\"Unsupported pending IF mask 0x%04x at 0x04000202 for gba\\0A\\00\", align 1\n", .{});
    try writer.print("@.fmt_irq_byte_store = private unnamed_addr constant [57 x i8] c\"Unsupported byte interrupt MMIO store at 0x%08x for gba\\0A\\00\", align 1\n", .{});
    try writer.print("declare i32 @printf(ptr, ...)\n", .{});
    try writer.print("declare i32 @hmgba_dump_frame_raw(ptr, ptr, ptr, ptr)\n", .{});
    try writer.print("declare i16 @hmgba_sample_keyinput_for_frame(i64)\n", .{});
    try writer.print("declare i64 @hm_runtime_max_instructions(i64)\n", .{});
    try writer.print("declare i32 @hm_runtime_output_mode_frame_raw()\n", .{});
    try writer.print("declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)\n\n", .{});
    try writer.print("declare {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32, i32)\n", .{});
    try writer.print("declare {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32, i32)\n", .{});
    try writer.print("declare {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32, i32)\n", .{});
    try writer.print("declare {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32, i32)\n\n", .{});
    try writer.print("define i32 @shim_gba_SoftReset(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  store i1 true, ptr %stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret i32 0\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define i32 @shim_gba_Div(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %regs_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_regs_field},
    );
    try writer.print("  %r0_ptr = getelementptr inbounds [16 x i32], ptr %regs_ptr, i32 0, i32 0\n", .{});
    try writer.print("  %r1_ptr = getelementptr inbounds [16 x i32], ptr %regs_ptr, i32 0, i32 1\n", .{});
    try writer.print("  %numerator = load i32, ptr %r0_ptr, align 4\n", .{});
    try writer.print("  %denominator = load i32, ptr %r1_ptr, align 4\n", .{});
    try writer.print("  %result = sdiv i32 %numerator, %denominator\n", .{});
    try writer.print("  store i32 %result, ptr %r0_ptr, align 4\n", .{});
    try writer.print("  ret i32 %result\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define i32 @shim_gba_Sqrt(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %sqrt_regs_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_regs_field},
    );
    try writer.print("  %sqrt_r0_ptr = getelementptr inbounds [16 x i32], ptr %sqrt_regs_ptr, i32 0, i32 0\n", .{});
    try writer.print("  %sqrt_value = load i32, ptr %sqrt_r0_ptr, align 4\n", .{});
    try writer.print(
        "  %sqrt_bios_latch_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_bios_latch_field},
    );
    try writer.print("  %sqrt_is_zero = icmp eq i32 %sqrt_value, 0\n", .{});
    try writer.print("  br i1 %sqrt_is_zero, label %sqrt_zero, label %sqrt_loop\n", .{});
    try writer.print("sqrt_zero:\n", .{});
    try writer.print("  store i32 0, ptr %sqrt_r0_ptr, align 4\n", .{});
    try writer.print("  store i32 3818921988, ptr %sqrt_bios_latch_ptr, align 4\n", .{});
    try writer.print("  ret i32 0\n", .{});
    try writer.print("sqrt_loop:\n", .{});
    try writer.print("  %sqrt_candidate = phi i32 [ 1, %entry ], [ %sqrt_next_candidate, %sqrt_continue ]\n", .{});
    try writer.print("  %sqrt_quotient = udiv i32 %sqrt_value, %sqrt_candidate\n", .{});
    try writer.print("  %sqrt_done = icmp ugt i32 %sqrt_candidate, %sqrt_quotient\n", .{});
    try writer.print("  br i1 %sqrt_done, label %sqrt_finish, label %sqrt_continue\n", .{});
    try writer.print("sqrt_continue:\n", .{});
    try writer.print("  %sqrt_next_candidate = add i32 %sqrt_candidate, 1\n", .{});
    try writer.print("  br label %sqrt_loop\n", .{});
    try writer.print("sqrt_finish:\n", .{});
    try writer.print("  %sqrt_result = sub i32 %sqrt_candidate, 1\n", .{});
    try writer.print("  store i32 %sqrt_result, ptr %sqrt_r0_ptr, align 4\n", .{});
    try writer.print("  store i32 3818921988, ptr %sqrt_bios_latch_ptr, align 4\n", .{});
    try writer.print("  ret i32 %sqrt_result\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define i64 @hmn_gba_advance_frame(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %advance_vblank_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_vblank_count_field},
    );
    try writer.print("  %advance_vblank_curr = load i64, ptr %advance_vblank_ptr, align 8\n", .{});
    try writer.print("  %advance_vblank_next = add i64 %advance_vblank_curr, 1\n", .{});
    try writer.print("  store i64 %advance_vblank_next, ptr %advance_vblank_ptr, align 8\n", .{});
    try writer.print(
        "  %advance_io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_io_field},
    );
    try writer.print(
        "  %advance_if_ptr = getelementptr inbounds [1024 x i8], ptr %advance_io_ptr, i32 0, i32 {d}\n",
        .{io_if_offset},
    );
    try writer.print("  %advance_if_curr = load i16, ptr %advance_if_ptr, align 1\n", .{});
    try writer.print("  %advance_if_next = or i16 %advance_if_curr, {d}\n", .{irq_vblank_mask});
    try writer.print("  store i16 %advance_if_next, ptr %advance_if_ptr, align 1\n", .{});
    try writer.print("  ret i64 %advance_vblank_next\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define i32 @shim_gba_VBlankIntrWait(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print("  %frame_index = call i64 @hmn_gba_advance_frame(ptr %state)\n", .{});
    try writer.print("  %keyinput_value = call i16 @hmgba_sample_keyinput_for_frame(i64 %frame_index)\n", .{});
    try writer.print(
        "  %wait_io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_io_field},
    );
    try writer.print(
        "  %keyinput_ptr = getelementptr inbounds [1024 x i8], ptr %wait_io_ptr, i32 0, i32 {d}\n",
        .{io_keyinput_offset},
    );
    try writer.print("  store i16 %keyinput_value, ptr %keyinput_ptr, align 1\n", .{});
    try writer.print("  call void @hmn_dispatch_vblank_irq(ptr %state)\n", .{});
    try writer.print("  ret i32 0\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define void @hmn_interrupt_fail_bad_ie(ptr %state, i16 %value) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %bad_ie_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  %bad_ie_value_i32 = zext i16 %value to i32\n", .{});
    try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_irq_bad_ie, i32 %bad_ie_value_i32)\n", .{});
    try writer.print("  store i1 true, ptr %bad_ie_stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define void @hmn_interrupt_fail_multi_if(ptr %state, i16 %value) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %multi_if_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  %multi_if_value_i32 = zext i16 %value to i32\n", .{});
    try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_irq_multi_if, i32 %multi_if_value_i32)\n", .{});
    try writer.print("  store i1 true, ptr %multi_if_stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define void @hmn_interrupt_fail_nested_ime(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %nested_ime_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_irq_nested_ime)\n", .{});
    try writer.print("  store i1 true, ptr %nested_ime_stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define void @hmn_interrupt_fail_byte_store(ptr %state, i32 %addr) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %byte_store_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_irq_byte_store, i32 %addr)\n", .{});
    try writer.print("  store i1 true, ptr %byte_store_stop_flag_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define void @hmn_store_gba_io16(ptr %state, i32 %offset, i16 %value, ptr %raw_ptr) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print("  switch i32 %offset, label %raw_store [\n", .{});
    try writer.print("    i32 {d}, label %store_ie\n", .{io_ie_offset});
    try writer.print("    i32 {d}, label %store_if\n", .{io_if_offset});
    try writer.print("    i32 {d}, label %store_ime\n", .{io_ime_offset});
    try writer.print("  ]\n", .{});
    try writer.print("store_ie:\n", .{});
    try writer.print("  %bad_ie_bits = and i16 %value, -2\n", .{});
    try writer.print("  %bad_ie = icmp ne i16 %bad_ie_bits, 0\n", .{});
    try writer.print("  br i1 %bad_ie, label %fail_ie, label %write_ie\n", .{});
    try writer.print("fail_ie:\n", .{});
    try writer.print("  call void @hmn_interrupt_fail_bad_ie(ptr %state, i16 %value)\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("write_ie:\n", .{});
    try writer.print("  store i16 %value, ptr %raw_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("store_if:\n", .{});
    try writer.print("  %if_curr = load i16, ptr %raw_ptr, align 1\n", .{});
    try writer.print("  %if_clear_mask = and i16 %value, {d}\n", .{irq_vblank_mask});
    try writer.print("  %if_keep_mask = xor i16 %if_clear_mask, -1\n", .{});
    try writer.print("  %if_next = and i16 %if_curr, %if_keep_mask\n", .{});
    try writer.print("  store i16 %if_next, ptr %raw_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("store_ime:\n", .{});
    try writer.print(
        "  %in_irq_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_in_irq_handler_field},
    );
    try writer.print("  %in_irq = load i1, ptr %in_irq_ptr, align 1\n", .{});
    try writer.print("  %ime_enable = and i16 %value, {d}\n", .{irq_vblank_mask});
    try writer.print("  %ime_enable_set = icmp ne i16 %ime_enable, 0\n", .{});
    try writer.print("  %bad_nested = and i1 %in_irq, %ime_enable_set\n", .{});
    try writer.print("  br i1 %bad_nested, label %fail_nested, label %write_ime\n", .{});
    try writer.print("fail_nested:\n", .{});
    try writer.print("  call void @hmn_interrupt_fail_nested_ime(ptr %state)\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("write_ime:\n", .{});
    try writer.print("  store i16 %ime_enable, ptr %raw_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("raw_store:\n", .{});
    try writer.print("  store i16 %value, ptr %raw_ptr, align 1\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
    try writer.print("define void @hmn_dispatch_vblank_irq(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %irq_io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_io_field},
    );
    try writer.print("  %irq_dispstat_ptr = getelementptr inbounds [1024 x i8], ptr %irq_io_ptr, i32 0, i32 {d}\n", .{io_dispstat_offset});
    try writer.print("  %irq_dispstat = load i16, ptr %irq_dispstat_ptr, align 1\n", .{});
    try writer.print("  %irq_dispstat_vblank = and i16 %irq_dispstat, 8\n", .{});
    try writer.print("  %irq_dispstat_enabled = icmp ne i16 %irq_dispstat_vblank, 0\n", .{});
    try writer.print("  br i1 %irq_dispstat_enabled, label %irq_check_ime, label %irq_done\n", .{});
    try writer.print("irq_check_ime:\n", .{});
    try writer.print("  %irq_ime_ptr = getelementptr inbounds [1024 x i8], ptr %irq_io_ptr, i32 0, i32 {d}\n", .{io_ime_offset});
    try writer.print("  %irq_ime = load i16, ptr %irq_ime_ptr, align 1\n", .{});
    try writer.print("  %irq_ime_enabled = icmp ne i16 %irq_ime, 0\n", .{});
    try writer.print("  br i1 %irq_ime_enabled, label %irq_check_ie, label %irq_done\n", .{});
    try writer.print("irq_check_ie:\n", .{});
    try writer.print("  %irq_ie_ptr = getelementptr inbounds [1024 x i8], ptr %irq_io_ptr, i32 0, i32 {d}\n", .{io_ie_offset});
    try writer.print("  %irq_ie = load i16, ptr %irq_ie_ptr, align 1\n", .{});
    try writer.print("  %irq_ie_vblank = and i16 %irq_ie, {d}\n", .{irq_vblank_mask});
    try writer.print("  %irq_ie_enabled = icmp ne i16 %irq_ie_vblank, 0\n", .{});
    try writer.print("  br i1 %irq_ie_enabled, label %irq_check_if, label %irq_done\n", .{});
    try writer.print("irq_check_if:\n", .{});
    try writer.print("  %irq_if_ptr = getelementptr inbounds [1024 x i8], ptr %irq_io_ptr, i32 0, i32 {d}\n", .{io_if_offset});
    try writer.print("  %irq_if = load i16, ptr %irq_if_ptr, align 1\n", .{});
    try writer.print("  %irq_if_multi = and i16 %irq_if, -2\n", .{});
    try writer.print("  %irq_if_bad = icmp ne i16 %irq_if_multi, 0\n", .{});
    try writer.print("  br i1 %irq_if_bad, label %irq_fail_multi_if, label %irq_check_vector\n", .{});
    try writer.print("irq_fail_multi_if:\n", .{});
    try writer.print("  call void @hmn_interrupt_fail_multi_if(ptr %state, i16 %irq_if)\n", .{});
    try writer.print("  br label %irq_done\n", .{});
    try writer.print("irq_check_vector:\n", .{});
    try writer.print(
        "  %irq_iwram_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_iwram_field},
    );
    try writer.print("  %irq_vector_ptr = getelementptr inbounds [32768 x i8], ptr %irq_iwram_ptr, i32 0, i32 32764\n", .{});
    try writer.print("  %irq_vector = load i32, ptr %irq_vector_ptr, align 1\n", .{});
    try writer.print("  %irq_has_vector = icmp ne i32 %irq_vector, 0\n", .{});
    try writer.print("  br i1 %irq_has_vector, label %irq_fire, label %irq_done\n", .{});
    try writer.print("irq_fire:\n", .{});
    try writer.print(
        "  %irq_in_handler_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_in_irq_handler_field},
    );
    try writer.print("  store i1 true, ptr %irq_in_handler_ptr, align 1\n", .{});
    try writer.print("  call void @hmn_call_guest(ptr %state, i32 %irq_vector)\n", .{});
    try writer.print("  store i1 false, ptr %irq_in_handler_ptr, align 1\n", .{});
    try writer.print("  br label %irq_done\n", .{});
    try writer.print("irq_done:\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitPsrHelpers(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("define void @hmn_switch_mode(ptr %state, i32 %new_mode) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %mode_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_mode_field},
    );
    try writer.print("  %old_mode = load i32, ptr %mode_ptr, align 4\n", .{});
    try writer.print("  %same_mode = icmp eq i32 %old_mode, %new_mode\n", .{});
    try writer.print("  br i1 %same_mode, label %switch_done, label %switch_check\n", .{});
    try writer.print("switch_check:\n", .{});
    try writer.print("  %old_is_fiq = icmp eq i32 %old_mode, {d}\n", .{mode_fiq});
    try writer.print("  %new_is_fiq = icmp eq i32 %new_mode, {d}\n", .{mode_fiq});
    try writer.print("  %swap_needed = xor i1 %old_is_fiq, %new_is_fiq\n", .{});
    try writer.print("  br i1 %swap_needed, label %switch_swap, label %switch_store\n", .{});
    try writer.print("switch_swap:\n", .{});
    try writer.print(
        "  %switch_regs_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_regs_field},
    );
    try writer.print(
        "  %switch_fiq_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_fiq_regs_field},
    );
    inline for (0..7) |index| {
        const reg_index = index + 8;
        try writer.print(
            "  %switch_reg_ptr_r{d} = getelementptr inbounds [16 x i32], ptr %switch_regs_ptr, i32 0, i32 {d}\n",
            .{ reg_index, reg_index },
        );
        try writer.print(
            "  %switch_fiq_reg_ptr_r{d} = getelementptr inbounds [7 x i32], ptr %switch_fiq_ptr, i32 0, i32 {d}\n",
            .{ reg_index, index },
        );
        try writer.print("  %switch_reg_val_r{d} = load i32, ptr %switch_reg_ptr_r{d}, align 4\n", .{ reg_index, reg_index });
        try writer.print("  %switch_fiq_val_r{d} = load i32, ptr %switch_fiq_reg_ptr_r{d}, align 4\n", .{ reg_index, reg_index });
        try writer.print("  store i32 %switch_fiq_val_r{d}, ptr %switch_reg_ptr_r{d}, align 4\n", .{ reg_index, reg_index });
        try writer.print("  store i32 %switch_reg_val_r{d}, ptr %switch_fiq_reg_ptr_r{d}, align 4\n", .{ reg_index, reg_index });
    }
    try writer.print("  br label %switch_store\n", .{});
    try writer.print("switch_store:\n", .{});
    try writer.print("  store i32 %new_mode, ptr %mode_ptr, align 4\n", .{});
    try writer.print("  br label %switch_done\n", .{});
    try writer.print("switch_done:\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});

    try writer.print("define i32 @hmn_read_cpsr(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %cpsr_mode_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_mode_field},
    );
    try writer.print("  %cpsr_mode = load i32, ptr %cpsr_mode_ptr, align 4\n", .{});
    inline for (&.{
        .{ "n", guest_state_flag_n_field, 31 },
        .{ "z", guest_state_flag_z_field, 30 },
        .{ "c", guest_state_flag_c_field, 29 },
        .{ "v", guest_state_flag_v_field, 28 },
    }) |flag| {
        try writer.print(
            "  %cpsr_{s}_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ flag[0], flag[1] },
        );
        try writer.print("  %cpsr_{s}_val = load i1, ptr %cpsr_{s}_ptr, align 1\n", .{ flag[0], flag[0] });
        try writer.print("  %cpsr_{s}_i32 = zext i1 %cpsr_{s}_val to i32\n", .{ flag[0], flag[0] });
        try writer.print("  %cpsr_{s}_bits = shl i32 %cpsr_{s}_i32, {d}\n", .{ flag[0], flag[0], flag[2] });
    }
    try writer.print("  %cpsr_flags_nz = or i32 %cpsr_n_bits, %cpsr_z_bits\n", .{});
    try writer.print("  %cpsr_flags_cv = or i32 %cpsr_c_bits, %cpsr_v_bits\n", .{});
    try writer.print("  %cpsr_flags = or i32 %cpsr_flags_nz, %cpsr_flags_cv\n", .{});
    try writer.print("  %cpsr_value = or i32 %cpsr_flags, %cpsr_mode\n", .{});
    try writer.print("  ret i32 %cpsr_value\n", .{});
    try writer.print("}}\n\n", .{});

    try writer.print("define i32 @hmn_read_spsr(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %spsr_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_spsr_field},
    );
    try writer.print("  %spsr_val = load i32, ptr %spsr_ptr, align 4\n", .{});
    try writer.print("  ret i32 %spsr_val\n", .{});
    try writer.print("}}\n\n", .{});

    try writer.print("define void @hmn_write_cpsr(ptr %state, i32 %value, i32 %field_mask) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print("  %write_flags_mask = and i32 %field_mask, 8\n", .{});
    try writer.print("  %write_flags = icmp ne i32 %write_flags_mask, 0\n", .{});
    inline for (&.{
        .{ "n", guest_state_flag_n_field, 31 },
        .{ "z", guest_state_flag_z_field, 30 },
        .{ "c", guest_state_flag_c_field, 29 },
        .{ "v", guest_state_flag_v_field, 28 },
    }) |flag| {
        try writer.print(
            "  %write_cpsr_{s}_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ flag[0], flag[1] },
        );
        try writer.print("  %write_cpsr_old_{s} = load i1, ptr %write_cpsr_{s}_ptr, align 1\n", .{ flag[0], flag[0] });
        try writer.print("  %write_cpsr_new_{s}_shift = lshr i32 %value, {d}\n", .{ flag[0], flag[2] });
        try writer.print("  %write_cpsr_new_{s} = trunc i32 %write_cpsr_new_{s}_shift to i1\n", .{ flag[0], flag[0] });
        try writer.print(
            "  %write_cpsr_next_{s} = select i1 %write_flags, i1 %write_cpsr_new_{s}, i1 %write_cpsr_old_{s}\n",
            .{ flag[0], flag[0], flag[0] },
        );
        try writer.print("  store i1 %write_cpsr_next_{s}, ptr %write_cpsr_{s}_ptr, align 1\n", .{ flag[0], flag[0] });
    }
    try writer.print("  %write_control_mask = and i32 %field_mask, 1\n", .{});
    try writer.print("  %write_control = icmp ne i32 %write_control_mask, 0\n", .{});
    try writer.print("  br i1 %write_control, label %write_cpsr_control, label %write_cpsr_done\n", .{});
    try writer.print("write_cpsr_control:\n", .{});
    try writer.print("  %write_cpsr_mode = and i32 %value, 31\n", .{});
    try writer.print("  call void @hmn_switch_mode(ptr %state, i32 %write_cpsr_mode)\n", .{});
    try writer.print("  br label %write_cpsr_done\n", .{});
    try writer.print("write_cpsr_done:\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});

    try writer.print("define void @hmn_write_spsr(ptr %state, i32 %value, i32 %field_mask) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print(
        "  %write_spsr_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_spsr_field},
    );
    try writer.print("  %write_spsr_current = load i32, ptr %write_spsr_ptr, align 4\n", .{});
    try writer.print("  %write_spsr_flags_mask = and i32 %field_mask, 8\n", .{});
    try writer.print("  %write_spsr_flags = icmp ne i32 %write_spsr_flags_mask, 0\n", .{});
    try writer.print("  %write_spsr_clear_flags = and i32 %write_spsr_current, 268435455\n", .{});
    try writer.print("  %write_spsr_new_flags = and i32 %value, -268435456\n", .{});
    try writer.print("  %write_spsr_with_flags = or i32 %write_spsr_clear_flags, %write_spsr_new_flags\n", .{});
    try writer.print(
        "  %write_spsr_after_flags = select i1 %write_spsr_flags, i32 %write_spsr_with_flags, i32 %write_spsr_current\n",
        .{},
    );
    try writer.print("  %write_spsr_control_mask = and i32 %field_mask, 1\n", .{});
    try writer.print("  %write_spsr_control = icmp ne i32 %write_spsr_control_mask, 0\n", .{});
    try writer.print("  %write_spsr_clear_control = and i32 %write_spsr_after_flags, -32\n", .{});
    try writer.print("  %write_spsr_new_control = and i32 %value, 31\n", .{});
    try writer.print("  %write_spsr_with_control = or i32 %write_spsr_clear_control, %write_spsr_new_control\n", .{});
    try writer.print(
        "  %write_spsr_next = select i1 %write_spsr_control, i32 %write_spsr_with_control, i32 %write_spsr_after_flags\n",
        .{},
    );
    try writer.print("  store i32 %write_spsr_next, ptr %write_spsr_ptr, align 4\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});

    try writer.print("define void @hmn_restore_cpsr_from_spsr(ptr %state) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print("  %restore_spsr = call i32 @hmn_read_spsr(ptr %state)\n", .{});
    try writer.print("  call void @hmn_write_cpsr(ptr %state, i32 %restore_spsr, i32 9)\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitRomConstant(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    if (program.rom_bytes.len == 0) {
        try writer.print("@rom_data = private constant [0 x i8] zeroinitializer, align 1\n\n", .{});
        return;
    }

    try writer.print("@rom_data = private constant [{d} x i8] [", .{program.rom_bytes.len});
    for (program.rom_bytes, 0..) |byte, index| {
        if (index != 0) try writer.print(", ", .{});
        try writer.print("i8 {d}", .{byte});
    }
    try writer.print("], align 1\n\n", .{});
}

fn emitStoreHelpers(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try emitStoreHelper(writer, program, 32);
    try emitStoreHelper(writer, program, 16);
    try emitStoreHelper(writer, program, 8);
}

fn emitLoadHelper(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try writer.print("define i32 @hmn_load32(ptr %state, i32 %addr) {{\n", .{});
    try writer.print("entry:\n", .{});
    for (memory_regions) |region| {
        try writer.print(
            "  %{s}_load_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ region.field_name, region.field_index },
        );
    }
    try writer.print(
        "  %bios_latch_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_bios_latch_field},
    );
    try writer.print(
        "  %save_load_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_save_field},
    );
    try writer.print(
        "  %save_bank_load_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flash_bank_field},
    );
    try writer.print(
        "  %dispstat_toggle_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_dispstat_toggle_field},
    );
    try writer.print("  %bios_hit = icmp ult i32 %addr, 16384\n", .{});
    try writer.print("  %save_hit_ge = icmp uge i32 %addr, {d}\n", .{save_region_base});
    try writer.print("  %save_hit_lt = icmp ult i32 %addr, {d}\n", .{save_region_end});
    try writer.print("  %save_hit = and i1 %save_hit_ge, %save_hit_lt\n", .{});
    try writer.print("  %dispstat_hit = icmp eq i32 %addr, 67108868\n", .{});
    try writer.print("  br i1 %bios_hit, label %load_bios, label %check_rom\n", .{});
    try writer.print("load_bios:\n", .{});
    try writer.print("  %bios_value = load i32, ptr %bios_latch_ptr, align 4\n", .{});
    try writer.print("  ret i32 %bios_value\n", .{});
    try writer.print("check_rom:\n", .{});
    switch (program.save_hardware) {
        .none => {
            try writer.print("  br i1 %save_hit, label %load_save_none, label %check_real_rom\n", .{});
            try writer.print("load_save_none:\n", .{});
            try writer.print("  ret i32 -1\n", .{});
        },
        .sram, .flash64, .flash128 => {
            try writer.print("  br i1 %save_hit, label %load_save_sram, label %check_real_rom\n", .{});
            try writer.print("load_save_sram:\n", .{});
            try emitSaveNormalizedOffset(writer, "addr", "load32", saveMirrorLen(program.save_hardware));
            if (program.save_hardware == .flash128) {
                try writer.print("  %load32_save_bank = load i32, ptr %save_bank_load_ptr, align 4\n", .{});
                try writer.print("  %load32_save_bank_base = shl i32 %load32_save_bank, 16\n", .{});
                try writer.print("  %load32_save_effective_offset = add i32 %load32_save_bank_base, %load32_save_offset\n", .{});
            }
            try writer.print(
                "  %load32_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_load_ptr, i32 0, i32 %{s}\n",
                .{if (program.save_hardware == .flash128) "load32_save_effective_offset" else "load32_save_offset"},
            );
            try writer.print("  %load32_save_value = load i8, ptr %load32_save_ptr, align 1\n", .{});
            try writer.print("  %load32_save_i32 = zext i8 %load32_save_value to i32\n", .{});
            try writer.print("  %load32_save_fill = mul i32 %load32_save_i32, {d}\n", .{save_byte_fill32});
            try writer.print("  ret i32 %load32_save_fill\n", .{});
        },
    }
    try writer.print("check_real_rom:\n", .{});
    if (program.rom_bytes.len >= 4) {
        const rom_window_end = program.rom_base_address + 0x0600_0000;
        const rom_span = @as(u32, @intCast(program.rom_bytes.len)) - 3;
        try writer.print("  %rom_ge = icmp uge i32 %addr, {d}\n", .{program.rom_base_address});
        try writer.print("  %rom_lt = icmp ult i32 %addr, {d}\n", .{rom_window_end});
        try writer.print("  %rom_window_hit = and i1 %rom_ge, %rom_lt\n", .{});
        try writer.print("  %rom_window_offset = sub i32 %addr, {d}\n", .{program.rom_base_address});
        try writer.print("  %rom_offset = and i32 %rom_window_offset, 33554431\n", .{});
        try writer.print("  %rom_in_range = icmp ult i32 %rom_offset, {d}\n", .{rom_span});
        try writer.print("  %rom_hit = and i1 %rom_window_hit, %rom_in_range\n", .{});
        try writer.print("  br i1 %rom_hit, label %load_rom, label %check_dispstat\n", .{});
        try writer.print("load_rom:\n", .{});
        try writer.print(
            "  %rom_ptr = getelementptr inbounds [{d} x i8], ptr @rom_data, i32 0, i32 %rom_offset\n",
            .{program.rom_bytes.len},
        );
        try writer.print("  %rom_value = load i32, ptr %rom_ptr, align 1\n", .{});
        try writer.print("  ret i32 %rom_value\n", .{});
    }
    // Polling fixtures such as ppu-hello read DISPSTAT with 32-bit LDRs while
    // waiting for VBlank. Keep this as a compatibility polling shim only:
    // overlay synthetic VBlank state on bit 0, preserve the rest of the word,
    // and leave IRQ dispatch to explicit frame-boundary wait paths.
    try writer.print("check_dispstat:\n", .{});
    try writer.print("  br i1 %dispstat_hit, label %load_dispstat, label %check_load_region_0\n", .{});
    try writer.print("load_dispstat:\n", .{});
    try writer.print(
        "  %dispstat_ptr = getelementptr inbounds [1024 x i8], ptr %io_load_ptr, i32 0, i32 {d}\n",
        .{io_dispstat_offset},
    );
    try writer.print("  %dispstat_raw = load i32, ptr %dispstat_ptr, align 1\n", .{});
    try writer.print("  %dispstat_masked = and i32 %dispstat_raw, -2\n", .{});
    try writer.print("  %dispstat_toggle = load i1, ptr %dispstat_toggle_ptr, align 1\n", .{});
    try writer.print("  %dispstat_vblank = select i1 %dispstat_toggle, i32 1, i32 0\n", .{});
    try writer.print("  %dispstat_value = or i32 %dispstat_masked, %dispstat_vblank\n", .{});
    try writer.print("  %dispstat_next = xor i1 %dispstat_toggle, true\n", .{});
    try writer.print("  store i1 %dispstat_next, ptr %dispstat_toggle_ptr, align 1\n", .{});
    try writer.print("  ret i32 %dispstat_value\n", .{});

    for (memory_regions, 0..) |region, index| {
        try writer.print("check_load_region_{d}:\n", .{index});
        try writer.print("  %load_region_ge_{d} = icmp uge i32 %addr, {d}\n", .{ index, region.base });
        try writer.print("  %load_region_lt_{d} = icmp ult i32 %addr, {d}\n", .{ index, region.base + region.mapped_size });
        try writer.print("  %load_region_hit_{d} = and i1 %load_region_ge_{d}, %load_region_lt_{d}\n", .{
            index,
            index,
            index,
        });
        if (index + 1 < memory_regions.len) {
            try writer.print(
                "  br i1 %load_region_hit_{d}, label %load_region_{d}, label %check_load_region_{d}\n",
                .{ index, index, index + 1 },
            );
        } else {
            try writer.print(
                "  br i1 %load_region_hit_{d}, label %load_region_{d}, label %load_default\n",
                .{ index, index },
            );
        }

        try writer.print("load_region_{d}:\n", .{index});
        try emitRegionNormalizedOffset(writer, "addr", "load", index, region);
        try writer.print(
            "  %load_ptr_{d} = getelementptr inbounds [{d} x i8], ptr %{s}_load_ptr, i32 0, i32 %load_offset_{d}\n",
            .{ index, region.llvm_len, region.field_name, index },
        );
        try writer.print("  %load_value_{d} = load i32, ptr %load_ptr_{d}, align 1\n", .{ index, index });
        try writer.print("  ret i32 %load_value_{d}\n", .{index});
    }

    try writer.print("load_default:\n", .{});
    try writer.print("  ret i32 0\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitLoad8Helper(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try writer.print("define i32 @hmn_load8(ptr %state, i32 %addr) {{\n", .{});
    try writer.print("entry:\n", .{});
    for (memory_regions) |region| {
        try writer.print(
            "  %{s}_load8_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ region.field_name, region.field_index },
        );
    }
    try writer.print(
        "  %save_load8_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_save_field},
    );
    try writer.print(
        "  %save_bank_load8_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flash_bank_field},
    );
    try writer.print("  %save_hit8_ge = icmp uge i32 %addr, {d}\n", .{save_region_base});
    try writer.print("  %save_hit8_lt = icmp ult i32 %addr, {d}\n", .{save_region_end});
    try writer.print("  %save_hit8 = and i1 %save_hit8_ge, %save_hit8_lt\n", .{});
    if (program.rom_bytes.len != 0) {
        switch (program.save_hardware) {
            .none => {
                try writer.print("  br i1 %save_hit8, label %load8_save_none, label %check_load8_rom\n", .{});
                try writer.print("load8_save_none:\n", .{});
                try writer.print("  ret i32 255\n", .{});
            },
            .sram, .flash64, .flash128 => {
                try writer.print("  br i1 %save_hit8, label %load8_save_sram, label %check_load8_rom\n", .{});
                try writer.print("load8_save_sram:\n", .{});
                try emitSaveNormalizedOffset(writer, "addr", "load8", saveMirrorLen(program.save_hardware));
                if (program.save_hardware == .flash128) {
                    try writer.print("  %load8_save_bank = load i32, ptr %save_bank_load8_ptr, align 4\n", .{});
                    try writer.print("  %load8_save_bank_base = shl i32 %load8_save_bank, 16\n", .{});
                    try writer.print("  %load8_save_effective_offset = add i32 %load8_save_bank_base, %load8_save_offset\n", .{});
                }
                try writer.print(
                    "  %load8_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_load8_ptr, i32 0, i32 %{s}\n",
                    .{if (program.save_hardware == .flash128) "load8_save_effective_offset" else "load8_save_offset"},
                );
                try writer.print("  %load8_save_value = load i8, ptr %load8_save_ptr, align 1\n", .{});
                try writer.print("  %load8_save_i32 = zext i8 %load8_save_value to i32\n", .{});
                try writer.print("  ret i32 %load8_save_i32\n", .{});
            },
        }
        try writer.print("check_load8_rom:\n", .{});
        const rom_window_end = program.rom_base_address + 0x0600_0000;
        const rom_span = @as(u32, @intCast(program.rom_bytes.len));
        try writer.print("  %rom8_ge = icmp uge i32 %addr, {d}\n", .{program.rom_base_address});
        try writer.print("  %rom8_lt = icmp ult i32 %addr, {d}\n", .{rom_window_end});
        try writer.print("  %rom8_window_hit = and i1 %rom8_ge, %rom8_lt\n", .{});
        try writer.print("  %rom8_window_offset = sub i32 %addr, {d}\n", .{program.rom_base_address});
        try writer.print("  %rom8_offset = and i32 %rom8_window_offset, 33554431\n", .{});
        try writer.print("  %rom8_in_range = icmp ult i32 %rom8_offset, {d}\n", .{rom_span});
        try writer.print("  %rom8_hit = and i1 %rom8_window_hit, %rom8_in_range\n", .{});
        try writer.print("  br i1 %rom8_hit, label %load8_rom, label %check_load8_rom_default\n", .{});
        try writer.print("load8_rom:\n", .{});
        try writer.print(
            "  %rom8_ptr = getelementptr inbounds [{d} x i8], ptr @rom_data, i32 0, i32 %rom8_offset\n",
            .{program.rom_bytes.len},
        );
        try writer.print("  %rom8_value = load i8, ptr %rom8_ptr, align 1\n", .{});
        try writer.print("  %rom8_i32 = zext i8 %rom8_value to i32\n", .{});
        try writer.print("  ret i32 %rom8_i32\n", .{});
        try writer.print("check_load8_rom_default:\n", .{});
        try writer.print("  br i1 %rom8_window_hit, label %load8_rom_default, label %check_load8_region_0\n", .{});
        try writer.print("load8_rom_default:\n", .{});
        try writer.print("  %rom8_default_halfword = lshr i32 %addr, 1\n", .{});
        try writer.print("  %rom8_default_shift_sel = and i32 %addr, 1\n", .{});
        try writer.print("  %rom8_default_shift = shl i32 %rom8_default_shift_sel, 3\n", .{});
        try writer.print("  %rom8_default_shifted = lshr i32 %rom8_default_halfword, %rom8_default_shift\n", .{});
        try writer.print("  %rom8_default_byte = and i32 %rom8_default_shifted, 255\n", .{});
        try writer.print("  ret i32 %rom8_default_byte\n", .{});
    } else {
        switch (program.save_hardware) {
            .none => {
                try writer.print("  br i1 %save_hit8, label %load8_save_none, label %check_load8_region_0\n", .{});
                try writer.print("load8_save_none:\n", .{});
                try writer.print("  ret i32 255\n", .{});
            },
            .sram, .flash64, .flash128 => {
                try writer.print("  br i1 %save_hit8, label %load8_save_sram, label %check_load8_region_0\n", .{});
                try writer.print("load8_save_sram:\n", .{});
                try emitSaveNormalizedOffset(writer, "addr", "load8", saveMirrorLen(program.save_hardware));
                if (program.save_hardware == .flash128) {
                    try writer.print("  %load8_save_bank = load i32, ptr %save_bank_load8_ptr, align 4\n", .{});
                    try writer.print("  %load8_save_bank_base = shl i32 %load8_save_bank, 16\n", .{});
                    try writer.print("  %load8_save_effective_offset = add i32 %load8_save_bank_base, %load8_save_offset\n", .{});
                }
                try writer.print(
                    "  %load8_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_load8_ptr, i32 0, i32 %{s}\n",
                    .{if (program.save_hardware == .flash128) "load8_save_effective_offset" else "load8_save_offset"},
                );
                try writer.print("  %load8_save_value = load i8, ptr %load8_save_ptr, align 1\n", .{});
                try writer.print("  %load8_save_i32 = zext i8 %load8_save_value to i32\n", .{});
                try writer.print("  ret i32 %load8_save_i32\n", .{});
            },
        }
    }

    for (memory_regions, 0..) |region, index| {
        try writer.print("check_load8_region_{d}:\n", .{index});
        try writer.print("  %load8_region_ge_{d} = icmp uge i32 %addr, {d}\n", .{ index, region.base });
        try writer.print("  %load8_region_lt_{d} = icmp ult i32 %addr, {d}\n", .{ index, region.base + region.mapped_size });
        try writer.print("  %load8_region_hit_{d} = and i1 %load8_region_ge_{d}, %load8_region_lt_{d}\n", .{
            index,
            index,
            index,
        });
        if (index + 1 < memory_regions.len) {
            try writer.print(
                "  br i1 %load8_region_hit_{d}, label %load8_region_{d}, label %check_load8_region_{d}\n",
                .{ index, index, index + 1 },
            );
        } else {
            try writer.print(
                "  br i1 %load8_region_hit_{d}, label %load8_region_{d}, label %load8_default\n",
                .{ index, index },
            );
        }

        try writer.print("load8_region_{d}:\n", .{index});
        try emitRegionNormalizedOffset(writer, "addr", "load8", index, region);
        try writer.print(
            "  %load8_ptr_{d} = getelementptr inbounds [{d} x i8], ptr %{s}_load8_ptr, i32 0, i32 %load8_offset_{d}\n",
            .{ index, region.llvm_len, region.field_name, index },
        );
        try writer.print("  %load8_value_{d} = load i8, ptr %load8_ptr_{d}, align 1\n", .{ index, index });
        try writer.print("  %load8_i32_{d} = zext i8 %load8_value_{d} to i32\n", .{ index, index });
        try writer.print("  ret i32 %load8_i32_{d}\n", .{index});
    }

    try writer.print("load8_default:\n", .{});
    try writer.print("  ret i32 0\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitLoad16Helper(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try emitSizedLoadHelper(writer, program, 16, false);
}

fn emitLoad16SignedHelper(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try emitSizedLoadHelper(writer, program, 16, true);
}

fn emitLoad8SignedHelper(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try emitSizedLoadHelper(writer, program, 8, true);
}

fn emitSizedLoadHelper(
    writer: *Io.Writer,
    program: Program,
    comptime bits: u16,
    comptime signed: bool,
) Io.Writer.Error!void {
    const name = if (bits == 16 and !signed)
        "hmn_load16"
    else if (bits == 16 and signed)
        "hmn_load16s"
    else
        "hmn_load8s";
    const load_name = if (bits == 16 and !signed)
        "load16"
    else if (bits == 16 and signed)
        "load16s"
    else
        "load8s";
    const llvm_ty = if (bits == 16) "i16" else "i8";
    const cast_op = if (signed) "sext" else "zext";
    const byte_width: u32 = bits / 8;

    try writer.print("define i32 @{s}(ptr %state, i32 %addr) {{\n", .{name});
    try writer.print("entry:\n", .{});
    for (memory_regions) |region| {
        try writer.print(
            "  %{s}_{s}_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ region.field_name, load_name, region.field_index },
        );
    }
    try writer.print(
        "  %save_{s}_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ load_name, guest_state_save_field },
    );
    try writer.print(
        "  %save_{s}_bank_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ load_name, guest_state_flash_bank_field },
    );
    try writer.print("  %{s}_save_ge = icmp uge i32 %addr, {d}\n", .{ load_name, save_region_base });
    try writer.print("  %{s}_save_lt = icmp ult i32 %addr, {d}\n", .{ load_name, save_region_end });
    try writer.print("  %{s}_save_hit = and i1 %{s}_save_ge, %{s}_save_lt\n", .{ load_name, load_name, load_name });
    if (program.rom_bytes.len >= byte_width) {
        switch (program.save_hardware) {
            .none => {
                try writer.print("  br i1 %{s}_save_hit, label %{s}_save_none, label %check_{s}_rom\n", .{ load_name, load_name, load_name });
                try writer.print("{s}_save_none:\n", .{load_name});
                if (signed and bits == 8)
                    try writer.print("  ret i32 -1\n", .{})
                else if (signed and bits == 16)
                    try writer.print("  ret i32 -1\n", .{})
                else if (!signed and bits == 8)
                    try writer.print("  ret i32 255\n", .{})
                else
                    try writer.print("  ret i32 65535\n", .{});
            },
            .sram, .flash64, .flash128 => {
                try writer.print("  br i1 %{s}_save_hit, label %{s}_save_sram, label %check_{s}_rom\n", .{ load_name, load_name, load_name });
                try writer.print("{s}_save_sram:\n", .{load_name});
                try emitSaveNormalizedOffset(writer, "addr", load_name, saveMirrorLen(program.save_hardware));
                if (program.save_hardware == .flash128) {
                    try writer.print("  %{s}_save_bank = load i32, ptr %save_{s}_bank_ptr, align 4\n", .{ load_name, load_name });
                    try writer.print("  %{s}_save_bank_base = shl i32 %{s}_save_bank, 16\n", .{ load_name, load_name });
                    try writer.print("  %{s}_save_effective_offset = add i32 %{s}_save_bank_base, %{s}_save_offset\n", .{
                        load_name,
                        load_name,
                        load_name,
                    });
                }
                if (program.save_hardware == .flash128) {
                    try writer.print(
                        "  %{s}_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_{s}_ptr, i32 0, i32 %{s}_save_effective_offset\n",
                        .{ load_name, load_name, load_name },
                    );
                } else {
                    try writer.print(
                        "  %{s}_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_{s}_ptr, i32 0, i32 %{s}_save_offset\n",
                        .{ load_name, load_name, load_name },
                    );
                }
                try writer.print("  %{s}_save_value = load i8, ptr %{s}_save_ptr, align 1\n", .{ load_name, load_name });
                if (bits == 8) {
                    try writer.print("  %{s}_save_i32 = {s} i8 %{s}_save_value to i32\n", .{ load_name, cast_op, load_name });
                } else {
                    try writer.print("  %{s}_save_i16_byte = zext i8 %{s}_save_value to i16\n", .{ load_name, load_name });
                    try writer.print("  %{s}_save_i16 = mul i16 %{s}_save_i16_byte, {d}\n", .{ load_name, load_name, save_byte_fill16 });
                    try writer.print("  %{s}_save_i32 = {s} i16 %{s}_save_i16 to i32\n", .{ load_name, cast_op, load_name });
                }
                try writer.print("  ret i32 %{s}_save_i32\n", .{load_name});
            },
        }
        try writer.print("check_{s}_rom:\n", .{load_name});
        const rom_window_end = program.rom_base_address + 0x0600_0000;
        const rom_span = @as(u32, @intCast(program.rom_bytes.len)) - byte_width + 1;
        try writer.print("  %{s}_rom_ge = icmp uge i32 %addr, {d}\n", .{ load_name, program.rom_base_address });
        try writer.print("  %{s}_rom_lt = icmp ult i32 %addr, {d}\n", .{ load_name, rom_window_end });
        try writer.print("  %{s}_rom_window_hit = and i1 %{s}_rom_ge, %{s}_rom_lt\n", .{ load_name, load_name, load_name });
        try writer.print("  %{s}_rom_window_offset = sub i32 %addr, {d}\n", .{ load_name, program.rom_base_address });
        try writer.print("  %{s}_rom_offset = and i32 %{s}_rom_window_offset, 33554431\n", .{ load_name, load_name });
        try writer.print("  %{s}_rom_in_range = icmp ult i32 %{s}_rom_offset, {d}\n", .{ load_name, load_name, rom_span });
        try writer.print("  %{s}_rom_hit = and i1 %{s}_rom_window_hit, %{s}_rom_in_range\n", .{ load_name, load_name, load_name });
        try writer.print("  br i1 %{s}_rom_hit, label %{s}_rom, label %check_{s}_region_0\n", .{ load_name, load_name, load_name });
        try writer.print("{s}_rom:\n", .{load_name});
        try writer.print(
            "  %{s}_rom_ptr = getelementptr inbounds [{d} x i8], ptr @rom_data, i32 0, i32 %{s}_rom_offset\n",
            .{ load_name, program.rom_bytes.len, load_name },
        );
        try writer.print("  %{s}_rom_value = load {s}, ptr %{s}_rom_ptr, align 1\n", .{ load_name, llvm_ty, load_name });
        try writer.print("  %{s}_rom_i32 = {s} {s} %{s}_rom_value to i32\n", .{ load_name, cast_op, llvm_ty, load_name });
        try writer.print("  ret i32 %{s}_rom_i32\n", .{load_name});
    } else {
        switch (program.save_hardware) {
            .none => {
                try writer.print("  br i1 %{s}_save_hit, label %{s}_save_none, label %check_{s}_region_0\n", .{ load_name, load_name, load_name });
                try writer.print("{s}_save_none:\n", .{load_name});
                if (signed and bits == 8)
                    try writer.print("  ret i32 -1\n", .{})
                else if (signed and bits == 16)
                    try writer.print("  ret i32 -1\n", .{})
                else if (!signed and bits == 8)
                    try writer.print("  ret i32 255\n", .{})
                else
                    try writer.print("  ret i32 65535\n", .{});
            },
            .sram, .flash64, .flash128 => {
                try writer.print("  br i1 %{s}_save_hit, label %{s}_save_sram, label %check_{s}_region_0\n", .{ load_name, load_name, load_name });
                try writer.print("{s}_save_sram:\n", .{load_name});
                try emitSaveNormalizedOffset(writer, "addr", load_name, saveMirrorLen(program.save_hardware));
                if (program.save_hardware == .flash128) {
                    try writer.print("  %{s}_save_bank = load i32, ptr %save_{s}_bank_ptr, align 4\n", .{ load_name, load_name });
                    try writer.print("  %{s}_save_bank_base = shl i32 %{s}_save_bank, 16\n", .{ load_name, load_name });
                    try writer.print("  %{s}_save_effective_offset = add i32 %{s}_save_bank_base, %{s}_save_offset\n", .{
                        load_name,
                        load_name,
                        load_name,
                    });
                }
                if (program.save_hardware == .flash128) {
                    try writer.print(
                        "  %{s}_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_{s}_ptr, i32 0, i32 %{s}_save_effective_offset\n",
                        .{ load_name, load_name, load_name },
                    );
                } else {
                    try writer.print(
                        "  %{s}_save_ptr = getelementptr inbounds [131072 x i8], ptr %save_{s}_ptr, i32 0, i32 %{s}_save_offset\n",
                        .{ load_name, load_name, load_name },
                    );
                }
                try writer.print("  %{s}_save_value = load i8, ptr %{s}_save_ptr, align 1\n", .{ load_name, load_name });
                if (bits == 8) {
                    try writer.print("  %{s}_save_i32 = {s} i8 %{s}_save_value to i32\n", .{ load_name, cast_op, load_name });
                } else {
                    try writer.print("  %{s}_save_i16_byte = zext i8 %{s}_save_value to i16\n", .{ load_name, load_name });
                    try writer.print("  %{s}_save_i16 = mul i16 %{s}_save_i16_byte, {d}\n", .{ load_name, load_name, save_byte_fill16 });
                    try writer.print("  %{s}_save_i32 = {s} i16 %{s}_save_i16 to i32\n", .{ load_name, cast_op, load_name });
                }
                try writer.print("  ret i32 %{s}_save_i32\n", .{load_name});
            },
        }
    }

    for (memory_regions, 0..) |region, index| {
        try writer.print("check_{s}_region_{d}:\n", .{ load_name, index });
        try writer.print("  %{s}_region_ge_{d} = icmp uge i32 %addr, {d}\n", .{ load_name, index, region.base });
        try writer.print("  %{s}_region_lt_{d} = icmp ult i32 %addr, {d}\n", .{ load_name, index, region.base + region.mapped_size });
        try writer.print("  %{s}_region_hit_{d} = and i1 %{s}_region_ge_{d}, %{s}_region_lt_{d}\n", .{
            load_name,
            index,
            load_name,
            index,
            load_name,
            index,
        });
        if (index + 1 < memory_regions.len) {
            try writer.print(
                "  br i1 %{s}_region_hit_{d}, label %{s}_region_{d}, label %check_{s}_region_{d}\n",
                .{ load_name, index, load_name, index, load_name, index + 1 },
            );
        } else {
            try writer.print(
                "  br i1 %{s}_region_hit_{d}, label %{s}_region_{d}, label %{s}_default\n",
                .{ load_name, index, load_name, index, load_name },
            );
        }

        try writer.print("{s}_region_{d}:\n", .{ load_name, index });
        try emitRegionNormalizedOffset(writer, "addr", load_name, index, region);
        try writer.print(
            "  %{s}_ptr_{d} = getelementptr inbounds [{d} x i8], ptr %{s}_{s}_ptr, i32 0, i32 %{s}_offset_{d}\n",
            .{ load_name, index, region.llvm_len, region.field_name, load_name, load_name, index },
        );
        try writer.print("  %{s}_value_{d} = load {s}, ptr %{s}_ptr_{d}, align 1\n", .{ load_name, index, llvm_ty, load_name, index });
        try writer.print("  %{s}_i32_{d} = {s} {s} %{s}_value_{d} to i32\n", .{ load_name, index, cast_op, llvm_ty, load_name, index });
        try writer.print("  ret i32 %{s}_i32_{d}\n", .{ load_name, index });
    }

    try writer.print("{s}_default:\n", .{load_name});
    try writer.print("  ret i32 0\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitStoreHelper(writer: *Io.Writer, program: Program, bits: u16) Io.Writer.Error!void {
    const store_name = switch (bits) {
        32 => "store32",
        16 => "store16",
        8 => "store8",
        else => unreachable,
    };
    try writer.print("define void @hmn_store{d}(ptr %state, i32 %addr, i32 %value) {{\n", .{bits});
    try writer.print("entry:\n", .{});
    for (memory_regions) |region| {
        try writer.print(
            "  %{s}_ptr_{d} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ region.field_name, bits, region.field_index },
        );
    }
    const lane_mask: u32 = switch (bits) {
        8 => 0,
        16 => 1,
        32 => 3,
        else => unreachable,
    };

    switch (program.save_hardware) {
        .none => try writer.print("  br label %check_region_{d}_{d}\n", .{ bits, 0 }),
        .sram => {
            try writer.print(
                "  %save_ptr_{d} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{ bits, guest_state_save_field },
            );
            try writer.print("  %save_ge_{d} = icmp uge i32 %addr, {d}\n", .{ bits, save_region_base });
            try writer.print("  %save_lt_{d} = icmp ult i32 %addr, {d}\n", .{ bits, save_region_end });
            try writer.print("  %save_hit_{d} = and i1 %save_ge_{d}, %save_lt_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %save_hit_{d}, label %store_save_{d}, label %check_region_{d}_{d}\n", .{
                bits,
                bits,
                bits,
                0,
            });
            try writer.print("store_save_{d}:\n", .{bits});
            try emitSaveNormalizedOffset(writer, "addr", store_name, saveMirrorLen(program.save_hardware));
            try writer.print(
                "  %save_store_ptr_{d} = getelementptr inbounds [131072 x i8], ptr %save_ptr_{d}, i32 0, i32 %{s}_save_offset\n",
                .{ bits, bits, store_name },
            );
            if (bits == 8) {
                try writer.print("  %save_store_value_{d} = trunc i32 %value to i8\n", .{bits});
            } else {
                try writer.print("  %save_store_lane_{d} = and i32 %addr, {d}\n", .{ bits, lane_mask });
                try writer.print("  %save_store_shift_{d} = shl i32 %save_store_lane_{d}, 3\n", .{ bits, bits });
                try writer.print("  %save_store_shifted_{d} = lshr i32 %value, %save_store_shift_{d}\n", .{ bits, bits });
                try writer.print("  %save_store_value_{d} = trunc i32 %save_store_shifted_{d} to i8\n", .{ bits, bits });
            }
            try writer.print("  store i8 %save_store_value_{d}, ptr %save_store_ptr_{d}, align 1\n", .{ bits, bits });
            try writer.print("  br label %store_ret_{d}\n", .{bits});
        },
        .flash64, .flash128 => {
            try writer.print(
                "  %save_ptr_{d} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{ bits, guest_state_save_field },
            );
            try writer.print(
                "  %flash_stage_ptr_{d} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{ bits, guest_state_flash_stage_field },
            );
            try writer.print(
                "  %flash_mode_ptr_{d} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{ bits, guest_state_flash_mode_field },
            );
            if (program.save_hardware == .flash128) {
                try writer.print(
                    "  %flash_bank_ptr_{d} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                    .{ bits, guest_state_flash_bank_field },
                );
            }
            try writer.print("  %save_ge_{d} = icmp uge i32 %addr, {d}\n", .{ bits, save_region_base });
            try writer.print("  %save_lt_{d} = icmp ult i32 %addr, {d}\n", .{ bits, save_region_end });
            try writer.print("  %save_hit_{d} = and i1 %save_ge_{d}, %save_lt_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %save_hit_{d}, label %store_save_{d}, label %check_region_{d}_{d}\n", .{
                bits,
                bits,
                bits,
                0,
            });
            try writer.print("store_save_{d}:\n", .{bits});
            try emitSaveNormalizedOffset(writer, "addr", store_name, saveMirrorLen(program.save_hardware));
            if (program.save_hardware == .flash128) {
                try writer.print("  %flash_bank_{d} = load i32, ptr %flash_bank_ptr_{d}, align 4\n", .{ bits, bits });
                try writer.print("  %flash_bank_base_{d} = shl i32 %flash_bank_{d}, 16\n", .{ bits, bits });
                try writer.print("  %flash_effective_offset_{d} = add i32 %flash_bank_base_{d}, %{s}_save_offset\n", .{ bits, bits, store_name });
            }
            if (program.save_hardware == .flash128) {
                try writer.print(
                    "  %save_store_ptr_{d} = getelementptr inbounds [131072 x i8], ptr %save_ptr_{d}, i32 0, i32 %flash_effective_offset_{d}\n",
                    .{ bits, bits, bits },
                );
            } else {
                try writer.print(
                    "  %save_store_ptr_{d} = getelementptr inbounds [131072 x i8], ptr %save_ptr_{d}, i32 0, i32 %{s}_save_offset\n",
                    .{ bits, bits, store_name },
                );
            }
            if (bits == 8) {
                try writer.print("  %save_store_value_{d} = trunc i32 %value to i8\n", .{bits});
            } else {
                try writer.print("  %save_store_lane_{d} = and i32 %addr, {d}\n", .{ bits, lane_mask });
                try writer.print("  %save_store_shift_{d} = shl i32 %save_store_lane_{d}, 3\n", .{ bits, bits });
                try writer.print("  %save_store_shifted_{d} = lshr i32 %value, %save_store_shift_{d}\n", .{ bits, bits });
                try writer.print("  %save_store_value_{d} = trunc i32 %save_store_shifted_{d} to i8\n", .{ bits, bits });
            }
            try writer.print("  %flash_store_value_i32_{d} = zext i8 %save_store_value_{d} to i32\n", .{ bits, bits });
            try writer.print("  %flash_stage_{d} = load i32, ptr %flash_stage_ptr_{d}, align 4\n", .{ bits, bits });
            try writer.print("  %flash_mode_{d} = load i32, ptr %flash_mode_ptr_{d}, align 4\n", .{ bits, bits });
            try writer.print("  %flash_program_mode_{d} = icmp eq i32 %flash_mode_{d}, {d}\n", .{ bits, bits, flash_mode_program });
            if (program.save_hardware == .flash128) {
                try writer.print("  %flash_bank_mode_{d} = icmp eq i32 %flash_mode_{d}, {d}\n", .{ bits, bits, flash_mode_bank });
            }
            try writer.print("  br i1 %flash_program_mode_{d}, label %flash_program_write_{d}, label %flash_check_bank_mode_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_program_write_{d}:\n", .{bits});
            try writer.print("  store i8 %save_store_value_{d}, ptr %save_store_ptr_{d}, align 1\n", .{ bits, bits });
            try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_mode_ptr_{d}, align 4\n", .{bits});
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_check_bank_mode_{d}:\n", .{bits});
            if (program.save_hardware == .flash128) {
                try writer.print("  br i1 %flash_bank_mode_{d}, label %flash_bank_write_{d}, label %flash_command_{d}\n", .{
                    bits,
                    bits,
                    bits,
                });
                try writer.print("flash_bank_write_{d}:\n", .{bits});
                try writer.print("  %flash_bank_value_{d} = and i32 %flash_store_value_i32_{d}, 1\n", .{ bits, bits });
                try writer.print("  store i32 %flash_bank_value_{d}, ptr %flash_bank_ptr_{d}, align 4\n", .{ bits, bits });
                try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
                try writer.print("  store i32 0, ptr %flash_mode_ptr_{d}, align 4\n", .{bits});
                try writer.print("  br label %store_ret_{d}\n", .{bits});
            } else {
                try writer.print("  br label %flash_command_{d}\n", .{bits});
            }
            try writer.print("flash_command_{d}:\n", .{bits});
            try writer.print("  %flash_offset_is_5555_{d} = icmp eq i32 %{s}_save_offset, 21845\n", .{ bits, store_name });
            try writer.print("  %flash_offset_is_2aaa_{d} = icmp eq i32 %{s}_save_offset, 10922\n", .{ bits, store_name });
            try writer.print("  %flash_stage_zero_{d} = icmp eq i32 %flash_stage_{d}, 0\n", .{ bits, bits });
            try writer.print("  %flash_stage_one_{d} = icmp eq i32 %flash_stage_{d}, 1\n", .{ bits, bits });
            try writer.print("  %flash_stage_two_{d} = icmp eq i32 %flash_stage_{d}, 2\n", .{ bits, bits });
            try writer.print("  %flash_mode_erase_{d} = icmp eq i32 %flash_mode_{d}, {d}\n", .{ bits, bits, flash_mode_erase });
            try writer.print("  %flash_is_aa_{d} = icmp eq i32 %flash_store_value_i32_{d}, 170\n", .{ bits, bits });
            try writer.print("  %flash_is_55_{d} = icmp eq i32 %flash_store_value_i32_{d}, 85\n", .{ bits, bits });
            try writer.print("  %flash_unlock1_prehit_{d} = and i1 %flash_stage_zero_{d}, %flash_offset_is_5555_{d}\n", .{ bits, bits, bits });
            try writer.print("  %flash_unlock1_{d} = and i1 %flash_unlock1_prehit_{d}, %flash_is_aa_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %flash_unlock1_{d}, label %flash_unlock1_store_{d}, label %flash_check_unlock2_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_unlock1_store_{d}:\n", .{bits});
            try writer.print("  store i32 1, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_check_unlock2_{d}:\n", .{bits});
            try writer.print("  %flash_unlock2_prehit_{d} = and i1 %flash_stage_one_{d}, %flash_offset_is_2aaa_{d}\n", .{ bits, bits, bits });
            try writer.print("  %flash_unlock2_{d} = and i1 %flash_unlock2_prehit_{d}, %flash_is_55_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %flash_unlock2_{d}, label %flash_unlock2_store_{d}, label %flash_check_stage2_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_unlock2_store_{d}:\n", .{bits});
            try writer.print("  store i32 2, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_check_stage2_{d}:\n", .{bits});
            try writer.print("  br i1 %flash_stage_two_{d}, label %flash_stage2_{d}, label %flash_reset_stage_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_stage2_{d}:\n", .{bits});
            try writer.print("  %flash_is_a0_{d} = icmp eq i32 %flash_store_value_i32_{d}, 160\n", .{ bits, bits });
            try writer.print("  %flash_is_80_{d} = icmp eq i32 %flash_store_value_i32_{d}, 128\n", .{ bits, bits });
            if (program.save_hardware == .flash128) {
                try writer.print("  %flash_is_b0_{d} = icmp eq i32 %flash_store_value_i32_{d}, 176\n", .{ bits, bits });
            }
            try writer.print("  %flash_is_10_{d} = icmp eq i32 %flash_store_value_i32_{d}, 16\n", .{ bits, bits });
            try writer.print("  %flash_is_30_{d} = icmp eq i32 %flash_store_value_i32_{d}, 48\n", .{ bits, bits });
            try writer.print("  %flash_program_cmd_{d} = and i1 %flash_offset_is_5555_{d}, %flash_is_a0_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %flash_program_cmd_{d}, label %flash_enter_program_{d}, label %flash_check_bank_cmd_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_enter_program_{d}:\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  store i32 {d}, ptr %flash_mode_ptr_{d}, align 4\n", .{ flash_mode_program, bits });
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_check_bank_cmd_{d}:\n", .{bits});
            if (program.save_hardware == .flash128) {
                try writer.print("  %flash_bank_cmd_{d} = and i1 %flash_offset_is_5555_{d}, %flash_is_b0_{d}\n", .{ bits, bits, bits });
                try writer.print("  br i1 %flash_bank_cmd_{d}, label %flash_enter_bank_{d}, label %flash_check_erase_cmd_{d}\n", .{
                    bits,
                    bits,
                    bits,
                });
                try writer.print("flash_enter_bank_{d}:\n", .{bits});
                try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
                try writer.print("  store i32 {d}, ptr %flash_mode_ptr_{d}, align 4\n", .{ flash_mode_bank, bits });
                try writer.print("  br label %store_ret_{d}\n", .{bits});
            } else {
                try writer.print("  br label %flash_check_erase_cmd_{d}\n", .{bits});
            }
            try writer.print("flash_check_erase_cmd_{d}:\n", .{bits});
            try writer.print("  %flash_erase_cmd_{d} = and i1 %flash_offset_is_5555_{d}, %flash_is_80_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %flash_erase_cmd_{d}, label %flash_enter_erase_{d}, label %flash_check_chip_erase_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_enter_erase_{d}:\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  store i32 {d}, ptr %flash_mode_ptr_{d}, align 4\n", .{ flash_mode_erase, bits });
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_check_chip_erase_{d}:\n", .{bits});
            try writer.print("  %flash_chip_pre_{d} = and i1 %flash_mode_erase_{d}, %flash_offset_is_5555_{d}\n", .{ bits, bits, bits });
            try writer.print("  %flash_chip_cmd_{d} = and i1 %flash_chip_pre_{d}, %flash_is_10_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %flash_chip_cmd_{d}, label %flash_chip_erase_{d}, label %flash_check_sector_erase_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_chip_erase_{d}:\n", .{bits});
            try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %save_ptr_{d}, i8 -1, i64 {d}, i1 false)\n", .{ bits, save_storage_len });
            try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_mode_ptr_{d}, align 4\n", .{bits});
            if (program.save_hardware == .flash128) {
                try writer.print("  store i32 0, ptr %flash_bank_ptr_{d}, align 4\n", .{bits});
            }
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_check_sector_erase_{d}:\n", .{bits});
            try writer.print("  %flash_sector_cmd_{d} = and i1 %flash_mode_erase_{d}, %flash_is_30_{d}\n", .{ bits, bits, bits });
            try writer.print("  br i1 %flash_sector_cmd_{d}, label %flash_sector_erase_{d}, label %flash_reset_stage_{d}\n", .{
                bits,
                bits,
                bits,
            });
            try writer.print("flash_sector_erase_{d}:\n", .{bits});
            try writer.print("  %flash_sector_base_{d} = and i32 %{s}_save_offset, 61440\n", .{ bits, store_name });
            if (program.save_hardware == .flash128) {
                try writer.print("  %flash_sector_bank_base_{d} = shl i32 %flash_bank_{d}, 16\n", .{ bits, bits });
                try writer.print("  %flash_sector_effective_base_{d} = add i32 %flash_sector_bank_base_{d}, %flash_sector_base_{d}\n", .{
                    bits,
                    bits,
                    bits,
                });
            }
            if (program.save_hardware == .flash128) {
                try writer.print(
                    "  %flash_sector_ptr_{d} = getelementptr inbounds [131072 x i8], ptr %save_ptr_{d}, i32 0, i32 %flash_sector_effective_base_{d}\n",
                    .{ bits, bits, bits },
                );
            } else {
                try writer.print(
                    "  %flash_sector_ptr_{d} = getelementptr inbounds [131072 x i8], ptr %save_ptr_{d}, i32 0, i32 %flash_sector_base_{d}\n",
                    .{ bits, bits, bits },
                );
            }
            try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %flash_sector_ptr_{d}, i8 -1, i64 4096, i1 false)\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_mode_ptr_{d}, align 4\n", .{bits});
            try writer.print("  br label %store_ret_{d}\n", .{bits});
            try writer.print("flash_reset_stage_{d}:\n", .{bits});
            try writer.print("  store i32 0, ptr %flash_stage_ptr_{d}, align 4\n", .{bits});
            try writer.print("  br label %store_ret_{d}\n", .{bits});
        },
    }
    for (memory_regions, 0..) |region, index| {
        try emitRegionDispatch(writer, bits, store_name, region, index);
    }
    try writer.print("store_ret_{d}:\n", .{bits});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitRegionDispatch(
    writer: *Io.Writer,
    bits: u16,
    store_name: []const u8,
    region: Region,
    index: usize,
) Io.Writer.Error!void {
    try writer.print("check_region_{d}_{d}:\n", .{ bits, index });
    try writer.print("  %region_ge_{d}_{d} = icmp uge i32 %addr, {d}\n", .{ bits, index, region.base });
    try writer.print("  %region_lt_{d}_{d} = icmp ult i32 %addr, {d}\n", .{ bits, index, region.base + region.mapped_size });
    try writer.print("  %region_hit_{d}_{d} = and i1 %region_ge_{d}_{d}, %region_lt_{d}_{d}\n", .{
        bits,
        index,
        bits,
        index,
        bits,
        index,
    });
    if (index + 1 < memory_regions.len) {
        try writer.print("  br i1 %region_hit_{d}_{d}, label %store_region_{d}_{d}, label %check_region_{d}_{d}\n", .{
            bits,
            index,
            bits,
            index,
            bits,
            index + 1,
        });
    } else {
        try writer.print("  br i1 %region_hit_{d}_{d}, label %store_region_{d}_{d}, label %store_ret_{d}\n", .{
            bits,
            index,
            bits,
            index,
            bits,
        });
    }

    try writer.print("store_region_{d}_{d}:\n", .{ bits, index });
    try emitRegionNormalizedOffset(writer, "addr", store_name, index, region);
    try writer.print(
        "  %ptr_{d}_{d} = getelementptr inbounds [{d} x i8], ptr %{s}_ptr_{d}, i32 0, i32 %{s}_offset_{d}\n",
        .{ bits, index, region.llvm_len, region.field_name, bits, store_name, index },
    );
    switch (bits) {
        32 => try writer.print("  store i32 %value, ptr %ptr_{d}_{d}, align 1\n", .{ bits, index }),
        16 => {
            if (region.field_index == guest_state_io_field) {
                try writer.print("  %io_special_ie_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_ie_offset,
                });
                try writer.print("  %io_special_if_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_if_offset,
                });
                try writer.print("  %io_special_ime_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_ime_offset,
                });
                try writer.print("  %io_special_any0_{d}_{d} = or i1 %io_special_ie_{d}_{d}, %io_special_if_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  %io_special_any_{d}_{d} = or i1 %io_special_any0_{d}_{d}, %io_special_ime_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  br i1 %io_special_any_{d}_{d}, label %io_store_special_{d}_{d}, label %io_store_raw_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("io_store_special_{d}_{d}:\n", .{ bits, index });
                try writer.print("  %value16_{d}_{d} = trunc i32 %value to i16\n", .{ bits, index });
                try writer.print(
                    "  call void @hmn_store_gba_io16(ptr %state, i32 %{s}_offset_{d}, i16 %value16_{d}_{d}, ptr %ptr_{d}_{d})\n",
                    .{ store_name, index, bits, index, bits, index },
                );
                try writer.print("  br label %store_ret_{d}\n", .{bits});
                try writer.print("io_store_raw_{d}_{d}:\n", .{ bits, index });
                try writer.print("  %value16_raw_{d}_{d} = trunc i32 %value to i16\n", .{ bits, index });
                try writer.print("  store i16 %value16_raw_{d}_{d}, ptr %ptr_{d}_{d}, align 1\n", .{ bits, index, bits, index });
                try writer.print("  br label %store_ret_{d}\n", .{bits});
                return;
            }
            try writer.print("  %value16_{d}_{d} = trunc i32 %value to i16\n", .{ bits, index });
            try writer.print("  store i16 %value16_{d}_{d}, ptr %ptr_{d}_{d}, align 1\n", .{ bits, index, bits, index });
        },
        8 => {
            if (region.field_index == guest_state_io_field) {
                try writer.print("  %io_byte_special_ie_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_ie_offset,
                });
                try writer.print("  %io_byte_special_ie_hi_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_ie_offset + 1,
                });
                try writer.print("  %io_byte_special_if_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_if_offset,
                });
                try writer.print("  %io_byte_special_if_hi_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_if_offset + 1,
                });
                try writer.print("  %io_byte_special_ime_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_ime_offset,
                });
                try writer.print("  %io_byte_special_ime_hi_{d}_{d} = icmp eq i32 %{s}_offset_{d}, {d}\n", .{
                    bits,
                    index,
                    store_name,
                    index,
                    io_ime_offset + 1,
                });
                try writer.print("  %io_byte_special_ie_any_{d}_{d} = or i1 %io_byte_special_ie_{d}_{d}, %io_byte_special_ie_hi_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  %io_byte_special_if_any_{d}_{d} = or i1 %io_byte_special_if_{d}_{d}, %io_byte_special_if_hi_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  %io_byte_special_ime_any_{d}_{d} = or i1 %io_byte_special_ime_{d}_{d}, %io_byte_special_ime_hi_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  %io_byte_special_any0_{d}_{d} = or i1 %io_byte_special_ie_any_{d}_{d}, %io_byte_special_if_any_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  %io_byte_special_any_{d}_{d} = or i1 %io_byte_special_any0_{d}_{d}, %io_byte_special_ime_any_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("  br i1 %io_byte_special_any_{d}_{d}, label %io_byte_store_fail_{d}_{d}, label %io_byte_store_raw_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print("io_byte_store_fail_{d}_{d}:\n", .{ bits, index });
                try writer.print("  call void @hmn_interrupt_fail_byte_store(ptr %state, i32 %addr)\n", .{});
                try writer.print("  br label %store_ret_{d}\n", .{bits});
                try writer.print("io_byte_store_raw_{d}_{d}:\n", .{ bits, index });
                try writer.print("  %value8_{d}_{d} = trunc i32 %value to i8\n", .{ bits, index });
                try writer.print("  store i8 %value8_{d}_{d}, ptr %ptr_{d}_{d}, align 1\n", .{ bits, index, bits, index });
                try writer.print("  br label %store_ret_{d}\n", .{bits});
                return;
            } else if (region.field_index == guest_state_oam_field) {
                // OAM byte stores are ignored on GBA.
            } else if (region.field_index == guest_state_palette_field or region.field_index == guest_state_vram_field) {
                try writer.print("  %value8_{d}_{d} = trunc i32 %value to i8\n", .{ bits, index });
                try writer.print("  %value16_lo_{d}_{d} = zext i8 %value8_{d}_{d} to i16\n", .{ bits, index, bits, index });
                try writer.print("  %value16_hi_{d}_{d} = shl i16 %value16_lo_{d}_{d}, 8\n", .{ bits, index, bits, index });
                try writer.print("  %value16_rep_{d}_{d} = or i16 %value16_lo_{d}_{d}, %value16_hi_{d}_{d}\n", .{
                    bits,
                    index,
                    bits,
                    index,
                    bits,
                    index,
                });
                try writer.print(
                    "  %{s}_halfword_offset_{d} = and i32 %{s}_offset_{d}, -2\n",
                    .{ store_name, index, store_name, index },
                );
                try writer.print(
                    "  %ptr16_{d}_{d} = getelementptr inbounds [{d} x i8], ptr %{s}_ptr_{d}, i32 0, i32 %{s}_halfword_offset_{d}\n",
                    .{ bits, index, region.llvm_len, region.field_name, bits, store_name, index },
                );
                try writer.print("  store i16 %value16_rep_{d}_{d}, ptr %ptr16_{d}_{d}, align 1\n", .{ bits, index, bits, index });
            } else {
                try writer.print("  %value8_{d}_{d} = trunc i32 %value to i8\n", .{ bits, index });
                try writer.print("  store i8 %value8_{d}_{d}, ptr %ptr_{d}_{d}, align 1\n", .{ bits, index, bits, index });
            }
        },
        else => unreachable,
    }
    try writer.print("  br label %store_ret_{d}\n", .{bits});
}

fn emitGuestFunction(writer: *Io.Writer, function: Function) Io.Writer.Error!void {
    try writer.print("define void @guest_{s}_{x:0>8}(ptr %state) {{\n", .{
        instructionSetName(function.entry.isa),
        function.entry.address,
    });
    try writer.print("entry:\n", .{});
    try emitBranchTo(writer, function.entry.address);
    for (function.instructions, 0..) |node, index| {
        try emitInstructionBlock(writer, function, index, node);
    }
    try writer.print("guest_return_{s}_{x:0>8}:\n", .{
        instructionSetName(function.entry.isa),
        function.entry.address,
    });
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitGuestCallDispatcher(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try writer.print("define void @hmn_call_guest(ptr %state, i32 %target) {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print("  switch i32 %target, label %dispatch_done [\n", .{});
    for (program.functions) |function| {
        const raw_target = function.entry.address | if (function.entry.isa == .thumb) @as(u32, 1) else @as(u32, 0);
        try writer.print("    i32 {d}, label %dispatch_{s}_{x:0>8}\n", .{
            raw_target,
            instructionSetName(function.entry.isa),
            function.entry.address,
        });
    }
    try writer.print("  ]\n", .{});
    for (program.functions) |function| {
        try writer.print("dispatch_{s}_{x:0>8}:\n", .{
            instructionSetName(function.entry.isa),
            function.entry.address,
        });
        try writer.print("  call void @guest_{s}_{x:0>8}(ptr %state)\n", .{
            instructionSetName(function.entry.isa),
            function.entry.address,
        });
        try writer.print("  br label %dispatch_done\n", .{});
    }
    try writer.print("dispatch_done:\n", .{});
    try writer.print("  ret void\n", .{});
    try writer.print("}}\n\n", .{});
}

fn emitMain(writer: *Io.Writer, program: Program) Io.Writer.Error!void {
    try writer.print("define i32 @main() {{\n", .{});
    try writer.print("entry:\n", .{});
    try writer.print("  %state = alloca %GuestState, align 4\n", .{});
    try writer.print(
        "  %state_regs_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_regs_field},
    );
    try writer.print(
        "  %state_flag_n_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flag_n_field},
    );
    try writer.print(
        "  %state_flag_z_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flag_z_field},
    );
    try writer.print(
        "  %state_flag_c_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flag_c_field},
    );
    try writer.print(
        "  %state_flag_v_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flag_v_field},
    );
    try writer.print(
        "  %state_bios_latch_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_bios_latch_field},
    );
    try writer.print(
        "  %state_ewram_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_ewram_field},
    );
    try writer.print(
        "  %state_iwram_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_iwram_field},
    );
    try writer.print(
        "  %state_oam_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_oam_field},
    );
    try writer.print(
        "  %state_io_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_io_field},
    );
    try writer.print(
        "  %state_palette_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_palette_field},
    );
    try writer.print(
        "  %state_vram_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_vram_field},
    );
    try writer.print(
        "  %state_dispstat_toggle_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_dispstat_toggle_field},
    );
    try writer.print(
        "  %state_mode_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_mode_field},
    );
    try writer.print(
        "  %state_spsr_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_spsr_field},
    );
    try writer.print(
        "  %state_fiq_regs_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_fiq_regs_field},
    );
    try writer.print(
        "  %state_save_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_save_field},
    );
    try writer.print(
        "  %state_flash_stage_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flash_stage_field},
    );
    try writer.print(
        "  %state_flash_mode_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flash_mode_field},
    );
    try writer.print(
        "  %state_flash_bank_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_flash_bank_field},
    );
    try writer.print(
        "  %state_instruction_budget_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_instruction_budget_field},
    );
    try writer.print(
        "  %state_stop_flag_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_stop_flag_field},
    );
    try writer.print(
        "  %state_retired_count_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_retired_count_field},
    );
    try writer.print(
        "  %state_retired_block_remaining_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_retired_block_remaining_field},
    );
    try writer.print(
        "  %state_vblank_count_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_vblank_count_field},
    );
    try writer.print(
        "  %state_in_irq_handler_ptr = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{guest_state_in_irq_handler_field},
    );
    try writer.print("  %state_sp_ptr = getelementptr inbounds [16 x i32], ptr %state_regs_ptr, i32 0, i32 13\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 4 %state_regs_ptr, i8 0, i64 64, i1 false)\n", .{});
    try writer.print("  store i1 false, ptr %state_flag_n_ptr, align 1\n", .{});
    try writer.print("  store i1 false, ptr %state_flag_z_ptr, align 1\n", .{});
    try writer.print("  store i1 false, ptr %state_flag_c_ptr, align 1\n", .{});
    try writer.print("  store i1 false, ptr %state_flag_v_ptr, align 1\n", .{});
    try writer.print("  store i32 3777622016, ptr %state_bios_latch_ptr, align 4\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_ewram_ptr, i8 0, i64 262144, i1 false)\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_iwram_ptr, i8 0, i64 32768, i1 false)\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_io_ptr, i8 0, i64 1024, i1 false)\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_palette_ptr, i8 0, i64 1024, i1 false)\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_vram_ptr, i8 0, i64 98304, i1 false)\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_oam_ptr, i8 0, i64 1024, i1 false)\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 1 %state_save_ptr, i8 -1, i64 131072, i1 false)\n", .{});
    try writer.print("  store i32 0, ptr %state_flash_stage_ptr, align 4\n", .{});
    try writer.print("  store i32 0, ptr %state_flash_mode_ptr, align 4\n", .{});
    try writer.print("  store i32 0, ptr %state_flash_bank_ptr, align 4\n", .{});
    try writer.print("  store i1 true, ptr %state_dispstat_toggle_ptr, align 1\n", .{});
    try writer.print("  store i32 {d}, ptr %state_mode_ptr, align 4\n", .{mode_system});
    try writer.print("  store i32 0, ptr %state_spsr_ptr, align 4\n", .{});
    try writer.print("  call void @llvm.memset.p0.i64(ptr align 4 %state_fiq_regs_ptr, i8 0, i64 28, i1 false)\n", .{});
    if (program.output_mode == .frame_raw or program.output_mode == .retired_count) {
        try writer.print("  %frame_budget = call i64 @hm_runtime_max_instructions(i64 {d})\n", .{program.instruction_limit orelse 0});
        try writer.print("  store i64 %frame_budget, ptr %state_instruction_budget_ptr, align 8\n", .{});
    } else {
        try writer.print("  store i64 -1, ptr %state_instruction_budget_ptr, align 8\n", .{});
    }
    try writer.print("  store i1 false, ptr %state_stop_flag_ptr, align 1\n", .{});
    try writer.print("  store i64 0, ptr %state_retired_count_ptr, align 8\n", .{});
    try writer.print("  store i64 0, ptr %state_retired_block_remaining_ptr, align 8\n", .{});
    try writer.print("  store i64 0, ptr %state_vblank_count_ptr, align 8\n", .{});
    try writer.print("  store i1 false, ptr %state_in_irq_handler_ptr, align 1\n", .{});
    try writer.print("  %initial_keyinput = call i16 @hmgba_sample_keyinput_for_frame(i64 0)\n", .{});
    try writer.print(
        "  %state_keyinput_ptr = getelementptr inbounds [1024 x i8], ptr %state_io_ptr, i32 0, i32 {d}\n",
        .{io_keyinput_offset},
    );
    try writer.print("  store i16 %initial_keyinput, ptr %state_keyinput_ptr, align 1\n", .{});
    try writer.print("  store i32 50364416, ptr %state_sp_ptr, align 4\n", .{});
    try writer.print("  call void @guest_{s}_{x:0>8}(ptr %state)\n", .{
        instructionSetName(program.entry.isa),
        program.entry.address,
    });
    try emitFinalOutput(writer, program.output_mode);
    try writer.print("  ret i32 0\n", .{});
    try writer.print("}}\n", .{});
}

fn emitInstructionBlock(
    writer: *Io.Writer,
    function: Function,
    index: usize,
    node: InstructionNode,
) Io.Writer.Error!void {
    const block_info = retiredBlockInfo(function, index);

    try writer.print("pc_{x:0>8}:\n", .{node.address});
    if (block_info.instruction_count > 1) {
        try emitRetiredBlockDispatch(writer, function.entry, node.address, block_info);
    } else {
        try writer.print("  br label %retired_block_regular_{x:0>8}\n", .{node.address});
        try emitInstructionAccountingPath(writer, function.entry, node.address, "retired_block_regular", .regular);
    }
    try writer.print("pc_exec_{x:0>8}:\n", .{node.address});
    try emitArchitecturalPcState(writer, function.entry.isa, node.address);
    if (node.condition != .al and !instructionHandlesOwnCondition(node.instruction)) {
        try emitBranchCondition(writer, "state", node.address, node.condition);
        try writer.print(
            "  br i1 %branch_cond_{x:0>8}, label %pc_body_{x:0>8}, label %pc_skip_{x:0>8}\n",
            .{ node.address, node.address, node.address },
        );
        try writer.print("pc_body_{x:0>8}:\n", .{node.address});
        try emitInstructionBody(writer, function, node);
        try writer.print("pc_skip_{x:0>8}:\n", .{node.address});
        try emitFallthrough(writer, function, node.address + node.size_bytes);
        return;
    }

    try emitInstructionBody(writer, function, node);
}

fn emitRetiredBlockDispatch(
    writer: *Io.Writer,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    block_info: RetiredBlockInfo,
) Io.Writer.Error!void {
    try writer.print(
        "  %retired_block_remaining_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ address, guest_state_retired_block_remaining_field },
    );
    try writer.print(
        "  %retired_block_remaining_{x:0>8} = load i64, ptr %retired_block_remaining_ptr_{x:0>8}, align 8\n",
        .{ address, address },
    );
    try writer.print(
        "  %retired_block_has_prepaid_{x:0>8} = icmp ne i64 %retired_block_remaining_{x:0>8}, 0\n",
        .{ address, address },
    );

    if (block_info.is_leader) {
        try writer.print(
            "  br i1 %retired_block_has_prepaid_{x:0>8}, label %retired_block_prepaid_dispatch_{x:0>8}, label %retired_block_prepay_check_{x:0>8}\n",
            .{ address, address, address },
        );
        try writer.print("retired_block_prepay_check_{x:0>8}:\n", .{address});
        try writer.print(
            "  %retired_block_budget_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
            .{ address, guest_state_instruction_budget_field },
        );
        try writer.print(
            "  %retired_block_budget_{x:0>8} = load i64, ptr %retired_block_budget_ptr_{x:0>8}, align 8\n",
            .{ address, address },
        );
        try writer.print(
            "  %retired_block_budget_unlimited_{x:0>8} = icmp eq i64 %retired_block_budget_{x:0>8}, -1\n",
            .{ address, address },
        );
        try writer.print(
            "  br i1 %retired_block_budget_unlimited_{x:0>8}, label %retired_block_prepay_ready_{x:0>8}, label %retired_block_budget_check_{x:0>8}\n",
            .{ address, address, address },
        );
        try writer.print("retired_block_budget_check_{x:0>8}:\n", .{address});
        try writer.print(
            "  %retired_block_budget_enough_{x:0>8} = icmp uge i64 %retired_block_budget_{x:0>8}, {d}\n",
            .{ address, address, block_info.instruction_count },
        );
        try writer.print(
            "  br i1 %retired_block_budget_enough_{x:0>8}, label %retired_block_prepay_ready_{x:0>8}, label %retired_block_regular_{x:0>8}\n",
            .{ address, address, address },
        );
        try writer.print("retired_block_prepay_ready_{x:0>8}:\n", .{address});
        try emitRetiredInstructionIncrement(writer, address, "retired_block_prepay_ready", block_info.instruction_count);
        try writer.print(
            "  store i64 {d}, ptr %retired_block_remaining_ptr_{x:0>8}, align 8\n",
            .{ block_info.instruction_count, address },
        );
        try writer.print("  br label %retired_block_prepaid_dispatch_{x:0>8}\n", .{address});
    } else {
        try writer.print(
            "  br i1 %retired_block_has_prepaid_{x:0>8}, label %retired_block_prepaid_dispatch_{x:0>8}, label %retired_block_regular_{x:0>8}\n",
            .{ address, address, address },
        );
    }

    try writer.print("retired_block_prepaid_dispatch_{x:0>8}:\n", .{address});
    try writer.print(
        "  %retired_block_remaining_curr_{x:0>8} = load i64, ptr %retired_block_remaining_ptr_{x:0>8}, align 8\n",
        .{ address, address },
    );
    try writer.print(
        "  %retired_block_remaining_next_{x:0>8} = sub i64 %retired_block_remaining_curr_{x:0>8}, 1\n",
        .{ address, address },
    );
    try writer.print(
        "  store i64 %retired_block_remaining_next_{x:0>8}, ptr %retired_block_remaining_ptr_{x:0>8}, align 8\n",
        .{ address, address },
    );
    try writer.print("  br label %retired_block_prepaid_{x:0>8}\n", .{address});
    try emitInstructionAccountingPath(writer, function_entry, address, "retired_block_prepaid", .prepaid);
    try emitInstructionAccountingPath(writer, function_entry, address, "retired_block_regular", .regular);
}

fn emitRetiredInstructionIncrement(
    writer: *Io.Writer,
    address: u32,
    label_prefix: []const u8,
    count: u32,
) Io.Writer.Error!void {
    try writer.print(
        "  %{s}_retired_count_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ label_prefix, address, guest_state_retired_count_field },
    );
    try writer.print(
        "  %{s}_retired_count_{x:0>8} = load i64, ptr %{s}_retired_count_ptr_{x:0>8}, align 8\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print(
        "  %{s}_retired_count_next_{x:0>8} = add i64 %{s}_retired_count_{x:0>8}, {d}\n",
        .{ label_prefix, address, label_prefix, address, count },
    );
    try writer.print(
        "  store i64 %{s}_retired_count_next_{x:0>8}, ptr %{s}_retired_count_ptr_{x:0>8}, align 8\n",
        .{ label_prefix, address, label_prefix, address },
    );
}

fn emitInstructionAccountingPath(
    writer: *Io.Writer,
    function_entry: armv4t_decode.CodeAddress,
    address: u32,
    label_prefix: []const u8,
    count_mode: RetiredCountMode,
) Io.Writer.Error!void {
    try writer.print("{s}_{x:0>8}:\n", .{ label_prefix, address });
    try writer.print(
        "  %{s}_stop_flag_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ label_prefix, address, guest_state_stop_flag_field },
    );
    try writer.print(
        "  %{s}_stop_flag_{x:0>8} = load i1, ptr %{s}_stop_flag_ptr_{x:0>8}, align 1\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print(
        "  br i1 %{s}_stop_flag_{x:0>8}, label %{s}_stop_return_{x:0>8}, label %{s}_budget_check_{x:0>8}\n",
        .{ label_prefix, address, label_prefix, address, label_prefix, address },
    );
    try writer.print("{s}_stop_return_{x:0>8}:\n", .{ label_prefix, address });
    try writer.print("  br label %guest_return_{s}_{x:0>8}\n", .{
        instructionSetName(function_entry.isa),
        function_entry.address,
    });
    try writer.print("{s}_budget_check_{x:0>8}:\n", .{ label_prefix, address });
    try writer.print(
        "  %{s}_instruction_budget_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ label_prefix, address, guest_state_instruction_budget_field },
    );
    try writer.print(
        "  %{s}_instruction_budget_{x:0>8} = load i64, ptr %{s}_instruction_budget_ptr_{x:0>8}, align 8\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print(
        "  %{s}_instruction_budget_unlimited_{x:0>8} = icmp eq i64 %{s}_instruction_budget_{x:0>8}, -1\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print(
        "  br i1 %{s}_instruction_budget_unlimited_{x:0>8}, label %{s}_budget_continue_{x:0>8}, label %{s}_budget_finite_{x:0>8}\n",
        .{ label_prefix, address, label_prefix, address, label_prefix, address },
    );
    try writer.print("{s}_budget_finite_{x:0>8}:\n", .{ label_prefix, address });
    try writer.print(
        "  %{s}_instruction_budget_empty_{x:0>8} = icmp eq i64 %{s}_instruction_budget_{x:0>8}, 0\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print(
        "  br i1 %{s}_instruction_budget_empty_{x:0>8}, label %{s}_budget_stop_{x:0>8}, label %{s}_budget_decrement_{x:0>8}\n",
        .{ label_prefix, address, label_prefix, address, label_prefix, address },
    );
    try writer.print("{s}_budget_stop_{x:0>8}:\n", .{ label_prefix, address });
    try writer.print(
        "  store i1 true, ptr %{s}_stop_flag_ptr_{x:0>8}, align 1\n",
        .{ label_prefix, address },
    );
    try writer.print("  br label %guest_return_{s}_{x:0>8}\n", .{
        instructionSetName(function_entry.isa),
        function_entry.address,
    });
    try writer.print("{s}_budget_decrement_{x:0>8}:\n", .{ label_prefix, address });
    try writer.print(
        "  %{s}_instruction_budget_next_{x:0>8} = sub i64 %{s}_instruction_budget_{x:0>8}, 1\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print(
        "  store i64 %{s}_instruction_budget_next_{x:0>8}, ptr %{s}_instruction_budget_ptr_{x:0>8}, align 8\n",
        .{ label_prefix, address, label_prefix, address },
    );
    try writer.print("  br label %{s}_budget_continue_{x:0>8}\n", .{ label_prefix, address });
    try writer.print("{s}_budget_continue_{x:0>8}:\n", .{ label_prefix, address });
    switch (count_mode) {
        .regular => try emitRetiredInstructionIncrement(writer, address, label_prefix, 1),
        .prepaid => {},
    }
    try writer.print("  br label %pc_exec_{x:0>8}\n", .{address});
}

fn retiredBlockInfo(function: Function, index: usize) RetiredBlockInfo {
    const leader_index = retiredBlockLeaderIndex(function, index);
    return .{
        .is_leader = leader_index == index,
        .instruction_count = retiredBlockInstructionCount(function, leader_index),
    };
}

fn retiredBlockLeaderIndex(function: Function, index: usize) usize {
    var current_index = index;
    while (current_index > 0 and !retiredBlockStartsAt(function, current_index)) {
        current_index -= 1;
    }
    return current_index;
}

fn retiredBlockStartsAt(function: Function, index: usize) bool {
    if (index == 0) return true;

    const node = function.instructions[index];
    const previous = function.instructions[index - 1];
    if (instructionEndsRetiredBlock(previous)) return true;
    if (previous.address + previous.size_bytes != node.address) return true;
    return retiredBlockHasIncomingTarget(function, node.address);
}

fn retiredBlockInstructionCount(function: Function, leader_index: usize) u32 {
    var count: u32 = 1;
    var index = leader_index;
    while (index + 1 < function.instructions.len) : (index += 1) {
        const node = function.instructions[index];
        const next = function.instructions[index + 1];
        if (instructionEndsRetiredBlock(node)) break;
        if (node.address + node.size_bytes != next.address) break;
        if (retiredBlockHasIncomingTarget(function, next.address)) break;
        count += 1;
    }
    return count;
}

fn retiredBlockHasIncomingTarget(function: Function, address: u32) bool {
    for (function.instructions) |candidate| {
        if (instructionTargetsAddress(candidate.instruction, address)) return true;
    }
    return false;
}

fn instructionTargetsAddress(instruction: armv4t_decode.DecodedInstruction, address: u32) bool {
    return switch (instruction) {
        .branch => |branch| branch.target == address,
        .add_reg_pc_target => |add| add.target == address,
        .ldr_pc_post_imm_target => |load| load.target == address,
        .ldm_pc_target => |ldm| ldm.target == address,
        .ldm_empty_pc_target => |ldm| ldm.target == address,
        .exception_return => |ret| ret.target == address,
        else => false,
    };
}

fn instructionEndsRetiredBlock(node: InstructionNode) bool {
    return switch (node.instruction) {
        .mov_reg => |mov| mov.rd == 15 and mov.rm == 14,
        .movs_reg => |mov| mov.rd == 15 and mov.rm == 14,
        .ldr_pc_post_imm_target, .add_reg_pc_target, .branch, .bl, .bx_target, .bx_lr, .thumb_saved_lr_return, .ldm_pc_target, .ldm_empty_pc_target, .exception_return, .bx_reg => true,
        .pop => |mask| registerMaskIncludesPc(mask),
        else => false,
    };
}

fn emitInstructionBody(writer: *Io.Writer, function: Function, node: InstructionNode) Io.Writer.Error!void {
    switch (node.instruction) {
        .nop => try emitFallthrough(writer, function, node.address + node.size_bytes),
        .mov_imm => |mov| {
            try emitRegPtr(writer, "state", node.address, "rd", mov.rd);
            try writer.print("  store i32 {d}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ mov.imm, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .movs_imm => |mov| {
            try emitRegPtr(writer, "state", node.address, "rd", mov.rd);
            try writer.print("  store i32 {d}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ mov.imm, node.address });
            try writer.print("  %movs_imm_val_{x:0>8} = or i32 {d}, 0\n", .{ node.address, mov.imm });
            try emitUpdateNzFlags(writer, "state", node.address, "movs_imm_val");
            if (mov.carry) |carry| {
                try emitFlagPtr(writer, "state", node.address, .c);
                try writer.print("  store i1 {s}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ boolLiteral(carry), node.address });
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .mvn_imm => |mvn| {
            try emitRegPtr(writer, "state", node.address, "rd", mvn.rd);
            try writer.print("  %mvn_val_{x:0>8} = xor i32 {d}, -1\n", .{ node.address, mvn.imm });
            try writer.print("  store i32 %mvn_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .mvn_reg => |mvn| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", mvn.rm);
            try emitRegPtr(writer, "state", node.address, "rd", mvn.rd);
            try writer.print("  %mvn_reg_val_{x:0>8} = xor i32 %rm_val_{x:0>8}, -1\n", .{ node.address, node.address });
            try writer.print("  store i32 %mvn_reg_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            if (mvn.update_flags) {
                try emitUpdateNzFlags(writer, "state", node.address, "mvn_reg_val");
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .mov_reg => |mov| {
            if (mov.rd == 15 and mov.rm == 14) {
                try emitFunctionReturn(writer, function.entry);
                return;
            }
            if (mov.rd == 15) unreachable;
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", mov.rm);
            try emitRegPtr(writer, "state", node.address, "rd", mov.rd);
            try writer.print("  store i32 %rm_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .movs_reg => |mov| {
            if (mov.rd == 15 and mov.rm == 14) {
                try emitFunctionReturn(writer, function.entry);
                return;
            }
            if (mov.rd == 15) unreachable;
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", mov.rm);
            try emitRegPtr(writer, "state", node.address, "rd", mov.rd);
            try writer.print("  store i32 %rm_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %movs_reg_val_{x:0>8} = or i32 %rm_val_{x:0>8}, 0\n", .{ node.address, node.address });
            try emitUpdateNzFlags(writer, "state", node.address, "movs_reg_val");
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .orr_imm => |orr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", orr.rn);
            try writer.print("  %orr_val_{x:0>8} = or i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, orr.imm });
            try emitRegPtr(writer, "state", node.address, "rd", orr.rd);
            try writer.print("  store i32 %orr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .orr_reg => |orr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", orr.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", orr.rm);
            try writer.print("  %orr_reg_val_{x:0>8} = or i32 %rn_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", orr.rd);
            try writer.print("  store i32 %orr_reg_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            if (orr.update_flags) {
                try emitUpdateNzFlags(writer, "state", node.address, "orr_reg_val");
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .eor_imm => |eor| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", eor.rn);
            try writer.print("  %eor_val_{x:0>8} = xor i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, eor.imm });
            try emitRegPtr(writer, "state", node.address, "rd", eor.rd);
            try writer.print("  store i32 %eor_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .eor_reg => |eor| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", eor.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", eor.rm);
            try writer.print("  %eor_reg_val_{x:0>8} = xor i32 %rn_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", eor.rd);
            try writer.print("  store i32 %eor_reg_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            if (eor.update_flags) {
                try emitUpdateNzFlags(writer, "state", node.address, "eor_reg_val");
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .bic_imm => |bic| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", bic.rn);
            try writer.print("  %bic_mask_{x:0>8} = xor i32 {d}, -1\n", .{ node.address, bic.imm });
            try writer.print("  %bic_val_{x:0>8} = and i32 %rn_val_{x:0>8}, %bic_mask_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", bic.rd);
            try writer.print("  store i32 %bic_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .bic_reg => |bic| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", bic.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", bic.rm);
            try writer.print("  %bic_reg_mask_{x:0>8} = xor i32 %rm_val_{x:0>8}, -1\n", .{ node.address, node.address });
            try writer.print("  %bic_reg_val_{x:0>8} = and i32 %rn_val_{x:0>8}, %bic_reg_mask_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", bic.rd);
            try writer.print("  store i32 %bic_reg_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            if (bic.update_flags) {
                try emitUpdateNzFlags(writer, "state", node.address, "bic_reg_val");
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .orr_shift_reg => |orr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", orr.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", orr.rm);
            try emitShiftImm(writer, node.address, "rm_val", "orr_shifted", orr.shift);
            try writer.print(
                "  %orr_val_{x:0>8} = or i32 %rn_val_{x:0>8}, %orr_shifted_{x:0>8}\n",
                .{ node.address, node.address, node.address },
            );
            try emitRegPtr(writer, "state", node.address, "rd", orr.rd);
            try writer.print("  store i32 %orr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .and_imm => |and_op| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", and_op.rn);
            try writer.print("  %and_val_{x:0>8} = and i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, and_op.imm });
            try emitRegPtr(writer, "state", node.address, "rd", and_op.rd);
            try writer.print("  store i32 %and_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .and_reg => |and_op| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", and_op.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", and_op.rm);
            try writer.print("  %and_reg_val_{x:0>8} = and i32 %rn_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", and_op.rd);
            try writer.print("  store i32 %and_reg_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            if (and_op.update_flags) {
                try emitUpdateNzFlags(writer, "state", node.address, "and_reg_val");
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .add_imm => |add| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try writer.print("  %add_val_{x:0>8} = add i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, add.imm });
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %add_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .adds_imm => |add| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try emitAddImmWithFlags(writer, "state", node.address, "rn_val", add.imm, "adds_val");
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %adds_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .adcs_imm => |add| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try emitAdcImmWithFlags(writer, "state", node.address, "rn_val", add.imm, "adcs_val");
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %adcs_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .adcs_shift_reg => |add| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", add.rm);
            try emitShiftOperandValue(writer, function.entry.isa, node.address, "rm_val", add.shift, "adc_rhs");
            try emitAdcRegWithFlags(writer, "state", node.address, "rn_val", "adc_rhs", "adcs_val");
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %adcs_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .adc_imm => |add| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try emitAdcImmValue(writer, "state", node.address, "rn_val", add.imm, "adc_val");
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %adc_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .sbcs_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try emitSbcImmWithFlags(writer, "state", node.address, "rn_val", sub.imm, "sbcs_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %sbcs_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .sbcs_reg => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", sub.rm);
            try emitSbcRegWithFlags(writer, "state", node.address, "rn_val", "rm_val", "sbcs_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %sbcs_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .sbc_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try emitSbcImmValue(writer, "state", node.address, "rn_val", sub.imm, "sbc_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %sbc_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .add_reg => |add| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", add.rm);
            try writer.print("  %add_val_{x:0>8} = add i32 %rn_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %add_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .add_shift_reg => |add| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rn", add.rn);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", add.rm);
            try emitShiftOperandValue(writer, function.entry.isa, node.address, "rm_val", add.shift, "add_rhs");
            try writer.print("  %add_val_{x:0>8} = add i32 %rn_val_{x:0>8}, %add_rhs_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", add.rd);
            try writer.print("  store i32 %add_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .rsb_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try writer.print("  %rsb_val_{x:0>8} = sub i32 {d}, %rn_val_{x:0>8}\n", .{ node.address, sub.imm, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %rsb_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .rsbs_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try writer.print("  %rsbs_lhs_{x:0>8} = or i32 {d}, 0\n", .{ node.address, sub.imm });
            try emitSubRegWithFlags(writer, "state", node.address, "rsbs_lhs", "rn_val", "rsb_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %rsb_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .rsc_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try emitRscImmValue(writer, "state", node.address, sub.imm, "rn_val", "rsc_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %rsc_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .sub_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try writer.print("  %sub_plain_val_{x:0>8} = sub i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, sub.imm });
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %sub_plain_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .subs_imm => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try emitSubImmWithFlags(writer, "state", node.address, "rn_val", sub.imm, "sub_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %sub_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .subs_reg => |sub| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", sub.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", sub.rm);
            try emitSubRegWithFlags(writer, "state", node.address, "rn_val", "rm_val", "sub_val");
            try emitRegPtr(writer, "state", node.address, "rd", sub.rd);
            try writer.print("  store i32 %sub_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsl_imm => |lsl| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", lsl.rm);
            try writer.print("  %lsl_val_{x:0>8} = shl i32 %rm_val_{x:0>8}, {d}\n", .{ node.address, node.address, lsl.imm });
            try emitRegPtr(writer, "state", node.address, "rd", lsl.rd);
            try writer.print("  store i32 %lsl_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsl_reg => |lsl| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", lsl.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", lsl.rs);
            try emitLslRegValue(writer, node.address, "rm_val", "rs_val", "lsl_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsl.rd);
            try writer.print("  store i32 %lsl_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .asr_imm => |asr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", asr.rm);
            try emitAsrImmValue(writer, node.address, "rm_val", asr.imm, "asr_val");
            try emitRegPtr(writer, "state", node.address, "rd", asr.rd);
            try writer.print("  store i32 %asr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .asr_reg => |asr| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", asr.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", asr.rs);
            try emitAsrRegValue(writer, node.address, "rm_val", "rs_val", "asr_val");
            try emitRegPtr(writer, "state", node.address, "rd", asr.rd);
            try writer.print("  store i32 %asr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsls_imm => |lsl| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", lsl.rm);
            try emitLslsImmWithFlags(writer, "state", node.address, "rm_val", lsl.imm, "lsls_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsl.rd);
            try writer.print("  store i32 %lsls_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsrs_imm => |lsr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", lsr.rm);
            try emitLsrsImmWithFlags(writer, "state", node.address, "rm_val", lsr.imm, "lsr_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsr.rd);
            try writer.print("  store i32 %lsr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .asrs_imm => |asr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", asr.rm);
            try emitAsrsImmWithFlags(writer, "state", node.address, "rm_val", asr.imm, "asr_val");
            try emitRegPtr(writer, "state", node.address, "rd", asr.rd);
            try writer.print("  store i32 %asr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsls_reg => |lsl| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", lsl.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", lsl.rs);
            try emitLslsRegWithFlags(writer, "state", node.address, "rm_val", "rs_val", "lsls_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsl.rd);
            try writer.print("  store i32 %lsls_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsr_imm => |lsr| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", lsr.rm);
            try emitLsrImmValue(writer, node.address, "rm_val", lsr.imm, "lsr_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsr.rd);
            try writer.print("  store i32 %lsr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsr_reg => |lsr| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", lsr.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", lsr.rs);
            try emitLsrRegValue(writer, node.address, "rm_val", "rs_val", "lsr_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsr.rd);
            try writer.print("  store i32 %lsr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .lsrs_reg => |lsr| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", lsr.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", lsr.rs);
            try emitLsrsRegWithFlags(writer, "state", node.address, "rm_val", "rs_val", "lsr_val");
            try emitRegPtr(writer, "state", node.address, "rd", lsr.rd);
            try writer.print("  store i32 %lsr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .asrs_reg => |asr| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", asr.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", asr.rs);
            try emitAsrsRegWithFlags(writer, "state", node.address, "rm_val", "rs_val", "asr_val");
            try emitRegPtr(writer, "state", node.address, "rd", asr.rd);
            try writer.print("  store i32 %asr_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ror_imm => |ror| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", ror.rm);
            try emitRorImmValue(writer, node.address, "rm_val", ror.imm, "ror_val");
            try emitRegPtr(writer, "state", node.address, "rd", ror.rd);
            try writer.print("  store i32 %ror_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ror_reg => |ror| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", ror.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", ror.rs);
            try emitRorRegValue(writer, node.address, "rm_val", "rs_val", "ror_val");
            try emitRegPtr(writer, "state", node.address, "rd", ror.rd);
            try writer.print("  store i32 %ror_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .rors_imm => |ror| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", ror.rm);
            try emitRorsImmWithFlags(writer, "state", node.address, "rm_val", ror.imm, "ror_val");
            try emitRegPtr(writer, "state", node.address, "rd", ror.rd);
            try writer.print("  store i32 %ror_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .rors_reg => |ror| {
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rm", ror.rm);
            try emitReadShiftRegValue(writer, function.entry.isa, "state", node.address, "rs", ror.rs);
            try emitRorsRegWithFlags(writer, "state", node.address, "rm_val", "rs_val", "ror_val");
            try emitRegPtr(writer, "state", node.address, "rd", ror.rd);
            try writer.print("  store i32 %ror_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .rrxs => |rrx| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", rrx.rm);
            try emitRrxsWithFlags(writer, "state", node.address, "rm_val", "rrx_val");
            try emitRegPtr(writer, "state", node.address, "rd", rrx.rd);
            try writer.print("  store i32 %rrx_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .mul => |mul| {
            try emitRegPtr(writer, "state", node.address, "rm", mul.rm);
            try writer.print("  %mul_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rs", mul.rs);
            try writer.print("  %mul_rs_val_{x:0>8} = load i32, ptr %rs_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %mul_val_{x:0>8} = mul i32 %mul_rm_val_{x:0>8}, %mul_rs_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", mul.rd);
            try writer.print("  store i32 %mul_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .mla => |mla| {
            try emitRegPtr(writer, "state", node.address, "rm", mla.rm);
            try writer.print("  %mla_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rs", mla.rs);
            try writer.print("  %mla_rs_val_{x:0>8} = load i32, ptr %rs_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "ra", mla.ra);
            try writer.print("  %mla_ra_val_{x:0>8} = load i32, ptr %ra_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %mla_mul_{x:0>8} = mul i32 %mla_rm_val_{x:0>8}, %mla_rs_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %mla_val_{x:0>8} = add i32 %mla_mul_{x:0>8}, %mla_ra_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", mla.rd);
            try writer.print("  store i32 %mla_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .umull => |mul| {
            try emitRegPtr(writer, "state", node.address, "rm", mul.rm);
            try writer.print("  %umull_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rs", mul.rs);
            try writer.print("  %umull_rs_val_{x:0>8} = load i32, ptr %rs_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %umull_rm_ext_{x:0>8} = zext i32 %umull_rm_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %umull_rs_ext_{x:0>8} = zext i32 %umull_rs_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %umull_val_{x:0>8} = mul i64 %umull_rm_ext_{x:0>8}, %umull_rs_ext_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %umull_lo_{x:0>8} = trunc i64 %umull_val_{x:0>8} to i32\n", .{ node.address, node.address });
            try writer.print("  %umull_hi_shift_{x:0>8} = lshr i64 %umull_val_{x:0>8}, 32\n", .{ node.address, node.address });
            try writer.print("  %umull_hi_{x:0>8} = trunc i64 %umull_hi_shift_{x:0>8} to i32\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdlo", mul.rdlo);
            try writer.print("  store i32 %umull_lo_{x:0>8}, ptr %rdlo_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdhi", mul.rdhi);
            try writer.print("  store i32 %umull_hi_{x:0>8}, ptr %rdhi_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .umlal => |mul| {
            try emitRegPtr(writer, "state", node.address, "rm", mul.rm);
            try writer.print("  %umlal_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rs", mul.rs);
            try writer.print("  %umlal_rs_val_{x:0>8} = load i32, ptr %rs_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdlo", mul.rdlo);
            try writer.print("  %umlal_rdlo_val_{x:0>8} = load i32, ptr %rdlo_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdhi", mul.rdhi);
            try writer.print("  %umlal_rdhi_val_{x:0>8} = load i32, ptr %rdhi_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %umlal_rm_ext_{x:0>8} = zext i32 %umlal_rm_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %umlal_rs_ext_{x:0>8} = zext i32 %umlal_rs_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %umlal_product_{x:0>8} = mul i64 %umlal_rm_ext_{x:0>8}, %umlal_rs_ext_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %umlal_acc_lo_{x:0>8} = zext i32 %umlal_rdlo_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %umlal_acc_hi_{x:0>8} = zext i32 %umlal_rdhi_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %umlal_acc_hi_shift_{x:0>8} = shl i64 %umlal_acc_hi_{x:0>8}, 32\n", .{ node.address, node.address });
            try writer.print("  %umlal_acc_{x:0>8} = or i64 %umlal_acc_hi_shift_{x:0>8}, %umlal_acc_lo_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %umlal_val_{x:0>8} = add i64 %umlal_acc_{x:0>8}, %umlal_product_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %umlal_lo_{x:0>8} = trunc i64 %umlal_val_{x:0>8} to i32\n", .{ node.address, node.address });
            try writer.print("  %umlal_hi_shift_{x:0>8} = lshr i64 %umlal_val_{x:0>8}, 32\n", .{ node.address, node.address });
            try writer.print("  %umlal_hi_{x:0>8} = trunc i64 %umlal_hi_shift_{x:0>8} to i32\n", .{ node.address, node.address });
            try writer.print("  store i32 %umlal_lo_{x:0>8}, ptr %rdlo_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  store i32 %umlal_hi_{x:0>8}, ptr %rdhi_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .smull => |mul| {
            try emitRegPtr(writer, "state", node.address, "rm", mul.rm);
            try writer.print("  %smull_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rs", mul.rs);
            try writer.print("  %smull_rs_val_{x:0>8} = load i32, ptr %rs_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %smull_rm_ext_{x:0>8} = sext i32 %smull_rm_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %smull_rs_ext_{x:0>8} = sext i32 %smull_rs_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %smull_val_{x:0>8} = mul i64 %smull_rm_ext_{x:0>8}, %smull_rs_ext_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %smull_lo_{x:0>8} = trunc i64 %smull_val_{x:0>8} to i32\n", .{ node.address, node.address });
            try writer.print("  %smull_hi_shift_{x:0>8} = lshr i64 %smull_val_{x:0>8}, 32\n", .{ node.address, node.address });
            try writer.print("  %smull_hi_{x:0>8} = trunc i64 %smull_hi_shift_{x:0>8} to i32\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdlo", mul.rdlo);
            try writer.print("  store i32 %smull_lo_{x:0>8}, ptr %rdlo_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdhi", mul.rdhi);
            try writer.print("  store i32 %smull_hi_{x:0>8}, ptr %rdhi_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .smlal => |mul| {
            try emitRegPtr(writer, "state", node.address, "rm", mul.rm);
            try writer.print("  %smlal_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rs", mul.rs);
            try writer.print("  %smlal_rs_val_{x:0>8} = load i32, ptr %rs_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdlo", mul.rdlo);
            try writer.print("  %smlal_rdlo_val_{x:0>8} = load i32, ptr %rdlo_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rdhi", mul.rdhi);
            try writer.print("  %smlal_rdhi_val_{x:0>8} = load i32, ptr %rdhi_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %smlal_rm_ext_{x:0>8} = sext i32 %smlal_rm_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %smlal_rs_ext_{x:0>8} = sext i32 %smlal_rs_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %smlal_product_{x:0>8} = mul i64 %smlal_rm_ext_{x:0>8}, %smlal_rs_ext_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %smlal_acc_lo_{x:0>8} = zext i32 %smlal_rdlo_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %smlal_acc_hi_{x:0>8} = zext i32 %smlal_rdhi_val_{x:0>8} to i64\n", .{ node.address, node.address });
            try writer.print("  %smlal_acc_hi_shift_{x:0>8} = shl i64 %smlal_acc_hi_{x:0>8}, 32\n", .{ node.address, node.address });
            try writer.print("  %smlal_acc_{x:0>8} = or i64 %smlal_acc_hi_shift_{x:0>8}, %smlal_acc_lo_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %smlal_val_{x:0>8} = add i64 %smlal_acc_{x:0>8}, %smlal_product_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %smlal_lo_{x:0>8} = trunc i64 %smlal_val_{x:0>8} to i32\n", .{ node.address, node.address });
            try writer.print("  %smlal_hi_shift_{x:0>8} = lshr i64 %smlal_val_{x:0>8}, 32\n", .{ node.address, node.address });
            try writer.print("  %smlal_hi_{x:0>8} = trunc i64 %smlal_hi_shift_{x:0>8} to i32\n", .{ node.address, node.address });
            try writer.print("  store i32 %smlal_lo_{x:0>8}, ptr %rdlo_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  store i32 %smlal_hi_{x:0>8}, ptr %rdhi_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .swp_word => |swp| {
            try emitRegPtr(writer, "state", node.address, "base", swp.base);
            try writer.print("  %swp_base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %swp_old_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %swp_base_val_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", swp.rm);
            try writer.print("  %swp_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  call void @hmn_store32(ptr %state, i32 %swp_base_val_{x:0>8}, i32 %swp_rm_val_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", swp.rd);
            try writer.print("  store i32 %swp_old_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .swp_byte => |swp| {
            try emitRegPtr(writer, "state", node.address, "base", swp.base);
            try writer.print("  %swpb_base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %swpb_old_{x:0>8} = call i32 @hmn_load8(ptr %state, i32 %swpb_base_val_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", swp.rm);
            try writer.print("  %swpb_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  call void @hmn_store8(ptr %state, i32 %swpb_base_val_{x:0>8}, i32 %swpb_rm_val_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", swp.rd);
            try writer.print("  store i32 %swpb_old_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_word_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load_val_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_word_imm_signed => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = sub i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load_val_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_byte_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load8_val_{x:0>8} = call i32 @hmn_load8(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load8_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_byte_post_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = or i32 %base_val_{x:0>8}, 0\n", .{ node.address, node.address });
            try writer.print("  %base_next_{x:0>8} = add i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load8_val_{x:0>8} = call i32 @hmn_load8(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try writer.print("  store i32 %base_next_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load8_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_byte_reg => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", load.rm);
            try writer.print("  %rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %load8_val_{x:0>8} = call i32 @hmn_load8(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load8_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_halfword_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load16_val_{x:0>8} = call i32 @hmn_load16(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load16_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_halfword_pre_index_reg => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", load.rm);
            try writer.print("  %rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print(
                "  %addr_{x:0>8} = {s} i32 %base_val_{x:0>8}, %rm_val_{x:0>8}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, node.address },
            );
            if (load.writeback) {
                try writer.print("  store i32 %addr_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            }
            try writer.print("  %load16_val_{x:0>8} = call i32 @hmn_load16(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load16_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_halfword_pre_index_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print(
                "  %addr_{x:0>8} = {s} i32 %base_val_{x:0>8}, {d}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, load.offset },
            );
            try writer.print("  %load16_val_{x:0>8} = call i32 @hmn_load16(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try writer.print("  store i32 %addr_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load16_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_halfword_post_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = or i32 %base_val_{x:0>8}, 0\n", .{ node.address, node.address });
            try writer.print(
                "  %base_next_{x:0>8} = {s} i32 %base_val_{x:0>8}, {d}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, load.offset },
            );
            try writer.print("  %load16_val_{x:0>8} = call i32 @hmn_load16(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try writer.print("  store i32 %base_next_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load16_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_signed_halfword_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load16s_val_{x:0>8} = call i32 @hmn_load16s(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load16s_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_signed_halfword_reg => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", load.rm);
            try writer.print("  %rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %load16s_val_{x:0>8} = call i32 @hmn_load16s(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load16s_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_signed_byte_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.offset });
            try writer.print("  %load8s_val_{x:0>8} = call i32 @hmn_load8s(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load8s_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_signed_byte_reg => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", load.rm);
            try writer.print("  %rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = add i32 %base_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try writer.print("  %load8s_val_{x:0>8} = call i32 @hmn_load8s(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load8s_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_word_pre_index_reg_shift => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rm", load.rm);
            try writer.print("  %rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitShiftImmWithState(writer, "state", node.address, "rm_val", load.shift, "load_offset");
            try writer.print(
                "  %addr_{x:0>8} = {s} i32 %base_val_{x:0>8}, %load_offset_{x:0>8}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, node.address },
            );
            if (load.writeback) {
                try writer.print("  store i32 %addr_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            }
            try writer.print("  %load_val_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_word_pre_index_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print(
                "  %addr_{x:0>8} = {s} i32 %base_val_{x:0>8}, {d}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, load.offset },
            );
            try writer.print("  %load_val_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try writer.print("  store i32 %addr_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_word_post_imm => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = or i32 %base_val_{x:0>8}, 0\n", .{ node.address, node.address });
            try writer.print(
                "  %base_next_{x:0>8} = {s} i32 %base_val_{x:0>8}, {d}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, load.offset },
            );
            try writer.print("  %load_val_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try writer.print("  store i32 %base_next_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitRegPtr(writer, "state", node.address, "rd", load.rd);
            try writer.print("  store i32 %load_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldr_pc_post_imm_target => |load| {
            try emitRegPtr(writer, "state", node.address, "base", load.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %addr_{x:0>8} = or i32 %base_val_{x:0>8}, 0\n", .{ node.address, node.address });
            try writer.print(
                "  %base_next_{x:0>8} = {s} i32 %base_val_{x:0>8}, {d}\n",
                .{ node.address, if (load.subtract) "sub" else "add", node.address, load.offset },
            );
            try writer.print("  %pc_load_val_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %addr_{x:0>8})\n", .{ node.address, node.address });
            try writer.print("  store i32 %base_next_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print("  %pc_target_match_{x:0>8} = icmp eq i32 %pc_load_val_{x:0>8}, {d}\n", .{ node.address, node.address, load.target });
            if (hasAddress(function, load.target)) {
                try writer.print(
                    "  br i1 %pc_target_match_{x:0>8}, label %pc_{x:0>8}, label %guest_return_{s}_{x:0>8}\n",
                    .{ node.address, load.target, instructionSetName(function.entry.isa), function.entry.address },
                );
            } else {
                try emitFunctionReturn(writer, function.entry);
            }
        },
        .stm => |stm| {
            try emitStoreMultiple(writer, node.address, stm.base, stm.mask, stm.writeback, stm.mode);
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .stm_empty => |stm| {
            try emitEmptyStoreMultiple(writer, node.address, stm.base, stm.writeback, stm.mode);
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .push => |mask| {
            try emitPushRegs(writer, node.address, mask);
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .pop => |mask| {
            try emitPopRegs(writer, node.address, mask);
            if (registerMaskIncludesPc(mask))
                try emitFunctionReturn(writer, function.entry)
            else
                try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldm => |ldm| {
            try emitLoadMultiple(writer, node.address, ldm.base, ldm.mask, ldm.writeback, ldm.mode);
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .ldm_pc_target => |ldm| {
            try emitLoadMultiple(writer, node.address, ldm.base, ldm.mask, ldm.writeback, ldm.mode);
            if (hasAddress(function, ldm.target))
                try emitBranchTo(writer, ldm.target)
            else
                try emitFunctionReturn(writer, function.entry);
        },
        .ldm_empty => unreachable,
        .ldm_empty_pc_target => |ldm| {
            try emitEmptyLoadMultiplePcTarget(writer, node.address, ldm.base, ldm.writeback, ldm.mode);
            if (hasAddress(function, ldm.target))
                try emitBranchTo(writer, ldm.target)
            else
                try emitFunctionReturn(writer, function.entry);
        },
        .tst_imm => |tst| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", tst.rn);
            try writer.print("  %tst_val_{x:0>8} = and i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, tst.imm });
            try emitUpdateNzFlags(writer, "state", node.address, "tst_val");
            if (tst.carry) |carry| {
                try emitFlagPtr(writer, "state", node.address, .c);
                try writer.print("  store i1 {s}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ if (carry) "true" else "false", node.address });
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .tst_reg => |tst| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", tst.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", tst.rm);
            try writer.print("  %tst_reg_val_{x:0>8} = and i32 %rn_val_{x:0>8}, %rm_val_{x:0>8}\n", .{ node.address, node.address, node.address });
            try emitUpdateNzFlags(writer, "state", node.address, "tst_reg_val");
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .cmp_imm => |cmp| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", cmp.rn);
            try emitSubImmWithFlags(writer, "state", node.address, "rn_val", cmp.imm, "cmp_val");
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .cmp_reg => |cmp| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", cmp.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", cmp.rm);
            try emitSubRegWithFlags(writer, "state", node.address, "rn_val", "rm_val", "cmp_val");
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .cmn_imm => |cmn| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", cmn.rn);
            try emitAddImmWithFlags(writer, "state", node.address, "rn_val", cmn.imm, "cmn_val");
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .cmn_reg => |cmn| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", cmn.rn);
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rm", cmn.rm);
            try emitAddRegWithFlags(writer, "state", node.address, "rn_val", "rm_val", "cmn_val");
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .teq_imm => |teq| {
            try emitReadAluRegValue(writer, function.entry.isa, "state", node.address, "rn", teq.rn);
            try writer.print("  %teq_val_{x:0>8} = xor i32 %rn_val_{x:0>8}, {d}\n", .{ node.address, node.address, teq.imm });
            try emitUpdateNzFlags(writer, "state", node.address, "teq_val");
            if (teq.carry) |carry| {
                try emitFlagPtr(writer, "state", node.address, .c);
                try writer.print("  store i1 {s}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ if (carry) "true" else "false", node.address });
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .store => |store| {
            try emitRegPtr(writer, "state", node.address, "base", store.base);
            try writer.print("  %base_val_{x:0>8} = load i32, ptr %base_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            switch (store.addressing) {
                .offset => |index| {
                    try emitOffsetAddress(writer, node.address, "base_val", index.offset, index.subtract, "addr");
                },
                .pre_index => |index| {
                    try emitOffsetAddress(writer, node.address, "base_val", index.offset, index.subtract, "addr");
                },
                .post_index => |index| {
                    try writer.print("  %addr_{x:0>8} = or i32 %base_val_{x:0>8}, 0\n", .{ node.address, node.address });
                    try emitOffsetAddress(writer, node.address, "base_val", index.offset, index.subtract, "base_next");
                },
            }
            try emitRegPtr(writer, "state", node.address, "src", store.src);
            try writer.print("  %src_val_{x:0>8} = load i32, ptr %src_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            const helper_bits: u16 = switch (store.size) {
                .byte => 8,
                .halfword => 16,
                .word => 32,
            };
            try writer.print(
                "  call void @hmn_store{d}(ptr %state, i32 %addr_{x:0>8}, i32 %src_val_{x:0>8})\n",
                .{ helper_bits, node.address, node.address },
            );
            switch (store.addressing) {
                .offset => {},
                .pre_index => try writer.print(
                    "  store i32 %addr_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n",
                    .{ node.address, node.address },
                ),
                .post_index => try writer.print(
                    "  store i32 %base_next_{x:0>8}, ptr %base_ptr_{x:0>8}, align 4\n",
                    .{ node.address, node.address },
                ),
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .add_reg_pc_target => |add| {
            if (add.target == node.address)
                try emitFunctionReturn(writer, function.entry)
            else if (hasAddress(function, add.target))
                try emitBranchTo(writer, add.target)
            else
                try emitFunctionReturn(writer, function.entry);
        },
        .branch => |branch| {
            if (branch.cond == .al) {
                if (branch.target == node.address)
                    try emitFunctionReturn(writer, function.entry)
                else if (hasAddress(function, branch.target))
                    try emitBranchTo(writer, branch.target)
                else
                    try emitFunctionReturn(writer, function.entry);
                return;
            }

            try emitBranchCondition(writer, "state", node.address, branch.cond);
            const has_fallthrough = hasAddress(function, node.address + node.size_bytes);
            const has_target = hasAddress(function, branch.target);
            if (has_fallthrough and has_target) {
                try writer.print(
                    "  br i1 %branch_cond_{x:0>8}, label %pc_{x:0>8}, label %pc_{x:0>8}\n",
                    .{ node.address, branch.target, node.address + node.size_bytes },
                );
            } else if (has_fallthrough) {
                try writer.print(
                    "  br i1 %branch_cond_{x:0>8}, label %guest_return_{s}_{x:0>8}, label %pc_{x:0>8}\n",
                    .{ node.address, instructionSetName(function.entry.isa), function.entry.address, node.address + node.size_bytes },
                );
            } else if (has_target) {
                try writer.print(
                    "  br i1 %branch_cond_{x:0>8}, label %pc_{x:0>8}, label %guest_return_{s}_{x:0>8}\n",
                    .{ node.address, branch.target, instructionSetName(function.entry.isa), function.entry.address },
                );
            } else {
                try emitFunctionReturn(writer, function.entry);
            }
        },
        .bl => |bl| {
            try emitRegPtr(writer, "state", node.address, "lr", 14);
            try writer.print("  store i32 {d}, ptr %lr_ptr_{x:0>8}, align 4\n", .{ node.address + node.size_bytes, node.address });
            if (bl.target.address != node.address + node.size_bytes or bl.target.isa != function.entry.isa) {
                try writer.print("  call void @guest_{s}_{x:0>8}(ptr %state)\n", .{
                    instructionSetName(bl.target.isa),
                    bl.target.address,
                });
            }
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .bx_target => |target| {
            try writer.print("  call void @guest_{s}_{x:0>8}(ptr %state)\n", .{
                instructionSetName(target.isa),
                target.address,
            });
            try emitFunctionReturn(writer, function.entry);
        },
        .bx_lr => try emitFunctionReturn(writer, function.entry),
        .thumb_saved_lr_return => try emitFunctionReturn(writer, function.entry),
        .mrs_psr => |mrs| {
            const helper_name = switch (mrs.target) {
                .cpsr => "hmn_read_cpsr",
                .spsr => "hmn_read_spsr",
            };
            try writer.print("  %mrs_val_{x:0>8} = call i32 @{s}(ptr %state)\n", .{ node.address, helper_name });
            try emitRegPtr(writer, "state", node.address, "rd", mrs.rd);
            try writer.print("  store i32 %mrs_val_{x:0>8}, ptr %rd_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .msr_psr_imm => |msr| {
            const helper_name = switch (msr.target) {
                .cpsr => "hmn_write_cpsr",
                .spsr => "hmn_write_spsr",
            };
            try writer.print(
                "  call void @{s}(ptr %state, i32 {d}, i32 {d})\n",
                .{ helper_name, msr.value, msr.field_mask },
            );
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .msr_psr_reg => |msr| {
            const helper_name = switch (msr.target) {
                .cpsr => "hmn_write_cpsr",
                .spsr => "hmn_write_spsr",
            };
            try emitRegPtr(writer, "state", node.address, "rm", msr.rm);
            try writer.print("  %msr_rm_val_{x:0>8} = load i32, ptr %rm_ptr_{x:0>8}, align 4\n", .{ node.address, node.address });
            try writer.print(
                "  call void @{s}(ptr %state, i32 %msr_rm_val_{x:0>8}, i32 {d})\n",
                .{ helper_name, node.address, msr.field_mask },
            );
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .exception_return => |ret| {
            try writer.print("  call void @hmn_restore_cpsr_from_spsr(ptr %state)\n", .{});
            if (hasAddress(function, ret.target))
                try emitBranchTo(writer, ret.target)
            else
                try emitFunctionReturn(writer, function.entry);
        },
        .swi => |swi| {
            const shim_name = switch (swi.imm24) {
                0x000000 => "SoftReset",
                0x000005, 0x050000 => "VBlankIntrWait",
                0x000006, 0x060000 => "Div",
                0x000008, 0x080000 => "Sqrt",
                else => unreachable,
            };
            try writer.print("  call i32 @shim_gba_{s}(ptr %state)\n", .{shim_name});
            try emitFallthrough(writer, function, node.address + node.size_bytes);
        },
        .bx_reg => unreachable,
    }
}

fn instructionHandlesOwnCondition(instruction: armv4t_decode.DecodedInstruction) bool {
    return switch (instruction) {
        .branch => true,
        else => false,
    };
}

fn emitOffsetAddress(
    writer: *Io.Writer,
    address: u32,
    base_value_prefix: []const u8,
    offset: armv4t_decode.Offset,
    subtract: bool,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    switch (offset) {
        .imm => |imm| {
            try writer.print(
                "  %{s}_{x:0>8} = {s} i32 %{s}_{x:0>8}, {d}\n",
                .{ result_prefix, address, if (subtract) "sub" else "add", base_value_prefix, address, imm },
            );
        },
        .reg => |reg_index| {
            try emitRegPtr(writer, "state", address, "offset", reg_index);
            try writer.print("  %offset_val_{x:0>8} = load i32, ptr %offset_ptr_{x:0>8}, align 4\n", .{ address, address });
            try writer.print(
                "  %{s}_{x:0>8} = {s} i32 %{s}_{x:0>8}, %offset_val_{x:0>8}\n",
                .{ result_prefix, address, if (subtract) "sub" else "add", base_value_prefix, address, address },
            );
        },
    }
}

fn emitShiftImm(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    result_prefix: []const u8,
    shift: armv4t_decode.ShiftImm,
) Io.Writer.Error!void {
    switch (shift.kind) {
        .lsl => try writer.print(
            "  %{s}_{x:0>8} = shl i32 %{s}_{x:0>8}, {d}\n",
            .{ result_prefix, address, value_prefix, address, shift.amount },
        ),
        .lsr => try writer.print(
            "  %{s}_{x:0>8} = lshr i32 %{s}_{x:0>8}, {d}\n",
            .{ result_prefix, address, value_prefix, address, shift.amount },
        ),
        .asr => try writer.print(
            "  %{s}_{x:0>8} = ashr i32 %{s}_{x:0>8}, {d}\n",
            .{ result_prefix, address, value_prefix, address, shift.amount },
        ),
        .ror => {
            const rotate = shift.amount % 32;
            if (rotate == 0) {
                try writer.print(
                    "  %{s}_{x:0>8} = or i32 %{s}_{x:0>8}, 0\n",
                    .{ result_prefix, address, value_prefix, address },
                );
                return;
            }
            try writer.print(
                "  %ror_lo_{x:0>8} = lshr i32 %{s}_{x:0>8}, {d}\n",
                .{ address, value_prefix, address, rotate },
            );
            try writer.print(
                "  %ror_hi_{x:0>8} = shl i32 %{s}_{x:0>8}, {d}\n",
                .{ address, value_prefix, address, 32 - rotate },
            );
            try writer.print(
                "  %{s}_{x:0>8} = or i32 %ror_lo_{x:0>8}, %ror_hi_{x:0>8}\n",
                .{ result_prefix, address, address, address },
            );
        },
        .rrx => unreachable,
    }
}

fn emitShiftImmWithState(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    shift: armv4t_decode.ShiftImm,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    switch (shift.kind) {
        .rrx => {
            try emitFlagPtr(writer, state_name, address, .c);
            try writer.print("  %rrx_carry_{x:0>8} = load i1, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
            try writer.print("  %rrx_carry_i32_{x:0>8} = zext i1 %rrx_carry_{x:0>8} to i32\n", .{ address, address });
            try writer.print("  %rrx_carry_hi_{x:0>8} = shl i32 %rrx_carry_i32_{x:0>8}, 31\n", .{ address, address });
            try writer.print("  %rrx_lo_{x:0>8} = lshr i32 %{s}_{x:0>8}, 1\n", .{ address, value_prefix, address });
            try writer.print(
                "  %{s}_{x:0>8} = or i32 %rrx_carry_hi_{x:0>8}, %rrx_lo_{x:0>8}\n",
                .{ result_prefix, address, address, address },
            );
        },
        else => try emitShiftImm(writer, address, value_prefix, result_prefix, shift),
    }
}

fn emitShiftOperandValue(
    writer: *Io.Writer,
    isa: armv4t_decode.InstructionSet,
    address: u32,
    value_prefix: []const u8,
    shift: armv4t_decode.ShiftOperand,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    switch (shift) {
        .imm => |imm| try emitShiftImm(writer, address, value_prefix, result_prefix, imm),
        .reg => |reg_shift| {
            try emitReadShiftRegValue(writer, isa, "state", address, "shift_rs", reg_shift.rs);
            switch (reg_shift.kind) {
                .lsl => try emitLslRegValue(writer, address, value_prefix, "shift_rs_val", result_prefix),
                .lsr => try emitLsrRegValue(writer, address, value_prefix, "shift_rs_val", result_prefix),
                .asr => try emitAsrRegValue(writer, address, value_prefix, "shift_rs_val", result_prefix),
                .ror => try emitRorRegValue(writer, address, value_prefix, "shift_rs_val", result_prefix),
                .rrx => unreachable,
            }
        },
    }
}

fn emitSubImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print(
        "  %ssub_pair_{x:0>8} = call {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %usub_pair_{x:0>8} = call {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %ssub_pair_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %sub_signed_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %ssub_pair_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %sub_unsigned_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %usub_pair_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  %sub_carry_{x:0>8} = xor i1 %sub_unsigned_overflow_{x:0>8}, true\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %sub_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %sub_signed_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitAddImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print(
        "  %sadd_pair_{x:0>8} = call {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %uadd_pair_{x:0>8} = call {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %sadd_pair_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %add_signed_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %sadd_pair_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %add_unsigned_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %uadd_pair_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %add_unsigned_overflow_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %add_signed_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitAddRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    rhs_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print(
        "  %sadd_pair_{x:0>8} = call {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %uadd_pair_{x:0>8} = call {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %sadd_pair_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %add_signed_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %sadd_pair_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %add_unsigned_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %uadd_pair_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %add_unsigned_overflow_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %add_signed_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitSubRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    rhs_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print(
        "  %ssub_pair_{x:0>8} = call {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %usub_pair_{x:0>8} = call {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %ssub_pair_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %sub_signed_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %ssub_pair_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %sub_unsigned_overflow_{x:0>8} = extractvalue {{ i32, i1 }} %usub_pair_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  %sub_carry_{x:0>8} = xor i1 %sub_unsigned_overflow_{x:0>8}, true\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %sub_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %sub_signed_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitAdcImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %adc_carry_in_{x:0>8} = zext i1 %flag_c_val_{x:0>8} to i32\n", .{ address, address });
    try writer.print(
        "  %adc_sadd_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %adc_uadd_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %adc_sum_0_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_0_{x:0>8}, 0\n",
        .{ address, address },
    );
    try writer.print("  %adc_signed_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %adc_unsigned_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %adc_uadd_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print(
        "  %adc_sadd_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32 %adc_sum_0_{x:0>8}, i32 %adc_carry_in_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %adc_uadd_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32 %adc_sum_0_{x:0>8}, i32 %adc_carry_in_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_1_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %adc_signed_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_1_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %adc_unsigned_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %adc_uadd_pair_1_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print(
        "  %adc_carry_{x:0>8} = or i1 %adc_unsigned_overflow_0_{x:0>8}, %adc_unsigned_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %adc_overflow_{x:0>8} = or i1 %adc_signed_overflow_0_{x:0>8}, %adc_signed_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("  store i1 %adc_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %adc_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitAdcRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    rhs_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %adc_carry_in_{x:0>8} = zext i1 %flag_c_val_{x:0>8} to i32\n", .{ address, address });
    try writer.print(
        "  %adc_sadd_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %adc_uadd_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %adc_sum_0_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_0_{x:0>8}, 0\n",
        .{ address, address },
    );
    try writer.print("  %adc_signed_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %adc_unsigned_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %adc_uadd_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print(
        "  %adc_sadd_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.sadd.with.overflow.i32(i32 %adc_sum_0_{x:0>8}, i32 %adc_carry_in_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %adc_uadd_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.uadd.with.overflow.i32(i32 %adc_sum_0_{x:0>8}, i32 %adc_carry_in_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_1_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %adc_signed_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %adc_sadd_pair_1_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %adc_unsigned_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %adc_uadd_pair_1_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print(
        "  %adc_carry_{x:0>8} = or i1 %adc_unsigned_overflow_0_{x:0>8}, %adc_unsigned_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %adc_overflow_{x:0>8} = or i1 %adc_signed_overflow_0_{x:0>8}, %adc_signed_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("  store i1 %adc_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %adc_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitAdcImmValue(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %adc_carry_in_{x:0>8} = zext i1 %flag_c_val_{x:0>8} to i32\n", .{ address, address });
    try writer.print("  %adc_sum_0_{x:0>8} = add i32 %{s}_{x:0>8}, {d}\n", .{ address, lhs_prefix, address, imm });
    try writer.print("  %{s}_{x:0>8} = add i32 %adc_sum_0_{x:0>8}, %adc_carry_in_{x:0>8}\n", .{ result_prefix, address, address, address });
}

fn emitSbcRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    rhs_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %sbc_reg_borrow_in_{x:0>8} = xor i1 %flag_c_val_{x:0>8}, true\n", .{ address, address });
    try writer.print("  %sbc_reg_borrow_i32_{x:0>8} = zext i1 %sbc_reg_borrow_in_{x:0>8} to i32\n", .{ address, address });
    try writer.print(
        "  %sbc_reg_ssub_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %sbc_reg_usub_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 %{s}_{x:0>8})\n",
        .{ address, lhs_prefix, address, rhs_prefix, address },
    );
    try writer.print(
        "  %sbc_reg_sum_0_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_reg_ssub_pair_0_{x:0>8}, 0\n",
        .{ address, address },
    );
    try writer.print("  %sbc_reg_signed_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_reg_ssub_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %sbc_reg_unsigned_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_reg_usub_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print(
        "  %sbc_reg_ssub_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32 %sbc_reg_sum_0_{x:0>8}, i32 %sbc_reg_borrow_i32_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %sbc_reg_usub_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32 %sbc_reg_sum_0_{x:0>8}, i32 %sbc_reg_borrow_i32_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_reg_ssub_pair_1_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %sbc_reg_signed_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_reg_ssub_pair_1_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %sbc_reg_unsigned_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_reg_usub_pair_1_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print(
        "  %sbc_reg_borrow_{x:0>8} = or i1 %sbc_reg_unsigned_overflow_0_{x:0>8}, %sbc_reg_unsigned_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %sbc_reg_overflow_{x:0>8} = or i1 %sbc_reg_signed_overflow_0_{x:0>8}, %sbc_reg_signed_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("  %sbc_reg_carry_{x:0>8} = xor i1 %sbc_reg_borrow_{x:0>8}, true\n", .{ address, address });
    try writer.print("  store i1 %sbc_reg_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %sbc_reg_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitSbcImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %sbc_borrow_in_{x:0>8} = xor i1 %flag_c_val_{x:0>8}, true\n", .{ address, address });
    try writer.print("  %sbc_borrow_i32_{x:0>8} = zext i1 %sbc_borrow_in_{x:0>8} to i32\n", .{ address, address });
    try writer.print(
        "  %sbc_ssub_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %sbc_usub_pair_0_{x:0>8} = call {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32 %{s}_{x:0>8}, i32 {d})\n",
        .{ address, lhs_prefix, address, imm },
    );
    try writer.print(
        "  %sbc_sum_0_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_ssub_pair_0_{x:0>8}, 0\n",
        .{ address, address },
    );
    try writer.print("  %sbc_signed_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_ssub_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %sbc_unsigned_overflow_0_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_usub_pair_0_{x:0>8}, 1\n", .{ address, address });
    try writer.print(
        "  %sbc_ssub_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.ssub.with.overflow.i32(i32 %sbc_sum_0_{x:0>8}, i32 %sbc_borrow_i32_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %sbc_usub_pair_1_{x:0>8} = call {{ i32, i1 }} @llvm.usub.with.overflow.i32(i32 %sbc_sum_0_{x:0>8}, i32 %sbc_borrow_i32_{x:0>8})\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %{s}_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_ssub_pair_1_{x:0>8}, 0\n",
        .{ result_prefix, address, address },
    );
    try writer.print("  %sbc_signed_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_ssub_pair_1_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %sbc_unsigned_overflow_1_{x:0>8} = extractvalue {{ i32, i1 }} %sbc_usub_pair_1_{x:0>8}, 1\n", .{ address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print(
        "  %sbc_borrow_{x:0>8} = or i1 %sbc_unsigned_overflow_0_{x:0>8}, %sbc_unsigned_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print(
        "  %sbc_overflow_{x:0>8} = or i1 %sbc_signed_overflow_0_{x:0>8}, %sbc_signed_overflow_1_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("  %sbc_carry_{x:0>8} = xor i1 %sbc_borrow_{x:0>8}, true\n", .{ address, address });
    try writer.print("  store i1 %sbc_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .v);
    try writer.print("  store i1 %sbc_overflow_{x:0>8}, ptr %flag_v_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitSbcImmValue(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    lhs_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %sbc_borrow_in_{x:0>8} = xor i1 %flag_c_val_{x:0>8}, true\n", .{ address, address });
    try writer.print("  %sbc_borrow_i32_{x:0>8} = zext i1 %sbc_borrow_in_{x:0>8} to i32\n", .{ address, address });
    try writer.print("  %sbc_sum_0_{x:0>8} = sub i32 %{s}_{x:0>8}, {d}\n", .{ address, lhs_prefix, address, imm });
    try writer.print("  %{s}_{x:0>8} = sub i32 %sbc_sum_0_{x:0>8}, %sbc_borrow_i32_{x:0>8}\n", .{ result_prefix, address, address, address });
}

fn emitRscImmValue(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    imm: u32,
    rhs_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %rsc_borrow_in_{x:0>8} = xor i1 %flag_c_val_{x:0>8}, true\n", .{ address, address });
    try writer.print("  %rsc_borrow_i32_{x:0>8} = zext i1 %rsc_borrow_in_{x:0>8} to i32\n", .{ address, address });
    try writer.print("  %rsc_sum_0_{x:0>8} = sub i32 {d}, %{s}_{x:0>8}\n", .{ address, imm, rhs_prefix, address });
    try writer.print("  %{s}_{x:0>8} = sub i32 %rsc_sum_0_{x:0>8}, %rsc_borrow_i32_{x:0>8}\n", .{ result_prefix, address, address, address });
}

fn emitAsrImmValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    const shift_amount = if (imm >= 32) 31 else imm;
    try writer.print(
        "  %{s}_{x:0>8} = ashr i32 %{s}_{x:0>8}, {d}\n",
        .{ result_prefix, address, value_prefix, address, shift_amount },
    );
}

fn emitAsrsImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitAsrImmValue(writer, address, value_prefix, imm, result_prefix);
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    const carry_shift_amount = if (imm >= 32) 31 else imm - 1;
    try writer.print(
        "  %asr_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, {d}\n",
        .{ address, value_prefix, address, carry_shift_amount },
    );
    try writer.print("  %asr_carry_bit_{x:0>8} = and i32 %asr_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %asr_carry_{x:0>8} = icmp ne i32 %asr_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %asr_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitLsrImmValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    if (imm >= 32) {
        try writer.print("  %{s}_{x:0>8} = and i32 %{s}_{x:0>8}, 0\n", .{ result_prefix, address, value_prefix, address });
        return;
    }
    try writer.print(
        "  %{s}_{x:0>8} = lshr i32 %{s}_{x:0>8}, {d}\n",
        .{ result_prefix, address, value_prefix, address, imm },
    );
}

fn emitLsrsImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitLsrImmValue(writer, address, value_prefix, imm, result_prefix);
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    const carry_shift_amount = if (imm >= 32) 31 else imm - 1;
    try writer.print(
        "  %lsr_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, {d}\n",
        .{ address, value_prefix, address, carry_shift_amount },
    );
    try writer.print("  %lsr_carry_bit_{x:0>8} = and i32 %lsr_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %lsr_carry_{x:0>8} = icmp ne i32 %lsr_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %lsr_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitRorImmValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitShiftImm(writer, address, value_prefix, result_prefix, .{
        .kind = .ror,
        .amount = imm,
    });
}

fn emitRorsImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitRorImmValue(writer, address, value_prefix, imm, result_prefix);
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  %ror_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, 31\n", .{ address, result_prefix, address });
    try writer.print("  %ror_carry_bit_{x:0>8} = and i32 %ror_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %ror_carry_{x:0>8} = icmp ne i32 %ror_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %ror_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitLslsImmWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    imm: u32,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    if (imm == 0) {
        try writer.print(
            "  %{s}_{x:0>8} = or i32 %{s}_{x:0>8}, 0\n",
            .{ result_prefix, address, value_prefix, address },
        );
        try emitUpdateNzFlags(writer, state_name, address, result_prefix);
        return;
    }

    try writer.print(
        "  %{s}_{x:0>8} = shl i32 %{s}_{x:0>8}, {d}\n",
        .{ result_prefix, address, value_prefix, address, imm },
    );
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print(
        "  %lsls_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, {d}\n",
        .{ address, value_prefix, address, 32 - imm },
    );
    try writer.print("  %lsls_carry_bit_{x:0>8} = and i32 %lsls_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %lsls_carry_{x:0>8} = icmp ne i32 %lsls_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try emitFlagPtr(writer, state_name, address, .c);
    try writer.print("  store i1 %lsls_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitLslRegValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print("  %lsl_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %lsl_is_zero_{x:0>8} = icmp eq i32 %lsl_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %lsl_is_zero_{x:0>8}, label %lsl_zero_{x:0>8}, label %lsl_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsl_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsl_join_{x:0>8}\n", .{address});

    try writer.print("lsl_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %lsl_lt32_{x:0>8} = icmp ult i32 %lsl_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %lsl_lt32_{x:0>8}, label %lsl_lt32_block_{x:0>8}, label %lsl_ge32_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsl_lt32_block_{x:0>8}:\n", .{address});
    try writer.print(
        "  %lsl_lt32_result_{x:0>8} = shl i32 %{s}_{x:0>8}, %lsl_amount_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  br label %lsl_join_{x:0>8}\n", .{address});

    try writer.print("lsl_ge32_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsl_join_{x:0>8}\n", .{address});

    try writer.print("lsl_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %lsl_zero_{x:0>8} ], [ %lsl_lt32_result_{x:0>8}, %lsl_lt32_block_{x:0>8} ], [ 0, %lsl_ge32_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, address, address, address },
    );
}

fn emitLslsRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %lsls_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %lsls_is_zero_{x:0>8} = icmp eq i32 %lsls_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %lsls_is_zero_{x:0>8}, label %lsls_zero_{x:0>8}, label %lsls_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsls_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsls_join_{x:0>8}\n", .{address});

    try writer.print("lsls_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %lsls_lt32_{x:0>8} = icmp ult i32 %lsls_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %lsls_lt32_{x:0>8}, label %lsls_lt32_block_{x:0>8}, label %lsls_ge32_{x:0>8}\n",
        .{ address, address, address },
    );

    try writer.print("lsls_lt32_block_{x:0>8}:\n", .{address});
    try writer.print(
        "  %lsls_lt32_result_{x:0>8} = shl i32 %{s}_{x:0>8}, %lsls_amount_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %lsls_carry_shift_{x:0>8} = sub i32 32, %lsls_amount_{x:0>8}\n", .{ address, address });
    try writer.print(
        "  %lsls_lt32_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, %lsls_carry_shift_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %lsls_lt32_carry_bit_{x:0>8} = and i32 %lsls_lt32_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %lsls_lt32_carry_{x:0>8} = icmp ne i32 %lsls_lt32_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %lsls_join_{x:0>8}\n", .{address});

    try writer.print("lsls_ge32_{x:0>8}:\n", .{address});
    try writer.print("  %lsls_eq32_{x:0>8} = icmp eq i32 %lsls_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %lsls_eq32_{x:0>8}, label %lsls_eq32_block_{x:0>8}, label %lsls_gt32_block_{x:0>8}\n",
        .{ address, address, address },
    );

    try writer.print("lsls_eq32_block_{x:0>8}:\n", .{address});
    try writer.print("  %lsls_eq32_carry_bit_{x:0>8} = and i32 %{s}_{x:0>8}, 1\n", .{ address, value_prefix, address });
    try writer.print("  %lsls_eq32_carry_{x:0>8} = icmp ne i32 %lsls_eq32_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %lsls_join_{x:0>8}\n", .{address});

    try writer.print("lsls_gt32_block_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsls_join_{x:0>8}\n", .{address});

    try writer.print("lsls_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %lsls_zero_{x:0>8} ], [ %lsls_lt32_result_{x:0>8}, %lsls_lt32_block_{x:0>8} ], [ 0, %lsls_eq32_block_{x:0>8} ], [ 0, %lsls_gt32_block_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, address, address, address, address },
    );
    try writer.print(
        "  %lsls_reg_carry_{x:0>8} = phi i1 [ %flag_c_val_{x:0>8}, %lsls_zero_{x:0>8} ], [ %lsls_lt32_carry_{x:0>8}, %lsls_lt32_block_{x:0>8} ], [ %lsls_eq32_carry_{x:0>8}, %lsls_eq32_block_{x:0>8} ], [ false, %lsls_gt32_block_{x:0>8} ]\n",
        .{ address, address, address, address, address, address, address, address },
    );
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  store i1 %lsls_reg_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitLsrRegValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print("  %lsr_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %lsr_is_zero_{x:0>8} = icmp eq i32 %lsr_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %lsr_is_zero_{x:0>8}, label %lsr_zero_{x:0>8}, label %lsr_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsr_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsr_join_{x:0>8}\n", .{address});

    try writer.print("lsr_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %lsr_lt32_{x:0>8} = icmp ult i32 %lsr_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %lsr_lt32_{x:0>8}, label %lsr_lt32_block_{x:0>8}, label %lsr_ge32_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsr_lt32_block_{x:0>8}:\n", .{address});
    try writer.print(
        "  %lsr_lt32_result_{x:0>8} = lshr i32 %{s}_{x:0>8}, %lsr_amount_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  br label %lsr_join_{x:0>8}\n", .{address});

    try writer.print("lsr_ge32_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsr_join_{x:0>8}\n", .{address});

    try writer.print("lsr_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %lsr_zero_{x:0>8} ], [ %lsr_lt32_result_{x:0>8}, %lsr_lt32_block_{x:0>8} ], [ 0, %lsr_ge32_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, address, address, address },
    );
}

fn emitLsrsRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %lsrs_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %lsrs_is_zero_{x:0>8} = icmp eq i32 %lsrs_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %lsrs_is_zero_{x:0>8}, label %lsrs_zero_{x:0>8}, label %lsrs_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsrs_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsrs_join_{x:0>8}\n", .{address});

    try writer.print("lsrs_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %lsrs_lt32_{x:0>8} = icmp ult i32 %lsrs_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %lsrs_lt32_{x:0>8}, label %lsrs_lt32_block_{x:0>8}, label %lsrs_ge32_{x:0>8}\n",
        .{ address, address, address },
    );

    try writer.print("lsrs_lt32_block_{x:0>8}:\n", .{address});
    try writer.print(
        "  %lsrs_lt32_result_{x:0>8} = lshr i32 %{s}_{x:0>8}, %lsrs_amount_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %lsrs_carry_shift_{x:0>8} = sub i32 %lsrs_amount_{x:0>8}, 1\n", .{ address, address });
    try writer.print(
        "  %lsrs_lt32_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, %lsrs_carry_shift_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %lsrs_lt32_carry_bit_{x:0>8} = and i32 %lsrs_lt32_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %lsrs_lt32_carry_{x:0>8} = icmp ne i32 %lsrs_lt32_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %lsrs_join_{x:0>8}\n", .{address});

    try writer.print("lsrs_ge32_{x:0>8}:\n", .{address});
    try writer.print("  %lsrs_eq32_{x:0>8} = icmp eq i32 %lsrs_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %lsrs_eq32_{x:0>8}, label %lsrs_eq32_block_{x:0>8}, label %lsrs_gt32_block_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("lsrs_eq32_block_{x:0>8}:\n", .{address});
    try writer.print("  %lsrs_eq32_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, 31\n", .{ address, value_prefix, address });
    try writer.print("  %lsrs_eq32_carry_bit_{x:0>8} = and i32 %lsrs_eq32_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %lsrs_eq32_carry_{x:0>8} = icmp ne i32 %lsrs_eq32_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %lsrs_join_{x:0>8}\n", .{address});
    try writer.print("lsrs_gt32_block_{x:0>8}:\n", .{address});
    try writer.print("  br label %lsrs_join_{x:0>8}\n", .{address});

    try writer.print("lsrs_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %lsrs_zero_{x:0>8} ], [ %lsrs_lt32_result_{x:0>8}, %lsrs_lt32_block_{x:0>8} ], [ 0, %lsrs_eq32_block_{x:0>8} ], [ 0, %lsrs_gt32_block_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, address, address, address, address },
    );
    try writer.print(
        "  %lsrs_reg_carry_{x:0>8} = phi i1 [ %flag_c_val_{x:0>8}, %lsrs_zero_{x:0>8} ], [ %lsrs_lt32_carry_{x:0>8}, %lsrs_lt32_block_{x:0>8} ], [ %lsrs_eq32_carry_{x:0>8}, %lsrs_eq32_block_{x:0>8} ], [ false, %lsrs_gt32_block_{x:0>8} ]\n",
        .{ address, address, address, address, address, address, address, address },
    );
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  store i1 %lsrs_reg_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitAsrRegValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print("  %asr_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %asr_is_zero_{x:0>8} = icmp eq i32 %asr_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %asr_is_zero_{x:0>8}, label %asr_zero_{x:0>8}, label %asr_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("asr_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %asr_join_{x:0>8}\n", .{address});
    try writer.print("asr_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %asr_lt32_{x:0>8} = icmp ult i32 %asr_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %asr_lt32_{x:0>8}, label %asr_lt32_block_{x:0>8}, label %asr_ge32_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("asr_lt32_block_{x:0>8}:\n", .{address});
    try writer.print(
        "  %asr_lt32_result_{x:0>8} = ashr i32 %{s}_{x:0>8}, %asr_amount_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  br label %asr_join_{x:0>8}\n", .{address});
    try writer.print("asr_ge32_{x:0>8}:\n", .{address});
    try writer.print("  %asr_ge32_result_{x:0>8} = ashr i32 %{s}_{x:0>8}, 31\n", .{ address, value_prefix, address });
    try writer.print("  br label %asr_join_{x:0>8}\n", .{address});
    try writer.print("asr_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %asr_zero_{x:0>8} ], [ %asr_lt32_result_{x:0>8}, %asr_lt32_block_{x:0>8} ], [ %asr_ge32_result_{x:0>8}, %asr_ge32_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, address, address, address, address },
    );
}

fn emitAsrsRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %asrs_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %asrs_is_zero_{x:0>8} = icmp eq i32 %asrs_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %asrs_is_zero_{x:0>8}, label %asrs_zero_{x:0>8}, label %asrs_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("asrs_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %asrs_join_{x:0>8}\n", .{address});
    try writer.print("asrs_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %asrs_lt32_{x:0>8} = icmp ult i32 %asrs_amount_{x:0>8}, 32\n", .{ address, address });
    try writer.print(
        "  br i1 %asrs_lt32_{x:0>8}, label %asrs_lt32_block_{x:0>8}, label %asrs_ge32_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("asrs_lt32_block_{x:0>8}:\n", .{address});
    try writer.print(
        "  %asrs_lt32_result_{x:0>8} = ashr i32 %{s}_{x:0>8}, %asrs_amount_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %asrs_carry_shift_{x:0>8} = sub i32 %asrs_amount_{x:0>8}, 1\n", .{ address, address });
    try writer.print(
        "  %asrs_lt32_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, %asrs_carry_shift_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %asrs_lt32_carry_bit_{x:0>8} = and i32 %asrs_lt32_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %asrs_lt32_carry_{x:0>8} = icmp ne i32 %asrs_lt32_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %asrs_join_{x:0>8}\n", .{address});
    try writer.print("asrs_ge32_{x:0>8}:\n", .{address});
    try writer.print("  %asrs_ge32_result_{x:0>8} = ashr i32 %{s}_{x:0>8}, 31\n", .{ address, value_prefix, address });
    try writer.print("  %asrs_ge32_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, 31\n", .{ address, value_prefix, address });
    try writer.print("  %asrs_ge32_carry_bit_{x:0>8} = and i32 %asrs_ge32_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %asrs_ge32_carry_{x:0>8} = icmp ne i32 %asrs_ge32_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %asrs_join_{x:0>8}\n", .{address});
    try writer.print("asrs_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %asrs_zero_{x:0>8} ], [ %asrs_lt32_result_{x:0>8}, %asrs_lt32_block_{x:0>8} ], [ %asrs_ge32_result_{x:0>8}, %asrs_ge32_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, address, address, address, address },
    );
    try writer.print(
        "  %asrs_reg_carry_{x:0>8} = phi i1 [ %flag_c_val_{x:0>8}, %asrs_zero_{x:0>8} ], [ %asrs_lt32_carry_{x:0>8}, %asrs_lt32_block_{x:0>8} ], [ %asrs_ge32_carry_{x:0>8}, %asrs_ge32_{x:0>8} ]\n",
        .{ address, address, address, address, address, address, address },
    );
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  store i1 %asrs_reg_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitRorRegValue(
    writer: *Io.Writer,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print("  %ror_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %ror_is_zero_{x:0>8} = icmp eq i32 %ror_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %ror_is_zero_{x:0>8}, label %ror_zero_{x:0>8}, label %ror_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("ror_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %ror_join_{x:0>8}\n", .{address});
    try writer.print("ror_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %ror_mod_{x:0>8} = and i32 %ror_amount_{x:0>8}, 31\n", .{ address, address });
    try writer.print("  %ror_mod_zero_{x:0>8} = icmp eq i32 %ror_mod_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %ror_mod_zero_{x:0>8}, label %ror_mod_zero_block_{x:0>8}, label %ror_mod_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("ror_mod_zero_block_{x:0>8}:\n", .{address});
    try writer.print("  br label %ror_join_{x:0>8}\n", .{address});
    try writer.print("ror_mod_nonzero_{x:0>8}:\n", .{address});
    try writer.print(
        "  %ror_lo_{x:0>8} = lshr i32 %{s}_{x:0>8}, %ror_mod_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %ror_left_shift_{x:0>8} = sub i32 32, %ror_mod_{x:0>8}\n", .{ address, address });
    try writer.print(
        "  %ror_hi_{x:0>8} = shl i32 %{s}_{x:0>8}, %ror_left_shift_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %ror_mod_result_{x:0>8} = or i32 %ror_lo_{x:0>8}, %ror_hi_{x:0>8}\n", .{ address, address, address });
    try writer.print("  br label %ror_join_{x:0>8}\n", .{address});
    try writer.print("ror_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %ror_zero_{x:0>8} ], [ %{s}_{x:0>8}, %ror_mod_zero_block_{x:0>8} ], [ %ror_mod_result_{x:0>8}, %ror_mod_nonzero_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, value_prefix, address, address, address, address },
    );
}

fn emitRorsRegWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    amount_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %rors_amount_{x:0>8} = and i32 %{s}_{x:0>8}, 255\n", .{ address, amount_prefix, address });
    try writer.print("  %rors_is_zero_{x:0>8} = icmp eq i32 %rors_amount_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %rors_is_zero_{x:0>8}, label %rors_zero_{x:0>8}, label %rors_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("rors_zero_{x:0>8}:\n", .{address});
    try writer.print("  br label %rors_join_{x:0>8}\n", .{address});
    try writer.print("rors_nonzero_{x:0>8}:\n", .{address});
    try writer.print("  %rors_mod_{x:0>8} = and i32 %rors_amount_{x:0>8}, 31\n", .{ address, address });
    try writer.print("  %rors_mod_zero_{x:0>8} = icmp eq i32 %rors_mod_{x:0>8}, 0\n", .{ address, address });
    try writer.print(
        "  br i1 %rors_mod_zero_{x:0>8}, label %rors_mod_zero_block_{x:0>8}, label %rors_mod_nonzero_{x:0>8}\n",
        .{ address, address, address },
    );
    try writer.print("rors_mod_zero_block_{x:0>8}:\n", .{address});
    try writer.print("  %rors_mod_zero_carry_src_{x:0>8} = lshr i32 %{s}_{x:0>8}, 31\n", .{ address, value_prefix, address });
    try writer.print("  %rors_mod_zero_carry_bit_{x:0>8} = and i32 %rors_mod_zero_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %rors_mod_zero_carry_{x:0>8} = icmp ne i32 %rors_mod_zero_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %rors_join_{x:0>8}\n", .{address});
    try writer.print("rors_mod_nonzero_{x:0>8}:\n", .{address});
    try writer.print(
        "  %rors_lo_{x:0>8} = lshr i32 %{s}_{x:0>8}, %rors_mod_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %rors_left_shift_{x:0>8} = sub i32 32, %rors_mod_{x:0>8}\n", .{ address, address });
    try writer.print(
        "  %rors_hi_{x:0>8} = shl i32 %{s}_{x:0>8}, %rors_left_shift_{x:0>8}\n",
        .{ address, value_prefix, address, address },
    );
    try writer.print("  %rors_mod_result_{x:0>8} = or i32 %rors_lo_{x:0>8}, %rors_hi_{x:0>8}\n", .{ address, address, address });
    try writer.print("  %rors_mod_carry_src_{x:0>8} = lshr i32 %rors_mod_result_{x:0>8}, 31\n", .{ address, address });
    try writer.print("  %rors_mod_carry_bit_{x:0>8} = and i32 %rors_mod_carry_src_{x:0>8}, 1\n", .{ address, address });
    try writer.print("  %rors_mod_carry_{x:0>8} = icmp ne i32 %rors_mod_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  br label %rors_join_{x:0>8}\n", .{address});
    try writer.print("rors_join_{x:0>8}:\n", .{address});
    try writer.print(
        "  %{s}_{x:0>8} = phi i32 [ %{s}_{x:0>8}, %rors_zero_{x:0>8} ], [ %{s}_{x:0>8}, %rors_mod_zero_block_{x:0>8} ], [ %rors_mod_result_{x:0>8}, %rors_mod_nonzero_{x:0>8} ]\n",
        .{ result_prefix, address, value_prefix, address, address, value_prefix, address, address, address, address },
    );
    try writer.print(
        "  %rors_reg_carry_{x:0>8} = phi i1 [ %flag_c_val_{x:0>8}, %rors_zero_{x:0>8} ], [ %rors_mod_zero_carry_{x:0>8}, %rors_mod_zero_block_{x:0>8} ], [ %rors_mod_carry_{x:0>8}, %rors_mod_nonzero_{x:0>8} ]\n",
        .{ address, address, address, address, address, address, address },
    );
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  store i1 %rors_reg_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitRrxsWithFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
    result_prefix: []const u8,
) Io.Writer.Error!void {
    try emitFlagLoad(writer, state_name, address, .c);
    try writer.print("  %rrx_carry_in_{x:0>8} = zext i1 %flag_c_val_{x:0>8} to i32\n", .{ address, address });
    try writer.print("  %rrx_carry_hi_{x:0>8} = shl i32 %rrx_carry_in_{x:0>8}, 31\n", .{ address, address });
    try writer.print("  %rrx_value_lo_{x:0>8} = lshr i32 %{s}_{x:0>8}, 1\n", .{ address, value_prefix, address });
    try writer.print("  %{s}_{x:0>8} = or i32 %rrx_carry_hi_{x:0>8}, %rrx_value_lo_{x:0>8}\n", .{ result_prefix, address, address, address });
    try emitUpdateNzFlags(writer, state_name, address, result_prefix);
    try writer.print("  %rrx_carry_bit_{x:0>8} = and i32 %{s}_{x:0>8}, 1\n", .{ address, value_prefix, address });
    try writer.print("  %rrx_carry_{x:0>8} = icmp ne i32 %rrx_carry_bit_{x:0>8}, 0\n", .{ address, address });
    try writer.print("  store i1 %rrx_carry_{x:0>8}, ptr %flag_c_ptr_{x:0>8}, align 1\n", .{ address, address });
}

fn emitFinalOutput(writer: *Io.Writer, output_mode: OutputMode) Io.Writer.Error!void {
    switch (output_mode) {
        .register_r0_decimal => {
            try writer.print(
                "  %state_regs_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_regs_field},
            );
            try writer.print("  %r0_ptr_done = getelementptr inbounds [16 x i32], ptr %state_regs_done, i32 0, i32 0\n", .{});
            try writer.print("  %result = load i32, ptr %r0_ptr_done, align 4\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_r0, i32 %result)\n", .{});
        },
        .memory_summary => {
            try writer.print(
                "  %state_io_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_io_field},
            );
            try writer.print(
                "  %state_palette_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_palette_field},
            );
            try writer.print(
                "  %state_vram_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_vram_field},
            );
            try writer.print("  %io0_ptr = getelementptr inbounds [1024 x i8], ptr %state_io_done, i32 0, i32 0\n", .{});
            try writer.print("  %io0 = load i32, ptr %io0_ptr, align 1\n", .{});
            try writer.print("  %io8_ptr = getelementptr inbounds [1024 x i8], ptr %state_io_done, i32 0, i32 8\n", .{});
            try writer.print("  %io8 = load i32, ptr %io8_ptr, align 1\n", .{});
            try writer.print("  %pal0_ptr = getelementptr inbounds [1024 x i8], ptr %state_palette_done, i32 0, i32 0\n", .{});
            try writer.print("  %pal0_raw = load i16, ptr %pal0_ptr, align 1\n", .{});
            try writer.print("  %pal0 = zext i16 %pal0_raw to i32\n", .{});
            try writer.print("  %pal2_ptr = getelementptr inbounds [1024 x i8], ptr %state_palette_done, i32 0, i32 2\n", .{});
            try writer.print("  %pal2_raw = load i16, ptr %pal2_ptr, align 1\n", .{});
            try writer.print("  %pal2 = zext i16 %pal2_raw to i32\n", .{});
            try writer.print("  %vram4000_ptr = getelementptr inbounds [98304 x i8], ptr %state_vram_done, i32 0, i32 16384\n", .{});
            try writer.print("  %vram4000 = load i32, ptr %vram4000_ptr, align 1\n", .{});
            try writer.print("  %map0800_ptr = getelementptr inbounds [98304 x i8], ptr %state_vram_done, i32 0, i32 2048\n", .{});
            try writer.print("  %map0800_raw = load i16, ptr %map0800_ptr, align 1\n", .{});
            try writer.print("  %map0800 = zext i16 %map0800_raw to i32\n", .{});
            try writer.print("  %map0804_ptr = getelementptr inbounds [98304 x i8], ptr %state_vram_done, i32 0, i32 2052\n", .{});
            try writer.print("  %map0804_raw = load i16, ptr %map0804_ptr, align 1\n", .{});
            try writer.print("  %map0804 = zext i16 %map0804_raw to i32\n", .{});
            try writer.print(
                "  call i32 (ptr, ...) @printf(ptr @.fmt_mem, i32 %io0, i32 %io8, i32 %pal0, i32 %pal2, i32 %vram4000, i32 %map0800, i32 %map0804)\n",
                .{},
            );
        },
        .arm_report => {
            try writer.print(
                "  %state_regs_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_regs_field},
            );
            try writer.print("  %r12_ptr_done = getelementptr inbounds [16 x i32], ptr %state_regs_done, i32 0, i32 12\n", .{});
            try writer.print("  %arm_report_code = load i32, ptr %r12_ptr_done, align 4\n", .{});
            try writer.print("  %arm_report_pass = icmp eq i32 %arm_report_code, 0\n", .{});
            try writer.print("  br i1 %arm_report_pass, label %arm_report_pass_block, label %arm_report_fail_block\n", .{});
            try writer.print("arm_report_pass_block:\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_arm_pass)\n", .{});
            try writer.print("  br label %arm_report_done\n", .{});
            try writer.print("arm_report_fail_block:\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_arm_fail, i32 %arm_report_code)\n", .{});
            try writer.print("  br label %arm_report_done\n", .{});
            try writer.print("arm_report_done:\n", .{});
        },
        .frame_raw => {
            try writer.print("  %frame_output_enabled = call i32 @hm_runtime_output_mode_frame_raw()\n", .{});
            try writer.print("  %frame_output_should_run = icmp ne i32 %frame_output_enabled, 0\n", .{});
            try writer.print("  br i1 %frame_output_should_run, label %frame_output_run, label %frame_output_done\n", .{});
            try writer.print("frame_output_run:\n", .{});
            try writer.print(
                "  %state_io_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_io_field},
            );
            try writer.print(
                "  %state_palette_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_palette_field},
            );
            try writer.print(
                "  %state_vram_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_vram_field},
            );
            try writer.print(
                "  %state_oam_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_oam_field},
            );
            try writer.print(
                "  %frame_output_result = call i32 @hmgba_dump_frame_raw(ptr %state_io_done, ptr %state_palette_done, ptr %state_vram_done, ptr %state_oam_done)\n",
                .{},
            );
            try writer.print("  %frame_output_ok = icmp eq i32 %frame_output_result, 0\n", .{});
            try writer.print("  br i1 %frame_output_ok, label %frame_output_done, label %frame_output_error\n", .{});
            try writer.print("frame_output_error:\n", .{});
            try writer.print("  switch i32 %frame_output_result, label %frame_output_done [\n", .{});
            try writer.print("    i32 1, label %frame_output_missing_path\n", .{});
            try writer.print("    i32 2, label %frame_output_bad_mode\n", .{});
            try writer.print("    i32 3, label %frame_output_write_failed\n", .{});
            try writer.print("  ]\n", .{});
            try writer.print("frame_output_missing_path:\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_frame_missing_path)\n", .{});
            try writer.print("  br label %frame_output_done\n", .{});
            try writer.print("frame_output_bad_mode:\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_frame_bad_mode)\n", .{});
            try writer.print("  br label %frame_output_done\n", .{});
            try writer.print("frame_output_write_failed:\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_frame_write_failed)\n", .{});
            try writer.print("  br label %frame_output_done\n", .{});
            try writer.print("frame_output_done:\n", .{});
        },
        .retired_count => {
            try writer.print(
                "  %retired_count_done = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
                .{guest_state_retired_count_field},
            );
            try writer.print("  %retired_count_value = load i64, ptr %retired_count_done, align 8\n", .{});
            try writer.print("  call i32 (ptr, ...) @printf(ptr @.fmt_retired, i64 %retired_count_value)\n", .{});
        },
    }
}

fn emitRegPtr(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    prefix: []const u8,
    reg_index: u4,
) Io.Writer.Error!void {
    try writer.print(
        "  %regs_ptr_{s}_{x:0>8} = getelementptr inbounds %GuestState, ptr %{s}, i32 0, i32 {d}\n",
        .{ prefix, address, state_name, guest_state_regs_field },
    );
    try writer.print(
        "  %{s}_ptr_{x:0>8} = getelementptr inbounds [16 x i32], ptr %regs_ptr_{s}_{x:0>8}, i32 0, i32 {d}\n",
        .{ prefix, address, prefix, address, reg_index },
    );
}

fn emitReadAluRegValue(
    writer: *Io.Writer,
    isa: armv4t_decode.InstructionSet,
    state_name: []const u8,
    address: u32,
    prefix: []const u8,
    reg_index: u4,
) Io.Writer.Error!void {
    try emitReadRegValueWithPc(writer, state_name, address, prefix, reg_index, architecturalPcValue(isa, address));
}

fn emitReadShiftRegValue(
    writer: *Io.Writer,
    isa: armv4t_decode.InstructionSet,
    state_name: []const u8,
    address: u32,
    prefix: []const u8,
    reg_index: u4,
) Io.Writer.Error!void {
    try emitReadRegValueWithPc(writer, state_name, address, prefix, reg_index, shiftRegisterPcValue(isa, address));
}

fn emitReadRegValueWithPc(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    prefix: []const u8,
    reg_index: u4,
    pc_value: u32,
) Io.Writer.Error!void {
    if (reg_index == 15) {
        try writer.print(
            "  %{s}_val_{x:0>8} = or i32 0, {d}\n",
            .{ prefix, address, pc_value },
        );
        return;
    }

    try emitRegPtr(writer, state_name, address, prefix, reg_index);
    try writer.print(
        "  %{s}_val_{x:0>8} = load i32, ptr %{s}_ptr_{x:0>8}, align 4\n",
        .{ prefix, address, prefix, address },
    );
}

fn emitArchitecturalPcState(
    writer: *Io.Writer,
    isa: armv4t_decode.InstructionSet,
    address: u32,
) Io.Writer.Error!void {
    try emitRegPtr(writer, "state", address, "pc_state", 15);
    try writer.print(
        "  store i32 {d}, ptr %pc_state_ptr_{x:0>8}, align 4\n",
        .{ architecturalPcValue(isa, address), address },
    );
}

const Flag = enum {
    n,
    z,
    c,
    v,
};

fn emitFlagZPtr(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
) Io.Writer.Error!void {
    try emitFlagPtr(writer, state_name, address, .z);
}

fn emitFlagPtr(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    flag: Flag,
) Io.Writer.Error!void {
    try writer.print(
        "  %{s}_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %{s}, i32 0, i32 {d}\n",
        .{ flagPtrPrefix(flag), address, state_name, flagFieldIndex(flag) },
    );
}

fn emitFlagLoad(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    flag: Flag,
) Io.Writer.Error!void {
    try emitFlagPtr(writer, state_name, address, flag);
    try writer.print(
        "  %{s}_val_{x:0>8} = load i1, ptr %{s}_ptr_{x:0>8}, align 1\n",
        .{ flagPtrPrefix(flag), address, flagPtrPrefix(flag), address },
    );
}

fn emitUpdateNzFlags(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    value_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print(
        "  %nz_zero_{s}_{x:0>8} = icmp eq i32 %{s}_{x:0>8}, 0\n",
        .{ value_prefix, address, value_prefix, address },
    );
    try emitFlagPtr(writer, state_name, address, .z);
    try writer.print(
        "  store i1 %nz_zero_{s}_{x:0>8}, ptr %flag_z_ptr_{x:0>8}, align 1\n",
        .{ value_prefix, address, address },
    );
    try writer.print(
        "  %nz_negative_{s}_{x:0>8} = icmp slt i32 %{s}_{x:0>8}, 0\n",
        .{ value_prefix, address, value_prefix, address },
    );
    try emitFlagPtr(writer, state_name, address, .n);
    try writer.print(
        "  store i1 %nz_negative_{s}_{x:0>8}, ptr %flag_n_ptr_{x:0>8}, align 1\n",
        .{ value_prefix, address, address },
    );
}

fn emitPushRegs(writer: *Io.Writer, address: u32, mask: u16) Io.Writer.Error!void {
    try emitStoreMultiple(writer, address, 13, mask, true, .db);
}

fn emitPopRegs(writer: *Io.Writer, address: u32, mask: u16) Io.Writer.Error!void {
    try emitLoadMultiple(writer, address, 13, mask, true, .ia);
}

fn emitEmptyStoreMultiple(
    writer: *Io.Writer,
    address: u32,
    base_reg: u4,
    writeback: bool,
    mode: armv4t_decode.BlockTransferMode,
) Io.Writer.Error!void {
    const reg_count: u16 = 16;
    const start_offset = blockTransferStartOffset(mode, reg_count);
    const writeback_offset = blockTransferWritebackOffset(mode, reg_count);

    try emitRegPtr(writer, "state", address, "stm_empty_base", base_reg);
    try writer.print("  %stm_empty_base_val_{x:0>8} = load i32, ptr %stm_empty_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    if (start_offset == 0) {
        try writer.print("  %stm_empty_addr_{x:0>8} = or i32 %stm_empty_base_val_{x:0>8}, 0\n", .{ address, address });
    } else {
        try writer.print("  %stm_empty_addr_{x:0>8} = add i32 %stm_empty_base_val_{x:0>8}, {d}\n", .{ address, address, start_offset });
    }
    try writer.print("  call void @hmn_store32(ptr %state, i32 %stm_empty_addr_{x:0>8}, i32 {d})\n", .{ address, address + 12 });
    if (writeback) {
        if (writeback_offset == 0) {
            try writer.print("  %stm_empty_new_base_{x:0>8} = or i32 %stm_empty_base_val_{x:0>8}, 0\n", .{ address, address });
        } else {
            try writer.print("  %stm_empty_new_base_{x:0>8} = add i32 %stm_empty_base_val_{x:0>8}, {d}\n", .{ address, address, writeback_offset });
        }
        try writer.print("  store i32 %stm_empty_new_base_{x:0>8}, ptr %stm_empty_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    }
}

fn emitStoreMultiple(
    writer: *Io.Writer,
    address: u32,
    base_reg: u4,
    mask: u16,
    writeback: bool,
    mode: armv4t_decode.BlockTransferMode,
) Io.Writer.Error!void {
    const reg_count = registerMaskCount(mask);
    const start_offset = blockTransferStartOffset(mode, reg_count);
    const writeback_offset = blockTransferWritebackOffset(mode, reg_count);

    try emitRegPtr(writer, "state", address, "stm_base", base_reg);
    try writer.print("  %stm_base_val_{x:0>8} = load i32, ptr %stm_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    if (start_offset == 0) {
        try writer.print("  %stm_start_{x:0>8} = or i32 %stm_base_val_{x:0>8}, 0\n", .{ address, address });
    } else {
        try writer.print("  %stm_start_{x:0>8} = add i32 %stm_base_val_{x:0>8}, {d}\n", .{ address, address, start_offset });
    }
    try writer.print(
        "  %stm_regs_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ address, guest_state_regs_field },
    );

    var slot_index: u32 = 0;
    for (0..16) |reg_index_usize| {
        const reg_index: u4 = @intCast(reg_index_usize);
        if ((mask & (@as(u16, 1) << reg_index)) == 0) continue;

        try writer.print(
            "  %stm_addr_r{d}_{x:0>8} = add i32 %stm_start_{x:0>8}, {d}\n",
            .{ reg_index, address, address, slot_index * 4 },
        );
        try writer.print(
            "  %stm_src_r{d}_{x:0>8} = getelementptr inbounds [16 x i32], ptr %stm_regs_ptr_{x:0>8}, i32 0, i32 {d}\n",
            .{ reg_index, address, address, reg_index },
        );
        try writer.print("  %stm_val_r{d}_{x:0>8} = load i32, ptr %stm_src_r{d}_{x:0>8}, align 4\n", .{
            reg_index,
            address,
            reg_index,
            address,
        });
        try writer.print(
            "  call void @hmn_store32(ptr %state, i32 %stm_addr_r{d}_{x:0>8}, i32 %stm_val_r{d}_{x:0>8})\n",
            .{ reg_index, address, reg_index, address },
        );
        slot_index += 1;
    }

    if (writeback) {
        if (writeback_offset == 0) {
            try writer.print("  %stm_new_base_{x:0>8} = or i32 %stm_base_val_{x:0>8}, 0\n", .{ address, address });
        } else {
            try writer.print("  %stm_new_base_{x:0>8} = add i32 %stm_base_val_{x:0>8}, {d}\n", .{ address, address, writeback_offset });
        }
        try writer.print("  store i32 %stm_new_base_{x:0>8}, ptr %stm_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    }
}

fn emitLoadMultiple(
    writer: *Io.Writer,
    address: u32,
    base_reg: u4,
    mask: u16,
    writeback: bool,
    mode: armv4t_decode.BlockTransferMode,
) Io.Writer.Error!void {
    const reg_count = registerMaskCount(mask);
    const start_offset = blockTransferStartOffset(mode, reg_count);
    const writeback_offset = blockTransferWritebackOffset(mode, reg_count);
    try emitRegPtr(writer, "state", address, "ldm_base", base_reg);
    try writer.print("  %ldm_base_val_{x:0>8} = load i32, ptr %ldm_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    if (start_offset == 0) {
        try writer.print("  %ldm_start_{x:0>8} = or i32 %ldm_base_val_{x:0>8}, 0\n", .{ address, address });
    } else {
        try writer.print("  %ldm_start_{x:0>8} = add i32 %ldm_base_val_{x:0>8}, {d}\n", .{ address, address, start_offset });
    }
    try writer.print(
        "  %ldm_regs_ptr_{x:0>8} = getelementptr inbounds %GuestState, ptr %state, i32 0, i32 {d}\n",
        .{ address, guest_state_regs_field },
    );

    var slot_index: u32 = 0;
    for (0..16) |reg_index_usize| {
        const reg_index: u4 = @intCast(reg_index_usize);
        if ((mask & (@as(u16, 1) << reg_index)) == 0) continue;

        try writer.print(
            "  %ldm_addr_r{d}_{x:0>8} = add i32 %ldm_start_{x:0>8}, {d}\n",
            .{ reg_index, address, address, slot_index * 4 },
        );
        try writer.print(
            "  %ldm_val_r{d}_{x:0>8} = call i32 @hmn_load32(ptr %state, i32 %ldm_addr_r{d}_{x:0>8})\n",
            .{ reg_index, address, reg_index, address },
        );
        if (reg_index != 15) {
            try writer.print(
                "  %ldm_dst_r{d}_{x:0>8} = getelementptr inbounds [16 x i32], ptr %ldm_regs_ptr_{x:0>8}, i32 0, i32 {d}\n",
                .{ reg_index, address, address, reg_index },
            );
            try writer.print("  store i32 %ldm_val_r{d}_{x:0>8}, ptr %ldm_dst_r{d}_{x:0>8}, align 4\n", .{
                reg_index,
                address,
                reg_index,
                address,
            });
        }
        slot_index += 1;
    }

    if (writeback) {
        if (writeback_offset == 0) {
            try writer.print("  %ldm_new_base_{x:0>8} = or i32 %ldm_base_val_{x:0>8}, 0\n", .{ address, address });
        } else {
            try writer.print("  %ldm_new_base_{x:0>8} = add i32 %ldm_base_val_{x:0>8}, {d}\n", .{
                address,
                address,
                writeback_offset,
            });
        }
        try writer.print("  store i32 %ldm_new_base_{x:0>8}, ptr %ldm_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    }
}

fn emitEmptyLoadMultiplePcTarget(
    writer: *Io.Writer,
    address: u32,
    base_reg: u4,
    writeback: bool,
    mode: armv4t_decode.BlockTransferMode,
) Io.Writer.Error!void {
    const reg_count: u16 = 16;
    const writeback_offset = blockTransferWritebackOffset(mode, reg_count);
    try emitRegPtr(writer, "state", address, "ldm_empty_base", base_reg);
    try writer.print("  %ldm_empty_base_val_{x:0>8} = load i32, ptr %ldm_empty_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    if (writeback) {
        if (writeback_offset == 0) {
            try writer.print("  %ldm_empty_new_base_{x:0>8} = or i32 %ldm_empty_base_val_{x:0>8}, 0\n", .{ address, address });
        } else {
            try writer.print("  %ldm_empty_new_base_{x:0>8} = add i32 %ldm_empty_base_val_{x:0>8}, {d}\n", .{ address, address, writeback_offset });
        }
        try writer.print("  store i32 %ldm_empty_new_base_{x:0>8}, ptr %ldm_empty_base_ptr_{x:0>8}, align 4\n", .{ address, address });
    }
}

fn blockTransferStartOffset(mode: armv4t_decode.BlockTransferMode, reg_count: u16) i32 {
    return switch (mode) {
        .ia => 0,
        .ib => 4,
        .da => -@as(i32, @intCast((reg_count - 1) * 4)),
        .db => -@as(i32, @intCast(reg_count * 4)),
    };
}

fn blockTransferWritebackOffset(mode: armv4t_decode.BlockTransferMode, reg_count: u16) i32 {
    return switch (mode) {
        .ia, .ib => @intCast(reg_count * 4),
        .da, .db => -@as(i32, @intCast(reg_count * 4)),
    };
}

fn emitBranchCondition(
    writer: *Io.Writer,
    state_name: []const u8,
    address: u32,
    cond: armv4t_decode.Cond,
) Io.Writer.Error!void {
    switch (cond) {
        .eq => {
            try emitFlagLoad(writer, state_name, address, .z);
            try writer.print("  %branch_cond_{x:0>8} = or i1 %flag_z_val_{x:0>8}, false\n", .{ address, address });
        },
        .ne => {
            try emitFlagLoad(writer, state_name, address, .z);
            try writer.print("  %branch_cond_{x:0>8} = xor i1 %flag_z_val_{x:0>8}, true\n", .{ address, address });
        },
        .hs => {
            try emitFlagLoad(writer, state_name, address, .c);
            try writer.print("  %branch_cond_{x:0>8} = or i1 %flag_c_val_{x:0>8}, false\n", .{ address, address });
        },
        .lo => {
            try emitFlagLoad(writer, state_name, address, .c);
            try writer.print("  %branch_cond_{x:0>8} = xor i1 %flag_c_val_{x:0>8}, true\n", .{ address, address });
        },
        .mi => {
            try emitFlagLoad(writer, state_name, address, .n);
            try writer.print("  %branch_cond_{x:0>8} = or i1 %flag_n_val_{x:0>8}, false\n", .{ address, address });
        },
        .pl => {
            try emitFlagLoad(writer, state_name, address, .n);
            try writer.print("  %branch_cond_{x:0>8} = xor i1 %flag_n_val_{x:0>8}, true\n", .{ address, address });
        },
        .vs => {
            try emitFlagLoad(writer, state_name, address, .v);
            try writer.print("  %branch_cond_{x:0>8} = or i1 %flag_v_val_{x:0>8}, false\n", .{ address, address });
        },
        .vc => {
            try emitFlagLoad(writer, state_name, address, .v);
            try writer.print("  %branch_cond_{x:0>8} = xor i1 %flag_v_val_{x:0>8}, true\n", .{ address, address });
        },
        .hi => {
            try emitFlagLoad(writer, state_name, address, .c);
            try emitFlagLoad(writer, state_name, address, .z);
            try writer.print("  %not_z_{x:0>8} = xor i1 %flag_z_val_{x:0>8}, true\n", .{ address, address });
            try writer.print("  %branch_cond_{x:0>8} = and i1 %flag_c_val_{x:0>8}, %not_z_{x:0>8}\n", .{ address, address, address });
        },
        .ls => {
            try emitFlagLoad(writer, state_name, address, .c);
            try emitFlagLoad(writer, state_name, address, .z);
            try writer.print("  %not_c_{x:0>8} = xor i1 %flag_c_val_{x:0>8}, true\n", .{ address, address });
            try writer.print("  %branch_cond_{x:0>8} = or i1 %not_c_{x:0>8}, %flag_z_val_{x:0>8}\n", .{ address, address, address });
        },
        .ge => {
            try emitFlagLoad(writer, state_name, address, .n);
            try emitFlagLoad(writer, state_name, address, .v);
            try writer.print("  %branch_cond_{x:0>8} = icmp eq i1 %flag_n_val_{x:0>8}, %flag_v_val_{x:0>8}\n", .{ address, address, address });
        },
        .lt => {
            try emitFlagLoad(writer, state_name, address, .n);
            try emitFlagLoad(writer, state_name, address, .v);
            try writer.print("  %branch_cond_{x:0>8} = icmp ne i1 %flag_n_val_{x:0>8}, %flag_v_val_{x:0>8}\n", .{ address, address, address });
        },
        .gt => {
            try emitFlagLoad(writer, state_name, address, .n);
            try emitFlagLoad(writer, state_name, address, .v);
            try emitFlagLoad(writer, state_name, address, .z);
            try writer.print("  %eq_nv_{x:0>8} = icmp eq i1 %flag_n_val_{x:0>8}, %flag_v_val_{x:0>8}\n", .{ address, address, address });
            try writer.print("  %not_z_{x:0>8} = xor i1 %flag_z_val_{x:0>8}, true\n", .{ address, address });
            try writer.print("  %branch_cond_{x:0>8} = and i1 %eq_nv_{x:0>8}, %not_z_{x:0>8}\n", .{ address, address, address });
        },
        .le => {
            try emitFlagLoad(writer, state_name, address, .n);
            try emitFlagLoad(writer, state_name, address, .v);
            try emitFlagLoad(writer, state_name, address, .z);
            try writer.print("  %lt_nv_{x:0>8} = icmp ne i1 %flag_n_val_{x:0>8}, %flag_v_val_{x:0>8}\n", .{ address, address, address });
            try writer.print("  %branch_cond_{x:0>8} = or i1 %lt_nv_{x:0>8}, %flag_z_val_{x:0>8}\n", .{ address, address, address });
        },
        .al => unreachable,
    }
}

fn boolLiteral(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn instructionSetName(isa: armv4t_decode.InstructionSet) []const u8 {
    return switch (isa) {
        .arm => "arm",
        .thumb => "thumb",
    };
}

fn architecturalPcValue(isa: armv4t_decode.InstructionSet, address: u32) u32 {
    return switch (isa) {
        .arm => address + 8,
        .thumb => (address + 4) & ~@as(u32, 3),
    };
}

fn shiftRegisterPcValue(isa: armv4t_decode.InstructionSet, address: u32) u32 {
    return switch (isa) {
        .arm => address + 12,
        .thumb => architecturalPcValue(isa, address),
    };
}

fn registerMaskCount(mask: u16) u16 {
    var remaining = mask;
    var count: u16 = 0;
    while (remaining != 0) {
        count += @intFromBool((remaining & 1) != 0);
        remaining >>= 1;
    }
    return count;
}

fn registerMaskIncludesPc(mask: u16) bool {
    return (mask & (@as(u16, 1) << 15)) != 0;
}

fn flagFieldIndex(flag: Flag) u8 {
    return switch (flag) {
        .n => guest_state_flag_n_field,
        .z => guest_state_flag_z_field,
        .c => guest_state_flag_c_field,
        .v => guest_state_flag_v_field,
    };
}

fn flagPtrPrefix(flag: Flag) []const u8 {
    return switch (flag) {
        .n => "flag_n",
        .z => "flag_z",
        .c => "flag_c",
        .v => "flag_v",
    };
}

fn emitFallthrough(writer: *Io.Writer, function: Function, address: u32) Io.Writer.Error!void {
    if (hasAddress(function, address)) {
        try emitBranchTo(writer, address);
    } else {
        try emitFunctionReturn(writer, function.entry);
    }
}

fn emitBranchTo(writer: *Io.Writer, address: u32) Io.Writer.Error!void {
    try writer.print("  br label %pc_{x:0>8}\n", .{address});
}

fn emitPcDispatch(
    writer: *Io.Writer,
    function: Function,
    address: u32,
    value_prefix: []const u8,
) Io.Writer.Error!void {
    try writer.print(
        "  switch i32 %{s}_{x:0>8}, label %guest_return_{s}_{x:0>8} [\n",
        .{ value_prefix, address, instructionSetName(function.entry.isa), function.entry.address },
    );
    for (function.instructions) |candidate| {
        try writer.print(
            "    i32 {d}, label %pc_{x:0>8}\n",
            .{ candidate.address, candidate.address },
        );
    }
    try writer.print("  ]\n", .{});
}

fn emitFunctionReturn(writer: *Io.Writer, entry: armv4t_decode.CodeAddress) Io.Writer.Error!void {
    try writer.print("  br label %guest_return_{s}_{x:0>8}\n", .{
        instructionSetName(entry.isa),
        entry.address,
    });
}

fn hasAddress(function: Function, address: u32) bool {
    for (function.instructions) |node| {
        if (node.address == address) return true;
    }
    return false;
}

test "llvm emission includes guest state and a lifted guest entry function" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 0, .imm = 10 } } },
                    .{ .address = 0x08000004, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 1, .imm = 2 } } },
                    .{ .address = 0x08000008, .condition = .al, .size_bytes = 4, .instruction = .{ .swi = .{ .imm24 = 0x000006 } } },
                },
            },
        },
        .output_mode = .register_r0_decimal,
        .instruction_limit = null,
    };
    try emitModule(&output.writer, program);

    try std.testing.expectStringStartsWith(output.writer.buffered(), "; generated by hmncli phase1 slice\n");
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%GuestState = type") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "define void @guest_arm_08000000(ptr %state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call void @guest_arm_08000000(ptr %state)") != null);
}

test "llvm emission lowers gba soft reset swi to the soft reset shim call" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .swi = .{ .imm24 = 0x000000 } } },
                },
            },
        },
        .output_mode = .register_r0_decimal,
        .instruction_limit = null,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call i32 @shim_gba_SoftReset(ptr %state)") != null);
}

test "llvm emission prepays retired counts for straight-line blocks" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 0, .imm = 0 } } },
                    .{ .address = 0x08000004, .condition = .al, .size_bytes = 4, .instruction = .{ .add_imm = .{ .rd = 0, .rn = 0, .imm = 1 } } },
                    .{ .address = 0x08000008, .condition = .al, .size_bytes = 4, .instruction = .{ .add_imm = .{ .rd = 0, .rn = 0, .imm = 1 } } },
                    .{ .address = 0x0800000C, .condition = .al, .size_bytes = 4, .instruction = .{ .branch = .{ .cond = .al, .target = 0x0800000C } } },
                },
            },
        },
        .output_mode = .retired_count,
        .instruction_limit = 8,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "retired_block_remaining_ptr_08000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "store i64 3, ptr %retired_block_remaining_ptr_08000000") != null);
}

test "minimal vblank interrupt MMIO helpers" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 0, .imm = 0x04000200 } } },
                    .{ .address = 0x08000004, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 1, .imm = 1 } } },
                    .{ .address = 0x08000008, .condition = .al, .size_bytes = 4, .instruction = .{ .store = .{
                        .src = 1,
                        .base = 0,
                        .addressing = .{ .offset = .{ .offset = .{ .imm = 0 }, .subtract = false } },
                        .size = .halfword,
                    } } },
                },
            },
        },
        .output_mode = .retired_count,
        .instruction_limit = 500_000,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@.fmt_irq_bad_ie") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@.fmt_irq_nested_ime") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@.fmt_irq_multi_if") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@hmn_store_gba_io16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@hmn_gba_advance_frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@hmn_dispatch_vblank_irq") != null);
}

test "minimal vblank interrupt MMIO helpers preserve handler IF acknowledgement" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .swi = .{ .imm24 = 0x000005 } } },
                },
            },
        },
        .output_mode = .retired_count,
        .instruction_limit = 500_000,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call i64 @hmn_gba_advance_frame(ptr %state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call void @hmn_dispatch_vblank_irq(ptr %state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call void @hmn_interrupt_fail_multi_if(ptr %state, i16 %irq_if)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call void @hmn_call_guest(ptr %state, i32 %irq_vector)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "store i16 1, ptr %irq_if_ptr") == null);
}

test "dispstat load32 compatibility preserves the upper halfword" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 0, .imm = 0 } } },
                },
            },
        },
        .output_mode = .retired_count,
        .instruction_limit = 4,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%dispstat_raw = load i32, ptr %dispstat_ptr, align 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%dispstat_masked = and i32 %dispstat_raw, -2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%dispstat_vblank = select i1 %dispstat_toggle, i32 1, i32 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%dispstat_value = or i32 %dispstat_masked, %dispstat_vblank") != null);
}

test "arm_report output emits PASS and FAIL formatters from r12" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const program = Program{
        .entry = .{ .address = 0x08000000, .isa = .arm },
        .rom_base_address = 0x08000000,
        .rom_bytes = &.{},
        .save_hardware = .none,
        .functions = &.{
            .{
                .entry = .{ .address = 0x08000000, .isa = .arm },
                .instructions = &.{
                    .{ .address = 0x08000000, .condition = .al, .size_bytes = 4, .instruction = .{ .mov_imm = .{ .rd = 12, .imm = 0 } } },
                },
            },
        },
        .output_mode = .arm_report,
        .instruction_limit = null,
    };
    try emitModule(&output.writer, program);

    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@.fmt_arm_pass") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "@.fmt_arm_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "%arm_report_code = load i32, ptr %r12_ptr_done, align 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call i32 (ptr, ...) @printf(ptr @.fmt_arm_pass)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "call i32 (ptr, ...) @printf(ptr @.fmt_arm_fail, i32 %arm_report_code)") != null);
}
