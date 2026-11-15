// license:BSD-3-Clause
// copyright-holders:Couriersud
// SPDX-License-Identifier: BSD-3-Clause
// Generated from pinned MAME0.289 ay8910.cpp build_single_table.
// MAME source attribution retained in provenance.json; separate donor raw path unchanged.
// Signed24-bit Q1.23. level is actual producer5-bit code; env_mode belongs to same epoch.
module snk_timed_ay_normal_exp(input clk,input[4:0] level,input env_mode,
 output reg signed[23:0] dout);
 always @(posedge clk) begin
    case({env_mode,level[4:1]})
      5'd0: dout <= -24'sd1048576;
      5'd1: dout <= -24'sd991644;
      5'd2: dout <= -24'sd974454;
      5'd3: dout <= -24'sd951818;
      5'd4: dout <= -24'sd916776;
      5'd5: dout <= -24'sd865760;
      5'd6: dout <= -24'sd803232;
      5'd7: dout <= -24'sd649355;
      5'd8: dout <= -24'sd556013;
      5'd9: dout <= -24'sd241711;
      5'd10: dout <= 24'sd68369;
      5'd11: dout <= 24'sd434813;
      5'd12: dout <= 24'sd933397;
      5'd13: dout <= 24'sd1462396;
      5'd14: dout <= 24'sd2275343;
      5'd15: dout <= 24'sd3145728;
      5'd16: dout <= -24'sd1048576;
      5'd17: dout <= -24'sd1010745;
      5'd18: dout <= -24'sd993475;
      5'd19: dout <= -24'sd970735;
      5'd20: dout <= -24'sd935531;
      5'd21: dout <= -24'sd884279;
      5'd22: dout <= -24'sd821463;
      5'd23: dout <= -24'sd666875;
      5'd24: dout <= -24'sd573102;
      5'd25: dout <= -24'sd257350;
      5'd26: dout <= 24'sd54162;
      5'd27: dout <= 24'sd422298;
      5'd28: dout <= 24'sd923183;
      5'd29: dout <= 24'sd1454625;
      5'd30: dout <= 24'sd2271325;
      5'd31: dout <= 24'sd3145728;
      default: dout <= 24'sd0;
    endcase
 end
endmodule
