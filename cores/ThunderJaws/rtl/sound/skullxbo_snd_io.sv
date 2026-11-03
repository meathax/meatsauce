`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones JSA Audio II (A047184-02): the parts on the LS138 3F
//  strobes: the LS273 4D control latch ($2A04 /WRIO), the LS174 3C mixer
//  latch ($2A06 /MIX), the LS240 2F status port ($2804 /RDIO) and the two
//  coin-counter drivers.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Module shape and port style
//  follow the Bad Lands core's `badlands_snd_io.sv` and the Vindicators
//  core's `vind_jsa_io.sv` (both GPL-3.0).  The bit maps are this board's
//  (they differ from the JSA I and from Bad Lands).  The periodic-IRQ divider
//  is in skullxbo_snd_bus.
//
//  LS273 4D, control latch.  Clocked by /WRIO; cleared by /RESET.
//
//    bit  net        effect
//    SD7  BA13       sound-ROM bank MSB  -> PAL 2D
//    SD6  BA12       sound-ROM bank LSB  -> PAL 2D
//    SD5  CCTR2      coin counter -> Q1 -> J1-12
//    SD4  CCTR1      coin counter -> Q2 -> J1-11
//    SD3  VFREQ      MSM6295 SS (sample-rate select)
//    SD2  /OKIRES    MSM6295 RESET (0 = held in reset)
//    SD1  --         not connected (that D input is grounded)
//    SD0  /YAMRES    YM2151 /IC and YM3012 ICL (0 = reset)
//
//  /RESET clears the whole latch: bank 0, counters off, VFREQ = 0 (7231 Hz
//  sample rate), OKI and YM2151 held in reset.  The firmware then pulses
//  /YAMRES and later releases /OKIRES, and it re-pulses /OKIRES during play,
//  so /OKIRES must be a real reset level, not an edge.
//
//  LS174 3C, mixer latch.  Clocked by /MIX; cleared by /RESET.  A hex flop:
//
//    bit  net        effect
//    SD5  LPF        switches C25 into the YM2151 Sallen-Key filter
//    SD4  --         not connected (that D input is grounded)
//    SD3  YM2        YM2151 volume bit 2  //    SD2  YM1        YM2151 volume bit 1   > 4066 ladder, gain = N/7
//    SD1  YM0        YM2151 volume bit 0  /
//    SD0  SP0        MSM6295 volume step
//    SD7, SD6        not connected
//
//  The game writes $0F at boot (filter off, YM volume 7) and changes both the
//  filter and the YM volume during play.
//
//  LS240 2F, /RDIO at $2804.  An inverting buffer, so an asserted (low)
//  input reads 1:
//
//    SD7 = self-test switch on
//    SD6 = a main->sound command is pending (/NMI)
//    SD5 = a sound->main response is pending (SFULL)
//    SD4 = self-test switch on (the same net as SD7; MAME says +5 V)
//    SD3 = J1-33 coin        SD2 = J1-31 coin
//    SD1 = J1-35 coin        SD0 = J1-36 coin
//
//  There are four coin inputs (MAME declares three).  An idle input reads 0
//  and a closed switch 1.  The firmware never reads SD6 or SD4, so MAME's
//  opposite sense for them is not observable.  `mame_polarity` = 1
//  reproduces MAME's byte (D6 = no command pending, D4 = 1), for comparison;
//  the core ties it to 0.
//
//  Coin counters: CCTR2 drives J1-12 and CCTR1 J1-11, but R13 (0 ohm)
//  bridges the two, so on the board either bit drives both counter pins.
//  `cctr_wired_or` is that node; the two bits are also output separately.
//============================================================================

module skullxbo_snd_io
(
	input  logic        clk,

	// ---- /RESET = POR AND /SNDRES -- 4D /MR and 3C /MR ----
	input  logic        reset_n,

	// ---- LS273 4D ----
	input  logic        wrio_stb,      // /WRIO ($2A04), one ce_1m79 clock
	input  logic  [7:0] wrio_data,     // SD7:0 at that write

	// ---- LS174 3C ----
	input  logic        mix_stb,       // /MIX ($2A06), one ce_1m79 clock
	input  logic  [7:0] mix_data,      // SD7:0 at that write

	// ---- LS240 2F sources (all logical "asserted" = 1) ----
	input  logic        self_test,     // SW1 / JAMMA-R: 1 while ON
	input  logic        cmd_pending,   // SCOM 3D FULL  (the /NMI line, asserted)
	input  logic        resp_pending,  // SCOM 3D BUSY  (SFULL, asserted)
	input  logic  [3:0] coin,          // {J1-33, J1-31, J1-35, J1-36}, 1 = closed
	input  logic        mame_polarity, // test only: MAME's D6/D4 senses

	// ---- LS273 4D outputs ----
	output logic  [1:0] bank,          // {BA13, BA12} -> PAL 2D pins 4, 3
	output logic        cctr2,         // 4D Q6, bit 5 -> Q1 -> J1-12
	output logic        cctr1,         // 4D Q5, bit 4 -> Q2 -> J1-11
	output logic        cctr_wired_or, // the R13 = 0 ohm node
	output logic        vfreq,         // MSM6295 pin 7 SS  (0 from reset)
	output logic        okires_n,      // MSM6295 pin 8 RESET, active low
	output logic        yamres_n,      // YM2151 /IC + YM3012 ICL, active low

	// ---- LS174 3C outputs ----
	output logic        lpf,           // 3C Q6, bit 5 -> Q5 -> C25
	output logic  [2:0] ym_vol,        // 3C Q4:Q2, bits 3:1 -> 4066 3B, N = 0..7
	output logic        sp0,           // 3C Q1, bit 0 -> 4066 section D

	// ---- the assembled $2804 byte ----
	output logic  [7:0] rdio_data
);

	// ---- LS273 4D ----------------------------------------------------------
	// /MR is asynchronous on the part; here it is a synchronous clear, which
	// is indistinguishable here (/RESET is tens of microseconds wide).
	always_ff @(posedge clk) begin
		if (!reset_n) begin
			bank     <= 2'd0;
			cctr2    <= 1'b0;
			cctr1    <= 1'b0;
			vfreq    <= 1'b0;   // SS = 0 -> /165 -> 7231 Hz
			okires_n <= 1'b0;   // the MSM6295 is HELD IN RESET from power-on
			yamres_n <= 1'b0;   // and so is the YM2151
		end else if (wrio_stb) begin
			bank     <= wrio_data[7:6];
			cctr2    <= wrio_data[5];
			cctr1    <= wrio_data[4];
			vfreq    <= wrio_data[3];
			okires_n <= wrio_data[2];
			yamres_n <= wrio_data[0];
		end
	end

	// R13 = 0 ohm ties J1-11 and J1-12 into one node.
	assign cctr_wired_or = cctr1 | cctr2;

	// wrio_data[1] reaches no D input on 4D (the pin is grounded).
	wire _unused_wrio = &{ 1'b0, wrio_data[1] };

	// ---- LS174 3C ----------------------------------------------------------
	always_ff @(posedge clk) begin
		if (!reset_n) begin
			lpf    <= 1'b0;     // filter disengaged
            ym_vol <= 3'd7;     // MAME JSA-II reset gain is 1.0
            sp0    <= 1'b1;     // MAME JSA-II reset gain is 1.0
		end else if (mix_stb) begin
			lpf    <= mix_data[5];
			ym_vol <= mix_data[3:1];
			sp0    <= mix_data[0];
		end
	end

	// Bits 7, 6 and 4 reach no D input on 3C (a hex flop with D2 grounded).
	// MAME comments them as JSA III / IIIs features.
	wire _unused_mix = &{ 1'b0, mix_data[7:6], mix_data[4] };

	// ---- LS240 2F ----------------------------------------------------------
	// D7 = D4 = self-test; D6 = command pending; D5 = response pending;
	// D3:D0 = the four coin inputs.  ALL ACTIVE HIGH after the inverter.
	wire d6 = mame_polarity ? ~cmd_pending : cmd_pending;
	wire d4 = mame_polarity ?  1'b1        : self_test;
	assign rdio_data = { self_test, d6, resp_pending, d4, coin };

endmodule
