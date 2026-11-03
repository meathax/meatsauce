// SPDX-License-Identifier: GPL-3.0-or-later
// Connect the retained-frame DDR rotation donor to the processed video path.
// Direct video bypasses the framebuffer immediately; after a re-enable or
// direction change a newly completed and published frame is required.
module spinal_video_rotation(
 input wire clk,reset,request,ccw,direct_video,ce,de,vs,
 input wire [7:0] red,green,blue,input wire fb_vblank,ddram_busy,
 output wire fb_enable,output wire [4:0] fb_format,
 output wire [11:0] fb_width,fb_height,output wire [31:0] fb_base,output wire [13:0] fb_stride,
 output wire ddram_clk,ddram_we,ddram_rd,output wire [28:0] ddram_address,
 output wire [63:0] ddram_data,output wire [7:0] ddram_byteenable,ddram_burstcount,
 output wire overflow,output wire [31:0] completed_frames,dropped_frames
);
 wire active=request && !direct_video;
 wire donor_enable;wire [31:0] donor_base;
 reg previous_active,previous_ccw,fresh,wait_publish;
 reg [31:0] previous_base,previous_completed;
 assign fb_base=donor_base;
 // Direction is registered into the producer. Suppress the old publication
 // immediately when the requested direction changes, before that register
 // updates; the existing completion fence hides any old-direction tail.
 assign fb_enable=active && fresh && donor_enable && ccw==previous_ccw;
 always @(posedge clk) begin
  if(reset)begin
   previous_active<=0;previous_ccw<=0;fresh<=0;wait_publish<=0;previous_base<=0;previous_completed<=0;
  end else begin
   previous_active<=active;previous_ccw<=ccw;
   if(!active || !previous_active || ccw!=previous_ccw)begin
    fresh<=0;wait_publish<=0;previous_base<=donor_base;previous_completed<=completed_frames;
   end else if(!fresh && !wait_publish && completed_frames-previous_completed>=32'd2)begin
    // One completion can be the tail of a frame begun before bypass/direction
    // changed. Wait for a second completion and its subsequent publication.
    wait_publish<=1;previous_base<=donor_base;
   end else if(!fresh && wait_publish && donor_enable && donor_base!=previous_base)fresh<=1;
  end
 end
 spinal_rotate rotation(.clk_sys(clk),.init_reset(reset),.enable(active),.rotate_ccw(previous_ccw),
  .ce_pixel(ce),.de(de),.vs(vs),.rgb({red,green,blue}),.fb_vblank(fb_vblank),.ddram_busy(ddram_busy),
  .fb_enable(donor_enable),.fb_format(fb_format),.fb_width(fb_width),.fb_height(fb_height),.fb_base(donor_base),.fb_stride(fb_stride),
  .ddram_clk(ddram_clk),.ddram_we(ddram_we),.ddram_rd(ddram_rd),.ddram_address(ddram_address),.ddram_data(ddram_data),
  .ddram_byteenable(ddram_byteenable),.ddram_burstcount(ddram_burstcount),.overflow(overflow),
  .completed_frames(completed_frames),.dropped_frames(dropped_frames));
endmodule
