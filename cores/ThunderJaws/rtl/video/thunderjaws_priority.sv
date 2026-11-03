// SPDX-License-Identifier: GPL-3.0-or-later
// Target thunderj.cpp PF/MO priority, alpha overlay, then atarimo stain pass.
module thunderjaws_priority (
 input wire clk_sys,reset,advance,
 input wire stain_override_enable,stain_override,
 input wire [8:0] hpos,
 input wire [12:0] background,
 input wire [8:0] alpha,
 input wire [10:0] motion,
 output wire [10:0] palette
);
 wire [1:0] pfpri=background[11:10];
 wire [2:0] mpri=motion[10:8];
 wire present=|motion[3:0];
 wire pf_wins=motion[7:0]==8'h01 || (background[3] &&
  ((pfpri==3 && !mpri[0]) || (pfpri[0] && mpri==0) || (pfpri[1] && !mpri[1])));
 wire [9:0] under_alpha=present && !mpri[2] && !pf_wins ? {2'b01,motion[7:0]} : background[9:0];
 wire [9:0] ordinary=(alpha[8] || |alpha[1:0]) ? {2'b00,alpha[7:0]} : under_alpha;
 reg staining,off_next;
 wire start_marker=present && mpri[2] && motion[1];
 wire end_marker=present && mpri[2] && motion[2];
 wire active=(hpos!=0 && staining) || start_marker;
 wire stopping=hpos!=0 && off_next && !start_marker;
 assign palette={stain_override_enable ? stain_override : active,ordinary};
 always @(posedge clk_sys)begin
  if(reset)begin staining<=0;off_next<=0;end
  else if(advance)begin
   staining<=active && !stopping && hpos!=335;
   off_next<=active && end_marker && !stopping && hpos!=335;
  end
 end
endmodule
