// Gaiapolis adapter. Source provenance: rtl/vendor/violent_storm_k054539/source.json
/*
 * Konami 054539 timer reconstructed from furrtek/SiliconRE
 * c926ce92fdebd7613c8712b42c45a059d63548e0, Konami/054539/hdl/054539.v:
 *   81-107: CLKDIVD is CLKDIV delayed one master clock
 *   498-523: transparent REG227, terminal-count reload and TIM toggle
 *
 * master_phase is the pre-increment 0..383 chip-clock phase. Delayed bit 6
 * rises when its low seven bits are 64. Supply the physical chip clock
 * enable and phase, independently of any emulated ROM wait-state stalls.
 * load_value is the live REG227 value; writes do not reset the timer.
 * Native NRES resets the caller's divider, not the counter or TIM state.
 * Explicit zero initialization below is an FPGA power-up policy only.
 */
module gaiapolis_k054539_timer(
    input            clk,
    input freeze,
    input            rst,
    input            cen,
    input      [8:0] master_phase,
    input            enable,
    input      [7:0] load_value,
    output reg       timeout,
    output reg [7:0] count
);

wire tick = cen && (master_phase[6:0] == 7'd64);

initial begin
    count = 8'd0;
    timeout = 1'b0;
end

always @(posedge clk) begin
    if (!freeze || rst) begin
    if (!rst && tick) begin
        if (!enable || count == 8'hff)
            count <= load_value;
        else
            count <= count + 8'd1;
    end

    end
end

// The die's TIM output clears immediately on the falling enable edge.
always @(posedge clk or negedge enable) begin
    if (!enable)
        timeout <= 1'b0;
    else if (!freeze) begin if (!rst && tick && count == 8'hff)
        timeout <= ~timeout;

    end
end

endmodule
