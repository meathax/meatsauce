// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// leland_sound -- the whole 80186 sound-board chain in one module for leland_board to
// instantiate. It owns:
//   - the vendored s80x86 core, run at the full clk_sys rate. Its optional
//     instruction-pacing profile consumes ce_8m only as a logical cycle enable;
//     accepted-cycle handshakes continue to own all bus side effects.
//   - the first-level bus arbiter (the core's instr_m vs data_m ports)
//   - i186_periph (CSU, timers, interrupt controller, DMA and the DMA-vs-CPU arbiter)
//   - leland_sound_board and leland_dac_mixer
//   - the 80186's own 16 KB RAM
//   - a byte-wide SDRAM read adapter for the ROM window (0x20000-0xFFFFF of the 80186
//     address space), with the same rom_req/rom_addr/rom_data/rom_stall shape as the
//     Z80 ROM clients
//
// Reference: MAME leland_a.cpp leland_80186_map_program (RAM 0x00000-0x1FFFF mirrored,
// ROM 0x20000-0xFFFFF identity-mapped into the audiocpu region).

module leland_sound #(
	parameter integer CPU_PACING_PROFILE = 0,
	parameter integer WSF_MIXER_PROFILE = 0,
	parameter integer USE_EXTERNAL_PIT_CE = 0
)(
	input  logic        clk_sys,   // selected board root clock
	input  logic        reset,     // board reset
	input  logic        ataxx_mode, // Ataxx sound board variant (I/O-mapped peripherals, PCS5 DACs)
	input  logic        wsf_mode,   // WSF variant (Indy Heat): YM2151 and external sample DAC
	input  logic        ce_8m,     // ~8MHz-equivalent CE -- paces ONLY
									// i186_periph's internal timer tick
									// (dac9's real sample rate); every
									// other signal in this chain runs
									// un-gated at clk_sys (see file header)
	input  logic        ce_4m,     // board-timed PIT/YM master-clock enable

	// --- Master-Z80-side control/command latch (leland_master.sv) ---
	input  logic [7:0]  sound_ctrl_data,
	input  logic         sound_ctrl_wr,
	input  logic [15:0] cmd_wr_data,
	input  logic         cmd_wr_lo, cmd_wr_hi,
	output logic [7:0]  response_data,

	// --- SDRAM read port (sound ROM), same shape as leland_master/
	//     leland_slave's own rom_req/rom_addr/rom_data/rom_stall ---
	output logic         rom_req,
	output logic [19:0] rom_addr,   // byte address, 0-0xFFFFF (80186's own address space)
	input  logic [7:0]  rom_data,
	input  logic         rom_stall,

	// --- External sample DAC ROM (WSF), same shape ---
	output logic         ext_req,
	output logic [18:0] ext_addr,
	input  logic [7:0]  ext_data,
	input  logic         ext_stall,

	// --- Audio output ---
	output logic signed [15:0] audio_out
);

// =====================================================================
// Core interrupt/debug ports: INT0/INT1 are decoded by leland_sound_board straight from
// control_data; NMI is unused per leland_a.cpp.
// =====================================================================
wire        nmi = 1'b0;
wire        intr, inta;
wire [7:0]  irq;

wire        debug_stopped;
wire [15:0] debug_val;

// =====================================================================
// Core bus ports
// =====================================================================
wire [19:1] instr_m_addr;
wire [15:0] instr_m_data_in;
wire        instr_m_access;
wire        instr_m_ack;

wire [19:1] data_m_addr;
wire [15:0] data_m_data_in;
wire [15:0] data_m_data_out;
wire        data_m_access;
wire        data_m_ack;
wire        data_m_wr_en;
wire [1:0]  data_m_bytesel;
wire        data_m_d_io;
wire        lock;

// --- audiocpu /RESET: board reset OR the control latch's own /RESET
// bit (leland_sound_board's decoded audiocpu_reset_n, active-high
// "running") ---
wire audiocpu_reset_n;
wire core_reset = reset | ~audiocpu_reset_n;

wire [15:0] core_ip_dbg;

