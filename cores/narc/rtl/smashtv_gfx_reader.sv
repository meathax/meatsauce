// -----------------------------------------------------------------------------
// smashtv_gfx_reader.sv
//
// GFX-ROM read front-end for the Williams DMA blitter (and CPU GFX reads) with
// the GFX ROM in SDRAM. It converts the pixel-indexed read interface (gfx_addr =
// pixel, gfx_data = 8-bit pixel) into 6-word BURST reads from the one-stick
// SDRAM GFX channel (12 packed pixels per transaction) and buffers two bursts
// with a one-burst-ahead PREFETCH.
//
// Why a burst, not just a reader-side prefetch: the blitter consumes ~2 cycles
// per pixel while a single-word SDRAM read costs LATENCY+ACK_HOLD (~11 cycles).
// So the GFX read was SDRAM-BANDWIDTH-bound; reading 6 words per transaction
// cuts transactions vs single-word, and the one-burst-ahead prefetch hides the
// remaining latency behind the 12 pixels being drawn.
//
// Two burst slots hold {current, prefetched}; each slot caches 6 consecutive
// words tagged by its base word index. Blits read source pixels sequentially, so
// while the blitter draws the current burst the module prefetches the next
// (base + 6). FUNCTIONALLY TRANSPARENT: gfx_data always equals the byte a plain
// read would return (tag miss simply refetches); only timing changes.
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

  // SDRAM GFX 6-word burst channel (dout = {word+5 .. word+0})
  output reg         gfx_ext_req,  // 1-cycle request pulse
  output wire [24:1] gfx_ext_addr, // burst base word address (held stable)
  input  wire [95:0] gfx_ext_dout, // 6 consecutive words
  input  wire        gfx_ext_ack
);

  localparam int BW = 6;                        // words per burst
  // Sized stride — never bit-slice the unsized int (BW[22:1] of 6 is 3).
  localparam logic [21:0] BW_OFF = 22'd6;

  wire [22:1] req_word = gfx_addr[22:1];        // requested word index (pixel >> 1)

  // Align demand misses down to a multiple of BW. An unaligned start (e.g. word
  // 7) used to cache [7..12] and miss the sequential predecessor/successor
  // stream the blitter actually walks; aligned [6..11] keeps one slot covering
  // a full 12-pixel run and makes +BW prefetch land on the next run.
  //
  // Do not express this as `% 6`: Quartus 17.1 inferred a generic 23-bit Mod0
  // divider on the request-to-fetching path. For x in [0, 2^22),
  // floor(x/6) == floor((floor(x/2) * ceil(2^21/3)) / 2^21). The 21x20
  // constant multiply maps to one DSP and is exact over the complete address
  // range; multiplying the quotient by six uses only shifts and one add.
  wire [20:0] div6_half = req_word[22:2];
  (* multstyle = "dsp" *) wire [40:0] div6_product =
      div6_half * 20'd699051;
  wire [19:0] div6_quotient = div6_product[40:21];
  wire [22:1] demand_base = {div6_quotient, 2'b00} +
                             {1'b0, div6_quotient, 1'b0};

  // two burst slots: each caches BW words [base .. base+BW-1], packed low-first.
  reg [22:1]        base  [0:1];
  // This is two 96-bit variable-slice cache slots.  The asynchronous slice
  // read is intentional; keep it in logic rather than presenting it as an
  // accidental MLAB/M10K candidate to Quartus.
  (* ramstyle = "logic" *) reg [BW*16-1:0] bdata [0:1]; // {w5,w4,w3,w2,w1,w0}
  reg               vld   [0:1];

  wire [21:0] off0 = req_word - base[0];        // 0-based so off[2:0] selects the word
  wire [21:0] off1 = req_word - base[1];
  wire h0 = vld[0] && (off0 < BW_OFF);         // req_word within slot-0's burst
  wire h1 = vld[1] && (off1 < BW_OFF);
  assign gfx_valid = h0 || h1;

  wire        cslot = h0 ? 1'b0 : 1'b1;         // slot covering req_word
  wire [2:0]  coff  = h0 ? off0[2:0] : off1[2:0]; // which of the BW words (0..5)
  wire [15:0] sw    = bdata[cslot][coff*16 +: 16];
  assign gfx_data = gfx_addr[0] ? sw[15:8] : sw[7:0];
  assign gfx_word = sw;

  // the burst base of the word currently being served, and the next burst
  wire [22:1] cbase   = base[cslot];
  wire [22:1] pf_base = cbase + BW_OFF;         // +6 words (full burst stride)
  wire pf_present = (vld[0] && base[0] == pf_base) || (vld[1] && base[1] == pf_base);

  wire        need_demand = !(h0 || h1);          // req_word's burst not cached
  wire        need_pf     = (h0 || h1) && !pf_present;
  wire        need_fetch  = need_demand || need_pf;
  wire [22:1] tgt         = need_demand ? demand_base : pf_base;

  reg [22:1] fetching;
  reg        fvic;      // slot to fill on completion
  reg        st;        // 0 = IDLE, 1 = WAIT
  reg        lru;

  assign gfx_ext_addr = GFX_WORD_BASE + {2'b00, fetching};

  always_ff @(posedge clk) begin
    gfx_ext_req <= 1'b0;
    if (rst) begin
      st <= 1'b0; vld[0] <= 1'b0; vld[1] <= 1'b0; base[0] <= '1; base[1] <= '1;
      fetching <= '1; fvic <= 1'b0; lru <= 1'b0;
    end else if (st == 1'b0) begin
      if (need_fetch && !gfx_ext_ack) begin
        fetching    <= tgt;
        fvic        <= h0 ? 1'b1 : h1 ? 1'b0 : lru;  // don't evict the covering slot
        gfx_ext_req <= 1'b1;                          // pulses next cycle, addr stable
        st          <= 1'b1;
      end
    end else begin
      if (gfx_ext_ack) begin
        base [fvic] <= fetching;
        bdata[fvic] <= gfx_ext_dout;     // all BW words at once
        vld  [fvic] <= 1'b1;
        lru <= ~fvic;
        st  <= 1'b0;
      end
    end
  end

endmodule : smashtv_gfx_reader

`default_nettype wire
