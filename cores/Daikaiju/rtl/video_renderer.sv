`default_nettype none

// A74 renderer for the MAME 0.289 daikaiju_state::screen_update contract.
// The scan RAM is mirrored continuously so the line engine can rasterize a
// complete line before it is displayed. The mirror is not a frame-atomic
// snapshot; exact mid-frame write visibility has not been established.
module a74_video_renderer (
    input  wire        clk_sys,
    input  wire        reset_n,
    input  wire        ce_pixel,
    input  wire [8:0]  h_counter,
    input  wire [8:0]  v_counter,
    input  wire [8:0]  display_x,
    input  wire [8:0]  display_y,
    input  wire        display_valid,
    input  wire [8:0]  prefetch_y,
    input  wire        flip_screen,

    input  wire [7:0]  vram_data,
    output reg  [13:0] vram_address,

    input  wire [15:0] ioctl_index,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    input  wire        ioctl_wr,

    output wire [8:0]  palette_index,
    output wire        pixel_valid
);

    localparam [13:0] VRAM_LAST = 14'h27ff;

    // 4 KiB tile entries, 256 four-byte scroll records, and 256 objects.
    // Byte/word ordering follows the contiguous c000-e7ff scan window.
    wire [7:0] tile_lo_data;
    wire [7:0] tile_hi_data;

    reg [13:0] scan_address_d;
    reg        scan_valid_d;
    reg        vram_cache_ready;

    // Each graphics ROM is 0x20000 bytes. Store 16-bit download words in
    // separate 0x10000-byte halves; the MAME ROMREGION_INVERT is applied as
    // bytes arrive, so the decode below sees the inverted region contents.
    (* ramstyle="MLAB" *) reg [15:0] gfx1_lo_mlab[0:6143];
    reg [15:0] gfx1_lo_m10k[0:26623];
    reg [15:0] gfx1_hi [0:32767];
    reg [15:0] gfx2_lo [0:32767];
    reg [15:0] gfx2_hi [0:32767];

    // Half-line buffers let the renderer build line N+1 while line N scans.

    reg [8:0] line_tag [0:1];
    reg [1:0] line_tag_valid;
    reg       render_bank;
    reg [8:0] render_y;
    reg       render_flip;

    // Top-pass records are collected in scroll-list order while the bottom
    // pass is rendered, then replayed after sprites.
    (* ramstyle="MLAB, no_rw_check" *) reg [26:0] top_queue [0:255];
    reg [8:0]  top_count;
    reg [8:0]  top_index;
    wire [26:0] top_record=top_queue[top_index[7:0]];

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_CLEAR      = 4'd1;
    localparam [3:0] ST_BG_SCAN    = 4'd2;
    localparam [3:0] ST_BG_ENTRY   = 4'd3;
    localparam [3:0] ST_BG_ROM     = 4'd4;
    localparam [3:0] ST_BG_DRAW    = 4'd5;
    localparam [3:0] ST_SPR_SCAN   = 4'd6;
    localparam [3:0] ST_SPR_ROM    = 4'd7;
    localparam [3:0] ST_SPR_DRAW   = 4'd8;
    localparam [3:0] ST_TOP_SCAN   = 4'd9;
    localparam [3:0] ST_TOP_ROM    = 4'd10;
    localparam [3:0] ST_TOP_DRAW   = 4'd11;
    localparam [3:0] ST_DONE       = 4'd12;
    localparam [3:0] ST_BG_WAIT    = 4'd13;

    reg [3:0] state;
    reg [8:0] clear_index;
    reg [8:0] bg_index;
    reg [8:0] group_start;
    reg [7:0] previous_id;
    reg [7:0] group_id;
    reg [7:0] group_previous_id;
    reg [7:0] global_scroll_x;

    reg [11:0] tile_code_q;
    reg [3:0]  tile_color_q;
    reg [7:0]  tile_x_q;
    reg [2:0]  tile_y_q;

    reg [8:0]  sprite_index;
    reg [9:0]  sprite_code_q;
    reg [3:0]  sprite_color_q;
    reg signed [10:0] sprite_x_q;
    reg [3:0]  sprite_y_q;
    reg        sprite_xflip_q;
    reg        sprite_wrap_q;
    reg        sprite_half;

    reg [15:0] gfx1_small_q,gfx1_large_q;
    reg gfx1_small_select_q;
    wire [15:0] gfx1_lo_q = gfx1_small_select_q ? gfx1_small_q : gfx1_large_q;
    reg [15:0] gfx1_hi_q;
    reg [15:0] gfx2_lo_q;
    reg [15:0] gfx2_hi_q;

    wire [7:0] scroll_byte[0:3],sprite_byte[0:3];
    genvar cache_lane;
    generate for(cache_lane=0;cache_lane<4;cache_lane=cache_lane+1)begin:cache_bytes
        a74_live_byte_cache scroll_store(
            .clk(clk_sys),.write_enable(reset_n && scan_valid_d && scan_address_d[13:10]==4'h8 && scan_address_d[1:0]==cache_lane[1:0]),
            .write_address(scan_address_d[9:2]),.write_data(vram_data),
            .read_address(bg_index[7:0]),.read_data(scroll_byte[cache_lane]));
        a74_live_byte_cache sprite_store(
            .clk(clk_sys),.write_enable(reset_n && scan_valid_d && scan_address_d[13:10]==4'h9 && scan_address_d[1:0]==cache_lane[1:0]),
            .write_address(scan_address_d[9:2]),.write_data(vram_data),
            .read_address(sprite_index[7:0]),.read_data(sprite_byte[cache_lane]));
    end endgenerate
    wire [31:0] current_scroll={scroll_byte[3],scroll_byte[2],scroll_byte[1],scroll_byte[0]};
    wire [31:0] current_sprite={sprite_byte[3],sprite_byte[2],sprite_byte[1],sprite_byte[0]};

    reg [7:0]  effective_scroll_x;
    reg [7:0]  background_x_calc;
    reg [7:0]  background_y_calc;
    reg [12:0] map_address_calc;
    reg [15:0] map_entry_calc;
    reg [7:0] map_entry_lo_q, map_entry_hi_q;
    reg [11:0] background_code_calc;
    reg [3:0]  background_color_calc;
    reg [2:0]  background_source_y_calc;

    always @* begin
        effective_scroll_x = current_scroll[31:24];
        if ((group_previous_id != 8'd1) &&
            (bg_index[7:0] != group_start[7:0]))
            effective_scroll_x = current_scroll[31:24] + global_scroll_x;

        if (render_flip)
            background_x_calc = 8'd248 - effective_scroll_x;
        else
            background_x_calc = effective_scroll_x;

        // scrolly = -byte0. The 8-bit arithmetic is intentionally modulo
        // 256, as are MAME's tile origins and the horizontal wrap copy.
        if (render_flip)
            background_y_calc = render_y[7:0] - 8'd248 + (8'd0 - current_scroll[7:0]);
        else
            background_y_calc = render_y[7:0] - (8'd0 - current_scroll[7:0]);

        map_address_calc = ( {5'd0, current_scroll[15:8]} << 6 ) +
                           ( {8'd0, background_y_calc[7:3]} << 1 );
        map_entry_calc = {map_entry_hi_q,map_entry_lo_q};
        background_code_calc = {map_entry_calc[11:8], map_entry_calc[7:0]};
        background_color_calc = map_entry_calc[15:12];
        if (render_flip)
            background_source_y_calc = 3'd7 - background_y_calc[2:0];
        else
            background_source_y_calc = background_y_calc[2:0];
    end

    wire signed [10:0] sprite_y_origin_raw =
        11'sd240 - $signed({3'b000, current_sprite[7:0]});
    wire signed [10:0] sprite_y_origin =
        render_flip ? (11'sd240 - sprite_y_origin_raw) : sprite_y_origin_raw;
    wire signed [10:0] render_y_signed = $signed({2'b00, render_y});
    wire signed [10:0] sprite_y_delta = render_y_signed - sprite_y_origin;
    wire sprite_y_hit = (sprite_y_delta >= 11'sd0) && (sprite_y_delta < 11'sd16);
    wire signed [10:0] sprite_x_origin = render_flip
        ? (11'sd240 - $signed({3'b000, current_sprite[31:24]}))
        :  $signed({3'b000, current_sprite[31:24]});
    wire [3:0] sprite_source_y_calc = (render_flip ^ current_sprite[15])
        ? (4'd15 - sprite_y_delta[3:0]) : sprite_y_delta[3:0];
    wire sprite_hflip_calc = render_flip ^ current_sprite[14];
    wire [9:0] sprite_code_calc = {current_sprite[13:12], current_sprite[23:16]};
    wire [3:0] sprite_color_calc = current_sprite[11:8];
    wire sprite_wrap_calc = !render_flip && (sprite_x_origin > 11'sd240);
    wire sprite_source_half = sprite_xflip_q ? ~sprite_half : sprite_half;

    wire [14:0] char_rom_address = {tile_code_q, tile_y_q};
    // MAME spritelayout: right half +128 bits; bottom half +256 bits.
    // Eight consecutive 16-bit rows form each 8x8 quadrant.
    wire [14:0] sprite_rom_address = {sprite_code_q, sprite_y_q[3],
                                     sprite_source_half, sprite_y_q[2:0]};

    // Keep RAM outputs free of reset/state muxes so Quartus can pack the
    // complete graphics regions into M10K. ST_*_ROM still supplies one edge
    // at the selected address before ST_*_DRAW consumes these registers.
    always @(posedge clk_sys) begin
        map_entry_lo_q <= tile_lo_data;
        map_entry_hi_q <= tile_hi_data;
        gfx1_small_q <= gfx1_lo_mlab[char_rom_address[12:0]];
        gfx1_large_q <= gfx1_lo_m10k[char_rom_address-15'd6144];
        gfx1_small_select_q <= char_rom_address<15'd6144;
        gfx1_hi_q <= gfx1_hi[char_rom_address];
        gfx2_lo_q <= gfx2_lo[sprite_rom_address];
        gfx2_hi_q <= gfx2_hi[sprite_rom_address];
    end

    reg       display_bank;
    reg       display_line_found;
    wire [8:0] display_palette_index;
    wire active_pixel = display_valid && (display_x < 9'd256) &&
                        (display_y >= 9'd16) && (display_y <= 9'd239);

    always @* begin
        display_bank = 1'b0;
        display_line_found = 1'b0;
        if (line_tag_valid[0] && (line_tag[0] == display_y)) begin
            display_bank = 1'b0;
            display_line_found = 1'b1;
        end else if (line_tag_valid[1] && (line_tag[1] == display_y)) begin
            display_bank = 1'b1;
            display_line_found = 1'b1;
        end


    end

    // This renderer presents the requested palette entry during the same
    // CE_PIXEL interval as the input h/v request. A registered PROM stage
    // should register RGB and its active/sync tuple together on that edge.
    assign palette_index = display_palette_index;
    assign pixel_valid = ce_pixel && active_pixel;

    function automatic [3:0] decode_8pixel(
        input [15:0] low_plane_word,
        input [15:0] high_plane_word,
        input [2:0]  pixel_x
    );
        reg [7:0] low_plane_byte;
        reg [7:0] high_plane_byte;
        reg [2:0] bit_index;
        begin
            low_plane_byte  = pixel_x[2] ? low_plane_word[15:8]  : low_plane_word[7:0];
            high_plane_byte = pixel_x[2] ? high_plane_word[15:8] : high_plane_word[7:0];
            // MAME readbit is MSB-first and layout plane 0 is pen bit 3.
            bit_index = {1'b0, pixel_x[1:0]};
            decode_8pixel[3] = high_plane_byte[bit_index + 3'd4];
            decode_8pixel[2] = high_plane_byte[bit_index];
            decode_8pixel[1] = low_plane_byte[bit_index + 3'd4];
            decode_8pixel[0] = low_plane_byte[bit_index];
        end
    endfunction

    integer draw_pixel;
    reg [3:0] draw_pen;
    reg signed [11:0] draw_x_signed;
    reg [7:0] draw_x_wrapped;
    reg [2:0] draw_char_x;

    reg [7:0] line_write_x,line_write_mask;
    reg [71:0] line_write_pixels;
    wire [8:0] stored_pixel;
    always @* begin
        line_write_x=0;line_write_mask=0;line_write_pixels={8{9'd511}};
        draw_char_x=0;draw_pen=0;draw_x_signed=0;draw_x_wrapped=0;
        if(reset_n)begin
            if(state==ST_CLEAR)begin line_write_x=clear_index[7:0];line_write_mask=1;end
            else if(state==ST_BG_DRAW || state==ST_TOP_DRAW)begin
                line_write_x=tile_x_q;
                for(draw_pixel=0;draw_pixel<8;draw_pixel=draw_pixel+1)begin
                    draw_char_x=render_flip?(3'd7-draw_pixel[2:0]):draw_pixel[2:0];
                    draw_pen=decode_8pixel(gfx1_lo_q,gfx1_hi_q,draw_char_x);
                    line_write_mask[draw_pixel]=draw_pen!=4'd15;
                    line_write_pixels[draw_pixel*9+:9]={1'b0,tile_color_q,draw_pen};
                end
            end else if(state==ST_SPR_DRAW)begin
                line_write_x=sprite_x_q[7:0]+{4'd0,sprite_half,3'b000};
                for(draw_pixel=0;draw_pixel<8;draw_pixel=draw_pixel+1)begin
                    draw_char_x=sprite_xflip_q?(3'd7-draw_pixel[2:0]):draw_pixel[2:0];
                    draw_pen=decode_8pixel(gfx2_lo_q,gfx2_hi_q,draw_char_x);
                    draw_x_signed=$signed({sprite_x_q[10],sprite_x_q})+$signed({8'd0,sprite_half,3'b000})+$signed({9'd0,draw_pixel[2:0]});
                    line_write_mask[draw_pixel]=(draw_pen!=4'd15) &&
                        (((draw_x_signed>=0)&&(draw_x_signed<256)) || (sprite_wrap_q && draw_x_signed>=256));
                    line_write_pixels[draw_pixel*9+:9]={1'b1,sprite_color_q,draw_pen};
                end
            end
        end
    end
    a74_line_buffer line_store(.clk(clk_sys),.write_bank(render_bank),.write_x(line_write_x),
        .write_mask(line_write_mask),.write_pixels(line_write_pixels),.read_bank(display_bank),
        .read_valid(ce_pixel && active_pixel && display_line_found),.read_x(display_x[7:0]),.read_pixel(stored_pixel));
    assign display_palette_index=(active_pixel && display_line_found)?stored_pixel:9'd511;

    // One-cycle synchronous scan port. Addresses are emitted monotonically
    // over the full 0x0000..0x27ff map; returned data updates the local mirror.
    always @(posedge clk_sys) begin
        if (!reset_n) begin
            vram_address  <= 14'd0;
            scan_address_d <= 14'd0;
            scan_valid_d <= 1'b0;
            vram_cache_ready <= 1'b0;
        end else begin
            scan_address_d <= vram_address;
            scan_valid_d <= 1'b1;
            if (vram_address == VRAM_LAST)
                vram_address <= 14'd0;
            else
                vram_address <= vram_address + 14'd1;

            if (scan_valid_d) begin
                if (scan_address_d == VRAM_LAST)
                    vram_cache_ready <= 1'b1;
            end
        end
    end

    a74_live_byte_cache #(.AW(12)) tile_lo_store(.clk(clk_sys),
        .write_enable(reset_n && scan_valid_d && scan_address_d<14'h2000 && !scan_address_d[0]),
        .write_address(scan_address_d[12:1]),.write_data(vram_data),.read_address(map_address_calc[12:1]),.read_data(tile_lo_data));
    a74_live_byte_cache #(.AW(12)) tile_hi_store(.clk(clk_sys),
        .write_enable(reset_n && scan_valid_d && scan_address_d<14'h2000 && scan_address_d[0]),
        .write_address(scan_address_d[12:1]),.write_data(vram_data),.read_address(map_address_calc[12:1]),.read_data(tile_hi_data));

    // HPS WIDE=1 exposes an even byte offset and a 16-bit data beat. Convert
    // the byte offset to a word index before splitting each 0x20000-byte ROM
    // into its lower and upper 0x10000-byte planes. PROM indexes 5/6 are not
    // consumed here: the parent owns RGB PROM lookup, and MAME ignores prio.
    always @(posedge clk_sys) begin
        if (ioctl_wr) begin
            if ((ioctl_index == 16'd3) && (ioctl_addr < 27'd131072)) begin
                if (ioctl_addr[16])
                    gfx1_hi[ioctl_addr[15:1]] <= ~ioctl_dout;
                else if(ioctl_addr[15:1]<15'd6144)
                    gfx1_lo_mlab[ioctl_addr[15:1]] <= ~ioctl_dout;
                else
                    gfx1_lo_m10k[ioctl_addr[15:1]-15'd6144] <= ~ioctl_dout;
            end else if ((ioctl_index == 16'd4) && (ioctl_addr < 27'd131072)) begin
                if (ioctl_addr[16])
                    gfx2_hi[ioctl_addr[15:1]] <= ~ioctl_dout;
                else
                    gfx2_lo[ioctl_addr[15:1]] <= ~ioctl_dout;
            end
        end
    end

    always @(posedge clk_sys) begin
        if (!reset_n) begin
            state <= ST_IDLE;
            line_tag_valid <= 2'b00;
            line_tag[0] <= 9'd0;
            line_tag[1] <= 9'd0;
            render_bank <= 1'b0;
            render_y <= 9'd0;
            render_flip <= 1'b0;
            clear_index <= 9'd0;
            bg_index <= 9'd0;
            group_start <= 9'd0;
            previous_id <= 8'hff;
            group_id <= 8'd0;
            group_previous_id <= 8'hff;
            global_scroll_x <= 8'd0;
            top_count <= 9'd0;
            top_index <= 9'd0;
            tile_code_q <= 12'd0;
            tile_color_q <= 4'd0;
            tile_x_q <= 8'd0;
            tile_y_q <= 3'd0;
            sprite_index <= 9'd0;
            sprite_code_q <= 10'd0;
            sprite_color_q <= 4'd0;
            sprite_x_q <= 11'sd0;
            sprite_y_q <= 4'd0;
            sprite_xflip_q <= 1'b0;
            sprite_wrap_q <= 1'b0;
            sprite_half <= 1'b0;
        end else begin
            if ((state == ST_IDLE) && ce_pixel && (h_counter == 9'd0) &&
                vram_cache_ready && (prefetch_y >= 9'd16) &&
                (prefetch_y <= 9'd239)) begin
                render_bank <= ~display_bank;
                render_y <= prefetch_y;
                render_flip <= flip_screen;
                line_tag[~display_bank] <= prefetch_y;
                line_tag_valid[~display_bank] <= 1'b0;
                clear_index <= 9'd0;
                top_count <= 9'd0;
                top_index <= 9'd0;
                state <= ST_CLEAR;
            end

            case (state)
                ST_IDLE: begin
                    // Line start above selects the next visible line.
                end

                ST_CLEAR: begin

                    if (clear_index == 9'd255) begin
                        bg_index <= 9'd0;
                        previous_id <= 8'hff;
                        state <= ST_BG_SCAN;
                    end else begin
                        clear_index <= clear_index + 9'd1;
                    end
                end

                ST_BG_SCAN: begin
                    if (bg_index == 9'd256) begin
                        sprite_index <= 9'd255;
                        state <= ST_SPR_SCAN;
                    end else if (current_scroll[16] /* ID bit 0 */) begin
                        previous_id <= current_scroll[23:16];
                        bg_index <= bg_index + 9'd1;
                    end else begin
                        group_id <= current_scroll[23:16];
                        group_start <= bg_index;
                        group_previous_id <= previous_id;
                        global_scroll_x <= 8'd0;
                        state <= ST_BG_WAIT;
                    end
                end

                ST_BG_WAIT: state <= ST_BG_ENTRY;

                ST_BG_ENTRY: begin
                    if (bg_index == 9'd256) begin
                        sprite_index <= 9'd255;
                        state <= ST_SPR_SCAN;
                    end else if (current_scroll[23:16] != group_id) begin
                        previous_id <= group_id;
                        state <= ST_BG_SCAN;
                    end else if (current_scroll == 32'd0) begin
                        bg_index <= bg_index + 9'd1;
                        state <= ST_BG_WAIT;
                    end else begin
                        if ((group_previous_id != 8'd1) && (bg_index == group_start))
                            global_scroll_x <= current_scroll[31:24];

                        if (background_color_calc == 4'hd) begin
                            top_queue[top_count[7:0]] <= {
                                background_code_calc,
                                background_color_calc,
                                background_x_calc,
                                background_source_y_calc
                            };
                            top_count <= top_count + 9'd1;
                            bg_index <= bg_index + 9'd1;
                            state <= ST_BG_WAIT;
                        end else begin
                            tile_code_q <= background_code_calc;
                            tile_color_q <= background_color_calc;
                            tile_x_q <= background_x_calc;
                            tile_y_q <= background_source_y_calc;
                            state <= ST_BG_ROM;
                        end
                    end
                end

                ST_BG_ROM: begin
                    state <= ST_BG_DRAW;
                end

                ST_BG_DRAW: begin

                    bg_index <= bg_index + 9'd1;
                    state <= ST_BG_WAIT;
                end

                ST_SPR_SCAN: begin
                    if (!sprite_y_hit) begin
                        if (sprite_index == 9'd0)
                            state <= ST_TOP_SCAN;
                        else
                            sprite_index <= sprite_index - 9'd1;
                    end else begin
                        sprite_code_q <= sprite_code_calc;
                        sprite_color_q <= sprite_color_calc;
                        sprite_x_q <= sprite_x_origin;
                        sprite_y_q <= sprite_source_y_calc;
                        sprite_xflip_q <= sprite_hflip_calc;
                        sprite_wrap_q <= sprite_wrap_calc;
                        sprite_half <= 1'b0;
                        state <= ST_SPR_ROM;
                    end
                end

                ST_SPR_ROM: begin
                    state <= ST_SPR_DRAW;
                end

                ST_SPR_DRAW: begin


                    if (!sprite_half) begin
                        sprite_half <= 1'b1;
                        state <= ST_SPR_ROM;
                    end else if (sprite_index == 9'd0) begin
                        state <= ST_TOP_SCAN;
                    end else begin
                        sprite_index <= sprite_index - 9'd1;
                        state <= ST_SPR_SCAN;
                    end
                end

                ST_TOP_SCAN: begin
                    if (top_index >= top_count) begin
                        state <= ST_DONE;
                    end else begin
                        tile_code_q <= top_record[26:15];
                        tile_color_q <= top_record[14:11];
                        tile_x_q <= top_record[10:3];
                        tile_y_q <= top_record[2:0];
                        state <= ST_TOP_ROM;
                    end
                end

                ST_TOP_ROM: begin
                    state <= ST_TOP_DRAW;
                end

                ST_TOP_DRAW: begin

                    top_index <= top_index + 9'd1;
                    state <= ST_TOP_SCAN;
                end

                ST_DONE: begin
                    line_tag[render_bank] <= render_y;
                    line_tag_valid[render_bank] <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
