// SPDX-License-Identifier: GPL-3.0-or-later
// Reference framebuffer metadata only. These markers are not PCB CRT timing.
// RGB and the framebuffer producer are untouched. The MiSTer scaler measures
// this raster, so it uses conventional geometry: 320x256 total, 256x224
// active, positive HS/VS pulses inside real horizontal/vertical blanking.
module airbustr_reference_metadata (
    input logic clk,reset,enable,
    input logic raw_ce,raw_de,raw_vb,
    input logic [8:0] raw_x,
    input logic [7:0] raw_y,
    output logic ce,hs,vs,de,
    output logic overlap_error
);
    logic armed;
    assign overlap_error = 1'b0;
    always_ff @(posedge clk) begin
        if (reset || !enable) begin
            ce<=0; hs<=0; vs<=0; de<=0; armed<=0;
        end else begin
            ce<=0;
            if (raw_ce) begin
                // Start emitting at a complete frame boundary.
                if (!armed) armed <= raw_x==9'd0 && raw_y==8'd0;
                if (armed || (raw_x==9'd0 && raw_y==8'd0)) begin
                    ce<=1;
                    de<=raw_de;
                    hs<=raw_x>=9'd272 && raw_x<9'd304;
                    vs<=raw_y>=8'd244 && raw_y<8'd247;
                end
            end
        end
    end
endmodule

// Continuous framebuffer measurement raster, independent of ROM/game reset.
// This is a 58 Hz HDMI presentation reference, not measured PCB CRT timing.
module airbustr_framebuffer_timing (
    input logic clk,reset,
    output wire raw_ce,raw_de,raw_vb,
    output logic [8:0] raw_x,
    output logic [7:0] raw_y
);
    logic [25:0] phase;
    wire [25:0] next_phase=phase+26'd4751360; // 320*256*58
    assign raw_ce=!reset && next_phase>=26'd48000000;
    assign raw_vb=raw_y<8'd16 || raw_y>=8'd240;
    assign raw_de=!raw_vb && raw_x<9'd256;
    always_ff @(posedge clk) begin
        if(reset) begin phase<=0; raw_x<=0; raw_y<=0; end
        else begin
            phase<=raw_ce ? next_phase-26'd48000000 : next_phase;
            if(raw_ce) begin
                if(raw_x==9'd319) begin raw_x<=0; raw_y<=raw_y+8'd1; end
                else raw_x<=raw_x+9'd1;
            end
        end
    end
endmodule
