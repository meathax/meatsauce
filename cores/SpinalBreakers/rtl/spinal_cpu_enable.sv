// SPDX-License-Identifier: GPL-3.0-or-later
// Experimental 10 MHz fx68k phases at 630/11 MHz fabric. The normal half-phase
// rate is 22/63; a held SDRAM wait is repaid at up to one half-phase per two
// fabric edges. This module is not production-qualified until the wait signal,
// S4 boundary and full bus modes are verified against the connected CPU.
module spinal_cpu_enable (
    input logic clk,reset,freeze,as_n,uds_n,lds_n,dtack_n,rom_wait,
    output wire phi1,phi2,output logic overflow=0,output logic [15:0] debt=0
);
    logic [6:0] accumulator=0;
    logic phase=0,active_phi1=0,cooldown=0;
    wire [7:0] sum={1'b0,accumulator}+8'd22;
    wire due=sum>=8'd63;
    // Permit address/strobe setup and only suppress the sampling Phi2 after
    // a Phi1 has been delivered during this asserted bus transaction.
    wire hold_cpu=!as_n && !(uds_n && lds_n) && rom_wait && dtack_n && active_phi1 && phase;
    wire emit=!reset && !freeze && !hold_cpu && !cooldown && (due || debt!=0);
    wire charge=!reset && !freeze && due && !emit;
    wire repay=emit && !due && debt!=0;
    assign phi1=emit && !phase;
    assign phi2=emit && phase;
    always_ff @(posedge clk) begin
        if(reset)begin accumulator<=0;phase<=0;active_phi1<=0;cooldown<=0;debt<=0;overflow<=0;end
        else if(!freeze)begin
            accumulator<=due ? sum-8'd63 : sum;
            if(emit)phase<=~phase;
            cooldown<=emit;
            if(as_n)active_phi1<=0;
            else if(phi1)active_phi1<=1;
            if(charge && !repay)begin if(&debt)overflow<=1;else debt<=debt+1'b1;end
            else if(repay && !charge)debt<=debt-1'b1;
        end
    end
endmodule
