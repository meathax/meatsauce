// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy Unit host binding for the MIT Credits overlay. One clock, original CE.
`default_nettype none
module heavyunit_credits #(parameter integer LOGICAL_RASTER=0) (
 input wire clk,reset,ce_pixel,menu_trigger,dismiss,frame_boundary,
 input wire [1:0] orientation,
 input wire [23:0] rgb,
 input wire hs,vs,hb,vb,de,
 input wire [7:0] pixel_x,
 output wire [23:0] rgb_out,
 output wire hs_out,vs_out,hb_out,vb_out,de_out,ce_out,frame_boundary_out,
 output wire [7:0] pixel_x_out,
 output wire active,
 output wire pause_active
);
 // 180 is already rendered upstream. Only the enabled downstream quarter turn
 // needs inverse glyph orientation; direct video always reaches 0 here.
 wire [1:0] credits_rotation=orientation==2'd1 ? 2'd1 :
                             orientation==2'd2 ? 2'd3 : 2'd0;
 wire overlay_de;
 credits_overlay #(.WIDTH(256),.HEIGHT(224),.LOGICAL_RASTER(LOGICAL_RASTER)) credits (
  .clk_video(clk),.reset,.ce_pixel,.menu_trigger,.dismiss,
  .rotation(credits_rotation),.r_in(rgb[23:16]),.g_in(rgb[15:8]),.b_in(rgb[7:0]),
  .hs_in(hs),.vs_in(vs),.hblank_in(hb),.vblank_in(vb),
  .r_out(rgb_out[23:16]),.g_out(rgb_out[15:8]),.b_out(rgb_out[7:0]),
  .hs_out,.vs_out,.hblank_out(hb_out),.vblank_out(vb_out),.de_out(overlay_de),.active
 );
 // Match the overlay's three CE-enabled RGB/sync/blanking registers. Preserve
 // the original DE qualifier and X coordinate for the framebuffer producer.
 reg [7:0] x_pipe[0:2];
 reg [2:0] de_pipe,eof_pipe;
 reg eof_pending;
 (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] active_sync;
 always @(posedge clk) begin
  if(reset) begin
   for(integer i=0;i<3;i=i+1)x_pipe[i]<=0;
   de_pipe<=0;eof_pipe<=0;eof_pending<=0;active_sync<=0;
  end else begin
   active_sync<={active_sync[0],active};
   if(frame_boundary)eof_pending<=1;
   if(ce_pixel) begin
    x_pipe[0]<=pixel_x;x_pipe[1]<=x_pipe[0];x_pipe[2]<=x_pipe[1];
    de_pipe<={de_pipe[1:0],de};
    eof_pipe<={eof_pipe[1:0],eof_pending|frame_boundary};
    eof_pending<=0;
   end
  end
 end
 assign pixel_x_out=x_pipe[2];
 assign de_out=overlay_de && de_pipe[2];
 assign ce_out=ce_pixel;
 assign frame_boundary_out=ce_pixel && eof_pipe[2];
 assign pause_active=active_sync[1];
endmodule
`default_nettype wire
