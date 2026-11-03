// MAME 0.289 watchdog.cpp defaults: unconfigured watchdog arms on first
// service, then expires after three seconds. This is the MAME board model;
// the physical PCB watchdog divider has not been measured.
module pwb_watchdog #(
 parameter integer CLOCK_HZ=48000000,
 parameter integer TIMEOUT_SECONDS=3,
 parameter integer TIMEOUT_CYCLES=CLOCK_HZ*TIMEOUT_SECONDS
)(
 input wire clk,reset,pause,service,
 output reg expired,output reg armed
);
 localparam integer COUNT_WIDTH=TIMEOUT_CYCLES>1?$clog2(TIMEOUT_CYCLES):1;
 localparam [COUNT_WIDTH-1:0] RELOAD=TIMEOUT_CYCLES-1;
 reg [COUNT_WIDTH-1:0] remaining;
 always @(posedge clk) begin
  expired<=0;
  if(reset) begin
   armed<=0;remaining<=0;
  end else if(service) begin
   // A service at the expiry boundary must win, including during pause.
   armed<=1;remaining<=RELOAD;
  end else if(!pause && armed) begin
   if(remaining==0) begin expired<=1;armed<=0;end
   else remaining<=remaining-1'b1;
  end
 end
endmodule
