// Private ROM-only adapter qualification fixture; not a production root.
module snk_hsj_renderer_shared(input wire RESETn,VIDEO_RSTn,i_clk,input wire [7:0] profile,input wire display_flip,input wire flip,bg_tile_bank,input wire [3:0] bg_palette_bank,input wire [8:0] bg_x,bg_y,sprite_x,sprite_y,input wire [2:0] layer_ena_dbg,input wire [1:0] tnk_bg_bank,input wire tnk_tx_bank,input wire [31:0] memory_video_data,input wire [127:0] memory_video_words,input wire [7:0] txd,bgd,input wire [23:0] spd,input wire [11:0] prd,output wire [3:0] memory_video_valid,output wire [13:0] memory_video_addr0,memory_video_addr1,memory_video_addr2,memory_video_addr3,output wire [14:0] tx_byte_addr,bg_socket_addr,sp_socket_addr,output wire [9:0] prom_addr,output wire [3:0] R,output wire [3:0] G,output wire [3:0] B,output wire HBLANK,output wire VBLANK,output wire HSYNC,output wire VSYNC,output wire [8:0] SCR_Y,output wire [8:0] SCR_X,output wire VBL,output wire SYNC,output wire VS,output wire HS,output wire DISP,output wire PIX_CLK,output wire CE_PIXEL);
wire CE_PIXEL_PRE0,CE_PIXEL_PRE1,CE_PIXEL_PRE2;
wire[3:0]native_R,native_G,native_B;
reg display_flip_latched=0;
reg[7:0]display_profile;
wire bgen0,txen0,spen0;wire[12:0] bgi0;wire[10:0]txi0;wire[7:0]spi0;
wire [14:0] tx0,bg0,sp0; wire [9:0] pr0;
wire [3:0] R0;
wire [3:0] G0;
wire [3:0] B0;
wire HBLANK0;
wire VBLANK0;
wire HSYNC0;
wire VSYNC0;
wire [8:0] SCR_Y0;
wire [8:0] SCR_X0;
wire VBL0;
wire SYNC0;
wire VS0;
wire HS0;
wire DISP0;
wire PIX_CLK0;
wire CE_PIXEL0;
snk_jcross_video_ram_ext v0(.bg_vram_en(bgen0),.tx_vram_en(txen0),.spr_vram_en(spen0),.bg_vram_index(bgi0),.tx_vram_index(txi0),.spr_vram_index(spi0),.bg_vram_data(memory_video_data[15:8]),.tx_vram_data(memory_video_data[23:16]),.spr_vram_word(memory_video_words[31:0]),.RESETn(RESETn),.VIDEO_RSTn(VIDEO_RSTn),.i_clk(i_clk),.ioctl_addr(25'b0),.ioctl_data(8'b0),.ioctl_wr(1'b0),.canonical_wr(1'b0),.canonical_addr(16'b0),.canonical_data(8'b0),.flip(flip),.bg_tile_bank(bg_tile_bank),.bg_palette_bank(bg_palette_bank),.bg_x(bg_x),.bg_y(bg_y),.sprite_x(sprite_x),.sprite_y(sprite_y),.layer_ena_dbg(layer_ena_dbg),.tx_byte_addr(tx0),.bg_socket_addr(bg0),.sp_socket_addr(sp0),.prom_addr(pr0),.tx_byte_data(txd),.bg_byte_data(bgd),.sp_plane_data(spd),.prom_data(prd),.R(R0),.G(G0),.B(B0),.HBLANK(HBLANK0),.VBLANK(VBLANK0),.HSYNC(HSYNC0),.VSYNC(VSYNC0),.SCR_Y(SCR_Y0),.SCR_X(SCR_X0),.VBL(VBL0),.SYNC(SYNC0),.VS(VS0),.HS(HS0),.DISP(DISP0),.PIX_CLK(PIX_CLK0),.presentation_180(display_flip_latched),.CE_PIXEL_PRE(CE_PIXEL_PRE0),.CE_PIXEL(CE_PIXEL0));
wire bgen1,txen1,spen1;wire[12:0] bgi1;wire[10:0]txi1;wire[7:0]spi1;
wire [14:0] tx1,bg1,sp1; wire [9:0] pr1;
wire [3:0] R1;
wire [3:0] G1;
wire [3:0] B1;
wire HBLANK1;
wire VBLANK1;
wire HSYNC1;
wire VSYNC1;
wire [8:0] SCR_Y1;
wire [8:0] SCR_X1;
wire VBL1;
wire SYNC1;
wire VS1;
wire HS1;
wire DISP1;
wire PIX_CLK1;
wire CE_PIXEL1;
snk_sgladiat_video_ram_ext v1(.bg_vram_en(bgen1),.tx_vram_en(txen1),.spr_vram_en(spen1),.bg_vram_index(bgi1),.tx_vram_index(txi1),.spr_vram_index(spi1),.bg_vram_data(memory_video_data[15:8]),.tx_vram_data(memory_video_data[23:16]),.spr_vram_word(memory_video_words[31:0]),.RESETn(RESETn),.VIDEO_RSTn(VIDEO_RSTn),.i_clk(i_clk),.ioctl_addr(25'b0),.ioctl_data(8'b0),.ioctl_wr(1'b0),.canonical_wr(1'b0),.canonical_addr(16'b0),.canonical_data(8'b0),.flip(flip),.bg_tile_bank(bg_tile_bank),.bg_palette_bank(bg_palette_bank),.bg_x(bg_x),.bg_y(bg_y),.sprite_x(sprite_x),.sprite_y(sprite_y),.layer_ena_dbg(layer_ena_dbg),.tx_byte_addr(tx1),.bg_socket_addr(bg1),.sp_socket_addr(sp1),.prom_addr(pr1),.tx_byte_data(txd),.bg_byte_data(bgd),.sp_plane_data(spd),.prom_data(prd),.R(R1),.G(G1),.B(B1),.HBLANK(HBLANK1),.VBLANK(VBLANK1),.HSYNC(HSYNC1),.VSYNC(VSYNC1),.SCR_Y(SCR_Y1),.SCR_X(SCR_X1),.VBL(VBL1),.SYNC(SYNC1),.VS(VS1),.HS(HS1),.DISP(DISP1),.PIX_CLK(PIX_CLK1),.presentation_180(display_flip_latched),.CE_PIXEL_PRE(CE_PIXEL_PRE1),.CE_PIXEL(CE_PIXEL1));
wire bgen2,txen2,spen2;wire[12:0] bgi2;wire[10:0]txi2;wire[7:0]spi2;
wire [14:0] tx2,bg2,sp2; wire [9:0] pr2;
wire [3:0] R2;
wire [3:0] G2;
wire [3:0] B2;
wire HBLANK2;
wire VBLANK2;
wire HSYNC2;
wire VSYNC2;
wire [8:0] SCR_Y2;
wire [8:0] SCR_X2;
wire VBL2;
wire SYNC2;
wire VS2;
wire HS2;
wire DISP2;
wire PIX_CLK2;
wire CE_PIXEL2;
snk_hal21_video_ram_ext v2(.aso_mode(profile==8'd6),.attr_mode(profile>=8'd7&&profile<=8'd10),.wave_c_in(profile>=8'd8&&profile<=8'd10),.tnk_family(profile>=8'd6&&profile<=8'd10),.bg_attr_data(memory_video_data[31:24]),.tnk_bg_bank(tnk_bg_bank),.tnk_tx_bank(tnk_tx_bank),.bg_vram_en(bgen2),.tx_vram_en(txen2),.spr_vram_en(spen2),.bg_vram_index(bgi2),.tx_vram_index(txi2),.spr_vram_index(spi2),.bg_vram_data(memory_video_data[15:8]),.tx_vram_data(memory_video_data[23:16]),.spr_vram_word(memory_video_words[31:0]),.RESETn(RESETn),.VIDEO_RSTn(VIDEO_RSTn),.i_clk(i_clk),.ioctl_addr(25'b0),.ioctl_data(8'b0),.ioctl_wr(1'b0),.canonical_wr(1'b0),.canonical_addr(16'b0),.canonical_data(8'b0),.flip(flip),.bg_tile_bank(bg_tile_bank),.bg_palette_bank(bg_palette_bank),.bg_x(bg_x),.bg_y(bg_y),.sprite_x(sprite_x),.sprite_y(sprite_y),.layer_ena_dbg(layer_ena_dbg),.tx_byte_addr(tx2),.bg_socket_addr(bg2),.sp_socket_addr(sp2),.prom_addr(pr2),.tx_byte_data(txd),.bg_byte_data(bgd),.sp_plane_data(spd),.prom_data(prd),.R(R2),.G(G2),.B(B2),.HBLANK(HBLANK2),.VBLANK(VBLANK2),.HSYNC(HSYNC2),.VSYNC(VSYNC2),.SCR_Y(SCR_Y2),.SCR_X(SCR_X2),.VBL(VBL2),.SYNC(SYNC2),.VS(VS2),.HS(HS2),.DISP(DISP2),.PIX_CLK(PIX_CLK2),.presentation_180(display_flip_latched),.CE_PIXEL_PRE(CE_PIXEL_PRE2),.CE_PIXEL(CE_PIXEL2));
wire [14:0] txa=profile==3?tx0:profile==4?tx1:tx2,bga=profile==3?bg0:profile==4?bg1:bg2,spa=profile==3?sp0:profile==4?sp1:sp2;wire [9:0] pra=profile==3?pr0:profile==4?pr1:pr2;
 
assign native_R=profile==3?R0:profile==4?R1:R2;
assign native_G=profile==3?G0:profile==4?G1:G2;
assign native_B=profile==3?B0:profile==4?B1:B2;
assign HBLANK=profile==3?HBLANK0:profile==4?HBLANK1:HBLANK2;
assign VBLANK=profile==3?VBLANK0:profile==4?VBLANK1:VBLANK2;
assign HSYNC=profile==3?HSYNC0:profile==4?HSYNC1:HSYNC2;
assign VSYNC=profile==3?VSYNC0:profile==4?VSYNC1:VSYNC2;
assign SCR_Y=profile==3?SCR_Y0:profile==4?SCR_Y1:SCR_Y2;
assign SCR_X=profile==3?SCR_X0:profile==4?SCR_X1:SCR_X2;
assign VBL=profile==3?VBL0:profile==4?VBL1:VBL2;
assign SYNC=profile==3?SYNC0:profile==4?SYNC1:SYNC2;
assign VS=profile==3?VS0:profile==4?VS1:VS2;
assign HS=profile==3?HS0:profile==4?HS1:HS2;
assign DISP=profile==3?DISP0:profile==4?DISP1:DISP2;
assign PIX_CLK=profile==3?PIX_CLK0:profile==4?PIX_CLK1:PIX_CLK2;
assign CE_PIXEL=profile==3?CE_PIXEL0:profile==4?CE_PIXEL1:CE_PIXEL2;
wire[12:0]bgi=profile==3?bgi0:profile==4?bgi1:bgi2;wire[10:0]txi=profile==3?txi0:profile==4?txi1:txi2;wire[7:0]spi=profile==3?spi0:profile==4?spi1:spi2;wire bgen=profile==3?bgen0:profile==4?bgen1:bgen2,txen=profile==3?txen0:profile==4?txen1:txen2,spen=profile==3?spen0:profile==4?spen1:spen2;

// Shared-RAM layout of the video read ports. HSJ profiles (3..5): spr 0000, bg 0800 (1 byte/tile), tx 1800.
// TNK3-class (6..10): see snk_early_tnk_controller (aso: shared 0000/spr 0800/bg 1000 1B/tx 2000; 7..10: spr 0000, bg 0800 2B/tile, tx 2800).
wire tnk_fam=profile>=8'd6&&profile<=8'd10,aso_p=profile==8'd6,attr_p=profile>=8'd7&&profile<=8'd10;
assign memory_video_valid={attr_p&&bgen,txen,bgen,spen};
assign memory_video_addr0=aso_p ? 14'h0800+{6'b0,spi} : {6'b0,spi};
assign memory_video_addr1=attr_p ? 14'h0800+{1'b0,bgi[11:0],1'b0} : aso_p ? 14'h1000+{2'b0,bgi[11:0]} : 14'h0800+{1'b0,bgi};
assign memory_video_addr2=attr_p ? 14'h2800+{3'b0,txi} : aso_p ? 14'h2000+{3'b0,txi} : 14'h1800+{3'b0,txi};
assign memory_video_addr3=attr_p ? 14'h0800+{1'b0,bgi[11:0],1'b1} : 14'b0;assign tx_byte_addr=txa;assign bg_socket_addr=bga;assign sp_socket_addr=spa;assign prom_addr=pra;

always @(posedge i_clk)begin
 if(!RESETn || !VIDEO_RSTn || profile!=display_profile)display_flip_latched<=0;
 else if(CE_PIXEL && VBLANK)display_flip_latched<=display_flip;
 display_profile<=profile;
end
wire pixel_anticipate=profile==3?CE_PIXEL_PRE0:profile==4?CE_PIXEL_PRE1:CE_PIXEL_PRE2;
wire presentation_primed;
snk_hsj_presentation180_linebuffer presentation(
 .clk(i_clk),.reset(!RESETn || !VIDEO_RSTn),.enable(display_flip_latched),.profile(profile),
 .ce_pre(pixel_anticipate),.ce_response(CE_PIXEL),.hblank(HBLANK),.vblank(VBLANK),
 .rgb_in({native_R,native_G,native_B}),.rgb_out({R,G,B}),.primed(presentation_primed));

endmodule
