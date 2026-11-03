// SPDX-License-Identifier: GPL-3.0-or-later
// REFERENCE ONLY framebuffer producer. Synthetic line/frame metadata is not
// Heavy Unit CRT timing. Input CE/RGB/DE/x/VB must describe the same pixel.
// DDR writes are pulses for the shared queued owner; BUSY cannot stall the
// pristine screen_rotate donor. The owner must retain every pulse until accepted.
module airbustr_reference_framebuffer (
 input logic clk,reset,enable,
 input logic [1:0] orientation_generation, // actual orientation, before donor mapping
 input logic writes_drained, // owner queue empty and no incoming pixel write
 input logic linearize_flip, // cancel flip address order; RGB is already oriented
 input logic [1:0] rotation, // 0=CW90,1=CCW90,2=180,3=disabled
 input logic pixel_ce,pixel_de,pixel_vblank,
 input logic [7:0] pixel_x,
 input logic [23:0] pixel_rgb,
 input logic fb_vblank,fb_low_latency,ddram_busy,
 output logic producer_quiescent,metadata_error,
 output logic fb_enable,video_rotated,
 output logic [4:0] fb_format,
 output logic [11:0] fb_width,fb_height,
 output logic [31:0] fb_base,
 output logic [13:0] fb_stride,
 output logic [7:0] write_burstcount,write_byteenable,
 output logic [28:0] write_address,
 output logic [63:0] write_data,
 output logic write_valid,
 output logic reference_ce,reference_de,reference_vs
);
 logic active,old_blank,marker_pending,held_blank,held_consumer_blank,halt_pending;
 logic [1:0] mode;
 logic linear_mode;
 logic [1:0] generation;
 logic [2:0] completed_slots,completion_pending;
 logic [15:0] frame_write_count;
 logic [1:0] frame_write_slot;
 wire [1:0] offered_slot=write_address[21:20];
 wire [1:0] selected_slot=fb_base[24:23];
 wire [28:0] donor_address;
 wire [7:0] donor_byteenable;
 // A 256x224 32-bit image occupies28672 64-bit words. Preserve slot high bits.
 wire [19:0] linear_word=20'd28671-donor_address[19:0];
 assign write_address=linear_mode ? {donor_address[28:20],linear_word} : donor_address;
 assign write_byteenable=linear_mode ? {donor_byteenable[3:0],donor_byteenable[7:4]} : donor_byteenable;
 logic [1:0] warm_frames;
 wire donor_enable,donor_write;
 logic [2:0] drain;
 wire frame_edge=pixel_ce && pixel_vblank && !old_blank;
 // Deactivation takes effect at a complete frame boundary. Hold the donor's
 // VS stable thereafter so disabled producers cannot advance buffer ownership.
 always_ff @(posedge clk) begin
  if(reset) begin
   active<=0;old_blank<=0;marker_pending<=0;held_blank<=1;
   held_consumer_blank<=0;halt_pending<=0;
   mode<=3;linear_mode<=0;generation<=0;completed_slots<=0;completion_pending<=0;frame_write_count<=0;frame_write_slot<=0;warm_frames<=0;drain<=0;metadata_error<=0;
  end else begin
   // Validity follows physical queued words, independently of donor geometry warmup.
   if(writes_drained) begin completed_slots<=completed_slots|completion_pending;completion_pending<=0;end
   if(write_valid) begin
    frame_write_count<=frame_write_count+1'b1;
    if(frame_write_count==0) begin completed_slots[offered_slot]<=0;completion_pending[offered_slot]<=0;frame_write_slot<=offered_slot;end
    else if(offered_slot!=frame_write_slot) metadata_error<=1;
    if(frame_write_count==16'd57343) completion_pending[offered_slot]<=1;
    if(frame_write_count>=16'd57344 || offered_slot==3) metadata_error<=1;
   end
   if(frame_edge) begin
    if(frame_write_count!=0 && frame_write_count!=16'd57344) metadata_error<=1;
    frame_write_count<=0;
    if(generation!=orientation_generation || mode!=rotation || linear_mode!=(linearize_flip && rotation==2)) begin completed_slots<=0;completion_pending<=0;end
   end
   // A mid-frame user orientation request discards the old partial image immediately.
   if(generation!=orientation_generation) begin completed_slots<=0;completion_pending<=0;end
   if(pixel_ce) old_blank<=pixel_vblank;
   if(frame_edge) begin active<=enable && rotation!=3;mode<=rotation;generation<=orientation_generation;linear_mode<=linearize_flip && rotation==2;end
   if(frame_edge) begin
    if(!active || !enable || rotation==3 || mode!=rotation || linear_mode!=(linearize_flip && rotation==2)) warm_frames<=0;
    else if(warm_frames!=3) warm_frames<=warm_frames+1'b1;
   end
   // One blank CE after disabling establishes VS-low in donor CE state.
   // Re-enable therefore observes a fresh VS rise before drawing its first frame.
   halt_pending<=active && frame_edge && !(enable && rotation!=3);
   marker_pending<=active && pixel_ce && pixel_de && pixel_x==255;
   if(active && pixel_ce) held_blank<=pixel_vblank;
   if(active) held_consumer_blank<=fb_vblank;
   drain<={drain[1:0],active};
   if(marker_pending && pixel_ce) metadata_error<=1;
  end
 end
 assign reference_ce=!reset && ((active && (pixel_ce || marker_pending)) || halt_pending);
 assign reference_de=active && pixel_ce && !marker_pending && pixel_de;
 assign reference_vs=halt_pending || !active ? 1'b0 : pixel_ce ? pixel_vblank : held_blank;
 assign producer_quiescent=!active && drain==0 && !write_valid && !marker_pending && !halt_pending;
 // The pristine donor has no reset. A resumed VS initially measures zero
 // lines; two complete frame boundaries restore its geometry before publishing.
 wire fb_publishable=active && generation==orientation_generation && warm_frames>=2 && donor_enable;
 // sys folds FB_EN into fb_crc; Main re-applies the video mode (HDMI PLL
 // retune) on every change. The consumer selects slots on its own vblank,
 // so it can land on a frame whose final DDR words are still queued. Keep
 // FB_EN asserted after the first complete frame of this mode/generation.
 logic fb_published;
 always_ff @(posedge clk) begin
  if(reset || !fb_publishable) fb_published<=0;
  else if(selected_slot!=3 && completed_slots[selected_slot]) fb_published<=1;
 end
 assign fb_enable=fb_published;
 // FB_WIDTH/FB_HEIGHT also feed sys fb_crc. Publish the fixed logical
 // geometry; a frame with a renderer-missed (DE-low) line must not change it.
 wire [11:0] donor_fb_width,donor_fb_height;
 assign fb_width =mode[1] ? 12'd256 : 12'd224;
 assign fb_height=mode[1] ? 12'd224 : 12'd256;
 assign write_valid=active && warm_frames>=2 && donor_write;
 airbustr_screen_rotate rotate (
  .CLK_VIDEO(clk),.CE_PIXEL(reference_ce),
  .VGA_R(pixel_rgb[23:16]),.VGA_G(pixel_rgb[15:8]),.VGA_B(pixel_rgb[7:0]),
  .VGA_HS(1'b1),.VGA_VS(reference_vs),.VGA_DE(reference_de),
  .rotate_ccw(mode==1),.no_rotate(mode[1]),.flip(mode==2),
  .video_rotated,.FB_EN(donor_enable),.FB_FORMAT(fb_format),
  .FB_WIDTH(donor_fb_width),.FB_HEIGHT(donor_fb_height),.FB_BASE(fb_base),.FB_STRIDE(fb_stride),
  .FB_VBL(active ? fb_vblank : held_consumer_blank),.FB_LL(1'b0), // Compatibility output uses complete-frame triple buffering; asynchronous LL overlap is unqualified.
  .DDRAM_CLK(),.DDRAM_BUSY(ddram_busy),.DDRAM_BURSTCNT(write_burstcount),
  .DDRAM_ADDR(donor_address),.DDRAM_DIN(write_data),.DDRAM_BE(donor_byteenable),
  .DDRAM_WE(donor_write),.DDRAM_RD()
 );
endmodule
