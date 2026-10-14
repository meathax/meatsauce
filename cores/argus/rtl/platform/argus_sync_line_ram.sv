// Core-local proposal: no reset, one master clock, one write port.
// Registered read returns pre-write data on a same-address read/write edge.
// This is the consumed-port behavior of dpram_hs and jtframe_dual_ram.
module argus_sync_line_ram #(
    parameter DW = 24,
    parameter AW = 9,
    parameter NUMWORDS = (1 << AW)
)(
    input clk,
    input [AW-1:0] waddr,
    input [DW-1:0] wdata,
    input we,
    input [AW-1:0] raddr,
    output reg [DW-1:0] q
);
    (* ramstyle = "M10K" *) reg [DW-1:0] ram [0:NUMWORDS-1];
    always @(posedge clk) begin
        if (we) ram[waddr] <= wdata;
        q <= ram[raddr];
    end
endmodule
