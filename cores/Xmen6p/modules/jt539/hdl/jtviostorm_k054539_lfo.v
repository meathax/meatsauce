// Konami 054539 effects LFO, reconstructed from physical circuit connectivity.
// SiliconRE c926ce92fdebd7613c8712b42c45a059d63548e0:
// k054539.SDF:22431,22516,33385: counter ENT = CYCLERES in normal mode.
// hdl/lfo.v:13-50: depth latch, up/down counter and delayed JK direction.
// The silicon divider starts at zero; a rate write does not restart it.
// frame_tick is one cen-qualified pulse per 384 native chip clocks.
module jtviostorm_k054539_lfo (
    input             clk,
    input             rst,
    input             cen,
    input             frame_tick,
    input      [7:0]   rate,
    input      [7:0]   depth,
    output reg [7:0]   value
);

reg [7:0] divider;
reg [7:0] latched_depth;
reg       descending;
reg       direction_pending;
wire      terminal = frame_tick && (&divider);

always @(posedge clk) begin
    if (rst) begin
        divider          <= 8'd0;
        latched_depth    <= 8'd0;
        descending       <= 1'b0;
        direction_pending<= 1'b0;
        value            <= 8'd0;
    end else if (cen) begin
        if (frame_tick)
            divider <= terminal ? ~rate : divider + 8'd1;

        // CNTA/B_OVF_D clocks the direction JK one native clock after
        // the overflow clocks the value counter and its depth latch.
        direction_pending <= terminal;
        if (direction_pending) begin
            case ({value == latched_depth, value == 8'd0})
                2'b01: descending <= 1'b0;
                2'b10: descending <= 1'b1;
                2'b11: descending <= ~descending;
                default: descending <= descending;
            endcase
        end

        if (terminal) begin
            latched_depth <= depth;
            // A zero newly latched depth asserts the physical counter's
            // asynchronous reset. A previously zero depth holds the first
            // enable overflow at zero before the next overflow increments.
            if (depth == 8'd0 || latched_depth == 8'd0)
                value <= 8'd0;
            else
                value <= descending ? value - 8'd1 : value + 8'd1;
        end
    end
end

endmodule
