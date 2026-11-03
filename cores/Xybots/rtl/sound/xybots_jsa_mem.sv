//============================================================================
//  Xybots (Atari Games, 1987) — JSA I sound-CPU memory: 8 KB work RAM +
//  64 KB program ROM with the A13B/A12B bank paging.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa_mem.sv
//  (GPL-3.0-or-later); see NOTICE.md.
//
//  SP-313 sheet 12:
//    * "2H-RAM" 8K x 8 150 ns: A12..A0 = SA12..SA0, CS1(20)=/RAM, CS2(26)=VCC,
//      /WE(27)=/SWR, /OE(22)=/SRD.                        -> 0x0000-0x1FFF
//    * "2K-ROM" 27256/27512 900 ns: A15(1)=SA15, A14(27)=SA14,
//      **A13(26)=A13B, A12(2)=A12B**, A11..A0 = SA11..SA0,
//      /OE(22)=/SRD, /CE(20)=/ROM.
//      A13B/A12B are PAL outputs that substitute the /WRIO latch's BA13/BA12
//      in the 0x3000-0x3FFF window and pass SA13/SA12 everywhere else, which
//      is MAME's `bankr("cpubank")` (4 x 0x1000 entries over the ROM's bottom
//      16 KB) plus `rom()` at 0x4000-0xFFFF.
//
//  ROM offset:
//    sel_bank -> {2'b00, bank, addr[11:0]}   (image 0x0000-0x3FFF)
//    sel_rom  -> addr                        (image 0x4000-0xFFFF)
//
//  All four banks are implemented, and the Xybots sound ROM (136054-1116.2k)
//  really does page this window: over a 15 s MAME attract trace it makes 1576
//  /WRIO writes with only three distinct values — 0x01 (711x, bank 0), 0x81
//  (396x, bank 2) and 0xC1 (479x, bank 3) — so banks 0, 2 and 3 are all live
//  and bank 1 is simply unused by this ROM.
//
//  Registered (BRAM) read: dout is valid one clk after addr/selects.  Each
//  array has its OWN dedicated registered-output read (ram_q / rom_q) so both
//  infer as M10K.  A single shared 'dout' output register muxed across the two
//  arrays defeats inference ("asynchronous read logic"): the M10K's output
//  register cannot be shared, so the 64 KB ROM would fall back to ~512 K
//  flip-flops and overflow the device (Quartus error 276003).
//============================================================================

module xybots_jsa_mem
(
	input  logic        clk,
	// loader (byte writes over the whole 64 KB ROM image; it sits at offset
	// 0x030000 of the MRA download stream)
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,
	// 6502 access
	input  logic [15:0] addr,
	input  logic  [7:0] din,
	input  logic        we,          // 6502 write (RAM only)
	input  logic        sel_ram,
	input  logic        sel_bank,
	input  logic        sel_rom,
	input  logic  [1:0] bank,
	output logic  [7:0] dout
);

	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] ram [0:8191];    // 8 KB work RAM
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] rom [0:65535];   // 64 KB program ROM
`ifndef ALTERA_RESERVED_QIS
	initial begin for (int i=0;i<8192;i++) ram[i]=8'h00; end   // sim-only; M10K powers to 0
`endif

	wire [15:0] rom_off = sel_bank ? {2'b00, bank, addr[11:0]} : addr;

	logic [7:0] ram_q, rom_q;
	logic       sel_ram_q, sel_romish_q;
	always_ff @(posedge clk) begin
		if (rom_wr) rom[rom_wr_addr] <= rom_wr_data;
		if (we && sel_ram) ram[addr[12:0]] <= din;
		ram_q        <= ram[addr[12:0]];
		rom_q        <= rom[rom_off];
		sel_ram_q    <= sel_ram;
		sel_romish_q <= sel_bank | sel_rom;
	end

	// Combinational mux over the registered BRAM outputs == the original 1-clk
	// latency, selected by the select that was valid at address time.
	always_comb begin
		if      (sel_ram_q)    dout = ram_q;
		else if (sel_romish_q) dout = rom_q;
		else                   dout = 8'hFF;
	end

endmodule
