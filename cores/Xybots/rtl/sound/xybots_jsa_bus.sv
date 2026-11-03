//============================================================================
//  Xybots (Atari Games, 1987) — JSA I sound-board bus: composes
//  xybots_jsa_decode + xybots_jsa_mem + xybots_jsa_io + xybots_sound_comm into
//  the 6502's bus and exposes the YM2151 strobes for the external jt51 core.
//  This is the whole JSA I board minus the 6502 and the YM2151.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Derived from the Arcade-Toobin_MiSTer core's toobin_jsa_bus.sv
//  (GPL-3.0-or-later), with the POKEY port group removed — Xybots' JSA I has
//  neither the POKEY (3K) nor the TMS5220C (3D) socket populated; see
//  NOTICE.md.
//
//  Bus timing: `ce` marks a valid 6502 bus cycle; reads mux combinationally
//  while the RAM/ROM read is registered (the address is presented one ce
//  early, as for a synchronous memory).
//
//  ---- what an empty socket reads ------------------------------------------
//  0x2C00-0x2FFF is still DECODED with the POKEY removed: the select is
//  CS0 = /REST (a PAL output) and CS1 = SA10, neither of which involves the
//  chip.  Nothing then drives SD7..SD0, and there are **no pull-ups on the
//  sound data bus anywhere on SP-313 sheets 12-14** — the only pull-ups on
//  those sheets are R18/R28/R52 (6502 /NMI, RDY, /IRQ), R17 (/SNDRES), R11
//  (SELF-TEST), R74/R75/R77/R78 (the four coin lines) and R37 (TMS5220
//  AD8/D).  So on real hardware the read returns floating open bus (bus
//  capacitance holding the previous byte, decaying towards the TTL high
//  level), not a defined value.  0xFF is used here: it is where a floating
//  NMOS/TTL bus settles, and it matches MAME, whose
//  `atari_jsa_i_device::pokey_r` returns 0xff once the device is removed.  It
//  is unobservable either way — over a 15 s MAME attract trace the sound ROM
//  makes no access at all to the 0x2C00-0x2FFF window.
//  /VOICE (0x2A00) writes are likewise accepted and dropped: the 3F LS374
//  latch is populated, it just drives an empty TMS5220 socket.  The same trace
//  shows six /VOICE writes in 15 s, so the RTL has to ignore them harmlessly
//  rather than trap.
//
//  0x2806 (/IRQACK) is the same open-bus situation and this file returns 0xFF
//  there too; MAME's sound_irq_ack_r returns 0x00.  Also unobservable — the
//  sound ROM discards the byte at $41BB (LDA $280E / RTS) and $41C9
//  (LDA $280E / PLA).
//
//  Direction: the decoder's LS138 selects are already read/write qualified by
//  the 2L-PAL's /SRD (Atari 136056-2101): /RDP, /RDIO and /IRQACK only exist
//  on a read, /VOICE, /WRP, /WRIO and /MIX only on a write.  The rd_stb/wr_stb
//  gates below therefore add only the Φ2 (`ce`) qualification for those, and
//  the direction for RAM/YM/ROM.
//============================================================================

