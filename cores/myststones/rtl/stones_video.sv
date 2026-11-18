// Live tile fetches and one-line-ahead sprite preparation; no game framebuffer.
// Tile RAM/ROM settle during the eight master clocks preceding each pixel CE.
// Sprite RAM retains the original prior-line scan order and approximate phase.
module stones_video (
    input wire clk, reset, ce_pixel,
    input wire [8:0] h, v,
    input wire [7:0] video_control, scroll,
    input wire flip_dip,
    output reg [9:0] fg_addr, bg_addr,
    input wire [7:0] fg_code, fg_attr, bg_code, bg_attr,
    output reg [4:0] sprite_addr,
    input wire [31:0] sprite_data,
    input wire gfx_wr,
    input wire [16:0] gfx_addr,
    input wire [7:0] gfx_data,
    output reg [5:0] pen,
    output reg overrun
);
    // Download: 00000..0bfff FG/sprites; 10000..1bfff background.
    reg [7:0] fg0[0:16383] /* verilator public_flat_rw */;
    reg [7:0] fg1[0:16383] /* verilator public_flat_rw */;
    reg [7:0] fg2[0:16383] /* verilator public_flat_rw */;
    reg [7:0] bg0[0:16383] /* verilator public_flat_rw */;
    reg [7:0] bg1[0:16383] /* verilator public_flat_rw */;
    reg [7:0] bg2[0:16383] /* verilator public_flat_rw */;
    reg [13:0] fg_rom_addr, live_fg_rom_addr, bg_rom_addr;
    reg [7:0] fq0,fq1,fq2,live_fq0,live_fq1,live_fq2,bq0,bq1,bq2;
    always @(posedge clk) begin
        if (gfx_wr) begin
            case (gfx_addr[16:14])
                3'd0: fg0[gfx_addr[13:0]] <= gfx_data;
                3'd1: fg1[gfx_addr[13:0]] <= gfx_data;
                3'd2: fg2[gfx_addr[13:0]] <= gfx_data;
                3'd4: bg0[gfx_addr[13:0]] <= gfx_data;
                3'd5: bg1[gfx_addr[13:0]] <= gfx_data;
                3'd6: bg2[gfx_addr[13:0]] <= gfx_data;
                default: begin end
            endcase
        end
        fq0 <= fg0[fg_rom_addr]; fq1 <= fg1[fg_rom_addr]; fq2 <= fg2[fg_rom_addr];
        live_fq0 <= fg0[live_fg_rom_addr];
        live_fq1 <= fg1[live_fg_rom_addr];
        live_fq2 <= fg2[live_fg_rom_addr];
        bq0 <= bg0[bg_rom_addr]; bq1 <= bg1[bg_rom_addr]; bq2 <= bg2[bg_rom_addr];
    end

    // Pen zero is transparent; later nonzero sprites overwrite earlier ones.
    reg [3:0] line0 [0:255], line1 [0:255];
    reg [3:0] sprite_pen;
    reg bank;
    reg [8:0] target_y;
    reg [7:0] x;
    reg [3:0] state;
    localparam IDLE=0,CLEAR=1,WAITSPRITES=2,SADDR=3,SWAIT=4,
               SSETUP=5,SROM=6,SRWAIT=7,SWRITE=8;
    wire flip = video_control[7] ^ flip_dip;
    wire [7:0] tile_x = flip ? 8'd255-h[7:0] : h[7:0];
    wire [7:0] tile_y = flip ? 8'd255-v[7:0] : v[7:0];
    wire [8:0] bg_y = {1'b0,tile_y}+{1'b0,scroll};
    // Column-major maps, with the columns reversed in RAM.
    wire [9:0] fg_index = {~tile_x[7:3],tile_y[7:3]};
    wire [8:0] bg_index = {~tile_x[7:4],bg_y[8:4]};
    reg [2:0] bit_index;
    wire [2:0] fg_pixel = {fq2[bit_index],fq1[bit_index],fq0[bit_index]};
    wire [2:0] tile_bit = ~tile_x[2:0];
    wire [2:0] live_fg_pixel = {live_fq2[tile_bit],live_fq1[tile_bit],live_fq0[tile_bit]};
    wire [2:0] bg_pixel = {bq2[tile_bit],bq1[tile_bit],bq0[tile_bit]};
    reg [8:0] sprite_code;
    reg sprite_color, sprite_flipx, sprite_flipy;
    reg signed [9:0] sprite_x;
    reg [3:0] sprite_row, sprite_pixel;
    wire [3:0] sx = sprite_flipx ? ~sprite_pixel : sprite_pixel;
    wire [3:0] sy = sprite_flipy ? ~sprite_row : sprite_row;
    wire signed [9:0] draw_x = sprite_x + $signed({6'd0,sprite_pixel});
    wire [7:0] attr = sprite_data[7:0];
    wire signed [9:0] raw_x = 10'sd240-$signed({2'b00,sprite_data[31:24]});
    wire [7:0] raw_y = 8'd240-sprite_data[23:16];
    wire signed [9:0] sprite_y = flip ? 10'sd240-$signed({2'b00,raw_y}) : $signed({2'b00,raw_y});
    wire signed [9:0] row_delta = $signed({1'b0,target_y})-sprite_y;
    wire in_range = draw_x >= 0 && draw_x < 256;
    wire [5:0] tile_pen = live_fg_pixel != 0 ?
        {1'b1,video_control[0],video_control[1],live_fg_pixel} :
        (sprite_pen != 0 ? {2'b00,sprite_pen} : {3'b010,bg_pixel});
    always @* begin
        fg_addr = fg_index;
        bg_addr = {video_control[2],bg_index};
    end

    always @(posedge clk) begin
        live_fg_rom_addr <= {fg_attr[2:0],fg_code,tile_y[2:0]};
        bg_rom_addr <= {bg_attr[0],bg_code,~tile_x[3],bg_y[3:0] ^ {4{bg_index[4]}}};
        sprite_pen <= v[0] ? line1[h[7:0]] : line0[h[7:0]];
        if (ce_pixel)
            pen <= h < 256 && v >= 8 && v < 248 ? tile_pen : 6'd0;
        if (reset) begin
            state <= IDLE;
            overrun <= 0;
            pen <= 0;
            sprite_addr <= 0;
            fg_rom_addr <= 0;
            bank <= 0; target_y <= 0; x <= 0;
        end else if (ce_pixel && h == 0) begin
            if (state != IDLE) overrun <= 1;
            target_y <= v == 271 ? 9'd0 : v+1'b1;
            bank <= ~v[0];
            x <= 0;
            state <= CLEAR;
        end else begin
            case (state)
                CLEAR: begin
                    if (bank) line1[x] <= 0; else line0[x] <= 0;
                    if (x == 255) state <= WAITSPRITES;
                    else x <= x+1'b1;
                end
                WAITSPRITES: begin
                    // Preserve the prior renderer's sprite scan phase after
                    // its 256 * 5-clock tile pass, with ample worst-case margin.
                    if (ce_pixel && h == 160) begin
                        sprite_addr <= 0;
                        state <= SADDR;
                    end
                end
                SADDR: state <= SWAIT;
                SWAIT: state <= SSETUP;
                SSETUP: begin
                    if (attr[0] && row_delta >= 0 && row_delta < 16) begin
                        sprite_code <= {attr[4],sprite_data[15:8]};
                        sprite_x <= flip ? 10'sd240-raw_x : raw_x;
                        sprite_row <= row_delta[3:0];
                        sprite_color <= attr[3];
                        sprite_flipx <= attr[2] ^ flip;
                        sprite_flipy <= attr[1] ^ flip;
                        sprite_pixel <= 0;
                        state <= SROM;
                    end else if (sprite_addr == 23) state <= IDLE;
                    else begin sprite_addr <= sprite_addr+1'b1; state <= SADDR; end
                end
                SROM: begin
                    fg_rom_addr <= {sprite_code,~sx[3],sy};
                    bit_index <= ~sx[2:0];
                    state <= SRWAIT;
                end
                SRWAIT: state <= SWRITE;
                SWRITE: begin
                    if (in_range && fg_pixel != 0) begin
                        if (bank) line1[draw_x[7:0]] <= {sprite_color,fg_pixel};
                        else line0[draw_x[7:0]] <= {sprite_color,fg_pixel};
                    end
                    if (sprite_pixel == 15) begin
                        if (sprite_addr == 23) state <= IDLE;
                        else begin sprite_addr <= sprite_addr+1'b1; state <= SADDR; end
                    end else begin sprite_pixel <= sprite_pixel+1'b1; state <= SROM; end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
