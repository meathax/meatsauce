/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Derived from the source-reviewed jtframe_68kdtack_cen helper retained in
 * fx68k-adapter-provenance.json. Local changes: explicit run/freeze, parameters,
 * exported accounting, no unused frequency-report logic. No timing exceptions.
 */
module gs_fx68k_cen #(
    parameter integer SYS_HZ=64000000, CPU_HZ=15238090,
    parameter integer DEBT_BITS=24
)(
    input wire clk,reset,run,
    input wire as_n,input wire [1:0] ds_n,
    input wire busy,legitimate,retire_ready,
    output wire phi1,phi2,next_phi1,idle_no_debt,
    output reg dtack_n,
    output reg [DEBT_BITS-1:0] debt,
    output wire earned,repaid,nominal,
    output reg overflow
);
    function automatic integer gcd(input integer a,b);
        integer t;begin while(b!=0)begin t=a%b;a=b;b=t;end gcd=a;end
    endfunction
    localparam integer G=gcd(SYS_HZ,CPU_HZ);
    localparam integer DEN=SYS_HZ/G,STEP=2*(CPU_HZ/G);
    localparam integer W=$clog2(DEN+1);
    reg [W:0] count=0;
    reg phase=0,active_phi1=0;
    reg gap_seen=0;
    wire selected=!as_n && !(&ds_n);
    // S2 setup must complete before holding the S4 DTACK sampling Phi2.
    wire hold_cpu=selected && dtack_n && active_phi1 && !phase && !legitimate;
    assign nominal=count>(W+1)'(DEN-STEP);
    // A completed non-IACK response may repay older external-memory debt.
    // Legitimate device waits still earn no credit and retain nominal phases.
    wire recover=debt!=0 && !nominal && !hold_cpu && (!legitimate || retire_ready);
    wire emit=run && !reset && !hold_cpu && (nominal || recover);
    assign phi1=emit && phase;
    assign phi2=emit && !phase;
    assign next_phi1=phase;
    assign earned=run && !reset && nominal && hold_cpu;
    assign repaid=run && !reset && recover;
    assign idle_no_debt=debt==0 && as_n && (&ds_n);
    always @(posedge clk)begin
        if(reset)begin
            count<=0;phase<=0;debt<=0;active_phi1<=0;
            dtack_n<=1;gap_seen<=0;overflow<=0;
        end else if(run)begin
            count<=nominal ? count+(W+1)'(STEP)-(W+1)'(DEN) : count+(W+1)'(STEP);
            if(emit)phase<=!phase;
            if(earned)begin
                if(&debt)overflow<=1;
                else debt<=debt+1'b1;
            end
            if(repaid)debt<=debt-1'b1;
            if(as_n)active_phi1<=0;
            else if(phi1)active_phi1<=1;
            // A full data-strobe gap re-arms DTACK, including TAS with AS low.
            if(!selected)begin dtack_n<=1;gap_seen<=1;end
            else if(gap_seen)dtack_n<=dtack_n && busy;
        end
    end
endmodule
