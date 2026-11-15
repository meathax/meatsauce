// SPDX-License-Identifier: GPL-3.0-or-later
// Enable/hold adapter for a one-clock synchronous memory response. No RAM.
module snk_hsj_enabled_response #(parameter WIDTH=8,parameter REGISTERED=0)(input wire clk,read_en,input wire[WIDTH-1:0]read_data,output wire[WIDTH-1:0]held_data);
reg read_en_q=0; reg[WIDTH-1:0]hold_q;
always@(posedge clk)begin read_en_q<=read_en; if(read_en_q)hold_q<=read_data;end
// Registered mode breaks the RAM -> code/attribute -> graphics-ROM address path.
// Its consuming renderer must establish the extra master-clock response margin.
assign held_data=REGISTERED ? hold_q : (read_en_q?read_data:hold_q);
endmodule
