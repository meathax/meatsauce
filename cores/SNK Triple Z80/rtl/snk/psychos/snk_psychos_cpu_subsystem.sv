// Psycho Soldier's three real native T80pa CPUs and program/shared/private RAM.
// Component stage: real scheduled CPU/video shared RAM. Actual root clock/video
// integration remains required; this module does not qualify gameplay.
module snk_psychos_cpu_subsystem #(parameter HISCORE_ENABLE=0)(
 input wire clk,reset_n,cen_p,cen_n,vblank,
 input wire hs_grant,hs_req,hs_write,
 input wire [15:0] hs_addr,input wire [7:0] hs_wdata,
 output wire hs_ack,output wire [7:0] hs_rdata,

 input wire [24:0] ioctl_addr,input wire [7:0] ioctl_data,input wire ioctl_wr,
 input wire [7:0] in0,in1,in2,in3,dsw1,dsw2,
 input wire sound_busy,sound_irq_n,input wire [7:0] sound_din,
 output wire [15:0] sound_bus_addr,
 output wire [7:0] sound_bus_data,
 output wire sound_bus_mem,sound_bus_rd,sound_bus_wr,
 output wire sound_command_wr,output wire [7:0] sound_command,
 output wire [8:0] bg_x,bg_y,s16_x,s16_y,s32_x,s32_y,
 output wire flip_screen,output wire [7:0] text_attrs,sprite_split,
 output wire coin_write,output wire [7:0] coin_data,
 input wire [10:0] vbg_addr,vtx_addr,output wire [7:0] vbg_data,vtx_data,
 input wire [6:0] vspr_addr,output wire [31:0] vspr_data,
 output wire [15:0] debug_a_addr,debug_b_addr,debug_s_addr,
 output wire [7:0] debug_a_data,debug_b_data,debug_s_data,
 output wire [7:0] debug_a_din,debug_b_din,debug_s_din,
 output wire [4:0] debug_a_ctl,debug_b_ctl,debug_s_ctl
);
 wire [15:0] a_addr,b_addr;
 wire [7:0] a_data,b_data,a_din,b_din,rom_a0,rom_a1,rom_a2,rom_b0,rom_b1,rom_b2;
 wire a_m1_n,a_mreq_n,a_iorq_n,a_rd_n,a_wr_n;
 wire b_m1_n,b_mreq_n,b_iorq_n,b_rd_n,b_wr_n;
 wire a_irq_n,b_irq_n,a_nmi_n,b_nmi_n;
 snk_main_cpu_pair pair(
 .clk(clk),.ioctl_addr(ioctl_addr),.ioctl_data(ioctl_data),.ioctl_wr(ioctl_wr),
 .pair_a_reset_n(reset_n),.pair_a_cen_p(cen_p),.pair_a_cen_n(cen_n),
 .pair_a_wait_n(1'b1),.pair_a_int_n(a_irq_n),.pair_a_nmi_n(a_nmi_n),.pair_a_din(a_din),
 .cpuA_nM1(a_m1_n),.cpuA_nMR(a_mreq_n),.cpuA_nIO(a_iorq_n),
 .cpuA_nRD(a_rd_n),.cpuA_nWR(a_wr_n),.cpuA_nRFSH(),.cpuA_nHALT(),.cpuA_nBUSACK(),
 .cpuA_A(a_addr),.cpuA_Dout(a_data),.pair_rom_a0(rom_a0),.pair_rom_a1(rom_a1),.pair_rom_a2(rom_a2),
 .pair_b_reset_n(reset_n),.pair_b_cen_p(cen_n),.pair_b_cen_n(cen_p),
 .pair_b_wait_n(1'b1),.pair_b_int_n(b_irq_n),.pair_b_nmi_n(b_nmi_n),.pair_b_din(b_din),
 .cpuB_nM1(b_m1_n),.cpuB_nMR(b_mreq_n),.cpuB_nIO(b_iorq_n),
 .cpuB_nRD(b_rd_n),.cpuB_nWR(b_wr_n),.cpuB_nRFSH(),.cpuB_nHALT(),.cpuB_nBUSACK(),
 .cpuB_A(b_addr),.cpuB_Dout(b_data),.pair_rom_b0(rom_b0),.pair_rom_b1(rom_b1),.pair_rom_b2(rom_b2));
 wire [7:0] a_rom=a_addr[15:14]==0  ?  rom_a0:(a_addr[15:14]==1  ?  rom_a1:rom_a2);
 wire [7:0] b_rom=b_addr[15:14]==0  ?  rom_b0:(b_addr[15:14]==1  ?  rom_b1:rom_b2);
 wire a_ram_req,b_ram_req,a_ram_write,b_ram_write;
 wire [13:0] a_ram_offset,b_ram_offset;
 wire [7:0] a_ram,b_ram;
 wire [8:0] turbo16_x,turbo16_y,turbo32_x,turbo32_y;
 wire [7:0] turbo_data;
 wire small_probe=a_addr[11:8]==4'hb;
 snk_psychos_shared_ram #(.HISCORE_ENABLE(HISCORE_ENABLE)) shared_ram(.clk(clk),.reset_n(reset_n),
 .hs_grant(hs_grant),.hs_req(hs_req),.hs_write(hs_write),.hs_addr(hs_addr),
 .hs_wdata(hs_wdata),.hs_ack(hs_ack),.hs_rdata(hs_rdata),
 .a_req(a_ram_req),.b_req(b_ram_req),.a_write(a_ram_write),.b_write(b_ram_write),
 .a_offset(a_ram_offset),.b_offset(b_ram_offset),.a_data(a_data),.b_data(b_data),.a_q(a_ram),.b_q(b_ram),
 .vbg_addr(vbg_addr),.vtx_addr(vtx_addr),.vbg_data(vbg_data),.vtx_data(vtx_data),
 .vspr_addr(vspr_addr),.vspr_data(vspr_data),
 .turbo_select(small_probe  ?  {1'b1,a_addr[6:4]}:{2'b00,a_addr[5:4]}),
 .turbo_x(small_probe  ?  turbo16_x:turbo32_x),.turbo_y(small_probe  ?  turbo16_y:turbo32_y),
 .turbo_data(turbo_data));
 snk_psychos_bus_control bus_ctl(
 .clk(clk),.reset_n(reset_n),.vblank(vblank),.a_addr(a_addr),.b_addr(b_addr),
 .a_data(a_data),.b_data(b_data),.a_rom(a_rom),.b_rom(b_rom),.a_ram(a_ram),.b_ram(b_ram),
 .a_mreq_n(a_mreq_n),.a_iorq_n(a_iorq_n),.a_m1_n(a_m1_n),.a_rd_n(a_rd_n),.a_wr_n(a_wr_n),
 .b_mreq_n(b_mreq_n),.b_iorq_n(b_iorq_n),.b_m1_n(b_m1_n),.b_rd_n(b_rd_n),.b_wr_n(b_wr_n),
 .in0(in0),.in1(in1),.in2(in2),.in3(in3),.dsw1(dsw1),.dsw2(dsw2),.sound_busy(sound_busy),
 .turbo_data(turbo_data),.turbo16_x(turbo16_x),.turbo16_y(turbo16_y),
 .turbo32_x(turbo32_x),.turbo32_y(turbo32_y),
 .a_din(a_din),.b_din(b_din),.a_ram_req(a_ram_req),.b_ram_req(b_ram_req),
 .a_ram_write(a_ram_write),.b_ram_write(b_ram_write),.a_ram_offset(a_ram_offset),.b_ram_offset(b_ram_offset),
 .a_irq_n(a_irq_n),.b_irq_n(b_irq_n),.a_nmi_n(a_nmi_n),.b_nmi_n(b_nmi_n),
 .sound_command_wr(sound_command_wr),.sound_command(sound_command),
 .bg_x(bg_x),.bg_y(bg_y),.s16_x(s16_x),.s16_y(s16_y),.s32_x(s32_x),.s32_y(s32_y),
 .flip_screen(flip_screen),.text_attrs(text_attrs),.sprite_split(sprite_split),
 .coin_write(coin_write),.coin_data(coin_data));
 wire [15:0] s_addr;wire [7:0] s_data;
 wire s_m1_n,s_mreq_n,s_iorq_n,s_rd_n,s_wr_n;
 wire [7:0] rom_s0,rom_s1,rom_s2;
 reg [7:0] s_din,s_ram;
 reg [7:0] sound_memory[0:4095];
 reg s_write_l;
 wire s_write=!s_mreq_n&&!s_wr_n;
 always @(posedge clk) begin
  s_ram<=sound_memory[s_addr[11:0]];
  if(!reset_n) s_write_l<=0;
  else begin
   s_write_l<=s_write;
   if(s_write&&!s_write_l&&s_addr[15:12]==4'hc)
    sound_memory[s_addr[11:0]]<=s_data;
  end
 end
 always @* begin
  s_din=8'hff;
  if(!s_mreq_n&&!s_rd_n) begin
   if(s_addr<16'hc000)
    case(s_addr[15:14])
     2'd0:s_din=rom_s0;2'd1:s_din=rom_s1;default:s_din=rom_s2;
    endcase
   else if(s_addr[15:12]==4'hc) s_din=s_ram;
   else if(s_addr>=16'he000) s_din=sound_din;
  end
 end
 T80pa sound_cpu(.CLK(clk),.RESET_n(reset_n),.CEN_p(cen_p),.CEN_n(cen_n),
 .WAIT_n(1'b1),.INT_n(sound_irq_n),.NMI_n(1'b1),.R800_mode(1'b0),.REG(),.DIRSet(1'b0),.DIR(212'b0),.BUSRQ_n(1'b1),.OUT0(1'b0),
 .DI(s_din),.M1_n(s_m1_n),.MREQ_n(s_mreq_n),.IORQ_n(s_iorq_n),
 .RD_n(s_rd_n),.WR_n(s_wr_n),.RFSH_n(),.HALT_n(),.BUSAK_n(),.A(s_addr),.DO(s_data));
 eprom_16K s0(.CLK(clk),.ADDR(s_addr[13:0]),.DATA(rom_s0),.CLK_DL(clk),
 .ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),
 .CS_DL(ioctl_addr>=25'h20000&&ioctl_addr<25'h24000));
 eprom_16K s1(.CLK(clk),.ADDR(s_addr[13:0]),.DATA(rom_s1),.CLK_DL(clk),
 .ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),
 .CS_DL(ioctl_addr>=25'h24000&&ioctl_addr<25'h28000));
 eprom_16K s2(.CLK(clk),.ADDR(s_addr[13:0]),.DATA(rom_s2),.CLK_DL(clk),
 .ADDR_DL(ioctl_addr[19:0]),.DATA_IN(ioctl_data),.WR(ioctl_wr),
 .CS_DL(ioctl_addr>=25'h28000&&ioctl_addr<25'h2c000));
 assign sound_bus_addr=s_addr;assign sound_bus_data=s_data;
 assign sound_bus_mem=!s_mreq_n;assign sound_bus_rd=!s_rd_n;assign sound_bus_wr=!s_wr_n;
 assign debug_a_addr=a_addr;assign debug_b_addr=b_addr;assign debug_s_addr=s_addr;
 assign debug_a_data=a_data;assign debug_b_data=b_data;assign debug_s_data=s_data;
 assign debug_a_din=a_din;assign debug_b_din=b_din;assign debug_s_din=s_din;
 assign debug_a_ctl={a_m1_n,a_mreq_n,a_iorq_n,a_rd_n,a_wr_n};
 assign debug_b_ctl={b_m1_n,b_mreq_n,b_iorq_n,b_rd_n,b_wr_n};
 assign debug_s_ctl={s_m1_n,s_mreq_n,s_iorq_n,s_rd_n,s_wr_n};
endmodule
