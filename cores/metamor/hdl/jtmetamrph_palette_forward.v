// SPDX-License-Identifier: GPL-3.0-or-later
// Palette-only mixed-port read/write forwarding. Both source RAM ports and
// this register must use the same clock. Video port is read-only; latches0.
module jtmetamrph_palette_forward(input clk,input rst,
 input[10:0]video_addr,cpu_addr,input[15:0]cpu_data,
 input[1:0]high_we,low_we,input[15:0]high_raw,low_raw,
 output[15:0]high_data,low_data);
reg[15:0]data_q;reg[1:0]high_mask,low_mask;
always @(posedge clk)begin
 data_q<=cpu_data;
 if(rst)begin high_mask<=0;low_mask<=0;end
 else begin
 high_mask<=video_addr==cpu_addr?high_we:0;
 low_mask<=video_addr==cpu_addr?low_we:0;
 end
end
assign high_data={high_mask[1]?data_q[15:8]:high_raw[15:8],high_mask[0]?data_q[7:0]:high_raw[7:0]};
assign low_data={low_mask[1]?data_q[15:8]:low_raw[15:8],low_mask[0]?data_q[7:0]:low_raw[7:0]};
endmodule
