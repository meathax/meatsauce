// Psycho Soldier address/IRQ/NMI/register decoder; no CPU, RAM or renderer model.
// Reference: pinned MAME 0.289 snk.cpp psychos_cpuA_map/psychos_cpuB_map.
// Shared-memory access scheduling is external. Both ports address identical RAM.
module snk_psychos_bus_control (
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
 wire a_read=!a_mreq_n&&!a_rd_n;
 wire b_read=!b_mreq_n&&!b_rd_n;
 wire a_write=!a_mreq_n&&!a_wr_n;
 wire b_write=!b_mreq_n&&!b_wr_n;
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
    16'hc100:a_din=in1;
    16'hc200:a_din=in2;
    16'hc300:a_din=in3;
    16'hc500:a_din=dsw1;
    16'hc600:a_din=dsw2;
    16'hcb00,16'hcb10,16'hcb20,16'hcb30,16'hcb40,16'hcb50,16'hcb60,16'hcb70,
    16'hccc0,16'hccd0,16'hcce0,16'hccf0:a_din=turbo_data;
    default:a_din=8'hff;
   endcase
  end
  if(b_read) begin
   if(b_addr<16'hc000) b_din=b_rom;
   else if(b_addr>=16'hd000) b_din=b_ram;
  end
 end
 // Both CPUs use the same scroll registers. Board arbitration must ensure
 // only one CPU write retires per master edge; B follows A for a tied edge.
 task write_video(input [15:0] addr,input [7:0] data);
 begin
  case(addr)
   16'hc800:bg_y[7:0]<=data;
   16'hc840:bg_x[7:0]<=data;
   16'hc880:begin
    flip_screen<=data[4]; bg_x[8]<=data[1];bg_y[8]<=data[0];
   end
   16'hc8c0:text_attrs<=data;
   16'hc900:s16_y[7:0]<=data;
   16'hc940:s16_x[7:0]<=data;
   16'hc980:s32_y[7:0]<=data;
   16'hc9c0:s32_x[7:0]<=data;
   16'hca80:begin
    s32_x[8]<=data[5];s16_x[8]<=data[4];
    s32_y[8]<=data[3];s16_y[8]<=data[2];
   end
   default:begin end
  endcase
 end
 endtask
 always @(posedge clk) begin
  if(!reset_n) begin
   a_read_l<=0;b_read_l<=0;a_write_l<=0;b_write_l<=0;vblank_l<=0;
   a_irq_n<=1;b_irq_n<=1;a_nmi_n<=1;b_nmi_n<=1;
   sound_command_wr<=0;sound_command<=0;coin_write<=0;coin_data<=0;
   bg_x<=0;bg_y<=0;s16_x<=0;s16_y<=0;s32_x<=0;s32_y<=0;
   flip_screen<=0;text_attrs<=0;sprite_split<=0;
   turbo16_x<=0;turbo16_y<=0;turbo32_x<=0;turbo32_y<=0;
  end else begin
   a_read_l<=a_read;b_read_l<=b_read;
   a_write_l<=a_write;b_write_l<=b_write;vblank_l<=vblank;
   sound_command_wr<=0;coin_write<=0;
   // HOLD_LINE IRQ: clear on the actual Z80 interrupt acknowledge.
   if(!a_iorq_n&&!a_m1_n) a_irq_n<=1;
   if(!b_iorq_n&&!b_m1_n) b_irq_n<=1;
   if(vblank&&!vblank_l) begin a_irq_n<=0;b_irq_n<=0;end
   // Read asserts the other CPU's NMI; write acknowledges one's own NMI.
   if(a_read_start&&a_addr==16'hc700) b_nmi_n<=0;
   if(b_read_start&&b_addr==16'hc700) a_nmi_n<=0;
   if(a_write_start) begin
    write_video(a_addr,a_data);
    case(a_addr)
     16'hc300:begin coin_write<=1;coin_data<=a_data;end
     16'hc400:begin sound_command_wr<=1;sound_command<=a_data;end
     16'hc700:a_nmi_n<=1;
     16'hcac0:sprite_split<=a_data;
     16'hca00:turbo16_y[7:0]<=a_data;
     16'hca40:turbo16_x[7:0]<=a_data;
     16'hcc00:turbo32_y[7:0]<=a_data;
     16'hcc40:turbo32_x[7:0]<=a_data;
     16'hcc80:begin
      turbo16_x[8]<=a_data[7];turbo32_x[8]<=a_data[7];
      turbo16_y[8]<=a_data[6];turbo32_y[8]<=a_data[6];
     end
     default:begin end
    endcase
   end
   if(b_write_start) begin
    write_video(b_addr,b_data);
    if(b_addr==16'hc700) b_nmi_n<=1;
   end
  end
 end
endmodule
