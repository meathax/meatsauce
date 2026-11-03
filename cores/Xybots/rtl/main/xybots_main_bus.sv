`timescale 1ns/1ps
//============================================================================
//  Xybots main board — SP-313 sheet 2 as one block.
//
//  Copyright (C) 2026 the Xybots MiSTer core authors.
//  GPL-3.0-or-later; see LICENSE.
//  Structure and several sub-blocks derive from the Arcade-Toobin_MiSTer
//  core's `toobin_main_bus.sv` (GPL-3.0-or-later); see NOTICE.md.
//
//  Composes: xybots_cpu (fx68k, cycle-exact 68000) + xybots_addr_decode +
//  xybots_dtack + xybots_irq + xybots_watchdog + xybots_slapstic +
//  xybots_eeprom_2804 + xybots_nvram_io + xybots_inputs + the video RAM
//  (14J/14E) and colour RAM (17J/17K) block RAMs.
//
//  ---- what is a port and why ---------------------------------------------
//  * The program ROM is a read port shaped like `xybots_mem`'s `prog_*` group:
//    the RAW 68000 A17..A1, /SLAPSTIC and the bank, because
//    `rtl/mem/xybots_prog_rom.sv` implements the 13C LS157 substitution and the
//    17B/19B 27256 A16 fold itself.  Latency is 1 clk_sys, which is a whole
//    VIDCLK inside the earliest /DTACK.
//  * The video sides of the VRAM and CRAM are read-only ports out of here.  The
//    CPU side is arbitrated: the CPU owns **VRAC phase 3** of the four-phase
//    video-RAM multiplex, and the 7B 74S74 in xybots_dtack is what makes the
//    CPU wait for that slot.
//  * `vrac`/`vrac2`, `v[2:0]`, `hblank`, `vblank`, `h256` and `virq` come from
//    the video timing block.  `virq` is the 6D LS174E output, i.e. bit 10 of
//    the ALPHA word being fetched — see xybots_irq's header.
//
//  ---- the /RESET net ------------------------------------------------------
//  The watchdog's /RESET resets the 68000 AND (leaving sheet 2 for sheet 3
//  only) clears the EEPROM unlock flip-flop and forces the EEPROM /OE gate.
//  A `RESET` instruction pulls the same net low through the CPU's open-drain
//  pin, so it force-locks the EEPROM and does nothing else — in particular it
//  does NOT reset the slapstic, the video side or the sound board (that is
//  /AUDRES -> SCOM /RESREQ).  The slapstic's own `rst` is therefore wired to
//  `init_reset` alone.
//============================================================================

module xybots_main_bus #(
	parameter int  CLK_HZ    = 57_272_727,
	parameter int  EE_WRITE_CYCLES = CLK_HZ / 100,   // X2804A 10 ms bound
	parameter bit  JP2       = 1'b0                  // watchdog disable jumper
)(
	input  logic        clk,          // clk_sys 57.272727 MHz
	input  logic        ce_7m,        // VIDCLK enable, clk_sys / 8 (withheld while paused)
	input  logic        init_reset,   // FPGA init / ROM not loaded yet
	// MiSTer OSD pause, from xybots_core.  `ce_7m` already arrives withheld
	// for the pause; this input freezes the three pieces of main-board state
	// that the video side, or raw clk_sys, would otherwise move during it:
	// the watchdog's /VBLANK count, the VIRQ preset into the IRQ1 latch and
	// the X2804 write timer.  Tie low where there is no pause.
	input  logic        paused,
	input  logic        por,          // sheet-1 power-on reset, active high

	// ---- video timing ----
	input  logic  [1:0] vrac,         // {VRAC1,VRAC0}; 3 = the CPU's slot
	input  logic        vrac2,        // 7B 74S74 clock
	input  logic  [2:0] v,            // 4V, 2V, 1V
	input  logic        hblank,
	input  logic        vblank,
	input  logic        h256,
	input  logic        virq,         // 6D LS174E pin 2: latched alpha bit 10

	// ---- program ROM read port, exactly xybots_mem's `prog_*` group ----
	output logic [16:0] prog_a,          // 68000 A17..A1, BEFORE substitution
	output logic        prog_slap_sel,   // /SLAPSTIC asserted (active high)
	output logic  [1:0] prog_slap_bank,  // {BS1, BS0} from 14B
	input  logic [15:0] prog_data,       // valid 1 clk_sys after the address

	// ---- EEPROM factory image, from xybots_mem's index-0 tail ----
	input  logic        eeprom_img_wr,
	input  logic  [8:0] eeprom_img_addr,
	input  logic  [7:0] eeprom_img_data,

	// ---- video read ports ----
	input  logic [12:0] vram_vaddr,
	output logic [15:0] vram_vdata,
	input  logic  [9:0] cram_vaddr,
	output logic [15:0] cram_vdata,

	// ---- control panel, active-HIGH "pressed"; bit order = the /SW word ----
	//  [15] P1 UP   [14] P1 DOWN  [13] P1 LEFT  [12] P1 RIGHT
	//  [11] P1 TWIST L [10] P1 TWIST R [9] P1 FIRE [8] P1 START
	//  [ 7] P2 UP   [ 6] P2 DOWN  [ 5] P2 LEFT  [ 4] P2 RIGHT
	//  [ 3] P2 TWIST L [ 2] P2 TWIST R [1] P2 FIRE [0] P2 START
	input  logic [15:0] panel,
	input  logic        self_test,    // 1 = the self-test switch is ON
	input  logic  [3:0] swb,          // SWB-3..6 -> /SYSIN D12..D15 (MAME: unused)

	// ---- JSA I sound mailbox (xybots_jsa) ----
	output logic        snd_cmd_wr,
	output logic  [7:0] snd_cmd_data,
	output logic        snd_resp_rd,
	output logic        snd_reset,
	input  logic  [7:0] snd_resp_data,
	input  logic        snd_irq,
	input  logic        snd_m2s_ready,

	// ---- MiSTer NVRAM (index 2) ----
	input  logic        ioctl_download,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_upload,
	output logic        ioctl_upload_req,
	output logic  [7:0] ioctl_upload_index,
	output logic  [7:0] ioctl_din,

	// ---- observation / debug; no consumer inside the core ----
	output logic [23:1] cpu_a,
	output logic [15:0] cpu_dout,
	output logic        cpu_as,
	output logic        cpu_uds_n,
	output logic        cpu_lds_n,
	output logic        cpu_rw,
	output logic        cpu_dtack,
	output logic  [2:0] cpu_fc,
	output logic [15:0] cpu_din,
	output logic  [1:0] slap_bank,
	output logic        watchdog_reset,
	output logic        reset_net,    // the sheet-2 /RESET net, ACTIVE HIGH here
	output logic  [2:0] ipl
);

	// =====================================================================
	//  CPU
	// =====================================================================
	logic        cpu_reset, reset_inst;
	logic [15:0] cpu_rdata_r;
	// 10A LS20.  Declared here because sheet 2 wires it to the 68000's VPA pin
	// as well as to the 5A's ENT input, so the CPU instance needs it.
	logic        vpa_n;

	// `xybots_cpu` is the fx68k wrapper (Jorge Cwik's cycle-exact 68000) and is
	// the core's only 68000.  It regenerates the second clock phase fx68k needs
	// from `ce_7m` itself, so sheet 2 hands it nothing but the enable that
	// everything else here runs on.
	xybots_cpu u_cpu (
		.clk(clk), .ce_7m(ce_7m), .reset(cpu_reset), .ipl(ipl),
		.a(cpu_a), .wdata(cpu_dout), .rdata(cpu_rdata_r),
		.as(cpu_as), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n), .rw(cpu_rw),
		.dtack(cpu_dtack), .vpa_n(vpa_n), .fc(cpu_fc),
		.reset_inst(reset_inst));

	assign cpu_din = cpu_rdata_r;

	// =====================================================================
	//  Decode (sheet 2)
	// =====================================================================
	logic r_n, w_n, wh_n, wl_n, boardsel;
	logic rom_n, slapstic_n, vram_n, ioen_n, cram_n, eerom_n, io7000_n, iosel_n;
	logic audrd_n, sw_n, sysin_n, rd3_n;
	logic unlock_n, audwr_n, wdog_n, vidack_n, nc4_n, nc5_n, audres_n, nc7_n;

	xybots_addr_decode u_dec (
		.a(cpu_a), .as(cpu_as), .uds_n(cpu_uds_n), .lds_n(cpu_lds_n),
		.rw(cpu_rw), .fc(cpu_fc),
		.r_n(r_n), .w_n(w_n), .wh_n(wh_n), .wl_n(wl_n), .boardsel(boardsel),
		.rom_n(rom_n), .slapstic_n(slapstic_n), .vram_n(vram_n), .ioen_n(ioen_n),
		.cram_n(cram_n), .eerom_n(eerom_n), .io7000_n(io7000_n), .iosel_n(iosel_n),
		.audrd_n(audrd_n), .sw_n(sw_n), .sysin_n(sysin_n), .rd3_n(rd3_n),
		.unlock_n(unlock_n), .audwr_n(audwr_n), .wdog_n(wdog_n), .vidack_n(vidack_n),
		.nc4_n(nc4_n), .nc5_n(nc5_n), .audres_n(audres_n), .nc7_n(nc7_n),
		.vpa_n(vpa_n));

	// The three bare LS138 stubs and the two undecoded LS139 outputs reach
	// nothing on this board.  They are read here so the tools see them used and
	// so a future revision that populates one has an obvious hook.
	/* verilator lint_off UNUSEDSIGNAL */
	wire unused_dec = &{1'b0, boardsel, ioen_n, iosel_n, io7000_n, rd3_n,
	                    nc4_n, nc5_n, nc7_n, r_n, w_n};
	/* verilator lint_on UNUSEDSIGNAL */

	// =====================================================================
	//  Bus-cycle edges
	// =====================================================================
	// A 68000 asserts /AS in S2 and the data strobes in S4 for a WRITE, so the
	// write one-shot has to fire on the data strobe, not on /AS.
	logic as_d, ws_d;
	wire  ws = cpu_as & ~cpu_rw & (~cpu_uds_n | ~cpu_lds_n);
	always_ff @(posedge clk) begin
		if (init_reset) begin as_d <= 1'b0; ws_d <= 1'b0; end
		else            begin as_d <= cpu_as; ws_d <= ws;  end
	end
	wire cyc_start = cpu_as & ~as_d;   // falling edge of /AS
	wire cyc_end   = ~cpu_as & as_d;   // RISING  edge of /AS  = the slapstic CK
	wire wr_stb    = ws & ~ws_d;       // one write strobe per bus cycle

	// =====================================================================
	//  SLAPSTIC 137412-107 (14B) and the 13C LS157 bank substitution
	// =====================================================================
	// CK (pin 7) = /AS.  A clocked part takes its RISING edge, i.e. the END of
	// the 68000 bus cycle, when the address is still held valid.  So the access
	// that selects a bank still reads the OLD bank and the new one applies from
	// the next cycle — which is exactly what MAME's read TAP does (the tap runs
	// after the underlying `bankr` read) and what the boot trace shows at
	// pc 0x13F32 (reads 0x8038 while switching 3 -> 2 and gets bank 3's word
	// 0x0100, then reads 0x0000 from bank 2 at pc 0x13F44).
	// /RESET does not reach 14B at all, so only power-up parks the chip at
	// BANKSTART = 3.
	/* verilator lint_off UNUSEDSIGNAL */
	wire [2:0] slap_state;
	/* verilator lint_on UNUSEDSIGNAL */
	xybots_slapstic u_slap (
		.clk(clk), .rst(init_reset),
		.cyc(cyc_end), .cs_n(slapstic_n), .a(cpu_a[14:1]), .we(~cpu_rw),
		.bank(slap_bank), .dbg_state(slap_state));

	// The 13C LS157 bank substitution and the 17B/19B 27256 A16 fold live in
	// `rtl/mem/xybots_prog_rom.sv`, which takes the raw A17..A1 plus /SLAPSTIC
	// and the bank; hand it exactly those three.
	assign prog_a         = cpu_a[17:1];
	assign prog_slap_sel  = ~slapstic_n;
	assign prog_slap_bank = slap_bank;

	// =====================================================================
	//  Video RAM (14J/14E) — 8 K words, true byte lanes, CPU = VRAC phase 3
	// =====================================================================
	// 15C LS32 gives 14J its own /WE from /WH and 14E its own /WE from /WL, so
	// byte writes on either lane are honoured.  The write
	// is held until the CPU's slot in the four-phase multiplex comes round; the
	// address and data are latched at the strobe so a phase boundary crossing
	// cannot use a stale bus.
	wire vram_phase   = (vrac == 2'd3);
	wire vram_wr_req  = wr_stb & ~vram_n;
	logic        vram_wr_pend;
	logic [12:0] vram_wa;
	logic [15:0] vram_wd;
	logic        vram_wpend_hi, vram_wpend_lo;

	always_ff @(posedge clk) begin
		if (init_reset) vram_wr_pend <= 1'b0;
		else if (vram_wr_req) begin
			vram_wa       <= cpu_a[13:1];
			vram_wd       <= cpu_dout;
			vram_wpend_hi <= ~wh_n;
			vram_wpend_lo <= ~wl_n;
			vram_wr_pend  <= ~vram_phase;
		end else if (vram_phase) begin
			vram_wr_pend  <= 1'b0;
		end
	end

	wire vram_we_now = (vram_wr_req | vram_wr_pend) & vram_phase;
	wire vram_we_hi  = vram_we_now & (vram_wr_req ? ~wh_n : vram_wpend_hi);
	wire vram_we_lo  = vram_we_now & (vram_wr_req ? ~wl_n : vram_wpend_lo);

	logic [15:0] vram_rdata;
	xybots_dpram_be #(.AW(13)) u_vram (
		.clk(clk),
		.a_addr(vram_wr_pend ? vram_wa : cpu_a[13:1]),
		.a_din (vram_wr_pend ? vram_wd : cpu_dout),
		.a_we_hi(vram_we_hi), .a_we_lo(vram_we_lo), .a_dout(vram_rdata),
		.b_addr(vram_vaddr), .b_dout(vram_vdata));

	// =====================================================================
	//  Colour RAM (17J/17K) — 1 K x 16
	// =====================================================================
	// Sheet 9 draws exactly ONE /WE path for both 17J and 17K, and it is
	// /WL-qualified — 15C LS32 (9 = /WL, 10 = /CRAMD) then 15C LS32 (13 = that,
	// 12 = /7M).  So the palette has no independent byte lanes: a low-byte write
	// strobe writes BOTH chips.  The schematic is implemented, which means a
	// UDS-only write to CRAM is LOST (no /WL) and an LDS-only write would store
	// whatever the CPU drives on D15:8.  The game never notices: it touches
	// CRAM with WORD accesses only, so this and MAME's per-lane
	// `palette_device::write16` are indistinguishable here.
	wire cram_we = wr_stb & ~cram_n & ~wl_n;
	logic [15:0] cram_rdata;
	xybots_dpram_be #(.AW(10)) u_cram (
		.clk(clk),
		.a_addr(cpu_a[10:1]), .a_din(cpu_dout),
		.a_we_hi(cram_we), .a_we_lo(cram_we), .a_dout(cram_rdata),
		.b_addr(cram_vaddr), .b_dout(cram_vdata));

	// =====================================================================
	//  Strobes off the two I/O decoders
	// =====================================================================
	// The write decoder (10B LS138) is qualified by /W and NOTHING else — no
	// /UDS, no /LDS — so a high-byte-only write strobes these exactly like a
	// word write.  The read decoder (11D half 2) has no
	// R/W qualifier at all, so /AUDRD reaches the SCOM's /RD pin on a WRITE to
	// 0x806000 too; the game never does that, but the strobe is faithful.
	wire unlock_wr  = wr_stb  & ~unlock_n;
	wire audwr_wr   = wr_stb  & ~audwr_n;
	wire wdog_wr    = wr_stb  & ~wdog_n;
	wire vidack_wr  = wr_stb  & ~vidack_n;
	wire audres_wr  = wr_stb  & ~audres_n;
	wire audrd_stb  = cyc_start & ~audrd_n;

	assign snd_cmd_wr   = audwr_wr;
	assign snd_cmd_data = cpu_dout[7:0];
	assign snd_resp_rd  = audrd_stb;
	assign snd_reset    = audres_wr;

	// =====================================================================
	//  Watchdog (3A LS90) and the /RESET net
	// =====================================================================
	logic vblank_d;
	always_ff @(posedge clk) vblank_d <= vblank;
	wire vblank_start = vblank & ~vblank_d;      // negative edge of /VBLANK

	logic wd_reset_n;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [3:0] wd_count;
	/* verilator lint_on UNUSEDSIGNAL */
	xybots_watchdog #(.JP2(JP2)) u_wdog (
		.clk(clk), .por(por | init_reset),
		.vblank_start(vblank_start & ~paused), .wdog_clr(wdog_wr),
		.reset_n(wd_reset_n), .count(wd_count));

	assign watchdog_reset = ~wd_reset_n;
	assign cpu_reset      = watchdog_reset | init_reset;
	// On the board the 68000's RESET and HALT pins are tied to this one net;
	// `xybots_cpu` performs the whole reset through fx68k's extReset instead
	// (see its header).  The CPU's own RESET instruction pulls the net low
	// without resetting the CPU, which is why `reset_inst` is ORed in here but
	// not into `cpu_reset`.
	assign reset_net      = watchdog_reset | init_reset | reset_inst;

	// =====================================================================
	//  Interrupts (sheet 2)
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire irq1_pending;
	/* verilator lint_on UNUSEDSIGNAL */
	// `reset` here is POWER-UP ONLY: the 1C 74S74's only clear is /VIDACK, so a
	// watchdog timeout must not drop a pending IRQ1 (see xybots_irq's header).
	// While paused the video keeps scanning, so VIRQ is masked here: the
	// latch keeps the state it had when the pause began.
	xybots_irq u_irq (
		.clk(clk), .reset(init_reset),
		.virq(virq & ~paused), .v(v), .hblank(hblank), .vblank(vblank),
		.vidack_wr(vidack_wr), .sound_irq(snd_irq),
		.ipl(ipl), .irq1_pending(irq1_pending));

	// =====================================================================
	//  EEPROM (20C/D) + unlock latch + MiSTer NVRAM
	// =====================================================================
	wire eeprom_we = wr_stb & ~eerom_n & ~wl_n;   // /CE = /EEROM, /WE = /WL
	wire low_write = wr_stb & ~wl_n;              // the board-global /WL edge

	logic [7:0] ee_rdata, ee_load_data, ee_dump_data;
	logic [8:0] ee_load_addr, ee_dump_addr;
	logic       ee_load_we, ee_write_accepted;
	/* verilator lint_off UNUSEDSIGNAL */
	wire        ee_busy, ee_oe_n, ee_unlocked;
	/* verilator lint_on UNUSEDSIGNAL */

	// Two restore paths reach the same 512 cells and are equivalent:
	// `xybots_mem` strips the MRA's 0x200-byte EEPROM tail out of the index-0
	// download, and `xybots_nvram_io` takes the `<nvram index="2">` channel
	// (and, standalone, the same index-0 tail).  Wire either or both; they
	// carry the same bytes.
	wire       ee_wr_any   = ee_load_we | eeprom_img_wr;
	wire [8:0] ee_wr_addr  = eeprom_img_wr ? eeprom_img_addr : ee_load_addr;
	wire [7:0] ee_wr_data  = eeprom_img_wr ? eeprom_img_data : ee_load_data;

	xybots_eeprom_2804 #(.CLK_HZ(CLK_HZ), .WRITE_CYCLES(EE_WRITE_CYCLES)) u_eeprom (
		.clk(clk), .init_reset(init_reset), .reset(reset_net), .paused(paused),
		.unlock(unlock_wr), .low_write(low_write), .cpu_we(eeprom_we),
		.cpu_addr(cpu_a[9:1]), .cpu_wdata(cpu_dout[7:0]), .cpu_rdata(ee_rdata),
		.busy(ee_busy), .oe_n(ee_oe_n), .unlocked(ee_unlocked),
		.write_accepted(ee_write_accepted),
		.load_we(ee_wr_any), .load_addr(ee_wr_addr), .load_data(ee_wr_data),
		.dump_addr(ee_dump_addr), .dump_data(ee_dump_data));

	xybots_nvram_io u_nvram (
		.clk(clk), .init_reset(init_reset), .write_accepted(ee_write_accepted),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_index(ioctl_index), .ioctl_upload(ioctl_upload),
		.load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data),
		.dump_addr(ee_dump_addr), .dump_data(ee_dump_data),
		.ioctl_upload_req(ioctl_upload_req),
		.ioctl_upload_index(ioctl_upload_index), .ioctl_din(ioctl_din));

	// =====================================================================
	//  Inputs (18F/21E/18J on sheet 4)
	// =====================================================================
	logic [15:0] sw_port, sysin_port;
	xybots_inputs u_inputs (
		.p1_up(panel[15]), .p1_down(panel[14]), .p1_left(panel[13]), .p1_right(panel[12]),
		.p1_twist_l(panel[11]), .p1_twist_r(panel[10]), .p1_fire(panel[9]), .p1_start(panel[8]),
		.p2_up(panel[7]),  .p2_down(panel[6]),  .p2_left(panel[5]),  .p2_right(panel[4]),
		.p2_twist_l(panel[3]),  .p2_twist_r(panel[2]),  .p2_fire(panel[1]),  .p2_start(panel[0]),
		.self_test(self_test), .snd_m2s_ready(snd_m2s_ready),
		.h256(h256), .vblank(vblank),
		.sw8(swb[0]), .sw9(swb[1]), .sw10(swb[2]), .sw11(swb[3]),
		.sw(sw_port), .sysin(sysin_port));

	// =====================================================================
	//  Read data
	// =====================================================================
	// Only the LS245 buffers on the A23 = 1 half and the ROM/slapstic on the
	// A23 = 0 half ever drive the CPU bus.  Everything else — reads of the
	// write-only strobes (the `clr` read-modify-writes at pc 0x52A and the five
	// `clr.w $ea00.w` sites), the three unconnected LS138 outputs, the
	// undecoded 0x806300/0x806700/0x807000 pages — leaves the bus floating,
	// modelled as 0xFFFF, which is also MAME's `unmap_value_high()`.
	logic [15:0] rdata_comb;
	always_comb begin
		if      (!rom_n)   rdata_comb = prog_data;                // includes the slapstic window
		else if (!vram_n)  rdata_comb = vram_rdata;
		else if (!cram_n)  rdata_comb = cram_rdata;
		else if (!eerom_n) rdata_comb = {8'hFF, ee_rdata};        // low lane only
		else if (!audrd_n) rdata_comb = {8'hFF, snd_resp_data};   // SCOM on D0B-D7B
		else if (!sw_n)    rdata_comb = sw_port;                  // full word
		else if (!sysin_n) rdata_comb = sysin_port;               // D15:8 only
		else               rdata_comb = 16'hFFFF;
	end

	// Register the read path so the value the CPU latches has settled for a
	// full clk_sys instead of arriving through a live decode + mux the same
	// cycle DTACK does.  Both block RAMs and the program ROM are already
	// registered-output, so the CPU sees data 2 clk_sys after the address —
	// far inside the 8 clk_sys (one VIDCLK) minimum before /DTACK.
	always_ff @(posedge clk) cpu_rdata_r <= rdata_comb;

	// =====================================================================
	//  DTACK (5A LS163A + 7B 74S74 + 1B LS02)
	// =====================================================================
	/* verilator lint_off UNUSEDSIGNAL */
	wire       dt_vdtack, dt_rco;
	wire [3:0] dt_wcnt;
	/* verilator lint_on UNUSEDSIGNAL */
	xybots_dtack u_dtack (
		.clk(clk), .ce_7m(ce_7m), .reset(init_reset),
		.as(cpu_as), .vram_n(vram_n), .eerom_n(eerom_n), .vpa_n(vpa_n), .vrac2(vrac2),
		.dtack(cpu_dtack), .vdtack(dt_vdtack), .rco(dt_rco), .wcnt(dt_wcnt));

endmodule
