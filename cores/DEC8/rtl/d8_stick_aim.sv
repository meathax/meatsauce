// SPDX-License-Identifier: GPL-3.0-or-later
// Caliber .50 stick/deadzone conventions adapted to Gondomania's relative 12-contact dial.
module d8_stick_aim #(parameter integer CLK_HZ=48000000)(
 input wire clk, reset, paused, enable,
 input wire [15:0] right1, right2,
 input wire [3:0] legacy1, legacy2,
 input wire [1:0] speed, deadzone,
 input wire autofire,
 input wire [1:0] actual_strobe,
 input wire [7:0] actual_angle,
 output wire [3:0] pos1, pos2,
 output wire [1:0] fire
);
 localparam integer MS_DIV=CLK_HZ/1000;
 localparam integer MS_W=MS_DIV<2 ? 1 : $clog2(MS_DIV);
 reg [MS_W-1:0] ms_count=0;
 wire tick_ms=ms_count==MS_DIV-1;
 always @(posedge clk) begin
  if(reset || !enable || tick_ms) ms_count<=0;
  else if(!paused) ms_count<=ms_count+1'b1;
 end
 wire [5:0] threshold=deadzone==0 ? 6'd32 : deadzone==1 ? 6'd13 : deadzone==2 ? 6'd38 : 6'd51;
 wire [3:0] defl,update;
 wire [11:0] direction;
 snk_aim_quant4 quant(.clk(clk),.reset(reset || !enable),
  .ana({right2,16'd0,right1,16'd0}),
  .inv_y(4'd0),.thr({threshold,6'd25,threshold,6'd25}),.defl(defl),.dir(direction),.upd(update));
 reg [3:0] legacy_q1=0,legacy_q2=0;
 always @(posedge clk) begin
  if(reset || !enable) begin legacy_q1<=legacy1;legacy_q2<=legacy2;end
  else if(!paused) begin legacy_q1<=legacy1;legacy_q2<=legacy2;end
 end
 wire [7:0] code1,code2;
 d8_aim_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(0)) p1(
  .clk(clk),.reset(reset || !enable),.paused(paused),.enable(enable),.tick_ms(tick_ms),
  .stick_active(defl[1]),.target_update(update[1]),.target_angle({5'd0,direction[5:3]}),.speed(speed),
  .actual_strobe(actual_strobe[0]),.actual_angle(actual_angle),
  .manual_load(legacy1!=legacy_q1),.manual_code({4'd0,legacy1}),.manual_cw(1'b0),.manual_ccw(1'b0),
  .code(code1),.target(),.aiming(),.pending(),.observed());
 d8_aim_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(0)) p2(
  .clk(clk),.reset(reset || !enable),.paused(paused),.enable(enable),.tick_ms(tick_ms),
  .stick_active(defl[3]),.target_update(update[3]),.target_angle({5'd0,direction[11:9]}),.speed(speed),
  .actual_strobe(actual_strobe[1]),.actual_angle(actual_angle),
  .manual_load(legacy2!=legacy_q2),.manual_code({4'd0,legacy2}),.manual_cw(1'b0),.manual_ccw(1'b0),
  .code(code2),.target(),.aiming(),.pending(),.observed());
 assign pos1=enable ? code1[3:0] : legacy1;
 assign pos2=enable ? code2[3:0] : legacy2;
 // The game supplies its own normal shot cadence while Shoot is held.
 assign fire={defl[3],defl[1]} & {2{enable && autofire && !reset && !paused}};
endmodule
