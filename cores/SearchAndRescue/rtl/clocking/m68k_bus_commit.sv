// SPDX-License-Identifier: GPL-3.0-or-later
// Same-clock68000 bus qualification. Decode/RAM get two complete system
// clocks after data strobes assert. Each strobe interval commits once;
// DTACK/data then stay held until the CPU releases its data/address strobes.
module m68k_bus_commit(
 input wire clk,reset,as_n,rw,uds_n,lds_n,ready,
 input wire [15:0] read_data,
 output reg dtack_n=1,
 output reg [15:0] cpu_data=0,
 output wire write_commit,
 output wire transaction_commit
);
 reg [1:0] age=0;
 reg committed=0;
 wire active=!as_n && (!uds_n || !lds_n);
 assign transaction_commit=!reset && active && age>=2 && !committed && ready;
 assign write_commit=transaction_commit && !rw;
 always @(posedge clk) begin
  if(reset || !active)begin age<=0;committed<=0;dtack_n<=1;end
  else begin
   if(age!=3)age<=age+1'b1;
   if(transaction_commit)begin
    committed<=1;cpu_data<=read_data;dtack_n<=0;
   end
  end
  if(reset)cpu_data<=0;
 end
endmodule
