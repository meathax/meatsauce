// Tumble Pop bootleg playfields. The board uses the DECO tile layouts but
// supplies its own tile RAM and scroll registers; PF1 is a runtime choice
// between 8x8 characters and 16x16 tiles, while PF2 is always 16x16.
module tumble_video_tiles(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             hs,
    input      [ 8:0]  hdump,
    input      [ 8:0]  vdump,
    input             flip,
    input             pf1_chars,
    input      [ 1:0]  tile_mode,
    input      [ 3:0]  scroll_mode,
    input      [15:0]  tilebank,
    input      [15:0]  pf1_scrollx,
    input      [15:0]  pf1_scrolly,
    input      [15:0]  pf2_scrollx,
    input      [15:0]  pf2_scrolly,
    input             pf1_rowscroll,
    output     [10:0]  pf1_rsram_addr,
    input      [15:0]  pf1_rsram_data,

    output     [11:0]  pf1_ram_addr,
    input      [15:0]  pf1_ram_data,
    input      [15:0]  pf1_ram_data2,
    output     [11:0]  pf2_ram_addr,
    input      [15:0]  pf2_ram_data,
    input      [15:0]  pf2_ram_data2,

    output            pf1_rom_cs,
    output     [20:2]  pf1_rom_addr,
    input      [31:0]  pf1_rom_data,
    input             pf1_rom_ok,
    output            pf2_rom_cs,
    output     [20:2]  pf2_rom_addr,
    input      [31:0]  pf2_rom_data,
    input             pf2_rom_ok,

    output     [ 8:0]  pf1_pixel,
    output     [ 8:0]  pf2_pixel
);

// Tumble Pop uses a 442 x 274 raw raster, 320 x 240 visible. The renderer
// starts one pixel before the active line and fetches 42 columns to cover the
// visible 40 tiles plus the maximum scroll margin.
reg signed [15:0] pf1_xoff, pf1_yoff, pf2_xoff, pf2_yoff;
wire funky_scroll = scroll_mode == 4'd9;
wire funky_rowscroll = funky_scroll && pf1_rowscroll;
always @* begin
    pf1_xoff = flip ? -16'sd3 : -16'sd5;
    pf1_yoff = 16'sd0;
    pf2_xoff = flip ? 16'sd1 : -16'sd1;
    pf2_yoff = 16'sd0;
    case (scroll_mode)
        4'd4: begin
            pf1_xoff = -16'sd5;
            pf1_yoff = 16'sd0;
            pf2_xoff = -16'sd1;
            pf2_yoff = 16'sd2;
        end
        4'd5: begin
            pf1_xoff = flip ? -16'sd3 : 16'sd8;
            pf1_yoff = 16'sd0;
            pf2_xoff = flip ? 16'sd1 : 16'sd8;
            pf2_yoff = 16'sd0;
        end
        4'd6: begin
            pf1_xoff = -16'sd5;
            pf1_yoff = -16'sd16;
            pf2_xoff = -16'sd1;
            pf2_yoff = 16'sd0;
        end
        // Super Trio: screen_update_suprtrio scrolls by -control - 6 / - 2.
        4'd7: begin
            pf1_xoff = -16'sd6;
            pf1_yoff = 16'sd0;
            pf2_xoff = -16'sd2;
            pf2_yoff = 16'sd0;
        end
        // The Funky Jet bootleg IRQ subtracts 10/4 from the original game's
        // PF1/PF2 scrolls (ROM 0x1e8/0x1f8). Undo that board compensation,
        // then apply DECO16 scrolldx(1,1). Its world-select row table also
        // starts eight pixels earlier (ROM 0x894a/0x8952).
        4'd9: begin
            pf1_xoff = funky_rowscroll ? 16'sd17 : 16'sd9;
            pf2_xoff = 16'sd3;
        end
        default: ;
    endcase
end
wire        scroll_neg = scroll_mode == 4'd7;
wire [15:0] pf1_x = (scroll_neg ? -pf1_scrollx : pf1_scrollx) + pf1_xoff;
wire [15:0] pf1_y = (scroll_neg ? -pf1_scrolly : pf1_scrolly) + pf1_yoff;
wire [15:0] pf2_x = (scroll_neg ? -pf2_scrollx : pf2_scrollx) + pf2_xoff;
wire [15:0] pf2_y = (scroll_neg ? -pf2_scrolly : pf2_scrolly) + pf2_yoff;
wire pair_mode = tile_mode != 2'd0;
wire pangpang_mode = tile_mode == 2'd2;
wire [15:0] pf1_code = pangpang_mode ? pf1_ram_data2 : pf1_ram_data;
wire [15:0] pf1_attr = pangpang_mode ? pf1_ram_data : pf1_ram_data2;
wire [15:0] pf2_code = pangpang_mode ? pf2_ram_data2 : pf2_ram_data;
wire [15:0] pf2_attr = pangpang_mode ? pf2_ram_data : pf2_ram_data2;
wire [3:0]  pf1_pair_color = pangpang_mode ? pf1_attr[15:12] : pf1_attr[3:0];
wire [3:0]  pf2_pair_color = pangpang_mode ? pf2_attr[15:12] : pf2_attr[3:0];
// Generic bootleg maps OR the complete software bank into the character code
// or its >>2 form into the 16x16 code. Paired maps carry their own code bits.
wire [11:0] pf1_code_low = pf1_ram_data[11:0] |
    (pf1_chars ? tilebank[11:0] : tilebank[13:2]);
