`timescale 1ns/1ps
//============================================================================
//  Xybots memory subsystem — the MiSTer download path, the ROMs that live in
//  block RAM, and the SDRAM that holds the graphics.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  It wires up, and hides, five modules:
//
//    xybots_rom_loader    index-0 download stream -> per-region byte strobes
//    xybots_prog_rom      192 KB 68000 program ROM in BRAM (192 M10K)
//    xybots_sdram_loader  byte pairs -> the ONE SDRAM write path
//    xybots_gfx_mem       PF + MO read arbiter over that same controller
//    xybots_sdram         the MT48LC16M16-class controller itself
//    (+ the 8 KB alphanumerics character ROM, a plain BRAM, inline below)
//
//  What it deliberately does NOT contain: the 64 KB JSA sound ROM (that BRAM
//  lives inside `xybots_jsa`, so this module only forwards `sndrom_*` write
//  strobes), the X2804 EEPROM and the whole ioctl index-2 NVRAM channel
//  (`xybots_nvram_io` + `xybots_eeprom_2804` own the device, the restore, the
//  save-back and `ioctl_din`; this module only offers the erased factory image
//  the MRA ships at stream 0x102000), and VRAM and CRAM (dual-port BRAM next
//  to the CPU and video sides that use them).
//
//  ---- reset: ONE reset, and it MUST be ~pll_locked -------------------------
//  `init_reset` reaches the SDRAM controller (where it drives SDRAM_CKE), the
//  loader and the arbiter.  It must be `~pll_locked` and NOTHING else.  A game
//  or download reset pulsing here drops CKE, restarts the 200 us init in the
//  middle of the download and silently loses every write already made — a
//  failure that shows up as a black screen with no other symptom.  That is why
//  `xybots_core` carries a separate `init_reset` port.  There is intentionally
//  no second reset input: nothing in the memory path needs to be reset when the
//  game resets, and offering the port would be offering the trap.
//
//  ---- read-port contracts (what the rest of the core codes against) -------
//
//  Program ROM (BRAM, no arbitration, never stalls):
//      prog_a[16:0]        68000 A17..A1 BEFORE slapstic substitution
//      prog_slap_sel       /SLAPSTIC asserted (A23=0 & A17=0 & A16=0 & A15=1)
//      prog_slap_bank[1:0] {BS1, BS0} from xybots_slapstic
//      prog_data[15:0]     valid 1 clk_sys after the address.  LATENCY 1.
//
//  Character ROM (BRAM, 5C, 8 KB):
//      char_addr[12:0] -> char_data[7:0], valid 1 clk_sys later.  LATENCY 1.
//
//  Playfield tiles / MO sprites (SDRAM, arbitrated):
//      *_addr is the byte address bits [17:2] / [18:2] of the wanted ROM byte;
//      one request returns the whole 4-byte row {b3,b2,b1,b0} = the two 16-bit
//      words at byte A+0 and A+2, b0 being the (A1,A0)=00 byte.  Raise `*_req`
//      and hold it; `*_valid` pulses once; then drop `*_req`.
//      LATENCY req->valid: 11 clk_sys idle, 31 worst case with the other
//      client active and a refresh colliding — against the 64 clk_sys the
//      video engine can wait.  See xybots_gfx_mem's header.
//
//  ---- download and NVRAM -------------------------------------------------
//  `ioctl_wait` is driven from the SDRAM loader's back-pressure and is the only
//  thing that stops the byte stream outrunning the SDRAM; `xybots_core` must
//  wire it straight to hps_io.
//
//  Index 0 is the MRA ROM stream and this module owns it in full.  Index 2 —
//  MiSTer's NVRAM restore/save channel — is NOT handled here:
//  `rtl/main/xybots_nvram_io.sv` owns it, together with `ioctl_din`,
//  `ioctl_upload_req` and the save-settle timer, because those belong with the
//  live X2804 array rather than with the ROMs.  To keep the two from fighting
//  over `ioctl_din`, this module drives no upload path at all.
//
//  The one EEPROM signal that does come out of here is `eeprom_img_*`: the
//  512-byte ERASED factory image that index 0 ships at stream 0x102000.  It is
//  offered as a ready-made hook for a core that does not instantiate
//  `xybots_nvram_io` (which decodes the same bytes itself); leave it
//  unconnected when it does.
//
//  ---- SDRAM map (word addresses, 32 MB module, 768 KB used) --------------
//    0x000000..0x01FFFF  tiles    0x40000 bytes (incl. the FF-filled 9L hole)
//    0x020000..0x05FFFF  sprites  0x80000 bytes (incl. the FF-filled 8th-MO
//                                 socket hole)
//  Everything lives in bank 0, rows of 512 words, so a 2-word aligned burst can
//  never cross a row.  SDRAM_CLK is NOT driven here — `Arcade-Xybots.sv` drives
//  the pin from the PLL's phase-shifted output, because the read-capture phase
//  can only be settled on real hardware (see `xybots_sdram`'s header).
//============================================================================

module xybots_mem #(
	parameter int AW = 24,
	parameter logic [AW-1:0] TILE_BASE = 24'h000000,
	parameter logic [AW-1:0] SPR_BASE  = 24'h020000
)(
	input  logic        clk,
	input  logic        init_reset,      // ~pll_locked ONLY — see header

	// ---- HPS ioctl download / upload ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	output logic        ioctl_wait,
	output logic        rom_loaded,

	// ---- 68000 program ROM read port (BRAM, latency 1) ----
	input  logic [16:0] prog_a,          // 68000 A17..A1, pre-substitution
	input  logic        prog_slap_sel,   // /SLAPSTIC asserted
	input  logic  [1:0] prog_slap_bank,  // {BS1, BS0}
	output logic [15:0] prog_data,

	// ---- alphanumerics character ROM read port (BRAM 5C, latency 1) ----
	input  logic [12:0] char_addr,
	output logic  [7:0] char_data,

	// ---- JSA I sound ROM write strobes (the BRAM lives in xybots_jsa) ----
	output logic        sndrom_wr,
	output logic [15:0] sndrom_addr,
	output logic  [7:0] sndrom_data,

	// ---- X2804 EEPROM erased factory image (index 0, stream 0x102000) ----
	// Optional: xybots_nvram_io decodes the same bytes and also owns index 2.
	output logic        eeprom_img_wr,
	output logic  [8:0] eeprom_img_addr,
	output logic  [7:0] eeprom_img_data,

	// ---- graphics read clients (SDRAM) ----
	input  logic        mo_req,
	input  logic [18:2] mo_addr,         // sprites byte address bits 18:2
	output logic        mo_valid,
	output logic [31:0] mo_data,
	input  logic        pf_req,
	input  logic [17:2] pf_addr,         // tiles byte address bits 17:2
	output logic        pf_valid,
	output logic [31:0] pf_data,

	// ---- SDRAM chip pins (SDRAM_CLK is driven in Arcade-Xybots.sv) ----
	inout  wire  [15:0] SDRAM_DQ,
	output logic [12:0] SDRAM_A,
	output logic  [1:0] SDRAM_BA,
	output logic        SDRAM_DQML,
	output logic        SDRAM_DQMH,
	output logic        SDRAM_CKE,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE
);

	// ================= index-0 download router =================
	logic        prog_wr;
	logic [17:0] prog_wr_addr;
	logic  [7:0] prog_wr_data;
	logic        tiles_wr, sprites_wr;
	logic [17:0] tiles_addr;
	logic [18:0] sprites_addr;
	logic  [7:0] gfx_data;
	logic        char_wr;
	logic [12:0] char_wr_addr;
	logic  [7:0] char_wr_data;

	xybots_rom_loader u_loader (
		.clk            (clk),
		.reset          (init_reset),
		.ioctl_download (ioctl_download),
		.ioctl_wr       (ioctl_wr),
		.ioctl_addr     (ioctl_addr),
		.ioctl_dout     (ioctl_dout),
		.ioctl_index    (ioctl_index),
		.prog_rom_wr    (prog_wr),
		.prog_rom_addr  (prog_wr_addr),
		.prog_rom_data  (prog_wr_data),
		.snd_rom_wr     (sndrom_wr),
		.snd_rom_addr   (sndrom_addr),
		.snd_rom_data   (sndrom_data),
		.tiles_wr       (tiles_wr),
		.tiles_addr     (tiles_addr),
		.sprites_wr     (sprites_wr),
		.sprites_addr   (sprites_addr),
		.gfx_data       (gfx_data),
		.char_rom_wr    (char_wr),
		.char_rom_addr  (char_wr_addr),
		.char_rom_data  (char_wr_data),
		.eeprom_wr      (eeprom_img_wr),
		.eeprom_addr    (eeprom_img_addr),
		.eeprom_data    (eeprom_img_data),
		.rom_loaded     (rom_loaded)
	);

	// ================= 68000 program ROM (BRAM) =================
	xybots_prog_rom u_prog (
		.clk       (clk),
		.wr        (prog_wr),
		.wr_addr   (prog_wr_addr),
		.wr_data   (prog_wr_data),
		.rd_a      (prog_a),
		.slap_sel  (prog_slap_sel),
		.slap_bank (prog_slap_bank),
		.rd_data   (prog_data)
	);

	// ================= alphanumerics character ROM (BRAM, 5C) =================
	// 8 KB, one 2764 fitted in a socket drawn for a 27128.  Address =
	// code*16 + row*2 + half; the code's bit 9 does not reach the fitted part,
	// which is the video side's concern, not this ROM's.
	logic [7:0] char_rom [0:8191];
`ifndef ALTERA_RESERVED_QIS
	initial for (int i = 0; i < 8192; i++) char_rom[i] = '0;
