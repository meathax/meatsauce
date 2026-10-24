/* SPDX-License-Identifier: GPL-3.0-or-later */
// Presentation only: the PCB raster, IRQs, CPU and all game enables are unchanged.
module jtblkpan_crt_video(
 input clk,reset,ce,
 input [63:0] status,
 input forced_scan,native_timing_valid,
 input [23:0] rgb,
 input hs,vs,hb,vb,
 output out_ce,
 output [23:0] out_rgb,
 output out_hs,out_vs,out_hb,out_vb,
 output active,available,clamped
);
// The buffered final row is still emitted after raw VBlank rises. Commit
// controls at VSync, inside blanking, after that row has drained.
reg vs_old;
always @(posedge clk) if(reset)vs_old<=1;else if(ce)vs_old<=vs;
wire boundary=ce && vs && !vs_old;
reg signed [4:0] size;
always @* case(status[51:49])
 3'd1:size=1;
 3'd2:size=2;
 3'd3:size=-2;
 3'd4:size=-1;
 default:size=0;
endcase
wire quarter_turn=status[13];
wire scaled=forced_scan || status[5:3]!=0;
jtblkpan_native_crt_adjust #(.PIXEL_DIV(8),.HTOTAL(384),.VTOTAL(264),
 .HACTIVE_START(97),.HS_REFERENCE(0),.LINE_REFERENCE_DELAY(72),
 .HSIZE_MIN(-2),.HSIZE_MAX(2),.HPOS_MIN(-16),.HPOS_MAX(15),.VPOS_MIN(-16),.VPOS_MAX(15)) u_native(
 .clk(clk),.reset(reset),.native_frame_boundary(boundary),.native_timing_valid(native_timing_valid),
 // Remove the presentation transform immediately when a doubled/rotated path
 // is selected. Re-entry still needs the donor's full frame warm-up.
 .native_profile(!scaled && !quarter_turn),.path_selected(1'b1),
 .scandoubler_enabled(scaled),.quarter_turn_selected(quarter_turn),
 .enable(status[48]),.hsize(size),.hposition({{2{status[56]}},status[56:52]}),
 .vposition(status[61:57]),.ce_in(ce),.rgb_in(rgb),.hs_in(hs),.vs_in(vs),.hb_in(hb),.vb_in(vb),
 .ce_out(out_ce),.rgb_out(out_rgb),.hs_out(out_hs),.vs_out(out_vs),.hb_out(out_hb),.vb_out(out_vb),
 .active(active),.available(available),.range_clamped(clamped));
endmodule
