// SPDX-License-Identifier: GPL-3.0-or-later
module argus_clock_enables #(
    parameter int unsigned SYS_HZ = 54_000_000
)(
    input  logic clk_sys,
    input  logic reset,
    input  logic pause_game,
    input  logic [1:0] game_id,
    input  logic [1:0] timing_profile,
    output logic ce_main,
    output logic ce_sound_cpu,
    output logic ce_opn
);
    logic [31:0] cpu_phase, opn_phase;
    logic [32:0] cpu_sum, opn_sum;
    logic [31:0] cpu_hz;
    // Profile 1 is an explicit Argus hardware candidate, not a release default.
    always_comb begin
        cpu_hz = (game_id == 2'd0 && timing_profile == 2'd1) ? 32'd4_000_000 : 32'd5_000_000;
        cpu_sum = {1'b0, cpu_phase} + {1'b0, cpu_hz};
        opn_sum = {1'b0, opn_phase} + 33'd1_500_000;
    end
    always_ff @(posedge clk_sys) begin
        ce_main <= 1'b0;
        ce_sound_cpu <= 1'b0;
        ce_opn <= 1'b0;
        if (reset) begin
            cpu_phase <= 32'd0;
            opn_phase <= 32'd0;
        end else if (!pause_game && game_id != 2'd3 && !timing_profile[1]) begin
            if (cpu_sum >= 33'(SYS_HZ)) begin
                cpu_phase <= 32'(cpu_sum - 33'(SYS_HZ));
                ce_main <= 1'b1;
                ce_sound_cpu <= 1'b1;
            end else cpu_phase <= cpu_sum[31:0];
            if (opn_sum >= 33'(SYS_HZ)) begin
                opn_phase <= 32'(opn_sum - 33'(SYS_HZ));
                ce_opn <= 1'b1;
            end else opn_phase <= opn_sum[31:0];
        end
    end
endmodule
