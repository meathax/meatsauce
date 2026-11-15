// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated P4 renderer. Caller supplies raster events; no native CRT totals,
// oscillator or fractional pixel enable is inferred from MAME's58Hz profile.
module heavyunit_video (
    input logic clk, reset, eof, vis_start, prepare_line, line_commit,
    input logic [7:0] prepare_y,
    input logic [8:0] scroll_x,scroll_y,
    input logic rotate_180,
    input logic [7:0] scan_x,scan_y,
    input logic scan_valid,
    output logic pixel_valid,
    output logic [23:0] rgb,
    output logic [8:0] pixel_index,
    output logic line_ready, line_pending, tile_busy, object_busy, object_hold,
    output logic object_completed,
    output logic [31:0] object_pass_cycles,
    output logic [15:0] object_late_swaps,
    output logic [9:0] objects_done,
    output logic [8:0] object_addr,
    input logic [63:0] object_data,
    output logic [9:0] tile_addr,
    input logic [7:0] tile_code,tile_attr,
    output logic [8:0] palette_addr,
    input logic [7:0] palette_low,palette_ext,
    output logic object_req_valid,
    input logic object_req_ready,
    output logic [20:0] object_req_addr,
    input logic object_rsp_valid,object_rsp_last,
    input logic [63:0] object_rsp_data,
    output logic tile_req_valid,
    input logic tile_req_ready,
    output logic [18:0] tile_req_addr,
    input logic tile_rsp_valid,
    input logic [63:0] tile_rsp_data
);
    logic [7:0] x,y,bg,obj;
    logic [3:0] valid_delay;
    logic [8:0] index_delay;
    logic unused_page;
    assign x = rotate_180 ? ~scan_x : scan_x;
    assign y = rotate_180 ? ~scan_y : scan_y;
    heavyunit_tilemap tilemap(.clk,.reset,.prepare_line,.line_commit,
        .prepare_y(rotate_180 ? ~prepare_y : prepare_y),.scroll_x,.scroll_y,
        .busy(tile_busy),.line_ready,.line_pending,.tile_addr,.tile_code,.tile_attr,
        .rom_req_valid(tile_req_valid),.rom_req_ready(tile_req_ready),.rom_req_addr(tile_req_addr),
        .rom_rsp_valid(tile_rsp_valid),.rom_rsp_data(tile_rsp_data),.rd_x(x),.rd_pix(bg));
    heavyunit_pandora pandora(.clk,.reset,.eof,.vis_start,.clear_bitmap(1'b1),
        .object_addr,.object_data,.cpu_hold(object_hold),
        .rom_req_valid(object_req_valid),.rom_req_ready(object_req_ready),.rom_req_addr(object_req_addr),
        .rom_rsp_valid(object_rsp_valid),.rom_rsp_last(object_rsp_last),.rom_rsp_data(object_rsp_data),.rd_x(x),.rd_y(y),.rd_pix(obj),
        .busy(object_busy),.completed(object_completed),.display_page(unused_page),
        .pass_cycles(object_pass_cycles),.late_swaps(object_late_swaps),.objects_done);
    always_ff @(posedge clk) begin
        palette_addr <= obj[3:0] != 0 ? {1'b1,obj} : {1'b0,bg};
        index_delay <= palette_addr;
        pixel_index <= index_delay;
        rgb <= {{2{palette_ext[3:0]}},{2{palette_low[7:4]}},{2{palette_low[3:0]}}};
        valid_delay <= reset ? 4'b0 : {valid_delay[2:0],scan_valid};
    end
    assign pixel_valid = valid_delay[3];
endmodule
