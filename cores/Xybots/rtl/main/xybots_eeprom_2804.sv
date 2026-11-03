`timescale 1ns/1ps
//============================================================================
//  Xicor X2804A (512 x 8) EEPROM at 20C/D — SP-313 sheet 3.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's `toobin_eeprom_2804.sv`
//  (GPL-3.0-or-later); see NOTICE.md.  Re-derived against the Xybots sheet-3
//  wiring.
//
//  ---- wiring --------------------------------------------------------------
//    A0..A10 (8,7,6,5,4,3,2,1,23,22,19) = A1B..A11B
//    D0..D7  (9..17)                    = **D0B..D7B only — the LOW byte**
//    /CE (18) = /EEROM
//    /WE (21) = **/WL**   (the board-global low-byte write strobe)
//    /OE (20) = 2A LS08 (10 = 4B.Q, 9 = /RESET -> 8)
//
//  The socket is wired for a 2 K x 8 part but the fitted X2804A is 512 x 8
//  (A0..A8 only), so the device repeats four times inside 0x805000-0x805FFF —
//  which is exactly MAME's `.mirror(0x7f8c00)`.  Addressing here is 9 bits;
//  the caller drops A10B/A11B.
//
//  ---- the unlock latch (4B LS74) ----------------------------------------
//    D (12) = GND        CK (11) = /WL
//    /PRE (10) = /UNLOCK  /CLR (13) = /RESET      Q (9) -> 2A LS08 pin 10
//
//  A write to /UNLOCK (0x806800) presets Q = 1, which drives /OE HIGH and so
//  permits the 28xx write cycle (the family inhibits a write while /OE is low).
//  The next RISING edge of /WL — the end of ANY low-byte write on the board,
//  not just an EEPROM one — clocks D = 0 back in and re-locks the part.
//  Exactly one write is permitted per unlock, which is MAME's
//  `lock_after_write(true)`.
//
//  Two orderings that matter and are reproduced here:
//   * The unlock write is itself a WORD write (`move.w d0,$e800.w`, pc 0xEA0),
//     so /WL rises at the end of that very cycle.  On the board /UNLOCK (two
//     gate delays behind /AS) is still low when /WL (one gate delay) rises, so
//     the preset wins and the unlock survives its own write.  Modelled as
//     "unlock beats the coincident /WL".
//   * `write_accepted` samples `unlocked` BEFORE the same strobe re-locks the
//     part, so the byte the game is unlocking for does get stored.
//
//  ---- /OE and reads ------------------------------------------------------
//  /OE = Q & /RESET.  While the part is unlocked (Q = 1) /OE is HIGH and the
//  outputs are OFF: a read in that window returns the floating bus, not the
//  cell.  The game masks all interrupts around unlock+write (pc 0xE9C..0xEA6)
//  so it never reads there, but the behaviour is modelled rather than assumed
//  away.  While /RESET is low the outputs are ON and writes are blocked.
//
//  ---- programming time ---------------------------------------------------
//  The X2804A data sheet gives a self-timed byte write of typically 5 ms and at
//  most 10 ms, with the I/O pins high-Z throughout.  The default is the 10 ms
//  bound; `WRITE_CYCLES` is a parameter so a focused simulation need not run
//  half a million clocks.  The game reads a byte back and skips both the
//  unlock and the write when it already matches (pc 0xE96), so a busy read
//  returning 0xFF simply makes it try again later.
//
//  ---- the part erases itself at power-up ---------------------------------
//  A factory X2804A reads 0xFF; an inferred FPGA RAM powers up at 0x00, and an
//  all-zero part is NOT the "unprogrammed" state the game's boot code expects.
//  So this module establishes the erased state itself rather than relying on
//  the loader, the MRA or the synthesis tool's RAM initialisation.  The rule,
//  and why an all-zero part is worse than an erased one, are in the block
//  above `programmed` below.
//============================================================================

module xybots_eeprom_2804 #(
	parameter int CLK_HZ       = 57_272_727,
	parameter int WRITE_CYCLES = CLK_HZ / 100      // 10 ms
)(
	input  logic       clk,
	// FPGA / PLL init, and every OSD reset.  It clears the busy state, locks
	// the part, and brackets one image load: see the power-up erase below.
	input  logic       init_reset,
	input  logic       reset,        // the board /RESET net, active high
	// MiSTer OSD pause (xybots_core): holds the self-timed write countdown so
	// a write in flight when the game pauses finishes in game time, not
	// real time.  Tie low where there is no pause.
	input  logic       paused,

	input  logic       unlock,       // 1-clk pulse: any write to /UNLOCK
	input  logic       low_write,    // 1-clk pulse: rising /WL, anywhere
	input  logic       cpu_we,       // 1-clk pulse: /EEROM write with /WL low
	input  logic [8:0] cpu_addr,     // A9B..A1B
	input  logic [7:0] cpu_wdata,
	output logic [7:0] cpu_rdata,
	output logic       busy,
	output logic       oe_n,         // 2A LS08 output -> 20C/D pin 20
	output logic       unlocked,
	output logic       write_accepted,

	// MiSTer NVRAM restore / save-back (xybots_nvram_io)
	input  logic       load_we,
	input  logic [8:0] load_addr,
	input  logic [7:0] load_data,
	input  logic [8:0] dump_addr,
	output logic [7:0] dump_data
);

	localparam int BUSY_W = (WRITE_CYCLES <= 1) ? 1 : $clog2(WRITE_CYCLES + 1);
	logic [BUSY_W-1:0] busy_ctr;
	logic [7:0] mem [0:511];

`ifndef ALTERA_RESERVED_QIS
	// Sim-only: an unprogrammed X2804A reads 0xFF, and that is what the MRA
	// ships as the factory image (its 0x200-byte tail).  On hardware the
	// loader writes the real image in before the CPU runs.
	initial for (int i = 0; i < 512; i++) mem[i] = 8'hFF;
