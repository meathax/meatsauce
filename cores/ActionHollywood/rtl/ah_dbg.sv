// On-screen hardware debug page (OSD option "Debug Page").  Collects bring-up evidence that a Verilator run with a
// preloaded SDRAM cannot show: what the 68000 actually fetched from SDRAM, how far it ran, whether it wrote video RAM.
// Rows (hex, label nibble + 32-bit value), expected values for a healthy boot in brackets:
//  0 flags  {..., pause[4], pll_locked[5], dl_seen[3], dl[2], ready[1], game_rst[0]}   [0000002A + dl_seen ; rst=0, ready=1]
//  1 loader words written (16-bit)                                           [00300000 hex = 3145728 for the full MRA image]
//  2 68000 ROM-port acks since reset                                          [grows]
//  3 first  ROM dword  (addr 0)   bytes 00 FF 0F FC read little endian      [FC0FFF00]  (sim-verified)
//  4 second ROM dword  (addr 4)                                              [00040000]  (sim-verified)
//  5 third  ROM dword  (addr 8)                                              [52390000]  (sim-verified)
//  6 last ROM dword address (word index)  and last data
//  7 vblank interrupts since reset                                           [grows ~60/s]
//  8 palette RAM writes   9 tilemap RAM writes   A sprite RAM writes   B GFX acks   C last video-slice cpu_addr
module ah_dbg(
    input  wire        clk, rst,
    input  wire        rom_ack, input wire [22:2] rom_addr, input wire [31:0] rom_data,
    input  wire        vid_cs, vid_ack, cpu_rw, input wire [23:1] cpu_addr,
    input  wire        vint, gfx_ack,
    output wire [32*13-1:0] words
);
reg [31:0] rom_n, d0, d1, d2, last_a, last_d, vint_n, pal_n, til_n, spr_n, gfx_n, last_v;
wire [23:0] a = {cpu_addr, 1'b0};
wire wr = vid_cs & vid_ack & ~cpu_rw;
always @(posedge clk) begin
    if (rst) begin
        rom_n <= 0; d0 <= 0; d1 <= 0; d2 <= 0; last_a <= 0; last_d <= 0; vint_n <= 0; pal_n <= 0; til_n <= 0; spr_n <= 0; gfx_n <= 0; last_v <= 0;
    end else begin
        if (rom_ack) begin
            rom_n <= rom_n + 1; last_a <= {11'd0, rom_addr}; last_d <= rom_data;
            if (rom_n == 0) d0 <= rom_data;
            if (rom_n == 1) d1 <= rom_data;
            if (rom_n == 2) d2 <= rom_data;
        end
        if (vint) vint_n <= vint_n + 1;
        if (gfx_ack) gfx_n <= gfx_n + 1;
        if (vid_cs & vid_ack) last_v <= {8'd0, a};
        if (wr) begin
            if (a[23:11] == 13'h1800) pal_n <= pal_n + 1;
            else if (a[23:15] == 9'h140 && a[14] == 1'b0 || a[23:14] == 10'h281 || a[23:14] == 10'h282) til_n <= til_n + 1;
            else if (a[23:11] == 13'h1600) spr_n <= spr_n + 1;
        end
    end
end
// words[0], words[1] (flags, loader count) are supplied by the wrapper through the same bus order: here the lower two slots are zero
assign words = {last_v, gfx_n, spr_n, til_n, pal_n, vint_n, last_a, d2, d1, d0, rom_n, 32'd0, 32'd0} ;
endmodule

// Text renderer: 4x5 hex font scaled 3x, cell 16x18 px, row r starts at y = 12 + 18*r, text at x = 16.
module ah_dbg_osd(
    input  wire        clk,
    input  wire [9:0]  x, y,                     // raster counters of ah_video (active x 82..433, y 0..239)
    input  wire [32*13-1:0] words,
    output reg         pix
);
function [19:0] glyph(input [3:0] n);
    case (n)
        4'h0: glyph = {4'hF,4'h9,4'h9,4'h9,4'hF};  4'h1: glyph = {4'h2,4'h6,4'h2,4'h2,4'h7};
        4'h2: glyph = {4'hF,4'h1,4'hF,4'h8,4'hF};  4'h3: glyph = {4'hF,4'h1,4'hF,4'h1,4'hF};
        4'h4: glyph = {4'h9,4'h9,4'hF,4'h1,4'h1};  4'h5: glyph = {4'hF,4'h8,4'hF,4'h1,4'hF};
        4'h6: glyph = {4'hF,4'h8,4'hF,4'h9,4'hF};  4'h7: glyph = {4'hF,4'h1,4'h2,4'h4,4'h4};
        4'h8: glyph = {4'hF,4'h9,4'hF,4'h9,4'hF};  4'h9: glyph = {4'hF,4'h9,4'hF,4'h1,4'hF};
        4'hA: glyph = {4'h6,4'h9,4'hF,4'h9,4'h9};  4'hB: glyph = {4'hE,4'h9,4'hE,4'h9,4'hE};
        4'hC: glyph = {4'h7,4'h8,4'h8,4'h8,4'h7};  4'hD: glyph = {4'hE,4'h9,4'h9,4'h9,4'hE};
        4'hE: glyph = {4'hF,4'h8,4'hE,4'h8,4'hF};  default: glyph = {4'hF,4'h8,4'hE,4'h8,4'h8};
    endcase
endfunction
wire [9:0] px = (x >= 10'd82) ? x - 10'd82 + 10'd1 : 10'd0;   // pixel inside the 352-wide picture (1 px pipeline offset is irrelevant)
wire [9:0] tx = px - 10'd16;
wire [9:0] ty = y - 10'd4;
wire in_area = (px >= 10'd16) && (y >= 10'd4);
reg [3:0] row; reg [5:0] ci; reg [4:0] cx; reg [4:0] cy; reg line_ok;
reg [3:0] nib; reg [19:0] g;
always @(posedge clk) begin
    row <= ty / 10'd18; cy <= ty % 10'd18;
    ci  <= tx[9:4];    cx <= {1'b0, tx[3:0]};
end
wire [31:0] w = words[row*32 +: 32];
always @(posedge clk) begin
    nib <= (ci == 6'd0) ? row : (ci >= 6'd2 && ci <= 6'd9) ? w[(9 - ci[3:0])*4 +: 4] : 4'd0;
    g   <= glyph(nib);
    pix <= in_area && row <= 4'd12 && cy < 5'd15 && cx < 5'd12 && (ci == 6'd0 || (ci >= 6'd2 && ci <= 6'd9)) &&
           g[19 - ((cy / 5'd3) * 4 + (cx / 5'd3))];
end
endmodule
