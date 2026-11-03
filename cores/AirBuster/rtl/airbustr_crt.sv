// SPDX-License-Identifier: GPL-3.0-or-later
// CRT Adjust glue ported from the darkmist core: same 48 MHz master, 8-clock
// native pixel and HS-to-active distance (96 px). Heavy Unit runs 384x270.
module airbustr_crt #(parameter integer HTOTAL=384, VTOTAL=270) (
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
    // Raster-specific centring (shared with darkmist): HS begins at x304, active begins at x0.
    // Offset compensates the donor read-window and two read pipeline ticks.
    // These integer-period tables are verified against all 256 tagged pixels;
    // Simple156's 512x274/CE6 fractional tables are deliberately not reused.
    function automatic signed [8:0] centre(input logic [2:0] option_code);
        case(option_code)
            1:centre=-9'sd26; 2:centre=-9'sd46;
            3:centre=9'sd74; 4:centre=9'sd31;
            default:centre=-9'sd1;
        endcase
    endfunction
    wire signed [8:0] wanted=centre(hsize_option)+$signed({{4{hpos_option[4]}},hpos_option});
    // At period10 the latest complete picture must finish before bank cutover.
    // Clamp re-derived for the 384-clock-wide line (tests/crt: all 256 tags at
    // hpos+1 for H-Size +2, truncation from +2 on); darkmist's 400 line used -36.
    wire signed [8:0] safe_hpos=(hsize_option==2 && wanted>-9'sd45) ? -9'sd45 : wanted;
    logic blank_d,hs_d;
    wire hs_reference;
    logic [7:0] accumulator;
    // Native pixel period is eight clocks. H-Size steps are whole clocks,
    // preserving uniform pixel durations; supported periods are 6..10 clocks.
    // Applies to direct video too; every selected interval remains an integer.
    assign read_period=8'd32+{{3{hsize[4]}},hsize};
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
