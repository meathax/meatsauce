// SPDX-License-Identifier: GPL-3.0-or-later
// Native-coordinate renderer. SRAM descriptors are read live, in descending order.
// Output is a scanline of {valid,palette address}; RGB palette reads remain live.
// The reused temporary bitmap and separate opacity/owner CLUT reads intentionally
// reproduce MAME's sprite-mix behavior (including pixels left by the prior layer).
module darkmist_scanline (
    input wire clk, reset, start,
    input wire [7:0] line_y, hardware_control, sprite_bank,
    input wire [15:0] bg_scroll_x,bg_scroll_y,fg_scroll_x,fg_scroll_y,
    output reg busy,done,protocol_error,unknown_sprite_active,
    output reg [15:0] line_clocks,
    output reg line_we,
    output reg [7:0] line_x,
    output reg [8:0] line_pen,
    output reg [6:0] sprite_index,
    input wire [31:0] sprite_data,
    output wire [9:0] text_index,
    input wire [15:0] text_data,
    output wire map_req,
    output wire map_fg,
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
    input wire [7:0] clut_addr,clut_data
);
    typedef enum logic [4:0] {IDLE,CLEAR,TILE_SETUP,MAP_READ,TEXT_WAIT,TEXT_GET,
        ROW_START,ROW_WAIT,PIXELS,SPR_WAIT,SPR_GET,SPR_NEXT,
        SPR_MIX_INIT,SPR_MIX,DRAIN,COMPLETE} state_t;
    state_t state;
    reg [7:0] y,control;
    reg [1:0] layer;
    reg signed [9:0] origin_x;
    reg [15:0] world_x,world_y;
    reg [3:0] pixel_count,pixel_last,palette;
    reg [10:0] code;
    reg [3:0] row;
    reg flip_x;
    reg [63:0] shift_pixels;
    reg [7:0] clear_x,mix_x;
    reg [2:0] drain_count;
    wire signed [9:0] screen_x=origin_x+$signed({6'd0,pixel_count});
    wire in_bounds=screen_x>=10'sd0 && screen_x<10'sd256;
    wire [3:0] pen=shift_pixels[3:0];
    assign text_index={y[7:3],origin_x[7:3]};
    assign map_fg=layer==2'd1;
    assign map_word_addr=map_fg ? {1'b0,world_y[11:4],world_x[9:4]} :
                                          {world_y[9:4],world_x[12:4]};
    assign map_req=state==MAP_READ;

    wire row_busy,row_done,row_error;
    wire [63:0] row_pixels;
    wire [1:0] row_region=layer==2'd3 ? 2'd0 :
                             layer==2'd0 ? 2'd1 : layer==2'd1 ? 2'd2 : 2'd3;
    darkmist_gfx_row decode (
        .clk(clk),.reset(reset),.start(state==ROW_START),.region(row_region),
        .code(code),.row(row),.busy(row_busy),.done(row_done),.protocol_error(row_error),
        .pixels(row_pixels),.rom_req(gfx_req),.rom_region(gfx_region),
        .rom_word_addr(gfx_word_addr),.rom_words(gfx_words),
        .rom_ack(gfx_ack),.rom_valid(gfx_valid),.rom_last(gfx_last),.rom_data(gfx_data)
    );

    wire temp_we=state==CLEAR || (state==PIXELS && in_bounds && (layer!=2'd2 || pen!=0));
    wire [7:0] temp_wr_addr=state==CLEAR ? clear_x : screen_x[7:0];
    wire [9:0] temp_din=state==CLEAR ? 10'd0 : {layer,palette,pen};
    wire [7:0] temp_rd_addr=state==SPR_MIX ? mix_x+8'd1 : 8'd0;
    wire [9:0] temp_dout;
    jtframe_rpwp_ram #(.DW(10),.AW(8)) temporary_line (
        .clk(clk),.rd_addr(temp_rd_addr),.dout(temp_dout),
        .wr_addr(temp_wr_addr),.din(temp_din),.we(temp_we)
    );

    // Pre-resolved palette address plus a separate opacity PROM read. These are
    // loaded before CPU release and never reset/cleared as general-purpose RAM.
    reg [7:0] color_lut[0:1023];
    reg opaque_lut[0:1023];
    function automatic [1:0] palette_base(input [1:0] owner);
        case(owner)
            2'd0: palette_base=2'b10;
            2'd1: palette_base=2'b00;
            2'd2: palette_base=2'b01;
            default: palette_base=2'b11;
        endcase
    endfunction
    wire candidate_valid=(state==PIXELS && in_bounds && layer!=2'd2) || state==SPR_MIX;
    wire [9:0] candidate=state==SPR_MIX ? temp_dout : {layer,palette,pen};
    wire [1:0] opacity_owner=state==SPR_MIX ? 2'd2 : layer;
    wire [7:0] candidate_x=state==SPR_MIX ? mix_x : screen_x[7:0];
    reg mix_valid,opaque_q;
    reg [7:0] color_q,mix_tag;
    always @(posedge clk) begin
        if(clut_we) begin
            color_lut[{clut_owner,clut_addr}]<={palette_base(clut_owner),clut_data[5:0]};
            opaque_lut[{clut_owner,clut_addr}]<=!clut_data[6];
        end
        if(candidate_valid) begin
            color_q<=color_lut[candidate];
            opaque_q<=opaque_lut[{opacity_owner,candidate[7:0]}];
            mix_tag<=candidate_x;
        end
        mix_valid<=!reset && candidate_valid;
    end

    task automatic setup_layer(input [1:0] next_layer);
        begin
            layer<=next_layer;
            pixel_last<=next_layer==2'd3 ? 4'd7 : 4'd15;
            flip_x<=1'b0;
            if(next_layer==2'd0) begin
                origin_x<=-$signed({6'd0,bg_scroll_x[3:0]});
                world_x<={bg_scroll_x[15:4],4'd0};
                world_y<=bg_scroll_y+{8'd0,y};
                row<=bg_scroll_y[3:0]+y[3:0];
            end else if(next_layer==2'd1) begin
                origin_x<=-$signed({6'd0,fg_scroll_x[3:0]});
                world_x<={fg_scroll_x[15:4],4'd0};
                world_y<=fg_scroll_y+{8'd0,y};
                row<=fg_scroll_y[3:0]+y[3:0];
            end else begin
                origin_x<=10'sd0;
                row<={1'b0,y[2:0]};
            end
            state<=TILE_SETUP;
        end
    endtask
    task automatic after_bg;
        begin
            if(control[1]) setup_layer(2'd1);
            else if(control[0]) begin layer<=2'd2;sprite_index<=7'd127;state<=SPR_WAIT;end
            else if(control[4]) setup_layer(2'd3);
            else begin state<=DRAIN;drain_count<=3'd0;end
        end
    endtask
    task automatic after_fg;
        begin
            if(control[0]) begin layer<=2'd2;sprite_index<=7'd127;state<=SPR_WAIT;end
            else if(control[4]) setup_layer(2'd3);
            else begin state<=DRAIN;drain_count<=3'd0;end
        end
    endtask
    integer n;
    wire [8:0] sprite_y={1'b0,sprite_data[23:16]};
    wire [8:0] relative_y={1'b0,y}-sprite_y;
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;busy<=1'b0;done<=1'b0;protocol_error<=1'b0;
            unknown_sprite_active<=1'b0;line_we<=1'b0;line_x<=0;line_pen<=0;
            line_clocks<=0;y<=0;control<=0;layer<=0;origin_x<=0;
            world_x<=0;world_y<=0;pixel_count<=0;pixel_last<=0;palette<=0;
            code<=0;row<=0;flip_x<=0;shift_pixels<=0;clear_x<=0;mix_x<=0;
            drain_count<=0;sprite_index<=0;
        end else begin
            done<=1'b0;line_we<=1'b0;
            if(row_error || (start && busy)) protocol_error<=1'b1;
            if(busy) line_clocks<=line_clocks+16'd1;
            if(mix_valid && opaque_q) begin
                line_we<=1'b1;line_x<=mix_tag;line_pen<={1'b1,color_q};
            end
            case(state)
                IDLE: if(start) begin
                    busy<=1'b1;line_clocks<=0;y<=line_y;control<=hardware_control;
                    clear_x<=0;unknown_sprite_active<=1'b0;state<=CLEAR;
                end
                CLEAR: begin
                    line_we<=1'b1;line_x<=clear_x;line_pen<=0;
                    clear_x<=clear_x+8'd1;
                    if(clear_x==8'd255) begin
                        if(control[2]) setup_layer(2'd0);else after_bg();
                    end
                end
                TILE_SETUP: state<=layer==2'd3 ? TEXT_WAIT : MAP_READ;
                MAP_READ: if(map_valid) begin
                    code<={1'b0,map_data[9:8],map_data[7:0]};
                    palette<=map_data[15:12];state<=ROW_START;
                end
                TEXT_WAIT: state<=TEXT_GET;
                TEXT_GET: begin
                    code<={2'd0,text_data[8],text_data[7:0]};
                    palette<=text_data[12:9];state<=ROW_START;
                end
                ROW_START: state<=ROW_WAIT;
                ROW_WAIT: if(row_done) begin
                    if(layer==2'd2 && flip_x) begin
                        for(n=0;n<16;n=n+1) shift_pixels[n*4 +:4]<=row_pixels[(15-n)*4 +:4];
                    end else shift_pixels<=row_pixels;
                    pixel_count<=0;state<=PIXELS;
                end
                PIXELS: begin
                    shift_pixels<={4'd0,shift_pixels[63:4]};
                    pixel_count<=pixel_count+4'd1;
                    if(pixel_count==pixel_last) begin
                        if(layer==2'd2) state<=SPR_NEXT;
                        else if(origin_x+(layer==2'd3 ? 10'sd8 : 10'sd16)>=10'sd256) begin
                            if(layer==2'd0) after_bg();
                            else if(layer==2'd1) after_fg();
                            else begin state<=DRAIN;drain_count<=0;end
                        end else begin
                            origin_x<=origin_x+(layer==2'd3 ? 10'sd8 : 10'sd16);
                            world_x<=world_x+16'd16;state<=TILE_SETUP;
                        end
                    end
                end
                SPR_WAIT: state<=SPR_GET;
                SPR_GET: begin
                    if({1'b0,y}>=sprite_y && relative_y<9'd16) begin
                        code<={(sprite_data[13] ? sprite_bank[2:0] : 3'd0),sprite_data[7:0]};
                        palette<=sprite_data[12:9];origin_x<=$signed({2'd0,sprite_data[31:24]});
                        row<=sprite_data[14] ? 4'd15-relative_y[3:0] : relative_y[3:0];
                        flip_x<=sprite_data[15];pixel_last<=4'd15;state<=ROW_START;
                        if(sprite_data[8]) unknown_sprite_active<=1'b1;
                    end else state<=SPR_NEXT;
                end
                SPR_NEXT: begin
                    if(sprite_index==0) begin mix_x<=0;state<=SPR_MIX_INIT;end
                    else begin sprite_index<=sprite_index-7'd1;state<=SPR_WAIT;end
                end
                SPR_MIX_INIT: state<=SPR_MIX;
                SPR_MIX: begin
                    mix_x<=mix_x+8'd1;
                    if(mix_x==8'd255) begin
                        if(control[4]) setup_layer(2'd3);
                        else begin state<=DRAIN;drain_count<=0;end
                    end
                end
                DRAIN: begin drain_count<=drain_count+3'd1;if(drain_count==3'd3) state<=COMPLETE;end
                COMPLETE: begin busy<=1'b0;done<=1'b1;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
