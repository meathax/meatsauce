// -----------------------------------------------------------------------------
// smashtv_vram.sv
//
// Midway Y-Unit frame buffer: 512 x 512 pixels, one 16-bit word per pixel,
// exactly MAME's m_local_videoram (williams/midyunit_v.cpp, 0x80000/2 =
// 262,144 uint16). The low byte of each word is the pixel/color byte (6 bpp
// used by Smash T.V.); the high byte is the palette-select byte. Rows 510/511
// are the autoerase source lines, not display lines.
//
// Three ports, matching how the real hardware touches the frame buffer:
//
//   CPU  (bank/mask semantics) — vram_w / vram_r. The CPU writes through the
//        Y-Unit bank select (CONTROL bit 5) and the blitter's DMA_PALETTE
//        register merges into the palette byte, per MAME vram_w. Word offset
//        granular with byte lane masks. Read latency 0 (registered elsewhere).
//
//   RANDOM (linear pixel) — CPU and U77 share one acknowledged logical port.
//
//   SCAN (linear pixel read) — the video timing generator reads a pixel word by
//        linear index for pen_map + palette lookup.
//
// Storage is true-dual-port M10K, interleaved across 16 banks on the low bits
// of the pixel index (smashtv_vram_array, bottom of this file). Y-unit packs 12
// live pen bits; Z-unit packs the 13 live pen bits as an 8+5 split per bank so
// Quartus does not emit a wasteful 8192x1 bit-plane. Total stored bits and the
// M10K cost are unchanged by the interleave -- each bank is still 16384 words
// deep, so a stored bit costs 2 blocks per bank x 16 banks = the same 32 it
// cost as one 262144-deep array (doc/EVALUATION.md).
// Two-pixel words were evaluated and rejected: 131072x26 maps to ~512 M10K.
//
// The pen_map decode (6 bpp) and palette live in the video stage, not here.
//
// Verified by sim/vram_check/tb_vram.sv against a MAME-derived reference model.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_vram #(
  // NARC's 8bpp Z-unit pen is the low 13 bits of each VRAM word. The default
  // remains the measured 12-live-bit Y-unit packing.
  parameter bit ZUNIT_8BPP = 1'b0,
  // Raw display blanking edges. The Z-unit port-B scheduler uses horizontal
  // blanking plus one safe slot in each 2-of-3 pixel-enable group for erase.
  parameter int HEBLNK = ZUNIT_8BPP ? 122 : 90,
  parameter int HSBLNK = ZUNIT_8BPP ? 634 : 500
) (
  input  wire        clk,
  // Game/CPU reset. Clears the CPU access FSM and autoerase engines so a mid-
  // access reset cannot leave cst != IDLE (which would ignore the next cpu_req
  // forever and hang the 34010 on the VRAM window).
  input  wire        rst,

  // --- CPU port: byte-granular multi-pixel access (MAME vram_w / vram_r) -----
  // The 34010 accesses VRAM as a byte-per-pixel, bank-selected plane. A field
  // access covers 1..4 consecutive pixel bytes (size 8/16/24/32, byte-aligned);
  // each pixel is a separate 16-bit VRAM word, so the engine walks them one per
  // cycle and pulses cpu_ready when done. bank=1 = pixel plane (low byte from
  // data, high byte from DMA_PALETTE), bank=0 = palette plane (high byte).
  input  wire        cpu_req,        // level: a CPU VRAM access is pending
  input  wire        cpu_we,
  // DPYCTL.SRT: a PIXT read loads the TMS34010's 2-line (1024-word) shift
  // register and a PIXT write stores that snapshot. NARC uses paired read/write
  // cycles to scroll the score table.
  input  wire        cpu_srt,
  input  wire [17:0] cpu_pbase,      // first pixel index = bit_addr >> 3
  input  wire [2:0]  cpu_nbytes,     // 1..4 (= size >> 3)
  input  wire [31:0] cpu_wdata,      // up to 4 data bytes, little-endian
  input  wire        bank_select,    // CONTROL bit 5 (m_videobank_select)
  input  wire [15:0] dma_palette,    // blitter DMA_PALETTE register
  output reg  [31:0] cpu_rdata,
  output reg         cpu_ready,      // 1-cycle pulse when the access completes

  // --- Blitter port: linear pixel write -------------------------------------
  input  wire        blit_we,
  input  wire [17:0] blit_idx,       // pixel index (ty*512 + tx), 0..262143
  input  wire [15:0] blit_pixel,
  output wire        blit_ready,

  // --- Serial scanout port --------------------------------------------------
  // scan_idx still carries the TMS34010 DPYADR/DPYTAP/ORG mapping, but Z-unit
  // pixels are served from a row buffer loaded through a TMS4461-style transfer
  // during horizontal blank. Scanout never consumes a logical random-port
  // transaction. Y-unit retains the legacy direct port-B path for now.
  input  wire [17:0] scan_idx,
  output wire [15:0] scan_pixel,

  // --- Autoerase: copy source line 510/511 into each displayed line, one line
  //     behind scanout, when enabled. Z-unit performs one logical destination
  //     row transfer materialized as 32 sixteen-bank writes; Y-unit retains the
  //     legacy per-pixel scheduler. CPU/U77 same-group lanes are hazard-masked
  //     so newly drawn pixels win without discarding the rest of the group.
  //     `ae_erase_line` is the display line to clear; src = line 510 + (line&1).
  input  wire        ce_pix,         // pixel-clock enable (phase ref for port B)
  // Live video HCOUNT (same domain as scanout). Z-unit port-B safe windows are
  // defined in HEBLNK/HSBLNK space; never derive them from erase triggers.
  input  wire [9:0]  hcount,
  input  wire        ae_en,          // autoerase enabled (CONTROL bit4 active-low)
  input  wire        ae_vblank,      // high during vblank -> (re)fill the src cache
  input  wire        ae_erase_trig,  // 1-cycle: begin erasing ae_erase_line
  input  wire [8:0]  ae_erase_line   // display line to clear (0..255)
);

  // Frame buffer: 262144 pixels of packed live pen bits (Y=12, Z=13). Instantiated
  // via dpram_tdp (altsyncram), not inline-inferred: Quartus 17 rejects the
  // inline true-dual-port pattern ("asynchronous read logic").

  localparam int VRAM_DW = ZUNIT_8BPP ? 13 : 12;

  // --- Bank interleave ------------------------------------------------------
  // The frame buffer is spread over NBANK independently addressed arrays chosen
  // by the low bits of the pixel index, so NBANK consecutive words are reachable
  // in one clock. Ordinary clients still move one word at a time: they drive the
  // shared row address plus a one-hot bank enable and read back through a
  // registered NBANK:1 output mux. Only the shift-register transfer uses the
  // full width.
  //
  // NBANK=16 (not 8) because the transfer keeps to port A: a read cycle and a
  // write cycle per group is NBANK/2 words per clock, and the >= 5.13 words/clk
  // budget in doc/SYMPTOM2_SCOREBOARD_FLICKER.md needs NBANK >= 11. Eight banks
  // would reach 8 words/clk only by writing through port B, which is the live
  // scanout port.
  localparam int NBANK = 16;
  localparam int BSEL  = 4;              // $clog2(NBANK)
  localparam int RW    = 18 - BSEL;      // 14 -> 16384 words per bank
  localparam int SRT_GROUPS = 1024 / NBANK;   // 64 groups per transfer

  // Y: pen={w[15:14],w[11:8],w[5:0]}; Z: pen=w[12:0].
  function automatic [VRAM_DW-1:0] pack16(input [15:0] w);
    if (ZUNIT_8BPP) pack16 = w[12:0];
    else            pack16 = VRAM_DW'({w[15:14], w[11:8], w[5:0]});
  endfunction
  function automatic [15:0] unpack_pixel(input [VRAM_DW-1:0] p);
    logic [12:0] p13;
    p13 = 13'd0;
    p13[VRAM_DW-1:0] = p;
    if (ZUNIT_8BPP) unpack_pixel = {3'b000, p13[12:0]};
    else            unpack_pixel = {p13[11:10], 2'b00, p13[9:6], 2'b00, p13[5:0]};
  endfunction

  // For a pixel at absolute index P, the palette (high) byte on a bank-1 write
  // comes from DMA_PALETTE: even P -> dma_palette[7:0], odd P -> dma_palette
  // [15:8] (MAME writes `DMA_PALETTE << 8` to the even pixel and
  // `DMA_PALETTE & 0xff00` to the odd one).
  function automatic [7:0] pal_hi(input [17:0] p);
    pal_hi = p[0] ? dma_palette[15:8] : dma_palette[7:0];
  endfunction

  // --- Two-port block RAM ---------------------------------------------------
  // Port A: single address, read/write, shared by the CPU engine and the
  //         blitter (blitter has priority; the CPU engine stalls on its cycles).
  // Port B: scanout read.
  // This is exactly a true-dual-port M10K; the earlier 4-access-pattern version
  // could not infer as block RAM and blew synthesis memory.
  wire  [17:0] a_addr;
  logic [17:0] a_addr_logical;
  logic a_we;
  logic [VRAM_DW-1:0] a_din;
  assign a_addr = a_addr_logical;
  wire  [VRAM_DW-1:0] q_a;
  wire [12:0] q_a13 = {{(13-VRAM_DW){1'b0}}, q_a};
  // Port A = CPU/blitter R/W; port B = scanout / autoerase. Unpack is applied
  // combinationally AFTER the registered M10K read (never inline in the array
  // read, or Quartus reports "asynchronous read logic" and abandons BRAM).
  wire [VRAM_DW-1:0] q_b;
  // --- Port B scheduler -----------------------------------------------------
  // Y-unit still shares port B between direct scanout and auxiliary traffic.
  // Z-unit uses port B only for explicit row transfers and autoerase/cache
  // work; the serial pixel stream below is independent of this port.
  logic [1:0] ph = 2'd0;
  always_ff @(posedge clk) begin
    ph <= ce_pix ? 2'd1 : (ph == 2'd2 ? 2'd0 : ph + 2'd1);
  end

  // TMS4461 serial-port abstraction. The physical board transfers the complete
  // row in one special DRAM cycle. Cyclone-V BRAM cannot expose 512 words at
  // once, so the implementation reads 16 interleaved banks per internal clock:
  // 32 transfers complete comfortably inside NARC's 122-pixel left blank.
  // The logical operation is still one row transfer; no CPU/blitter random-port
  // slot is consumed and the visible scanner touches only serial_line.
  (* ramstyle = "MLAB, no_rw_check" *) logic [VRAM_DW-1:0] serial_line [0:511];
  logic [VRAM_DW-1:0] serial_q;
  logic [9:0] scan_hcount_q = 10'h3ff;
  logic scan_fetch_active = 1'b0;
  logic scan_fetch_cap = 1'b0;
  logic [8:0] scan_fetch_row = 9'd0;
  logic [4:0] scan_fetch_group = 5'd0;
  logic [4:0] scan_fetch_cap_group = 5'd0;
  wire scan_line_start = ZUNIT_8BPP && ce_pix && (hcount == 10'd0) &&
                         (scan_hcount_q != 10'd0);

  always_ff @(posedge clk) begin
    scan_hcount_q <= hcount;
    serial_q <= serial_line[scan_idx[8:0]];
    if (rst) begin
      scan_fetch_active <= 1'b0;
      scan_fetch_cap <= 1'b0;
      scan_fetch_row <= 9'd0;
      scan_fetch_group <= 5'd0;
      scan_fetch_cap_group <= 5'd0;
    end else begin
      scan_fetch_cap <= scan_fetch_active;
      scan_fetch_cap_group <= scan_fetch_group;
      if (scan_line_start) begin
        scan_fetch_active <= 1'b1;
        scan_fetch_row <= scan_idx[17:9];
        scan_fetch_group <= 5'd0;
        scan_fetch_cap <= 1'b0;
      end else if (scan_fetch_active) begin
        if (scan_fetch_group == 5'd31)
          scan_fetch_active <= 1'b0;
        else
          scan_fetch_group <= scan_fetch_group + 5'd1;
      end
      if (scan_fetch_cap) begin
        for (int sk = 0; sk < NBANK; sk++)
          serial_line[{scan_fetch_cap_group, 4'(sk)}] <=
              pb_q_bus[sk*VRAM_DW +: VRAM_DW];
      end
    end
  end

  // fill/erase state (engines below). Power-up initializers (honored by Quartus
  // for Cyclone V FFs and by simulation) give these a defined 0 start -- without
  // them the trigger gate `!erase_active` sees X and can never resolve in sim,
  // and hardware would rely on implicit power-up state.
  logic [17:0] ae_fill_baddr;
  logic        ae_filling;
  logic        erase_active = 1'b0;
  logic [8:0]  erase_line;
  logic [8:0]  erase_goal_line = 9'd0;
  logic [9:0]  erase_col;
  logic        erase_a_slot;
  // One scan line of auto-erase source pixels. Keeping this small, sequential
  // cache in MLABs leaves scarce M10Ks available for the 13-bit frame buffer.
  (* ramstyle = "MLAB, no_rw_check" *) logic [VRAM_DW-1:0] ae_cache [0:1023];
  logic        esrc_rdy = 1'b0;   // esrc_r has been loaded for the first column
  wire  [17:0] ae_dest_addr = {erase_line, 9'd0} + {9'd0, erase_col[8:0]};
  wire y_scan_slot = (ph == 2'd2);
  wire fill_slot = ae_filling &&
                   !scan_fetch_active &&
                   (ZUNIT_8BPP ? 1'b1 : (ph == 2'd0));
  // esrc_rdy holds the very first write of each line off by one cycle so esrc_r
  // (loaded at the trigger edge) is settled before it is consumed.
  // erase_b_slot is a scheduled erase opportunity. erase_slot below is the
  // subset that actually reaches port B after same-address arbitration.
  wire erase_b_slot = erase_active && esrc_rdy && !fill_slot &&
                      !scan_fetch_active &&
                      (erase_line < 9'd510) &&
                      (ZUNIT_8BPP ? 1'b1 : !y_scan_slot);
  wire erase_slot;
  wire erase_step;

  // Triggers can arrive slightly faster than the conservative Z-unit safe-slot
  // budget. Keep the newest requested line as a goal and erase every intervening
  // line in order; vblank provides ample time to drain the small backlog.
  wire [8:0] erase_goal_effective = (ae_erase_trig && ae_en)
                                          ? ae_erase_line : erase_goal_line;
  wire erase_start = ae_erase_trig && ae_en && !erase_active &&
                     (ae_erase_line < 9'd510);
  // MAME autoerase_line only copies scanline in [0,510). Never walk into the
  // wallpaper source rows 510/511; if the goal wraps below the current line
  // (DPYSTRT reload), snap instead of incrementing through them.
  wire erase_goal_behind = (erase_goal_effective < erase_line);
  wire erase_can_advance = (erase_line != erase_goal_effective) &&
                           (erase_goal_behind || (erase_line < 9'd509));
  wire erase_last_group = ZUNIT_8BPP ? (erase_col >= 10'd496)
                                     : (erase_col == 10'd511);
  wire erase_advance_line = erase_active && erase_step &&
                            erase_last_group &&
                            erase_can_advance;

  // Next-state of erase_col/erase_line (mirrors the always_ff updates below) --
  // used to prefetch the correct src word one cycle ahead into esrc_r.
  wire [9:0] ecol_next  = erase_start ? 10'd0
                        : erase_advance_line ? 10'd0
                        : (erase_active && erase_step && !erase_last_group)
                          ? erase_col + (ZUNIT_8BPP ? 10'd16 : 10'd1)
                          : erase_col;
  wire [8:0] eline_next = erase_start ? ae_erase_line
                        : (erase_advance_line && erase_goal_behind) ? erase_goal_effective
                        : erase_advance_line ? erase_line + 9'd1 : erase_line;

  // The src word for the column being written is PREFETCHED into a register
  // (esrc_r) rather than muxed straight onto the port-B write-data bus. ae_cache
  // is a 1024x12-bit register array, so ae_cache[idx] is a 1024:1 combinational
  // mux; feeding that mux directly into the M10K write-data setup (din_b) was the
  // clk_sys critical path (-0.770 ns -- Quartus cannot register the M10K din
  // behind a mux that deep). esrc_r instead holds ae_cache indexed by ecol_next
  // (the erase column value AFTER this clock edge), so on the NEXT cycle it is
  // exactly the word that cycle's write needs -- no bubble, every erase slot
  // writes (full 2 writes / 3 clocks). The path becomes reg->mux->reg(esrc_r) and
  // din_b is driven straight from the esrc_r register. (ecol_next is defined with
  // the erase engine below.)
  logic [VRAM_DW-1:0] esrc_r;

  wire  [17:0] pb_addr;
  logic [17:0] pb_addr_logical;
  assign pb_addr = pb_addr_logical;
  logic        pb_we;
  logic [VRAM_DW-1:0] pb_din;
  always_comb begin
    pb_we  = 1'b0; pb_din = esrc_r; pb_addr_logical = scan_idx;
    if      (fill_slot)  begin pb_addr_logical = ae_fill_baddr; end
    else if (erase_slot) begin pb_addr_logical = ae_dest_addr; pb_we = 1'b1; end
  end

  // Storage: NBANK banks, each 16384 words deep, held in smashtv_vram_array
  // (bottom of this file). In simulation that module keeps ONE flat,
  // linear-indexed behavioral array named `mem`, so every hierarchical peek
  // (`*.u_vram.mem[y*512+x]`) keeps its exact meaning; the banked port
  // structure is modelled around it, address for address. Define
  // NARC_SIM_SYNTH_VRAM_LAYOUT to exercise the altsyncram geometry instead.
  //
  // Each bank keeps the same 8+5 plane split synthesis already used, so the
  // block cost is unchanged: at 16384 words a stored bit costs
  // ceil(16384/8192) = 2 M10Ks, versus 32 at 262144, and there are 16 banks
  // instead of 1 -- 2*8*16 = 256 for the low plane and 2*5*16 = 160 for the
  // high plane, the same 416 as before. Splitting deeper than 32 banks would
  // start to round up and is not free.
  logic [RW-1:0]            pa_row;
  logic [NBANK-1:0]         pa_we_bank;
  logic [NBANK*VRAM_DW-1:0] pa_din_bus;
  wire  [NBANK*VRAM_DW-1:0] pa_q_bus;
  logic [RW-1:0]            pb_row;
  logic [NBANK-1:0]         pb_we_bank;
  logic [NBANK*VRAM_DW-1:0] pb_din_bus;
  wire  [NBANK*VRAM_DW-1:0] pb_q_bus;

  smashtv_vram_array #(
    .DW(VRAM_DW), .SPLIT(ZUNIT_8BPP), .NBANK(NBANK), .RW(RW)
  ) u_vram (
    .clk  (clk),
    .a_row(pa_row), .a_we(pa_we_bank), .a_din(pa_din_bus), .a_q(pa_q_bus),
    .b_row(pb_row), .b_we(pb_we_bank), .b_din(pb_din_bus), .b_q(pb_q_bus)
  );

  // Single-word view of each port. The bank select is registered alongside the
  // array's own address register so q_a/q_b keep the existing 1-clock read
  // latency and the existing write-first read-during-write on a port.
  logic [BSEL-1:0] a_bank_q, b_bank_q;
  always_ff @(posedge clk) begin
    a_bank_q <= a_addr[BSEL-1:0];
    b_bank_q <= pb_addr[BSEL-1:0];
  end
  // Explicit constant-slice bank muxes. Functionally IDENTICAL to
  //   assign q_b = pb_q_bus[b_bank_q*VRAM_DW +: VRAM_DW];
  // but that form is a dynamic part-select whose base is a signal times a
  // NON-power-of-two constant (x13) over a 208-bit bus, and it is the prime
  // suspect for a Quartus 17 miscompile seen only on silicon: the shipped
  // 20260801 build scanned out every pixel column DOUBLED (native capture:
  // 100.00% even/odd column pairing, zero 1-px features, whole frame), while
  // the identical RTL is pixel-exact in simulation and the fitted RAMs are
  // confirmed unregistered-output (fit.rpt RAM Summary: Output Regs "no").
  // The CPU byte engine has shipped variable-base selects for weeks, but with
  // x8 strides -- powers of two compile to shifts; x13 needs a real multiply
  // in the select base, which only these two lines used. Note the same
  // expression on port A passes the boot VRAM march, so if the tool is at
  // fault it is instance-specific -- rewriting BOTH removes the construct
  // everywhere. The unrolled loop below produces constant slices after
  // elaboration and synthesizes as a plain 16:1 mux.
  logic [VRAM_DW-1:0] qa_mux, qb_mux;
  always_comb begin
    qa_mux = pa_q_bus[0 +: VRAM_DW];
    qb_mux = pb_q_bus[0 +: VRAM_DW];
    for (int k = 1; k < NBANK; k++) begin
      if (a_bank_q == BSEL'(k)) qa_mux = pa_q_bus[k*VRAM_DW +: VRAM_DW];
      if (b_bank_q == BSEL'(k)) qb_mux = pb_q_bus[k*VRAM_DW +: VRAM_DW];
    end
  end
  assign q_a = qa_mux;
  assign q_b = qb_mux;

  // (The port-A physical drive lives below the port-A arbiter, which is where
  // a_addr/a_we/a_din and the transfer state it selects on are defined.)

  // Z-unit row transfer gets first use of port B. It reads all 16 banks at a
  // shared row address; ordinary autoerase/cache operations remain one word.
  always_comb begin
    if (ZUNIT_8BPP && scan_fetch_active) begin
      pb_row = {scan_fetch_row, scan_fetch_group};
      pb_we_bank = '0;
      pb_din_bus = '0;
    end else if (ZUNIT_8BPP && erase_slot) begin
      // One logical TMS4461 destination-row transfer, materialized as 32
      // writes across the 16 interleaved FPGA banks. If port A draws into the
      // same group, mask only its lanes so the new pixel wins while the other
      // fifteen background pixels still transfer.
      pb_row = {erase_line, erase_col[8:4]};
      pb_we_bank = '1;
      pb_din_bus = '0;
      for (int ek = 0; ek < NBANK; ek++)
        pb_din_bus[ek*VRAM_DW +: VRAM_DW] =
            ae_cache[{erase_line[0], erase_col[8:4], 4'(ek)}];
      if (pa_row == {erase_line, erase_col[8:4]})
        pb_we_bank = pb_we_bank & ~pa_we_bank;
    end else begin
      pb_row     = pb_addr[17:BSEL];
      pb_we_bank = '0;
      pb_din_bus = {NBANK{pb_din}};
      if (pb_we) pb_we_bank[pb_addr[BSEL-1:0]] = 1'b1;
    end
  end

  assign scan_pixel = unpack_pixel(ZUNIT_8BPP ? serial_q : q_b);

  // --- CPU access engine: per byte, present address (read) then act ---------
  // SRT load/store. On the board the shift register lives inside the TMS4461s
  // and a transfer cycle moves a whole row in parallel, so a PIXT with
  // DPYCTL.SRT set costs one memory cycle. We cannot copy 1024 words in a clock
  // out of M10K, but we can avoid paying for transfers that move no data:
  //
  //   NARC.ASM DIRQ1 issues `CLR A1; PIXT *A1,A2` once per display interrupt
  //   purely to poke the DMA ("SHIFT REGISTER READ TO RESTART DMA"). A2 is
  //   never used. Eagerly snapshotting 1024 words for it burned 1026 clocks of
  //   port A on every display interrupt -- 912 times in an 1800-frame run.
  //
  // So a load records the source row and returns word 0 (all a PIXT read can
  // yield); the row is only walked when a store actually follows, as it does in
  // the scroll driver at NARC.ASM:2517.
  //
  // A store used to snapshot the whole source row into a 1024-word cache before
  // writing any of it, because "source and destination rows are only a
  // scroll-delta apart, so a read/write interleave would clobber source words
  // before reading them". That is an ORDERING problem, not a storage problem:
  // copy ascending when dst < src and descending when dst > src -- what memmove
  // does -- and no source word is ever written before it has been read. The
  // cache is gone with it, and so are its two M10Ks and its second 1024-clock
  // pass.
  //
  // The transfer runs over the bank interleave: C_SRT_G_RD reads a whole
  // NBANK-word group in one clock, C_SRT_G_WR writes it in the next, so a
  // 1024-word transfer costs SRT_GROUPS*2 + setup ~= 129 clocks instead of
  // 2051. Both bases are 16-word aligned in every SRT NARC issues (the scroll
  // driver steps by 0x2000 bit addresses = 1024 words from a row base), which
  // is what lets whole groups be moved with no rotation and no partial-group
  // masking. A misaligned base falls back to the single-word path below, which
  // is correct at the same ~2050 clocks the old two-pass copy cost.
  typedef enum logic [3:0] {
    C_IDLE, C_ADDR, C_ACT, C_DONE,
    C_SRT_RD_ADDR, C_SRT_RD_CAP,
    C_SRT_WR_ADDR, C_SRT_G_RD, C_SRT_G_WR, C_SRT_W_RD, C_SRT_W_WR
  } cstate_t;
  cstate_t   cst = C_IDLE;
  logic [2:0]  cidx;
  logic [31:0] rd_acc;
  logic [17:0] cp;
  logic [17:0] srt_src_base;
  logic [17:0] srt_dst_base;
  logic [9:0]  srt_idx;
  wire  [7:0]  wbyte = cpu_wdata[cidx*8 +: 8];

  // Wide path is usable only when both ends sit on a bank boundary, so every
  // one of the 1024 words falls in a whole group.
`ifdef SMASHTV_VRAM_SRT_FORCE_SLOW
  wire srt_fast = 1'b0;      // regression hook: exercise the fallback copy
`else
  wire srt_fast = (srt_src_base[BSEL-1:0] == '0) &&
                  (srt_dst_base[BSEL-1:0] == '0);
`endif
  // Overlap direction. dst above src must be copied from the top down.
  wire srt_down = (srt_dst_base > srt_src_base);

  wire srt_group_rd = (cst == C_SRT_G_RD);
  wire srt_group_wr = (cst == C_SRT_G_WR);
  wire [RW-1:0] srt_grp = {{(RW-6){1'b0}}, srt_idx[5:0]};
  wire [RW-1:0] srt_rd_row = srt_src_base[17:BSEL] + srt_grp;
  wire [RW-1:0] srt_wr_row = srt_dst_base[17:BSEL] + srt_grp;
  wire srt_grp_last = srt_down ? (srt_idx[5:0] == 6'd0)
                               : (srt_idx[5:0] == 6'(SRT_GROUPS-1));
  wire srt_word_last = srt_down ? (srt_idx == 10'd0) : (srt_idx == 10'd1023);

  // CPU-side port-A drive (combinational); muxed with the blitter below.
  logic [17:0] cpu_a_addr; logic cpu_a_we;
  logic [VRAM_DW-1:0] cpu_a_din;
  always_comb begin
    cpu_a_addr = cp; cpu_a_we = 1'b0; cpu_a_din = '0;
    if (cst == C_SRT_RD_ADDR || cst == C_SRT_WR_ADDR) begin
      cpu_a_addr = srt_src_base;
    end else if (cst == C_SRT_G_RD || cst == C_SRT_G_WR) begin
      // Address comes from srt_rd_row/srt_wr_row; this only keeps a defined
      // logical address for the same-address collision checks.
      cpu_a_addr = srt_group_wr ? {srt_wr_row, {BSEL{1'b0}}}
                                : {srt_rd_row, {BSEL{1'b0}}};
    end else if (cst == C_SRT_W_RD) begin
      cpu_a_addr = srt_src_base + {8'd0, srt_idx};
    end else if (cst == C_SRT_W_WR) begin
      cpu_a_addr = srt_dst_base + {8'd0, srt_idx};
      cpu_a_we   = 1'b1;
      cpu_a_din  = q_a;                  // word read on the previous clock
    end else if (cst == C_ACT && cpu_we) begin
      cpu_a_we = 1'b1;
      if (bank_select) cpu_a_din = pack16({pal_hi(cp), wbyte});           // pixel plane
      else if (ZUNIT_8BPP)
        cpu_a_din = {wbyte[4:0], q_a13[7:0]};                             // Z palette-plane RMW
      else
        cpu_a_din = VRAM_DW'({wbyte[7:6], wbyte[3:0], q_a[5:0]});         // Y palette-plane RMW
    end
  end

  wire srt_port_active = (cst == C_SRT_RD_ADDR) ||
                         (cst == C_SRT_RD_CAP) ||
                         (cst == C_SRT_WR_ADDR) ||
                         (cst == C_SRT_G_RD) ||
                         (cst == C_SRT_G_WR) ||
                         (cst == C_SRT_W_RD) ||
                         (cst == C_SRT_W_WR);

  // U77 and the CPU share one logical random port. A newly accepted SRT owns
  // that port atomically beginning on this edge, so DMA must hold its pixel.
  assign blit_ready = !srt_port_active &&
                      !((cst == C_IDLE) && cpu_req && cpu_srt);

  // Legacy Y-unit only: supplement the per-pixel port-B scheduler through an
  // otherwise-idle port-A cycle. Z-unit autoerase is a wide row transfer and
  // never uses this path.
  always_comb begin
    erase_a_slot = !ZUNIT_8BPP && erase_active && esrc_rdy && !erase_b_slot &&
                   (erase_line < 9'd510) && !srt_port_active &&
                   (cst == C_IDLE) && !cpu_req && !blit_we;
  end

  // Port-A arbitration: an in-flight SRT transfer is atomic, then blitter,
  // then ordinary CPU traffic.  The physical shift-register cycle is atomic
  // too; allowing a blit between its source read and destination write would
  // corrupt the scrolling bitmap.
  always_comb begin
    if (srt_port_active) begin a_addr_logical = cpu_a_addr;  a_we = cpu_a_we; a_din = cpu_a_din; end
    else if (blit_we)    begin a_addr_logical = blit_idx;    a_we = 1'b1;     a_din = pack16(blit_pixel); end
    else if (erase_a_slot) begin a_addr_logical = ae_dest_addr; a_we = 1'b1; a_din = esrc_r; end
    else                 begin a_addr_logical = cpu_a_addr;  a_we = cpu_a_we; a_din = cpu_a_din; end
  end

  // Port A physical drive. Every state except the wide shift-register transfer
  // presents one word: shared row, one-hot bank enable, data broadcast.
  always_comb begin
    if (srt_group_rd) begin
      pa_row     = srt_rd_row;
      pa_we_bank = '0;
      pa_din_bus = pa_q_bus;
    end else if (srt_group_wr) begin
      // The whole group is written straight from the previous cycle's read.
      // Registered array output to registered array input -- exactly the path
      // the old srt_cache drain already used, just NBANK words wide.
      pa_row     = srt_wr_row;
      pa_we_bank = '1;
      pa_din_bus = pa_q_bus;
    end else begin
      pa_row     = a_addr[17:BSEL];
      pa_we_bank = '0;
      pa_din_bus = {NBANK{a_din}};
      if (a_we) pa_we_bank[a_addr[BSEL-1:0]] = 1'b1;
    end
  end

  // A functional CPU/SRT/blitter write wins a same-address collision with the
  // background erase. Suppress the undefined dual-port double write, but count
  // the erase slot as consumed so it cannot retry later and overwrite the newly
  // drawn pixel. Tested against the physical bank enables, so a wide
  // shift-register group write covers all NBANK words it commits.
  wire erase_b_collision = erase_b_slot &&
                           (pa_row == ae_dest_addr[17:BSEL]) &&
                           pa_we_bank[ae_dest_addr[BSEL-1:0]];
  assign erase_slot = erase_b_slot && (ZUNIT_8BPP || !erase_b_collision);
  assign erase_step = erase_b_slot || erase_a_slot;

`ifdef VERILATOR
  always_ff @(posedge clk) begin
    if (!rst)
      assert (!((pa_row == pb_row) && ((pa_we_bank & pb_we_bank) != '0)))
        else $fatal(1, "VRAM same-address dual-port write collision row %04x banks %04x",
                    pa_row, pa_we_bank & pb_we_bank);
  end
`endif

  always_ff @(posedge clk) begin
    cpu_ready <= 1'b0;
    if (rst) begin
      cst <= C_IDLE;
      cidx <= 3'd0;
      rd_acc <= 32'h0;
      cp <= 18'd0;
      srt_src_base <= 18'd0;
      srt_dst_base <= 18'd0;
      srt_idx <= 10'd0;
      cpu_rdata <= 32'h0;
    end else begin
      // The CPU engine only advances on cycles it owns port A (blitter idle).
      case (cst)
        C_IDLE: if (cpu_req) begin
          if (cpu_srt) begin
            if (cpu_we) begin
              srt_dst_base <= cpu_pbase;
              srt_idx <= 10'd0;
              cst <= C_SRT_WR_ADDR;
            end else begin
              srt_src_base <= cpu_pbase;
              srt_idx <= 10'd0;
              cst <= C_SRT_RD_ADDR;
            end
          end else begin
            cidx <= 3'd0; rd_acc <= 32'h0; cp <= cpu_pbase; cst <= C_ADDR;
          end
        end
        C_ADDR: if (!blit_we) cst <= C_ACT;                 // read presented this cycle
        // If the blitter steals port A during C_ACT, q_a is the blit location
        // (write-first BRAM). Re-present cp via C_ADDR rather than RMW/reading
        // with a stale q_a once the blitter releases.
        C_ACT:  if (blit_we) cst <= C_ADDR;
                else begin
                  if (!cpu_we)
                    if (ZUNIT_8BPP)
                      rd_acc[cidx*8 +: 8] <= bank_select ? q_a13[7:0]
                                                         : {3'b000, q_a13[12:8]};
                    else
                      rd_acc[cidx*8 +: 8] <= bank_select ? {2'b00, q_a[5:0]}
                                                         : {q_a[11:10], 2'b00, q_a[9:6]};
                  if (cidx + 3'd1 >= cpu_nbytes) cst <= C_DONE;
                  else begin cidx <= cidx + 3'd1; cp <= cp + 18'd1; cst <= C_ADDR; end
                end
        C_DONE: begin cpu_rdata <= rd_acc; cpu_ready <= 1'b1; cst <= C_IDLE; end
        // Load: record the source row (done on entry) and return word 0. Two
        // clocks, no row walk -- an unpaired load moves no data.
        C_SRT_RD_ADDR: cst <= C_SRT_RD_CAP;
        C_SRT_RD_CAP: begin
          cpu_rdata <= {16'd0, unpack_pixel(q_a)};
          cpu_ready <= 1'b1;
          cst <= C_IDLE;
        end
        // Store: one pass, ordered so the copy never reads a word it has
        // already overwritten. Port A only; port B stays scanout-safe.
        // srt_dst_base was registered on the accepting clock, so srt_fast and
        // srt_down are first valid here.
        C_SRT_WR_ADDR: begin
          if (srt_fast) begin
            srt_idx <= srt_down ? 10'(SRT_GROUPS-1) : 10'd0;
            cst <= C_SRT_G_RD;
          end else begin
            srt_idx <= srt_down ? 10'd1023 : 10'd0;
            cst <= C_SRT_W_RD;
          end
        end
        // Wide path: NBANK words read, then the same NBANK words written.
        C_SRT_G_RD: cst <= C_SRT_G_WR;
        C_SRT_G_WR: begin
          if (srt_grp_last) begin
            cpu_ready <= 1'b1;
            cst <= C_IDLE;
          end else begin
            srt_idx <= srt_down ? srt_idx - 10'd1 : srt_idx + 10'd1;
            cst <= C_SRT_G_RD;
          end
        end
        // Fallback for a base that is not on a bank boundary: same ordering
        // rule, one word at a time.
        C_SRT_W_RD: cst <= C_SRT_W_WR;
        C_SRT_W_WR: begin
          if (srt_word_last) begin
            cpu_ready <= 1'b1;
            cst <= C_IDLE;
          end else begin
            srt_idx <= srt_down ? srt_idx - 10'd1 : srt_idx + 10'd1;
            cst <= C_SRT_W_RD;
          end
        end
        default: cst <= C_IDLE;
      endcase
    end
  end

  // --- Autoerase engines: cache fill (port B reads, vblank) + line erase
  //     (port B writes in the scheduler's idle slots) -----------------------
  localparam [17:0] SRC_L510 = 18'd261120;   // 510 * 512
  localparam [17:0] SRC_L511 = 18'd261632;   // 511 * 512
  logic [9:0] fi;          // fill index 0..1023 (bit9 = which src line, [8:0] = col)
  logic       fill_active = 1'b0, fill_done = 1'b0;
  logic       fill_cap = 1'b0;    // a fill read address was registered last cycle
  logic [9:0] fill_cap_fi; // ... for this index
  assign ae_filling    = fill_active;
  assign ae_fill_baddr = (fi[9] ? SRC_L511 : SRC_L510) + {9'd0, fi[8:0]};

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_cap <= 1'b0;
      fill_cap_fi <= 10'd0;
      fi <= 10'd0;
      fill_active <= 1'b0;
      fill_done <= 1'b0;
      esrc_r <= '0;
      esrc_rdy <= 1'b0;
      erase_active <= 1'b0;
      erase_col <= 10'd0;
      erase_line <= 9'd0;
      erase_goal_line <= 9'd0;
    end else begin
      // Refill the 2-line src cache once per vblank. A fill read address is
      // registered at the end of each fill_slot cycle (ph0); its data is on q_b
      // during the FOLLOWING cycle and captured at that cycle's end.
      fill_cap <= 1'b0;
      if (fill_slot) begin fill_cap <= 1'b1; fill_cap_fi <= fi; fi <= fi + 10'd1; end
      if (fill_cap)  begin
        ae_cache[fill_cap_fi] <= q_b;
        if (fill_cap_fi == 10'd1023) begin fill_active <= 1'b0; fill_done <= 1'b1; end
      end
      if (ae_vblank) begin
        if (!fill_done && !fill_active) begin fill_active <= 1'b1; fi <= 10'd0; end
      end else begin
        fill_active <= 1'b0; fill_done <= 1'b0;           // re-arm for the next vblank
      end

      // Prefetch the src word for the column that will be written NEXT cycle.
      // ecol_next/eline_next mirror the erase_col/erase_line updates below, so
      // esrc_r is always ae_cache[the very next write column] -- no bubbles, every
      // erase slot writes. (Breaks the 1024:1 ae_cache mux off the M10K din path.)
      esrc_r    <= ae_cache[{eline_next[0], ecol_next[8:0]}];
      esrc_rdy  <= erase_active;   // 1 from the 2nd active cycle: esrc_r settled

      // Erase requested lines in order through safe port-B slots. Z-unit may
      // finish a line shortly after the next trigger, so retain that trigger as
      // erase_goal_line instead of dropping every other erase request.
      if (ae_erase_trig && ae_en && (ae_erase_line < 9'd510))
        erase_goal_line <= ae_erase_line;
      if (!erase_active) begin
        if (ae_erase_trig && ae_en && (ae_erase_line < 9'd510)) begin
          erase_active <= 1'b1;
          erase_col <= 10'd0;
          erase_line <= ae_erase_line;
        end
      end else if (erase_step) begin
        if (erase_last_group) begin
          if (erase_line == erase_goal_effective) begin
            erase_active <= 1'b0;
          end else if (erase_goal_effective < erase_line) begin
            erase_line <= erase_goal_effective;
            erase_col <= 10'd0;
          end else if (erase_line >= 9'd509) begin
            erase_active <= 1'b0;
          end else begin
            erase_line <= erase_line + 9'd1;
            erase_col <= 10'd0;
          end
        end else begin
          erase_col <= erase_col + (ZUNIT_8BPP ? 10'd16 : 10'd1);
        end
      end
    end
  end

endmodule

// -----------------------------------------------------------------------------
// smashtv_vram_array -- the frame buffer itself, interleaved across NBANK
// independently addressed banks selected by the low BSEL bits of the pixel
// index. Both ports present one shared row address and a per-bank enable, so a
// single-word client drives one enable and the shift-register transfer drives
// all of them.
//
// Simulation keeps one flat behavioral array called `mem`, indexed by the
// ordinary linear pixel index, so `<vram>.u_vram.mem[y*512+x]` means exactly
// what it always meant and the banking is modelled around it rather than
// replacing it. Define NARC_SIM_SYNTH_VRAM_LAYOUT to build the altsyncram
// geometry under the simulator instead.
//
// Synthesis: SPLIT keeps the existing 8 + (DW-8) plane pair inside each bank.
// Do NOT collapse to a single DW-wide array -- 13 rounds up to x16 in an M10K
// and wastes three bits of every word.
// -----------------------------------------------------------------------------
module smashtv_vram_array #(
  parameter int DW    = 13,
  parameter bit SPLIT = 1'b1,
  parameter int NBANK = 16,
  parameter int RW    = 14
) (
  input  wire                  clk,
  input  wire [RW-1:0]         a_row,
  input  wire [NBANK-1:0]      a_we,
  input  wire [NBANK*DW-1:0]   a_din,
  output wire [NBANK*DW-1:0]   a_q,
  input  wire [RW-1:0]         b_row,
  input  wire [NBANK-1:0]      b_we,
  input  wire [NBANK*DW-1:0]   b_din,
  output wire [NBANK*DW-1:0]   b_q
);
`ifdef VERILATOR
`ifndef NARC_SIM_SYNTH_VRAM_LAYOUT
`define SMASHTV_VRAM_BEHAVIORAL
`endif
`endif

`ifdef SMASHTV_VRAM_BEHAVIORAL
  // Flat linear storage; bank k holds the words whose linear index has
  // [BSEL-1:0] == k, so index = row*NBANK + k reproduces the banked layout
  // exactly while leaving `mem` addressable the way every testbench expects.
  reg [DW-1:0] mem [0:(NBANK << RW)-1];
  reg [DW-1:0] rq_a [0:NBANK-1];
  reg [DW-1:0] rq_b [0:NBANK-1];
  integer ka, kb;
  always @(posedge clk) begin
    for (ka = 0; ka < NBANK; ka = ka + 1) begin
      if (a_we[ka]) begin
        mem[int'(a_row) * NBANK + ka] <= a_din[ka*DW +: DW];
        rq_a[ka] <= a_din[ka*DW +: DW];
      end else begin
        rq_a[ka] <= mem[int'(a_row) * NBANK + ka];
      end
    end
  end
  always @(posedge clk) begin
    for (kb = 0; kb < NBANK; kb = kb + 1) begin
      if (b_we[kb]) begin
        mem[int'(b_row) * NBANK + kb] <= b_din[kb*DW +: DW];
        rq_b[kb] <= b_din[kb*DW +: DW];
      end else begin
        rq_b[kb] <= mem[int'(b_row) * NBANK + kb];
      end
    end
  end
  genvar gq;
  generate
    for (gq = 0; gq < NBANK; gq = gq + 1) begin : g_qmap
      assign a_q[gq*DW +: DW] = rq_a[gq];
      assign b_q[gq*DW +: DW] = rq_b[gq];
    end
  endgenerate
`else
  genvar gb;
  generate
    for (gb = 0; gb < NBANK; gb = gb + 1) begin : g_bank
      if (SPLIT) begin : g_split
        wire [7:0]      qa_lo, qb_lo;
        wire [DW-9:0]   qa_hi, qb_hi;
        dpram_tdp #(.AW(RW), .DW(8)) u_lo (
          .clk    (clk),
          .addr_a (a_row), .din_a (a_din[gb*DW +: 8]),
          .we_a   (a_we[gb]), .q_a (qa_lo),
          .addr_b (b_row), .din_b (b_din[gb*DW +: 8]),
          .we_b   (b_we[gb]), .q_b (qb_lo)
        );
        dpram_tdp #(.AW(RW), .DW(DW-8)) u_hi (
          .clk    (clk),
          .addr_a (a_row), .din_a (a_din[gb*DW+8 +: (DW-8)]),
          .we_a   (a_we[gb]), .q_a (qa_hi),
          .addr_b (b_row), .din_b (b_din[gb*DW+8 +: (DW-8)]),
          .we_b   (b_we[gb]), .q_b (qb_hi)
        );
        assign a_q[gb*DW +: DW] = {qa_hi, qa_lo};
        assign b_q[gb*DW +: DW] = {qb_hi, qb_lo};
      end else begin : g_flat
        wire [DW-1:0] qa_w, qb_w;
        dpram_tdp #(.AW(RW), .DW(DW)) u_ram (
          .clk    (clk),
          .addr_a (a_row), .din_a (a_din[gb*DW +: DW]),
          .we_a   (a_we[gb]), .q_a (qa_w),
          .addr_b (b_row), .din_b (b_din[gb*DW +: DW]),
          .we_b   (b_we[gb]), .q_b (qb_w)
        );
        assign a_q[gb*DW +: DW] = qa_w;
        assign b_q[gb*DW +: DW] = qb_w;
      end
    end
  endgenerate
`endif

`ifdef SMASHTV_VRAM_BEHAVIORAL
`undef SMASHTV_VRAM_BEHAVIORAL
`endif
endmodule
`default_nettype wire