module xybots_jsa_bus #(
	parameter int IRQ_DIV    = 14336,
	parameter bit SWAP_COINS = 1'b1
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        ce,             // 6502 bus-cycle enable (1.7897725 MHz)
	input  logic        ce_jsa,         // JSA master enable  (3.579545 MHz)

	// ---- 6502 ----
	input  logic [15:0] cpu_addr,
	input  logic  [7:0] cpu_dout,       // 6502 write data
	input  logic        cpu_rnw,        // 1 = read
	output logic  [7:0] cpu_din,        // read data to the 6502
	output logic        cpu_irq,        // periodic timer OR YM2151 (open-collector wired-OR)
	input  logic        ym_irq,         // YM2151 timer IRQ (active high)
	output logic        cpu_nmi,        // command-pending NMI (SCOM FULL)
	output logic        cpu_reset,      // /SNDRES from the main CPU's /AUDRES

	// ---- ROM loader ----
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,

	// ---- main-CPU mailbox side ----
	input  logic        main_cmd_wr,
	input  logic  [7:0] main_cmd_data,
	input  logic        main_resp_rd,
	input  logic        main_sndrst_wr,
	output logic  [7:0] main_resp_data,
	output logic        main_irq,
	output logic        main_to_sound_ready,  // raw flag; /SYSIN bit 9 is its COMPLEMENT

	// ---- board inputs / outputs ----
	input  logic        coin1,          // LEFT chute
	input  logic        coin2,          // RIGHT chute
	input  logic        coin3,          // JCOIN-2 (normally unused)
	input  logic        coin4,          // JCOIN-1 (normally unused; MAME calls it +5V)
	input  logic        self_test,      // SW1 on the audio PCB, also to /SYSIN bit 8
	output logic        ym_reset_n,
	output logic        coin_ctr1,
	output logic        coin_ctr2,
	output logic  [1:0] cpu_bank,

	// ---- YM2151 external core ----
	output logic        ym_cs,          // access strobe (this cycle)
	output logic        ym_a0,          // register select (SA0)
	output logic        ym_we,          // write strobe (ce-gated)
	output logic        ym_rd,          // read strobe  (ce-gated)
	output logic  [7:0] ym_dout,        // 6502 -> YM data
	input  logic  [7:0] ym_din,         // YM -> 6502 data

	// ---- /MIX write (to the audio mixer, 5F LS273B) ----
	output logic        mix_wr,
	output logic  [7:0] mix_data
);

	// ---- decode ----
	wire sel_ram, sel_ym, sel_rdp, sel_rdio, sel_irqack, sel_voice,
	     sel_wrp, sel_wrio, sel_mix, sel_pokey, sel_bank, sel_rom, ym_reg;
	wire [3:0] pokey_reg;
	xybots_jsa_decode u_dec (
		.addr(cpu_addr), .rnw(cpu_rnw), .sel_ram(sel_ram), .sel_ym(sel_ym), .sel_rdp(sel_rdp),
		.sel_rdio(sel_rdio), .sel_irqack(sel_irqack), .sel_voice(sel_voice),
		.sel_wrp(sel_wrp), .sel_wrio(sel_wrio), .sel_mix(sel_mix), .sel_pokey(sel_pokey),
		.sel_bank(sel_bank), .sel_rom(sel_rom), .ym_reg(ym_reg), .pokey_reg(pokey_reg) );

	wire wr_stb = ce & ~cpu_rnw;
	wire rd_stb = ce &  cpu_rnw;
	// /VOICE (3F LS374 -> empty TMS5220 socket) and the POKEY register index
	// are decoded on the board but answer to nothing here.
	wire unused = &{1'b0, sel_voice, pokey_reg};
	assign mix_wr   = sel_mix & wr_stb;          // /MIX (0x2A06) -> 5F LS273B
	assign mix_data = cpu_dout;

	// ---- memory ----
	wire [7:0] mem_dout;
	xybots_jsa_mem u_mem (
		.clk(clk), .rom_wr(rom_wr), .rom_wr_addr(rom_wr_addr), .rom_wr_data(rom_wr_data),
		.addr(cpu_addr), .din(cpu_dout), .we(wr_stb & sel_ram),
		.sel_ram(sel_ram), .sel_bank(sel_bank), .sel_rom(sel_rom), .bank(cpu_bank),
		.dout(mem_dout) );

	// ---- SCOM mailbox ----
	wire [7:0] snd_cmd_data;
	wire       snd_nmi, snd_reset, snd2main_ready;
	xybots_sound_comm u_comm (
		.clk(clk), .reset(reset),
		.main_cmd_wr(main_cmd_wr), .main_cmd_data(main_cmd_data), .main_resp_rd(main_resp_rd),
		.main_sndrst_wr(main_sndrst_wr), .main_resp_data(main_resp_data), .main_irq(main_irq),
		.main_to_sound_ready(main_to_sound_ready), .sound_to_main_ready(snd2main_ready),
		.snd_cmd_rd(sel_rdp & rd_stb), .snd_resp_wr(sel_wrp & wr_stb), .snd_resp_data(cpu_dout),
		.snd_cmd_data(snd_cmd_data), .snd_nmi(snd_nmi), .snd_reset(snd_reset) );

	// ---- I/O + banking + periodic IRQ ----
	wire [7:0] rdio_data;
	wire       sound_irq;
	xybots_jsa_io #(.IRQ_DIV(IRQ_DIV), .SWAP_COINS(SWAP_COINS)) u_io (
		.clk(clk), .reset(reset), .ce_jsa(ce_jsa),
		.wrio_wr(sel_wrio & wr_stb), .wrio_data(cpu_dout),
		.irqack(sel_irqack & ce),    // /IRQACK: a READ of 0x2806 (the 2L-PAL's /SRD
		                             // disables the LS138 for writes there — 136056-2101)
		.self_test(self_test), .nmi_line_n(~snd_nmi), .resp_full(snd2main_ready),
		.coin1(coin1), .coin2(coin2), .coin3(coin3), .coin4(coin4),
		.cpu_bank(cpu_bank), .coin_ctr1(coin_ctr1), .coin_ctr2(coin_ctr2),
		.ym_reset_n(ym_reset_n), .rdio_data(rdio_data), .sound_irq(sound_irq) );

	// ---- YM2151 strobes ----
	assign ym_cs   = sel_ym;
	assign ym_a0   = ym_reg;
	assign ym_we   = sel_ym & wr_stb;
	assign ym_rd   = sel_ym & rd_stb;
	assign ym_dout = cpu_dout;

	// ---- 6502 read mux ----
	always_comb begin
		if      (sel_ram || sel_bank || sel_rom) cpu_din = mem_dout;
		else if (sel_ym)                         cpu_din = ym_din;
		else if (sel_rdp)                        cpu_din = snd_cmd_data;
		else if (sel_rdio)                       cpu_din = rdio_data;
		// 0x2C00-0x2FFF is decoded but the POKEY socket (3K) is empty: nothing
		// drives SD7..SD0 and there are no bus pull-ups, so the real board
		// floats.  0xFF both matches MAME's explicit `pokey_r -> 0xff` and is
		// where a floating NMOS/TTL bus settles.  Split out from the catch-all
		// so the intent is visible.
		else if (sel_pokey)                      cpu_din = 8'hFF;
		else                                     cpu_din = 8'hFF;   // /IRQACK, /VOICE, gaps
	end

	assign cpu_irq   = sound_irq | ym_irq;   // Q8 open collector + the YM's /IRQ, on one pull-up
	assign cpu_nmi   = snd_nmi;
	assign cpu_reset = snd_reset;

endmodule
