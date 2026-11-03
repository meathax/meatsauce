// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed-output-cadence nearest-neighbour content resize. The accumulator
// selects source addresses only: it NEVER creates or gates a pixel enable.
module dfjail_crt_geometry(
 input clk,reset,line_reset,read_ce,
 input [9:0] read_x,source_start,source_end,
 input signed [4:0] size_step,
 input signed [8:0] position,
 output [9:0] source_address,
 output window_active,source_active
);
wire signed [12:0] source_width=$signed({3'b0,source_end})-$signed({3'b0,source_start});
wire signed [12:0] output_width=source_width+($signed(size_step)*16);
// Keep the display aperture clear of sync. H-position moves content inside
// that aperture, with black edge fill, rather than moving DE into HSync.
wire signed [12:0] aperture_left=$signed({3'b0,source_start})-($signed(size_step)*8);
wire signed [12:0] left_edge=aperture_left+$signed(position);
wire signed [12:0] output_x=$signed({3'b0,read_x});
wire source_span=output_width>0 && output_x>=left_edge && output_x<left_edge+output_width;
assign window_active=output_width>0 && output_x>=aperture_left && output_x<aperture_left+output_width;
assign source_active=window_active && source_span;
reg [12:0] phase;
reg [9:0] address;
wire [13:0] advanced={1'b0,phase}+source_width;
wire [1:0] advance_count=advanced>=2*output_width ? 2 : advanced>=output_width ? 1 : 0;
assign source_address=address;
always @(posedge clk)begin
 if(reset || line_reset)begin phase<=0;address<=source_start;end
 else if(read_ce && source_span)begin
  phase<=advanced-advance_count*output_width;
  address<=address+advance_count;
 end
end
endmodule
