`timescale 1ns/1ps
//============================================================================
//  Skull & Crossbones JSA Audio II (A047184-02): the 6502 bus.  The 6502A at
//  1D (Atari 137577-001) on T65, the 6264 work RAM at 2B, the 27512 program
//  ROM at 1B with its $3000 bank window, the LS393 / LS74 periodic-IRQ chain,
//  the /IRQ wire-OR with the YM2151, the SD7:0 read mux and the board reset.
//
//  Copyright (C) 2026 the Skull & Crossbones MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE, NOTICE.md.  The T65 instantiation, the
//  registered-read memories, the "read mux gated by each chip's own output
//  enable" convention and the bus-hold model come from the Bad Lands core's
//  `badlands_snd_bus.sv` (GPL-3.0); the ack-gated divider is from the
//  Vindicators core's `vind_jsa_io.sv` (GPL-3.0).  Everything device-specific
//  is this board's.
//
//  6502A 1D:
//     O0 in   = 1790K = 1.789772 MHz            -> `ce_1m79`
//     R/W     = SR/W (1 = read)
//     RDY     = +5 V: the sound CPU never waits
//     SO      = +5 V (inactive)
//     /NMI    = SCOM 3D FULL
//     /IRQ    = wire-OR of the periodic chain (Q6) and the YM2151 IRQ pin
//               (the YM2151 IRQ is connected on this board, unlike Bad Lands)
//     /RES    = /RESET = POR AND /SNDRES
//  There is no wait-state logic on this bus (the JSA I's optional wait-state
//  PAL has no site on this board), so `Rdy` is tied to 1.
//
//  O2 in this core: one `ce_1m79` enable is one 6502 bus cycle.  The address
//  and write data are stable between enables and the transfer happens on the
//  enable.  The memories are read a clock ahead (registered block-RAM
//  output), so their data is ready at the enable; the LS138 strobes are
//  O2-gated, so they are true only on the enable, when T65 samples DI.
//
//  Memories:
//   * 6264 2B (8 K x 8): /CS1 = /RAM, /WE = /SWR, /OE = /SRD.  $0000-$1FFF,
//     no mirroring.
//   * 27512 1B: /CE = /ROM, /OE = /SRD, A13/A12 = A13B/A12B.  $4000-$FFFF is
//     the ROM straight through; $3000-$3FFF is a 4 KB window over ROM
//     $0000-$3FFF, page {BA13,BA12} from the LS273 4D (page n -> offset
//     n * $1000).  /ROM includes SR/W, so writes to ROM space do nothing, and
//     only /OE is O2-qualified, so the read mux uses `rom_ce & srd`.
//
//  Undriven bus: a read of $2806 (/IRQACK), of the $2A00 write group, or of
//  the $2C00-$2FFF hole enables no driver, and SD7:0 has no pull-ups.  This is
//  modelled as a bus hold: the last byte driven (by the 6502 on a write, or
//  by the selected device on a read).  MAME returns 0xFF.  The firmware
//  discards the only such reads it makes (its two /IRQACK reads).
//
//  Periodic IRQ:
//      LS393 4K.A : CK = 3579K ; 1QB (/4) -> 4K.B
//      LS393 4K.B : 2QD (/16)  -> 5K.A
//      LS393 5K.A : 1QD (/16)  -> 5K.B        = 3495.65 Hz
//      LS393 5K.B : a mod-14 counter, 2CLR = the IRQ flag
//      LS74 5F-1  : D = 5K 2QC , CK = 5K 2QB
//      LS74 5F-2  : D = 5K 2QD , CK = 5F-1 Q , /CLR = /IRQACK
//                   Q -> 5K 2CLR  and  -> Q6 -> /IRQ
//
//  At count 14 of the last stage 5F-2 sets: /IRQ goes low and the counter is
//  held cleared until the 6502 reads or writes $2806.
//
//      period = 3 579 545 / (4 * 16 * 16 * 14) = 249.69 Hz
//             = exactly 7168 cycles of the 6502 clock
//
//  This is MAME's JSA_MASTER_CLOCK/4/16/16/14, but on the board the interval
//  runs from the acknowledge, not from the previous interrupt (under 1 %
//  difference).  `MAME_FREERUN = 1` gives MAME's free-running timing.  The
//  first three stages free-run, so the restart after an acknowledge is
//  aligned to the 3495.65 Hz tick.  The 5F/6F flops have no reset (neither
//  the POR nor /SNDRES reaches them); the firmware acknowledges once during
//  boot.  The `por` term below is only the FPGA power-up value.
//
//  /IRQACK is a read or a write strobe (the LS138 has no direction term) and
//  is the LS74's asynchronous /CLR, so it wins over a coincident divider edge.
//
//  The sound ROM is loaded through `rom_wr*` (download offset 0x2B8000,
//  64 KB).  The array is a simple dual-port M10K: loader writes, 6502 reads.
//  Do not merge the RAM and ROM outputs into one register: an M10K's output
//  register cannot be shared and Quartus would fall back to flip-flops.
//============================================================================

module skullxbo_snd_bus #(
	parameter int IRQ_PRE      = 1024,   // /4 /16 /16, free-running (CLRs at GND)
	parameter int IRQ_POST     = 14,     // the LS393+LS74 /14 that STOPS when pending
	parameter int IRQ_SAMPLE_ADVANCE_YM = 0, // target-specific CPU input-sampler compensation
	parameter bit MAME_FREERUN = 1'b0    // 1 = MAME's free-running divider
) (
	input  logic        clk,
	input  logic        ce_1m79,      // 6502 O0 = 1790K; also O2
	input  logic        ce_3m58,      // 3579K -- the LS393 chain's input
	input  logic        por,          // power-on reset (Q4 / R18 / C10)

	// ---- SCOM 3D ----
	input  logic        sndres,       // pin 16 RES = /SNDRES asserted (1 = held)
	input  logic        scom_full,    // pin 4 FULL asserted -> 6502 /NMI

	// ---- YM2151 3A pin 2 ----
	input  logic        ym_irq,       // asserted (1)

	// ---- LS273 4D bank bits ----
	input  logic  [1:0] bank,         // {BA13, BA12}

	// ---- I/O read sources (each already gated by its own strobe below) ----
	input  logic  [7:0] rdp_data,     // SCOM 3D  ($2802)
	input  logic  [7:0] rdio_data,    // LS240 2F ($2804)
	input  logic  [7:0] rdv_data,     // MSM6295 6D/E status ($2800)

	// ---- YM2151 3A ----
	output logic        ym_cs,        // /YAM asserted (address decode only)
	output logic        ym_a0,        // SA0
	output logic        ym_we,        // /SWR & /YAM
	output logic        ym_rd,        // /SRD & /YAM
	output logic  [7:0] ym_dout,      // 6502 -> YM
	input  logic  [7:0] ym_din,       // YM status -> 6502

	// ---- LS138 3F strobes (O2-qualified, no direction term) ----
	output logic        sel_rdv,      // Y0 $2800
	output logic        sel_rdp,      // Y1 $2802
	output logic        sel_rdio,     // Y2 $2804
	output logic        sel_irqack,   // Y3 $2806  -- read OR write
	output logic        sel_wrv,      // Y4 $2A00
	output logic        sel_wrp,      // Y5 $2A02
	output logic        sel_wrio,     // Y6 $2A04
	output logic        sel_mix,      // Y7 $2A06

	// ---- sound ROM load port (from the ROM loader) ----
	input  logic        rom_wr,
	input  logic [15:0] rom_wr_addr,
	input  logic  [7:0] rom_wr_data,

	// ---- board reset and debug outputs ----
	output logic        reset_n,      // /RESET = POR AND /SNDRES -> 4D, 3C, 1D
	output logic        irq_periodic, // 5F-2 Q (1 = the timer interrupt is up)
	output logic [15:0] cpu_addr,
	output logic  [7:0] cpu_dout,
	output logic  [7:0] cpu_din,
	output logic        cpu_rnw,
	output logic        cpu_sync
);

	// ---- /RESET = POR AND /SNDRES ------------------------------------------
	// LS132 4F pin 3 = NAND(POR, /SNDRES); LS86 6K inverts it back.
	assign reset_n = ~(por | sndres);

	// ---- the periodic IRQ chain --------------------------------------------
	// NOT reset by /SNDRES: the LS74 5F/6F pair has no reset at all.
	localparam int PREW  = $clog2(IRQ_PRE);
	localparam int POSTW = $clog2(IRQ_POST);

	logic [PREW-1:0]  pre_cnt;
	logic [POSTW-1:0] post_cnt;
	logic irq_sample_advance_cancelled;
	wire irq_sample_advance_active = MAME_FREERUN && (IRQ_SAMPLE_ADVANCE_YM > 0) &&
		(post_cnt == POSTW'(IRQ_POST-1)) &&
		(pre_cnt >= PREW'(IRQ_PRE-IRQ_SAMPLE_ADVANCE_YM)) &&
		(pre_cnt <= PREW'(IRQ_PRE-1)) && !irq_sample_advance_cancelled;

	always_ff @(posedge clk) begin
		if (por) begin
			pre_cnt <= '0; post_cnt <= '0; irq_periodic <= 1'b0;
			irq_sample_advance_cancelled <= 1'b0;
		end else begin
			if (ce_3m58) begin
				pre_cnt <= pre_cnt + PREW'(1);
				if (pre_cnt == PREW'(IRQ_PRE-1)) begin
					if (post_cnt == POSTW'(IRQ_POST-1)) begin
						post_cnt     <= '0;
						irq_periodic <= 1'b1;    // 5F-2 sets -> Q6 -> /IRQ low
						irq_sample_advance_cancelled <= 1'b0;
					end else begin
						post_cnt <= post_cnt + POSTW'(1);
					end
				end
			end
			// 5F-2's Q holds the last LS393's active-high 2CLR for as long as
			// the interrupt is pending, so the /14 stage cannot advance.
			if (!MAME_FREERUN && irq_periodic) post_cnt <= '0;
			// /IRQACK is 5F-2's ASYNCHRONOUS /CLR: dominant over a coincident
			// divider edge (applied last).
			if (sel_irqack) begin
				irq_periodic <= 1'b0;
				if (irq_sample_advance_active && (pre_cnt != PREW'(IRQ_PRE-1)))
					irq_sample_advance_cancelled <= 1'b1;
			end
		end
	end

	// Q6 is an open-collector pull-down onto /IRQ; the YM2151's IRQ pin is the
	// other pull-down and R49 10 K is the pull-up.
	wire irq_n = ~(irq_periodic | irq_sample_advance_active | ym_irq);
	wire nmi_n = ~scom_full;

	// ---- 6502A 1D ----------------------------------------------------------
	// Mode 00 = NMOS 6502.  Enable = ce_1m79, Rdy = 1.
	// The instance MUST be named `u_cpu` -- SkullXBones.sdc addresses the core
	// as *u_sound|u_bus|u_cpu|u_t65|*.
	wire [7:0] dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc;
	T65_wrap u_cpu (
		.Mode(2'b00), .Res_n(reset_n), .Clk(clk), .Enable(ce_1m79), .Rdy(1'b1),
		.IRQ_n(irq_n), .NMI_n(nmi_n), .DI(cpu_din),
		.A(cpu_addr), .DO(cpu_dout), .R_W_n(cpu_rnw), .Sync(cpu_sync),
		.dbg_A(dbgA_nc), .dbg_X(dbgX_nc), .dbg_Y(dbgY_nc),
		.dbg_S(dbgS_nc), .dbg_P(dbgP_nc) );

	// ---- PAL 2D + LS138 3F --------------------------------------------------
	wire rom_ce, yam, rest, ram, a13b, a12b, swr, srd, srd_gal;
	wire sel_ram, sel_ym, sel_bank, sel_romfix, sel_hole;
	wire [15:0] rom_rd_addr;
	skullxbo_snd_decode u_dec (
		.sa(cpu_addr), .srw(cpu_rnw), .o2(ce_1m79),
		.ba13(bank[1]), .ba12(bank[0]),
		.rom_ce(rom_ce), .yam(yam), .rest(rest), .ram(ram),
		.a13b(a13b), .a12b(a12b), .swr(swr), .srd(srd), .srd_gal(srd_gal),
		.sel_ram(sel_ram), .sel_ym(sel_ym), .sel_bank(sel_bank),
		.sel_romfix(sel_romfix), .sel_hole(sel_hole),
		.sel_rdv(sel_rdv), .sel_rdp(sel_rdp), .sel_rdio(sel_rdio),
		.sel_irqack(sel_irqack), .sel_wrv(sel_wrv), .sel_wrp(sel_wrp),
		.sel_wrio(sel_wrio), .sel_mix(sel_mix),
		.ym_a0(ym_a0), .rom_addr(rom_rd_addr) );

	// ---- 6264 2B : 8 KB work RAM -------------------------------------------
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] ram_mem [0:8191];
	// ---- 27512 1B : 64 KB program ROM, filled by the ROM loader -------------
	(* ramstyle = "no_rw_check, M10K" *) logic [7:0] rom_mem [0:65535];
`ifndef ALTERA_RESERVED_QIS
	// Sim-only zero fill so iverilog/verilator never read X out of an
	// unwritten location.  Quartus zeroes M10K contents at configuration.
	initial begin
		for (int i = 0; i < 8192;  i++) ram_mem[i] = 8'h00;
		for (int i = 0; i < 65536; i++) rom_mem[i] = 8'h00;
	end
