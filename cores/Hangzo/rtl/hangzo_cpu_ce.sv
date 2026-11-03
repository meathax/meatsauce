// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from MAD MOTOR/rtl/madmotor_cpu_ce.sv (local source-bound provenance
// in docs/CPU_RECOVERY_GATE.md). 56MHz root / 14MHz nominal pair starts.
// A pair spends an already-earned token. Delay Phi2 during artificial memory
// transport waits; catch up with >=2/1-root phase gaps, never borrowed cycles.
module hangzo_cpu_ce (
    input wire clk, reset, pause, block_phi2,
    output wire phi1, phi2,
    output reg [11:0] credit
`ifdef VERILATOR
    ,output reg [63:0] debug_ticks, debug_pairs, debug_dropped
`endif
);
    reg [1:0] tick_phase, age;
    reg pending_phi2;
    // First nonreset edge can start Phi1, preserving the old divider origin.
    wire tick = tick_phase == 2'd0;
    assign phi1 = !reset && !pause && !pending_phi2 && ((credit != 0) || tick);
    assign phi2 = !reset && !pause && pending_phi2 && (age != 0) && !block_phi2;
    wire [12:0] balance = {1'b0, credit} + (tick ? 13'd1 : 13'd0)
                                           - (phi1 ? 13'd1 : 13'd0);
    always @(posedge clk) begin
        if (reset) begin
            tick_phase <= 0; age <= 0; pending_phi2 <= 0; credit <= 0;
`ifdef VERILATOR
            debug_ticks <= 0; debug_pairs <= 0; debug_dropped <= 0;
`endif
        end else begin
            if (!pause) tick_phase <= tick_phase + 2'd1;
            // Pause deliberately discards old debt, avoiding a resume burst.
            // Every discarded token remains visible in diagnostic accounting.
            if (pause) begin
                credit <= 0;
`ifdef VERILATOR
                debug_dropped <= debug_dropped + {52'd0, credit};
`endif
            end else if (balance > 13'd4095) begin
                credit <= 12'd4095;
`ifdef VERILATOR
                debug_dropped <= debug_dropped + {51'd0, balance} - 64'd4095;
`endif
            end else credit <= balance[11:0];
            if (phi1) begin pending_phi2 <= 1; age <= 0; end
            else begin
                if (phi2) pending_phi2 <= 0;
                if (age != 3) age <= age + 2'd1;
            end
`ifdef VERILATOR
            if (!pause && tick) debug_ticks <= debug_ticks + 64'd1;
            if (phi1) debug_pairs <= debug_pairs + 64'd1;
`endif
        end
    end
endmodule
