// SPDX-License-Identifier: GPL-3.0-or-later
module spy_main #(parameter integer CPU_DIVIDER=16) (
    input logic clk, reset, pause, irq_n,
    output wire [17:0] rom_addr,
    output wire rom_cs,
    input logic [7:0] rom_dout,
    input logic rom_ok,
    output wire tile_cs, obj_cs, gfx_we, pal_cs, pal_we,
    output wire [13:0] gfx_addr,
    output wire [15:0] cpu_addr,
    output wire [7:0] cpu_dout,
    output wire cpu_rnw, cpu_transfer,
    input logic [7:0] tile_dout, obj_dout, pal_dout,
    input logic tile_ok,
    input logic [7:0] system_in, p1_in, p2_in, dip1, dip2,
    output wire [7:0] sound_latch,
    output wire sound_irq, watchdog_reset, rmrd, video_enable,
    output wire [1:0] coin_counter,
    output wire pmc_irq_n,
    output wire [111:0] cpu_registers,
    output wire [7:0] control_state,
    input logic state_bank, state_we,
    input logic [12:0] state_addr,
    input logic [7:0] state_din,
    output wire [7:0] state_dout,
    output wire state_grant
);
    wire [7:0] cpu_din, work_dout, pmc_dout, pmc_ram_cpu, pmc_ram_read, pmc_ram_write;
    wire ready, work_cs, work_we, pmc_cs, pmc_we, pmc_host_write;
    wire [12:0] work_addr, pmc_ram_addr;
    wire pmc_write, pmc_bk, pmc_start;
    logic [1:0] pmc_phase;
    wire pmc_cen = !pause && pmc_phase == 0;
    // GX857 schematic U29 pin20 M12 receives12MHz:48MHz master /4.
    always_ff @(posedge clk) begin
        if(reset) pmc_phase <= 0;
        else if(!pause) pmc_phase <= pmc_phase + 1'b1;
    end
    spy_cpu #(.CLOCK_DIVIDER(CPU_DIVIDER)) u_cpu (
        .clk(clk), .reset(reset), .pause(pause), .din(cpu_din), .ready(ready),
        .irq_n(irq_n), .firq_n(pmc_irq_n), .addr(cpu_addr), .dout(cpu_dout),
        .rnw(cpu_rnw), .transfer(cpu_transfer), .opcode(), .registers(cpu_registers));
    spy_bus u_bus (
        .clk(clk), .reset(reset), .pause(pause), .transfer(cpu_transfer),
        .rnw(cpu_rnw), .addr(cpu_addr), .dout(cpu_dout), .din(cpu_din), .ready(ready),
        .rom_cs(rom_cs), .rom_addr(rom_addr), .rom_dout(rom_dout), .rom_ok(rom_ok),
        .work_cs(work_cs), .work_we(work_we), .work_addr(work_addr), .work_dout(work_dout),
        .pal_cs(pal_cs), .pal_we(pal_we), .pal_dout(pal_dout),
        .pmc_cs(pmc_cs), .pmc_we(pmc_we), .pmc_dout(pmc_dout),
        .tile_cs(tile_cs), .obj_cs(obj_cs), .gfx_we(gfx_we), .gfx_addr(gfx_addr),
        .tile_dout(tile_dout), .obj_dout(obj_dout), .tile_ok(tile_ok),
        .system_in({system_in[7:4],pmc_irq_n,system_in[2:0]}),
        .p1_in(p1_in), .p2_in(p2_in), .dip1(dip1), .dip2(dip2),
        .sound_latch(sound_latch), .sound_irq(sound_irq), .watchdog_reset(watchdog_reset),
        .rmrd(rmrd), .pmc_bk(pmc_bk), .pmc_start(pmc_start), .video_enable(video_enable),
        .coin_counter(coin_counter), .rom_bank(), .control_state(control_state));
    assign state_grant = pause;
    assign state_dout = state_bank ? pmc_ram_cpu : work_state;
    wire [7:0] work_state;
    jtframe_dual_ram #(.AW(13)) u_work (
        .clk0(clk), .data0(cpu_dout), .addr0(work_addr), .we0(work_we), .q0(work_dout),
        .clk1(clk), .data1(state_din), .addr1(state_addr),
        .we1(pause && state_we && !state_bank), .q1(work_state));
    jt052591 u_pmc (
        .rst(reset), .clk(clk), .cen(pmc_cen), .cs(pmc_cs), .cpu_we(pmc_we),
        .cpu_addr({2'b0,cpu_addr[10:0]}), .cpu_dout(cpu_dout),
        .cpu_ram_dout(pmc_ram_cpu), .cpu_din(pmc_dout), .cpu2ram_we(pmc_host_write),
        .ram_addr(pmc_ram_addr), .ram_din(pmc_ram_write), .ram_we(pmc_write),
        .ram_oe(), .ram_dout(pmc_ram_read), .bk(pmc_bk), .start(pmc_start),
        .out0(pmc_irq_n), .st_dout());
    // EA12:11 are not connected on GX857: the external RAM is 2 KiB.
    jtframe_dual_ram #(.AW(11)) u_pmc_ram (
        .clk0(clk), .data0(pause && state_bank ? state_din : cpu_dout),
        .addr0(pause && state_bank ? state_addr[10:0] : cpu_addr[10:0]),
        .we0(pause ? state_we && state_bank : pmc_host_write), .q0(pmc_ram_cpu),
        .clk1(clk), .data1(pmc_ram_write), .addr1(pmc_ram_addr[10:0]),
        .we1(pmc_write && !pause), .q1(pmc_ram_read));
endmodule
