//============================================================================
//  Xybots (Atari Games, 1987) — JSA I audio PCB address-decoder PAL, 2L.
//  Atari part 136056-2101 ("Programmed PAL16L8A, 25 ns"), SP-313 sheet 12.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//
//  This is the fuse map, not a reading of the memory map.  The equations below
//  are transcribed from a GAL16V8 dump of the same assembly-numbered part, and
//  the module reproduces that dump over every one of the 1 048 576 input
//  combinations — so the transcription is checked against the silicon rather
//  than against the intent.
//
//  Pins (SP-313 sheet 12):
//    in   1 SR//W  2 Φ2  3 BA12  4 BA13  5 SA9  6 SA11  7 SA12  8 SA13
//         9 SA14  11 SA15
//    out 12 /ROM  13 /YAM  14 /REST  15 /RAM  16 A13B  17 A12B  18 /SWR  19 /SRD
//
//  Equations off the fuses (complex mode, every OLMC combinational and active
//  low; `pin14` is the chip's own /REST fed back through the AND array):
//
//    /RAM  = /SA13 & /SA14 & /SA15                               0000-1FFF
//    /YAM  = /SA11 & /SA12 & SA13 & /SA14 & /SA15                2000-27FF
//    /REST = Φ2 & SA11 & /SA12 & SA13 & /SA14 & /SA15            2800-2FFF
//    /ROM  = R/W & SA15 + R/W & SA14 + R/W & SA12 & SA13         reads of 3000-FFFF
//    /A13B = /BA13 & SA12 & SA13 & /SA14 & /SA15 + /SA13         BA13 in 3000-3FFF, else SA13
//    /A12B = /BA12 & SA12 & SA13 & /SA14 & /SA15 + /SA12         BA12 in 3000-3FFF, else SA12
//    /SWR  = Φ2 & /R/W & /SA13 & /SA14 & /SA15                   writes to 0000-1FFF
//          + Φ2 & /R/W & /SA11 & /SA12 & SA13 & /SA14 & /SA15    writes to 2000-27FF
//    /SRD  = Φ2 & R/W & pin14                                    reads outside 2800-2FFF
//          + R/W & SA9 & [2800-2FFF]                             reads  of 2A00-2BFF, 2E00-2FFF
//          + /R/W & /SA9 & [2800-2FFF]                           writes to 2800-29FF, 2C00-2DFF
//          + /Φ2 & [2800-2FFF]
//
//  What the last one means: inside 0x2800-0x2FFF, /SRD is not a read strobe,
//  it is the DIRECTION CODE for the 4M LS138 (whose active-high G1 it drives,
//  which is exactly what the drawing shows).  The LS138 is enabled when /SRD
//  is HIGH, i.e. for reads with SA9 = 0 (Y0-Y3: n/c, /RDP, /RDIO, /IRQACK) and
//  for writes with SA9 = 1 (Y4-Y7: /VOICE, /WRP, /WRIO, /MIX).  Consequences
//  that differ from MAME's atarijsa1_map: the YM2151 answers across the whole
//  of 0x2000-0x27FF (MAME: 0x2000-0x2001), and /IRQACK is read-only (MAME also
//  accepts a write).  The Xybots sound ROM exercises neither.
//============================================================================

module xybots_jsa_pal_2l
(
	input  logic rnw,      // pin 1  SR//W (1 = read)
	input  logic o2,       // pin 2  Φ2
	input  logic ba12,     // pin 3  bank bit from the /WRIO latch
	input  logic ba13,     // pin 4
	input  logic sa9,      // pin 5
	input  logic sa11,     // pin 6
	input  logic sa12,     // pin 7
	input  logic sa13,     // pin 8
	input  logic sa14,     // pin 9
	input  logic sa15,     // pin 11
	output logic rom_n,    // pin 12
	output logic yam_n,    // pin 13
	output logic rest_n,   // pin 14
	output logic ram_n,    // pin 15
	output logic a13b,     // pin 16
	output logic a12b,     // pin 17
	output logic swr_n,    // pin 18
	output logic srd_n     // pin 19
);

	// the one address range the PAL decodes with more than the top bits
	wire blk28 = sa11 & ~sa12 & sa13 & ~sa14 & ~sa15;          // 0x2800-0x2FFF
	wire blk20 = ~sa11 & ~sa12 & sa13 & ~sa14 & ~sa15;         // 0x2000-0x27FF
	wire blk00 = ~sa13 & ~sa14 & ~sa15;                        // 0x0000-0x1FFF
	wire blk30 = sa12 & sa13 & ~sa14 & ~sa15;                  // 0x3000-0x3FFF

	assign ram_n  = ~blk00;
	assign yam_n  = ~blk20;
	assign rest_n = ~(o2 & blk28);
	assign rom_n  = ~((rnw & sa15) | (rnw & sa14) | (rnw & sa12 & sa13));
	assign a13b   = ~((~ba13 & blk30) | ~sa13);
	assign a12b   = ~((~ba12 & blk30) | ~sa12);
	assign swr_n  = ~((o2 & ~rnw & blk00) | (o2 & ~rnw & blk20));
	assign srd_n  = ~((o2 & rnw & rest_n) | (rnw & sa9 & blk28) |
	                  (~rnw & ~sa9 & blk28) | (~o2 & blk28));

endmodule
