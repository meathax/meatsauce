// SPDX-License-Identifier: BSD-3-Clause
// Maps/protocols: pinned MAME0.289 snk.cpp marvins/madcrash; no embedded CPU, ROM, RAM or sound device.
// External registered RAM ports and the common two-JT49/Wave devices are owned by the union.
module snk_wave_controller_external(
 input wire clk,reset,input wire [7:0] profile,
 input wire vblank,ce_sound,
 input wire [7:0] in0,in1,in2,dsw1,dsw2,
 input wire [15:0] a_addr,b_addr,s_addr,
 input wire [7:0] a_dout,b_dout,s_dout,rom_qa,rom_qb,rom_qs,
 input wire a_m1_n,a_mreq_n,a_iorq_n,a_rd_n,a_wr_n,
 input wire b_m1_n,b_mreq_n,b_iorq_n,b_rd_n,b_wr_n,
 input wire s_m1_n,s_mreq_n,s_iorq_n,s_rd_n,s_wr_n,
 output reg [7:0] a_din,b_din,s_din,
 output wire a_irq_n,b_irq_n,s_irq_n,a_nmi_n,b_nmi_n,s_nmi_n,
 input wire memory_b_wait_n,output wire b_wait_n,
 output wire [13:0] ram_addr_a,ram_addr_b,
 output wire ram_write_a,ram_write_b,output wire [7:0] ram_data_a,ram_data_b,
 input wire [7:0] shared_qa,shared_qb,
 output wire [10:0] sound_ram_addr,output wire [7:0] sound_ram_data,
 output wire sound_ram_write,input wire [7:0] ram_qs,
 output reg [3:0] ay_addr0,ay_addr1,output wire ay_write0,ay_write1,
 output wire [7:0] sound_data,output wire wave_write,output wire [2:0] wave_addr,
 output reg flip,output reg [6:0] bg_palette_offset,fg_palette_offset,
 output reg [8:0] bg_x,fg_x,sprite_x,output reg [7:0] bg_y,fg_y,sprite_y,sprite_split,
 input wire memory_commit,input wire [13:0] committed_addr,input wire [7:0] committed_data,
 output wire canonical_wr,output wire [15:0] canonical_addr,output wire [7:0] canonical_data,
 output wire sound_busy,output wire supported,
 output reg [31:0] input_polls,sound_commands,ay_writes,wave_writes
);
 wire marvin=profile==0;
 assign supported=profile==0||profile==1||profile==2;
 wire ar=supported&&!reset&&!a_mreq_n&&!a_rd_n,aw=supported&&!reset&&!a_mreq_n&&!a_wr_n;
 wire br=supported&&!reset&&!b_mreq_n&&!b_rd_n,bw=supported&&!reset&&!b_mreq_n&&!b_wr_n;
 wire sr=supported&&!reset&&!s_mreq_n&&!s_rd_n,sw=supported&&!reset&&!s_mreq_n&&!s_wr_n;
 reg last_ar,last_aw,last_br,last_bw,last_sr,last_sw,last_vblank;
 wire new_aw=aw&&!last_aw,new_bw=bw&&!last_bw,new_ar=ar&&!last_ar,new_br=br&&!last_br;
 wire new_sr=sr&&!last_sr,new_sw=sw&&!last_sw;
 reg irq_a,irq_b,irq_s,nmi_a,nmi_b,nmi_s,latch_pending;
 reg [7:0] sound_latch;reg [13:0] nmi_timer;
 assign a_irq_n=!irq_a;assign b_irq_n=!irq_b;assign s_irq_n=!irq_s;
 assign a_nmi_n=!nmi_a;assign b_nmi_n=!nmi_b;assign s_nmi_n=!nmi_s;
 assign sound_busy=latch_pending;assign b_wait_n=memory_b_wait_n;
 // RAM canonical order is Marvin's C000..F7FF. Mad/Vanguard aliases translate into the same planes.
 function automatic [14:0] ram_decode(input [15:0] addr,input is_b);
  reg [15:0] canonical;
  begin
   canonical=0;ram_decode=0;
   if(marvin)begin
    if(addr>=16'hc000&&addr<=16'hf7ff)ram_decode={1'b1,addr[13:0]};
   end else if(!is_b)begin
    if(addr>=16'hc000&&addr<=16'hc7ff)canonical=addr;
    else if(addr>=16'hd000&&addr<=16'hd7ff)canonical=addr+16'h1000;
    else if(addr>=16'he000&&addr<=16'he7ff)canonical=addr-16'h1000;
    else if((addr>=16'hd800&&addr<=16'hdfff)||(addr>=16'he800&&addr<=16'hf7ff))canonical=addr;
    if(canonical!=0)ram_decode={1'b1,canonical[13:0]};
   end else begin
    if(addr>=16'hc000&&addr<=16'hc7ff)canonical=addr+16'h1000;
    else if(addr>=16'hc800&&addr<=16'hcfff)canonical=addr+16'h2000;
    else if(addr>=16'hd000&&addr<=16'hd7ff)canonical=addr+16'h2000;
    else if(addr>=16'he000&&addr<=16'he7ff)canonical=addr-16'h2000;
    else if(addr>=16'hf000&&addr<=16'hf7ff)canonical=addr-16'h1000;
    else if(addr>=16'hf800)canonical=addr-16'h2000;
    if(canonical!=0)ram_decode={1'b1,canonical[13:0]};
   end
  end
 endfunction
 wire [14:0] da=ram_decode(a_addr,1'b0),db=ram_decode(b_addr,1'b1);
 assign ram_addr_a=da[13:0];assign ram_addr_b=db[13:0];
 assign ram_write_a=aw&&da[14];assign ram_write_b=bw&&db[14];
 assign ram_data_a=a_dout;assign ram_data_b=b_dout;
 assign sound_ram_addr=s_addr[10:0];assign sound_ram_data=s_dout;
 assign sound_ram_write=sw&&s_addr>=16'he000&&s_addr<=16'he7ff;
 assign canonical_wr=supported&&!reset&&memory_commit;
 assign canonical_addr=16'hc000+{2'b0,committed_addr};assign canonical_data=committed_data;
 assign sound_data=s_dout;
 assign ay_write0=new_sw&&s_addr==16'h8001;
 assign ay_write1=new_sw&&s_addr==16'h8009;
 assign wave_write=new_sw&&s_addr>=16'h8002&&s_addr<=16'h8007;
 assign wave_addr=s_addr[2:0]-3'd2;
 wire [7:0] busy_mask=marvin?8'h40:(profile==1?8'h20:8'h60);
 always @* begin
  a_din=8'hff;b_din=8'hff;s_din=8'hff;
  if(ar)begin
   if(a_addr<=(marvin?16'h5fff:16'h7fff))a_din=rom_qa;
   else if(da[14])a_din=shared_qa;
   else case(a_addr)
    16'h8000:a_din=(in0&~busy_mask)|(latch_pending?busy_mask:8'h00);
    16'h8100:a_din=in1;16'h8200:a_din=in2;
    16'h8400:a_din=dsw1;16'h8500:a_din=dsw2;
    default:a_din=8'hff;
   endcase
  end
  if(br)begin
   if(b_addr<=(marvin?16'h5fff:16'h9fff))b_din=rom_qb;
   else if(db[14])b_din=shared_qb;
  end
  if(sr)begin
   if(s_addr<=16'h3fff)s_din=rom_qs;
   else if(s_addr==16'h4000)s_din=sound_latch;
   else if(s_addr>=16'he000&&s_addr<=16'he7ff)s_din=ram_qs;
  end
 end
 task automatic video_write(input [15:0] address,input [7:0] data,input is_b);
  reg valid;reg [2:0] regno;
  begin
   valid=0;regno=0;
   if(marvin)begin
    valid=address>=16'hf800&&address[7:0]==0;
    case(address[10:8])
     0:regno=4;1:regno=5;2:regno=6;3:regno=7;
     4:regno=0;5:regno=1;6:regno=2;7:regno=3;
    endcase
   end else if(is_b)begin
    valid=address>=16'hd800&&address<=16'hdf00&&address[7:0]==0;regno=address[10:8];
   end else begin valid=address>=16'hf800;regno=address[10:8];end
   if(valid)case(regno)
    0:bg_y<=data;1:bg_x[7:0]<=data;2:sprite_split<=data;
    3:begin bg_x[8]<=data[2];fg_x[8]<=data[1];sprite_x[8]<=data[0];end
    4:sprite_y<=data;5:sprite_x[7:0]<=data;6:fg_y<=data;7:fg_x[7:0]<=data;
   endcase
  end
 endtask
 always @(posedge clk)begin
  last_ar<=ar;last_aw<=aw;last_br<=br;last_bw<=bw;last_sr<=sr;last_sw<=sw;last_vblank<=vblank;
  if(reset||!supported)begin
   last_ar<=0;last_aw<=0;last_br<=0;last_bw<=0;last_sr<=0;last_sw<=0;last_vblank<=0;
   irq_a<=0;irq_b<=0;irq_s<=0;nmi_a<=0;nmi_b<=0;nmi_s<=0;latch_pending<=0;sound_latch<=0;nmi_timer<=0;
   ay_addr0<=0;ay_addr1<=0;flip<=0;bg_palette_offset<=0;fg_palette_offset<=0;
   bg_x<=0;fg_x<=0;sprite_x<=0;bg_y<=0;fg_y<=0;sprite_y<=0;sprite_split<=0;
   input_polls<=0;sound_commands<=0;ay_writes<=0;wave_writes<=0;
  end else begin
   if(!a_m1_n&&!a_iorq_n)irq_a<=0;
   if(!b_m1_n&&!b_iorq_n)irq_b<=0;
   if(!s_m1_n&&!s_iorq_n)irq_s<=0;
   if(vblank&&!last_vblank)begin irq_a<=1;irq_b<=1;end
   if(ce_sound)begin nmi_timer<=nmi_timer+1'b1;if(nmi_timer==14'h3fff)nmi_s<=1;end
   if(new_ar&&a_addr==16'h8700)nmi_b<=1;
   if(new_br&&marvin&&b_addr==16'h8700)nmi_a<=1;
   if(new_aw&&a_addr==16'h8700)nmi_a<=0;
   if(new_bw&&(b_addr==16'h8700||(!marvin&&b_addr==16'ha000)))nmi_b<=0;
   if(new_sr&&s_addr==16'ha000)nmi_s<=0;
   if(new_sr&&s_addr==16'h4000)latch_pending<=0;
   if(new_aw)begin
    video_write(a_addr,a_dout,1'b0);
    if(a_addr==16'h8300)begin sound_latch<=a_dout;if(!latch_pending)irq_s<=1;latch_pending<=1;sound_commands<=sound_commands+1'b1;end
    if((marvin&&a_addr==16'h6000)||(!marvin&&a_addr[15:8]==8'hc8))begin bg_palette_offset<={a_dout[6:4],4'b0};fg_palette_offset<={a_dout[2:0],4'b0};end
    if((marvin&&a_addr==16'h8600)||(!marvin&&a_addr[15:8]==8'h86))flip<=a_dout[7];
   end
   if(new_bw)video_write(b_addr,b_dout,1'b1);
   if(new_ar&&(a_addr==16'h8000||a_addr==16'h8100||a_addr==16'h8200||a_addr==16'h8400||a_addr==16'h8500))input_polls<=input_polls+1'b1;
   if(new_sw)begin
    if(s_addr==16'h8000)ay_addr0<=s_dout[3:0];if(s_addr==16'h8008)ay_addr1<=s_dout[3:0];
    if(ay_write0||ay_write1)ay_writes<=ay_writes+1'b1;if(wave_write)wave_writes<=wave_writes+1'b1;
   end
  end
 end
endmodule
