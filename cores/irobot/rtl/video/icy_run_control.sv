`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Vector-generator run control: makes one ICY run atomic with respect to the
// STATWR writes that surround it.
//
// MAME's statwr_w (irobot_m.cpp:86-95) latches m_commbank from STATWR bit 7 and
// then calls run_video(), which captures m_commram[m_commbank] once
// (irobot_v.cpp:254) and walks the entire display list before returning.  Every
// bit-2 rising edge therefore draws its whole list, against the bank that was
// selected when that edge occurred.
//
// The RTL engine takes real time, so two things that cannot happen in MAME can
// happen here.  Measured in gameplay (level 1, frame 3599 of
// scenarios/attract_coin_start.input.jsonl) the game issues two VG starts on
// alternating banks only 811 CPU cycles -- about 6500 clk_12m096 clocks --
// apart, while an ICY run over one of those lists needs far longer:
//
//   * the second start arrived while icy_object_fetch was mid-walk, and
//     icy_object_fetch only accepts `start` in IDLE, so that entire display
//     list (the starfield, the Big Brother head and the distant geometry) was
//     dropped;
//   * STATWR bit 7 fed irobot_commram directly, so the run already in flight
//     switched communication banks mid-walk and finished by drawing a
//     different list's data through the first list's pointers.
//
// This block holds one deferred start (with the bank that was selected when it
// was issued) and presents the ICY memory port a bank that is frozen for the
// duration of a run.  The CPU keeps its own live view of STATWR bit 7.
module icy_run_control (
	input  logic clk,
	input  logic reset,
	// One-cycle pulse: STATWR bit 2 rising edge.
	input  logic video_start,
	// STATWR bit 7, live.
	input  logic statwr_bank,
	// Framebuffer clear in progress; ICY writes are discarded while it runs.
	input  logic clear_active,
	// The engine's own busy flag.
	input  logic icy_busy,
	output logic icy_start,
	output logic video_busy,
	// Communication-RAM bank presented to the ICY read port.
	output logic video_bank
);
	logic pending, pending_bank, run_bank;
	wire blocked = clear_active | icy_busy;
	wire start_bank = pending ? pending_bank : statwr_bank;

	assign icy_start  = (video_start | pending) & ~blocked;
	assign video_busy = icy_busy | pending;
	// A run reads the bank captured when its start was issued.  Between runs
	// the port follows STATWR so a fresh start sees the current selection.
	assign video_bank = icy_busy ? run_bank : statwr_bank;

	always_ff @(posedge clk) begin
		if (reset) begin
			pending      <= 1'b0;
			pending_bank <= 1'b0;
			run_bank     <= 1'b0;
		end else begin
			// run_bank is registered here and icy_busy rises on the same edge,
			// one clock before icy_object_fetch can raise mem_req, so the bank
			// is settled before the run's first read.
			if (icy_start) run_bank <= start_bank;
			if (video_start && blocked) begin
				pending      <= 1'b1;
				pending_bank <= statwr_bank;
			end else if (!blocked) begin
				pending <= 1'b0;
			end
		end
	end
endmodule
