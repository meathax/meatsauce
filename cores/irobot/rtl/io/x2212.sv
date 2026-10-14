`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// X2212D: independent 256x4 volatile and nonvolatile arrays. Host readback
// exposes the live SRAM image so MiSTer persistence captures writes made since
// the last STORE; host downloads still populate the nonvolatile array.
module x2212 (
	input  logic       clk,
	input  logic       reset,
	input  logic       cs,
	input  logic       we,
	input  logic [7:0] addr,
	input  logic [3:0] din,
	output logic [3:0] dout,
	input  logic       store,
	input  logic       recall,
	input  logic       host_we,
	input  logic [7:0] host_addr,
	input  logic [3:0] host_din,
	output logic [3:0] host_dout,
	output logic       busy
);
	logic [3:0] live [0:255];
	logic [3:0] nv   [0:255];
	// X2212 power-up state.  The nonvolatile array is a floating-gate E2PROM:
	// an erased cell reads as a one, so a part that has never had a STORE
	// performed on it presents 0xF in every nibble, and the power-up RECALL
	// copies that into the live SRAM.  MAME's x2212 model fills its E2PROM
	// with 0xff for the same reason (devices/machine/x2212.cpp,
	// nvram_default).  Without this the FPGA arrays come up all-zero, the
	// board's NOVRAM verifier at $8384 accumulates a different checksum from
	// the reference, and the two models take different initialisation paths
	// out of cold reset.  A real cabinet's contents are whatever was last
	// stored; MiSTer supplies that through the host port when a save exists.
	initial begin
		for (int unsigned index = 0; index < 256; index++) begin
			live[index] = 4'hf;
			nv[index]   = 4'hf;
		end
	end
	logic store_d, recall_d;
	typedef enum logic [1:0] {IDLE, STORING, RECALLING} copy_state_t;
	copy_state_t state;
	logic [7:0] copy_addr;

	assign dout = live[addr];
	assign host_dout = live[host_addr];

	always_ff @(posedge clk) begin
		// The host persistence port models the operator loading a previously
		// stored part, so it is deliberately independent of the board reset.
		// MiSTer streams the saved image in while the core is held in reset for
		// the ROM/DIP download; gating these writes on !reset silently dropped
		// the whole image, the game then found an erased array, reinitialised
		// the table and persisted those defaults over the player's scores.
		// Writing both arrays keeps the part consistent whether the following
		// power-on RECALL runs or not.
		if (host_we) begin
			nv[host_addr]   <= host_din;
			live[host_addr] <= host_din;
		end

		if (reset) begin
			// The live/nonvolatile arrays intentionally retain their contents;
			// only the edge detectors and copy engine are reset.  Initialising
			// these two flops is required so a power-on recall cannot depend on
			// simulator X-state or an arbitrary first input sample.
			store_d <= 1'b0;
			recall_d <= 1'b0;
			state <= RECALLING;
			copy_addr <= 0;
		end else begin
			store_d <= store;
			recall_d <= recall;
			// MiSTer may restore the persisted image while the power-on recall
			// copy is still in progress.  The host path is an external
			// persistence port, so it must not be gated by the internal copy
			// state.  Updating both images makes the restored byte immediately
			// visible and prevents a later recall cycle from resurrecting the
			// stale nonvolatile nibble.
			case (state)
			IDLE: begin
				if (cs && we) live[addr] <= din;
				if (store && !store_d) begin state<=STORING; copy_addr<=0; end
				else if (recall && !recall_d) begin state<=RECALLING; copy_addr<=0; end
			end
			STORING: begin
				// A host restore has priority over the copy engine for the same
				// address; otherwise the old live value can overwrite it.
				if (!(host_we && host_addr == copy_addr))
					nv[copy_addr] <= live[copy_addr];
				copy_addr <= copy_addr + 1'd1;
				if(copy_addr==8'hff) state<=IDLE;
			end
			RECALLING: begin
				// A host restore has priority over the copy engine for the same
				// address; otherwise stale NV data can overwrite the restore.
				if (!(host_we && host_addr == copy_addr))
					live[copy_addr] <= nv[copy_addr];
				copy_addr <= copy_addr + 1'd1;
				if(copy_addr==8'hff) state<=IDLE;
			end
			default: begin state<=RECALLING; copy_addr<=0; end
			endcase
		end
	end
	assign busy = state != IDLE;
endmodule
