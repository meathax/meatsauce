// SPDX-License-Identifier: GPL-3.0-only
// Simple dual-port memory with a registered write port and an asynchronous
// read port, implemented in Cyclone V MLAB (altdpram, same parameterisation as
// MiSTer-devel Arcade-PsikyoSH2_MiSTer rtl/mlab.vhd).
//
// Contract for callers: a location written on clock edge e may be read (with
// a defined value) only in cycles that begin at or after edge e+1. Reads of
// other locations are always defined. The simulation model below (register
// semantics) is equivalent for every read that honours this contract.
module bigfight_mlab_dp #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH_BITS = 6
) (
    input  logic                  clk,
    input  logic                  we,
    input  logic [DEPTH_BITS-1:0] waddr,
    input  logic [WIDTH-1:0]      wdata,
    input  logic [DEPTH_BITS-1:0] raddr,
    output logic [WIDTH-1:0]      rdata
);
`ifdef VERILATOR
    `define BIGFIGHT_MLAB_BEHAVIOURAL
`endif
`ifdef __ICARUS__
    `define BIGFIGHT_MLAB_BEHAVIOURAL
`endif
`ifdef BIGFIGHT_MLAB_BEHAVIOURAL
    logic [WIDTH-1:0] mem [0:(1<<DEPTH_BITS)-1];
    always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
    assign rdata = mem[raddr];
`else
    altdpram #(
        .indata_aclr("OFF"), .indata_reg("INCLOCK"),
        .intended_device_family("Cyclone V"), .lpm_type("altdpram"),
        .outdata_aclr("OFF"), .outdata_reg("UNREGISTERED"),
        .ram_block_type("MLAB"),
        .rdaddress_aclr("OFF"), .rdaddress_reg("UNREGISTERED"),
        .rdcontrol_aclr("OFF"), .rdcontrol_reg("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("CONSTRAINED_DONT_CARE"),
        .width(WIDTH), .widthad(DEPTH_BITS), .width_byteena(1),
        .wraddress_aclr("OFF"), .wraddress_reg("INCLOCK"),
        .wrcontrol_aclr("OFF"), .wrcontrol_reg("INCLOCK")
    ) mlab_i (
        .data(wdata), .outclock(clk), .rdaddress(raddr), .wren(we),
        .inclock(clk), .wraddress(waddr), .q(rdata),
        .aclr(1'b0), .byteena(1'b1), .inclocken(1'b1), .outclocken(1'b1),
        .rdaddressstall(1'b0), .rden(1'b1), .wraddressstall(1'b0)
    );
`endif
endmodule
