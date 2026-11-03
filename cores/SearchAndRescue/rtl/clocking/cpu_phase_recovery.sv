// SPDX-License-Identifier: GPL-3.0-or-later
// Native72MHz /4 phase budget (9MHz two-phase68000). Recover stalled phase
// credits at no faster than one event per3 system clocks (12MHz CPU ceiling).
// A pause drains an active bus cycle, then freezes at an idle bus boundary.
module cpu_phase_recovery(
 input wire clk,reset,pause_request,bus_idle,bus_wait,
 output wire phi1,phi2,paused,
 output reg [15:0] credits=0,
 output reg overflow=0
);
 reg [1:0] nominal_phase=0,cooldown=0;
 reg next_phi2=0,halted=0;
 wire freeze=halted || (pause_request && bus_idle);
 wire budget=nominal_phase==0;
 wire issue=!reset && !freeze && !bus_wait && cooldown==0 && (budget || credits!=0);
 assign phi1=issue && !next_phi2;
 assign phi2=issue && next_phi2;
 assign paused=!reset && freeze;
 always @(posedge clk) begin
  if(reset)begin
   nominal_phase<=0;cooldown<=0;next_phi2<=0;halted<=0;credits<=0;overflow<=0;
  end else begin
   halted<=pause_request && (halted || bus_idle);
   if(cooldown!=0)cooldown<=cooldown-1'b1;
   if(!freeze)begin
    nominal_phase<=nominal_phase+1'b1;
    case({budget,issue})
     2'b10:if(credits==16'hffff)overflow<=1;else credits<=credits+1'b1;
     2'b01:credits<=credits-1'b1;
     default:begin end
    endcase
    if(issue)begin next_phi2<=!next_phi2;cooldown<=2;end
   end
  end
 end
endmodule
