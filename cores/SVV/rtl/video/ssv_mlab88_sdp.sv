//============================================================================
//  88-word simple dual-port MLAB (1 write + 1 registered read).
//
//  Quartus 17 fails to infer MLABs for ssv_line_buffer4's 16 line-slot banks
//  when the arrays live inside a large module with muxed write
//  addresses/enables and a muxed read address (confirmed 2026-08-19: zero
//  RAM-inference log lines across three different array/always-block
//  structurings, ~745-830 LAB fitter overflow every time). Same failure
//  class and same fix as ssv_mlab32_sdp (ES5506 voice banks) and
//  ssv_mlab240_sdp (sprite renderer line metadata): explicit altsyncram
//  forces MLAB packing instead of leaving it to RTL inference.
//============================================================================

`timescale 1ns/1ps

module ssv_mlab88_sdp #(
    parameter integer WIDTH = 15
) (
    input  logic                 clk,
    input  logic           [6:0] wr_addr,
    input  logic                 we,
    input  logic [WIDTH-1:0]     wdata,
    input  logic           [6:0] rd_addr,
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
    ram.numwords_a = 88,
    ram.widthad_a = 7,
    ram.width_a = WIDTH,
    ram.numwords_b = 88,
    ram.widthad_b = 7,
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
    // Keep this as an explicit primitive: the line-buffer's muxed addresses
    // do not infer reliably in Quartus 17. The bypass logic, not the RAM
    // primitive, defines the same-cycle RMW behavior.
    ram.ram_block_type = "MLAB",
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    ram.width_byteena_a = 1;
`else
logic [WIDTH-1:0] mem [0:87];
logic [WIDTH-1:0] q_r;
assign q = q_r;

integer __i;
initial begin
    for (__i = 0; __i < 88; __i = __i + 1)
        mem[__i] = {WIDTH{1'b0}};
end

// Same-address RDW returns the prior value (NBA write after read sample),
// matching the common "old data" MLAB behaviour. Hardware is DONT_CARE;
// line_buffer4's bypass registers cover the same-cycle RMW hazard.
always_ff @(posedge clk) begin
    if (we)
        mem[wr_addr] <= wdata;
    q_r <= mem[rd_addr];
end
`endif

endmodule
