// Captain Silver byte latch and alternate-nibble IRQ around real JT5205.
module d8_adpcm #(parameter MAME_RESET=1)(
    input  logic clk,
    input  logic rst_n,
    input  logic i_pause,
    input  logic i_data_we,
    input  logic [7:0] i_data,
    output logic o_irq,
    output wire o_tick,
    output wire [3:0] o_nibble,
    output wire signed [11:0] o_audio
);
    // The 384 kHz divider and the JT5205 sample counter restart at reset, so
    // the first MSM5205 VCK callback falls 54 x 384 kHz periods (140.6 us)
    // after release, then every 48 periods, as in MAME (msm5205.cpp: VCK
    // starts low, half period 24, legacy callback 6 clocks after the fall).
    logic [7:0] divider = '0;
    wire cen384 = rst_n && !i_pause && divider == 8'd124;
    always_ff @(posedge clk) begin
        if (!rst_n) divider <= '0;
        else if (!i_pause) divider <= divider == 8'd124 ? 8'd0 : divider+8'd1;
    end
    logic [7:0] next_byte;
    logic toggle;
    assign o_nibble = next_byte[7:4];
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            next_byte <= '0;
            toggle <= 1'b0;
            o_irq <= 1'b0;
        end else begin
            if (o_tick) begin
                toggle <= !toggle;
                if (!toggle) o_irq <= 1'b1;
                next_byte <= {next_byte[3:0],4'd0};
            end
            if (i_data_we) begin
                next_byte <= i_data;
                o_irq <= 1'b0;
            end
        end
    end
    jt5205 #(.INTERPOL(0), .VCLK_CEN(1), .MAME_RESET(MAME_RESET), .MAME_PHASE(1)) u_msm (
        .rst(!rst_n), .clk, .cen(cen384), .sel(2'd2), .din(o_nibble),
        .sound(o_audio), .sample(), .irq(o_tick), .vclk_o());
endmodule
