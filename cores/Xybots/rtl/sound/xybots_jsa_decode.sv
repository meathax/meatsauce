//============================================================================
//  Xybots (Atari Games, 1987) — JSA I sound-CPU (6502) address decoder.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa_decode.sv
//  (GPL-3.0-or-later); see NOTICE.md.  Both games carry the same Atari
//  "Stand-Alone Audio PCB" — Xybots' copy is SP-313 sheets 11-14 (PDF pages
//  13-16), Toobin's SP-320 sheets 19-22 — and nothing in this module differs
//  between them: the address map is a property of the board.
//
//  ---- what the board decodes (SP-313 sheet 12) ----------------------------
//  Four parts do the whole job, and all four are modelled here as parts:
//
//    * 2L-PAL, Atari 136056-2101 (`xybots_jsa_pal_2l`, transcribed from its
//      fuse map).  Produces /RAM, /YAM, /REST, /ROM, /SWR, /SRD and the banked
//      A13B/A12B.
//    * 4M 74LS138, G1(6)=/SRD, /G2A(5)=/REST, /G2B(4)=SA10,
//      SELC(3)=SA9, SELB(2)=SA2, SELA(1)=SA1:
//         Y0 0x2800 n/c    Y1 /RDP     Y2 /RDIO    Y3 /IRQACK
//         Y4 /VOICE        Y5 /WRP     Y6 /WRIO    Y7 /MIX
//      Only SA9, SA2 and SA1 are decoded, so SA8..SA3 and SA0 are don't-cares
//      — which is exactly MAME's `.mirror(0x01f9)`, confirmed from the drawing
//      rather than assumed.  (The Xybots sound ROM really does use the mirror:
//      it addresses /RDP as $280A, /RDIO as $280C and /IRQACK as $280E.)
//    * POKEY 3K: CS0(30)=/REST, CS1(31)=SA10 — so the POKEY socket answers to
//      the whole of 0x2C00-0x2FFF with SA3:SA0 as the register.  MAME's
//      `map(0x2c00,0x2c0f).mirror(0x03f0)` covers the identical range.
//    * YM2151 2F: /CS(7)=/YAM from the PAL, A0(4)=SA0.
//
//  Two properties come from the PAL fuse map rather than from MAME's map:
//
//  1. G1 = /SRD.  Inside 0x2800-0x2FFF the PAL's /SRD is not a read strobe but
//     a direction code: it stays HIGH (LS138 enabled) for READS with SA9 = 0
//     and for WRITES with SA9 = 1, and drops otherwise.  So /RDP, /RDIO and
//     /IRQACK exist only on a read and /VOICE, /WRP, /WRIO and /MIX only on a
//     write.  The decoder therefore takes `rnw` and its LS138 selects are
//     direction-qualified — /IRQACK is read-only (MAME also maps
//     `sound_irq_ack_w`; the Xybots ROM never writes it).
//  2. /YAM covers 0x2000-0x27FF, not 0x2000-0x2001: the YM2151 has only A0,
//     and the PAL does not see SA10..SA1.  MAME maps 0x2000-0x2001 only.
//     Unobservable here — the ROM addresses the YM at $2000/$2001 only.
//
//  Φ2 qualification: the PAL's Φ2 input gates /REST, /SWR and /SRD.  This
//  decoder ties it high and leaves the cycle qualification to `ce` in
//  `xybots_jsa_bus` (wr_stb / rd_stb / irqack & ce), which is the same gate
//  applied one level up; the selects here are therefore "what the address and
//  direction decode to during a valid cycle".  The PAL's A13B/A12B outputs are
//  realised in `xybots_jsa_mem` (`rom_off`), which substitutes the /WRIO bank
//  bits in 0x3000-0x3FFF exactly as the equations do; they are generated here
//  only so the PAL is instantiated whole.
//
//  The POKEY and TMS5220 sockets are unpopulated on Xybots, but their SELECTS
//  still exist (they come from the PAL and from SA10, not from the chips), so
//  `sel_pokey` and `sel_voice` are still produced here and handled as "nothing
//  answers" in `xybots_jsa_bus`.
//
//    0x0000-0x1FFF  RAM (8 KB, 2H)
//    0x2000-0x27FF  YM2151 (2F, register select = SA0; /YAM is the whole block)
//    0x2800         n/c                        (mirror 0x01F9)  read only
//    0x2802         /RDP   sound command read  (mirror 0x01F9)  read only
//    0x2804         /RDIO  input port          (mirror 0x01F9)  read only
//    0x2806         /IRQACK                    (mirror 0x01F9)  read only
//    0x2A00         /VOICE TMS5220 latch (3F)  (mirror 0x01F9)  write only, socket empty
//    0x2A02         /WRP   sound response      (mirror 0x01F9)  write only
//    0x2A04         /WRIO  output latch (5H)   (mirror 0x01F9)  write only
//    0x2A06         /MIX   mixer latch  (5F)   (mirror 0x01F9)  write only
//    0x2C00-0x2C0F  POKEY (3K)                 (mirror 0x03F0)  socket empty
//    0x3000-0x3FFF  banked ROM (A13B/A12B from the /WRIO latch)  read only
//    0x4000-0xFFFF  fixed ROM                                    read only
//============================================================================

