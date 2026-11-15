// Late-family external CPU buses plus original shared/private RAM; no CPU/ROM instances.
// Component stage: real scheduled CPU/video shared RAM. Actual root clock/video
// integration remains required; this module does not qualify gameplay.
module snk_late_cpu_bus #(parameter HISCORE_ENABLE=0)(
 input wire [7:0] profile_id,
 input wire clk,reset_n,vblank,
 input wire hs_grant,hs_req,hs_write,
 input wire [15:0] hs_addr,input wire [7:0] hs_wdata,
 output wire hs_ack,output wire [7:0] hs_rdata,

 input wire [15:0] a_addr,b_addr,s_addr,
 input wire [7:0] a_data,b_data,s_data,a_rom,b_rom,s_rom,
 input wire a_m1_n,a_mreq_n,a_iorq_n,a_rd_n,a_wr_n,
 input wire b_m1_n,b_mreq_n,b_iorq_n,b_rd_n,b_wr_n,
 input wire s_m1_n,s_mreq_n,s_iorq_n,s_rd_n,s_wr_n,
 output wire [7:0] a_din,b_din,output reg [7:0] s_din,
 output wire a_wait_n,b_wait_n,s_wait_n,
 output wire a_irq_n,b_irq_n,s_irq_n,a_nmi_n,b_nmi_n,s_nmi_n,
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
 // Full-width guard prevents donor/unsupported high IDs aliasing canonical IDs.
 wire ik=profile_id==8'd14||profile_id==8'd18; // Ikari Warriors / Victory Road (bermudat-family bus, front hard-flags at CE00)
 wire late_valid=profile_id==8'd11||profile_id==8'd12||profile_id==8'd13||profile_id==8'd16||profile_id==8'd19||ik;
 wire a_irq_raw,b_irq_raw,a_nmi_raw,b_nmi_raw;
 assign a_irq_n=late_valid ? a_irq_raw:1'b1;
 assign b_irq_n=late_valid ? b_irq_raw:1'b1;
 assign a_nmi_n=late_valid ? a_nmi_raw:1'b1;
 assign b_nmi_n=late_valid ? b_nmi_raw:1'b1;
 assign s_irq_n=late_valid ? sound_irq_n:1'b1;
 assign s_nmi_n=1'b1;
 assign a_wait_n=1'b1;assign b_wait_n=1'b1;assign s_wait_n=1'b1;
 wire a_ram_req,b_ram_req,a_ram_write,b_ram_write;
 wire [13:0] a_ram_offset,b_ram_offset;
 wire [7:0] a_ram,b_ram;
 wire [8:0] turbo16_x,turbo16_y,turbo32_x,turbo32_y;
 wire [7:0] turbo_data;
 wire small_probe=a_addr[11:8]==4'hb;
 // ikari hard-flag reads come from CPU B (game code) or A (boot test): pick the CPU addressing CE00-CEFF
 wire [15:0] hf_addr=(b_addr[15:8]==8'hce&&!b_mreq_n&&!b_rd_n) ? b_addr : a_addr;
 snk_late_shared_ram #(.HISCORE_ENABLE(HISCORE_ENABLE)) shared_ram(.profile_id(profile_id),.clk(clk),.reset_n(reset_n),
 .hs_grant(hs_grant),.hs_req(hs_req),.hs_write(hs_write),.hs_addr(hs_addr),
 .hs_wdata(hs_wdata),.hs_ack(hs_ack),.hs_rdata(hs_rdata),
 .a_req(a_ram_req),.b_req(b_ram_req),.a_write(a_ram_write),.b_write(b_ram_write),
 .a_offset(a_ram_offset),.b_offset(b_ram_offset),.a_data(a_data),.b_data(b_data),.a_q(a_ram),.b_q(b_ram),
 .vbg_addr(vbg_addr),.vtx_addr(vtx_addr),.vbg_data(vbg_data),.vtx_data(vtx_data),
 .vspr_addr(vspr_addr),.vspr_data(vspr_data),
 .turbo_select(ik ? {1'b1,(hf_addr[7:5]==3'd7 ? 3'd6 : hf_addr[7:5])} : small_probe  ?  {1'b1,a_addr[6:4]}:{2'b00,a_addr[5:4]}),
 .turbo_x((small_probe||ik)  ?  turbo16_x:turbo32_x),.turbo_y((small_probe||ik)  ?  turbo16_y:turbo32_y),
 .turbo_data(turbo_data));
 snk_late_bus_control bus_ctl(.profile_id(late_valid ? profile_id[4:0]:5'd31),
 .clk(clk),.reset_n(reset_n),.vblank(vblank),.a_addr(a_addr),.b_addr(b_addr),
 .a_data(a_data),.b_data(b_data),.a_rom(a_rom),.b_rom(b_rom),.a_ram(a_ram),.b_ram(b_ram),
 .a_mreq_n(a_mreq_n),.a_iorq_n(a_iorq_n),.a_m1_n(a_m1_n),.a_rd_n(a_rd_n),.a_wr_n(a_wr_n),
 .b_mreq_n(b_mreq_n),.b_iorq_n(b_iorq_n),.b_m1_n(b_m1_n),.b_rd_n(b_rd_n),.b_wr_n(b_wr_n),
 .in0(in0),.in1(in1),.in2(in2),.in3(in3),.dsw1(dsw1),.dsw2(dsw2),.sound_busy(sound_busy),
 .turbo_data(turbo_data),.turbo16_x(turbo16_x),.turbo16_y(turbo16_y),
 .turbo32_x(turbo32_x),.turbo32_y(turbo32_y),
 .a_din(a_din),.b_din(b_din),.a_ram_req(a_ram_req),.b_ram_req(b_ram_req),
 .a_ram_write(a_ram_write),.b_ram_write(b_ram_write),.a_ram_offset(a_ram_offset),.b_ram_offset(b_ram_offset),
 .a_irq_n(a_irq_raw),.b_irq_n(b_irq_raw),.a_nmi_n(a_nmi_raw),.b_nmi_n(b_nmi_raw),
 .sound_command_wr(sound_command_wr),.sound_command(sound_command),
 .bg_x(bg_x),.bg_y(bg_y),.s16_x(s16_x),.s16_y(s16_y),.s32_x(s32_x),.s32_y(s32_y),
 .flip_screen(flip_screen),.text_attrs(text_attrs),.sprite_split(sprite_split),
 .coin_write(coin_write),.coin_data(coin_data));
 reg [7:0] s_ram;
 reg [7:0] sound_memory[0:4095];
 reg s_write_l;
 wire s_write=late_valid&&!s_mreq_n&&!s_wr_n;
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
  if(late_valid&&!s_mreq_n&&!s_rd_n) begin
   if(s_addr<16'hc000)
    s_din=s_rom;
   else if(s_addr[15:12]==4'hc) s_din=s_ram;
   else if(s_addr>=16'he000) s_din=sound_din;
  end
 end
 assign sound_bus_addr=s_addr;assign sound_bus_data=s_data;
 assign sound_bus_mem=late_valid&&!s_mreq_n;assign sound_bus_rd=late_valid&&!s_rd_n;assign sound_bus_wr=late_valid&&!s_wr_n;
 assign debug_a_addr=a_addr;assign debug_b_addr=b_addr;assign debug_s_addr=s_addr;
 assign debug_a_data=a_data;assign debug_b_data=b_data;assign debug_s_data=s_data;
 assign debug_a_din=a_din;assign debug_b_din=b_din;assign debug_s_din=s_din;
 assign debug_a_ctl={a_m1_n,a_mreq_n,a_iorq_n,a_rd_n,a_wr_n};
 assign debug_b_ctl={b_m1_n,b_mreq_n,b_iorq_n,b_rd_n,b_wr_n};
 assign debug_s_ctl={s_m1_n,s_mreq_n,s_iorq_n,s_rd_n,s_wr_n};
endmodule
