// SPDX-License-Identifier: GPL-3.0-or-later
// Physical CPU-cycle accounting for a faster microcoded execution engine.
// Costs advance a virtual deadline; CPU ticks consume elapsed cycle units.
// The first cost seeds an epoch after this edge's tick. In-flight memory stalls
// may earn credit; pause freezes it. Restart is for reset/quiescent epoch changes,
// not a way to forgive an instruction's unpaid cost. The controller must enforce
// that ownership contract. Production Core uses this single ledger owner.
// Rebase is a distinct charged-event operation: after old work is paid it seeds
// a fresh deadline, preventing historical credit from shortening event response.
module PhysicalCycleBudget #(
 parameter integer BALANCE_BITS=32,
 parameter integer PARALLEL_COSTS=0,
 parameter integer LATE_COSTS=0,
 parameter integer PARALLEL_EVENTS=0,
 // Record the charge event on its edge and apply it on the next edge from
 // registered operands. The late dispatch decision then reaches only event
 // flops, not the ledger arithmetic. Ledger values are identical from two
 // edges after every event; can_issue is held low for the one edge between.
 parameter integer DEFER_CHARGE=0
)(
 input wire clk, reset, restart, run, ce_cpu, rebase,
 input wire cost_valid,
 input wire [11:0] cost_cycles,
 output wire can_issue,
 output reg fault=0,
 output reg armed=0,
 output wire pending,
 output reg signed [BALANCE_BITS-1:0] balance=0,
 input wire [11:0] alternate_cost_cycles,
 input wire select_alternate_cost,
 input wire [4:0] late_cost_cycles,
 input wire [11:0] rep_cost_cycles, interrupt_cost_cycles,
 // Event mode: 0/1 instruction, 2 REP, 3 IRQ; cost_valid=0 selects no charge.
 input wire [1:0] select_event
);
localparam integer MIN_CALC_BITS=(LATE_COSTS || PARALLEL_EVENTS)?14:13;
localparam integer CALC_BITS=(BALANCE_BITS+1>MIN_CALC_BITS)?BALANCE_BITS+1:MIN_CALC_BITS;
localparam signed [63:0] MAX_BALANCE=(64'sd1 << (BALANCE_BITS-1))-1;
localparam signed [63:0] MIN_BALANCE=-(64'sd1 << (BALANCE_BITS-1));
// Keep both completed sums so a late branch decision selects the result,
// rather than feeding through the instruction decoder and ledger arithmetic.
(* keep *) reg signed [CALC_BITS-1:0] candidate;
(* keep *) reg signed [CALC_BITS-1:0] alternate_candidate;
wire use_alternate=PARALLEL_COSTS ? select_alternate_cost : 1'b0;
wire [4:0] late_cost=(LATE_COSTS && cost_valid) ? late_cost_cycles : 5'd0;
wire [12:0] selected_cost;
wire candidate_overflow,alternate_overflow;
wire selected_overflow=use_alternate ? alternate_overflow : candidate_overflow;
wire [2:0] event_lane=PARALLEL_EVENTS ?
 (!cost_valid ? 3'd0 : select_event==2'd3 ? 3'd4 : select_event==2'd2 ? 3'd3 : use_alternate ? 3'd2 : 3'd1) :
 {2'd0,use_alternate};
// Deferred event record (unused when DEFER_CHARGE=0).
reg p_valid=0,p_rebase=0;
reg [2:0] p_lane=0;
reg [11:0] p_cost=0,p_alternate=0,p_rep=0,p_interrupt=0;
reg [4:0] p_late=0;
assign pending=DEFER_CHARGE ? p_valid : 1'b0;
assign can_issue=run && !fault && !pending && (!armed || balance<=0);
genvar lane;
generate if (!LATE_COSTS && !PARALLEL_EVENTS) begin: ordinary_cost
assign selected_cost={1'b0,(use_alternate ? alternate_cost_cycles : cost_cycles)};
assign candidate_overflow=candidate>MAX_BALANCE || candidate<MIN_BALANCE;
assign alternate_overflow=alternate_candidate>MAX_BALANCE || alternate_candidate<MIN_BALANCE;
always @* begin
 candidate={{(CALC_BITS-BALANCE_BITS){balance[BALANCE_BITS-1]}},balance};
 if (cost_valid) candidate=candidate+$signed({1'b0,cost_cycles});
 if (ce_cpu) candidate=candidate-1'b1;
 alternate_candidate={{(CALC_BITS-BALANCE_BITS){balance[BALANCE_BITS-1]}},balance};
 if (cost_valid) alternate_candidate=alternate_candidate+$signed({1'b0,alternate_cost_cycles});
 if (ce_cpu) alternate_candidate=alternate_candidate-1'b1;
end
end else begin: late_cost_select
// The late five-bit charge must not traverse the full-width ledger carry.
// Compute all high-half carry cases directly from the early operands. The
// carry-one form A-~B avoids a second serial increment (shared lesson 6134).
localparam integer HIGH_BITS=CALC_BITS-5;
localparam integer LANES=PARALLEL_EVENTS?5:2;
localparam signed [63:0] MAX_HIGH=MAX_BALANCE >>> 5;
localparam signed [63:0] MIN_HIGH=MIN_BALANCE >>> 5;
initial if (BALANCE_BITS<6) $fatal(1,"Late cost requires BALANCE_BITS >= 6");
wire signed [CALC_BITS-1:0] result [0:LANES-1];
wire overflow [0:LANES-1];
wire [12:0] seed_cost [0:LANES-1];
wire [2:0] selected_lane=DEFER_CHARGE ? p_lane : event_lane;
wire [11:0] op_cost=DEFER_CHARGE ? p_cost : cost_cycles;
wire [11:0] op_alternate=DEFER_CHARGE ? p_alternate : alternate_cost_cycles;
wire [11:0] op_rep=DEFER_CHARGE ? p_rep : rep_cost_cycles;
wire [11:0] op_interrupt=DEFER_CHARGE ? p_interrupt : interrupt_cost_cycles;
wire [4:0] op_late=DEFER_CHARGE ? p_late : late_cost_cycles;
initial if (DEFER_CHARGE && !(LATE_COSTS && PARALLEL_EVENTS)) $fatal(1,"Deferred charge uses the late-cost event bank");
for(lane=0;lane<LANES;lane=lane+1) begin: cost_lane
 // Event/valid decisions must never feed these early arithmetic operands.
 wire [11:0] early_cost=PARALLEL_EVENTS ?
  (lane==0 ? 12'd0 : lane==1 ? op_cost : lane==2 ? op_alternate : lane==3 ? op_rep : op_interrupt) :
  (lane==0 ? cost_cycles : alternate_cost_cycles);
 wire [11:0] charged_cost=PARALLEL_EVENTS ? early_cost : (cost_valid ? early_cost : 12'd0);
 wire [4:0] lane_late=PARALLEL_EVENTS ?
  ((LATE_COSTS && (lane==1 || lane==2)) ? op_late : 5'd0) : late_cost;
 wire signed [13:0] charge=$signed({2'b0,charged_cost})-(ce_cpu ? 14'sd1 : 14'sd0);
 wire signed [HIGH_BITS-1:0] high_balance=$signed(balance) >>> 5;
 wire signed [HIGH_BITS-1:0] high_charge=$signed(charge) >>> 5;
 wire signed [HIGH_BITS-1:0] high_charge_one=high_charge+1'b1;
 (* keep *) wire signed [HIGH_BITS-1:0] high_zero=high_balance+high_charge;
 (* keep *) wire signed [HIGH_BITS-1:0] high_one=high_balance-(~high_charge);
 (* keep *) wire signed [HIGH_BITS-1:0] high_two=high_balance-(~high_charge_one);
 (* keep *) wire overflow_zero=high_zero>MAX_HIGH || high_zero<MIN_HIGH;
 (* keep *) wire overflow_one=high_one>MAX_HIGH || high_one<MIN_HIGH;
 (* keep *) wire overflow_two=high_two>MAX_HIGH || high_two<MIN_HIGH;
 (* keep *) wire [5:0] early_low={1'b0,balance[4:0]}+{1'b0,charge[4:0]};
 wire [6:0] final_low={1'b0,early_low}+{2'b0,lane_late};
 wire signed [HIGH_BITS-1:0] final_high=final_low[6] ? high_two : final_low[5] ? high_one : high_zero;
 assign result[lane]={final_high,final_low[4:0]};
 assign overflow[lane]=final_low[6] ? overflow_two : final_low[5] ? overflow_one : overflow_zero;
 // First-charge/rebase seeds also select a finished sum, independent of the
 // late event decision. The count only adds five bits and selects a high half.
 wire [5:0] seed_low={1'b0,early_cost[4:0]}+{1'b0,lane_late};
 (* keep *) wire [7:0] seed_high_zero={1'b0,early_cost[11:5]};
 (* keep *) wire [7:0] seed_high_one=seed_high_zero+1'b1;
 assign seed_cost[lane]={seed_low[5] ? seed_high_one : seed_high_zero,seed_low[4:0]};
end
always @* begin
 candidate=result[selected_lane];
 alternate_candidate=result[selected_lane];
end
assign candidate_overflow=overflow[selected_lane];
assign alternate_overflow=overflow[selected_lane];
assign selected_cost=seed_cost[selected_lane];
end endgenerate
generate if (!DEFER_CHARGE) begin: immediate_charge
always @(posedge clk) begin
 if (reset || restart) begin
  balance<=0; armed<=0; fault<=0;
 end else if (!run) begin
  if (cost_valid || rebase) fault<=1; // A paused engine must not dispatch work.
 end else if (!fault) begin
  if(rebase) begin
   // A newly accepted external event cannot spend historical stall credit.
   // Its owner must have paid all old work and charge this new epoch now.
   if(!cost_valid || (armed && balance>0) || {1'b0,selected_cost}>MAX_BALANCE) fault<=1;
   else begin balance<=selected_cost; armed<=1; end
  end else if (!armed) begin
   if (cost_valid) begin
    if ({1'b0,selected_cost}>MAX_BALANCE) fault<=1;
    else begin balance<=selected_cost; armed<=1; end
   end
  end else if (selected_overflow) begin
   fault<=1; // Never wrap a missed deadline into permission to issue.
  end else balance<=use_alternate ? alternate_candidate[BALANCE_BITS-1:0] : candidate[BALANCE_BITS-1:0];
 end
end
end else begin: deferred_charge
wire [BALANCE_BITS-1:0] idle_next=balance-{{(BALANCE_BITS-1){1'b0}},ce_cpu};
wire idle_overflow=ce_cpu && ($signed(balance)==MIN_BALANCE);
always @(posedge clk) begin
 if (reset || restart) begin
  balance<=0; armed<=0; fault<=0; p_valid<=0; p_rebase<=0;
 end else if (!run) begin
  p_valid<=0;
  if (cost_valid || rebase) fault<=1; // A paused engine must not dispatch work.
 end else if (!fault) begin
  if (p_valid) begin
   p_valid<=0;
   // Admission is held low while an event is pending, so no owner may charge now.
   if (cost_valid || rebase) fault<=1;
   else if (p_rebase || !armed) begin
    // The seed follows this edge's tick, exactly as an immediate seed followed the next one.
    if ({1'b0,selected_cost}>MAX_BALANCE) fault<=1;
    else begin balance<=$signed({1'b0,selected_cost})-$signed({{(BALANCE_BITS){1'b0}},ce_cpu}); armed<=1; end
   end else if (candidate_overflow) fault<=1;
   else balance<=candidate[BALANCE_BITS-1:0];
  end else begin
   if (armed) begin
    if (idle_overflow) fault<=1;
    else balance<=idle_next;
   end
   if (rebase) begin
    if (!cost_valid || (armed && balance>0)) fault<=1;
    else begin
     p_valid<=1; p_rebase<=1; p_lane<=event_lane;
     p_cost<=cost_cycles; p_alternate<=alternate_cost_cycles; p_rep<=rep_cost_cycles;
     p_interrupt<=interrupt_cost_cycles; p_late<=late_cost_cycles;
    end
   end else if (cost_valid) begin
    p_valid<=1; p_rebase<=0; p_lane<=event_lane;
    p_cost<=cost_cycles; p_alternate<=alternate_cost_cycles; p_rep<=rep_cost_cycles;
    p_interrupt<=interrupt_cost_cycles; p_late<=late_cost_cycles;
   end
  end
 end
end
end endgenerate
endmodule
