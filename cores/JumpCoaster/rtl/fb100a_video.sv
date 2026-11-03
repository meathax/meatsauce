// SPDX-License-Identifier: GPL-3.0-or-later
// FB-100A line renderer based on MAME's fastfred_state::screen_update_fastfred.
// ROM/RAM byte organization follows the MAME gfx_jumpcoas layouts.
module fb100a_video (
    input  wire        clk_sys,
    input  wire        reset,
    input  wire        ce_pixel,
    input  wire [8:0]  x,
    input  wire [7:0]  y,
    input  wire [1:0]  color_bank,
    input  wire [1:0]  character_bank,
    input  wire        flip_x,
    input  wire        flip_y,
    input  wire [7:0]  background_color,
    output reg  [9:0]  video_scan_addr,
    input  wire [7:0]  video_scan_data,
    output reg  [9:0]  tile_scan_addr,
    input  wire [7:0]  tile_scan_data,
    output reg  [13:0] graphics_scan_addr,
    input  wire [7:0]  graphics_scan_data,
    output wire [7:0]  pixel_index,
    output wire        line_build_busy,
    output reg         line_ready
);
    localparam [5:0] ST_IDLE              = 6'd0;
    localparam [5:0] ST_ATTR_SCROLL_READ  = 6'd1;
    localparam [5:0] ST_ATTR_SCROLL_LATCH = 6'd2;
    localparam [5:0] ST_ATTR_COLOR_READ   = 6'd3;
    localparam [5:0] ST_ATTR_COLOR_LATCH  = 6'd4;
    localparam [5:0] ST_TILE_READ         = 6'd5;
    localparam [5:0] ST_TILE_LATCH        = 6'd6;
    localparam [5:0] ST_TILE_GFX_READ     = 6'd7;
    localparam [5:0] ST_TILE_GFX_LATCH    = 6'd8;
    localparam [5:0] ST_TILE_DRAW         = 6'd9;
    localparam [5:0] ST_SPR_Y_READ        = 6'd10;
    localparam [5:0] ST_SPR_Y_LATCH       = 6'd11;
    localparam [5:0] ST_SPR_CODE_READ     = 6'd12;
    localparam [5:0] ST_SPR_CODE_LATCH    = 6'd13;
    localparam [5:0] ST_SPR_COLOR_READ    = 6'd14;
    localparam [5:0] ST_SPR_COLOR_LATCH   = 6'd15;
    localparam [5:0] ST_SPR_X_READ        = 6'd16;
    localparam [5:0] ST_SPR_X_LATCH       = 6'd17;
    localparam [5:0] ST_SPR_TEST          = 6'd18;
    localparam [5:0] ST_SPR_GFX_READ      = 6'd19;
    localparam [5:0] ST_SPR_GFX_LATCH     = 6'd20;
    localparam [5:0] ST_SPR_DRAW          = 6'd21;

    reg [5:0] state=ST_IDLE;
    reg [7:0] line_buffer [0:255];
    reg [255:0] line_valid=0;
    reg [7:0] target_y=0;
    reg [7:0] source_y=0;
    reg [7:0] bg_snapshot=0;
    reg [1:0] color_bank_snapshot=0;
    reg [1:0] character_bank_snapshot=0;
    reg flip_x_snapshot=0;
    reg flip_y_snapshot=0;
    reg [7:0] tile_code=0;
    reg [7:0] tile_color=0;
    reg [7:0] tile_plane_0=0;
    reg [7:0] tile_plane_1=0;
    reg [7:0] tile_plane_2=0;
    reg [7:0] sprite_y=0;
    reg [7:0] sprite_code_attr=0;
    reg [7:0] sprite_color_attr=0;
    reg [7:0] sprite_x=0;
    reg [4:0] column=0;
    reg [2:0] sprite_index=0;
    reg [2:0] graphics_plane=0;
    reg [3:0] tile_x=0;
    reg [3:0] sprite_x_draw=0;
    reg [3:0] sprite_row=0;
    reg [6:0] sprite_code=0;
    reg [7:0] sprite_group=0;
    reg signed [9:0] sprite_x_start=0;
    reg sprite_flip_x=0;
    reg sprite_flip_y=0;
    reg sprite_half=0;
    reg [7:0] sprite_pixels [0:2][0:1];

    wire [4:0] source_column = flip_x_snapshot ? (5'd31 - column) : column;
    wire [13:0] graphics_plane_base = (graphics_plane==3'd0) ? 14'd8192 :
                                      (graphics_plane==3'd1) ? 14'd4096 : 14'd0;
    wire [13:0] tile_code_base = {2'b00,character_bank_snapshot[0],tile_code,3'b000};
    wire [4:0] sprite_row_offset = (sprite_row < 4'd8) ? {2'b0,sprite_row[2:0]} :
                                  ({2'b0,sprite_row[2:0]} + 5'd8);
    wire [13:0] sprite_code_base = {2'b00,sprite_code,5'b00000};
    wire [13:0] sprite_rom_offset = sprite_code_base + {9'd0,sprite_row_offset} +
                                    (sprite_half ? 14'd8 : 14'd0);
    wire [4:0] sprite_local_x = sprite_flip_x ? (5'd15 - {1'b0,sprite_x_draw}) :
                                                {1'b0,sprite_x_draw};
    wire [7:0] sprite_plane_0 = sprite_pixels[0][sprite_local_x[3]];
    wire [7:0] sprite_plane_1 = sprite_pixels[1][sprite_local_x[3]];
    wire [7:0] sprite_plane_2 = sprite_pixels[2][sprite_local_x[3]];
    wire [2:0] sprite_pen = {sprite_plane_2[sprite_local_x[2:0]],
                             sprite_plane_1[sprite_local_x[2:0]],
                             sprite_plane_0[sprite_local_x[2:0]]};
    wire signed [9:0] sprite_sy_raw = 10'sd240 - $signed({2'b00,sprite_y});
    wire signed [9:0] sprite_sy = flip_y_snapshot ? (10'sd240 - sprite_sy_raw) : sprite_sy_raw;
    wire signed [9:0] sprite_sx_raw = $signed({2'b00,sprite_x});
    wire signed [9:0] sprite_sx = flip_x_snapshot ? (10'sd240 - sprite_sx_raw) : sprite_sx_raw;
    wire signed [9:0] sprite_row_relative = $signed({2'b00,target_y}) - sprite_sy;
    wire sprite_row_visible = (target_y >= 8'd16) && (target_y < 8'd240) &&
                              (sprite_row_relative >= 0) && (sprite_row_relative < 16);
    wire sprite_flip_y_calc = sprite_code_attr[7] ^ flip_y_snapshot;
    wire [2:0] tile_local_x = flip_x_snapshot ? (3'd7 - tile_x[2:0]) : tile_x[2:0];
    wire [2:0] tile_pen = {tile_plane_2[tile_local_x],tile_plane_1[tile_local_x],tile_plane_0[tile_local_x]};
    wire [7:0] tile_pixel_value = tile_color | {5'd0,tile_pen};
    wire [7:0] tile_dest = {column,tile_x[2:0]};
    wire signed [9:0] sprite_dest_x = sprite_x_start + $signed({6'd0,sprite_x_draw});
    wire sprite_x_visible = (sprite_dest_x >= 0) && (sprite_dest_x < 256) &&
                            (flip_x_snapshot ? (sprite_dest_x < 240) : (sprite_dest_x >= 16));

    assign pixel_index = line_valid[x[7:0]] ? line_buffer[x[7:0]] : bg_snapshot;
    assign line_build_busy = (state != ST_IDLE);

    always @* begin
        video_scan_addr = 10'd0;
        tile_scan_addr = 10'd0;
        graphics_scan_addr = 14'd0;

        case (state)
            ST_ATTR_SCROLL_READ: video_scan_addr = {4'd0,source_column,1'b0};
            ST_ATTR_COLOR_READ:  video_scan_addr = {4'd0,source_column,1'b1};
            ST_SPR_Y_READ:       video_scan_addr = 10'h040 + {5'd0,sprite_index,2'b00};
            ST_SPR_CODE_READ:    video_scan_addr = 10'h041 + {5'd0,sprite_index,2'b00};
            ST_SPR_COLOR_READ:   video_scan_addr = 10'h042 + {5'd0,sprite_index,2'b00};
            ST_SPR_X_READ:       video_scan_addr = 10'h043 + {5'd0,sprite_index,2'b00};
            default: begin end
        endcase

        if (state == ST_TILE_READ)
            tile_scan_addr = {source_y[7:3],source_column};

        if (state == ST_TILE_GFX_READ)
            graphics_scan_addr = graphics_plane_base + tile_code_base + {11'd0,source_y[2:0]};
        else if (state == ST_SPR_GFX_READ)
            graphics_scan_addr = graphics_plane_base + sprite_rom_offset;
    end

    always @(posedge clk_sys) begin
        if (reset) begin
            state <= ST_IDLE;
            line_ready <= 1'b0;
            line_valid <= 256'd0;
            column <= 0;
            sprite_index <= 0;
            tile_x <= 0;
            sprite_x_draw <= 0;
        end else begin
            if ((state == ST_IDLE) && ce_pixel && (x == 9'd256)) begin
                target_y <= y + 8'd1;
                bg_snapshot <= background_color;
                color_bank_snapshot <= color_bank;
                character_bank_snapshot <= character_bank;
                flip_x_snapshot <= flip_x;
                flip_y_snapshot <= flip_y;
                line_ready <= 1'b0;
                line_valid <= 256'd0;
                column <= 0;
                state <= ST_ATTR_SCROLL_READ;
            end else begin
                case (state)
                    ST_IDLE: begin end
                    ST_ATTR_SCROLL_READ: state <= ST_ATTR_SCROLL_LATCH;
                    ST_ATTR_SCROLL_LATCH: begin
                        source_y <= (flip_y_snapshot ? (8'd255 - target_y) : target_y) + video_scan_data;
                        state <= ST_ATTR_COLOR_READ;
                    end
                    ST_ATTR_COLOR_READ: state <= ST_ATTR_COLOR_LATCH;
                    ST_ATTR_COLOR_LATCH: begin
                        tile_color <= {color_bank_snapshot,video_scan_data[2:0],3'b000};
                        state <= ST_TILE_READ;
                    end
                    ST_TILE_READ: state <= ST_TILE_LATCH;
                    ST_TILE_LATCH: begin
                        tile_code <= tile_scan_data;
                        graphics_plane <= 0;
                        state <= ST_TILE_GFX_READ;
                    end
                    ST_TILE_GFX_READ: state <= ST_TILE_GFX_LATCH;
                    ST_TILE_GFX_LATCH: begin
                        case (graphics_plane)
                            0: tile_plane_0 <= graphics_scan_data;
                            1: tile_plane_1 <= graphics_scan_data;
                            default: tile_plane_2 <= graphics_scan_data;
                        endcase
                        if (graphics_plane == 2) begin
                            tile_x <= 0;
                            state <= ST_TILE_DRAW;
                        end else begin
                            graphics_plane <= graphics_plane + 3'd1;
                            state <= ST_TILE_GFX_READ;
                        end
                    end
                    ST_TILE_DRAW: begin
                        if (tile_pen != 3'd0) begin
                            line_buffer[tile_dest] <= tile_pixel_value;
                            line_valid[tile_dest] <= 1'b1;
                        end
                        if (tile_x == 4'd7) begin
                            if (column == 5'd31) begin
                                sprite_index <= 3'd7;
                                state <= ST_SPR_Y_READ;
                            end else begin
                                column <= column + 5'd1;
                                state <= ST_ATTR_SCROLL_READ;
                            end
                        end else tile_x <= tile_x + 4'd1;
                    end
                    ST_SPR_Y_READ: state <= ST_SPR_Y_LATCH;
                    ST_SPR_Y_LATCH: begin sprite_y <= video_scan_data; state <= ST_SPR_CODE_READ; end
                    ST_SPR_CODE_READ: state <= ST_SPR_CODE_LATCH;
                    ST_SPR_CODE_LATCH: begin sprite_code_attr <= video_scan_data; state <= ST_SPR_COLOR_READ; end
                    ST_SPR_COLOR_READ: state <= ST_SPR_COLOR_LATCH;
                    ST_SPR_COLOR_LATCH: begin sprite_color_attr <= video_scan_data; state <= ST_SPR_X_READ; end
                    ST_SPR_X_READ: state <= ST_SPR_X_LATCH;
                    ST_SPR_X_LATCH: begin sprite_x <= video_scan_data; state <= ST_SPR_TEST; end
                    ST_SPR_TEST: begin
                        if (sprite_row_visible) begin
                            sprite_code <= {1'b1,sprite_code_attr[5:0]};
                            sprite_group <= {color_bank_snapshot,sprite_color_attr[2:0],3'b000};
                            sprite_x_start <= sprite_sx;
                            sprite_flip_x <= (~sprite_code_attr[6]) ^ flip_x_snapshot;
                            sprite_flip_y <= sprite_flip_y_calc;
                            sprite_row <= sprite_flip_y_calc ? (4'd15 - sprite_row_relative[3:0]) : sprite_row_relative[3:0];
                            graphics_plane <= 0;
                            sprite_half <= 0;
                            state <= ST_SPR_GFX_READ;
                        end else if (sprite_index == 0) begin
                            state <= ST_IDLE;
                            line_ready <= 1'b1;
                        end else begin
                            sprite_index <= sprite_index - 3'd1;
                            state <= ST_SPR_Y_READ;
                        end
                    end
                    ST_SPR_GFX_READ: state <= ST_SPR_GFX_LATCH;
                    ST_SPR_GFX_LATCH: begin
                        sprite_pixels[graphics_plane[1:0]][sprite_half] <= graphics_scan_data;
                        if (!sprite_half) begin
                            sprite_half <= 1'b1;
                            state <= ST_SPR_GFX_READ;
                        end else if (graphics_plane != 2) begin
                            sprite_half <= 0;
                            graphics_plane <= graphics_plane + 3'd1;
                            state <= ST_SPR_GFX_READ;
                        end else begin
                            sprite_x_draw <= 0;
                            state <= ST_SPR_DRAW;
                        end
                    end
                    ST_SPR_DRAW: begin
                        if (sprite_x_visible && (sprite_pen != 0)) begin
                            line_buffer[sprite_dest_x[7:0]] <= sprite_group | {5'd0,sprite_pen};
                            line_valid[sprite_dest_x[7:0]] <= 1'b1;
                        end
                        if (sprite_x_draw == 4'd15) begin
                            if (sprite_index == 0) begin
                                state <= ST_IDLE;
                                line_ready <= 1'b1;
                            end else begin
                                sprite_index <= sprite_index - 3'd1;
                                state <= ST_SPR_Y_READ;
                            end
                        end else sprite_x_draw <= sprite_x_draw + 4'd1;
                    end
                    default: begin
                        state <= ST_IDLE;
                        line_ready <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
