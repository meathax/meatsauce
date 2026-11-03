//============================================================================
// Yellow Cab SDRAM controller — ROM download + 3 read ports.
// CL2, 16-bit, serialized. Init: PRECHARGE ALL → REF×2 → MRS → idle.
// Refresh ~every 750 cycles @96 MHz (8192/64ms).
// Request: level held or pulse; ack held ≥2 cycles for clk_sys CDC.
// Timing @96 MHz: tRCD/tRP/tWR ≥2 cycles (~20 ns).
//============================================================================

module sdram (
  input             clk,
  input             init,
  output reg        ready,

  inout      [15:0] SDRAM_DQ,
  output reg [12:0] SDRAM_A,
  output reg  [1:0] SDRAM_BA,
  output            SDRAM_DQML,
  output            SDRAM_DQMH,
  output            SDRAM_nCS,
  output            SDRAM_nCAS,
  output            SDRAM_nRAS,
  output            SDRAM_nWE,
  output            SDRAM_CKE,

  input             wr_req,
  input      [24:1] wr_addr,
  input      [15:0] wr_din,
  input       [1:0] wr_be,
  output reg        wr_ack,

  input             p0_req,
  input      [24:1] p0_addr,
  output reg [15:0] p0_dout,
  output reg        p0_ack,

  input             p1_req,
  input      [24:1] p1_addr,
  output reg [15:0] p1_dout,
  output reg        p1_ack,

  input             p2_req,
  input      [24:1] p2_addr,
  output reg [15:0] p2_dout,
  output reg        p2_ack
);

// Dedicated capture register: one I/O-cell flop per DQ pin so every bit has the same, short
// pin-to-register delay (p*_dout loading straight from the pins left half the bits in fabric).
(* useioff = 1 *) reg [15:0] dq_in;
always @(posedge clk) dq_in <= SDRAM_DQ;

reg [15:0] dq_out;
reg        dq_oe;
reg  [1:0] dqm;

assign SDRAM_CKE  = 1'b1;
assign SDRAM_DQML = dqm[0];
assign SDRAM_DQMH = dqm[1];
assign SDRAM_DQ   = dq_oe ? dq_out : 16'hZZZZ;

localparam CMD_NOP   = 4'b0111;
localparam CMD_ACT   = 4'b0011;
localparam CMD_READ  = 4'b0101;
localparam CMD_WRITE = 4'b0100;
localparam CMD_PRE   = 4'b0010;
localparam CMD_REF   = 4'b0001;
localparam CMD_MRS   = 4'b0000;

// Mode: burst=1, seq, CL2, write burst single
localparam [12:0] MODE = 13'b000_0_00_010_0_000;

reg [3:0] cmd = CMD_NOP;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

reg [15:0] init_cnt = 16'hffff;
reg  [3:0] init_step;
reg  [9:0] ref_cnt;
reg        ref_pend;
reg  [3:0] wait_cnt;
reg  [1:0] ack_hold; // stretch read/write ack for clk_sys CDC

typedef enum logic [3:0] {
  ST_INIT, ST_IDLE, ST_ACT, ST_RCD, ST_CMD, ST_CL1, ST_CL2, ST_CL3, ST_DATA,
  ST_WRWAIT, ST_PRE, ST_RP, ST_REF, ST_RFC
} state_t;

state_t state = ST_INIT;

reg [24:1] cur_addr;
reg [15:0] cur_din;
reg  [1:0] cur_be;
reg        cur_write;
reg  [1:0] cur_port;

wire [12:0] row = cur_addr[24:12];
wire  [8:0] col = cur_addr[11:3];
wire  [1:0] ba  = cur_addr[2:1];

// Rising-edge request latches
reg p0_pend, p1_pend, p2_pend, wr_pend;
reg [24:1] p0_addr_p, p1_addr_p, p2_addr_p, wr_addr_p;
reg [15:0] wr_din_p;
reg  [1:0] wr_be_p;
reg p0_req_d, p1_req_d, p2_req_d, wr_req_d;

always @(posedge clk) begin
  p0_req_d <= p0_req; p1_req_d <= p1_req; p2_req_d <= p2_req; wr_req_d <= wr_req;
  // Clear pend on first ack cycle (ack may stay high for CDC stretch)
  if (p0_ack) p0_pend <= 1'b0;
  if (p1_ack) p1_pend <= 1'b0;
  if (p2_ack) p2_pend <= 1'b0;
  if (wr_ack) wr_pend <= 1'b0;
  if (p0_req && !p0_req_d) begin p0_pend <= 1'b1; p0_addr_p <= p0_addr; end
  if (p1_req && !p1_req_d) begin p1_pend <= 1'b1; p1_addr_p <= p1_addr; end
  if (p2_req && !p2_req_d) begin p2_pend <= 1'b1; p2_addr_p <= p2_addr; end
  if (wr_req && !wr_req_d) begin
    wr_pend <= 1'b1; wr_addr_p <= wr_addr; wr_din_p <= wr_din; wr_be_p <= wr_be;
  end
  if (init) begin
    {p0_pend,p1_pend,p2_pend,wr_pend} <= 4'b0;
    {p0_req_d,p1_req_d,p2_req_d,wr_req_d} <= 4'b0;
  end
end

