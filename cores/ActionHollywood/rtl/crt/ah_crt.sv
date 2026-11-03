// SPDX-License-Identifier: GPL-3.0-or-later
// CRT Adjust glue (derived from the HeavyUnit/darkmist glue) for the Action Hollywood raster:
// 48 MHz master, 6-clock pixel (8 MHz), 512x260 total.  The read pixel period is PIX_CLKS clocks
// +/- hsize quarter-clock steps (whole-clock steps only: hsize options are multiples of 4).
// H-Size option codes: 0 none, 1 +1 clk, 3 -2 clk, 4 -1 clk per pixel (code 2 = +2 clk exists but is not offered:
// 352 px at 8 clk + HS 240 clk does not fit the 3072-clk line, tests/framework/crt shows truncation).
// The centre() offsets compensate read window/pipeline so the picture centre stays put for every
// H-Size; they are calibrated by tests/framework/crt (tags every active pixel): centre(H-Size) = 1917..1920 clk after HS rise for
// codes 0/3/4; code 1 is limited by the 17-pixel front porch (HCLAMP keeps the picture off the next HS).
module ah_crt #(parameter integer HTOTAL=512, VTOTAL=260, PIX_CLKS=6,
                parameter signed [8:0] C0=-9'sd1, C1=-9'sd66, C2=-9'sd1, C3=9'sd159, C4=9'sd63,
                parameter signed [8:0] HCLAMP=-9'sd60) (
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
    function automatic signed [8:0] centre(input logic [2:0] option_code);
        case(option_code)
            1:centre=C1; 2:centre=C2; 3:centre=C3; 4:centre=C4;
            default:centre=C0;
        endcase
    endfunction
    wire signed [8:0] wanted=centre(hsize_option)+$signed({{4{hpos_option[4]}},hpos_option});
    wire signed [8:0] safe_hpos=(hsize_option==1 && wanted>HCLAMP) ? HCLAMP : wanted;
    logic blank_d,hs_d;
    wire hs_reference;
    logic [7:0] accumulator;
    assign read_period=8'(4*PIX_CLKS)+{{3{hsize[4]}},hsize};
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
