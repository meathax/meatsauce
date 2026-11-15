// Shared-clock Psycho frontend. ROM bridge and actual MiSTer wrapper are
// external integration dependencies; this stage alone is not a release core.
module snk_psychos_board #(parameter HISCORE_ENABLE=0,parameter DISPLAY_FLIP_ENABLE=0)(
 input wire clk,reset_n,cen_p,cen_n,ce_opl,pxl_cen,
 input wire display_flip,
 input wire hs_grant,hs_req,hs_write,
 input wire [15:0] hs_addr,input wire [7:0] hs_wdata,
 output wire hs_ack,output wire [7:0] hs_rdata,

 input wire [24:0] ioctl_addr,input wire [7:0] ioctl_data,input wire ioctl_wr,
 input wire [7:0] in0,in1,in2,in3,dsw1,dsw2,
 output wire [17:2] bgrom_addr,s16rom_addr,
 output wire [18:2] s32rom_addr,
 output wire bgrom_req,s16rom_req,s32rom_req,
 input wire [31:0] bgrom_data,s16rom_data,s32rom_data,
 input wire bgrom_ack,s16rom_ack,s32rom_ack,
 output wire [20:0] sample_addr,output wire sample_req,
 input wire [7:0] sample_data,input wire sample_ack,
 output wire [7:0] red,green,blue,
 output wire hsync,vsync,hblank,vblank,
 output wire signed [15:0] audio_mono,
 output wire signed [15:0] ym3526_pcm,y8950_pcm,
 output wire ym3526_sample,y8950_sample,
 output wire [3:0] sound_status,
 output wire [2:0] render_busy,line_overrun,
 output wire [15:0] debug_a_addr,debug_b_addr,debug_s_addr,
 output wire [7:0] debug_a_data,debug_b_data,debug_s_data,
 output wire [7:0] debug_a_din,debug_b_din,debug_s_din,
 output wire [4:0] debug_a_ctl,debug_b_ctl,debug_s_ctl,
 output wire sound_command_wr,output wire [7:0] sound_command
);
 wire [10:0] vbg_addr,vtx_addr;
 wire [7:0] vbg_data,vtx_data;
 wire [6:0] vspr_addr;wire [31:0] vspr_data;
 wire [8:0] bg_x,bg_y,s16_x,s16_y,s32_x,s32_y;
 wire flip_screen;wire [7:0] text_attrs,sprite_split;
 wire [15:0] sound_bus_addr;wire [7:0] sound_bus_data,sound_din;
 wire sound_bus_mem,sound_bus_rd,sound_bus_wr,sound_busy,sound_irq_n;
 wire coin_write;wire [7:0] coin_data;
 snk_psychos_cpu_subsystem #(.HISCORE_ENABLE(HISCORE_ENABLE)) cpus(
 .hs_grant(hs_grant),.hs_req(hs_req),.hs_write(hs_write),.hs_addr(hs_addr),
 .hs_wdata(hs_wdata),.hs_ack(hs_ack),.hs_rdata(hs_rdata),
 .clk(clk),.reset_n(reset_n),.cen_p(cen_p),.cen_n(cen_n),.vblank(vblank),
 .ioctl_addr(ioctl_addr),.ioctl_data(ioctl_data),.ioctl_wr(ioctl_wr),
 .in0(in0),.in1(in1),.in2(in2),.in3(in3),.dsw1(dsw1),.dsw2(dsw2),
 .sound_busy(sound_busy),.sound_irq_n(sound_irq_n),.sound_din(sound_din),
 .sound_bus_addr(sound_bus_addr),.sound_bus_data(sound_bus_data),
 .sound_bus_mem(sound_bus_mem),.sound_bus_rd(sound_bus_rd),.sound_bus_wr(sound_bus_wr),
 .sound_command_wr(sound_command_wr),.sound_command(sound_command),
 .bg_x(bg_x),.bg_y(bg_y),.s16_x(s16_x),.s16_y(s16_y),.s32_x(s32_x),.s32_y(s32_y),
 .flip_screen(flip_screen),.text_attrs(text_attrs),.sprite_split(sprite_split),
 .coin_write(coin_write),.coin_data(coin_data),
 .vbg_addr(vbg_addr),.vtx_addr(vtx_addr),.vbg_data(vbg_data),.vtx_data(vtx_data),
 .vspr_addr(vspr_addr),.vspr_data(vspr_data),
 .debug_a_addr(debug_a_addr),.debug_b_addr(debug_b_addr),.debug_s_addr(debug_s_addr),
 .debug_a_data(debug_a_data),.debug_b_data(debug_b_data),.debug_s_data(debug_s_data),
 .debug_a_din(debug_a_din),.debug_b_din(debug_b_din),.debug_s_din(debug_s_din),
 .debug_a_ctl(debug_a_ctl),.debug_b_ctl(debug_b_ctl),.debug_s_ctl(debug_s_ctl));
 psychos_audio audio(
 .clk(clk),.rst(!reset_n),.ce_opl(ce_opl),
 .cpu_addr(sound_bus_addr),.cpu_din(sound_bus_data),
 .cpu_mem(sound_bus_mem),.cpu_rd(sound_bus_rd),.cpu_wr(sound_bus_wr),
 .cpu_dout(sound_din),.cpu_data_cs(),.cpu_irq_n(sound_irq_n),
 .cmd_data(sound_command),.cmd_wr(sound_command_wr),.cmd_busy(sound_busy),.sound_status(sound_status),
 .sample_addr(sample_addr),.sample_req(sample_req),.sample_data(sample_data),.sample_ack(sample_ack),
 .ym3526_pcm(ym3526_pcm),.y8950_pcm(y8950_pcm),
 .ym3526_sample(ym3526_sample),.y8950_sample(y8950_sample),
 .ym3526_irq_n(),.y8950_irq_n(),.adpcm_pcm(),.adpcm_valid(),.adpcm_status());
 // MAME Psycho routes each chip to mono at gain2. The US set is documented as
 // quieter than psychosj (MAME issue 08153), so add the same +6 dB profile trim
 // as the production union mixer. Preserve headroom and saturate at signed16.
 wire signed [16:0] chip_sum=$signed({ym3526_pcm[15],ym3526_pcm})+
                             $signed({y8950_pcm[15],y8950_pcm});
 wire signed [19:0] chip_sum_wide=$signed({{3{chip_sum[16]}},chip_sum});
 wire signed [19:0] mixed=chip_sum_wide <<< 2;
 assign audio_mono=mixed>20'sd32767 ? 16'sh7fff :
                   (mixed< -20'sd32768 ? 16'sh8000 : mixed[15:0]);
 wire [14:0] txrom_addr;wire [7:0] txrom_data,tx_lo,tx_hi;
 eprom_16K tx0(.CLK(clk),.CLK_DL(clk),.ADDR(txrom_addr[13:0]),.ADDR_DL(ioctl_addr[19:0]),
 .DATA_IN(ioctl_data),.CS_DL(ioctl_addr>=25'h30000&&ioctl_addr<25'h34000),.WR(ioctl_wr),.DATA(tx_lo));
 eprom_16K tx1(.CLK(clk),.CLK_DL(clk),.ADDR(txrom_addr[13:0]),.ADDR_DL(ioctl_addr[19:0]),
 .DATA_IN(ioctl_data),.CS_DL(ioctl_addr>=25'h34000&&ioctl_addr<25'h38000),.WR(ioctl_wr),.DATA(tx_hi));
 assign txrom_data=txrom_addr[14] ? tx_hi : tx_lo;
 wire [9:0] pal_addr;wire [3:0] palr,palg,palb;
 prom_1K_4bit pr(.CLK(clk),.CLK_DL(clk),.ADDR(pal_addr),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN({4'b0,ioctl_data[3:0]}),
 .CS_DL(ioctl_addr>=25'h120000&&ioctl_addr<25'h120400),.WR(ioctl_wr),.DATA(palr));
 prom_1K_4bit pg(.CLK(clk),.CLK_DL(clk),.ADDR(pal_addr),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN({4'b0,ioctl_data[3:0]}),
 .CS_DL(ioctl_addr>=25'h120400&&ioctl_addr<25'h120800),.WR(ioctl_wr),.DATA(palg));
 prom_1K_4bit pb(.CLK(clk),.CLK_DL(clk),.ADDR(pal_addr),.ADDR_DL(ioctl_addr[19:0]),.DATA_IN({4'b0,ioctl_data[3:0]}),
 .CS_DL(ioctl_addr>=25'h120800&&ioctl_addr<25'h120c00),.WR(ioctl_wr),.DATA(palb));
 wire active_h,active_v;wire [7:0] raw_r,raw_g,raw_b;
 snk_psychos_video #(.DISPLAY_FLIP_ENABLE(DISPLAY_FLIP_ENABLE)) video(
 .display_flip(display_flip),.rst(!reset_n),.clk(clk),.pxl_cen(pxl_cen),
 .bg_scrollx(bg_x),.bg_scrolly(bg_y),.sp16_scrollx(s16_x),.sp16_scrolly(s16_y),
 .sp32_scrollx(s32_x),.sp32_scrolly(s32_y),.split(sprite_split),.txbank(text_attrs),.flip(flip_screen),
 .vbg_addr(vbg_addr),.vbg_data(vbg_data),.vtx_addr(vtx_addr),.vtx_data(vtx_data),.vspr_addr(vspr_addr),.vspr_data(vspr_data),
 .bgrom_addr(bgrom_addr),.bgrom_cs(bgrom_req),.bgrom_data(bgrom_data),.bgrom_ok(bgrom_ack),
 .s16rom_addr(s16rom_addr),.s16rom_cs(s16rom_req),.s16rom_data(s16rom_data),.s16rom_ok(s16rom_ack),
 .s32rom_addr(s32rom_addr),.s32rom_cs(s32rom_req),.s32rom_data(s32rom_data),.s32rom_ok(s32rom_ack),
 .blank_en(1'b0),.op16_addr(),.op16(1'b1),.op32_addr(),.op32(1'b1),
 .txrom_addr(txrom_addr),.txrom_data(txrom_data),.pal_addr(pal_addr),.palr(palr),.palg(palg),.palb(palb),
 .LHBL(active_h),.LVBL(active_v),.HS(hsync),.VS(vsync),.red(raw_r),.green(raw_g),.blue(raw_b),
 .gfx_en(4'b1111),.obj_cycles(),.render_busy(render_busy),.line_overrun(line_overrun));
 assign hblank=!active_h;assign vblank=!active_v;
 // Fill the alternating line buffers before exposing the first full frame.
 reg seen_active,frame_primed;
 always @(posedge clk) begin
  if(!reset_n)begin seen_active<=0;frame_primed<=0;end
  else begin
   if(active_v)seen_active<=1;
   if(seen_active&&!active_v)frame_primed<=1;
  end
 end
 assign red=frame_primed ? raw_r : 8'd0;
 assign green=frame_primed ? raw_g : 8'd0;
 assign blue=frame_primed ? raw_b : 8'd0;
endmodule
