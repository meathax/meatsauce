// tv80s with clock-enable input (cen).
// Derived from tv80s.v (Guy Hutchison, MIT licence) — adds cen port so
// the core can be clocked at a sub-rate of the system clock without a
// gated clock net (safe for FPGA BRAM and PLL-derived clocks).

`define TV80DELAY

module tv80s_ce (
  output        m1_n,
  output        read_t2, // Public T2 phase for wait classification; no RTL hierarchy probe.
  output reg    mreq_n,
  output reg    iorq_n,
  output reg    rd_n,
  output reg    wr_n,
  output        rfsh_n,
  output        halt_n,
  output        busak_n,
  output [15:0] A,
  output [7:0]  dout,
  input         reset_n,
  input         clk,
  input         cen,       // clock enable (e.g. CE_6M)
  input         wait_n,
  input         int_n,
  input         nmi_n,
  input         busrq_n,
  input  [7:0]  di
);

  parameter Mode    = 0;
  parameter T2Write = 1;
  parameter IOWait  = 1;

  wire       intcycle_n;
  wire       no_read;
  wire       write;
  wire       iorq;
  reg  [7:0] di_reg;
  wire [6:0] mcycle;
  wire [6:0] tstate;
  assign read_t2 = tstate[2];

  tv80_core #(Mode, IOWait) i_tv80_core
  (
    .cen        (cen),
    .m1_n       (m1_n),
    .iorq       (iorq),
    .no_read    (no_read),
    .write      (write),
    .rfsh_n     (rfsh_n),
    .halt_n     (halt_n),
    .wait_n     (wait_n),
    .int_n      (int_n),
    .nmi_n      (nmi_n),
    .reset_n    (reset_n),
    .busrq_n    (busrq_n),
    .busak_n    (busak_n),
    .clk        (clk),
    .IntE       (),
    .stop       (),
    .A          (A),
    .dinst      (di),
    .di         (di_reg),
    .dout       (dout),
    .mc         (mcycle),
    .ts         (tstate),
    .intcycle_n (intcycle_n)
  );

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      rd_n   <= `TV80DELAY 1'b1;
      wr_n   <= `TV80DELAY 1'b1;
      iorq_n <= `TV80DELAY 1'b1;
      mreq_n <= `TV80DELAY 1'b1;
      di_reg <= `TV80DELAY 0;
    end else if (cen) begin
      rd_n   <= `TV80DELAY 1'b1;
      wr_n   <= `TV80DELAY 1'b1;
      iorq_n <= `TV80DELAY 1'b1;
      mreq_n <= `TV80DELAY 1'b1;
      if (mcycle[0]) begin
        if (tstate[1] || (tstate[2] && wait_n == 1'b0)) begin
          rd_n   <= `TV80DELAY ~intcycle_n;
          mreq_n <= `TV80DELAY ~intcycle_n;
          iorq_n <= `TV80DELAY  intcycle_n;
        end
      end else begin
        if ((tstate[1] || (tstate[2] && wait_n == 1'b0)) && no_read == 1'b0 && write == 1'b0) begin
          rd_n   <= `TV80DELAY 1'b0;
          iorq_n <= `TV80DELAY ~iorq;
          mreq_n <= `TV80DELAY  iorq;
        end
        if (T2Write == 0) begin
          if (tstate[2] && write == 1'b1) begin
            wr_n   <= `TV80DELAY 1'b0;
            iorq_n <= `TV80DELAY ~iorq;
            mreq_n <= `TV80DELAY  iorq;
          end
        end else begin
          if ((tstate[1] || (tstate[2] && wait_n == 1'b0)) && write == 1'b1) begin
            wr_n   <= `TV80DELAY 1'b0;
            iorq_n <= `TV80DELAY ~iorq;
            mreq_n <= `TV80DELAY  iorq;
          end
        end
      end
      if (tstate[2] && wait_n == 1'b1 && !write && !no_read)
        di_reg <= `TV80DELAY di;
    end
  end

endmodule
