`timescale 1ns/1ps
//============================================================================
//  Batman motion-object line buffers: the two 137536-001 customs at 11B and
//  11C.  One bank is written by the MOB while the display reads the other.
//
//  Copyright (C) 2026 the Batman MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE and NOTICE.md.
//  Structure follows skullxbo_lb.sv of the Skull & Crossbones MiSTer core
//  (GPL-3.0); see NOTICE.md.  The address counters live in batman_mob.sv;
//  this module is the storage, the bank flip and the erase.
//
//  The manual lacks the video sheets, so this follows MAME's atarimo.  Each
//  location holds {MPR2:0 priority, MPAL3:0 colour, MPX3:0 pen}.  The pen is
//  stored as the complement of the (inverted) stamp ROM bits, so an all-zero
//  location is transparent and a freshly configured BRAM starts empty;
//  batman_mob inverts on the way in and the mixer on the way out.
//
//  LB_ERASE: the read pass clears each location one pixel behind the read
//  pointer, so the bank is empty before the MOB writes it again (0 = no
//  erase, which leaves stale objects).
//  FIRST_WINS: MAME draws Batman's object list in reverse, so the first entry
//  ends up on top.  Walking the list forwards gives the same result only if a
//  write is suppressed where an opaque pixel is already stored.
//============================================================================

module thunderjaws_lb #(
	parameter bit LB_ERASE  = 1'b1,
	parameter bit FIRST_WINS = 1'b1
)(
	input  logic        clk,
	input  logic        reset,

	// ---- the bank the MOB is writing; the display reads the other one -----
	input  logic        wbank,
    input logic scan_enable,
    input logic [9:0] scan_address,
    output wire [10:0] scan_q,

	// ---- the write side (batman_mob.sv owns the address) -----------------
	input  logic        we,
	input  logic  [9:0] wa,
	input  logic [10:0] wd,          // {MPR2:0, MPAL3:0, MPX3:0}

	// ---- the read side ----------------------------------------------------
	input  logic        rd_ce,       // one pulse per displayed pixel
	input  logic  [9:0] ra,
	output logic [10:0] q
);

	localparam logic [10:0] EMPTY = 11'd0;

	logic [10:0] mem0 [0:1023];
	logic [10:0] mem1 [0:1023];
    integer i;initial for(i=0;i<1024;i=i+1)begin mem0[i]=0;mem1[i]=0;end
    logic collision_forward;
    logic [10:0] collision_data;

	// One write-side pipeline stage reads the target location's occupancy
	// before the write commits. Same-address consecutive writes forward the
	// actual committed pixel so FIRST_WINS does not depend on RAM collision mode.
	logic        we_d, wbank_d;
	logic  [9:0] wa_d;
	logic [10:0] wd_d;
	logic [10:0] occ;                // what the target location already holds

	// The erase runs one pixel behind the read pointer, so a location is
	// cleared only after it has been displayed.
	logic  [9:0] ra_d;
	logic        ers;

	always_ff @(posedge clk) begin
		if (reset) begin
			we_d <= 1'b0;
			ers  <= 1'b0;
		end else begin
			we_d    <= we;
			wa_d    <= wa;
			wd_d    <= wd;
			wbank_d <= wbank;
			ers     <= rd_ce & (LB_ERASE != 0);
			if (rd_ce) ra_d <= ra;
		end
	end

	// Write only opaque pixels and, under FIRST_WINS, only into empty locations.
	wire wr_ok = we_d && (wd_d[3:0] != 4'h0)
	                  && (!FIRST_WINS || (occ[3:0] == 4'h0));

    always_ff @(posedge clk)begin
        if(reset)collision_forward<=0;
        else begin
            collision_forward<=wr_ok && wbank_d==wbank && wa_d==wa;
            collision_data<=wd_d;
        end
    end

	// Each bank sees one read and one write per clk: the write bank takes the
	// occupancy read and object write, the read bank the display read and the
	// erase.  That is a plain simple dual-port RAM.
    wire [9:0] write_read_address=scan_enable ? scan_address : wa;
	wire [9:0] a0_rd = (wbank   == 1'b0) ? write_read_address : ra;
	wire [9:0] a1_rd = (wbank   == 1'b1) ? write_read_address : ra;
	wire [9:0] a0_wr = (wbank_d == 1'b0) ? wa_d : ra_d;
	wire [9:0] a1_wr = (wbank_d == 1'b1) ? wa_d : ra_d;
	wire       e0_wr = (wbank_d == 1'b0) ? wr_ok : ers;
	wire       e1_wr = (wbank_d == 1'b1) ? wr_ok : ers;
	wire [10:0] d0_wr = (wbank_d == 1'b0) ? wd_d : EMPTY;
	wire [10:0] d1_wr = (wbank_d == 1'b1) ? wd_d : EMPTY;

	logic [10:0] q0, q1;
	always_ff @(posedge clk) begin
		q0 <= mem0[a0_rd];
		if (e0_wr) mem0[a0_wr] <= d0_wr;
	end
	always_ff @(posedge clk) begin
		q1 <= mem1[a1_rd];
		if (e1_wr) mem1[a1_wr] <= d1_wr;
	end

	// Select by the bank in force when the read address was issued.
	assign occ = collision_forward ? collision_data : wbank_d ? q1 : q0;
	assign q   = wbank_d ? q0 : q1;
    assign scan_q=wbank ? q1 : q0;

	/* verilator lint_off UNUSEDSIGNAL */
	wire _unused = &{1'b0, occ[10:4], 1'b0};
	/* verilator lint_on UNUSEDSIGNAL */

endmodule