`endif

	// ---- power-up erase: a factory X2804A reads 0xFF, an FPGA RAM reads 0x00
	//
	// The `initial` above is SIMULATION ONLY.  On the FPGA this array is an
	// inferred RAM and every cell powers up at 0x00 unless something writes it,
	// and the only thing that normally does is the MRA's 0x200-byte erased tail
	// arriving on ioctl index 0.  If that tail does not arrive -- an old MRA, a
	// blank save file landing on top of it -- the game boots against an
	// all-zero part, and an all-zero block is NOT the "unprogrammed" case the
	// ROM bails out on: Atari's EEPROM records are Hamming-protected, an
	// ERASED block is UNCORRECTABLE (so the boot gives up after a couple of
	// blocks and logs the small legitimate count) while an ALL-ZERO block is
	// CORRECTABLE (so the boot believes the garbage, walks every block, and
	// logs a large one).  On this game the self test's Error Count reads 16 on
	// an erased part and 64 on a zeroed one -- and 64 is below the ROM's 75
	// threshold, so a zeroed Xybots part shows a wrong count with no
	// "EEPROM ERROR" banner to flag it.
	//
	// So the erased state is established HERE, by the part itself, and does not
	// depend on the loader, the MRA or the synthesis tool's RAM initialisation.
	//
	// Every loader byte reaches this module while `init_reset` is HIGH: at
	// `xybots_main_bus` that input covers the whole of the index-0 stream and
	// the whole of an index-2 restore.  That window is therefore exactly one
	// "image load", and the decision taken when it releases is:
	//
	//   an image was loaded and every byte of it was 0x00  -> ERASE
	//        (a `.nvm` the HPS has never actually written; an all-zero X2804A
	//         is not a state this game can leave behind)
	//   no image was loaded and nothing has ever been written -> ERASE
	//        (the MRA's 0x200-byte erased tail did not arrive)
	//   anything else -> leave the array alone
	//
	// `programmed` is the "something real has been written here" flag; it is
	// deliberately ACTIVE HIGH and RESETLESS so that Quartus's power-up value
	// for such a register -- 0 -- is already the correct one.  It must NOT be
	// cleared by `init_reset`, which also pulses on every OSD reset: clearing it
	// there would erase a restored image or a freshly programmed option.
	//
	// One erase pass is 512 clk_sys = 8.9 us.  The 68000 is held far longer:
	// the 3A LS90 watchdog parks at 9 over power-on and only rolls 9 -> 0 on
	// the first /VBLANK edge after the release -- SYNGEN restarts at
	// (v, h) = (0, 0), so that edge is 240 lines away, 240 * 456 * 8 =
	// 875 520 clk_sys (15.3 ms).  A loader byte in the same cycle wins and
	// aborts the pass.
	logic       programmed;
	logic       ld_seen, ld_nonzero;
	logic       por_run;
	logic [8:0] por_addr;
	wire        ld_data_nz  = load_we & (|load_data);
	wire        nx_seen     = ld_seen    | load_we;
	wire        nx_nonzero  = ld_nonzero | ld_data_nz;
	wire        por_we      = por_run & ~load_we;

	always_ff @(posedge clk) begin
		if (ld_data_nz || write_accepted) programmed <= 1'b1;

		if (init_reset) begin
			ld_seen    <= nx_seen;
			ld_nonzero <= nx_nonzero;
			// armed, not running; re-evaluated on every held cycle
			por_run    <= nx_seen ? ~nx_nonzero : ~programmed;
			por_addr   <= 9'd0;
		end else begin
			ld_seen    <= 1'b0;
			ld_nonzero <= 1'b0;
			if (load_we || write_accepted) por_run <= 1'b0;
			else if (por_run) begin
				por_addr <= por_addr + 1'b1;
				if (&por_addr) por_run <= 1'b0;
			end
		end
	end

	assign busy           = |busy_ctr;
	assign write_accepted = cpu_we & unlocked & ~busy;
	assign dump_data      = mem[dump_addr];
	assign oe_n           = unlocked & ~reset;   // 2A LS08 (Q, /RESET)

	// 4B LS74.  /CLR = /RESET is asynchronous on the part; /UNLOCK (/PRE) beats
	// the /WL edge of its own cycle, see the header.
	always_ff @(posedge clk) begin
		if (init_reset || reset) unlocked <= 1'b0;
		else if (unlock)         unlocked <= 1'b1;
		else if (low_write)      unlocked <= 1'b0;
	end

	// The cell array has no reset pin, so programming continues across a board
	// reset.  An out-of-band loader write is the power-up restore and wins.
	//
	// **THE LOADER WRITE IS OUTSIDE THE init_reset GUARD, AND MUST BE.**  At
	// `xybots_main_bus` that input stays asserted for the whole of the index-0
	// download and the whole of an index-2 restore, so a loader write placed in
	// the `else` branch would silently discard every byte the loader delivers
	// -- including the MRA's 0x200-byte erased tail at 0x102000 -- and leave
	// the array at the FPGA RAM's 0x00 power-up value.  Simulation cannot catch
	// that: the sim-only `initial` fill above has already written 0xFF into
	// every cell.
	always_ff @(posedge clk) begin
		if (load_we) begin
			mem[load_addr] <= load_data;
			busy_ctr <= '0;
		end else if (init_reset) begin
			busy_ctr <= '0;
		end else begin
			if (busy && !paused) busy_ctr <= busy_ctr - 1'b1;
			if (por_we) begin
				mem[por_addr] <= 8'hFF;      // factory-erased cell
			end else if (write_accepted) begin
				mem[cpu_addr] <= cpu_wdata;
				busy_ctr <= BUSY_W'(WRITE_CYCLES);
			end
		end

		// During programming the I/O pins float; so do they while /OE is high
		// (the unlocked window).  The board has no bus pull-ups on D0B-D7B, so
		// the modelled float value is the 0xFF that MAME's unmapped read gives.
		if (busy || oe_n) cpu_rdata <= 8'hFF;
		else              cpu_rdata <= mem[cpu_addr];
	end

endmodule
