// -----------------------------------------------------------------------------
// exterm_vram.sv -- 64K x 16 VRAM (used for BG/master and FG/slave) with
//   * port A: CPU (read/write with byte enables, plus VRAM shift-register transfer)
//   * port B: scanout read (1-cycle latency)
// and the shared true-dual-port primitive `exterm_dpram_be`.
//
// CPU protocol (contract section 1):
//   Requester raises req (plus we/addr/wdata/be, or srt_rd / srt_wr) and holds it until
//   `ack` (a 1-clk pulse; rdata valid in the same cycle for reads).  One idle cycle
//   (the cycle after ack) is ignored so a requester that drops req one clock late
//   cannot cause a double access.  A transaction is `req | srt_rd | srt_wr`.
//
//   Normal access  : req->ack = 5 clk.
//   srt_rd         : to_shiftreg   -> shiftreg[0..255] = vram[{addr[15:8], 0..255}]
//   srt_wr         : from_shiftreg -> vram[{addr[15:8], 0..255}] = shiftreg[0..255]
//                    (the real TMS4461-class VRAM moves one whole 256-word row per transfer cycle)
//                    POSTED: the row is queued (256 deep) and ack'd ~2 clk later if there is room;
//                    a background engine copies the (constant) shift buffer. Any other CPU access
//                    (read/write/srt_rd) waits until queue and engine are idle, so ordering is
//                    preserved. Scanout shows a row once the engine has reached it.  Shift buffer is
//                    private to this instance (one per GSP, like MAME's m_shiftreg) and untouched by
//                    normal accesses.  Scanout (port B) is independent and never stalls.
//
//   Speed: the RAM is 8 interleaved banks (word bank = addr[2:0]) and the shift buffer is 32 x 128,
//   so a row moves 8 words per clock (34 clk per row, was 258). On real hardware a row transfer is a
//   single memory cycle; the slave clears ~100 rows with SRT every frame (DINT handler at FFFFF700)
//   and then redraws its whole display list before the next DINT flips the buffer -- with 258 clk
//   per row the drain stall (~26K clk, 7.7% of a frame) exceeded the slave's ~6% slack in the title
//   "Gottlieb" scene, so the last-drawn text ("...Pest Control Man!") was shown half-drawn.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
`default_nettype none
module exterm_vram (
  input  wire        clk,
  input  wire        rst,
  // CPU port
  input  wire        req,
  input  wire        we,
  input  wire [15:0] addr,        // word address
  input  wire [15:0] wdata,
  input  wire [1:0]  be,
  input  wire        srt_rd,
  input  wire        srt_wr,
  output reg  [15:0] rdata,
  output reg         ack,
  // scanout port
  input  wire [15:0] scan_addr,
  output wire [15:0] scan_data
);
  typedef enum logic [2:0] {S_IDLE, S_ACC, S_RES, S_ACK, S_SR} st_t;
  st_t st;

  reg        cool;                // ignore request in the cycle after ack
  reg [15:0] r_addr, r_wdata;
  reg [1:0]  r_be;
  reg        r_we;
  reg [7:0]  row;
  reg [5:0]  cnt;                 // 0..32 (one step = 8 words)

  // ---- posted shift-register writes: queue of destination rows + background copy engine ----
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] fq [0:255];
  reg  [7:0] fq_q;
  reg  [7:0] fq_wp, fq_rp;
  reg  [8:0] qcnt;                // 0..256 queued rows
  reg  [1:0] eng;                 // 0 idle, 1 fetch row, 2 copying
  reg  [7:0] erow;
  wire       q_full  = qcnt[8];
  wire       drained = (qcnt == 9'd0) && (eng == 2'd0);
  wire       eng_run = (eng == 2'd2);

  // shift-register buffer: 32 entries x 8 words (entry k word j = shiftreg[8k+j]); simple dual port, sync read
  (* ramstyle = "M10K, no_rw_check" *) reg [127:0] sbuf [0:31];
  reg  [127:0] sbuf_q;
  wire [4:0]   sbuf_ra = cnt[4:0];
  wire         sbuf_we = (st == S_SR) && (cnt != 6'd0);
  wire [4:0]   sbuf_wa = cnt[4:0] - 5'd1;
  wire [127:0] a_q;               // all 8 banks, word j at [16j +: 16]
  wire         push = (st == S_IDLE) && srt_wr && !cool && !q_full;
  always_ff @(posedge clk) begin
    if (sbuf_we) sbuf[sbuf_wa] <= a_q;
    sbuf_q <= sbuf[sbuf_ra];
    if (push) fq[fq_wp] <= addr[15:8];
    fq_q <= fq[fq_rp];
  end

  // port A drive: one shared 13-bit bank index; CPU accesses enable one bank, a row move enables all 8
  reg  [12:0]  a_idx;
  reg  [127:0] a_din;
  reg  [7:0]   a_we;
  reg  [1:0]   a_be;
  always_comb begin
    a_idx = r_addr[15:3]; a_din = {8{r_wdata}}; a_be = r_be;
    a_we  = (st == S_ACC && r_we) ? (8'd1 << r_addr[2:0]) : 8'd0;
    if (st == S_SR) begin
      a_idx = {row, cnt[4:0]}; a_we = 8'd0;
    end else if (eng_run) begin
      a_idx = {erow, cnt[4:0] - 5'd1}; a_din = sbuf_q; a_be = 2'b11; a_we = {8{cnt != 6'd0}};
    end
  end

  exterm_vram_ram u_ram (
    .clk(clk),
    .idx_a(a_idx), .din_a(a_din), .we_a(a_we), .be_a(a_be), .q_a(a_q),
    .addr_b(scan_addr), .q_b(scan_data)
  );

  wire want = req | srt_rd | srt_wr;
  wire pop  = (eng == 2'd1);
  wire [15:0] a_qw = a_q[{r_addr[2:0], 4'd0} +: 16];

  always_ff @(posedge clk) begin
    ack <= 1'b0;
    if (rst) begin
      st <= S_IDLE; cool <= 1'b0; cnt <= 6'd0; rdata <= 16'd0;
      r_we <= 1'b0; r_addr <= 16'd0; r_wdata <= 16'd0; r_be <= 2'b11; row <= 8'd0;
      fq_wp <= 8'd0; fq_rp <= 8'd0; qcnt <= 9'd0; eng <= 2'd0; erow <= 8'd0;
    end else begin
      // queue bookkeeping
      if (push) fq_wp <= fq_wp + 8'd1;
      if (pop)  fq_rp <= fq_rp + 8'd1;
      qcnt <= qcnt + {8'd0, push} - {8'd0, pop};
      // copy engine (only while the CPU side is idle in S_IDLE; CPU ops other than posting wait for drained)
      case (eng)
        2'd0: if (qcnt != 9'd0) eng <= 2'd1;
        2'd1: begin erow <= fq_q; cnt <= 6'd0; eng <= 2'd2; end
        2'd2: begin
          cnt <= cnt + 6'd1;
          if (cnt == 6'd32) eng <= 2'd0;
        end
        default: eng <= 2'd0;
      endcase
      case (st)
        S_IDLE: begin
          cool <= 1'b0;
          if (want && !cool) begin
            if (srt_wr) begin                          // posted: ack immediately if room
              if (!q_full) begin ack <= 1'b1; cool <= 1'b1; end
            end else if (drained) begin                // everything else waits for the queue to drain
              r_addr <= addr; r_wdata <= wdata; r_be <= be; r_we <= we;
              row <= addr[15:8]; cnt <= 6'd0;
              if (srt_rd) st <= S_SR;
              else        st <= S_ACC;
            end
          end
        end
        S_ACC: st <= S_RES;                       // RAM samples address/control at end of this cycle
        S_RES: begin rdata <= a_qw; st <= S_ACK; end
        S_ACK: begin ack <= 1'b1; cool <= 1'b1; st <= S_IDLE; end
        S_SR: begin
          cnt <= cnt + 6'd1;
          if (cnt == 6'd32) st <= S_ACK;          // last buffer write happened this cycle
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule

// -----------------------------------------------------------------------------
// exterm_vram_ram -- 64K x 16 VRAM as 8 interleaved banks (bank = word addr[2:0]).
//   Port A: 8 lanes share one bank index idx_a (= word addr[15:3]); lane j writes bank j when we_a[j]
//           (byte enables be_a common); q_a returns all 8 banks (1-clock latency).
//   Port B: scanout, one 16-bit word at addr_b (1-clock latency).
// Simulation keeps one flat `mem` array (debug dumps / tb_frame load it by name).
// -----------------------------------------------------------------------------
module exterm_vram_ram (
  input  wire         clk,
  input  wire [12:0]  idx_a,
  input  wire [127:0] din_a,
  input  wire [7:0]   we_a,
  input  wire [1:0]   be_a,
  output wire [127:0] q_a,
  input  wire [15:0]  addr_b,
  output wire [15:0]  q_b
);
`ifdef VERILATOR
  reg [15:0]  mem [0:65535] /*verilator public_flat_rw*/;
  reg [127:0] rq_a;
  reg [15:0]  rq_b;
  integer j;
  always @(posedge clk) begin
    for (j = 0; j < 8; j = j + 1) begin
      if (we_a[j]) begin
        if (be_a[1]) mem[{idx_a, j[2:0]}][15:8] <= din_a[16*j+8 +: 8];
        if (be_a[0]) mem[{idx_a, j[2:0]}][7:0]  <= din_a[16*j   +: 8];
        rq_a[16*j +: 16] <= {be_a[1] ? din_a[16*j+8 +: 8] : mem[{idx_a, j[2:0]}][15:8],
                             be_a[0] ? din_a[16*j   +: 8] : mem[{idx_a, j[2:0]}][7:0]};
      end else
        rq_a[16*j +: 16] <= mem[{idx_a, j[2:0]}];
    end
    rq_b <= mem[addr_b];
  end
  assign q_a = rq_a;
  assign q_b = rq_b;
