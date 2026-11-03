// SPDX-License-Identifier: GPL-3.0-or-later
// Air Buster renderer (airbustr.cpp screen_update): bg tilemap (opaque,
// colours 256-511), fg tilemap (pen 0 transparent, colours 0-255), then the
// Pandora sprite bitmap (pen 0 transparent, colours 512-767). Palette is
// xGRB_555. Raster events come from the caller; no timing is invented here.
module airbustr_video (
    input logic clk, reset, eof, vis_start, prepare_line, line_commit,
    input logic [7:0] prepare_y,
    // per-frame latched scroll registers (raw port values)
    input logic [7:0] scroll_x0, scroll_y0, scroll_x1, scroll_y1, scroll_high_n,
    input logic game_flip, sprite_clear,
    input logic rotate_180,
    input logic [7:0] scan_x,scan_y,
    input logic scan_valid,
    output logic pixel_valid,
    output logic [23:0] rgb,
    output logic line_ready, line_pending, tile_busy, object_busy, object_hold,
    output logic object_completed,
    output logic [31:0] object_pass_cycles,
    output logic [15:0] object_late_swaps,
    output logic [9:0] objects_done,
    output logic [8:0] object_addr,
    input logic [63:0] object_data,
    output logic [9:0] bg_tile_addr, fg_tile_addr,
    input logic [7:0] bg_tile_code, bg_tile_attr, fg_tile_code, fg_tile_attr,
    output logic [9:0] palette_addr,
    input logic [15:0] palette_data,
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
    logic [7:0] x,y,bg,fg,obj;
    logic [3:0] valid_delay;
    logic unused_page;
    logic bg_ready, fg_ready, bg_pending, fg_pending, bg_busy, fg_busy;
    assign x = rotate_180 ? ~scan_x : scan_x;
    assign y = rotate_180 ? ~scan_y : scan_y;
    wire [7:0] map_y = rotate_180 ? ~prepare_y : prepare_y;   // bitmap row being prepared
    wire [7:0] highbits = ~scroll_high_n;                     // port 0C is complemented
    wire [8:0] sx0 = {highbits[2],scroll_x0}, sy0 = {highbits[3],scroll_y0};
    wire [8:0] sx1 = {highbits[0],scroll_x1}, sy1 = {highbits[1],scroll_y1};
    // MAME tilemap scrolldx(0x094,0x06a), scrolldy(0x100,0x1ff), 512x512 map:
    //   normal  src_x = scroll + x - 0x94,   src_y = scroll + y - 0x100
    //   flipped src_x = scroll + 0x95 - x,   src_y = scroll + 0x100 - y
    wire [8:0] bg_start_x = game_flip ? sx0 + 9'h095 : sx0 - 9'h094;
    wire [8:0] fg_start_x = game_flip ? sx1 + 9'h095 : sx1 - 9'h094;
    wire [8:0] bg_start_y = game_flip ? sy0 + 9'h100 - {1'b0,map_y} : sy0 + 9'h100 + {1'b0,map_y};
    wire [8:0] fg_start_y = game_flip ? sy1 + 9'h100 - {1'b0,map_y} : sy1 + 9'h100 + {1'b0,map_y};

    // Two layer engines share one tile-ROM channel, one request outstanding.
    logic bg_req, fg_req, bg_rsp, fg_rsp, owner, owned;
    logic [18:0] bg_addr, fg_addr;
    wire grant_bg = !owned && bg_req;
    wire grant_fg = !owned && !bg_req && fg_req;
    assign tile_req_valid = !owned && (bg_req || fg_req);
    assign tile_req_addr = bg_req ? bg_addr : fg_addr;
    wire bg_ready_in = grant_bg && tile_req_ready;
    wire fg_ready_in = grant_fg && tile_req_ready;
    assign bg_rsp = owned && owner == 1'b0 && tile_rsp_valid;
    assign fg_rsp = owned && owner == 1'b1 && tile_rsp_valid;
    always_ff @(posedge clk) begin
        if (reset) begin owned <= 0; owner <= 0; end
        else if (!owned && tile_req_valid && tile_req_ready) begin owned <= 1; owner <= !bg_req; end
        else if (owned && tile_rsp_valid) owned <= 0;
    end

    airbustr_tilemap bg_map(.clk,.reset,.prepare_line,.line_commit,
        .start_x(bg_start_x),.start_y(bg_start_y),.flip(game_flip),
        .busy(bg_busy),.line_ready(bg_ready),.line_pending(bg_pending),
        .tile_addr(bg_tile_addr),.tile_code(bg_tile_code),.tile_attr(bg_tile_attr),
        .rom_req_valid(bg_req),.rom_req_ready(bg_ready_in),.rom_req_addr(bg_addr),
        .rom_rsp_valid(bg_rsp),.rom_rsp_data(tile_rsp_data),.rd_x(x),.rd_pix(bg));
    airbustr_tilemap fg_map(.clk,.reset,.prepare_line,.line_commit,
        .start_x(fg_start_x),.start_y(fg_start_y),.flip(game_flip),
        .busy(fg_busy),.line_ready(fg_ready),.line_pending(fg_pending),
        .tile_addr(fg_tile_addr),.tile_code(fg_tile_code),.tile_attr(fg_tile_attr),
        .rom_req_valid(fg_req),.rom_req_ready(fg_ready_in),.rom_req_addr(fg_addr),
        .rom_rsp_valid(fg_rsp),.rom_rsp_data(tile_rsp_data),.rd_x(x),.rd_pix(fg));
    assign tile_busy = bg_busy || fg_busy;
    assign line_pending = bg_pending && fg_pending;
    assign line_ready = bg_ready || fg_ready;

    airbustr_pandora pandora(.clk,.reset,.eof,.vis_start,.clear_bitmap(sprite_clear),.flip_screen(game_flip),
        .object_addr,.object_data,.cpu_hold(object_hold),
        .rom_req_valid(object_req_valid),.rom_req_ready(object_req_ready),.rom_req_addr(object_req_addr),
        .rom_rsp_valid(object_rsp_valid),.rom_rsp_last(object_rsp_last),.rom_rsp_data(object_rsp_data),.rd_x(x),.rd_y(y),.rd_pix(obj),
        .busy(object_busy),.completed(object_completed),.display_page(unused_page),
        .pass_cycles(object_pass_cycles),.late_swaps(object_late_swaps),.objects_done);
    wire [4:0] pr = palette_data[9:5], pg = palette_data[14:10], pb = palette_data[4:0];
    always_ff @(posedge clk) begin
        palette_addr <= obj[3:0] != 0 ? {2'b10,obj} : fg[3:0] != 0 ? {2'b00,fg} : {2'b01,bg};
        rgb <= {pr,pr[4:2],pg,pg[4:2],pb,pb[4:2]};
        valid_delay <= reset ? 4'b0 : {valid_delay[2:0],scan_valid};
    end
    assign pixel_valid = valid_delay[3];
endmodule
