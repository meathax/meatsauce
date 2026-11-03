// SPDX-License-Identifier: GPL-3.0-or-later
// MAME YMFM timer A: (1024-value)*12*prescale chip clocks from load.
// ymfm_fm.ipp update_timer gives A no free-running scan-phase adjustment.
// State stays in clk_sys; chip_ce is an enable, never a derived clock.
module a74_ym2203_timer_a(
 input wire clk,rst,chip_ce,load,enable_status,clr_flag,
 input wire [9:0] start_value,
 input wire [6:0] period,
 output reg flag,
 output wire overflow,trigger
);
 // jt12_mmr holds clr_flag until its next prescaled clk_en. YMFM clears the
 // status once at the register write, so act only on the request's first cycle.
 reg load_q,clr_q;
 wire clr_pulse=clr_flag && !clr_q;
 reg [16:0] remaining;
 wire [16:0] duration=(17'd1024-{7'd0,start_value})*{10'd0,period};
 assign overflow=load && load_q && chip_ce && remaining==17'd1;
 assign trigger=(load && !load_q) || overflow;
 always @(posedge clk or posedge rst) begin
  if(rst) begin load_q<=0;clr_q<=0;remaining<=0;flag<=0;end
  else begin
   load_q<=load;clr_q<=clr_flag;
   if(!load)remaining<=0;
   else if(!load_q)remaining<=duration;
   else if(chip_ce) begin
    if(remaining==17'd1)remaining<=duration;
    else if(remaining!=0)remaining<=remaining-17'd1;
   end
   if(clr_pulse)flag<=0;
   else if(overflow && enable_status)flag<=1;
  end
 end
endmodule
