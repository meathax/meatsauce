// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  ST010 daughterboard wrapper: uPD96050 + its 2K x 16 data ROM + the exact
//  SSV CPU-side decode for $480000 and $482000-$482fff.
//
//  THE DECODE, DERIVED NOT ASSUMED
//  -------------------------------
//  ssv.cpp:410-411 (drifto94_map) and :769-770 (twineag2_map):
//
//      map(0x480000, 0x480000).rw(m_dsp, upd96050_device::data_r, data_w);
//      map(0x482000, 0x482fff).rw(dsp_r, dsp_w).umask16(0x00ff);
//
//  and ssv.cpp:350-362:
//
//      uint8_t dsp_r(offs_t offset) {
//          uint16_t temp  = m_dsp->dataram_r(offset / 2);
//          uint8_t  shift = BIT(offset, 0) << 3;
//          return (temp >> shift) & 0xff;
//      }
//      void dsp_w(offs_t offset, uint8_t data) {
//          uint8_t shift = BIT(offset, 0) << 3;
//          m_dsp->dataram_w(offset / 2, (uint16_t(data) << 8) | data,
//                           uint16_t(0xff) << shift);
//      }
//
//  `offset` is NOT the CPU byte offset. It is the offset MAME hands an 8-bit
//  handler installed with umask16 on a 16-bit space, and that is one step per
//  bus WORD, not per byte. From memory_units_descriptor (src/emu/emumem_mud.cpp)
//  with Width=1, AddrShift=0, access_width=0, unitmask=0x00ff:
//
//      active_count      = 1                 (one active byte lane)
//      active_count_log  = 0
//      base_shift        = Width - access_width - active_count_log = 1
//      shift             = base_shift + access_width + AddrShift  = 1
//      handler offset    = cpu_addr >> 1  (emumem_heu.cpp:86)
//
//  so, with A the V60 byte address:
//
//      offset   = (A - 0x482000) >> 1  = A[11:1]      range 0x000..0x7FF
//      DSP word = offset >> 1          = A[11:2]      range 0x000..0x3FF
//      high byte when offset[0]        = A[1]
//
//  Two consequences that are easy to get backwards and are what the
//  tb_upd96050_window bench exists to pin down:
//
//    1. The high/low byte of a DSP word is selected by A[1], NOT A[0].
//       A[0] is dropped entirely by the >> 1.
//    2. Only DSP data-RAM words 0x000-0x3FF are reachable from the CPU.
//       The 0x1000-byte window is 2048 handler offsets = 2048 CPU-visible
//       bytes = 1024 DSP words. The upper 1024 words of the 2048-word data
//       RAM are DSP-private. (The Phase 9 spec's "2048 usable bytes" is right;
//       its "word n/2" is only right if n is read as MAME's offset, not as a
//       CPU address.)
//
//  BYTE LANE: unitmask 0x00ff is data bits D7:0. The SSV main CPU is a NEC V60
//  (ssv.cpp:112, :2433) whose program space is ENDIANNESS_LITTLE
//  (v60.cpp:98), so D7:0 is the EVEN byte -- cpu_be[0] in this core, the same
//  lane the ES5506 host port uses. $480000 resolves to the same lane: with a
//  one-byte range MAME reduces the default 0xffff unitmask to emask =
//  make_bitmask((addrend-addrbase+1) << 3) = 0x00ff.
//
//  The duplicated byte plus mask in dsp_w is precisely a byte enable, which is
//  how it is passed through to the data RAM's port B.
//============================================================================

