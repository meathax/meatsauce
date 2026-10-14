// -----------------------------------------------------------------------------
// smashtv_gfx_reader.sv
//
// GFX-ROM read front-end for the Williams DMA blitter (and CPU GFX reads) with
// the GFX ROM in SDRAM. It converts the pixel-indexed read interface (gfx_addr =
// pixel, gfx_data = 8-bit pixel) into 6-word BURST reads from the SDRAM GFX
// channel (6 consecutive 16-bit words = 12 packed pixels per transaction) and
// caches THREE bursts with a TWO-burst-ahead prefetch.
//
// Why 3 slots / 2-ahead (was 2 slots / 1-ahead): the blitter consumes ~2 clk per
// pixel while an SDRAM burst costs ~11 clk (LATENCY+ACK_HOLD). One-ahead hides the
// fetch on long rows, but a short STRIDED row (e.g. a 16-px sprite row = 8 words)
// gives only ~4 pixels (~8 clk) of draw-time in its last burst to hide the ~11-clk
// next-row fetch -> a demand miss at every row boundary (~23% stall, tb_blit_perf).
// Prefetching TWO bursts ahead issues the next-row-start fetch a full burst
// earlier, so it completes before the blitter reaches the row boundary.
//
// CORRECTNESS is independent of every prefetch/eviction choice: gfx_data is served
// TAG-BASED from whichever of the 3 slots holds req_word, and a total miss simply
// demand-refetches (stalling the blitter until the word arrives). So gfx_data
// always equals the byte a plain read would return; prefetch only changes timing.
// Blits read source pixels forward-only (along a row, then jump to the next row),
// so the eviction victim (a burst already behind the read cursor) is never
// re-read within a blit even while req_word advances during a prefetch fetch.
//
// SDRAM handshake preserved exactly: a 1-cycle req pulse issued only while
// gfx_ext_ack is low (so a prior fetch's ACK_HOLD-extended ack is not mistaken
// for this one), request address held stable for the whole transaction.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_gfx_reader #(
  parameter [24:1] GFX_WORD_BASE = 24'h20000   // matches smashtv_rom_loader
) (
  input  wire        clk,
  input  wire        rst,

  // pixel-indexed read interface (to the blitter / CPU GFX mux)
  input  wire [22:0] gfx_addr,     // pixel index
  output wire [7:0]  gfx_data,     // selected 8-bit pixel
  output wire        gfx_valid,    // gfx_data holds the pixel for gfx_addr
  output wire [15:0] gfx_word,     // full 16-bit word containing gfx_addr
                                   // (= MAME gfxrom_r packing {byte 2n+1, byte 2n})

  // Prefetch hints from the blitter: last source word of the current row, and
  // the first source word of the next row. When the linear +6 prefetch would
  // overshoot the current row, prefetch the next row's start instead (kills the
  // per-row demand miss on strided sprites). Tie gfx_row_last='1 for linear.
  input  wire [22:1] gfx_row_last,
  input  wire [22:1] gfx_row_next,

  // SDRAM GFX 6-word burst channel (dout = {word+5 .. word+0})
  output reg         gfx_ext_req,  // 1-cycle request pulse
  output wire [24:1] gfx_ext_addr, // burst base word address (held stable)
  input  wire [95:0] gfx_ext_dout, // 6 consecutive words
  input  wire        gfx_ext_ack
);

  localparam int BW = 6;                        // words per burst
  localparam int NS = 3;                        // burst cache slots

  wire [22:1] req_word = gfx_addr[22:1];        // requested word index (pixel >> 1)

  // three burst slots: each caches BW words [base .. base+BW-1], packed low-first.
  reg [22:1]        base  [0:NS-1];
  reg [BW*16-1:0]   bdata [0:NS-1];   // {w5,w4,w3,w2,w1,w0}
  reg               vld   [0:NS-1];

  wire [21:0] off0 = req_word - base[0];        // 0-based so off[2:0] selects the word
  wire [21:0] off1 = req_word - base[1];
  wire [21:0] off2 = req_word - base[2];
  wire h0 = vld[0] && (off0 < BW[21:0]);        // req_word within slot-0's burst
  wire h1 = vld[1] && (off1 < BW[21:0]);
  wire h2 = vld[2] && (off2 < BW[21:0]);
  assign gfx_valid = h0 || h1 || h2;

  wire [1:0]  cslot = h0 ? 2'd0 : h1 ? 2'd1 : 2'd2;   // slot covering req_word
  wire [2:0]  coff  = h0 ? off0[2:0] : h1 ? off1[2:0] : off2[2:0]; // word 0..5
  wire [15:0] sw    = bdata[cslot][coff*16 +: 16];
  assign gfx_data = gfx_addr[0] ? sw[15:8] : sw[7:0];
  // CPU gfxrom_r must be BYTE-granular: a MOVB from an ODD byte offset returns
  // the requested byte (gfx[N] = sw[15:8]) in the LOW byte, matching MAME
  // (gfx[N] | gfx[N+1]<<8). The old `gfx_word = sw` returned the even byte for
  // odd offsets (word-aligned), which failed the custom-chip POST (U99 BAD).
  // (High byte for odd offsets is the pair's even byte; CPU MOVB reads only the
  // low byte and 16-bit gfx reads are word-aligned, so this is sufficient.)
  assign gfx_word = gfx_addr[0] ? {sw[7:0], sw[15:8]} : sw;

  // Two-ahead prefetch targets in read order (along the row, then jump to the
  // next row). pf1 = the burst after the one being served; pf2 = the burst after
  // pf1. When the linear step would overshoot the current row (gfx_row_last), the
  // next useful source is the next row's start. pf2 past a row boundary reads the
  // next row's second burst speculatively -- a harmless wasted fetch if that row
  // is short (transparency is still guaranteed by the tag-based serve).
  wire [22:1] cbase      = base[cslot];
  wire [22:1] lin1       = cbase + BW[22:1];
  wire        pf1_in_row = (gfx_row_last >= lin1);
  wire [22:1] pf1        = pf1_in_row ? lin1 : gfx_row_next;
  wire [22:1] lin2       = pf1 + BW[22:1];
  wire [22:1] pf2        = pf1_in_row ? ((gfx_row_last >= lin2) ? lin2 : gfx_row_next)
                                      : (gfx_row_next + BW[22:1]);

  wire pf1_present = (vld[0] && base[0]==pf1) || (vld[1] && base[1]==pf1) || (vld[2] && base[2]==pf1);
  wire pf2_present = (vld[0] && base[0]==pf2) || (vld[1] && base[1]==pf2) || (vld[2] && base[2]==pf2);

  wire        need_demand = !gfx_valid;                       // req_word not cached
  wire        need_pf1    = gfx_valid && !pf1_present;
  wire        need_pf2    = gfx_valid && !pf2_present && (pf2 != pf1);
  wire        need_fetch  = need_demand || need_pf1 || need_pf2;
  wire [22:1] tgt         = need_demand ? req_word : need_pf1 ? pf1 : pf2;

  // Victim: prefer an invalid slot, else a slot that neither covers req_word nor
  // holds a still-wanted prefetch target. Safe regardless (serve is tag-based;
  // a wrong evict only costs a future refetch, never a wrong pixel).
  wire keep0 = h0 || (vld[0] && (base[0]==pf1 || base[0]==pf2));
  wire keep1 = h1 || (vld[1] && (base[1]==pf1 || base[1]==pf2));
  wire keep2 = h2 || (vld[2] && (base[2]==pf1 || base[2]==pf2));
  wire [1:0] victim = !vld[0] ? 2'd0 : !vld[1] ? 2'd1 : !vld[2] ? 2'd2 :
                      !keep0  ? 2'd0 : !keep1  ? 2'd1 : 2'd2;

  reg [22:1] fetching;
  reg [1:0]  fvic;      // slot to fill on completion
  reg        st;        // 0 = IDLE, 1 = WAIT

  assign gfx_ext_addr = GFX_WORD_BASE + {2'b00, fetching};

  always_ff @(posedge clk) begin
    gfx_ext_req <= 1'b0;
    if (rst) begin
      st <= 1'b0;
      vld[0] <= 1'b0; vld[1] <= 1'b0; vld[2] <= 1'b0;
      base[0] <= '1;  base[1] <= '1;  base[2] <= '1;
      fetching <= '1; fvic <= 2'd0;
    end else if (st == 1'b0) begin
      if (need_fetch && !gfx_ext_ack) begin
        fetching    <= tgt;
        fvic        <= victim;
        gfx_ext_req <= 1'b1;                          // pulses next cycle, addr stable
        st          <= 1'b1;
      end
    end else begin
      if (gfx_ext_ack) begin
        base [fvic] <= fetching;
        bdata[fvic] <= gfx_ext_dout;     // all BW words at once
        vld  [fvic] <= 1'b1;
        st  <= 1'b0;
      end
    end
  end

endmodule : smashtv_gfx_reader

`default_nettype wire
