// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ns
module hangzo_main #(parameter HISCORE_SUPPORTED=0, SCHMEISER_SUPPORTED=0) (
    input wire game_id,
    input wire clk, reset, pause, vblank,
    input wire [15:0] player_inputs, dips,
    input wire [7:0] dips3,
    input wire [2:0] coin_service,
    output wire rom_request,
    output wire [19:1] rom_address,
    input wire rom_ready,
    input wire [15:0] rom_data,
    // Video owns its VRAM, row RAM, sprite RAM and palette. This port is held
    // until ready; a future SDRAM/renderer stalls it through the same contract.
    output wire video_request,
    output reg [3:0] video_region,
    output reg [12:1] video_offset,
    output wire video_write,
    output wire [1:0] video_byte_enable,
    output wire [15:0] video_write_data,
    input wire video_ready,
    input wire [15:0] video_read_data,
    input wire sprite_copy_ready, palette_copy_ready,
    output wire sprite_copy, palette_copy,
    output reg [15:0] priority_control,
    output wire [7:0] sound_data,
    output wire sound_write,
    // Accepted CPU bus observations, including internal RAM and protection.
    output wire bus_accepted, bus_write,
    output wire [23:0] bus_address,
    output wire [1:0] bus_byte_enable,
    output wire [15:0] bus_write_data, bus_read_data,
    output wire [2:0] bus_function_code,
    output wire phase1, phase2, halted,
    output reg irq_pending,
    input wire hiscore_pause_request,hiscore_request,hiscore_write,
    input wire [14:0] hiscore_byte_address,
    input wire [7:0] hiscore_write_data,
    output wire hiscore_paused,hiscore_initialized,hiscore_ack,hiscore_fault,
    output wire [7:0] hiscore_read_data
