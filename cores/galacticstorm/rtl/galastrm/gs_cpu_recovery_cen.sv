// SPDX-License-Identifier: GPL-3.0-or-later
// Rational CPU enable with bounded SDRAM-stall recovery. Recovery edges are
// confined to the declared maximum rate; phase and debt survive pause and are
// reset together at a new CPU epoch. No generated clock or timing exception.
module gs_cpu_recovery_cen #(
    parameter integer SYS_HZ=64_000_000,
    parameter integer CPU_HZ=16_000_000,
    parameter bit RECOVER_STALLS=1'b0,
    parameter integer MAX_RECOVERY_HZ=32_000_000,
    parameter integer DEBT_WIDTH=32
)(
    input logic clk,reset,pause,
    input logic step_ready,
    // Optional user overclock: deliver every legal spacing edge (MAX_RECOVERY_HZ).
    // The same minimum spacing as stall recovery applies; debt is held.
    input logic turbo,
    output wire nominal_ce,
    output wire recovery_ce,
    output wire advance,
    output logic [DEBT_WIDTH-1:0] debt,
    output logic overflow
);
    function automatic integer frequency_gcd(input integer a,input integer b);
        integer remainder;
        begin
            while(b!=0) begin remainder=a%b;a=b;b=remainder;end
            frequency_gcd=a;
        end
    endfunction

    localparam integer FREQUENCY_GCD=frequency_gcd(SYS_HZ,CPU_HZ);
    localparam integer SYS_UNITS=SYS_HZ/FREQUENCY_GCD;
    localparam integer CPU_UNITS=CPU_HZ/FREQUENCY_GCD;
    localparam integer PHASE_BITS=$clog2(SYS_UNITS)>0 ? $clog2(SYS_UNITS) : 1;
    localparam integer MIN_SPACING=RECOVER_STALLS ?
        ((SYS_HZ+MAX_RECOVERY_HZ-1)/MAX_RECOVERY_HZ) : 1;
    localparam integer AGE_BITS=$clog2(MIN_SPACING+1)>0 ? $clog2(MIN_SPACING+1) : 1;

    logic [PHASE_BITS-1:0] phase;
    logic [AGE_BITS-1:0] spacing_age;
    wire [PHASE_BITS:0] next_phase={1'b0,phase}+(PHASE_BITS+1)'(CPU_UNITS);
    wire nominal_tick=next_phase>=(PHASE_BITS+1)'(SYS_UNITS);
    wire spacing_ok=!RECOVER_STALLS || spacing_age>=AGE_BITS'(MIN_SPACING-1);
    wire nominal_deliver=nominal_tick && step_ready && spacing_ok;
    wire recover_deliver=RECOVER_STALLS && !nominal_tick && (debt!=0) &&
                         step_ready && spacing_ok;
    wire turbo_deliver=RECOVER_STALLS && turbo && step_ready && spacing_ok;
    wire missed_nominal=RECOVER_STALLS && !turbo && !reset && !pause && nominal_tick && !nominal_deliver;

    assign nominal_ce=!reset && !pause && nominal_tick;
    assign recovery_ce=!reset && !pause && !turbo && recover_deliver;
    assign advance=!reset && !pause && step_ready && spacing_ok &&
                   (nominal_tick || recovery_ce || turbo_deliver);

    always_ff @(posedge clk) begin
        if(reset) begin
            phase<=0;
            spacing_age<=AGE_BITS'(MIN_SPACING);
        end else begin
            if(!pause)
                phase<=nominal_tick ? PHASE_BITS'(next_phase-(PHASE_BITS+1)'(SYS_UNITS)) : next_phase[PHASE_BITS-1:0];
            if(advance) spacing_age<=0;
            else if(spacing_age<AGE_BITS'(MIN_SPACING)) spacing_age<=spacing_age+1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            debt<=0;
            overflow<=0;
        end else if(RECOVER_STALLS && !pause) begin
            if(missed_nominal) begin
                if(&debt) overflow<=1;
                else debt<=debt+1'b1;
            end else if(recovery_ce) begin
                if(debt==0) overflow<=1;
                else debt<=debt-1'b1;
            end
        end
    end
endmodule
