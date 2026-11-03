// SPDX-License-Identifier: GPL-3.0-or-later
// Retained rotation writes and read ownership for Leland's shared DDRAM port.
//
// The framework screen_rotate producer emits one-cycle write requests and does
// not honor DDRAM_BUSY. This block stores the complete write tuple, arbitrates
// it with the ROM loader and CRT retimer, and keeps read-response ownership
// until DDRAM_DOUT_READY. A full write queue or an orphan read response is a
// sticky fault; callers must blank the framebuffer on fault.
module leland_ddr_arbiter #(
	parameter integer WRITE_DEPTH = 512,
	parameter integer READ_DEPTH  = 256
)(
	input             clk,
	input             reset,

	input             rot_we,
	input      [28:0] rot_addr,
	input      [63:0] rot_din,
	input       [7:0] rot_be,
	input       [7:0] rot_burstcnt,
	output            write_queue_empty,
	output reg        fault,

	input             loader_acquire,
	input      [28:0] loader_addr,
	input             loader_read,
	output            loader_busy,
	output     [63:0] loader_rdata,
	output            loader_rdata_ready,

	input      [28:0] retimer_addr,
	input      [63:0] retimer_din,
	input             retimer_read,
	input             retimer_we,
	output            retimer_busy,
	output     [63:0] retimer_rdata,
	output            retimer_rdata_ready,

	input             ddram_busy,
	input      [63:0] ddram_rdata,
	input             ddram_rdata_ready,
	output reg [28:0] ddram_addr,
	output reg [63:0] ddram_din,
	output reg  [7:0] ddram_be,
	output reg  [7:0] ddram_burstcnt,
	output reg        ddram_read,
	output reg        ddram_we
);

localparam integer WRITE_PTR_W = (WRITE_DEPTH < 2) ? 1 : $clog2(WRITE_DEPTH);
localparam integer WRITE_CNT_W = $clog2(WRITE_DEPTH + 1);
localparam integer READ_PTR_W  = (READ_DEPTH < 2) ? 1 : $clog2(READ_DEPTH);
localparam integer READ_CNT_W  = $clog2(READ_DEPTH + 1);
localparam integer WRITE_PACKET_W = 8 + 29 + 64 + 8;
localparam [1:0] OWNER_NONE = 2'd0, OWNER_LOADER = 2'd1, OWNER_RETIM = 2'd2;