`ifdef VERILATOR
    ,output wire [11:0] debug_cpu_credit,
    output wire [63:0] debug_cpu_ticks,debug_cpu_pairs,debug_cpu_dropped
`endif
);
    wire request, acknowledge;
    wire cpu_pause_ack;
    // Do not stop initialization merely because the frontend wants a restore.
    wire cpu_pause = pause || (HISCORE_SUPPORTED && hiscore_pause_request && hiscore_initialized);
    wire [15:0] cpu_read;
    wire [15:0] system_port = {12'd0, vblank, coin_service};
    hangzo_cpu u_cpu (
        .clk(clk), .reset(reset), .pause(cpu_pause), .irq6(irq_pending),
        .request(request), .address(bus_address), .write(bus_write),
        .byte_enable(bus_byte_enable), .write_data(bus_write_data),
        .acknowledge(acknowledge), .read_data(cpu_read),
        .function_code(bus_function_code), .phase1(phase1), .phase2(phase2), .halted(halted), .pause_ack(cpu_pause_ack)
`ifdef VERILATOR
        ,.debug_credit(debug_cpu_credit),.debug_ticks(debug_cpu_ticks),
        .debug_pairs(debug_cpu_pairs),.debug_dropped(debug_cpu_dropped)
`endif
    );
    wire is_rom = bus_address < 24'h100000;
    wire work_schmeiser = SCHMEISER_SUPPORTED && game_id;
    wire is_work = work_schmeiser ?
        (bus_address >= 24'hff0000 && bus_address <= 24'hff7ffe) :
        (bus_address >= 24'h3f0000 && bus_address <= 24'h3f3ffe);
    wire is_protection = bus_address >= 24'h280000 && bus_address <= 24'h283ffe;
    wire read_dips3 = bus_address == 24'h2c0000 || bus_address == 24'h300000;
    wire read_system = bus_address == 24'h310002;
    wire sprite_dma = bus_address == 24'h300000;
    wire palette_dma = bus_address == 24'h31000a;
    wire priority_write = bus_address == 24'h322000;
    wire irq_ack = bus_address == 24'h321100;
    wire video_mapped = video_region != 0;
    always @* begin
        video_region = 0;
        video_offset = bus_address[12:1];
        if (bus_address >= 24'h200000 && bus_address <= 24'h20000e && bus_write)
            video_region = 1;
        else if (bus_address >= 24'h240000 && bus_address <= 24'h24000e && bus_write)
            video_region = 2;
        else if (bus_address >= 24'h3c0000 && bus_address <= 24'h3c1ffe)
            video_region = 3;
        else if (bus_address >= 24'h3c2000 && bus_address <= 24'h3c2ffe)
            video_region = 4;
        else if (bus_address >= 24'h3c4000 && bus_address <= 24'h3c4ffe)
            video_region = 5;
        else if (bus_address >= 24'h3c6000 && bus_address <= 24'h3c6ffe)
            video_region = 6;
        else if (bus_address >= 24'h3c8000 && bus_address <= 24'h3c9ffe)
            video_region = 7;
        else if (bus_address >= 24'h3ca000 && bus_address <= 24'h3cfffe) begin
            video_region = 4'd8 + {2'd0, bus_address[14:13]} - 4'd1;
            video_offset = {1'b0, bus_address[11:1]};
        end else if (bus_address >= 24'h3d0000 && bus_address <= 24'h3d07fe) begin
            video_region = 11;
            video_offset = {2'd0, bus_address[10:1]};
        end else if (bus_address >= 24'h3e0000 && bus_address <= 24'h3e3ffe)
            video_region = 12;
        // Regions4..6 have a4KiB window, not the8KiB tile0/row0 window.
        if (video_region >= 4 && video_region <= 6)
            video_offset = {1'b0, bus_address[11:1]};
    end
    wire cached_rom_ready;
    wire [15:0] cached_rom_data;
    hangzo_rom_cache u_program_cache (
        .clk(clk),.reset(reset),.request(request && is_rom && !bus_write),
        .address(bus_address[19:1]),.ready(cached_rom_ready),.data(cached_rom_data),
        .memory_request(rom_request),.memory_address(rom_address),
        .memory_ready(rom_ready),.memory_data(rom_data)
    );
    assign video_request = request && video_mapped;
    assign video_write = bus_write;
    assign video_byte_enable = bus_byte_enable;
    assign video_write_data = bus_write_data;

    reg [1:0] age;
    always @(posedge clk) begin
        if (reset || !request) age <= 0;
        else if (age != 3) age <= age + 2'd1;
    end
    wire [15:0] work_data;
    wire [13:0] score_ram_address;
    wire [15:0] score_ram_data,score_ram_q;
    wire [1:0] score_ram_we;
    wire [1:0] work_we = {2{request && is_work && bus_write && age == 0}} & bus_byte_enable;
    localparam integer WORK_AW = SCHMEISER_SUPPORTED ? 14 : 13;
    wire [WORK_AW-1:0] score_ram_full_address = score_ram_address[WORK_AW-1:0];
    jtframe_dual_ram16 #(.AW(WORK_AW)) u_work (
        .clk0(clk), .addr0(bus_address[WORK_AW:1]), .data0(bus_write_data), .we0(work_we), .q0(work_data),
        .clk1(clk), .addr1(score_ram_full_address), .data1(score_ram_data), .we1(score_ram_we), .q1(score_ram_q)
    );
    generate if(HISCORE_SUPPORTED) begin: g_hiscore
        wire hg_initialized,sch_initialized;
        wire hg_ack,sch_ack,hg_fault,sch_fault;
        wire [13:0] hg_address,sch_address;
        wire [15:0] hg_data,sch_data;
        wire [1:0] hg_we,sch_we;
        wire [7:0] hg_read,sch_read;
        hangzo_score_initialization initialization_witness(
            .clk(clk),.reset(reset || work_schmeiser),.cpu_accepted(bus_accepted && !work_schmeiser),.cpu_write(bus_write),
            .cpu_address(bus_address),.cpu_byte_enable(bus_byte_enable),.cpu_data(bus_write_data),
            .initialized(hg_initialized));
        assign hiscore_initialized=work_schmeiser ? sch_initialized : hg_initialized;
        assign hiscore_paused=hiscore_initialized && cpu_pause_ack;
        hangzo_score_ram_port #(.BYTE_AW(15)) score_port(
            .clk(clk),.reset(reset || work_schmeiser),.paused(hiscore_paused && !work_schmeiser),.request(hiscore_request && !work_schmeiser),.write(hiscore_write),
            .byte_address(hiscore_byte_address),.write_data(hiscore_write_data),
            .acknowledge(hg_ack),.read_data(hg_read),.fault(hg_fault),
            .ram_address(hg_address),.ram_data(hg_data),.ram_we(hg_we),.ram_q(score_ram_q));
        if(SCHMEISER_SUPPORTED) begin: g_schmeisr
            hangzo_score_initialization #(.TABLE_FIRST(24'hff5a36),.TABLE_LAST_WORD(24'hff5a98),.FIRST_WORD(16'h0010),.LAST_WORD(16'h4c00)) initialization_witness(
                .clk(clk),.reset(reset || !work_schmeiser),.cpu_accepted(bus_accepted && work_schmeiser),.cpu_write(bus_write),
                .cpu_address(bus_address),.cpu_byte_enable(bus_byte_enable),.cpu_data(bus_write_data),.initialized(sch_initialized));
            hangzo_score_ram_port #(.BYTE_AW(15),.TABLE_FIRST(15'h5a36),.TABLE_LAST(15'h5a99)) score_port(
                .clk(clk),.reset(reset || !work_schmeiser),.paused(hiscore_paused && work_schmeiser),.request(hiscore_request && work_schmeiser),.write(hiscore_write),
                .byte_address(hiscore_byte_address),.write_data(hiscore_write_data),
                .acknowledge(sch_ack),.read_data(sch_read),.fault(sch_fault),
                .ram_address(sch_address),.ram_data(sch_data),.ram_we(sch_we),.ram_q(score_ram_q));
        end else begin: g_no_schmeisr
            assign sch_initialized=1'b0;
            assign sch_ack=1'b0;assign sch_read=8'd0;assign sch_fault=1'b0;
            assign sch_address=14'd0;assign sch_data=16'd0;assign sch_we=2'd0;
        end
        assign hiscore_ack=work_schmeiser ? sch_ack : hg_ack;
        assign hiscore_read_data=work_schmeiser ? sch_read : hg_read;
        assign hiscore_fault=work_schmeiser ? sch_fault : hg_fault;
        assign score_ram_address=work_schmeiser ? sch_address : hg_address;
        assign score_ram_data=work_schmeiser ? sch_data : hg_data;
        assign score_ram_we=work_schmeiser ? sch_we : hg_we;
    end else begin: g_no_hiscore
        assign hiscore_initialized=1'b0;
        assign hiscore_paused=1'b0;
        assign hiscore_ack=1'b0;
        assign hiscore_fault=1'b0;
        assign hiscore_read_data=8'd0;
        assign score_ram_address=14'd0;
        assign score_ram_data=16'd0;
        assign score_ram_we=2'd0;
    end endgenerate
    wire protection_ready;
    wire [15:0] protection_data;
    hangzo_deco104 u_protection (
        .clk(clk), .reset(reset), .select(request && is_protection),
        .write(bus_write), .offset(bus_address[13:1]),
        .byte_enable(bus_byte_enable), .write_data(bus_write_data),
        .inputs(player_inputs), .system_inputs(system_port), .dips(dips),
        .ready(protection_ready), .read_data(protection_data),
        .sound_data(sound_data), .sound_write(sound_write)
    );
    assign acknowledge = request && (is_rom && !bus_write ? cached_rom_ready :
        bus_write && sprite_dma ? sprite_copy_ready :
        bus_write && palette_dma ? palette_copy_ready :
        is_work ? age != 0 : is_protection ? protection_ready :
        video_mapped ? video_ready : 1'b1);
    // MAME's 68000 unmapped reads are all ones; no-op writes acknowledge.
    assign cpu_read = is_rom && !bus_write ? cached_rom_data : is_work ? work_data :
        is_protection ? protection_data : video_mapped ? video_read_data :
        read_dips3 ? {8'd0, dips3} : read_system ? system_port : 16'hffff;
    assign bus_read_data = cpu_read;
    assign bus_accepted = request && acknowledge;
    // These are exactly the corresponding MMIO acceptance equations. Keeping
    // them independent of generic video_ready avoids a combinational loop
    // through the source-RAM reservation on the same request edge.
    assign sprite_copy = request && bus_write && sprite_dma && sprite_copy_ready;
    assign palette_copy = request && bus_write && palette_dma && palette_copy_ready;
    reg previous_vblank;
    always @(posedge clk) begin
        if (reset) begin
            previous_vblank <= 0;
            irq_pending <= 0;
            priority_control <= 0;
        end else begin
            previous_vblank <= vblank;
            if (bus_accepted && bus_write && irq_ack) irq_pending <= 0;
            if (vblank && !previous_vblank) irq_pending <= 1;
            if (bus_accepted && bus_write && priority_write) begin
                if (bus_byte_enable[1]) priority_control[15:8] <= bus_write_data[15:8];
                if (bus_byte_enable[0]) priority_control[7:0] <= bus_write_data[7:0];
            end
        end
    end
endmodule
