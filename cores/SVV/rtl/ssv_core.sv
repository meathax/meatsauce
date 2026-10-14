// SPDX-License-Identifier: GPL-3.0-or-later
// Dyna Gear SSV board core: V60, memory map, inputs, IRQs and scanline video.
// ES5506 host/register file + voice PCM engine (bank-2 linear PCM for Dyna Gear).

`timescale 1ns/1ps

module ssv_core #(
    // MAME's unconfigured WATCHDOG_TIMER defaults to exactly three seconds.
    // clk_sys is the PLL's 48.317307 MHz SSV master domain. Focused benches
    // override this cycle count rather than synthesizing a frame-based proxy.
    parameter int unsigned WDOG_TIMEOUT_CYCLES = 3 * 48_317_307,
    // Diagnostic build switch: 1 replaces the game picture with the
    // fullscreen ES5506 audio-debug text screen (ssv_audio_debug_overlay).
    // The core, video pipeline and audio path keep running untouched
    // underneath -- only the final rgb output is swapped.
    // Default stays 0 so every existing bench and frame-CRC regression sees
    // the untouched game picture; +define+SSV_DBG_AUDIO_OVERLAY flips the
    // default for sim builds without touching any testbench.
`ifdef SSV_DBG_AUDIO_OVERLAY
    parameter bit DBG_AUDIO_OVERLAY = 1'b1
`else
    parameter bit DBG_AUDIO_OVERLAY = 1'b0
`endif
) (
    input              clk_sys,
    // rst includes watchdog soft reset. cold_rst excludes watchdog and is
    // used where MAME/device hardware retains state across /RESET.
    input              rst,
    input              cold_rst,
    input              ce_cpu,
    // MiSTer persistence pauses stop the V60, preventing the game from
    // servicing its physical watchdog. Freeze only for explicit host pauses;
    // normal CPU and bus stalls must still trip the board watchdog.
    input              watchdog_hold,

    // Per-game configuration. The Dyna Gear record (ssv_pkg::cfg_dynagear)
    // reproduces the behaviour that used to be hardwired here.
    input  ssv_pkg::ssv_cfg_t cfg,

    output logic       sdr_p0_req,
    output logic [ssv_pkg::SDR_AW:1] sdr_p0_addr,
    input       [15:0] sdr_p0_dout,
    input              sdr_p0_ack,

    // Graphics row fetch. Moved from the controller's 64-bit p1 to its 128-bit
    // p2 (rd_total=8) when the loader was changed to pack a whole 16-pixel tile
    // row into one aligned 16-byte record -- see
    // docs/SDRAM_GFX_REPACK_DESIGN.md. p1 is now free.
    output logic       sdr_p2_req,
    output logic [ssv_pkg::SDR_AW:4] sdr_p2_addr,
    input      [127:0] sdr_p2_dout,
    input              sdr_p2_ack,

    output logic       sdr_wr_req,
    output logic [ssv_pkg::SDR_AW:1] sdr_wr_addr,
    output logic [15:0] sdr_wr_din,
    output logic [1:0] sdr_wr_be,
    input              sdr_wr_ack,

    // ST010 (uPD96050) program fetch. p5 is the controller's second 64-bit
    // 4-word burst port and is LAST in the round-robin chain, so a DSP fetch
    // can never delay the graphics fetcher or the sample engine. Held idle --
    // req constant 0 -- unless cfg.has_st010, which is why the six non-DSP
    // titles see the same SDRAM traffic they always did.
    output             sdr_p5_req,
    output      [ssv_pkg::SDR_AW:3] sdr_p5_addr,
    input       [63:0] sdr_p5_dout,
    input              sdr_p5_ack,

    // ST010 "dspdata" load port, driven by ssv_rom_loader.
    input              st010_drom_we,
    input       [10:0] st010_drom_wa,
    input       [15:0] st010_drom_wd,

    // ES5506 sample fetches (16-bit SDRAM words)
    output logic       sdr_p4_req,
    output logic [ssv_pkg::SDR_AW:1] sdr_p4_addr,
    input       [15:0] sdr_p4_dout,
    input              sdr_p4_ack,

    input       [15:0] in_dsw1,
    input       [15:0] in_dsw2,
    input       [15:0] in_p1,
    input       [15:0] in_p2,
    input       [15:0] in_system,
    input       [15:0] in_extra,
    // UNUSED. The mahjong/Eagle Shot/Sexy Reaction/GDFS optional-I/O family was
    // pruned from the universal profile (f0622c5): none of the qualified sets in
    // tools/ssv_supported_sets.py selects it, so nothing inside ssv_core reads
    // this port and it synthesizes away. Retained only because eight benches
    // under verif/ bind it by name (tb_ssv_core_memory_windows, tb_ssv_frame_crc,
    // tb_ssv_hang_watch, tb_ssv_loader_core_boot, tb_ssv_realrom_boot,
    // tb_ssv_realrom_video, tb_ssv_rom_write_ack, tb_ssv_watchdog); delete the
    // port and those bindings in one change, not this one.
    input       [23:0] in_mahjong_rows,
    input       [11:0] in_coord_x,
    input       [11:0] in_coord_y,
    input        [7:0] in_paddle,
    input              in_ball_switch,

    // High score save/load. MAME maps SSV main RAM at $000000-$00ffff
    // (ssv.cpp: map(0x000000, 0x00ffff).ram().share(m_mainram)), which is this
    // core's work_ram, and its second port was tied off. Handing that port out
    // gives the hiscore module collision-free access with no arbitration
    // against the V60 -- the reason the wrapper still pauses the CPU around an
    // access is the game's own consistency, not a RAM hazard.
    input       [14:0] hs_addr,
    input       [15:0] hs_din,
    input        [1:0] hs_be,
    input              hs_we,
    output      [15:0] hs_dout,

    output logic [23:0] rgb,
    output logic       ce_pixel,
    // Exactly 2x ce_pixel, from the same accumulator. Used by the line
    // doubler; see ssv_video_timing.
    output logic       ce_pix_x2,
    output logic       hs,
    output logic       vs,
    output logic       hb,
    output logic       vb,
    // Native raster-frame strobe for wrapper-side deterministic input logic.
    output logic       frame_tick,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic       audio_tick,
    // Sticky one-shot after exactly WDOG_TIMEOUT_CYCLES without the correct
    // $210000 strobe. Wrapper ORs it into core reset.
    output logic       wdog_rst,
    output logic [1:0] coin_lockout,
    output logic       renderer_overrun
    ,output logic       motor_output
`ifdef SIMULATION
    , output logic [31:0] debug_pc
    , output logic [23:0] debug_status
    , output logic        debug_v60_retire
    , output logic [31:0] debug_v60_retire_pc
    , output logic  [7:0] debug_v60_opcode
    , output logic [31:0] debug_v60_psw
    , output logic [1023:0] debug_v60_gprs
    , output logic        debug_mainbus_complete
    , output logic        debug_mainbus_write
    , output logic [23:0] debug_mainbus_addr
    , output logic [15:0] debug_mainbus_data
    , output logic  [1:0] debug_mainbus_be
    , output logic  [7:0] debug_mainbus_device
    , output logic        debug_ifetch_complete
    , output logic [23:0] debug_ifetch_addr
    , output logic [63:0] debug_ifetch_data
    , output logic [31:0] debug_reset_epoch
    , output logic [31:0] debug_frame
    , output logic  [8:0] debug_scanline
    , output logic  [8:0] debug_hpos
    , output logic        debug_irq_ack
    , output logic  [7:0] debug_irq_vector
    , output logic  [7:0] debug_irq_requested
    , output logic  [7:0] debug_irq_enabled
    , output logic        debug_watchdog_kick
    , output logic        debug_watchdog_reset
    , output logic        debug_st010_retire
    , output logic [23:0] debug_st010_ir
    , output logic [13:0] debug_st010_pc
    , output logic  [5:0] debug_st010_flaga
    , output logic  [5:0] debug_st010_flagb
    , output logic        debug_st010_host_access
    , output logic        debug_st010_fetch_req
    , output logic        debug_st010_fetch_done
    , output logic [13:0] debug_st010_prg_addr
    , output logic [23:0] debug_st010_prg_data
    , output logic        debug_st010_ram_write
    , output logic [10:0] debug_st010_ram_addr
    , output logic [15:0] debug_st010_ram_wdata
    , output logic [10:0] debug_st010_host_ram_addr
    , output logic        debug_st010_host_ram_high
    , output logic [15:0] debug_st010_host_ram_q
    , output logic  [7:0] debug_st010_host_ram_dout
    , output logic  [2:0] debug_st010_state
    , output logic        debug_sound_commit
    , output logic  [6:0] debug_sound_page
    , output logic  [3:0] debug_sound_reg
    , output logic [31:0] debug_sound_data
    , output logic        debug_sound_engine_cr_write
    , output logic  [4:0] debug_sound_engine_voice
    , output logic [15:0] debug_sound_engine_cr
    , output logic [15:0] debug_sound_engine_cr_set
    , output logic [15:0] debug_sound_engine_cr_clr
    , output logic [16:0] debug_sound_engine_fc
    , output logic [31:0] debug_sound_engine_start
    , output logic [31:0] debug_sound_engine_end
    , output logic [31:0] debug_sound_engine_accum
    , output logic        debug_sound_engine_snapshot
    , output logic        debug_sound_engine_accum_write
    , output logic [31:0] debug_sound_engine_accum_w
    , output logic        debug_sound_irq_promote
    , output logic        debug_sound_voice_writeback
    , output logic  [4:0] debug_sound_voice
    , output logic        debug_sample_req
    , output logic        debug_sample_done
    , output logic        debug_sample_tick
    , output logic        debug_sample_underrun
    , output logic        debug_video_enable
    , output logic        debug_line_boundary
    , output logic        debug_frame_boundary
`endif
);

import ssv_pkg::*;

// Report a bad SDRAM layout at time 0 rather than as unexplained corruption.
// ssv_pkg computes the rule; a package cannot host an initial block, so the
// reporting lives here. Guarded on SIMULATION -- the project's own define, set
// by every verif script -- rather than on a vendor SYNTHESIS macro, so the
// block provably never reaches Quartus.
`ifdef SIMULATION
initial if (SDR_LAYOUT_FAULT != 0)
    $fatal(1, "ssv_pkg SDRAM layout is invalid (rule %0d)", SDR_LAYOUT_FAULT);
initial if (WDOG_TIMEOUT_CYCLES < 1)
    $fatal(1, "WDOG_TIMEOUT_CYCLES must be positive");
`endif

logic        c_req, c_we, c_ack;
logic [31:0] c_addr, c_wdata, c_rdata;
logic  [1:0] c_size;
logic        m_req, m_we, m_ack;
logic        ack_r, ack_r_d;
logic [23:1] m_addr;
logic [15:0] m_wdata, m_rdata;
logic  [1:0] m_be;
logic        cpu_irq_ack;
logic        irq_n;
logic  [7:0] irq_vector;
wire [31:0] cpu_trace_pc;

// Dedicated wide instruction-fetch port (FAST_IFETCH): prefetch reads whole
// 8-byte ROM icache lines at clk_sys latency, bypassing the ce-gated 16-bit
// data adapter that otherwise bottlenecks fetch bandwidth.
wire        if_req;
wire [23:0] if_addr;
logic [63:0] if_data;
logic        if_served;
wire         if_ack = if_served;

// FAST_IFETCH defaults on; override at build time (+define+FAST_IFETCH_EN=1'b0)
// to A/B-test the wide fetch path against the legacy ce-gated adapter fetch.
`ifndef FAST_IFETCH_EN
 `define FAST_IFETCH_EN 1'b1
