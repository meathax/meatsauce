// Loader/renderer bridge for the shared graphics SDRAM.
// SPDX-License-Identifier: GPL-3.0-or-later

module gd_gfx_arbiter
#(
	parameter integer CACHE_INDEX_BITS = 11
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        cache_flush,
	input  logic [24:0] loader_addr,
	input  logic [15:0] loader_din,
	input  logic  [1:0] loader_be,
	input  logic        loader_burst,
	input  logic [63:0] loader_burst_data,
	input  logic        loader_rnw,
	input  logic        loader_req,
	output logic [15:0] loader_dout,
	output logic        loader_ack,

	input  logic [24:0] renderer_addr,
	input  logic        renderer_req,
	output logic [63:0] renderer_dout,
	output logic        renderer_ack,

	output logic [24:0] mem_addr,
	output logic [15:0] mem_din,
	output logic  [1:0] mem_be,
	output logic        mem_burst,
	output logic [63:0] mem_burst_data,
	output logic        mem_rnw,
	output logic        mem_req,
	input  logic [15:0] mem_dout,
	input  logic        mem_ack,

	output logic [24:0] dma_addr,
	output logic        dma_req,
	input  logic [63:0] dma_data,
	input  logic        dma_ack
);

logic loader_busy;
logic loader_req_latched;

localparam integer CACHE_SET_BITS = CACHE_INDEX_BITS - 1;
localparam integer CACHE_SETS = 1 << CACHE_SET_BITS;
localparam integer CACHE_TAG_BITS = 23 - CACHE_INDEX_BITS;

// One cache line is exactly the eight-byte planar row consumed by the video
// renderer. Data and tags use synchronous M10Ks; only validity/replacement
// metadata remains in logic. This avoids both the former four-row miss latency
// and the very large mux/register network inferred by asynchronous deep tags.
(* ramstyle = "M10K" *) logic [63:0] cache_data_way0 [0:CACHE_SETS-1];
(* ramstyle = "M10K" *) logic [63:0] cache_data_way1 [0:CACHE_SETS-1];
(* ramstyle = "M10K" *) logic [CACHE_TAG_BITS-1:0]
	cache_tag_way0 [0:CACHE_SETS-1];
(* ramstyle = "M10K" *) logic [CACHE_TAG_BITS-1:0]
	cache_tag_way1 [0:CACHE_SETS-1];
logic cache_valid_way0 [0:CACHE_SETS-1];
logic cache_valid_way1 [0:CACHE_SETS-1];
logic cache_replace_way [0:CACHE_SETS-1];
logic [63:0] cache_data_way0_q;
logic [63:0] cache_data_way1_q;
logic [CACHE_TAG_BITS-1:0] cache_tag_way0_q;
logic [CACHE_TAG_BITS-1:0] cache_tag_way1_q;
logic cache_fill_way;
integer cache_index;

typedef enum logic [1:0] {RENDER_IDLE, RENDER_LOOKUP, RENDER_DMA}
	render_state_t;
render_state_t renderer_state;
logic renderer_req_latched;
logic [24:0] renderer_addr_latched;

// Renderer addresses remain stable until acknowledged. Reading the arrays
// continuously therefore places the requested set on the registered M10K
// outputs before RENDER_LOOKUP tests its tag on the following clock.
always_ff @(posedge clk) begin
	cache_data_way0_q <=
		cache_data_way0[renderer_addr[CACHE_INDEX_BITS+1:3]];
	cache_data_way1_q <=
		cache_data_way1[renderer_addr[CACHE_INDEX_BITS+1:3]];
	cache_tag_way0_q <=
		cache_tag_way0[renderer_addr[CACHE_INDEX_BITS+1:3]];
	cache_tag_way1_q <=
		cache_tag_way1[renderer_addr[CACHE_INDEX_BITS+1:3]];
end

