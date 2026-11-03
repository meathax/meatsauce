// SPDX-License-Identifier: GPL-3.0-or-later
// S.A.R. native72MHz schedule. Pixels remain uniform through game resets,
// pause and OSD. Fractional accumulation is used ONLY for the640kHz ADPCM CE.
module sar_clock_enables(
 input wire clk,
 output reg ce_pixel=0,
 output reg ce_sound=0,
 output reg ce_adpcm=0,
 output reg ce_sound_n=0,
 output reg [3:0] pixel_phase=0
);
 reg [4:0] sound_phase=0;
 reg [7:0] adpcm_phase=0;
 always @(posedge clk) begin
  pixel_phase<=pixel_phase==11 ? 0 : pixel_phase+1'b1;
  ce_pixel<=pixel_phase==0;
  sound_phase<=sound_phase==17 ? 0 : sound_phase+1'b1;
  ce_sound<=sound_phase==0;
  ce_sound_n<=sound_phase==9;
  if(adpcm_phase>=223) begin
   adpcm_phase<=adpcm_phase-223;
   ce_adpcm<=1;
  end else begin
   adpcm_phase<=adpcm_phase+2;
   ce_adpcm<=0;
  end
 end
endmodule
