// Penguin Brothers derivative of staged Guardians gd_cpu_subsystem.
// Upstream MiSTer-devel/Arcade-Guardians_MiSTer:
// 43bb986da05aa19adb06ac575cfcc8af5c003fb7; staged SHA256 follows.
// Donor SHA256: e8b5ce23dcc75f5b6fdd25a7ba7dc0186308234c181fbb7c6f7b709674a1d7b3
// Changes: exact rational clock enables; unpatched 1 MiB ROM; five RAM windows;
// Penguin device/input map; no scrub, cheat, turbo or fast-boot override.
// SPDX-License-Identifier: GPL-3.0-or-later

module penguin_cpu_subsystem #(
    parameter integer SYS_HZ = 50000000,
    parameter integer EXTERNAL_WORK_RAM = 0
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        pause,
	input  logic        vblank,
	input  logic        raster_irq,
	input  logic [15:0] dip_switches,
	input  logic [31:0] joystick_p1,
	input  logic [31:0] joystick_p2,
	input  logic        service,
	input  logic        turbo,
	input  logic        cheat_reset,
	input  logic [128:0] cheat_code,

	output logic [20:0] rom_addr,
	output logic        rom_req,
	input  logic [15:0] rom_dout,
	input  logic        rom_ack,
	output logic [17:0] ram_addr, // WORD address: five contiguous 64 KiB banks
	output logic        ram_req,
	output logic        ram_write,
	output logic [15:0] ram_data,
	output logic  [1:0] ram_be,
	input  logic [15:0] ram_dout,
	input  logic        ram_ack,

	input  logic [16:0] sprite_video_address,
	output logic [63:0] sprite_video_q,
	output logic [15:0] sprite_video_seed_q,
	input  logic [14:0] palette_video_address,
	output logic [15:0] palette_video_q,
	input  logic  [4:0] video_reg_address,
	output logic [15:0] video_reg_q,
	output logic [15:0] video_control,
	output logic [26:0] video_x_offset,
	output logic [26:0] video_x_zoom,
	output logic video_x_half_mode, video_x_fractional_mode,
	output logic [26:0] video_y_offset,
	output logic [26:0] video_y_zoom,
	output logic        sprite_buffer_busy,
	output logic [15:0] raster_enable,
	output logic [15:0] raster_position,
	output logic        raster_rearm,
	output logic        rowscroll_write,
	output logic [16:0] rowscroll_write_address,
	output logic [15:0] rowscroll_write_data,
	output logic  [1:0] rowscroll_write_byte_enable,

	output logic        x1_write,
	output logic [12:0] x1_address,
	output logic [15:0] x1_data,
	output logic  [1:0] x1_byte_enable,
	input  logic [15:0] x1_q,

	output logic [63:0] sample_banks,
	output logic [23:0] debug_address,
	output logic [31:0] debug_bus_cycles,
	output logic [31:0] debug_rom_cycles,
	output logic [15:0] debug_unmapped_cycles,
	output logic        cpu_running
);

// 50 MHz /3 CPU cycles and two ordered phases per CPU cycle.
// Integer rational accumulators are exact over a 3*SYS_HZ denominator.
// Stored remainder <3*SYS_HZ; the largest temporary sum is below that
// denominator +100,000,000. Keep constants at the same bounded width.
localparam integer CLOCK_ACC_WIDTH = $clog2(64'(SYS_HZ) * 3 + 64'd100000001);
localparam logic [CLOCK_ACC_WIDTH-1:0] CLOCK_DENOMINATOR = CLOCK_ACC_WIDTH'(SYS_HZ) * CLOCK_ACC_WIDTH'(3);
localparam logic [CLOCK_ACC_WIDTH-1:0] PHASE_INCREMENT = CLOCK_ACC_WIDTH'(100000000);
localparam logic [CLOCK_ACC_WIDTH-1:0] TIMER_INCREMENT = CLOCK_ACC_WIDTH'(50000000);
logic [CLOCK_ACC_WIDTH-1:0] phase_accumulator, timer_accumulator;
logic cpu_half_phase, cpu_phi1, cpu_phi2, timer_cpu_ce;
wire system_reset = reset;
always_ff @(posedge clk) begin
    cpu_phi1 <= 0; cpu_phi2 <= 0; timer_cpu_ce <= 0;
    if (reset) begin
        phase_accumulator <= 0; timer_accumulator <= 0; cpu_half_phase <= 0;
    end else if (!pause) begin
        if (timer_accumulator + TIMER_INCREMENT >= CLOCK_DENOMINATOR) begin
            timer_accumulator <= timer_accumulator + TIMER_INCREMENT - CLOCK_DENOMINATOR;
            timer_cpu_ce <= 1;
        end else timer_accumulator <= timer_accumulator + TIMER_INCREMENT;
        // The approximate DX-101 copy engine borrows the CPU-side sprite port.
        // Retain phase order when it is busy; do not emit an orphan phi2.
        if (!sprite_buffer_busy) begin
            if (phase_accumulator + PHASE_INCREMENT >= CLOCK_DENOMINATOR) begin
                phase_accumulator <= phase_accumulator + PHASE_INCREMENT - CLOCK_DENOMINATOR;
                if (cpu_half_phase) cpu_phi2 <= 1; else cpu_phi1 <= 1;
                cpu_half_phase <= ~cpu_half_phase;
            end else phase_accumulator <= phase_accumulator + PHASE_INCREMENT;
        end
    end
