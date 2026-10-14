// Zero Team native-stage check of the MeatCore credits overlay: 320x256 active
// in a 512x282 raster. Verifies pass-through when closed (3-pixel delay),
// opening from the menu bit, visible panel, any-button close and re-pass-through.
`timescale 1ns/1ps
module credits_overlay_check;
    reg clk=0; always #5 clk=~clk;
    reg reset=1, trig=0, dismiss=0;
    reg [1:0] div=0; reg ce=0;
    always @(posedge clk) begin div<=div+1; ce<=(div==2'd3); end   // one pixel per 4 clocks
    reg [9:0] x=0,y=0;
    wire hb=x>=320, vb=y>=256;
    wire hs=(x>=336&&x<368), vs=(y>=260&&y<264);
    wire [7:0] r=x[7:0]^y[7:0], g=x[8:1]^8'h5a, b=y[7:0]+8'h11;
    always @(posedge clk) if(ce) begin
        if(x==511) begin x<=0; y<=(y==281)?0:y+1; end else x<=x+1;
    end
    wire [7:0] ro,go,bo; wire hso,vso,hbo,vbo,de,active;
    credits_overlay #(.WIDTH(320),.HEIGHT(256),.SCALE_LOG2(0),.SCROLL_FRAMES(4)) dut(
        .clk_video(clk),.reset(reset),.ce_pixel(ce),.menu_trigger(trig),.dismiss(dismiss),
        .r_in(r),.g_in(g),.b_in(b),.hs_in(hs),.vs_in(vs),.hblank_in(hb),.vblank_in(vb),
        .r_out(ro),.g_out(go),.b_out(bo),.hs_out(hso),.vs_out(vso),.hblank_out(hbo),.vblank_out(vbo),
        .de_out(de),.active(active));
    // 3-pixel-enable delayed reference of the input
    reg [27:0] d1,d2,d3,d4; integer c1=0,c2=0,c3=0,c4=0; // {r,g,b,hs,vs,hb,vb} = 8*3+4 = 28
    always @(posedge clk) if(ce) begin d1<={r,g,b,hs,vs,hb,vb}; d2<=d1; d3<=d2; d4<=d3; end
    integer frame=0, diff_closed=0, diff_open=0, vis_open=0, i;
    reg [27:0] outv; always @* outv={ro,go,bo,hso,vso,hbo,vbo};
    reg prev_vb=0; integer phase=0;
    always @(posedge clk) if(ce) begin
        prev_vb<=vb;
        if(!reset && !hbo && !vbo) begin
            if((phase==0 && frame>=2) || phase==3) begin if(outv!==d3) diff_closed<=diff_closed+1; c1<=c1+(outv!==d1); c2<=c2+(outv!==d2); c3<=c3+(outv!==d3); c4<=c4+(outv!==d4); end
            if(phase==2) begin diff_open<=diff_open+(outv!==d3); end
        end
        if(prev_vb && !vb) begin
            frame<=frame+1;
            case(frame)
              4:  begin phase<=0; end
              6:  begin trig<=1; phase<=1; end
              9:  trig<=0;
              14: phase<=2;      // panel should be up
              19: phase<=1;
              20: begin dismiss<=1; end
              24: begin dismiss<=0; end   // held-open input released earlier: tap closes
              26: begin dismiss<=1; end
              28: begin dismiss<=0; end
              36: phase<=3;
            endcase
        end
    end
    initial begin
        repeat(100) @(posedge clk); reset<=0;
        wait(frame==44);
        $display("c1=%0d c2=%0d c3=%0d c4=%0d",c1,c2,c3,c4); $display("closed-diff=%0d open-diff=%0d active=%0b",diff_closed,diff_open,active);
        if(diff_closed==0 && diff_open>5000 && !active) $display("CREDITS_CHECK_PASS"); else $display("CREDITS_CHECK_FAIL");
        $finish;
    end
    initial begin #2_000_000_000; $display("TIMEOUT frame=%0d",frame); $finish; end
endmodule
