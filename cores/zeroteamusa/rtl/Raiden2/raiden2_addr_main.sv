// Zero Team USA address map; original donor decode retained outside target differences.
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
// Raiden II Main V30 address translator (pattern Irem M72 pal.sv).
// Decodifica address V30 → memrq per region. Mappa MAME raiden2_mem
// (raiden2.cpp:626-646), fine-decode del blocco $400-$7FF trascritto dalla
// maincpu_map della repo _old (quella che bootava):
//   $00000-$003FF  RAM (IVT)                 → ram_memrq
//   $00400-$006FF  COP SEI300                → cop_memrq (meno i ritagli sotto)
//     $00470-$00471  cop_tile_bank_2 (cbank) → cbank_memrq
//     $00600-$0063F  Seibu CRTC              → crtc_memrq
//     $00640-$006BF  finestra obj            → obj_memrq
//     $0068E-$0068F  latch buffered spriteram→ sprbuf_memrq (dentro obj)
//     $006CA-$006CB  bank ROM                → bankw_memrq
//     $006CC-$006CD  tile bank               → tbank_memrq
//   $00700-$0071F  Seibu sound (umask 00FF)  → sound_memrq
//   $00740-$00741  DSW1                      → dsw_memrq
//   $00744-$00745  P1+P2                     → p1p2_memrq
//   $00748-$00749  P3+P4                     → p3p4_memrq
//   $0074C-$0074D  SYSTEM                    → sys_memrq
//   $0075C-$0075D  DSW2                      → dsw2_memrq
//   $00762-$00763  sprite_prot_dst1_r        → sprdst_memrq
//   $00800-$0BFFF  RAM                       → ram_memrq
//   $0C000-$0CFFF  spriteram (4KB)           → sprite_memrq
//   $0D000-$0D7FF  BG                        → bg_memrq
//   $0D800-$0DFFF  FG                        → fg_memrq
//   $0E000-$0E7FF  MG                        → mg_memrq
//   $0E800-$0F7FF  TEXT (4KB, non allineata) → text_memrq
//   $0F800-$0FFFF  RAM (stack)               → ram_memrq
//   $10000-$1EFFF  RAM                       → ram_memrq
//   $1F000-$1FFFF  palette (4KB)             → pal_memrq
//   $20000-$3FFFF  ROM bancata (rom_bank)    → ls245_en
//   $40000-$FFFFF  ROM diretta               → ls245_en
//
// ls245_en alto SOLO per le region ROM (SDRAM). Il resto è BRAM/registri
// interni → niente stall.
// sdr_addr: byte addr dentro l'immagine ROM da 1MB (MAIN a base 0 in SDRAM,
// layout della _old). Finestra bancata: {rom_bank, A[16:0]} come la _old.

module raiden2_addr_main
(
	input  logic [19:0] A,
	input  logic        DBEN,     // = rd | wr (bus enable: pulse durante accesso)
	input  logic        rom_bank, // da write $6CB (reset 1, ~wdata[15])
	// Raiden DX: mappa programma DIVERSA (MAME raidendx_mem).
	//   Raiden II: $20000-$3FFFF bancata, 2 pagine da 128K a base 0, sel. $6C9 bit7
	//   Raiden DX: $20000-$2FFFF bancata, 16 pagine da 64K nel 2o MB, sel. $470[15:12]
	//              $30000-$FFFFF ROM diretta (Raiden II: da $40000)
	input  logic        board_dx,
	input  logic  [3:0] dx_prg_bank,

	// SDRAM ROM region
	output logic        ls245_en,
	output logic [23:0] sdr_addr,

	// BRAM / registri (combinatorio)
	output logic        ram_memrq,
	output logic        cop_memrq,
	output logic        cbank_memrq,
	output logic        crtc_memrq,
	output logic        obj_memrq,
	output logic        sprbuf_memrq,
	output logic        bankw_memrq,
	output logic        tbank_memrq,
	output logic        sound_memrq,
	output logic        dsw_memrq,
	output logic        p1p2_memrq,
	output logic        p3p4_memrq,
	output logic        sys_memrq,
	output logic        dsw2_memrq,
	output logic        sprdst_memrq,
	output logic        sprite_memrq,
	output logic        bg_memrq,
	output logic        fg_memrq,
	output logic        mg_memrq,
	output logic        text_memrq,
	output logic        pal_memrq
);

// Parallel aligned-window predicates avoid a serial priority decode feeding
// COP trigger/stall logic. Every output retains the original byte map.
wire cop_window = (A[19:10] == 10'd1) && (A[9:8] != 2'b11);
wire cop_cutout = (board_dx && A[9:3] == 7'h1a) ||
                  (A[9:1] == 9'h038) ||
                  (A[9:6] == 4'h8) || (A[9:6] == 4'h9) || (A[9:6] == 4'ha) ||
                  (A[9:1] == 9'h165) || (A[9:1] == 9'h166);
always_comb begin
    ram_memrq = DBEN && ((A[19:10] == 10'd0) ||
                 (board_dx && A[19:3] == 17'h09a) ||
                 ((A[19:16] == 4'h0) && A[15:11] >= 5'd1 && A[15:11] < 5'd23) ||
                 (A[19:16] == 4'h1));
    cop_memrq = DBEN && cop_window && !cop_cutout;
    // These legacy bank-write windows are holes on this target.
    cbank_memrq = 1'b0;
    bankw_memrq = 1'b0;
    tbank_memrq = 1'b0;
    crtc_memrq = DBEN && (A[19:6] == 14'h018);
    sprbuf_memrq = DBEN && (A[19:1] == 19'h00347);
    obj_memrq = DBEN && ((A[19:6] == 14'h019) || (A[19:6] == 14'h01a)) &&
                         (A[9:1] != 9'h147);
    sound_memrq = DBEN && (A[19:5] == 15'h0038);
    dsw_memrq = DBEN && (A[19:1] == 19'h003a0);
    p1p2_memrq = DBEN && (A[19:1] == 19'h003a2);
    p3p4_memrq = DBEN && (A[19:1] == 19'h003a4);
    sys_memrq = DBEN && (A[19:1] == 19'h003a6);
    dsw2_memrq = DBEN && (A[19:1] == 19'h003ae);
    sprdst_memrq = DBEN && (A[19:1] == 19'h003b1);
    bg_memrq = DBEN && (A[19:11] == 9'h017);
    fg_memrq = DBEN && (A[19:11] == 9'h018);
    mg_memrq = DBEN && (A[19:11] == 9'h019);
    text_memrq = DBEN && (A[19:12] == 8'h0d);
    pal_memrq = DBEN && (A[19:12] == 8'h0e);
    sprite_memrq = DBEN && (A[19:12] == 8'h0f);
    ls245_en = DBEN && (A[19:17] != 3'd0);
    sdr_addr = 24'd0;
    if (ls245_en) begin
        if (board_dx && A[19:16] == 4'h2)
            sdr_addr = {4'h6, dx_prg_bank, A[15:0]};
        else if (!board_dx && A[19:17] == 3'd1)
            sdr_addr = {6'd0, rom_bank, A[16:0]};
        else
            sdr_addr = {4'd0, A};
    end
end

endmodule
