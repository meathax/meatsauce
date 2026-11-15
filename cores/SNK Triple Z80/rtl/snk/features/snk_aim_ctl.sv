// SPDX-License-Identifier: GPL-3.0-or-later
// Twin-stick / pad aim controller for the games with the SNK LS-30 12-position rotary stick
// (TNK III, Bermuda Triangle, World Wars, Ikari Warriors, Victory Road, Guerrilla War).
//
// What the games really do with the rotary (MAME 0.289 ROM analysis + live MAME tests, sim/aim_stick):
//  * The 4-bit code on IN1/IN2[7:4] is a STEP COUNTER, not an absolute angle.  Every frame the game computes
//    delta=(code-prev) mod 16, looks it up in a 16x16 table (|delta|<=2, or <=3 in victroad/gwar/worldwar/bermudat),
//    adds -delta*k to its own aim variable A (8 directions, 45 degrees each) and only then stores prev=code.
//    A delta outside the table is IGNORED and prev is NOT updated, so a code that jumps away from prev is lost
//    until it comes back (e.g. during intros/death the integrator does not run at all).
//  * Respawn / new life: the game writes A=0 (up) and prev=current code.
// A twin-stick therefore cannot be an open-loop code: this module snoops CPU-A writes of the aim variable
// (exact game state), computes the 45-degree sector the stick points at, and walks the code one legal step at a
// time (at most 2 outstanding steps, ack-paced, time-out -> revert to the last acknowledged code), so the game's own
// aim variable converges on the requested compass direction and never loses sync.
// Everything is synchronous on clk (96 MHz clk_sys), millisecond timers from one tick generator.