`timescale 1ns/1ps

module upd96050_st010 (
    input               clk,
    input               rst,       // cold/download reset: clear all state/RAM
    input               soft_rst,  // watchdog /RESET: MAME-retained state
    // Instruction-issue enable for the DSP. On SSV, drive from a fractional
    // accumulator with increment 3391 off clk_sys (48.324 MHz) for the
    // 2.5 MIPS MAME models at its (self-flagged "TODO: correct?") 10 MHz.
    input               ce_dsp,

    //------------------------------------------------------------------------
    // V60 bus. Strobes are expected one-shot per bus cycle, i.e. qualified
    // with `!ack_r` exactly as ssv_core does for sound_host_we/sound_host_re.
    // cpu_rdata for the $482000 window is valid one clk after cpu_addr is
    // stable, so the integrator must insert one wait state there (the
    // sound_rd_cnt pattern); the $480000 byte is combinational.
    //------------------------------------------------------------------------
    input        [23:1] cpu_addr,
    input         [1:0] cpu_be,
    input               cpu_we,          // 1-clk write strobe
    input               cpu_re,          // 1-clk read strobe
    input        [15:0] cpu_wdata,
    output       [15:0] cpu_rdata,
    output              cpu_sel,         // this module owns the cycle

    //------------------------------------------------------------------------
    // Program memory, 16384 x 24. MAME builds this from st010.bin bytes
    // 0x00000-0x0ffff as a 32-bit big-endian region (ssv.cpp ROM_COPY into
    // "dspprg") and fetches read_dword(pc) >> 8, so:
    //     prg_data = { rom[4*pc+0], rom[4*pc+1], rom[4*pc+2] }
    // and rom[4*pc+3] is never used.
    // NOT provided here: 16K x 24 = 393,216 bits = 48 M10K minimum on
    // Cyclone V, against 43 free. Back this with SDRAM and a small cache.
    //------------------------------------------------------------------------
    output       [13:0] prg_addr,
    output              prg_req,
    input        [23:0] prg_data,
    input               prg_valid,

    //------------------------------------------------------------------------
    // Data ROM load port. st010.bin bytes 0x10000-0x10fff, 16-bit big-endian
    // ("dspdata", ssv.cpp ROM_COPY), 2048 words. 4 M10K.
    //------------------------------------------------------------------------
    input               drom_we,
    input        [10:0] drom_wa,
    input        [15:0] drom_wd,

    input               int_req,
    output              p0,
    output              p1
`ifdef SIMULATION
    ,
    // Simulation-only verification taps; omitted from the release wrapper.
    output              dbg_retire,
    output       [23:0] dbg_ir,
    output       [13:0] dbg_pc,
    output       [15:0] dbg_a,
    output       [15:0] dbg_b,
    output        [5:0] dbg_flaga,
    output        [5:0] dbg_flagb,
    output       [15:0] dbg_dp,
    output       [15:0] dbg_dr,
    output       [15:0] dbg_sr,
    output       [15:0] dbg_k,
    output       [15:0] dbg_l,
    output       [15:0] dbg_m,
    output       [15:0] dbg_n,
    output              dbg_ram_write,
    output       [10:0] dbg_ram_addr,
    output       [15:0] dbg_ram_wdata,
    output       [10:0] dbg_host_ram_addr,
    output              dbg_host_ram_high,
    output       [15:0] dbg_host_ram_q,
    output        [7:0] dbg_host_ram_dout,
    output        [2:0] dbg_state
