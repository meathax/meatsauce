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