module xybots_jsa_decode
(
	input  logic [15:0] addr,
	input  logic        rnw,         // 6502 R//W (1 = read)
	output logic        sel_ram,
	output logic        sel_ym,
	output logic        sel_rdp,
	output logic        sel_rdio,
	output logic        sel_irqack,
	output logic        sel_voice,   // TMS5220 latch — socket empty on Xybots
	output logic        sel_wrp,
	output logic        sel_wrio,
	output logic        sel_mix,
	output logic        sel_pokey,   // POKEY socket — empty on Xybots
	output logic        sel_bank,
	output logic        sel_rom,
	output logic        ym_reg,      // YM2151 register select (SA0)
	output logic  [3:0] pokey_reg    // POKEY register (SA3..SA0)
);

	// ---- 2L-PAL 136056-2101 ----
	wire rom_n, yam_n, rest_n, ram_n, swr_n, srd_n, a13b, a12b;
	xybots_jsa_pal_2l u_pal (
		.rnw(rnw), .o2(1'b1), .ba12(1'b0), .ba13(1'b0),
		.sa9(addr[9]), .sa11(addr[11]), .sa12(addr[12]), .sa13(addr[13]),
		.sa14(addr[14]), .sa15(addr[15]),
		.rom_n(rom_n), .yam_n(yam_n), .rest_n(rest_n), .ram_n(ram_n),
		.a13b(a13b), .a12b(a12b), .swr_n(swr_n), .srd_n(srd_n) );
	// /SWR is the RAM /WE and YM /WR; the bus derives the same gate from
	// `wr_stb & sel_ram` / `wr_stb & sel_ym`.  A13B/A12B: see the header.
	// SA8..SA4 reach no decoder on the board (the LS138 sees SA9/SA2/SA1, the
	// POKEY SA3..SA0, the YM SA0) — the mirrors are real, not a modelling choice.
	wire unused = &{1'b0, swr_n, a13b, a12b, addr[8:4]};

	// ---- 4M 74LS138 ----
	wire en138 = srd_n & ~rest_n & ~addr[10];      // G1 high, /G2A low, /G2B low
	wire [2:0] y = {addr[9], addr[2], addr[1]};    // SELC, SELB, SELA

	assign sel_ram    = ~ram_n;                                // 0x0000-0x1FFF
	assign sel_ym     = ~yam_n;                                // 0x2000-0x27FF
	assign sel_rdp    = en138 & (y == 3'd1);                   // 0x2802, reads
	assign sel_rdio   = en138 & (y == 3'd2);                   // 0x2804, reads
	assign sel_irqack = en138 & (y == 3'd3);                   // 0x2806, reads
	assign sel_voice  = en138 & (y == 3'd4);                   // 0x2A00, writes
	assign sel_wrp    = en138 & (y == 3'd5);                   // 0x2A02, writes
	assign sel_wrio   = en138 & (y == 3'd6);                   // 0x2A04, writes
	assign sel_mix    = en138 & (y == 3'd7);                   // 0x2A06, writes
	assign sel_pokey  = ~rest_n & addr[10];                    // 0x2C00-0x2FFF (CS0=/REST, CS1=SA10)
	assign sel_bank   = ~rom_n & (addr[15:12] == 4'h3);        // 0x3000-0x3FFF, reads
	assign sel_rom    = ~rom_n & (addr[15:12] != 4'h3);        // 0x4000-0xFFFF, reads

	assign ym_reg    = addr[0];
	assign pokey_reg = addr[3:0];

endmodule
