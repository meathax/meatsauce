// SPDX-License-Identifier: BSD-3-Clause
// Galastrm record/chunk setup, from MAME 0.289 galastrm.cpp:254-346.
// One independently scheduled chunk per command; drawing and list ordering
// belong to the scanline engine. ROM map input is a canonical little-endian word.
module gs_sprite_chunk (
    input wire clk, reset,
    input wire command,
    output wire command_ready,
    input wire [31:0] record0, record2, record3,
    input wire [3:0] chunk,
    output wire map_req,
    output wire [17:0] map_word_addr,
    input wire map_ack,
    input wire [15:0] map_rdata,
    output reg valid,
    input wire ready,
    output reg enabled,
    output reg [14:0] code,
    output reg [7:0] color,
    output reg [1:0] sprite_priority,
    output reg flipx, flipy,
    output reg signed [11:0] x, y,
    output reg [6:0] width, height
);
    reg waiting;
    reg [17:0] saved_map_addr;
    reg saved_enabled;
    wire double_size = record3[18];
    wire [2:0] row = double_size ? {1'b0,chunk[3:2]} : {2'b0,chunk[1]};
    wire [2:0] col = double_size ? {1'b0,chunk[1:0]} : {2'b0,chunk[0]};
    wire [2:0] last_chunk = double_size ? 3'd3 : 3'd1;
    wire [2:0] map_col = record0[23] ? last_chunk-col : col;
    wire [2:0] map_row = record3[17] ? last_chunk-row : row;
    wire [7:0] zoom_x = {1'b0,record0[22:16]} + 8'd1;
    wire [7:0] zoom_y = {1'b0,record3[16:10]} + 8'd1;
    wire [10:0] col_product = col * zoom_x;
    wire [10:0] row_product = row * zoom_y;
    wire [2:0] next_col = col+3'd1;
    wire [2:0] next_row = row+3'd1;
    wire [10:0] next_col_product = next_col * zoom_x;
    wire [10:0] next_row_product = next_row * zoom_y;
    wire [8:0] dx = double_size ? col_product[10:2] : col_product[9:1];
    wire [8:0] dy = double_size ? row_product[10:2] : row_product[9:1];
    wire [8:0] next_dx = double_size ? next_col_product[10:2] : next_col_product[9:1];
    wire [8:0] next_dy = double_size ? next_row_product[10:2] : next_row_product[9:1];
    wire [8:0] chunk_width = next_dx-dx;
    wire [8:0] chunk_height = next_dy-dy;
    wire signed [11:0] base_x = $signed({2'b00,record2[9:0]})
                              - (record2[9:0] > 10'd713 ? 12'sd1024 : 12'sd0)
                              + 12'sd54;
    wire [9:0] wrapped_y = record3[9:0] < 10'd117 ?
                           record3[9:0]+10'd512 : record3[9:0];
    wire [9:0] neg_y = -wrapped_y;
    wire signed [11:0] base_y = $signed({2'b00,neg_y}) - 12'sd511
                              + (record3[17] ? 12'sd128-$signed({4'b0,zoom_y}) : 12'sd0);
    assign command_ready = !waiting && !valid;
    assign map_req = waiting;
    assign map_word_addr = saved_map_addr;
    always @(posedge clk) begin
        if (reset) begin
            waiting <= 0; valid <= 0; enabled <= 0;
            code <= 0; color <= 0; sprite_priority <= 0; flipx <= 0; flipy <= 0;
            x <= 0; y <= 0; width <= 0; height <= 0;
            saved_map_addr <= 0; saved_enabled <= 0;
        end else begin
            if (valid && ready) valid <= 0;
            if (command && command_ready) begin
                waiting <= 1;
                saved_map_addr <= {1'b0,record0[14:0],2'b00}
                                  + {15'b0,map_col}
                                  + ({15'b0,map_row} << (double_size ? 2 : 1));
                saved_enabled <= record0[14:0] != 0 && (double_size || chunk < 4);
                color <= record2[17:10]; sprite_priority <= record2[19:18];
                flipx <= !record0[23]; flipy <= record3[17];
                x <= base_x + $signed({3'b0,dx});
                y <= base_y + $signed({3'b0,dy});
                width <= chunk_width[6:0]; height <= chunk_height[6:0];
            end
            if (waiting && map_ack) begin
                waiting <= 0; valid <= 1; code <= map_rdata[14:0];
                enabled <= saved_enabled && map_rdata != 16'hffff && width != 0 && height != 0;
            end
        end
    end
endmodule
