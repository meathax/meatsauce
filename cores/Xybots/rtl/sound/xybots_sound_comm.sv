//============================================================================
//  Xybots (Atari Games, 1987) — inter-CPU sound mailbox (the Atari SCOM pair).
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_sound_comm.sv
//  (GPL-3.0-or-later), which reproduces MAME's `atari_sound_comm` device; see
//  NOTICE.md.
//
//  ---- what the hardware is (SP-313 sheets 3 and 14) -----------------------
//  The main<->sound link is NOT a pair of parallel latches.  It is two Atari
//  SCOM customs exchanging a byte SERIALLY over one wire:
//
//    game PCB 20E (MASTER, S/M- = GND)      audio PCB 1M (SLAVE, S/M- = PR1)
//      /WR   = /AUDWR  (0x806900 write)       /WR   = /WRP  (0x2A02 write)
//      /RD   = /AUDRD  (0x806001 read)        /RD   = /RDP  (0x2802 read)
//      /RESREQ = /AUDRES (0x806E00 write)     /RESREQ = PR1 (never asserted)
//      /EFULL  = /AUDFLAG (from the slave)    /EFULL  = FIN  (from the master)
//      CK      = AUDCLK = 4H                  CK      = /CLK (the master's)
//      /FULL   = /IPL1 -> 68000 IRQ2          FULL    = /NMI -> 6502 NMI
//      /BUSY   = /AUDBUSY -> /SYSIN bit 9     BUSY    = SFULL -> /RDIO bit 5
//      SD      = AUDAT ------------------ /DATA (bidirectional serial data)
//      /RES    = stub, not connected          RES     = /SNDRES -> 6502 RESET
//
//  Two consequences the register-level model has to be honest about:
//
//   1. **The sound-CPU reset travels over the link.**  There is no reset wire
//      in the AUD ribbon: a /RESREQ pulse on the master makes the *slave's*
//      RES output drive /SNDRES.  Modelled here as `snd_reset` pulsing on
//      `main_sndrst_wr`, which is what MAME does too.
//   2. **A transfer takes a serial frame, not zero time.**  AUDCLK is 4H =
//      7.159091 MHz / 8 = 894.886 kHz (1.1175 us/bit), so a byte costs at
//      least 8 bit times = 8.94 us, i.e. ~16 6502 cycles or ~64 68000 cycles;
//      with framing bits it is longer.  This model transfers in one clk_sys
//      cycle.  **It is not observable in the Xybots ROMs' behaviour**: over a
//      25 s MAME trace the 68000 polled /SYSIN bit 9 (/AUDBUSY) 6687 times
//      before its 2392 /AUDWR commands and found it ready on every single one,
//      so no code path ever waited on the link — and MAME is itself
//      zero-latency.  Should a difference ever turn up, the place to add it is
//      here, as a countdown that delays the set of `m2s_ready`/`s2m_ready`.
//
//  ---- register-level semantics (MAME atariscom.cpp) -----------------------
//    main_command_w  (68000 writes 0x806900): latch main->sound data, set
//                     main_to_sound_ready, assert the 6502 NMI.
//    sound_command_r (6502 reads 0x2802 /RDP): clear main_to_sound_ready + NMI.
//    sound_response_w(6502 writes 0x2A02 /WRP): latch sound->main data, set
//                     sound_to_main_ready, assert the 68000 IRQ2.
//    main_response_r (68000 reads 0x806001): clear sound_to_main_ready + IRQ2.
//                     IRQ2 has NO acknowledge strobe on Xybots — this read is
//                     the only hardware access its handler makes, so clearing
//                     it here is required.
//    sound reset     (68000 writes 0x806E00): reset the 6502 and clear the
//                     response side.
//
//  The two CPUs run in one FPGA fabric on clock enables, so MAME's zero-delay
//  synchronisation timers collapse to synchronous set/clear here.  On a
//  same-cycle set+clear of a ready flag the set (new datum) wins, so a command
//  or response is never silently dropped.
//============================================================================

module xybots_sound_comm
(
	input  logic       clk,
	input  logic       reset,           // global/power-on reset

	// ---- main-CPU (68000) side ----
	input  logic       main_cmd_wr,     // pulse: 68000 wrote 0x806900 (/AUDWR)
	input  logic [7:0] main_cmd_data,   // D7:0 of that write
	input  logic       main_resp_rd,    // pulse: 68000 read  0x806001 (/AUDRD)
	input  logic       main_sndrst_wr,  // pulse: 68000 wrote 0x806E00 (/AUDRES)
	output logic [7:0] main_resp_data,  // data returned to the 68000 read
	output logic       main_irq,        // -> 68000 IRQ2 (level)
	output logic       main_to_sound_ready,
	output logic       sound_to_main_ready,

	// ---- sound-CPU (6502) side ----
	input  logic       snd_cmd_rd,      // pulse: 6502 read  0x2802 (/RDP)
	input  logic       snd_resp_wr,     // pulse: 6502 wrote 0x2A02 (/WRP)
	input  logic [7:0] snd_resp_data,
	output logic [7:0] snd_cmd_data,    // data returned to the 6502 command read
	output logic       snd_nmi,         // -> 6502 NMI (level while a command is pending)
	output logic       snd_reset        // -> 6502 reset (1-cycle pulse)
);

	logic [7:0] m2s_data, s2m_data;
	logic       m2s_ready, s2m_ready;

	assign main_to_sound_ready = m2s_ready;
	assign sound_to_main_ready = s2m_ready;
	assign snd_cmd_data        = m2s_data;
	assign main_resp_data      = s2m_data;
	assign snd_nmi             = m2s_ready;   // SCOM FULL -> 6502 /NMI
	assign main_irq            = s2m_ready;   // SCOM /FULL -> 68000 /IPL1

	always_ff @(posedge clk) begin
		if (reset) begin
			m2s_data  <= 8'h00;
			s2m_data  <= 8'h00;
			m2s_ready <= 1'b0;
			s2m_ready <= 1'b0;
			snd_reset <= 1'b0;
		end else begin
			snd_reset <= 1'b0;

			// main -> sound command latch
			if (main_cmd_wr) begin
				m2s_data  <= main_cmd_data;
				m2s_ready <= 1'b1;          // set wins over a coincident 6502 read
			end else if (snd_cmd_rd) begin
				m2s_ready <= 1'b0;
			end

			// sound -> main response latch
			if (snd_resp_wr) begin
				s2m_data  <= snd_resp_data;
				s2m_ready <= 1'b1;          // set wins over a coincident 68000 read
			end else if (main_resp_rd || main_sndrst_wr) begin
				s2m_ready <= 1'b0;
			end

			// /AUDRES -> master /RESREQ -> slave RES -> /SNDRES
			if (main_sndrst_wr)
				snd_reset <= 1'b1;
		end
	end

endmodule
