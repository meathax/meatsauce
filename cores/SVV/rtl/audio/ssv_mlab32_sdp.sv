//============================================================================
//  32-word simple dual-port MLAB (1 write + 1 registered read).
//
//  Quartus 17 fails to infer MLABs for the ES5506 voice banks when the arrays
//  live inside a large always_ff with case-gated reads and muxed write
//  indices.  Explicit altsyncram (same pattern as s32_big_dpram) forces MLAB
//  packing.  Simulation uses a cycle-equivalent behavioural model.
//============================================================================

`timescale 1ns/1ps

module ssv_mlab32_sdp #(
    parameter integer WIDTH = 16
) (
    input  logic                 clk,
    input  logic           [4:0] wr_addr,
    input  logic                 we,
    input  logic [WIDTH-1:0]     wdata,
    input  logic           [4:0] rd_addr,
    output logic [WIDTH-1:0]     q
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(wr_addr),
    .data_a(wdata),
    .wren_a(we),
    .q_a(),

    .clock1(clk),
    .address_b(rd_addr),
    .data_b({WIDTH{1'b0}}),
    .wren_b(1'b0),
    .q_b(q),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a(1'b1),
    .byteena_b(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 32,
    ram.widthad_a = 5,
    ram.width_a = WIDTH,
    ram.numwords_b = 32,
    ram.widthad_b = 5,
    ram.width_b = WIDTH,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "DUAL_PORT",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    ram.ram_block_type = "MLAB",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    ram.width_byteena_a = 1;
`else
logic [WIDTH-1:0] mem [0:31];
logic [WIDTH-1:0] q_r;
assign q = q_r;

integer __i;
initial begin
    for (__i = 0; __i < 32; __i = __i + 1)
        mem[__i] = {WIDTH{1'b0}};
end

// Same-address RDW returns the prior value (NBA write after read sample),
// matching the common "old data" MLAB behaviour. Hardware is DONT_CARE;
// the regs host-steal path avoids relying on conflicted reads.
always_ff @(posedge clk) begin
    if (we)
        mem[wr_addr] <= wdata;
    q_r <= mem[rd_addr];
end
`endif

endmodule
