// SPDX-License-Identifier: GPL-3.0-or-later
// Main and sound processors on one 48.8336-MHz game master with enables.
// 400 x 256 at 48.8336/8 MHz = 59.611 Hz, matching the frame rate measured from
// real-PCB attract footage (capture-frame beat, docs/pcb-refresh-measurement.md).
// The raw H/V totals remain the MAME-shaped 400 x 256 fixture; only the
// master is retimed. Enables keep Z80 = 4.000 MHz and T5182/YM2151 = 3.579545 MHz.
// For the MAME 60.000-Hz fixture (49.152 MHz master): 125/1536, 715909/9830400.
// MAME screen.cpp begins its reference epoch at vblank start (line 240).
// This reset phase aligns cold-boot comparisons; it is not a PCB measurement.
module darkmist_board #(
    parameter [7:0] INITIAL_RASTER_Y = 8'd240,
    parameter integer MAIN_STEP = 2500,      // 4,000,000 / 1600
    parameter integer MAIN_MOD = 30521,      // 48,833,600 / 1600
    parameter integer SOUND_STEP = 715909,   // 3,579,545 / 5
    parameter integer SOUND_MOD = 9766720    // 48,833,600 / 5
) (
    input wire clk, reset, pause,
    output wire paused,
    input wire hs_access,hs_we,
    input wire [11:0] hs_addr,
    input wire [7:0] hs_data,
    input wire [7:0] p1,p2,starts,dip1,dip2,unknown_inputs,
    input wire [1:0] coins,
    output wire main_rom_req, main_rom_opcode,
    output wire [16:0] main_rom_addr,
    input wire main_rom_valid,
    input wire [7:0] main_rom_data,
    output wire sound_rom_req, sound_rom_external,
    output wire [14:0] sound_rom_addr,
    input wire sound_rom_valid,
    input wire [7:0] sound_rom_data,
    input wire [2:0] video_region,
    input wire [11:0] video_addr,debug_addr,
    output wire [7:0] video_data,debug_data,
    input wire [6:0] sprite_desc_index,
    output wire [31:0] sprite_desc_data,
    input wire [9:0] text_tile_index,
    output wire [15:0] text_tile_data,
    input wire [7:0] color_index,
    output wire [11:0] color_rgb,
    output wire [15:0] bg_scroll_x,bg_scroll_y,fg_scroll_x,fg_scroll_y,
    output wire [7:0] hardware_control,sprite_bank,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_sample,
    output wire trace_main_write,trace_sound_write,trace_sound_io,
    output wire [15:0] trace_main_addr,trace_sound_addr,
    output wire [7:0] trace_main_data,trace_sound_data,
    output wire [15:0] main_cpu_addr,sound_cpu_addr,
    output wire [2:0] sound_irq_state,
    output wire [7:0] unknown_port40,unknown_port50,
    output wire sound_io_read,sound_irq_ack,sound_fetch,sound_bus_cen,
    output wire [7:0] sound_cpu_din,
    output wire ce_pixel,
    output reg [8:0] raster_x,
    output reg [7:0] raster_y
);
    reg [14:0] main_acc;
    wire [15:0] main_sum = {1'b0,main_acc} + 16'(MAIN_STEP);
    wire main_cen = main_sum >= 16'(MAIN_MOD);
    reg [23:0] sound_acc;
    wire [24:0] sound_sum = {1'b0,sound_acc} + 25'(SOUND_STEP);
    wire sound_cen = sound_sum >= 25'(SOUND_MOD);
    assign sound_bus_cen = sound_cen && !pause;
    reg ym_phase;
    wire ym_p1 = sound_cen && ym_phase;
    reg [2:0] pixel_div;
    assign ce_pixel = pixel_div == 3'd7;
    wire scanline_tick = ce_pixel && raster_x == 9'd0;
    always @(posedge clk) begin
        if (reset) begin
            main_acc <= 15'd0;
            sound_acc <= 24'd0;
            ym_phase <= 1'b0;
            pixel_div <= 3'd0;
            raster_x <= 9'd0;
            raster_y <= INITIAL_RASTER_Y;
        end else begin
            // Game execution pauses; the display clock and raster must stay alive.
            if (!pause) begin
                main_acc <= main_cen ? 15'(main_sum - 16'(MAIN_MOD)) : main_sum[14:0];
                sound_acc <= sound_cen ? 24'(sound_sum - 25'(SOUND_MOD)) : sound_sum[23:0];
                if (sound_cen) ym_phase <= !ym_phase;
            end
            pixel_div <= pixel_div + 3'd1;
            if (ce_pixel) begin
                if (raster_x == 9'd399) begin
                    raster_x <= 9'd0;
                    raster_y <= raster_y + 8'd1;
                end else raster_x <= raster_x + 9'd1;
            end
        end
    end
    darkmist_pause_ack pause_ack(.clk(clk),.reset(reset),.request(pause),.paused(paused));
    wire [6:0] host_addr;
    wire [7:0] host_out,host_in;
    wire host_write,host_irq,main_acquire,main_release,sound_semaphore;
    wire unused_paused,unused_m1,unused_mreq,unused_iorq,unused_rd,unused_wr;
    wire [7:0] unused_dout;
    darkmist_main main_cpu (
        .clk(clk),.reset(reset),.cpu_cen(main_cen),.pause(pause),
        .scanline_tick(scanline_tick && !pause),.scanline(raster_y),
        .p1(p1),.p2(p2),.starts(starts),.dip1(dip1),.dip2(dip2),
        .unknown_inputs(unknown_inputs),.rom_req(main_rom_req),
        .rom_addr(main_rom_addr),.rom_opcode(main_rom_opcode),
        .rom_valid(main_rom_valid),.rom_data(main_rom_data),
        .sound_host_addr(host_addr),.sound_host_dout(host_out),.sound_host_din(host_in),
        .sound_semaphore(sound_semaphore),.sound_host_write(host_write),
        .sound_irq(host_irq),.main_sem_acquire(main_acquire),.main_sem_release(main_release),
        .hardware_control(hardware_control),.sprite_bank(sprite_bank),
        .video_region(video_region),.video_addr(video_addr),.video_data(video_data),
        .sprite_desc_index(sprite_desc_index),.sprite_desc_data(sprite_desc_data),
        .text_tile_index(text_tile_index),.text_tile_data(text_tile_data),
        .color_index(color_index),.color_rgb(color_rgb),
        .bg_scroll_x(bg_scroll_x),.bg_scroll_y(bg_scroll_y),
        .fg_scroll_x(fg_scroll_x),.fg_scroll_y(fg_scroll_y),
        .hs_access(hs_access && paused),.hs_we(hs_we),.hs_addr(hs_addr),.hs_data(hs_data),
        .debug_addr(debug_addr),.debug_data(debug_data),.paused(unused_paused),
        .cpu_addr(main_cpu_addr),.cpu_dout(unused_dout),.cpu_m1_n(unused_m1),
        .cpu_mreq_n(unused_mreq),.cpu_iorq_n(unused_iorq),.cpu_rd_n(unused_rd),
        .cpu_wr_n(unused_wr),.trace_write(trace_main_write),
        .trace_addr(trace_main_addr),.trace_data(trace_main_data)
    );
    darkmist_t5182 sound_cpu (
        .clk(clk),.reset(reset),.cpu_cen(sound_cen),.ym_cen(sound_cen),
        .ym_cen_p1(ym_p1),.pause(pause),.coins(coins),
        .host_addr(host_addr),.host_dout(host_out),.host_din(host_in),
        .host_write(host_write),.host_irq(host_irq),
        .main_sem_acquire(main_acquire),.main_sem_release(main_release),
        .sound_semaphore(sound_semaphore),.rom_req(sound_rom_req),
        .rom_external(sound_rom_external),.rom_addr(sound_rom_addr),
        .rom_valid(sound_rom_valid),.rom_data(sound_rom_data),
        .audio_left(audio_left),.audio_right(audio_right),.audio_sample(audio_sample),
        .cpu_addr(sound_cpu_addr),.trace_write(trace_sound_write),
        .trace_io(trace_sound_io),.trace_addr(trace_sound_addr),.trace_data(trace_sound_data),
        .irq_state(sound_irq_state),.unknown_port40(unknown_port40),
        .unknown_port50(unknown_port50),.debug_io_read(sound_io_read),
        .debug_irq_ack(sound_irq_ack),.debug_fetch(sound_fetch),.debug_din(sound_cpu_din)
    );
endmodule
