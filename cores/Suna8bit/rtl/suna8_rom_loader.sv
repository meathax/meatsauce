module suna8_rom_loader
(
    input  logic clk,
    input  logic ioctl_download,
    input  logic ioctl_wr,
    input  logic [7:0] ioctl_index,
    input  logic [24:0] ioctl_addr,
    input  logic [7:0] ioctl_dout,

    output logic [2:0] profile_id = 3'd0,
    output logic profile_valid = 1'b0,
    output logic [24:0] image_size,
    output logic [31:0] image_crc,
    output logic download_active,

    // Download writes are deliberately exposed as a byte-wide backend
    // contract.  The loader does not infer a ROM size or instantiate a large
    // on-chip array; the MiSTer SDRAM controller consumes these absolute
    // addresses and stores the bytes in the MRA layout.
    output logic media_wr_valid,
    output logic [2:0] media_wr_region,
    output logic [24:0] media_wr_addr,
    output logic [24:0] media_wr_offset,
    output logic [7:0] media_wr_data,

    input  logic [19:0] main_addr,
    input  logic [7:0] main_mem_q,
    output logic [7:0] main_q,
    output logic [24:0] main_media_addr,
    input  logic [15:0] sound_addr,
    input  logic [7:0] sound_mem_q,
    output logic [7:0] sound_q,
    output logic [24:0] sound_media_addr,
    input  logic [15:0] pcm_addr,
    input  logic [7:0] pcm_mem_q,
    output logic [7:0] pcm_q,
    output logic [24:0] pcm_media_addr,
    input  logic [19:0] gfx1_addr,
    input  logic [7:0] gfx1_mem_q,
    output logic [7:0] gfx1_q,
    output logic [24:0] gfx1_media_addr,
    input  logic [19:0] gfx2_addr,
    input  logic [7:0] gfx2_mem_q,
    output logic [7:0] gfx2_q,
    output logic [24:0] gfx2_media_addr,
    input  logic [15:0] sample_addr,
    input  logic [7:0] sample_mem_q,
    output logic [7:0] sample_q,
    output logic [24:0] sample_media_addr,
    input  logic [7:0] prom_addr,
    input  logic [7:0] prom_mem_q,
    output logic [7:0] prom_q,
    output logic [24:0] prom_media_addr
);

    import suna8_media_pkg::*;

    suna8_media_region_t write_region;
	logic index0_active_d = 1'b0;
	logic image_seen = 1'b0;
	logic image_sequence_valid = 1'b0;
	logic [24:0] image_next_addr = 25'd0;
	logic [31:0] image_crc_state = 32'hffffffff;

	assign image_size = image_next_addr;
	assign image_crc = ~image_crc_state;

    // MiSTer Main holds status[0] (the emulated-machine reset) asserted while
    // it parses an MRA and transfers every ROM index. The fixed index-1
    // profile byte therefore arrives while the rest of the core is in reset.
    // Treat the profile as loader configuration, not resettable machine
    // state: invalidate it at the start of a new index-0 image, then latch the
    // following index-1 byte regardless of the machine reset level. FPGA
    // configuration supplies the deterministic power-up values above.
    always_ff @(posedge clk) begin
		index0_active_d <= ioctl_download && (ioctl_index == 8'd0);

		if (ioctl_download && (ioctl_index == 8'd0) && !index0_active_d) begin
			// Begin a fresh image contract. A first write may accompany the
			// download edge, but it must be address zero.
			profile_valid <= 1'b0;
			if (ioctl_wr && (ioctl_addr == 25'd0)) begin
				image_seen <= 1'b1;
				image_sequence_valid <= 1'b1;
				image_next_addr <= 25'd1;
				image_crc_state <= media_crc32_byte(32'hffffffff, ioctl_dout);
			end else begin
				image_seen <= 1'b0;
				image_sequence_valid <= !ioctl_wr;
				image_next_addr <= 25'd0;
				image_crc_state <= 32'hffffffff;
			end
		end else if (ioctl_download && (ioctl_index == 8'd0)) begin
			profile_valid <= 1'b0;
			if (ioctl_wr) begin
				image_crc_state <= media_crc32_byte(image_crc_state, ioctl_dout);
				if (!image_seen && image_sequence_valid &&
				    (ioctl_addr == 25'd0)) begin
					image_seen <= 1'b1;
					image_next_addr <= 25'd1;
				end else if (image_seen && image_sequence_valid &&
				             (ioctl_addr == image_next_addr)) begin
					image_next_addr <= image_next_addr + 25'd1;
				end else begin
					image_sequence_valid <= 1'b0;
				end
			end
        end else if (ioctl_download && ioctl_wr && ioctl_index == 8'd1 && ioctl_addr == 25'd0) begin
            // Reject any nonzero reserved bits instead of allowing values
            // such as 8'h08 to alias profile 0 through the [2:0] slice.
            if ((ioctl_dout <= 8'd5) && image_seen &&
			    image_sequence_valid &&
			    (image_next_addr == media_image_size_for_profile(ioctl_dout[2:0]))) begin
                profile_id    <= ioctl_dout[2:0];
                profile_valid <= 1'b1;
            end else begin
                profile_valid <= 1'b0;
            end
        end
    end

    always_comb begin
        download_active = ioctl_download;
        write_region = media_region_for_address(ioctl_addr);

        // Store the complete sequential MRA image, including explicit zero
        // fills between logical regions. Full storage makes a subsequent
        // end-to-end CRC readback meaningful and prevents uninitialized gap
        // contents from hiding addressing or DQM faults in external SDRAM.
        media_wr_valid  = ioctl_download && ioctl_wr && (ioctl_index == 8'd0) &&
                           (ioctl_addr < MEDIA_IMAGE_MAX);
        media_wr_region = write_region;
        media_wr_addr   = ioctl_addr;
        media_wr_offset = media_region_offset(ioctl_addr, write_region);
        media_wr_data   = ioctl_dout;

        main_media_addr   = MEDIA_MAIN_BASE + main_addr;
        sound_media_addr  = MEDIA_AUDIO_BASE + sound_addr;
        pcm_media_addr    = MEDIA_PCM_BASE + pcm_addr;
        gfx1_media_addr   = MEDIA_GFX1_BASE + gfx1_addr;
        gfx2_media_addr   = MEDIA_GFX2_BASE + gfx2_addr;
        sample_media_addr = MEDIA_SAMPLES_BASE + sample_addr;
        prom_media_addr   = MEDIA_PROMS_BASE + prom_addr;

        main_q  = main_mem_q;
        sound_q = sound_mem_q;
        pcm_q   = pcm_mem_q;
        gfx1_q  = gfx1_mem_q;
        gfx2_q  = gfx2_mem_q;
        sample_q = sample_mem_q;
        prom_q = prom_mem_q;
    end

endmodule