end

wire        cpu_rw;
wire        cpu_as_n;
wire        cpu_lds_n;
wire        cpu_uds_n;
wire  [2:0] cpu_fc;
wire [15:0] cpu_data_out;
logic [15:0] cpu_data_in;
wire [23:1] cpu_word_addr;
logic        cpu_dtack_n;
wire [23:0] cpu_even_address = {cpu_word_addr, 1'b0};
wire [23:0] cpu_bus_address = {cpu_word_addr,
	(!cpu_lds_n && cpu_uds_n)};
wire [1:0] cpu_byte_enable = {~cpu_uds_n, ~cpu_lds_n};
wire cpu_data_strobe = !cpu_uds_n || !cpu_lds_n;
wire cpu_iack_cycle = !cpu_as_n && (&cpu_fc);

logic [2:0] tmp_irq_level;
logic [7:0] tmp_irq_vector;
wire [2:0] cpu_ipl_n = ~tmp_irq_level;
wire tmp_iack;

fx68k main_cpu
(
	.clk(clk), .HALTn(1'b1), .extReset(system_reset), .pwrUp(system_reset),
	.enPhi1(cpu_phi1), .enPhi2(cpu_phi2),
	.eRWn(cpu_rw), .ASn(cpu_as_n), .LDSn(cpu_lds_n), .UDSn(cpu_uds_n),
	.E(), .VMAn(), .FC0(cpu_fc[0]), .FC1(cpu_fc[1]), .FC2(cpu_fc[2]),
	.BGn(), .oRESETn(), .oHALTEDn(), .DTACKn(cpu_dtack_n),
	.VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
	.IPL0n(cpu_ipl_n[0]), .IPL1n(cpu_ipl_n[1]),
	.IPL2n(cpu_ipl_n[2]), .iEdb(cpu_data_in),
	.oEdb(cpu_data_out), .eab(cpu_word_addr)
);

logic cpu_data_strobe_seen;
always_ff @(posedge clk) begin
	if (system_reset || cpu_as_n) cpu_data_strobe_seen <= 1'b0;
	else if (cpu_data_strobe) cpu_data_strobe_seen <= 1'b1;
end

wire cs_program = (cpu_even_address <= 24'h0ffffe);
wire cs_work = cpu_even_address >= 24'h200000 && cpu_even_address <= 24'h23fffe;
wire cs_aux = cpu_even_address >= 24'h300000 && cpu_even_address <= 24'h30fffe;
wire cs_dsw1 = cpu_even_address == 24'h500300;
wire cs_dsw2 = cpu_even_address == 24'h500302;
wire cs_p1 = cpu_even_address == 24'h600000;
wire cs_p2 = cpu_even_address == 24'h600002;
wire cs_system = cpu_even_address == 24'h600004;
wire cs_watchdog = cpu_even_address == 24'h600006;
wire cs_coin = cs_system && !cpu_rw && cpu_byte_enable[0];
wire cs_x1 = cpu_even_address >= 24'ha00000 && cpu_even_address <= 24'ha03ffe;
wire cs_sprite = cpu_even_address >= 24'hb00000 && cpu_even_address <= 24'hb3fffe;
wire cs_palette = cpu_even_address >= 24'hb40000 && cpu_even_address <= 24'hb4fffe;
wire cs_video_regs = cpu_even_address >= 24'hb60000 && cpu_even_address <= 24'hb6003e;
wire cs_sample_bank = !cpu_rw && cpu_even_address >= 24'h500300 && cpu_even_address <= 24'h50030e;
wire cs_tmp = cpu_even_address >= 24'hfffc00;
wire mapped_cycle = cs_program || cs_work || cs_aux || cs_dsw1 || cs_dsw2
    || cs_p1 || cs_p2 || cs_system || cs_watchdog || cs_coin || cs_x1
    || cs_sprite || cs_palette || cs_video_regs || cs_sample_bank || cs_tmp;

typedef enum logic [2:0] {
	BUS_IDLE, BUS_ROM_WAIT, BUS_RAM_WAIT, BUS_ACK, BUS_TMP_DECODE, BUS_TMP_DATA
} bus_state_t;
bus_state_t bus_state;

// TMP68301 accesses are registered once and performed one bus state later, so
// the CPU address never reaches the 16-bit TMP read mux in the same clock.
logic [9:0]  tmp_addr_q;
logic [15:0] tmp_data_q;
logic [1:0]  tmp_be_q;
logic        tmp_write_q;
logic [15:0] tmp_rd_data;
wire         tmp_access = (bus_state == BUS_TMP_DECODE);

// Acknowledge the source on the same edge that captures its vector. A
// registered pulse can instead retire a newly arrived higher-priority IRQ.
assign tmp_iack = !system_reset && (bus_state == BUS_IDLE) && !cpu_as_n
    && cpu_data_strobe && cpu_data_strobe_seen && cpu_iack_cycle;

wire local_write = !cpu_as_n && !cpu_iack_cycle && cpu_data_strobe
	&& cpu_data_strobe_seen && !cpu_rw && (bus_state == BUS_IDLE);

always_comb begin
	rowscroll_write = local_write && cs_sprite;
	rowscroll_write_address = cpu_even_address[17:1];
	rowscroll_write_data = cpu_data_out;
	rowscroll_write_byte_enable = cpu_byte_enable;
end

// Five independent 64 KiB windows. No power-on scrub: the original CPU
// executes its real RAM self-test. External mode omits all internal work RAM.
wire [2:0] state_bank = cs_aux ? 3'd4 : {1'b0,cpu_even_address[17:16]};
logic [15:0] state_q;
`ifndef SYNTHESIS
// Preserve direct state access for mode0 authentic-ROM diagnostic snapshots.
logic [15:0] state_ram [0:4][0:32767];
`endif
genvar state_instance;
generate if (!EXTERNAL_WORK_RAM) begin : internal_work_storage
`ifdef SYNTHESIS
// Pin each 64 KiB bank to the donor's explicit M10K primitive. Quartus 17
// otherwise expands the dynamic two-dimensional array before RAM inference.
wire [15:0] state_bank_q [0:4];
for (state_instance=0; state_instance<5; state_instance=state_instance+1) begin : work_banks
    gd_word_ram #(.ADDR_WIDTH(15)) bank (
        .clk(clk), .address(cpu_even_address[15:1]), .data(cpu_data_out),
        .byte_enable(cpu_byte_enable),
        .write(local_write && (cs_work || cs_aux) && state_bank==state_instance),
        .q(state_bank_q[state_instance]),
        .video_clk(clk), .video_address(15'd0), .video_q()
    );
end
always_comb state_q=state_bank_q[state_bank];
`else
always_ff @(posedge clk) begin
    state_q <= state_ram[state_bank][cpu_even_address[15:1]];
    if (local_write && (cs_work || cs_aux)) begin
        if (cpu_byte_enable[1]) state_ram[state_bank][cpu_even_address[15:1]][15:8] <= cpu_data_out[15:8];
        if (cpu_byte_enable[0]) state_ram[state_bank][cpu_even_address[15:1]][7:0] <= cpu_data_out[7:0];
    end
end
`endif
end else begin : external_work_storage
    always_comb state_q=16'd0;
end endgenerate

wire [15:0] sprite_q;
wire sprite_buffer_trigger = local_write && cs_video_regs
	&& ((cpu_even_address[5:1] == 5'h13) || (cpu_even_address[5:1] == 5'h12))
	&& ((cpu_byte_enable[1] && (cpu_data_out[15:8] != 8'd0))
	    || (cpu_byte_enable[0] && (cpu_data_out[7:0] != 8'd0)));
// Match MAME raster rearm register semantics; physical IRQ phase remains open.
always_comb raster_rearm = local_write && cs_video_regs
	&& (cpu_even_address[5:1] == 5'h1e)
	&& cpu_byte_enable[0] && cpu_data_out[0];
penguin_sprite_ram sprite_ram
(
	.clk(clk), .reset(system_reset), .buffer_trigger(sprite_buffer_trigger),
	.address(cpu_even_address[17:1]), .data(cpu_data_out),
	.byte_enable(cpu_byte_enable), .write(local_write && cs_sprite), .q(sprite_q),
	.video_clk(clk), .video_address(sprite_video_address), .video_q(sprite_video_q),
	.video_seed_q(sprite_video_seed_q),
	.buffer_busy(sprite_buffer_busy)
);

wire [15:0] palette_q;
gd_word_ram #(.ADDR_WIDTH(15)) palette_ram
(
	.clk(clk), .address(cpu_even_address[15:1]), .data(cpu_data_out),
	.byte_enable(cpu_byte_enable), .write(local_write && cs_palette), .q(palette_q),
	.video_clk(clk), .video_address(palette_video_address), .video_q(palette_video_q)
);

logic [15:0] video_registers [0:31];
integer vr;
// Zoom class captures the SAME merged word as the original register bank.
// Separate constant word reads avoid adding a 32-word read mux on these FFs.
function automatic [15:0] merge_video_zoom_word;
    input [15:0] old_word, new_word;
    input [1:0] byte_enable;
    begin
        merge_video_zoom_word = old_word;
        if (byte_enable[1]) merge_video_zoom_word[15:8] = new_word[15:8];
        if (byte_enable[0]) merge_video_zoom_word[7:0] = new_word[7:0];
    end
endfunction
wire [15:0] zoom_low_after_write = (cpu_even_address[5:1] == 5'd10)
    ? merge_video_zoom_word(video_registers[10], cpu_data_out, cpu_byte_enable)
    : video_registers[10];
wire [15:0] zoom_high_after_write = (cpu_even_address[5:1] == 5'd11)
    ? merge_video_zoom_word(video_registers[11], cpu_data_out, cpu_byte_enable)
    : video_registers[11];
wire [26:0] zoom_after_write = {zoom_high_after_write[10:0], zoom_low_after_write};
always_ff @(posedge clk) begin
	if (system_reset) begin
		for (vr = 0; vr < 32; vr = vr + 1) video_registers[vr] <= 16'd0;
		video_x_half_mode <= 1'b0;
		video_x_fractional_mode <= 1'b0;
	end
	else if (local_write && cs_video_regs) begin
		if (cpu_byte_enable[1]) video_registers[cpu_even_address[5:1]][15:8]
			<= cpu_data_out[15:8];
		if (cpu_byte_enable[0]) video_registers[cpu_even_address[5:1]][7:0]
			<= cpu_data_out[7:0];
		if ((cpu_even_address[5:1] == 5'd10) || (cpu_even_address[5:1] == 5'd11)) begin
			video_x_half_mode <= (zoom_after_write == 27'h0020000);
			video_x_fractional_mode <= (zoom_after_write > 27'h0010000)
				&& (zoom_after_write < 27'h0020000);
		end
	end
end
always_comb video_reg_q = video_registers[video_reg_address];
always_comb begin
	video_control = video_registers[24];
	video_x_offset = {video_registers[9][10:0], video_registers[8]};
	video_x_zoom = {video_registers[11][10:0], video_registers[10]};
	video_y_offset = {video_registers[13][10:0], video_registers[12]};
	video_y_zoom = {video_registers[15][10:0], video_registers[14]};
	raster_enable = video_registers[30];
	raster_position = video_registers[31];
end
wire [15:0] cpu_video_reg_q = video_registers[cpu_even_address[5:1]];

logic [15:0] raw_cpu_read_data;
always_comb begin
    if (cs_program) raw_cpu_read_data = rom_dout;
    else if (cs_work || cs_aux) raw_cpu_read_data = state_q;
    else if (cs_dsw1) raw_cpu_read_data = {8'hff,dip_switches[7:0]};
    else if (cs_dsw2) raw_cpu_read_data = {8'hff,dip_switches[15:8]};
    else if (cs_p1) raw_cpu_read_data = p1_port;
    else if (cs_p2) raw_cpu_read_data = p2_port;
    else if (cs_system) raw_cpu_read_data = system_port;
    else if (cs_x1) raw_cpu_read_data = x1_q;
    else if (cs_sprite) raw_cpu_read_data = sprite_q;
    else if (cs_palette) raw_cpu_read_data = palette_q;
    else if (cs_video_regs) raw_cpu_read_data = cpu_video_reg_q;
    else raw_cpu_read_data = 16'hffff;
end
// Full legacy ports retained, but no cheat engine/turbo modifies faithful CPU.
wire unused_legacy = &{1'b0,turbo,cheat_reset,cheat_code,ram_dout,ram_ack};

logic [15:0] p1_port;
logic [15:0] p2_port;
logic [15:0] system_port;
always_comb begin
	p1_port = 16'hffff;
	p2_port = 16'hffff;
	system_port = 16'hffff;
	// MiSTer direction bits -> Penguin active-low inputs; only two buttons used.
	p1_port[0] = ~joystick_p1[1]; p2_port[0] = ~joystick_p2[1];
	p1_port[1] = ~joystick_p1[0]; p2_port[1] = ~joystick_p2[0];
	p1_port[2] = ~joystick_p1[3]; p2_port[2] = ~joystick_p2[3];
	p1_port[3] = ~joystick_p1[2]; p2_port[3] = ~joystick_p2[2];
	p1_port[4] = ~joystick_p1[4]; p2_port[4] = ~joystick_p2[4];
	p1_port[5] = ~joystick_p1[5]; p2_port[5] = ~joystick_p2[5];
	p1_port[6] = 1'b1; p2_port[6] = 1'b1;
	p1_port[7] = ~joystick_p1[8]; p2_port[7] = ~joystick_p2[8];
	system_port[0] = ~joystick_p1[9];
	system_port[1] = ~joystick_p2[9];
	system_port[2] = ~(joystick_p1[10] | joystick_p2[10]);
	system_port[3] = ~service;
end

wire [15:0] tmp_q;
penguin_tmp68301 tmp68301_regs
(
	.clk(clk), .reset(system_reset), .cpu_ce(timer_cpu_ce), .cs(tmp_access),
	.write(tmp_access && tmp_write_q),
	.address(tmp_addr_q), .data(tmp_data_q),
	.byte_enable(tmp_be_q), .q(tmp_q), .ext_irq0(vblank),
	.ext_irq1(raster_irq), .iack(tmp_iack), .irq_level(tmp_irq_level),
	.irq_vector(tmp_irq_vector)
);

always_comb x1_address = cpu_even_address[13:1];

always_ff @(posedge clk) begin
	x1_write <= 1'b0;
	if (system_reset) begin

		x1_data <= 16'd0;
		x1_byte_enable <= 2'd0;
		sample_banks <= 64'd0;
	end
	else begin
		if (local_write && cs_x1) begin
			x1_write <= 1'b1;

			x1_data <= cpu_data_out;
			x1_byte_enable <= cpu_byte_enable;
		end
		if (local_write && cs_sample_bank && cpu_byte_enable[0])
			sample_banks[cpu_even_address[3:1]*8 +: 8] <= cpu_data_out[7:0];
	end
end

always_ff @(posedge clk) begin
	debug_address <= cpu_bus_address;
	if (system_reset) begin
		bus_state <= BUS_IDLE;
		cpu_dtack_n <= 1'b1;
		cpu_data_in <= 16'hffff;
		rom_addr <= 21'd0;
		rom_req <= 1'b0;
		ram_addr <= 18'd0;
		ram_req <= 1'b0;
		ram_write <= 1'b0;
		ram_data <= 16'd0;
		ram_be <= 2'd0;
		debug_address <= 24'd0;
		debug_bus_cycles <= 32'd0;
		debug_rom_cycles <= 32'd0;
		debug_unmapped_cycles <= 16'd0;
		cpu_running <= 1'b0;
	end
	else begin
		case (bus_state)
			BUS_IDLE: begin
				cpu_dtack_n <= 1'b1;
				if (!cpu_as_n && cpu_data_strobe && cpu_data_strobe_seen) begin
					debug_bus_cycles <= debug_bus_cycles + 32'd1;
					if (cpu_iack_cycle) begin
						cpu_data_in <= {8'hff, tmp_irq_vector};
						cpu_dtack_n <= 1'b0;
						bus_state <= BUS_ACK;
					end
					else if (cs_program && cpu_rw) begin
						rom_addr <= cpu_even_address[20:0];
						rom_req <= ~rom_req;
						debug_rom_cycles <= debug_rom_cycles + 32'd1;
						cpu_running <= 1'b1;
						bus_state <= BUS_ROM_WAIT;
					end

					else if (EXTERNAL_WORK_RAM && (cs_work || cs_aux)) begin
						// Latch all request fields once. Hold them until toggle ACK.
						ram_addr <= {state_bank,cpu_even_address[15:1]};
						ram_write <= !cpu_rw;
						ram_data <= cpu_data_out;
						ram_be <= cpu_byte_enable;
						ram_req <= ~ram_req;
						bus_state <= BUS_RAM_WAIT;
					end
					else if (cs_tmp) begin
						tmp_addr_q <= cpu_even_address[9:0];
						tmp_data_q <= cpu_data_out;
						tmp_be_q <= cpu_byte_enable;
						tmp_write_q <= !cpu_rw;
						bus_state <= BUS_TMP_DECODE;
					end
					else begin
						if (!mapped_cycle)
							debug_unmapped_cycles <= debug_unmapped_cycles + 16'd1;
						cpu_data_in <= raw_cpu_read_data;
						cpu_dtack_n <= 1'b0;
						bus_state <= BUS_ACK;
					end
				end
			end

			BUS_ROM_WAIT: if (rom_ack == rom_req) begin
				cpu_data_in <= rom_dout;
				cpu_dtack_n <= 1'b0;
				bus_state <= BUS_ACK;
			end

			BUS_RAM_WAIT: if (ram_ack == ram_req) begin
				cpu_data_in <= ram_dout;
				cpu_dtack_n <= 1'b0;
				bus_state <= BUS_ACK;
			end

			// The registered TMP access (write or read capture) happens here.
			BUS_TMP_DECODE: begin
				tmp_rd_data <= tmp_q;
				bus_state <= BUS_TMP_DATA;
			end

			BUS_TMP_DATA: begin
				cpu_data_in <= tmp_rd_data;
				cpu_dtack_n <= 1'b0;
				bus_state <= BUS_ACK;
			end

			BUS_ACK: if (cpu_as_n) begin
				cpu_dtack_n <= 1'b1;
				bus_state <= BUS_IDLE;
			end
			default: bus_state <= BUS_IDLE;
		endcase
	end
end

endmodule

// Banked 256 KiB sprite RAM with a 64-bit video-side record port.
// Four consecutive DX-101 words are stored in separate M10K banks so a full
// list header or sprite descriptor can be streamed in one read without
// duplicating memory.
// SPDX-License-Identifier: GPL-3.0-or-later

module penguin_sprite_ram
(
	input  logic        clk,
	input  logic        reset,
	input  logic        buffer_trigger,
	input  logic [16:0] address,
	input  logic [15:0] data,
	input  logic  [1:0] byte_enable,
	input  logic        write,
	output logic [15:0] q,
	input  logic        video_clk,
	input  logic [16:0] video_address,
	output logic [63:0] video_q,
	output logic [15:0] video_seed_q,
	output logic        buffer_busy
);

logic [15:0] bank_q [0:3];
// Headers occupy records 0x600..0x7ff: lane bank1, tail bank0.
// Tap the existing registered RAM outputs; no extra read cycle or memory.
wire [63:0] source_header_q;
wire [15:0] header_word [0:3];
genvar header_word_index;
generate for(header_word_index=0;header_word_index<4;header_word_index=header_word_index+1)begin: header_words
    assign header_word[header_word_index]=source_header_q[header_word_index*16 +:16];
end endgenerate
logic [15:0] video_bank_q [0:3];

// MAME approximates DX-101 snapshots base-list headers when register 0x26 is written,
// packs every referenced record into low sprite RAM, and rewrites each private
// header pointer to that packed copy. The resulting low records remain CPU-visible, as in MAME.
// Physical list processing is not verified on this board. A simple vblank snapshot is not equivalent: it
// can bisect the game's multiword rewrite and retain complete 64-line bands
// from the preceding scene.
// Full MAME 0x1000-byte list, not the donor's 128-entry limit.
localparam int PRIVATE_HEADER_COUNT = 512;
`ifndef SYNTHESIS
logic [63:0] private_headers [0:PRIVATE_HEADER_COUNT-1];
`endif
logic [63:0] private_video_q;
logic [63:0] private_header_q;
logic [PRIVATE_HEADER_COUNT-1:0] private_header_valid;
logic private_headers_ready, private_header_read_valid;
logic        private_video_select;
logic        private_video_select_q;
logic  [8:0] private_video_index;

typedef enum logic [2:0] {
	C_IDLE, C_HEADER_WAIT, C_HEADER_CAPTURE,
	C_DESCRIPTOR_WAIT, C_DESCRIPTOR_CAPTURE
} copy_state_t;
copy_state_t copy_state;
logic  [8:0] copy_header_index;
// Zero-based count removes header RAM-to-carry-chain setup path.
// Encoding is (original remaining-1) modulo512; no bus/FSM cycle changes.
logic  [8:0] copy_descriptors_remaining_m1;
logic [16:0] copy_read_address;
logic [14:0] copy_dest_record;
logic        copy_last_header;
localparam logic [14:0] PACKED_RECORD_LIMIT = 15'h0600;
wire private_header_write = !reset && (copy_state == C_HEADER_CAPTURE);
wire [63:0] private_header_data = {
    header_word[3][15], (copy_dest_record | ((header_word[0][15] && header_word[3] == 16'd0) ? 15'h4000 : 15'd0)),
    header_word[2], header_word[1],
    header_word[0] | ((copy_header_index == PRIVATE_HEADER_COUNT-1) ? 16'h8000 : 16'd0)
};
// Reset metadata, not 32,768 RAM bits. The first completed genuine copy
// publishes valid headers; untouched entries retain the original zero readback.
always_ff @(posedge clk) begin
    if (reset) begin
        private_header_valid <= '0;
        private_headers_ready <= 1'b0;
    end else begin
        if (private_header_write) private_header_valid[copy_header_index] <= 1'b1;
        if ((copy_state == C_DESCRIPTOR_CAPTURE)
            && (copy_descriptors_remaining_m1 == 9'd0) && copy_last_header)
            private_headers_ready <= 1'b1;
    end
end
always_comb private_video_q = private_header_read_valid ? private_header_q : 64'd0;
`ifdef SYNTHESIS
altsyncram #(
    .operation_mode("BIDIR_DUAL_PORT"),
    .width_a(64), .widthad_a(9), .numwords_a(PRIVATE_HEADER_COUNT),
    .width_b(64), .widthad_b(9), .numwords_b(PRIVATE_HEADER_COUNT),
    .width_byteena_a(1), .width_byteena_b(1),
    .address_reg_b("CLOCK1"), .outdata_reg_a("UNREGISTERED"),
    .outdata_reg_b("UNREGISTERED"), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_mixed_ports("OLD_DATA"),
    .intended_device_family("Cyclone V"), .ram_block_type("M10K")
) private_header_ram (
    .clock0(clk), .clock1(video_clk), .address_a(copy_header_index),
    .address_b(private_video_index), .data_a(private_header_data), .data_b(64'd0),
    .byteena_a(1'b1), .byteena_b(1'b1),
    .wren_a(private_header_write), .wren_b(1'b0), .q_a(), .q_b(private_header_q)
);
`else
// Simulation preserves directly inspectable reset-zero private snapshots.
integer private_index;
always_ff @(posedge clk) begin
    if (reset) begin
        for (private_index=0; private_index<PRIVATE_HEADER_COUNT; private_index=private_index+1)
            private_headers[private_index] <= 64'd0;
    end else if (private_header_write)
        private_headers[copy_header_index] <= private_header_data;
end
always_ff @(posedge video_clk) private_header_q <= private_headers[private_video_index];
`endif
// Legacy renderer seed output has no Penguin board meaning.
always_comb video_seed_q = 16'd0;

assign buffer_busy = (copy_state != C_IDLE);
// The packed destination occupies bytes 0x0000-0x2fff. A longer source list
// must not run into the base headers beginning at byte 0x3000. Saturating the
// pointer also leaves later private headers outside the valid packed range.
wire copy_record_write = (copy_state == C_DESCRIPTOR_CAPTURE)
	&& (copy_dest_record < PACKED_RECORD_LIMIT);
// The list-copy bus master owns the CPU port while the 68000 is held. Never
// steal the video read port: the renderer can still be drawing a scanline
// during a buffer transaction (notably the intro fire trail and HUD).
wire [14:0] bank_cpu_address = copy_record_write
	? copy_dest_record : (buffer_busy ? copy_read_address[16:2] : address[16:2]);
wire [16:0] bank_video_address = video_address;

always_ff @(posedge clk) begin
	if (reset) begin
		copy_state <= C_IDLE;
		copy_header_index <= 9'd0;
		copy_descriptors_remaining_m1 <= 9'h1ff;
		copy_read_address <= 17'd0;
		copy_dest_record <= 15'd0;
		copy_last_header <= 1'b0;
	end
	else begin
		case (copy_state)
			C_IDLE: if (buffer_trigger) begin
				copy_header_index <= 9'd0;
				copy_dest_record <= 15'd0;
				copy_read_address <= 17'h01800;
				copy_state <= C_HEADER_WAIT;
			end
			C_HEADER_WAIT: copy_state <= C_HEADER_CAPTURE;
			C_HEADER_CAPTURE: begin
				// Early boot can trigger buffering before software has planted
				// an end marker. Bound the private table and synthesize one in
				// its last slot, matching the finite hardware/MAME scan.
				copy_last_header <= header_word[0][15]
					|| (copy_header_index == PRIVATE_HEADER_COUNT-1);
				copy_descriptors_remaining_m1
					<= {1'b0, header_word[0][7:0]};
				copy_read_address <= {header_word[3][14:0], 2'b00};
				copy_state <= C_DESCRIPTOR_WAIT;
			end
			C_DESCRIPTOR_WAIT: copy_state <= C_DESCRIPTOR_CAPTURE;
			C_DESCRIPTOR_CAPTURE: begin
				if (copy_dest_record < PACKED_RECORD_LIMIT)
					copy_dest_record <= copy_dest_record + 15'd1;
				if (copy_descriptors_remaining_m1 == 9'd0) begin
					if (copy_last_header)
						copy_state <= C_IDLE;
					else begin
						copy_header_index <= copy_header_index + 9'd1;
						copy_read_address <= 17'h01800
							+ {(copy_header_index + 9'd1), 2'b00};
						copy_state <= C_HEADER_WAIT;
					end
				end
				else begin
					copy_descriptors_remaining_m1
						<= copy_descriptors_remaining_m1 - 9'd1;
					copy_read_address <= copy_read_address + 17'd4;
					copy_state <= C_DESCRIPTOR_WAIT;
				end
			end
			default: copy_state <= C_IDLE;
		endcase
	end
end

always_comb begin
	private_video_select = (video_address >= 17'h01800)
		&& (video_address <= 17'h01ffc);
	private_video_index = video_address[10:2];
	case (address[1:0])
		2'd0: q = bank_q[0];
		2'd1: q = bank_q[1];
		2'd2: q = bank_q[2];
		default: q = bank_q[3];
	endcase
	if (private_video_select_q)
		video_q = private_video_q;
	else
		video_q = {video_bank_q[3], video_bank_q[2],
		           video_bank_q[1], video_bank_q[0]};
end

// Private-header reads have the same one-clock address latency as M10K reads.
always_ff @(posedge video_clk) begin
	if (reset) begin
		private_video_select_q <= 1'b0;
		private_header_read_valid <= 1'b0;
	end
	else begin
		private_video_select_q <= private_video_select;
		private_header_read_valid <= private_headers_ready && private_header_valid[private_video_index];
	end
end

// The caller presents its address for a registered RAM read before local_write.
// Merge only the selected CPU bytes; descriptor copies write all64 bits.
logic [63:0] live_cpu_record, live_video_record;
integer packed_word;
always_comb begin
    for (packed_word=0;packed_word<4;packed_word=packed_word+1) begin
        bank_q[packed_word]=live_cpu_record[packed_word*16 +: 16];
        video_bank_q[packed_word]=live_video_record[packed_word*16 +: 16];
    end
end
penguin_sprite_packed_ram packed_ram (
    .clk(clk), .address(bank_cpu_address),
    .data(copy_record_write ? live_cpu_record : {4{data}}),
    .write_mask(copy_record_write ? 8'hff : ({6'd0,byte_enable} << (address[1:0]*2))),
    .copy_mode(copy_record_write),
    .cpu_data(data),
    .write(copy_record_write || (write && !buffer_busy && (|byte_enable))),
    .q(live_cpu_record), .header_q(source_header_q), .video_clk(video_clk),
    .video_address(bank_video_address[16:2]), .video_q(live_video_record)
);
`ifndef SYNTHESIS
logic [14:0] prior_cpu_record;
always_ff @(posedge clk) begin
    prior_cpu_record <= bank_cpu_address;
    if (!reset && write && !buffer_busy && (|byte_enable))
        assert (prior_cpu_record == bank_cpu_address)
            else $fatal(1,"sprite partial-write merge lacked prepared address");
    if (!reset && write && buffer_busy)
        $fatal(1,"CPU sprite write while copy master owns its port");
end
`endif


endmodule
