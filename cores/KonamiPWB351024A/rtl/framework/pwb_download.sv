// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from SPY loader: strict contiguous 0x320000-byte stream; tile mirror.
// Only loader reset enters here. CPU/game reset must never erase this transport.
module pwb_download(input wire clk,reset,init,wr,input wire [7:0] data,input wire [26:0] addr,
input wire prog_ack,prog_rdy,output wire wait_hps,prog_en,prog_wr,
output reg [21:0] prog_addr,output reg [1:0] prog_ba,prog_dsn,output reg [15:0] prog_din,
output reg image_ready=0,load_error=0,output wire accepted,output reg [24:0] accepted_bytes=0);
reg [2:0] state=0;reg mirror_tile=0,active=0;
assign wait_hps=reset||init||state!=0;
assign accepted=wr&&!wait_hps;
assign prog_en=active||state!=0||accepted;
assign prog_wr=state==1||state==4;
always @(posedge clk) begin
 if(reset)begin state<=0;image_ready<=0;load_error<=0;accepted_bytes<=0;active<=0;mirror_tile<=0;prog_addr<=0;prog_ba<=0;prog_dsn<=3;prog_din<=0;end
 else begin
 if(accepted)begin
  active<=1;image_ready<=0;
  if(addr==0)begin accepted_bytes<=1;load_error<=0;end
  else begin accepted_bytes<=accepted_bytes+25'd1;if(addr!={2'b00,accepted_bytes}||addr>=27'h320000)load_error<=1;end
  prog_addr<=addr[22:1];prog_din<={data,data};prog_dsn<=addr[0]?2'b01:2'b10;
  prog_ba<=addr>=27'h020000&&addr<27'h120000 ?2'd0:addr>=27'h120000&&addr<27'h220000 ?2'd3:2'd2;
  mirror_tile<=addr>=27'h020000&&addr<27'h120000;state<=1;
 end
 if(state==1&&prog_ack)begin state<=prog_rdy?(mirror_tile?3:0):2;if(prog_rdy&&mirror_tile)prog_ba<=1;end
 if(state==2&&prog_rdy)begin state<=mirror_tile?3:0;if(mirror_tile)prog_ba<=1;end
 if(state==3)state<=4;
 if(state==4&&prog_ack)state<=prog_rdy?0:5;
 if(state==5&&prog_rdy)state<=0;
 if(active&&state==0&&!accepted&&accepted_bytes==25'h320000)begin active<=0;image_ready<=!load_error;end
 end
end
endmodule
