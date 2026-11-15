// SPDX-License-Identifier: GPL-3.0-or-later
// Private integration candidate: one native graphics store for the six early profiles.
// Four byte lanes preserve little-endian Wave words and synchronous HSJ byte reads.
module snk_early_graphics_store(
 input wire clk,reset,input wire [7:0] profile,
 input wire load_wr,input wire [24:0] load_addr,input wire [7:0] load_data,
 input wire tile_req,input wire [1:0] tile_sel,input wire [10:0] tile_addr,
 output reg tile_ack,output wire [31:0] tile_data,
 input wire sp_req,input wire [12:0] sp_addr,output reg sp_ack,output wire [31:0] sp_data,
 input wire [14:0] tx_byte_addr,bg_byte_addr,sp_byte_addr,
 output wire [7:0] tx_byte_data,bg_byte_data,output wire [23:0] sp_plane_data,
 input wire [9:0] prom_addr,output reg [11:0] prom_data,
 input wire legacy_active,input wire [14:0] legacy_tx_addr,
 input wire [9:0] legacy_prom_addr,
 output wire [7:0] legacy_tx_data,output wire [11:0] legacy_prom_data
);
 wire wave=profile<=2,hal=profile==5,hsj=profile>=3&&profile<=5;
 // TNK3-class profiles 6..10 (aso,tnk3,athena,fitegolf,countryc): tx 16 KiB (tx low), bg 32 KiB (bg + tx-high arrays),
 // sprites 3 x 32 KiB planes (s0..s2 + fg + overflow arrays su0b/su1/su2). Reads retarget the idle arrays by profile.
 wire tnk=profile>=6&&profile<=10;
 wire supported=wave||hsj||tnk;
 (* ramstyle="M10K" *) reg [7:0] tx0l[0:4095],tx1l[0:4095],tx2l[0:4095],tx3l[0:4095];
 (* ramstyle="M10K" *) reg [7:0] tx0h[0:4095],tx1h[0:4095],tx2h[0:4095],tx3h[0:4095];
 (* ramstyle="M10K" *) reg [7:0] fg0[0:2047],fg1[0:2047],fg2[0:2047],fg3[0:2047];
 (* ramstyle="M10K" *) reg [7:0] bg0[0:4095],bg1[0:4095],bg2[0:4095],bg3[0:4095];
 (* ramstyle="M10K" *) reg [7:0] s00[0:4095],s01[0:4095],s02[0:4095],s03[0:4095];
 (* ramstyle="M10K" *) reg [7:0] s10[0:4095],s11[0:4095],s12[0:4095],s13[0:4095];
 (* ramstyle="M10K" *) reg [7:0] s20[0:4095],s21[0:4095],s22[0:4095],s23[0:4095];
 (* ramstyle="M10K" *) reg [7:0] su0b0[0:2047],su0b1[0:2047],su0b2[0:2047],su0b3[0:2047];
 (* ramstyle="M10K" *) reg [7:0] su10[0:4095],su11[0:4095],su12[0:4095],su13[0:4095];
 (* ramstyle="M10K" *) reg [7:0] su20[0:4095],su21[0:4095],su22[0:4095],su23[0:4095];
 (* ramstyle="M10K" *) reg [3:0] pr[0:1023],pg[0:1023],pb[0:1023];
 // Preserve the legacy ROM helper power-up contract; reset never clears storage.
 integer powerup_index;
 initial begin
  for(powerup_index=0;powerup_index<4096;powerup_index=powerup_index+1)begin
   tx0l[powerup_index]=0;tx1l[powerup_index]=0;tx2l[powerup_index]=0;tx3l[powerup_index]=0;
   tx0h[powerup_index]=0;tx1h[powerup_index]=0;tx2h[powerup_index]=0;tx3h[powerup_index]=0;
  end
  for(powerup_index=0;powerup_index<1024;powerup_index=powerup_index+1)begin pr[powerup_index]=0;pg[powerup_index]=0;pb[powerup_index]=0;end
 end
 wire [12:0] tx_ra=wave?{2'b0,tile_addr}:tx_byte_addr[14:2];
 wire [12:0] bg_w13=bg_byte_addr[14:2],sp_w13=sp_byte_addr[14:2];
 wire [11:0] bg_ra=wave?{1'b0,tile_addr}:bg_w13[11:0];
 wire [11:0] sp_ra=wave?{1'b0,sp_addr[10:0]}:sp_w13[11:0];
 reg [31:0] tx_low_q,tx_high_q,fg_q,bg_q,s0_q,s1_q,s2_q;
 reg [31:0] su0b_q,su1_q,su2_q;
 reg tx_bank_q;reg [1:0] legacy_lane_q;
 wire [31:0] tx_q=tx_bank_q?tx_high_q:tx_low_q;
 wire [11:0] tx_read_word=legacy_active?legacy_tx_addr[13:2]:tx_ra[11:0];
 // tnk: tx-high arrays serve the bg upper 16 KiB, fg arrays serve sprite plane0 words 4096..6143.
 wire [11:0] tx_high_ra=tnk?bg_w13[11:0]:tx_read_word;
 wire [10:0] fg_ra=tnk?sp_w13[10:0]:tile_addr;
 reg bg_hi_q,sp_hi_q,sp_hi2_q;
 wire [31:0] bg_m=bg_hi_q?tx_high_q:bg_q;
 wire [31:0] s0_m=sp_hi_q?(sp_hi2_q?su0b_q:fg_q):s0_q;
 wire [31:0] s1_m=sp_hi_q?su1_q:s1_q;
 wire [31:0] s2_m=sp_hi_q?su2_q:s2_q;
 wire [9:0] prom_read_addr=legacy_active?legacy_prom_addr:prom_addr;
 reg [11:0] read_word_q,write_word_q;reg [1:0] write_lane_q;
 reg write_bank_q,tx_write_q;reg [7:0] load_data_q;
 reg [9:0] prom_read_q,prom_write_addr_q;reg [1:0] prom_write_channel_q;reg prom_write_q;
 wire legacy_tx_low_hit=tx_write_q&&!write_bank_q&&write_word_q==read_word_q&&write_lane_q==legacy_lane_q;
 wire legacy_tx_high_hit=tx_write_q&&write_bank_q&&write_word_q==read_word_q&&write_lane_q==legacy_lane_q;
 wire [7:0] legacy_low=legacy_tx_low_hit?load_data_q:8'(tx_low_q>>(legacy_lane_q*8));
 wire [7:0] legacy_high=legacy_tx_high_hit?load_data_q:8'(tx_high_q>>(legacy_lane_q*8));
 assign legacy_tx_data=legacy_tx_addr[14]?legacy_high:legacy_low;
 wire prom_hit=prom_write_q&&prom_write_addr_q==prom_read_q;
 assign legacy_prom_data={prom_hit&&prom_write_channel_q==2?load_data_q[3:0]:prom_data[11:8],prom_hit&&prom_write_channel_q==1?load_data_q[3:0]:prom_data[7:4],prom_hit&&prom_write_channel_q==0?load_data_q[3:0]:prom_data[3:0]};
 reg [1:0] tx_lane,bg_lane,sp_lane,tile_sel_q,sp_sel_q;
 assign tile_data=tile_sel_q==0?tx_q:tile_sel_q==1?fg_q:tile_sel_q==2?bg_q:32'hffffffff;
 assign sp_data=sp_sel_q==0?s0_q:sp_sel_q==1?s1_q:sp_sel_q==2?s2_q:32'hffffffff;
 assign tx_byte_data=8'(tx_q>>(tx_lane*8));
 assign bg_byte_data=8'(bg_m>>(bg_lane*8));
 assign sp_plane_data={8'(s2_m>>(sp_lane*8)),8'(s1_m>>(sp_lane*8)),8'(s0_m>>(sp_lane*8))};
 wire [24:0] tx_count=(profile==3||tnk)?25'h4000:25'h2000;
 wire [24:0] bg_base=wave?25'h50000:25'h40000;
 wire [24:0] bg_count=tnk?25'h8000:hal?25'h4000:25'h2000;
 wire [24:0] sp_base=wave?25'h60000:25'h50000;
 wire [24:0] sp_count=tnk?25'h18000:hal?25'hc000:25'h6000;
 wire [24:0] prom_base=tnk?25'h68000:wave?25'h70000:25'h60000;
 wire [24:0] sp_offset=load_addr-sp_base;
 wire [1:0] load_plane=tnk?sp_offset[16:15]:hal?sp_offset[15:14]:sp_offset[14:13];
 wire [12:0] tnk_sp_word=sp_offset[14:2];
 wire [11:0] load_sp_word=tnk?tnk_sp_word[11:0]:hal?sp_offset[13:2]:{1'b0,sp_offset[12:2]};
 wire sp_up=tnk&&tnk_sp_word[12];
 wire [24:0] prom_offset=load_addr-prom_base;
 wire legacy_tx_wr=load_wr&&legacy_active&&load_addr>=25'h30000&&load_addr<25'h38000;
 wire tx_wr=load_wr&&supported&&load_addr>=25'h30000&&load_addr<25'h30000+tx_count;
 wire shared_tx_wr=tx_wr||legacy_tx_wr;
 wire fg_wr=load_wr&&wave&&load_addr>=25'h40000&&load_addr<25'h42000;
 wire bg_wr_any=load_wr&&supported&&load_addr>=bg_base&&load_addr<bg_base+bg_count;
 wire bg_hi_wr=tnk&&bg_wr_any&&load_addr[14];
 wire bg_wr=bg_wr_any&&!bg_hi_wr;
 wire sp_wr_any=load_wr&&supported&&load_addr>=sp_base&&load_addr<sp_base+sp_count;
 wire sp_wr=sp_wr_any&&!sp_up;
 wire sp_fg_wr=sp_wr_any&&sp_up&&load_plane==0&&!tnk_sp_word[11];
 wire sp_u0b_wr=sp_wr_any&&sp_up&&load_plane==0&&tnk_sp_word[11];
 wire sp_u1_wr=sp_wr_any&&sp_up&&load_plane==1;
 wire sp_u2_wr=sp_wr_any&&sp_up&&load_plane==2;
 wire legacy_prom_wr=load_wr&&legacy_active&&load_addr>=25'h120000&&load_addr<25'h120c00;
 wire prom_wr=load_wr&&supported&&load_addr>=prom_base&&load_addr<prom_base+25'hc00;
 wire shared_prom_wr=prom_wr||legacy_prom_wr;
 wire [11:0] selected_prom_offset=legacy_prom_wr?load_addr[11:0]:prom_offset[11:0];
 always @(posedge clk)begin
  tx_low_q<={tx3l[tx_read_word],tx2l[tx_read_word],tx1l[tx_read_word],tx0l[tx_read_word]};
  tx_high_q<={tx3h[tx_high_ra],tx2h[tx_high_ra],tx1h[tx_high_ra],tx0h[tx_high_ra]};
  tx_bank_q<=tx_ra[12];legacy_lane_q<=legacy_tx_addr[1:0];read_word_q<=tx_read_word;
  tx_write_q<=shared_tx_wr;write_word_q<=load_addr[13:2];write_bank_q<=load_addr[14];write_lane_q<=load_addr[1:0];load_data_q<=load_data;
  prom_read_q<=prom_read_addr;prom_write_q<=shared_prom_wr;prom_write_addr_q<=selected_prom_offset[9:0];prom_write_channel_q<=selected_prom_offset[11:10];
  fg_q<={fg3[fg_ra],fg2[fg_ra],fg1[fg_ra],fg0[fg_ra]};
  bg_q<={bg3[bg_ra],bg2[bg_ra],bg1[bg_ra],bg0[bg_ra]};
  s0_q<={s03[sp_ra],s02[sp_ra],s01[sp_ra],s00[sp_ra]};
  s1_q<={s13[sp_ra],s12[sp_ra],s11[sp_ra],s10[sp_ra]};
  s2_q<={s23[sp_ra],s22[sp_ra],s21[sp_ra],s20[sp_ra]};
  su0b_q<={su0b3[sp_w13[10:0]],su0b2[sp_w13[10:0]],su0b1[sp_w13[10:0]],su0b0[sp_w13[10:0]]};
  su1_q<={su13[sp_w13[11:0]],su12[sp_w13[11:0]],su11[sp_w13[11:0]],su10[sp_w13[11:0]]};
  su2_q<={su23[sp_w13[11:0]],su22[sp_w13[11:0]],su21[sp_w13[11:0]],su20[sp_w13[11:0]]};
  bg_hi_q<=tnk&&bg_w13[12];sp_hi_q<=tnk&&sp_w13[12];sp_hi2_q<=sp_w13[11];
  tx_lane<=tx_byte_addr[1:0];bg_lane<=bg_byte_addr[1:0];sp_lane<=sp_byte_addr[1:0];
  // A response and its data publish together after one synchronous memory read.
  tile_sel_q<=tile_sel;sp_sel_q<=sp_addr[12:11];
  tile_ack<=tile_req;sp_ack<=sp_req;
  if(reset)begin tile_ack<=tile_req;sp_ack<=sp_req;end
  prom_data<={pb[prom_read_addr],pg[prom_read_addr],pr[prom_read_addr]};
  if(shared_tx_wr&&!load_addr[14])case(load_addr[1:0])
   0:tx0l[load_addr[13:2]]<=load_data;
   1:tx1l[load_addr[13:2]]<=load_data;
   2:tx2l[load_addr[13:2]]<=load_data;
   3:tx3l[load_addr[13:2]]<=load_data;
  endcase
  // tx-high arrays: legacy/wave text bank 1, or (tnk) the upper half of the bg ROM.
  if((shared_tx_wr&&load_addr[14])||bg_hi_wr)case(load_addr[1:0])
   0:tx0h[load_addr[13:2]]<=load_data;
   1:tx1h[load_addr[13:2]]<=load_data;
   2:tx2h[load_addr[13:2]]<=load_data;
   3:tx3h[load_addr[13:2]]<=load_data;
  endcase
  // fg arrays: wave fg tiles, or (tnk) sprite plane0 words 4096..6143.
  if(fg_wr)case(load_addr[1:0])0:fg0[load_addr[12:2]]<=load_data;1:fg1[load_addr[12:2]]<=load_data;2:fg2[load_addr[12:2]]<=load_data;3:fg3[load_addr[12:2]]<=load_data;endcase
  else if(sp_fg_wr)case(load_addr[1:0])0:fg0[tnk_sp_word[10:0]]<=load_data;1:fg1[tnk_sp_word[10:0]]<=load_data;2:fg2[tnk_sp_word[10:0]]<=load_data;3:fg3[tnk_sp_word[10:0]]<=load_data;endcase
  if(bg_wr)case(load_addr[1:0])0:bg0[load_addr[13:2]]<=load_data;1:bg1[load_addr[13:2]]<=load_data;2:bg2[load_addr[13:2]]<=load_data;3:bg3[load_addr[13:2]]<=load_data;endcase
  if(sp_wr)case({load_plane,load_addr[1:0]})
   0:s00[load_sp_word]<=load_data;1:s01[load_sp_word]<=load_data;2:s02[load_sp_word]<=load_data;3:s03[load_sp_word]<=load_data;
   4:s10[load_sp_word]<=load_data;5:s11[load_sp_word]<=load_data;6:s12[load_sp_word]<=load_data;7:s13[load_sp_word]<=load_data;
   8:s20[load_sp_word]<=load_data;9:s21[load_sp_word]<=load_data;10:s22[load_sp_word]<=load_data;11:s23[load_sp_word]<=load_data;
  endcase
  if(sp_u0b_wr)case(load_addr[1:0])0:su0b0[tnk_sp_word[10:0]]<=load_data;1:su0b1[tnk_sp_word[10:0]]<=load_data;2:su0b2[tnk_sp_word[10:0]]<=load_data;3:su0b3[tnk_sp_word[10:0]]<=load_data;endcase
  if(sp_u1_wr)case(load_addr[1:0])0:su10[tnk_sp_word[11:0]]<=load_data;1:su11[tnk_sp_word[11:0]]<=load_data;2:su12[tnk_sp_word[11:0]]<=load_data;3:su13[tnk_sp_word[11:0]]<=load_data;endcase
  if(sp_u2_wr)case(load_addr[1:0])0:su20[tnk_sp_word[11:0]]<=load_data;1:su21[tnk_sp_word[11:0]]<=load_data;2:su22[tnk_sp_word[11:0]]<=load_data;3:su23[tnk_sp_word[11:0]]<=load_data;endcase
  if(shared_prom_wr)case(selected_prom_offset[11:10])0:pr[selected_prom_offset[9:0]]<=load_data[3:0];1:pg[selected_prom_offset[9:0]]<=load_data[3:0];2:pb[selected_prom_offset[9:0]]<=load_data[3:0];endcase
 end
endmodule
