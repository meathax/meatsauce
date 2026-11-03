// -----------------------------------------------------------------------------
// exterm_master_mem.sv -- TMS34010 bit-addressed memory fabric for Exterminator
//
// CPU side: req/ack field interface of tms34010_core (bit address, size 1..32,
// 32-bit wdata, rdata held after ack), exactly the contract smashtv_mem served.
// Backends, selected from the MAME exterm.cpp map (mirrors honoured):
//
//   MASTER (IS_SLAVE=0)                              SLAVE (IS_SLAVE=1)
//     a[25:23]=000  BG VRAM 128 KB   -> v_*             a[26]=0  FG VRAM 128 KB -> v_*
//     a[25:23]=001  DRAM 512 KB      -> SDRAM           a[26]=1  DRAM 1 MB      -> SDRAM
//     a[25:24]=01,a[23]=0 I/O ports  -> per_*           (nothing else mapped)
//     a[25:23]=011  CLUT 2Kx16       -> pal_*
//     a[25:23]=101  NVRAM 2Kx16      -> nv_*
//     a[25:24]=11   EPROM 2 MB       -> SDRAM (4-word line cache)
//   I/O register space (a[31:30]=11, a[29:9]=0) is served on-chip by the core
//   (ack immediately, no side effect here).
//
// A field touches up to three consecutive 16-bit words. Reads fetch the words
// the field spans; writes read-modify-write only when a touched byte is only
// partly covered, otherwise they write the covered bytes with byte enables.
// Peripheral reads keep MAME's per-word side effects (trackball accumulation,
// HSTDATA auto increment).
//
// SRT: a PIXT cycle to VRAM while DPYCTL.SRT is set becomes a shift-register
// transfer, signalled as v_req + v_srt_rd (memory -> shift register, PIXT read)
// or v_req + v_srt_wr (shift register -> memory, PIXT write); v_addr is the
// word address of the pixel (row = v_addr[15:8]); completed by v_ack like any
// VRAM access (see lesson 2036: the PIXT write itself never issues a read).
// -----------------------------------------------------------------------------
`default_nettype none
module exterm_master_mem #(
  parameter bit IS_SLAVE = 1'b0
) (
  input  wire        clk,
  input  wire        rst,

  // CPU bus (held by the request stage until ack)
  input  wire        req,
  input  wire        we,
  input  wire [31:0] addr,
  input  wire [5:0]  size,
  input  wire [31:0] wdata,
  input  wire        pix,        // PIXT bus cycle
  input  wire        srt_on,     // DPYCTL.SRT
  input  wire [2:0]  eng,        // bus cycle class (core): 0 normal 1 PIXT 2 FILL 3 PIXBLT 4 DRAV/LINE
  input  wire [1:0]  esub,       // engine sub-step
  input  wire        ers,        // pixel op needs the destination (PPOP != 0 / transparency)
  input  wire        srt_clr,    // new instruction: forget the per-word transfer history
  output wire [31:0] rdata,
  output wire        ack,

  // SDRAM client (exterm_sdram_arb): hold sd_req until the sd_ack pulse
  output reg         sd_req,
  output reg         sd_we,
  output reg  [23:0] sd_addr,
  output reg  [15:0] sd_din,
  output reg  [1:0]  sd_be,
  output reg  [2:0]  sd_burst,
  input  wire [63:0] sd_dout,
  input  wire        sd_ack,
  input  wire        rom_inval,  // download active: drop the ROM line cache

  // VRAM port (lane 2): v_req held until v_ack pulse (rdata valid on v_ack)
  output reg         v_req,
  output reg         v_we,
  output reg  [15:0] v_addr,
  output reg  [15:0] v_wdata,
  output reg  [1:0]  v_be,
  output reg         v_srt_rd,
  output reg         v_srt_wr,
  input  wire [15:0] v_rdata,
  input  wire        v_ack,

  // CLUT port (registered 1-cycle-latency read), master only
  output reg         pal_we,
  output reg  [10:0] pal_addr,
  output reg  [15:0] pal_wdata,
  output reg  [1:0]  pal_be,
  input  wire [15:0] pal_rdata,

  // NVRAM BRAM port (registered 1-cycle-latency read), master only
  output reg         nv_we,
  output reg  [10:0] nv_addr,
  output reg  [15:0] nv_wdata,
  output reg  [1:0]  nv_be,
  input  wire [15:0] nv_rdata,

  // Peripheral word port (master only): per_req held until per_ack pulse
  output reg         per_req,
  output reg         per_we,
  output reg  [3:0]  per_sel,
  output reg  [15:0] per_wdata,
  input  wire [15:0] per_rdata,
  input  wire        per_ack
);

  // ---- region / peripheral codes ------------------------------------------------
  localparam [2:0] R_NONE = 3'd0, R_VRAM = 3'd1, R_DRAM = 3'd2, R_ROM = 3'd3,
                   R_CLUT = 3'd4, R_NV = 3'd5, R_PER = 3'd6;
  localparam [3:0] PS_HADRL = 4'd0, PS_HADRH = 4'd1, PS_HDATA = 4'd2, PS_HCTL = 4'd3,
                   PS_TB0 = 4'd4, PS_TB1 = 4'd5, PS_DSW = 4'd6, PS_OUT = 4'd7,
                   PS_SND = 4'd8, PS_WDG = 4'd9, PS_NONE = 4'd15;

  localparam [23:0] MASTER_DRAM_BASE = 24'h400000;
  localparam [23:0] SLAVE_DRAM_BASE  = 24'h800000;

  // ---- request (held stable by the cpu_sys request stage until ack) ---------------
  wire        l_we    = we;
  wire        l_pix   = pix;
  wire [31:0] l_addr  = addr;
  wire [31:0] l_wdata = wdata;
  wire [5:0]  l_size  = size;

  wire [5:0] esize = (l_size == 6'd0) ? 6'd32 : l_size;
  wire [6:0] span  = {3'd0, l_addr[3:0]} + {1'b0, esize};
  wire [1:0] nw    = (span > 7'd32) ? 2'd3 : (span > 7'd16) ? 2'd2 : 2'd1;

  // ---- region decode (on the latched address) -------------------------------------
  wire a_io = (l_addr[31:30] == 2'b11) && (l_addr[29:9] == 21'd0);
  reg  [2:0] region;
  reg  [3:0] psel;
  always @* begin
    region = R_NONE; psel = PS_NONE;
    if (a_io) begin
      region = R_NONE;
    end else if (IS_SLAVE) begin
      region = l_addr[26] ? R_DRAM : R_VRAM;
    end else begin
      case (l_addr[25:24])
        2'b00: region = l_addr[23] ? R_DRAM : R_VRAM;
        2'b01: begin
          if (l_addr[23]) region = R_CLUT;
          else begin
            region = R_PER;
            if (!l_addr[22]) psel = {2'b00, l_addr[21:20]};        // host port
            else case (l_addr[21:18])
              4'b0000: psel = PS_TB0;
              4'b0001: psel = PS_TB1;
              4'b0010: psel = PS_DSW;
              4'b0100: psel = PS_OUT;
              4'b0110: psel = PS_SND;
              4'b0111: psel = PS_WDG;
              default: begin psel = PS_NONE; region = R_NONE; end
            endcase
          end
        end
        2'b10: region = l_addr[23] ? R_NV : R_NONE;
        default: region = R_ROM;
      endcase
    end
  end

  // ---- field extract / insert -------------------------------------------------------
  reg  [15:0] win0, win1, win2;
  reg  [1:0]  wcnt;      // write-phase word index
  reg  [1:0]  rcnt;      // read-phase word index
  reg  [3:0]  st;
  wire        c_hit;
  wire [15:0] c_rdq_w;
  wire        dir_rd = (st == 4'd3) && ((region == R_DRAM) || (region == R_ROM)) && c_hit &&
                       (rcnt + 2'd1 >= nw) && !l_we;
  wire [15:0] c_rdq = c_rdq_w;
  wire [31:0] rd_field;
  wire [15:0] mw0, mw1, mw2;
  wire [2:0]  wstrobe_unused;
  wire [47:0] wmask;
  exterm_field u_field (
    .bit_addr(l_addr), .size(l_size), .wdata(l_wdata),
    .rd_w0((dir_rd && rcnt == 2'd0) ? c_rdq : win0),
    .rd_w1((dir_rd && rcnt == 2'd1) ? c_rdq : win1),
    .rd_w2((dir_rd && rcnt == 2'd2) ? c_rdq : win2),
    .rd_field(rd_field),
    .wr_w0(mw0), .wr_w1(mw1), .wr_w2(mw2),
    .wr_strobe(wstrobe_unused), .wr_mask(wmask)
  );
  // Byte enables per window word; a read is needed when a touched byte is partial.
  reg  [1:0] wbe0, wbe1, wbe2;
  reg        need_rd;
  always @* begin
    wbe0 = {|wmask[15:8],  |wmask[7:0]};
    wbe1 = {|wmask[31:24], |wmask[23:16]};
    wbe2 = {|wmask[47:40], |wmask[39:32]};
    need_rd = 1'b0;
    if (wmask[7:0]   != 8'h00 && wmask[7:0]   != 8'hFF) need_rd = 1'b1;
    if (wmask[15:8]  != 8'h00 && wmask[15:8]  != 8'hFF) need_rd = 1'b1;
    if (wmask[23:16] != 8'h00 && wmask[23:16] != 8'hFF) need_rd = 1'b1;
    if (wmask[31:24] != 8'h00 && wmask[31:24] != 8'hFF) need_rd = 1'b1;
    if (wmask[39:32] != 8'h00 && wmask[39:32] != 8'hFF) need_rd = 1'b1;
    if (wmask[47:40] != 8'h00 && wmask[47:40] != 8'hFF) need_rd = 1'b1;
    // SDRAM: the MiSTer SDRAM module ignores DQM (lesson 10570, measured), so every DRAM write must be a
    // whole merged 16-bit word: byte-partial words are read-modify-written and stored with be=11.
    if (region == R_DRAM &&
        (wbe0 == 2'b01 || wbe0 == 2'b10 || wbe1 == 2'b01 || wbe1 == 2'b10 || wbe2 == 2'b01 || wbe2 == 2'b10))
      need_rd = 1'b1;
  end

  // ---- word address of window word i ---------------------------------------------------
  wire [19:0] wi0 = l_addr[23:4];
  wire [19:0] wi_w = wi0 + {18'd0, wcnt};
  wire [19:0] wi_r = wi0 + {18'd0, rcnt};

  // ---- line cache for ROM + DRAM reads ---------------------------------------------
  // Direct mapped, 64 lines x 4 words (4-word aligned SDRAM bursts = one icache
  // sub-segment fill). Indexed by the SDRAM word address: data address sw[7:0],
  // line sw[7:2], tag sw[23:8]. DRAM writes are write-through and update a
  // present line; DRAM writes are posted (sd_pend) so the CPU does not wait.
  localparam CL = 7;                                  // log2(lines): 128 lines x 4 words
  localparam CT = 24 - (CL + 2);                      // tag bits
  (* ramstyle = "MLAB, no_rw_check" *) reg [CT-1:0] c_tag [0:(1<<CL)-1];   // MLAB (async read), no reset
  reg [(1<<CL)-1:0] c_v;
  reg [7:0]  c_lo [0:(4<<CL)-1];
  reg [7:0]  c_hi [0:(4<<CL)-1];
  reg        c_wen;
  reg [CL+1:0] c_wa;
  reg [15:0] c_wd;
  reg [1:0]  c_wbe;
  always @(posedge clk) begin
    if (c_wen && c_wbe[0]) c_lo[c_wa] <= c_wd[7:0];
    if (c_wen && c_wbe[1]) c_hi[c_wa] <= c_wd[15:8];
  end
  wire [23:0] sw_r = (region == R_ROM) ? {4'd0, wi_r[19:0]}
                   : IS_SLAVE ? (SLAVE_DRAM_BASE | {5'd0, wi_r[18:0]})
                              : (MASTER_DRAM_BASE | {6'd0, wi_r[17:0]});
  wire [23:0] sw_w = IS_SLAVE ? (SLAVE_DRAM_BASE | {5'd0, wi_w[18:0]})
                              : (MASTER_DRAM_BASE | {6'd0, wi_w[17:0]});
  reg  [15:0] c_rdq_r;
  always @(posedge clk) c_rdq_r <= {c_hi[sw_r[CL+1:0]], c_lo[sw_r[CL+1:0]]};
  assign c_rdq_w = c_rdq_r;
  assign c_hit   = c_v[sw_r[CL+1:2]] && (c_tag[sw_r[CL+1:2]] == sw_r[23:CL+2]);
  wire        c_hit_w = c_v[sw_w[CL+1:2]] && (c_tag[sw_w[CL+1:2]] == sw_w[23:CL+2]);
  reg  [63:0] f_dat;
  reg  [CL-1:0] f_idx;
  reg  [CT-1:0] f_tag;
  reg  [2:0]  f_cnt;
  // posted-write queue (4 entries): DRAM writes are acknowledged to the CPU when queued
  // and drained to SDRAM in the background; reads that miss wait for an empty queue.
  reg         sd_inflight;        // head entry is on the SDRAM port
  reg  [23:0] wq_a [0:3];
  reg  [15:0] wq_d [0:3];
  reg  [1:0]  wq_b [0:3];
  reg  [1:0]  wq_h, wq_t;
  reg  [2:0]  wq_cnt;
  // read bypass: a line fill may be issued ahead of queued writes unless one of them targets the same 4-word line
  reg         wq_conf;
  always @* begin
    wq_conf = 1'b0;
    for (int i = 0; i < 4; i++)
      if (3'(2'(i) - wq_h) < wq_cnt && wq_a[i][23:2] == sw_r[23:2]) wq_conf = 1'b1;
  end

  // ---- shift-register transfers under DPYCTL.SRT (MAME 34010gfx.hxx) --------------------------
  //   PIXT            : read = MTR, write = RTM (single pixel, no history)
  //   DRAV / LINE     : write = RTM per pixel; their read-modify-write read is NOT issued (lesson 2036)
  //   FILL            : word write = RTM (once per word), read = dummy (no transfer)
  //   PIXBLT          : word read = MTR (src; dst only when the op needs the destination), word write = RTM
  // MAME works on 16-bit words; the core's engines work per pixel, so repeated accesses to the same word
  // within one instruction are folded (history cleared on every instruction fetch).
  reg        h_sr_v, h_dr_v, h_w_v;
  reg [15:0] h_sr, h_dr, h_w;
  wire [15:0] cur_w = l_addr[19:4];
  reg        srt_skip;
  always @* begin
    srt_skip = 1'b0;
    case (eng)
      3'd1: srt_skip = 1'b0;                                                     // PIXT
      3'd4: srt_skip = !l_we;                                                    // DRAV/LINE read
      3'd2: srt_skip = !l_we || (h_w_v && h_w == cur_w);                         // FILL
      3'd3: begin                                                                // PIXBLT
        if (l_we)              srt_skip = (h_w_v  && h_w  == cur_w);
        else if (esub == 2'd0) srt_skip = (h_sr_v && h_sr == cur_w);
        else                   srt_skip = !ers || (h_dr_v && h_dr == cur_w);
      end
      default: srt_skip = 1'b0;
    endcase
  end

  // ---- state machine -----------------------------------------------------------------
  // Word-wise pixel-engine writes to the host data port (MAME's PIXBLT/FILL assemble whole 16-bit words and write each word
  // once; the per-pixel engine here would write the port once per pixel, advancing the auto-incrementing HSTADR twice as
  // fast for 8-bit pixels and corrupting the slave memory image). Pixel writes to the same HSTDATA word are merged in a
  // one-word buffer; it is written out when the word changes, another access arrives, or the instruction ends (srt_clr).
  reg         pw_v, pw_fl;
  reg  [27:0] pw_a;
  reg  [15:0] pw_d, pw_m;          // buffered data / bits written so far (a partial word is read-merged when flushed)
  reg         pw_rd;                // flush read issued
  localparam [3:0] S_PWF = 4'd10;
  wire pw_cand = l_we && (region == R_PER) && (psel == PS_HDATA) && (eng == 3'd2 || eng == 3'd3) && (nw == 2'd1);
  wire pw_hit  = pw_v && pw_cand && (pw_a == l_addr[31:4]);
  localparam [3:0] S_IDLE = 4'd0, S_RD = 4'd2, S_RDW = 4'd3,
                   S_WR = 4'd4, S_WRW = 4'd5, S_RESP = 4'd6, S_SRT = 4'd7,
                   S_FILLW = 4'd8, S_FILL = 4'd9;
  wire rd_wait = (st == S_RDW) && ((region == R_DRAM) || (region == R_ROM)) && !c_hit && !wq_conf;
  wire rd_go   = rd_wait && !sd_inflight && !sd_req;   // line fill takes the SDRAM port this clk (priority over the drain)
  reg [2:0] tmo;
  reg [31:0] rdata_r;
  reg        ack_r;
  reg        fin_c;            // combinational completion (same-cycle ack)
  reg        v_pend;           // a posted VRAM write is outstanding
  assign ack   = ack_r | fin_c;
  assign rdata = (fin_c && dir_rd) ? rd_field : rdata_r;
  reg [1:0] wbe_sel;
  reg [15:0] wr_word;
  reg [1:0]  wr_be;

  `define PUTWIN(I, D) case (I) 2'd0: win0 <= (D); 2'd1: win1 <= (D); default: win2 <= (D); endcase

  wire last_w = (wcnt == 2'd2) || ((wcnt == 2'd1) && (wbe2 == 2'b00)) ||
                ((wcnt == 2'd0) && (wbe1 == 2'b00) && (wbe2 == 2'b00));
  always @* begin
    case (wcnt)
      2'd0: begin wr_word = mw0; wr_be = wbe0; end
      2'd1: begin wr_word = mw1; wr_be = wbe1; end
      default: begin wr_word = mw2; wr_be = wbe2; end
    endcase
  end

  wire wq_push = (st == S_WR) && (wcnt != 2'd3) && (wr_be != 2'b00) && (region == R_DRAM) && (wq_cnt != 3'd4);
  wire wq_pop  = sd_inflight && sd_ack;
  // same-cycle (combinational) completion
  always @* begin
    fin_c = 1'b0;
    if (!rst) begin
      if (st == S_RDW && (region == R_DRAM || region == R_ROM) && dir_rd) fin_c = 1'b1;
      if (st == S_WR && region == R_DRAM && !(wcnt == 2'd3) && wr_be != 2'b00 && (wq_cnt != 3'd4) && last_w) fin_c = 1'b1;
      if (st == S_WR && region == R_VRAM && !(wcnt == 2'd3) && wr_be != 2'b00 && !v_pend && !v_req && last_w) fin_c = 1'b1;
      if (st == S_WR && (region == R_CLUT || region == R_NV) && !(wcnt == 2'd3) && wr_be != 2'b00 && last_w) fin_c = 1'b1;
      if (st == S_WRW && per_ack && last_w) fin_c = 1'b1;
    end
  end

  always @(posedge clk) begin
    ack_r    <= 1'b0;
    pal_we   <= 1'b0;
    nv_we    <= 1'b0;
    if (rst) begin
      st <= S_IDLE; rdata_r <= 32'h0; wcnt <= 2'd0; rcnt <= 2'd0; tmo <= 3'd0;
      sd_req <= 1'b0; sd_we <= 1'b0; sd_addr <= 24'h0; sd_din <= 16'h0; sd_be <= 2'b00; sd_burst <= 3'd1;
      v_req <= 1'b0; v_we <= 1'b0; v_addr <= 16'h0; v_wdata <= 16'h0; v_be <= 2'b00;
      v_srt_rd <= 1'b0; v_srt_wr <= 1'b0;
      pal_addr <= 11'h0; pal_wdata <= 16'h0; pal_be <= 2'b00;
      nv_addr <= 11'h0; nv_wdata <= 16'h0; nv_be <= 2'b00;
      per_req <= 1'b0; per_we <= 1'b0; per_sel <= PS_NONE; per_wdata <= 16'h0;
      win0 <= 16'h0; win1 <= 16'h0; win2 <= 16'h0;
      h_sr_v <= 1'b0; h_dr_v <= 1'b0; h_w_v <= 1'b0; h_sr <= 16'h0; h_dr <= 16'h0; h_w <= 16'h0; v_pend <= 1'b0; c_v <= '0; c_wen <= 1'b0; c_wa <= '0; c_wd <= 16'h0; c_wbe <= 2'b00; sd_inflight <= 1'b0; wq_h <= 2'd0; wq_t <= 2'd0; wq_cnt <= 3'd0; pw_v <= 1'b0; pw_fl <= 1'b0; pw_a <= 28'h0; pw_d <= 16'h0; pw_m <= 16'h0; pw_rd <= 1'b0;
      f_dat <= 64'h0; f_idx <= '0; f_tag <= '0; f_cnt <= 3'd0;
    end else begin
      c_wen <= 1'b0;
      if (srt_clr) begin h_sr_v <= 1'b0; h_dr_v <= 1'b0; h_w_v <= 1'b0; pw_fl <= 1'b1; end
      if (rom_inval) c_v <= '0;
      wq_cnt <= wq_cnt + {2'b00, wq_push} - {2'b00, wq_pop};
      // background drain of the posted-write queue
      if (sd_inflight && sd_ack) begin
        wq_h <= wq_h + 2'd1;
        if (wq_cnt >= 3'd2 && !rd_wait) begin   // back-to-back (not when a read is waiting for the port): present the next posted write at once
          sd_addr <= wq_a[wq_h + 2'd1]; sd_din <= wq_d[wq_h + 2'd1]; sd_be <= wq_b[wq_h + 2'd1];
        end else begin
          sd_req <= 1'b0; sd_we <= 1'b0; sd_inflight <= 1'b0;
        end
      end else if (!sd_req && !sd_inflight && wq_cnt != 3'd0 && !rd_go) begin
        sd_req <= 1'b1; sd_we <= 1'b1; sd_burst <= 3'd1;
        sd_addr <= wq_a[wq_h]; sd_din <= wq_d[wq_h]; sd_be <= wq_b[wq_h]; sd_inflight <= 1'b1;
      end
      if (v_pend && v_ack)   begin v_req <= 1'b0; v_we <= 1'b0; v_pend <= 1'b0; end
      case (st)
        // ------------------------------------------------------------------
        S_IDLE: begin
          if (pw_v && ((req && !ack && region == R_PER && !pw_hit) || pw_fl)) st <= S_PWF;   // write the pending word out first (other regions do not observe it)
          else if (req && !ack && pw_hit) begin
            pw_d <= (pw_d & ~wmask[15:0]) | (mw0 & wmask[15:0]);   // merge this pixel into the buffered word
            pw_m <= pw_m | wmask[15:0];
            st <= S_RESP;
          end
          else if (req && !ack) begin
            win0 <= 16'h0; win1 <= 16'h0; win2 <= 16'h0;
            wcnt <= 2'd0; rcnt <= 2'd0;
            if (srt_on && region == R_VRAM && (l_pix || eng != 3'd0)) begin
              if (srt_skip) begin rdata_r <= 32'h0; st <= S_RESP; end   // dummy read / repeated word: no transfer
              else          st <= S_SRT;
            end
            else if (l_we && !need_rd)               st <= S_WR;    // whole bytes covered: no read phase
            else                                     st <= S_RD;
          end
        end
        // ------------------------------------------------------------------
        // Shift-register transfer (PIXT with DPYCTL.SRT)
        S_SRT: begin
          if (eng == 3'd2 || eng == 3'd3) begin
            if (l_we) begin h_w_v <= 1'b1; h_w <= cur_w; end
            else if (esub == 2'd0) begin h_sr_v <= 1'b1; h_sr <= cur_w; end
            else begin h_dr_v <= 1'b1; h_dr <= cur_w; end
          end
          if (!v_req && !v_pend) begin
            v_req <= 1'b1; v_we <= l_we; v_addr <= l_addr[19:4];
            v_srt_rd <= !l_we; v_srt_wr <= l_we; v_be <= 2'b00; v_wdata <= 16'h0;
          end else if (v_ack) begin
            v_req <= 1'b0; v_srt_rd <= 1'b0; v_srt_wr <= 1'b0;
            st <= S_RESP;
          end
        end
        // ------------------------------------------------------------------
        // Read phase: issue the read of window word rcnt (DRAM: one burst).
        S_RD: begin
          st <= S_RDW;
          case (region)
            R_VRAM: if (v_pend) st <= S_RD;       // order after a posted write
                    else begin
              v_req <= 1'b1; v_we <= 1'b0; v_addr <= wi_r[15:0]; v_be <= 2'b11;
              v_srt_rd <= 1'b0; v_srt_wr <= 1'b0;
            end
            R_DRAM, R_ROM: ;                    // index presented; hit/miss resolved in S_RDW
            R_CLUT: begin pal_addr <= wi_r[10:0]; tmo <= 3'd2; end
            R_NV:   begin nv_addr  <= wi_r[10:0]; tmo <= 3'd2; end
            R_PER: begin
              per_req <= 1'b1; per_we <= 1'b0; per_sel <= psel;
            end
            default: begin   // unmapped / I/O register space: reads 0
              if (rcnt + 2'd1 >= nw) st <= l_we ? S_WR : S_RESP;
              else begin rcnt <= rcnt + 2'd1; st <= S_RD; end
            end
          endcase
        end
        // ------------------------------------------------------------------
        S_RDW: begin
          case (region)
            R_VRAM: if (!v_req) st <= S_RD;       // posted write was pending: re-issue the read
            else if (v_ack) begin
              v_req <= 1'b0; `PUTWIN(rcnt, v_rdata)
              if (rcnt + 2'd1 >= nw) st <= l_we ? S_WR : S_RESP;
              else begin rcnt <= rcnt + 2'd1; st <= S_RD; end
            end
            R_DRAM, R_ROM: begin
              if (c_hit) begin
                `PUTWIN(rcnt, c_rdq)
                if (dir_rd) begin rdata_r <= rd_field; st <= S_IDLE; end   // same-cycle ack (fin_c)
                else if (rcnt + 2'd1 >= nw) st <= l_we ? S_WR : S_RESP;
                else begin rcnt <= rcnt + 2'd1; st <= S_RD; end
              end else if (!wq_conf && !sd_inflight && !sd_req) begin
                sd_req <= 1'b1; sd_we <= 1'b0; sd_burst <= 3'd4; sd_addr <= {sw_r[23:2], 2'b00};
                st <= S_FILLW;
              end
            end
            R_CLUT, R_NV: begin
              if (tmo != 3'd0) tmo <= tmo - 3'd1;
              else begin
                `PUTWIN(rcnt, (region == R_CLUT) ? pal_rdata : nv_rdata)
                if (rcnt + 2'd1 >= nw) st <= l_we ? S_WR : S_RESP;
                else begin rcnt <= rcnt + 2'd1; st <= S_RD; end
              end
            end
            R_PER: if (per_ack) begin
              per_req <= 1'b0; `PUTWIN(rcnt, per_rdata)
              if (rcnt + 2'd1 >= nw) st <= l_we ? S_WR : S_RESP;
              else begin rcnt <= rcnt + 2'd1; st <= S_RD; end
            end
            default: st <= S_RESP;
          endcase
        end
        // ------------------------------------------------------------------
        S_FILLW: if (sd_ack) begin
          sd_req <= 1'b0;
          f_dat <= sd_dout; f_idx <= sw_r[CL+1:2]; f_tag <= sw_r[23:CL+2]; f_cnt <= 3'd0;
          `PUTWIN(rcnt, sd_dout[16*sw_r[1:0] +: 16])
          st <= S_FILL;
        end
        S_FILL: begin
          if (f_cnt[2] == 1'b0) begin
            c_wen <= 1'b1; c_wa <= {f_idx, f_cnt[1:0]}; c_wbe <= 2'b11;
            c_wd <= f_dat[16*f_cnt[1:0] +: 16];
          end
          f_cnt <= f_cnt + 3'd1;
          if (f_cnt == 3'd4) begin   // one idle cycle so the last word is in the array
            c_tag[f_idx] <= f_tag; c_v[f_idx] <= !rom_inval;
            if (rcnt + 2'd1 >= nw) st <= l_we ? S_WR : S_RESP;
            else begin rcnt <= rcnt + 2'd1; st <= S_RD; end
          end
        end
        // ------------------------------------------------------------------
        // Write phase: wcnt walks the three window words.
        S_WR: begin
          if (wcnt == 2'd3) begin
            st <= S_RESP;
          end else if (wr_be == 2'b00 || region == R_NONE || region == R_ROM) begin
            if (wcnt == 2'd2) begin st <= S_RESP; wcnt <= 2'd0; end
            else wcnt <= wcnt + 2'd1;
          end else if (region == R_DRAM) begin
            // posted write-through: issue, update the cache line if present, do not wait
            if (wq_cnt != 3'd4) begin
              wq_a[wq_t] <= sw_w; wq_d[wq_t] <= wr_word; wq_b[wq_t] <= 2'b11; wq_t <= wq_t + 2'd1;   // whole merged word (DQM ignored on HW)
              if (c_hit_w) begin c_wen <= 1'b1; c_wa <= sw_w[CL+1:0]; c_wd <= wr_word; c_wbe <= 2'b11; end
              wcnt <= wcnt + 2'd1;
              if (last_w) st <= S_IDLE;                                  // same-cycle ack (fin_c)
            end
          end else if (region == R_VRAM) begin
            // posted VRAM write: the lane-2 port completes it in the background
            if (!v_pend && !v_req) begin
              v_req <= 1'b1; v_we <= 1'b1; v_addr <= wi_w[15:0]; v_wdata <= wr_word; v_be <= wr_be;
              v_srt_rd <= 1'b0; v_srt_wr <= 1'b0; v_pend <= 1'b1;
              wcnt <= wcnt + 2'd1;
              if (last_w) st <= S_IDLE;
            end
          end else if (region == R_CLUT || region == R_NV) begin
            if (region == R_CLUT) begin pal_addr <= wi_w[10:0]; pal_wdata <= wr_word; pal_be <= wr_be; pal_we <= 1'b1; end
            else                  begin nv_addr  <= wi_w[10:0]; nv_wdata  <= wr_word; nv_be  <= wr_be; nv_we  <= 1'b1; end
            wcnt <= wcnt + 2'd1;
            if (last_w) st <= S_IDLE;
          end else if (pw_cand) begin
            pw_v <= 1'b1; pw_fl <= 1'b0; pw_a <= l_addr[31:4]; pw_d <= wr_word; pw_m <= need_rd ? 16'hFFFF : wmask[15:0];   // buffered word-wise engine write
            wcnt <= 2'd0; st <= S_RESP;
          end else begin
            st <= S_WRW;                                                 // R_PER
            per_req <= 1'b1; per_we <= 1'b1; per_sel <= psel; per_wdata <= wr_word;
          end
        end
        // ------------------------------------------------------------------
        S_PWF: begin   // write the buffered HSTDATA word (read-merge first if only some bits were written)
          if (pw_m != 16'hFFFF && !pw_rd) begin
            if (!per_req) begin per_req <= 1'b1; per_we <= 1'b0; per_sel <= PS_HDATA; end
            else if (per_ack) begin per_req <= 1'b0; pw_d <= (per_rdata & ~pw_m) | (pw_d & pw_m); pw_m <= 16'hFFFF; end
          end else begin
            if (!per_req) begin per_req <= 1'b1; per_we <= 1'b1; per_sel <= PS_HDATA; per_wdata <= pw_d; end
            else if (per_ack) begin per_req <= 1'b0; per_we <= 1'b0; pw_v <= 1'b0; pw_fl <= 1'b0; st <= S_IDLE; end
          end
        end
        S_WRW: begin   // R_PER write only
          if (per_ack) begin
            per_req <= 1'b0; per_we <= 1'b0; wcnt <= wcnt + 2'd1;
            if (last_w) st <= S_IDLE; else st <= S_WR;                   // same-cycle ack (fin_c) when last
          end
        end
        // ------------------------------------------------------------------
        S_RESP: begin
          ack_r <= 1'b1;
          if (!l_we) rdata_r <= rd_field;
          st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
