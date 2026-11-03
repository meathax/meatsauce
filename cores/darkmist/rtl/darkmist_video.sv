// SPDX-License-Identifier: GPL-3.0-or-later
// Two tagged scanlines; no framebuffer and no stopped raster during game pause.
// The renderer prepares y+1 while the current native y is displayed.
module darkmist_video (
    input wire clk,reset,ce_pixel,display_flip,
    input wire [8:0] raster_x,
    input wire [7:0] raster_y,hardware_control,sprite_bank,
    input wire [15:0] bg_scroll_x,bg_scroll_y,fg_scroll_x,fg_scroll_y,
    output wire [6:0] sprite_index,
    input wire [31:0] sprite_data,
    output wire [9:0] text_index,
    input wire [15:0] text_data,
    output wire [7:0] color_index,
    input wire [11:0] color_rgb,
    output wire map_req,map_fg,
    output wire [14:0] map_word_addr,
    input wire map_valid,
    input wire [15:0] map_data,
    output wire gfx_req,
    output wire [1:0] gfx_region,
    output wire [16:0] gfx_word_addr,
    output wire [2:0] gfx_words,
    input wire gfx_ack,gfx_valid,gfx_last,
    input wire [15:0] gfx_data,
    input wire clut_we,
    input wire [1:0] clut_owner,
    input wire [7:0] clut_addr,clut_data,
    output wire [11:0] rgb,
    output reg pixel_ce,pixel_valid,
    output reg [8:0] pixel_x,
    output reg [7:0] pixel_y,
    output reg [15:0] underflow_lines,overrun_lines,maximum_line_clocks,
    output reg unknown_sprite_seen,
    output wire protocol_error
);
    reg render_start;
    reg [7:0] render_y,render_tag;
    reg flip_active;
    wire [7:0] display_read_x=flip_active ? 8'd255-raster_x[7:0] : raster_x[7:0];
    wire renderer_busy,renderer_done,unknown_sprite_active;
    wire [15:0] renderer_clocks;
    wire line_we;
    wire [7:0] line_x;
    wire [8:0] line_pen;
    reg [7:0] tag0,tag1;
    reg valid0,valid1;
    wire [8:0] buffer0,buffer1;
    wire [8:0] display_pen=raster_y[0] ? buffer1 : buffer0;
    wire tag_valid=raster_y[0] ? valid1 && tag1==raster_y : valid0 && tag0==raster_y;
    reg tag_valid_q,ce_q;
    reg [8:0] x_q;
    reg [7:0] y_q;
    assign color_index=display_pen[7:0];
    assign rgb=pixel_valid ? color_rgb : 12'd0;
    darkmist_scanline renderer (
        .clk(clk),.reset(reset),.start(render_start),.line_y(render_y),
        .hardware_control(hardware_control),.sprite_bank(sprite_bank),
        .bg_scroll_x(bg_scroll_x),.bg_scroll_y(bg_scroll_y),
        .fg_scroll_x(fg_scroll_x),.fg_scroll_y(fg_scroll_y),
        .busy(renderer_busy),.done(renderer_done),.protocol_error(protocol_error),
        .unknown_sprite_active(unknown_sprite_active),.line_clocks(renderer_clocks),
        .line_we(line_we),.line_x(line_x),.line_pen(line_pen),
        .sprite_index(sprite_index),.sprite_data(sprite_data),
        .text_index(text_index),.text_data(text_data),
        .map_req(map_req),.map_fg(map_fg),.map_word_addr(map_word_addr),
        .map_valid(map_valid),.map_data(map_data),
        .gfx_req(gfx_req),.gfx_region(gfx_region),.gfx_word_addr(gfx_word_addr),.gfx_words(gfx_words),
        .gfx_ack(gfx_ack),.gfx_valid(gfx_valid),.gfx_last(gfx_last),.gfx_data(gfx_data),
        .clut_we(clut_we),.clut_owner(clut_owner),.clut_addr(clut_addr),.clut_data(clut_data)
    );
    jtframe_rpwp_ram #(.DW(9),.AW(8)) line0 (
        .clk(clk),.rd_addr(display_read_x),.dout(buffer0),
        .wr_addr(line_x),.din(line_pen),.we(line_we && !render_tag[0])
    );
    jtframe_rpwp_ram #(.DW(9),.AW(8)) line1 (
        .clk(clk),.rd_addr(display_read_x),.dout(buffer1),
        .wr_addr(line_x),.din(line_pen),.we(line_we && render_tag[0])
    );
    always @(posedge clk) begin
        if(reset) begin
            render_start<=0;render_y<=0;render_tag<=0;flip_active<=0;tag0<=0;tag1<=0;valid0<=0;valid1<=0;
            tag_valid_q<=0;ce_q<=0;x_q<=0;y_q<=0;
            pixel_ce<=0;pixel_valid<=0;pixel_x<=0;pixel_y<=0;
            underflow_lines<=0;overrun_lines<=0;maximum_line_clocks<=0;unknown_sprite_seen<=0;
        end else begin
            render_start<=0;
            x_q<=raster_x;y_q<=raster_y;ce_q<=ce_pixel;
            tag_valid_q<=tag_valid;
            pixel_ce<=ce_q;pixel_x<=x_q;pixel_y<=y_q;
            pixel_valid<=display_pen[8] && tag_valid_q && x_q<9'd256 && y_q>=8'd16 && y_q<8'd240;
            if(renderer_done) begin
                if(render_tag[0]) begin tag1<=render_tag;valid1<=1'b1;end
                else begin tag0<=render_tag;valid0<=1'b1;end
                if(renderer_clocks>maximum_line_clocks) maximum_line_clocks<=renderer_clocks;
                if(unknown_sprite_active) unknown_sprite_seen<=1'b1;
            end
            if(ce_pixel && raster_x==0) begin
                if(raster_y==8'd240) begin
                    flip_active<=display_flip;
                    if(display_flip!=flip_active) begin valid0<=0;valid1<=0;end
                end
                if(raster_y>=8'd16 && raster_y<8'd240 && !tag_valid) underflow_lines<=underflow_lines+16'd1;
                if(raster_y>=8'd15 && raster_y<8'd239) begin
                    if(renderer_busy || render_start) overrun_lines<=overrun_lines+16'd1;
                    else begin
                        render_tag<=raster_y+8'd1;
                        render_y<=flip_active ? 8'd254-raster_y : raster_y+8'd1;
                        render_start<=1'b1;
                    end
                end
            end
        end
    end
endmodule
