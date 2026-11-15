// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical SGladiator maps from pinned MAME 0.289. Private integration candidate.
// Shared CPUs connect here; the standalone wrapper is a boot-proof harness.
module snk_early_hsj_controller #(parameter CLK_HZ=53600000)(

 input [7:0] profile,
 input [7:0] shared_qa,shared_qb,ram_qs,input memory_b_wait,
 input [12:0] committed_addr,input canonical_wr,input [7:0] canonical_data,
 input hs_ack,input [7:0] hs_rdata,
 output [12:0] ram_addr_a,ram_addr_b,ram_hs_addr,
 output ram_write_a,ram_write_b,ram_hs_req,output [7:0] ram_data_a,ram_data_b,
 output [10:0] sound_ram_addr,output [7:0] sound_ram_data,output sound_ram_write,
 output [3:0] ay_register0,ay_register1,output ay_write0,ay_write1,output [7:0] ay_data,
 input clk,reset,pause_cpu,input [7:0] in0,in1,in2,dsw1,dsw2,
 input vblank,input ay_ce,input [7:0] rom_qa,rom_qb,rom_qs,
 input [15:0] a_addr,b_addr,s_addr,input [7:0] a_dout,b_dout,s_dout,
 input a_mreq_n,a_iorq_n,a_m1_n,a_rd_n,a_wr_n,
 input b_mreq_n,b_iorq_n,b_m1_n,b_rd_n,b_wr_n,
 input s_mreq_n,s_iorq_n,s_m1_n,s_rd_n,s_wr_n,
 output reg [7:0] a_din,b_din,s_din,
 output a_int_n,b_int_n,s_int_n,a_nmi_n,b_nmi_n,s_nmi_n,b_wait_n,
 output sound_busy,input [10:0] audio_unsigned,input audio_sample,
 input [12:0] video_ram_addr,output [7:0] video_ram_data,
 output reg flip,output reg bg_tile_bank,output reg [3:0] bg_palette_bank,
 output reg [8:0] bg_x,bg_y,sprite_x,sprite_y,
 input hs_grant,hs_req,hs_write,input [15:0] hs_addr,input [7:0] hs_wdata,

 output reg [31:0] a_reads,b_reads,s_reads,shared_writes,sound_commands,ay_writes,input_polls,
 output [15:0] canonical_addr
);
 wire is_hal=profile==8'd5,is_jc=profile==8'd3,is_sg=profile==8'd4;
 wire valid_profile=is_hal||is_jc||is_sg;
 wire [8:0] irq_rate=is_hal?9'd220:9'd244;
 reg [7:0] sound_latch=0;
 reg busy=0,cmdirq=0,nmia=0,nmib=0,inta=0,intb=0,ints=0,last_vblank=0;
 reg last_ar=0,last_br=0,last_sr=0,last_aw=0,last_bw=0,last_sw=0,last_si=0;
 reg [26:0] tempo=0;
 wire ar=!a_mreq_n&&!a_rd_n,aw=!a_mreq_n&&!a_wr_n;
 wire br=!b_mreq_n&&!b_rd_n,bw=!b_mreq_n&&!b_wr_n;
 wire sr=!s_mreq_n&&!s_rd_n,sw=!s_mreq_n&&!s_wr_n;
 wire si=!s_iorq_n&&!s_rd_n&&s_m1_n;
 wire a_shared=valid_profile&&(is_hal ? a_addr>=16'he000 : a_addr>=16'hd800&&a_addr<=16'hf7ff);
 wire b_shared=valid_profile&&(is_hal ? ((b_addr>=16'hc000&&b_addr<=16'hc7ff)||(b_addr>=16'hd000&&b_addr<=16'hdfff)||(b_addr>=16'he800&&b_addr<=16'hefff)) : ((b_addr>=16'hc000&&b_addr<=(is_jc?16'hd7ff:16'hcfff))||(b_addr>=16'he000&&b_addr<=16'he7ff)));
 wire [12:0] bi=is_hal ? (b_addr[15:12]==4'hc ? {2'b00,b_addr[10:0]} : b_addr[15:12]==4'hd ? 13'h0800+{1'b0,b_addr[11:0]} : 13'h1800+{2'b00,b_addr[10:0]}) : b_addr<(is_jc?16'he000:16'hd000) ? b_addr-16'hc000 : 13'h1800+{2'd0,b_addr[10:0]};
 wire [12:0] ai=is_hal ? a_addr[12:0] : a_addr-16'hd800;
 assign b_wait_n=valid_profile?memory_b_wait:1'b1;
 assign a_int_n=!valid_profile||!inta;assign b_int_n=!valid_profile||!intb;assign s_int_n=!valid_profile||!ints;
 assign a_nmi_n=!valid_profile||!nmia;assign b_nmi_n=!valid_profile||!nmib;assign s_nmi_n=!valid_profile||!cmdirq;
 // Gladiator polls busy before every command. Keep that handshake closed
 // until the sound CPU has both consumed the latch and acknowledged its NMI.
 // Otherwise a second write between A000 and C000 gets no new NMI edge,
 // and the old acknowledgement strands it with busy=1, cmdirq=0.
 wire command_busy=busy||(is_sg&&cmdirq);
 assign sound_busy=valid_profile&&command_busy;
 wire [12:0] hs_native_offset=is_hal?hs_addr[12:0]:hs_addr-16'hd800;
 assign canonical_addr=is_hal?{3'b111,committed_addr}:16'hd800+committed_addr;
 assign ram_addr_a=ai;assign ram_addr_b=bi;
 assign ram_write_a=aw&&!last_aw&&!pause_cpu&&a_shared;
 assign ram_write_b=bw&&!last_bw&&!pause_cpu&&b_shared;
 assign ram_data_a=a_dout;assign ram_data_b=b_dout;
 assign ram_hs_req=valid_profile&&hs_req&&(is_hal?hs_addr>=16'he000:hs_addr>=16'hd800&&hs_addr<=16'hf7ff);
 assign ram_hs_addr=hs_native_offset;
 assign sound_ram_addr=s_addr[10:0];assign sound_ram_data=s_dout;
 assign sound_ram_write=valid_profile&&sw&&!last_sw&&!pause_cpu&&s_addr>=16'h8000&&s_addr<=16'h87ff;
 reg [3:0] ay_addr0=0,ay_addr1=0;
 wire data0=valid_profile&&sw&&!last_sw&&s_addr==16'he001;
 wire data1=valid_profile&&sw&&!last_sw&&s_addr==(is_hal?16'he009:16'he005);
 assign ay_write0=data0;assign ay_write1=data1;
 assign ay_register0=ay_addr0;assign ay_register1=ay_addr1;assign ay_data=s_dout;
 wire [7:0] ram_qa=shared_qa,ram_qb=shared_qb;
 // ROM bytes are already registered by the one shared program bank.
 always @* begin
  a_din=8'hff;b_din=8'hff;s_din=8'hff;
  if(a_addr<(is_hal?16'h8000:(is_hal?16'hc000:16'ha000)))a_din=rom_qa;
  else if(a_shared)a_din=ram_qa;
  else case(a_addr)
   (is_hal?16'hc000:16'ha000):a_din=(in0&8'hdf)|(command_busy ? 8'h20:8'h00);
   (is_hal?16'hc100:16'ha100):a_din=in1;(is_hal?16'hc200:16'ha200):a_din=in2;
   (is_hal?16'hc400:16'ha400):a_din=dsw1;(is_hal?16'hc500:16'ha500):a_din=dsw2;
  endcase
  if(b_addr<(is_hal?16'ha000:16'h8000))b_din=rom_qb;
  else if(b_shared)b_din=ram_qb;
  if(!s_iorq_n)s_din=8'hff;
  else if(s_addr<16'h4000)s_din=rom_qs;
  else if(s_addr>=16'h8000&&s_addr<=16'h87ff)s_din=ram_qs;
  else if(s_addr==16'ha000)s_din=sound_latch;
  if(!valid_profile)begin a_din=8'hff;b_din=8'hff;s_din=8'hff;end
 end
 always @(posedge clk)begin
  if(reset||!valid_profile)begin
   busy<=0;cmdirq<=0;nmia<=0;nmib<=0;inta<=0;intb<=0;ints<=0;
   tempo<=0;last_vblank<=0;last_ar<=0;last_br<=0;last_sr<=0;
   last_aw<=0;last_bw<=0;last_sw<=0;last_si<=0;ay_addr0<=0;ay_addr1<=0;
   flip<=0;bg_tile_bank<=0;bg_palette_bank<=8;bg_x<=0;bg_y<=0;sprite_x<=0;sprite_y<=0;
   a_reads<=0;b_reads<=0;s_reads<=0;shared_writes<=0;sound_commands<=0;ay_writes<=0;input_polls<=0;
  end else begin
   last_ar<=ar;last_br<=br&&b_wait_n;last_sr<=sr;
   last_aw<=aw;last_bw<=bw;last_sw<=sw;last_si<=si;
   last_vblank<=vblank;
   if(vblank&&!last_vblank)begin inta<=1;intb<=1;end
   if(!a_iorq_n&&!a_m1_n)inta<=0;
   if(!b_iorq_n&&!b_m1_n)intb<=0;
   // Source level IRQ remains asserted through interrupt acknowledge.
   if(is_hal)begin if(!s_iorq_n&&!s_m1_n)ints<=0;end
   else if(si&&!last_si&&s_addr[7:0]==8'h00)ints<=0;
   // Exact rational 244Hz periodic IRQ, inherited canonical JCross MAME timing; physical rate unproved.
   if(!pause_cpu)begin
    if(tempo+irq_rate>=CLK_HZ)begin tempo<=tempo+irq_rate-CLK_HZ;ints<=1;end
    else tempo<=tempo+irq_rate;
   end
   if(ar&&!last_ar)begin a_reads<=a_reads+1;if(a_addr==(is_hal?16'hc700:16'ha700))nmib<=1;if(a_addr==(is_hal?16'hc000:16'ha000))input_polls<=input_polls+1;end
   if(br&&b_wait_n&&!last_br)begin b_reads<=b_reads+1;if(!is_hal&&b_addr==(is_jc?16'ha700:16'ha000))nmia<=1;end
   if(sr&&!last_sr)begin
    s_reads<=s_reads+1;
    if(s_addr==16'ha000)busy<=0;
    if(s_addr==16'hc000)cmdirq<=0;
   end
   if(aw&&!last_aw&&!pause_cpu)begin
    if(a_shared)begin shared_writes<=shared_writes+1;end
    case(a_addr)
     (is_hal?16'hc300:16'ha300):begin sound_latch<=a_dout;busy<=1;cmdirq<=1;sound_commands<=sound_commands+1;end
     (is_hal?16'hc600:16'ha600):begin flip<=a_dout[7];bg_tile_bank<=is_hal?a_dout[5]:1'b0;bg_palette_bank<=a_dout[3:0]^4'h8;end
     (is_hal?16'hc700:16'ha700):nmia<=0;
     16'hd300:begin if(is_hal||is_jc)begin bg_y[8]<=a_dout[4];sprite_y[8]<=a_dout[3];end bg_x[8]<=a_dout[1];sprite_x[8]<=a_dout[0];end
     16'hd400:sprite_y[7:0]<=a_dout;16'hd500:sprite_x[7:0]<=a_dout;
     16'hd600:bg_y[7:0]<=a_dout;16'hd700:bg_x[7:0]<=a_dout;
    endcase
   end
   if(bw&&!last_bw&&!pause_cpu)begin
    if(b_shared)begin shared_writes<=shared_writes+1;end
    case(b_addr)
     (is_jc?16'ha700:16'ha000):nmib<=0;
     16'ha600:begin if(is_sg)begin flip<=b_dout[7];bg_palette_bank<=b_dout[3:0]^4'h8;end end
     16'hdb00:begin if(is_sg)begin bg_x[8]<=b_dout[1];sprite_x[8]<=b_dout[0];end end
     16'hdc00:if(is_sg)sprite_y[7:0]<=b_dout;16'hdd00:if(is_sg)sprite_x[7:0]<=b_dout;
     16'hde00:if(is_sg)bg_y[7:0]<=b_dout;16'hdf00:if(is_sg)bg_x[7:0]<=b_dout;
    endcase
   end
   if(sw&&!last_sw&&!pause_cpu)begin
    if(s_addr==16'he000)ay_addr0<=s_dout[3:0];
    if(s_addr==(is_hal?16'he008:16'he004))ay_addr1<=s_dout[3:0];
    if(s_addr==16'he001||s_addr==(is_hal?16'he009:16'he005))ay_writes<=ay_writes+1;
   end
  end
 end
endmodule
