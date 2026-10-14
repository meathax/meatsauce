//============================================================================
// True dual-port RAM: both ports read and write, one shared clock.
//
// Written so Quartus infers a single M10K in True Dual Port mode.  The
// previous shared-RAM description used two independent write statements over
// one array, which Quartus implemented as two *Simple Dual Port* copies with
// their write ports muxed together (see docs/AUDIT.md A7): two writes in the
// same cycle to different addresses kept both in simulation but lost one in
// hardware.
//
// Read-during-write on the same port returns the new data, matching the M10K
// behaviour Quartus reports, so simulation and hardware agree.  Cross-port
// same-address read-during-write is undefined on the device and is avoided by
// the arbitration in ikki_shared.
//============================================================================
module ikki_tdpram #(
	parameter ADDR_WIDTH = 11,
	parameter DATA_WIDTH = 8
)(
	input                       clk,

	input  [ADDR_WIDTH-1:0]     addr_a,
	input  [DATA_WIDTH-1:0]     din_a,
	input                       we_a,
	output reg [DATA_WIDTH-1:0] dout_a,

	input  [ADDR_WIDTH-1:0]     addr_b,
	input  [DATA_WIDTH-1:0]     din_b,
	input                       we_b,
	output reg [DATA_WIDTH-1:0] dout_b
);

(* ramstyle = "no_rw_check, M10K" *)
reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1] /* verilator public_flat_rw */;

always @(posedge clk) begin
	if (we_a) begin
		mem[addr_a] <= din_a;
		dout_a      <= din_a;
	end else
		dout_a <= mem[addr_a];
end

always @(posedge clk) begin
	if (we_b) begin
		mem[addr_b] <= din_b;
		dout_b      <= din_b;
	end else
		dout_b <= mem[addr_b];
end

endmodule
