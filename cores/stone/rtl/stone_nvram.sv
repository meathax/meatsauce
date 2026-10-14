// SPDX-License-Identifier: GPL-3.0-or-later
// One 2048x8 true-dual-port M10K memory supplies both registered read ports.
// CPU priority permits at most one write per clock, including different-address
// collisions. Storage uses complemented bytes so power-up zero means erased FF.
// Explicit mixed-port forwarding avoids depending on device collision data.
module stone_nvram(
 input wire clk,cpu_we,nv_we,input wire [10:0] cpu_addr,nv_addr,
 input wire [7:0] cpu_din,nv_din,output wire [7:0] cpu_dout,nv_dout);
 wire restore_write=nv_we && !cpu_we;
 wire [7:0] cpu_q,nv_q;
 reg cpu_forward_q,nv_forward_q;
 reg [7:0] cpu_forward_data_q,nv_forward_data_q;
 altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),.ram_block_type("M10K"),
  .intended_device_family("Cyclone V"),.width_a(8),.widthad_a(11),.numwords_a(2048),
  .width_b(8),.widthad_b(11),.numwords_b(2048),.address_reg_b("CLOCK0"),
  .indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),
  .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
  .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
  .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
  .read_during_write_mode_mixed_ports("OLD_DATA"),.power_up_uninitialized("FALSE"))
 bytes_ram(.clock0(clk),.clock1(1'b1),.clocken0(1'b1),.clocken1(1'b1),
  .clocken2(1'b1),.clocken3(1'b1),.aclr0(1'b0),.aclr1(1'b0),
  .address_a(cpu_addr),.data_a(~cpu_din),.wren_a(cpu_we),.q_a(cpu_q),
  .address_b(nv_addr),.data_b(~nv_din),.wren_b(restore_write),.q_b(nv_q),
  .rden_a(1'b1),.rden_b(1'b1),.byteena_a(1'b1),.byteena_b(1'b1),
  .addressstall_a(1'b0),.addressstall_b(1'b0),.eccstatus());
 always @(posedge clk) begin
   cpu_forward_q<=restore_write && nv_addr==cpu_addr;
   nv_forward_q<=cpu_we && cpu_addr==nv_addr;
   cpu_forward_data_q<=nv_din;
   nv_forward_data_q<=cpu_din;
 end
 assign cpu_dout=cpu_forward_q ? cpu_forward_data_q:~cpu_q;
 assign nv_dout=nv_forward_q ? nv_forward_data_q:~nv_q;
endmodule
