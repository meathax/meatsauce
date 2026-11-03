// Banked 256 KiB sprite RAM with a 64-bit video-side record port.
// Four consecutive DX-101 words are stored in separate M10K banks so a full
// list header or sprite descriptor can be streamed in one read without
// duplicating memory.
// SPDX-License-Identifier: GPL-3.0-or-later

module gd_sprite_ram
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
logic [15:0] video_bank_q [0:3];

// The real DX-101 snapshots base-list headers when register 0x26 is written,
// packs every referenced record into low sprite RAM, and rewrites each private
// header pointer to that packed copy. Guardians subsequently changes the low
// records during raster IRQs. A simple vblank snapshot is not equivalent: it
// can bisect the game's multiword rewrite and retain complete 64-line bands
// from the preceding scene.
// Dense gameplay exceeds 32 display-list groups (40 were observed in the
// attract demo). Keep enough private headers for those late HUD/foreground
// groups; the hardware's private area can hold many more than 32.
localparam int PRIVATE_HEADER_COUNT = 128;
logic [63:0] private_headers [0:PRIVATE_HEADER_COUNT-1];
logic [63:0] private_video_q;
logic        private_video_select;
logic        private_video_select_q;
logic  [6:0] private_video_index;
integer private_index;

typedef enum logic [2:0] {
	C_IDLE, C_HEADER_WAIT, C_HEADER_CAPTURE,
	C_DESCRIPTOR_WAIT, C_DESCRIPTOR_CAPTURE
} copy_state_t;
copy_state_t copy_state;
logic  [6:0] copy_header_index;
logic  [8:0] copy_descriptors_remaining;
logic [16:0] copy_read_address;
logic [14:0] copy_dest_record;
logic        copy_last_header;
localparam logic [14:0] PACKED_RECORD_LIMIT = 15'h0600;
// Keep the packed word-2 seed paired with the private header generation.
// During the kick transition software starts raster-writing a new fire group
// before the next buffer trigger retires the old companion-layer header.
// Live sprite RAM must remain writable; the seed lets the renderer preserve
// the old companion identity without delaying a row or stealing a RAM port.
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] packed_seed [0:1535];

always_ff @(posedge clk) begin
	if (copy_record_write)
		packed_seed[copy_dest_record] <= bank_q[2];
end

