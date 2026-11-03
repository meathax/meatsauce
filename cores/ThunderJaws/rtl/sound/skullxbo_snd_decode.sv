`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones JSA Audio II (A047184-02): the 6502 address decode.
//  PAL16L8 136056-2101 at 2D plus the LS138 at 3F, as JSA sheet 2 draws them.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  Module structure and port
//  style follow the Bad Lands core's `badlands_snd_decode.sv` (GPL-3.0).
//  The PAL equations are the 136056-2101 fuse dump (decoded with jedutil);
//  the LS138 wiring is this board's.
//
//  PAL16L8 2D pins:
//     1  SR/W  (1 = read)        12  /ROM   -> 27512 1B /CE
//     2  O2    (6502 pin 39)     13  /YAM   -> YM2151 3A /CS
//     3  BA12  (LS273 4D)        14  /REST  -> LS138 3F /G2A
//     4  BA13  (LS273 4D)        15  /RAM   -> 6264 2B /CS1
//     5  SA9                     16  A13B   -> 27512 1B A13
//     6  SA11                    17  A12B   -> 27512 1B A12
//     7  SA12                    18  /SWR   -> 2B /WE, YM 3A /WR
//     8  SA13                    19  /SRD   -> 1B /OE, 2B /OE, YM 3A /RD
//     9  SA14
//    11  SA15
//  All eight outputs are combinational and active low: a plain PAL16L8.
//
//  The equations (B = the $2800-$2FFF block, R = SR/W, W = !SR/W):
//
//    B      = SA11 & !SA12 & SA13 & !SA14 & !SA15
//    /ROM   = R & SA15  +  R & SA14  +  R & SA12 & SA13
//    /YAM   = !SA11 & !SA12 & SA13 & !SA14 & !SA15
//    /REST  = O2 & B
//    /RAM   = !SA13 & !SA14 & !SA15
//    A13B   = SA13 & ( BA13 | !SA12 | SA14 | SA15 )
//    A12B   = SA12 & ( BA12 | !SA13 | SA14 | SA15 )
//    /SWR   = W & O2 & !SA13 & !SA14 & !SA15                         (RAM)
//           + W & O2 & !SA11 & !SA12 & SA13 & !SA14 & !SA15          (YM)
//    /SRD   =  R & O2 & !B
//           +  R &  SA9 & B
//           +  W & !SA9 & B
//           + !O2       & B
//
//  Three of /SRD's four terms have no effect on this board.  They serve the
//  JSA I, where the LS138's G1 is /SRD; on the JSA II G1 is +5 V, and inside
//  $2800-$2FFF none of the devices /SRD enables is selected.  So `srd` is the
//  simplified form (R & O2) and `srd_gal` the full equation, kept for
//  reference.
//
//  /ROM includes SR/W, so writes to ROM space do nothing.  /ROM is not
//  O2-qualified (only /SRD is), so the ROM read is gated with `srd` in
//  skullxbo_snd_bus.
//
//  Bank window: outside $3000-$3FFF, A13B/A12B = SA13/SA12.  Inside it they
//  are BA13/BA12, so the 27512 sees ROM $0000-$3FFF as four 4 KB pages.  That
//  part of the ROM is reachable only through the window.
//
//  LS138 3F: G1 = +5 V, /G2A = /REST, /G2B = SA10, C,B,A = SA9, SA2, SA1.
//     enabled for O2 & $2800-$2BFF; SA8..SA3 and SA0 are ignored (mask $01F9)
//
//     Y0 $2800 /RDV     MSM6295 status read (RD pin)
//     Y1 $2802 /RDP     SCOM 3D read (clears /NMI)
//     Y2 $2804 /RDIO    LS240 2F status port
//     Y3 $2806 /IRQACK  clears the periodic-IRQ flop
//     Y4 $2A00 /WRV     MSM6295 command write (WR pin)
//     Y5 $2A02 /WRP     SCOM 3D write
//     Y6 $2A04 /WRIO    LS273 4D clock
//     Y7 $2A06 /MIX     LS174 3C clock
//
//  Differences from MAME and the JSA I that are deliberate:
//   1. No R/W qualification: G1 is +5 V, so every strobe fires on a read and
//      on a write; only SA9 separates the "read" and "write" groups.  (MAME
//      splits them read-only / write-only.)  /IRQACK acks on either, and a
//      read of $2A00 would pulse the MSM6295's WR pin (the firmware never
//      does that).
//   2. SA10 must be 0, so $2C00-$2FFF decodes nothing.
//   3. The program uses the +8 mirrors ($2808 / $280A / $280C / $280E): SA3
//      is ignored, so a full-address compare would break it.
//
//  The YM2151 decodes SA15:SA11 only, so it answers anywhere in $2000-$27FF
//  (MAME maps only $2000-$2001).
//
//  O2: `o2` is `ce_1m79`, high for the clock on which the transfer happens.
//  /RAM, /YAM, /ROM, A13B and A12B do not include O2, so they stay valid for
//  the whole cycle and can address the synchronous memories a clock ahead.
//============================================================================

module skullxbo_snd_decode
(
	// ---- 6502A 1D ----
	input  logic [15:0] sa,          // SA15..SA0
	input  logic        srw,         // SR//W, 1 = read      -- 2D pin 1
	input  logic        o2,          // O2 (6502 pin 39)     -- 2D pin 2

	// ---- LS273 4D bank bits ----
	input  logic        ba13,        // 4D Q7                -- 2D pin 4
	input  logic        ba12,        // 4D Q6                -- 2D pin 3

	// ---- PAL 2D outputs, in ACTIVE-HIGH "asserted" form ----
	output logic        rom_ce,      // /ROM  (pin 12) -- NOT O2-qualified
	output logic        yam,         // /YAM  (pin 13)
	output logic        rest,        // /REST (pin 14) -- O2 & $2800-$2FFF
	output logic        ram,         // /RAM  (pin 15)
	output logic        a13b,        // A13B  (pin 16) -- 1B A13, positive sense
	output logic        a12b,        // A12B  (pin 17) -- 1B A12, positive sense
	output logic        swr,         // /SWR  (pin 18)
	output logic        srd,         // /SRD  (pin 19) -- simplified (see header)
	output logic        srd_gal,     // /SRD  (pin 19) -- the full PAL equation

	// ---- address-only windows (no O2, no direction) ----
	output logic        sel_ram,     // $0000-$1FFF  -> 6264 2B
	output logic        sel_ym,      // $2000-$27FF  -> YM2151 3A  (= yam)
	output logic        sel_bank,    // $3000-$3FFF  -> 1B, A13/A12 = BA13/BA12
	output logic        sel_romfix,  // $4000-$FFFF  -> 1B straight through
	output logic        sel_hole,    // $2C00-$2FFF  -> nothing decodes

	// ---- LS138 3F outputs, ACTIVE-HIGH, O2-qualified, NO direction term ----
	output logic        sel_rdv,     // Y0 $2800  /RDV    MSM6295 RD
	output logic        sel_rdp,     // Y1 $2802  /RDP    SCOM 3D RD
	output logic        sel_rdio,    // Y2 $2804  /RDIO   LS240 2F /1G,/2G
	output logic        sel_irqack,  // Y3 $2806  /IRQACK 6F /CLR
	output logic        sel_wrv,     // Y4 $2A00  /WRV    MSM6295 WR
	output logic        sel_wrp,     // Y5 $2A02  /WRP    SCOM 3D WR
	output logic        sel_wrio,    // Y6 $2A04  /WRIO   LS273 4D CP
	output logic        sel_mix,     // Y7 $2A06  /MIX    LS174 3C CP

	// ---- misc ----
	output logic        ym_a0,       // YM2151 pin 4 = SA0
	output logic [15:0] rom_addr     // 1B A15..A0 = {SA15,SA14,A13B,A12B,SA11:0}
);

	// ---- the PAL's own literal terms ---------------------------------------
	wire r = srw;
	wire w = ~srw;
	// `B` = $2800-$2FFF, used by /REST and by the literal /SRD.
	wire b = sa[11] & ~sa[12] & sa[13] & ~sa[14] & ~sa[15];

	assign rom_ce = (r & sa[15]) | (r & sa[14]) | (r & sa[12] & sa[13]);
	assign yam    = ~sa[11] & ~sa[12] &  sa[13] & ~sa[14] & ~sa[15];
	assign rest   = o2 & b;
	assign ram    = ~sa[13] & ~sa[14] & ~sa[15];
	assign a13b   = sa[13] & ( ba13 | ~sa[12] | sa[14] | sa[15] );
	assign a12b   = sa[12] & ( ba12 | ~sa[13] | sa[14] | sa[15] );
	assign swr    = ( w & o2 & ~sa[13] & ~sa[14] & ~sa[15] )
	              | ( w & o2 & ~sa[11] & ~sa[12] & sa[13] & ~sa[14] & ~sa[15] );

	// The full PAL equation, and the simplified form used.  They differ only
	// inside `B`, where no /SRD load is selected on this board.
	assign srd_gal = ( r & o2 & ~b )
	               | ( b & ( ~o2 | (r & sa[9]) | (w & ~sa[9]) ) );
	assign srd     = r & o2;

	// ---- the address windows the memories see ------------------------------
	assign sel_ram    = ram;                        // $0000-$1FFF
	assign sel_ym     = yam;                        // $2000-$27FF (mirror $07FE)
	assign sel_bank   = (sa[15:12] == 4'h3);        // $3000-$3FFF
	assign sel_romfix = (sa[15:14] != 2'b00);       // $4000-$FFFF
	assign sel_hole   = b & sa[10];                 // $2C00-$2FFF

	// ---- LS138 3F ----------------------------------------------------------
	// G1 = PR (no direction term!), /G2A = /REST, /G2B = SA10.
	wire       en138 = rest & ~sa[10];
	wire [2:0] s138  = { sa[9], sa[2], sa[1] };
	wire [7:0] y138  = en138 ? (8'h01 << s138) : 8'h00;

	assign sel_rdv    = y138[0];
	assign sel_rdp    = y138[1];
	assign sel_rdio   = y138[2];
	assign sel_irqack = y138[3];
	assign sel_wrv    = y138[4];
	assign sel_wrp    = y138[5];
	assign sel_wrio   = y138[6];
	assign sel_mix    = y138[7];

	assign ym_a0    = sa[0];
	assign rom_addr = { sa[15], sa[14], a13b, a12b, sa[11:0] };

	// SA8..SA3 and SA0 are decoded by nothing inside the LS138 window (the
	// $01F9 mirror), which is exactly why the firmware's $2808 / $280A /
	// $280C / $280E work.  They still reach the memories through `sa`.
	wire _unused_dec = &{ 1'b0, sa[8:3] };

endmodule
