// SPDX-License-Identifier: GPL-3.0-or-later
module spy_game (
    input logic clk,reset,pause,
    input logic [7:0] system_in,p1_in,p2_in,dip1,dip2,
    output wire [17:0] main_addr,
    output wire main_cs,
    input logic [7:0] main_data,
    input logic main_ok,
    output wire [16:0] f_addr,a_addr,b_addr,
    output wire [17:0] o_addr,
    output wire f_cs,a_cs,b_cs,o_cs,
    input logic [31:0] f_data,a_data,b_data,o_data,
    input logic a_ok,o_ok,
    output wire [7:0] red,green,blue,
    output wire ce_pix,hs,vs,lhbl,lvbl,
    output wire [8:0] hdump,vdump,
    output wire [15:0] debug_addr,
    output wire [7:0] debug_control,
    output wire [111:0] debug_registers,
    output wire [7:0] sound_latch,
    output wire sound_irq,
    output wire watchdog_expired,
    input logic state_req,state_we,
    input logic [12:0] state_addr,
    input logic [7:0] state_din,
    output wire state_grant,
    output wire [7:0] state_dout
);
    logic [2:0] phase;
    wire pxl_cen=!reset && phase==0, pxl2_cen=!reset && phase[1:0]==0;
    always_ff @(posedge clk) if(reset) phase<=0; else phase<=phase+1'b1;
    wire tile_cs,obj_cs,gfx_we,pal_cs,pal_we,rnw,transfer,rmrd,video_enable,irq_n,tile_ok;
    wire [13:0] gfx_addr;
    wire [7:0] cpu_dout,tile_dout,obj_dout,pal_dout;
    wire watchdog_kick;
    wire game_reset=reset || watchdog_expired;
    spy_watchdog u_watchdog (.clk(clk),.reset(reset),.pause(pause),.kick(watchdog_kick),
        .expired(watchdog_expired),.debug_armed(),.debug_count());
    wire main_state_grant;
    assign state_grant=state_req && main_state_grant;
    spy_main u_main (
        .clk(clk),.reset(game_reset),.pause(pause),.irq_n(irq_n),
        .rom_addr(main_addr),.rom_cs(main_cs),.rom_dout(main_data),.rom_ok(main_ok),
        .tile_cs(tile_cs),.obj_cs(obj_cs),.gfx_we(gfx_we),.pal_cs(pal_cs),.pal_we(pal_we),.gfx_addr(gfx_addr),
        .cpu_addr(debug_addr),.cpu_dout(cpu_dout),.cpu_rnw(rnw),.cpu_transfer(transfer),
        .tile_dout(tile_dout),.obj_dout(obj_dout),.pal_dout(pal_dout),.tile_ok(tile_ok),
        .system_in(system_in),.p1_in(p1_in),.p2_in(p2_in),.dip1(dip1),.dip2(dip2),
        .sound_latch(sound_latch),.sound_irq(sound_irq),.watchdog_reset(watchdog_kick),.rmrd(rmrd),.video_enable(video_enable),
        .coin_counter(),.pmc_irq_n(),.cpu_registers(debug_registers),.control_state(debug_control),
        .state_bank(1'b0),.state_we(state_req && state_we),.state_addr(state_addr),
        .state_din(state_din),.state_dout(state_dout),.state_grant(main_state_grant));
    spy_video u_video (
        .clk(clk),.reset(game_reset),.pxl_cen(pxl_cen),.pxl2_cen(pxl2_cen),.video_enable(video_enable),
        .tile_cs(tile_cs),.obj_cs(obj_cs),.gfx_we(gfx_we),.pal_we(pal_we),.gfx_addr(gfx_addr),.cpu_rnw(rnw),
        .pal_addr(debug_addr[10:0]),.cpu_dout(cpu_dout),.tile_dout(tile_dout),.obj_dout(obj_dout),.pal_dout(pal_dout),
        .rmrd(rmrd),.tile_ok(tile_ok),.irq_n(irq_n),.f_addr(f_addr),.a_addr(a_addr),.b_addr(b_addr),.o_addr(o_addr),
        .f_cs(f_cs),.a_cs(a_cs),.b_cs(b_cs),.o_cs(o_cs),.f_data(f_data),.a_data(a_data),.b_data(b_data),.o_data(o_data),
        .a_ok(a_ok),.o_ok(o_ok),.red(red),.green(green),.blue(blue),.ce_pix(ce_pix),.hs(hs),.vs(vs),
        .lhbl(lhbl),.lvbl(lvbl),.hdump(hdump),.vdump(vdump));
endmodule
