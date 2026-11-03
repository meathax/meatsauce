// SPDX-License-Identifier: GPL-3.0-or-later
// Stall-debt accounting adapted from Jose Tejada's jtframe_68kdtack_cen.
// Reference: MiSTer-devel/Arcade-BloodBros_MiSTer, commit
// 2abeab3f6189c62cf179a2ade7fa933dcb42493c, rtl/jtframe/jtframe_68kdtack_cen.v
// SHA256 1c6a90bcb02947f586fe94eb3d61f6aba6d53f9f4f09fc28d0f9cab769b0ec5e.
// The 6809 bus protocol is different: retain its E0/Q8 phase ordering, count
// missing fabric ticks, and repay only by skipping a non-strobe phase.
module pwb_cpu_clock #(parameter DEBT_WIDTH=32)(
 input wire clk,reset,pause,cpu_ok,
 output reg [3:0] phase,
 output reg paused,
 output wire stop_cpu,ce_e,ce_q,
 output reg primed,
 output reg [DEBT_WIDTH-1:0] debt,
 output reg debt_overflow
);
 wire pause_boundary=pause && phase==0;
 assign stop_cpu=paused || pause_boundary;
 // As in the original board, reset dominates the consumer's clocked state.
 // Raw E may be asserted during reset; the board masks bus acceptance.
 wire advance=!stop_cpu && cpu_ok && !debt_overflow;
 assign ce_e=advance && phase==0;
 assign ce_q=advance && phase==8;
 wire repay=advance && primed && debt!=0 && phase!=7 && phase!=15;
 always @(posedge clk) begin
  if(reset) begin
   phase<=0;paused<=0;primed<=0;debt<=0;debt_overflow<=0;
  end else begin
   paused<=pause && (paused || phase==0);
   if(!stop_cpu && !debt_overflow) begin
    if(!cpu_ok) begin
     // Never silently wrap or discard elapsed CPU time. A diagnosed capacity
     // failure stops accepted CPU events until the next board-reset epoch.
     if(&debt) debt_overflow<=1;
     else debt<=debt+1'b1;
    end else begin
     phase<=phase+(repay ? 4'd2 : 4'd1);
     if(repay) debt<=debt-1'b1;
     // Keep all debt, but do not accelerate reset's first E-to-Q window.
     if(phase==8) primed<=1;
    end
   end
  end
 end
endmodule