always_ff @(posedge video_clk) begin
	if (reset || (video_address >= 17'h01800))
		video_seed_q <= 16'd0;
	else
		video_seed_q <= packed_seed[video_address[16:2]];
end

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
		copy_header_index <= 7'd0;
		copy_descriptors_remaining <= 9'd0;
		copy_read_address <= 17'd0;
		copy_dest_record <= 15'd0;
		copy_last_header <= 1'b0;
		for (private_index = 0; private_index < PRIVATE_HEADER_COUNT;
		     private_index = private_index + 1)
			private_headers[private_index] <= 64'd0;
	end
	else begin
		case (copy_state)
			C_IDLE: if (buffer_trigger) begin
				copy_header_index <= 7'd0;
				copy_dest_record <= 15'd0;
				copy_read_address <= 17'h01800;
				copy_state <= C_HEADER_WAIT;
			end
			C_HEADER_WAIT: copy_state <= C_HEADER_CAPTURE;
			C_HEADER_CAPTURE: begin
				private_headers[copy_header_index] <= {
					bank_q[3][15], copy_dest_record,
					bank_q[2], bank_q[1],
					bank_q[0]
						| ((copy_header_index == PRIVATE_HEADER_COUNT-1)
							? 16'h8000 : 16'd0)
				};
				// Early boot can trigger buffering before software has planted
				// an end marker. Bound the private table and synthesize one in
				// its last slot, matching the finite hardware/MAME scan.
				copy_last_header <= bank_q[0][15]
					|| (copy_header_index == PRIVATE_HEADER_COUNT-1);
				copy_descriptors_remaining
					<= {1'b0, bank_q[0][7:0]} + 9'd1;
				copy_read_address <= {bank_q[3][14:0], 2'b00};
				copy_state <= C_DESCRIPTOR_WAIT;
			end
			C_DESCRIPTOR_WAIT: copy_state <= C_DESCRIPTOR_CAPTURE;
			C_DESCRIPTOR_CAPTURE: begin
				if (copy_dest_record < PACKED_RECORD_LIMIT)
					copy_dest_record <= copy_dest_record + 15'd1;
				if (copy_descriptors_remaining == 9'd1) begin
					if (copy_last_header)
						copy_state <= C_IDLE;
					else begin
						copy_header_index <= copy_header_index + 7'd1;
						copy_read_address <= 17'h01800
							+ {(copy_header_index + 7'd1), 2'b00};
						copy_state <= C_HEADER_WAIT;
					end
				end
				else begin
					copy_descriptors_remaining
						<= copy_descriptors_remaining - 9'd1;
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
		&& (video_address <= 17'h019fc);
	private_video_index = video_address[8:2];
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
		private_video_q <= 64'd0;
	end
	else begin
		private_video_select_q <= private_video_select;
		private_video_q <= private_headers[private_video_index];
	end
end

`ifdef SYNTHESIS
genvar ram_bank;
generate
	for (ram_bank = 0; ram_bank < 4; ram_bank = ram_bank + 1) begin: banks
		altsyncram #(
			.operation_mode("BIDIR_DUAL_PORT"),
			.width_a(16), .widthad_a(15), .numwords_a(32768),
			.width_b(16), .widthad_b(15), .numwords_b(32768),
			.width_byteena_a(2), .width_byteena_b(2),
			.address_reg_b("CLOCK1"), .outdata_reg_a("UNREGISTERED"),
			.outdata_reg_b("UNREGISTERED"), .power_up_uninitialized("FALSE"),
			.read_during_write_mode_mixed_ports("OLD_DATA"),
			.intended_device_family("Cyclone V"), .ram_block_type("M10K")
		) bank_ram (
			.clock0(clk), .clock1(video_clk), .address_a(bank_cpu_address),
			.address_b(bank_video_address[16:2]),
			.data_a(copy_record_write ? bank_q[ram_bank] : data),
			.data_b(16'd0),
			.byteena_a(copy_record_write ? 2'b11 : byte_enable),
			.byteena_b(2'b11),
			.wren_a(copy_record_write
				|| (write && (address[1:0] == ram_bank))), .wren_b(1'b0),
			.q_a(bank_q[ram_bank]), .q_b(video_bank_q[ram_bank])
		);
	end
endgenerate
`else
logic [15:0] bank_memory [0:3][0:32767];

always_ff @(posedge clk) begin
	if (copy_record_write) begin
		bank_memory[0][copy_dest_record] <= bank_q[0];
		bank_memory[1][copy_dest_record] <= bank_q[1];
		bank_memory[2][copy_dest_record] <= bank_q[2];
		bank_memory[3][copy_dest_record] <= bank_q[3];
	end
	else if (write) begin
		if (byte_enable[1])
			bank_memory[address[1:0]][address[16:2]][15:8] <= data[15:8];
		if (byte_enable[0])
			bank_memory[address[1:0]][address[16:2]][7:0] <= data[7:0];
	end
	bank_q[0] <= bank_memory[0][bank_cpu_address];
	bank_q[1] <= bank_memory[1][bank_cpu_address];
	bank_q[2] <= bank_memory[2][bank_cpu_address];
	bank_q[3] <= bank_memory[3][bank_cpu_address];
end

always_ff @(posedge video_clk) begin
	video_bank_q[0] <= bank_memory[0][bank_video_address[16:2]];
	video_bank_q[1] <= bank_memory[1][bank_video_address[16:2]];
	video_bank_q[2] <= bank_memory[2][bank_video_address[16:2]];
	video_bank_q[3] <= bank_memory[3][bank_video_address[16:2]];
end
`endif

endmodule
