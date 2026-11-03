// Project-owned adaptation of vendor/thunderjaws/thunderjaws_rotate.sv.
// On every enabled FIFO read, pop == head_valid: an empty-head load
// has both zero; a valid-head replacement requires pop. Selecting the
// lookahead address with registered head_valid removes raw DDR BUSY
// from the RAM address cone without changing any accepted transfer.
// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer screen_rotate address/format convention (Sorgelig, GPL-2.0-or-later).
// Retain each DDR write through BUSY and publish only a physically completed
// producer frame. Geometry is measured from the actual post-mixer DE stream,
// including scandoubler/HQ2x. Incomplete/overloaded frames are never displayed.
module spinal_rotate #(parameter integer FIFO_DEPTH=1024)(
 input wire clk_sys,init_reset,enable,rotate_ccw,
 input wire ce_pixel,de,vs,
 input wire [23:0] rgb,
 input wire fb_vblank,ddram_busy,
 output wire fb_enable,
 output wire [4:0] fb_format,
 output wire [11:0] fb_width,fb_height,
 output wire [31:0] fb_base,
 output wire [13:0] fb_stride,
 output wire ddram_clk,ddram_we,ddram_rd,
 output wire [28:0] ddram_address,
 output wire [63:0] ddram_data,
 output wire [7:0] ddram_byteenable,ddram_burstcount,
 output reg overflow,
 output reg [31:0] completed_frames,dropped_frames
);
 localparam PW=$clog2(FIFO_DEPTH),CW=$clog2(FIFO_DEPTH+1);
 typedef struct packed {
  logic marker,bad,ccw;
  logic [1:0] slot;
  logic [22:0] offset;
  logic [23:0] rgb;
 } packet_t;
 reg [51:0] fifo[0:FIFO_DEPTH-1];
 packet_t head,push_packet;
 reg [PW-1:0] rp,wp;
 reg [CW-1:0] count;
 reg head_valid;
 wire pop=head_valid && (head.marker || !ddram_busy);
 wire space=count<FIFO_DEPTH || pop;
 reg marker_pending;
 packet_t end_packet;
 reg old_vs,old_de,armed,capturing,frame_pending,frame_bad;
 reg mode;
 reg [1:0] write_slot,read_slot,ready_slot;
 reg read_valid,ready_valid,ready_mode,read_mode;
 reg [10:0] learned_w,capture_w,x;
 reg [9:0] learned_h,capture_h,y,lines;
 reg [20:0] written;
 reg [10:0] slot_width[0:2];
 reg [9:0] slot_height[0:2];
 (* async_reg="true" *) reg fb_vb_meta,fb_vb_sync;
 reg fb_vb_old;
 wire consume=fb_vb_sync && !fb_vb_old && ready_valid;
 wire frame_end=vs && !old_vs;
 wire first_pixel=ce_pixel && de && !old_de;
 wire start_frame=first_pixel && armed && enable && !frame_pending;
 wire pixel=ce_pixel && de && (capturing || start_frame) && !frame_end;
 wire [10:0] pixel_x=old_de ? x+11'd1 : 11'd0;
 wire [9:0] pixel_y=old_de ? y : lines;
 wire [10:0] width_now=start_frame ? learned_w : capture_w;
 wire [9:0] height_now=start_frame ? learned_h : capture_h;
 wire ccw_now=start_frame ? rotate_ccw : mode;
 function automatic [1:0] free_slot(input [1:0] a,b,input b_valid);
 begin
  if(a!=0 && (!b_valid || b!=0))free_slot=0;
  else if(a!=1 && (!b_valid || b!=1))free_slot=1;
  else free_slot=2;
 end endfunction
 wire [1:0] target=start_frame ? free_slot(read_slot,ready_slot,ready_valid) : write_slot;
 wire [10:0] column=ccw_now ? width_now-11'd1-pixel_x : pixel_x;
 wire [9:0] row=ccw_now ? pixel_y : height_now-10'd1-pixel_y;
 wire [20:0] word_offset=column*height_now+row;
 wire in_bounds=pixel_x<width_now && pixel_y<height_now;
 wire push=space && (marker_pending || (pixel && in_bounds));
 always @*begin
  push_packet=end_packet;
  if(!marker_pending)begin
   push_packet.marker=0;push_packet.bad=0;push_packet.ccw=ccw_now;
   push_packet.slot=target;push_packet.offset={word_offset,2'b00};push_packet.rgb=rgb;
  end
 end
 wire [PW-1:0] read_address=rp+PW'(head_valid);
 always @(posedge clk_sys)begin
  if(push)fifo[wp]<=push_packet;
  if((!head_valid || pop) && count>CW'(pop))head<=fifo[read_address];
 end
`ifndef SYNTHESIS
 always @(posedge clk_sys) if(!init_reset && (!head_valid || pop) && count>CW'(pop)) begin
  assert(pop==head_valid) else $fatal(1,"ROTATE_READ_ADDRESS_EQUIVALENCE");
 end
`endif
 assign ddram_clk=clk_sys;
 assign ddram_rd=0;
 assign ddram_we=head_valid && !head.marker && !init_reset;
 assign ddram_burstcount=1;
 assign ddram_address={7'b0010010,head.slot,head.offset[22:3]};
 assign ddram_byteenable=head.offset[2] ? 8'hf0 : 8'h0f;
 wire [31:0] pixel_word={8'd0,head.rgb[7:0],head.rgb[15:8],head.rgb[23:16]};
 assign ddram_data={pixel_word,pixel_word};
 assign fb_enable=enable && read_valid && read_mode==rotate_ccw;
 assign fb_format=5'b00110;
 assign fb_base={7'b0010010,read_slot,23'd0};
 assign fb_width={2'd0,slot_height[read_slot]};
 assign fb_height={1'd0,slot_width[read_slot]};
 assign fb_stride={2'd0,slot_height[read_slot],2'b00};
 integer i;
 always @(posedge clk_sys)begin
  if(init_reset)begin
   rp<=0;wp<=0;count<=0;head_valid<=0;marker_pending<=0;
   old_vs<=0;old_de<=0;armed<=0;capturing<=0;frame_pending<=0;frame_bad<=0;mode<=0;
   write_slot<=1;read_slot<=0;ready_slot<=0;read_valid<=0;ready_valid<=0;ready_mode<=0;read_mode<=0;
   learned_w<=336;learned_h<=240;capture_w<=336;capture_h<=240;x<=0;y<=0;lines<=0;written<=0;
   fb_vb_meta<=0;fb_vb_sync<=0;fb_vb_old<=0;overflow<=0;completed_frames<=0;dropped_frames<=0;
   for(i=0;i<3;i=i+1)begin slot_width[i]<=336;slot_height[i]<=240;end
  end else begin
   fb_vb_meta<=fb_vblank;fb_vb_sync<=fb_vb_meta;fb_vb_old<=fb_vb_sync;
   old_vs<=vs;
   if(push)wp<=wp+1'b1;
   if(pop)rp<=rp+1'b1;
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
   if((!head_valid || pop) && count>CW'(pop))head_valid<=1;
   else if(pop)head_valid<=0;
   if(push && marker_pending)marker_pending<=0;
   if(consume)begin read_slot<=ready_slot;read_mode<=ready_mode;read_valid<=1;ready_valid<=0;end
   // A marker is behind every write of its frame, including the final BUSY
   // command. Simultaneous consumer VBlank retains a newly completed frame.
   if(pop && head.marker)begin
    frame_pending<=0;
    if(!head.bad)begin ready_slot<=head.slot;ready_mode<=head.ccw;ready_valid<=1;completed_frames<=completed_frames+1'b1;end
    else dropped_frames<=dropped_frames+1'b1;
   end
   if(ce_pixel)begin
    old_de<=de;
    if(de)begin x<=pixel_x;y<=pixel_y;if(!old_de)lines<=lines+1'b1;end
    if(old_de && !de)begin
     if(capturing && x+1'b1!=capture_w)frame_bad<=1;
     learned_w<=x+1'b1;
    end
   end
   if(first_pixel && armed)armed<=0;
   if(start_frame)begin
    capturing<=1;frame_pending<=1;frame_bad<=!space;
    write_slot<=target;mode<=rotate_ccw;capture_w<=learned_w;capture_h<=learned_h;
    slot_width[target]<=learned_w;slot_height[target]<=learned_h;
    written<=space && in_bounds ? 21'd1 : 21'd0;
   end else if(pixel && in_bounds && space)written<=written+1'b1;
   if(pixel && in_bounds && (!space || marker_pending))begin overflow<=1;frame_bad<=1;end
   if(pixel && !in_bounds)frame_bad<=1;
   if(frame_end)begin
    old_de<=0;lines<=0;x<=0;y<=0;armed<=1;
    if(lines!=0)learned_h<=lines;
    if(capturing)begin
     capturing<=0;marker_pending<=1;
     end_packet.marker<=1;end_packet.bad<=frame_bad || written!=capture_w*capture_h || lines!=capture_h;
     end_packet.ccw<=mode;end_packet.slot<=write_slot;end_packet.offset<=0;end_packet.rgb<=0;
    end
   end
  end
 end
endmodule
