// SPDX-License-Identifier: GPL-2.0-or-later
//
// Tracks the FPGA side of an hps_io EEPROM upload.  hps_io provides no
// durable-host acknowledgement: ioctl_upload is only high while the FPGA is
// being read.  Therefore the only safe acknowledgement this core can issue
// is after that transfer has ended and no newer accepted EEPROM write exists.
module pr2_eeprom_upload_guard(
	input  logic clk,
	input  logic dirty,
	input  logic write_accepted,
	input  logic ioctl_upload,
	input  logic [15:0] ioctl_index,
	input  logic ioctl_rd,
	input  logic [26:0] ioctl_addr,
	output logic upload_request,
	output logic dirty_clear
);
	localparam logic [15:0] EEPROM_INDEX = 16'd9;
	// WIDE hps_io prefetches address 0 when upload starts. Each of the
	// host's 1024 data strobes returns the prefetched word and requests the
	// next address; the final strobe requests 2048 while returning word 1023.
	localparam logic [10:0] EEPROM_READS = 11'd1025;
	localparam logic [26:0] EEPROM_NEXT_ADDR = 27'd2050;
	logic        upload_d = 1'b0;
	logic        upload_active = 1'b0;
	logic        clear_pending = 1'b0;
	logic        upload_valid = 1'b0;
	logic [15:0] upload_index_latched = 16'd0;
	logic [10:0] upload_read_count = 11'd0;
	logic [26:0] upload_next_addr = 27'd0;
	logic [31:0] write_generation = 32'd0;
	logic [31:0] upload_generation = 32'd0;
	initial begin
		upload_request = 1'b0;
		dirty_clear = 1'b0;
	end

	always_ff @(posedge clk) begin
		// dirty_clear is a one-clock command.  The EEPROM block consumes it on
		// this edge; its write path deliberately has priority over clear.
		dirty_clear <= 1'b0;

		if (write_accepted)
			write_generation <= write_generation + 1'd1;

		// hps_io queues saves only on a request rising edge.  Release its
		// request while an upload is active, then raise a fresh edge when a
		// newer generation survives that transfer.
		if (!dirty) begin
			upload_request <= 1'b0;
			clear_pending <= 1'b0;
		end else if (clear_pending && write_accepted) begin
			// The EEPROM block will retain the new generation over the
			// previously queued clear.  Emit a fresh request edge.
			upload_request <= 1'b1;
			clear_pending <= 1'b0;
		end else if (!ioctl_upload && !upload_active && !clear_pending) begin
			upload_request <= 1'b1;
		end

		if (ioctl_upload & ~upload_d) begin
			upload_active     <= dirty;
			upload_valid      <= dirty && (ioctl_index == EEPROM_INDEX);
			upload_index_latched <= ioctl_index;
			upload_read_count <= 11'd0;
			upload_next_addr  <= 27'd0;
			upload_generation <= write_generation;
			upload_request    <= 1'b0;
			// hps_io emits an initial WIDE=1 read at address zero on the same
			// cycle that the upload becomes visible.  Because both this guard and
			// hps_io use nonblocking assignments, account for that first read in
			// the upload-edge branch before sampling the following data pulses.
			if (dirty && (ioctl_index == EEPROM_INDEX) && ioctl_rd &&
			(ioctl_addr == 27'd0)) begin
			upload_read_count <= 11'd1;
			upload_next_addr  <= 27'd2;
		end
	end

		if (ioctl_upload && upload_active && ioctl_rd) begin
			if (!upload_valid || (ioctl_index != upload_index_latched) ||
				(upload_read_count >= EEPROM_READS) ||
				(ioctl_addr != upload_next_addr)) begin
				upload_valid <= 1'b0;
			end else begin
				upload_read_count <= upload_read_count + 1'd1;
				upload_next_addr <= upload_next_addr + 27'd2;
			end
		end

		if (~ioctl_upload & upload_d) begin
			// A falling edge is useful only after index 9 supplied exactly the
			// ordered 2 KiB image.  It still does not prove durable host storage.
			if (upload_active && upload_valid && dirty && !write_accepted &&
				(upload_read_count == EEPROM_READS) &&
				(upload_next_addr == EEPROM_NEXT_ADDR) &&
				(write_generation == upload_generation)) begin
				dirty_clear <= 1'b1;
				clear_pending <= 1'b1;
			end else begin
				// Preserve dirty state and rearm a new rising-edge request for
				// zero/partial/wrong-index/out-of-order/interrupted transfers.
				upload_request <= dirty;
				clear_pending <= 1'b0;
			end
			upload_active <= 1'b0;
		end

		upload_d <= ioctl_upload;
	end
endmodule
