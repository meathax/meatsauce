// SPDX-License-Identifier: GPL-3.0-or-later
// Penguin wrapper; derivative provenance is recorded in penguin_dx101_video.sv.
// H_TOTAL/V_TOTAL defaults are a synthetic MAME-reference geometry, not PCB timing.
module penguin_video #(
    parameter bit REGISTERED_SCAN_BLANK=1'b0,
    parameter integer ACTIVE_WIDTH=320,
    parameter integer ACTIVE_HEIGHT=224,
    parameter integer H_TOTAL=512,
    parameter integer V_TOTAL=256
)(
    input logic clk, reset, ce_pix,
    input logic [8:0] h_count, v_count,
    input logic hblank, vblank,
    input logic scan_line_active, scan_next_line_active,
    input logic [15:0] control,
    input logic rotate_180,
    input logic [26:0] video_x_offset, video_x_zoom, video_y_offset, video_y_zoom,
    input logic video_x_half_mode, video_x_fractional_mode,
    input logic raster_active,
    input logic rowscroll_override_valid,
    input logic [14:0] rowscroll_override_record,
    input logic [15:0] rowscroll_override_data,
    input logic rowscroll_seed_valid,
    input logic [15:0] rowscroll_seed_data,
    input logic rowscroll_live_valid,
    input logic [14:0] rowscroll_live_record,
    input logic [15:0] rowscroll_live_data,
    output logic [16:0] sprite_address,
    input logic [63:0] sprite_q,
    input logic [15:0] sprite_seed_q,
    output logic [14:0] palette_address,
    input logic [15:0] palette_q,
    output logic [24:0] gfx_addr,
    output logic gfx_req,
    input logic [63:0] gfx_dout,
    input logic gfx_ack,
    output logic [7:0] red, green, blue,
    output logic busy, line_done,
    output logic [15:0] missed_lines,
    output logic [8:0] rowscroll_lookup_line
);
    penguin_dx101_video #(.REGISTERED_SCAN_BLANK(REGISTERED_SCAN_BLANK),.AHEAD_RENDER(1'b1),.ACTIVE_WIDTH(ACTIVE_WIDTH),
        .ACTIVE_HEIGHT(ACTIVE_HEIGHT),.H_TOTAL(H_TOTAL),.V_TOTAL(V_TOTAL)) engine(
        .clk,.reset,.ce_pix,.h_count,.v_count,.hblank,.vblank,.video_control(control),
        .scan_line_active,.scan_next_line_active,
        .rotate_180,.video_x_offset,.video_x_zoom,.video_x_half_mode,.video_x_fractional_mode,.video_y_offset,.video_y_zoom,
        .raster_active,.rowscroll_override_valid,.rowscroll_override_record,
        .rowscroll_override_data,.rowscroll_seed_valid,.rowscroll_seed_data,
        .rowscroll_live_valid,.rowscroll_live_record,.rowscroll_live_data,
        .sprite_address,.sprite_q,.sprite_seed_q,.palette_address,.palette_q,
        .gfx_addr,.gfx_req,.gfx_dout,.gfx_ack,.red,.green,.blue,
        .busy,.line_done,.missed_lines,.rowscroll_lookup_line);
`ifndef SYNTHESIS
    initial begin
        if (ACTIVE_WIDTH != 320 || ACTIVE_HEIGHT != 224 || ACTIVE_WIDTH%8)
            $fatal(1,"Penguin geometry contract requires320x224 and whole8-pixel lanes");
        if (H_TOTAL>512 || V_TOTAL>512 || H_TOTAL<=ACTIVE_WIDTH || V_TOTAL<=ACTIVE_HEIGHT)
            $fatal(1,"Geometry exceeds9-bit counts or lacks blanking");
    end
`endif
endmodule
