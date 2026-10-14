//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md §1).
//   cen_phi1/cen_phi2 : fx68k phases, alternating pulses at 2 x 12.288 MHz
//                       (fractional 32/125 accumulator: 24.576 M pulses/s)
//   cen_h8            : 16.384 MHz (fractional 64/375)
//   cen_pix           : 6.4 MHz (96/15), exact integer divider for the video path; pix_sync
//                       (a pulse the clock after the platform's 6.4 MHz clock edge is seen)
//                       restarts the divider so the pixel is stable when that clock samples it
//   cen_c352          : 85.333 kHz sample tick (96 MHz / 1125)
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic reset,
    input  logic pix_sync,
    output logic cen_phi1,
    output logic cen_phi2,
    output logic cen_h8,
    output logic cen_pix,
    output logic cen_c352
);
    logic [7:0]  acc68;      // 0..124
    logic        phase;
    logic [8:0]  acch8;      // 0..374
    logic [3:0]  divpix;
    logic [10:0] divc;

    always_ff @(posedge clk) begin
        if (reset) begin
            acc68 <= 8'd0; phase <= 1'b0; acch8 <= 9'd0; divpix <= 4'd0; divc <= 11'd0;
            cen_phi1 <= 1'b0; cen_phi2 <= 1'b0; cen_h8 <= 1'b0; cen_pix <= 1'b0; cen_c352 <= 1'b0;
        end else begin
            // 68000: add 32 every clock, pulse on wrap past 125
            if (acc68 + 8'd32 >= 8'd125) begin
                acc68 <= acc68 + 8'd32 - 8'd125;
                phase <= ~phase;
                cen_phi1 <= ~phase;
                cen_phi2 <= phase;
            end else begin
                acc68 <= acc68 + 8'd32;
                cen_phi1 <= 1'b0; cen_phi2 <= 1'b0;
            end
            // H8: add 64 every clock, pulse on wrap past 375
            if (acch8 + 9'd64 >= 9'd375) begin acch8 <= acch8 + 9'd64 - 9'd375; cen_h8 <= 1'b1; end
            else begin acch8 <= acch8 + 9'd64; cen_h8 <= 1'b0; end
            // pixel: /15
            divpix  <= pix_sync ? 4'd12 : (divpix == 4'd14) ? 4'd0 : divpix + 4'd1;
            cen_pix <= (divpix == 4'd14);
            // C352 sample tick: /1125
            divc     <= (divc == 11'd1124) ? 11'd0 : divc + 11'd1;
            cen_c352 <= (divc == 11'd1124);
        end
    end
endmodule
