// SPDX-License-Identifier: GPL-3.0-or-later
// Rotary code generator for the SNK LS-30 games: keyboard/bumper steps (immediate press step, then runtime-rate held
// repeat), spinner (mouse) code, twin-stick servo (snk_aim_ctl) and the Guerrilla War LS-30 protection.
// MAME POSITIONAL sensitivity15*keydelta1*60Hz motivates the repeat cadence, not PCB timing.
// The game tracks the code as a step counter (see snk_aim_ctl.sv), so every contribution is an additive offset mod 12.
module snk_rotary_keys #(parameter integer CLK_HZ=48000000,REPEAT_HZ=9)(
 input clk_sys,reset_game,pause_game,input [7:0] profile,input [31:0] joy0,joy1,
 input [10:0] ps2_key,input [3:0] spinner_rotary_0,spinner_rotary_1,
 input [15:0] ana_l0,ana_r0,ana_l1,ana_r1,input [11:0] aim_cfg,   // hps_io analog sticks, OSD "Controls" bits
 input [15:0] cpu_a_addr,input [7:0] cpu_a_data,input [4:0] cpu_a_ctl, // CPU-A bus snoop (aim variable writes)
 output reg [3:0] rotary_0=0,rotary_1=0,output [3:0] digital_0,digital_1,
 output [31:0] joy0_f,joy1_f                                         // joystick words with the stick/layout filter applied
);
 localparam integer PHASE_BITS=$clog2(CLK_HZ+32+1);
 reg [PHASE_BITS-1:0] phase0=0,phase1=0;
 reg [3:0] offset0=0,offset1=0,key_held=0;
 reg key_toggle=0;reg [7:0] previous_profile=255;
 reg [1:0] previous0=0,previous1=0;
 wire enabled=profile==8'd11||profile==8'd12||profile==8'd7||profile==8'd14||profile==8'd18||profile==8'd19;
 wire [4:0] rep_hz_w;
 wire [4:0] rep_hz=rep_hz_w;wire [1:0] aim_mode;wire ms_tick;wire [3:0] aoff0,aoff1;
 wire man_en=aim_mode!=2'd1;                       // Twin-stick mode: right stick only (keys/bumpers frozen)
 function [3:0] keyf(input [3:0] held,input [10:0] k,input t);
  reg [3:0] n;
  begin
   n=held;
   if(k[10]!=t)case(k[8:0])
    9'h01a:n[0]=k[9]; // Z, decrement before PORT_REVERSE
    9'h022:n[1]=k[9]; // X, increment before PORT_REVERSE
    9'h031:n[2]=k[9]; // N, player2 decrement
    9'h03a:n[3]=k[9]; // M, player2 increment
    default:begin end
   endcase
   keyf=n;
  end
 endfunction
 wire [3:0] key_next=keyf(key_held,ps2_key,key_toggle);
 // bumper bits: bermudat/tnk3/ikari/victroad 10,11; worldwar/gwar 11,12 (MRA button order, Test sits at bit 10)
 wire sel10=profile==8'd11||profile==8'd7||profile==8'd14||profile==8'd18, sel11=profile==8'd12||profile==8'd19;
 wire [1:0] gamepad_left=sel10 ? {joy1[10],joy0[10]} : sel11 ? {joy1[11],joy0[11]} : 2'b00;
 wire [1:0] gamepad_right=sel10 ? {joy1[11],joy0[11]} : sel11 ? {joy1[12],joy0[12]} : 2'b00;
 wire left0=key_next[0]|gamepad_left[0],right0=key_next[1]|gamepad_right[0];
 wire left1=key_next[2]|gamepad_left[1],right1=key_next[3]|gamepad_right[1];
 wire [1:0] direction0=!man_en||left0==right0 ? 2'd0 : (left0 ? 2'd1 : 2'd2);
 wire [1:0] direction1=!man_en||left1==right1 ? 2'd0 : (left1 ? 2'd1 : 2'd2);
 wire [PHASE_BITS:0] sum0={1'b0,phase0}+rep_hz,sum1={1'b0,phase1}+rep_hz;
 function automatic [3:0] step(input [3:0] position,input [1:0] direction);
  step=direction==1 ? (position==11 ? 4'd0:position+1'b1) : (position==0 ? 4'd11:position-1'b1);
 endfunction
 always @(posedge clk_sys)begin
  previous_profile<=profile;
  if(reset_game||!enabled||profile!=previous_profile)begin
   phase0<=0;phase1<=0;offset0<=0;offset1<=0;key_held<=0;
   key_toggle<=ps2_key[10];previous0<=0;previous1<=0;
  end else if(pause_game)begin
   // Main suppresses keyboard packets in OSD; retain aim but discard stale holds.
   phase0<=0;phase1<=0;key_held<=0;key_toggle<=ps2_key[10];previous0<=0;previous1<=0;
  end else begin
   key_toggle<=ps2_key[10];key_held<=key_next;
   previous0<=direction0;previous1<=direction1;
   if(direction0==0)phase0<=0;
   else if(direction0!=previous0)begin phase0<=0;offset0<=step(offset0,direction0);end
   else if(sum0>=CLK_HZ)begin phase0<=sum0-CLK_HZ;offset0<=step(offset0,direction0);end
   else phase0<=sum0;
   if(direction1==0)phase1<=0;
   else if(direction1!=previous1)begin phase1<=0;offset1<=step(offset1,direction1);end
   else if(sum1>=CLK_HZ)begin phase1<=sum1-CLK_HZ;offset1<=step(offset1,direction1);end
   else phase1<=sum1;
  end
 end
 // Track raw spinner movement even while blocked, discarding paused/stick-only deltas.
 reg [3:0] spin0=0,spin1=0,raw0=0,raw1=0;
 wire [4:0] delta0=spinner_rotary_0>=raw0 ? {1'b0,spinner_rotary_0}-{1'b0,raw0} : 5'd12+spinner_rotary_0-raw0;
 wire [4:0] delta1=spinner_rotary_1>=raw1 ? {1'b0,spinner_rotary_1}-{1'b0,raw1} : 5'd12+spinner_rotary_1-raw1;
 wire [4:0] spin_sum0=spin0+delta0,spin_sum1=spin1+delta1;
 always @(posedge clk_sys)begin
  raw0<=spinner_rotary_0;raw1<=spinner_rotary_1;
  if(reset_game||!enabled||profile!=previous_profile)begin spin0<=0;spin1<=0;end
  else if(!pause_game&&man_en)begin
   spin0<=spin_sum0>=12?spin_sum0-5'd12:spin_sum0[3:0];
   spin1<=spin_sum1>=12?spin_sum1-5'd12:spin_sum1[3:0];
  end
 end
 // manual (keyboard/bumper/mouse) code changes cancel a held twin-stick target
 reg [3:0] off0_q=0,off1_q=0,sp0_q=0,sp1_q=0;reg man0=0,man1=0;
 always @(posedge clk_sys)begin
  off0_q<=offset0;off1_q<=offset1;sp0_q<=spin0;sp1_q<=spin1;
  man0<=off0_q!=offset0||sp0_q!=spin0;man1<=off1_q!=offset1||sp1_q!=spin1;
 end
 snk_aim_ctl #(.CLK_HZ(CLK_HZ)) aim(.clk(clk_sys),.reset(reset_game||profile!=previous_profile),.pause(pause_game),.profile(profile),
  .joy0(joy0),.joy1(joy1),.l0(ana_l0),.r0(ana_r0),.l1(ana_l1),.r1(ana_r1),.cfg(aim_cfg),
  .a_addr(cpu_a_addr),.a_data(cpu_a_data),.a_ctl(cpu_a_ctl),.manual0(man0),.manual1(man1),
  .ms_tick(ms_tick),.aoff0(aoff0),.aoff1(aoff1),.mode(aim_mode),.rep_hz(rep_hz_w),.joy0_f(joy0_f),.joy1_f(joy1_f),.enabled());
 // code = spinner + keys + servo (mod 12)
 wire [4:0] s0=spin0+offset0,s1=spin1+offset1;
 wire [3:0] m0=s0>=12 ? s0-5'd12:s0[3:0],m1=s1>=12 ? s1-5'd12:s1[3:0];
 wire [4:0] t0=m0+aoff0,t1=m1+aoff1;
 wire [3:0] code0=t0>=12 ? t0-5'd12:t0[3:0],code1=t1>=12 ? t1-5'd12:t1[3:0];
 assign digital_0=offset0;assign digital_1=offset1;
 // Guerrilla War LS-30 protection (MAME gwar_state::gwar_rotary): the first and then every 8th direct 5<->6 transition
 // reads as 0xf (no switch closed).  The game flags "JOYSTICK" and hangs after 8 clean 5<->6 changes.  0xf is held
 // PROT_MS so at least one frame sees it; the game ignores 0xf (table delta 0) and then accepts 6/5 against prev.
 localparam integer PROT_MS=40;
 wire prot=profile==8'd19;
 reg [2:0] cp0=0,cp1=0;reg [6:0] hold0=0,hold1=0;
 wire cross0=(rotary_0==4'd5&&code0==4'd6)||(rotary_0==4'd6&&code0==4'd5);
 wire cross1=(rotary_1==4'd5&&code1==4'd6)||(rotary_1==4'd6&&code1==4'd5);
 always @(posedge clk_sys)begin
  if(reset_game||!prot)begin
   cp0<=0;cp1<=0;hold0<=0;hold1<=0;rotary_0<=code0;rotary_1<=code1;
  end else if(!pause_game)begin
   if(hold0!=0)begin
    if(ms_tick)hold0<=hold0-1'b1;
    if(hold0==7'd1&&ms_tick)rotary_0<=code0;
   end else if(code0!=rotary_0)begin
    if(cross0)begin cp0<=cp0+1'b1;if(cp0==3'd0)begin rotary_0<=4'hf;hold0<=PROT_MS;end else rotary_0<=code0;end
    else rotary_0<=code0;
   end
   if(hold1!=0)begin
    if(ms_tick)hold1<=hold1-1'b1;
    if(hold1==7'd1&&ms_tick)rotary_1<=code1;
   end else if(code1!=rotary_1)begin
    if(cross1)begin cp1<=cp1+1'b1;if(cp1==3'd0)begin rotary_1<=4'hf;hold1<=PROT_MS;end else rotary_1<=code1;end
    else rotary_1<=code1;
   end
  end
 end
endmodule
