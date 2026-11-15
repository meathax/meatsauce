// SPDX-License-Identifier: GPL-3.0-or-later
// Specialized replacement for the pinned jtframe_ram_rst AW7/CEN_RD1 instance.
// Read stays on oscillator enable; captured writes commit one master edge later.
module heavyunit_mcu_ram(input logic rst,clk,cen,
 input logic [7:0] data,input logic [6:0] addr,input logic we,
 output logic [7:0] q);
 (* ramstyle = "M10K" *) logic [7:0] memory[0:127];
 logic reset_l;logic [6:0] clear_addr=0;
 logic write_pending;logic [6:0] write_addr;logic [7:0] write_data;
 always_ff @(posedge clk) begin
  reset_l<=rst;
  if(reset_l)clear_addr<=clear_addr+1'b1;
  write_pending<=!rst && !reset_l && cen && we;
  if(rst)begin write_addr<=0;write_data<=0;end
  else if(cen)begin write_addr<=addr;write_data<=data;end
 end
 always_ff @(posedge clk) begin
  if(reset_l)begin
   q<=memory[clear_addr];memory[clear_addr]<=0;
  end else begin
   if(cen)q<=memory[addr];
   if(write_pending && !rst)memory[write_addr]<=write_data;
  end
 end
endmodule
