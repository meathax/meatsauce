// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from HeavyUnit heavyunit_native_crt_adjust; caller timing validation remains required.
module hangzo_native_crt_adjust #(
 parameter integer PIXEL_DIV=0,HTOTAL=0,VTOTAL=0,HACTIVE_START=0,HS_REFERENCE=0,
 parameter integer ACTIVE_WIDTH=320,ACTIVE_HEIGHT=240,
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
 // Negative HPosition wraps the active window across raw x=0. Move only that
 // private bank/read reference so the window stays inside one completed bank;
 // nonnegative positions retain the donor's native reference and sync path.
 // Hangzo's negative endpoint moves x384 to x336 (394 CE events), with its
 // x426..303 read window wholly inside one bank interval.
 localparam integer INTERNAL_HS_REFERENCE=HTOTAL>0 ?
  (HACTIVE_START+ACTIVE_WIDTH+HPOS_MAX+1)%HTOTAL : 0;
 localparam integer HS_ADVANCE=HTOTAL>0 ? (HS_REFERENCE-INTERNAL_HS_REFERENCE+HTOTAL)%HTOTAL : 0;
 localparam integer HS_DELAY=HS_ADVANCE==0 ? 0 : HTOTAL-HS_ADVANCE;
 // Donor CONTENTSHIFT pass window is hb1+hoffset <= rdcnt < hb0+hoffset.
 // Bound both native and negative-position rephased origins in profile checks.
 localparam integer READ_ORIGIN_RAW=HTOTAL>0 ? (HACTIVE_START-HS_REFERENCE+HTOTAL)%HTOTAL : 0;
 localparam integer READ_ORIGIN_REPHASED=HTOTAL>0 ? (HACTIVE_START-INTERNAL_HS_REFERENCE+HTOTAL)%HTOTAL : 0;
 localparam integer READ_FIRST_RAW=READ_ORIGIN_RAW+HPOS_MIN;
 localparam integer READ_FIRST_REPHASED=READ_ORIGIN_REPHASED+HPOS_MIN;
 localparam integer READ_LAST_RAW=READ_ORIGIN_RAW+ACTIVE_WIDTH+HPOS_MAX;
 localparam integer READ_LAST_REPHASED=READ_ORIGIN_REPHASED+ACTIVE_WIDTH+HPOS_MAX;
 localparam integer READ_FIRST=(READ_FIRST_RAW<READ_FIRST_REPHASED)?READ_FIRST_RAW:READ_FIRST_REPHASED;
 localparam integer READ_LAST=(READ_LAST_RAW>READ_LAST_REPHASED)?READ_LAST_RAW:READ_LAST_REPHASED;
 localparam longint LINE_CLOCKS=longint'(HTOTAL)*longint'(PIXEL_DIV);
 localparam longint LAST_READ_CLOCK=longint'(READ_LAST)*longint'(PIXEL_DIV+HSIZE_MAX);
 localparam bit PARAMETERS_VALID=PIXEL_DIV>=2 && PIXEL_DIV<=65535 && ACTIVE_WIDTH>0 && ACTIVE_WIDTH<HTOTAL &&
  ACTIVE_HEIGHT>0 && ACTIVE_HEIGHT<VTOTAL && HTOTAL<=1024 &&
  HACTIVE_START>=0 && HACTIVE_START<HTOTAL && HS_REFERENCE>=0 && HS_REFERENCE<HTOTAL &&
  READ_FIRST>=0 && READ_LAST<=HTOTAL && LAST_READ_CLOCK<=LINE_CLOCKS &&
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
 logic signed [4:0] hs_q,vp_q;
 logic signed [6:0] hp_q;
 logic [1:0] warm_frames;
 always_ff @(posedge clk) begin
  if(!safe)begin request_q<=0;hs_q<=0;hp_q<=0;vp_q<=0;warm_frames<=0;range_clamped<=0;end
  else if(native_frame_boundary)begin
   request_q<=request;hs_q<=5'(hs_request);hp_q<=7'(hp_request);vp_q<=5'(vp_request);
   range_clamped<=hs_request!=int'($signed(hsize)) || hp_request!=int'($signed(hposition)) || vp_request!=int'($signed(vposition));
   if(!request || !request_q || hs_q!=5'(hs_request) || hp_q!=7'(hp_request) || vp_q!=5'(vp_request))warm_frames<=0;
   else if(warm_frames<2)warm_frames<=warm_frames+1'b1;
  end
 end
 assign active=safe && request_q && warm_frames==2;
 // Fixed integer CE period per admitted setting. No quarter-cycle/Bresenham jitter.
 integer read_period,read_counter;
 wire hs_reference;
 logic hs_reference_old;
 wire read_ce=safe && request_q && read_counter==read_period-1;
 always_comb read_period=PIXEL_DIV+int'($signed(hs_q));
 always_ff @(posedge clk)begin
  if(!safe || !request_q)begin read_counter<=0;hs_reference_old<=hs_donor_in;end
  else begin
   hs_reference_old<=hs_reference;
   if(hs_reference && !hs_reference_old)read_counter<=0;
   else if(read_ce)read_counter<=0;
   else read_counter<=read_counter+1;
  end
 end
 wire [23:0] adjusted_rgb;
 wire adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb;
 logic hs_native_q,vs_adjusted_q;
 logic [((HS_DELAY>0)?HS_DELAY:1)-1:0] hs_delay;
 wire hs_internal;
 generate
  if(HS_DELAY==1) begin: hs_delay_one
   always_ff @(posedge clk)begin
    if(!safe)hs_delay[0]<=hs_in;
    else if(ce_in)hs_delay[0]<=hs_in;
   end
   assign hs_internal=hs_delay[0];
  end else if(HS_DELAY>1) begin: hs_delay_many
   always_ff @(posedge clk)begin
    if(!safe)hs_delay<={HS_DELAY{hs_in}};
    else if(ce_in)hs_delay<={hs_delay[HS_DELAY-2:0],hs_in};
   end
   assign hs_internal=hs_delay[HS_DELAY-1];
  end else begin: hs_delay_none
   assign hs_internal=hs_in;
  end
 endgenerate
 wire hs_donor_in=(request_q && ($signed(hp_q)<0)) ? hs_internal : hs_in;
  // The donor's separate-blank path already associates VBlank with the
  // completed line. A second raw-HSync sample here advances the blank tag one
  // more line on the rephased negative-HPosition read path, dropping source
  // row 8 and admitting blank source row 248. Keep the original tag phase.
  wire vb_donor_in=vb_in;
 always_ff @(posedge clk)begin
  if(!safe)begin hs_native_q<=hs_in;vs_adjusted_q<=vs_in;end
  else begin
   if(ce_in)hs_native_q<=hs_in;
   if(read_ce)vs_adjusted_q<=adjusted_vs;
  end
 end
 generate if(PARAMETERS_VALID) begin: donor_enabled
  crt_adjust #(.HTOTAL(HTOTAL),.VTOTAL(VTOTAL),.HPOS_MODE(1),.SEPARATE_BLANK(1)) donor(
   .clk,.pxl_cen(ce_in),.pxl2_cen(read_ce),.active(safe && request_q),
   .hsize(hs_q),.hoffset({{2{hp_q[6]}},hp_q}),.voffset({vp_q[4],vp_q}),
   .r_in(rgb_in[23:16]),.g_in(rgb_in[15:8]),.b_in(rgb_in[7:0]),
    .hs_in(hs_donor_in),.vs_in,.hb_in,.vb_in(vb_donor_in),
   .r_out(adjusted_rgb[23:16]),.g_out(adjusted_rgb[15:8]),.b_out(adjusted_rgb[7:0]),
   .hs_out(adjusted_hs),.vs_out(adjusted_vs),.hb_out(adjusted_hb),.vb_out(adjusted_vb),.hs_ref_out(hs_reference));
 end else begin: no_valid_profile
  assign adjusted_rgb=rgb_in;
  assign {adjusted_hs,adjusted_vs,adjusted_hb,adjusted_vb}={hs_internal,vs_in,hb_in,vb_in};
  assign hs_reference=hs_internal;
 end endgenerate
 // Off bypass is outside donor, with no added clocks, sync phase or blank changes.
 assign ce_out=active ? read_ce : ce_in;
 assign rgb_out=active ? adjusted_rgb : rgb_in;
 // Keep the known-good adjusted sync path for nonnegative HPosition. The
 // negative rephase uses native HS delayed one input CE to match the output
 // chain; its V-positioned VS receives one read-CE alignment stage as well.
 assign hs_out=active ? (($signed(hp_q)<0) ? hs_native_q : adjusted_hs) : hs_in;
 assign vs_out=active ? (($signed(hp_q)<0) ? vs_adjusted_q : adjusted_vs) : vs_in;
 assign hb_out=active ? adjusted_hb : hb_in;
 assign vb_out=active ? adjusted_vb : vb_in;
endmodule
