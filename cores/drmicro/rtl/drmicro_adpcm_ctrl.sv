// SPDX-License-Identifier: GPL-3.0-or-later
// vclk_request precedes the JT5205 sampling edge by one 384kHz period.
module drmicro_adpcm_ctrl(
 input logic clk,reset,start,vclk_request,
 input logic [7:0] command,
 output logic [13:0] rom_addr,
 input logic [7:0] rom_data,
 output logic [3:0] nibble,
 output logic decoder_reset,
 output logic [14:0] position
);
 logic [1:0] pending;
 assign rom_addr=position[14:1];
 always_ff @(posedge clk)begin
  if(reset)begin position<=0;pending<=0;nibble<=0;decoder_reset<=1;end
  else if(start)begin position<={command[5:0],9'd0};pending<=2;end
  else if(pending!=0)begin
   pending<=pending-2'd1;
   if(pending==1)begin
    if(rom_data==8'h70)decoder_reset<=1;
    else begin decoder_reset<=0;nibble<=position[0]?rom_data[3:0]:rom_data[7:4];position<=position+15'd1;end
   end
  end else if(vclk_request)pending<=2;
 end
endmodule
