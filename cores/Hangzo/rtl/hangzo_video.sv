// SPDX-License-Identifier: GPL-3.0-or-later
// Production video ownership. Raster and ROM arbitration are external.
`timescale 1ns/1ns
module hangzo_video #(
    parameter TILE0="",TILE1="",TILE2="",TILE3="",ROWS0="",ROWS1="",
    parameter SPRITES="",PALETTE="",
    parameter TILE_PREFETCH_NEXT=1
)(
    input wire clk,reset,pixel_ce,hs,vs,hblank,vblank,flip,frame_odd,
    input wire [8:0] hpos,vpos,
    input wire select,write,
    input wire [3:0] region,
    input wire [11:0] offset,
    input wire [15:0] write_data,
    input wire [1:0] byte_enable,
    output wire ready,
    output wire [15:0] read_data,
    input wire sprite_copy,palette_copy,
    output wire sprite_copy_ready,palette_copy_ready,sprite_busy,palette_busy,
    output wire sprite_valid,palette_valid,
    input wire [2:0] priority_control,
    output wire [3:0] rom_request,tile16,
    output wire [18:0] rom_address0,rom_address1,rom_address2,rom_address3,
    input wire [31:0] rom_data0,rom_data1,rom_data2,rom_data3,
    input wire [3:0] rom_ready,
    output wire sprite_request,
    output wire [20:0] sprite_address,
    input wire [31:0] sprite_data,
    input wire sprite_ready,
    output wire rgb_ce,
    output wire [23:0] rgb,
    output wire hblank_out,vblank_out,hs_out,vs_out,
    output wire [31:0] layers,
    output wire [12:0] sprite_pen,
    output wire [10:0] pen
);
    wire tile_ready,sram_ready,pram_ready,board_flip;
    wire [15:0] tile_data,sram_data,pram_data;
    wire [3:0] layer_enable;
    // The streaming engine fills its lead FIFO in HBlank. On a continuous
    // raster that prefetch belongs to the upcoming visible line. The frozen
    // component fixture supplies that line already and selects parameter0.
    wire [8:0] tile_vpos=(TILE_PREFETCH_NEXT && hblank) ? vpos+9'd1 : vpos;
    // The object RAM flips write banks at active->blank. Its opposite-bank
    // display therefore consumes this blank's work two visible lines later.
    // Hold that target across blank(v) -> active(v+1), including the final
    // sprite descriptors whose scan can cross the horizontal counter wrap.
    wire [8:0] sprite_vpos=(TILE_PREFETCH_NEXT && hblank) ? vpos+9'd2 : vpos+9'd1;
    assign ready = region>=1 && region<=10 ? tile_ready : region==11 ? sram_ready : region==12 ? pram_ready : 1'b0;
    assign read_data = region==11 ? sram_data : region==12 ? pram_data : tile_data;
    hangzo_tile_video #(.TILE0(TILE0),.TILE1(TILE1),.TILE2(TILE2),.TILE3(TILE3),.ROWS0(ROWS0),.ROWS1(ROWS1)) u_tiles(
        .clk(clk),.reset(reset),.pixel_ce(pixel_ce),.hs(hs),.flip(flip),.hpos(hpos),.vpos(tile_vpos),
        .select(select && region>=1 && region<=10),.write(write),.region(region),.offset(offset),
        .write_data(write_data),.byte_enable(byte_enable),.ready(tile_ready),.read_data(tile_data),
        .layers(layers),.tile16(tile16),.layer_enable(layer_enable),.board_flip(board_flip),
        .rom_request(rom_request),.rom_address0(rom_address0),.rom_address1(rom_address1),
        .rom_address2(rom_address2),.rom_address3(rom_address3),
        .rom_data0(rom_data0),.rom_data1(rom_data1),.rom_data2(rom_data2),.rom_data3(rom_data3),.rom_ready(rom_ready));
    wire [9:0] sprite_ram_address;
    wire [15:0] sprite_ram_data;
    // DMA can occur in active video. Publish a complete inactive sprite table
    // at VBlank entry, before any next-frame visible-line prefetch.
    wire sprite_publish=pixel_ce && hpos==0 && vpos==248;
    hangzo_buffered_ram #(.AW(10),.SOURCE_FILE(SPRITES),.FRAME_LATCH(1)) u_sprites(
        .clk(clk),.reset(reset),.select(select && region==11),.write(write),.address(offset[9:0]),
        .write_data(write_data),.byte_enable(byte_enable),.ready(sram_ready),.read_data(sram_data),
        .copy_request(sprite_copy),.publish(sprite_publish),.copy_ready(sprite_copy_ready),.busy(sprite_busy),.copy_done(),.display_valid(sprite_valid),
        .display_address(sprite_ram_address),.display_data(sprite_ram_data));
    wire [12:0] raw_sprite_pen;
    assign sprite_pen=sprite_valid ? raw_sprite_pen : 13'd0;
    hangzo_decospr u_sprite_engine(
        .rst(reset),.clk(clk),.pxl_cen(pixel_ce),.flip(!(flip ^ board_flip)),.pswap(1'b0),.frame_odd(frame_odd),
        .HS(hs),.LHBL(!hblank),.LVBL(!vblank),.vrender(sprite_vpos),.hdump(hpos),
        .oram_addr(sprite_ram_address),.oram_dout(sprite_ram_data),
        .rom_cs(sprite_request),.rom_addr(sprite_address),.rom_data(sprite_data),.rom_ok(sprite_ready),.pxl(raw_sprite_pen));
    hangzo_colmix u_mix(.layers(layers),.sprite_pixel(sprite_pen),.layer_enable(layer_enable),.priority_control(priority_control),.pen(pen));
    hangzo_palette #(.SOURCE_FILE(PALETTE)) u_palette(
        .clk(clk),.reset(reset),.select(select && region==12),.write(write),.address(offset),
        .write_data(write_data),.byte_enable(byte_enable),.ready(pram_ready),.read_data(pram_data),
        .copy_request(palette_copy),.copy_ready(palette_copy_ready),.busy(palette_busy),.copy_done(),.display_valid(palette_valid),
        .pixel_ce(pixel_ce),.pen(pen),.hblank(hblank),.vblank(vblank),.hs(hs),.vs(vs),
        .rgb_ce(rgb_ce),.rgb(rgb),.hblank_out(hblank_out),.vblank_out(vblank_out),.hs_out(hs_out),.vs_out(vs_out));
endmodule
