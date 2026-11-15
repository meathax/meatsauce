// SPDX-License-Identifier: GPL-3.0-or-later
// MAME 0.289 logical screen model; board sync edges remain unqualified.
// MAME supplies 60 Hz, 288x224 total, and visible x=0..287/y=8..223.
// pce must be an externally supplied exact pixel enable; no cadence is made here.
// H/V sync are omitted because the MAME screen setup does not declare their edges.
module snk_wave_raster_inherited(
 input wire clk,reset,pce,
 output wire hblank,vblank,hsync,vsync,
 output reg [8:0] hc,vc
);
 localparam integer H_TOTAL=288;
 localparam integer V_TOTAL=224;
 localparam integer V_VISIBLE_START=8;

 always @(posedge clk)begin
  if(reset)begin hc<=0;vc<=0;end
  else if(pce)begin
   if(hc==H_TOTAL-1)begin
    hc<=0;
    if(vc==V_TOTAL-1)vc<=0;else vc<=vc+1'b1;
   end else hc<=hc+1'b1;
  end
 end

 // The MAME visible rectangle covers every horizontal sample and 216 rows.
 assign hblank=1'b0;
 assign vblank=vc<V_VISIBLE_START;
 // MAME defines no PCB sync edges for this screen. These negative-polarity pulses
 // are transport markers only (4 logical samples and 4 logical lines), not board measurements.
 assign hsync=(hc>=9'd4);
 assign vsync=(vc>=9'd4);
endmodule
