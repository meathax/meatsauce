// SPDX-License-Identifier: GPL-3.0-or-later
// Root / NOMINAL_DIV nominal 68000. Borrow only already-earned CPU cycles.
// Hold Phi2 at an artificial memory wait; never insert extra CPU wait states.
// A started pair costs one token, earned once per NOMINAL_DIV unpaused roots.
// Phi1->Phi2 >=2 roots; Phi2->Phi1 >=1 root; fastest pair period3 roots.
// Concept/reference: shared lesson21208, AH token-bucket experiment. This
// implementation uses directly consumed synchronous enables and exact pause.
module madmotor_cpu_ce #(
    parameter integer CREDIT_MAX=4095,
    parameter integer NOMINAL_DIV=4,
    parameter integer BANDIT_DIV=6
)(
    input tri0 bandit,
    input wire clk,reset,pause,block_phi2,
    output wire phi1,phi2,
    output reg [11:0] credit
`ifdef VERILATOR
    ,output reg [31:0] debug_ticks,debug_pairs,debug_dropped
`endif
);
    localparam integer TICK_WIDTH=$clog2(NOMINAL_DIV>BANDIT_DIV?NOMINAL_DIV:BANDIT_DIV);
    reg [TICK_WIDTH-1:0] tick_phase;
    reg [1:0] age;
    reg pending_phi2;
    wire tick=tick_phase==TICK_WIDTH'((bandit?BANDIT_DIV:NOMINAL_DIV)-1);
    assign phi1=!reset&&!pause&&!pending_phi2&&((credit!=0)||tick);
    assign phi2=!reset&&!pause&&pending_phi2&&(age!=0)&&!block_phi2;
    wire [12:0] balance={1'b0,credit}+(tick?13'd1:13'd0)-(phi1?13'd1:13'd0);
    always @(posedge clk)begin
        if(reset)begin
            tick_phase<=0;age<=0;pending_phi2<=0;credit<=0;
`ifdef VERILATOR
            debug_ticks<=0;debug_pairs<=0;debug_dropped<=0;
`endif
        end else begin
            tick_phase<=tick?{TICK_WIDTH{1'b0}}:tick_phase+1'b1;
            if(pause)begin
                credit<=0;
`ifdef VERILATOR
                debug_dropped<=debug_dropped+32'(credit);
`endif
            end else if(balance>CREDIT_MAX)begin
                credit<=12'(CREDIT_MAX);
`ifdef VERILATOR
                debug_dropped<=debug_dropped+32'(balance-CREDIT_MAX);
`endif
            end else credit<=balance[11:0];
            if(phi1)begin pending_phi2<=1;age<=0;end
            else begin
                if(phi2)pending_phi2<=0;
                if(age!=3)age<=age+2'd1;
            end
`ifdef VERILATOR
            if(!pause&&tick)debug_ticks<=debug_ticks+32'd1;
            if(phi1)debug_pairs<=debug_pairs+32'd1;
`endif
        end
    end
endmodule