`endif

	// Both arrays are read EVERY clk from the (stable) 6502 address, so their
	// registered outputs are standing at the ce_1m79 edge on which T65 samples
	// DI.
	logic [7:0] ram_q, rom_q;
	always @(posedge clk) begin
		if (swr & sel_ram) ram_mem[cpu_addr[12:0]] <= cpu_dout;
		ram_q <= ram_mem[cpu_addr[12:0]];
		rom_q <= rom_mem[rom_rd_addr];
		if (rom_wr) rom_mem[rom_wr_addr] <= rom_wr_data;
	end

	// ---- YM2151 3A strobes -------------------------------------------------
	assign ym_cs   = sel_ym;
	assign ym_we   = sel_ym & swr;
	assign ym_rd   = sel_ym & srd;
	assign ym_dout = cpu_dout;

	// ---- the SD7:0 read mux -------------------------------------------------
	// Each source is qualified by the strobe that actually turns on its own
	// output driver on the board: 2B /OE = /SRD with /CS1 = /RAM; 1B /OE =
	// /SRD with /CE = /ROM; YM2151 /RD = /SRD with /CS = /YAM; SCOM 3D drives
	// on /RDP; LS240 2F on /RDIO; the MSM6295's CS pin is tied to GND, so its
	// RD pin alone (/RDV) enables its status byte.
	logic [7:0] sd_drv;
	logic       sd_hit;
	always_comb begin
		sd_hit = 1'b1;
		if      (srd & sel_ram) sd_drv = ram_q;
		else if (srd & rom_ce)  sd_drv = rom_q;
		else if (srd & sel_ym)  sd_drv = ym_din;
		else if (sel_rdp)       sd_drv = rdp_data;
		else if (sel_rdio)      sd_drv = rdio_data;
		else if (sel_rdv)       sd_drv = rdv_data;
		// MAME's mapped /IRQACK read handler clears the timer IRQ and returns 0.
		else if (srd & sel_irqack) sd_drv = 8'h00;
		else begin sd_drv = 8'h00; sd_hit = 1'b0; end
	end

	// Bus hold: nobody drives SD7:0 inside the $2C00-$2FFF hole or on a READ
	// of the $2A00 group. Remember the last byte a real driver put on the bus
	// instead of inventing 0xFF. /IRQACK is the mapped MAME zero-read above.
	logic [7:0] sd_last;
	initial sd_last = 8'h00;
	// NOTE: `always @(posedge clk)`, not `always_ff`: this register has no
	// reset (its power-up value comes from the `initial` above) and IEEE 1800
	// 9.2.2.4 forbids an always_ff variable being written by another process.
	always @(posedge clk) if (ce_1m79) begin
		if      (~cpu_rnw) sd_last <= cpu_dout;   // the 6502 drives on a write
		else if (sd_hit)   sd_last <= sd_drv;
	end

	assign cpu_din = sd_hit ? sd_drv : sd_last;

	// Unused: the PAL's raw /SRD output, the raw PAL selects and the 27512's
	// own A13/A12 pins, the T65 debug registers, and the $2C00-$2FFF hole.
	wire _unused_bus = &{ 1'b0, srd_gal, rest, ram, yam, a13b, a12b,
	                      sel_bank, sel_romfix, sel_hole,
	                      dbgA_nc, dbgX_nc, dbgY_nc, dbgS_nc, dbgP_nc };

endmodule
