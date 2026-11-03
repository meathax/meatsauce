// SPDX-License-Identifier: GPL-3.0-or-later
// Memory requests are persistent toggles. Platform/persistence stays outside.
module penguin_board #(
    parameter integer SYS_HZ=100000000,
    parameter integer PIXEL_DIV=16,H_TOTAL=400,V_TOTAL=258,
    parameter bit EXTERNAL_WORK_RAM=1'b1
)(
    input logic clk,cold_reset,reset,pause,
    input logic [15:0] dip_switches,
    input logic [31:0] joystick_p1,joystick_p2,
    input logic service,rotate_180,
    output wire [20:0] rom_addr,
    output wire rom_req,
    input logic [15:0] rom_dout,
    input logic rom_ack,
    output wire [17:0] ram_addr,
    output wire ram_req,ram_write,
    output wire [15:0] ram_data,
    output wire [1:0] ram_be,
    input logic [15:0] ram_dout,
    input logic ram_ack,
    output wire [24:0] gfx_addr,
    output wire gfx_req,
    input logic [63:0] gfx_dout,
    input logic gfx_ack,
    output wire [20:0] sample_addr,
    output wire sample_req,
    input logic [7:0] sample_dout,
    input logic sample_ack,
    output wire [7:0] red,green,blue,
    output wire ce_pix,hsync,vsync,hblank,vblank,
    output wire [8:0] h_count,v_count,
    output wire signed [15:0] audio_left,audio_right,
    output wire audio_valid,
    output wire [15:0] mixer_overruns,missed_lines,
    output wire [31:0] frame_number,debug_bus_cycles,debug_rom_cycles,
    output wire [15:0] debug_unmapped_cycles,
    output wire [23:0] debug_address,
    output wire cpu_running,sprite_buffer_busy,
    output wire [15:0] raster_enable
);
    wire vblank_irq;
    wire scan_line_active, scan_next_line_active;
    penguin_timing #(.SYS_HZ(SYS_HZ),.PIXEL_DIV(PIXEL_DIV),.H_TOTAL(H_TOTAL),.V_TOTAL(V_TOTAL)) timing(
        .clk,.cold_reset,.ce_pix,.h_count,.v_count,.hblank,.vblank,.hsync,.vsync,
        .vblank_irq,.frame_number,.scan_line_active,.scan_next_line_active);
    wire [16:0] sprite_address;
    wire [63:0] sprite_q;
    wire [15:0] sprite_seed_q;
    wire [14:0] palette_address;
    wire [15:0] palette_q,video_control,raster_position;
    wire [26:0] video_x_offset,video_x_zoom,video_y_offset,video_y_zoom;
    wire video_x_half_mode,video_x_fractional_mode;
    wire raster_rearm,raster_irq,rowscroll_write;
    wire [16:0] rowscroll_write_address;
    wire [15:0] rowscroll_write_data;
    wire [1:0] rowscroll_write_byte_enable;
    wire x1_write;
    wire [12:0] x1_address;
    wire [15:0] x1_data,x1_q;
    wire [1:0] x1_byte_enable;
    wire [63:0] sample_banks;
    penguin_cpu_subsystem #(.SYS_HZ(SYS_HZ),.EXTERNAL_WORK_RAM(EXTERNAL_WORK_RAM)) cpu(
        .clk,.reset,.pause,.vblank(vblank_irq),.raster_irq,.dip_switches,
        .joystick_p1,.joystick_p2,.service,.turbo(1'b0),.cheat_reset(1'b0),.cheat_code(129'd0),
        .rom_addr,.rom_req,.rom_dout,.rom_ack,
        .ram_addr,.ram_req,.ram_write,.ram_data,.ram_be,.ram_dout,.ram_ack,
        .sprite_video_address(sprite_address),.sprite_video_q(sprite_q),.sprite_video_seed_q(sprite_seed_q),
        .palette_video_address(palette_address),.palette_video_q(palette_q),
        .video_reg_address(5'd0),.video_reg_q(),.video_control,
        .video_x_offset,.video_x_zoom,.video_x_half_mode,.video_x_fractional_mode,.video_y_offset,.video_y_zoom,.sprite_buffer_busy,
        .raster_enable,.raster_position,.raster_rearm,.rowscroll_write,.rowscroll_write_address,
        .rowscroll_write_data,.rowscroll_write_byte_enable,
        .x1_write,.x1_address,.x1_data,.x1_byte_enable,.x1_q,.sample_banks,
        .debug_address,.debug_bus_cycles,.debug_rom_cycles,.debug_unmapped_cycles,.cpu_running);
    gd_raster_irq raster(
        .clk,.reset,.ce_pix,.h_count,.v_count,.enable(raster_enable[0]),
        .position(raster_position[8:0]),.rearm(raster_rearm),.irq(raster_irq));
    wire video_busy,video_line_done;
    wire [8:0] rowscroll_lookup_line;
    // The private display list is unavailable until the first real CPU buffer
    // completes. Keep the renderer's metadata reset during that startup window;
    // CPU execution, IRQs, raster timing and sound continue normally.
    logic first_sprite_buffer_seen,video_ready;
    always_ff @(posedge clk) begin
        if (reset) begin
            first_sprite_buffer_seen <= 1'b0;
            video_ready <= 1'b0;
        end else begin
            if (sprite_buffer_busy) first_sprite_buffer_seen <= 1'b1;
            if (first_sprite_buffer_seen && !sprite_buffer_busy) video_ready <= 1'b1;
        end
    end
    wire video_reset = reset || !video_ready;
    // No Guardians stage-specific historical heuristics are imported.
    // Penguin raster write behavior remains a gate if observed during play.
    penguin_video #(.REGISTERED_SCAN_BLANK(1'b1),.H_TOTAL(H_TOTAL),.V_TOTAL(V_TOTAL)) video(
        .clk,.reset(video_reset),.ce_pix,.h_count,.v_count,.hblank,.vblank,.control(video_control),
        .scan_line_active,.scan_next_line_active,
        .rotate_180,.video_x_offset,.video_x_zoom,.video_x_half_mode,.video_x_fractional_mode,.video_y_offset,.video_y_zoom,
        .raster_active(raster_enable[0]),.rowscroll_override_valid(1'b0),
        .rowscroll_override_record(15'd0),.rowscroll_override_data(16'd0),
        .rowscroll_seed_valid(1'b0),.rowscroll_seed_data(16'd0),.rowscroll_live_valid(1'b0),
        .rowscroll_live_record(15'd0),.rowscroll_live_data(16'd0),
        .sprite_address,.sprite_q,.sprite_seed_q,.palette_address,.palette_q,
        .gfx_addr,.gfx_req,.gfx_dout,.gfx_ack,.red,.green,.blue,
        .busy(video_busy),.line_done(video_line_done),.missed_lines,.rowscroll_lookup_line);
    penguin_x1_010 #(.SYS_HZ(SYS_HZ)) sound(
        .clk,.reset,.pause,.cpu_write(x1_write),.cpu_address(x1_address),
        .cpu_data(x1_data),.cpu_byte_enable(x1_byte_enable),.cpu_q(x1_q),.sample_banks,
        .sample_addr,.sample_req,.sample_dout,.sample_ack,.audio_left,.audio_right,
        .audio_valid,.mixer_overruns);
endmodule
