// SPDX-License-Identifier: GPL-3.0-or-later
// Two 128K-word VRAM pages. Each word keeps its display byte and a flag for
// a nonzero high byte in SDRAM. Eight interleaved banks allow the GSP's VRAM
// shift register to move a block within vertical blank. Ordinary GSP/blitter
// accesses retain their three-clock A and four-clock scanout B latencies.
`default_nettype none
module stone_vram(input wire clk,
 input wire a_we,input wire [17:0] a_addr,input wire [7:0] a_lo,input wire a_hi,
 output reg [7:0] a_lo_q,output reg a_hi_q,
 input wire [7:0] a_burst_we,input wire [71:0] a_burst_data,
 output reg [71:0] a_burst_q,
 input wire [17:0] b_addr,output reg [7:0] b_q);
 reg [14:0] addr_r,b_addr_r,b_addr_r2;
 reg [2:0] a_lane_r,a_lane_r2,b_lane_r,b_lane_r2,b_lane_r3;
 wire [71:0] qa,qb;
 always @(posedge clk) begin
  addr_r<=a_addr[17:3];a_lane_r<=a_addr[2:0];a_lane_r2<=a_lane_r;
  b_addr_r<=b_addr[17:3];b_addr_r2<=b_addr_r;
  b_lane_r<=b_addr[2:0];b_lane_r2<=b_lane_r;b_lane_r3<=b_lane_r2;
  a_lo_q<=qa[9*a_lane_r2+:8];a_hi_q<=qa[9*a_lane_r2+8];
  a_burst_q<=qa;b_q<=qb[9*b_lane_r3+:8];
 end
 genvar lane;
 generate for(lane=0;lane<8;lane=lane+1) begin:bank
  reg we_r;reg [8:0] data_r;
  always @(posedge clk) begin
   we_r<=a_burst_we[lane] || (a_we && a_addr[2:0]==3'(lane));
   data_r<=a_burst_we[lane] ? a_burst_data[9*lane+:9]:{a_hi,a_lo};
  end
  // 1Kx10 packing still uses 256 M10Ks for all nine bits of both pages.
  altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),.ram_block_type("M10K"),.intended_device_family("Cyclone V"),.maximum_depth(1024),
   .width_a(9),.widthad_a(15),.numwords_a(32768),.width_b(9),.widthad_b(15),.numwords_b(32768),
   .address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),.outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
   .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
   .read_during_write_mode_mixed_ports("OLD_DATA"),
   .power_up_uninitialized("FALSE"),.width_byteena_a(1),.width_byteena_b(1),.lpm_type("altsyncram")) ram(
   .clock0(clk),.clock1(1'b1),.clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.aclr0(1'b0),.aclr1(1'b0),
   .address_a(addr_r),.data_a(data_r),.wren_a(we_r),.q_a(qa[9*lane+:9]),.rden_a(1'b1),.byteena_a(1'b1),
   .address_b(b_addr_r2),.data_b(9'd0),.wren_b(1'b0),.q_b(qb[9*lane+:9]),.rden_b(1'b1),.byteena_b(1'b1),.addressstall_a(1'b0),.addressstall_b(1'b0),.eccstatus());
 end endgenerate
endmodule
`default_nettype wire
