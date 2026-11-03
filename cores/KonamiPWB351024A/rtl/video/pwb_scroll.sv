/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 15-4-2023 */

// SPY adaptation: normalized 16-KiB video aperture and 304-pixel viewport.
module pwb_scroll(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,

    // Base Video
    output            lhbl,
    output            lvbl,
    output            hs,
    output            vs,
    output     [ 8:0] hdump, vdump, vrender, vrender1,

    // CPU interface
    input             gfx_cs,
    input             cpu_we,
    input             cpu_rnw,
    input      [13:0] cpu_addr,
    input      [ 7:0] cpu_dout,
    output     [ 7:0] tile_dout,
    output reg        cpu_rom_dtack,
    output            rst8,     // reset signal at 8th frame

    // control
    input             game_mainevt,
    input             rmrd,     // Tile ROM read mode
    output            irq_n,
    output            firq_n,
    output            nmi_n,
    output            flip,
    output            e, q,


    // Tile ROMs
    output     [12:0] lyra_addr,
    output     [12:0] lyrb_addr,
    output     [12:0] lyrf_addr,

    output            lyrf_cs,
    output            lyra_cs,
    output            lyrb_cs,

    input      [31:0] lyrf_data,
    input      [31:0] lyra_data,
    input      [31:0] lyrb_data,

    output     [ 7:0] lyrf_col, lyrf_extra,
    output     [ 7:0] lyra_col, lyra_extra,
    output     [ 7:0] lyrb_col, lyrb_extra,

    input      [ 7:0] lyrf_cg,
    input      [ 7:0] lyra_cg,
    input      [ 7:0] lyrb_cg,

    input             lyra_ok,

    // Final pixels
    output            lyrf_blnk_n,
    output            lyra_blnk_n,
    output            lyrb_blnk_n,
    output     [ 7:0] lyrf_pxl,
    output     [11:0] lyra_pxl,
    output     [11:0] lyrb_pxl,

    // Debug
    input      [14:0] ioctl_addr,
    input             ioctl_ram,
    output     [ 7:0] ioctl_din,
    output     [ 7:0] mmr_dump,

    input      [ 3:0] gfx_en,
    input      [ 7:0] debug_bus,
    output     [ 7:0] st_dout
);

parameter [8:0] HB_OFFSET=9'h1ff, // -1 pixel: align pipeline viewport with MAME
                HB_EXTRAL=8,
                HB_EXTRAR=8;
parameter       FULLRAM  =0; // Enables the three possible memory chips
parameter       K051961  =0;

wire [ 7:0] tilemap_dout, tilerom_dout;
wire [ 2:0] hsub_a, hsub_b;
wire        hflip_en;
// The donor's reset map has colour RAM at 6000 and code RAM at 8000.
// SPY's aperture places those at offsets 0000 and 2000 respectively.
wire [15:0] chip_addr = {2'b0,cpu_addr} + 16'h6000;

assign lyrf_cs =  gfx_en[0];
wire cpu_rom_read=rmrd && gfx_cs && cpu_rnw;
assign lyra_cs = cpu_rom_read | gfx_en[1];
assign lyrb_cs =  gfx_en[2];

assign tile_dout = cpu_rom_read ? tilerom_dout : tilemap_dout;

always @(posedge clk) cpu_rom_dtack <= ~cpu_rom_read | lyra_ok;

pwb_tilemap #(.FULLRAM(FULLRAM),.K051961(K051961)) u_tilemap(
    .game_mainevt(game_mainevt),
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),
    .pxl2_cen   ( pxl2_cen  ),

    .lvbl       ( lvbl      ),
    // CPU interface
    .cpu_addr   ( chip_addr ),
    .cpu_din    (tilemap_dout),
    .cpu_dout   ( cpu_dout  ),
    .gfx_cs     ( gfx_cs    ),
    .cpu_we     ( cpu_we    ),
    .cpu_rnw    ( cpu_rnw   ),
    .rst8       ( rst8      ),

    // control
    .rmrd       ( rmrd      ),
    .hdump      ( hdump     ),
    .vdump      ( vdump     ),
    .q          ( q         ),
    .e          ( e         ),

    // Fine grain scroll
    .hsub_a     ( hsub_a    ),
    .hsub_b     ( hsub_b    ),

    .irq_n      ( irq_n     ),
    .firq_n     ( firq_n    ),
    .nmi_n      ( nmi_n     ),
    .flip       ( flip      ),
    .hflip_en   ( hflip_en  ),

    // tile ROM addressing
    // original pins: { CAB2,CAB1,VC[10:0] }
    // [2:0] tile row (8 lines)
    .lyrf_addr  ( lyrf_addr ),
    .lyra_addr  ( lyra_addr ),
    .lyrb_addr  ( lyrb_addr ),

    .lyrf_extra ( lyrf_extra),
    .lyra_extra ( lyra_extra),
    .lyrb_extra ( lyrb_extra),

    .lyrf_col   ( lyrf_col  ),
    .lyra_col   ( lyra_col  ),
    .lyrb_col   ( lyrb_col  ),

    // Debug
    .ioctl_addr ( ioctl_addr),
    .ioctl_din  ( ioctl_din ),
    .ioctl_ram  ( ioctl_ram ),

    .debug_bus  ( debug_bus ),
    .mmr_dump   ( mmr_dump  ),
    .st_dout    ( st_dout   )
);

/* verilator tracing_on */
pwb_tile_draw #(
    .HB_OFFSET  ( HB_OFFSET ),
    .HB_EXTRAL  ( HB_EXTRAL ),
    .HB_EXTRAR  ( HB_EXTRAR )
) u_draw(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),

    .flip       ( flip      ),
    .hflip_en   ( hflip_en  ),

    .cpu_addr   (cpu_addr[1:0]),
    .cpu_din    (tilerom_dout),

    .lyrf_data  ( lyrf_data ),
    .lyra_data  ( lyra_data ),
    .lyrb_data  ( lyrb_data ),

    .lyrf_col   ( lyrf_cg   ),
    .lyra_col   ( lyra_cg   ),  // lyra/b color byte get their nibbles
    .lyrb_col   ( lyrb_cg   ),  // swapped inside this module

    // Fine grain scroll
    .hsub_a     ( hsub_a    ),
    .hsub_b     ( hsub_b    ),

    .hdump      ( hdump     ),
    .vdump      ( vdump     ),
    .vrender    ( vrender   ),
    .vrender1   ( vrender1  ),
    .lhbl       ( lhbl      ),
    .lvbl       ( lvbl      ),
    .hs         ( hs        ),
    .vs         ( vs        ),

    .lyrf_blnk_n(lyrf_blnk_n),
    .lyra_blnk_n(lyra_blnk_n),
    .lyrb_blnk_n(lyrb_blnk_n),
    .lyrf_pxl   ( lyrf_pxl  ),
    .lyra_pxl   ( lyra_pxl  ),
    .lyrb_pxl   ( lyrb_pxl  ),

    // Debug
    .gfx_en     ( gfx_en    ),
    // Debug
    .debug_bus  ( debug_bus )
);

endmodule
