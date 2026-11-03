// Adapted for Mad Motor separate H/V blanking; GPL-3.0-or-later donor retained.
// SPDX-License-Identifier: GPL-3.0-or-later
// Core-side real crt_adjust donor. External profile validation remains required.
module madmotor_native_crt_adjust #(
 parameter integer PIXEL_DIV=0,HTOTAL=0,VTOTAL=0,HACTIVE_START=0,HS_REFERENCE=0,
 parameter integer HSIZE_MIN=0,HSIZE_MAX=0,HPOS_MIN=0,HPOS_MAX=0,VPOS_MIN=0,VPOS_MAX=0
)(
 input logic clk,reset,native_frame_boundary,native_timing_valid,native_profile,
 input logic path_selected,scandoubler_enabled,quarter_turn_selected,enable,
 input logic signed [4:0] hsize,vposition,
 input logic signed [6:0] hposition,
 input logic ce_in,input logic [23:0] rgb_in,
 input logic hs_in,vs_in,hb_in,vb_in,
 output logic ce_out,output logic [23:0] rgb_out,
 output logic hs_out,vs_out,hb_out,vb_out,active,available,range_clamped
);
 // Donor CONTENTSHIFT pass window is hb1+hoffset <= rdcnt < hb0+hoffset.
 // hb1 origin is the native HSync rise to active-start distance; width is256.
 localparam integer READ_ORIGIN=HTOTAL>0 ? (HACTIVE_START-HS_REFERENCE+HTOTAL)%HTOTAL : 0;
 localparam integer READ_FIRST=READ_ORIGIN+HPOS_MIN;
 localparam integer READ_LAST=READ_ORIGIN+256+HPOS_MAX;
 localparam longint LINE_CLOCKS=longint'(HTOTAL)*longint'(PIXEL_DIV);
 localparam longint LAST_READ_CLOCK=longint'(READ_LAST)*longint'(PIXEL_DIV+HSIZE_MAX);
 localparam bit PARAMETERS_VALID=PIXEL_DIV>=2 && PIXEL_DIV<=65535 && HTOTAL>256 && HTOTAL<=1024 && VTOTAL>224 &&
  HACTIVE_START>=0 && HACTIVE_START<HTOTAL && HS_REFERENCE>=0 && HS_REFERENCE<HTOTAL &&
  READ_FIRST>=0 && READ_LAST<=1024 && LAST_READ_CLOCK<=LINE_CLOCKS &&
  HSIZE_MIN>=-16 && HSIZE_MAX<=15 && HSIZE_MIN<=0 && HSIZE_MAX>=0 && PIXEL_DIV+HSIZE_MIN>=2 &&
  HPOS_MIN>=-64 && HPOS_MAX<=63 && HPOS_MIN<=0 && HPOS_MAX>=0 &&
  VPOS_MIN>=-16 && VPOS_MAX<=15 && VPOS_MIN<=0 && VPOS_MAX>=0;
 wire safe=PARAMETERS_VALID && native_timing_valid && native_profile && !reset;
 // Eligibility is independent of stored On/Off and frame warmup.
 assign available=safe && path_selected && !scandoubler_enabled && !quarter_turn_selected;
 wire request=available && enable;
 integer hs_request,hp_request,vp_request;
 always_comb begin
  hs_request=int'($signed(hsize));hp_request=int'($signed(hposition));vp_request=int'($signed(vposition));
  if(hs_request<HSIZE_MIN)hs_request=HSIZE_MIN;else if(hs_request>HSIZE_MAX)hs_request=HSIZE_MAX;
  if(hp_request<HPOS_MIN)hp_request=HPOS_MIN;else if(hp_request>HPOS_MAX)hp_request=HPOS_MAX;
  if(vp_request<VPOS_MIN)vp_request=VPOS_MIN;else if(vp_request>VPOS_MAX)vp_request=VPOS_MAX;
 end
 logic request_q;
 logic active_latched;
 wire engine_active=request_q || active_latched;
 logic signed [4:0] hs_q,vp_q;
 logic signed [6:0] hp_q;
 logic [1:0] warm_frames;
 always_ff @(posedge clk) begin
  if(!safe || !available)begin request_q<=0;hs_q<=0;hp_q<=0;vp_q<=0;warm_frames<=0;range_clamped<=0;end
  else if(native_frame_boundary)begin
   request_q<=request;hs_q<=5'(hs_request);hp_q<=7'(hp_request);vp_q<=5'(vp_request);
   range_clamped<=hs_request!=int'($signed(hsize)) || hp_request!=int'($signed(hposition)) || vp_request!=int'($signed(vposition));
   if(!request || !request_q || hs_q!=5'(hs_request) || hp_q!=7'(hp_request) || vp_q!=5'(vp_request))warm_frames<=0;
   else if(warm_frames<2)warm_frames<=warm_frames+1'b1;
  end
 end
 assign active=available && active_latched;
 // Internal source-pixel retirement period. This must never drive CE_PIXEL:
 // resizing samples this held stream on the unchanged native pixel grid.
 integer read_period,read_counter;
 wire hs_reference;
 logic hs_reference_old;
 wire read_ce=safe && engine_active && read_counter==read_period-1;
 always_comb read_period=PIXEL_DIV+int'($signed(hs_q));
 always_ff @(posedge clk)begin
  if(!safe || !engine_active)begin read_counter<=0;hs_reference_old<=hs_in;end
  else begin
   hs_reference_old<=hs_reference;
   if(hs_reference && !hs_reference_old)read_counter<=0;
   else if(read_ce)read_counter<=0;
   else read_counter<=read_counter+1;
  end
 end
 wire [23:0] adjusted_rgb;
 wire adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb;
 generate if(PARAMETERS_VALID) begin: donor_enabled
  madmotor_crt_adjust #(.HTOTAL(HTOTAL),.VTOTAL(VTOTAL),.HPOS_MODE(1),.SEPARATE_BLANK(1)) donor(
   .clk,.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(safe && engine_active),
   .hsize(hs_q),.hoffset({{2{hp_q[6]}},hp_q}),.voffset({vp_q[4],vp_q}),
   .r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),
   .hs_in,.vs_in,.hb_in,.vb_in,
   .r_out(adjusted_rgb[23:16]),.g_out(adjusted_rgb[15:8]),.b_out(adjusted_rgb[7:0]),
   .hs_out(adjusted_hs),.vs_out(adjusted_vs),.hb_out(adjusted_hb),.vb_out(adjusted_vb),.hs_ref_out(hs_reference));
 end else begin: no_valid_profile
  assign adjusted_rgb=rgb_in;
  assign {adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb}={hs_in,vs_in,hb_in,vb_in};
  assign hs_reference=hs_in;
 end endgenerate
 // Hand the mux over only after the last buffered row and VSync pulse drain.
 // Keep the engine running during an Off request until that handoff completes.
 always_ff @(posedge clk) begin
  if(!safe || !available) active_latched<=0;
  else if(vb_in && adjusted_vb && !vs_in && !adjusted_vs && !hs_in && !adjusted_hs)
   active_latched<=request_q && warm_frames==2;
 end
 // Off bypass is outside donor, with no added clocks, sync phase or blank changes.
 assign ce_out=ce_in;
 assign rgb_out=active ? adjusted_rgb : rgb_in;
 assign {hs_out,vs_out,hb_out,vb_out}=active ? {adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb} : {hs_in,vs_in,hb_in,vb_in};
endmodule