Core #(.PACING_PROFILE(CPU_PACING_PROFILE)) cpu(
	.clk(clk_sys), .reset(core_reset),
	.pace_ce(ce_8m),
	.nmi(nmi), .intr(intr), .irq(irq), .inta(inta),
	.instr_m_addr(instr_m_addr), .instr_m_data_in(instr_m_data_in),
	.instr_m_access(instr_m_access), .instr_m_ack(instr_m_ack),
	.data_m_addr(data_m_addr), .data_m_data_in(data_m_data_in),
	.data_m_data_out(data_m_data_out), .data_m_access(data_m_access),
	.data_m_ack(data_m_ack), .data_m_wr_en(data_m_wr_en),
	.data_m_bytesel(data_m_bytesel), .d_io(data_m_d_io), .lock(lock),
	.debug_stopped(debug_stopped), .debug_seize(1'b0),
	.debug_addr(8'h0), .debug_run(1'b0), .debug_val(debug_val),
	.debug_wr_val(16'h0), .debug_wr_en(1'b0),
	.ip_out(core_ip_dbg));

// =====================================================================
// First-level arbiter: instr_m (lower priority, "a") vs data_m (higher priority, "b"), so
// data accesses win over prefetch. d_io is synthesised from the same q_b grant
// (instruction fetches are always memory space), as in the DMA arbiter's d_io mux in
// i186_periph.sv.
// =====================================================================
wire [19:1] cpu_m_addr;
wire [15:0] cpu_m_data_in;
wire [15:0] cpu_m_data_out;
wire        cpu_m_access;
wire        cpu_m_ack;
wire        cpu_m_wr_en;
wire [1:0]  cpu_m_bytesel;
wire        cpu_arb_grant_b;
wire        cpu_m_d_io = cpu_arb_grant_b ? data_m_d_io : 1'b0;

