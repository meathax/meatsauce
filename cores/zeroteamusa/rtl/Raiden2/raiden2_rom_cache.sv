// SPDX-License-Identifier: GPL-3.0-or-later
// Direct-mapped read-only word cache for the COP's program-ROM port.
//
// The COP reads sprite templates (C480/6880 DMA) and hitbox descriptors
// (B100/B900) from program ROM, one word at a time, while the V30 is held by
// cop_cpu_stall. Each read was a full SDRAM transaction behind the video-first
// arbiter, so scenes with many objects stretched the CPU stall and the game
// slowed down. A hit answers two clocks after the request.
//
// req: one-clock pulse with addr valid; addr stays stable until ready.
// ready: one-clock pulse, data held until the next request.
// mem_req: held until the one-clock mem_ready pulse (bridge level contract).
// The ROM is read-only while the core runs; a ROM download holds reset, which
// re-sweeps the tags. Requests arriving during the sweep are fetched uncached.
module raiden2_rom_cache #(
	parameter BITS = 12
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        req,
	input  wire [23:0] addr,
	output reg  [15:0] data,
	output reg         ready,
	output reg         mem_req,
	output wire [23:0] mem_addr,
	input  wire [15:0] mem_data,
	input  wire        mem_ready
);

localparam TW = 23 - BITS;   // word address bits [23:BITS+1]

(* ramstyle = "M10K,no_rw_check" *) reg [15:0] cache_data [0:(1<<BITS)-1];
(* ramstyle = "M10K,no_rw_check" *) reg [TW:0]  cache_tag  [0:(1<<BITS)-1]; // {valid, tag}

reg [15:0]     q;
reg [TW:0]     tq;
reg [23:0]     a;
reg            look;
reg            init = 1'b1;
reg [BITS-1:0] init_idx = {BITS{1'b0}};

always @(posedge clk) begin
	q  <= cache_data[addr[BITS:1]];
	tq <= cache_tag[addr[BITS:1]];
end

wire hit  = !init && tq[TW] && tq[TW-1:0] == a[23:BITS+1];
wire fill = mem_req && mem_ready;
assign mem_addr = a;

always @(posedge clk) begin
	ready <= 1'b0;
	if (reset) begin
		look    <= 1'b0;
		mem_req <= 1'b0;
	end else if (req) begin
		a    <= addr;
		look <= 1'b1;
	end else if (look) begin
		look <= 1'b0;
		if (hit) begin
			data  <= q;
			ready <= 1'b1;
		end else
			mem_req <= 1'b1;
	end else if (fill) begin
		mem_req <= 1'b0;
		data    <= mem_data;
		ready   <= 1'b1;
	end
end

always @(posedge clk) begin
	if (init) begin
		cache_tag[init_idx] <= {(TW+1){1'b0}};
		init_idx <= init_idx + 1'b1;
		if (init_idx == {BITS{1'b1}} && !reset) init <= 1'b0;
	end else if (reset) begin
		init     <= 1'b1;
		init_idx <= {BITS{1'b0}};
	end else if (fill) begin
		cache_data[a[BITS:1]] <= mem_data;
		cache_tag[a[BITS:1]]  <= {1'b1, a[23:BITS+1]};
	end
end

endmodule