`else
  wire [15:0] qb [0:7];
  reg  [2:0]  bsel_b;
  always @(posedge clk) bsel_b <= addr_b[2:0];
  assign q_b = qb[bsel_b];
  genvar gj;
  generate
    for (gj = 0; gj < 8; gj = gj + 1) begin : g_bank
      exterm_dpram_be #(.AW(13)) u_bank (
        .clk(clk),
        .addr_a(idx_a), .din_a(din_a[16*gj +: 16]), .we_a(we_a[gj]), .be_a(be_a), .q_a(q_a[16*gj +: 16]),
        .addr_b(addr_b[15:3]), .q_b(qb[gj])
      );
    end
  endgenerate
`endif
endmodule

// -----------------------------------------------------------------------------
// exterm_dpram_be -- 64K x 16 true-dual-port RAM, port A R/W with byte enables,
// port B read only.  Both ports: 1-clock read latency (address register inside the
// RAM, unregistered q).  Port A read-during-write returns the new data.
// Quartus 17 does not infer a byte-enabled TDP from behavioural code reliably, so
// the FPGA build instantiates altsyncram directly (same settings as the proven
// NARC dpram_tdp); simulation takes the behavioural branch.
// -----------------------------------------------------------------------------
module exterm_dpram_be #(
  parameter int AW = 16
) (
  input  wire          clk,
  input  wire [AW-1:0] addr_a,
  input  wire [15:0]   din_a,
  input  wire          we_a,
  input  wire [1:0]    be_a,
  output wire [15:0]   q_a,
  input  wire [AW-1:0] addr_b,
  output wire [15:0]   q_b
);
`ifdef VERILATOR
  reg [15:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;
  reg [15:0] rq_a, rq_b;
  wire [15:0] cur = mem[addr_a];
  wire [15:0] nxt = {be_a[1] ? din_a[15:8] : cur[15:8], be_a[0] ? din_a[7:0] : cur[7:0]};
  always @(posedge clk) begin
    if (we_a) begin mem[addr_a] <= nxt; rq_a <= nxt; end
    else      rq_a <= cur;
    rq_b <= mem[addr_b];
  end
  assign q_a = rq_a;
  assign q_b = rq_b;
`else
  altsyncram #(
    .operation_mode                    ("BIDIR_DUAL_PORT"),
    .width_a                           (16),
    .widthad_a                         (AW),
    .numwords_a                        (1 << AW),
    .width_byteena_a                   (2),
    .width_b                           (16),
    .widthad_b                         (AW),
    .numwords_b                        (1 << AW),
    .width_byteena_b                   (1),
    .outdata_reg_a                     ("UNREGISTERED"),
    .outdata_reg_b                     ("UNREGISTERED"),
    .address_reg_b                     ("CLOCK0"),
    .indata_reg_b                      ("CLOCK0"),
    .wrcontrol_wraddress_reg_b         ("CLOCK0"),
    .byteena_reg_b                     ("CLOCK0"),
    .rdcontrol_reg_b                   ("CLOCK0"),
    .read_during_write_mode_port_a     ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b     ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_mixed_ports("OLD_DATA"),
    .ram_block_type                    ("M10K"),
    .intended_device_family            ("Cyclone V"),
    .power_up_uninitialized            ("TRUE"),
    .clock_enable_input_a              ("BYPASS"),
    .clock_enable_input_b              ("BYPASS"),
    .clock_enable_output_a             ("BYPASS"),
    .clock_enable_output_b             ("BYPASS"),
    .lpm_type                          ("altsyncram")
  ) u_ram (
    .clock0    (clk),
    .address_a (addr_a), .data_a (din_a), .wren_a (we_a), .byteena_a (be_a), .q_a (q_a),
    .address_b (addr_b), .data_b (16'd0), .wren_b (1'b0), .byteena_b (1'b1), .q_b (q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif
endmodule
`default_nettype wire