always_ff @(posedge clk) begin
	if (reset) begin
		loader_dout <= 16'd0;
		loader_ack <= 1'b0;
		mem_addr <= 25'd0;
		mem_din <= 16'd0;
		mem_be <= 2'b11;
		mem_burst <= 1'b0;
		mem_burst_data <= 64'd0;
		mem_rnw <= 1'b1;
		mem_req <= 1'b0;
		loader_busy <= 1'b0;
		loader_req_latched <= 1'b0;
		renderer_dout <= 64'd0;
		renderer_ack <= 1'b0;
		renderer_req_latched <= 1'b0;
		renderer_addr_latched <= 25'd0;
		renderer_state <= RENDER_IDLE;
		dma_addr <= 25'd0;
		dma_req <= 1'b0;
		cache_fill_way <= 1'b0;
		for (cache_index = 0; cache_index < CACHE_SETS;
		     cache_index = cache_index + 1) begin
			cache_valid_way0[cache_index] <= 1'b0;
			cache_valid_way1[cache_index] <= 1'b0;
			cache_replace_way[cache_index] <= 1'b0;
		end
	end
	else begin
		// Graphics ROM is immutable while the game runs. A new download clears
		// validity in parallel while leaving the loader handshake operational.
		if (cache_flush) begin
			for (cache_index = 0; cache_index < CACHE_SETS;
			     cache_index = cache_index + 1) begin
				cache_valid_way0[cache_index] <= 1'b0;
				cache_valid_way1[cache_index] <= 1'b0;
				cache_replace_way[cache_index] <= 1'b0;
			end
		end

		case (renderer_state)
			RENDER_IDLE: begin
				if (renderer_req != renderer_ack) begin
					renderer_addr_latched <= renderer_addr;
					renderer_req_latched <= renderer_req;
					renderer_state <= RENDER_LOOKUP;
				end
			end

			RENDER_LOOKUP: begin
				if (cache_valid_way0[
					        renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
				    && (cache_tag_way0_q
				        == renderer_addr_latched[24:CACHE_INDEX_BITS+2])) begin
					renderer_dout <= cache_data_way0_q;
					renderer_ack <= renderer_req_latched;
					renderer_state <= RENDER_IDLE;
				end
				else if (cache_valid_way1[
				             renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
				         && (cache_tag_way1_q
				             == renderer_addr_latched[24:CACHE_INDEX_BITS+2])) begin
					renderer_dout <= cache_data_way1_q;
					renderer_ack <= renderer_req_latched;
					renderer_state <= RENDER_IDLE;
				end
				else begin
					if (!cache_valid_way0[
					        renderer_addr_latched[CACHE_INDEX_BITS+1:3]])
						cache_fill_way <= 1'b0;
					else if (!cache_valid_way1[
					             renderer_addr_latched[CACHE_INDEX_BITS+1:3]])
						cache_fill_way <= 1'b1;
					else
						cache_fill_way <= cache_replace_way[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]];
					dma_addr <= {renderer_addr_latched[24:3], 3'b000};
					dma_req <= ~dma_req;
					renderer_state <= RENDER_DMA;
				end
			end

			RENDER_DMA: begin
				if (dma_ack == dma_req) begin
					if (!cache_fill_way) begin
						cache_data_way0[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
							<= dma_data;
						cache_tag_way0[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
							<= renderer_addr_latched[24:CACHE_INDEX_BITS+2];
						cache_valid_way0[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
							<= 1'b1;
					end
					else begin
						cache_data_way1[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
							<= dma_data;
						cache_tag_way1[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
							<= renderer_addr_latched[24:CACHE_INDEX_BITS+2];
						cache_valid_way1[
							renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
							<= 1'b1;
					end
					cache_replace_way[
						renderer_addr_latched[CACHE_INDEX_BITS+1:3]]
						<= ~cache_fill_way;
					renderer_dout <= dma_data;
					renderer_ack <= renderer_req_latched;
					renderer_state <= RENDER_IDLE;
				end
			end

			default: renderer_state <= RENDER_IDLE;
		endcase

		if (!loader_busy) begin
			if (loader_req != loader_ack) begin
				mem_addr <= loader_addr;
				mem_din <= loader_din;
				mem_be <= loader_be;
				mem_burst <= loader_burst;
				mem_burst_data <= loader_burst_data;
				mem_rnw <= loader_rnw;
				mem_req <= ~mem_req;
				loader_req_latched <= loader_req;
				loader_busy <= 1'b1;
			end
		end
		else if (mem_ack == mem_req) begin
			loader_dout <= mem_dout;
			loader_ack <= loader_req_latched;
			loader_busy <= 1'b0;
		end
	end
end

endmodule
