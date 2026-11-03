// ah_cpu_ce: 68000 phi1/phi2 clock-enable generator with credit based cycle recovery.
//
// Nominal rate: exactly 12 MHz.  clk = 47.95395 MHz (PLL set for the PCB-measured 60.038 Hz refresh, see
// clock_plan.json), so a "tick" is an exact n/m fractional enable, NUM/DEN = 12 MHz/clk = 240000/959079
// (ticks 3 or 4 clk apart, average 3.996); each tick adds one credit; issuing a phi1 spends one.  When the bus asks for a stall
// (block2: waiting for slow memory, nothing the 68000 can see) phi2 is withheld, credits
// pile up, and after the stall the pairs are replayed at up to one pair every 3 clk
// (15.98 MHz peak, never faster).  Average rate is therefore exactly 12 MHz (ticks == pairs
// + credit + dropped); credit is capped at CMAX so a very long stall cannot cause an
// unbounded burst (the excess is counted in `dropped`).  `pause` freezes the CPU and
// discards credit so there is no burst after un-pausing.
//
// Pulse spacing rules (needed so a registered "block" decision can see the AS the
// previous phi1 created, see docs/lane_A.md):
//   phi1 -> phi2 : at least 2 clk   (pulse in cycle t, next pulse >= t+2)
//   phi2 -> phi1 : at least 1 clk   (adjacent allowed)
// ce1/ce2 are registered single-cycle pulses and never overlap.
module ah_cpu_ce #(
    parameter CMAX = 48,
    parameter [19:0] NUM = 20'd240000,   // 12 MHz      / 5
    parameter [19:0] DEN = 20'd959079    // 47.95395 MHz / 50 (NUM/DEN <= 1/3)
)(
    input  clk,
    input  rst,
    input  pause,
    input  block2,         // withhold the next phi2 (comb, evaluated every cycle)
    output reg ce1,
    output reg ce2,
    output reg [6:0] credit
`ifdef VERILATOR
    ,output reg [31:0] n_ticks, n_pairs, n_drop
`endif
);
reg [19:0] tick_acc;     // fractional tick accumulator (n/m enable, R6)
reg       ph;            // 0: next pulse is phi1, 1: next is phi2
reg [1:0] age;           // clk since ce1 was issued (saturating)
wire [20:0] tick_sum = {1'b0,tick_acc} + {1'b0,NUM};
wire      tick = (tick_sum >= {1'b0,DEN});
wire      avail = (credit != 0) || tick;
wire      issue1 = !pause && !ph && avail;
wire      issue2 = !pause && ph && (age != 0) && !block2;
// credit update (saturating at CMAX)
wire [7:0] credit_n = {1'b0,credit} + (tick ? 8'd1 : 8'd0) - (issue1 ? 8'd1 : 8'd0);

always @(posedge clk) begin
    ce1 <= 1'b0;
    ce2 <= 1'b0;
    if (rst) begin
        tick_acc <= 20'd0;
        ph       <= 1'b0;
        age      <= 2'd0;
        credit   <= 7'd0;
`ifdef VERILATOR
        n_ticks <= 0; n_pairs <= 0; n_drop <= 0;
`endif
    end else begin
        tick_acc <= tick ? tick_sum[19:0] - DEN : tick_sum[19:0];
        if (pause) begin
            credit <= 7'd0;
`ifdef VERILATOR
            n_drop <= n_drop + credit;
`endif
        end else begin
            if (credit_n > CMAX) begin
                credit <= CMAX[6:0];
`ifdef VERILATOR
                n_drop <= n_drop + (credit_n - CMAX);
`endif
            end else
                credit <= credit_n[6:0];
        end
        if (issue1) begin
            ce1 <= 1'b1;
            ph  <= 1'b1;
            age <= 2'd0;
        end else if (issue2) begin
            ce2 <= 1'b1;
            ph  <= 1'b0;
        end else if (age != 2'd3)
            age <= age + 2'd1;
`ifdef VERILATOR
        if (!pause) n_ticks <= n_ticks + (tick ? 1 : 0);
        if (issue1) n_pairs <= n_pairs + 1;
`endif
    end
end
endmodule
