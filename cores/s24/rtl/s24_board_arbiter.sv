import s24_pkg::*;

// Shared 315-5295-style board-device arbiter.  This is intentionally a
// transaction arbiter, not a physical SDRAM controller: the latter remains a
// storage adapter below s24_core.  Independent CPU memory reads bypass this
// module, while writes, I/O, palette, video-register, FDC, and interrupt
// cycles enter here and receive one deterministic grant at a time.
//
// The two request inputs are already captured at a valid 68000 data-strobe
// boundary by s24_cpu_bus.  A round-robin tie break prevents one CPU from
// starving the other; a transaction is held unchanged until completion.
module s24_board_arbiter (
    input  logic                clk,
    input  logic                reset,
    input  board_transaction_t  a_transaction,
    input  board_transaction_t  b_transaction,
    input  logic                a_pending,
    input  logic                b_pending,
    output logic                a_grant,
    output logic                b_grant,
    output board_transaction_t  transaction,
    output logic                transaction_valid,
    input  logic                completion,
    output logic                a_complete,
    output logic                b_complete
);
    logic selected_q;
    logic round_robin_q;
    board_transaction_t active_transaction_q;

    always_comb begin
        transaction = '0;
        if (transaction_valid || a_complete || b_complete)
            transaction = active_transaction_q;
        // The source transaction is captured on grant and remains immutable
        // through wait and completion. Status fields belong to the arbiter
        // and must remain observable at its boundary.
        transaction.valid       = transaction_valid;
        transaction.requester   = selected_q;
        transaction.grant       = transaction_valid;
        transaction.complete    = a_complete | b_complete;
        transaction.phase       = a_complete | b_complete
                                ? BUS_PHASE_COMPLETE
                                : a_grant | b_grant
                                ? BUS_PHASE_GRANTED
                                : transaction_valid
                                ? BUS_PHASE_WAIT : BUS_PHASE_CAPTURE;
        transaction.wait_state  = transaction_valid && !completion;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            selected_q       <= 1'b0;
            round_robin_q    <= 1'b0;
            active_transaction_q <= '0;
            transaction_valid <= 1'b0;
            a_grant          <= 1'b0;
            b_grant          <= 1'b0;
            a_complete       <= 1'b0;
            b_complete       <= 1'b0;
        end else begin
            a_grant    <= 1'b0;
            b_grant    <= 1'b0;
            a_complete <= 1'b0;
            b_complete <= 1'b0;

            if (!transaction_valid) begin
                if (a_pending && b_pending) begin
                    selected_q <= round_robin_q;
                    if (round_robin_q) begin
                        b_grant <= 1'b1;
                        active_transaction_q <= b_transaction;
                    end else begin
                        a_grant <= 1'b1;
                        active_transaction_q <= a_transaction;
                    end
                    round_robin_q <= ~round_robin_q;
                    transaction_valid <= 1'b1;
                end else if (a_pending) begin
                    selected_q <= 1'b0;
                    active_transaction_q <= a_transaction;
                    a_grant <= 1'b1;
                    transaction_valid <= 1'b1;
                end else if (b_pending) begin
                    selected_q <= 1'b1;
                    active_transaction_q <= b_transaction;
                    b_grant <= 1'b1;
                    transaction_valid <= 1'b1;
                end
            end else if (completion) begin
                transaction_valid <= 1'b0;
                if (selected_q) b_complete <= 1'b1;
                else            a_complete <= 1'b1;
            end
        end
    end
endmodule