MemArbiter u_cpu_arb(
	.clk(clk_sys), .reset(core_reset),
	.a_m_addr(instr_m_addr), .a_m_data_in(instr_m_data_in), .a_m_data_out(16'h0),
	.a_m_access(instr_m_access), .a_m_ack(instr_m_ack), .a_m_wr_en(1'b0), .a_m_bytesel(2'b11),
	.b_m_addr(data_m_addr), .b_m_data_in(data_m_data_in), .b_m_data_out(data_m_data_out),
	.b_m_access(data_m_access), .b_m_ack(data_m_ack), .b_m_wr_en(data_m_wr_en), .b_m_bytesel(data_m_bytesel),
	.q_m_addr(cpu_m_addr), .q_m_data_in(cpu_m_data_in), .q_m_data_out(cpu_m_data_out),
	.q_m_access(cpu_m_access), .q_m_ack(cpu_m_ack), .q_m_wr_en(cpu_m_wr_en), .q_m_bytesel(cpu_m_bytesel),
	.q_b(cpu_arb_grant_b));

// =====================================================================
// Combinational-loop break: u_cpu_arb's q_m_* outputs (addr/access/wr_en/bytesel/data_out/
// d_io) are only stable once granted; in the cycle before grant_active registers, q_b (and
// so cpu_m_d_io) and q_m_access are live functions of the core's instr_m_access/
// data_m_access. The latches in i186_periph (internal_hit) and leland_sound_board
// (local_hit) do not remove that live selector edge from Quartus's structural loop check
// (a 299-node loop rooted at sys_d_io).
//
// The whole forward request bundle is therefore registered here, before it reaches
// i186_periph, so everything downstream sees a stable view of the transaction. The return
// path (cpu_m_ack/cpu_m_data_in) stays combinational: ack may arrive on any cycle, and
// registering it would need stale-ack gating for no benefit.
//
// This adds one cycle of uniform latency to every transaction and also makes cpu_d_io a
// stable per-transaction value, which leland_sound_board's do_write relies on.
// =====================================================================
reg  [19:1] cpu_req_addr_r;
reg  [15:0] cpu_req_data_out_r;
reg         cpu_req_access_r;
reg         cpu_req_wr_en_r;
reg  [1:0]  cpu_req_bytesel_r;
reg         cpu_req_d_io_r;

always_ff @(posedge clk_sys or posedge core_reset) begin
	if (core_reset) begin
		cpu_req_access_r <= 1'b0;
	end else begin
		cpu_req_addr_r     <= cpu_m_addr;
		cpu_req_data_out_r <= cpu_m_data_out;
		cpu_req_access_r   <= cpu_m_access;
		cpu_req_wr_en_r    <= cpu_m_wr_en;
		cpu_req_bytesel_r  <= cpu_m_bytesel;
		cpu_req_d_io_r     <= cpu_m_d_io;
	end
end

// =====================================================================
// i186_periph
// =====================================================================
wire [19:1] sys_addr;
wire [15:0] sys_data_in;
wire [15:0] sys_data_out;
wire        sys_access;
wire        sys_ack;
wire        sys_wr_en;
wire [1:0]  sys_bytesel;
wire        sys_d_io;

wire [19:0] ext_window_base;
wire        ext_window_is_mem, ext_window_valid;
wire [15:0] reloc_reg, umcs_reg, lmcs_reg, pacs_reg, mmcs_reg, mpcs_reg;
wire        tmrout0, tmrout1;
wire [2:0]  timer_irq, timer_tc_pulse;
wire [15:0] t_count[0:2], t_maxA[0:2], t_maxB[0:2], t_control[0:2];
wire [7:0]  intc_request_reg, intc_in_service_reg;
wire [2:0]  intc_status_reg;
wire [3:0]  intc_timer0_ctrl_reg, intc_dma0_ctrl_reg, intc_dma1_ctrl_reg;
wire [6:0]  intc_ext0_ctrl_reg, intc_ext1_ctrl_reg;

wire        int0_pin, int1_pin; // from leland_sound_board's control_data decode
wire        drq0_pit_level, drq1_pit_level, drq0_clear, drq1_clear;
wire [19:0] dma_src[0:1], dma_dst[0:1];
wire [15:0] dma_count[0:1], dma_control[0:1];
wire [1:0]  dma_active;
wire        dma_byte_done, dma_byte_done_ch;

i186_periph periph(
	.clk(clk_sys), .reset(core_reset), .ce_8m(ce_8m),
	.cpu_data_m_addr(cpu_req_addr_r), .cpu_data_m_data_in(cpu_m_data_in),
	.cpu_data_m_data_out(cpu_req_data_out_r), .cpu_data_m_access(cpu_req_access_r),
	.cpu_data_m_ack(cpu_m_ack), .cpu_data_m_wr_en(cpu_req_wr_en_r),
	.cpu_data_m_bytesel(cpu_req_bytesel_r), .cpu_d_io(cpu_req_d_io_r),
	.sys_data_m_addr(sys_addr), .sys_data_m_data_in(sys_data_in),
	.sys_data_m_data_out(sys_data_out), .sys_data_m_access(sys_access),
	.sys_data_m_ack(sys_ack), .sys_data_m_wr_en(sys_wr_en),
	.sys_data_m_bytesel(sys_bytesel), .sys_d_io(sys_d_io),
	.ext_window_base(ext_window_base), .ext_window_is_mem(ext_window_is_mem),
	.ext_window_valid(ext_window_valid),
	.reloc_reg(reloc_reg), .umcs_reg(umcs_reg), .lmcs_reg(lmcs_reg),
	.pacs_reg(pacs_reg), .mmcs_reg(mmcs_reg), .mpcs_reg(mpcs_reg),
	.tmrout0(tmrout0), .tmrout1(tmrout1), .timer_irq(timer_irq),
	.timer_tc_pulse(timer_tc_pulse),
	.t_count(t_count), .t_maxA(t_maxA), .t_maxB(t_maxB), .t_control(t_control),
	.intr(intr), .irq_out(irq), .inta(inta),
	.int0_pin(int0_pin), .int1_pin(int1_pin),
	.dma0_irq_req(1'b0), .dma1_irq_req(1'b0),
	.intc_request_reg(intc_request_reg), .intc_in_service_reg(intc_in_service_reg),
	.intc_status_reg(intc_status_reg),
	.intc_timer0_ctrl_reg(intc_timer0_ctrl_reg), .intc_dma0_ctrl_reg(intc_dma0_ctrl_reg),
	.intc_dma1_ctrl_reg(intc_dma1_ctrl_reg),
	.intc_ext0_ctrl_reg(intc_ext0_ctrl_reg), .intc_ext1_ctrl_reg(intc_ext1_ctrl_reg),
	.drq0_pit_level(drq0_pit_level), .drq1_pit_level(drq1_pit_level),
	.drq0_clear(drq0_clear), .drq1_clear(drq1_clear),
	.dma_src(dma_src), .dma_dst(dma_dst), .dma_count(dma_count), .dma_control(dma_control),
	.dma_active(dma_active), .dma_byte_done(dma_byte_done), .dma_byte_done_ch(dma_byte_done_ch));

// =====================================================================
// leland_sound_board -- PIT clock enable: the two discrete PIT8254s run at 4 MHz
// (leland_a.cpp `set_clk<N>(4000000)`). Legacy standalone runs may derive clk_sys/12;
// the production board supplies the phase-coherent 4 MHz enable from the clock plan.
// =====================================================================
reg [3:0] pit_ce_div;
wire      pit_ce = USE_EXTERNAL_PIT_CE ? ce_4m : (pit_ce_div == 4'd11);
always @(posedge clk_sys or posedge reset) begin
	if (reset) pit_ce_div <= 4'd0;
	else pit_ce_div <= (pit_ce_div == 4'd11) ? 4'd0 : pit_ce_div + 4'd1;
end

wire [19:1] mem_addr;
wire [15:0] mem_data_in;
wire [15:0] mem_data_out;
wire        mem_access;
wire        mem_ack;
wire        mem_wr_en;
wire [1:0]  mem_bytesel;
wire        mem_d_io;

wire        audiocpu_test_n; // decoded but unused (no /TEST wiring needed)
wire [7:0]  dac_sample[0:5];
wire [7:0]  dac_vol[0:5];
wire        dac_wr[0:5];
wire [9:0]  dac9_sample;
wire        dac9_wr;
wire [6:0]  clock_active;
wire        response_wr;
wire        ym_we, ym_a0;
wire [7:0]  ym_din, ym_dout;
wire signed [15:0] ym_left, ym_right;

// =====================================================================
// Combinational-loop break, second boundary: leland_sound_board's win_hit/fresh_access
// latch still reads the live `cpu_access` (= u_dma_arb's q_m_access, which depends
// combinationally on `cpu_ack` through MemArbiter's `q_m_access = ~q_m_ack & (...)`) in
// its selector, which Quartus reports as a 42-node loop between u_dma_arb and
// leland_sound_board. As for the first boundary, the whole forward bundle is
// registered here and the return leg (cpu_ack/cpu_data_in) is left unregistered.
// =====================================================================
reg  [19:1] board_req_addr_r;
reg  [15:0] board_req_data_out_r;
reg         board_req_access_r;
reg         board_req_wr_en_r;
reg  [1:0]  board_req_bytesel_r;
reg         board_req_d_io_r;

always_ff @(posedge clk_sys or posedge core_reset) begin
	if (core_reset) begin
		board_req_access_r <= 1'b0;
	end else begin
		board_req_addr_r     <= sys_addr;
		board_req_data_out_r <= sys_data_out;
		board_req_access_r   <= sys_access;
		board_req_wr_en_r    <= sys_wr_en;
		board_req_bytesel_r  <= sys_bytesel;
		board_req_d_io_r     <= sys_d_io;
	end
end

// leland_sound_board is reset by the plain board-level `reset`, not `core_reset`:
// core_reset is derived from this module's own audiocpu_reset_n output, so gating this
// module's reset on it would lock the module in reset (audiocpu_reset_n resets to 0).
// Everything held while the control latch's /RESET bit is asserted (core, i186_periph)
// uses core_reset; the module that decides that bit must not.
leland_sound_board board(
	.clk(clk_sys), .reset(reset),
	.cpu_addr(board_req_addr_r), .cpu_data_in(sys_data_in), .cpu_data_out(board_req_data_out_r),
	.cpu_access(board_req_access_r), .cpu_ack(sys_ack), .cpu_wr_en(board_req_wr_en_r),
	.cpu_bytesel(board_req_bytesel_r), .cpu_d_io(board_req_d_io_r),
	.ext_window_base(ext_window_base), .ext_window_is_mem(ext_window_is_mem),
	.ext_window_valid(ext_window_valid),
	.mem_addr(mem_addr), .mem_data_in(mem_data_in), .mem_data_out(mem_data_out),
	.mem_access(mem_access), .mem_ack(mem_ack), .mem_wr_en(mem_wr_en),
	.mem_bytesel(mem_bytesel), .mem_d_io(mem_d_io),
	.t0_tc_pulse(timer_tc_pulse[0]),
	.pit_ce(pit_ce), .ataxx_mode(ataxx_mode), .wsf_mode(wsf_mode),
	.t1_tc_pulse(timer_tc_pulse[1]), .t1_state(t_control[1][1] ? t_control[1][12] : 1'b1),
	.ym_we(ym_we), .ym_a0(ym_a0), .ym_din(ym_din), .ym_dout(ym_dout),
	.ext_req(ext_req), .ext_addr(ext_addr), .ext_data(ext_data), .ext_stall(ext_stall),
	.cmd_wr_data(cmd_wr_data), .cmd_wr_lo(cmd_wr_lo), .cmd_wr_hi(cmd_wr_hi),
	.response_data(response_data), .response_wr(response_wr),
	.control_data(sound_ctrl_data), .control_wr(sound_ctrl_wr),
	.audiocpu_reset_n(audiocpu_reset_n), .audiocpu_test_n(audiocpu_test_n),
	.int0_pin(int0_pin), .int1_pin(int1_pin),
	.dac_sample(dac_sample), .dac_vol(dac_vol), .dac_wr(dac_wr),
	.dac9_sample(dac9_sample), .dac9_wr(dac9_wr),
	.drq0_pit_level(drq0_pit_level), .drq1_pit_level(drq1_pit_level),
	.drq0_clear(drq0_clear), .drq1_clear(drq1_clear),
	.clock_active(clock_active));

// =====================================================================
// leland_dac_mixer_profile
// =====================================================================
leland_dac_mixer_profile #(.WSF_MIXER_PROFILE(WSF_MIXER_PROFILE)) mixer(
	.clk(clk_sys), .reset(reset),
	.wsf_mode(wsf_mode),
	.dac_sample(dac_sample), .dac_vol(dac_vol), .dac9_sample(dac9_sample),
	.ym_left(ym_left), .ym_right(ym_right),
	.audio_out(audio_out));

// =====================================================================
// YM2151 (WSF only): 4 MHz chip clock, 2 MHz phase enable. A write is held until the next
// phase tick, then applied as a single-clock pulse (the chip acts on every clock it is high).
// =====================================================================
reg ym_phase;
always @(posedge clk_sys or posedge reset) begin
	if (reset) ym_phase <= 1'b0;
	else if (pit_ce) ym_phase <= ~ym_phase;
end
wire ym_cen_p1 = pit_ce && ym_phase;

reg       ym_wr_hold, ym_a0_r;
reg [7:0] ym_din_r;
always @(posedge clk_sys or posedge reset) begin
	if (reset) begin
		ym_wr_hold <= 1'b0;
		ym_a0_r    <= 1'b0;
		ym_din_r   <= 8'h00;
	end else if (ym_we) begin
		ym_wr_hold <= 1'b1;
		ym_a0_r    <= ym_a0;
		ym_din_r   <= ym_din;
	end else if (ym_cen_p1) begin
		ym_wr_hold <= 1'b0;
	end
end

// The chip's internal pipelines need a long reset to clear (a short one leaves it noisy).
reg [11:0] ym_rst_cnt;
wire       ym_rst = (ym_rst_cnt != 12'hFFF);
always @(posedge clk_sys) begin
	if (reset | ~wsf_mode) ym_rst_cnt <= 12'd0;
	else if (ym_rst)       ym_rst_cnt <= ym_rst_cnt + 12'd1;
end

jt51 ym(
	.rst(ym_rst), .clk(clk_sys), .cen(pit_ce), .cen_p1(ym_cen_p1),
	.cs_n(1'b0), .wr_n(~(ym_wr_hold & ym_cen_p1)), .a0(ym_a0_r), .din(ym_din_r), .dout(ym_dout),
	.ct1(), .ct2(), .irq_n(), .sample(),
	.left(ym_left), .right(ym_right), .xleft(), .xright());

// =====================================================================
// 80186's own memory: RAM (16 KB, mirrored x8 across 0x00000-0x1FFFF), self-contained
// here; ROM (0x20000-0xFFFFF) via the byte-wide SDRAM adapter below. Per
// leland_80186_map_program, RAM occupies word address < 19'h10000 and ROM is everything
// above it up to the region's 1 MB size.
// =====================================================================
wire mem_is_ram = (mem_addr < 19'h10000);

// --- RAM (16 KB = 8192 words, byte-addressable via bytesel) ---
reg [7:0] ram_lo [0:8191]; // even bytes
reg [7:0] ram_hi [0:8191]; // odd bytes
wire [12:0] ram_word_addr = mem_addr[13:1]; // mirror: only the low 13 bits of the word address matter

reg        ram_ack;
reg [15:0] ram_data_in_r;
always @(posedge clk_sys or posedge core_reset) begin
	if (core_reset) begin
		ram_ack <= 1'b0;
	end else begin
		if (mem_access && mem_is_ram && !ram_ack) begin
			ram_ack <= 1'b1;
			ram_data_in_r <= {ram_hi[ram_word_addr], ram_lo[ram_word_addr]};
			if (mem_wr_en) begin
				if (mem_bytesel[0]) ram_lo[ram_word_addr] <= mem_data_out[7:0];
				if (mem_bytesel[1]) ram_hi[ram_word_addr] <= mem_data_out[15:8];
			end
		end else if (!mem_access) begin
			ram_ack <= 1'b0;
		end
	end
end

// --- ROM (byte-wide SDRAM adapter): fetches both bytes of the containing word for every
// access (regardless of bytesel) and presents a full 16-bit word once both arrive. There
// is a one-cycle req-low gap between the two byte requests, as leland_board's SDRAM
// arbiter requires (clients deassert req for >= 1 cycle after ack).
localparam ROM_IDLE = 3'd0, ROM_LO = 3'd1, ROM_GAP = 3'd2, ROM_HI = 3'd3, ROM_DONE = 3'd4;
reg [2:0]  rom_phase;
reg [18:0] rom_word_addr_latch;
reg [7:0]  rom_lo_byte, rom_hi_byte;

wire rom_hit = mem_access && !mem_is_ram;

assign rom_req  = (rom_phase == ROM_LO) || (rom_phase == ROM_HI);
assign rom_addr = (rom_phase == ROM_HI) ? {rom_word_addr_latch, 1'b1} : {rom_word_addr_latch, 1'b0};

always @(posedge clk_sys or posedge core_reset) begin
	if (core_reset) begin
		rom_phase <= ROM_IDLE;
	end else begin
		case (rom_phase)
			ROM_IDLE: if (rom_hit) begin
				rom_word_addr_latch <= mem_addr;
				rom_phase <= ROM_LO;
			end
			ROM_LO: if (!rom_stall) begin
				rom_lo_byte <= rom_data;
				rom_phase  <= ROM_GAP;
			end
			ROM_GAP: rom_phase <= ROM_HI; // one cycle, rom_req low
			ROM_HI: if (!rom_stall) begin
				rom_hi_byte <= rom_data;
				rom_phase  <= ROM_DONE;
			end
			ROM_DONE: if (!mem_access) rom_phase <= ROM_IDLE;
		endcase
	end
end

wire        rom_done_ack  = (rom_phase == ROM_DONE);
wire [15:0] rom_data_word = {rom_hi_byte, rom_lo_byte};

assign mem_ack     = mem_is_ram ? ram_ack      : rom_done_ack;
assign mem_data_in = mem_is_ram ? ram_data_in_r : rom_data_word;

endmodule
