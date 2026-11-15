// SPDX-License-Identifier: GPL-3.0-or-later
// Canonical raw-stream lengths from pinned MAME0.289 MRA reconstruction.
// Retain reset until an ordered, complete download follows its profile header.
module snk_rom_download_guard(
 input wire clk,reset,
 input wire download,wr,bridge_wait,
 input wire [15:0] index,
 input wire [26:0] addr,input wire [7:0] data,
 output reg [7:0] profile=8'd13,
 output reg hdr_ok=0,need_rom=1,
 output wire rom_accept,
 output reg [26:0] accepted_bytes=0,expected_bytes=0,
 output reg stream_fault=0
);
 function automatic [26:0] image_bytes(input [7:0] id);
  case(id)
   8'd13:image_bytes=27'h170000;
   8'd11,8'd12,8'd19:image_bytes=27'h160000;
   8'd16:image_bytes=27'h150000;
   8'd14:image_bytes=27'h120C00;
   8'd18:image_bytes=27'h150000;
   8'd15:image_bytes=27'h140000;
   8'd17:image_bytes=27'h130000;
   8'd0,8'd1,8'd2:image_bytes=27'h80000;
   8'd3,8'd4,8'd5:image_bytes=27'h70000;
   8'd6,8'd7,8'd8,8'd9,8'd10:image_bytes=27'h68c00; // TNK3-class: A/B/S 64K slots, tx 0x30000, bg 0x40000, sp 0x50000 (3x32K), proms 0x68000
   default:image_bytes=0;
  endcase
 endfunction
 wire dl0=download&&index==0;
 reg dl0_q=0;
 assign rom_accept=dl0&&wr&&hdr_ok&&!bridge_wait&&!stream_fault&&
                   addr==accepted_bytes&&accepted_bytes<expected_bytes;
 always @(posedge clk)begin
  if(reset)begin
   profile<=8'd13;hdr_ok<=0;need_rom<=1;accepted_bytes<=0;
   expected_bytes<=0;stream_fault<=0;dl0_q<=0;
  end else begin
   dl0_q<=dl0;
   if(dl0&&!dl0_q)begin
    accepted_bytes<=0;stream_fault<=!hdr_ok;need_rom<=1;
   end
   if(dl0&&wr)begin
    if(!hdr_ok||bridge_wait||addr!=accepted_bytes||accepted_bytes>=expected_bytes)
     stream_fault<=1;
    else if(!stream_fault)accepted_bytes<=accepted_bytes+1'b1;
   end
   if(dl0_q&&!dl0)begin
    hdr_ok<=0;
    need_rom<=stream_fault||!hdr_ok||expected_bytes==0||accepted_bytes!=expected_bytes;
   end
   // A new header takes priority over a coincident previous-stream end.
   if(wr&&index==1&&addr==0)begin
    profile<=data;expected_bytes<=image_bytes(data);
    hdr_ok<=image_bytes(data)!=0;need_rom<=1;accepted_bytes<=0;
    stream_fault<=image_bytes(data)==0;
   end
  end
 end
endmodule
