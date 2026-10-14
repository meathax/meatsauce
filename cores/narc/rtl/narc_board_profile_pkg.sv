`default_nettype none
package narc_board_profile_pkg;
  // Confirmed by rev-7 INITDATA and the SYS-Z schematic transcription.
  localparam int unsigned NARC_VISIBLE_W = 512;
  localparam int unsigned NARC_VISIBLE_H = 400;
  localparam int unsigned NARC_HTOTAL = 674;
  localparam int unsigned NARC_HEBLNK = 122;
  localparam int unsigned NARC_HSBLNK = 634;
  localparam int unsigned NARC_VTOTAL = 433;
  localparam int unsigned NARC_VEBLNK = 27;
  localparam int unsigned NARC_VSBLNK = 427;
  localparam int unsigned NARC_PALETTE_ENTRIES = 8192;
  localparam int unsigned NARC_VRAM_WORDS = 262144;
  localparam int unsigned NARC_VRAM_LIVE_BITS = 13;
  localparam int unsigned NARC_SRT_WORDS = 1024;

  localparam logic [31:0] NARC_VRAM_BASE = 32'h0000_0000;
  localparam logic [31:0] NARC_SCRATCH_BASE = 32'h0100_0000;
  localparam logic [31:0] NARC_CMOS_BASE = 32'h0140_0000;
  localparam logic [31:0] NARC_PALETTE_BASE = 32'h0180_0000;
  localparam logic [31:0] NARC_DMA_BASE = 32'h01A8_0000;
  localparam logic [31:0] NARC_IMAGE_BASE = 32'h0200_0000;
  localparam logic [31:0] NARC_PROGRAM_BASE = 32'hFFC0_0000;

  // These nominal clocks agree with the software/MAME operating point, but the
  // oscillator glyph and divider jumper topology remain physically unresolved.
  localparam int unsigned NARC_MASTER_HZ_PROVISIONAL = 48_000_000;
  localparam int unsigned NARC_GSP_EFFECTIVE_HZ_PROVISIONAL = 6_000_000;
  localparam int unsigned NARC_PIXEL_HZ_PROVISIONAL = 16_000_000;
  localparam bit NARC_CLOCK_TREE_PHYSICALLY_PROVEN = 1'b0;
  localparam bit NARC_U12_DUMP_AVAILABLE = 1'b0;
  localparam bit NARC_U90_DUMP_AVAILABLE = 1'b0;
  localparam bit NARC_U77_INTERNAL_LOGIC_AVAILABLE = 1'b0;
endpackage
`default_nettype wire
