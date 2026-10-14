// -----------------------------------------------------------------------------
// smashtv_mem.sv  (bring-up stage)
//
// Memory controller between the TMS34010 core and storage. Presents the core's
// req/ack bit-addressed interface, uses smashtv_field for extract/insert, and
// decodes the Midway Y-Unit memory map. This stage backs only the two regions
// needed to prove the CPU executes real code end to end:
//
//   Program ROM   bit 0xFFE00000 .. 0xFFFFFFFF   256 KB   read-only
//   Main RAM      bit 0x01000000 .. 0x0101FFFF   128 KB   read-write
//   (reset vector at 0xFFFFFFE0 lives in program ROM)
//
// Everything else reads 0 and ignores writes for now (VRAM, palette, CMOS,
// blitter, sound, inputs, GFX ROM come in later stages). Those stubs are
// counted so bring-up can see stray accesses.
//
// Word storage is 16-bit little-endian (TMS34010 external bus). A field access
// touches up to three consecutive words; the field window is read
// combinationally and, for writes, the modified words are stored back per the
// field module's strobe. One access completes in a single ack cycle here; a
// cycle-accurate multi-word timing model arrives with the instruction cache and
// the MAME differential harness.
//
// Program ROM loads through a synchronous word port (ld_*), which the MiSTer
// ioctl download path will drive; the bring-up testbench drives it directly.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_mem #(
  parameter int PROG_WORDS   = 131072, // 256 KB program ROM (internal-BRAM mode)
  // CPU bit-address base of the populated program window. Y-unit Smash TV
  // uses 0xFFE00000 (256 KB); Z-unit NARC and Total Carnage use 0xFFC00000
  // (512 KB populated).
  parameter logic [31:0] PROG_BASE = 32'hFFE0_0000,
  parameter int MAIN_WORDS   = 65536,  // 128 KB main RAM
  // When 1, program-ROM word reads come from the external burst port
  // (prog_ext_*) -- SDRAM on hardware. When 0 (default) they come from the
  // internal prog[] BRAM, which is how the sim testbenches load the ROM.
  parameter bit EXTERNAL_PROG = 1'b0,
  // When 1, main RAM lives in SDRAM (single-stick architecture: the frame buffer
  // fills block RAM). When 0 (sim), it is the internal mram BRAM.
  parameter bit EXTERNAL_MAIN = 1'b0,
  // Place the 32 KiB CMOS/NVRAM in the same SDRAM client in hardware,
  // reclaiming 32 scarce M10Ks while preserving the banked CPU window.
  parameter bit EXTERNAL_CMOS = 1'b0,
  parameter [24:1] MAIN_SDRAM_BASE = 24'h800000,   // main RAM word base
  parameter [24:1] CMOS_SDRAM_BASE = 24'h810000,   // 16K-word CMOS image
  // Simulation-only: preload the internal program ROM from this hex file
  // ($readmemh, 16-bit words). Empty in hardware (the ROM is loaded via ioctl).
  parameter     PROG_HEX = ""
) (
  input  wire        clk,
  input  wire        rst,

  // CPU bit-addressed interface
  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,             // TMS34010 bit address
  input  wire [5:0]  size,             // field size in bits (1..32)
  input  wire [31:0] wdata,
  input  wire [1:0]  cmos_page,
  output reg  [31:0] rdata,
  output reg         ack,

  // Program ROM load port (ioctl / testbench) -- internal-BRAM mode
  input  wire        ld_prog_en,
  input  wire [17:0] ld_prog_addr,     // word index into program ROM
  input  wire [15:0] ld_prog_data,

  // External program-ROM burst port (EXTERNAL_PROG=1). Request a word address;
  // the SDRAM side returns the 3-word field window (w0..w2) with prog_ext_valid.
  output reg         prog_ext_req,
  output reg  [17:0] prog_ext_addr,    // word index of the first (w0) word
  input  wire [15:0] prog_ext_w0,
  input  wire [15:0] prog_ext_w1,
  input  wire [15:0] prog_ext_w2,
  input  wire        prog_ext_valid,

  // External main-RAM port (EXTERNAL_MAIN=1 -> SDRAM). Read returns the 3-word
  // window {w2,w1,w0}; write commits a single word.
  output reg         main_ext_req,
  output reg         main_ext_we,
  output reg  [24:1] main_ext_addr,
  output reg  [15:0] main_ext_din,
  output reg  [1:0]  main_ext_be,
  input  wire [47:0] main_ext_dout,
  input  wire        main_ext_ack,

  // Bring-up observability: an access hit an unbacked region
  output reg         miss_stb
);

  // --- Region bases (TMS34010 bit addresses) -------------------------------
  localparam logic [31:0] MAIN_BASE = 32'h0100_0000;
  localparam logic [31:0] CMOS_BASE = 32'h0140_0000;

  // --- Storage -------------------------------------------------------------
  // Main RAM as a true single-clock 1R1W block RAM. M10K reads are SYNCHRONOUS,
  // so the old combinational 3-address read (rd_main x3 in always_comb) could
  // not infer as block RAM and exploded into ~1 Mbit of registers during
  // synthesis. Here one registered read port streams the 3-word field window
  // sequentially (S_MRD) and one registered write port commits it (S_MWB).
  logic [15:0] mram_raddr, mram_waddr, mram_wdata, mram_rq;
  logic        mram_we;
  generate if (!EXTERNAL_MAIN) begin : g_mram
    (* ramstyle = "M10K" *) logic [15:0] mram [0:MAIN_WORDS-1];
    always_ff @(posedge clk) begin
      if (mram_we) mram[mram_waddr] <= mram_wdata;
      mram_rq <= mram[mram_raddr];
    end
  end else begin : g_nomram
    always_ff @(posedge clk) mram_rq <= 16'h0;   // main RAM is in SDRAM
  end endgenerate

  // Internal program-ROM BRAM only exists in internal mode; in EXTERNAL_PROG
  // mode the ROM lives in SDRAM and this 2 Mbit array must not be instantiated
  // (Quartus otherwise wastes it and can run out of memory during synthesis).
  logic [15:0] int_w0, int_w1, int_w2;   // internal-prog window words

  // --- Two-cycle handshake, matching sim_memory_model (the timing the CPU was
  //     validated against: latch the request in IDLE, respond in ACK). A
  //     1-cycle handshake shifts when the CPU's MOVE-load writeback samples
  //     mem_rdata_eff, corrupting register loads from memory. ------------------
  logic        l_we;
  logic [31:0] l_addr, l_wdata;
  logic [5:0]  l_size;

  // Field access operates on the LATCHED address, so the response reflects the
  // captured request (as in sim_memory_model's MEM_ACK).
  wire [31:0] a = l_addr;

  // --- Decode (on the latched address) -------------------------------------
  wire is_prog = (a >= PROG_BASE);                       // 0xFFE00000..top
  wire is_main = (a >= MAIN_BASE) &&
                 (a <  MAIN_BASE + (MAIN_WORDS*16));
  wire is_cmos = EXTERNAL_CMOS && (a >= CMOS_BASE) &&
                 (a < CMOS_BASE + 32'h0001_0000);

  wire [31:0] main_wi = (a - MAIN_BASE) >> 4;
  wire [31:0] cmos_wi = {18'd0, cmos_page, a[15:4]};
  wire [31:0] data_wi = is_cmos ? cmos_wi : main_wi;
  wire [31:0] mi0 = data_wi;
  wire [31:0] mi1 = data_wi + 32'd1;
  wire [31:0] mi2 = data_wi + 32'd2;

  // Registered main-RAM field window, filled sequentially by the S_MRD state.
  logic [15:0] mwin0, mwin1, mwin2;

  // Internal program ROM: instantiated only when EXTERNAL_PROG=0. The load port
  // fills it; the 3-word window drives int_w0..2. In external mode the array is
  // absent and int_w* are tied 0 (the external burst supplies the window).
  localparam int PROG_AW = $clog2(PROG_WORDS);
  generate
    if (!EXTERNAL_PROG) begin : gp
      (* ramstyle = "no_rw_check" *) logic [15:0] prog [0:PROG_WORDS-1];
      wire [31:0] prog_wi = (a - PROG_BASE) >> 4;
      wire [31:0] pi0 = prog_wi;
      wire [31:0] pi1 = prog_wi + 32'd1;
      wire [31:0] pi2 = prog_wi + 32'd2;
      initial if (PROG_HEX != "") $readmemh(PROG_HEX, prog);   // sim preload
      always_ff @(posedge clk)
        if (ld_prog_en) prog[ld_prog_addr] <= ld_prog_data;
      assign int_w0 = (pi0 < PROG_WORDS) ? prog[pi0[PROG_AW-1:0]] : 16'h0;
      assign int_w1 = (pi1 < PROG_WORDS) ? prog[pi1[PROG_AW-1:0]] : 16'h0;
      assign int_w2 = (pi2 < PROG_WORDS) ? prog[pi2[PROG_AW-1:0]] : 16'h0;
    end else begin : gp
      assign int_w0 = 16'h0; assign int_w1 = 16'h0; assign int_w2 = 16'h0;
    end
  endgenerate

  // External program-ROM window words, latched when prog_ext_valid.
  logic [15:0] ext_w0, ext_w1, ext_w2;

  // --- Program-ROM window cache -------------------------------------------
  // Every prog access pulls a 3-word window from SDRAM, but the TMS34010
  // icache fills a 4-word line as FOUR separate 16-bit accesses at consecutive
  // word addresses (tms34010_icache.sv:209-218). Without a cache that is 4
  // transactions x 3 words = 12 SDRAM words read to deliver 4 -- measured as
  // "program fetch (next word): 4 cycles", identical to a cold fetch, in
  // doc/measurements/sdram_baseline_20260730.txt.
  //
  // Hold the last window and serve any request fully covered by it. A line
  // fill then costs 2 transactions instead of 4, and sequential streaming
  // costs one transaction per three words. Program ROM is written only by the
  // loader while the CPU is in reset, so the window needs no invalidation.
  logic [15:0] pw0, pw1, pw2;
  logic [17:0] pw_base;
  logic        pw_valid;

  logic [15:0] w0, w1, w2;
  always_comb begin
    if (is_prog) begin
      if (EXTERNAL_PROG) begin
        w0 = ext_w0; w1 = ext_w1; w2 = ext_w2;
      end else begin
        w0 = int_w0; w1 = int_w1; w2 = int_w2;
      end
    end else if (is_main || is_cmos) begin
      w0 = mwin0; w1 = mwin1; w2 = mwin2;   // filled by S_MRD (registered reads)
    end else begin
      w0 = 16'h0; w1 = 16'h0; w2 = 16'h0;
    end
  end

  // --- Field extract / insert ----------------------------------------------
  wire [31:0] rd_field;
  wire [15:0] mw0, mw1, mw2;
  wire [2:0]  wstrobe;

  smashtv_field u_field (
    .bit_addr (l_addr),
    .size     (l_size),
    .wdata    (l_wdata),
    .rd_w0    (w0), .rd_w1 (w1), .rd_w2 (w2),
    .rd_field (rd_field),
    .wr_w0    (mw0), .wr_w1 (mw1), .wr_w2 (mw2),
    .wr_strobe(wstrobe)
  );

  // --- Access handshake -----------------------------------------------------
  //   S_IDLE : capture the request. Main RAM -> S_MRD; external prog read ->
  //            S_FETCH; everything else -> S_RESP.
  //   S_MRD  : stream the 3-word main window from the 1R BRAM port (registered
  //            reads, so ~5 cycles).
  //   S_FETCH: wait on the external program-ROM burst.
  //   S_RESP : field access on the window -> ack + rdata (reads); main writes
  //            go on to S_MWB first.
  //   S_MWB  : commit the modified main words through the 1W BRAM port.
  // rdata holds after ack (only overwritten by the next read), matching the
  // CPU-validated sim_memory_model / the smashtv_core rdata-hold contract.
  typedef enum logic [2:0] { S_IDLE, S_MRD, S_FETCH, S_RESP, S_MWB } mstate_t;
  mstate_t st;
  logic [2:0] mrc;    // main-read cycle counter
  logic [1:0] mwc;    // main-writeback cycle counter
  logic       m_inflight;   // an SDRAM main request is outstanding
  // SDRAM word address of main word i (main_wi + i), based on the region base.
  wire [24:1] data_sdram_base = is_cmos ? CMOS_SDRAM_BASE : MAIN_SDRAM_BASE;
  wire [24:1] main_sw0 = data_sdram_base + data_wi[23:0];
  wire [24:1] main_sw1 = data_sdram_base + data_wi[23:0] + 24'd1;
  wire [24:1] main_sw2 = data_sdram_base + data_wi[23:0] + 24'd2;

  always_ff @(posedge clk) begin
    if (rst) begin
      ack <= 1'b0; rdata <= 32'h0; st <= S_IDLE; mrc <= 3'd0; mwc <= 2'd0;
      miss_stb <= 1'b0;
      if (!EXTERNAL_MAIN) mram_we <= 1'b0;
      m_inflight <= 1'b0;
      prog_ext_req <= 1'b0; prog_ext_addr <= 18'h0;
      main_ext_req <= 1'b0; main_ext_we <= 1'b0;
      l_we <= 1'b0; l_addr <= 32'h0; l_size <= 6'h0; l_wdata <= 32'h0;
      mwin0 <= 16'h0; mwin1 <= 16'h0; mwin2 <= 16'h0;
      pw_valid <= 1'b0; pw_base <= 18'h0;
      pw0 <= 16'h0; pw1 <= 16'h0; pw2 <= 16'h0;
    end else begin
      ack          <= 1'b0;
      miss_stb     <= 1'b0;
      if (!EXTERNAL_MAIN) mram_we <= 1'b0;
      main_ext_req <= 1'b0;   // one-cycle request pulse

      case (st)
      S_IDLE:
        // Don't accept a new access until any prior SDRAM ack has cleared -- the
        // held ack (ACK_HOLD across the 4:1 CDC) would otherwise be mistaken for
        // this access's prog/main response (stale data -> CPU crash).
        if (req && !ack && !prog_ext_valid && !main_ext_ack) begin
          l_addr <= addr; l_we <= we; l_size <= size; l_wdata <= wdata;
          if ((addr >= MAIN_BASE && addr < MAIN_BASE + (MAIN_WORDS*16)) ||
              (EXTERNAL_CMOS && addr >= CMOS_BASE && addr < CMOS_BASE + 32'h0001_0000)) begin
            mrc <= 3'd0; st <= S_MRD;                 // main RAM: read window first
          end else if (EXTERNAL_PROG && !we && (addr >= PROG_BASE)) begin
            // Words this access actually needs from the window: a field of
            // `size` bits starting at bit offset addr[3:0] spans
            // ceil((addr[3:0]+size)/16) words, which is 1..3.
            logic [17:0] wa;
            logic [2:0]  nw;
            logic [18:0] koff;
            wa    = 18'((addr - PROG_BASE) >> 4);
            nw    = 3'((({2'd0, addr[3:0]} + {1'd0, size}) + 7'd15) >> 4);
            koff  = {1'b0, wa} - {1'b0, pw_base};
            if (pw_valid && !koff[18] && (koff <= 19'd2) &&
                ((koff[2:0] + nw) <= 3'd3)) begin
              // Covered by the held window: shift it into place, no SDRAM.
              // Words beyond the covered span are zeroed and, by the koff+nw
              // test above, are never referenced by the field extractor.
              case (koff[1:0])
                2'd0: begin ext_w0 <= pw0; ext_w1 <= pw1;   ext_w2 <= pw2;   end
                2'd1: begin ext_w0 <= pw1; ext_w1 <= pw2;   ext_w2 <= 16'h0; end
                default: begin ext_w0 <= pw2; ext_w1 <= 16'h0; ext_w2 <= 16'h0; end
              endcase
              st <= S_RESP;
            end else begin
              prog_ext_req  <= 1'b1;
              prog_ext_addr <= wa;
              st <= S_FETCH;
            end
          end else begin
            st <= S_RESP;                             // internal prog / stub
          end
        end

      S_MRD:
        if (EXTERNAL_MAIN || is_cmos) begin
          // one 3-word SDRAM burst read fills the whole window
          // wait for a previous ack to clear before issuing (the SDRAM holds ack
          // for ACK_HOLD clk_ram cycles across the 4:1 CDC; without this guard a
          // stale ack is mistaken for this request's ack).
          if (!m_inflight && !main_ext_ack) begin
            main_ext_req  <= 1'b1; main_ext_we <= 1'b0; main_ext_addr <= main_sw0;
            m_inflight    <= 1'b1;
          end else if (m_inflight && main_ext_ack) begin
            mwin0 <= main_ext_dout[15:0];
            mwin1 <= main_ext_dout[31:16];
            mwin2 <= main_ext_dout[47:32];
            m_inflight <= 1'b0; st <= S_RESP;
          end
        end else if (!EXTERNAL_MAIN) begin
          // sequential registered BRAM reads: raddr mi0,mi1,mi2 -> mwin0,1,2
          case (mrc)
            3'd0: begin mram_raddr <= mi0[15:0]; mrc <= 3'd1; end
            3'd1: begin mram_raddr <= mi1[15:0]; mrc <= 3'd2; end
            3'd2: begin mwin0 <= (mi0 < MAIN_WORDS) ? mram_rq : 16'h0;
                        mram_raddr <= mi2[15:0]; mrc <= 3'd3; end
            3'd3: begin mwin1 <= (mi1 < MAIN_WORDS) ? mram_rq : 16'h0; mrc <= 3'd4; end
            default: begin mwin2 <= (mi2 < MAIN_WORDS) ? mram_rq : 16'h0; st <= S_RESP; end
          endcase
        end

      S_FETCH:
        if (prog_ext_valid) begin
          ext_w0 <= prog_ext_w0; ext_w1 <= prog_ext_w1; ext_w2 <= prog_ext_w2;
          // Hold the window so the next 1-2 sequential prog words are free.
          pw0 <= prog_ext_w0; pw1 <= prog_ext_w1; pw2 <= prog_ext_w2;
          pw_base <= prog_ext_addr; pw_valid <= 1'b1;
          prog_ext_req <= 1'b0; st <= S_RESP;
        end

      S_RESP: begin
        if (l_we && (is_main || is_cmos)) begin
          mwc <= 2'd0; st <= S_MWB;                   // read-modify-write
        end else begin
          ack <= 1'b1;
          if (!l_we) rdata <= rd_field;
          if (!is_prog && !is_main && !is_cmos) miss_stb <= 1'b1;
          if (l_we && is_prog)      miss_stb <= 1'b1;
          st <= S_IDLE;
        end
      end

      S_MWB:
        if (EXTERNAL_MAIN || is_cmos) begin
          // commit each strobed word to SDRAM, one outstanding write at a time.
          // Wait for a prior ack to clear before issuing (see S_MRD note) so a
          // held stale ack is never mistaken for this write's ack.
          if (!m_inflight && !main_ext_ack) begin
            case (mwc)
              2'd0: if (wstrobe[0]) begin
                      main_ext_req<=1'b1; main_ext_we<=1'b1; main_ext_addr<=main_sw0;
                      main_ext_din<=mw0; main_ext_be<=2'b11; m_inflight<=1'b1;
                    end else mwc <= 2'd1;
              2'd1: if (wstrobe[1]) begin
                      main_ext_req<=1'b1; main_ext_we<=1'b1; main_ext_addr<=main_sw1;
                      main_ext_din<=mw1; main_ext_be<=2'b11; m_inflight<=1'b1;
                    end else mwc <= 2'd2;
              default: if (wstrobe[2]) begin
                      main_ext_req<=1'b1; main_ext_we<=1'b1; main_ext_addr<=main_sw2;
                      main_ext_din<=mw2; main_ext_be<=2'b11; m_inflight<=1'b1;
                    end else begin ack <= 1'b1; st <= S_IDLE; end
            endcase
          end else if (m_inflight && main_ext_ack) begin
            m_inflight <= 1'b0;
            if (mwc >= 2'd2) begin ack <= 1'b1; st <= S_IDLE; end
            else                 mwc <= mwc + 2'd1;
          end
        end else if (!EXTERNAL_MAIN) begin
          // commit the modified words one per cycle through the single BRAM port
          case (mwc)
            2'd0: begin
              if (wstrobe[0] && mi0 < MAIN_WORDS) begin
                mram_we <= 1'b1; mram_waddr <= mi0[15:0]; mram_wdata <= mw0;
              end
              mwc <= 2'd1;
            end
            2'd1: begin
              if (wstrobe[1] && mi1 < MAIN_WORDS) begin
                mram_we <= 1'b1; mram_waddr <= mi1[15:0]; mram_wdata <= mw1;
              end
              mwc <= 2'd2;
            end
            default: begin
              if (wstrobe[2] && mi2 < MAIN_WORDS) begin
                mram_we <= 1'b1; mram_waddr <= mi2[15:0]; mram_wdata <= mw2;
              end
              ack <= 1'b1; st <= S_IDLE;
            end
          endcase
        end

      default: begin
        st <= S_IDLE;
        m_inflight <= 1'b0;
        prog_ext_req <= 1'b0;
      end
      endcase
    end
  end

endmodule
`default_nettype wire
