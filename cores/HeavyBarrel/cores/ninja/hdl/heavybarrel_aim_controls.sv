// SPDX-License-Identifier: GPL-3.0-or-later
// Heavy Barrel twin-stick aiming. Each right stick picks one of the eight
// native gun angles; the shared one-legal-step servo then walks the 12-contact
// rotary ring until the game's own angle byte (FF8066/FF80AA) matches.
// Native contract (MAME 0.289 hbarrel): angle byte/4 = 0N 1NE 2E ... 7NW on the
// upright portrait picture; one contact step in the positive direction
// (rotary<<1) lowers the angle by one, so contact increase = counterclockwise.
module heavybarrel_aim_controls #(parameter integer CLOCK_HZ=48000000)(
 input wire clk,reset,paused,unrotated,
 input wire [15:0] right1,right2,
 input wire [1:0] speed,deadzone,
 input wire autofire,
 // Legacy jtcop dial steps: dir==0 moves one contact in the positive direction.
 input wire [1:0] legacy_step,legacy_dir,
 // Completed game writes of the angle byte (data is the raw byte).
 input wire [1:0] angle_write,
 input wire [7:0] angle_data,
 output wire [11:0] rotary1,rotary2,
 output wire [1:0] fire,
 output wire [1:0] active
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
 wire [3:0] defl,upd;
 wire [11:0] dir;
 snk_aim_quant4 quant(.clk(clk),.reset(reset),.ana({right2,16'd0,right1,16'd0}),
  .thr({threshold,6'd25,threshold,6'd25}),.inv_y(4'd0),.defl(defl),.dir(dir),.upd(upd));
 // Native angle bytes are multiples of four below 32. Anything else is not an aim write.
 wire byte_ok=angle_data[1:0]==2'b00 && angle_data[7:5]==3'b000;
 wire [2:0] observed_angle=angle_data[4:2];
 wire [2:0] target1=unrotated ? dir[5:3]-3'd2 : dir[5:3];
 wire [2:0] target2=unrotated ? dir[11:9]-3'd2 : dir[11:9];
 wire [7:0] code1,code2;
 // Positive code = counterclockwise = rotary<<1; the legacy dial has the same sense.
 rotary_target_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(0)) servo1(
  .clk(clk),.reset(reset),.paused(paused),.enable(1'b1),.tick_ms(tick_ms),
  .stick_active(defl[1]),.target_update(upd[1]),.target_angle({5'd0,target1}),.speed(speed),
  .actual_strobe(angle_write[0] && byte_ok),.actual_angle({5'd0,observed_angle}),
  .manual_cw(legacy_step[0] && legacy_dir[0]),.manual_ccw(legacy_step[0] && !legacy_dir[0]),
  .code(code1),.target(),.observed(),.aiming(),.pending());
 rotary_target_servo #(.ANGLE_STATES(8),.CODE_STATES(12),.CODE_POSITIVE_IS_CW(0)) servo2(
  .clk(clk),.reset(reset),.paused(paused),.enable(1'b1),.tick_ms(tick_ms),
  .stick_active(defl[3]),.target_update(upd[3]),.target_angle({5'd0,target2}),.speed(speed),
  .actual_strobe(angle_write[1] && byte_ok),.actual_angle({5'd0,observed_angle}),
  .manual_cw(legacy_step[1] && legacy_dir[1]),.manual_ccw(legacy_step[1] && !legacy_dir[1]),
  .code(code2),.target(),.observed(),.aiming(),.pending());
 assign rotary1=12'd1<<code1[3:0];
 assign rotary2=12'd1<<code2[3:0];
 aim_autofire #(.PERIOD_MS(100),.ON_MS(25)) af1(.clk(clk),.reset(reset),.paused(paused),
  .tick_ms(tick_ms),.enable(autofire),.stick_active(defl[1]),.fire(fire[0]));
 aim_autofire #(.PERIOD_MS(100),.ON_MS(25)) af2(.clk(clk),.reset(reset),.paused(paused),
  .tick_ms(tick_ms),.enable(autofire),.stick_active(defl[3]),.fire(fire[1]));
 assign active={defl[3],defl[1]};
endmodule

// Completed write of an angle byte. FF8066 (P1) and FF80AA (P2) are the high
// (even-address) bytes of sysram words 0x33 and 0x55; the rotary routine writes
// them with UDS only. Writes by other lanes or other addresses are ignored.
module heavybarrel_aim_snoop(
 input wire clk,reset,commit,sysram,uds_n,
 input wire [12:0] word,
 input wire [15:0] dout,
 output reg [1:0] angle_write=0,
 output reg [7:0] angle_data=0
);
 always @(posedge clk) begin
  angle_write<=0;
  if(reset) angle_data<=0;
  else if(commit && sysram && !uds_n) begin
   if(word==13'h0033) begin angle_data<=dout[15:8];angle_write[0]<=1; end
   if(word==13'h0055) begin angle_data<=dout[15:8];angle_write[1]<=1; end
  end
 end
endmodule
