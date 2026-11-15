// Native late-family address/IRQ/NMI/register decoder; no CPU, RAM or renderer model.
// Canonical profiles only: 11 Bermuda, 12 World Wars, 13 Psycho, 16 Chopper, 19 Guerrilla War.
// Runtime profile changes require board reset and ROM reload.
// Reference: pinned MAME 0.289 snk.cpp psychos_cpuA_map/psychos_cpuB_map.
// Shared-memory access scheduling is external. Both ports address identical RAM.
module snk_late_bus_control (
 input wire [4:0] profile_id,
 input wire clk, reset_n, vblank,
 input wire [15:0] a_addr, b_addr,
 input wire [7:0] a_data, b_data, a_rom, b_rom, a_ram, b_ram,
 input wire a_mreq_n,a_iorq_n,a_m1_n,a_rd_n,a_wr_n,
 input wire b_mreq_n,b_iorq_n,b_m1_n,b_rd_n,b_wr_n,
 input wire [7:0] in0,in1,in2,in3,dsw1,dsw2,
 input wire sound_busy,
 input wire [7:0] turbo_data,
 output reg [8:0] turbo16_x,turbo16_y,turbo32_x,turbo32_y,
 output reg [7:0] a_din,b_din,
 output wire a_ram_req,b_ram_req,a_ram_write,b_ram_write,
 output wire [13:0] a_ram_offset,b_ram_offset,
 output reg a_irq_n,b_irq_n,a_nmi_n,b_nmi_n,
 output reg sound_command_wr,
 output reg [7:0] sound_command,
 output reg [8:0] bg_x,bg_y,s16_x,s16_y,s32_x,s32_y,
 output reg flip_screen,
 output reg [7:0] text_attrs,sprite_split,
 output reg coin_write,
 output reg [7:0] coin_data
);
 wire ik=profile_id==5'd14 || profile_id==5'd18; // Ikari Warriors / Victory Road (snk.cpp ikari_cpuA_map/ikari_cpuB_map)
 wire profile_valid=profile_id==5'd11 || profile_id==5'd12 ||
                    profile_id==5'd13 || profile_id==5'd16 || profile_id==5'd19 || ik;
 // Chopper (16) and Guerrilla War (19) share the gwar_cpuA/B_map style: sub CPU NMI at C000, sub writes only the
 // tx bank (C8C0), C880 carries flip (bit2) and the sprite scroll MSBs, no turbo-check registers.
 wire chopper=profile_id==5'd16 || profile_id==5'd19;
 wire gwar=profile_id==5'd19;
 // MAME gwar_state::gwar_rotary: the LS30 rotary stick returns 0xF once every 8 direct 5<->6 changes
 // (protection checks that a mechanical 12-way switch occasionally opens). Updated on each CPU read of C100/C200.
 reg [3:0] rlast1=0,rlast2=0;reg [2:0] rcnt1=0,rcnt2=0;
 wire rsw1=(rlast1==4'h5&&in1[7:4]==4'h6)||(rlast1==4'h6&&in1[7:4]==4'h5);
 wire rsw2=(rlast2==4'h5&&in2[7:4]==4'h6)||(rlast2==4'h6&&in2[7:4]==4'h5);
 wire [3:0] rval1=(gwar&&rsw1&&rcnt1==0) ? 4'hf : in1[7:4];
 wire [3:0] rval2=(gwar&&rsw2&&rcnt2==0) ? 4'hf : in2[7:4];
 wire [15:0] b_nmi_address=(chopper||ik) ? 16'hc000 : 16'hc700;
 wire a_read=profile_valid&&!a_mreq_n&&!a_rd_n;
 wire b_read=profile_valid&&!b_mreq_n&&!b_rd_n;
 wire a_write=profile_valid&&!a_mreq_n&&!a_wr_n;
 wire b_write=profile_valid&&!b_mreq_n&&!b_wr_n;
 reg a_read_l,b_read_l,a_write_l,b_write_l,vblank_l;
 wire a_read_start=a_read&&!a_read_l;
 wire b_read_start=b_read&&!b_read_l;
 wire a_write_start=a_write&&!a_write_l;
 wire b_write_start=b_write&&!b_write_l;
 assign a_ram_req=!a_mreq_n&&(a_read||a_write)&&a_addr>=16'hd000;
 assign b_ram_req=!b_mreq_n&&(b_read||b_write)&&b_addr>=16'hd000;
 assign a_ram_write=a_write_start&&a_addr>=16'hd000;
 assign b_ram_write=b_write_start&&b_addr>=16'hd000;
 assign a_ram_offset={2'b00,a_addr[11:0]}+
                     (a_addr[15:12]-4'hd)*14'h1000;
 assign b_ram_offset={2'b00,b_addr[11:0]}+
                     (b_addr[15:12]-4'hd)*14'h1000;
 always @* begin
  a_din=8'hff; b_din=8'hff;
  if(a_read) begin
   if(a_addr<16'hc000) a_din=a_rom;
   else if(a_addr>=16'hd000) a_din=a_ram;
   else case(a_addr)
    16'hc000:a_din={in0[7:1],sound_busy};
    16'hc100:a_din=gwar ? {rval1,in1[3:0]} : in1;
    16'hc200:a_din=gwar ? {rval2,in2[3:0]} : in2;
    16'hc300:a_din=in3;
    16'hc500:a_din=dsw1;
    16'hc600:a_din=dsw2;
    16'hcb00,16'hcb10,16'hcb20,16'hcb30,16'hcb40,16'hcb50,16'hcb60,16'hcb70,
    16'hccc0,16'hccd0,16'hcce0,16'hccf0:a_din=(chopper||ik) ? 8'hff : turbo_data;
    // ikari hardflags_check8<0..5> (CE00..CEA0, 8 sp16 entries each) and hardflags7 (CEE0: entries 48/49 on bits 0,1 and 4,5)
    16'hce00,16'hce20,16'hce40,16'hce60,16'hce80,16'hcea0:a_din=ik ? turbo_data : 8'hff;
    16'hcee0:a_din=ik ? {2'b00,turbo_data[1:0],2'b00,turbo_data[1:0]} : 8'hff;
    default:a_din=8'hff;
   endcase
  end
  if(b_read) begin
   if(b_addr<16'hc000) b_din=b_rom;
   else if(b_addr>=16'hd000) b_din=b_ram;
   else if(ik) case(b_addr)
    // CPU B is the reader of the ikari hard-flags (visibility) registers in the game code (2.8p: LD A,(CE00..CEE0))
    16'hce00,16'hce20,16'hce40,16'hce60,16'hce80,16'hcea0:b_din=turbo_data;
    16'hcee0:b_din={2'b00,turbo_data[1:0],2'b00,turbo_data[1:0]};
    default:begin end
   endcase
  end
 end
 // Both CPUs use the same scroll registers. Board arbitration must ensure
 // only one CPU write retires per master edge; B follows A for a tied edge.
 task write_video(input [15:0] addr,input [7:0] data);
 begin
  if(ik) begin
   // ikari_cpuA_map video registers (bg_scrolly_w .. ikari_sp_scroll_msb_w); C980 = tx char/palette bank
   case(addr)
    16'hc800:bg_y[7:0]<=data;
    16'hc880:bg_x[7:0]<=data;
    16'hc900:begin bg_x[8]<=data[1];bg_y[8]<=data[0];end
    16'hca00:s16_y[7:0]<=data;
    16'hca80:s16_x[7:0]<=data;
    16'hcb00:s32_y[7:0]<=data;
    16'hcb80:s32_x[7:0]<=data;
    16'hcd00:begin s32_x[8]<=data[5];s16_x[8]<=data[4];s32_y[8]<=data[3];s16_y[8]<=data[2];end
    16'hc980:text_attrs<={3'b000,data[4],3'b000,data[0]};
    default:begin end
   endcase
  end else
  case(addr)
   16'hc800:bg_y[7:0]<=data;
   16'hc840:bg_x[7:0]<=data;
   16'hc880:begin
    flip_screen<=chopper ? data[2] : data[4];
    bg_x[8]<=data[1];bg_y[8]<=data[0];
    if(chopper)begin
     s32_x[8]<=data[7];s16_x[8]<=data[6];
     s32_y[8]<=data[5];s16_y[8]<=data[4];
    end
   end
   16'hc8c0:text_attrs<=data;
   16'hc900:s16_y[7:0]<=data;
   16'hc940:s16_x[7:0]<=data;
   16'hc980:s32_y[7:0]<=data;
   16'hc9c0:s32_x[7:0]<=data;
   16'hca80:if(!chopper)begin
    s32_x[8]<=data[5];s16_x[8]<=data[4];
    s32_y[8]<=data[3];s16_y[8]<=data[2];
   end
   default:begin end
  endcase
 end
 endtask
 always @(posedge clk) begin
  if(!reset_n || !profile_valid) begin
   a_read_l<=0;b_read_l<=0;a_write_l<=0;b_write_l<=0;vblank_l<=0;
   a_irq_n<=1;b_irq_n<=1;a_nmi_n<=1;b_nmi_n<=1;
   sound_command_wr<=0;sound_command<=0;coin_write<=0;coin_data<=0;
   bg_x<=0;bg_y<=0;s16_x<=0;s16_y<=0;s32_x<=0;s32_y<=0;
   flip_screen<=0;text_attrs<=0;sprite_split<=0;
   turbo16_x<=0;turbo16_y<=0;turbo32_x<=0;turbo32_y<=0;
   rlast1<=0;rlast2<=0;rcnt1<=0;rcnt2<=0;
  end else begin
   a_read_l<=a_read;b_read_l<=b_read;
   a_write_l<=a_write;b_write_l<=b_write;vblank_l<=vblank;
   sound_command_wr<=0;coin_write<=0;
   // HOLD_LINE IRQ: clear on the actual Z80 interrupt acknowledge.
   if(!a_iorq_n&&!a_m1_n) a_irq_n<=1;
   if(!b_iorq_n&&!b_m1_n) b_irq_n<=1;
   if(vblank&&!vblank_l) begin a_irq_n<=0;b_irq_n<=0;end
   // Read asserts the other CPU's NMI; write acknowledges one's own NMI.
   if(gwar&&a_read_start&&a_addr==16'hc100) begin rlast1<=rval1;if(rsw1)rcnt1<=rcnt1+3'd1; end
   if(gwar&&a_read_start&&a_addr==16'hc200) begin rlast2<=rval2;if(rsw2)rcnt2<=rcnt2+3'd1; end
   if(a_read_start&&a_addr==16'hc700) b_nmi_n<=0;
   if(b_read_start&&b_addr==b_nmi_address) a_nmi_n<=0;
   if(a_write_start) begin
    write_video(a_addr,a_data);
    case(a_addr)
     16'hc300:begin coin_write<=1;coin_data<=a_data;end
     16'hc400:begin sound_command_wr<=1;sound_command<=a_data;end
     16'hc700:a_nmi_n<=1;
     16'hcac0:if(!ik)sprite_split<=a_data;
     16'hca00:if(!chopper&&!ik)turbo16_y[7:0]<=a_data;
     16'hca40:if(!chopper&&!ik)turbo16_x[7:0]<=a_data;
     16'hcc00:if(ik)turbo16_y[7:0]<=a_data; else if(!chopper)turbo32_y[7:0]<=a_data;
     16'hcc40:if(!chopper&&!ik)turbo32_x[7:0]<=a_data;
     16'hcc80:if(ik)turbo16_x[7:0]<=a_data; else if(!chopper)begin
      turbo16_x[8]<=a_data[7];turbo32_x[8]<=a_data[7];
      turbo16_y[8]<=a_data[6];turbo32_y[8]<=a_data[6];
     end
     16'hcd80:if(ik)begin turbo16_x[8]<=a_data[7];turbo16_y[8]<=a_data[6];end
     default:begin end
    endcase
   end
   if(b_write_start) begin
    if(ik) begin
     // ikari_common_map is shared by both CPUs: tx attrs (C980) and the hard-flag position registers
     if(b_addr==16'hc980)write_video(b_addr,b_data);
     if(b_addr==16'hcc00)turbo16_y[7:0]<=b_data;
     if(b_addr==16'hcc80)turbo16_x[7:0]<=b_data;
     if(b_addr==16'hcd80)begin turbo16_x[8]<=b_data[7];turbo16_y[8]<=b_data[6];end
    end else if(!chopper || b_addr==16'hc8c0)write_video(b_addr,b_data);
    if(b_addr==b_nmi_address) b_nmi_n<=1;
   end
  end
 end
endmodule
