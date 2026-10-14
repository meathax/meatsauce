// SPDX-License-Identifier: GPL-3.0-or-later
module emu (`include "sys/emu_ports.vh");
 assign ADC_BUS='z;assign USER_OUT='1;assign {UART_RTS,UART_TXD,UART_DTR}=0;
 assign {SD_SCK,SD_MOSI,SD_CS}='z;
 assign VGA_F1=0;assign VGA_SCALER=0;assign VGA_DISABLE=0;
 assign HDMI_FREEZE=0;assign HDMI_BLACKOUT=0;assign HDMI_BOB_DEINT=0;
 assign AUDIO_S=1;assign AUDIO_MIX=0;assign LED_DISK=0;assign LED_POWER=0;assign BUTTONS=0;
 localparam CONF_STR={"StoneBall;;",
 "O[122:121],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
 "O[8:7],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
 "O[11:10],Rotate Screen,Off,90 CW,90 CCW,180;",
 "O[6:4],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;","-;",
 "DIP;","-;","O9,Autosave EEPROM,On,Off;","T[3],Save EEPROM;","R[0],Reset;",
 "J1,Shoot/Fight,Pass/Tackle,Push,Start,Coin;","jn,A,B,X,Start,Select;","V,development"};
 wire clk,vclk,locked;wire [127:0] status;wire [1:0] buttons;wire [31:0] joy0,joy1,joy2,joy3;
 wire forced_scandoubler,direct_video;wire [21:0] gamma_bus;
 wire download,upload,io_wr;wire [15:0] io_index;wire [26:0] io_addr;wire [7:0] io_data,nv_data;
 reg load_req;reg [22:0] load_addr;reg [15:0] load_data;reg [1:0] load_be;wire load_ack;
 reg rom_loaded=0,download_d=0,save_d=0;reg [22:0] byte_count=0;
 // MRA switch data arrives as index 254, little-endian by byte.  The first
 // byte is DSW1 (300004) and the second is DSW2 (300006), matching the
 // ordering used by the other MiSTer arcade cores.
 wire dip_download = download && (io_index == 16'd254);
 // MRA ROM index 1 carries one byte: 0 Stone Ball, 1 Ultimate Tennis, 2 Cheese Chase.
 reg [1:0] game = 2'd0;
 reg [15:0] dip_switches = 16'hfaff;
 wire mem_ready;wire wait_io=load_req || !mem_ready;
 hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps(.clk_sys(clk),.HPS_BUS(HPS_BUS),.EXT_BUS(),
 .buttons(buttons),.status(status),.forced_scandoubler(forced_scandoubler),.direct_video(direct_video),.gamma_bus(gamma_bus),.status_menumask(16'd0),.joystick_0(joy0),.joystick_1(joy1),.joystick_2(joy2),.joystick_3(joy3),
 .ioctl_download(download),.ioctl_upload(upload),.ioctl_index(io_index),.ioctl_addr(io_addr),.ioctl_wr(io_wr),.ioctl_dout(io_data),.ioctl_wait(wait_io),
 .ioctl_upload_req((status[3] && !save_d && nv_dirty) || as_req),.ioctl_upload_index(8'd2),.ioctl_din(nv_data));
 // Hi-score (EEPROM) autosave, on by default (OSD option "Autosave EEPROM").
 // The image is uploaded when the OSD opens, as on the other MiSTer arcade
 // cores, and every 2^29 clocks (~5.4 s) as a safety net, if the CPU wrote the
 // EEPROM since the last save. Dirty clears when an upload ends; a CPU write
 // during the upload keeps it set.
 reg [28:0] as_cnt=0;reg as_req=0,upload_d=0,osd_d=0;
 wire autosave=!status[9];
 always @(posedge clk) begin
   upload_d<=nv_saving;osd_d<=OSD_STATUS;as_cnt<=as_cnt+1'b1;as_req<=0;
   if(autosave && nv_dirty && !upload && !download && (&as_cnt || (OSD_STATUS && !osd_d))) as_req<=1;
 end
 wire nv_saving=upload && io_index==16'd2;
 // hps_io leaves ioctl_addr at the last uploaded byte (2047). An aborted
 // upload, or an upload of a different index, must leave the image dirty.
 wire nv_clear=upload_d && !upload && io_addr==27'd2047;
 wire sdram_clk,clk_vid;
 stone_pll pll(.refclk(CLK_50M),.reset(1'b0),.clk(clk),.vclk(vclk),.sdram_clk(sdram_clk),.clk_vid(clk_vid),.locked(locked));
 // Forward the phase-shifted SDRAM clock through the pin's DDIO register so the
 // clock-out delay is fixed at the I/O cell rather than set by fabric routing.
 // StoneBall.sdc sources the SDRAM_CLK generated clock from this same PLL output.
 altddio_out #(.extend_oe_disable("OFF"),.intended_device_family("Cyclone V"),.invert_output("OFF"),.lpm_hint("UNUSED"),
 .lpm_type("altddio_out"),.oe_reg("UNREGISTERED"),.power_up_high("OFF"),.width(1)) sdram_clk_ddr(
 .datain_h(1'b1),.datain_l(1'b0),.outclock(sdram_clk),.dataout(SDRAM_CLK),.aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
 wire fabric_reset;
 tms34010_reset_sync reset_sync(.clk_i(clk),.async_reset_i(!locked),.rst_o(fabric_reset));
 wire async_game_reset=fabric_reset || RESET || status[0] || buttons[1] || !rom_loaded || download || dip_download || !mem_ready;
 wire reset_game;
 tms34010_reset_sync game_reset_sync(.clk_i(clk),.async_reset_i(async_game_reset),.rst_o(reset_game));
 wire vreset;
 tms34010_reset_sync video_reset_sync(.clk_i(vclk),.async_reset_i(reset_game),.rst_o(vreset));
 always @(posedge clk) begin
   download_d<=download;save_d<=status[3];
   if(fabric_reset) begin load_req<=0;load_addr<=0;load_data<=0;load_be<=0;rom_loaded<=0;byte_count<=0;end
   else begin
     if(download && !download_d && io_index==0) begin rom_loaded<=0;byte_count<=0;end
     if(io_wr && download && io_index==0 && io_addr<27'h0500000) begin
       load_req<=1;load_addr<=io_addr[23:1];
       // CPU bytes arrive big-endian; graphics/samples arrive little-endian.
       if((io_addr<27'h0080000) ^ io_addr[0]) begin load_data<={io_data,8'd0};load_be<=2;end
       else begin load_data<={8'd0,io_data};load_be<=1;end
     end
     if(load_ack) begin load_req<=0;byte_count<=byte_count+1'b1;end
     if(!download && !load_req && byte_count==23'h500000) rom_loaded<=1;
   end
   if (download && io_wr && io_index==16'd1 && !(|io_addr)) game <= io_data[1:0];
   if (fabric_reset)
     dip_switches <= 16'hfaff;
   else if (dip_download && io_wr && !(|io_addr[26:1])) begin
     if (io_addr[0]) dip_switches[15:8] <= io_data;
     else            dip_switches[7:0]  <= io_data;
   end
 end
 function automatic [7:0] player(input [31:0] j);
   player={j[6],j[5],j[4],j[7],j[0],j[1],j[2],j[3]};
 endfunction
 wire mreq,mwe,mack;wire [22:0] maddr;wire [15:0] mdin,mdout;wire [1:0] mbe;
 wire [23:0] rgb;wire hs,vs,hblank,vblank;wire signed [15:0] audio;wire nv_dirty;wire illegal,blitbusy;
 stone_board board(.game(game),.clk(clk),.reset(reset_game),.fabric_reset(fabric_reset),.vclk(vclk),.vreset(vreset),
 .p1(player(joy0)),.p2(player(joy1)),.p3(player(joy2)),.p4(player(joy3)),.coins({4'd0,joy3[8],joy2[8],joy1[8],joy0[8]}),.dip1(dip_switches[7:0]),.dip2(dip_switches[15:8]),
 .load_req(load_req),.load_addr(load_addr),.load_data(load_data),.load_be(load_be),.load_ack(load_ack),
 .nv_wr(io_wr && download && io_index==2),.nv_addr(io_addr[10:0]),.nv_din(io_data),.nv_dout(nv_data),.nv_dirty(nv_dirty),.nv_clear(nv_clear),.nv_saving(nv_saving),
 .mem_req(mreq),.mem_we(mwe),.mem_addr(maddr),.mem_din(mdin),.mem_be(mbe),.mem_ack(mack),.mem_dout(mdout),
 .rgb(rgb),.hs(hs),.vs(vs),.de(),.hblank(hblank),.vblank(vblank),.audio(audio),.debug_gsp_pc(),.debug_cpu_addr(),.debug_illegal(illegal),.debug_blit_busy(blitbusy));
 stone_sdram_bridge memory(.clk(clk),.reset(fabric_reset),.req(mreq),.we(mwe),.addr(maddr),.din(mdin),.be(mbe),.ack(mack),.dout(mdout),.ready(mem_ready),
 .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),.SDRAM_CKE(SDRAM_CKE));
 // Video output. CLK_VIDEO is 5x the pixel clock (and 1/3 of clk) from the
 // same PLL, so HDMI direct video (and RetroTink-class receivers), the scaler
 // and the analog scandoubler all get a clock the HDMI transmitter accepts plus
 // a real pixel enable. The pixel-domain outputs change only on vclk edges,
 // which coincide with every fifth clk_vid edge; STA times this related-clock
 // capture.
 reg vtog=1'b0;
 always @(posedge vclk) vtog<=~vtog;
 reg t0,t1,ce_pix,hs0,vs0,hb0,vb0,hs_p,vs_p,hb_p,vb_p;reg [23:0] rgb0,rgb_p;
 // Supply sync while the GSP's video timing is unprogrammed.
 reg [8:0] fh=9'd0,fv=9'd0;reg real_v=1'b0,vs_q=1'b0;reg [2:0] vs_edges=3'd0;
 always @(posedge vclk) begin
   vs_q<=vs;
   fh<=(fh==9'd427)?9'd0:fh+1'b1;
   if(fh==9'd427) fv<=(fv==9'd312)?9'd0:fv+1'b1;
   // The GSP's reset state can emit one stray edge; trust it after two full pulses.
   if(vreset) begin real_v<=1'b0;vs_edges<=3'd0;end
   else if(vs!=vs_q && !real_v) begin vs_edges<=vs_edges+1'b1;if(vs_edges==3'd3) real_v<=1'b1;end
 end
 wire [23:0] rgb_m=real_v ? rgb:24'd0;
 wire hs_m=real_v ? hs:(fh>=9'd340 && fh<9'd372);
 wire vs_m=real_v ? vs:(fv>=9'd260 && fv<9'd263);
 wire hb_m=real_v ? hblank:(fh>=9'd320);
 wire vb_m=real_v ? vblank:(fv>=9'd256);
 always @(posedge clk_vid) begin
   t0<=vtog;rgb0<=rgb_m;hs0<=hs_m;vs0<=vs_m;hb0<=hb_m;vb0<=vb_m;
   t1<=t0;ce_pix<=t0^t1;
   if(t0^t1) begin rgb_p<=rgb0;hs_p<=hs0;vs_p<=vs0;hb_p<=hb0;vb_p<=vb0;end
 end
 wire vga_de;
 arcade_video #(.WIDTH(320),.DW(24)) arcade_video(.clk_video(clk_vid),.ce_pix(ce_pix),.RGB_in(rgb_p),.HBlank(hb_p),.VBlank(vb_p),.HSync(hs_p),.VSync(vs_p),
 .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(vga_de),.VGA_SL(VGA_SL),
 .fx(status[6:4]),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus));
 // Screen rotation for HDMI (through the framework's DDR frame buffer). Analog
 // and direct video are never rotated, so a physical CRT keeps its orientation.
 // 0 = off, 1 = 90 CW, 2 = 90 CCW, 3 = 180.
 wire [1:0] rot=status[11:10];
 wire no_rotate=(rot==2'd0) || (rot==2'd3) || direct_video;
 wire rotate_ccw=(rot==2'd2);
 wire flip=(rot==2'd3) && !direct_video;
 wire video_rotated;
 assign FB_FORCE_BLANK=1'b0;
 screen_rotate screen_rotate(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),.VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
 .rotate_ccw(rotate_ccw),.no_rotate(no_rotate),.flip(flip),.video_rotated(video_rotated),
 .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
 .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),.DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD));
 wire [1:0] ar=status[122:121];
 wire [11:0] arx=(!ar) ? (video_rotated ? 12'd3 : 12'd4) : {10'd0,ar-2'd1};
 wire [11:0] ary=(!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;
 video_freak video_freak(.CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_VS(VGA_VS),.HDMI_WIDTH(HDMI_WIDTH),.HDMI_HEIGHT(HDMI_HEIGHT),
 .VGA_DE(VGA_DE),.VIDEO_ARX(VIDEO_ARX),.VIDEO_ARY(VIDEO_ARY),.VGA_DE_IN(vga_de),
 .ARX(arx),.ARY(ary),.CROP_SIZE(12'd0),.CROP_OFF(5'd0),.SCALE({1'b0,status[8:7]}));
 assign AUDIO_L=audio;assign AUDIO_R=audio;assign LED_USER=download || illegal;
endmodule