`endif
);

//==========================================================================
// Decode
//==========================================================================
// $480000 is a single even byte on D7:0.
wire sel_dport = (cpu_addr == 23'h240000) && cpu_be[0];
// $482000-$482fff.
wire sel_win   = (cpu_addr[23:12] == 12'h482);
wire sel_win_b = sel_win && cpu_be[0];

assign cpu_sel = sel_dport || sel_win;

wire [10:0] win_word = {1'b0, cpu_addr[11:2]};   // offset >> 1
wire        win_high = cpu_addr[1];              // BIT(offset, 0)

wire [7:0] dp_dout;
wire [7:0] win_dout;

// data_r and data_w are NOT idempotent -- each one flips DRS and can clear
// RQM -- so a bus strobe that happens to stay high for more than one clk must
// not be applied twice. Edge-detecting here means the integrator can hand this
// module either a one-shot strobe or a level held for the whole bus cycle.
// (Data-RAM window writes are idempotent and need no such guard.)
logic dp_rd_q, dp_wr_q;
wire  dp_rd_lvl = cpu_re && sel_dport;
wire  dp_wr_lvl = cpu_we && sel_dport;
always_ff @(posedge clk) begin
    if (rst || soft_rst) begin
        dp_rd_q <= 1'b0;
        dp_wr_q <= 1'b0;
    end
    else begin
        dp_rd_q <= dp_rd_lvl;
        dp_wr_q <= dp_wr_lvl;
    end
end
wire dp_rd_pulse = dp_rd_lvl && !dp_rd_q;
wire dp_wr_pulse = dp_wr_lvl && !dp_wr_q;

// MAME's address_space unmapped read value defaults to 0, so a word read that
// straddles the mapped low byte returns 0 in the high byte.
wire sel_dport_any = (cpu_addr == 23'h240000);
assign cpu_rdata = sel_dport_any ? {8'h00, dp_dout}
                 : sel_win       ? {8'h00, win_dout}
                                 : 16'h0000;

//==========================================================================
// Data ROM: 2048 x 16, loader on port A, DSP on port B.
//==========================================================================
wire [11:0] drom_addr;
wire [15:0] drom_q;
logic       drom_hi_q;

s32_big_dpram #(
    .ADDR_WIDTH(11), .DATA_WIDTH(16), .BE_WIDTH(2), .NUM_WORDS(2048)
) datarom (
    .clock_a(clk),
    .address_a(drom_wa),
    .data_a(drom_wd),
    .byteena_a(2'b11),
    .wren_a(drom_we),
    .q_a(),

    .clock_b(clk),
    .address_b(drom_addr[10:0]),
    .data_b(16'h0000),
    .byteena_b(2'b00),
    .wren_b(1'b0),
    .q_b(drom_q)
);

// ssv.cpp:346 maps only 0x000-0x7ff of the DSP's 12-bit data space, so the
// upper half reads as MAME's unmapped value, 0.
always_ff @(posedge clk) drom_hi_q <= drom_addr[11];
wire [15:0] drom_data = drom_hi_q ? 16'h0000 : drom_q;

//==========================================================================
upd96050 dsp (
    .clk(clk), .ce(ce_dsp), .rst(rst), .soft_rst(soft_rst),

    .prg_addr(prg_addr), .prg_req(prg_req),
    .prg_data(prg_data), .prg_valid(prg_valid),

    .drom_addr(drom_addr), .drom_data(drom_data),

    .host_dp_rd(dp_rd_pulse),
    .host_dp_wr(dp_wr_pulse),
    .host_dp_din(cpu_wdata[7:0]),
    .host_dp_dout(dp_dout),
    .host_sr(),

    .host_ram_addr(win_word),
    .host_ram_high(win_high),
    .host_ram_wr(cpu_we && sel_win_b),
    .host_ram_din(cpu_wdata[7:0]),
    .host_ram_dout(win_dout),

    .int_req(int_req), .p0(p0), .p1(p1)
`ifdef SIMULATION
    ,
    .dbg_retire(dbg_retire), .dbg_ir(dbg_ir), .dbg_pc(dbg_pc),
    .dbg_a(dbg_a), .dbg_b(dbg_b),
    .dbg_flaga(dbg_flaga), .dbg_flagb(dbg_flagb),
    .dbg_k(dbg_k), .dbg_l(dbg_l), .dbg_m(dbg_m), .dbg_n(dbg_n),
    .dbg_dp(dbg_dp), .dbg_rp(), .dbg_tr(), .dbg_trb(),
    .dbg_dr(dbg_dr), .dbg_sr(dbg_sr), .dbg_so(), .dbg_idb(), .dbg_sp(),
    .dbg_ram_write(dbg_ram_write), .dbg_ram_addr(dbg_ram_addr),
    .dbg_ram_wdata(dbg_ram_wdata), .dbg_host_ram_addr(dbg_host_ram_addr),
    .dbg_host_ram_high(dbg_host_ram_high), .dbg_host_ram_q(dbg_host_ram_q),
    .dbg_host_ram_dout(dbg_host_ram_dout), .dbg_state(dbg_state)
`endif
);

endmodule