wire [11:0] pf2_code_low = pf2_ram_data[11:0] | tilebank[13:2];
wire [15:0] pf1_tile_word = pair_mode ? {pf1_pair_color,pf1_code[11:0]} :
    {pf1_ram_data[15:12],pf1_code_low};
wire [15:0] pf2_tile_word = pair_mode ? {pf2_pair_color,pf2_code[11:0]} :
    {pf2_ram_data[15:12],pf2_code_low};
wire        pf1_code_high = pair_mode ? pf1_code[12] :
                           (pf1_chars ? tilebank[12] : tilebank[14]);
wire        pf2_code_high = pair_mode ? (pangpang_mode || pf2_code[12]) : tilebank[14];
wire        pf1_color_high = tile_mode == 2'd1 && pf1_attr[4];
wire        pf2_color_high = tile_mode == 2'd1 && pf2_attr[4];
wire [2:0] pf1_code_bank = pair_mode ? 3'd0 :
    (pf1_chars ? tilebank[15:13] : {1'b0,tilebank[15],1'b0});
wire [2:0] pf2_code_bank = pair_mode ? 3'd0 : {1'b0,tilebank[15],1'b0};
wire [8:0] pf1_pixel_raw, pf2_pixel_raw;
wire pf1_pixel_valid, pf2_pixel_valid;
// An empty or stalled stream uses the board's transparent pen. Family C's
// pen0 is opaque, so it must receive pen15 when no fetched column is valid.
assign pf1_pixel = pf1_pixel_valid ? pf1_pixel_raw : (tile_mode == 2'd1 ? 9'h00f : 9'd0);
assign pf2_pixel = pf2_pixel_valid ? pf2_pixel_raw : (tile_mode == 2'd1 ? 9'h00f : 9'd0);

jtcninja_deco16 #(.COLORW(5), .HTOTAL(442), .NCOLS(42), .HFLIP_END(319), .ROM_AW(19)) u_pf1(
    .rst        ( rst          ),
    .clk        ( clk          ),
    .pxl_cen    ( pxl_cen      ),
    .hs         ( hs           ),
    .vdump      ( vdump        ),
    .hdump      ( hdump        ),
    .flip       ( flip         ),
    .fullheight ( pf1_chars && scroll_mode == 4'd6 ),
    .scrollx    ( pf1_x        ),
    .scrolly    ( pf1_y        ),
    // The bootleg omits the IRQ write of control[5]. Its program only
    // supplies two row entries, split at source Y=128 (DECO style 7).
    .control0   ( funky_scroll ? 8'hb8 : 8'h80 ),
    .control1   ( {pf1_chars,funky_rowscroll,6'd0} ),
    .bank       ( pf1_code_bank ),
    .pswap      ( 1'b0         ),
    .rowmajor   ( 1'b0         ),
    .ram_addr   ( pf1_ram_addr ),
    .ram_data   ( pf1_tile_word ),
    .ram_code_high ( pf1_code_high ),
    .ram_color_high ( pf1_color_high ),
    .rsram_addr ( pf1_rsram_addr ),
    .rsram_data ( pf1_rsram_data ),
    .rom_cs     ( pf1_rom_cs   ),
    .rom_addr   ( pf1_rom_addr ),
    .rom_data   ( pf1_rom_data ),
    .rom_ok     ( pf1_rom_ok   ),
    .pxl        ( pf1_pixel_raw ),
    .pixel_valid( pf1_pixel_valid )
);

jtcninja_deco16 #(.COLORW(5), .HTOTAL(442), .NCOLS(42), .HFLIP_END(319), .ROM_AW(19)) u_pf2(
    .rst        ( rst          ),
    .clk        ( clk          ),
    .pxl_cen    ( pxl_cen      ),
    .hs         ( hs           ),
    .vdump      ( vdump        ),
    .hdump      ( hdump        ),
    .flip       ( flip         ),
    .fullheight ( 1'b0         ),
    .scrollx    ( pf2_x        ),
    .scrolly    ( pf2_y        ),
    .control0   ( 8'h80        ),
    .control1   ( 8'h00        ),
    .bank       ( pf2_code_bank ),
    .pswap      ( 1'b0         ),
    .rowmajor   ( 1'b0         ),
    .ram_addr   ( pf2_ram_addr ),
    .ram_data   ( pf2_tile_word ),
    .ram_code_high ( pf2_code_high ),
    .ram_color_high ( pf2_color_high ),
    .rsram_addr (              ),
    .rsram_data ( 16'd0        ),
    .rom_cs     ( pf2_rom_cs   ),
    .rom_addr   ( pf2_rom_addr ),
    .rom_data   ( pf2_rom_data ),
    .rom_ok     ( pf2_rom_ok   ),
    .pxl        ( pf2_pixel_raw ),
    .pixel_valid( pf2_pixel_valid )
);

endmodule
