// SPDX-License-Identifier: GPL-3.0-or-later
// Synchronous strobes on the 56 MHz shared system/video clock.
module hangzo_service_enables(
    input wire clk,reset,
    output reg refresh=1'b0,
    output reg audio_sample_ce=1'b0
);
    // One refresh request every 400 roots = 7.142857 us. The controller
    // retains refresh debt while busy; physical command latency is checked
    // separately. This generator runs during pause and game reset.
    reg [8:0] refresh_count=9'd0;
    reg [11:0] sample_phase=12'd0;
    always @(posedge clk) begin
        refresh<=1'b0;
        audio_sample_ce<=1'b0;
        if(reset) begin
            refresh_count<=9'd0;
            sample_phase<=12'd0;
        end else begin
            if(refresh_count==9'd399) begin
                refresh_count<=9'd0;
                refresh<=1'b1;
            end else refresh_count<=refresh_count+9'd1;
            // 56 MHz * 3/3500 = 48 kHz. This is an audio strobe,
            // never CE_PIXEL or a derived clock.
            if(sample_phase>=12'd3497) begin
                sample_phase<=sample_phase-12'd3497;
                audio_sample_ce<=1'b1;
            end else sample_phase<=sample_phase+12'd3;
        end
    end
endmodule