`endif

`ifdef SIMULATION
logic cpu_halted;
logic [31:0] cpu_retire_pc;
logic [7:0] cpu_retire_opcode;
logic [31:0] cpu_retire_psw;
logic [1023:0] cpu_gpr_flat;
`endif
s32_v60 #(.START_PC(32'hFFFF_FFF0), .FAST_IFETCH(`FAST_IFETCH_EN)) cpu (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .fast_ifetch(1'b1),
    .rom_base(-(24'(cfg.prog_mb) << 20)),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr),
    .bus_size(c_size), .bus_wdata(c_wdata),
    .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(cpu_irq_ack),
    .nmi_n(1'b1), .trace_pc(cpu_trace_pc)
`ifdef SIMULATION
    , .dbg_pc(debug_pc), .dbg_halted(cpu_halted),
    .dbg_retire(debug_v60_retire), .dbg_retire_pc(cpu_retire_pc),
    .dbg_retire_opcode(cpu_retire_opcode), .dbg_retire_psw(cpu_retire_psw),
    .dbg_gpr_flat(cpu_gpr_flat)
`endif
);

s32_v60_bus bus_adapter (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
    .m_wdata(m_wdata), .m_be(m_be),
    .m_rdata(m_rdata), .m_ack(m_ack)
);

wire [23:0] a = {m_addr, 1'b0};
wire sel_wram    = (a <= 24'h00ffff);
wire sel_sprram  = (a >= 24'h100000) && (a <= 24'h13ffff);
// The descriptor cache build only walks the global sprite list, which lives in
// the first 0x1000 words (0x2000 bytes) of sprite RAM -- see LAST_GLOBAL in
// ssv_cached_sprite_renderer.sv. Everything above that is tile/local sprite
// payload the games stream continuously during active display (measured in
// MAME 0.289 on vasara: offsets 0x08000-0x1806e written on every raster line
// 0..239 and 250..261). Restarting the build on those writes would rewind it
// forever, so the restart trigger is scoped to the range the walk depends on.
wire sel_sprlist = sel_sprram && (a <= 24'h101fff);
wire sel_palette = (a >= 24'h140000) && (a <= 24'h15ffff);
wire sel_xram    = (a >= 24'h160000) && (a <= 24'h17ffff);
wire sel_scroll  = (a >= 24'h1c0000) && (a <= 24'h1c007f);
wire sel_io      = (a >= 24'h210000) && (a <= 24'h210011);
wire sel_irqvec  = (a >= 24'h230000) && (a <= 24'h230071);
wire sel_irqack  = (a >= 24'h240000) && (a <= 24'h240071);
wire sel_irqen   = (a >= 24'h260000) && (a <= 24'h260001);
wire sel_sound   = (a >= 24'h300000) && (a <= 24'h30007f);
wire sel_drifto_unknown = cfg.has_drifto_unknown &&
                          ((a == 24'h510000) || (a == 24'h520000));
wire sel_cpuram  = (cfg.extra_ram_mode == 2'd1) &&
                   (a >= 24'h400000) && (a <= 24'h43ffff);
wire sel_extra_wram = (cfg.extra_ram_mode == 2'd2) &&
                      (a >= 24'h010000) && (a <= 24'h03ffff);
wire [16:0] nvram_last_offset = (cfg.nvram_mode == 2'd1) ?
                                 17'h007ff : 17'h0ffff;
wire sel_nvram   = cfg.has_nvram && (cfg.nvram_mode != 2'd0) &&
                   (a >= 24'h580000) &&
                   (a <= (24'h580000 + {7'd0, nvram_last_offset}));
// $500008-$500009. The SAM-5127 cartridge carries 3P and 4P connectors with a
// dedicated I/O-FILTER stage at U30/U31, and this is the only decoded input
// window unaccounted for -- so this is the prime candidate for where the third
// and fourth player ports read back. Unproven: Dyna Gear is a 2-player game.
// `in_extra` is tied high by the wrapper, which is correct for any game that
// does not read it. See docs/hardware/SSV_PCB_FINDINGS_ACTION_PLAN.md item 1.
wire sel_extra   = extra_input_window_cfg(cfg, a);
// The release profile contains exactly the nine sets in
// tools/ssv_supported_sets.py. None selects the legacy mahjong, Eagle Shot,
// Sexy Reaction or GDFS optional-I/O families. Keep those device models and
// standalone benches as source references, but do not instantiate unreachable
// hardware in the one universal RBF. This removes the largest optional block
// (the register-built GDFS EEPROM) without touching any supported descriptor.
// MAME maps the program ROM as `ssv_map(map, rom)` with rom..0xffffff, and in
// every SSV set rom == 0x1000000 - program_size: $f00000 for a 1 MB program
// (dynagear), $e00000 for 2 MB (cairblad, twineag2, ultrax),
// $c00000 for 4 MB (drifto94, stmblade, vasara, vasara2). So the base is a
// function of prog_mb and does not need its own config field.
// 0x1000000 does not fit the 24-bit CPU address, and it does not need to:
// in 24-bit arithmetic 0x1000000 - size is exactly -size, which yields
// 0xF00000 / 0xE00000 / 0xC00000 for 1 / 2 / 4 MB -- MAME's values.
wire [23:0] rom_window_base = -(24'(cfg.prog_mb) << 20);
wire sel_rom     = (a >= rom_window_base);
wire sel_extmem  = sel_xram | sel_cpuram | sel_extra_wram | sel_nvram;

// ---------------------------------------------------------------------------
// ST010 daughterboard, $480000 and $482000-$482fff.
//
// drifto94_map (ssv.cpp:410-411) and twineag2_map (:769-770):
//     map(0x480000, 0x480000).rw(m_dsp, upd96050_device::data_r, data_w);
//     map(0x482000, 0x482fff).rw(dsp_r, dsp_w).umask16(0x00ff);
// The window translation (offset = A[11:1], word = A[11:2], high byte = A[1])
// lives in upd96050_st010.sv, which is where it is derived; this is only the
// window decode and the wait-state handling.
//
// Everything below is gated on cfg.has_st010, so for the six titles without the
// daughterboard sel_st010 is constant 0, the read mux is untouched, the DSP is
// held in reset and sdr_p5_req never leaves 0.
//
// No conflict with sel_irqack ($240000-$240071): that is a CPU address, whereas
// upd96050_st010 compares cpu_addr[23:1] == 23'h240000, which IS $480000.
// ---------------------------------------------------------------------------
wire sel_st010_port = cfg.has_st010 && (a == 24'h480000);
wire sel_st010_win  = cfg.has_st010 && (a[23:12] == 12'h482);
wire sel_st010      = sel_st010_port | sel_st010_win;

// Registers, not memory, and it cannot be otherwise: every one of these 64
// words is read combinationally in parallel (sprite_offsets, tilemap_scrolls
// and the individual control words below), and the array takes a reset. The
// old ramstyle="MLAB" attribute here was silently ignored -- the fit report
// lists scroll[63][1], scroll[62][0] and friends as discrete flops -- so it
// described an implementation that never existed. About 1k flops is the
// honest, irreducible cost of a 64-word file with 64 concurrent readers.
logic [15:0] scroll [0:63];

wire [14:0] wram_addr = a[15:1];
wire [16:0] spr_addr  = a[17:1];
wire [15:0] pal_addr  = a[16:1];
wire  [5:0] scr_addr  = a[6:1];

wire [15:0] wram_q, pal_q;
wire [15:0] spr_q;
logic [15:0] scroll_q;
wire [16:0] renderer_spr_addr;
wire [16:0] bg_spr_addr, obj_spr_addr;
wire [255:0] sprite_offsets;
wire [511:0] tilemap_scrolls;
wire [15:0] spr_video_q;
wire [15:0] spr_video_next_q;
wire [14:0] line_color;
wire [23:0] palette_video_rgb;
wire [23:0] palette_background_rgb;
integer scroll_init_i;

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) work_ram (
    .clock_a(clk_sys), .address_a(wram_addr), .data_a(m_wdata),
    .byteena_a(m_be), .wren_a(m_req && m_we && sel_wram), .q_a(wram_q),
    .clock_b(clk_sys), .address_b(hs_addr), .data_b(hs_din),
    .byteena_b(hs_be), .wren_b(hs_we), .q_b(hs_dout)
);

// Sprite RAM is split by word parity, exactly as ssv_palette_ram is. Both
// banks are addressed by the same index (word address >> 1), so one address
// hands the renderer the word at `addr` *and* the word at `addr | 1` in the
// same cycle.
//
// That matters because ssv_cached_sprite_renderer's tile_address() is always
// even: base = page << (size_shift+2) with size_shift >= 8, column =
// (x & mask & 0x1fff0) << 2, and row = (y & 0x1f0) >> 3 are each even. A tile's
// 16-bit code and its 16-bit attribute are therefore an even/odd pair at one
// bank index, and the renderer no longer needs a second address cycle to walk
// from one to the other -- two cycles saved out of ten per drawn tile, which is
// what decides whether a heavily-loaded scanline makes its deadline.
//
// Readers at arbitrary addresses (the descriptor-cache build walking the global
// and local lists, the row-scroll table lookup) still work: for an odd address
// the wanted word is the odd bank at the same index, selected by the registered
// parity bit below. Only `spr_video_next_q` requires an even address.
//
// Block RAM is unchanged: 2 x 65536 x 16 is the same 2,097,152 bits as
// 1 x 131072 x 16, and a 16-bit-wide true-dual-port M10K holds 512 words either
// way (256 blocks before, 128 + 128 after). This is reasoned, not fitted --
// no Quartus run was made.
logic spr_cpu_bank_d;
logic spr_video_bank_d;
wire [15:0] spr_even_cpu_q, spr_odd_cpu_q;
wire [15:0] spr_even_video_q, spr_odd_video_q;

always_ff @(posedge clk_sys) begin
    spr_cpu_bank_d   <= spr_addr[0];
    spr_video_bank_d <= renderer_spr_addr[0];
end

s32_big_dpram #(.ADDR_WIDTH(16), .NUM_WORDS(65536)) sprite_ram_even (
    .clock_a(clk_sys), .address_a(spr_addr[16:1]), .data_a(m_wdata),
    .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_sprram && !spr_addr[0]), .q_a(spr_even_cpu_q),
    .clock_b(clk_sys), .address_b(renderer_spr_addr[16:1]), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(spr_even_video_q)
);

s32_big_dpram #(.ADDR_WIDTH(16), .NUM_WORDS(65536)) sprite_ram_odd (
    .clock_a(clk_sys), .address_a(spr_addr[16:1]), .data_a(m_wdata),
    .byteena_a(m_be),
    .wren_a(m_req && m_we && sel_sprram && spr_addr[0]), .q_a(spr_odd_cpu_q),
    .clock_b(clk_sys), .address_b(renderer_spr_addr[16:1]), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(spr_odd_video_q)
);

// One-cycle read latency, so the parity that selects the bank is the one that
// was presented with the address, not the current one.
assign spr_q          = spr_cpu_bank_d   ? spr_odd_cpu_q   : spr_even_cpu_q;
assign spr_video_q    = spr_video_bank_d ? spr_odd_video_q : spr_even_video_q;
// The word after `renderer_spr_addr`; meaningful only for an even address,
// which is the only case any consumer uses it in.
assign spr_video_next_q = spr_odd_video_q;

ssv_palette_ram palette_ram (
    .clk(clk_sys), .cpu_addr(pal_addr), .cpu_data(m_wdata),
    .cpu_be(m_be), .cpu_we(m_req && m_we && sel_palette), .cpu_q(pal_q),
    .video_index(line_color), .video_rgb(palette_video_rgb),
    .background_rgb(palette_background_rgb)
);

always_ff @(posedge clk_sys) begin
    // Scroll/CRTC registers are shared board RAM in MAME and machine_reset()
    // does not clear them. Only a cold/download reset initializes the array.
    if (cold_rst) begin
        scroll_q <= 16'd0;
        for (scroll_init_i = 0; scroll_init_i < 64;
             scroll_init_i = scroll_init_i + 1)
            scroll[scroll_init_i] <= 16'd0;
    end
    else begin
        scroll_q <= scroll[scr_addr];
    if (m_req && m_we && sel_scroll) begin
        if (m_be[0]) scroll[scr_addr][7:0]  <= m_wdata[7:0];
        if (m_be[1]) scroll[scr_addr][15:8] <= m_wdata[15:8];
    end
    end
end

genvar sprite_offset_i;
generate
    for (sprite_offset_i = 0; sprite_offset_i < 16; sprite_offset_i = sprite_offset_i + 1) begin : g_sprite_offsets
        assign sprite_offsets[sprite_offset_i * 16 +: 16] = scroll[32 + sprite_offset_i];
    end
endgenerate

genvar tilemap_scroll_i;
generate
    for (tilemap_scroll_i = 0; tilemap_scroll_i < 32;
         tilemap_scroll_i = tilemap_scroll_i + 1) begin : g_tilemap_scrolls
        assign tilemap_scrolls[tilemap_scroll_i * 16 +: 16] =
            scroll[tilemap_scroll_i];
    end
endgenerate

logic [8:0] hcnt, vcnt;
logic vblank_pulse;
logic irq3_pulse;
logic video_enable;
wire [8:0] active_width = active_width_cfg(cfg);
wire [8:0] active_height = active_height_cfg(cfg);
ssv_video_timing timing (
    // A watchdog machine reset must not restart the raster halfway through a
    // frame. Renderers may blank while restarting, but sync remains continuous.
    .clk(clk_sys), .rst(cold_rst), .ce_pixel(ce_pixel), .ce_pix_x2(ce_pix_x2),
    .active_width(active_width), .active_height(active_height),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hb), .vblank(vb),
    .hsync(hs), .vsync(vs), .vblank_pulse(vblank_pulse),
    .irq3_pulse(irq3_pulse)
);

logic [8:0] renderer_target_y;
always_comb begin
    if (vcnt >= SSV_VTOTAL - 2)
        renderer_target_y = vcnt - (SSV_VTOTAL - 2);
    else
        renderer_target_y = vcnt + 2'd2;
end

// The descriptor cache is built during vblank and owns the whole of it, but
// the build has no natural bound worth relying on. The first visible line is
// swapped at horizontal blank in raster line 260 (target_y 0), so allow the
// cache to use that line's active portion and cut it off at the swap point.
// This recovers one active-line budget for dense scenes without permitting a
// still-busy cache to suppress a line swap; the next vblank then re-arms the
// build normally.
wire cache_deadline = (vcnt > SSV_VTOTAL - 2) ||
                      ((vcnt == SSV_VTOTAL - 2) &&
                       (hcnt >= active_width - 1'd1));

// Declared here rather than with the rest of the renderer nets below, because
// line_buffer_start reads obj_cache_busy and renderer_line_start reads
// renderer_busy. An implicit net would be inferred under the older rules, but
// slang rejects the use-before-declaration outright.
wire obj_cache_busy, obj_cache_ready, obj_cache_overflow;
wire renderer_busy;

// Advance scanout to the next completed ring line as active display enters
// horizontal blank. renderer_target_y here is purely the raster-derived
// consumption schedule; the renderers themselves are driven by the queue
// counter below. The target_y==0 pulse (end of raster line VTOTAL-2) exposes
// nothing -- the first line consumed is line 0, at the target_y==1 pulse --
// so it is excluded from consumption.
wire line_buffer_start = video_enable && ce_pixel &&
                         (hcnt == active_width - 1'd1) &&
                         (renderer_target_y <= active_height) &&
                         !obj_cache_busy;
wire line_buffer_consume = line_buffer_start &&
                           (renderer_target_y != 9'd0);

// Ring-buffer producer handshake (driven by the line buffer below).
wire line_render_ready, line_render_go, line_underrun;

// Queue-based renderer kicking into the four-line ring. next_render_y counts
// this frame's lines in order; a render is kicked whenever the renderer is
// idle, the ring has a clean slot, and visible lines remain -- so the
// renderer runs up to three lines ahead of the beam and a sprite-dense line
// can borrow the headroom instead of missing its deadline. The kick is
// registered so render_line_y is stable when the start pulse reaches the
// renderers (the object renderer samples target_y at bg_done, well after the
// pulse). Kicking only while idle keeps the p2 ownership rules and the
// renderer-overlap assertion below intact: bg and obj never overlap a new
// start.
//
// KNOWN APPROXIMATION: the background renderer samples its scroll registers
// (and row-scroll RAM) live, so a line rendered up to three lines ahead
// samples them up to three lines early. The cached sprite renderer already
// freezes per-frame state during vblank, and bg scroll is static per frame
// on these games, so the head start is accepted rather than pipelining the
// scroll values.
//
// The kick window opens four lines before the visible frame (matching the
// old scheme's vblank-tail preparation, a little earlier so the ring can
// fill) and stays shut through early vblank, where the descriptor cache
// build and its CPU-write restart window own the sprite RAM port.
logic [8:0] next_render_y;
logic [8:0] render_line_y;
logic       render_kick_q;
wire render_window = (vcnt >= SSV_VTOTAL - 9'd4) || (vcnt < active_height);
wire render_kick_ok = video_enable && render_window && !obj_cache_busy &&
                      line_render_ready && !renderer_busy && !render_kick_q &&
                      (next_render_y < active_height);
always_ff @(posedge clk_sys) begin
    if (rst) begin
        next_render_y <= 9'd0;
        render_line_y <= 9'd0;
        render_kick_q <= 1'b0;
    end
    else if (vblank_pulse) begin
        // Same edge as the line buffer's frame_sync: both ring pointers and
        // the line counter restart from one deterministic aligned state.
        //
        // Unconditional on video_enable, unlike cache_start below. The CPU's
        // lockout bit ($21000e bit 7) can drop mid-active-line and come back
        // mid-vblank of a later frame -- twineag2's attract transition does
        // exactly this -- which would otherwise miss the one
        // video_enable&&vblank_pulse edge that realigns the ring. Missing it
        // once left next_render_y resuming from its stale pre-blank value
        // instead of 0: it then crossed active_height mid-frame instead of at
        // the frame boundary, render_kick_ok's bound latched shut for the
        // rest of that frame, and scanout drained the ring's remaining stale
        // lines dry -- SSV_RENDERER_OWNERSHIP cause=line_deadline. Kicking
        // itself, and the descriptor-cache rebuild, still require
        // video_enable live (no point spending SDRAM/sprite-RAM bandwidth on
        // a blanked screen); only the realignment must not be skippable.
        next_render_y <= 9'd0;
        render_kick_q <= 1'b0;
    end
    else begin
        render_kick_q <= 1'b0;
        if (render_kick_ok) begin
            render_kick_q <= 1'b1;
            render_line_y <= next_render_y;
            next_render_y <= next_render_y + 1'd1;
        end
    end
end
wire renderer_line_start = render_kick_q;

// Look ahead one address to cover the line-buffer/palette read pipeline.  The
// output observed at coordinate x is the value requested on the preceding
// pixel clock; x=0 is preloaded throughout horizontal blank.
wire [8:0] scan_x_ahead = (hcnt < active_width - 1'd1)
                          ? hcnt + 1'd1 : 9'd0;
wire [3:0] renderer_plot_we;
wire renderer_plot_shadow, renderer_shadow_4bit;
wire [35:0] renderer_plot_x;
wire [59:0] renderer_plot_color;
wire [31:0] renderer_plot_pen;
wire renderer_done;
wire [3:0] bg_plot_we;
wire bg_plot_shadow, bg_shadow_4bit;
wire [35:0] bg_plot_x;
wire [59:0] bg_plot_color;
wire [31:0] bg_plot_pen;
wire [3:0] obj_plot_we;
wire obj_plot_shadow, obj_shadow_4bit;
wire [35:0] obj_plot_x;
wire [59:0] obj_plot_color;
wire [31:0] obj_plot_pen;
wire bg_rom_req, obj_rom_req;
wire [SDR_AW:4] bg_rom_addr, obj_rom_addr;
wire bg_busy, bg_done, obj_busy, obj_done;
assign renderer_spr_addr = (obj_cache_busy || obj_busy) ? obj_spr_addr : bg_spr_addr;
// p2 is one shared SDRAM port with two clients. obj_busy picks who drives
// req/addr -- but the ack has to be steered as well. Both fetchers are level
// sensitive on rom_ack, so handing the raw ack to the renderer that does NOT
// own the port makes it latch the other renderer's tile data as its own.
//
// That is reachable: renderer_line_start is not gated on renderer_busy (a
// still-busy renderer can overlap a later line start, so a line that misses
// its deadline starts the background renderer while the object renderer is
// still fetching. Both then sit in WAIT_ACK on the same ack. Simulation never
// hits it because the behavioural SDRAM is fast enough that lines never
// overrun; on hardware it paints large parts of the background with sprite
// tile data until the scene thins out.
//
// Selecting from live obj_busy is not sufficient to prevent that. obj_busy is
// free to change between the clock that issues a request and the clock its
// acknowledgement returns, and when it does, the address presented to the
// controller moves mid-transaction and the returning data is handed to the
// client that did not ask for it. Ownership is therefore latched for the
// duration of each outstanding transaction, in the same shape as the V60
// prefetch transport guard: decide once at issue, hold until acknowledged.
logic p2_busy_r;
logic p2_owner_obj_r;
always_ff @(posedge clk_sys) begin
    if (rst) begin
        p2_busy_r      <= 1'b0;
        p2_owner_obj_r <= 1'b0;
    end
    else if (!p2_busy_r) begin
        // sdr_p2_req is driven from live obj_busy while no transaction is
        // outstanding, so the owner captured here is the one that issued.
        if (sdr_p2_req && !sdr_p2_ack) begin
            p2_busy_r      <= 1'b1;
            p2_owner_obj_r <= obj_busy;
        end
    end
    // Release on acknowledge, and also if the owning client withdraws its
    // request. Both fetchers hold req until ack, so the withdrawal case should
    // not arise; releasing on it anyway keeps a protocol violation from
    // latching the port to a client that is no longer asking and starving the
    // other one for the rest of the frame.
    else if (sdr_p2_ack ||
             !(p2_owner_obj_r ? obj_rom_req : bg_rom_req)) begin
        p2_busy_r <= 1'b0;
    end
end

wire p2_owner_obj = p2_busy_r ? p2_owner_obj_r : obj_busy;
wire bg_rom_ack   = sdr_p2_ack && !p2_owner_obj;
wire obj_rom_ack  = sdr_p2_ack &&  p2_owner_obj;

assign sdr_p2_req = p2_owner_obj ? obj_rom_req : bg_rom_req;
assign sdr_p2_addr = p2_owner_obj ? obj_rom_addr : bg_rom_addr;

// verif/ssv_tilemap_page_check.sv binds into this module and still names the
// graphics port p1. These aliases keep that (shared, not-mine-to-edit) checker
// compiling while the port itself moves to the controller's 128-bit p2.
// Simulation-only: they must never reach Quartus as dangling nets.
assign renderer_plot_we = obj_busy ? obj_plot_we : bg_plot_we;
assign renderer_plot_x = obj_busy ? obj_plot_x : bg_plot_x;
assign renderer_plot_color = obj_busy ? obj_plot_color : bg_plot_color;
assign renderer_plot_shadow = obj_busy ? obj_plot_shadow : bg_plot_shadow;
assign renderer_plot_pen = obj_busy ? obj_plot_pen : bg_plot_pen;
assign renderer_shadow_4bit = obj_busy ? obj_shadow_4bit : bg_shadow_4bit;
assign renderer_busy = bg_busy | obj_busy;
assign renderer_done = obj_done;

// Sprite-list writes are clustered in the first nine visible-height lines of
// vblank. Restarting the cache on every accepted write made the build chase
// the CPU's list walk: a late write could abort BUILD_REINDEX and the repeated
// rebuilds then reached cache_deadline with no publishable index. Issue one
// restart on the first accepted write and suppress the rest of that window;
// this preserves the full remaining vblank budget for the rebuild.
logic cache_write_pending;
wire cache_list_write_accept = m_req && m_we &&
                               (sel_sprlist || sel_scroll) &&
                               ack_r && !ack_r_d;
wire cache_write_window = (vcnt >= active_height) &&
                          (vcnt < active_height + 9'd9);
wire cache_restart_flush = cache_list_write_accept &&
                            cache_write_window && !cache_write_pending;
wire cache_write_window_end = ce_pixel && (hcnt == 9'd0) &&
                              (vcnt == active_height + 9'd9);
always_ff @(posedge clk_sys) begin
    if (rst)
        cache_write_pending <= 1'b0;
    else if (cache_write_window_end)
        cache_write_pending <= 1'b0;
    else if (cache_restart_flush)
        cache_write_pending <= 1'b1;
end

ssv_line_buffer4 line_buffer (
    .clk(clk_sys), .rst(rst),
    // Same edge that resets next_render_y above: once per frame, during
    // vblank, strictly before this frame's first consumption. It resets both
    // ring pointers to one deterministic aligned state.
    //
    // Unconditional on video_enable -- see the comment on next_render_y's
    // reset above for why the ring must realign every frame even while the
    // display is blanked, while cache_start below stays gated.
    .frame_sync(vblank_pulse),
    .line_start(line_buffer_consume),
    .render_start(renderer_line_start),
    .render_done(renderer_done),
    .plot_we(renderer_plot_we), .plot_x(renderer_plot_x),
    .plot_color(renderer_plot_color), .plot_shadow(renderer_plot_shadow),
    .plot_pen(renderer_plot_pen), .shadow_4bit(renderer_shadow_4bit),
    .scan_x(scan_x_ahead), .scan_color(line_color),
    .render_ready(line_render_ready), .render_go(line_render_go),
    .scan_underrun(line_underrun)
);

ssv_bg_renderer background_renderer (
    .clk(clk_sys), .rst(rst), .cfg(cfg), .line_start(renderer_line_start),
    // render_go replaces the old post-swap clear_done pulse: the ring slot
    // handed to this render was cleared before the kick was allowed.
    .target_y(render_line_y), .clear_done(line_render_go),
    .scroll_x(scroll[0]), .scroll_y(scroll[1]), .scroll_mode(scroll[3]),
    .global_y_base(scroll[56]), .global_y_adjust(scroll[53]),
    .flip_control(scroll[58]), .shadow_4bit(scroll[59][7]),
    .spr_addr(bg_spr_addr), .spr_data(spr_video_q),
    .spr_data_next(spr_video_next_q),
    .rom_req(bg_rom_req), .rom_addr(bg_rom_addr),
    .rom_data(sdr_p2_dout), .rom_ack(bg_rom_ack),
    .plot_we(bg_plot_we), .plot_x(bg_plot_x),
    .plot_color(bg_plot_color),
    .plot_shadow(bg_plot_shadow), .plot_pen(bg_plot_pen),
    .plot_shadow_4bit(bg_shadow_4bit),
    .busy(bg_busy), .done(bg_done)
);

ssv_cached_sprite_renderer sprite_renderer (
    .clk(clk_sys), .rst(rst), .cfg(cfg),
    .cache_start(video_enable && vblank_pulse),
    // The build starts at vblank_pulse (end of active line 239) but the
    // game's level-3 handler does not run until irq3_pulse at line 240, so
    // the build is reading the sprite list exactly while the handler rewrites
    // it. The committed cache is then a mix of two frames -- the diagonal
    // seam and HUD shimmer seen on hardware. A completed CPU write to sprite
    // RAM or the video registers during a build abandons it and rebuilds, so
    // the commit reflects post-write state.
    //
    // Window sizing, and why it is +9 rather than the original +5:
    //   one line   = SSV_HTOTAL 454 px x (48.317/7.159) ~= 3064 clk_sys
    //   vblank     = lines 240..260 (cache_deadline) = 20 lines ~= 61.3k
    //   worst build= 46,852 clk_sys measured (CACHE_BUILD max, frame 526)
    //               ~= 15.3 lines.
    // The original +5 was derived from that worst-case build alone: restart at
    // 244 leaves 16 lines and fits, 245 leaves 15 and does not. What it did not
    // account for is when the games actually stop writing the list. Measured in
    // MAME 0.289 (vasara, write taps on 0x100000-0x13ffff bucketed by beam
    // line, 240 frames): the global-list writes land on raster lines 240-247
    // only, at offsets 0x00002-0x000be. Lines 245, 246 and 247 therefore wrote
    // descriptors straight into an in-flight build with no restart, so the
    // committed cache mixed two frames' lists and sprites appeared for one
    // frame and vanished the next -- the flicker reported on vasara/vasara2.
    // Covering through 248 closes that hole. It is affordable only because the
    // The first accepted write in the measured window is coalesced above.
    // Payload streaming that resumes on line 250 is excluded, so later writes
    // cannot livelock the build.
    .cache_restart(cache_restart_flush),
    .cache_deadline(cache_deadline),
    .start(bg_done),
    .target_y(render_line_y),
    .local_control(scroll[59]), .flip_control(scroll[58]),
    .coordinate_control(scroll[61]),
    .global_y_base(scroll[56]), .global_y_adjust(scroll[53]),
    .sprite_offsets(sprite_offsets), .shadow_4bit(scroll[59][7]),
    .tilemap_scrolls(tilemap_scrolls),
    .spr_addr(obj_spr_addr), .spr_data(spr_video_q),
    .spr_data_next(spr_video_next_q),
    .rom_req(obj_rom_req), .rom_addr(obj_rom_addr),
    .rom_data(sdr_p2_dout), .rom_ack(obj_rom_ack),
    .plot_we(obj_plot_we), .plot_x(obj_plot_x),
    .plot_color(obj_plot_color),
    .plot_shadow(obj_plot_shadow), .plot_pen(obj_plot_pen),
    .plot_shadow_4bit(obj_shadow_4bit),
    .cache_busy(obj_cache_busy),
    .cache_ready(obj_cache_ready),
    .cache_overflow(obj_cache_overflow),
    .busy(obj_busy), .done(obj_done)
);

assign frame_tick = vblank_pulse;

always_ff @(posedge clk_sys) begin
    if (rst)
        renderer_overrun <= 1'b0;
    // A renderer busy at a line boundary is normal ring pipelining now; the
    // fault is scanout finding no completed line (line_underrun).
    else if (line_underrun || obj_cache_overflow)
        renderer_overrun <= 1'b1;
end

`ifdef SIMULATION
// Which producer armed the sticky flag, kept out of synthesis because the
// hardware indicator is one LED and cannot express a cause anyway.
logic overrun_cause_deadline, overrun_cause_cache;
always_ff @(posedge clk_sys) begin
    if (rst) begin
        overrun_cause_deadline <= 1'b0;
        overrun_cause_cache    <= 1'b0;
    end
    else begin
        if (line_underrun)      overrun_cause_deadline <= 1'b1;
        if (obj_cache_overflow) overrun_cause_cache    <= 1'b1;
    end
end

// These are deliberately local invariants rather than relaxed scoreboards:
// a shared p2 acknowledgement must go only to the renderer that owns the
// outstanding request, and a missed line deadline must never launch a second
// renderer on top of an in-flight one.  The sticky renderer_overrun above is
// still the externally reported fault; these checks make a future ownership
// or scheduling regression fail at its first causal clock.
//
// The ownership check is stated as address stability across an outstanding
// transaction, which is exactly the property the latch above exists to
// provide and is independent of the steering expressions themselves.
// Comparing bg_rom_ack against p2_owner_obj, as this invariant previously
// did, only restated their own definitions and could never fail however badly
// the port was steered.
//
// Two things that look like violations are not. obj_busy legitimately changes
// while a transaction is outstanding, because the object renderer can finish
// between issue and acknowledgement; the latched owner is what keeps that
// harmless. And a client legitimately drops its request on the clock its
// acknowledgement arrives, so "acknowledged while not requesting" is ordinary
// completion rather than a misroute.
logic [SDR_AW:4] p2_addr_r;
always_ff @(posedge clk_sys) begin
    if (!p2_busy_r && sdr_p2_req && !sdr_p2_ack) p2_addr_r <= sdr_p2_addr;
end

always @(posedge clk_sys) begin
    if (!rst) begin
        if (renderer_line_start && renderer_busy)
            $fatal(1, "renderer started while a previous renderer is busy");
        if (p2_busy_r && !sdr_p2_ack && (sdr_p2_addr !== p2_addr_r))
            $fatal(1, "p2 address moved while a transaction was outstanding: issued=%h now=%h owner_obj=%0d",
                   p2_addr_r, sdr_p2_addr, p2_owner_obj_r);
    end
end
`endif

wire vector_we = m_req && m_we && sel_irqvec;
wire ack_we    = m_req && m_we && sel_irqack;
wire enable_we = m_req && m_we && sel_irqen;
wire [2:0] irq_reg_level = a[6:4];
logic [7:0] irq_requested, irq_enabled;

ssv_irq irqs (
    // Scanline 0 of the visible frame; gated per game by the config.
    .line0_pulse(ce_pixel && (hcnt == 9'd0) && (vcnt == 9'd0)),
    .irq_level1_line0(cfg.irq_level1_line0),
    .line120_pulse(ce_pixel && (hcnt == 9'd0) && (vcnt == 9'd120)),
    .irq_level2_line120(cfg.irq_level2_line120),
    .adc_eoc_pulse(1'b0),
    .clk(clk_sys), .rst(rst), .cold_rst(cold_rst),
    .vblank_pulse(irq3_pulse),
    .vector_we(vector_we), .vector_level(irq_reg_level),
    .vector_data(m_wdata),
    .enable_we(enable_we), .enable_be(m_be), .enable_data(m_wdata),
    .ack_we(ack_we), .ack_level(irq_reg_level),
    .cpu_irq_ack(cpu_irq_ack), .irq_n(irq_n), .irq_vector(irq_vector),
    .requested(irq_requested), .enabled(irq_enabled)
);

always_ff @(posedge clk_sys) begin
    if (cold_rst)
        // MAME init_ssv() starts with video enabled; bit 7 of the lockout
        // register can subsequently blank it. machine_reset() does not call
        // init_ssv(), so watchdog soft reset must retain the current value.
        video_enable <= 1'b1;
    else if (m_req && m_we && (a == 24'h21000e) && m_be[0])
        video_enable <= m_wdata[7];
end

// MAME derives a live top/left clip from the CRTC visible-area registers at
// $1c0062/$64 and $1c006a/$6c.  The renderer may safely build the full native
// line; masking at scanout is equivalent for the externally visible pixels
// and also honors mid-game blank/window changes without flushing caches.
logic signed [18:0] crtc_min_x_calc, crtc_min_y_calc;
logic [8:0] crtc_min_x, crtc_min_y;
always_comb begin
    crtc_min_x_calc = 19'(active_width) +
        (19'($signed({1'b0, scroll[49]})) -
         19'($signed({1'b0, scroll[50]}))) * 19'sd2;
    crtc_min_y_calc = 19'(active_height) +
        19'($signed({1'b0, scroll[53]})) -
        19'($signed({1'b0, scroll[54]}));
    if (crtc_min_x_calc <= 0)
        crtc_min_x = 9'd0;
    else if (crtc_min_x_calc >= 19'(active_width))
        crtc_min_x = active_width;
    else
        crtc_min_x = crtc_min_x_calc[8:0];
    if (crtc_min_y_calc <= 0)
        crtc_min_y = 9'd0;
    else if (crtc_min_y_calc >= 19'(active_height))
        crtc_min_y = active_height;
    else
        crtc_min_y = crtc_min_y_calc[8:0];
end

// Line-buffer indices resolve through the live xRGB888 palette.
wire crtc_visible = (hcnt >= crtc_min_x) && (hcnt < active_width) &&
                    (vcnt >= crtc_min_y) && (vcnt < active_height);
wire video_active = video_enable && crtc_visible && !hb && !vb;
// MAME's screen_update() first bitmap.fill(0), then returns early when the
// video-enable latch is clear.  The visible result is palette pen 0, not a
// hard black RGB value; this matters when boot software has already loaded
// the backdrop colour before a blanking write.
wire [23:0] core_pixel =
    (crtc_visible && !hb && !vb) ?
        (video_enable ? palette_video_rgb : palette_background_rgb) :
        24'h000000;

// Audio-debug diagnostic overlay (see DBG_AUDIO_OVERLAY parameter above).
// Instantiated near the end of the file where the ES5506 taps exist.
wire [23:0] dbg_rgb;
assign rgb = DBG_AUDIO_OVERLAY ? dbg_rgb : core_pixel;

// Every subtraction below is evaluated at the SDR_AW+1 = 27-bit width of the
// return value, with cpu_addr zero-extended -- the operands are written 27 bits
// wide so that is explicit rather than inferred from the assignment context.
// Widths only; the computed value is unchanged.
//
// Range invariant: ext_phys_addr is consumed only where `sel_extmem` qualifies
// the access (the SDRAM request block below), and sel_extmem is
// sel_xram|sel_cpuram|sel_extra_wram|sel_nvram. Each branch therefore only ever
// sees an address inside the window whose base it subtracts -- sel_nvram for
// $580000, sel_extra_wram for $010000, sel_cpuram for $400000, and sel_xram
// ($160000-$17ffff) for the fall-through -- so no borrow occurs on a live
// access. Off-window inputs still produce a defined (wrapped) 27-bit value that
// no consumer looks at.
function automatic [SDR_AW:0] external_byte_addr(input [23:0] cpu_addr);
    if (cpu_addr >= 24'h580000)
        external_byte_addr = SDR_NVRAM_BASE + (27'(cpu_addr) - 27'h0580000);
    else if ((cfg.extra_ram_mode == 2'd2) &&
             (cpu_addr >= 24'h010000) && (cpu_addr <= 24'h03ffff))
        external_byte_addr = SDR_CPU_RAM_BASE + (27'(cpu_addr) - 27'h0010000);
    else if ((cfg.extra_ram_mode == 2'd1) &&
             (cpu_addr >= 24'h400000) && (cpu_addr <= 24'h43ffff))
        external_byte_addr = SDR_CPU_RAM_BASE + (27'(cpu_addr) - 27'h0400000);
    else
        external_byte_addr = SDR_XRAM_BASE + (27'(cpu_addr) - 27'h0160000);
endfunction

wire [SDR_AW:0] ext_phys_addr = external_byte_addr(a);
logic      ext_busy;
logic      ext_is_write;
logic [15:0] ext_read_data;
logic      ext_done;
logic      ext_p0_req_r;
logic [SDR_AW:1] ext_p0_addr_r;

// Forward-declared: icache lookup suppresses re-arming a completed ROM read
// while the V60 bus still holds m_req (ack_r driven in the read-mux block).
logic [15:0] read_mux;
logic        read_wait;
// MAME's drifto94_unknown_r() returns machine().rand(). A tiny deterministic
// LFSR gives the same non-constant hardware-visible contract without pulling
// in a large PRNG; the descriptor gates it to Drift Out/Storm Blade only.
logic [15:0] drifto_unknown_lfsr;
wire [15:0] drifto_unknown_value = drifto_unknown_lfsr;

always_ff @(posedge clk_sys) begin
    if (rst)
        drifto_unknown_lfsr <= 16'h1;
    // Advance once after the completed read.  The V60 holds m_req throughout
    // the core's wait/ack sequence, so advancing on a held request changes the
    // value multiple times for one MAME handler transaction.
    else if (m_req && !m_we && sel_drifto_unknown && ack_r && !ack_r_d)
        drifto_unknown_lfsr <= {
            drifto_unknown_lfsr[14:0],
            drifto_unknown_lfsr[15] ^ drifto_unknown_lfsr[13] ^
            drifto_unknown_lfsr[12] ^ drifto_unknown_lfsr[10]
        };
end

// ---------------------------------------------------------------------------
// V60 ROM fetch via SDRAM p0, through a small I/D cache (from s32):
//   128 lines x 8 bytes direct-mapped. Hit = 1 clk_sys; miss = 4 sequential
//   p0 word reads to fill the line. Reset (incl. ROM download) invalidates.
// p0 is shared with the XRAM and $400000 CPU RAM reads — icache fills win.
// ---------------------------------------------------------------------------
logic        rom_req_r;
logic [SDR_AW:1] rom_addr_r;
// Fill words land in this register, and the completed 8-byte line is written
// to the array in one piece. A per-word bit-select write into the array made
// Quartus give up on memory inference (warning 10999), so the 32x64 array was
// built from 2048 flops plus three 64-bit 32:1 read muxes; whole-word writes
// map to LUTRAM like icache_tag already did.
logic [63:0] fill_buf;
(* ramstyle = "MLAB, no_rw_check" *) logic [63:0] icache_data [0:127];
(* ramstyle = "MLAB, no_rw_check" *) logic [13:0] icache_tag  [0:127]; // offset[21:8]
logic [127:0] icache_valid;

// MAME: map(rom, 0xffffff).rom().region("maincpu", 0), where rom is the
// descriptor-sized base ($f00000/$e00000/$c00000). Translate the CPU address
// to the selected set's full 1/2/4 MB image before indexing the cache. The old
// Dyna-only path truncated every address to 20 bits, so 2 MB and 4 MB sets
// fetched their reset stub from offset zero and immediately executed garbage.
// 22 bits is the exact natural width of this offset, not a convenience: the
// subtraction is only meaningful under `sel_rom` (a >= rom_window_base, decoded
// above), and rom_window_base = -(cfg.prog_mb << 20) with prog_mb in {1,2,4}
// puts the window base at $f00000/$e00000/$c00000. The largest live offset is
// therefore $ffffff - $c00000 = $3fffff, which fills 22 bits exactly and cannot
// borrow. The cast makes that intent explicit; it drops the same top two bits
// the implicit assignment already dropped, so the value is unchanged. Every
// consumer (ic_line/ic_tag/ic_word and the fill path) is gated on sel_rom.
// NOTE: this width is only correct while prog_mb <= 4. A future 8 MB program
// would need 23 bits here and in the icache tag.
wire [21:0] rom_byte_a = 22'(a - rom_window_base);
wire [6:0]  ic_line    = rom_byte_a[9:3];
wire [13:0] ic_tag     = rom_byte_a[21:8];
wire        ic_hit     = icache_valid[ic_line] && (icache_tag[ic_line] == ic_tag);
wire [63:0] ic_ldata   = icache_data[ic_line];
wire [15:0] ic_word    = ic_ldata[{rom_byte_a[2:1], 4'b0000} +: 16];

// Instruction-fetch lookup (whole 8-byte line), using the same full-window
// translation as data accesses. The V60 presents a 24-bit address here.
// Same 22-bit natural width and same rom_window_base derivation as rom_byte_a
// above; explicit cast, identical bits. Unlike the data path there is no
// `sel_rom` gate on this expression -- the icache is the V60's only instruction
// source, so the invariant here is that the prefetch frontier stays inside the
// program-ROM window, which is a property of SSV code (it executes from ROM),
// not of a decode. A fetch from outside the window would already read the wrong
// backing store with or without this cast; the cast changes nothing about that.
wire [21:0] if_byte_a  = 22'(if_addr - rom_window_base);
wire [6:0]  if_line_ix = if_byte_a[9:3];
wire [13:0] if_tag_ix  = if_byte_a[21:8];
wire        if_hit     = icache_valid[if_line_ix] &&
                         (icache_tag[if_line_ix] == if_tag_ix);
// Pre-align so byte 0 is the frontier byte (if_addr[2:0] = intra-line offset).
wire [63:0] if_hit_data = icache_data[if_line_ix] >> {if_addr[2:0], 3'b000};

logic [1:0]  fill_word;
logic        rom_filling;
logic        rom_ready;
logic [15:0] rom_word_r;
logic [6:0]  fill_line;
logic [13:0] fill_tag;
logic [18:0] fill_wbase;
logic        fill_isfetch;
logic [1:0]  fill_dsel;
logic [2:0]  fill_foff;
logic        fill_awaiting;   // waiting for rising ack of current fill word
logic        fill_need_req;   // issue next word req after stretched ack falls
logic        sdr_p0_ack_d;
wire         sdr_p0_ack_rise = sdr_p0_ack && !sdr_p0_ack_d;
// Complete line as of the final fill word: three buffered words plus the beat
// being acked this cycle.
wire [63:0]  fill_line_data = {sdr_p0_dout, fill_buf[47:0]};

wire icache_p0_busy = rom_filling || rom_req_r || (if_req && !if_served);

assign sdr_p0_req  = ext_p0_req_r | rom_req_r;
assign sdr_p0_addr = ext_p0_req_r ? ext_p0_addr_r
                                  : rom_addr_r;

always_ff @(posedge clk_sys) begin
    if (rst) begin
        rom_req_r     <= 1'b0;
        rom_filling   <= 1'b0;
        rom_ready     <= 1'b0;
        icache_valid  <= 128'h0;
        if_served     <= 1'b0;
        fill_awaiting <= 1'b0;
        fill_need_req <= 1'b0;
        sdr_p0_ack_d  <= 1'b0;
    end
    else begin
        sdr_p0_ack_d <= sdr_p0_ack;
        rom_req_r <= 1'b0;
        rom_ready <= 1'b0;
        // Re-arm the fetch port once the CPU drops if_req (consumed if_ack).
        if (!if_req)
            if_served <= 1'b0;

        if (rom_filling) begin
            // Wait for stretched ack to drop before the next rising-edge req
            // (TB models and the real SDRAM both need a fresh req edge).
            if (fill_need_req && !sdr_p0_ack && !ext_p0_req_r) begin
                fill_need_req <= 1'b0;
                fill_awaiting <= 1'b1;
                rom_req_r     <= 1'b1;
                rom_addr_r    <= {5'b00000, fill_wbase, fill_word};
            end
            else if (fill_awaiting && sdr_p0_ack_rise && !ext_p0_req_r) begin
                fill_buf[{fill_word, 4'b0000} +: 16] <= sdr_p0_dout;
                fill_awaiting <= 1'b0;
                if (fill_word == 2'd3) begin
                    rom_filling <= 1'b0;
                    icache_data[fill_line]  <= fill_line_data;
                    icache_tag[fill_line]   <= fill_tag;
                    icache_valid[fill_line] <= 1'b1;
                    if (fill_isfetch) begin
                        if_data   <= fill_line_data >> {fill_foff, 3'b000};
                        if_served <= 1'b1;
                    end
                    else begin
                        rom_word_r <=
                            fill_line_data[{fill_dsel, 4'b0000} +: 16];
                        rom_ready  <= 1'b1;
                    end
                end
                else begin
                    fill_word     <= fill_word + 1'd1;
                    fill_need_req <= 1'b1;
                end
            end
        end
        // Instruction fetch has priority (common ROM access path).
        else if (if_req && !if_served && !ext_p0_req_r) begin
            if (if_hit) begin
                if_data   <= if_hit_data;
                if_served <= 1'b1;
            end
            else begin
                rom_filling   <= 1'b1;
                fill_isfetch  <= 1'b1;
                fill_foff     <= if_addr[2:0];
                fill_line     <= if_line_ix;
                fill_tag      <= if_tag_ix;
                fill_wbase    <= if_byte_a[21:3];
                fill_word     <= 2'd0;
                fill_awaiting <= 1'b1;
                fill_need_req <= 1'b0;
                rom_req_r     <= 1'b1;
                rom_addr_r    <= {5'b00000, if_byte_a[21:3], 2'b00};
            end
        end
        // Data ROM read (constants/tables). See !ack_r note above.
        else if (m_req && !m_we && sel_rom && !rom_ready && !ack_r &&
                 !ext_p0_req_r) begin
            if (ic_hit) begin
                rom_word_r <= ic_word;
                rom_ready  <= 1'b1;
            end
            else begin
                rom_filling   <= 1'b1;
                fill_isfetch  <= 1'b0;
                fill_line     <= ic_line;
                fill_tag      <= ic_tag;
                fill_wbase    <= rom_byte_a[21:3];
                fill_dsel     <= rom_byte_a[2:1];
                fill_word     <= 2'd0;
                fill_awaiting <= 1'b1;
                fill_need_req <= 1'b0;
                rom_req_r     <= 1'b1;
                rom_addr_r    <= {5'b00000, rom_byte_a[21:3], 2'b00};
            end
        end
    end
end

// XRAM / $400000 CPU RAM via SDRAM p0/wr (uncached). Yields to icache fills.
always_ff @(posedge clk_sys) begin
    if (rst) begin
        ext_busy      <= 1'b0;
        ext_is_write  <= 1'b0;
        ext_read_data <= 16'hffff;
        ext_done      <= 1'b0;
        ext_p0_req_r  <= 1'b0;
        ext_p0_addr_r <= '0;
        sdr_wr_req    <= 1'b0;
        sdr_wr_addr   <= '0;
        sdr_wr_din    <= '0;
        sdr_wr_be     <= 2'b00;
    end
    else begin
        ext_done <= 1'b0;
        if (sdr_p0_ack_rise && ext_p0_req_r) begin
            ext_p0_req_r  <= 1'b0;
            ext_busy      <= 1'b0;
            ext_read_data <= sdr_p0_dout;
            ext_done      <= 1'b1;
        end
        // Posted write completes in SDRAM: release the request/busy so the
        // next extmem access can start. The CPU was already acked at accept
        // time (ext_done pulse in the accept branch below), so no ext_done
        // here -- a stray pulse now could falsely complete an unrelated
        // in-progress extmem access.
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            ext_busy   <= 1'b0;
        end

        // Do not start a new SDRAM beat while ack_r is still posted. With a
        // sparse ce_cpu the CPU may leave m_req high for several clk_sys
        // cycles after ext_done; without this guard the TB/hardware can
        // issue a spurious second fetch and corrupt the outstanding read.
        // Also wait for the ROM icache to release p0.
        if (m_req && sel_extmem && !ext_busy && !ext_done && !ack_r &&
            !icache_p0_busy) begin
            if (m_we) begin
                sdr_wr_req   <= 1'b1;
                sdr_wr_addr  <= ext_phys_addr[SDR_AW:1];
                sdr_wr_din   <= m_wdata;
                sdr_wr_be    <= m_be;
                ext_is_write <= 1'b1;
                ext_busy     <= 1'b1;
                // Posted write: ack the CPU now instead of after the SDRAM
                // round trip. sdram.sv latches wr_addr/din/be on the wr_req
                // rising edge and these sdr_wr_* registers hold until then,
                // so the beat is safely in flight. ext_busy stays set until
                // sdr_wr_ack, which stalls ANY subsequent extmem access
                // (read or write) behind the in-flight write -- conservative
                // full ordering, no address-match forwarding. On the PCB this
                // RAM was uniform-speed SRAM, so the earlier ack is closer to
                // real timing, and completed-transaction ORDER is unchanged.
                ext_done     <= 1'b1;
            end
            else begin
                ext_p0_req_r  <= 1'b1;
                ext_p0_addr_r <= ext_phys_addr[SDR_AW:1];
                ext_is_write  <= 1'b0;
                ext_busy      <= 1'b1;
            end
        end
    end
end
// ---------------------------------------------------------------------------
// ST010: instruction-issue enable, DSP + data ROM, and the SDRAM program fetch.
//
// MAME instantiates UPD96050 at 10 MHz with its own `// TODO: correct?`, so the
// clock is not authoritative. The core runs a fixed 5-state sequence per
// instruction and starts one only when `ce` is high, so the instruction rate IS
// the ce rate: 10 MHz / 4 = 2.5 MIPS. Off clk_sys = 48.324 MHz a 16-bit
// fractional accumulator with increment 3391 gives
//     48.324e6 * 3391 / 65536 = 2.5005 MHz   (+0.02%)
// which is well inside the uncertainty of the 10 MHz figure itself.
// ---------------------------------------------------------------------------
logic [15:0] st010_ce_acc;
logic        st010_ce;
wire  [16:0] st010_acc_next = {1'b0, st010_ce_acc} + 17'd3391;

always_ff @(posedge clk_sys) begin
    if (rst || !cfg.has_st010) begin
        st010_ce_acc <= 16'd0;
        st010_ce     <= 1'b0;
    end
    else begin
        st010_ce_acc <= st010_acc_next[15:0];
        st010_ce     <= st010_acc_next[16];
    end
end

wire [13:0] st010_prg_addr;
wire        st010_prg_req;
wire [23:0] st010_prg_data;
wire        st010_prg_valid;
wire [15:0] st010_rdata;
logic [1:0] st010_rd_cnt;
`ifdef SIMULATION
wire        st010_debug_retire;
wire [23:0] st010_debug_ir;
wire [13:0] st010_debug_pc;
wire [15:0] st010_debug_a, st010_debug_b;
wire  [5:0] st010_debug_flaga, st010_debug_flagb;
wire [15:0] st010_debug_dp, st010_debug_dr, st010_debug_sr;
wire [15:0] st010_debug_k, st010_debug_l, st010_debug_m, st010_debug_n;
wire        st010_debug_ram_write;
wire [10:0] st010_debug_ram_addr, st010_debug_host_ram_addr;
wire [15:0] st010_debug_ram_wdata, st010_debug_host_ram_q;
wire        st010_debug_host_ram_high;
wire  [7:0] st010_debug_host_ram_dout;
wire  [2:0] st010_debug_state;
`endif

// The project ships one universal RBF, so this daughterboard must always be
// present in synthesis. cfg.has_st010 is the only selection mechanism: it
// parks the DSP and fetcher for titles without the board, while Drift Out '94,
// Storm Blade and Twin Eagle II can enable the same hardware at ROM-load time.
// Never put this instance behind a compile-time game/profile define.
upd96050_st010 st010 (
    .clk(clk_sys),
    .rst(cold_rst || !cfg.has_st010),
    .soft_rst(rst && !cold_rst && cfg.has_st010),
    .ce_dsp(st010_ce),

    .cpu_addr(m_addr), .cpu_be(m_be),
    // The wrapper edge-detects the data-port strobes internally, so a level
    // held for the whole bus cycle is safe here (upd96050_st010.sv:151-167).
    .cpu_we(m_req &&  m_we && sel_st010 && !ack_r),
    .cpu_re(m_req && !m_we && sel_st010 && !ack_r),
    .cpu_wdata(m_wdata), .cpu_rdata(st010_rdata), .cpu_sel(),

    .prg_addr(st010_prg_addr), .prg_req(st010_prg_req),
    .prg_data(st010_prg_data), .prg_valid(st010_prg_valid),

    .drom_we(st010_drom_we), .drom_wa(st010_drom_wa), .drom_wd(st010_drom_wd),

    // MAME never wires the uPD96050's INT on SSV, and the DSP's P0/P1 outputs
    // go nowhere on the daughterboard.
    .int_req(1'b0), .p0(), .p1()

`ifdef SIMULATION
    , .dbg_retire(st010_debug_retire), .dbg_ir(st010_debug_ir),
    .dbg_pc(st010_debug_pc),
    .dbg_a(st010_debug_a), .dbg_b(st010_debug_b),
    .dbg_flaga(st010_debug_flaga), .dbg_flagb(st010_debug_flagb),
    .dbg_dp(st010_debug_dp), .dbg_dr(st010_debug_dr),
    .dbg_sr(st010_debug_sr), .dbg_k(st010_debug_k),
    .dbg_l(st010_debug_l), .dbg_m(st010_debug_m), .dbg_n(st010_debug_n),
    .dbg_ram_write(st010_debug_ram_write), .dbg_ram_addr(st010_debug_ram_addr),
    .dbg_ram_wdata(st010_debug_ram_wdata),
    .dbg_host_ram_addr(st010_debug_host_ram_addr),
    .dbg_host_ram_high(st010_debug_host_ram_high),
    .dbg_host_ram_q(st010_debug_host_ram_q),
    .dbg_host_ram_dout(st010_debug_host_ram_dout),
    .dbg_state(st010_debug_state)
`endif
);

ssv_st010_prg_fetch st010_fetch (
    .clk(clk_sys), .rst(rst), .enable(cfg.has_st010),
    .prg_addr(st010_prg_addr), .prg_req(st010_prg_req),
    .prg_data(st010_prg_data), .prg_valid(st010_prg_valid),
    .sdr_req(sdr_p5_req), .sdr_addr(sdr_p5_addr),
    .sdr_dout(sdr_p5_dout), .sdr_ack(sdr_p5_ack)
);

wire [7:0] sound_rdata;
// ES5506 MLAB banks need 2 wait cycles: steal addr, then latch q → read_latch.
logic [1:0] sound_rd_cnt;
wire sound_host_we = m_req && m_we && sel_sound && !ack_r && m_be[0];
// m_be[0] mirrors sound_host_we: MAME maps the ES5506 with umask16(0x00ff),
// so an odd-address byte read never reaches the device. Without the gate the
// read still stole the register file's port and, for host_reg 0xE, cleared
// IRQV where MAME would not.
wire sound_host_re = m_req && !m_we && sel_sound &&
                     !ack_r && m_be[0] && (sound_rd_cnt == 2'd0);
wire sound_irq_n;
wire [6:0] sound_current_page;
wire sound_commit;
wire [6:0] sound_commit_page;
wire [3:0] sound_commit_reg;
wire [31:0] sound_commit_data;
wire [4:0] sound_active_voices;
wire [4:0] eng_voice;
wire       eng_snap;
wire       eng_snap_ok;
wire [15:0] eng_cr;
wire        eng_cr_valid;
wire [16:0] eng_fc;
wire [15:0] eng_lvol, eng_rvol, eng_k1, eng_k2;
wire [7:0]  eng_lvramp, eng_rvramp;
wire [8:0]  eng_ecount, eng_k1ramp, eng_k2ramp;
wire [31:0] eng_start, eng_end, eng_accum;
wire [17:0] eng_o4n1, eng_o3n1, eng_o3n2, eng_o2n1, eng_o2n2, eng_o1n1;
wire        eng_wr_accum, eng_wr_cr, eng_wr_filt, eng_wr_env;
wire [31:0] eng_accum_w;
wire [15:0] eng_cr_set, eng_cr_clr;
wire [15:0] eng_lvol_w, eng_rvol_w, eng_k1_w, eng_k2_w;
wire [17:0] eng_o4n1_w, eng_o3n1_w, eng_o3n2_w, eng_o2n1_w, eng_o2n2_w, eng_o1n1_w;
wire [8:0]  eng_ecount_w;
wire        eng_irq_set;
wire [4:0]  eng_irq_voice;
wire        sound_sample_tick, sound_underrun;
// Share the CPU enable so voice and V60 stay phase-aligned (saves a second
// fractional accumulator and matches board 16 MHz OTTO / V60 clocking).
wire ce_snd = ce_cpu;

ssv_es5506_regs sound_registers (
    .clk(clk_sys),
    .rst(rst),
    .cold_rst(cold_rst),
    .host_we(sound_host_we),
    .host_re(sound_host_re),
    .host_addr(a[6:1]),
    .host_wdata(m_wdata[7:0]),
    .host_rdata(sound_rdata),
    .par_data(10'd0),
    .irq_set(eng_irq_set),
    .irq_voice(eng_irq_voice),
    .irq_n(sound_irq_n),
    .current_page(sound_current_page),
    .active_voices(sound_active_voices),
    .mode(),
    .word_clock_start(),
    .word_clock_end(),
    .lr_clock_end(),
    .commit(sound_commit),
    .commit_page(sound_commit_page),
    .commit_reg(sound_commit_reg),
    .commit_data(sound_commit_data),
    .eng_voice(eng_voice),
    .eng_snap(eng_snap),
    .snap_ok(eng_snap_ok),
    .eng_cr(eng_cr), .eng_cr_valid(eng_cr_valid),
    .eng_fc(eng_fc),
    .eng_lvol(eng_lvol), .eng_lvramp(eng_lvramp),
    .eng_rvol(eng_rvol), .eng_rvramp(eng_rvramp),
    .eng_ecount(eng_ecount),
    .eng_k1(eng_k1), .eng_k1ramp(eng_k1ramp),
    .eng_k2(eng_k2), .eng_k2ramp(eng_k2ramp),
    .eng_start(eng_start), .eng_end(eng_end), .eng_accum(eng_accum),
    .eng_o4n1(eng_o4n1), .eng_o3n1(eng_o3n1), .eng_o3n2(eng_o3n2),
    .eng_o2n1(eng_o2n1), .eng_o2n2(eng_o2n2), .eng_o1n1(eng_o1n1),
    .eng_wr_accum(eng_wr_accum), .eng_accum_w(eng_accum_w),
    .eng_wr_cr(eng_wr_cr), .eng_cr_set(eng_cr_set), .eng_cr_clr(eng_cr_clr),
    .eng_wr_filt(eng_wr_filt),
    .eng_o4n1_w(eng_o4n1_w), .eng_o3n1_w(eng_o3n1_w), .eng_o3n2_w(eng_o3n2_w),
    .eng_o2n1_w(eng_o2n1_w), .eng_o2n2_w(eng_o2n2_w), .eng_o1n1_w(eng_o1n1_w),
    .eng_wr_env(eng_wr_env),
    .eng_lvol_w(eng_lvol_w), .eng_rvol_w(eng_rvol_w),
    .eng_k1_w(eng_k1_w), .eng_k2_w(eng_k2_w), .eng_ecount_w(eng_ecount_w)
);

logic srmp7_bank;
wire srmp7_bank_write;
ssv_srmp7_bank srmp7_bank_latch (
    .clk(clk_sys), .cold_rst(cold_rst), .write(srmp7_bank_write),
    .data(m_wdata[0]), .bank(srmp7_bank)
);
ssv_es5506_voice sound_voices (
    .cfg(cfg),
    .srmp7_bank(srmp7_bank),
    .clk(clk_sys), .rst(rst), .ce(ce_snd),
    .active_voices(sound_active_voices),
    .eng_voice(eng_voice),
    .eng_cr(eng_cr), .eng_cr_valid(eng_cr_valid),
    .eng_fc(eng_fc),
    .eng_lvol(eng_lvol), .eng_lvramp(eng_lvramp),
    .eng_rvol(eng_rvol), .eng_rvramp(eng_rvramp),
    .eng_ecount(eng_ecount),
    .eng_k1(eng_k1), .eng_k1ramp(eng_k1ramp),
    .eng_k2(eng_k2), .eng_k2ramp(eng_k2ramp),
    .eng_start(eng_start), .eng_end(eng_end), .eng_accum(eng_accum),
    .eng_o4n1(eng_o4n1), .eng_o3n1(eng_o3n1), .eng_o3n2(eng_o3n2),
    .eng_o2n1(eng_o2n1), .eng_o2n2(eng_o2n2), .eng_o1n1(eng_o1n1),
    .eng_wr_accum(eng_wr_accum), .eng_accum_w(eng_accum_w),
    .eng_wr_cr(eng_wr_cr), .eng_cr_set(eng_cr_set), .eng_cr_clr(eng_cr_clr),
    .eng_wr_filt(eng_wr_filt),
    .eng_o4n1_w(eng_o4n1_w), .eng_o3n1_w(eng_o3n1_w), .eng_o3n2_w(eng_o3n2_w),
    .eng_o2n1_w(eng_o2n1_w), .eng_o2n2_w(eng_o2n2_w), .eng_o1n1_w(eng_o1n1_w),
    .eng_wr_env(eng_wr_env),
    .eng_lvol_w(eng_lvol_w), .eng_rvol_w(eng_rvol_w),
    .eng_k1_w(eng_k1_w), .eng_k2_w(eng_k2_w), .eng_ecount_w(eng_ecount_w),
    .irq_ready(sound_irq_n),
    .eng_irq_set(eng_irq_set), .eng_irq_voice(eng_irq_voice),
    .host_ecount_write(sound_commit && (sound_commit_page < 7'h20) &&
                       (sound_commit_reg == 4'h6)),
    .host_ecount_voice(sound_commit_page[4:0]),
    .sdr_req(sdr_p4_req), .sdr_addr(sdr_p4_addr),
    .sdr_dout(sdr_p4_dout), .sdr_ack(sdr_p4_ack),
    .audio_l(audio_l), .audio_r(audio_r),
    .sample_tick(sound_sample_tick), .underrun(sound_underrun),
    .eng_snap(eng_snap),
    .snap_ok(eng_snap_ok)
);

assign audio_tick = sound_sample_tick;

// ---------------------------------------------------------------------------
// Fullscreen ES5506 audio-debug screen (diagnostic builds only; the mux back
// at the rgb assignment selects it when DBG_AUDIO_OVERLAY=1). It only taps
// existing signals -- nothing in the audio or video path changes behaviour.
// ---------------------------------------------------------------------------
ssv_audio_debug_overlay u_audio_dbg (
    .clk(clk_sys), .rst(rst), .en(DBG_AUDIO_OVERLAY),
    .ce_pixel(ce_pixel), .hcnt(hcnt), .vcnt(vcnt),
    .active_width(active_width), .active_height(active_height),
    .rgb_in(core_pixel), .rgb_out(dbg_rgb),
    .eng_snap(eng_snap), .eng_voice(eng_voice),
    .eng_cr(eng_cr), .eng_fc(eng_fc), .eng_accum(eng_accum),
    .eng_start(eng_start), .eng_end(eng_end),
    .eng_lvol(eng_lvol), .eng_rvol(eng_rvol), .eng_ecount(eng_ecount),
    .eng_k1(eng_k1), .eng_k2(eng_k2),
    .eng_wr_accum(eng_wr_accum), .eng_accum_w(eng_accum_w),
    .eng_wr_cr(eng_wr_cr), .eng_wr_filt(eng_wr_filt),
    .eng_wr_env(eng_wr_env),
    .bank_valid(cfg.bank_valid),
    .sample_tick(sound_sample_tick), .underrun(sound_underrun),
    .irq_n(sound_irq_n), .irq_set(eng_irq_set), .irq_voice(eng_irq_voice),
    .active_voices(sound_active_voices), .current_page(sound_current_page),
    .commit(sound_commit), .commit_page(sound_commit_page),
    .commit_reg(sound_commit_reg), .commit_data(sound_commit_data),
    .host_we(sound_host_we), .host_re(sound_host_re), .ce_snd(ce_snd),
    .p4_req(sdr_p4_req), .p4_ack(sdr_p4_ack),
    .audio_l(audio_l), .audio_r(audio_r)
);

assign m_rdata = read_mux;
assign m_ack   = ack_r;

// MAME's WATCHDOG_TIMER has no SSV-specific override, so watchdog.cpp uses its
// default attotime::from_seconds(3). Count clk_sys master cycles from reset;
// video cadence and video_enable are unrelated to this physical timer.
// How it is kicked -- and whether the board has one at all -- is descriptor
// data, and getting this wrong is not subtle:
//   mode 1  read-kick   dynagear, twineag2, ultrax            (reset16_r)
//   mode 2  write-kick  vasara, vasara2                       (reset16_w)
//   mode 0  no device   drifto94, stmblade
// MAME's WATCHDOG_TIMER first appears at ssv.cpp:2513, after the drifto94 and
// stmblade machine configs, so those two have no watchdog. Left unconditional,
// this counter would reset them forever and never be kicked by vasara.
localparam int WDOG_COUNTER_WIDTH = $clog2(WDOG_TIMEOUT_CYCLES + 1);
logic [WDOG_COUNTER_WIDTH-1:0] wdog_cycle_cnt;
wire        wdog_addr_hit = sel_io && (a[4:1] == 4'h0) && ack_r && !ack_r_d;
wire        wdog_kick = m_req && wdog_addr_hit &&
                        ((cfg.wdog_mode == 2'd1) ? !m_we :
                         (cfg.wdog_mode == 2'd2) ?  m_we : 1'b0);

`ifdef SIMULATION
// These messages are deliberately simulation-only.  They record the accepted
// transaction edge (not merely a bus request) and the resulting sticky reset,
// which is the useful distinction when diagnosing a real-game reset.
logic sim_wdog_rst_d;
initial sim_wdog_rst_d = 1'b0;
always @(posedge clk_sys) begin
    if (wdog_kick && $test$plusargs("WDOG_TRACE"))
        $display("SSV_WDOG_KICK mode=%0d rw=%0d addr=%06x cycle=%0d",
                 cfg.wdog_mode, m_we, a, wdog_cycle_cnt);
    if (wdog_rst !== sim_wdog_rst_d)
        $display("SSV_WDOG_TRIP state=%0d mode=%0d cycle=%0d",
                 wdog_rst, cfg.wdog_mode, wdog_cycle_cnt);
    sim_wdog_rst_d <= wdog_rst;
end

`endif

// MAME ssv_state::lockout_w / lockout_inv_w. Both variants use data bit 1
// for coin slot 0 and bit 0 for slot 1; only the lockout polarity changes.
// Counter 0 is driven by bit 3 and counter 1 by bit 2, and bookkeeping counts
// low-to-high transitions rather than every write that leaves a bit asserted.
wire lockout_write = m_req && m_we && (a == 24'h21000e) && m_be[0] &&
                     ack_r && !ack_r_d;
assign srmp7_bank_write = cfg.srmp7_sample_half_bank && m_req && m_we &&
                          (a == 24'h580000) && m_be[0] && ack_r && !ack_r_d;
wire [15:0] in_system_gated = in_system |
    {14'd0, coin_lockout[1], coin_lockout[0]};

always_ff @(posedge clk_sys) begin
    // Cabinet bookkeeping and output latches are not cleared by MAME's
    // machine_reset(); retain them across a watchdog reset.
    if (cold_rst) begin
        coin_lockout <= 2'b00; // cabinet starts unlocked
    end
    else begin
        if (lockout_write) begin
            coin_lockout[0] <= cfg.lockout_inverted ?  m_wdata[1] : ~m_wdata[1];
            coin_lockout[1] <= cfg.lockout_inverted ?  m_wdata[0] : ~m_wdata[0];
        end
    end
end

// No qualified profile has the Sexy Reaction cabinet motor output.
assign motor_output = 1'b0;

always_ff @(posedge clk_sys) begin
    if (rst) begin
        wdog_cycle_cnt <= '0;
        wdog_rst       <= 1'b0;
        ack_r_d        <= 1'b0;
    end
    else begin
        ack_r_d <= ack_r;
        if (cfg.wdog_mode == 2'd0) begin
            wdog_cycle_cnt <= '0;
            wdog_rst <= 1'b0;
        end
        else if (wdog_kick) begin
            wdog_cycle_cnt <= '0;
        end
        else if (!watchdog_hold && !wdog_rst) begin
            if (wdog_cycle_cnt ==
                WDOG_COUNTER_WIDTH'(WDOG_TIMEOUT_CYCLES - 1))
                wdog_rst <= 1'b1;
            else
                wdog_cycle_cnt <= wdog_cycle_cnt + 1'd1;
        end
    end
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ack_r        <= 1'b0;
        read_wait    <= 1'b0;
        sound_rd_cnt <= 2'd0;
        st010_rd_cnt <= 2'd0;
        // V60 program space is configured with MAME's default unmapped value
        // of zero.  Mapped active-low input ports still supply 16'hffff when
        // idle; only genuinely unmapped/nopr reads take this default.
        read_mux     <= 16'h0000;
    end
    else if (!m_req) begin
        ack_r        <= 1'b0;
        read_wait    <= 1'b0;
        sound_rd_cnt <= 2'd0;
        st010_rd_cnt <= 2'd0;
    end
    else if (!ack_r) begin
        // ROM reads complete via the icache (rom_ready). ROM writes are nops
        // (MAME image is read-only) but must still ack or a push into 0xFxxxxx
        // hangs forever.
        if (sel_rom && !m_we) begin
            if (rom_ready) begin
                read_mux <= rom_word_r;
                ack_r    <= 1'b1;
            end
        end
        else if (sel_extmem) begin
            // Fast path: capture read data straight off the p0 ack edge,
            // one clk_sys earlier than waiting for the registered ext_done
            // pulse. ext_p0_req_r is only ever set for the extmem access the
            // CPU is currently holding (m_req stays up until ack), so this
            // tap cannot see someone else's data. The ext_done branch still
            // covers posted writes (acked at accept) and remains a safe
            // fallback; when the fast path fires, the following ext_done
            // pulse lands while ack_r is already high and is ignored.
            if (ext_p0_req_r && sdr_p0_ack_rise) begin
                read_mux <= sdr_p0_dout;
                ack_r    <= 1'b1;
            end
            else if (ext_done) begin
                read_mux <= ext_is_write ? 16'hffff : ext_read_data;
                ack_r    <= 1'b1;
            end
        end
        else if (m_we) begin
            ack_r <= 1'b1;
        end
        // The $482000 data-RAM window is a block-RAM read: host_ram_dout is the
        // byte for the address presented one clk earlier (upd96050.sv:113).
        // Two wait cycles, the same shape the ES5506 MLAB banks use, cover both
        // that and the combinational $480000 byte.
        else if (sel_st010) begin
            if (st010_rd_cnt < 2'd2)
                st010_rd_cnt <= st010_rd_cnt + 2'd1;
            else begin
                st010_rd_cnt <= 2'd0;
                ack_r        <= 1'b1;
                read_mux     <= st010_rdata;
            end
        end
        else if (sel_sound && cfg.srmp7_irqv_mame && (a == 24'h300076)) begin
            // MAME 0.289 compatibility assumption.  The reference driver
            // synthesizes IRQV=0x80 because the physical ES5506 level-5 path
            // is unresolved; this does not invent an IRQ source.
            ack_r <= 1'b1;
            read_mux <= 16'h0080;
        end
        else if (sel_sound) begin
            if (sound_rd_cnt < 2'd2)
                sound_rd_cnt <= sound_rd_cnt + 2'd1;
            else begin
                sound_rd_cnt <= 2'd0;
                ack_r        <= 1'b1;
                read_mux     <= {8'h00, sound_rdata};
            end
        end
        else if (!read_wait) begin
            read_wait <= 1'b1;
        end
        else begin
            read_wait <= 1'b0;
            ack_r <= 1'b1;
            unique case (1'b1)
                sel_wram:    read_mux <= wram_q;
                sel_sprram:  read_mux <= spr_q;
                sel_palette: read_mux <= pal_q;
                sel_scroll:  read_mux <= (a == 24'h1c0000)
                    ? ssv_video_status(vb, hb) : scroll_q;
                sel_io: begin
                    unique case (a[4:1])
                        // Only read-kick maps install a readable watchdog at
                        // $210000.  Vasara is write-only and Drift/STM have no
                        // device there.  watchdog reset16_r and the V60
                        // program space's unmapped value are both zero.
                        4'h0: read_mux <= (cfg.wdog_mode == 2'd1)
                            ? 16'h0000 : 16'h0000;
                        // MAME's portr() values are eight-bit ports on this
                        // 16-bit V60 map. The handler zero-extends them; the
                        // wrapper's high byte is only internal idle padding.
                        4'h1: read_mux <= {8'h00, in_dsw1[7:0]};
                        4'h2: read_mux <= {8'h00, in_dsw2[7:0]};
                        4'h4: read_mux <= {8'h00, in_p1[7:0]};
                        4'h5: read_mux <= {8'h00, in_p2[7:0]};
                        4'h6: read_mux <= {8'h00, in_system_gated[7:0]};
                        default: read_mux <= 16'h0000;
                    endcase
                end
                sel_extra: read_mux <= in_extra;
                sel_drifto_unknown: read_mux <= drifto_unknown_value;
                default:   read_mux <= 16'h0000;
            endcase
        end
    end
end
`ifdef SIMULATION
logic debug_rst_d;
logic debug_mainbus_complete_d;

// Stable device identifiers shared with the MAME adapter.  They describe the
// selected hardware target, not a game name: 0 unmapped, 1 program ROM,
// 2 work RAM, 3 sprite, 4 palette, 5 extension RAM/NVRAM, 6 scroll,
// 7 board/extra I/O, 8 IRQ, 9 ES5506, 10 ST010, 11 random-read window.
always_comb begin
    debug_status = {cpu_halted, video_enable, irq_n, vb, hb, ext_busy,
                    ext_done, renderer_overrun, irq_requested, irq_enabled};
    debug_v60_retire_pc = cpu_retire_pc;
    debug_v60_opcode = cpu_retire_opcode;
    debug_v60_psw = cpu_retire_psw;
    debug_v60_gprs = cpu_gpr_flat;
    debug_mainbus_complete = m_req && ack_r && !ack_r_d;
    debug_mainbus_write = m_we;
    debug_mainbus_addr = a;
    debug_mainbus_data = m_we ? m_wdata : m_rdata;
    debug_mainbus_be = m_be;
    debug_mainbus_device = 8'd0;
    if (sel_rom) debug_mainbus_device = 8'd1;
    else if (sel_wram) debug_mainbus_device = 8'd2;
    else if (sel_sprram) debug_mainbus_device = 8'd3;
    else if (sel_palette) debug_mainbus_device = 8'd4;
    else if (sel_extmem) debug_mainbus_device = 8'd5;
    else if (sel_scroll) debug_mainbus_device = 8'd6;
    else if (sel_io || sel_extra) debug_mainbus_device = 8'd7;
    else if (sel_irqvec || sel_irqack || sel_irqen) debug_mainbus_device = 8'd8;
    else if (sel_sound) debug_mainbus_device = 8'd9;
    else if (sel_st010) debug_mainbus_device = 8'd10;
    else if (sel_drifto_unknown) debug_mainbus_device = 8'd11;
    debug_ifetch_complete = if_req && if_ack;
    debug_ifetch_addr = if_addr;
    debug_ifetch_data = if_data;
    debug_scanline = vcnt;
    debug_hpos = hcnt;
    debug_irq_ack = cpu_irq_ack;
    debug_irq_vector = irq_vector;
    debug_irq_requested = irq_requested;
    debug_irq_enabled = irq_enabled;
    debug_watchdog_kick = wdog_kick;
    debug_watchdog_reset = wdog_rst;
    debug_st010_retire = st010_debug_retire;
    debug_st010_ir = st010_debug_ir;
    debug_st010_pc = st010_debug_pc;
    debug_st010_flaga = st010_debug_flaga;
    debug_st010_flagb = st010_debug_flagb;
    debug_st010_host_access = debug_mainbus_complete && sel_st010;
    debug_st010_fetch_req = st010_prg_req;
    debug_st010_fetch_done = st010_prg_valid;
    debug_st010_prg_addr = st010_prg_addr;
    debug_st010_prg_data = st010_prg_data;
    debug_st010_ram_write = st010_debug_ram_write;
    debug_st010_ram_addr = st010_debug_ram_addr;
    debug_st010_ram_wdata = st010_debug_ram_wdata;
    debug_st010_host_ram_addr = st010_debug_host_ram_addr;
    debug_st010_host_ram_high = st010_debug_host_ram_high;
    debug_st010_host_ram_q = st010_debug_host_ram_q;
    debug_st010_host_ram_dout = st010_debug_host_ram_dout;
    debug_st010_state = st010_debug_state;
    debug_sound_commit = sound_commit;
    debug_sound_page = sound_commit_page;
    debug_sound_reg = sound_commit_reg;
    debug_sound_data = sound_commit_data;
    debug_sound_engine_cr_write = eng_wr_cr;
    debug_sound_engine_voice = eng_voice;
    debug_sound_engine_cr = eng_cr;
    debug_sound_engine_cr_set = eng_cr_set;
    debug_sound_engine_cr_clr = eng_cr_clr;
    debug_sound_engine_fc = eng_fc;
    debug_sound_engine_start = eng_start;
    debug_sound_engine_end = eng_end;
    debug_sound_engine_accum = eng_accum;
    debug_sound_engine_snapshot = eng_snap;
    debug_sound_engine_accum_write = eng_wr_accum;
    debug_sound_engine_accum_w = eng_accum_w;
    debug_sound_irq_promote = eng_irq_set;
    debug_sound_voice_writeback = eng_wr_accum || eng_wr_cr ||
                                  eng_wr_filt || eng_wr_env;
    debug_sound_voice = eng_voice;
    debug_sample_req = sdr_p4_req;
    debug_sample_done = sdr_p4_req && sdr_p4_ack;
    debug_sample_tick = sound_sample_tick;
    debug_sample_underrun = sound_underrun;
    debug_video_enable = video_enable;
    debug_line_boundary = ce_pixel && (hcnt == 9'd0);
    debug_frame_boundary = frame_tick;
end

always_ff @(posedge clk_sys) begin
    debug_rst_d <= rst;
    debug_mainbus_complete_d <= debug_mainbus_complete;
    if (cold_rst) begin
        debug_reset_epoch <= 32'd0;
        debug_frame <= 32'd0;
        debug_mainbus_complete_d <= 1'b0;
    end
    else if (rst && !debug_rst_d) begin
        debug_reset_epoch <= debug_reset_epoch + 1'd1;
    end
    else if (frame_tick) begin
        debug_frame <= debug_frame + 1'd1;
    end

    if (!rst && debug_mainbus_complete) begin
        if (!$onehot0({sel_rom, sel_wram, sel_sprram, sel_palette, sel_extmem,
                       sel_scroll, (sel_io || sel_extra),
                       (sel_irqvec || sel_irqack || sel_irqen), sel_sound,
                       sel_st010, sel_drifto_unknown}))
            $fatal(1, "SSV_OVERLAPPING_SELECT pc=%08x addr=%06x", debug_pc, a);
    end
    if (!rst && sound_underrun)
        $fatal(1, "SSV_SAMPLE_UNDERRUN pc=%08x frame=%0d scanline=%0d",
               debug_pc, debug_reset_epoch, vcnt);
    // The V60 bus adapter holds m_req until its next sparse ce_cpu edge, so
    // the registered level acknowledgement may remain high for several
    // clk_sys cycles.  A duplicate *completion* is an additional rising
    // completion event, not a held level; assert on consecutive completion
    // pulses while preserving the level handshake required by the adapter.
    if (!rst && debug_mainbus_complete && debug_mainbus_complete_d)
        $fatal(1, "SSV_DUPLICATE_ACK pc=%08x addr=%06x", debug_pc, a);
    // The normal acceptance profile keeps this fatal.  The real-ROM audio
    // isolation bench may opt into continuing past a known video-cache
    // deadline so it can inspect ES5506 host writes/sample traffic; that
    // diagnostic does not relax any audio assertion and is never a release
    // verdict.
    // The sticky flag has two independent producers -- a missed per-line
    // renderer deadline and a sprite/tilemap descriptor cache overflow -- and
    // they call for different investigations. Name which one armed it instead
    // of making every reader cross-reference separate CACHE_OVR telemetry.
    if (!rst && renderer_overrun &&
        !$test$plusargs("ALLOW_RENDERER_OVERRUN_DIAGNOSTIC"))
        $fatal(1, "SSV_RENDERER_OWNERSHIP cause=%s pc=%08x frame=%0d scanline=%0d hpos=%0d",
               (overrun_cause_deadline && overrun_cause_cache) ? "deadline+cache" :
               overrun_cause_cache                             ? "cache_overflow" :
               overrun_cause_deadline                          ? "line_deadline"  :
                                                                 "unknown",
               debug_pc, debug_frame, vcnt, hcnt);
end
`endif

endmodule
