// SPDX-License-Identifier: GPL-3.0-or-later
module appoooh_core #(
 parameter integer CPU_HZ=3072000, ADPCM_HZ=384000, PIXEL_HZ=4915200,
 parameter integer CPU_CE_PHASE=0, VIDEO_CE_PHASE=0,
 // Begin each frame at the active-to-blank edge. Reset uses this same origin,
 // so changing raster coordinates does not move NMI relative to CPU startup.
 parameter integer NMI_LINE=239, NMI_X=316, FRAME_ORIGIN=240
)(
 input logic clk,cold_reset,game_reset,
 input logic download,ioctl_wr,
 input logic [15:0] ioctl_index,
 input logic [26:0] ioctl_addr,
 input logic [7:0] ioctl_data,
 input logic [31:0] joy0,joy1,
 input logic [10:0] ps2_key,
 input logic [7:0] dip1,dip2,
 output logic loaded,load_error,running,
 output logic [7:0] red,green,blue,
 output logic hs,vs,hblank,vblank,pixel_ce,
 output logic signed [15:0] audio,
 output logic [8:0] debug_x,
 output logic [7:0] debug_y,
 output logic [15:0] debug_addr,
 output logic [7:0] debug_data,
 output logic debug_io_write,debug_mem_write,debug_fetch,debug_nmi,debug_halt,
 output logic deadline_error,
 output logic [14:0] psg0,psg1,psg2,
 output logic signed [11:0] adpcm,
 output logic [8:0] debug_pen
);
 logic cpu_ce,adpcm_ce,video_ce,loading,load_wr,clearing,robowres_mode;
 logic [18:0] load_addr;
 logic [7:0] load_data;
 appoooh_rom_loader loader(.clk(clk),.cold_reset(cold_reset),.download(download),.wr(ioctl_wr),.index(ioctl_index),.addr(ioctl_addr),.data(ioctl_data),.valid(loaded),.error(load_error),.loading(loading),.mem_wr(load_wr),.mem_addr(load_addr),.mem_data(load_data),.robowres_mode(robowres_mode));
 wire reset=cold_reset||game_reset||!loaded||loading;
 assign running=!reset&&!clearing;
 // Start all fractional enables when the ROM/RAM reset sequence releases the
 // board.  This gives CPU and raster a defined shared phase after download.
 appoooh_ce #(.RATE(CPU_HZ),.INITIAL_PHASE(CPU_CE_PHASE)) cpu_clock(.clk(clk),.reset(!running),.ce(cpu_ce));
 appoooh_ce #(.RATE(ADPCM_HZ)) adpcm_clock(.clk(clk),.reset(!running),.ce(adpcm_ce));
 appoooh_ce #(.RATE(PIXEL_HZ),.INITIAL_PHASE(VIDEO_CE_PHASE)) pixel_clock(.clk(clk),.reset(!running),.ce(video_ce));
 logic [15:0] addr;
  logic [7:0] dout,di,mem_data,p1,p2,button3;
 logic mreq_n,iorq_n,rd_n,wr_n,rfsh_n,m1_n,nmi_n,halt_n;
  logic mem_write,io_write,nmi_enable,flip,cpu_bank,frame_event;
  logic [1:0] render_prio;
 logic [1:0] nmi_hold;
 tv80s #(.Mode(0),.T2Write(0),.IOWait(1)) cpu(.clk(clk),.cen(cpu_ce),.reset_n(running),.wait_n(1'b1),.int_n(1'b1),.nmi_n(nmi_n),.busrq_n(1'b1),.di(di),.dout(dout),.A(addr),.mreq_n(mreq_n),.iorq_n(iorq_n),.rd_n(rd_n),.wr_n(wr_n),.rfsh_n(rfsh_n),.m1_n(m1_n),.halt_n(halt_n),.busak_n());
  appoooh_bus bus(.clk(clk),.reset(!running),.mreq_n(mreq_n),.iorq_n(iorq_n),.rd_n(rd_n),.wr_n(wr_n),.rfsh_n(rfsh_n),.m1_n(m1_n),.addr(addr),.mem_data(mem_data),.p1(p1),.p2(p2),.dsw(dip1),.system(button3),.cpu_data(di),.mem_write(mem_write),.io_write(io_write));
  appoooh_inputs inputs(.clk(clk),.reset(!running),.joy0(joy0),.joy1(joy1),.ps2_key(ps2_key),.p1(p1),.p2(p2),.button3(button3));
 assign nmi_n=nmi_hold==0;
 always_ff @(posedge clk)begin
   if(!running)begin nmi_enable<=0;flip<=0;cpu_bank<=0;render_prio<=0;nmi_hold<=0;end
  else begin
   if(cpu_ce&&nmi_hold!=0)nmi_hold<=nmi_hold-2'd1;
   if(frame_event&&nmi_enable)nmi_hold<=2;
    if(io_write&&addr[7:0]==4)begin
     nmi_enable<=dout[0];flip<=dout[1];render_prio<=dout[5:4];cpu_bank<=dout[6];
    end
  end
 end
 logic [11:0] va;logic [7:0] vd;
  logic [14:0] ga;logic [23:0] g0,g1;
  logic [15:0] sa;logic [7:0] sd;
  logic [8:0] pen;logic [7:0] indirect,color;
  appoooh_memory memory(.clk(clk),.reset(reset),.load_wr(load_wr),.robowres_mode(robowres_mode),.load_addr(load_addr),.load_data(load_data),.cpu_addr(addr),.cpu_bank(cpu_bank),.cpu_wr(mem_write&&running),.cpu_m1_n(m1_n),.cpu_dout(dout),.cpu_din(mem_data),.clearing(clearing),.video_addr(va),.video_data(vd),.gfx_addr(ga),.gfx0(g0),.gfx1(g1),.sample_addr(sa),.sample_data(sd),.pen_addr(pen),.indirect(indirect),.color_addr(indirect[4:0]),.color_data(color));
  appoooh_video #(.NMI_LINE(NMI_LINE),.NMI_X(NMI_X),.FRAME_ORIGIN(FRAME_ORIGIN)) video(.clk(clk),.reset(!running),.ce(video_ce),.flip(flip),.robowres_mode(robowres_mode),.prio(render_prio),.va(va),.vd(vd),.ga(ga),.gfx0(g0),.gfx1(g1),.pen(pen),.color(color),.red(red),.green(green),.blue(blue),.hs(hs),.vs(vs),.hblank(hblank),.vblank(vblank),.pixel_ce(pixel_ce),.frame_event(frame_event),.debug_x(debug_x),.debug_y(debug_y),.deadline_error(deadline_error));
  appoooh_sound sound(.clk(clk),.reset(!running),.psg_ce(cpu_ce),.adpcm_ce(adpcm_ce),.io_write(io_write&&running),.port_addr(addr[7:0]),.data(dout),.sample_addr(sa),.sample_data(sd),.audio(audio),.psg0(psg0),.psg1(psg1),.psg2(psg2),.adpcm(adpcm),.sample_strobe(),.sample_position());
 assign debug_addr=addr;assign debug_data=dout;assign debug_io_write=io_write&&running;
 assign debug_mem_write=mem_write&&running;assign debug_fetch=!m1_n&&!rd_n&&!mreq_n;
 assign debug_nmi=!nmi_n;assign debug_halt=!halt_n;
 logic [8:0] pen_pipe[0:2];
 always_ff @(posedge clk)begin pen_pipe[0]<=pen;pen_pipe[1]<=pen_pipe[0];pen_pipe[2]<=pen_pipe[1];end
 assign debug_pen=pen_pipe[2];
endmodule
