// SPDX-License-Identifier: GPL-3.0-or-later
// TNK3-class board maps (MAME 0.289 snk.cpp tnk3_cpuA/B_map, aso_cpuA/B_map, tnk3_YM3526/aso_YM3526/sound_common sound maps).
// Profiles: 6 aso, 7 tnk3, 8 athena, 9 fitegolf, 10 countryc.
// Shared CPUs connect here; video is the hal21 hsj renderer, sound is the late-family OPL block driven through a
// virtual sound bus (this module decodes the sound CPU map and translates the early ack reads into late status writes).
module snk_early_tnk_controller #(parameter CLK_HZ=96000000)(
 input [7:0] profile,
 input [7:0] shared_qa,shared_qb,ram_qs,input memory_b_wait,
 output [13:0] ram_addr_a,ram_addr_b,
 output ram_write_a,ram_write_b,output [7:0] ram_data_a,ram_data_b,
 output [11:0] sound_ram_addr,output [7:0] sound_ram_data,output sound_ram_write,
 input clk,reset,pause_cpu,input [7:0] in0,in1,in2,in3,in4,in5,dsw1,dsw2,
 input vblank,input [7:0] rom_qa,rom_qb,rom_qs,
 input [15:0] a_addr,b_addr,s_addr,input [7:0] a_dout,b_dout,s_dout,
 input a_mreq_n,a_iorq_n,a_m1_n,a_rd_n,a_wr_n,
 input b_mreq_n,b_iorq_n,b_m1_n,b_rd_n,b_wr_n,
 input s_mreq_n,s_iorq_n,s_m1_n,s_rd_n,s_wr_n,
 output reg [7:0] a_din,b_din,s_din,
 output a_int_n,b_int_n,s_int_n,a_nmi_n,b_nmi_n,s_nmi_n,b_wait_n,
 output reg flip,tx_bank,output reg [1:0] bg_tile_bank,output reg [3:0] bg_palette_bank,
 output reg [8:0] bg_x,bg_y,sprite_x,sprite_y,
 // virtual late-family sound bus + command latch (consumed by snk_union_opl_audio in the shared board)
 output reg [15:0] snd_addr,output [7:0] snd_data,output snd_mem,snd_rd,snd_wr,
 output snd_cmd_wr,output [7:0] snd_cmd,output reg snd_audio_rd
);
 wire is_aso=profile==8'd6,is_tnk3=profile==8'd7,is_cc=profile==8'd10;
 wire valid_profile=profile>=8'd6&&profile<=8'd10;
 wire common_snd=profile>=8'd8;           // athena/fitegolf/countryc: late sound_common_map
 reg inta=0,intb=0,nmia=0,nmib=0,last_vblank=0;
 reg last_ar=0,last_br=0,last_aw=0,last_bw=0,last_sw=0;
 reg trackball_sel=0;
 wire ar=!a_mreq_n&&!a_rd_n,aw=!a_mreq_n&&!a_wr_n;
 wire br=!b_mreq_n&&!b_rd_n,bw=!b_mreq_n&&!b_wr_n;
 wire sr=!s_mreq_n&&!s_rd_n,sw=!s_mreq_n&&!s_wr_n;
 // ---- shared state RAM map (internal 14-bit offsets; 2 KiB banks, see README)
 // tnk3/athena/fitegolf/countryc: spr 0000, bg 0800 (2 bytes/tile), tx 2800, B-private 3000
 // aso: shared 0000, spr 0800, bg 1000 (1 byte/tile), tx 2000
 wire a_shared=valid_profile&&(is_aso ? a_addr>=16'hd800 : a_addr>=16'hd000);
 wire [13:0] ai=is_aso ? {1'b0,a_addr-16'hd800} : {1'b0,a_addr-16'hd000};
 wire b_lo=is_aso ? (b_addr>=16'hc800&&b_addr<=16'he7ff) : (b_addr>=16'hc800&&b_addr<=16'hefff);
 wire b_priv=!is_aso&&b_addr>=16'hf000&&b_addr<=16'hf7ff;
 wire b_tx=b_addr>=16'hf800;
 wire b_shared=valid_profile&&(b_lo||b_priv||b_tx);
 wire [13:0] bi=b_lo ? {1'b0,b_addr-16'hc800} :
                b_priv ? 14'h3000+{3'd0,b_addr[10:0]} :
                (is_aso ? 14'h2000 : 14'h2800)+{3'd0,b_addr[10:0]};
 assign b_wait_n=valid_profile?memory_b_wait:1'b1;
 assign a_int_n=!valid_profile||!inta;assign b_int_n=!valid_profile||!intb;assign s_int_n=1'b1;
 assign a_nmi_n=!valid_profile||!nmia;assign b_nmi_n=!valid_profile||!nmib;assign s_nmi_n=1'b1;
 assign ram_addr_a=ai;assign ram_addr_b=bi;
 assign ram_write_a=aw&&!last_aw&&!pause_cpu&&a_shared;
 assign ram_write_b=bw&&!last_bw&&!pause_cpu&&b_shared;
 assign ram_data_a=a_dout;assign ram_data_b=b_dout;
 // ---- sound CPU RAM
 wire s_ram_hit=valid_profile&&(is_tnk3 ? (s_addr>=16'h8000&&s_addr<=16'h87ff) :
                               (is_aso ? (s_addr>=16'hc000&&s_addr<=16'hc7ff) : (s_addr>=16'hc000&&s_addr<=16'hcfff)));
 assign sound_ram_addr=s_addr[11:0];assign sound_ram_data=s_dout;
 assign sound_ram_write=sw&&!last_sw&&!pause_cpu&&s_ram_hit;
 wire [15:0] s_rom_limit=is_tnk3 ? 16'h8000 : 16'hc000;
 // trackball (countryc): IN1/IN2 select player by c300 bit0
 wire [7:0] in1_sel=(is_cc&&trackball_sel)?in4:in1,in2_sel=(is_cc&&trackball_sel)?in5:in2;
 always @* begin
  a_din=8'hff;b_din=8'hff;s_din=8'hff;
  if(a_addr<16'hc000)a_din=rom_qa;
  else if(a_shared)a_din=shared_qa;
  else case(a_addr)
   16'hc000:a_din=in0;16'hc100:a_din=in1_sel;16'hc200:a_din=in2_sel;
   16'hc300:a_din=is_aso?8'hff:in3;
   16'hc500:a_din=dsw1;16'hc600:a_din=dsw2;
   default:a_din=8'hff;
  endcase
  if(b_addr<16'hc000)b_din=rom_qb;
  else if(b_shared)b_din=shared_qb;
  if(!s_iorq_n)s_din=8'hff;
  else if(s_addr<s_rom_limit)s_din=rom_qs;
  else if(s_ram_hit)s_din=ram_qs;
  if(!valid_profile)begin a_din=8'hff;b_din=8'hff;s_din=8'hff;end
 end
 // ---- virtual sound bus
 // late status register writes (f800): bit4 ack YM1, bit6 clear busy, bit7 ack cmd (active-low data bits)
 localparam [7:0] ST_BUSY=8'hbf,ST_CMD=8'h7f,ST_YM1=8'hef;
 reg [7:0] vdata;reg vwr,vrd,audio_rd_nxt;
 always @* begin
  snd_addr=s_addr;vdata=s_dout;vwr=sw;vrd=sr;audio_rd_nxt=0;
  if(valid_profile&&!s_iorq_n)begin vwr=0;vrd=0;end
  else if(common_snd)begin
   audio_rd_nxt=sr&&s_addr>=16'he000;
  end else if(is_tnk3)begin
   case(s_addr)
    16'ha000:begin snd_addr=16'he000;audio_rd_nxt=sr;end
    16'hc000:begin snd_addr=16'hf800;if(sr)begin vwr=1;vrd=0;vdata=ST_BUSY;end end
    16'he000:begin snd_addr=16'he800;audio_rd_nxt=sr;end
    16'he001:begin snd_addr=16'hec00;end
    16'he004:begin snd_addr=16'hf800;if(sr)begin vwr=1;vrd=0;vdata=ST_CMD;end end
    16'he006:begin snd_addr=16'hf800;if(sr)begin vwr=1;vrd=0;vdata=ST_YM1;end end
    default:begin vwr=0;vrd=0;end
   endcase
  end else begin
   case(s_addr)
    16'hd000:begin snd_addr=16'he000;audio_rd_nxt=sr;end
    16'he000:begin snd_addr=16'hf800;if(sr)begin vwr=1;vrd=0;vdata=ST_BUSY;end end
    16'hf000:begin snd_addr=16'he800;audio_rd_nxt=sr;end
    16'hf001:begin snd_addr=16'hec00;end
    16'hf004:begin snd_addr=16'hf800;if(sr)begin vwr=1;vrd=0;vdata=ST_CMD;end end
    16'hf006:begin snd_addr=16'hf800;if(sr)begin vwr=1;vrd=0;vdata=ST_YM1;end end
    default:begin vwr=0;vrd=0;end
   endcase
  end
  snd_audio_rd=valid_profile&&audio_rd_nxt;
 end
 assign snd_data=vdata;
 assign snd_mem=valid_profile&&!s_mreq_n&&(vwr||vrd);
 assign snd_rd=valid_profile&&vrd;assign snd_wr=valid_profile&&vwr;
 reg cmd_pulse=0;reg [7:0] cmd_q=0;
 assign snd_cmd_wr=cmd_pulse;assign snd_cmd=cmd_q;
 always @(posedge clk)begin
  cmd_pulse<=0;
  if(reset||!valid_profile)begin
   nmia<=0;nmib<=0;inta<=0;intb<=0;last_vblank<=0;
   last_ar<=0;last_br<=0;last_aw<=0;last_bw<=0;last_sw<=0;trackball_sel<=0;
   flip<=0;tx_bank<=0;bg_tile_bank<=0;bg_palette_bank<=8;bg_x<=0;bg_y<=0;sprite_x<=0;sprite_y<=0;
  end else begin
   last_ar<=ar;last_br<=br&&b_wait_n;
   last_aw<=aw;last_bw<=bw;last_sw<=sw;
   last_vblank<=vblank;
   if(vblank&&!last_vblank)begin inta<=1;intb<=1;end
   if(!a_iorq_n&&!a_m1_n)inta<=0;
   if(!b_iorq_n&&!b_m1_n)intb<=0;
   if(ar&&!last_ar&&a_addr==16'hc700)nmib<=1;
   if(br&&b_wait_n&&!last_br&&(b_addr==16'hc000||b_addr==16'hc700))nmia<=1;
   if(aw&&!last_aw&&!pause_cpu)begin
    case(a_addr)
     16'hc300:if(is_cc)trackball_sel<=a_dout[0];
     16'hc400:begin cmd_pulse<=1;cmd_q<=a_dout;end
     16'hc700:nmia<=0;
     16'hc800:begin
`ifdef TNK_TRACE
       $display("TNK c800 <= %02x profile %0d",a_dout,profile);
`endif
       flip<=is_aso?a_dout[5]:a_dout[7];
       if(!is_aso)tx_bank<=a_dout[6];
       bg_y[8]<=a_dout[4];sprite_y[8]<=a_dout[3];bg_x[8]<=a_dout[1];sprite_x[8]<=a_dout[0];
     end
     16'hc900:sprite_y[7:0]<=a_dout;
     16'hca00:sprite_x[7:0]<=a_dout;
     16'hcb00:bg_y[7:0]<=a_dout;
     16'hcc00:bg_x[7:0]<=a_dout;
     16'hcf00:if(is_aso)begin bg_palette_bank<=a_dout[3:0]^4'h8;bg_tile_bank<=a_dout[5:4];end
     default:begin end
    endcase
   end
   if(bw&&!last_bw&&!pause_cpu)begin
    if(b_addr==16'hc000||b_addr==16'hc700)nmib<=0;
   end
  end
 end
endmodule
