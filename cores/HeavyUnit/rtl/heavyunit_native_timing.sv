// SPDX-License-Identifier: GPL-3.0-or-later
// Parameterized wiring candidate. No default describes a Heavy Unit PCB.
module heavyunit_native_timing #(
 parameter integer PIXEL_DIV=0,HTOTAL=0,VTOTAL=0,
 parameter integer HACTIVE_START=0,HACTIVE_END=0,VACTIVE_START=0,VACTIVE_END=0,
 parameter integer HS_START=0,HS_END=0,VS_START=0,VS_END=0,
 parameter bit HS_ACTIVE_LOW=0,VS_ACTIVE_LOW=0,
 parameter integer EOF_LINE=0,IRQ64_LINE=0,IRQ240_LINE=0,SUB_IRQ_LINE=0
)(
 input logic clk,reset,native_timing_valid,tile_busy,line_pending,
 output logic main_event_64,main_event_240,sub_vblank,eof,vis_start,
 output logic prepare_line,line_commit,
 output logic [7:0] prepare_y,scan_x,scan_y,
 output logic scan_valid,raw_ce_pixel,raw_hs,raw_vs,raw_hb,raw_vb,raw_de,
 output logic sync_qualified,
 output logic [31:0] frame_number,missed_lines,blocked_preparations
);
 localparam bit PARAMETERS_VALID=PIXEL_DIV>=2 && HTOTAL>256 && HTOTAL<=1024 && VTOTAL>224 && VTOTAL<=1024 &&
  HACTIVE_START>=0 && HACTIVE_END-HACTIVE_START==256 && HACTIVE_END<=HTOTAL &&
  VACTIVE_START>=0 && VACTIVE_END-VACTIVE_START==224 && VACTIVE_END<=VTOTAL &&
  HS_START>=0 && HS_END>HS_START && HS_END<=HTOTAL &&
  VS_START>=0 && VS_END>VS_START && VS_END<=VTOTAL &&
  EOF_LINE>=0 && EOF_LINE<VTOTAL && IRQ64_LINE>=0 && IRQ64_LINE<VTOTAL &&
  IRQ240_LINE>=0 && IRQ240_LINE<VTOTAL && SUB_IRQ_LINE>=0 && SUB_IRQ_LINE<VTOTAL;
 localparam integer DW=PIXEL_DIV>1 ? $clog2(PIXEL_DIV) : 1;
 localparam integer HW=HTOTAL>1 ? $clog2(HTOTAL) : 1;
 localparam integer VW=VTOTAL>1 ? $clog2(VTOTAL) : 1;
 localparam integer PRE_FIRST=VACTIVE_START>0 ? VACTIVE_START-1 : VTOTAL-1;
 logic [DW-1:0] divider;
 logic [HW-1:0] hpos;
 logic [VW-1:0] vpos;
 logic current_line_valid;
 wire admitted=PARAMETERS_VALID && native_timing_valid && !reset;
 wire ce=admitted && divider==DW'(PIXEL_DIV-1);
 wire horizontal=int'(hpos)>=HACTIVE_START && int'(hpos)<HACTIVE_END;
 wire vertical=int'(vpos)>=VACTIVE_START && int'(vpos)<VACTIVE_END;
 wire first=ce && int'(hpos)==HACTIVE_START;
 wire line_start=ce && int'(hpos)==0;
 wire prep_candidate=first && (int'(vpos)==PRE_FIRST || (vertical && int'(vpos)<VACTIVE_END-1));
 assign sync_qualified=admitted;
 assign raw_ce_pixel=ce;
 assign raw_hb=!horizontal;
 assign raw_vb=!vertical;
 assign raw_hs=HS_ACTIVE_LOW ? !(int'(hpos)>=HS_START && int'(hpos)<HS_END) : (int'(hpos)>=HS_START && int'(hpos)<HS_END);
 assign raw_vs=VS_ACTIVE_LOW ? !(int'(vpos)>=VS_START && int'(vpos)<VS_END) : (int'(vpos)>=VS_START && int'(vpos)<VS_END);
 assign scan_x=8'(int'(hpos)-HACTIVE_START);
 assign scan_y=8'(int'(vpos)-VACTIVE_START+16);
 assign raw_de=admitted && horizontal && vertical && (first ? line_pending : current_line_valid);
 assign scan_valid=ce && raw_de;
 assign eof=line_start && int'(vpos)==EOF_LINE;
 assign sub_vblank=line_start && int'(vpos)==SUB_IRQ_LINE;
 assign main_event_64=line_start && int'(vpos)==IRQ64_LINE;
 assign main_event_240=line_start && int'(vpos)==IRQ240_LINE;
 assign vis_start=first && int'(vpos)==VACTIVE_START;
 assign line_commit=first && vertical && line_pending;
 assign prepare_line=prep_candidate && (!tile_busy || line_commit);
 assign prepare_y=int'(vpos)==PRE_FIRST ? 8'd16 : scan_y+8'd1;
 always_ff @(posedge clk) begin
  if(!admitted) begin
   divider<=0;hpos<=0;vpos<=0;current_line_valid<=0;
   frame_number<=0;missed_lines<=0;blocked_preparations<=0;
  end else begin
   if(ce) begin
    divider<=0;
    if(int'(hpos)==HTOTAL-1) begin hpos<=0;if(int'(vpos)==VTOTAL-1)vpos<=0;else vpos<=vpos+1'b1;end
    else hpos<=hpos+1'b1;
   end else divider<=divider+1'b1;
   if(eof)frame_number<=frame_number+1'b1;
   if(first) begin
    current_line_valid<=vertical && line_pending;
    if(vertical && !line_pending)missed_lines<=missed_lines+1'b1;
    if(prep_candidate && !prepare_line)blocked_preparations<=blocked_preparations+1'b1;
   end
  end
 end
endmodule
