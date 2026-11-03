// SPDX-License-Identifier: GPL-3.0-or-later
// Two adjacent pixels per write edge, including odd starts and reverse X.
// Reuses the production donor-derived d8_dpram. Physical parity banks allow
// the pair to straddle word boundaries without adding a scan-out cycle.
module d8_linebuf_pair(
    input wire clk,
    input wire [8:0] addr0,addr1,
    input wire [15:0] data0,data1,
    input wire we0,we1,
    input wire [8:0] read_addr,
    output wire [15:0] read_data
);
    wire [7:0] even_addr=addr0[0]?addr1[8:1]:addr0[8:1];
    wire [7:0] odd_addr=addr0[0]?addr0[8:1]:addr1[8:1];
    wire [15:0] even_data=addr0[0]?data1:data0;
    wire [15:0] odd_data=addr0[0]?data0:data1;
    wire even_we=addr0[0]?we1:we0;
    wire odd_we=addr0[0]?we0:we1;
    wire [15:0] even_q,odd_q;
    reg read_odd;
    always @(posedge clk)read_odd<=read_addr[0];
    assign read_data=read_odd?odd_q:even_q;
    d8_dpram #(.AW(8),.DW(16)) even_ram(
        .clk,.addr_a(even_addr),.d_a(even_data),.we_a(even_we),.be_a(2'b11),
        .q_a(),.addr_b(read_addr[8:1]),.q_b(even_q));
    d8_dpram #(.AW(8),.DW(16)) odd_ram(
        .clk,.addr_a(odd_addr),.d_a(odd_data),.we_a(odd_we),.be_a(2'b11),
        .q_a(),.addr_b(read_addr[8:1]),.q_b(odd_q));
`ifdef SIMULATION
    always @(posedge clk)if((we0||we1)&&addr0[0]==addr1[0])
        $fatal(1,"LINEBUF_PAIR_PARITY_COLLISION");
`endif
endmodule
