// SPDX-License-Identifier: GPL-3.0-or-later
// Own the idle 68000 bus; no clock or phase-enable is gated here.
module dfjail_pause_bus(
 input clk,rst,cen,request,cpu_BGn,cpu_ASn,cpu_DTACKn,
 output cpu_BRn,cpu_BGACKn,granted
);
jtframe_68kdma dma(.clk(clk),.rst(rst),.cen(cen),.dev_br(request),
 .cpu_BRn(cpu_BRn),.cpu_BGACKn(cpu_BGACKn),.cpu_BGn(cpu_BGn),.cpu_ASn(cpu_ASn),.cpu_DTACKn(cpu_DTACKn));
assign granted=!rst && !cpu_BGACKn && cpu_ASn && cpu_DTACKn;
endmodule
