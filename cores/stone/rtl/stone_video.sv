// SPDX-License-Identifier: GPL-3.0-or-later
// TMS screen-refresh address translation follows MAME get_display_params and
// artmagic scanline. A dual-clock line store streams the next row while blanked.
// The row is read from the on-chip VRAM scanout port, one word per clock.
//
// The transfer starts from the display scheduler's request (screen_req), not
// from the arbitrated bus cycle. The GSP bus can be held for tens of
// microseconds by an emulated 512-word VRAM shift-register transfer, far longer
// than the 16 us horizontal blank; starting on the bus grant made those lines
// repeat the previous row. The refresh never enters the GSP bus arbiter at
// all (tms34010_system EXT_SCREEN): screen_ack retires the request directly
// once the row is stored, and stays high until screen_req falls, so every
// line's request is issued and served within its own horizontal blank.
`default_nettype none
module stone_video(input wire clk,reset,vclk,vreset,
 input wire screen_req,input wire [13:0] srfaddr,input wire [15:0] dpytap,input wire org,
 output wire screen_ack,input wire hs,vs,hblank,vblank,blank,
 output reg [17:0] vram_addr,input wire [7:0] vram_data,
 output wire [7:0] pixel,output reg out_hs,out_vs,out_de,out_hb,out_vb,output reg underrun);
 // Scanout-port read latency in clocks, from vram_addr to vram_data.
 localparam LATENCY=4;
 reg [7:0] linebuf[0:1023];
 reg bank,completed_bank;
 reg [1:0] state;
 reg [8:0] count,col,issued;
 reg [17:0] base;
 reg [LATENCY:0] valid;
 reg req_d,done;
 assign screen_ack=done;
 wire [15:0] dpyadr={org ? srfaddr:~srfaddr,2'b0};
 wire [8:0] startcol=({dpyadr[3:2],7'b0} | {dpytap[7:0],1'b0});
 reg [1:0] bank_sync;
 reg active_bank,prev_blank,consumed_bank,have_line;
 reg [8:0] x;
 reg [7:0] pixel_q;
 assign pixel=pixel_q;
 always @(posedge clk) begin
   valid<={valid[LATENCY-1:0],1'b0};
   req_d<=screen_req;
   if(!screen_req) done<=0;
   if(reset) begin req_d<=0;done<=0;bank<=0;completed_bank<=0;state<=0;vram_addr<=0;count<=0;col<=0;issued<=0;base<=0;valid<=0;end
   else case(state)
     0:if(screen_req && !req_d) begin
       bank<=~bank;count<=0;issued<=0;col<=startcol;
       base<={dpyadr[14],dpyadr[12:4],8'b0};state<=1;
     end
     1:begin
       // Issue one address per clock; data returns LATENCY clocks later.
       if(issued!=320) begin
         vram_addr<=base+{9'b0,col};col<=col+1'b1;issued<=issued+1'b1;valid[0]<=1;
       end
       if(valid[LATENCY]) begin
         linebuf[{bank,count}]<=vram_data;
         if(count==319) begin done<=1;completed_bank<=bank;state<=0;end
         else count<=count+1'b1;
       end
     end
     default:state<=0;
   endcase
 end
 // All RAM read addressing and timing remain in the pixel domain.
 always @(posedge vclk) begin
   // Publish only a complete row. The next bank can be written while the
   // pixel domain continues to read the last complete bank.
   bank_sync<={bank_sync[0],completed_bank};prev_blank<=hblank;
   if(vreset) begin x<=0;active_bank<=0;pixel_q<=0;out_hs<=0;out_vs<=0;out_de<=0;out_hb<=1;out_vb<=1;underrun<=0;bank_sync<=0;prev_blank<=1;consumed_bank<=0;have_line<=0;end
   else begin
     if(hblank) begin x<=0;active_bank<=bank_sync[1];end
     else x<=x+1'b1;
     if(prev_blank && !hblank && !vblank && !blank) begin
       if(have_line && active_bank==consumed_bank) underrun<=1;
       consumed_bank<=active_bank;have_line<=1;
     end
     if(vblank) have_line<=0;
     pixel_q<=linebuf[{active_bank,x}];
     out_hs<=hs;out_vs<=vs;
     out_de<=!blank && !hblank && !vblank && x<9'd320;
     // MiSTer's arcade_video samples VBlank on the falling HBlank edge.
     // Keep that edge on EVERY line, including vertical blank: folding
     // vblank into HBlank prevents VBlank from ever being latched high and
     // makes the scandoubler measure a frame-long horizontal porch.
     // ENV-off blanking belongs in VBlank; HBlank still describes a line.
     out_hb<=hblank || x>=9'd320;
     out_vb<=vblank || (blank && !hblank);
   end
 end
endmodule
`default_nettype wire
