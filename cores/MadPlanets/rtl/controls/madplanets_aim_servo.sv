// SPDX-License-Identifier: GPL-3.0-or-later
// One acknowledged relative dial step at a time, using the native game bias.
module madplanets_aim_servo(
 input wire clk,reset,paused,enable,tick_ms,
 input wire stick_active,target_update,
 input wire [3:0] target_angle,
 input wire [1:0] speed,
 input wire angle_write,bias_write,
 input wire [7:0] angle_data,bias_data,
 input wire dial_read,
 output reg [7:0] dial_delta=0,
 output reg pending=0,
 output reg [3:0] observed=0,target=0
);
 reg angle_valid=0,bias_valid=0,bias_negative=0,aiming=0,seen_read=0;
 reg [3:0] expected=0;
 reg [7:0] age_ms=0,delay_ms=0;
 wire [7:0] step_delay=speed==0 ? 8'd12:speed==1 ? 8'd40:8'd0;
 wire [3:0] clockwise_distance=target-observed;
 wire clockwise=clockwise_distance<=8;
 wire [3:0] distance=clockwise ? clockwise_distance : -clockwise_distance;
 // The native routine supports at most three increments per dial read.
 wire [3:0] step_count=(speed==2 && distance>1) ? (distance>3 ? 4'd3:distance):4'd1;
 wire [7:0] positive_delta={4'd0,step_count}+(bias_negative ? 8'd0:8'd1);
 wire [7:0] negative_delta=8'd0-({4'd0,step_count}+(bias_negative ? 8'd1:8'd0));
 always @(posedge clk)begin
  if(reset)begin
   dial_delta<=0;pending<=0;observed<=0;target<=0;expected<=0;
   angle_valid<=0;bias_valid<=0;bias_negative<=0;aiming<=0;seen_read<=0;age_ms<=0;delay_ms<=0;
  end else begin
   if(angle_write && angle_data<16)begin observed<=angle_data[3:0];angle_valid<=1;end
   if(bias_write && (bias_data==0 || bias_data==8'hff))begin bias_negative<=bias_data[7];bias_valid<=1;end
   if(pending && dial_read)seen_read<=1;
   if(pending && seen_read && !dial_read)dial_delta<=0;
   // Bias is written after the masked angle. Wait for both before issuing
   // another step, including when a pause drains the CPU's current write.
   if(pending && seen_read && bias_write && (bias_data==0 || bias_data==8'hff) && observed==expected)begin
    pending<=0;seen_read<=0;dial_delta<=0;age_ms<=0;delay_ms<=step_delay;
   end else if(!paused)begin
    if(tick_ms && delay_ms!=0)delay_ms<=delay_ms-1'b1;
    if(!enable)begin aiming<=0;pending<=0;dial_delta<=0;seen_read<=0;age_ms<=0;end
    else begin
     if(target_update && stick_active)begin target<=target_angle;aiming<=1;end
     if(pending && tick_ms)begin
      if(age_ms==119)begin pending<=0;dial_delta<=0;seen_read<=0;age_ms<=0;delay_ms<=250;end
      else age_ms<=age_ms+1'b1;
     end else if(!pending && aiming && angle_valid && bias_valid && delay_ms==0 && target!=observed)begin
      expected<=clockwise ? observed+step_count:observed-step_count;
      dial_delta<=clockwise ? positive_delta:negative_delta;
      pending<=1;seen_read<=0;age_ms<=0;
     end
    end
   end
  end
 end
endmodule
