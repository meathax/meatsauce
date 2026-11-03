// SPDX-License-Identifier: GPL-3.0-or-later
// Feed the framework integer-scaling arithmetic stable source geometry.
// The analog/direct raster itself is untouched by this metadata path.
module spinal_video_scaler(
 input wire clk,reset,direct_video,fb_enable,
 input wire [11:0] fb_width,fb_height,hdmi_width,hdmi_height,
 input wire [1:0] aspect_choice,scale_choice,
 output reg [12:0] video_arx,video_ary
);
 wire rotated=fb_enable && !direct_video && fb_width!=0 && fb_height!=0;
 wire [11:0] width=rotated ? fb_width : 12'd352;
 wire [11:0] height=rotated ? fb_height : 12'd240;
 // ARY=0 encodes Full Screen or a user-defined aspect selection.
 wire [11:0] arx=aspect_choice==0 ? (rotated ? 12'd3 : 12'd4) : {10'd0,aspect_choice}-12'd1;
 wire [11:0] ary=aspect_choice==0 ? (rotated ? 12'd4 : 12'd3) : 12'd0;
 wire [2:0] scale=direct_video ? 3'd0 : scale_choice==1 ? 3'd1 : scale_choice==2 ? 3'd4 : 3'd0;
 wire [12:0] scaled_x,scaled_y;
 video_scale_int native_scale(.CLK_VIDEO(clk),.HDMI_WIDTH(hdmi_width),.HDMI_HEIGHT(hdmi_height),
  .SCALE(scale),.hsize(width),.vsize(height),.arx_i(arx),.ary_i(ary),.arx_o(scaled_x),.ary_o(scaled_y));
 // The framework calculator runs continuously and has no transaction reset.
 // Hold the last coherent pair while an input change propagates through its
 // sequential multiply/divide state machine. 1024 clocks exceed two complete
 // worst-case 16-state passes of the pinned 24-bit divider/12-bit multiplier.
 wire [53:0] input_config={direct_video,rotated,width,height,hdmi_width,hdmi_height,aspect_choice,scale_choice};
 reg [53:0] previous_config;
 reg [10:0] settle;
 always @(posedge clk)begin
  if(reset)begin previous_config<=~input_config;settle<=0;video_arx<=13'd4;video_ary<=13'd3;end
  else if(input_config!=previous_config)begin previous_config<=input_config;settle<=0;end
  else if(settle<11'd1024)settle<=settle+1'b1;
  else begin video_arx<=scaled_x;video_ary<=scaled_y;end
 end
endmodule
