// SPDX-License-Identifier: GPL-3.0-or-later
module drmicro_bus(
 input logic clk,reset,mreq_n,iorq_n,rd_n,wr_n,rfsh_n,m1_n,
 input logic [15:0] addr,
 input logic [7:0] mem_data,p1,p2,dip1,dip2,
 output logic [7:0] cpu_data,
 output logic mem_write,io_write
);
 logic seen;
 wire memory_cycle=!mreq_n&&rfsh_n;
 wire io_cycle=!iorq_n&&m1_n;
 wire write_cycle=!wr_n&&(memory_cycle||io_cycle);
 assign mem_write=write_cycle&&!seen&&memory_cycle&&addr>=16'hc000;
 assign io_write=write_cycle&&!seen&&io_cycle;
 always_ff @(posedge clk) if(reset)seen<=0;else seen<=write_cycle;
 // tv80s controls track its CE-held tstate at every fast clock. Keep the
 // read response through T2/T3 even after RD deasserts; di_reg/dinst consume
 // it at the next enabled CPU edge. The memory has ample time before this.
 always_ff @(posedge clk) begin
  if(reset)cpu_data<=8'hff;
  else if(!rd_n&&memory_cycle)cpu_data<=mem_data;
  else if(!rd_n&&io_cycle) case(addr[7:0])
   0:cpu_data<=p1;1:cpu_data<=p2;3:cpu_data<=dip1;4:cpu_data<=dip2;
   // Pinned MAME noprw port reads zero (confirmed by the reference read tap).
   // Original watchdog electrical behaviour is not documented.
   5:cpu_data<=8'h00;
   default:cpu_data<=8'hff;
  endcase
 end
endmodule
