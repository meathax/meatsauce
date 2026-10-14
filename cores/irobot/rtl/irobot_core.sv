`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Atari I, Robot board-level integration.
//
// The board has two independent oscillator domains.  clk_20m is the video
// oscillator (20 MHz -> 5 MHz dot clock); clk_12m096 is the CPU/mathbox/audio
// oscillator and must be supplied by the board-specific PLL/divider network.
// Keeping both clocks explicit here prevents the MiSTer shell from silently
// collapsing the two timing domains while the PLL work is completed.
module irobot_core (
	input  logic        clk_12m096,
	input  logic        clk_20m,
	input  logic        reset,
	input  logic        rom_download,

	// MiSTer ROM stream (index 0, validated by irobot_rom_router).
	input  logic        ioctl_wr,
	input  logic [24:0] ioctl_addr,
	input  logic [7:0]  ioctl_data,
	output logic        ioctl_wait,
	output logic        rom_loaded,

	// Cabinet inputs.  The board ports are active-low, as on SP-251.
	/* verilator lint_off UNUSEDSIGNAL */ // Fixed MiSTer input word; only board-wired controls are mapped below.
	input  logic [31:0] joystick,
	/* verilator lint_on UNUSEDSIGNAL */
	input  logic signed [7:0] analog_x,
	input  logic signed [7:0] analog_y,
	input  logic        analog_valid,
	input  logic        digital_left,
	input  logic        digital_right,
	input  logic        digital_up,
	input  logic        digital_down,
	input  logic        instant_digital,
	input  logic [7:0] dsw1,
	input  logic [7:0] dsw2,

	// Host persistence port for the X2212 nonvolatile array.  The shell may
	// leave this idle until MiSTer upload/download persistence is enabled.
	// Asserted by the shell while MiSTer is streaming the saved NVRAM image in.
	// The persistence path must keep running through it even though the game is
	// held in reset, otherwise the image is discarded.
	input  logic        nvram_download,
	input  logic        nvram_host_we,
	input  logic [7:0]  nvram_host_addr,
	input  logic [3:0]  nvram_host_din,
	output logic [3:0]  nvram_host_dout,
	input  logic        nvram_store,

	output logic        ce_pixel,
	output logic        hblank,
	output logic        vblank,
	output logic        hsync,
	output logic        vsync,
	output logic        frame_start,
	output logic [7:0]  red,
	output logic [7:0]  green,
	output logic [7:0]  blue,
	// Signed sample: irobot_audio_mix models the board's series AC coupling, so
	// the mix is centred on zero.  The shell must set AUDIO_S = 1.
	output logic signed [15:0] audio,

	// Cabinet start-button lamps (J20-G "LED1", J20-F "LED2").  Active high.
	// The MiSTer shell has no cabinet lamp conduit; these are brought out so a
	// harness or a future I/O board can observe them without inventing a use
	// for an unrelated framework pin.
	output logic        lamp_start1,
	output logic        lamp_start2,
	// Cabinet coin-counter drive levels (J20-H/J), active high.
	output logic        coin_counter_right,
	output logic        coin_counter_left,
	// Active-high 74LS90 watchdog reset, observation only.
	output logic        wdog_reset,


	// Read-only bring-up observables.  These are deliberately retained at the
	// integration boundary for the deterministic bus/debug harness.
	output logic [15:0] cpu_bus_addr,
	/* verilator lint_off UNOPTFLAT */ // MC6809 asynchronous board-read cone; sampled at the E-fall boundary.
	output logic [7:0]  cpu_bus_din,
	/* verilator lint_on UNOPTFLAT */
	output logic [7:0]  cpu_bus_dout,
	output logic [7:0]  cpu_bus_data,
	output logic        cpu_bus_rw,
	output logic        cpu_accepted,
	output logic [111:0] cpu_state,
	output logic        math_busy,
	output logic        video_busy,
	output logic        icy_malformed,
	// CPU-domain toggle emitted once for each accepted NVRAM write.  The
	// shell synchronizes this single-bit event before requesting persistence.
	output logic        nvram_write_toggle
);
	logic [7:0] in0, in1;
	logic [7:0] pokey_dout;
	logic       pokey_cs /* verilator public_flat_rd */, pokey_ce /* verilator public_flat_rd */;
	logic [5:0] pokey_addr /* verilator public_flat_rd */;
	logic [7:0] pokey_din /* verilator public_flat_rd */;
	logic [7:0] pokey_ch0 /* verilator public_flat_rd */, pokey_ch1 /* verilator public_flat_rd */;
	logic [7:0] pokey_ch2 /* verilator public_flat_rd */, pokey_ch3 /* verilator public_flat_rd */;
	logic signed [15:0] mix_audio /* verilator public_flat_rd */;

	// The HPS stream is emitted in clk_20m while the board ROMs are written in
	// clk_12m096. A direct pulse crossing can silently drop bytes. This small
	// Gray-pointer FIFO provides a real CDC boundary and back-pressure. The
	// loader runs while rom_download is asserted even though the game board is
	// held in reset; irobot_rom_router intentionally accepts writes in reset.
	localparam integer LD_AW = 3; // eight entries, 33-bit payload
	logic [24:0] ld_addr_mem [0:(1<<LD_AW)-1];
	logic [7:0]  ld_data_mem [0:(1<<LD_AW)-1];
	logic [LD_AW:0] ld_wr_bin, ld_wr_gray;
	logic [LD_AW:0] ld_rd_bin, ld_rd_gray;
	logic [LD_AW:0] ld_rd_gray_s1, ld_rd_gray_s2;
	logic [LD_AW:0] ld_wr_gray_s1, ld_wr_gray_s2;
	logic           ld_pending;
	logic [24:0]    ld_pending_addr;
	logic [7:0]     ld_pending_data;
	logic           ld_wr;
	logic [24:0]    ld_addr;
	logic [7:0]     ld_data;
	logic           loader_reset;
	logic           ld_full;
	logic           ld_empty;
	logic nvram_host_wait, nvram_we_cpu;
	logic [7:0] nvram_addr_cpu;
	logic [3:0] nvram_data_cpu;

	function automatic [LD_AW:0] bin2gray(input [LD_AW:0] b);
		bin2gray = (b >> 1) ^ b;
	endfunction
	assign loader_reset = reset && !rom_download;
	assign ld_full = (bin2gray(ld_wr_bin + {{LD_AW{1'b0}},1'b1}) ==
					 {~ld_rd_gray_s2[LD_AW:LD_AW-1],ld_rd_gray_s2[LD_AW-2:0]});
	assign ld_empty = (ld_rd_gray == ld_wr_gray_s2);
	// HPS samples this before issuing the next ioctl_wr pulse. The pending
	// register covers the one-cycle latency between a write and back-pressure.
	assign ioctl_wait = ld_pending || ld_full || nvram_host_wait;

	// Source (HPS) clock domain. A staged byte is committed once the
	// synchronized destination pointer shows space. A simultaneous next byte
	// is accepted when the previous one is committed.
	always_ff @(posedge clk_20m) begin
		if (loader_reset) begin
			ld_wr_bin        <= '0;
			ld_wr_gray       <= '0;
			ld_rd_gray_s1    <= '0;
			ld_rd_gray_s2    <= '0;
			ld_pending       <= 1'b0;
			ld_pending_addr  <= '0;
			ld_pending_data  <= '0;
		end else begin
			ld_rd_gray_s1 <= ld_rd_gray;
			ld_rd_gray_s2 <= ld_rd_gray_s1;
			if (ld_pending && !ld_full) begin
				ld_addr_mem[ld_wr_bin[LD_AW-1:0]] <= ld_pending_addr;
				ld_data_mem[ld_wr_bin[LD_AW-1:0]] <= ld_pending_data;
				ld_wr_bin  <= ld_wr_bin + {{LD_AW{1'b0}},1'b1};
				ld_wr_gray <= bin2gray(ld_wr_bin + {{LD_AW{1'b0}},1'b1});
				if (ioctl_wr) begin
					ld_pending_addr <= ioctl_addr;
					ld_pending_data <= ioctl_data;
					ld_pending      <= 1'b1;
				end else begin
					ld_pending      <= 1'b0;
				end
			end else if (ioctl_wr && !ld_pending) begin
				ld_pending_addr <= ioctl_addr;
				ld_pending_data <= ioctl_data;
				ld_pending      <= 1'b1;
			end
		end
	end

	// Destination (CPU) clock domain. Gray-pointer synchronization gives the
	// dual-clock storage two destination clocks to settle before consumption.
	always_ff @(posedge clk_12m096) begin
		if (loader_reset) begin
			ld_rd_bin     <= '0;
			ld_rd_gray    <= '0;
			ld_wr_gray_s1 <= '0;
			ld_wr_gray_s2 <= '0;
			ld_wr         <= 1'b0;
			ld_addr       <= '0;
			ld_data       <= '0;
		end else begin
			ld_wr_gray_s1 <= ld_wr_gray;
			ld_wr_gray_s2 <= ld_wr_gray_s1;
			ld_wr <= 1'b0;
			if (!ld_empty) begin
				ld_addr <= ld_addr_mem[ld_rd_bin[LD_AW-1:0]];
				ld_data <= ld_data_mem[ld_rd_bin[LD_AW-1:0]];
				ld_rd_bin  <= ld_rd_bin + {{LD_AW{1'b0}},1'b1};
				ld_rd_gray <= bin2gray(ld_rd_bin + {{LD_AW{1'b0}},1'b1});
				ld_wr <= 1'b1;
			end
		end
	end

	// The bridge carries the host image across to the CPU domain; keep it out
	// of reset for the duration of the transfer.
	wire persist_reset = reset && !nvram_download;
	irobot_nvram_write_cdc nvram_write_bridge (
		.src_clk(clk_20m), .dst_clk(clk_12m096), .reset(persist_reset),
		.src_we(nvram_host_we), .src_addr(nvram_host_addr), .src_data(nvram_host_din),
		.src_wait(nvram_host_wait), .dst_we(nvram_we_cpu),
		.dst_addr(nvram_addr_cpu), .dst_data(nvram_data_cpu)
	);

	// Standard MiSTer joystick bits are active high.  The original board
	// inputs are pulled high and assert low.  Keep the mapping explicit so an
	// input journal can reproduce the exact cabinet port bytes.
	always_comb begin
		in0 = 8'hff;
		in1 = 8'hff;
		// service, coin 3, coin 1, coin 2.
		// The MRA's <buttons> list starts at joystick bit 4: Fire 4, View 5,
		// Start 1P 6, Start 2P 7, Coin 1 8, Coin 2 9, Coin 3 10, Service 11.
		in0[4] = ~joystick[11];
		in0[5] = ~joystick[10];
		in0[6] = ~joystick[8];
		in0[7] = ~joystick[9];
		// button 1/2 and start 2/1.
		//
		// The program never reads IN1 bit 5.  Every mask it applies to its
		// debounced copy of this port ($15) and to the new-press edges ($13) is
		// $10 (Fire), $40/$80/$c0 (Start 2 / Start 1 / either) or their
		// complements; there is no $20 test anywhere in the 88 KB of program.
		// On the cabinet the viewing angle is changed with the Start button
		// during play, which is what those either-start tests are.  The OSD
		// "View" button (joystick bit 5) is therefore driven onto Start 1 as
		// well, so it does what a player expects; bit 5 stays connected for
		// port-byte parity with the reference input journals.
		in1[4] = ~joystick[4];
		in1[5] = ~joystick[5];
		in1[6] = ~joystick[7];
		in1[7] = ~(joystick[6] | joystick[5]);
	end

	logic [7:0] board_red, board_green, board_blue;
	// DIPs are written by the 20 MHz HPS/download domain while reset is held,
	// then read by the CPU/E domain.  Keep a CPU-domain snapshot so the 6809
	// never samples the bundled host byte directly on its generated E phase.
	logic [7:0] dsw1_meta, dsw1_cpu, dsw2_meta, dsw2_cpu;
	always_ff @(posedge clk_12m096) begin
		if (reset) begin
			dsw1_meta <= 8'hff;
			dsw1_cpu <= 8'hff;
			dsw2_meta <= 8'hff;
			dsw2_cpu <= 8'hff;
		end else begin
			dsw1_meta <= dsw1;
			dsw1_cpu <= dsw1_meta;
			dsw2_meta <= dsw2;
			dsw2_cpu <= dsw2_meta;
		end
	end

	// Board-level CPU/video/mathbox/ICY composition.  Quad-POKEY is kept as a
	// separate board peripheral so its bus/audio path remains observable in
	// the differential harness; the Verilator lane uses pokey_sv, the
	// SystemVerilog translation of the audited donor.
	irobot_board board (
		.clk_12m096(clk_12m096), .clk_20m(clk_20m), .reset(reset),
		.rom_download(rom_download), .ioctl_wr(ld_wr), .ioctl_addr(ld_addr), .ioctl_data(ld_data),
		.in0(in0), .in1(in1), .dsw1(dsw1_cpu), .stick_x(analog_x), .stick_y(analog_y),
		.controls_analog_valid(analog_valid), .controls_left(digital_left),
		.controls_right(digital_right), .controls_up(digital_up), .controls_down(digital_down),
		.controls_instant_digital(instant_digital),
		.pokey_dout(pokey_dout), .pokey_cs(pokey_cs),
		/* verilator lint_off PINCONNECTEMPTY */
		.pokey_we(),
		/* verilator lint_on PINCONNECTEMPTY */
		.pokey_ce(pokey_ce),
		.pokey_addr(pokey_addr), .pokey_din(pokey_din), .nvram_host_we(nvram_we_cpu),
		.nvram_host_addr(nvram_we_cpu ? nvram_addr_cpu : nvram_host_addr), .nvram_host_din(nvram_data_cpu),
		.nvram_host_dout(nvram_host_dout), .nvram_store(nvram_store), .rom_loaded(rom_loaded),
		.ce_pixel(ce_pixel), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
		.frame_start(frame_start),
		.red(board_red), .green(board_green), .blue(board_blue), .cpu_bus_addr(cpu_bus_addr),
		.cpu_bus_din(cpu_bus_din), .cpu_bus_dout(cpu_bus_dout), .cpu_bus_rw(cpu_bus_rw),
		.cpu_accepted(cpu_accepted), .cpu_state(cpu_state), .math_busy(math_busy),
		.video_busy(video_busy), .icy_malformed(icy_malformed),
		.lamp_start1(lamp_start1), .lamp_start2(lamp_start2),
		.coin_counter_right(coin_counter_right), .coin_counter_left(coin_counter_left),
		.wdog_reset(wdog_reset)
	);

	// NVRAM dirty detection belongs to the CPU master-clock domain.  Export a
	// toggle rather than the raw E-domain bus/address, so the shell can safely
	// observe the event from clk_20m without timing a wide asynchronous bus.
	always_ff @(posedge clk_12m096) begin
		if(reset || !rom_loaded)
			nvram_write_toggle <= 1'b0;
		else if(cpu_accepted && !cpu_bus_rw && (cpu_bus_addr[15:8] == 8'h12))
			nvram_write_toggle <= ~nvram_write_toggle;
	end

	// Four C012294 devices are physically summed on the CPU board.  The
	// board's RnW signal is already active-high for reads, matching POKEY's
	// RW_L naming convention (low during writes).
	quad_pokey pokeys (
		.clk(clk_12m096),
		.reset(reset),
		.ena(pokey_ce),
		.cs(pokey_cs),
		.rw(cpu_bus_rw),
		.addr(pokey_addr),
		.din(pokey_din),
		.allpot0(dsw2_cpu),
		.dout(pokey_dout),
		.pin0(8'hff),
		.pin1(8'hff),
		.pin2(8'hff),
		.pin3(8'hff),
		/* verilator lint_off PINCONNECTEMPTY */
		.audio(),
		/* verilator lint_on PINCONNECTEMPTY */
		.ch0(pokey_ch0), .ch1(pokey_ch1), .ch2(pokey_ch2), .ch3(pokey_ch3)
	);

	// SP-251 sheet 4A analog output stage: 1:1:1:1 strap, C9/R19 low pass and
	// C8/R24 series AC coupling.  pokey_ce is the CI/O phi2 (CLKE) enable that
	// already clocks the POKEYs, which is the rate irobot_audio_mix expects.
	irobot_audio_mix u_audio_mix (
		.clk(clk_12m096),
		.reset(reset),
		.ena(pokey_ce),
		.ch0(pokey_ch0), .ch1(pokey_ch1), .ch2(pokey_ch2), .ch3(pokey_ch3),
		.audio(mix_audio)
	);

	assign red   = board_red;
	assign green = board_green;
	assign blue  = board_blue;
	// Canonical accepted-transaction payload for the differential contract:
	// reads expose the returned byte and writes expose the driven byte.
	assign cpu_bus_data = cpu_bus_rw ? cpu_bus_din : cpu_bus_dout;
	// The board's analog stage is AC coupled, so the delivered sample is signed
	// and centred on zero.
	assign audio = mix_audio;
endmodule
