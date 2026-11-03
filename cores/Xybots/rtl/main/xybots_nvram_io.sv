`timescale 1ns/1ps
//============================================================================
//  MiSTer transport / save-request controller for the Xybots X2804A.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's `toobin_nvram_io.sv`
//  (GPL-3.0-or-later); see NOTICE.md.  Re-based on the Xybots download stream.
//
//  Two channels feed the same 512-byte array:
//   * ioctl index 0 is the MRA ROM stream.  `releases/Xybots.mra` appends the
//     EEPROM image as its last 0x200 bytes at **0x102000**, shipped ERASED
//     (0xFF) exactly like an Atari factory part, so a first cold boot walks
//     the self test's first-power-on setup.  That is the factory image.
//   * ioctl index 2 is the `<nvram index="2" size="512"/>` restore/save
//     channel; it lands on top of the factory image at boot and is what the
//     HPS reads back when the game programs a byte.
//
//  The cell / unlock / busy behaviour stays in `xybots_eeprom_2804`.
//
//  Dirty state deliberately SURVIVES a board or watchdog reset: the physical
//  EEPROM does, so dropping the pending-save flag there could lose a freshly
//  programmed option or high score.  Only FPGA initialisation or an
//  out-of-band factory/NVRAM load establishes a clean image.  If a write and
//  an upload start coincide, the write wins and is requested again.
//============================================================================

module xybots_nvram_io #(
	// ~1.17 s at 57.272727 MHz: long enough that a burst of option writes from
	// one self-test page produces a single upload.
	parameter int unsigned SETTLE_CYCLES = 67_108_863,
	parameter logic [26:0] EEP_BASE = 27'h102000
)(
	input  logic        clk,
	input  logic        init_reset,

	input  logic        write_accepted,

	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,

	output logic        load_we,
	output logic  [8:0] load_addr,
	output logic  [7:0] load_data,
	output logic  [8:0] dump_addr,
	input  logic  [7:0] dump_data,

	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din
);

	wire index0_eeprom = (ioctl_index == 16'd0) &&
	                     (ioctl_addr >= EEP_BASE) &&
	                     (ioctl_addr < EEP_BASE + 27'h200);
	wire index2_nvram  = (ioctl_index == 16'd2);

	assign load_we   = ioctl_download & ioctl_wr & (index0_eeprom | index2_nvram);
	assign load_addr = index2_nvram ? ioctl_addr[8:0] : 9'(ioctl_addr - EEP_BASE);
	assign load_data = ioctl_dout;
	assign dump_addr = ioctl_addr[8:0];

	localparam int SETTLE_W = (SETTLE_CYCLES <= 1) ? 1 : $clog2(SETTLE_CYCLES + 1);
	logic [SETTLE_W-1:0] settle;
	logic dirty;
	wire  settled      = (settle == SETTLE_W'(SETTLE_CYCLES));
	wire  upload_start = ioctl_upload & index2_nvram;

	always_ff @(posedge clk) begin
		if (init_reset) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (write_accepted) begin
			dirty  <= 1'b1;      // a new byte cannot be cleaned by a concurrent upload
			settle <= '0;
		end else if (load_we || upload_start) begin
			dirty  <= 1'b0;
			settle <= '0;
		end else if (dirty && !settled) begin
			settle <= settle + 1'b1;
		end
	end

	assign ioctl_upload_req   = dirty & settled;
	assign ioctl_upload_index = 8'd2;
	assign ioctl_din          = dump_data;

endmodule
