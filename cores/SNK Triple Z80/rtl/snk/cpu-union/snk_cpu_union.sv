// SPDX-License-Identifier: GPL-3.0-or-later
// Controllers supply CPU DI and native enable phases/reset/WAIT/IRQ/NMI.
// rom_data supplies the selected controller's synchronous ROM byte inputs.
module snk_cpu_union(
 input wire clk,input wire [7:0] profile,input wire load_wr,
 input wire [24:0] load_addr,input wire [7:0] load_data,
 input wire [2:0] reset_n,cen_p,cen_n,wait_n,irq_n,nmi_n,
 input wire [23:0] din,output wire [23:0] rom_data,dout,
 output wire [47:0] addr,
 output wire [2:0] m1_n,mreq_n,iorq_n,rd_n,wr_n,rfsh_n,halt_n,busack_n
);
 snk_cpu_union_engine cpus(.*);
 snk_union_program_bank program_bank(.clk(clk),.profile(profile),.load_wr(load_wr),
  .load_addr(load_addr),.load_data(load_data),.cpu_addr(addr),.rom_data(rom_data));
endmodule
