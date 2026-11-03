// SPDX-License-Identifier: GPL-3.0-or-later
// Complete-frame quarter-turn producer. No slot is published before all of
// its DDR writes are accepted. A bounded queue overflow discards that frame.
module dfjail_framebuffer #(parameter FIFO_AW=9, parameter [6:0] MEM_BASE=7'b0010010)(
 input CLK_VIDEO,reset,CE_PIXEL,
 input [7:0] VGA_R,VGA_G,VGA_B,
 input VGA_HS,VGA_VS,VGA_DE,
 input rotate_ccw,no_rotate,flip,
 output video_rotated,FB_EN,
 output [4:0] FB_FORMAT,
 output [11:0] FB_WIDTH,FB_HEIGHT,
 output [31:0] FB_BASE,
 output [13:0] FB_STRIDE,
 input FB_VBL,FB_LL,
 output DDRAM_CLK,input DDRAM_BUSY,
 output [7:0] DDRAM_BURSTCNT,
 output [28:0] DDRAM_ADDR,
 output [63:0] DDRAM_DIN,
 output [7:0] DDRAM_BE,
 output DDRAM_WE,DDRAM_RD,
 output reg overflow
);
localparam FREE=0,CAPTURE=1,DRAIN=2,READY=3,DISPLAY=4;
reg [2:0] state[0:2];
reg [19:0] outstanding[0:2];
reg valid_frame[0:2],ccw[0:2];
reg [11:0] width[0:2],height[0:2];
reg [13:0] stride[0:2];
reg [1:0] writer,front;
reg writing,front_valid,frame_bad;
reg old_vs,old_de;
reg [11:0] x,y,measured_width,source_width,source_height;
reg [19:0] pixel_count;
// Consumer vblank is a single-bit asynchronous event, synchronized locally.
(* async_reg="true" *) reg fb_vbl_meta,fb_vbl_sync;
reg old_fb_vbl;
wire frame_edge=CE_PIXEL && VGA_VS && !old_vs;
wire consume_edge=fb_vbl_sync && !old_fb_vbl;
wire request_change=no_rotate || (front_valid && ccw[front]!=rotate_ccw);
assign FB_EN=front_valid && !request_change;
assign video_rotated=!no_rotate;
assign FB_FORMAT=5'b00110;
assign FB_WIDTH=front_valid ? height[front] : source_height;
assign FB_HEIGHT=front_valid ? width[front] : source_width;
assign FB_STRIDE=front_valid ? stride[front] : (({2'b0,source_height}+3)>>2)<<4;
assign FB_BASE={MEM_BASE,front,23'd0};
assign DDRAM_CLK=CLK_VIDEO;
assign DDRAM_BURSTCNT=1;
assign DDRAM_RD=0;
// Synchronous-read FIFO; the output register remains stable throughout BUSY.
localparam DEPTH=1<<FIFO_AW;
reg [46:0] fifo[0:DEPTH-1]; // slot, byte address[22:2], BGR24
reg [FIFO_AW-1:0] wr_ptr,rd_ptr;
reg [FIFO_AW:0] count;
reg [46:0] read_data,held;
reg read_pending,held_valid;
wire accepted=held_valid && !DDRAM_BUSY;
wire fetch=!read_pending && (!held_valid || accepted) && count!=0;
wire pixel_offer=CE_PIXEL && VGA_DE && writing && !frame_bad && !frame_edge;
wire queue_room=count<DEPTH || fetch;
wire push=pixel_offer && queue_room;
wire [23:0] offset_cw=x*stride[writer]+(height[writer]-1'b1-y)*4;
wire [23:0] offset_ccw=(width[writer]-1'b1-x)*stride[writer]+y*4;
wire [23:0] offset=ccw[writer] ? offset_ccw : offset_cw;
wire [46:0] incoming={writer,offset[22:2],VGA_B,VGA_G,VGA_R};
assign DDRAM_WE=held_valid;
assign DDRAM_ADDR={MEM_BASE,held[46:45],held[44:25]};
assign DDRAM_BE=held[24] ? 8'hf0 : 8'h0f;
assign DDRAM_DIN={8'd0,held[23:0],8'd0,held[23:0]};
integer i;
integer chosen;
always @(posedge CLK_VIDEO) begin
 if(reset) begin
  writer<=0;front<=0;writing<=0;front_valid<=0;frame_bad<=0;
  old_vs<=0;old_de<=0;x<=0;y<=0;measured_width<=0;source_width<=0;source_height<=0;pixel_count<=0;
  fb_vbl_meta<=0;fb_vbl_sync<=0;old_fb_vbl<=0;
  wr_ptr<=0;rd_ptr<=0;count<=0;read_pending<=0;held_valid<=0;read_data<=0;held<=0;overflow<=0;
  for(i=0;i<3;i=i+1) begin state[i]<=FREE;outstanding[i]<=0;valid_frame[i]<=0;ccw[i]<=0;width[i]<=0;height[i]<=0;stride[i]<=0;end
 end else begin
  fb_vbl_meta<=FB_VBL;fb_vbl_sync<=fb_vbl_meta;old_fb_vbl<=fb_vbl_sync;
  if(accepted)held_valid<=0;
  read_pending<=fetch;
  if(fetch)begin read_data<=fifo[rd_ptr];rd_ptr<=rd_ptr+1'b1;end
  if(read_pending)begin held<=read_data;held_valid<=1;end
  if(push)begin fifo[wr_ptr]<=incoming;wr_ptr<=wr_ptr+1'b1;end
  case({push,fetch})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
  for(i=0;i<3;i=i+1)begin
   case({push && writer==i,accepted && held[46:45]==i})
    2'b10:outstanding[i]<=outstanding[i]+1'b1;
    2'b01:outstanding[i]<=outstanding[i]-1'b1;
    default:;
   endcase
   if(state[i]==DRAIN && outstanding[i]==0)state[i]<=valid_frame[i] ? READY : FREE;
   // Old-generation images cannot be selected after a user mode change.
   if(state[i]==READY && (no_rotate || ccw[i]!=rotate_ccw))state[i]<=FREE;
  end
  if(pixel_offer && !queue_room)begin overflow<=1;frame_bad<=1;end
  if(CE_PIXEL)begin
   old_vs<=VGA_VS;old_de<=VGA_DE;
   if(VGA_DE)begin
    x<=x+1'b1;pixel_count<=pixel_count+1'b1;
    if(writing && (x>=width[writer] || y>=height[writer]))frame_bad<=1;
   end
   if(old_de && !VGA_DE)begin
    measured_width<=x;x<=0;y<=y+1'b1;
    if(writing && x!=width[writer])frame_bad<=1;
   end
   if(frame_edge)begin
    source_width<=measured_width;source_height<=y;
    x<=0;y<=0;pixel_count<=0;frame_bad<=0;writing<=0;
    if(writing)begin
     state[writer]<=DRAIN;
     valid_frame[writer]<=!frame_bad && pixel_count==width[writer]*height[writer] && y==height[writer] && !no_rotate && ccw[writer]==rotate_ccw;
    end
    chosen=-1;
    for(i=0;i<3;i=i+1)if(state[i]==FREE)chosen=i;
    if(!no_rotate && chosen>=0 && measured_width!=0 && y!=0)begin
     writer<=chosen;writing<=1;state[chosen]<=CAPTURE;
     width[chosen]<=measured_width;height[chosen]<=y;
     stride[chosen]<=((y+3)>>2)<<4;
     ccw[chosen]<=rotate_ccw;valid_frame[chosen]<=0;
    end
   end
  end
  if(consume_edge)begin
   chosen=-1;
   for(i=0;i<3;i=i+1)if(state[i]==READY && !no_rotate && ccw[i]==rotate_ccw)chosen=i;
   if(chosen>=0)begin
    if(front_valid)state[front]<=FREE;
    front<=chosen;front_valid<=1;state[chosen]<=DISPLAY;
   end else if(no_rotate && front_valid)begin state[front]<=FREE;front_valid<=0;end
  end
 end
end
endmodule
