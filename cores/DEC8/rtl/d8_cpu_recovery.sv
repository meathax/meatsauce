// SPDX-License-Identifier: GPL-3.0-or-later
// DEC8 whole-cycle CE recovery. All logic remains on clk_sys96.
// jtframe_6809wait demonstrates cycle recovery, but its E/Q half-cycle
// relationship is not the measured DEC8 3/4-Q relationship preserved here.
// turbo (OSD option, default off) is a user overclock: whole cycles use the
// shorter turbo period, latched at a cycle boundary, and the elapsed-time debt
// is held at zero (no catch-up obligation while ahead of the PCB rate).
module d8_cpu_recovery #(
    parameter integer P_DEBT_BITS=32,
    parameter integer P_SYS_MHZ=96
)(
    input wire clk,rst_n,pause,fast_mode,rom_wait,turbo,
    output reg [6:0] phase,period,
    output wire cen_E,cen_Q,begin_cycle,holding,
    output reg [P_DEBT_BITS-1:0] elapsed_debt,
    output wire fault
);
    reg fast_q,turbo_q,mode_fault,overflow_fault;
    localparam [6:0] FAST_PERIOD=P_SYS_MHZ/3;
    localparam [6:0] SLOW_PERIOD=2*P_SYS_MHZ/3;
    // Turbo: 1.5 MHz profiles run at 3 MHz, 3 MHz profiles at 4 MHz. Both
    // periods are already-qualified DEC8 periods (fast nominal / fast catch-up).
    localparam [6:0] TURBO_SLOW=P_SYS_MHZ/3;
    localparam [6:0] TURBO_FAST=P_SYS_MHZ/4;
    wire [6:0] nominal=fast_q?FAST_PERIOD:SLOW_PERIOD;
    wire [6:0] turbo_period=fast_q?TURBO_FAST:TURBO_SLOW;
    wire [6:0] recovery=nominal-(nominal>>2);
    wire [6:0] quarter=period>>2;
    wire [6:0] q_phase=period-quarter-7'd1;
    wire landing=phase==period-7'd1;
    wire overflow_next=!turbo_q&&(&elapsed_debt)&&!landing;
    // Fail closed on the first invalid edge, before sticky fault capture.
    // Board-side RAM/I/O strobes must use this same qualification.
    assign fault=mode_fault||overflow_fault||(rst_n&&((fast_mode!=fast_q)||overflow_next));
    wire active=rst_n&&!pause&&!fault&&(fast_mode==fast_q)&&!overflow_next;
    assign cen_E=active&&landing;
    assign cen_Q=active&&phase==q_phase;
    assign begin_cycle=active&&phase==7'd1;
    assign holding=active&&phase==q_phase-7'd1&&rom_wait;
    wire [P_DEBT_BITS:0] debt_plus={1'b0,elapsed_debt}+1'b1;
    wire [P_DEBT_BITS:0] debt_after=debt_plus-(P_DEBT_BITS+1)'(nominal);
    always @(posedge clk)begin
        if(!rst_n)begin
            fast_q<=fast_mode;turbo_q<=turbo;phase<=0;
            period<=turbo?(fast_mode?TURBO_FAST:TURBO_SLOW):(fast_mode?FAST_PERIOD:SLOW_PERIOD);
            elapsed_debt<=0;mode_fault<=0;overflow_fault<=0;
        end else if(fast_mode!=fast_q)mode_fault<=1;
        else if(!pause&&!fault)begin
            if(overflow_next)overflow_fault<=1;
            else if(landing)begin
                phase<=0;turbo_q<=turbo;
                if(turbo)begin elapsed_debt<=0;period<=turbo_period;end
                else if(turbo_q)begin elapsed_debt<=0;period<=nominal;end
                else begin
                    elapsed_debt<=debt_after[P_DEBT_BITS-1:0];
                    period<=debt_after>=(P_DEBT_BITS+1)'(nominal-recovery)?recovery:nominal;
                end
            end else begin
                elapsed_debt<=turbo_q?{P_DEBT_BITS{1'b0}}:debt_plus[P_DEBT_BITS-1:0];
                if(!holding)phase<=phase+7'd1;
            end
        end
    end
`ifdef SIMULATION
    initial if(P_SYS_MHZ!=48&&P_SYS_MHZ!=96)
        $fatal(1,"CPU_RECOVERY_UNQUALIFIED_MASTER_RATE");
    always @(posedge clk)if(rst_n&&!turbo_q&&cen_E&&debt_plus<(P_DEBT_BITS+1)'(nominal))
        $fatal(1,"CPU_RECOVERY_EXECUTED_AHEAD_OF_NOMINAL_TIME");
`endif
endmodule
