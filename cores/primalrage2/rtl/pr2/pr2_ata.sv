// GPL-2.0-or-later
// PR2 ATA HLE: MAME 49e9a1f7 task-file semantics with a MiSTer hps_io block bridge.
// The sector bridge follows System573_MiSTer 6b114d6b's request/stream contract.

module pr2_ata #(
	parameter int unsigned RESET_CYCLES = 67_738,
	// Keep a wedged HPS image request from holding the ATA state machine
	// forever. This is deliberately below the board watchdog interval so an
	// ordinary media error is reported to the guest before a global reset.
	parameter int unsigned IO_TIMEOUT_CYCLES = 16_934_400
) (
	input  logic        clk,
	input  logic        reset,

	input  logic  [2:0] task_addr,
	input  logic        task_read,
	input  logic        task_write,
	input  logic [15:0] task_wdata,
	output logic [15:0] task_rdata,

	input  logic        control_read,
	input  logic        control_write,
	input  logic  [2:1] control_wdata,
	output logic  [7:0] control_rdata,

	input  logic        data32_read,
	output logic [31:0] data32_rdata,

	output logic        irq,
	output logic        dma_request,
	input  logic        dma_read_enable,
	output logic [15:0] dma_read_data,

	input  logic        img_readonly,
	input  logic [63:0] img_size,

	output logic [31:0] sd_lba,
	output logic        sd_rd,
	output logic        sd_wr,
	input  logic        sd_ack,
	input  logic  [8:0] sd_buff_addr,
	input  logic [15:0] sd_buff_dout,
	output logic [15:0] sd_buff_din,
	input  logic        sd_buff_wr
);

	localparam logic [7:0] ST_ERR  = 8'h01;
	localparam logic [7:0] ST_DRQ  = 8'h08;
	localparam logic [7:0] ST_DSC  = 8'h10;
	localparam logic [7:0] ST_DRDY = 8'h40;
	localparam logic [7:0] ST_BSY  = 8'h80;
	localparam logic [7:0] ST_READY = ST_DRDY | ST_DSC;
	localparam logic [7:0] ERR_ABRT = 8'h04;
	localparam logic [7:0] ERR_IDNF = 8'h10;

	typedef enum logic [4:0] {
		S_RESET_WAIT,
		S_SOFT_RESET,
		S_IDLE,
		S_READ_WAIT_ACK_LOW,
		S_READ_REQUEST,
		S_READ_STREAM,
		S_PRIME0,
		S_PRIME1,
		S_PRIME2,
		S_PRIME3,
		S_PRIME4,
		S_PRIME5,
		S_READ_DATA,
		S_IDENTIFY_BUILD,
		S_WRITE_DATA,
		S_WRITE_WAIT_ACK_LOW,
		S_WRITE_REQUEST,
		S_WRITE_COMPLETE
	} state_t;

	state_t state;
	logic [7:0] feature;
	logic [7:0] error_reg;
	logic [7:0] sector_count;
	logic [7:0] sector_number;
	logic [7:0] cylinder_low;
	logic [7:0] cylinder_high;
	logic [7:0] device_head;
	logic [7:0] status;
	logic [2:1] device_control;
	logic [7:0] block_count;
	logic       irq_pending;

	logic [16:0] reset_count;
	logic [31:0] current_lba;
	logic  [8:0] sectors_left;
	logic  [8:0] words_left;
	logic  [8:0] write_word;
	logic  [8:0] identify_index;
	logic [24:0] io_timeout_count;
	logic  [8:0] stream_next_addr;
	logic  [8:0] stream_write_count;
	logic        stream_error;

	(* ramstyle = "M10K, no_rw_check" *) logic [15:0] sector_even [0:127];
	(* ramstyle = "M10K, no_rw_check" *) logic [15:0] sector_odd  [0:127];
	logic [6:0] ram_read_pair;
	logic [15:0] ram_q_even;
	logic [15:0] ram_q_odd;
	logic        host_addr_odd;
	logic        sector_even_we;
	logic        sector_odd_we;
	logic  [6:0] sector_even_waddr;
	logic  [6:0] sector_odd_waddr;
	logic [15:0] sector_even_wdata;
	logic [15:0] sector_odd_wdata;

	logic [6:0] fifo_read_pair;
	logic       fifo_refill_odd;
	logic [15:0] fifo_w0;
	logic [15:0] fifo_w1;
	logic [15:0] fifo_w2;
	logic [15:0] fifo_w3;
	logic [15:0] fifo_pending_word;

	wire write_host_active = state == S_WRITE_WAIT_ACK_LOW ||
	                         state == S_WRITE_REQUEST ||
	                         state == S_WRITE_COMPLETE;
	// Declare these before their first use in the RAM address selector.
	// Some maintained simulators reject forward net references even though
	// Quartus accepts them. The expressions and behavior are unchanged.
	wire consume_pair = data32_read && status[3] && state == S_READ_DATA;
	wire consume_one  = state == S_READ_DATA && status[3] &&
	                   ((task_read && task_addr == 3'd0) ||
	                    (dma_read_enable && dma_request));

	// Explicit sensitivity keeps nested task-file reads portable in Icarus
	// and avoids a simulator delta-cycle loop on the board wrapper path.
	always @* begin
		if (write_host_active) begin
			ram_read_pair = sd_buff_addr[7:1];
		end else if (consume_pair) begin
			ram_read_pair = fifo_read_pair + 1'b1;
	end else if (consume_one) begin
		ram_read_pair = fifo_refill_odd ? fifo_read_pair : fifo_read_pair + 1'b1;
	end else begin
		ram_read_pair = fifo_read_pair;
	end
	end

	// Keep one write port per bank so Quartus can infer the 128x16 M10Ks.
	// The ordering matches the original sequential assignments: a core write
	// takes priority over a simultaneous host-buffer write to the same bank.
	always @* begin
		sector_even_we    = 1'b0;
		sector_odd_we     = 1'b0;
		sector_even_waddr = 7'd0;
		sector_odd_waddr  = 7'd0;
		sector_even_wdata = 16'h0000;
		sector_odd_wdata  = 16'h0000;

		// Only the acknowledged read-stream state owns the HPS buffer write
		// port.  hps_io can drain a delayed tail after a request is canceled or
		// across reset; accepting those beats would overwrite a new sector.
		if (!reset && state == S_READ_STREAM && sd_buff_wr) begin
			if (sd_buff_addr[0]) begin
				sector_odd_we    = 1'b1;
				sector_odd_waddr = sd_buff_addr[7:1];
				sector_odd_wdata = sd_buff_dout;
			end else begin
				sector_even_we    = 1'b1;
				sector_even_waddr = sd_buff_addr[7:1];
				sector_even_wdata = sd_buff_dout;
			end
		end

		if (state == S_IDENTIFY_BUILD) begin
			if (identify_index[0]) begin
				sector_odd_we    = 1'b1;
				sector_odd_waddr = identify_index[7:1];
				sector_odd_wdata = identify_word(identify_index);
			end else begin
				sector_even_we    = 1'b1;
				sector_even_waddr = identify_index[7:1];
				sector_even_wdata = identify_word(identify_index);
			end
		end

		if (task_write && task_addr == 3'd0 &&
		    state == S_WRITE_DATA && status[3]) begin
			if (write_word[0]) begin
				sector_odd_we    = 1'b1;
				sector_odd_waddr = write_word[7:1];
				sector_odd_wdata = task_wdata;
			end else begin
				sector_even_we    = 1'b1;
				sector_even_waddr = write_word[7:1];
				sector_even_wdata = task_wdata;
			end
		end
	end

	always_ff @(posedge clk) begin
		if (sector_even_we)
			sector_even[sector_even_waddr] <= sector_even_wdata;
		ram_q_even <= sector_even[ram_read_pair];
	end

	always_ff @(posedge clk) begin
		if (sector_odd_we)
			sector_odd[sector_odd_waddr] <= sector_odd_wdata;
		ram_q_odd <= sector_odd[ram_read_pair];
	end

	always_ff @(posedge clk) begin
		host_addr_odd <= sd_buff_addr[0];
	end

	always @* begin
		sd_buff_din = host_addr_odd ? ram_q_odd : ram_q_even;
	end

	function automatic [31:0] task_lba;
		logic [31:0] chs_lba;
		begin
			if (device_head[6]) begin
				task_lba = {4'b0000, device_head[3:0], cylinder_high,
				            cylinder_low, sector_number};
			end else begin
				chs_lba = ((({16'h0000, cylinder_high, cylinder_low} * 32'd16) +
				           {28'h0000000, device_head[3:0]}) * 32'd63);
				task_lba = chs_lba + {24'h000000, sector_number} - 32'd1;
			end
		end
	endfunction

	function automatic [15:0] identify_word(input logic [8:0] index);
		begin
			identify_word = 16'h0000;
			case (index)
				0:  identify_word = 16'h045a;
				1:  identify_word = 16'd2096;
				3:  identify_word = 16'd16;
				6:  identify_word = 16'd63;
				10,11,12,13,14,15,16,17,18,19: identify_word = 16'h3030;
				22: identify_word = 16'd4;
				23: identify_word = 16'h312e;
				24: identify_word = 16'h3020;
				25,26: identify_word = 16'h2020;
				27: identify_word = 16'h5155;
				28: identify_word = 16'h414e;
				29: identify_word = 16'h5455;
				30: identify_word = 16'h4d20;
				31: identify_word = 16'h4649;
				32: identify_word = 16'h5245;
				33: identify_word = 16'h4241;
				34: identify_word = 16'h4c4c;
				35: identify_word = 16'h2043;
				36: identify_word = 16'h5220;
				37: identify_word = 16'h342e;
				38: identify_word = 16'h3341;
				39: identify_word = 16'h5420;
				40,41,42,43,44,45,46: identify_word = 16'h2020;
				47: identify_word = 16'h8010;
				49: identify_word = 16'h0f03;
				51,52: identify_word = 16'd2;
				53: identify_word = 16'd3;
				54: identify_word = 16'd2096;
				55: identify_word = 16'd16;
				56: identify_word = 16'd63;
				57: identify_word = 16'h3d00;
				58: identify_word = 16'h0020;
				59: identify_word = block_count == 0 ? 16'h0000 : {8'h01, block_count};
				60: identify_word = 16'h3d00;
				61: identify_word = 16'h0020;
				62: identify_word = 16'h0007;
				63: identify_word = 16'h0407;
				64: identify_word = 16'h0003;
				65,66,68: identify_word = 16'h0078;
				67: identify_word = 16'h014d;
				default: identify_word = 16'h0000;
			endcase
		end
	endfunction

	function automatic [31:0] advanced_task_address;
		logic [7:0] next_sector;
		logic [7:0] next_cyl_low;
		logic [7:0] next_cyl_high;
		logic [7:0] next_head;
		begin
			next_sector  = sector_number;
			next_cyl_low = cylinder_low;
			next_cyl_high = cylinder_high;
			next_head = device_head;
			if (device_head[6]) begin
				next_sector = sector_number + 1'b1;
				if (sector_number == 8'hff) begin
					next_cyl_low = cylinder_low + 1'b1;
					if (cylinder_low == 8'hff) begin
						next_cyl_high = cylinder_high + 1'b1;
						if (cylinder_high == 8'hff)
							next_head[3:0] = device_head[3:0] + 1'b1;
					end
				end
			end else begin
				if (sector_number == 8'd63) begin
					next_sector = 8'd1;
					if (device_head[3:0] == 4'd15) begin
						next_head[3:0] = 4'd0;
						{next_cyl_high, next_cyl_low} =
							{cylinder_high, cylinder_low} + 1'b1;
					end else begin
						next_head[3:0] = device_head[3:0] + 1'b1;
					end
				end else begin
					next_sector = sector_number + 1'b1;
				end
			end
			advanced_task_address = {next_head, next_cyl_high, next_cyl_low, next_sector};
		end
	endfunction

	wire        image_readonly = img_readonly;
	wire [31:0] image_sectors = img_size[40:9];
	// The HPS contract supplies whole 512-byte sectors and the ATA address
	// path is 32-bit. Reject malformed metadata instead of presenting a
	// seemingly-ready disk whose sector count silently wrapped or truncated.
	wire image_size_valid = (img_size[63:41] == 23'd0) &&
	                        (img_size[8:0] == 9'd0) &&
	                        (image_sectors != 32'd0);
	// Widen before incrementing so an overflowing LBA cannot wrap into range.
	wire next_sector_in_image = ({1'b0, current_lba} + 33'd1) <
	                            {1'b0, image_sectors};

	always @* begin
		task_rdata = 16'h0000;
		if ((status & ST_BSY) != 8'h00 && task_addr != 3'd0) begin
			task_rdata = {8'h00, status};
		end else begin
			case (task_addr)
				3'd0: task_rdata = status[3] ? fifo_w0 : 16'h0000;
				3'd1: task_rdata = {8'h00, error_reg};
				3'd2: task_rdata = {8'h00, sector_count};
				3'd3: task_rdata = {8'h00, sector_number};
				3'd4: task_rdata = {8'h00, cylinder_low};
				3'd5: task_rdata = {8'h00, cylinder_high};
				3'd6: task_rdata = {8'h00, device_head};
				3'd7: task_rdata = {8'h00, status};
			endcase
		end

		control_rdata = control_read ? status : 8'h00;
		data32_rdata  = status[3] ? {fifo_w1, fifo_w0} : 32'h00000000;
		dma_read_data = status[3] ? fifo_w0 : 16'h0000;
		dma_request   = state == S_READ_DATA && status[3];
		irq           = irq_pending && !device_control[1];
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			feature          <= 8'h00;
			error_reg        <= 8'h01;
			sector_count     <= 8'h01;
			sector_number    <= 8'h01;
			cylinder_low     <= 8'h00;
			cylinder_high    <= 8'h00;
			device_head      <= 8'h00;
			status           <= ST_BSY;
			device_control   <= 2'b00;
			block_count      <= 8'h00;
			irq_pending      <= 1'b0;
			reset_count      <= RESET_CYCLES[16:0];
			current_lba      <= 32'h00000000;
			sectors_left     <= 9'd0;
			words_left       <= 9'd0;
			write_word       <= 9'd0;
			identify_index   <= 9'd0;
			io_timeout_count <= 25'd0;
			stream_next_addr <= 9'd0;
			stream_write_count <= 9'd0;
			stream_error     <= 1'b0;
			fifo_read_pair   <= 7'd0;
			fifo_refill_odd  <= 1'b0;
			fifo_w0          <= 16'h0000;
			fifo_w1          <= 16'h0000;
			fifo_w2          <= 16'h0000;
			fifo_w3          <= 16'h0000;
			fifo_pending_word <= 16'h0000;
			sd_lba           <= 32'h00000000;
			sd_rd            <= 1'b0;
			sd_wr            <= 1'b0;
			state            <= S_RESET_WAIT;
		end else begin
			// A status read acknowledges the interrupt visible before this edge.
			// Preserve a new completion raised below on the same edge: the bus
			// read still returned the preceding status (for example, BUSY).
			if (task_read && task_addr == 3'd7)
				irq_pending <= 1'b0;

			case (state)
				S_RESET_WAIT: begin
					status <= ST_BSY;
					if (reset_count != 0) begin
						reset_count <= reset_count - 1'b1;
					end else begin
						status        <= ST_READY;
						error_reg     <= 8'h01;
						sector_count  <= 8'h01;
						sector_number <= 8'h01;
						cylinder_low  <= 8'h00;
						cylinder_high <= 8'h00;
						device_head   <= 8'h00;
						state         <= S_IDLE;
					end
				end

				S_SOFT_RESET: begin
					status <= ST_BSY;
					sd_rd  <= 1'b0;
					sd_wr  <= 1'b0;
				end

				S_READ_WAIT_ACK_LOW: begin
					if (!sd_ack) begin
						sd_rd <= 1'b1;
						state <= S_READ_REQUEST;
					end
				end

				S_READ_REQUEST: begin
					if (sd_ack) begin
						sd_rd <= 1'b0;
						stream_next_addr <= 9'd0;
						stream_write_count <= 9'd0;
						stream_error <= 1'b0;
						state <= S_READ_STREAM;
					end
				end

				S_READ_STREAM: begin
					if (sd_buff_wr) begin
						// hps_io writes the sector buffer in address order. Do not
						// expose a partially filled M10K merely because address 255
						// appeared after a dropped or duplicated host beat.
						if (sd_buff_addr != stream_next_addr)
							stream_error <= 1'b1;
						if (stream_write_count != 9'd511)
							stream_write_count <= stream_write_count + 1'b1;
						if (sd_buff_addr != 9'd255 && stream_next_addr != 9'd255)
							stream_next_addr <= stream_next_addr + 1'b1;

						if (sd_buff_addr == 9'd255) begin
							if (!stream_error && sd_buff_addr == stream_next_addr &&
							    stream_write_count == 9'd255) begin
								fifo_read_pair <= 7'd0;
								fifo_refill_odd <= 1'b0;
								fifo_pending_word <= 16'h0000;
								state <= S_PRIME0;
							end else begin
								status <= ST_READY | ST_ERR;
								error_reg <= ERR_ABRT;
								irq_pending <= 1'b1;
								state <= S_IDLE;
							end
						end
					end
				end

				S_PRIME0: state <= S_PRIME1;
				S_PRIME1: state <= S_PRIME2;
				S_PRIME2: begin
					fifo_w0 <= ram_q_even;
					fifo_w1 <= ram_q_odd;
					fifo_read_pair <= 7'd1;
					state <= S_PRIME3;
				end
				S_PRIME3: state <= S_PRIME4;
				S_PRIME4: begin
					fifo_w2 <= ram_q_even;
					fifo_w3 <= ram_q_odd;
					fifo_read_pair <= 7'd2;
					state <= S_PRIME5;
				end
				S_PRIME5: begin
					words_left      <= 9'd256;
					fifo_refill_odd <= 1'b0;
					status          <= ST_READY | ST_DRQ;
					irq_pending     <= 1'b1;
					state           <= S_READ_DATA;
				end

				S_READ_DATA: begin
					if (consume_pair) begin
						if (words_left <= 9'd2) begin
							status      <= ST_READY;
							sector_count <= 8'h00;
							if (sectors_left > 9'd1) begin
								// End this sector's notification before preparing the next.
								// A late status read must not merge two ready events.
								irq_pending <= 1'b0;
								sectors_left <= sectors_left - 1'b1;
								sector_count <= sectors_left[7:0] - 8'd1;
								current_lba  <= current_lba + 1'b1;
								sd_lba       <= current_lba + 1'b1;
								{device_head, cylinder_high, cylinder_low, sector_number} <= advanced_task_address();
								status <= ST_READY | ST_BSY;
								state  <= S_READ_WAIT_ACK_LOW;
								if (!next_sector_in_image) begin
									status      <= ST_READY | ST_ERR;
									error_reg   <= ERR_IDNF;
									irq_pending <= 1'b1;
									state       <= S_IDLE;
								end
							end else begin
								state <= S_IDLE;
							end
						end else begin
							fifo_w0 <= fifo_w2;
							fifo_w1 <= fifo_w3;
							fifo_w2 <= ram_q_even;
							fifo_w3 <= ram_q_odd;
							fifo_read_pair <= fifo_read_pair + 1'b1;
							if (fifo_refill_odd) begin
								fifo_w2 <= fifo_pending_word;
								fifo_w3 <= ram_q_even;
								fifo_pending_word <= ram_q_odd;
								fifo_refill_odd <= 1'b1;
							end else begin
								fifo_refill_odd <= 1'b0;
							end
							words_left <= words_left - 9'd2;
						end
					end else if (consume_one) begin
						if (words_left == 9'd1) begin
							status       <= ST_READY;
							sector_count <= 8'h00;
							if (sectors_left > 9'd1) begin
								irq_pending <= 1'b0;
								sectors_left <= sectors_left - 1'b1;
								sector_count <= sectors_left[7:0] - 8'd1;
								current_lba  <= current_lba + 1'b1;
								sd_lba       <= current_lba + 1'b1;
								{device_head, cylinder_high, cylinder_low, sector_number} <= advanced_task_address();
								status <= ST_READY | ST_BSY;
								state  <= S_READ_WAIT_ACK_LOW;
								if (!next_sector_in_image) begin
									status      <= ST_READY | ST_ERR;
									error_reg   <= ERR_IDNF;
									irq_pending <= 1'b1;
									state       <= S_IDLE;
								end
							end else begin
								state <= S_IDLE;
							end
						end else begin
							fifo_w0 <= fifo_w1;
							fifo_w1 <= fifo_w2;
							fifo_w2 <= fifo_w3;
							if (!fifo_refill_odd) begin
								fifo_w3 <= ram_q_even;
								fifo_pending_word <= ram_q_odd;
								fifo_read_pair <= fifo_read_pair + 1'b1;
								fifo_refill_odd <= 1'b1;
							end else begin
								fifo_w3 <= fifo_pending_word;
								fifo_refill_odd <= 1'b0;
							end
							words_left <= words_left - 1'b1;
						end
					end
				end

				S_IDENTIFY_BUILD: begin
					if (identify_index == 9'd255) begin
						fifo_read_pair <= 7'd0;
						fifo_refill_odd <= 1'b0;
						fifo_pending_word <= 16'h0000;
						state <= S_PRIME0;
					end else begin
						identify_index <= identify_index + 1'b1;
					end
				end

				S_WRITE_DATA: begin
					status <= ST_READY | ST_DRQ;
				end

				S_WRITE_WAIT_ACK_LOW: begin
					if (!sd_ack) begin
						sd_wr <= 1'b1;
						state <= S_WRITE_REQUEST;
					end
				end

				S_WRITE_REQUEST: begin
					if (sd_ack) begin
						sd_wr <= 1'b0;
						state <= S_WRITE_COMPLETE;
					end
				end

				S_WRITE_COMPLETE: begin
					if (!sd_ack) begin
						if (sectors_left > 9'd1) begin
							sectors_left <= sectors_left - 1'b1;
							sector_count <= sectors_left[7:0] - 8'd1;
							current_lba  <= current_lba + 1'b1;
							sd_lba       <= current_lba + 1'b1;
							write_word    <= 9'd0;
							{device_head, cylinder_high, cylinder_low, sector_number} <= advanced_task_address();
							status <= ST_READY | ST_DRQ;
							irq_pending <= 1'b1;
							state <= S_WRITE_DATA;
							if (!next_sector_in_image) begin
								status    <= ST_READY | ST_ERR;
								error_reg <= ERR_IDNF;
								state     <= S_IDLE;
							end
						end else begin
							sector_count <= 8'h00;
							status <= ST_READY;
							irq_pending <= 1'b1;
							state <= S_IDLE;
						end
					end
				end

			default: state <= S_IDLE;
			endcase

			// A missing HPS acknowledgement or buffer stream must become a
			// guest-visible ATA error instead of an unbounded BUSY condition.
			// The board watchdog remains a last-resort reset, while this path
			// lets firmware recover the disk interface and keep video alive.
			if (state == S_READ_WAIT_ACK_LOW || state == S_READ_REQUEST ||
			    state == S_READ_STREAM || state == S_WRITE_WAIT_ACK_LOW ||
			    state == S_WRITE_REQUEST || state == S_WRITE_COMPLETE) begin
				if (io_timeout_count < IO_TIMEOUT_CYCLES)
					io_timeout_count <= io_timeout_count + 1'b1;
				else begin
					io_timeout_count <= 25'd0;
					sd_rd <= 1'b0;
					sd_wr <= 1'b0;
					sectors_left <= 9'd0;
					words_left <= 9'd0;
					status <= ST_READY | ST_ERR;
					error_reg <= ERR_ABRT;
					irq_pending <= 1'b1;
					state <= S_IDLE;
				end
			end else begin
				io_timeout_count <= 25'd0;
			end

			if (control_write) begin
				device_control <= control_wdata;
				if (control_wdata[2]) begin
					sectors_left <= 9'd0;
					words_left   <= 9'd0;
					write_word   <= 9'd0;
					status       <= ST_BSY;
					irq_pending  <= 1'b0;
					io_timeout_count <= 25'd0;
					stream_next_addr <= 9'd0;
					stream_write_count <= 9'd0;
					stream_error <= 1'b0;
					sd_rd        <= 1'b0;
					sd_wr        <= 1'b0;
					state        <= S_SOFT_RESET;
				end else if (device_control[2]) begin
					reset_count <= RESET_CYCLES[16:0];
					io_timeout_count <= 25'd0;
					state       <= S_RESET_WAIT;
				end
			end

			if (task_write) begin
				if (status[3] && task_addr != 3'd0) begin
					status      <= ST_READY | ST_ERR;
					error_reg   <= ERR_ABRT;
					irq_pending <= 1'b0;
				end

				case (task_addr)
					3'd0: begin
						if (state == S_WRITE_DATA && status[3]) begin
							if (write_word == 9'd255) begin
								write_word <= 9'd0;
								status <= ST_READY | ST_BSY;
								state <= S_WRITE_WAIT_ACK_LOW;
							end else begin
								write_word <= write_word + 1'b1;
							end
						end
					end
					3'd1: feature       <= task_wdata[7:0];
					3'd2: sector_count  <= task_wdata[7:0];
					3'd3: sector_number <= task_wdata[7:0];
					3'd4: cylinder_low  <= task_wdata[7:0];
					3'd5: cylinder_high <= task_wdata[7:0];
					3'd6: device_head   <= task_wdata[7:0];
					3'd7: begin
						error_reg    <= 8'h00;
						irq_pending  <= 1'b0;
						case (task_wdata[7:0])
							8'h10,8'h11,8'h12,8'h13,8'h14,8'h15,8'h16,8'h17,
							8'h18,8'h19,8'h1a,8'h1b,8'h1c,8'h1d,8'h1e,8'h1f,
							8'h70,8'h90,8'h91,8'he0,8'he1,8'he2,8'he3,8'he7,
							8'hef: begin
								if (task_wdata[7:0] == 8'hef &&
								    !(feature == 8'h01 || feature == 8'h03 || feature == 8'h55 ||
								      feature == 8'h66 || feature == 8'h81 || feature == 8'haa ||
								      feature == 8'hbb || feature == 8'hcc)) begin
									status    <= ST_READY | ST_ERR;
									error_reg <= ERR_ABRT;
								end else begin
									status    <= ST_READY;
									error_reg <= task_wdata[7:0] == 8'h90 ? 8'h01 : 8'h00;
								end
								irq_pending <= 1'b1;
							end

							8'he5: begin
								sector_count <= 8'hff;
								status       <= ST_READY;
								irq_pending  <= 1'b1;
							end

							8'hc6: begin
								block_count <= sector_count;
								status      <= ST_READY;
								irq_pending <= 1'b1;
							end

							8'h40,8'h41: begin
				if (!image_size_valid || task_lba() >= image_sectors) begin
									status      <= ST_READY | ST_ERR;
									error_reg   <= ERR_IDNF;
								end else begin
									status       <= ST_READY;
									sector_count <= 8'h00;
								end
								irq_pending <= 1'b1;
							end

							8'h20,8'h21,8'hc4,8'hc8: begin
				if (!image_size_valid || task_lba() >= image_sectors) begin
									status      <= ST_READY | ST_ERR;
									error_reg   <= ERR_IDNF;
									irq_pending <= 1'b1;
								end else begin
									current_lba  <= task_lba();
									sd_lba       <= task_lba();
									sectors_left <= sector_count == 0 ? 9'd256 : {1'b0, sector_count};
									status        <= ST_READY | ST_BSY;
									state         <= S_READ_WAIT_ACK_LOW;
								end
							end

							8'h30,8'h31,8'hc5,8'hca: begin
				if (!image_size_valid || image_readonly || task_lba() >= image_sectors) begin
									status      <= ST_READY | ST_ERR;
									error_reg   <= image_readonly ? ERR_ABRT : ERR_IDNF;
									irq_pending <= 1'b1;
								end else begin
									current_lba  <= task_lba();
									sd_lba       <= task_lba();
									sectors_left <= sector_count == 0 ? 9'd256 : {1'b0, sector_count};
									write_word    <= 9'd0;
									status        <= ST_READY | ST_DRQ;
									state         <= S_WRITE_DATA;
								end
							end

							8'hec: begin
								// IDENTIFY owns one block, independent of a canceled command.
								sectors_left   <= 9'd1;
								identify_index <= 9'd0;
								status         <= ST_READY | ST_BSY;
								state          <= S_IDENTIFY_BUILD;
							end

							default: begin
								status      <= ST_READY | ST_ERR;
								error_reg   <= ERR_ABRT;
								irq_pending <= 1'b1;
							end
						endcase
					end
				endcase
			end
		end

	end

endmodule
