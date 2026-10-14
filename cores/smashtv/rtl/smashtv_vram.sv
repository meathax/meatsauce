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
//   BLIT (linear pixel) — the DMA blitter writes a full 16-bit pixel word at a
//        linear pixel index (ty*512 + tx). Highest-traffic writer.
//
//   SCAN (linear pixel read) — the video timing generator reads a pixel word by
//        linear index for pen_map + palette lookup.
//
// Storage is inferred block RAM. This keeps the MAME-identical 16 bits/pixel for
// correctness; a 12-bit live-bit packing (pen_map uses only 0x0f3f|0xc000) is a
// later block-RAM optimization (see doc/EVALUATION.md — 12 bpp measured at 384
// M10K, the single-stick budget assumes that packing).
//
// The pen_map decode (6 bpp) and palette live in the video stage, not here.
//
// Verified by sim/vram_check/tb_vram.sv against a MAME-derived reference model.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_vram (
  input  wire        clk,

  // --- CPU port: byte-granular multi-pixel access (MAME vram_w / vram_r) -----
  // The 34010 accesses VRAM as a byte-per-pixel, bank-selected plane. A field
  // access covers 1..4 consecutive pixel bytes (size 8/16/24/32, byte-aligned);
  // each pixel is a separate 16-bit VRAM word, so the engine walks them one per
  // cycle and pulses cpu_ready when done. bank=1 = pixel plane (low byte from
  // data, high byte from DMA_PALETTE), bank=0 = palette plane (high byte).
  input  wire        cpu_req,        // level: a CPU VRAM access is pending
  input  wire        cpu_we,
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

  // --- Scanout port: linear pixel read --------------------------------------
  input  wire [17:0] scan_idx,
  output wire [15:0] scan_pixel,

  // --- Autoerase (MAME autoerase_line): copy source line 510/511 into each
  //     displayed line, one line behind the scanout, when enabled. The source
  //     lines are cached from VRAM during vblank via the idle scanout port, and
  //     the per-line erase WRITES also go through PORT B's idle cycles: the
  //     scanout only needs the port-B address registered on the cycle before
  //     each ce_pix sample (1 of every 3 clocks), leaving 2 slots per pixel for
  //     erase writes. The erase therefore NEVER competes with the blitter or
  //     CPU on port A -- under the old port-A scheme heavy blits starved whole
  //     line-erases (ghost trails / doubled sprites during big transitions).
  //     `ae_erase_line` is the display line to clear; src = line 510 + (line&1).
  input  wire        ce_pix,         // pixel-clock enable (phase ref for port B)
  input  wire        ae_en,          // autoerase enabled (CONTROL bit4 active-low)
  input  wire        ae_vblank,      // high during vblank -> (re)fill the src cache
  input  wire        ae_erase_trig,  // 1-cycle: begin erasing ae_erase_line
  input  wire [8:0]  ae_erase_line   // display line to clear (0..255)
);

  // 262,144 x 12-bit frame buffer. Only 12 of the 16 bits of a Y-Unit VRAM word
  // are live (the pen uses 0x0f3f|0xc000); the real board has 12-bit VRAM
  // (12 x 53461 chips). We store exactly the pen: the packed 12-bit value equals
  // pen_map6 of the 16-bit word, so scanout is a plain unpack. The 4 dead bits
  // (word 6,7,12,13) read back 0, matching hardware.
  // 262144 x 12-bit true dual-port block RAM (see dpram_tdp.sv). Instantiated,
  // not inline-inferred: Quartus 17.0 rejects the inline true-dual-port pattern
  // ("asynchronous read logic") but infers the submodule cleanly.

  // pen = {w[15:14], w[11:8], w[5:0]}  (== pen_map6 without the &0xfff mask)
  function automatic [11:0] pack16(input [15:0] w);
    pack16 = {w[15:14], w[11:8], w[5:0]};
  endfunction
  function automatic [15:0] unpack12(input [11:0] p);
    unpack12 = {p[11:10], 2'b00, p[9:6], 2'b00, p[5:0]};
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
  logic [17:0] a_addr; logic a_we; logic [11:0] a_din; logic [11:0] q_a;
  // Both ports register the RAW array read directly into a register (so Quartus
  // uses the M10K output register and infers block RAM). Any transform (unpack12)
  // must be applied AFTER the register, combinationally -- wrapping the read in a
  // function inline creates an asynchronous read that blocks M10K inference.
  // Canonical Quartus true-dual-port template (write-first with explicit else) --
  // this is the exact shape Quartus 17.0 reliably infers as M10K. Port A read and
  // write never occur in the same cycle here (the CPU engine reads in C_ADDR/C_ACT
  // and writes in a later C_ACT), so write-first vs read-first is immaterial.
  // Port A = CPU/blitter R/W (a_addr, write-first). Port B = scanout read (we_b
  // tied 0). unpack12 is applied combinationally on the registered read output.
  logic [11:0] q_b;
  // --- Port B scheduler --------------------------------------------------------
  // ce_pix marks the sample cycle: at the posedge ending it, smashtv_video
  // latches scan_pixel, so the port-B address registered at the END of the
  // PREVIOUS cycle must be scan_idx. Phase counter: ph==0 during the ce cycle,
  // then 1, 2. Slot roles (what is registered at the END of each cycle):
  //   end of ph2 : scan_idx            (mandatory -- feeds the ce sample)
  //   end of ph0 : vblank fill read address, else erase write, else scan
  //   end of ph1 : fill-data capture (from ph0's read) + erase write, else scan
  // Display time: erase gets 2 write slots per pixel (1024 writes per 3-clk*512
  // = a full line erased in half a line). Vblank: fill and erase interleave.
  logic [1:0]  ph = 2'd0;
  always_ff @(posedge clk) ph <= ce_pix ? 2'd1 : (ph == 2'd2 ? 2'd0 : ph + 2'd1);

  // fill/erase state (engines below). Power-up initializers (honored by Quartus
  // for Cyclone V FFs and by simulation) give these a defined 0 start -- without
  // them the trigger gate `!erase_active` sees X and can never resolve in sim,
  // and hardware would rely on implicit power-up state.
  logic [17:0] ae_fill_baddr;
  logic        ae_filling;
  logic        erase_active = 1'b0;
  logic [8:0]  erase_line;
  logic [9:0]  erase_col;
  logic [11:0] ae_cache [0:1023];    // src cache: line 510 @ [0:511], 511 @ [512:1023]
  wire  [17:0] ae_dest_addr = {erase_line, 9'd0} + {9'd0, erase_col[8:0]};

  // Next-state of erase_col/erase_line (mirrors the always_ff updates below) --
  // used to prefetch the correct src word one cycle ahead into esrc_r.
  wire [9:0] ecol_next  = (ae_erase_trig && ae_en && !erase_active)     ? 10'd0
                        : (erase_active && erase_slot && erase_col != 10'd511)
                                                                          ? erase_col + 10'd1
                        :                                                   erase_col;
  wire [8:0] eline_next = (ae_erase_trig && ae_en && !erase_active) ? ae_erase_line
                        :                                             erase_line;

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
  logic [11:0] esrc_r;
  logic        esrc_rdy = 1'b0;   // esrc_r has been loaded for the first column

  logic [17:0] pb_addr;
  logic        pb_we;
  logic [11:0] pb_din;
  wire scan_slot  = (ph == 2'd2);                 // must register scan_idx
  wire fill_slot  = (ph == 2'd0) && ae_filling;   // vblank cache-fill read
  // esrc_rdy holds the very first write of each line off by one cycle so esrc_r
  // (loaded at the trigger edge) is settled before it is consumed -- a single
  // 1-of-512 bubble per line, not the per-write bubble that would halve throughput.
  wire erase_slot = !scan_slot && !fill_slot && erase_active && esrc_rdy;
  always_comb begin
    pb_we  = 1'b0; pb_din = esrc_r; pb_addr = scan_idx;
    if      (fill_slot)  begin pb_addr = ae_fill_baddr; end
    else if (erase_slot) begin pb_addr = ae_dest_addr; pb_we = 1'b1; end
  end

  dpram_tdp #(.AW(18), .DW(12)) u_vram (
    .clk    (clk),
    .addr_a (a_addr),  .din_a (a_din), .we_a (a_we), .q_a (q_a),
    .addr_b (pb_addr), .din_b (pb_din), .we_b (pb_we), .q_b (q_b)
  );
  assign scan_pixel = unpack12(q_b);   // combinational transform on the registered read

  // --- CPU access engine: per byte, present address (read) then act ---------
  typedef enum logic [1:0] { C_IDLE, C_ADDR, C_ACT, C_DONE } cstate_t;
  cstate_t   cst;
  logic [2:0]  cidx;
  logic [31:0] rd_acc;
  logic [17:0] cp;
  wire  [7:0]  wbyte = cpu_wdata[cidx*8 +: 8];

  // CPU-side port-A drive (combinational); muxed with the blitter below.
  logic [17:0] cpu_a_addr; logic cpu_a_we; logic [11:0] cpu_a_din;
  always_comb begin
    cpu_a_addr = cp; cpu_a_we = 1'b0; cpu_a_din = 12'h0;
    if (cst == C_ACT && cpu_we) begin
      cpu_a_we = 1'b1;
      if (bank_select) cpu_a_din = pack16({pal_hi(cp), wbyte});           // pixel plane
      else             cpu_a_din = {wbyte[7:6], wbyte[3:0], q_a[5:0]};    // palette plane RMW
    end
  end

  // Port-A arbitration: blitter first, then the CPU engine. (The autoerase
  // moved to port B's idle slots -- see the port-B scheduler above.)
  always_comb begin
    if (blit_we) begin a_addr = blit_idx;   a_we = 1'b1;     a_din = pack16(blit_pixel); end
    else         begin a_addr = cpu_a_addr; a_we = cpu_a_we; a_din = cpu_a_din;          end
  end

  always_ff @(posedge clk) begin
    cpu_ready <= 1'b0;
    // The CPU engine only advances on cycles it owns port A (blitter idle).
    case (cst)
      C_IDLE: if (cpu_req) begin cidx <= 3'd0; rd_acc <= 32'h0; cp <= cpu_pbase; cst <= C_ADDR; end
      C_ADDR: if (!blit_we) cst <= C_ACT;                 // read presented this cycle
      C_ACT:  if (!blit_we) begin
                if (!cpu_we)
                  rd_acc[cidx*8 +: 8] <= bank_select ? {2'b00, q_a[5:0]}
                                                     : {q_a[11:10], 2'b00, q_a[9:6]};
                if (cidx + 3'd1 >= cpu_nbytes) cst <= C_DONE;
                else begin cidx <= cidx + 3'd1; cp <= cp + 18'd1; cst <= C_ADDR; end
              end
      C_DONE: begin cpu_rdata <= rd_acc; cpu_ready <= 1'b1; cst <= C_IDLE; end
      default: cst <= C_IDLE;
    endcase
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

    // Erase the target line through the port-B write slots. With >=1 slot per
    // 3 clocks guaranteed (2 during display), a 512-column line always finishes
    // well before the next per-line trigger -- no skips at ANY blit load.
    if (ae_erase_trig && ae_en && !erase_active) begin
      erase_active <= 1'b1; erase_col <= 10'd0; erase_line <= ae_erase_line;
    end else if (erase_active && erase_slot) begin      // this slot's write landed
      if (erase_col == 10'd511) erase_active <= 1'b0;
      else erase_col <= erase_col + 10'd1;
    end
  end

endmodule
`default_nettype wire
