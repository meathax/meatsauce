// SPDX-License-Identifier: GPL-3.0-or-later
// Forgotten Worlds twin-stick aiming.
//
// Native contract (MAME 0.289 forgottn, docs/FORGOTTEN_AIM_CONTRACT.md): the
// uPD4701 counters at 800052 (P1) / 80005A (P2) hold the movement since the
// game last wrote the reset at 800041 / 800049. Each game frame the IRQ reads
// and clears the counter, then routine 8B28 adds the sign-extended count to the
// player's aim accumulator at FFB36A (P1) / FFB3BA (P2) in the same frame. That
// accumulator sets the firing direction: shot sector (0=N, 8=E, 16=S, 24=W,
// clockwise) = (((acc+0x20)>>6)&31) + 8. The satellite accumulator at
// FFCF0A/5A is only a copy delayed by 9-23 frames, so it must never be the
// feedback variable. The controller is closed-loop on the player accumulator:
// it snoops the game's accumulator write, and after the game has cleared the
// counter it emits one quadrature burst whose count moves the accumulator toward
// the centre of the requested sector. A burst never overlaps the game's counter
// read because it is only produced after the clear that follows the read.
module forgotten_quad_burst #(parameter integer HOLD=4)(
 input wire clk, reset,
 input wire start, positive, load,
 input wire [7:0] count,
 input wire [1:0] load_dial,
 output wire [1:0] dial,
 output reg busy = 0
);
 reg [1:0] phase = 0;
 reg direction = 0;
 reg [9:0] steps = 0;
 reg [2:0] hold = 0;
 // Positive (increasing) sequence, A first: 00,10,11,01.
 assign dial = phase==0 ? 2'b00 : phase==1 ? 2'b10 : phase==2 ? 2'b11 : 2'b01;
 always @(posedge clk) begin
  if(reset) begin phase<=0;direction<=0;steps<=0;hold<=0;busy<=0;end
  else if(!busy) begin
   if(load) phase <= load_dial==2'b00 ? 2'd0 : load_dial==2'b10 ? 2'd1 : load_dial==2'b11 ? 2'd2 : 2'd3;
   else if(start && count!=0) begin
    direction<=positive; steps<={count,1'b0}; hold<=HOLD-1; busy<=1;
    phase <= positive ? phase+2'd1 : phase-2'd1;
   end
  end else if(hold!=0) hold<=hold-1'b1;
  else if(steps==1) begin steps<=0;busy<=0; end
  else begin
   steps<=steps-1'b1; hold<=HOLD-1;
   phase <= direction ? phase+2'd1 : phase-2'd1;
  end
 end
endmodule

// One player's closed-loop axis. acc_write marks a completed game write of
// the accumulator; counter_cleared marks the end of the game's counter reset.
module forgotten_aim_axis(
 input wire clk, reset,
 input wire enable, load,
 input wire [1:0] load_dial,
 input wire [1:0] speed,
 input wire [4:0] target,
 input wire target_update,
 input wire acc_write,
 input wire [15:0] acc_data,
 input wire counter_cleared,
 output wire [1:0] dial,
 output wire busy
);
 reg [10:0] acc = 0;
 reg valid=0, fresh=0, armed=0, aiming=0, start=0, positive=0;
 reg [4:0] tgt=0;
 reg [7:0] count=0;
 wire [4:0] aim=tgt-5'd8;   // stick sector -> accumulator sector
 wire [10:0] diff={aim,6'd0}-acc;
 wire negative=diff[10];
 wire [10:0] mag=negative ? 11'd0-diff : diff;
 wire in_sector=negative ? mag<=31 : diff<=32;
 wire [7:0] cap=speed==0 ? 8'd64 : speed==1 ? 8'd24 : 8'd255;   // counts per frame: Normal, Slow, Instant
 forgotten_quad_burst quad(.clk(clk),.reset(reset),.start(start),.positive(positive),.load(load),
  .count(count),.load_dial(load_dial),.dial(dial),.busy(busy));
 always @(posedge clk) begin
  start<=0;
  if(reset) begin
   acc<=0;valid<=0;fresh<=0;armed<=0;aiming<=0;tgt<=0;count<=0;positive<=0;
  end else begin
   if(acc_write) begin acc<=acc_data[10:0];valid<=1;fresh<=1;end
   if(counter_cleared) armed<=1;
   if(!enable) aiming<=0;
   else if(target_update) begin tgt<=target;aiming<=1;end
   if(armed && fresh && !busy && !start && !acc_write) begin
    armed<=0;fresh<=0;
    if(enable && aiming && valid && !in_sector) begin
     positive<=!negative;
     count<=mag>{3'd0,cap} ? cap : mag[7:0];
     start<=1;
    end
   end
  end
 end
endmodule

module forgotten_aim_controls #(parameter integer CLOCK_HZ=48000000)(
 input wire clk, reset, paused,
 input wire [15:0] left1,left2,right1,right2,
 input wire [1:0] legacy1,legacy2,speed,deadzone,
 input wire autofire,
 input wire [7:0] joy1,joy2,            // active-low upstream joystick/buttons
 input wire [1:0] acc_write,
 input wire [15:0] acc_data,
 input wire [1:0] counter_cleared,
 output wire [7:0] joy1_out,joy2_out,
 output wire [1:0] dial1,dial2,fire,owned
);
 localparam integer MS_DIV=CLOCK_HZ/1000;
 localparam integer MS_W=MS_DIV<2 ? 1 : $clog2(MS_DIV);
 reg [MS_W-1:0] ms_count=0;
 wire tick_ms=ms_count==MS_DIV-1;
 always @(posedge clk) begin
  if(reset || tick_ms) ms_count<=0;
  else ms_count<=ms_count+1'b1;
 end
 wire [5:0] threshold=deadzone==0 ? 6'd32 : deadzone==1 ? 6'd13 : deadzone==2 ? 6'd38 : 6'd51;
 wire [1:0] defl,update;
 wire [9:0] direction;
 aim_quant32 quant(.clk(clk),.reset(reset),.ana({right2,right1}),
  .thr({threshold,threshold}),.defl(defl),.dir(direction),.upd(update));
 // Ownership: the first deflection takes the dial; any manual dial motion
 // returns it until the stick is centred and deflected again.
 reg [1:0] owns=0,prime=0,block=0,legacy_seen=0;
 reg [1:0] last1=0,last2=0;
 wire [1:0] manual={legacy2!=last2,legacy1!=last1};
 integer p;
 always @(posedge clk) begin
  last1<=legacy1;last2<=legacy2;
  if(reset) begin owns<=0;prime<=0;block<=0;end
  else for(p=0;p<2;p=p+1) begin
   if(manual[p] && owns[p]) begin owns[p]<=0;block[p]<=1;prime[p]<=0;end
   else if(block[p] && !defl[p]) block[p]<=0;
   else if(!owns[p] && !prime[p] && !block[p] && defl[p]) prime[p]<=1;
   else if(prime[p]) begin prime[p]<=0;owns[p]<=1;end
  end
 end
 assign owned=owns;
 wire [1:0] q1,q2;
 wire [1:0] busy;
 forgotten_aim_axis axis1(.clk(clk),.reset(reset),.enable(owns[0]),.load(prime[0]),.load_dial(legacy1),
  .speed(speed),.target(direction[4:0]),.target_update(update[0] && defl[0]),
  .acc_write(acc_write[0]),.acc_data(acc_data),.counter_cleared(counter_cleared[0]),.dial(q1),.busy(busy[0]));
 forgotten_aim_axis axis2(.clk(clk),.reset(reset),.enable(owns[1]),.load(prime[1]),.load_dial(legacy2),
  .speed(speed),.target(direction[9:5]),.target_update(update[1] && defl[1]),
  .acc_write(acc_write[1]),.acc_data(acc_data),.counter_cleared(counter_cleared[1]),.dial(q2),.busy(busy[1]));
 assign dial1=owns[0] ? q1 : legacy1;
 assign dial2=owns[1] ? q2 : legacy2;
 aim_autofire #(.PERIOD_MS(100),.ON_MS(25)) af1(.clk(clk),.reset(reset),.paused(paused),
  .tick_ms(tick_ms),.enable(autofire),.stick_active(defl[0]),.fire(fire[0]));
 aim_autofire #(.PERIOD_MS(100),.ON_MS(25)) af2(.clk(clk),.reset(reset),.paused(paused),
  .tick_ms(tick_ms),.enable(autofire),.stick_active(defl[1]),.fire(fire[1]));
 wire [3:0] move1,move2;
 analog_move8 mv1(.clk(clk),.reset(reset),.ana(left1),.threshold(threshold),.move(move1));
 analog_move8 mv2(.clk(clk),.reset(reset),.ana(left2),.threshold(threshold),.move(move2));
 assign joy1_out={joy1[7:5],joy1[4] & ~fire[0],joy1[3:0] & ~move1};
 assign joy2_out={joy2[7:5],joy2[4] & ~fire[1],joy2[3:0] & ~move2};
endmodule
