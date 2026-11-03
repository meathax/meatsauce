// SPDX-License-Identifier: GPL-3.0-or-later
// Simple156 CRT Adjust, at the unchanged DEC8 48MHz video / 6MHz pixel rate.
module d8_geometry (
    input wire clk,reset,ce_in,active,
    input wire signed [4:0] hsize,hposition,vposition,
    input wire [7:0] red_in,green_in,blue_in,
    input wire hs_in,vs_in,hblank_in,vblank_in,
    output wire ce_out,hs_out,vs_out,hblank_out,vblank_out,
    output wire [7:0] red_out,green_out,blue_out
);
    // Sample one coherent OSD tuple in the actual 48MHz video domain. This
    // gives the centring/clamp and donor read-window arithmetic a full video
    // clock instead of the related 96->48MHz half-period launch window.
    // Synchronous reset/startup selects native bypass and neutral controls;
    // subsequent tuples take effect together after the next rising edge.
    reg active_q=0;
    reg signed [4:0] hsize_q=0,hposition_q=0,vposition_q=0;
    always @(posedge clk) begin
        if(reset) begin
            active_q<=0;hsize_q<=0;hposition_q<=0;vposition_q<=0;
        end else begin
            active_q<=active;hsize_q<=hsize;
            hposition_q<=hposition;vposition_q<=vposition;
        end
    end
    wire hs_ref;
    reg hs_prev=0;
    reg [7:0] phase=0;
    // Period is in quarter clocks; 48MHz/6MHz = 8 clocks = 32 quarters.
    wire [8:0] period=9'd32+{{4{hsize_q[4]}},hsize_q};
    wire [8:0] next_phase={1'b0,phase}+9'd4;
    wire tick=next_phase>=period;
    wire read_ce=active_q ? tick : ce_in;
    wire [7:0] rr,gg,bb;
    wire hh,vv,hb,vb;
    // Centre the picture at its native 208 pixels after HS rises (HS x304).
    // These constant tables use quarter-clock period=32+hsize; retain a
    // four-read-tick guard before the next HS so the whole buffered row fits.
    function automatic signed [10:0] centre(input signed [4:0] s);
        case(s)
            -10:centre=95;-9:centre=81;-8:centre=69;-7:centre=58;
            -6:centre=48;-5:centre=39;-4:centre=30;-3:centre=22;
            -2:centre=14;-1:centre=7;0:centre=0;1:centre=-6;
            2:centre=-12;3:centre=-18;4:centre=-23;5:centre=-28;
            6:centre=-33;default:centre=0;
        endcase
    endfunction
    function automatic signed [10:0] last_start(input signed [4:0] s);
        case(s)
            -10:last_start=218;-9:last_start=194;-8:last_start=172;-7:last_start=151;
            -6:last_start=132;-5:last_start=115;-4:last_start=98;-3:last_start=83;
            -2:last_start=69;-1:last_start=56;0:last_start=44;1:last_start=32;
            2:last_start=21;3:last_start=11;4:last_start=1;5:last_start=-8;
            6:last_start=-17;default:last_start=0;
        endcase
    endfunction
    function automatic signed [10:0] first_start(input signed [4:0] s);
        case(s)
            -10:first_start=-29;-9:first_start=-31;-8:first_start=-33;-7:first_start=-35;
            -6:first_start=-36;-5:first_start=-38;-4:first_start=-39;-3:first_start=-40;
            -2:first_start=-41;-1:first_start=-42;0:first_start=-44;1:first_start=-44;
            2:first_start=-45;3:first_start=-46;4:first_start=-47;5:first_start=-48;
            6:first_start=-49;default:first_start=0;
        endcase
    endfunction
    wire signed [10:0] wanted=centre(hsize_q)+$signed({{5{hposition_q[4]}},hposition_q,1'b0});
    wire signed [10:0] limit=last_start(hsize_q);
    wire signed [10:0] first=first_start(hsize_q);
    wire signed [10:0] offset=wanted>limit ? limit : wanted<first ? first : wanted;
    always @(posedge clk) begin
        hs_prev<=hs_ref;
        if(reset) begin phase<=0;hs_prev<=0;end
        else if(hs_ref && !hs_prev) phase<=0;
        else if(tick) phase<=8'(next_phase-period);
        else phase<=next_phase[7:0];
    end
    // As in Simple156, content shift retains native HSync and clamps geometry
    // to its legal porch; the read engine and cadence share hs_ref.
    crt_adjust #(.VTOTAL(272),.HTOTAL(384),.HPOS_MODE(1)) adjust (
        .clk(clk),.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(active_q),
        .hsize(hsize_q),.hoffset(offset[8:0]),
        .voffset({vposition_q[4],vposition_q}),
        .r_in(red_in),.g_in(green_in),.b_in(blue_in),
        .hs_in(hs_in),.vs_in(vs_in),.hb_in(hblank_in),.vb_in(vblank_in),
        .r_out(rr),.g_out(gg),.b_out(bb),.hs_out(hh),.vs_out(vv),
        .hb_out(hb),.vb_out(vb),.hs_ref_out(hs_ref)
    );
    assign ce_out=read_ce;
    assign {red_out,green_out,blue_out}=active_q ? {rr,gg,bb} : {red_in,green_in,blue_in};
    assign {hs_out,vs_out,hblank_out,vblank_out}=active_q ? {hh,vv,hb,vb} : {hs_in,vs_in,hblank_in,vblank_in};
endmodule
