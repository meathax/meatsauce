// Clock-enable divider. Emits a one-cycle `cen` pulse every (DIV+1) ref_clk
// cycles. AY logic uses cen as an enable; the 6502 wrappers use its rising
// edge as a divided clock, constrained explicitly in the project SDC.

module clk_en #(
  parameter DIV    = 12,
  parameter OFFSET = 0
)
(
  input      ref_clk,
  output reg cen
);

// The divider is used with small, fixed ratios (23, 31 and 63 in the
// universal core). Keeping a 16-bit counter here needlessly consumes a long
// carry chain and extra ALMs in every instance. Include OFFSET in the bound
// so the parameter remains safe for non-zero initial phases as well.
localparam integer COUNT_MAX = (DIV > OFFSET) ? DIV : OFFSET;
localparam integer CNT_WIDTH = (COUNT_MAX < 1) ? 1 : $clog2(COUNT_MAX + 1);

reg [CNT_WIDTH-1:0] cnt = OFFSET;

always @(posedge ref_clk) begin
  if (cnt == DIV) begin
    cnt <= 0;
    cen <= 1'b1;
  end
  else begin
    cen <= 1'b0;
    cnt <= cnt + 1'b1;
  end
end

endmodule
