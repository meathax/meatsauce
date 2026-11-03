// SPDX-License-Identifier: GPL-3.0-or-later
// Stain markers describe left-to-right runs in source coordinates. Reversing
// the marker stream reverses neither open runs nor the extra ending pixel.
// Scan the completed flipped MO line in source order using its idle occupancy
// port, retaining only a one-bit mask per pixel in each scanline bank.
module thunderjaws_stain_line(
 input wire clk_sys,reset,start,
 input wire [8:0] line_number,
 input wire [10:0] scan_data,
 output reg scan_enable,
 output wire [9:0] scan_address,
 input wire display_tick,
 input wire [8:0] display_h,display_v,
 output wire stain,
 output reg fault
);
 reg [335:0] mask0,mask1;
 reg [8:0] tag0,tag1,target_line,cursor,read_index;
 reg valid0,valid1,read_valid,issued_last,staining,off_next;
 wire present=|scan_data[3:0];
 wire start_marker=present && scan_data[10] && scan_data[1];
 wire end_marker=present && scan_data[10] && scan_data[2];
 wire active=(read_index!=0 && staining) || start_marker;
 wire stopping=read_index!=0 && off_next && !start_marker;
 wire matching=display_v[0] ? valid1 && tag1==display_v : valid0 && tag0==display_v;
 assign scan_address={1'b0,9'd335-cursor};
 assign stain=display_h<336 && matching && (display_v[0] ? mask1[display_h] : mask0[display_h]);
 always @(posedge clk_sys)begin
  if(reset)begin
   scan_enable<=0;read_valid<=0;issued_last<=0;valid0<=0;valid1<=0;
   cursor<=0;read_index<=0;target_line<=0;tag0<=0;tag1<=0;staining<=0;off_next<=0;fault<=0;
  end else begin
   if(display_tick && display_v<240 && display_h<336 && !matching)fault<=1;
   if(start)begin
    if(scan_enable)fault<=1;
    scan_enable<=1;cursor<=0;target_line<=line_number;read_valid<=0;issued_last<=0;staining<=0;off_next<=0;
    if(line_number[0])valid1<=0;else valid0<=0;
   end else if(scan_enable)begin
    if(!issued_last)begin
     read_valid<=1;read_index<=cursor;
     if(cursor==335)issued_last<=1;else cursor<=cursor+1'b1;
    end
    if(read_valid)begin
     if(target_line[0])mask1[9'd335-read_index]<=active;else mask0[9'd335-read_index]<=active;
     staining<=active && !stopping && read_index!=335;
     off_next<=active && end_marker && !stopping && read_index!=335;
     if(read_index==335)begin
      scan_enable<=0;read_valid<=0;
      if(target_line[0])begin valid1<=1;tag1<=target_line;end
      else begin valid0<=1;tag0<=target_line;end
     end
    end
   end
  end
 end
endmodule
