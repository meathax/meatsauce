// SPDX-License-Identifier: GPL-3.0-or-later
// Caliber .50: native 16-state portrait compass, counted quadrature feedback.
module caliber_aim_controls #(parameter integer CLOCK_HZ=48000000)(
 input wire clk,reset,paused,dial_reset,unrotated,
 input wire [15:0] right1,right2,
 input wire [1:0] legacy1,legacy2,speed,deadzone,
 input wire autofire,
 input wire [1:0] angle_write,
 input wire [3:0] angle_data,
 input wire [1:0] decoder_step,decoder_dir,
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
 wire [3:0] defl,update;
 wire [15:0] direction;
 aim_quant16 quant(.clk(clk),.reset(reset),.ana({right2,16'd0,right1,16'd0}),
  .thr({threshold,6'd25,threshold,6'd25}),.defl(defl),.dir(direction),.upd(update));
 reg [1:0] owns=0,prime=0;
 integer p;
 always @(posedge clk) begin
  if(reset) begin owns<=0;prime<=0;end
  else if(!paused) for(p=0;p<2;p=p+1) begin
   if(!owns[p] && !prime[p] && defl[2*p+1]) prime[p]<=1;
   else if(prime[p]) begin prime[p]<=0;owns[p]<=1;end
  end
 end
 assign owned=owns;
 wire [1:0] raw1={legacy1[0],legacy1[1]},raw2={legacy2[0],legacy2[1]};
 wire [1:0] q1,q2;
 wire [3:0] target1=unrotated ? direction[7:4]-4'd4 : direction[7:4];
 wire [3:0] target2=unrotated ? direction[15:12]-4'd4 : direction[15:12];
 caliber_aim_servo servo1(.clk(clk),.reset(reset),.dial_reset(dial_reset),.paused(paused),
  .enable(owns[0]),.tick_ms(tick_ms),.advance(1'b1),.stick_active(defl[1]),.target_update(update[1]),
  .load(prime[0]),.load_dial(raw1),.target_angle(target1),.speed(speed),
  .angle_write(angle_write[0]),.angle_data(angle_data),.decoder_step(decoder_step[0]),.decoder_dir(decoder_dir[0]),
  .dial(q1),.pending(),.observed(),.target());
 caliber_aim_servo servo2(.clk(clk),.reset(reset),.dial_reset(dial_reset),.paused(paused),
  .enable(owns[1]),.tick_ms(tick_ms),.advance(1'b1),.stick_active(defl[3]),.target_update(update[3]),
  .load(prime[1]),.load_dial(raw2),.target_angle(target2),.speed(speed),
  .angle_write(angle_write[1]),.angle_data(angle_data),.decoder_step(decoder_step[1]),.decoder_dir(decoder_dir[1]),
  .dial(q2),.pending(),.observed(),.target());
 // jtcal50_main swaps each pair on its way into jt4701.
 assign dial1=owns[0] ? {q1[0],q1[1]} : legacy1;
 assign dial2=owns[1] ? {q2[0],q2[1]} : legacy2;
 aim_autofire #(.PERIOD_MS(100),.ON_MS(25)) af1(.clk(clk),.reset(reset),.paused(paused),
  .tick_ms(tick_ms),.enable(autofire),.stick_active(defl[1]),.fire(fire[0]));
 aim_autofire #(.PERIOD_MS(100),.ON_MS(25)) af2(.clk(clk),.reset(reset),.paused(paused),
  .tick_ms(tick_ms),.enable(autofire),.stick_active(defl[3]),.fire(fire[1]));
endmodule
