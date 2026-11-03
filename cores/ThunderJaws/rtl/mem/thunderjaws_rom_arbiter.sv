// SPDX-License-Identifier: GPL-3.0-or-later
// Five held read descriptors and one loader writer share the SDRAM controller.
// Admission/response ownership survives logical game reset. Only PLL/init reset
// clears this transport together with the controller. No accepted burst is cut.
module thunderjaws_rom_arbiter (
 input wire clk_sys,init_reset,
 input wire [4:0] read_valid,
 output reg [4:0] read_ready,
 input wire [119:0] read_address,
 input wire [14:0] read_length,
 output reg [4:0] read_response_valid,
 output wire [15:0] read_response_data,
 input wire write_valid,
 output wire write_ready,
 input wire [23:0] write_address,
 input wire [15:0] write_data,
 output reg write_response_valid,
 output wire controller_request,
 input wire controller_ready,
 output reg [23:0] controller_address,
 output reg [15:0] controller_write_data,
 output reg controller_write,
 output reg [2:0] controller_length,
 input wire controller_valid,
 input wire [15:0] controller_data
);
 localparam IDLE=0,READ=1,WRITE=2;
 reg [1:0] state;
 reg [2:0] owner,next_owner,selected,remaining;
 reg found,saw_busy,next_video;
 integer i,candidate;
 always @*begin
  found=0;selected=next_owner;
  // Each playfield has a fixed eight-pixel (48-system-clock) ROM deadline.
  // Give pending playfields first admission, alternating if both are pending.
  // CPU/MO/OKI/loader retain round-robin service in the remaining bandwidth.
  if(read_valid[1] || read_valid[2])begin
   found=1;selected=read_valid[1] && (!read_valid[2] || !next_video) ? 1 : 2;
  end
  for(i=0;i<6;i=i+1)begin
   candidate=next_owner+i;if(candidate>=6)candidate=candidate-6;
   if(!found && (candidate==5 ? write_valid : read_valid[candidate]))begin selected=3'(candidate);found=1;end
  end
  read_ready=0;
  if(!init_reset && state==IDLE && found && controller_ready && selected<5)read_ready[selected]=1;
  controller_address=0;controller_write_data=0;controller_write=0;controller_length=0;
  if(found)begin
   if(selected==5)begin controller_address=write_address;controller_write_data=write_data;controller_write=1;end
   else begin controller_address=read_address[selected*24+:24];controller_length=read_length[selected*3+:3];end
  end
 end
 // Select only at actual controller admission. Never reserve an unaccepted
 // noncritical request while refresh/recovery hides newly pending video work.
 assign write_ready=!init_reset && state==IDLE && found && controller_ready && selected==5;
 assign controller_request=!init_reset && state==IDLE && found && controller_ready;
 assign read_response_data=controller_data;
 // Data and valid identify the same controller beat at the consuming edge.
 always @*begin
  read_response_valid=0;
  if(!init_reset && state==READ && controller_valid)read_response_valid[owner]=1;
 end
 always @(posedge clk_sys)begin
  write_response_valid<=0;
  if(init_reset)begin state<=IDLE;owner<=0;next_owner<=0;saw_busy<=0;remaining<=0;next_video<=0;
  end else case(state)
   IDLE:if(controller_request)begin
    owner<=selected;remaining<=controller_length;saw_busy<=0;
    if(selected==1 || selected==2)next_video<=selected==1;
    if(selected==5)state<=WRITE;else state<=READ;
   end
   READ:if(controller_valid)begin
    if(remaining==0)begin
     // Video priority must not restart the background round-robin cursor;
     // otherwise a repeating PF phase can starve the program CPU forever.
     if(owner!=1 && owner!=2)next_owner<=owner==5 ? 0 : owner+1;
     state<=IDLE;
    end
    else remaining<=remaining-1;
   end
   WRITE:begin
    if(!controller_ready)saw_busy<=1;
    if(saw_busy && controller_ready)begin write_response_valid<=1;next_owner<=0;state<=IDLE;end
   end
  endcase
 end
endmodule
