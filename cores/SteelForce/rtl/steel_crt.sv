// SPDX-License-Identifier: GPL-3.0-or-later
// CRT Adjust (H-Size, H-Position, V-Shift) for the Steel Force raster, ported from the Darkmist
// core's darkmist_crt glue around rmonic79's crt_adjust (rtl/vendor/crt_adjust).
// Raster (rtl/steel_raster_params.vh): 500 x 262 pixels, one pixel every 6 clocks, active
// x8..373 / y0..239, HSync x392..427, VSync lines 244..246. Sync stays native; the picture is
// re-read from a line buffer at an integer period of 4..7 clocks (H-Size -2..+1) and shifted by
// H-Position; V-Shift delays VSync by whole lines. Every source pixel keeps a uniform duration.
// The centring table is measured for this raster (sim/crt_extremes.cpp), not Darkmist's.
module steel_crt (
    input logic clk,reset,ce_in,enable,
    input logic [1:0] hsize_option,          // 0, +1, -2, -1
    input logic [4:0] hpos_option,vpos_option,
    input logic [7:0] r_in,g_in,b_in,
    input logic hs_in,vs_in,hb_in,vb_in,
    output logic ce_out,active,
    output wire [7:0] r_out,g_out,b_out,
    output wire hs_out,vs_out,hb_out,vb_out,
    output wire [7:0] read_period
);
    // Measured (sim/crt_extremes.cpp measure): native picture HS-rise offsets 696..2892 (centre 1794);
    // one H-Position step = one read period. Period 4 (-2) and 5 (-1) are centred on 1794. At period 7 (+1)
    // the 2,562-clock picture only fits between HSync end (216) and the next HSync rise (3000), so it is
    // centred in that window (start 326) and H-Position is clamped to keep it there (start 221..417).
    localparam signed [8:0] CENTRE0=-9'sd1, CENTRE1=-9'sd70, CENTRE2=9'sd149, CENTRE3=9'sd60;
    localparam signed [8:0] WIDE_MIN=-9'sd85, WIDE_MAX=-9'sd57;
    logic signed [4:0] hsize;
    logic signed [8:0] hpos;
    logic signed [5:0] vpos;
    function automatic signed [8:0] centre(input logic [1:0] option_code);
        case(option_code)
            1:centre=CENTRE1; 2:centre=CENTRE2; 3:centre=CENTRE3;
            default:centre=CENTRE0;
        endcase
    endfunction
    wire signed [8:0] requested=centre(hsize_option)+$signed({{4{hpos_option[4]}},hpos_option});
    wire signed [8:0] wanted=hsize_option!=2'd1 ? requested : requested<WIDE_MIN ? WIDE_MIN : requested>WIDE_MAX ? WIDE_MAX : requested;
    logic blank_d,hs_d;
    wire hs_reference;
    logic [7:0] accumulator;
    // Native pixel period is six clocks (24 quarter-clocks); H-Size steps are whole clocks.
    assign read_period=8'd24+{{3{hsize[4]}},hsize};
    wire [8:0] advanced={1'b0,accumulator}+9'd4;
    wire read_tick=advanced>={1'b0,read_period};
    wire [7:0] advanced_less_period=advanced[7:0]-read_period;
    wire read_ce=active?read_tick:ce_in;
    always_ff @(posedge clk) begin
        if(reset) begin
            active<=0;hsize<=0;hpos<=0;vpos<=0;blank_d<=0;hs_d<=0;accumulator<=0;ce_out<=0;
        end else begin
            hs_d<=hs_reference;
            ce_out<=read_ce;
            // Restart the read divider at sync fall, inside horizontal blanking.
            if(!hs_reference && hs_d)accumulator<=0;
            else if(read_tick)accumulator<=advanced_less_period;
            else accumulator<=advanced[7:0];
            if(ce_in) begin
                blank_d<=vb_in;
                // Options are latched once per frame at the start of vertical blanking.
                if(vb_in && !blank_d) begin
                    active<=enable;
                    case(hsize_option)
                        1:hsize<=4; 2:hsize<=-8; 3:hsize<=-4; default:hsize<=0;
                    endcase
                    hpos<=wanted;
                    vpos<={vpos_option[4],vpos_option};
                end
            end
        end
    end
    crt_adjust #(.VTOTAL(262),.HTOTAL(500),.HPOS_MODE(1),.SEPARATE_BLANK(1)) adjust (
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(active),
        .hsize(hsize),.hoffset(hpos),.voffset(vpos),
        .r_in(r_in),.g_in(g_in),.b_in(b_in),.hs_in(hs_in),.vs_in(vs_in),
        .hb_in(hb_in),.vb_in(vb_in),
        .r_out(r_out),.g_out(g_out),.b_out(b_out),.hs_out(hs_out),.vs_out(vs_out),
        .hb_out(hb_out),.vb_out(vb_out),.hs_ref_out(hs_reference)
    );
endmodule
