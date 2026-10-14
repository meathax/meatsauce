`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Atari I, Robot CPU/video board composition. The two independent oscillator
// domains are explicit at this boundary, matching SP-251 sheets 3B and 7A.
module irobot_board (
	input logic clk_12m096,input logic clk_20m,input logic reset,input logic rom_download,
	input logic ioctl_wr,input logic[24:0]ioctl_addr,input logic[7:0]ioctl_data,
	input logic[7:0]in0,in1,dsw1,input logic[7:0]stick_x,stick_y,
	input logic controls_analog_valid,controls_left,controls_right,controls_up,controls_down,
	input logic controls_instant_digital,
	input logic[7:0]pokey_dout,
	output logic pokey_cs,output logic pokey_we,output logic pokey_ce,
	output logic[5:0]pokey_addr,output logic[7:0]pokey_din,
	input logic nvram_host_we,input logic[7:0]nvram_host_addr,input logic[3:0]nvram_host_din,
	output logic[3:0]nvram_host_dout,input logic nvram_store,
	output logic rom_loaded,output logic ce_pixel,output logic hblank,vblank,hsync,vsync,frame_start,
	output logic[7:0]red,green,blue,
	output logic[15:0]cpu_bus_addr,output logic[7:0]cpu_bus_din,cpu_bus_dout,
	output logic cpu_bus_rw,output logic cpu_accepted,output logic[111:0]cpu_state,
	output logic math_busy,output logic video_busy,output logic icy_malformed,
	// SP-251 sheet 3A LS273 10L bits 4/5 -> sheet 3B Q2/Q5 2N3904 drivers ->
	// J20-G "LED1" and J20-F "LED2".  MAME rom_banksel_w m_leds[0]/m_leds[1].
	// Active high at the latch; the cabinet lamp is on when the bit is set.
	output logic lamp_start1,output logic lamp_start2,
	// SP-251 sheet 3B LS273 10L bits 6/7 -> Q3/Q4 2N3904 drivers ->
	// J20-H "COUNTER R" and J20-J "COUNTER L". Active high at the latch.
	output logic coin_counter_right,output logic coin_counter_left,
	// Active-high CPU-board watchdog reset (74LS90 7A QD).
	output logic wdog_reset
);
	logic cpu_rom_we,object_we,alpha_char_we,alpha_prom_we,micro_we;
	logic[16:0]cpu_rom_addr;logic[15:0]object_addr;logic[10:0]alpha_char_addr;
	logic[4:0]alpha_prom_addr;logic[9:0]micro_addr;logic[3:0]micro_plane,micro_nibble;
	logic[7:0]cpu_rom_data,object_data,alpha_char_data,alpha_prom_data;
	irobot_rom_router router(clk_12m096,reset,rom_download,ioctl_wr,ioctl_addr,ioctl_data,
		cpu_rom_we,cpu_rom_addr,cpu_rom_data,object_we,object_addr,object_data,
		alpha_char_we,alpha_char_addr,alpha_char_data,alpha_prom_we,alpha_prom_addr,
		alpha_prom_data,micro_we,micro_addr,micro_plane,micro_nibble,rom_loaded);

	logic[8:0]hcount;logic[7:0]vcount;logic vblank_status;logic line_toggle;
	// SP-251 7A raster counters are in the independent video oscillator domain
	// and have no board-reset connection; keep them running across every CPU
	// and loader reset while the CPU-domain CDC state below reacquires them.
	logic hblank_raster,vblank_raster,hsync_raster,vsync_raster;
	irobot_timing timing(.clk_20m(clk_20m),.ce_pixel(ce_pixel),.hcount(hcount),.vcount(vcount),
		.hblank(hblank_raster),.vblank(vblank_status),.hsync(hsync_raster),.vsync(vsync_raster),.frame_start(frame_start),
		.display_blank(vblank_raster),.line_toggle(line_toggle));
	// The video pipeline registers red/green/blue on ce_pixel, so a dot's colour
	// is presented during the following dot period.  Blanking and sync must go
	// through the same one-dot register stage or the output window opens one
	// dot before the first pixel and closes one dot before the last.  That is
	// what the MiSTer showed on the self-test crosshatch: the picture sat one
	// dot to the right, column 0 was black and the right-edge line at dot 255
	// was cut off, while the rows (0, 115/116, 231) were exact.  The raster
	// counters, IRQ, watchdog and status bits keep the undelayed signals.
	initial begin hblank=1'b1;vblank=1'b1;hsync=1'b0;vsync=1'b0;end
	always @(posedge clk_20m) if(ce_pixel) begin
		hblank<=hblank_raster;vblank<=vblank_raster;hsync<=hsync_raster;vsync<=vsync_raster;
	end
	// Bundled-data controls CDC. The source samples during the final scanline
	// and holds the payload through the following line-0 control update.
	logic line_toggle_video_d,controls_toggle_video;
	logic signed [7:0] controls_x_video,controls_y_video;
	logic controls_valid_video,controls_left_video,controls_right_video;
	logic controls_up_video,controls_down_video,controls_instant_video;
	// The CPU input ports are a separate bundled CDC payload.  They are
	// captured when the source-domain values change and held until the CPU
	// domain acknowledges the synchronized toggle.
	logic [7:0] in0_video,in1_video;
	logic input_toggle_video;
	always_ff @(posedge clk_20m) begin
		if(reset) begin
			line_toggle_video_d<=0;controls_toggle_video<=0;
			controls_x_video<=8'sd0;controls_y_video<=8'sd0;
			controls_valid_video<=0;controls_left_video<=0;controls_right_video<=0;
			controls_up_video<=0;controls_down_video<=0;controls_instant_video<=0;
			in0_video<=8'hff;in1_video<=8'hff;input_toggle_video<=0;
		end else begin
			line_toggle_video_d<=line_toggle;
			if((line_toggle!=line_toggle_video_d)&&(vcount==8'hff)) begin
				controls_toggle_video<=~controls_toggle_video;
				controls_x_video<=stick_x;controls_y_video<=stick_y;
				controls_valid_video<=controls_analog_valid;
				controls_left_video<=controls_left;controls_right_video<=controls_right;
				controls_up_video<=controls_up;controls_down_video<=controls_down;
				controls_instant_video<=controls_instant_digital;
			end
			// in0/in1 originate in this same video clock domain at the shell
			// boundary.  A change event plus a held payload gives the CPU a
			// coherent snapshot without timing the raw joystick bus into E.
			if((in0!=in0_video)||(in1!=in1_video)) begin
				in0_video<=in0;in1_video<=in1;
				input_toggle_video<=~input_toggle_video;
			end
		end
	end
	logic line_meta,line_synced,line_previous;
	logic[7:0]vmeta,vsynced;logic vbmeta,vbsynced;
	logic scanline_start /* verilator public_flat_rd */,control_update;
	always_ff @(posedge clk_12m096)begin
		if(reset) begin
			line_meta<=0;line_synced<=0;line_previous<=0;
			vmeta<=0;vsynced<=0;vbmeta<=0;vbsynced<=0;
		end else begin
			// Bundled-data CDC. The line toggle takes two CPU clocks to
			// settle; vcount is captured in parallel and stable for the
			// complete line, so vsynced is coherent when the event arrives.
			line_meta<=line_toggle;line_synced<=line_meta;line_previous<=line_synced;
			vmeta<=vcount;vsynced<=vmeta;vbmeta<=vblank_status;vbsynced<=vbmeta;
		end
	end
	assign scanline_start=(line_synced!=line_previous);
	assign control_update=scanline_start&&(vsynced==0);
	logic controls_toggle_meta,controls_toggle_sync,controls_toggle_cpu;
	logic input_toggle_meta,input_toggle_sync,input_toggle_cpu;
	logic [7:0] in0_meta,in0_sync,in0_cpu,in1_meta,in1_sync,in1_cpu;
	logic signed [7:0] controls_x_meta,controls_x_sync,controls_x_cpu,controls_y_meta,controls_y_sync,controls_y_cpu;
	logic controls_valid_meta,controls_valid_sync,controls_valid_cpu,controls_left_meta,controls_left_sync,controls_left_cpu;
	logic controls_right_meta,controls_right_sync,controls_right_cpu,controls_up_meta,controls_up_sync,controls_up_cpu;
	logic controls_down_meta,controls_down_sync,controls_down_cpu,controls_instant_meta,controls_instant_sync,controls_instant_cpu;
	always_ff @(posedge clk_12m096) begin
		if(reset) begin
			controls_toggle_meta<=0;controls_toggle_sync<=0;controls_toggle_cpu<=0;
			input_toggle_meta<=0;input_toggle_sync<=0;input_toggle_cpu<=0;
			in0_meta<=8'hff;in0_sync<=8'hff;in0_cpu<=8'hff;
			in1_meta<=8'hff;in1_sync<=8'hff;in1_cpu<=8'hff;
			controls_x_meta<=0;controls_x_sync<=0;controls_x_cpu<=0;controls_y_meta<=0;controls_y_sync<=0;controls_y_cpu<=0;
			controls_valid_meta<=0;controls_valid_sync<=0;controls_valid_cpu<=0;
			controls_left_meta<=0;controls_left_sync<=0;controls_left_cpu<=0;controls_right_meta<=0;controls_right_sync<=0;controls_right_cpu<=0;
			controls_up_meta<=0;controls_up_sync<=0;controls_up_cpu<=0;controls_down_meta<=0;controls_down_sync<=0;controls_down_cpu<=0;
			controls_instant_meta<=0;controls_instant_sync<=0;controls_instant_cpu<=0;
		end else begin
			controls_toggle_meta<=controls_toggle_video;controls_toggle_sync<=controls_toggle_meta;
			input_toggle_meta<=input_toggle_video;input_toggle_sync<=input_toggle_meta;
			in0_meta<=in0_video;in0_sync<=in0_meta;
			in1_meta<=in1_video;in1_sync<=in1_meta;
			controls_x_meta<=controls_x_video;controls_x_sync<=controls_x_meta;
			controls_y_meta<=controls_y_video;controls_y_sync<=controls_y_meta;
			controls_valid_meta<=controls_valid_video;controls_valid_sync<=controls_valid_meta;
			controls_left_meta<=controls_left_video;controls_left_sync<=controls_left_meta;
			controls_right_meta<=controls_right_video;controls_right_sync<=controls_right_meta;
			controls_up_meta<=controls_up_video;controls_up_sync<=controls_up_meta;
			controls_down_meta<=controls_down_video;controls_down_sync<=controls_down_meta;
			controls_instant_meta<=controls_instant_video;controls_instant_sync<=controls_instant_meta;
			if(controls_toggle_sync!=controls_toggle_cpu) begin
				controls_toggle_cpu<=controls_toggle_sync;
				controls_x_cpu<=controls_x_sync;controls_y_cpu<=controls_y_sync;
				controls_valid_cpu<=controls_valid_sync;
				controls_left_cpu<=controls_left_sync;controls_right_cpu<=controls_right_sync;
				controls_up_cpu<=controls_up_sync;controls_down_cpu<=controls_down_sync;
				controls_instant_cpu<=controls_instant_sync;
			end
			if(input_toggle_sync!=input_toggle_cpu) begin
				input_toggle_cpu<=input_toggle_sync;
				in0_cpu<=in0_sync;in1_cpu<=in1_sync;
			end
		end
	end

	logic[7:0]control_x,control_y;
	irobot_controls controls(clk_12m096,reset,control_update,controls_x_cpu,controls_y_cpu,
		controls_valid_cpu,controls_left_cpu,controls_right_cpu,controls_up_cpu,controls_down_cpu,
		controls_instant_cpu,control_x,control_y);

	logic irq_n,firq_n,irq_clear,firq_clear,math_done;
	irobot_interrupts interrupts(clk_12m096,reset,scanline_start,vsynced,irq_clear,math_done,firq_clear,irq_n,firq_n);

	logic nvram_cs,nvram_we,adc_start,shared_cs,palette_we,alpha_we;
	logic [9:0] alpha_cpu_addr;
	logic [7:0] alpha_cpu_data,alpha_cpu_dout;
	logic[1:0]adc_channel;
	/* verilator lint_off UNUSEDSIGNAL */ // Raw STATWR level bits 5/4/2 retain the physical latch state after dedicated cocktail/start outputs consume their functions.
	logic[7:0]statwr;
	/* verilator lint_on UNUSEDSIGNAL */
	/* verilator lint_off UNUSEDSIGNAL */ // OUT0 RAM-bank bits are consumed inside irobot_mainboard; bit 0 has no documented board consumer.
	logic[7:0]out0;
	/* verilator lint_on UNUSEDSIGNAL */
	/* verilator lint_off UNUSEDSIGNAL */ // OUT1 ROM-bank bits are consumed inside irobot_mainboard; bit 0 has no documented board consumer.
	logic[7:0]bankctl;
	/* verilator lint_on UNUSEDSIGNAL */
	logic[7:0]nvram_data,adc_data;
	logic math_start,video_start,wdclr;
	// SP-251 sheet 3A: LS90 7A QD is a board-wide /RESET.  It is held asserted
	// while the ROM image is still being downloaded (the CPU is not running, so
	// nothing can pet it), therefore the fired output is gated with rom_loaded so
	// a download can never be interrupted by it.  The counter cannot deadlock:
	// its R9 set-to-9 input is the power-on reset only, and the BCD decade wraps
	// from 9 back to 0 two counts after firing, which releases QD by itself.
	logic wdog_fire;
	irobot_watchdog wdog(.clk(clk_12m096),.reset(reset|!rom_loaded),.wdclr(wdclr),
		.tick_128v(vsynced[7]),.reset_out(wdog_fire));
	assign wdog_reset=wdog_fire&&rom_loaded&&!reset;
	irobot_cpu_board cpu_board(clk_12m096,reset|!rom_loaded|wdog_reset,irq_n,firq_n,cpu_rom_we,cpu_rom_addr,cpu_rom_data,
		in0_cpu,in1_cpu,dsw1,math_busy,video_busy,vbsynced,nvram_data,adc_data,pokey_dout,shared_dout,alpha_cpu_dout,
		cpu_accepted,cpu_bus_addr,cpu_bus_din,cpu_bus_dout,cpu_bus_rw,cpu_state,nvram_cs,adc_start,
		pokey_cs,shared_cs,nvram_we,pokey_we,palette_we,alpha_we,alpha_cpu_addr,alpha_cpu_data,adc_channel,
		statwr,out0,bankctl,math_start,video_start,irq_clear,firq_clear,wdclr);
	assign pokey_addr=cpu_bus_addr[5:0];assign pokey_din=cpu_bus_dout;
	// LS273 10L bit 4 = LED1 (start 1), bit 5 = LED2 (start 2).
	assign lamp_start1=bankctl[4];assign lamp_start2=bankctl[5];
	// Preserve the raw software-controlled levels; the PCB has no one-shot or
	// other pulse shaping between this latch and the counter drivers.
	assign coin_counter_right=bankctl[6];assign coin_counter_left=bankctl[7];

	// nvram_store originates in the host/video clock domain; give it a real
	// two-flop synchroniser before the X2212 edge detector sees it.
	logic nvstore_meta,nvstore_sync;
	always_ff @(posedge clk_12m096)begin
		if(reset)begin nvstore_meta<=0;nvstore_sync<=0;end
		else begin nvstore_meta<=nvram_store;nvstore_sync<=nvstore_meta;end
	end

	/* verilator lint_off UNUSEDSIGNAL */ // Device-boundary observables; board-level consumers are unproven.
	logic adc_eoc,adc_busy,nvram_busy;
	/* verilator lint_on UNUSEDSIGNAL */
	irobot_peripherals peripherals(clk_12m096,reset,nvram_cs,nvram_we,cpu_bus_addr[7:0],cpu_bus_dout[3:0],
		adc_start,adc_channel,control_x,control_y,~statwr[6],nvstore_sync,nvram_host_we,nvram_host_addr,
		nvram_host_din,nvram_host_dout,nvram_data,adc_data,adc_eoc,adc_busy,nvram_busy,pokey_ce);

	logic[15:0]object_byte_addr;logic comm_cpu_req,comm_cpu_we,math_cpu_we;
	logic[11:0]comm_cpu_addr;logic[12:0]math_cpu_addr;logic[7:0]comm_cpu_din,math_cpu_din;
	logic[7:0]shared_dout,comm_cpu_dout,math_cpu_dout,object_cpu_dout;
	irobot_shared_window window(shared_cs,cpu_bus_rw,cpu_bus_addr[12:0],cpu_bus_dout,out0[4:3],out0[2:1],
		object_cpu_dout,comm_cpu_dout,math_cpu_dout,shared_dout,object_byte_addr,
		comm_cpu_req,comm_cpu_we,comm_cpu_addr,comm_cpu_din,math_cpu_we,math_cpu_addr,math_cpu_din);
	always_ff @(posedge clk_12m096) begin
		if(!reset) assert(!shared_cs || !statwr[3]);
	end

	logic math_comm_we;logic[10:0]math_comm_addr;logic[15:0]math_comm_dout;
	/* verilator lint_off UNUSEDSIGNAL */ // Mathbox trace/state observables retained for focused diagnostics.
	logic[15:0]math_y /* verilator public_flat_rd */,math_latch;logic[9:0]math_pc;logic[7:0]math_flags;
	logic math_trace_read,math_trace_write;logic[11:0]math_slices;
	/* verilator lint_on UNUSEDSIGNAL */
	irobot_mathbox_system mathbox(clk_12m096,reset|!rom_loaded,math_start,micro_we,micro_addr,micro_plane,
		micro_nibble,object_we,object_addr,object_data,
		math_busy,math_done,math_pc,math_y,math_comm_we,math_comm_addr,math_comm_dout,math_latch,
		math_flags,math_trace_read,math_trace_write,math_slices,math_cpu_we,math_cpu_addr,math_cpu_din,
		math_cpu_dout,object_byte_addr,object_cpu_dout);

	logic icy_mem_req,icy_mem_ack;logic[10:0]icy_mem_addr;logic[15:0]icy_mem_data;
	/* verilator lint_off UNUSEDSIGNAL */ // Composed-memory response monitor retained for diagnostics.
	logic comm_cpu_ack;
	/* verilator lint_on UNUSEDSIGNAL */
	logic icy_video_bank;
	irobot_commram commram(clk_12m096,reset,statwr[7],icy_video_bank,comm_cpu_req,comm_cpu_we,comm_cpu_addr,
		comm_cpu_din,comm_cpu_ack,comm_cpu_dout,icy_mem_req,icy_mem_addr,icy_mem_ack,icy_mem_data,
		math_comm_we,math_comm_addr,math_comm_dout);
	/* verilator lint_off UNUSEDSIGNAL */ // ICY completion monitor retained for diagnostics.
	logic icy_done;
	/* verilator lint_on UNUSEDSIGNAL */
	logic icy_fb_we;logic[15:0]icy_fb_addr;logic[6:0]icy_fb_data;
	logic statwr_clear_d,clear_start,draw_bank;
	/* verilator lint_off UNUSEDSIGNAL */ // Framebuffer status and pixel probes remain available to focused tests.
	logic display_bank,detail_pixel,clear_busy,clear_done,draw_ready;
	/* verilator lint_on UNUSEDSIGNAL */
	// STATWR can set the clear bit and a VG start in the same write, and the
	// clear (irobot_framebuffers) takes 65,536 draw clocks during which
	// effective_we forces the clear pattern and silently discards any ICY
	// pixel write. icy.sv has no back-pressure input, so a start issued
	// while a clear is in effect is latched here and released the cycle the
	// clear drops; video_busy is reported as busy meanwhile (pending OR the
	// engine's own busy) so the CPU's STATRD poll sees the generator busy
	// across the whole clear, matching MAME's atomic bufsel/clear/start
	// ordering in statwr_w.
	//
	// clear_start and video_start become active in the SAME cycle (both are
	// registered off the same STATWR write), but irobot_framebuffers'
	// clear_busy output only rises a cycle later, once it has registered
	// clear_start itself. Gating on clear_busy alone leaves a one-cycle gap
	// where a coincident video_start would still slip icy_start through
	// before the clear actually starts, so clear_start is ORed in here too.
	//
	// A start that arrives while the ENGINE is still drawing is deferred the
	// same way, and the communication bank is frozen for the duration of a
	// run: in gameplay the game issues two starts on alternating banks about
	// 6500 clk_12m096 clocks apart, far less than one run takes, so without
	// both the second display list was dropped outright and the first run
	// finished reading the wrong bank.  See rtl/video/icy_run_control.sv.
	logic icy_busy,icy_start;
	wire clear_active = clear_busy | clear_start;
	icy_run_control run_control(clk_12m096,reset,video_start,statwr[7],clear_active,
		icy_busy,icy_start,video_busy,icy_video_bank);
	icy icy_engine(clk_12m096,reset,icy_start,icy_mem_req,icy_mem_addr,icy_mem_ack,icy_mem_data,
		icy_busy,icy_done,icy_malformed,icy_fb_we,icy_fb_addr,icy_fb_data);

	always_ff @(posedge clk_12m096)begin
		if(reset)statwr_clear_d<=0;else statwr_clear_d<=statwr[0];
	end
	assign clear_start=statwr[0]&~statwr_clear_d;
	irobot_video_pipeline video(clk_12m096,clk_20m,reset,ce_pixel,hcount,vcount,
		icy_fb_we,icy_fb_addr,icy_fb_data,statwr[1]^draw_bank,clear_start,
		palette_we,cpu_bus_rw,cpu_bus_addr,cpu_bus_dout,alpha_we,alpha_cpu_addr,alpha_cpu_data,alpha_cpu_dout,
		alpha_char_we,alpha_char_addr,alpha_char_data,alpha_prom_we,alpha_prom_addr,alpha_prom_data,
		out0[7],statwr[5],red,green,blue,clear_busy,clear_done,draw_ready,draw_bank,display_bank,detail_pixel);
endmodule
