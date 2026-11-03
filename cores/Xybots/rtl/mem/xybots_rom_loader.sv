`timescale 1ns/1ps
//============================================================================
//  Xybots ROM download router — MiSTer index-0 ioctl stream -> region writes.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's `toobin_rom_loader.sv`
//  (GPL-3.0-or-later); see NOTICE.md.  The stream map, the region widths and
//  the EEPROM channel are Xybots-specific.
//
//  ---- the stream this decodes (as `releases/Xybots.mra` emits it) ---------
//
//    stream base   size       MAME region  destination
//    0x000000      0x030000   maincpu      68000 program ROM   -> BRAM (word)
//    0x030000      0x010000   jsa:cpu      6502 sound ROM      -> BRAM (byte)
//    0x040000      0x040000   tiles        playfield gfx       -> SDRAM
//    0x080000      0x080000   sprites      motion-object gfx   -> SDRAM
//    0x100000      0x002000   chars        alpha gfx (5C)      -> BRAM (byte)
//    0x102000      0x000200   —            X2804 EEPROM image  -> BRAM (byte)
//    total         0x102200                (1 057 280 bytes)
//
//  The MRA has already done all of the assembly work, so this module is a pure
//  address decode into per-region byte strobes + region-local byte offsets:
//
//    * maincpu is emitted as BIG-ENDIAN INTERLEAVED WORDS — the even-offset
//      MAME ROM (17cd/17b) is `map="01"`, the FIRST byte of each output word,
//      i.e. D15:8.  So download byte 2N is the 68000 word's high lane and byte
//      2N+1 is the low lane; `xybots_prog_rom` splits them exactly that way.
//      Getting this backwards byte-swaps every opcode and the 68000 fetches a
//      garbage reset vector, with no error message anywhere to say so.
//    * the 12L tiles ROM_RELOAD and both unpopulated-socket holes (tiles
//      0x20000-0x2FFFF = the 9L socket, sprites 0x70000-0x7FFFF = the eighth MO
//      socket) are already materialised in the stream, so the graphics regions
//      are flat and this router never has to know about them.
//    * the EEPROM image is 512 bytes of 0xFF (an erased X2804).  MiSTer's NVRAM
//      channel (ioctl index 2) restores saved settings OVER it afterwards; that
//      channel is NOT handled here — index 0 only — because
//      `xybots_nvram_io` owns the index-2 path and the save-back upload.
//
//  Nothing else in the stream exists: bytes at or above 0x102200, and every
//  ioctl index other than 0, produce no strobe at all.
//
//  ---- back-pressure -------------------------------------------------------
//  The BRAM regions accept a byte per clock and never stall.  The two SDRAM
//  regions go through `xybots_sdram_loader`, which packs byte pairs into words
//  and raises `wr_busy` while a word is outstanding; `xybots_mem` wires that
//  straight to `ioctl_wait`.  This module deliberately does not consume
//  `ioctl_wait` itself: hps_io holds `ioctl_addr`/`ioctl_dout` and simply does
//  not issue the next `ioctl_wr`, so the decode is unaffected.
//
//  Outputs are REGISTERED (one clk_sys after the ioctl_wr).  The SDRAM loader's
//  combinational `wr_busy` is derived from those registered strobes and so
//  asserts one cycle after the byte.
//============================================================================

module xybots_rom_loader
(
	input  logic        clk,
	input  logic        reset,          // ~pll_locked ONLY (see xybots_mem)

	// ---- HPS ioctl download channel ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,     // byte offset into the index-0 stream
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,

	// ---- program ROM (BRAM), byte port; xybots_prog_rom does even->D15:8 ----
	output logic        prog_rom_wr,
	output logic [17:0] prog_rom_addr,  // byte offset 0..0x2FFFF
	output logic  [7:0] prog_rom_data,

	// ---- JSA I 6502 sound ROM (BRAM), byte port ----
	output logic        snd_rom_wr,
	output logic [15:0] snd_rom_addr,   // byte offset 0..0xFFFF
	output logic  [7:0] snd_rom_data,

	// ---- playfield tiles -> SDRAM (via xybots_sdram_loader) ----
	output logic        tiles_wr,
	output logic [17:0] tiles_addr,     // byte offset 0..0x3FFFF

	// ---- motion-object sprites -> SDRAM (via xybots_sdram_loader) ----
	output logic        sprites_wr,
	output logic [18:0] sprites_addr,   // byte offset 0..0x7FFFF

	// shared byte for both SDRAM regions (they never strobe in the same cycle)
	output logic  [7:0] gfx_data,

	// ---- alphanumerics character ROM (5C, BRAM), byte port ----
	output logic        char_rom_wr,
	output logic [12:0] char_rom_addr,  // byte offset 0..0x1FFF
	output logic  [7:0] char_rom_data,

	// ---- X2804 EEPROM initial image (BRAM/NVRAM), byte port ----
	output logic        eeprom_wr,
	output logic  [8:0] eeprom_addr,    // byte offset 0..0x1FF
	output logic  [7:0] eeprom_data,

	// ---- high once the index-0 download has ended ----
	output logic        rom_loaded
);

	// region base offsets in the concatenated download stream
	localparam [26:0] BASE_PROG   = 27'h000000;
	localparam [26:0] BASE_SND    = 27'h030000;
	localparam [26:0] BASE_TILES  = 27'h040000;
	localparam [26:0] BASE_SPR    = 27'h080000;
	localparam [26:0] BASE_CHARS  = 27'h100000;
	localparam [26:0] BASE_EEPROM = 27'h102000;
	localparam [26:0] END_STREAM  = 27'h102200;

	wire is_idx0 = (ioctl_index == 16'd0);
	wire wr      = ioctl_download & ioctl_wr & is_idx0;

	wire in_prog   = wr && (ioctl_addr <  BASE_SND);       // BASE_PROG == 0
	wire in_snd    = wr && (ioctl_addr >= BASE_SND)    && (ioctl_addr < BASE_TILES);
	wire in_tiles  = wr && (ioctl_addr >= BASE_TILES)  && (ioctl_addr < BASE_SPR);
	wire in_spr    = wr && (ioctl_addr >= BASE_SPR)    && (ioctl_addr < BASE_CHARS);
	wire in_chars  = wr && (ioctl_addr >= BASE_CHARS)  && (ioctl_addr < BASE_EEPROM);
	wire in_eeprom = wr && (ioctl_addr >= BASE_EEPROM) && (ioctl_addr < END_STREAM);

	logic [7:0] data_r;

	always_ff @(posedge clk) begin
		data_r        <= ioctl_dout;
		prog_rom_wr   <= in_prog   & ~reset;
		snd_rom_wr    <= in_snd    & ~reset;
		tiles_wr      <= in_tiles  & ~reset;
		sprites_wr    <= in_spr    & ~reset;
		char_rom_wr   <= in_chars  & ~reset;
		eeprom_wr     <= in_eeprom & ~reset;
		prog_rom_addr <= 18'(ioctl_addr - BASE_PROG);
		snd_rom_addr  <= 16'(ioctl_addr - BASE_SND);
		tiles_addr    <= 18'(ioctl_addr - BASE_TILES);
		sprites_addr  <= 19'(ioctl_addr - BASE_SPR);
		char_rom_addr <= 13'(ioctl_addr - BASE_CHARS);
		eeprom_addr   <=  9'(ioctl_addr - BASE_EEPROM);
	end

	// one registered byte, fanned out to every destination port
	assign prog_rom_data = data_r;
	assign snd_rom_data  = data_r;
	assign gfx_data      = data_r;
	assign char_rom_data = data_r;
	assign eeprom_data   = data_r;

	// rom_loaded latches on the falling edge of the INDEX-0 download.  The index
	// qualifier matters: an NVRAM (index 2) restore on a core that has never
	// seen a ROM download must not announce "ROMs are loaded".  `reset`
	// (~pll_locked) gives it a defined value from power-up, so simulation and
	// hardware agree and no consumer ever samples an X.
	wire  dl0 = ioctl_download & is_idx0;
	logic dl0_d;
	always_ff @(posedge clk) begin
		if (reset) begin
			dl0_d      <= 1'b0;
			rom_loaded <= 1'b0;
		end else begin
			dl0_d <= dl0;
			if (dl0)        rom_loaded <= 1'b0;   // download in progress
			else if (dl0_d) rom_loaded <= 1'b1;   // first cycle after it ends
		end
	end

endmodule
