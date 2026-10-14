//============================================================================
// Simple dual-port BRAM: Port A write+read, Port B read-only.
// Avoids BIDIR inference / multi-driver issues; maps cleanly to M10K.
// REGISTERED_B is intentional: the video renderer must model the selected
// FPGA RAM output mode, rather than silently simulating a different memory.
//============================================================================
module ikki_dpram #(
	parameter ADDR_WIDTH = 11,
	parameter DATA_WIDTH = 8,
	parameter REGISTERED_B = 1
)(
	input                       clock_a,
	input                       clock_b,
	input  [ADDR_WIDTH-1:0]     address_a,
	input  [ADDR_WIDTH-1:0]     address_b,
	input  [DATA_WIDTH-1:0]     data_a,
	input  [DATA_WIDTH-1:0]     data_b,
	input                       wren_a,
	input                       wren_b,
	output reg [DATA_WIDTH-1:0] q_a,
	output reg [DATA_WIDTH-1:0] q_b
);

(* ramstyle = "no_rw_check, M10K" *) reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

wire _unused = |{data_b, wren_b};

always @(posedge clock_a) begin
	if (wren_a) mem[address_a] <= data_a;
	q_a <= mem[address_a];
end

generate
	if (REGISTERED_B) begin : gen_registered_b
		always @(posedge clock_b) begin
			q_b <= mem[address_b];
		end
	end else begin : gen_async_b
		always @(*) begin
			q_b = mem[address_b];
		end
	end
endgenerate

endmodule
