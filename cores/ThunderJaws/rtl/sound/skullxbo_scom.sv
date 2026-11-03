`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones sound link: both Atari SCOM customs (137526-001) and
//  the four-wire cable between them.  120E on the game PCB is the master
//  (S/M- = GND) and 3D on the JSA Audio II board is the slave (S/M- = +5 V),
//  the same arrangement as Vindicators.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Ported from
//  `Arcade-Vindicators_MiSTer/rtl/sound/vind_scom.sv` (GPL-3.0): the
//  two-ended register model, the frame sequencer, the /RESREQ -> RES path
//  and the MAME_MAILBOX switch are that file's.  The pin table, the cable
//  topology and the flag meanings are this board's.
//
//  Pins:
//   pin            120E MASTER (game PCB)            3D SLAVE (JSA II)
//   D0..D7         BD0..BD7                          SD0..SD7
//    4 FULL  out   /IPL2 -> 68000 (level 4),         /NMI -> 6502, LS240 2F SD6,
//                  and -> J1-21                      and -> J1-23
//    5 BUSY  out   /AUDBUSY -> status BD6            SFULL -> LS240 2F SD5
//    6 /EFULL in   <- J1-23                          <- J1-21
//    7 /RESREQ in  /AUDRES (FF1800 write)            +5 V (never asserted)
//    9 WR    in    /AUDWR (FF1400)                   /WRP ($2A02)
//   10 RD    in    /AUDRD (FF5001)                   /RDP ($2802)
//   11 CK    in    /4H = 894.886 kHz, -> J1-25       <- J1-25
//   16 RES   out   not connected                     /SNDRES -> 6502 reset
//   19 SD   bidir  J1-27                             J1-27
//
//  The link clock /4H is made on the game PCB and sent to the slave, so the
//  master owns the bit clock in both directions.
//
//  The cable is symmetric: each end's FULL goes to the other end's /EFULL,
//  and BUSY never leaves either board.  So the flags mean:
//      FULL  = "a byte has arrived in my receive latch and not been read"
//              (set at end of frame, cleared by my own RD)
//      BUSY  = "the far end has not yet taken the byte I sent"
//              (set by my own WR, cleared when the far end's FULL falls)
//  The 68000 checks /AUDBUSY before every command write, and the 6502's NMI
//  handler waits while SFULL is set; MAME's `atari_sound_comm` has the same
//  two flags.
//
//  68000 -> 6502:
//    1. 68000 writes FF1400: master BUSY sets (status D6 reads busy).
//    2. The master sends a frame on SD.
//    3. The slave's FULL sets: 6502 /NMI, and /RDIO D6 = 1.
//    4. 6502 reads $2802 (the program uses the $280A mirror): slave FULL
//       clears, and the master's BUSY clears.
//
//  6502 -> 68000:
//    1. 6502 writes $2A02: slave BUSY sets (SFULL, /RDIO D5 = 1).
//    2. The master clocks the frame in on SD.
//    3. The master's FULL sets: /IPL2, interrupt level 4.
//    4. 68000 reads FF5001: master FULL clears, and the slave's BUSY clears.
//  A write to FF1800 (/AUDRES) asserts the master's /RESREQ; the slave drives
//  /SNDRES on pin 16, and the response side is cleared with it.
//
//  BUSY is drawn without a bar but must be active low (the game side's net is
//  /AUDBUSY and the LS240 inverts it).  The ports here are active high:
//  `audbusy` = 1 means busy, `audfull` = 1 means a response is waiting.
//
//  Framing.  The SCOM is an undumped custom and the schematic does not show
//  its framing.  This model uses a 10-CK frame (start + 8 data bits LSB first
//  + stop), 11.18 us per byte (`FRAME_BITS`).  Only the latency depends on
//  this; nothing the CPUs can see does.  When both directions are pending,
//  the master's own byte goes first (also inferred, and never observable).
//
//  `scom_ck` is the /4H level from skullxbo_main; each rising edge is one CK
//  period.  /4H is clk_sys / 64 exactly, with no short cycle at the line wrap.
//
//  MAME_MAILBOX = 1 replaces the link with MAME's zero-latency mailbox, for
//  comparison.  The default is the schematic.
//============================================================================

module skullxbo_scom #(
	parameter int  FRAME_BITS   = 10,     // start + 8 data + stop, in CK periods
	parameter int  RESET_BITS   = 10,     // /RESREQ -> RES propagation, CK periods
	parameter bit  MAME_MAILBOX = 1'b0,   // 1 = MAME's zero-latency mailbox
	// Test only: 1 drops the `_sent` qualifier from the BUSY release below.
	// The core never sets it.
	parameter bit  BUSY_UNSENT  = 1'b0
) (
	input  logic       clk,
	input  logic       reset,          // power-on reset (both boards)
	input  logic       scom_ck,        // pin 11 CK = LS125 50H = /4H, a level

	// ---- game PCB, SCOM 120E (MASTER) -- the ports skullxbo_main drives ----
	input  logic       audwr_stb,      // /AUDWR pulse  (FF1400 write), 1 clk
	input  logic [7:0] audwr_data,     // BD7:0 at that write
	input  logic       audrd_stb,      // /AUDRD pulse  (FF5001 read),  1 clk
	output logic [7:0] audrd_data,     // the byte that read returns
	input  logic       audres_stb,     // /AUDRES pulse (FF1800 write) -> /RESREQ
	output logic       audfull,        // pin 4 FULL, LOGICAL: 1 = a sound->main
	                                   //   response is waiting -> /IPL2 (level 4)
	output logic       audbusy,        // pin 5 BUSY, LOGICAL: 1 = the last
	                                   //   main->sound command is not consumed
	                                   //   -> status BD6 carries /AUDBUSY = ~this

	// ---- JSA Audio II, SCOM 3D (SLAVE) ----
	input  logic       jsa_rdp,        // /RDP pulse: 6502 read  $2802 (uses $280A)
	input  logic       jsa_wrp,        // /WRP pulse: 6502 write $2A02
	input  logic [7:0] jsa_wrp_data,
	output logic [7:0] jsa_cmd_data,   // the byte the 6502 sees at /RDP
	output logic       jsa_nmi,        // pin 4 FULL -> 6502 /NMI (1 = asserted)
	output logic       jsa_sfull,      // pin 5 BUSY -> SFULL -> /RDIO D5 (1 = set)
	output logic       jsa_res         // pin 16 RES -> /SNDRES (1 = held in reset)
);

	// ---- CK = /4H, taken from the game PCB: one tick per RISING EDGE -------
	logic ck_div;                       // the previous level of pin 11
	wire  ce_ck = scom_ck & ~ck_div;

	// ---- master-side registers (120E) --------------------------------------
	logic [7:0] m_tx_data;    // transmit holding latch  (loaded by /AUDWR)
	logic       m_tx_pend;    // -> pin 5 BUSY / /AUDBUSY
	logic       m_tx_sent;    // shifted out; BUSY now waits for the slave's
	                          // FULL to fall (the J1-23 "Full" wire)
	logic [7:0] m_rx_data;    // receive holding latch   (read by /AUDRD)
	logic       m_rx_full;    // -> pin 4 FULL  / /IPL2

	// ---- slave-side registers (3D) -----------------------------------------
	logic [7:0] s_tx_data;    // transmit holding latch  (loaded by /WRP)
	logic       s_tx_pend;    // -> pin 5 BUSY / SFULL / /RDIO D5
	logic       s_tx_sent;    // shifted out; BUSY waits for the master's FULL
	logic [7:0] s_rx_data;    // receive holding latch   (read by /RDP)
	logic       s_rx_full;    // -> pin 4 FULL / 6502 /NMI / /RDIO D6

	// ---- the cable ---------------------------------------------------------
	//  `sd`         J1-27, driven by whichever SD pin owns the frame
	//  `full_m2s`   J1-21, master pin 4 FULL -> slave  pin 6 /EFULL
	//  `full_s2m`   J1-23, slave  pin 4 FULL -> master pin 6 /EFULL
	//  (CK is `ce_ck` itself, out on J1-25.)
	logic       sd;
	wire        full_m2s = m_rx_full;
	wire        full_s2m = s_rx_full;
	wire        m_efull  = full_s2m;     // master pin 6
	wire        s_efull  = full_m2s;     // slave  pin 6

	// ---- frame sequencer: the master owns CK, so ONE counter steps both
	//      shift registers.  dir 0 = master -> slave, 1 = slave -> master.
	localparam int FCW = $clog2(FRAME_BITS + 1);
	logic           frame_act;
	logic           frame_dir;
	logic [FCW-1:0] frame_bit;
	logic [7:0]     shifter;

	// ---- /RESREQ -> RES.  The request travels the same link, so it is held
	//      for RESET_BITS CK periods (~11 us, ~20 6502 cycles).
	localparam int RCW = $clog2(RESET_BITS + 1);
	logic [RCW-1:0] res_cnt;

	assign audrd_data  = m_rx_data;
	assign audfull     = m_rx_full;
	assign audbusy     = m_tx_pend;
	assign jsa_cmd_data = s_rx_data;
	assign jsa_nmi     = s_rx_full;
	assign jsa_sfull   = s_tx_pend;
	assign jsa_res     = (res_cnt != '0);

	// Each end's BUSY is released by the FAR end's FULL FALLING, which is the
	// only edge the cable carries in that direction.
	logic m_rx_full_d, s_rx_full_d;

	always_ff @(posedge clk) begin
		if (reset) begin
			ck_div    <= 1'b0;
			m_tx_data <= 8'h00; m_tx_pend <= 1'b0; m_tx_sent <= 1'b0;
			m_rx_data <= 8'h00; m_rx_full <= 1'b0;
			s_tx_data <= 8'h00; s_tx_pend <= 1'b0; s_tx_sent <= 1'b0;
			s_rx_data <= 8'h00; s_rx_full <= 1'b0;
			frame_act <= 1'b0;  frame_dir <= 1'b0; frame_bit <= '0;
			shifter   <= 8'h00; sd        <= 1'b1;
			res_cnt   <= '0;
			m_rx_full_d <= 1'b0; s_rx_full_d <= 1'b0;
		end else begin
			ck_div      <= scom_ck;
			m_rx_full_d <= m_rx_full;
			s_rx_full_d <= s_rx_full;

			// -------- the two "Full" wires -> the far end's /EFULL --------
			// Only the far CPU's READ (or, for the slave, /AUDRES) can make
			// these edges happen, which is what closes the handshake.  Placed
			// FIRST so that a CPU write landing on the same clk as a far-end
			// release still raises BUSY (the later assignment wins in SV).
			//
			// The `_sent` qualifier matters.  If a new byte has been loaded
			// since the last one was sent, the far end's FULL falling refers to
			// the previous byte; clearing BUSY then would also drop the new
			// byte, because a frame only starts while BUSY is set.
			if (!MAME_MAILBOX) begin
				if (s_rx_full_d && !s_rx_full && (m_tx_sent | BUSY_UNSENT)) m_tx_pend <= 1'b0;
				if (m_rx_full_d && !m_rx_full && (s_tx_sent | BUSY_UNSENT)) s_tx_pend <= 1'b0;
			end

			// -------- CPU-side accesses (fabric rate) --------
			// /AUDWR: load the master transmit latch, raise BUSY (/AUDBUSY).
			if (audwr_stb) begin
				m_tx_data <= audwr_data;
				m_tx_pend <= 1'b1;
				m_tx_sent <= 1'b0;
			end
			// /WRP: load the slave transmit latch, raise BUSY (SFULL, D5).
			if (jsa_wrp) begin
				s_tx_data <= jsa_wrp_data;
				s_tx_pend <= 1'b1;
				s_tx_sent <= 1'b0;
			end
			// /RDP: the 6502 takes the command -> slave FULL releases (NMI, D6).
			if (jsa_rdp)   s_rx_full <= 1'b0;
			// /AUDRD: the 68000 takes the response -> master FULL releases.
			if (audrd_stb) m_rx_full <= 1'b0;

			// -------- the serial link (on CK) --------
			if (MAME_MAILBOX) begin
				// A/B mode: zero-latency mailbox with MAME's flag semantics.
				if (audwr_stb) begin s_rx_data <= audwr_data; s_rx_full <= 1'b1; end
				else if (jsa_rdp) m_tx_pend <= 1'b0;
				if (jsa_wrp) begin m_rx_data <= jsa_wrp_data; m_rx_full <= 1'b1; end
				else if (audrd_stb || audres_stb) s_tx_pend <= 1'b0;
			end else if (ce_ck) begin
				if (!frame_act) begin
					// Idle.  The master's own transmit wins the wire; otherwise
					// the master polls and the slave answers if it has a byte.
					// Each end is held off by its own /EFULL pin, which is the
					// far end's FULL: "your receive latch is still full, wait".
					if (m_tx_pend && !m_tx_sent && !m_efull) begin
						frame_act <= 1'b1; frame_dir <= 1'b0;
						frame_bit <= '0;   shifter   <= m_tx_data;
						sd        <= 1'b0;                     // start bit
					end else if (s_tx_pend && !s_tx_sent && !s_efull) begin
						frame_act <= 1'b1; frame_dir <= 1'b1;
						frame_bit <= '0;   shifter   <= s_tx_data;
						sd        <= 1'b0;                     // start bit
					end else begin
						sd <= 1'b1;                            // idle high
					end
				end else begin
					frame_bit <= frame_bit + FCW'(1);
					if (frame_bit < FCW'(8)) begin
						sd      <= shifter[0];                 // LSB first
						shifter <= {1'b1, shifter[7:1]};
					end else begin
						sd <= 1'b1;                            // stop / turnaround
					end
					if (frame_bit == FCW'(FRAME_BITS-1)) begin
						frame_act <= 1'b0;
						if (frame_dir == 1'b0) begin
							// master -> slave: the command lands and the slave's
							// FULL sets (6502 /NMI, /RDIO D6).  The master's BUSY
							// stays set until that FULL falls, over J1-23.
							s_rx_data <= m_tx_data;
							s_rx_full <= 1'b1;
							m_tx_sent <= 1'b1;
						end else begin
							// slave -> master: the response lands and the master's
							// FULL sets (/IPL2).  The slave's BUSY stays set until
							// that FULL falls, over J1-21.
							m_rx_data <= s_tx_data;
							m_rx_full <= 1'b1;
							s_tx_sent <= 1'b1;
						end
					end
				end
			end

			// -------- /RESREQ -> RES over the link --------
			if (audres_stb) begin
				res_cnt   <= RCW'(RESET_BITS);
				s_tx_pend <= 1'b0;      // the response side is cleared with it
				s_tx_sent <= 1'b0;
				m_rx_full <= 1'b0;
			end else if (ce_ck && res_cnt != '0) begin
				res_cnt <= res_cnt - RCW'(1);
			end
		end
	end

	// `sd` models the real wire for waveforms; nothing uses it (the receive
	// latch is loaded from the transmit latch at end of frame, which is what
	// the shift register would have reassembled).
	wire _unused_cable = &{1'b0, sd, shifter[7]};

endmodule
