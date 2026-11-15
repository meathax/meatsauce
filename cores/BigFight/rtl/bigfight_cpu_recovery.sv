// Isolated Big Fight FX68K phase-recovery candidate. Not production RTL.
// One qualified wait-repeat pulse represents one full donor S4 wait cycle;
// four root-credit units account for its four-root nominal phase period.
module bigfight_cpu_recovery #(
    parameter integer CREDIT_W = 24,
    parameter integer LEDGER_W = 48
) (
    input  logic clk_sys,
    input  logic phase_reset,
    input  logic cpu_reset,
    input  logic pause,
    input  logic wait_active_i,
    input  logic wait_repeat_i,
    output logic phi1_o,
    output logic phi2_o,
    output logic [CREDIT_W-1:0] credit_o,
    output logic [LEDGER_W-1:0] earned_o,
    output logic [LEDGER_W-1:0] saved_o,
    output logic [LEDGER_W-1:0] forgiven_o,
    output logic overflow_o,
    output logic protocol_fault_o
);

    logic [1:0] phase_q /* verilator public_flat_rd */;
    logic shortened_interval_q;
    logic [CREDIT_W-1:0] credit_q /* verilator public_flat_rd */;
    logic [LEDGER_W-1:0] earned_q /* verilator public_flat_rd */;
    logic [LEDGER_W-1:0] saved_q /* verilator public_flat_rd */;
    logic [LEDGER_W-1:0] forgiven_q /* verilator public_flat_rd */;
    logic overflow_q /* verilator public_flat_rd */;
    logic protocol_fault_q /* verilator public_flat_rd */;

    wire can_shorten = (credit_q != '0) && !wait_active_i && !cpu_reset &&
                       !overflow_q && !( &saved_q );
    wire accepted_wait_repeat = wait_repeat_i && phi1_o && wait_active_i &&
                                !cpu_reset && !pause;
    wire accepted_shortening = shortened_interval_q && phi1_o;

    logic [CREDIT_W:0] credit_plus_four;
    logic [LEDGER_W:0] earned_plus_four;
    logic [LEDGER_W:0] saved_plus_one;
    logic [LEDGER_W:0] forgiven_plus_credit;
    logic [LEDGER_W-1:0] credit_extended;

    always_comb begin
        phi1_o = 1'b0;
        phi2_o = 1'b0;
        if (!phase_reset && !pause) begin
            phi2_o = (phase_q == 2'b01);
            phi1_o = (phase_q == 2'b11) &&
                     (!shortened_interval_q || can_shorten);
        end

        credit_plus_four = {1'b0, credit_q} +
                           {{(CREDIT_W-2){1'b0}}, 3'b100};
        earned_plus_four = {1'b0, earned_q} +
                           {{(LEDGER_W-2){1'b0}}, 3'b100};
        saved_plus_one = {1'b0, saved_q} + {{LEDGER_W{1'b0}}, 1'b1};
        credit_extended = {{(LEDGER_W-CREDIT_W){1'b0}}, credit_q};
        forgiven_plus_credit = {1'b0, forgiven_q} + {1'b0, credit_extended};
    end

    assign credit_o = credit_q;
    assign earned_o = earned_q;
    assign saved_o = saved_q;
    assign forgiven_o = forgiven_q;
    assign overflow_o = overflow_q;
    assign protocol_fault_o = protocol_fault_q;

    // phase_q=00 is followed by the existing 01 (Phi2), 10, 11 (Phi1)
    // sequence. Only the interval after a debt-bearing Phi2 may skip phase 10.
    // A pending short interval is canceled to the nominal spacing if a wait,
    // reset, exhausted debt, or pause intervenes before its Phi1 is emitted.
    always_ff @(posedge clk_sys) begin
        if (phase_reset) begin
            phase_q <= 2'b00;
            shortened_interval_q <= 1'b0;
            credit_q <= '0;
            earned_q <= '0;
            saved_q <= '0;
            forgiven_q <= '0;
            overflow_q <= 1'b0;
            protocol_fault_q <= 1'b0;
        end else begin
            if (!pause) begin
                if (phase_q == 2'b01) begin
                    if (can_shorten) begin
                        phase_q <= 2'b11;
                        shortened_interval_q <= 1'b1;
                    end else begin
                        phase_q <= 2'b10;
                        shortened_interval_q <= 1'b0;
                    end
                end else if ((phase_q == 2'b11) && shortened_interval_q &&
                             !can_shorten) begin
                    // Do not emit a shortened Phi1. Keep it pending for the
                    // following root so this interval remains two roots.
                    phase_q <= 2'b11;
                    shortened_interval_q <= 1'b0;
                end else begin
                    phase_q <= phase_q + 2'b01;
                    shortened_interval_q <= 1'b0;
                end
            end

            if (wait_repeat_i && !accepted_wait_repeat)
                protocol_fault_q <= 1'b1;

            // CPU reset never stops nominal phase generation. It forgives
            // outstanding debt; phase_reset begins a wholly new accounting epoch.
            if (cpu_reset) begin
                credit_q <= '0;
                if (credit_q != '0) begin
                    if (forgiven_plus_credit[LEDGER_W]) begin
                        forgiven_q <= {LEDGER_W{1'b1}};
                        overflow_q <= 1'b1;
                    end else begin
                        forgiven_q <= forgiven_plus_credit[LEDGER_W-1:0];
                    end
                end
            end else if (!pause && !overflow_q && accepted_wait_repeat) begin
                if (credit_plus_four[CREDIT_W] || earned_plus_four[LEDGER_W]) begin
                    overflow_q <= 1'b1;
                end else begin
                    credit_q <= credit_plus_four[CREDIT_W-1:0];
                    earned_q <= earned_plus_four[LEDGER_W-1:0];
                end
            end else if (!pause && !overflow_q && accepted_shortening) begin
                if (saved_plus_one[LEDGER_W]) begin
                    overflow_q <= 1'b1;
                end else begin
                    credit_q <= credit_q - {{(CREDIT_W-1){1'b0}}, 1'b1};
                    saved_q <= saved_plus_one[LEDGER_W-1:0];
                end
            end
        end
    end

endmodule
