// -----------------------------------------------------------------------------
// exterm_sdram_arb.sv -- one SDRAM port shared by master GSP, slave GSP and the
// ROM-download path.
//
// Client protocol (m_*, s_*): hold *_req with stable we/addr/din/be/burst until
// the one-cycle *_ack pulse; read data is then valid on rd_dout (held until the
// next transaction). Drop *_req on ack.
//
// Downstream (sd_*, to rtl/mem/sdram.sv or sim/sdram_model.sv): sd_req is held
// until sd_ack is seen, then dropped; the arbiter waits for sd_ack to fall
// (ACK_HOLD across the 4:1 clock ratio) before it issues the next request.
//
// Priority: ROM loader > (master, slave round robin).
// -----------------------------------------------------------------------------
`default_nettype none
module exterm_sdram_arb (
  input  wire        clk,
  input  wire        rst,

  input  wire        m_req,
  input  wire        m_we,
  input  wire [23:0] m_addr,
  input  wire [15:0] m_din,
  input  wire [1:0]  m_be,
  input  wire [2:0]  m_burst,
  output reg         m_ack,

  input  wire        s_req,
  input  wire        s_we,
  input  wire [23:0] s_addr,
  input  wire [15:0] s_din,
  input  wire [1:0]  s_be,
  input  wire [2:0]  s_burst,
  output reg         s_ack,

  output reg  [63:0] rd_dout,

  // ROM download (byte stream in the maincpu region)
  input  wire        ld_en,
  input  wire        ld_wr,
  input  wire [23:0] ld_addr,
  input  wire [7:0]  ld_data,
  output wire        ld_busy,

  // SDRAM client port
  output reg         sd_req,
  output reg         sd_we,
  output reg  [23:0] sd_addr,
  output reg  [15:0] sd_din,
  output reg  [1:0]  sd_be,
  output reg  [2:0]  sd_burst,
  input  wire [63:0] sd_dout,
  input  wire        sd_ack
);

  // ---- loader latch -----------------------------------------------------------
  reg        ld_pend;
  reg [23:0] ld_a;
  reg [7:0]  ld_d;
  // Whole-word loader writes: the MiSTer SDRAM module ignores DQM (lesson 10570, measured on hardware), so a
  // byte-masked write would store {odd,odd}. The even byte is held and the pair is written as one be=11 word
  // when its odd byte arrives (same scheme as the hardware-proven NARC loader).
  reg        ld_have_lo, ld_pair;
  reg [23:1] ld_lo_a;
  reg [7:0]  ld_lo_d, ld_lo;
  wire       ld_in      = ld_en && ld_wr && !ld_pend && (ld_addr[23:21] == 3'b000);
  wire       ld_launch  = ld_in && ld_addr[0];            // the odd byte launches the paired SDRAM write
  assign ld_busy = ld_pend | ld_launch;                   // backpressure in the launching cycle

  typedef enum logic [1:0] { A_IDLE, A_WAIT, A_GAP } astate_t;
  reg armed;   // sd_ack seen low since the grant (a new request may be raised while the previous ack is still held)
  astate_t st;
  reg [2:0] owner;       // 0 = master read, 1 = slave read, 2 = loader, 3 = master posted write, 4 = slave posted write
  reg       last_m;      // round robin: last granted client was the master

  // Posted writes: a client write request is ACCEPTED into a one-entry buffer (ack = accepted) and written to SDRAM in the
  // background, so the client's request/ack turn-around overlaps the SDRAM write. Buffered writes are issued before any read
  // (in-order per client; the master's queue-bypass conflict check only has to cover entries still in its own queue).
  reg        mwb_v, swb_v;
  reg [23:0] mwb_a, swb_a;
  reg [15:0] mwb_d, swb_d;
  reg [1:0]  mwb_b, swb_b;
  wire m_acc = m_req && m_we && !mwb_v && !m_ack;
  wire s_acc = s_req && s_we && !swb_v && !s_ack;

  always @(posedge clk) begin
    m_ack <= 1'b0;
    s_ack <= 1'b0;
    if (rst) begin
      st <= A_IDLE; armed <= 1'b0; sd_req <= 1'b0; ld_pend <= 1'b0; ld_have_lo <= 1'b0; ld_pair <= 1'b0; last_m <= 1'b0; owner <= 3'd0;
      sd_we <= 1'b0; sd_addr <= 24'h0; sd_din <= 16'h0; sd_be <= 2'b00; sd_burst <= 3'd1;
      rd_dout <= 64'h0; mwb_v <= 1'b0; swb_v <= 1'b0;
      mwb_a <= 24'h0; swb_a <= 24'h0; mwb_d <= 16'h0; swb_d <= 16'h0; mwb_b <= 2'b00; swb_b <= 2'b00;
    end else begin
      if (ld_in) begin
        if (!ld_addr[0]) begin ld_have_lo <= 1'b1; ld_lo_a <= ld_addr[23:1]; ld_lo_d <= ld_data; end
        else begin
          ld_pend <= 1'b1; ld_a <= ld_addr; ld_d <= ld_data;
          ld_pair <= ld_have_lo && (ld_lo_a == ld_addr[23:1]); ld_lo <= ld_lo_d;
          ld_have_lo <= 1'b0;
        end
      end
      if (m_acc) begin mwb_v <= 1'b1; mwb_a <= m_addr; mwb_d <= m_din; mwb_b <= m_be; m_ack <= 1'b1; end
      if (s_acc) begin swb_v <= 1'b1; swb_a <= s_addr; swb_d <= s_din; swb_b <= s_be; s_ack <= 1'b1; end
      case (st)
        A_IDLE: begin
          if (ld_pend) begin
            owner   <= 3'd2;
            sd_we   <= 1'b1;
            sd_addr <= {3'b000, ld_a[21:1]};
            sd_din  <= ld_pair ? {ld_d, ld_lo} : {ld_d, ld_d};
            sd_be   <= ld_pair ? 2'b11 : 2'b10;          // an unpaired odd byte cannot occur in the MRA stream
            sd_burst<= 3'd1;
            sd_req  <= 1'b1; st <= A_WAIT; armed <= 1'b0;
          end else if (mwb_v && (!swb_v || !last_m)) begin
            owner <= 3'd3; last_m <= 1'b1; mwb_v <= 1'b0;
            sd_we <= 1'b1; sd_addr <= mwb_a; sd_din <= mwb_d; sd_be <= mwb_b; sd_burst <= 3'd1;
            sd_req <= 1'b1; st <= A_WAIT; armed <= 1'b0;
          end else if (swb_v) begin
            owner <= 3'd4; last_m <= 1'b0; swb_v <= 1'b0;
            sd_we <= 1'b1; sd_addr <= swb_a; sd_din <= swb_d; sd_be <= swb_b; sd_burst <= 3'd1;
            sd_req <= 1'b1; st <= A_WAIT; armed <= 1'b0;
          end else if (m_req && !m_we && (!s_req || s_we || !last_m)) begin
            owner   <= 3'd0; last_m <= 1'b1;
            sd_we   <= 1'b0; sd_addr <= m_addr; sd_din <= m_din; sd_be <= m_be; sd_burst <= m_burst;
            sd_req  <= 1'b1; st <= A_WAIT; armed <= 1'b0;
          end else if (s_req && !s_we) begin
            owner   <= 3'd1; last_m <= 1'b0;
            sd_we   <= 1'b0; sd_addr <= s_addr; sd_din <= s_din; sd_be <= s_be; sd_burst <= s_burst;
            sd_req  <= 1'b1; st <= A_WAIT; armed <= 1'b0;
          end
        end
        A_WAIT: begin
          if (!sd_ack) armed <= 1'b1;
          if (sd_ack && armed) begin
            if (!sd_we) rd_dout <= sd_dout;
            if (owner == 3'd0)      m_ack <= 1'b1;
            else if (owner == 3'd1) s_ack <= 1'b1;
            else if (owner == 3'd2) ld_pend <= 1'b0;
            if (owner >= 3'd3 && (mwb_v || swb_v) && !ld_pend) begin
              // back-to-back posted writes: keep the port busy, present the next one now
              armed <= 1'b0;
              if (mwb_v && (!swb_v || owner == 3'd4)) begin
                owner <= 3'd3; mwb_v <= 1'b0; sd_addr <= mwb_a; sd_din <= mwb_d; sd_be <= mwb_b;
              end else begin
                owner <= 3'd4; swb_v <= 1'b0; sd_addr <= swb_a; sd_din <= swb_d; sd_be <= swb_b;
              end
            end else begin
              sd_req <= 1'b0;
              st <= (owner >= 3'd3) ? A_IDLE : A_GAP;
            end
          end
        end
        A_GAP: st <= A_IDLE;   // one clk for the client to withdraw / replace its request
        default: st <= A_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
