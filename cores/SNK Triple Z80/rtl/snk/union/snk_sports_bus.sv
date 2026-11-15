// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical MAME0.289 sports maps, shared by parent tdfever15 and fsoccer17.
// External CPU trio and common registered ROM bytes; no physical CPUs/ROMs here.
module snk_sports_bus #(parameter BYTE_READBACK=0)(
 input clk,reset_n,vblank,input [7:0] profile_id,input [79:0] inputs,
 input [7:0] dsw1,dsw2,input sound_busy,sound_irq_n,input [7:0] sound_din,
 input [15:0] a_addr,b_addr,s_addr,input [7:0] a_data,b_data,s_data,a_rom,b_rom,s_rom,
 input a_m1_n,a_mreq_n,a_iorq_n,a_rd_n,a_wr_n,b_m1_n,b_mreq_n,b_iorq_n,b_rd_n,b_wr_n,
 input s_m1_n,s_mreq_n,s_iorq_n,s_rd_n,s_wr_n,
 output reg [7:0] a_din,b_din,s_din,
 output a_wait_n,b_wait_n,s_wait_n,a_irq_n,b_irq_n,s_irq_n,a_nmi_n,b_nmi_n,s_nmi_n,
 output reg sound_command_wr,output reg [7:0] sound_command,
 output [15:0] sound_bus_addr,output [7:0] sound_bus_data,output sound_bus_mem,sound_bus_rd,sound_bus_wr,
 output reg [8:0] bg_x,bg_y,s32_x,s32_y,output reg flip_screen,
 output reg [7:0] text_attrs,output reg coin_write,output reg [7:0] coin_data,
 input [15:0] video_addr,output reg [7:0] video_data,
 input [10:0] vbg_addr,vtx_addr,output reg [7:0] vbg_data,vtx_data,
 input [4:0] vspr_addr,output reg [31:0] vspr_data,
 output reg video_commit,output reg [15:0] video_commit_addr,output reg [7:0] video_commit_data,
 output reg radar_commit
);
 wire valid=profile_id==8'd15||profile_id==8'd17;
 wire ar=valid&&!a_mreq_n&&!a_rd_n,br=valid&&!b_mreq_n&&!b_rd_n;
 wire aw=valid&&!a_mreq_n&&!a_wr_n,bw=valid&&!b_mreq_n&&!b_wr_n;
 wire sw=valid&&!s_mreq_n&&!s_wr_n;
 reg last_ar,last_br,last_aw,last_bw,last_sw,last_vblank;
 reg ai,bi,an,bn;
 assign a_irq_n=valid ? !ai:1'b1;assign b_irq_n=valid ? !bi:1'b1;
 assign a_nmi_n=valid ? !an:1'b1;assign b_nmi_n=valid ? !bn:1'b1;
 assign s_irq_n=valid ? sound_irq_n:1'b1;assign s_nmi_n=1'b1;
 assign a_wait_n=1'b1;assign b_wait_n=1'b1;assign s_wait_n=1'b1;
 assign sound_bus_addr=s_addr;assign sound_bus_data=s_data;
 assign sound_bus_mem=valid&&!s_mreq_n;assign sound_bus_rd=valid&&!s_rd_n;assign sound_bus_wr=valid&&!s_wr_n;
 // One scheduled CPU port and independent renderer byte port in each bank.
 // Native opposite A/B phases prohibit simultaneous write-start requests.
 (* ramstyle="M10K" *) reg [7:0] bg_ram[0:2047],shared_ram[0:2047],text_ram[0:2047];
 (* ramstyle="M10K" *) reg [7:0] sprite0[0:1535],sprite1[0:1535],sprite2[0:1535],sprite3[0:1535];
 (* ramstyle="M10K" *) reg [7:0] sound_ram[0:4095];
 wire a_req=(ar||aw)&&a_addr>=16'hd000,b_req=(br||bw)&&b_addr>=16'hd000;
 wire a_we=aw&&!last_aw&&a_addr>=16'hd000,b_we=bw&&!last_bw&&b_addr>=16'hd000;
 reg turn,last_selected,last_valid;reg [1:0] last_bank;
 wire selected=a_we ? 1'b0:b_we ? 1'b1:turn;
 wire [15:0] maddr=selected ? b_addr:a_addr;
 wire [7:0] mdata=selected ? b_data:a_data;
 wire [1:0] bank=maddr<16'hd800 ? 0:maddr<16'he000 ? 1:maddr<16'hf800 ? 2:3;
 wire [12:0] sprite_index=(maddr>=16'he000&&maddr<16'hf800) ? maddr-16'he000:0;
 reg [7:0] qbg,qshared,qtext,qa,qb,qs,qsp0,qsp1,qsp2,qsp3;reg [1:0] qsp_lane;
 wire [7:0] qsprite=qsp_lane==0?qsp0:qsp_lane==1?qsp1:qsp_lane==2?qsp2:qsp3;
 wire [7:0] response=last_bank==0?qbg:last_bank==1?qshared:last_bank==2?qsprite:qtext;
 always @(posedge clk)begin
  qbg<=bg_ram[maddr[10:0]];qshared<=shared_ram[maddr[10:0]];
  qsp0<=sprite0[sprite_index[12:2]];qsp1<=sprite1[sprite_index[12:2]];qsp2<=sprite2[sprite_index[12:2]];qsp3<=sprite3[sprite_index[12:2]];qsp_lane<=sprite_index[1:0];qtext<=text_ram[maddr[10:0]];
  qs<=sound_ram[s_addr[11:0]];
  vbg_data<=bg_ram[vbg_addr];vtx_data<=text_ram[vtx_addr];
  vspr_data<={sprite3[vspr_addr],sprite2[vspr_addr],sprite1[vspr_addr],sprite0[vspr_addr]};
  if(BYTE_READBACK&&valid&&video_addr>=16'hd000)begin
   if(video_addr<16'hd800)video_data<=bg_ram[video_addr[10:0]];
   else if(video_addr<16'he000)video_data<=shared_ram[video_addr[10:0]];
   else if(video_addr<16'hf800)case(video_addr[1:0])
    0:video_data<=sprite0[(video_addr-16'he000)>>2];1:video_data<=sprite1[(video_addr-16'he000)>>2];
    2:video_data<=sprite2[(video_addr-16'he000)>>2];3:video_data<=sprite3[(video_addr-16'he000)>>2];endcase
   else video_data<=text_ram[video_addr[10:0]];
  end else video_data<=8'hff;
  if(reset_n&&(a_we||b_we))case(bank)
   0:bg_ram[maddr[10:0]]<=mdata;1:shared_ram[maddr[10:0]]<=mdata;
   2:case(sprite_index[1:0])0:sprite0[sprite_index[12:2]]<=mdata;1:sprite1[sprite_index[12:2]]<=mdata;2:sprite2[sprite_index[12:2]]<=mdata;3:sprite3[sprite_index[12:2]]<=mdata;endcase
   3:text_ram[maddr[10:0]]<=mdata;
  endcase
  if(reset_n&&sw&&!last_sw&&s_addr>=16'hc000&&s_addr<=16'hcfff)sound_ram[s_addr[11:0]]<=s_data;
 end
 always @*begin
  a_din=8'hff;b_din=8'hff;s_din=8'hff;
  if(ar)begin
   if(a_addr<16'hc000)a_din=a_rom;
   else if(a_addr>=16'hd000)a_din=qa;
   else case(a_addr)
    16'hc000:a_din=(inputs[7:0]&8'hf7)|{4'b0,sound_busy,3'b0};
    16'hc080:a_din=inputs[15:8];16'hc100:a_din=inputs[23:16];16'hc180:a_din=inputs[31:24];
    16'hc200:a_din=inputs[39:32];16'hc280:a_din=inputs[47:40];16'hc300:a_din=inputs[55:48];
    16'hc380:a_din=inputs[63:56];16'hc400:a_din=inputs[71:64];16'hc480:a_din=inputs[79:72];
    16'hc580:a_din=dsw1;16'hc600:a_din=dsw2;
   endcase
  end
  if(br)begin if(b_addr<16'hc000)b_din=b_rom;else if(b_addr>=16'hd000)b_din=qb;end
  if(valid&&!s_mreq_n&&!s_rd_n)begin
   if(s_addr<16'hc000)s_din=s_rom;else if(s_addr<=16'hcfff)s_din=qs;
   else if(s_addr==16'he000||s_addr==16'hf800||s_addr==16'hf000||(profile_id==15&&s_addr==16'he800))s_din=sound_din;
  end
 end
 always @(posedge clk)begin
  if(!reset_n)begin
   last_ar<=0;last_br<=0;last_aw<=0;last_bw<=0;last_sw<=0;last_vblank<=0;
   ai<=0;bi<=0;an<=0;bn<=0;turn<=0;last_selected<=0;last_valid<=0;last_bank<=0;qa<=0;qb<=0;
   sound_command_wr<=0;sound_command<=0;bg_x<=0;bg_y<=0;s32_x<=0;s32_y<=0;flip_screen<=0;text_attrs<=0;coin_write<=0;coin_data<=0;
   video_commit<=0;video_commit_addr<=0;video_commit_data<=0;radar_commit<=0;
  end else begin
   last_ar<=ar;last_br<=br;last_aw<=aw;last_bw<=bw;last_sw<=sw;last_vblank<=vblank;
   turn<=!turn;last_selected<=selected;last_valid<=selected ? b_req:a_req;last_bank<=bank;
   if(last_valid)begin if(last_selected)qb<=response;else qa<=response;end
   sound_command_wr<=0;coin_write<=0;video_commit<=0;radar_commit<=0;
   if(valid&&vblank&&!last_vblank)begin ai<=1;bi<=1;end
   if(!a_iorq_n&&!a_m1_n)ai<=0;if(!b_iorq_n&&!b_m1_n)bi<=0;
   if(ar&&!last_ar&&a_addr==16'hc700)bn<=1;
   // Both sub NMI addresses are mapped for all three in pinned MAME.
   if(br&&!last_br&&(b_addr==16'hc000||b_addr==16'hc700))an<=1;
   if(aw&&!last_aw)case(a_addr)
    16'hc500:begin sound_command<=a_data;sound_command_wr<=1;end
    16'hc680:begin coin_data<=a_data;coin_write<=1;end
    16'hc700:an<=0;16'hc800:bg_y[7:0]<=a_data;16'hc840:bg_x[7:0]<=a_data;
    16'hc880:begin flip_screen<=a_data[4];bg_x[8]<=a_data[1];bg_y[8]<=a_data[0];end
    16'hc8c0:text_attrs<=a_data;
    16'hc900:begin s32_y[8]<=a_data[7];s32_x[8]<=a_data[6];end
    16'hc980:s32_y[7:0]<=a_data;16'hc9c0:s32_x[7:0]<=a_data;
   endcase
   if(bw&&!last_bw)begin
    if(b_addr==16'hc000||b_addr==16'hc700)bn<=0;
    if(b_addr==16'hc8c0)text_attrs<=b_data;
   end
   if(a_we||b_we)begin video_commit<=1;video_commit_addr<=maddr;video_commit_data<=mdata;radar_commit<=maddr>=16'he000&&maddr<16'he080;end
  end
 end
 `ifdef VERILATOR
 always @(posedge clk)if(reset_n&&a_we&&b_we)$fatal(1,"Sports native CPU phase contract: simultaneous shared write starts");
 `endif
endmodule