always @(posedge clk) begin
  if (ack_hold != 2'd0) begin
    ack_hold <= ack_hold - 2'd1;
  end else begin
    wr_ack <= 1'b0;
    p0_ack <= 1'b0;
    p1_ack <= 1'b0;
    p2_ack <= 1'b0;
  end

  cmd    <= CMD_NOP;
  dq_oe  <= 1'b0;
  dqm    <= 2'b00;

  if (init) begin
    state     <= ST_INIT;
`ifdef SIM_FAST_INIT
    init_cnt  <= 16'h0010;
`else
    init_cnt  <= 16'hffff;
`endif
    init_step <= 4'd0;
    ready     <= 1'b0;
    ref_pend  <= 1'b0;
    ref_cnt   <= 10'd750;
    ack_hold  <= 2'd0;
    wr_ack    <= 1'b0;
    p0_ack    <= 1'b0;
    p1_ack    <= 1'b0;
    p2_ack    <= 1'b0;
  end else begin
    // Do not arm refresh until ready (avoids fighting init)
    if (ready) begin
      if (ref_cnt != 0)
        ref_cnt <= ref_cnt - 10'd1;
      else begin
        ref_cnt  <= 10'd750;
        ref_pend <= 1'b1;
      end
    end

    case (state)
      ST_INIT: begin
        ready <= 1'b0;
        if (init_cnt != 0)
          init_cnt <= init_cnt - 16'd1;
        else begin
          case (init_step)
            4'd0: begin // PRECHARGE ALL
              cmd       <= CMD_PRE;
              SDRAM_A   <= {3'b001, 10'd0};
              SDRAM_BA  <= 2'b00;
              init_step <= 4'd1;
              wait_cnt  <= 4'd3; // tRP
            end
            4'd1: begin
              if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
              else begin
                cmd       <= CMD_REF;
                init_step <= 4'd2;
                wait_cnt  <= 4'd7;
              end
            end
            4'd2: begin
              if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
              else begin
                cmd       <= CMD_REF;
                init_step <= 4'd3;
                wait_cnt  <= 4'd7;
              end
            end
            4'd3: begin
              if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
              else begin
                cmd       <= CMD_MRS;
                SDRAM_A   <= MODE;
                SDRAM_BA  <= 2'b00;
                init_step <= 4'd4;
                wait_cnt  <= 4'd2;
              end
            end
            default: begin
              if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
              else begin
                state   <= ST_IDLE;
                ready   <= 1'b1;
                ref_cnt <= 10'd750;
              end
            end
          endcase
        end
      end

      ST_IDLE: begin
        if (ref_pend) begin
          ref_pend <= 1'b0;
          cmd      <= CMD_REF;
          state    <= ST_RFC;
          wait_cnt <= 4'd7;
        end
        else if (wr_pend) begin
          cur_addr  <= wr_addr_p;
          cur_din   <= wr_din_p;
          cur_be    <= wr_be_p;
          cur_write <= 1'b1;
          cur_port  <= 2'd3;
          state     <= ST_ACT;
        end
        else if (p0_pend) begin
          cur_addr  <= p0_addr_p;
          cur_write <= 1'b0;
          cur_port  <= 2'd0;
          state     <= ST_ACT;
        end
        else if (p1_pend) begin
          cur_addr  <= p1_addr_p;
          cur_write <= 1'b0;
          cur_port  <= 2'd1;
          state     <= ST_ACT;
        end
        else if (p2_pend) begin
          cur_addr  <= p2_addr_p;
          cur_write <= 1'b0;
          cur_port  <= 2'd2;
          state     <= ST_ACT;
        end
      end

      ST_ACT: begin
        cmd      <= CMD_ACT;
        SDRAM_A  <= row;
        SDRAM_BA <= ba;
        state    <= ST_RCD;
        wait_cnt <= 4'd1; // +1 in ST_RCD ⇒ tRCD ≥ 2
      end

      ST_RCD: begin
        if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
        else state <= ST_CMD;
      end

      ST_CMD: begin
        SDRAM_BA <= ba;
        if (cur_write) begin
          cmd     <= CMD_WRITE;
          SDRAM_A <= {4'b0000, col};
          dq_oe   <= 1'b1;
          dq_out  <= cur_din;
          dqm     <= ~cur_be;
          wr_ack  <= 1'b1;
          ack_hold <= 2'd2; // ≥2 clk_ram for clk_sys sample
          state   <= ST_WRWAIT;
          wait_cnt <= 4'd1; // tWR ≥ 2 before PRE
        end else begin
          cmd     <= CMD_READ;
          SDRAM_A <= {4'b0000, col};
          state   <= ST_CL1;
        end
      end

      ST_CL1: state <= ST_CL2;
      ST_CL2: state <= ST_CL3;   // dq_in captures the CL2 word on this edge
      ST_CL3: state <= ST_DATA;

      ST_DATA: begin
        case (cur_port)
          2'd0: begin p0_dout <= dq_in; p0_ack <= 1'b1; end
          2'd1: begin p1_dout <= dq_in; p1_ack <= 1'b1; end
          default: begin p2_dout <= dq_in; p2_ack <= 1'b1; end
        endcase
        ack_hold <= 2'd2;
        state <= ST_PRE;
      end

      ST_WRWAIT: begin
        if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
        else state <= ST_PRE;
      end

      ST_PRE: begin
        cmd      <= CMD_PRE;
        SDRAM_A  <= {3'b001, 10'd0};
        state    <= ST_RP;
        wait_cnt <= 4'd1; // tRP ≥ 2
      end

      ST_RP: begin
        if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
        else state <= ST_IDLE;
      end

      ST_RFC: begin
        if (wait_cnt != 0) wait_cnt <= wait_cnt - 4'd1;
        else state <= ST_IDLE;
      end

      default: state <= ST_IDLE;
    endcase
  end
end

endmodule
