// Data East Liberation-family normalized ioctl region map.
// Linear download (index 0), little-endian byte stream from MRA.
//
//  SDRAM byte addr     Size     Region
//  ----------------    -------  ----------------
//  0x00000             0x10000  maincpu (pre nibble-swap in loader)
//  0x10000             0x04000  audiocpu $C000-$FFFF
//  0x14000             0x12000  gfx1 (3 x 0x6000 planar slots)
//  0x26000             0x08000  gfx2
//  0x2E000             0x04000  user1
//  0x32000             0x00020  proms
//  ----------------
//  Total end           0x32020

`ifndef YELLOWCAB_ROM_MAP_SV
`define YELLOWCAB_ROM_MAP_SV

package yellowcab_rom_map;
  localparam int unsigned MAIN_BASE   = 'h00000;
  localparam int unsigned MAIN_SIZE   = 'h10000;
  localparam int unsigned AUDIO_BASE  = 'h10000;
  localparam int unsigned AUDIO_SIZE  = 'h04000;
  localparam int unsigned GFX1_BASE   = 'h14000;
  localparam int unsigned GFX1_SIZE   = 'h12000;
  localparam int unsigned GFX2_BASE   = 'h26000;
  localparam int unsigned GFX2_SIZE   = 'h08000;
  localparam int unsigned USER1_BASE  = 'h2E000;
  localparam int unsigned USER1_SIZE  = 'h04000;
  localparam int unsigned PROM_BASE   = 'h32000;
  localparam int unsigned PROM_SIZE   = 'h00020;
  localparam int unsigned ROM_END     = 'h32020;
endpackage

`endif
