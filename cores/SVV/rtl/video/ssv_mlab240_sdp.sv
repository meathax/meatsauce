// SPDX-License-Identifier: GPL-3.0-or-later
// 240-word single-write, registered-read memory used by frame-local metadata.
//
// The current universal fit has enough M10K headroom but is ALM-limited.  A
// forced MLAB implementation consumed about 1,168 ALMs/720 MLAB cells for this
// 240x180 table.  Keep this primitive-shaped wrapper deliberately small and
// select M10K explicitly: one write port, one registered read port, one clock,
// and no reset inside the memory array.  The legacy module name is retained so
// this storage-only placement correction does not churn simulation manifests.
// The renderer masks the read output during reset and rebuilds every entry
// before consuming it, matching the old inferred-array contract.

`timescale 1ns/1ps

module ssv_mlab240_sdp #(
    parameter integer WIDTH = 180,
    parameter integer DEPTH = 240
) (
    input  logic                 clk,
    input  logic [7:0]           wr_addr,
    input  logic                 we,
    input  logic [WIDTH-1:0]     wdata,
    input  logic [7:0]           rd_addr,
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
        ram.numwords_a = DEPTH,
        ram.widthad_a = 8,
        ram.width_a = WIDTH,
        ram.numwords_b = DEPTH,
        ram.widthad_b = 8,
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
        ram.power_up_uninitialized = "TRUE",
        ram.ram_block_type = "M10K",
        ram.read_during_write_mode_mixed_ports = "DONT_CARE",
        ram.width_byteena_a = 1;
`else
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [WIDTH-1:0] q_r;

    assign q = q_r;

    always_ff @(posedge clk) begin
        if (we)
            mem[wr_addr] <= wdata;
        q_r <= mem[rd_addr];
    end
`endif

endmodule