`endif
	always_ff @(posedge clk) begin
		if (char_wr) char_rom[char_wr_addr] <= char_wr_data;
		char_data <= char_rom[char_addr];
	end

	// ================= graphics: one write path, two read clients =============
	logic          dl_wr, dl_ack;
	logic [AW-1:0] dl_waddr;
	logic [15:0]   dl_wdata;

	xybots_sdram_loader #(
		.AW (AW), .TILE_BASE (TILE_BASE), .SPR_BASE (SPR_BASE)
	) u_sdram_loader (
		.clk          (clk),
		.reset        (init_reset),
		.tiles_wr     (tiles_wr),
		.tiles_addr   (tiles_addr),
		.sprites_wr   (sprites_wr),
		.sprites_addr (sprites_addr),
		.ld_data      (gfx_data),
		.wr_busy      (ioctl_wait),
		.dl_wr        (dl_wr),
		.dl_waddr     (dl_waddr),
		.dl_wdata     (dl_wdata),
		.dl_ack       (dl_ack)
	);

	logic          sd_req, sd_we, sd_ready, sd_valid;
	logic [AW-1:0] sd_addr;
	logic  [1:0]   sd_blen;
	logic [15:0]   sd_wdata, sd_rdata;

	xybots_gfx_mem #(
		.AW (AW), .TILE_BASE (TILE_BASE), .SPR_BASE (SPR_BASE)
	) u_gfx (
		.clk      (clk),
		.reset    (init_reset),
		.mo_req   (mo_req),   .mo_addr (mo_addr),
		.mo_valid (mo_valid), .mo_data (mo_data),
		.pf_req   (pf_req),   .pf_addr (pf_addr),
		.pf_valid (pf_valid), .pf_data (pf_data),
		.dl_wr    (dl_wr),    .dl_waddr (dl_waddr),
		.dl_wdata (dl_wdata), .dl_ack   (dl_ack),
		.sd_req   (sd_req),   .sd_addr  (sd_addr),
		.sd_we    (sd_we),    .sd_blen  (sd_blen),
		.sd_wdata (sd_wdata), .sd_ready (sd_ready),
		.sd_valid (sd_valid), .sd_rdata (sd_rdata)
	);

	xybots_sdram #(
		.CLK_KHZ (57273), .ROW_BITS (13), .COL_BITS (9)
	) u_sdram (
		.clk        (clk),
		.reset      (init_reset),
		.addr       (sd_addr),
		.wdata      (sd_wdata),
		.we         (sd_we),
		.blen       (sd_blen),
		.req        (sd_req),
		.rdata      (sd_rdata),
		.valid      (sd_valid),
		.ready      (sd_ready),
		.SDRAM_DQ   (SDRAM_DQ),
		.SDRAM_A    (SDRAM_A),
		.SDRAM_BA   (SDRAM_BA),
		.SDRAM_DQML (SDRAM_DQML),
		.SDRAM_DQMH (SDRAM_DQMH),
		.SDRAM_CKE  (SDRAM_CKE),
		.SDRAM_nCS  (SDRAM_nCS),
		.SDRAM_nRAS (SDRAM_nRAS),
		.SDRAM_nCAS (SDRAM_nCAS),
		.SDRAM_nWE  (SDRAM_nWE)
	);

endmodule