// Keep the packet store in reset-free synchronous RAM processes so Quartus can
// infer embedded memory. The output register is intentionally not reset; the
// queue count and head bypass prevent its contents from being observed before
// a valid packet has been written.
(* ramstyle = "M10K" *) reg [WRITE_PACKET_W-1:0] write_mem [0:WRITE_DEPTH-1];
reg [WRITE_PACKET_W-1:0] write_ram_data;
reg [WRITE_PACKET_W-1:0] write_ram_bypass_data;
reg write_ram_bypass_valid = 1'b0;
reg [WRITE_PACKET_W-1:0] write_head;
reg [WRITE_PTR_W-1:0] write_wp = {WRITE_PTR_W{1'b0}};
reg [WRITE_PTR_W-1:0] write_rp = {WRITE_PTR_W{1'b0}};
reg [WRITE_CNT_W-1:0] write_count = {WRITE_CNT_W{1'b0}};

wire write_empty = (write_count == 0);
wire write_full  = (write_count == WRITE_DEPTH);
assign write_queue_empty = write_empty;

reg read_owner_mem [0:READ_DEPTH-1]; // 0 = retimer, 1 = loader
reg [READ_PTR_W-1:0] read_wp = {READ_PTR_W{1'b0}};
reg [READ_PTR_W-1:0] read_rp = {READ_PTR_W{1'b0}};
reg [READ_CNT_W-1:0] read_count = {READ_CNT_W{1'b0}};
reg last_grant_rotation = 1'b0;
reg loader_request_accepted = 1'b0;
reg grant_locked = 1'b0;
reg [1:0] grant_owner = OWNER_NONE;
initial fault = 1'b0;

wire read_pop = ddram_rdata_ready && (read_count != 0);
wire read_tag_space = (read_count < READ_DEPTH) || read_pop;

wire rotation_pending = !write_empty;
wire retimer_pending = retimer_read || retimer_we;

// Do not let ROM replay take the port until all earlier work has drained.
// This preserves the retimer's read-response stream and gives queued rotation
// writes an opportunity to finish before the loader starts its exclusive read
// sequence. The loader observes the barrier as BUSY and holds its request.
wire loader_barrier_clear = write_empty && !rot_we &&
							!(retimer_read || retimer_we) && (read_count == 0);
wire loader_eligible = loader_acquire && loader_read &&
						 (loader_request_accepted || loader_barrier_clear) && read_tag_space;

wire retimer_eligible = retimer_pending && (!retimer_read || read_tag_space);
wire raw_rotation = !loader_eligible && rotation_pending &&
						(!retimer_eligible || !last_grant_rotation);
wire raw_retimer = !loader_eligible && retimer_eligible &&
					  (!rotation_pending || last_grant_rotation);
wire choose_rotation = grant_locked ? grant_owner==2'd3 : raw_rotation;
wire choose_retimer = grant_locked ? grant_owner==OWNER_RETIM : raw_retimer;
wire choose_loader = grant_locked ? grant_owner==OWNER_LOADER : loader_eligible;

wire accept_rotation = choose_rotation && !ddram_busy;
wire accept_loader_read = choose_loader && loader_read && !ddram_busy;
wire accept_retimer_read = choose_retimer && retimer_read && !ddram_busy;
wire accepted_read = accept_loader_read || accept_retimer_read;
// Some DDR test doubles and bridges can return a read on its acceptance edge.
// Route that response directly and do not leave a stale owner tag behind.
wire immediate_read_response = ddram_rdata_ready && (read_count == 0) && accepted_read;
wire read_push = accepted_read && !immediate_read_response;
wire write_push = rot_we && !fault && (!write_full || accept_rotation);
wire write_pop = accept_rotation;

wire [WRITE_PACKET_W-1:0] write_packet = {rot_burstcnt, rot_addr, rot_din, rot_be};
wire [WRITE_PTR_W-1:0] write_next_rp = write_rp + {{(WRITE_PTR_W-1){1'b0}}, 1'b1};
wire [WRITE_PTR_W-1:0] write_nextnext_rp = write_next_rp + {{(WRITE_PTR_W-1){1'b0}}, 1'b1};
// After a pop, prefetch one packet beyond the new head so the registered RAM
// output is ready for a consecutive pop. At all other times, prefetch the
// packet immediately after the current head.
wire [WRITE_PTR_W-1:0] write_ram_read_addr = write_pop ? write_nextnext_rp : write_next_rp;
wire write_ram_collision = write_push && (write_wp == write_ram_read_addr);

assign loader_busy = ddram_busy ||
					 (loader_acquire && !loader_read && !loader_barrier_clear) ||
					 (loader_read && !choose_loader);
assign retimer_busy = ddram_busy || !choose_retimer;

assign loader_rdata = ddram_rdata;
assign retimer_rdata = ddram_rdata;

wire [1:0] response_owner = (read_count != 0) ?
							 (read_owner_mem[read_rp] ? OWNER_LOADER : OWNER_RETIM) :
							 (accept_loader_read ? OWNER_LOADER :
							  accept_retimer_read ? OWNER_RETIM : OWNER_NONE);
assign loader_rdata_ready = ddram_rdata_ready && (response_owner == OWNER_LOADER);
assign retimer_rdata_ready = ddram_rdata_ready && (response_owner == OWNER_RETIM);

// Isolated, reset-free RAM read/write processes preserve the existing
// one-packet-per-cycle head timing. A separate bypass register handles a
// same-address read/write collision without putting reset on the RAM output.
always @(posedge clk) begin
	if (!reset && write_push)
		write_mem[write_wp] <= write_packet;
end

always @(posedge clk) begin
	write_ram_data <= write_mem[write_ram_read_addr];
end

always @(posedge clk) begin
	if (reset) begin
		write_ram_bypass_valid <= 1'b0;
	end else begin
		write_ram_bypass_valid <= write_ram_collision;
		if (write_ram_collision)
			write_ram_bypass_data <= write_packet;
	end
end

`ifndef SYNTHESIS
initial begin
	if (WRITE_DEPTH < 2 || (WRITE_DEPTH & (WRITE_DEPTH - 1)) != 0)
		$error("WRITE_DEPTH must be a power of two >= 2");
	if (READ_DEPTH < 2 || (READ_DEPTH & (READ_DEPTH - 1)) != 0)
		$error("READ_DEPTH must be a power of two >= 2");
end
`endif

// Retain an Avalon grant until its command is actually accepted. A newly
// queued rotation packet must not replace a stalled foreground/retimer read.
always @(posedge clk) begin
 if (reset) begin grant_locked<=1'b0; grant_owner<=OWNER_NONE; end
 else if ((ddram_read || ddram_we) && ddram_busy) begin
  grant_locked<=1'b1;
  grant_owner<=choose_loader ? OWNER_LOADER : choose_retimer ? OWNER_RETIM : 2'd3;
 end else if (ddram_read || ddram_we) grant_locked<=1'b0;
end

always @* begin
	ddram_addr     = 29'd0;
	ddram_din      = 64'd0;
	ddram_be       = 8'hFF;
	ddram_burstcnt = 8'd1;
	ddram_read     = 1'b0;
	ddram_we       = 1'b0;

	if (choose_loader) begin
		ddram_addr = loader_addr;
		ddram_read = loader_read;
	end else if (choose_retimer) begin
		ddram_addr = retimer_addr;
		ddram_din  = retimer_din;
		ddram_read = retimer_read;
		ddram_we   = retimer_we;
	end else if (choose_rotation) begin
		ddram_burstcnt = write_head[WRITE_PACKET_W-1 -: 8];
		ddram_addr     = write_head[WRITE_PACKET_W-9 -: 29];
		ddram_din      = write_head[71:8];
		ddram_be       = write_head[7:0];
		ddram_we       = 1'b1;
	end
end

always @(posedge clk) begin
	if (reset) begin
		write_wp <= {WRITE_PTR_W{1'b0}};
		write_rp <= {WRITE_PTR_W{1'b0}};
		write_count <= {WRITE_CNT_W{1'b0}};
		write_head <= {WRITE_PACKET_W{1'b0}};
		read_wp <= {READ_PTR_W{1'b0}};
		read_rp <= {READ_PTR_W{1'b0}};
		read_count <= {READ_CNT_W{1'b0}};
		last_grant_rotation <= 1'b0;
		loader_request_accepted <= 1'b0;
		fault <= 1'b0;
	end else begin
		if (rot_we && fault == 1'b0 && write_full && !accept_rotation)
			fault <= 1'b1;
		if (ddram_rdata_ready && (read_count == 0) && !accepted_read)
			fault <= 1'b1;

		if (write_push) begin
			write_wp <= write_wp + {{(WRITE_PTR_W-1){1'b0}}, 1'b1};
		end
		if (write_pop) begin
			write_rp <= write_next_rp;
			if (write_count > 1)
				write_head <= write_ram_bypass_valid ? write_ram_bypass_data : write_ram_data;
			else if (write_push) write_head <= write_packet;
		end else if (write_empty && write_push) begin
			write_head <= write_packet;
		end
		case ({write_push, write_pop})
			2'b10: write_count <= write_count + 1'b1;
			2'b01: write_count <= write_count - 1'b1;
			default: write_count <= write_count;
		endcase

		if (read_push) begin
			read_owner_mem[read_wp] <= accept_loader_read;
			read_wp <= read_wp + {{(READ_PTR_W-1){1'b0}}, 1'b1};
		end
		if (read_pop) read_rp <= read_rp + {{(READ_PTR_W-1){1'b0}}, 1'b1};
		case ({read_push, read_pop})
			2'b10: read_count <= read_count + 1'b1;
			2'b01: read_count <= read_count - 1'b1;
			default: read_count <= read_count;
		endcase

		if (accept_rotation) last_grant_rotation <= 1'b1;
		else if (choose_retimer && !ddram_busy) last_grant_rotation <= 1'b0;

		if (!loader_read) loader_request_accepted <= 1'b0;
		else if (accept_loader_read) loader_request_accepted <= 1'b1;
	end
end

endmodule
