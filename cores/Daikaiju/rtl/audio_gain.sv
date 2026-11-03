// SPDX-License-Identifier: GPL-3.0-or-later
// Exact replacements for signed truncation-toward-zero constant divisions.
// Exhaustively proved on every legal input code, not approximate gain fitting:
// floor(n*63/100)       == (n*660603)>>20, n=0..32768
// floor(n*16382/2125)   == (n*4041829)>>19, n=0..1024
// floor(n*16384/2125)   == (n*2021161)>>18, n=0..1024
module a74_audio_gain(
 input wire signed[15:0] fm_raw,
 input wire signed[10:0] ym_psg,ay_psg,
 output wire signed[31:0] fm_scaled,ym_scaled,ay_scaled
);
 wire[15:0]fm_magnitude=fm_raw[15]?(~fm_raw+16'd1):fm_raw;
 wire[10:0]ym_magnitude=ym_psg[10]?(~ym_psg+11'd1):ym_psg;
 wire[10:0]ay_magnitude=ay_psg[10]?(~ay_psg+11'd1):ay_psg;
 wire[35:0]fm_product=fm_magnitude*20'd660603;
 wire[32:0]ym_product=ym_magnitude*22'd4041829;
 wire[31:0]ay_product=ay_magnitude*21'd2021161;
 wire[15:0]fm_quotient=fm_product[35:20];
 wire[15:0]ym_quotient={2'd0,ym_product[32:19]};
 wire[15:0]ay_quotient={2'd0,ay_product[31:18]};
 wire signed[15:0]fm_value=fm_raw[15]?-$signed(fm_quotient):$signed(fm_quotient);
 wire signed[15:0]ym_value=ym_psg[10]?-$signed(ym_quotient):$signed(ym_quotient);
 wire signed[15:0]ay_value=ay_psg[10]?-$signed(ay_quotient):$signed(ay_quotient);
 assign fm_scaled=fm_value;
 assign ym_scaled=ym_value;
 assign ay_scaled=ay_value;
endmodule
