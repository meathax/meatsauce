// SPDX-License-Identifier: GPL-3.0-or-later
// SNK early-family "Group B" (Wave boards, profiles 0..2) output raster on the 93.8 MHz early PLL setting.
//
// Logical source: pinned MAME 0.289 snk.cpp -- 288 active columns, 224 total
// lines, lines 0..7 blank, rows 8..223 visible (216), pixel = 3.87072 MHz.
// The pixel cadence is NOT generated here: pce must be the exact
// group_b_pixel_cen from snk_early_master_cen (clk/14 at 93.8 MHz = 6.7 MHz, the 13.4 MHz-family pixel).
//
// Synthetic transport blanking, same recipe as rtl/snk/late/snk_late_video.sv
// (16 H blank pixels, 5 trailing V blank lines; none of it is measured PCB timing):
//   H: 288 active, 16 blank (total 304); HS = 8 pixels starting 4 after active.
//   V: lines 0..7 MAME blank, 8..223 visible, 224..228 synthetic blank
//      (total 229). VS = 3 lines starting 2 after line 223 (late: VACT+2..+4).
//      The 8 MAME-blank lines and the 5 synthetic lines are contiguous across
//      the frame wrap, giving one 16-line vertical blank and 216 visible rows.
//   2026-10-21: totals 310x229 with pce = clk/22 (4.363636 MHz) give 61.4683 Hz,
//   the real-PCB rate measured from Jumping Cross footage (61.416 Hz).
//   2026-10-27 (93.8 MHz family PLL): the Wave boards share the 13.4 MHz crystal family (MAME CPUs 3.36 MHz),
//   so pce = clk/14 = 6.7 MHz with the same 416x262 raster as the other early boards = 61.472 Hz (PCB 61.416).
//   The Wave renderer was written for a 6.7 MHz pce (3328-clock lines at 53.6 MHz); a 5824-clock line is wider.
//   HS 308..315 as the Ikari/early 416-pixel line; lines 224..261 and 0..7 form one 46-line vertical blank.
// Polarity: all four outputs ACTIVE HIGH (HBlank/VBlank/HSync/VSync), as the
// late video module and snk_mister_video expect.
//
// Outputs are registered on pce and lag the hc/vc counters by exactly one pce
// (output after pce n describes counter position n-1). HBlank toggles on every
// line including the vertical blank (the Wave line scheduler needs hblank
// falling edges on every line). VS only changes at the HS leading edge.
module snk_early_group_b_raster #(
 parameter integer H_ACTIVE=288,
 parameter integer H_TOTAL=416,
 parameter integer HS_START=308,
 parameter integer HS_END=316,
 parameter integer V_VIS_START=8,
 parameter integer V_VIS_END=224,   // first line after the visible window
 parameter integer V_TOTAL=262,
 parameter integer VS_START=226,
 parameter integer VS_END=229
)(
 input wire clk,reset,pce,
 output reg hblank=1'b1,vblank=1'b1,hsync=1'b0,vsync=1'b0,
 output reg [8:0] hc=9'd0,vc=9'd0
);
 always @(posedge clk)begin
  if(reset)begin
   hc<=9'd0;vc<=9'd0;hblank<=1'b1;vblank<=1'b1;hsync<=1'b0;vsync<=1'b0;
  end else if(pce)begin
   if(hc==H_TOTAL-1)begin
    hc<=9'd0;
    vc<=(vc==V_TOTAL-1)?9'd0:vc+9'd1;
   end else hc<=hc+9'd1;
   hblank<=(hc>=H_ACTIVE);
   vblank<=(vc<V_VIS_START)||(vc>=V_VIS_END);
   hsync<=(hc>=HS_START)&&(hc<HS_END);
   if(hc==HS_START)vsync<=(vc>=VS_START)&&(vc<VS_END);
  end
 end
endmodule
