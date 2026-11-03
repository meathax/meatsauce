// SPDX-License-Identifier: GPL-3.0-or-later
// CRT Adjust glue ported from HeavyUnit/darkmist (crt_adjust donor, 8-clock native pixel).
// Tables below are derived for SWAT's esd16_video_line raster: 64 MHz, 512x260, active x0..319 y0..239,
// HS x344..383, VS y248..250 (sim/crt bench, tagged pixels, every setting).
module esd16_crt #(parameter integer HTOTAL=512, VTOTAL=260, PXDIV=8,
    // Centring offsets per H-Size option code (0:0 1:+1 2:+2 3:-2 4:-1) and the H-Size +1/+2 clamps.
    // Native picture centre is 2620 clocks after HS rise; periods 8/9/10/6/7 clocks give 2620/2615.5/2481/2617/2622.5.
    // +2 (3200-clock picture) cannot reach the native centre without crossing HS, so it sits at its clamp.
    parameter integer C0=-1, C1=-38, C2=-81, C3=107, C4=46, CLAMP1=-35, CLAMP2=-81) (
    input logic clk,reset,ce_in,enable,
    input logic [2:0] hsize_option,
    input logic [4:0] hpos_option,vpos_option,
    input logic [7:0] r_in,g_in,b_in,
    input logic hs_in,vs_in,hb_in,vb_in,
    output logic ce_out,active,
    output wire [7:0] r_out,g_out,b_out,
    output wire hs_out,vs_out,hb_out,vb_out,
    output wire [7:0] read_period
);
    logic signed [4:0] hsize;
    logic signed [8:0] hpos;
    logic signed [5:0] vpos;
    // Raster-specific centring: offset compensates the donor read-window and two read pipeline ticks.
    function automatic signed [8:0] centre(input logic [2:0] option_code);
        case(option_code)
            1:centre=9'(C1); 2:centre=9'(C2);
            3:centre=9'(C3); 4:centre=9'(C4);
            default:centre=9'(C0);
        endcase
    endfunction
    wire signed [8:0] wanted=centre(hsize_option)+$signed({{4{hpos_option[4]}},hpos_option});
    // At periods 9/10 the stretched picture must end before the next HS. Bench boundary (sim/crt scan): offsets
    // above -34 (+1) / -80 (+2) cross HS; the clamps keep one step of margin.
    wire signed [8:0] safe_hpos=(hsize_option==1 && wanted>$signed(9'(CLAMP1))) ? $signed(9'(CLAMP1)) :
                                (hsize_option==2 && wanted>$signed(9'(CLAMP2))) ? $signed(9'(CLAMP2)) : wanted;
    logic blank_d,hs_d;
    wire hs_reference;
    logic [7:0] accumulator;
    // Native pixel period is eight clocks. H-Size steps are whole clocks,
    // preserving uniform pixel durations; supported periods are 6..10 clocks.
    // Applies to direct video too; every selected interval remains an integer.
    assign read_period=8'(4*PXDIV)+{{3{hsize[4]}},hsize};
    wire [8:0] advanced={1'b0,accumulator}+9'd4;
    wire read_tick=advanced>={1'b0,read_period};
    wire [7:0] advanced_less_period=advanced[7:0]-read_period; // low 8 bits of the 9-bit difference
    wire read_ce=active?read_tick:ce_in;
    always_ff @(posedge clk) begin
        if(reset) begin
            active<=0;hsize<=0;hpos<=0;vpos<=0;blank_d<=0;hs_d<=0;accumulator<=0;ce_out<=0;
        end else begin
            hs_d<=hs_reference;
            ce_out<=read_ce; // consume the donor's registered output next clock.
            // A right-shifted slow read can still be active at sync rise.
            // Restart the divider at sync fall, inside horizontal blanking,
            // so its phase restart cannot lengthen an active pixel interval.
            if(!hs_reference && hs_d)accumulator<=0;
            else if(read_tick)accumulator<=advanced_less_period;
            else accumulator<=advanced[7:0];
            if(ce_in) begin
                blank_d<=vb_in;
                if(vb_in && !blank_d) begin
                    active<=enable;
                    case(hsize_option)
                        0:hsize<=0; 1:hsize<=4; 2:hsize<=8;
                        3:hsize<=-8; 4:hsize<=-4; default:hsize<=0;
                    endcase
                    hpos<=safe_hpos;
                    vpos<={vpos_option[4],vpos_option};
                end
            end
        end
    end
    crt_adjust #(.VTOTAL(VTOTAL),.HTOTAL(HTOTAL),.HPOS_MODE(1),.SEPARATE_BLANK(1)) adjust (
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(active),
        .hsize(hsize),.hoffset(hpos),.voffset(vpos),
        .r_in(r_in),.g_in(g_in),.b_in(b_in),.hs_in(hs_in),.vs_in(vs_in),
        .hb_in(hb_in),.vb_in(vb_in),
        .r_out(r_out),.g_out(g_out),.b_out(b_out),.hs_out(hs_out),.vs_out(vs_out),
        .hb_out(hb_out),.vb_out(vb_out),.hs_ref_out(hs_reference)
    );
endmodule
