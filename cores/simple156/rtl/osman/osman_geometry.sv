// SPDX-License-Identifier: GPL-3.0-or-later
// Core-side CRT Adjust; native bypass and quarter-cycle read cadence
// (native pixel = 6 clocks = 24 quarter-cycles; raster 512x274).
module osman_geometry (
    input wire clk,reset,ce_in,active,
    input wire signed [4:0] hsize,hposition,vposition,
    input wire [7:0] red_in,green_in,blue_in,
    input wire hs_in,vs_in,de_in,
    input wire [8:0] x,
    input wire [7:0] y,
    output wire ce_out,de_out,hs_out,vs_out,hblank_out,vblank_out,
    output wire [7:0] red_out,green_out,blue_out
);
    wire [7:0] crt_r,crt_g,crt_b;
    wire crt_hs,crt_vs,crt_hb,crt_vb,hs_ref;
    reg hs_ref_previous;
    reg [7:0] read_phase;
    // Horizontal geometry. A source pixel is read for (24+hsize)/4 clocks, so the
    // picture is 320*(24+hsize)/4 clocks wide, and the crt_adjust read window
    // starts a fixed 97 read ticks after HSync ends. Left alone, a wider picture
    // therefore starts later and its centre drifts right (+4: 5.6 us right and
    // 3 us into the next HSync). centre_ticks() moves the read window so the
    // picture centre stays 1536 clocks (31.5 us) after the end of HSync, i.e. 35.4 us
    // after it starts, where the unadjusted raster puts it, unless the picture
    // would reach the next HSync; min_ticks()/max_ticks() keep the whole picture between the pulses
    // for every H-Position. H-Size is limited to -10..+6: a wider picture cannot
    // fit, a narrower one needs more offset than crt_adjust can express.
    // Tables: scripts/crt_position_tables.py (all values in read ticks).
    wire signed [4:0] hsize_c = hsize > 5'sd6 ? 5'sd6 : hsize < -5'sd10 ? -5'sd10 : hsize;
    function automatic signed [10:0] centre_ticks(input [4:0] hs);
        case (hs)
            5'd22: centre_ticks = 11'sd182; // H-Size -10
            5'd23: centre_ticks = 11'sd153; // H-Size -9
            5'd24: centre_ticks = 11'sd127; // H-Size -8
            5'd25: centre_ticks = 11'sd104; // H-Size -7
            5'd26: centre_ticks = 11'sd84; // H-Size -6
            5'd27: centre_ticks = 11'sd66; // H-Size -5
            5'd28: centre_ticks = 11'sd50; // H-Size -4
            5'd29: centre_ticks = 11'sd36; // H-Size -3
            5'd30: centre_ticks = 11'sd22; // H-Size -2
            5'd31: centre_ticks = 11'sd10; // H-Size -1
            5'd0: centre_ticks = -11'sd1; // H-Size +0
            5'd1: centre_ticks = -11'sd11; // H-Size +1
            5'd2: centre_ticks = -11'sd21; // H-Size +2
            5'd3: centre_ticks = -11'sd29; // H-Size +3
            5'd4: centre_ticks = -11'sd38; // H-Size +4
            5'd5: centre_ticks = -11'sd45; // H-Size +5
            5'd6: centre_ticks = -11'sd52; // H-Size +6
            default: centre_ticks = 11'sd0;
        endcase
    endfunction
    function automatic signed [10:0] min_ticks(input [4:0] hs);
        case (hs)
            5'd22: min_ticks = -11'sd90; // H-Size -10
            5'd23: min_ticks = -11'sd90; // H-Size -9
            5'd24: min_ticks = -11'sd91; // H-Size -8
            5'd25: min_ticks = -11'sd91; // H-Size -7
            5'd26: min_ticks = -11'sd91; // H-Size -6
            5'd27: min_ticks = -11'sd91; // H-Size -5
            5'd28: min_ticks = -11'sd92; // H-Size -4
            5'd29: min_ticks = -11'sd92; // H-Size -3
            5'd30: min_ticks = -11'sd92; // H-Size -2
            5'd31: min_ticks = -11'sd92; // H-Size -1
            5'd0: min_ticks = -11'sd93; // H-Size +0
            5'd1: min_ticks = -11'sd93; // H-Size +1
            5'd2: min_ticks = -11'sd93; // H-Size +2
            5'd3: min_ticks = -11'sd93; // H-Size +3
            5'd4: min_ticks = -11'sd93; // H-Size +4
            5'd5: min_ticks = -11'sd93; // H-Size +5
            5'd6: min_ticks = -11'sd93; // H-Size +6
            default: min_ticks = 11'sd0;
        endcase
    endfunction
    function automatic signed [10:0] max_ticks(input [4:0] hs);
        case (hs)
            5'd22: max_ticks = 11'sd255; // H-Size -10
            5'd23: max_ticks = 11'sd255; // H-Size -9
            5'd24: max_ticks = 11'sd255; // H-Size -8
            5'd25: max_ticks = 11'sd251; // H-Size -7
            5'd26: max_ticks = 11'sd214; // H-Size -6
            5'd27: max_ticks = 11'sd180; // H-Size -5
            5'd28: max_ticks = 11'sd151; // H-Size -4
            5'd29: max_ticks = 11'sd123; // H-Size -3
            5'd30: max_ticks = 11'sd99; // H-Size -2
            5'd31: max_ticks = 11'sd76; // H-Size -1
            5'd0: max_ticks = 11'sd56; // H-Size +0
            5'd1: max_ticks = 11'sd37; // H-Size +1
            5'd2: max_ticks = 11'sd19; // H-Size +2
            5'd3: max_ticks = 11'sd3; // H-Size +3
            5'd4: max_ticks = -11'sd12; // H-Size +4
            5'd5: max_ticks = -11'sd26; // H-Size +5
            5'd6: max_ticks = -11'sd39; // H-Size +6
            default: max_ticks = 11'sd0;
        endcase
    endfunction
    wire signed [10:0] hoffset_want = centre_ticks(hsize_c[4:0]) + $signed({{5{hposition[4]}},hposition,1'b0});
    wire signed [10:0] hoffset_lo = min_ticks(hsize_c[4:0]);
    wire signed [10:0] hoffset_hi = max_ticks(hsize_c[4:0]);
    wire signed [10:0] hoffset_clamped = hoffset_want < hoffset_lo ? hoffset_lo :
                                         hoffset_want > hoffset_hi ? hoffset_hi : hoffset_want;
    wire [8:0] read_period = 9'd24 + {{4{hsize_c[4]}},hsize_c};
    wire [8:0] read_next = {1'b0,read_phase} + 9'd4;
    wire read_tick = read_next >= read_period;
    wire read_ce = active ? read_tick : ce_in;
    wire native_hblank = x >= 9'd320;
    wire native_vblank = y < 8'd8 || y >= 8'd248;
    always @(posedge clk) begin
        hs_ref_previous <= hs_ref;
        if(reset) begin
            read_phase <= 0;hs_ref_previous <= 0;
        end else begin
            // Reference is supplied by the actual module, including H-position.
            if(hs_ref && !hs_ref_previous) read_phase <= 0;
            else if(read_tick) read_phase <= 8'(read_next-read_period);
            else read_phase <= read_next[7:0];
        end
    end
    crt_adjust #(.VTOTAL(274),.HTOTAL(512),.HPOS_MODE(1)) u_adjust (
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(active),
        .hsize(hsize_c),.hoffset(hoffset_clamped[8:0]),.voffset({vposition[4],vposition}),
        .r_in(red_in),.g_in(green_in),.b_in(blue_in),.hs_in(hs_in),.vs_in(vs_in),
        .hb_in(native_hblank),.vb_in(native_vblank),
        .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),.hs_out(crt_hs),.vs_out(crt_vs),
        .hb_out(crt_hb),.vb_out(crt_vb),.hs_ref_out(hs_ref)
    );
    assign ce_out = read_ce;
    assign red_out = active?crt_r:red_in;
    assign green_out = active?crt_g:green_in;
    assign blue_out = active?crt_b:blue_in;
    assign hs_out = active?crt_hs:hs_in;
    assign vs_out = active?crt_vs:vs_in;
    // Blanking and RGB share the donor read pipeline. Anchoring DE to the
    // native write window clipped shrunk pictures and exposed leading black.
    assign de_out = active?(!crt_hb&&!crt_vb):de_in;
    assign hblank_out = active?crt_hb:native_hblank;
    assign vblank_out = active?crt_vb:native_vblank;
endmodule
