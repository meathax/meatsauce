// SPDX-License-Identifier: GPL-3.0-or-later
// Target wiring around the pinned rmonic79 Seibu renderer and ROM arbiter engines.
module ZeroTeam_video #(parameter SEPARATE_TIMING_RESET=0) (
    input wire clk, reset,
    input wire timing_reset,
    input wire [4:0] layer_enable,
    input wire flip_screen,
    input wire [15:0] bg_x,bg_y,mg_x,mg_y,fg_x,fg_y,tx_x,tx_y,
    output wire [10:0] bg_address,mg_address,fg_address,tx_address,spr_address,pal_address,
    input wire [15:0] bg_data,mg_data,fg_data,tx_data,spr_data,pal_data,
    output wire rom_request,
    output wire [23:0] rom_address,
    output wire [2:0] rom_kind,
    // Tile/text {first LE16,second LE16}; sprite native LE32 (original DDR path).
    input wire [31:0] rom_data,
    input wire rom_valid,
    // Dedicated sprite row port (ZeroTeam_rom_bridge spr_*): encrypted LE32
    // halves of one 8-byte row, decrypted here.
    output wire sprite_rom_request,
    output wire [23:0] sprite_rom_address,
    input wire [31:0] sprite_rom_data,
    input wire sprite_rom_valid,
    input wire sprite_rom_half,
    output wire ce_pixel,display_enable,hblank,vblank,hsync,vsync,
    output wire [9:0] x,
    output wire [8:0] y,
    output wire [7:0] r,g,b,
    output wire pixel_strobe,pixel_display,
    output wire [9:0] pixel_x,
    output wire [8:0] pixel_y
);
    wire [9:0] hpos,vpos,h_start;
    wire [8:0] v_start;
    Raiden2_video_timing timing (
        .clk(clk),.reset(SEPARATE_TIMING_RESET ? timing_reset : reset),.mode_60hz(1'b0),.ce_pix(ce_pixel),
        .hpos(hpos),.vpos(vpos),.active_x(x),.active_y(y),
        .hblank(hblank),.vblank(vblank),.hsync(hsync),.vsync(vsync),
        .de(display_enable),.h_vis_start(h_start),.v_vis_start(v_start)
    );
    reg [9:0] h_prev;
    always @(posedge clk) if(reset)h_prev<=10'h3ff; else if(ce_pixel)h_prev<=hpos;
    wire new_line=ce_pixel && hpos==0 && h_prev!=0;
    wire [8:0] logical_y=vpos[8:0]-v_start;
    // Fetch row zero after vblank DMA has settled, immediately before line zero.
    // Row 255 must still swap into display. The late-vblank trigger refreshes
    // row zero again after DMA; its earlier speculative copy is never displayed.
    wire [8:0] prefetch_y=(vpos==281)?9'd255:logical_y;
    wire [9:0] read_x=flip_screen?(10'd319-x):x;
    // Prime the first column during blanking; normal lookahead resumes in active video.
    wire [9:0] next_x=hblank ? (flip_screen?10'd319:10'd0) : (flip_screen?(read_x-10'd1):(read_x+10'd1));
    // The sprite read port anticipates the next raster pixel; DE must match it.
    wire sprite_de=(hpos<10'd319 && vpos<10'd256) ||
                   (hpos==10'd511 && (vpos<10'd255 || vpos==10'd281));
    wire [4:0] requests,valids;
    wire [23:0] addresses [0:4];
    wire [31:0] data [0:4];
    wire [3:0] opaque;
    wire [10:0] pens [0:4];
    wire sprite_opaque;
    wire [1:0] sprite_priority;
    // External sprite ROM stays encrypted. The real RTL transform follows the
    // sprite-port response (one register stage); the word index is the half's
    // own 32-bit address. Tile/text words receive the same one-clock delay.
    wire [31:0] sprite_plain;
    reg [31:0] graphics_word_q;
    reg graphics_valid_q;
    reg sprite_valid_q,sprite_half_q;
    zeroteam_sprite_decrypt sprite_cipher (
        .clk(clk),.widx({sprite_rom_address[23:3],sprite_rom_half}),.din(sprite_rom_data),.dout(sprite_plain)
    );
    always @(posedge clk) begin
        if(reset) begin graphics_valid_q<=0; sprite_valid_q<=0; end
        else begin graphics_valid_q<=rom_valid; sprite_valid_q<=sprite_rom_valid; end
        if(rom_valid) graphics_word_q<=rom_data;
        sprite_half_q<=sprite_rom_half;
    end
    wire [31:0] graphics_word=graphics_word_q;
    // Label the pixel when the mixer samples the renderer outputs, then retain
    // its coordinates until the final RGB is ready. No host-side alignment offsets.
    reg ce_delay;
    reg [9:0] sampled_x;
    reg [8:0] sampled_y;
    always @(posedge clk) begin
        ce_delay<=ce_pixel;
        if(ce_delay)begin sampled_x<=x; sampled_y<=y; end
    end
    assign pixel_x=sampled_x;
    assign pixel_y=sampled_y;
    Raiden2_text_renderer text_layer (
        .clk(clk),.reset(reset),.ce_pix(ce_pixel),.hpos(read_x),.hpos_rd(next_x),
        .vpos(prefetch_y),.flip_screen(flip_screen),.de(display_enable),
        .layer_en(layer_enable[3]),.new_line(new_line),.scroll_x(tx_x),.scroll_y(tx_y),
        .xoff(10'sd0),.yoff(10'sd0),.vram_addr(tx_address),.vram_data(tx_data),
        .rom_req(requests[4]),.rom_addr(addresses[4]),.rom_data(data[4]),.rom_valid(valids[4]),
        .opaque(opaque[3]),.pen_index(pens[4])
    );
    Raiden2_tile_layer #(.COLOR_BASE(11'h400),.HAS_TRANSP(1),.TILE_KIND(0)) bg_layer (
        .clk(clk),.reset(reset),.ce_pix(ce_pixel),.hpos(read_x),.hpos_rd(next_x),
        .vpos(prefetch_y),.flip_screen(flip_screen),.de(display_enable),
        .layer_en(layer_enable[0]),.new_line(new_line),.scroll_x(bg_x),.scroll_y(bg_y),
        .xoff(10'sd0),.yoff(10'sd0),.gfx_bank(16'd0),.vram_addr(bg_address),.vram_data(bg_data),
        .rom_req(requests[0]),.rom_addr(addresses[0]),.rom_data(data[0]),.rom_valid(valids[0]),
        .opaque(opaque[0]),.pen_index(pens[0])
    );
    Raiden2_tile_layer #(.COLOR_BASE(11'h600),.HAS_TRANSP(1),.TILE_KIND(1)) mg_layer (
        .clk(clk),.reset(reset),.ce_pix(ce_pixel),.hpos(read_x),.hpos_rd(next_x),
        .vpos(prefetch_y),.flip_screen(flip_screen),.de(display_enable),
        .layer_en(layer_enable[1]),.new_line(new_line),.scroll_x(mg_x),.scroll_y(mg_y),
        .xoff(10'sd0),.yoff(10'sd0),.gfx_bank(16'd1),.vram_addr(mg_address),.vram_data(mg_data),
        .rom_req(requests[1]),.rom_addr(addresses[1]),.rom_data(data[1]),.rom_valid(valids[1]),
        .opaque(opaque[1]),.pen_index(pens[1])
    );
    Raiden2_tile_layer #(.COLOR_BASE(11'h500),.HAS_TRANSP(1),.TILE_KIND(2)) fg_layer (
        .clk(clk),.reset(reset),.ce_pix(ce_pixel),.hpos(read_x),.hpos_rd(next_x),
        .vpos(prefetch_y),.flip_screen(flip_screen),.de(display_enable),
        .layer_en(layer_enable[2]),.new_line(new_line),.scroll_x(fg_x),.scroll_y(fg_y),
        .xoff(10'sd0),.yoff(10'sd0),.gfx_bank(16'd2),.vram_addr(fg_address),.vram_data(fg_data),
        .rom_req(requests[2]),.rom_addr(addresses[2]),.rom_data(data[2]),.rom_valid(valids[2]),
        .opaque(opaque[2]),.pen_index(pens[2])
    );
    Raiden2_sprite_renderer #(.BLANK_UPPER_HALF(1)) sprite_layer (
        .clk(clk),.reset(reset),.ce_pix(ce_pixel),.hpos(next_x),.vpos(prefetch_y),
        .flip_screen(flip_screen),.de(sprite_de),.layer_en(layer_enable[4]),
        .new_line(new_line),.xoff(10'sd0),.yoff(10'sd0),.spr_addr(spr_address),.spr_data(spr_data),
        .rom_req(sprite_rom_request),.rom_addr(sprite_rom_address),.rom_data(sprite_plain),
        .rom_valid(sprite_valid_q),.rom_half(sprite_half_q),
        .opaque(sprite_opaque),.pen_index(pens[3]),.pri_code(sprite_priority)
    );
    tile_rom_arbiter arbiter (
        .clk(clk),.reset(reset),.hblank(hblank),
        .r0_req(requests[0]),.r0_addr(addresses[0]),.r0_data(data[0]),.r0_valid(valids[0]),
        .r1_req(requests[1]),.r1_addr(addresses[1]),.r1_data(data[1]),.r1_valid(valids[1]),
        .r2_req(requests[2]),.r2_addr(addresses[2]),.r2_data(data[2]),.r2_valid(valids[2]),
        // Sprites use their own bridge port; arbiter client 3 is idle.
        .r3_req(1'b0),.r3_addr(24'd0),.r3_data(data[3]),.r3_valid(valids[3]),
        .r4_req(requests[4]),.r4_addr(addresses[4]),.r4_data(data[4]),.r4_valid(valids[4]),
        .tile_req(rom_request),.tile_addr(rom_address),.tile_kind(rom_kind),
        .tile_data(graphics_word),.tile_valid(graphics_valid_q)
    );
    raiden2_mixer #(.ZERO_TEAM(1)) mixer (
        .clk(clk),.ce_pix(ce_pixel),.spr_pen(pens[3]),
        .spr_pri0(sprite_opaque && sprite_priority==0),.spr_pri1(sprite_opaque && sprite_priority==1),
        .spr_pri2(sprite_opaque && sprite_priority==2),.spr_pri3(sprite_opaque && sprite_priority==3),
        .bg_pen(pens[0]),.bg_opaque(opaque[0]),.mg_pen(pens[1]),.mg_opaque(opaque[1]),
        .fg_pen(pens[2]),.fg_opaque(opaque[2]),.text_pen(pens[4]),.text_opaque(opaque[3]),
        .video_de(display_enable),.pal_addr(pal_address),.pal_word(pal_data),.rgb_r(r),.rgb_g(g),.rgb_b(b),
        .pixel_strobe(pixel_strobe),.pixel_display(pixel_display)
    );
endmodule
