// Zero Team video chain bench: native raster -> px_* stage (OLD folded HBlank vs NEW
// per-line HBlank in vblank) -> sys arcade_video (15 kHz and forced scandoubler).
// Counts frames, VBlank-asserted lines seen at the VGA stage, DE lines per frame.
module vbench #(parameter NEWHB=0, SD=0)(input clk, input reset,
    output reg [31:0] frames, output reg [31:0] de_lines_last, output reg [31:0] vs_pulses,
    output reg [31:0] de_pixels_line_max);
    wire ce_pixel,hblank,vblank,hsync,vsync,de; wire [9:0] hpos,vpos,ax; wire [8:0] ay,vv; wire [9:0] hv;
    Raiden2_video_timing t(.clk(clk),.reset(reset),.mode_60hz(1'b0),.ce_pix(ce_pixel),.hpos(hpos),.vpos(vpos),
        .active_x(ax),.active_y(ay),.hblank(hblank),.vblank(vblank),.hsync(hsync),.vsync(vsync),.de(de),
        .h_vis_start(hv),.v_vis_start(vv));
    // pixel_display: native DE delayed 3 pixel enables (RGB-aligned), as the mixer's hold_de
    reg [2:0] dd=0; always @(posedge clk) if(ce_pixel) dd<={dd[1:0],de};
    wire pixel_display=dd[2];
    reg sync_h=0,sync_v=0,sync_vb=1,sync_hb=1;
    reg px_hs=0,px_vs=0,px_hb=1,px_vb=1,px_ce=0;
    reg [7:0] px_r=0;
    always @(posedge clk) begin
        px_ce<=ce_pixel;
        if(ce_pixel) begin
            px_r<=hpos[7:0]^vpos[7:0];
            px_hb<= reset || ((NEWHB && sync_vb) ? sync_hb : !pixel_display);
            px_vb<=sync_vb; px_hs<=sync_h; px_vs<=sync_v;
            sync_h<=hsync; sync_v<=vsync; sync_vb<=vblank; sync_hb<=hblank;
        end
    end
    wire [7:0] r,g,b; wire hs,vs,vde,vce,clkv; wire [1:0] sl; wire [21:0] gb=0;
    arcade_video #(.WIDTH(320),.DW(24)) av(.clk_video(clk),.ce_pix(px_ce),.RGB_in({px_r,px_r,px_r}),
        .HBlank(px_hb),.VBlank(px_vb),.HSync(px_hs),.VSync(px_vs),.CLK_VIDEO(clkv),.CE_PIXEL(vce),
        .VGA_R(r),.VGA_G(g),.VGA_B(b),.VGA_HS(hs),.VGA_VS(vs),.VGA_DE(vde),.VGA_SL(sl),.fx(3'd0),
        .forced_scandoubler(SD[0]),.gamma_bus(gb));
    reg vs_d=0,hs_d=0,de_d=0; reg [31:0] lines=0,pix=0; reg [31:0] first_de_line=0;
    always @(posedge clk) if(reset) begin frames<=0;de_lines_last<=0;vs_pulses<=0;de_pixels_line_max<=0;lines<=0;pix<=0; end else if(vce) begin
        vs_d<=vs; hs_d<=hs; de_d<=vde;
        if(vde) pix<=pix+1;
        if(de_d && !vde) begin lines<=lines+1; if(pix>de_pixels_line_max) de_pixels_line_max<=pix; pix<=0; end
        if(!vs_d && vs) begin vs_pulses<=vs_pulses+1; frames<=frames+1; de_lines_last<=lines; lines<=0; end
    end
endmodule
