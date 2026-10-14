// -----------------------------------------------------------------------------
// smashtv_blitter.sv
//
// The Midway Y/Z-Unit custom DMA blitter (Williams L1A3787). It reads 8-bit
// source pixels from the GFX ROM and writes 16-bit pixel words into VRAM,
// applying one of 16 command modes with X-flip, color-key and solid-fill. It is
// asynchronous to the CPU: a write to DMA_COMMAND with bit 15 set starts it, and
// on completion it clears bit 15 and asserts IRQ line 0.
//
// Z-unit NARC (SYS.INC / NDSP1) uses the same ten-register window at
// 0x01A80000 (+0x80000 mirror). DMAREGS (0x01A800A0) is only the MMTM base
// just past DMACONST; the software QDMA queues live in scratch RAM. DMASTRT
// writes 0 to DMACTRL to kill any pending transfer before TRAP 1 / DMAINT
// loads the next record -- so a CMD write with bit15 clear MUST abort the
// engine back to idle (MAME never needs this because dma_draw is synchronous).
//
// Faithful to MAME williams/midyunit_v.cpp dma_w + dma_draw. Deliberately
// including two documented MAME quirks so this matches the reference exactly:
//   * The clipping source-offset compensation (offset += ...) is DEAD in MAME:
//     `m_dma_state.offset = gfxoffset - 0x02000000` overwrites it before the
//     draw. We likewise do not compensate offset for clipped rows/columns.
//   * The `o >= 0x06000000` overrun guard is unreachable given an 8 MB source;
//     we omit it. MEASURED 2026-07-29, not assumed: a probe on the row-start
//     decision over a full 1820-frame real-ROM run (street gameplay, including
//     the frame-1780 explosion) counted 2,139,291 row starts and ZERO at or
//     beyond 0x06000000. This was suspect #4 for the blitter-into-HUD fault
//     (doc/BUGFIX_PLAN.md Phase 1) and is now eliminated on evidence.
//     If reinstating it, gate the ROW-START decision only and exempt fill
//     modes: the sibling Y-unit core hit a bug (their P0018) applying it to
//     the write state too, where the running offset has already advanced to
//     the NEXT row's base, which silently suppressed every write in a row.
// Smash T.V. / NARC use m_yawdim_dma = false, so only that flip path is
// implemented. Vertical flip is applied in software before the queue.
//
// Registers (index = CPU word offset into the blitter register window):
//   0 COMMAND  1 ROWBYTES  2 OFFSETLO  3 OFFSETHI  4 XSTART  5 YSTART
//   6 WIDTH    7 HEIGHT    8 PALETTE   9 COLOR
//
// One source pixel per VRAM write; the GFX read has one cycle of latency. The
// 41 ns/pixel completion delay MAME models is not reproduced here yet (a
// cycle-accurate timing pass comes with the instruction cache + timing work);
// functionally the blit completes and raises IRQ.
//
// Verified by sim/blit_check/tb_blitter.sv against a MAME-derived reference.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_blitter (
  input  wire        clk,
  input  wire        rst,

  // CPU register write (from smashtv_mem). reg_addr is the DMA register index.
  input  wire        reg_we,
  input  wire [3:0]  reg_addr,
  input  wire [15:0] reg_data,
  // CPU register read (DMA_COMMAND bit 15 = busy)
  input  wire [3:0]  reg_raddr,
  output wire [15:0] reg_rdata,
  // DMA_PALETTE register, exposed for the VRAM CPU-write palette-byte merge
  output wire [15:0] dma_palette_o,

  // GFX ROM read: pixel index -> 8-bit source pixel, 1-cycle registered latency.
  // gfx_addr is combinational (= current source pixel index); the ROM registers
  // the read, so data is valid the cycle after the address is presented.
  output wire [22:0] gfx_addr,      // pixel index into 8 MB (2^23) gfx space
  input  wire [7:0]  gfx_data,
  input  wire        gfx_valid,     // gfx_data is valid for the current gfx_addr

  // VRAM linear pixel write (to smashtv_vram blit port)
  output reg         vram_we,
  output reg  [17:0] vram_idx,      // ty*512 + tx
  output reg  [15:0] vram_pixel,
  input  wire        vram_ready,

  // Completion interrupt (IRQ line 0). MAME drives the 34010's external INT1
  // line: set_input_line(0, ASSERT_LINE) on blit completion (dma_callback) and
  // set_input_line(0, CLEAR_LINE) on every DMA_COMMAND write (dma_w). The
  // 34010's INTPEND.INT1 then FOLLOWS that line level (execute_set_input), so
  // we expose the line as a level (irq_line) -- the pulse (irq_set) is kept for
  // any edge-triggered consumer but the interrupt path uses irq_line.
  output reg         irq_set,       // one-cycle pulse when a blit finishes
  output reg         irq_line,      // level: 1 from completion until next CMD write
  output wire        busy,
  // 1 when this blit is provably not using the shared GFX reader, so another
  // client (the CPU's image-ROM reads) may take it. Fill blits, 0x0c-0x0f,
  // never touch the GFX bus -- see fill_mode below and the B_PIX comment.
  output wire        gfx_bus_idle
);

  // --- register file --------------------------------------------------------
  logic [15:0] dreg [0:9];
  localparam int CMD=0, ROWBYTES=1, OFFLO=2, OFFHI=3, XSTART=4, YSTART=5,
                 WIDTH=6, HEIGHT=7, PALETTE=8, COLOR=9;

  assign reg_rdata = (reg_raddr <= 4'd9) ? dreg[reg_raddr] : 16'h0;
  // DMA_PALETTE is the high byte position: MAME uses m_dma_register[DMA_PALETTE]
  // (unshifted) as the vram_w merge value.
  assign dma_palette_o = dreg[PALETTE];

  // busy = DMA_COMMAND bit 15
  assign busy = dreg[CMD][15];

  // --- blit engine state ----------------------------------------------------
  typedef enum logic [2:0] { B_IDLE, B_LATCH, B_SETUP, B_ROW, B_PIX, B_DONE } bstate_t;
  bstate_t st;

  // working registers (signed 32-bit like MAME's int)
  logic signed [31:0] w_rowbytes, w_xpos, w_ypos, w_width, w_height;
  logic        [15:0] w_pal, w_color16;
  logic        [31:0] w_offset_pix;     // pixel base (offset >> 3)
  logic        [3:0]  w_cmd;
  // Fill modes (0x0c-0x0f, "color all pixels") write a solid colour with no GFX
  // source -- used for the arena floor and the intro-scroll elements.
  wire fill_mode = (w_cmd[3:2] == 2'b11);
  // Narrower than `!busy`: a running FILL leaves the GFX reader completely
  // unused, so the CPU need not wait out the whole blit for it.
  assign gfx_bus_idle = !busy || fill_mode;
  logic signed [31:0] dx;

  logic signed [31:0] y_cnt, x_cnt;
  logic        [31:0] row_base;         // pixel offset at start of current row
  logic        [31:0] o_pix;            // running source pixel index
  logic signed [31:0] tx;
  logic        [8:0]  ty;

  // gfx address is the current source pixel index (combinational). The ROM
  // registers the read, so gfx_data is valid the cycle after o_pix is stable.
  assign gfx_addr = o_pix[22:0];

  // combinational setup values from the registers at trigger time
  wire signed [31:0] reg_rowbytes = $signed({{16{dreg[ROWBYTES][15]}}, dreg[ROWBYTES]});
  wire signed [31:0] reg_xpos     = $signed({{16{dreg[XSTART][15]}},   dreg[XSTART]});
  wire signed [31:0] reg_ypos     = $signed({{16{dreg[YSTART][15]}},   dreg[YSTART]});
  wire        [31:0] reg_width    = {16'h0, dreg[WIDTH]};
  wire        [31:0] reg_height   = {16'h0, dreg[HEIGHT]};
  wire        [31:0] gfxoffset0   = {dreg[OFFHI], dreg[OFFLO]};

  // per-pixel command result
  function automatic logic do_draw(input [3:0] cmd, input [7:0] px);
    unique case (cmd)
      4'h0:                      do_draw = 1'b0;
      4'h1:                      do_draw = (px == 8'h0);
      4'h2:                      do_draw = (px != 8'h0);
      4'h3:                      do_draw = 1'b1;
      4'h4, 4'h5:                do_draw = (px == 8'h0);
      4'h6, 4'h7:                do_draw = 1'b1;
      4'h8, 4'ha:                do_draw = (px != 8'h0);
      4'h9, 4'hb:                do_draw = 1'b1;
      default:                   do_draw = 1'b1;   // 0xc..0xf
    endcase
  endfunction
  function automatic logic [15:0] draw_val(input [3:0] cmd, input [7:0] px,
                                           input [15:0] pal, input [15:0] color16);
    unique case (cmd)
      4'h1:        draw_val = pal;
      4'h2:        draw_val = pal | {8'h0, px};
      4'h3:        draw_val = pal | {8'h0, px};
      4'h4, 4'h5:  draw_val = color16;
      4'h6, 4'h7:  draw_val = (px == 8'h0) ? color16 : (pal | {8'h0, px});
      4'h8, 4'ha:  draw_val = color16;
      4'h9, 4'hb:  draw_val = (px != 8'h0) ? color16 : (pal | {8'h0, px});
      default:     draw_val = color16;             // 0xc..0xf
    endcase
  endfunction

  // CMD bit15 start / abort. Priority over the draw FSM so DMASTRT's
  // "MOVE 0,@DMACTRL" can kill a mid-blit transfer before TRAP 1 reloads.
  wire cmd_wr    = reg_we && (reg_addr == CMD[3:0]);
  wire cmd_start = cmd_wr &&  reg_data[15];
  wire cmd_abort = cmd_wr && !reg_data[15];

  always_ff @(posedge clk) begin
    if (rst) begin
      st <= B_IDLE;
      for (int i = 0; i < 10; i++) dreg[i] <= 16'h0;
      vram_we <= 1'b0; irq_set <= 1'b0; irq_line <= 1'b0;
    end else begin
      vram_we <= 1'b0;
      irq_set <= 1'b0;

      // Non-command register writes always land.
      if (reg_we && !cmd_wr) begin
        dreg[reg_addr] <= reg_data;
      end

      // INT1 line follows MAME: any DMA_COMMAND write clears it (dma_w).
      if (cmd_wr) irq_line <= 1'b0;

      if (cmd_abort) begin
        // Kill pending / in-flight blit. No completion IRQ (DMASTRT race).
        dreg[CMD] <= reg_data;
        st        <= B_IDLE;
      end else if (cmd_start) begin
        // Start or restart. One settle state (B_LATCH) before B_SETUP so a
        // wide {ROWBYTES,CMD} 32-bit write's high half (pw2 beat) lands first
        // when CMD is the low half; Z-unit MMTM usually writes CMD last.
        dreg[CMD] <= reg_data;
        st        <= B_LATCH;
      end else unique case (st)
        B_IDLE: begin
        end

        B_LATCH: st <= B_SETUP;

        B_SETUP: begin
          // Mirror dma_w. Latch the basic fields.
          w_cmd     <= dreg[CMD][3:0];
          w_pal     <= {dreg[PALETTE][7:0], 8'h0};          // DMA_PALETTE << 8
          w_color16 <= {dreg[PALETTE][7:0], 8'h0} | {8'h0, dreg[COLOR][7:0]};
          dx        <= (dreg[CMD][4]) ? -32'sd1 : 32'sd1;   // X flip

          // rowbytes / xpos / offset per flip. yawdim = false (Smash T.V.).
          begin
            logic signed [31:0] rb, xp, yp, wd, ht;
            logic        [31:0] goff;
            rb = reg_rowbytes; xp = reg_xpos; yp = reg_ypos;
            wd = $signed(reg_width); ht = $signed(reg_height);
            goff = gfxoffset0;

            if (dreg[CMD][4]) begin  // X flip
              goff = goff - (reg_width - 32'd1) * 32'd8;
              rb   = (rb - wd + 32'sd3) & ~32'sd3;
              xp   = xp + wd - 32'sd1;
            end else begin
              rb   = (rb + wd + 32'sd3) & ~32'sd3;
            end

            // Y clipping (offset compensation intentionally omitted -- dead in MAME)
            if (yp < 0) begin
              ht = ht + yp;   // height -= -ypos
              yp = 0;
            end
            if (yp + ht > 32'sd512) ht = 32'sd512 - yp;

            // X clipping
            if (!dreg[CMD][4]) begin
              if (xp < 0) begin
                wd = wd + xp;  // width -= -xpos
                xp = 0;
              end
              if (xp + wd > 32'sd512) wd = 32'sd512 - xp;
            end else begin
              if (xp >= 32'sd512) begin
                wd = wd - (xp - 32'sd511);
                xp = 32'sd511;
              end
              if (xp - wd < 0) wd = xp;
            end

            // final offset (the overwrite MAME does): gfxoffset - 0x02000000,
            // with the wrap that adds it back if below the gfx base.
            if (goff < 32'h0200_0000) goff = goff + 32'h0200_0000;
            w_offset_pix <= (goff - 32'h0200_0000) >> 3;

            w_rowbytes <= rb;
            w_xpos     <= xp;
            w_ypos     <= yp;
            w_width    <= wd;
            w_height   <= ht;
          end

          y_cnt   <= 32'sd0;
          st      <= B_ROW;
        end

        B_ROW: begin
          if (y_cnt >= w_height || w_width <= 0) begin
            st <= B_DONE;
          end else begin
            logic [31:0] next_o;
            next_o   = (y_cnt == 0) ? w_offset_pix : (row_base + w_rowbytes);
            ty       <= (w_ypos[8:0] + y_cnt[8:0]) & 9'h1ff;
            row_base <= next_o;
            o_pix    <= next_o;   // gfx_addr follows combinationally
            tx       <= w_xpos;
            x_cnt    <= 32'sd0;
            st       <= B_PIX;
          end
        end

        // ONE pixel per clock. The GFX reader's gfx_data/gfx_valid are
        // COMBINATIONAL from gfx_addr (= o_pix), so a cached pixel is written
        // AND o_pix advanced in the same cycle -- no separate read state. This
        // ~doubles throughput vs the old 2-state (RD then WR) machine, which is
        // what lets the kernel's per-frame full-screen redraw actually finish
        // (black floor / missing backgrounds were the redraw running out of
        // frame time). Fills (cmd 0x0c-0x0f, "color all") need no GFX source, so
        // they run at a guaranteed 1 px/clk and never touch the GFX bus; GFX
        // blits run 1 px/clk while the burst is cached and stall only on a cache
        // miss (SDRAM burst latency), so effective rate ~= GFX bus bandwidth.
        B_PIX: begin
          if (x_cnt >= w_width) begin
            y_cnt <= y_cnt + 32'sd1;
            st    <= B_ROW;
          end else if (fill_mode || gfx_valid) begin
            // Transparent pixels require no VRAM transaction. A drawn pixel
            // advances only after the shared random port acknowledges it.
            if (!do_draw(w_cmd, gfx_data) || vram_ready) begin
              if (do_draw(w_cmd, gfx_data)) begin
                vram_we    <= 1'b1;
                vram_idx   <= {ty, 9'h0} + {9'd0, tx[8:0]}; // ty*512 + tx
                vram_pixel <= draw_val(w_cmd, gfx_data, w_pal, w_color16);
              end
              tx    <= tx + dx;
              if (!fill_mode) o_pix <= o_pix + 32'd1;      // fills keep gfx_addr stable
              x_cnt <= x_cnt + 32'sd1;
            end
          end
          // else: GFX cache miss -> hold (o_pix stable) until the reader fetches.
        end

        B_DONE: begin
          dreg[CMD][15] <= 1'b0;   // clear busy
          irq_set       <= 1'b1;   // one-cycle completion pulse
          irq_line      <= 1'b1;   // assert INT1 line until the next CMD write
          st            <= B_IDLE;
        end

        default: st <= B_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
