// SPDX-License-Identifier: GPL-3.0-or-later
// DECO141 two-playfield adaptation of JTCORES jtcninja_deco16's source-column
// rendering scheme. See docs/TILES.md for pinned donor provenance and changes.
// Board layouts/control behaviour: MAME 0.289 deco16ic.cpp/simpl156.cpp (BSD-3-Clause).
// One 64-bit ROM read returns both planes of two adjacent glyph rows
// (osman_loader stores the tile ROM row/plane-interleaved). `abort` makes the
// engine finish its outstanding transaction and return to IDLE without a pixel.
module osman_tiles (
    input logic [7:0] profile,
    input logic clk, reset,
    input logic cfg_load, abort,
    output logic cfg_done,
    input logic pixel_req,
    input logic [8:0] pixel_x, pixel_y,
    output logic pixel_ready, pixel_valid,
    output logic [8:0] pf1_index, pf2_index,
    output logic pf1_opaque, pf2_opaque,
    output logic flip_screen,
    output logic state_req,
    output logic [25:0] state_addr,
    input logic state_valid,
    input logic [31:0] state_data,
    output logic tile_req,
    output logic [20:0] tile_byte_addr,
    input logic tile_valid,
    input logic [63:0] tile_data
);
    typedef enum logic [3:0] { IDLE, CFG_ISSUE, CFG_WAIT, PROCESS,
        ROW_WAIT, COL_WAIT, MAP_WAIT, ROM_WAIT } phase_t;
    phase_t phase;
    logic [15:0] control [0:7];
    logic [2:0] cfg_word;
    logic layer;
    logic [8:0] x, y;
    logic [7:0] c0, c1, bank;
    logic [15:0] scrollx, scrolly;
    logic [9:0] sx, sy_base, sy;
    logic [10:0] row_index, col_index, map_index;
    logic [25:0] map_addr, rows_addr;
    logic [15:0] row_value [0:1], col_value [0:1];
    logic [10:0] row_key [0:1], col_key [0:1];
    logic row_valid [0:1], col_valid [0:1];
    logic [25:0] cached_map [0:1];
    logic [3:0] cached_y [0:1];
    logic cached_half [0:1], cached_flipx [0:1], cache_valid [0:1];
    logic [3:0] cached_colour [0:1];
    logic [31:0] cached_planes [0:1];
    logic pending_row0;
    logic [31:0] fetched_planes;
    logic [3:0] pending_colour;
    logic pending_flipx;
    logic [3:0] pen;
    logic [2:0] px;
    logic need_row, need_col, cache_hit;
    logic [15:0] fetched;
    logic [14:0] code;
    logic [3:0] glyph_x, glyph_y;
    logic tile_fx, tile_fy;
    logic [31:0] glyph_offset;
    logic [15:0] sum_x, sum_y, sum_col_y;
    logic active_layer;
    logic [8:0] active_x, active_y;
    logic [2:0] fetched_px;
    logic [3:0] fetched_pen;
    logic [7:0] fast_c0,fast_c1;
    logic [15:0] fast_sum_x,fast_sum_y,fast_sum_col_y;
    logic [9:0] fast_sx,fast_sy_base,fast_sy;
    logic [10:0] fast_row_index,fast_col_index,fast_map_index;
    logic [25:0] fast_map_addr;
    logic fast_need_row,fast_need_col,fast_cache_hit,fast_pf2_ready;
    logic [2:0] fast_px;
    logic [3:0] fast_pen;
    integer i;

    assign pixel_ready = phase == IDLE && !cfg_load;
    assign flip_screen = control[0][7];
    always_comb begin
        // Use accepted coordinates immediately for the first playfield. This
        // removes the capture-only clock on a cached pixel, without accepting
        // another request before pixel_valid/pixel_ready complete the pixel.
        active_layer = phase == IDLE && pixel_req ? 1'b0 : layer;
        active_x = phase == IDLE && pixel_req ? pixel_x : x;
        active_y = phase == IDLE && pixel_req ? pixel_y : y;
        c0 = active_layer ? control[5][15:8] : control[5][7:0];
        c1 = active_layer ? control[6][15:8] : control[6][7:0];
        bank = active_layer ? control[7][15:8] : control[7][7:0];
        scrollx = active_layer ? control[3] : control[1];
        scrolly = active_layer ? control[4] : control[2];
        sum_y = scrolly + (flip_screen ? 16'd255 - {7'd0,active_y} : {7'd0,active_y});
        sy_base = {1'b0,sum_y[8:0]};
        if (c1[7]) sy_base[8] = 0;
        row_index = {1'b0,sy_base} >> c0[6:3];
        if (c0[6:3] >= 9) row_index = 0;
        need_row = c1[6] && (!row_valid[active_layer] || row_key[active_layer] != row_index);
        sum_x = scrollx + (flip_screen ? 16'd319 - {7'd0,active_x} : {7'd0,active_x}) +
            (c1[6] ? row_value[active_layer] : 16'd0);
        sx = sum_x[9:0];
        if (c1[7]) sx[9] = 0;
        col_index = 11'h200 + ({2'b0,sx[8:0]} >> (3 + c0[2:0]));
        need_col = c1[5] && (!col_valid[active_layer] || col_key[active_layer] != col_index);
        sum_col_y = {6'd0,sy_base} + (c1[5] ? col_value[active_layer] : 16'd0);
        sy = {1'b0,sum_col_y[8:0]};
        if (c1[7]) sy[8] = 0;
        // 16x16 maps use two 32x32 pages; 8x8 maps are linear 64x32.
        if (c1[7]) map_index = {sy[7:3],sx[8:3]};
        else map_index = {sx[9],sy[8:4],sx[8:4]};
        map_addr = (active_layer ? 26'h1d4000 : 26'h1d0000) + ({15'd0,map_index} << 2);
        rows_addr = active_layer ? 26'h1e4000 : 26'h1e0000;
        cache_hit = cache_valid[active_layer] && cached_map[active_layer] == map_addr &&
            cached_y[active_layer] == sy[3:0] && cached_half[active_layer] == sx[3];
        px = cached_flipx[active_layer] ? ~sx[2:0] : sx[2:0];
        pen = {cached_planes[active_layer][31-32'(px)], cached_planes[active_layer][23-32'(px)],
               cached_planes[active_layer][15-32'(px)], cached_planes[active_layer][7-32'(px)]};
        fetched_px = pending_flipx ? ~sx[2:0] : sx[2:0];
        // Group word order: {row odd plane1, row odd plane0, row even plane1, row even plane0}.
        fetched_planes = pending_row0 ? tile_data[63:32] : tile_data[31:0];
        fetched_pen = {fetched_planes[31-32'(fetched_px)], fetched_planes[23-32'(fetched_px)],
                       fetched_planes[15-32'(fetched_px)], fetched_planes[7-32'(fetched_px)]};
        // A second cached playfield needs no state/ROM transaction. Evaluate
        // its coordinate and cache keys in parallel, and complete the pixel
        // with PF1 when both results are already available. Row/column misses
        // retain the normal sequential path and its board read ordering.
        fast_c0 = control[5][15:8]; fast_c1 = control[6][15:8];
        fast_sum_y = control[4] + (flip_screen ? 16'd255-{7'd0,active_y} : {7'd0,active_y});
        fast_sy_base = {1'b0,fast_sum_y[8:0]};
        if (fast_c1[7]) fast_sy_base[8] = 0;
        fast_row_index = {1'b0,fast_sy_base} >> fast_c0[6:3];
        if (fast_c0[6:3] >= 9) fast_row_index = 0;
        fast_need_row = fast_c1[6] && (!row_valid[1] || row_key[1] != fast_row_index);
        fast_sum_x = control[3] + (flip_screen ? 16'd319-{7'd0,active_x} : {7'd0,active_x}) +
            (fast_c1[6] ? row_value[1] : 16'd0);
        fast_sx = fast_sum_x[9:0];
        if (fast_c1[7]) fast_sx[9] = 0;
        fast_col_index = 11'h200 + ({2'b0,fast_sx[8:0]} >> (3+fast_c0[2:0]));
        fast_need_col = fast_c1[5] && (!col_valid[1] || col_key[1] != fast_col_index);
        fast_sum_col_y = {6'd0,fast_sy_base} + (fast_c1[5] ? col_value[1] : 16'd0);
        fast_sy = {1'b0,fast_sum_col_y[8:0]};
        if (fast_c1[7]) fast_sy[8] = 0;
        fast_map_index = fast_c1[7] ? {fast_sy[7:3],fast_sx[8:3]} : {fast_sx[9],fast_sy[8:4],fast_sx[8:4]};
        fast_map_addr = 26'h1d4000 + ({15'd0,fast_map_index} << 2);
        fast_cache_hit = cache_valid[1] && cached_map[1] == fast_map_addr &&
            cached_y[1] == fast_sy[3:0] && cached_half[1] == fast_sx[3];
        fast_px = cached_flipx[1] ? ~fast_sx[2:0] : fast_sx[2:0];
        fast_pen = {cached_planes[1][31-32'(fast_px)],cached_planes[1][23-32'(fast_px)],
                    cached_planes[1][15-32'(fast_px)],cached_planes[1][7-32'(fast_px)]};
        fast_pf2_ready = !fast_c0[7] || (!fast_need_row && !fast_need_col && fast_cache_hit);
        fetched = state_data[15:0];
        code = {3'b000,fetched[11:0]} + {bank[6:4],12'b0};
        tile_fx = fetched[15] && c1[0];
        tile_fy = fetched[15] && c1[1];
        glyph_x = c1[7] ? {1'b0,sx[2:0]} : sx[3:0];
        glyph_y = c1[7] ? {1'b0,sy[2:0]} : sy[3:0];
        if (tile_fx) glyph_x = (c1[7] ? 4'd7 : 4'd15) - glyph_x;
        if (tile_fy) glyph_y = (c1[7] ? 4'd7 : 4'd15) - glyph_y;
        glyph_offset = (c1[7] ? {17'd0,code} << 4 : {17'd0,code} << 6) +
            ({28'd0,glyph_y} << 1) + ((!c1[7] && !glyph_x[3]) ? 32'd32 : 32'd0);
        state_req = 0;
        state_addr = 0;
        tile_req = 0;
        tile_byte_addr = 0;
        if (phase == CFG_ISSUE) begin
            state_req = 1;
            state_addr = 26'h1c0000 + {21'd0,cfg_word,2'b00};
        end else if (phase == PROCESS && c0[7]) begin
            if (need_row) begin state_req = 1; state_addr = rows_addr + ({15'd0,row_index} << 2); end
            else if (need_col) begin state_req = 1; state_addr = rows_addr + ({15'd0,col_index} << 2); end
            else if (!cache_hit) begin state_req = 1; state_addr = map_addr; end
        end
        // A completed response permits the next request on the same edge;
        // neither channel has more than one uncompleted transaction.
        // Row/plane-interleaved tile ROM: the 8-byte group {glyph word[18:1]}
        // holds plane0/plane1 of glyph rows 2k and 2k+1.
        if (phase == MAP_WAIT && state_valid && !abort) begin
            tile_req = 1;
            tile_byte_addr = profile == 8'd2 ? {1'b0,glyph_offset[18:2],3'b000} : {glyph_offset[19:2],3'b000};
        end
    end

    always_ff @(posedge clk) begin
        pixel_valid <= 0;
        cfg_done <= 0;
        if (reset) begin
            phase <= IDLE;
            layer <= 0;
            cfg_word <= 0;
            x <= 0; y <= 0;
            pf1_index <= 0; pf2_index <= 9'h100;
            pf1_opaque <= 0; pf2_opaque <= 0;
            pending_row0 <= 0; pending_colour <= 0; pending_flipx <= 0;
            for (i=0;i<8;i=i+1) control[i] <= 0;
            for (i=0;i<2;i=i+1) begin
                row_valid[i] <= 0; col_valid[i] <= 0; cache_valid[i] <= 0;
                row_value[i] <= 0; col_value[i] <= 0; row_key[i] <= 0; col_key[i] <= 0;
                cached_map[i] <= 0; cached_y[i] <= 0; cached_half[i] <= 0;
                cached_flipx[i] <= 0; cached_colour[i] <= 0; cached_planes[i] <= 0;
            end
        end else case (phase)
            IDLE: begin
                if (cfg_load) begin
                    cfg_word <= 0;
                    for (i=0;i<2;i=i+1) begin
                        row_valid[i] <= 0; col_valid[i] <= 0; cache_valid[i] <= 0;
                    end
                    phase <= CFG_ISSUE;
                end else if (pixel_req) begin
                    x <= pixel_x; y <= pixel_y; layer <= 0; phase <= PROCESS;
                    if (!c0[7] || (!need_row && !need_col && cache_hit)) begin
                        pf1_index <= c0[7] ? {1'b0,cached_colour[0],pen} : 9'd0;
                        pf1_opaque <= c0[7] && pen != 0;
                        layer <= 1;
                        if (fast_pf2_ready) begin
                            pf2_index <= fast_c0[7] ? {1'b1,cached_colour[1],fast_pen} : 9'h100;
                            pf2_opaque <= fast_c0[7] && fast_pen != 0;
                            pixel_valid <= 1; phase <= IDLE;
                        end
                    end
                end
            end
            CFG_ISSUE: phase <= CFG_WAIT;
            CFG_WAIT: if (state_valid) begin
                control[cfg_word] <= state_data[15:0];
                if (cfg_word == 7) begin cfg_done <= 1; phase <= IDLE; end
                else begin cfg_word <= cfg_word + 1'b1; phase <= CFG_ISSUE; end
            end
            PROCESS: begin
                if (abort) phase <= IDLE;
                else if (c0[7] && need_row) phase <= ROW_WAIT;
                else if (c0[7] && need_col) phase <= COL_WAIT;
                else if (c0[7] && !cache_hit) phase <= MAP_WAIT;
                else begin
                    if (!layer) begin
                        pf1_index <= c0[7] ? {1'b0,cached_colour[0],pen} : 9'd0;
                        pf1_opaque <= c0[7] && pen != 0;
                        layer <= 1;
                    end else begin
                        pf2_index <= c0[7] ? {1'b1,cached_colour[1],pen} : 9'h100;
                        pf2_opaque <= c0[7] && pen != 0;
                        pixel_valid <= 1; phase <= IDLE;
                    end
                end
            end
            ROW_WAIT: if (state_valid) begin
                row_value[layer] <= state_data[15:0]; row_key[layer] <= row_index;
                row_valid[layer] <= 1; phase <= abort ? IDLE : PROCESS;
            end
            COL_WAIT: if (state_valid) begin
                col_value[layer] <= state_data[15:0]; col_key[layer] <= col_index;
                col_valid[layer] <= 1; phase <= abort ? IDLE : PROCESS;
            end
            MAP_WAIT: if (state_valid) begin
                pending_row0 <= glyph_offset[1];
                pending_colour <= fetched[15:12] & ((tile_fx || tile_fy) ? 4'h7 : 4'hf);
                pending_flipx <= tile_fx;
                cached_map[layer] <= map_addr; cached_y[layer] <= sy[3:0];
                cached_half[layer] <= sx[3];
                phase <= abort ? IDLE : ROM_WAIT;
            end
            ROM_WAIT: if (tile_valid) begin
                cached_planes[layer] <= fetched_planes;
                cached_colour[layer] <= pending_colour; cached_flipx[layer] <= pending_flipx;
                cache_valid[layer] <= 1;
                // The returned planes already determine this pixel. Publish
                // its playfield result on the fill edge rather than rereading
                // the newly written cache in another PROCESS clock.
                if (abort) phase <= IDLE;
                else if (!layer) begin
                    pf1_index <= {1'b0,pending_colour,fetched_pen};
                    pf1_opaque <= fetched_pen != 0;
                    layer <= 1; phase <= PROCESS;
                    if (fast_pf2_ready) begin
                        pf2_index <= fast_c0[7] ? {1'b1,cached_colour[1],fast_pen} : 9'h100;
                        pf2_opaque <= fast_c0[7] && fast_pen != 0;
                        pixel_valid <= 1; phase <= IDLE;
                    end
                end else begin
                    pf2_index <= {1'b1,pending_colour,fetched_pen};
                    pf2_opaque <= fetched_pen != 0;
                    pixel_valid <= 1; phase <= IDLE;
                end
            end
            default: phase <= IDLE;
        endcase
    end
endmodule
