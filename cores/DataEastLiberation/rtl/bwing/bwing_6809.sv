// MC6809E wrapper for the 24 MHz / 16 B-Wings clock. The project system clock
// is 48 MHz, so one E/Q cycle spans 32 clocks. Q leads E by 90 degrees.
module bwing_6809 (
  input             clk_sys,
  input             reset,
  input             ready,
  input       [7:0] din,
  output      [7:0] dout,
  output     [15:0] addr,
  output            rw,
  input             irq_n,
  input             firq_n,
  input             nmi_n,
  output            cycle_stb,
  output    [111:0] regs
);

reg [4:0] phase = 5'd0;
always @(posedge clk_sys) begin
  // mc6809i samples nRESET and clears its interrupt pipeline on falling E.
  // E and Q therefore must continue running while reset is asserted.
  if (ready) phase <= phase + 5'd1;
end

wire q = (phase < 5'd16);
wire e = (phase >= 5'd8) && (phase < 5'd24);
// The original mc6809i integration clocks external memory on cen_q: the
// rising edge of Q, one quarter-cycle before E rises.  At this point the bus
// values produced after the previous falling E have been stable for 8 system
// clocks.  Sampling at falling E instead can observe the core changing to its
// next internal bus state and loses writes on real program cycles.
assign cycle_stb = (phase == 5'd0) && !reset && ready;

wire bs, ba, avma, busy, lic;
mc6809i u_cpu (
  .clk(clk_sys), .D(din), .DOut(dout), .ADDR(addr), .RnW(rw),
  .E(e), .Q(q), .BS(bs), .BA(ba),
  .nIRQ(irq_n), .nFIRQ(firq_n), .nNMI(nmi_n),
  .AVMA(avma), .BUSY(busy), .LIC(lic),
  .nHALT(1'b1), .nRESET(~reset), .nDMABREQ(1'b1), .RegData(regs)
);

endmodule
