// SPDX-License-Identifier: GPL-3.0-or-later
// Frozen R7 candidate. nominal is the existing 5 MHz pulse; freeze is actual
// acknowledged pause. Registered T80 strobes make blocked independent of ce.
module spinal_sound_cpu_recovery(
    input logic clk,reset,freeze,nominal,blocked,
    output wire ce,output logic [15:0] debt=0,output logic overflow=0
);
    logic [2:0] age=3'd7;
    assign ce=!reset && !freeze && !blocked && age==7 && (nominal || debt!=0);
    wire charge=!reset && !freeze && nominal && !ce;
    wire repay=ce && !nominal;
    always_ff @(posedge clk) begin
        if(ce)age<=0;
        else if(age!=7)age<=age+1'b1;
        if(reset)begin debt<=0;overflow<=0;end
        else if(!freeze)begin
            if(charge)begin if(&debt)overflow<=1;else debt<=debt+1'b1;end
            else if(repay)debt<=debt-1'b1;
        end
    end
endmodule
