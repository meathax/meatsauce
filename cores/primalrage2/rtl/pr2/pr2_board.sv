// GPL-2.0-or-later
// Atari COH-1000W glue used by Primal Rage II.
// Address behavior follows MAME zn.cpp/vt83c461.cpp at 49e9a1f7.

module pr2_board #(
	parameter int unsigned ATA_RESET_CYCLES = 67_738
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        pause,

	input  logic [28:0] bus_addr,
	input  logic [31:0] bus_data_write,
	input  logic  [3:0] bus_write_mask,
	input  logic  [1:0] bus_reqsize,
	input  logic        bus_read,
	input  logic        bus_write,
	output logic [31:0] bus_data_read,

	output logic        ata_irq,
	output logic        dma_request,
	input  logic        dma_read_enable,
	output logic [15:0] dma_read_data,
	output logic        watchdog_reset,

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

	localparam logic [28:0] WATCHDOG_BASE = 29'h1f000000;
	localparam logic [28:0] VT16_BASE     = 29'h1f7e4000;
	localparam logic [28:0] IRQ_BASE      = 29'h1f7e8000;
	localparam logic [28:0] VT32_BASE     = 29'h1f7f4000;
	localparam logic [24:0] WATCHDOG_LIMIT = 25'd20_321_279;

	logic  [7:0] vt_unknown;
	logic  [7:0] vt_selector;
	logic  [7:0] vt_config [0:15];
	logic [15:0] irq_control;
	logic [15:0] data32_latch;
	logic [24:0] watchdog_count;

	logic  [2:0] ata_task_addr;
	logic        ata_task_read;
	logic        ata_task_write;
	logic [15:0] ata_task_wdata;
	wire  [15:0] ata_task_rdata;
	logic        ata_control_read;
	logic        ata_control_write;
	logic  [2:1] ata_control_wdata;
	logic  [7:0] ata_control_rdata;
	logic        ata_data32_read;
	logic [31:0] ata_data32_rdata;
	logic        ata_irq_raw;

	logic [31:0] read_mux;
	logic [11:0] vt16_offset;
	logic [11:0] vt16_access_offset;
	logic [11:0] vt32_offset;
	logic  [1:0] write_lane;
	logic  [7:0] write_byte;
	logic [15:0] write_half;
	logic  [7:0] vt_config_read;
	logic        watchdog_kick;

	function automatic [31:0] lane_byte(input logic [7:0] value,
	                                                input logic [1:0] lane);
		lane_byte = {24'h000000, value} << (lane * 8);
	endfunction

	function automatic [31:0] lane_half(input logic [15:0] value,
	                                                input logic lane);
		lane_half = lane ? {value, 16'h0000} : {16'h0000, value};
	endfunction

	// Use explicit sensitivity for broad simulator compatibility.  These
	// decode helpers are pure combinational logic; avoiding always_comb's
	// implicit sensitivity quirks also prevents a delta-cycle loop in Icarus
	// when a nested ATA task-file read is asserted.
	always @* begin
		write_lane = bus_addr[1:0];
		// The PSX CPU presents stores on an aligned word bus and uses the
		// byte-enable mask to select the addressed lane.  Direct board benches
		// may still present a byte-sized request with the exact byte address.
		if (bus_reqsize == 2'b10) begin
			case (bus_write_mask)
				4'b0010: write_lane = 2'd1;
				4'b0100: write_lane = 2'd2;
				4'b1000: write_lane = 2'd3;
				4'b1100: write_lane = 2'd2;
				default: write_lane = 2'd0;
			endcase
		end
		// Select the byte explicitly so the lane extraction is width-clean in
		// synthesis and cannot rely on an implicit 32-to-8 truncation.
		case (write_lane)
			2'd0: write_byte = bus_data_write[7:0];
			2'd1: write_byte = bus_data_write[15:8];
			2'd2: write_byte = bus_data_write[23:16];
			default: write_byte = bus_data_write[31:24];
		endcase
		write_half = write_lane[1] ? bus_data_write[31:16] : bus_data_write[15:0];
	end

	// A watchdog MMIO write is a heartbeat, independent of which byte lane
	// the CPU bridge used. The old lower-two-lane-only test ignored valid
	// upper-halfword/word stores and could reset a healthy guest at the timeout.
	always @* begin
		watchdog_kick = bus_write && bus_addr >= WATCHDOG_BASE &&
		                bus_addr < WATCHDOG_BASE + 29'h4 &&
		                ((bus_reqsize == 2'b10) || (|bus_write_mask));
	end

	always @* begin
		vt16_offset = bus_addr[11:0] - VT16_BASE[11:0];
		vt16_access_offset = vt16_offset;
		if (bus_write && bus_reqsize == 2'b10)
			vt16_access_offset = vt16_offset + write_lane;
		vt32_offset = bus_addr[11:0] - VT32_BASE[11:0];
		case (vt16_access_offset[3:2])
			2'd1: vt_config_read = vt_unknown;
			2'd2: vt_config_read = vt_selector;
			2'd3: vt_config_read = vt_selector < 8'd16 ? vt_config[vt_selector[3:0]] : 8'h00;
			default: vt_config_read = 8'h00;
		endcase
	end

	always @* begin
		ata_task_addr      = 3'd0;
		ata_task_read      = 1'b0;
		ata_task_write     = 1'b0;
		if (bus_reqsize == 2'b00 || bus_write_mask == 4'b0001 ||
			bus_write_mask == 4'b0010 || bus_write_mask == 4'b0100 ||
			bus_write_mask == 4'b1000)
			ata_task_wdata = {8'h00, write_byte};
		else
			ata_task_wdata = write_half;
		ata_control_read   = 1'b0;
		ata_control_write  = 1'b0;
		ata_control_wdata  = write_byte[2:1];
		ata_data32_read    = 1'b0;
		read_mux           = 32'h00000000;

		if (bus_addr >= VT16_BASE && bus_addr < VT16_BASE + 29'h1000) begin
			if (vt16_access_offset >= 12'h030 && vt16_access_offset < 12'h040) begin
				if (bus_read) begin
					if (vt16_access_offset[1:0] == 2'b00)
						read_mux = lane_byte(vt_config_read, bus_addr[1:0]);
				end
			end else if (vt16_access_offset >= 12'h1f0 && vt16_access_offset < 12'h1f8) begin
				ata_task_addr  = vt16_access_offset[2:0];
				ata_task_read  = bus_read;
				ata_task_write = bus_write;
			end else if (vt16_access_offset >= 12'h3f0 && vt16_access_offset < 12'h3f8) begin
				if (vt16_access_offset[2:0] == 3'd6) begin
					ata_control_read  = bus_read;
					ata_control_write = bus_write;
				end else if (vt16_access_offset[2:0] == 3'd7 && bus_read) begin
					read_mux = lane_byte(8'h01, bus_addr[1:0]);
				end
			end
		end else if (bus_addr >= IRQ_BASE && bus_addr < IRQ_BASE + 29'h4) begin
			if (bus_read) begin
				case (bus_reqsize)
					2'b00: read_mux = lane_byte(bus_addr[0] ? irq_control[15:8] :
					                                      irq_control[7:0], bus_addr[1:0]);
					2'b01: read_mux = lane_half(irq_control, bus_addr[1]);
					default: read_mux = {irq_control, irq_control};
				endcase
			end
		end else if (bus_addr >= VT32_BASE && bus_addr < VT32_BASE + 29'h1000) begin
			if (bus_read) begin
				if (vt32_offset == 12'h1f0) begin
					ata_data32_read = 1'b1;
				end else if (vt32_offset == 12'h1f2) begin
					read_mux = bus_reqsize == 2'b00 ?
						lane_byte(data32_latch[7:0], bus_addr[1:0]) :
						lane_half(data32_latch, bus_addr[1]);
				end
			end
		end
	end

	assign ata_irq = ata_irq_raw && irq_control[0];

	pr2_ata #(.RESET_CYCLES(ATA_RESET_CYCLES)) ata (
		.clk(clk),
		.reset(reset),
		.task_addr(ata_task_addr),
		.task_read(ata_task_read),
		.task_write(ata_task_write),
		.task_wdata(ata_task_wdata),
		.task_rdata(ata_task_rdata),
		.control_read(ata_control_read),
		.control_write(ata_control_write),
		.control_wdata(ata_control_wdata),
		.control_rdata(ata_control_rdata),
		.data32_read(ata_data32_read),
		.data32_rdata(ata_data32_rdata),
		.irq(ata_irq_raw),
		.dma_request(dma_request),
		.dma_read_enable(dma_read_enable),
		.dma_read_data(dma_read_data),
		.img_readonly(img_readonly),
		.img_size(img_size),
		.sd_lba(sd_lba),
		.sd_rd(sd_rd),
		.sd_wr(sd_wr),
		.sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr)
	);

	integer i;
	always_ff @(posedge clk) begin
		bus_data_read  <= 32'h00000000;
		watchdog_reset <= 1'b0;

		if (reset) begin
			vt_unknown    <= 8'h00;
			vt_selector   <= 8'h00;
			irq_control   <= 16'h0000;
			data32_latch  <= 16'h0000;
			watchdog_count <= 25'd0;
			for (i = 0; i < 16; i = i + 1)
				vt_config[i] <= 8'h00;
		end else begin
			if (bus_read) begin
				if (ata_task_read) begin
					if (bus_reqsize == 2'b00)
						bus_data_read <= lane_byte(ata_task_rdata[7:0], bus_addr[1:0]);
					else
						bus_data_read <= bus_addr[1] ? {ata_task_rdata, 16'h0000} :
							{16'h0000, ata_task_rdata};
				end else if (ata_control_read) begin
					bus_data_read <= bus_reqsize == 2'b00 ?
						lane_byte(ata_control_rdata, bus_addr[1:0]) :
						lane_half({8'h00, ata_control_rdata}, bus_addr[1]);
				end else if (ata_data32_read) begin
					if (bus_reqsize == 2'b10)
						bus_data_read <= ata_data32_rdata;
					else if (bus_reqsize == 2'b00)
						bus_data_read <= lane_byte(ata_data32_rdata[7:0], bus_addr[1:0]);
					else
						bus_data_read <= lane_half(ata_data32_rdata[15:0], bus_addr[1]);
				end else begin
					bus_data_read <= read_mux;
				end
			end

			if (ata_data32_read)
				data32_latch <= ata_data32_rdata[31:16];

			if (bus_write && bus_addr >= VT16_BASE &&
			    bus_addr < VT16_BASE + 29'h1000 &&
			    vt16_access_offset >= 12'h030 && vt16_access_offset < 12'h040) begin
				case (vt16_access_offset[3:2])
					2'd1: vt_unknown  <= vt16_access_offset[1:0] == 2'b00 ? write_byte : 8'h00;
					2'd2: vt_selector <= vt16_access_offset[1:0] == 2'b00 ? write_byte : 8'h00;
					2'd3: if (vt_selector < 8'd16)
						vt_config[vt_selector[3:0]] <=
							vt16_access_offset[1:0] == 2'b00 ? write_byte : 8'h00;
					default: begin end
				endcase
			end

			if (bus_write && bus_addr >= IRQ_BASE && bus_addr < IRQ_BASE + 29'h4) begin
				if (bus_write_mask[0]) irq_control[7:0]  <= bus_data_write[7:0];
				if (bus_write_mask[1]) irq_control[15:8] <= bus_data_write[15:8];
				if (bus_write_mask[2]) irq_control[7:0]  <= bus_data_write[23:16];
				if (bus_write_mask[3]) irq_control[15:8] <= bus_data_write[31:24];
			end

			if (watchdog_kick) begin
				watchdog_count <= 25'd0;
			end else if (!pause && watchdog_count == WATCHDOG_LIMIT) begin
				watchdog_count <= 25'd0;
				watchdog_reset <= 1'b1;
			end else if (!pause) begin
				watchdog_count <= watchdog_count + 1'b1;
			end
		end
	end

endmodule
