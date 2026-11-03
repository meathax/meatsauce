// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone candidate: integer /6 nominal CPU cycles with bounded stall debt.
// No integration is implied. Existing CPU wrappers still use their old producer.
// Independently implemented from the clock-plan R7 accounting contract; no donor
// clock ratio, PLL phase or exception is used. All outputs are clock enables.
// Normal half-cycle spacing is3/3; debt repayment allows2/1 (pair period>=3).
module thunderjaws_cpu_clock #(
    parameter integer NOMINAL_DIVIDER=6,
    parameter integer MAX_CREDITS=48
)(
    input wire clk_sys,init_reset,cpu_reset,pause_safe,block_phi2,
    output wire phi1,phi2,nominal_tick,
    output reg [6:0] credits,
    output reg overflow_sticky,
    output reg [31:0] tick_count,pair_count,dropped_count,pause_discard_count,
    output reg [6:0] reset_discard_credits,
    output reg aborted_half_pair
);
    localparam integer DIV_W=$clog2(NOMINAL_DIVIDER);
    localparam integer AGE_W=$clog2(NOMINAL_DIVIDER+1);
    reg [DIV_W-1:0] tick_phase;
    reg next_phi2;
    reg [AGE_W-1:0] half_age,half_threshold;
    reg [1:0] since_phi1;
    wire enabled=!init_reset && !cpu_reset && !pause_safe;
    assign nominal_tick=enabled && tick_phase==0;
    assign phi1=enabled && !next_phi2 && since_phi1>=2 && (credits!=0 || nominal_tick);
    assign phi2=enabled && next_phi2 && half_age>=half_threshold && !block_phi2;
    wire [7:0] credit_next={1'b0,credits}+{7'b0,nominal_tick}-{7'b0,phi1};

    // Nominal phase is independent of logical CPU reset. Safe pause excludes
    // paused time; initial reset starts a new global clock/measurement epoch.
    always @(posedge clk_sys)begin
        if(init_reset)tick_phase<=0;
        else if(!pause_safe)tick_phase<=tick_phase==NOMINAL_DIVIDER-1 ? 0 : tick_phase+1'b1;
        if(init_reset)since_phi1<=2;
        else if(phi1)since_phi1<=0;
        else if(since_phi1!=3)since_phi1<=since_phi1+1'b1;
    end
    always @(posedge clk_sys)begin
        reset_discard_credits<=0;aborted_half_pair<=0;
        if(init_reset)begin
            credits<=0;next_phi2<=0;half_age<=0;half_threshold<=NOMINAL_DIVIDER/2-1;
            tick_count<=0;pair_count<=0;dropped_count<=0;pause_discard_count<=0;overflow_sticky<=0;
        end else if(cpu_reset)begin
            reset_discard_credits<=credits;
            aborted_half_pair<=next_phi2;
            credits<=0;next_phi2<=0;half_age<=0;half_threshold<=NOMINAL_DIVIDER/2-1;
            tick_count<=0;pair_count<=0;dropped_count<=0;pause_discard_count<=0;overflow_sticky<=0;
        end else if(pause_safe)begin
            // Paused time earns nothing. Retain already earned debt and the
            // paid half-pair so resume cannot lose work or rebase its phase.
            credits<=credits;
        end else begin
            if(nominal_tick)tick_count<=tick_count+1'b1;
            if(phi1)pair_count<=pair_count+1'b1;
            if(credit_next>MAX_CREDITS)begin
                credits<=MAX_CREDITS;
                dropped_count<=dropped_count+1'b1;overflow_sticky<=1;
            end else credits<=credit_next[6:0];
            if(phi1)begin
                next_phi2<=1;half_age<=0;
                half_threshold<=credits!=0 ? 1 : NOMINAL_DIVIDER/2-1;
            end else if(phi2)next_phi2<=0;
            else if(half_age<NOMINAL_DIVIDER)half_age<=half_age+1'b1;
        end
    end
endmodule
