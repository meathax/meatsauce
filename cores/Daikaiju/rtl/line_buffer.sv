// SPDX-License-Identifier: GPL-3.0-or-later
// Eight consecutive destination pixels occupy distinct banks even at x wrap.
module a74_line_buffer(
 input wire clk,write_bank,
 input wire [7:0] write_x,write_mask,
 input wire [71:0] write_pixels,
 input wire read_bank,read_valid,
 input wire [7:0] read_x,
 output wire [8:0] read_pixel
);
 wire [8:0] lane_pixel[0:7];
 genvar lane;
 generate for(lane=0;lane<8;lane=lane+1)begin:lanes
  wire [2:0] source_pixel=lane[2:0]-write_x[2:0];
  wire [8:0] destination={1'b0,write_x}+{6'd0,source_pixel};
  a74_line_lane store(.clk(clk),.write_enable(write_mask[source_pixel]),
   .write_address({write_bank,destination[7:3]}),.write_data(write_pixels[source_pixel*9+:9]),
   .read_address({read_bank,read_x[7:3]}),.read_data(lane_pixel[lane]));
 end endgenerate
 assign read_pixel=lane_pixel[read_x[2:0]];
 // Only completed/tagged display banks are observed. Also exclude the cycle
 // immediately after a write; ST_TOP_SCAN/ST_DONE provide that ownership gap.
 reg recent_write=0,recent_bank=0;
 always @(posedge clk)begin recent_write<=|write_mask;recent_bank<=write_bank;end
 // synthesis translate_off
 always @(posedge clk)if(read_valid &&
    ((|write_mask && write_bank==read_bank) || (recent_write && recent_bank==read_bank)))
  $fatal(1,"line buffer read/write bank ownership violation");
 // synthesis translate_on
endmodule

// Plain write/async-read storage so Quartus maps each lane to MLAB; the
// generate-local array with selected write ports stayed in registers.
module a74_line_lane(
 input wire clk,write_enable,
 input wire [5:0] write_address,read_address,
 input wire [8:0] write_data,
 output wire [8:0] read_data
);
 (* ramstyle="MLAB, no_rw_check" *) reg [8:0] pixels[0:63];
 always @(posedge clk)if(write_enable)pixels[write_address]<=write_data;
 assign read_data=pixels[read_address];
endmodule
