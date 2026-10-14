// Clock-enable divider. Emits a one-cycle `cen` pulse every (DIV+1) ref_clk
// cycles. Both 6502s and the AYs run from these enables rather than from
// divided clocks, so the whole core stays in one 48 MHz timing domain.

module clk_en #(
  parameter DIV    = 12,
  parameter OFFSET = 0
)
(
  input      ref_clk,
  output reg cen
);

reg [15:0] cnt = OFFSET;

always @(posedge ref_clk) begin
  if (cnt == DIV) begin
    cnt <= 16'd0;
    cen <= 1'b1;
  end
  else begin
    cen <= 1'b0;
    cnt <= cnt + 16'd1;
  end
end

endmodule
