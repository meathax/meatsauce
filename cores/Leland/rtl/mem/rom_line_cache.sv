// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// rom_line_cache: a direct-mapped, read-only line cache in front of one of the
// sequential-code SDRAM read clients (master Z80, slave Z80, 80186 sound CPU). Code ROM
// is immutable for the session, so no invalidation is needed: a line is valid forever
// once filled.
//
// A hit is served in ~2 clk_sys cycles with no SDRAM traffic. A miss fills a whole line
// of LINE_WORDS bytes with LINE_WORDS sequential single-word SDRAM transactions through
// the normal sdram_rdN_req/ack protocol, then serves the requested byte. Burst refill is
// deliberately not used: a burst test found a one-word capture anomaly that was never
// ruled out at the client level.
//
// Block RAM inference: one packed array (line_mem) with a registered read port, a
// synchronous write port and a sequential clear over the first 2**INDEX_BITS cycles of
// reset (a one-shot clear or per-entry arrays would fall back to ALMs).
module rom_line_cache #(
	parameter [26:0] BASE        = 27'h0,  // flat SDRAM byte base for this client's ROM region
	parameter        ADDR_WIDTH  = 18,     // client-relative ROM address width (bits)
	parameter        INDEX_BITS  = 8,      // 2**INDEX_BITS lines
	parameter        LINE_BITS   = 3       // 2**LINE_BITS bytes/line (8 bytes)
)(
	input                       clk_sys,
	input                       reset,      // synchronous reset (drives the sequential cache clear)
	input                       sdram_ready,

	// Client side — same shape as the CPU-module rom_req/rom_addr/rom_data/rom_stall port set
	input                       cpu_req,
	input      [ADDR_WIDTH-1:0] cpu_addr,
	output reg [7:0]            cpu_data,
	output                      cpu_stall,

	// SDRAM arbiter side — same one-shot req/ack shape as sdram_rdN_*
	output                      sd_req,
	output     [24:0]           sd_addr,
	input      [7:0]            sd_data,
	input                       sd_ack
);

localparam TAG_BITS   = ADDR_WIDTH - INDEX_BITS - LINE_BITS;
localparam LINE_WORDS = (1 << LINE_BITS);
localparam LINE_W     = 1 + TAG_BITS + 8*LINE_WORDS; // valid + tag + bytes

wire [LINE_BITS-1:0]  woff = cpu_addr[LINE_BITS-1:0];
wire [INDEX_BITS-1:0] idx  = cpu_addr[LINE_BITS +: INDEX_BITS];
wire [TAG_BITS-1:0]   tag  = cpu_addr[LINE_BITS+INDEX_BITS +: TAG_BITS];

// ---- Cache storage (M10K recipe: packed array, registered read, sequential clear) ----
reg [LINE_W-1:0] line_mem [0:(1<<INDEX_BITS)-1];
reg [INDEX_BITS-1:0] clear_idx;
reg                  clear_done;
reg                  mem_wr_en;
reg [INDEX_BITS-1:0] mem_wr_addr;
reg [LINE_W-1:0]     mem_wr_data;
reg [LINE_W-1:0]     rd_data_r;

always @(posedge clk_sys) begin
	if (reset) begin
		clear_done <= 1'b0;
		if (!clear_done) begin
			line_mem[clear_idx] <= {LINE_W{1'b0}}; // bit LINE_W-1 (valid) = 0
			if (clear_idx == {INDEX_BITS{1'b1}}) clear_done <= 1'b1;
			else clear_idx <= clear_idx + 1'b1;
		end
	end else begin
		clear_idx  <= '0;
		clear_done <= 1'b0;
		if (mem_wr_en) line_mem[mem_wr_addr] <= mem_wr_data;
	end
	rd_data_r <= line_mem[idx];
end

wire                cvalid = rd_data_r[LINE_W-1];
wire [TAG_BITS-1:0] ctag   = rd_data_r[LINE_W-2 -: TAG_BITS];

// ---- Inner fill sub-FSM: LINE_WORDS sequential single-word SDRAM reads ----
localparam FS_IDLE = 2'd0, FS_REQ = 2'd1, FS_GAP = 2'd2;
reg [1:0]            fstate;
reg [LINE_BITS-1:0]  fill_word;
reg [7:0]            line_buf [0:LINE_WORDS-1];
reg                  sd_req_r;
reg                  fill_start;
reg                  fill_done;
reg [INDEX_BITS-1:0] miss_idx_r;
reg [TAG_BITS-1:0]   miss_tag_r;
reg [LINE_BITS-1:0]  miss_woff_r;

assign sd_req  = sd_req_r;
assign sd_addr = BASE[24:0] + {miss_tag_r, miss_idx_r, fill_word};

always @(posedge clk_sys) begin
	fill_done <= 1'b0;
	if (reset) begin
		fstate <= FS_IDLE;
		sd_req_r <= 1'b0;
		fill_word <= '0;
	end else begin
		case (fstate)
			FS_IDLE: begin
				sd_req_r <= 1'b0;
				if (fill_start) begin
					fill_word <= '0;
					fstate    <= FS_REQ;
				end
			end
			FS_REQ: begin
				sd_req_r <= sdram_ready;
				if (sd_req_r && sd_ack) begin
					line_buf[fill_word] <= sd_data;
					sd_req_r <= 1'b0;
					if (fill_word == LINE_WORDS-1) begin
						fstate    <= FS_IDLE;
						fill_done <= 1'b1;
					end else begin
						fill_word <= fill_word + 1'b1;
						fstate    <= FS_GAP; // one-cycle req-low gap between words
					end
				end
			end
			FS_GAP: begin
				fstate <= FS_REQ;
			end
		endcase
	end
end

// ---- Outer lookup FSM ----
localparam ST_IDLE = 2'd0, ST_LOOKUP = 2'd1, ST_FILL = 2'd2;
reg [1:0] state;
reg       cpu_req_d;
wire      req_start = cpu_req & ~cpu_req_d;

reg cache_ack;
reg cache_ack_hold;

always @(posedge clk_sys) begin
	cpu_req_d    <= cpu_req;
	cache_ack    <= 1'b0;
	mem_wr_en    <= 1'b0;
	fill_start   <= 1'b0;

	if (reset) begin
		state <= ST_IDLE;
	end else begin
		case (state)
			ST_IDLE: begin
				if (req_start) state <= ST_LOOKUP;
			end
			ST_LOOKUP: begin
				if (cvalid && (ctag == tag)) begin
					cpu_data     <= rd_data_r[8*woff +: 8];
					cache_ack    <= 1'b1;
					state        <= ST_IDLE;
				end else begin
					miss_idx_r  <= idx;
					miss_tag_r  <= tag;
					miss_woff_r <= woff;
					fill_start  <= 1'b1;
					state       <= ST_FILL;
				end
			end
			ST_FILL: begin
				if (fill_done) begin
					mem_wr_en   <= 1'b1;
					mem_wr_addr <= miss_idx_r;
					mem_wr_data <= {1'b1, miss_tag_r,
					                line_buf[7], line_buf[6], line_buf[5], line_buf[4],
					                line_buf[3], line_buf[2], line_buf[1], line_buf[0]};
					cpu_data     <= line_buf[miss_woff_r];
					cache_ack    <= 1'b1;
					state        <= ST_IDLE;
				end
			end
		endcase
	end
end

always @(posedge clk_sys) begin
	if (!cpu_req) cache_ack_hold <= 1'b0;
	else if (cache_ack) cache_ack_hold <= 1'b1;
end

assign cpu_stall = cpu_req & (~cache_ack_hold | ~sdram_ready);

endmodule