// ---------------------------------------------------------------------------------------------------------
// Serial 4-channel stick quantiser: analog X/Y -> deflected flag (hysteresis) + 8-way compass direction.
// dir: 0=N 1=NE 2=E 3=SE 4=S 5=SW 6=W 7=NW (clockwise, same as the games' aim index).
// Channel order: 0=P1 left, 1=P1 right, 2=P2 left, 3=P2 right.  No multipliers (shift/add only).
// ---------------------------------------------------------------------------------------------------------
module snk_aim_quant4(
 input  wire        clk,
 input  wire        reset,
 input  wire [63:0] ana,        // {P2R,P2L,P1R,P1L}, each {Y[7:0],X[7:0]} signed, Y positive = down (MiSTer)
 input  wire [23:0] thr,        // 4 x 6-bit deflection threshold (axis counts, 127 = full)
 input  wire [3:0]  inv_y,      // 1 = Y positive means up
 output reg  [3:0]  defl,       // deflected, with hysteresis (leaves at 75% of the enter radius)
 output reg  [11:0] dir,        // 3 bits per channel, last direction seen while radius >= threshold
 output reg  [3:0]  upd         // one-clock pulse when dir was refreshed from a deflected sample
);
 reg [1:0] ch=0;
 always @(posedge clk) ch<=ch+1'b1;

 // stage A: channel select
 reg [7:0] xa,ya; reg [5:0] tha; reg inva; reg [1:0] taga;
 always @(posedge clk)begin
  case(ch)
   2'd0:begin xa<=ana[7:0];   ya<=ana[15:8];  tha<=thr[5:0];   inva<=inv_y[0];end
   2'd1:begin xa<=ana[23:16]; ya<=ana[31:24]; tha<=thr[11:6];  inva<=inv_y[1];end
   2'd2:begin xa<=ana[39:32]; ya<=ana[47:40]; tha<=thr[17:12]; inva<=inv_y[2];end
   default:begin xa<=ana[55:48]; ya<=ana[63:56]; tha<=thr[23:18]; inva<=inv_y[3];end
  endcase
  taga<=ch;
 end
 // stage B: magnitude and signs (right/up positive)
 reg [7:0] axb,ayb; reg sxb,syb; reg [5:0] thb; reg [1:0] tagb;
 wire [7:0] xneg=8'd0-xa, yneg=8'd0-ya;
 always @(posedge clk)begin
  axb<=xa[7] ? (xa==8'h80 ? 8'd127 : xneg) : xa;
  ayb<=ya[7] ? (ya==8'h80 ? 8'd127 : yneg) : ya;
  sxb<=!xa[7] && xa!=8'd0;
  syb<=inva ? (!ya[7] && ya!=8'd0) : ya[7];
  thb<=tha; tagb<=taga;
 end
 // stage C: major/minor and octagon radius r = major + minor/2
 reg [7:0] majc,minc; reg xmajc,sxc,syc; reg [8:0] rc; reg [5:0] thc; reg [1:0] tagc;
 always @(posedge clk)begin
  if(axb>=ayb)begin majc<=axb;minc<=ayb;xmajc<=1'b1;end else begin majc<=ayb;minc<=axb;xmajc<=1'b0;end
  rc<=((axb>=ayb)?{1'b0,axb}:{1'b0,ayb})+(((axb>=ayb)?ayb:axb)>>1);
  sxc<=sxb;syc<=syb;thc<=thb;tagc<=tagb;
 end
 // stage D: minor/major ratio against tan(20 deg)=93/256 and tan(25 deg)=119/256 (5 degree sector hysteresis)
 wire [15:0] m=({8'd0,majc});
 wire [15:0] p93 =(m<<6)+(m<<4)+(m<<3)+(m<<2)+m;                   // 93*major
 wire [15:0] p119=(m<<6)+(m<<5)+(m<<4)+(m<<2)+(m<<1)+m;            // 119*major
 wire [15:0] mn=({minc,8'd0});
 reg condlo,condhi,xmajd,sxd,syd; reg [8:0] rd; reg [5:0] thd; reg [1:0] tagd;
 always @(posedge clk)begin
  condlo<=mn<=p93; condhi<=mn<=p119;
  xmajd<=xmajc;sxd<=sxc;syd<=syc;rd<=rc;thd<=thc;tagd<=tagc;
 end
 // stage E: state update
 reg [3:0] axis_q=4'b1111;       // last classification was an axis-aligned (N/E/S/W) sector
 wire [8:0] thr9={3'd0,thd};
 wire [8:0] thx9=thr9-{3'd0,2'b00,thd[5:2]}; // 75% exit radius
 wire enter_ok=rd>=thr9, keep_ok=rd>=thx9;
 wire cur_axis=axis_q[tagd];
 wire axis_next=cur_axis ? condhi : condlo;
 reg [2:0] dnew;
 always @*begin
  if(axis_next)begin
   if(xmajd) dnew=sxd ? 3'd2 : 3'd6; else dnew=syd ? 3'd0 : 3'd4;
  end else begin
   dnew=sxd ? (syd ? 3'd1 : 3'd3) : (syd ? 3'd7 : 3'd5);
  end
 end
 reg curdef;
 always @*begin
  case(tagd) 2'd0:curdef=defl[0]; 2'd1:curdef=defl[1]; 2'd2:curdef=defl[2]; default:curdef=defl[3]; endcase
 end
 integer i;
 always @(posedge clk)begin
  upd<=4'b0000;
  if(reset)begin
   defl<=4'b0000; dir<=12'd0; axis_q<=4'b1111;
  end else begin
   for(i=0;i<4;i=i+1)if(tagd==i)begin
    defl[i]<=curdef ? keep_ok : enter_ok;
    if(enter_ok)begin
     axis_q[i]<=axis_next;
     dir[i*3+:3]<=dnew;
     upd[i]<=1'b1;
    end
   end
  end
 end
endmodule

// ---------------------------------------------------------------------------------------------------------
// CPU-A write snooper: captures completed memory writes to the per-profile aim variable addresses.
// ---------------------------------------------------------------------------------------------------------
module snk_aim_snoop(
 input  wire        clk,
 input  wire        reset,
 input  wire [7:0]  profile,
 input  wire [15:0] a_addr,
 input  wire [7:0]  a_data,
 input  wire [4:0]  a_ctl,       // {m1_n,mreq_n,iorq_n,rd_n,wr_n}
 output reg         ev0,ev1,     // aim variable of player 1 / 2 written
 output reg  [2:0]  a8           // aim direction 0..7 (clockwise from up) carried by that write
);
 // CPU-A work-RAM addresses of (iy|ix)+0x10 / +8 / +0x17 per game (MAME-verified, see docs/controls.md)
 // {p1,p2} per profile; enc1: value is bits[2:0] (bermudat) instead of bits[3:1]
 function [31:0] addrs(input [7:0] pr);
  case(pr)
   8'd7:  addrs={16'hfd47,16'hfd8d}; // TNK III
   8'd11: addrs={16'hf408,16'hf4a8}; // Bermuda Triangle
   8'd12: addrs={16'hf408,16'hf448}; // World Wars
   8'd14: addrs={16'hfdb6,16'hfe06}; // Ikari Warriors
   8'd18: addrs={16'hfdb6,16'hfe06}; // Victory Road
   8'd19: addrs={16'he3d3,16'he437}; // Guerrilla War
   default:addrs=32'd0;
  endcase
 endfunction
 wire [31:0] ad=addrs(profile);
 wire [15:0] p1=ad[31:16],p2=ad[15:0];
 wire enc1=profile==8'd11;
 wire act=!a_ctl[3]&&!a_ctl[0];       // mreq_n and wr_n low
 reg act_q=0; reg [15:0] addr_q=0; reg [7:0] data_q=0;
 wire supported=profile==8'd7||profile==8'd11||profile==8'd12||profile==8'd14||profile==8'd18||profile==8'd19;
 always @(posedge clk)begin
  act_q<=act;
  if(act)begin addr_q<=a_addr; data_q<=a_data; end
  ev0<=1'b0; ev1<=1'b0;
  if(reset||!supported)begin act_q<=1'b0; end
  else if(act_q&&!act)begin
   if(addr_q==p1)begin ev0<=1'b1; a8<=enc1 ? data_q[2:0] : data_q[3:1]; end
   if(addr_q==p2)begin ev1<=1'b1; a8<=enc1 ? data_q[2:0] : data_q[3:1]; end
  end
 end
endmodule

// ---------------------------------------------------------------------------------------------------------
// Per-player servo: walks the rotary code offset until the observed game aim equals the target.
// ---------------------------------------------------------------------------------------------------------
module snk_aim_servo #(parameter integer TMO_MS=120,RETRY_MS=250)(
 input  wire       clk,
 input  wire       reset,
 input  wire       run,          // 0 while the game is paused (timers and steps freeze)
 input  wire       enabled,
 input  wire       ms_tick,
 input  wire       single,       // victroad: its table has wrap quirks for multi-step deltas -> one step in flight
 input  wire [1:0] speed,        // 0 Normal: ack-paced, 1 step per game frame; 1 Instant: up to `burst` steps in flight; 2/3 Slow: 40 ms between steps
 input  wire [1:0] burst,        // Instant: steps the game's delta table accepts per frame (3 victroad-family, 2 tnk3/ikari)
 input  wire       tgt_active,
 input  wire [2:0] tgt,
 input  wire       ev,           // aim variable written by the game
 input  wire [2:0] a8,           // its direction value
 output reg  [3:0] aoff,         // servo contribution to the rotary code (0..11)
 output reg  [2:0] a_obs,        // last observed game aim
 output wire       busy
);
 reg [3:0] c_ack=0; reg [1:0] outn=0; reg out_dir=0; reg [7:0] tmo=0,gap=8'hff; reg [8:0] hold=0;
 assign busy=outn!=2'd0;
 wire [2:0] diff=tgt-a_obs;                         // clockwise steps needed (A increases)
 wire want_dir=!(diff>=3'd1&&diff<=3'd4);           // 0: A increases (code-1), 1: A decreases (code+1)
 wire [2:0] needed=want_dir ? (3'd0-diff) : diff;   // remaining steps in that direction
 wire [2:0] magup=a8-a_obs, magdn=a_obs-a8;
 wire [2:0] mag=out_dir ? magdn : magup;
 wire [7:0] interval=(speed==2'd0||speed==2'd1) ? 8'd0 : 8'd40;
 wire [1:0] maxout=(speed==2'd1&&!single) ? burst : 2'd1;
 wire gap_ok=gap>=interval;
 function [3:0] inc12(input [3:0] v); inc12=(v==4'd11) ? 4'd0 : v+1'b1; endfunction
 function [3:0] dec12(input [3:0] v); dec12=(v==4'd0) ? 4'd11 : v-1'b1; endfunction
 // The games' delta tables have no entry for the -3 step from code 2 to code 11 (found by the Instant fuzz, Bermuda Triangle:
 // the game ignores it and loses sync). A burst that would end with that third decrement is held back until the game acks.
 wire hole=(c_ack==4'd2)&&(outn==2'd2)&&!want_dir&&(aoff==4'd0);
 wire can_issue=run&&enabled&&tgt_active&&diff!=3'd0&&hold==9'd0&&gap_ok&&!hole&&
                (outn==2'd0 || (out_dir==want_dir && outn<maxout && {1'b0,outn}<{1'b0,needed}));
 always @(posedge clk)begin
  if(reset||!enabled)begin
   aoff<=0;c_ack<=0;outn<=0;out_dir<=0;tmo<=0;gap<=8'hff;hold<=0;a_obs<=3'd0;
  end else if(run)begin
   if(ms_tick)begin
    if(gap!=8'hff)gap<=gap+1'b1;
    if(hold!=0)hold<=hold-1'b1;
    if(outn!=0)tmo<=tmo+1'b1;
   end
   if(ev)begin
    a_obs<=a8;
    if(outn==0)c_ack<=aoff;                          // game consumed everything: code == its prev
    else if(mag!=3'd0&&mag<=outn)begin               // ack (or two) of our steps
     outn<=outn-mag[1:0]; tmo<=0;
     c_ack<=(outn==mag[1:0]) ? aoff : (out_dir ? dec12(aoff) : inc12(aoff));
    end else if(mag!=3'd0)begin                      // unexpected change (respawn): resync
     outn<=0; tmo<=0; c_ack<=aoff;
    end
   end else if(outn!=0&&tmo>=TMO_MS)begin
    // game did not consume our steps (integrator off / ignored): undo and back off
    aoff<=c_ack; outn<=0; tmo<=0; hold<=RETRY_MS;
   end else if(can_issue)begin
    aoff<=want_dir ? inc12(aoff) : dec12(aoff);
    out_dir<=want_dir;
    if(outn==0)tmo<=0;
    outn<=outn+1'b1; gap<=0;
   end
  end
 end
endmodule

// ---------------------------------------------------------------------------------------------------------
// Controller: quantisers, snooper, servos, mode/priority logic, pad (movement) filter.
// cfg ({status[43],status[40:30]}): [1:0] mode 0 Auto 1 Twin-stick 2 Bumpers 3 Digital(aim = D-pad)
//   [3:2] right-stick deadzone 25/10/20/30 %  [5:4] servo speed 0 Normal 1 Instant 2 Slow  [7:6] bumper repeat 9/5/14/20 Hz
//   [8] left stick moves: 0 yes 1 no (D-pad only)   [10:9] layout: bit0 swap sticks, bit1 invert aim Y
//   [11] stick autofire: hold the game's normal Fire button (joystick bit 4) while the aim stick is outside the deadzone
// ---------------------------------------------------------------------------------------------------------
module snk_aim_ctl #(parameter integer CLK_HZ=96000000)(
 input  wire        clk,
 input  wire        reset,
 input  wire        pause,
 input  wire [7:0]  profile,
 input  wire [31:0] joy0,joy1,
 input  wire [15:0] l0,r0,l1,r1,           // hps_io joystick_l/r_analog_0/1
 input  wire [11:0] cfg,
 input  wire [15:0] a_addr,
 input  wire [7:0]  a_data,
 input  wire [4:0]  a_ctl,
 input  wire        manual0,manual1,       // keyboard/bumper/mouse changed the code: cancel the servo target
 output wire        ms_tick,
 output wire [3:0]  aoff0,aoff1,
 output wire [1:0]  mode,
 output wire [4:0]  rep_hz,
 output wire [31:0] joy0_f,joy1_f,
 output wire        enabled
);
 assign enabled=profile==8'd7||profile==8'd11||profile==8'd12||profile==8'd14||profile==8'd18||profile==8'd19;
 assign mode=cfg[1:0];
 wire [1:0] dzsel=cfg[3:2],speedsel=cfg[5:4],repsel=cfg[7:6];
 wire leftoff=cfg[8],swap=cfg[9],invy=cfg[10],stickfire=cfg[11];
 wire [1:0] speed=speedsel==2'd0 ? 2'd0 : speedsel==2'd1 ? 2'd1 : 2'd2;
 // Instant burst = most steps the game's delta table accepts per frame (|delta|<=3: bermudat/worldwar/gwar; <=2: tnk3/ikari; victroad single step)
 wire [1:0] burst=(profile==8'd11||profile==8'd12||profile==8'd19) ? 2'd3 : (profile==8'd7||profile==8'd14) ? 2'd2 : 2'd1;
 assign rep_hz=repsel==2'd0 ? 5'd9 : repsel==2'd1 ? 5'd5 : repsel==2'd2 ? 5'd14 : 5'd20;
 // 1 ms tick
 localparam integer MS_DIV=CLK_HZ/1000;
 reg [16:0] msc=0; reg ms=0;
 always @(posedge clk)begin ms<=0; if(msc>=MS_DIV-1)begin msc<=0;ms<=1;end else msc<=msc+1'b1; end
 assign ms_tick=ms;
 wire run=!pause;
 // quantiser channels: 0 P1L 1 P1R 2 P2L 3 P2R ; aim stick = swap ? L : R
 wire [5:0] dz=dzsel==2'd0 ? 6'd32 : dzsel==2'd1 ? 6'd13 : dzsel==2'd2 ? 6'd25 : 6'd38;   // 25/10/20/30 % of 127
 wire [5:0] other=6'd28;
 wire [3:0] defl; wire [11:0] dir; wire [3:0] upd;
 snk_aim_quant4 quant(.clk(clk),.reset(reset||!enabled),.ana({r1,l1,r0,l0}),
  .thr({ (swap?other:dz),(swap?dz:other),(swap?other:dz),(swap?dz:other)}),
  .inv_y({ (swap?1'b0:invy),(swap?invy:1'b0),(swap?1'b0:invy),(swap?invy:1'b0)}),
  .defl(defl),.dir(dir),.upd(upd));
 // note: thr/inv_y concatenations are {P2R,P2L,P1R,P1L}: aim channel is R when !swap, L when swap
 wire a0_upd=swap ? upd[0] : upd[1], a1_upd=swap ? upd[2] : upd[3];
 wire a0_defl=swap ? defl[0] : defl[1], a1_defl=swap ? defl[2] : defl[3];
 wire [2:0] a0_dir=swap ? dir[2:0] : dir[5:3], a1_dir=swap ? dir[8:6] : dir[11:9];
 // snooper + servos
 wire ev0,ev1; wire [2:0] snoop_a8;
 snk_aim_snoop snoop(.clk(clk),.reset(reset),.profile(profile),.a_addr(a_addr),.a_data(a_data),.a_ctl(a_ctl),
  .ev0(ev0),.ev1(ev1),.a8(snoop_a8));
 // D-pad -> compass for "Digital" mode
 function [3:0] dpad8(input [3:0] j); // returns {valid,dir}; j = {up,down,left,right}
  reg u,d,l,r;
  begin u=j[3]&!j[2]; d=j[2]&!j[3]; l=j[1]&!j[0]; r=j[0]&!j[1];
   if(u)dpad8=r ? {1'b1,3'd1} : l ? {1'b1,3'd7} : {1'b1,3'd0};
   else if(d)dpad8=r ? {1'b1,3'd3} : l ? {1'b1,3'd5} : {1'b1,3'd4};
   else dpad8=r ? {1'b1,3'd2} : l ? {1'b1,3'd6} : 4'd0;
  end
 endfunction
 wire [3:0] dp0=dpad8(joy0[3:0]),dp1=dpad8(joy1[3:0]);
 wire stick_en=mode==2'd0||mode==2'd1, dig_en=mode==2'd3, man_en=mode!=2'd1;
 reg t0_act=0,t1_act=0; reg [2:0] t0=0,t1=0; reg [1:0] mode_q=0;
 // Manual input owns aim until the aiming stick/D-pad is released. A continuous
 // quantiser update must not immediately undo a bumper or spinner step.
 reg rearm0=0,rearm1=0;
 always @(posedge clk)begin
  mode_q<=mode;
  if(reset||!enabled||mode!=mode_q)begin t0_act<=0;t1_act<=0;rearm0<=0;rearm1<=0;end
  else if(run)begin
   if(!(dig_en ? dp0[3] : a0_defl))rearm0<=0;
   if(!(dig_en ? dp1[3] : a1_defl))rearm1<=0;
   if(man_en&&manual0)begin t0_act<=0;rearm0<=1;end
   else if(!rearm0)begin
    if(dig_en&&dp0[3])begin t0<=dp0[2:0];t0_act<=1;end
    if(stick_en&&a0_upd)begin t0<=a0_dir;t0_act<=1;end
   end
   if(man_en&&manual1)begin t1_act<=0;rearm1<=1;end
   else if(!rearm1)begin
    if(dig_en&&dp1[3])begin t1<=dp1[2:0];t1_act<=1;end
    if(stick_en&&a1_upd)begin t1<=a1_dir;t1_act<=1;end
   end
  end
 end
 wire [2:0] obs0,obs1;
 snk_aim_servo servo0(.clk(clk),.reset(reset),.run(run),.enabled(enabled),.ms_tick(ms),.single(profile==8'd18),.speed(speed),.burst(burst),
  .tgt_active(t0_act),.tgt(t0),.ev(ev0),.a8(snoop_a8),.aoff(aoff0),.a_obs(obs0),.busy());
 snk_aim_servo servo1(.clk(clk),.reset(reset),.run(run),.enabled(enabled),.ms_tick(ms),.single(profile==8'd18),.speed(speed),.burst(burst),
  .tgt_active(t1_act),.tgt(t1),.ev(ev1),.a8(snoop_a8),.aoff(aoff1),.a_obs(obs1),.busy());
 // pad filter: left stick (hps_io merges it into the D-pad bits) / swap layout
 wire [3:0] rdir0,rdir1;
 function [3:0] dir2bits(input [2:0] d); // {up,down,left,right}
  case(d) 3'd0:dir2bits=4'b1000; 3'd1:dir2bits=4'b1001; 3'd2:dir2bits=4'b0001; 3'd3:dir2bits=4'b0101;
          3'd4:dir2bits=4'b0100; 3'd5:dir2bits=4'b0110; 3'd6:dir2bits=4'b0010; default:dir2bits=4'b1010; endcase
 endfunction
 assign rdir0=dir2bits(dir[5:3]); assign rdir1=dir2bits(dir[11:9]);
 wire mask0=enabled&&defl[0]&&(swap||leftoff), mask1=enabled&&defl[2]&&(swap||leftoff);
 // Consume the movement axis directly as well as Main's merged digital bits;
 // analog-only mappings must work without Main's analog-to-D-pad conversion.
 wire [3:0] mv0=(mask0 ? 4'b0000 : joy0[3:0]) |
   ((enabled&&swap&&defl[1]) ? rdir0 :
    (enabled&&!swap&&!leftoff&&defl[0]) ? dir2bits(dir[2:0]) : 4'b0000);
 wire [3:0] mv1=(mask1 ? 4'b0000 : joy1[3:0]) |
   ((enabled&&swap&&defl[3]) ? rdir1 :
    (enabled&&!swap&&!leftoff&&defl[2]) ? dir2bits(dir[8:6]) : 4'b0000);
 // Stick autofire is not a rapid-fire macro: Fire (joystick bit 4) is simply held while the aim stick is deflected
 // (outside the deadzone, with the quantiser's hysteresis), exactly like holding the button.
 wire hold0=enabled&&stickfire&&stick_en&&a0_defl, hold1=enabled&&stickfire&&stick_en&&a1_defl;
 assign joy0_f={joy0[31:5],joy0[4]|hold0,mv0};
 assign joy1_f={joy1[31:5],joy1[4]|hold1,mv1};
endmodule
