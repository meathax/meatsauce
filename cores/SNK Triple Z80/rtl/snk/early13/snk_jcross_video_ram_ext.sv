// SPDX-License-Identifier: GPL-3.0-or-later
//Author: @RndMnkIII
// HAL21 adapter generated from snk_early_board: actual TTL tile/sprite/linebuffer/PROM paths.
// Source coordinate equivalence and real-frame comparison remain required before integration.
`default_nettype none
module snk_jcross_video_ram_ext(
 input wire presentation_180,output wire CE_PIXEL_PRE,
 output wire bg_vram_en,tx_vram_en,spr_vram_en,output wire [12:0] bg_vram_index,output wire [10:0] tx_vram_index,output wire [7:0] spr_vram_index,input wire [7:0] bg_vram_data,tx_vram_data,input wire [31:0] spr_vram_word,
 output wire [14:0] tx_byte_addr,output wire [14:0] bg_socket_addr,sp_socket_addr,input wire [7:0] tx_byte_data,bg_byte_data,input wire [23:0] sp_plane_data,output wire [9:0] prom_addr,input wire [11:0] prom_data,
 input RESETn,VIDEO_RSTn,i_clk,input [24:0] ioctl_addr,input [7:0] ioctl_data,input ioctl_wr,
 input canonical_wr,input [15:0] canonical_addr,input [7:0] canonical_data,
 input flip,bg_tile_bank,input [3:0] bg_palette_bank,input [8:0] bg_x,bg_y,sprite_x,sprite_y,
 input [2:0] layer_ena_dbg,
 output [3:0] R,G,B,output HBLANK,VBLANK,HSYNC,VSYNC,
 output [8:0] SCR_Y,SCR_X,output VBL,SYNC,VS,HS,DISP,PIX_CLK,CE_PIXEL
);
 wire tnk3_mode=1;
 reg [24:0] video_ioctl_addr;
 always @*begin
  video_ioctl_addr=ioctl_addr;
  // JC native planes are 8KiB: p0 0x50000, p1 0x52000, p2 0x54000; padding must not overwrite a socket.
  if(ioctl_addr>=25'h52000&&ioctl_addr<25'h54000)video_ioctl_addr=25'h60000+(ioctl_addr-25'h52000);
  else if(ioctl_addr>=25'h54000&&ioctl_addr<25'h56000)video_ioctl_addr=25'h70000+(ioctl_addr-25'h54000);
  else if(ioctl_addr>=25'h60000&&ioctl_addr<25'h60c00)video_ioctl_addr=25'h80000+(ioctl_addr-25'h60000);
  else if(ioctl_addr>=25'h56000&&ioctl_addr<25'h60000)video_ioctl_addr=25'h1000000;
  else if(ioctl_addr>=25'h60c00)video_ioctl_addr=25'h1000000; // native padding after PROMs must not overwrite sprite plane p1 (0x60000 socket)
 end
    logic VRD, AE, BE;
    
    logic CK0, CK0n, CK1, CK1n, LDn;
    logic HLDn;
    (* keep *) logic [8:0] H;
    (* keep *) logic [2:0] Hn;
    logic [8:0] FH;
    logic FCK;
    logic [7:0] Y;
    logic [7:0] X;
    logic [8:0] FV;
    logic VCKn;
    logic LT;
    logic VLK;
    logic VFLGn;
    logic VDG, V_C;
    logic VWE, VOE;
    logic BWA, A_B, RLA, RLB, WBA, WBB;
    logic LA, LC, LD, HD8;

    //CPU A data bus (tri-state)
    logic  [7:0] AD;
    
    //common buses
    logic [7:0] VD_out, VD_in;
    logic [12:0] VA;
    wire B1_COLBK;
    wire wave_c_mode=0;

    //Video Registers and CS 
    logic FRONT_VIDEO_CSn;
    logic SIDE_VRAM_CSn;
    logic DISC;
    logic MSB; //Video Attribs.
    logic FSX; //Front video scroll X
    logic FSY; //Fraont video scroll Y
    logic B1SX; //Back1 video scroll X
    logic B1SY; //Back1 video scroll Y
    logic SIDE_COLOR_BANK; //Unknown write registers
    logic BACK1_TILE_COLOR_BANK;
    logic BACK1_VRAM_CSn;

    //Video Attributes
    logic INV;  //Flip screen (invert)
    logic INVn; //Negated flip screen
    logic B1X8; //BACK1 tile layer scroll X MSB
    logic B1Y8; //BACK1 tile layer scroll Y MSB
    logic FX8;  //FRONT tile layer scroll X MSB
    logic FY8;  //FRONT tile layer scroll Y MSB
    
    //IO devices
    logic COIN;
    logic P1;
    logic P2;
    logic P1_P2;
    logic MCODE;
    logic DIP1;
    logic DIP2;

     logic clk_13p4_cen;
     logic clk_13p4;
     logic clk_13p4b_cen;
     logic clk_13p4b;
     logic clk_6p7_cen;
     logic clk_6p7b_cen;
     logic clk_3p35_cen;
     logic clk_3p35b_cen;
     logic clk_4_cen;
     logic clk_4b_cen;

    snk_early_master_cen #(.CLK_HZ(93800000),.VIDEO_LOCK(1)) amc_clk_cen(
        .i_clk(i_clk),.aso_grid(1'b0),
        .clk_13p4_cen(clk_13p4_cen),
        .clk_13p4(clk_13p4),
        .clk_13p4b_cen(clk_13p4b_cen),
        .clk_13p4b(clk_13p4b),
        .clk_6p7_cen(clk_6p7_cen),
        .clk_6p7b_cen(clk_6p7b_cen),
        .clk_3p35_cen(clk_3p35_cen),
        .clk_3p35b_cen(clk_3p35b_cen),
        .clk_4_cen(clk_4_cen),
        .clk_4b_cen(clk_4b_cen)
    );
    
    assign B1_COLBK=0;
    assign HS=HSYNC;assign VS=VSYNC;
	 // Final RGBg13/g14 consume the risingCK1 edge; publish its oneclockresponse-valid tag.
 reg ck1_pixel_history=1'b1, pixel_response_valid=1'b0;
    always @(posedge i_clk) begin
        if (!VIDEO_RSTn) begin
            ck1_pixel_history <= 1'b1;
            pixel_response_valid <= 1'b0;
        end else begin
            ck1_pixel_history <= CK1;
            pixel_response_valid <= CK1 && !ck1_pixel_history;
        end
    end
 assign CE_PIXEL=pixel_response_valid;
 assign CE_PIXEL_PRE=VIDEO_RSTn && CK1 && !ck1_pixel_history;
 wire[7:0]presentation_X;wire presentation_DISP; 

snk_hal21_timing amc_clocks_sync(
 .presentation_180(presentation_180),.presentation_X(presentation_X),.presentation_DISP(presentation_DISP),
        .tnk3_mode(tnk3_mode),.native_sprite_x(sprite_y[7:0]),
    .clk(i_clk), //53.6
    .clk_13p4_cen(clk_13p4_cen), //CK0
    .clk_13p4(clk_13p4),
    .clk_13p4b_cen(clk_13p4b_cen), //CK0n
    .clk_13p4b(clk_13p4b),
    .clk_6p7_cen(clk_6p7_cen),
    .clk_6p7b_cen(clk_6p7b_cen),
    .reset(VIDEO_RSTn),
    .VIDEO_RSTn(VIDEO_RSTn),
    .INVn(INVn), //replace for INVn
    .FSX(FSX),
    .FX8(FX8), //replace for FX8
    .VD_in(VD_in),
    .VRD(VRD), //replace for VRD
    .AE(AE), //replace for AE
    .BE(BE), //replace for BE
    //output
    .CK0(CK0),
    .CK0n(CK0n),
    .HLDn(HLDn),
    .CK1(CK1),
    .CK1n(CK1n),
    .H(H),
    .Hn(Hn),
    .FH(FH),
    .FCK(FCK),
    .Y(Y),
    .X(X),
    .FV(FV),
    .VCKn(VCKn),
    .VBL(VBL),
    .DISP(DISP),
    .SYNC(SYNC),
	 .HBLANK(HBLANK),
	 .VBLANK(VBLANK),
    .HSYNC(HSYNC),
    .VSYNC(VSYNC),
    .LT(LT),
    //
    .VWE(),
    .VOE(),
    .BWA(BWA),
    .A_B(A_B),
    .RLA(RLA),
    .RLB(RLB),
    .WBA(WBA),
    .WBB(WBB),
    .VDG(),
    .VLK(VLK),
    .V_C(),
    .VFLGn(VFLGn),
    .HD8(HD8),
    .LC(LC),
    .LD(LD),
    .LA(LA)
);
    // Canonical write events mirror actual shared RAM into the existing video primitives.
    // These primitives retain their original true dual-port video SRAMs.
    reg [15:0] write_addr_q=0;
    reg write_q=0,write_q2=0;
    always @(posedge i_clk)begin
      if(!VIDEO_RSTn)begin write_q<=0;write_q2<=0;VD_in<=0;write_addr_q<=0;end
      else begin
        write_q<=canonical_wr;write_q2<=write_q;
        if(canonical_wr)begin VD_in<=canonical_data;write_addr_q<=canonical_addr;end
      end
    end
    assign VRD=1'b1;assign AE=0;assign BE=0;
    assign VDG=0;assign VOE=1;assign VWE=!write_q2;assign V_C=0;
    assign FRONT_VIDEO_CSn=!(write_q2&&write_addr_q>=16'he000&&write_addr_q<=16'he7ff);
    assign BACK1_VRAM_CSn=!(write_q2&&write_addr_q>=16'he800&&write_addr_q<=16'hf7ff);
    assign SIDE_VRAM_CSn=!(write_q2&&write_addr_q>=16'hf800);
    assign VA=write_addr_q>=16'hf800 ? write_addr_q-16'hf800 :
      write_addr_q>=16'he800 ? write_addr_q-16'he800 : write_addr_q-16'he000;
    assign FSX=write_q2&&write_addr_q==16'hd500;
    assign B1SX=write_q2&&write_addr_q==16'hd700;
    assign B1SY=write_q2&&write_addr_q==16'hd600;
    assign INV=flip;assign INVn=!flip;
    // Row comparator consumes sprite byte0 (MAME Y); line buffer uses byte2 (MAME X).
    assign FX8=sprite_y[8];assign FY8=sprite_x[8];
    assign B1X8=bg_y[8];
    // HAL overrides inherited flipped -32 background DY with +224: precisely +256.
    assign B1Y8=bg_x[8]^flip;
    wire [7:0] FY=sprite_x[7:0];
    wire [1:0] BACK1_TILE_BANK={1'b0,bg_tile_bank};
    // Canonical bank already has XOR8; donor PAL applies XOR8 again.
    wire [3:0] BACK1_COLOR_BANK=bg_palette_bank ^ 4'h8;
    //Side Layer hardware
    logic [6:0] SD;
    // ASO character palettes arrive with the side pixels.

    logic SIDE_SELn;
    logic [7:0] side_vout;
    snk_early_text_ram_ext amc_side_sync(
 .tx_vram_en(tx_vram_en),.tx_vram_index(tx_vram_index),.tx_vram_data(tx_vram_data),
 .tx_byte_addr(tx_byte_addr),.tx_byte_data(tx_byte_data),
        .text_bank(wave_c_mode && B1_COLBK),
        .VIDEO_RSTn(VIDEO_RSTn),
        .clk(i_clk),
        .CK1(CK1),
    //Flip screen control
        .INV(INV),
        .INVn(INVn),

    //common video data bus
        .VD_in(VD_in),
        .VD_out(side_vout),
     //hps_io rom interface
        .ioctl_addr(video_ioctl_addr),
        .ioctl_wr(ioctl_wr),
        .ioctl_data(ioctl_data),
    //Side SRAM address selector
        .V_C(V_C),
    //A address
        .SIDE_VRAM_CSn(SIDE_VRAM_CSn),
        .VA(VA[10:0]),
    //B address
        .VFLGn(VFLGn),
        .H8(H[8]),
        .Y(Y[7:3]), //Y[7:3] in schematics
        .X(presentation_X), 

    //side SRAM control
        .VRD(VRD),
        .VDG(VDG),
        .VOE(VOE),
        .VWE(VWE),

    //clocking
        .VLK(VLK),
        .H2n(Hn[2]),
        .H1n(Hn[1]),
        .H0n(Hn[0]),

    //side palette index color
        .SD(SD)
    );

    logic [7:0] B1D;
    // Background palette bits travel with the shared background pixels.
    logic [7:0] back1_vout;
    snk_jcross_background_ram_ext amc_back1_sync(
 .bg_vram_en(bg_vram_en),.bg_vram_index(bg_vram_index),.bg_vram_data(bg_vram_data),
 .bg_socket_addr(bg_socket_addr),.bg_byte_data(bg_byte_data),
        .native_bg_x(bg_y[7:0]),.native_bg_y(bg_x[7:0]),
        .B1_COLORBANK(BACK1_COLOR_BANK),.B1_COLBK(B1_COLBK),.JMP_B1D7(1'b0),
        .tnk3_mode(1'b0),
        .VIDEO_RSTn(VIDEO_RSTn),
        .clk(i_clk),
        .CK1(CK1),
        .RESET(VIDEO_RSTn),
        //Flip screen control
        .INV(INV), //Flip screen, in real pcb two LS368 chained gates
        .INVn(INVn),
        //common video data bus
        .VD_in(VD_in),
        .VD_out(back1_vout),
        //hps_io rom interface
        .ioctl_addr(video_ioctl_addr),
        .ioctl_wr(ioctl_wr),
        .ioctl_data(ioctl_data),
        //Registers
        .B1SY(B1SY),
        .B1SX(B1SX),
        //MSBs
        .B1Y8(B1Y8),
        .B1X8(B1X8),
        //VIDEO/CPU Selector
        .V_C(V_C),
        //B address
        .H8(H[8]),
        .Y(Y[7:3]), //Y[7:3] in schematics
        .H2(H[2]),
        .H1(H[1]),
        .H0(H[0]),
        .X(presentation_X), 
        .VA(VA),
        .BACK1_VRAM_CSn(BACK1_VRAM_CSn),
        .B1_TILEBANK(BACK1_TILE_BANK), //from CPU_PCB 5A(15,12)
        
        //A address
        .VFLGn(VFLGn),

        //side SRAM control
        .VRD(VRD),
        .VDG(VDG),
        .VOE(VOE),
        .VWE(VWE),

        //clocking
        .CK1n(CK1n),
        .LA(LA),
        .VLK(VLK),
        //input wire H3

        //Back1 data color
        .B1D(B1D)
    );
    
    logic [7:0] FD;
    logic [8:0] FL_Y;
    logic [7:0] front_vout;
    snk_jcross_sprites_ram_ext amc_front_sync(
 .spr_vram_en(spr_vram_en),.spr_vram_index(spr_vram_index),.spr_vram_word(spr_vram_word),
 .sp_socket_addr(sp_socket_addr),.sp_plane_data(sp_plane_data),
        .wave_c_mode(wave_c_mode),
        .tnk3_mode(tnk3_mode),
        .VIDEO_RSTn(VIDEO_RSTn),
        .clk(i_clk),
        .CK1(CK1),
        //common video data bus
        .VD_in(VD_in),
        .VD_out(front_vout),
        //hps_io rom interface
        .ioctl_addr(video_ioctl_addr),
        .ioctl_wr(ioctl_wr),
        .ioctl_data(ioctl_data),
        //Side SRAM address selector V/C
        .V_C(V_C),
        //B address
        .FRONT_VIDEO_CSn(FRONT_VIDEO_CSn),
        .VA(VA[11:0]), //VA[11:0]
        //A address
        .VCKn(VCKn),
        //front SRAM control
        .VRD(VRD),
        .VDG(VDG),
        .VOE(VOE),
        .VWE(VWE),
        //clocking
        .FH(FH[8:4]),
        .FV(FV),
        .LC(LC),
        .VLK(VLK),
	    //.VLK(~VLK), //HACK, do not do nothing
        .FCK(FCK),
        //.FCK(~FCK), //HACK, mess sprites
        .H3(H[3]),
        .LD(LD),
        .CK0(CK0),
        //front data output
        .FD(FD),
        .FL_Y(FL_Y)
    );

    logic [7:0] LD_BUF;
    logic FYocho;
    assign FYocho = FY8;
    AlphaMissionCore_LineBuffer_sync amc_linebuf_sync(
        //inputs:
        .VIDEO_RSTn(VIDEO_RSTn),
        .clk(i_clk),
        .RESETn(VIDEO_RSTn),
        .FD(FD),
        .LT(LT),
        .VCKn(VCKn),
        .CK1(CK1),
        .CK1n(CK1n),
        .CK0(CK0),
        .CK0n(CK0n),
        .FCK(FCK),
        .LD(LD),
        .FL_Y(FL_Y), //comes from FRONT output
        .HLD(HLDn),
        .FY8(FYocho),
        .FY(FY),
        .INVn(INVn),
        //output:
        .LD_BUF(LD_BUF)
    );

    //Video out multiplexer
        assign VD_out = ( (!VDG && !SIDE_VRAM_CSn)   ? side_vout  : (
                          (!VDG && !BACK1_VRAM_CSn)  ? back1_vout : (
                          (!VDG && !FRONT_VIDEO_CSn) ? front_vout : 8'hff ))); //default bus data works as tri-state pulled up data bus
    //

    snk_early_palette_ram_ext amc_video_mixer(
 .prom_addr(prom_addr),.prom_data(prom_data),
        .tnk3_mode(tnk3_mode),
    //clocks
        .VIDEO_RSTn(VIDEO_RSTn),
        .clk(i_clk),
        .HD8(HD8),
        .H1(H[1]),
        .CK1(CK1),
        .CK1n(CK1n),
        //hps_io rom interface
        .ioctl_addr(video_ioctl_addr),
        .ioctl_wr(ioctl_wr),
        .ioctl_data(ioctl_data),

        //dbg layer en/disable interface
        .layer_ena_dbg(layer_ena_dbg),
        //Graphics layers
        .LD(LD_BUF), //Line buffer
        //.LD(8'hff), //bypass
        .SD(SD), //Side layer
        .B1D(B1D), //Background layer
        //.B1D(8'hff), //Background layer

        //Final pixel color RGB triplet
        .DISP(presentation_DISP), //enable/disable pixel color
        //Final pixel color RGB triplet,
        .R(R),
        .G(G),
        .B(B)
    );

    assign SCR_X = X;
    assign SCR_Y = {H[8],Y[7:3],H[2:0]};
    assign PIX_CLK = CK1;
endmodule
