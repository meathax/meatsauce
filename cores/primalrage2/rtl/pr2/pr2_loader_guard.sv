module pr2_loader_guard #(
	parameter logic [26:0] BIOS_BYTES = 27'd524288,
	parameter logic [26:0] PROGRAM_BYTES = 27'd2097152,
	parameter logic [26:0] KEY_BYTES = 27'd8,
	parameter logic [26:0] EEPROM_BYTES = 27'd2048,
	parameter logic        REQUIRE_EEPROM = 1'b1
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic        sdram_write_pending,
	input  logic [63:0] img_size,
	output logic        media_ready
);

	logic bios_stream;
	logic program_stream;
	logic key_a_stream;
	logic key_b_stream;
	logic eeprom_stream;
	logic bios_stream_d;
	logic program_stream_d;
	logic key_a_stream_d;
	logic key_b_stream_d;
	logic eeprom_stream_d;
	logic bios_loaded;
	logic program_loaded;
	logic key_a_loaded;
	logic key_b_loaded;
	logic eeprom_loaded;
	logic bios_valid;
	logic program_valid;
	logic key_a_valid;
	logic key_b_valid;
	logic eeprom_valid;
	logic [26:0] bios_next;
	logic [26:0] program_next;
	logic [26:0] key_a_next;
	logic [26:0] key_b_next;
	logic [26:0] eeprom_next;
	logic image_size_valid;

	assign bios_stream = ioctl_download && (ioctl_index == 16'd0);
	assign program_stream = ioctl_download && (ioctl_index == 16'd2);
	assign key_a_stream = ioctl_download && (ioctl_index == 16'd4);
	assign key_b_stream = ioctl_download && (ioctl_index == 16'd5);
	assign eeprom_stream = ioctl_download && (ioctl_index == 16'd9);

	// img_size is a byte count from hps_io. Require a whole, non-zero sector
	// count and reject values wider than the ATA bridge's 32-bit LBA space;
	// otherwise media_ready could release the core with a silently truncated
	// disk geometry.
	assign image_size_valid = (img_size[63:41] == 23'd0) &&
	                          (img_size[8:0] == 9'd0) &&
	                          (img_size[40:9] != 32'd0);

	assign media_ready = bios_loaded && program_loaded && key_a_loaded &&
	                     key_b_loaded && image_size_valid &&
	                     (!REQUIRE_EEPROM || eeprom_loaded) &&
	                     !sdram_write_pending && !ioctl_download;

	always_ff @(posedge clk) begin
		if (reset) begin
			bios_stream_d <= 1'b0;
			program_stream_d <= 1'b0;
			key_a_stream_d <= 1'b0;
			key_b_stream_d <= 1'b0;
			eeprom_stream_d <= 1'b0;
			bios_loaded <= 1'b0;
			program_loaded <= 1'b0;
			key_a_loaded <= 1'b0;
			key_b_loaded <= 1'b0;
			eeprom_loaded <= 1'b0;
			bios_valid <= 1'b0;
			program_valid <= 1'b0;
			key_a_valid <= 1'b0;
			key_b_valid <= 1'b0;
			eeprom_valid <= 1'b0;
			bios_next <= 27'd0;
			program_next <= 27'd0;
			key_a_next <= 27'd0;
			key_b_next <= 27'd0;
			eeprom_next <= 27'd0;
		end else begin
			bios_stream_d <= bios_stream;
			program_stream_d <= program_stream;
			key_a_stream_d <= key_a_stream;
			key_b_stream_d <= key_b_stream;
			eeprom_stream_d <= eeprom_stream;

			if (bios_stream) begin
				if (!bios_stream_d) begin
					bios_loaded <= 1'b0;
					bios_valid <= !ioctl_wr || (ioctl_addr == 27'd0);
					bios_next <= ioctl_wr ? 27'd2 : 27'd0;
				end else if (ioctl_wr) begin
					if ((bios_next >= BIOS_BYTES) || (ioctl_addr != bios_next))
						bios_valid <= 1'b0;
					else
						bios_next <= bios_next + 27'd2;
				end
			end else if (bios_stream_d) begin
				bios_loaded <= bios_valid && (bios_next == BIOS_BYTES);
			end

			if (program_stream) begin
				if (!program_stream_d) begin
					program_loaded <= 1'b0;
					program_valid <= !ioctl_wr || (ioctl_addr == 27'd0);
					program_next <= ioctl_wr ? 27'd2 : 27'd0;
				end else if (ioctl_wr) begin
					if ((program_next >= PROGRAM_BYTES) || (ioctl_addr != program_next))
						program_valid <= 1'b0;
					else
						program_next <= program_next + 27'd2;
				end
			end else if (program_stream_d) begin
				program_loaded <= program_valid && (program_next == PROGRAM_BYTES);
			end

			if (key_a_stream) begin
				if (!key_a_stream_d) begin
					key_a_loaded <= 1'b0;
					key_a_valid <= !ioctl_wr || (ioctl_addr == 27'd0);
					key_a_next <= ioctl_wr ? 27'd2 : 27'd0;
				end else if (ioctl_wr) begin
					if ((key_a_next >= KEY_BYTES) || (ioctl_addr != key_a_next))
						key_a_valid <= 1'b0;
					else
						key_a_next <= key_a_next + 27'd2;
				end
			end else if (key_a_stream_d) begin
				key_a_loaded <= key_a_valid && (key_a_next == KEY_BYTES);
			end

			if (key_b_stream) begin
				if (!key_b_stream_d) begin
					key_b_loaded <= 1'b0;
					key_b_valid <= !ioctl_wr || (ioctl_addr == 27'd0);
					key_b_next <= ioctl_wr ? 27'd2 : 27'd0;
				end else if (ioctl_wr) begin
					if ((key_b_next >= KEY_BYTES) || (ioctl_addr != key_b_next))
						key_b_valid <= 1'b0;
					else
						key_b_next <= key_b_next + 27'd2;
				end
			end else if (key_b_stream_d) begin
				key_b_loaded <= key_b_valid && (key_b_next == KEY_BYTES);
			end

			// Index 9 is the 2 KiB AT28C16 factory-or-restored NVRAM image.
			// Its complete, ordered stream is required before PR2 is released;
			// this prevents an accidental all-FF BRAM initialization from
			// masquerading as a defined startup state.
			if (eeprom_stream) begin
				if (!eeprom_stream_d) begin
					eeprom_loaded <= 1'b0;
					eeprom_valid <= !ioctl_wr || (ioctl_addr == 27'd0);
					eeprom_next <= ioctl_wr ? 27'd2 : 27'd0;
				end else if (ioctl_wr) begin
					if ((eeprom_next >= EEPROM_BYTES) || (ioctl_addr != eeprom_next))
						eeprom_valid <= 1'b0;
					else
						eeprom_next <= eeprom_next + 27'd2;
				end
			end else if (eeprom_stream_d) begin
				eeprom_loaded <= eeprom_valid && (eeprom_next == EEPROM_BYTES);
			end
		end
	end

endmodule
