// MiSTer feature boundary. Pinned sys/ remains unchanged.
// Native game pixels/timing enter here; CRT Adjust defaults to bypass.
// GPL-3.0-or-later, combined with pinned GPL donors listed in the provenance.
module snk_mister_video #(
 parameter NATIVE_180=0,parameter WIDTH=512, parameter HTOTAL=512, parameter VTOTAL=264
)(
 input clk,reset,ce_pix,
 input [23:0] rgb,
 input hb,vb,hs,vs,
 input direct_video,forced_scandoubler,
 input [2:0] fx,
 input [1:0] rotation,scale_mode,aspect,
 input [11:0] hdmi_width,hdmi_height,
 input crt_active,
 input signed [4:0] crt_hsize,
 input signed [8:0] crt_hpos,
 input signed [5:0] crt_vpos,
 inout [21:0] gamma_bus,
 output CLK_VIDEO,CE_PIXEL,
 output [7:0] VGA_R,VGA_G,VGA_B,
 output VGA_HS,VGA_VS,VGA_DE,
 output [1:0] VGA_SL,
 output [12:0] VIDEO_ARX,VIDEO_ARY,
 output FB_EN,
 output [4:0] FB_FORMAT,
 output [11:0] FB_WIDTH,FB_HEIGHT,
 output [31:0] FB_BASE,
 output [13:0] FB_STRIDE,
 input FB_VBL,FB_LL,
 output DDRAM_CLK,
 input DDRAM_BUSY,
 output [7:0] DDRAM_BURSTCNT,
 output [28:0] DDRAM_ADDR,
 output [63:0] DDRAM_DIN,
 output [7:0] DDRAM_BE,
 output DDRAM_WE,DDRAM_RD
);
 wire [7:0] crt_r,crt_g,crt_b;
 wire crt_hs,crt_vs,crt_hb,crt_vb,hs_ref;
 // CRT resizing changes line-buffer sample addresses, never the output clock.
 wire read_ce=ce_pix;
 // Native raster measured per game (pixels per line, lines per frame): CRT Adjust negative H-Position/V-Shift
 // tap the sync delay line at the real line/frame length, whatever the family (late 420x236, wave 310x231, early 430x262...).
 reg [9:0] hcnt=0,hlen=0;reg [8:0] lcnt=0,vlen=0;reg hs_m_d=0,vs_m_d=0,vs_pend=0;
 always @(posedge clk) if(ce_pix) begin
  hs_m_d<=hs;vs_m_d<=vs;
  hcnt<=(hcnt==10'd1023) ? hcnt : hcnt+10'd1;
  if(vs&&!vs_m_d)vs_pend<=1;
  if(hs&&!hs_m_d)begin
   hlen<=hcnt+10'd1;hcnt<=0;
   lcnt<=(lcnt==9'd511) ? lcnt : lcnt+9'd1;
   if(vs_pend)begin vlen<=lcnt+9'd1;lcnt<=0;vs_pend<=0;end
  end
 end
 crt_adjust #(.VTOTAL(VTOTAL),.HTOTAL(HTOTAL),.HPOS_MODE(0)) geometry(
  .clk(clk),.pxl_cen(ce_pix),.pxl2_cen(read_ce),.hlen(hlen),.vlen(vlen),.active(crt_active),
  .hsize(crt_hsize),.hoffset(crt_hpos),.voffset(crt_vpos),
  .r_in(rgb[23:16]),.g_in(rgb[15:8]),.b_in(rgb[7:0]),
  .hs_in(hs),.vs_in(vs),.hb_in(hb|vb),.vb_in(vb),
  .r_out(crt_r),.g_out(crt_g),.b_out(crt_b),
  .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),
  .hs_ref_out(hs_ref));
 wire mixer_de;
 // True native bypass keeps the original RGB, CE and sync phase untouched.
 snk_arcade_video #(.WIDTH(WIDTH),.DW(24)) mixer(
  .clk_video(clk),.ce_pix(read_ce),
  .RGB_in(crt_active ? {crt_r,crt_g,crt_b} : rgb),
  .HBlank(crt_active ? crt_hb : hb),.VBlank(crt_active ? crt_vb : vb),
  .HSync(crt_active ? crt_hs : hs),.VSync(crt_active ? crt_vs : vs),
  .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),
  .VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
  .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(mixer_de),.VGA_SL(VGA_SL),
  .fx(fx),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus));
 wire quarter_turn=!direct_video && (rotation==1 || rotation==2);
 wire [2:0] scale=scale_mode==2 ? 3'd4 : {1'b0,scale_mode};
 wire [11:0] arx=aspect==0 ? (quarter_turn ? 12'd3 : 12'd4) : {10'd0,aspect}-12'd1;
 wire [11:0] ary=aspect==0 ? (quarter_turn ? 12'd4 : 12'd3) : 12'd0;
 video_freak scaling(
  .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),
  .HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),
  .VGA_DE(VGA_DE),.VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY),
  .VGA_DE_IN(mixer_de),.ARX(arx),.ARY(ary),
  .CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE(scale));
 snk_screen_rotate rotation_buffer(
  .reset(reset),
  .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),
  .VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
  .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
  .rotate_ccw(rotation==2),.no_rotate(!quarter_turn),
  .flip(!NATIVE_180 && !direct_video && rotation==3),.video_rotated(),
  .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
  .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
  .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),
  .DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
  .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD));
endmodule
