// Fractional clock enables for the nominal 48 MHz clk_sys. The hardware PLL
// currently produces 48.317307 MHz on this device, so a literal divide by
// three would run the PCD/video raster 0.66% fast. Keep the default at 48 MHz
// for the deterministic Verilator contract, and let the hardware top pass its
// measured PLL rate so the long-term 16/8/4/20 MHz rates remain exact.
module s24_clock_enables #(
    parameter int unsigned CLK_HZ = 48_000_000,
    parameter int unsigned PIXEL_HZ = 16_000_000,
    parameter int unsigned PHASE_HZ = 20_000_000
) (
    input  logic clk,
    input  logic reset,
    input  logic pause,
    output logic phi1,
    output logic phi2,
    output logic ce_16m,
    output logic ce_8m,
    output logic ce_4m
);
    logic [31:0] pixel_acc,phase_acc;
    logic [1:0] pixel_subdiv;
    logic phase_sel;

    always_ff @(posedge clk) begin
        if (reset) begin
            pixel_acc <= 0;
            pixel_subdiv <= 0;
            phase_acc <= 0;
            phase_sel <= 0;
            phi1 <= 0;
            phi2 <= 0;
            ce_16m <= 0;
            ce_8m <= 0;
            ce_4m <= 0;
        end else begin
            ce_16m <= 1'b0;
            ce_8m <= 1'b0;
            ce_4m <= 1'b0;
            if (pixel_acc + PIXEL_HZ >= CLK_HZ) begin
                ce_16m <= 1'b1;
                // 8 MHz is every second 16 MHz pixel event; 4 MHz is every
                // fourth event.  Test the current phase before advancing it.
                if (pixel_subdiv[0]) ce_8m <= 1'b1;
                if (pixel_subdiv == 2'd3) ce_4m <= 1'b1;
                pixel_subdiv <= (pixel_subdiv == 2'd3)
                              ? 2'd0 : pixel_subdiv + 1'b1;
                pixel_acc <= pixel_acc + PIXEL_HZ - CLK_HZ;
            end else pixel_acc <= pixel_acc + PIXEL_HZ;

            // Alternating phase events are phi1 and phi2, hence each
            // architectural phase repeats at half PHASE_HZ.
            phi1 <= 1'b0;
            phi2 <= 1'b0;
            if (!pause) begin
                if (phase_acc + PHASE_HZ >= CLK_HZ) begin
                    if (phase_sel) phi2 <= 1'b1;
                    else           phi1 <= 1'b1;
                    phase_sel <= ~phase_sel;
                    phase_acc <= phase_acc + PHASE_HZ - CLK_HZ;
                end else begin
                    phase_acc <= phase_acc + PHASE_HZ;
                end
            end
        end
    end
endmodule
