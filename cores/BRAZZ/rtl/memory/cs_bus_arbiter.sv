// SPDX-License-Identifier: GPL-3.0-or-later
// Fair, one-outstanding arbitration with response ownership held until reply.
module cs_bus_arbiter #(
    parameter int CLIENTS = 2,
    parameter int PRIORITY_CLIENT = -1,
    parameter int SECOND_PRIORITY_CLIENT = -1,
    parameter int PRIORITY_BURST = 0, // zero preserves legacy strict priority
    parameter bit REGISTER_GRANT = 0, // owned selection before ready/payload fanout
    // PREEMPT_AGE>0: a lock held by a background (non-priority) request that has not been accepted for
    // PREEMPT_AGE clocks (the endpoint holds it, e.g. a read behind queued texture writes) is handed to a
    // waiting priority client (sound/display). The held request stays valid at its client and is granted again
    // afterwards; a request is only preempted before acceptance, never while a response is pending.
    parameter int PREEMPT_AGE = 0,
    parameter int BURST_BITS = PRIORITY_BURST > 0 ? $clog2(PRIORITY_BURST+1) : 1,
    parameter int INDEX_BITS = CLIENTS > 1 ? $clog2(CLIENTS) : 1
) (
    input logic clk, reset,
    input logic [CLIENTS-1:0] client_valid,
    output logic [CLIENTS-1:0] client_ready,
    input logic [CLIENTS-1:0][31:0] client_address, client_data,
    input logic [CLIENTS-1:0][3:0] client_strobe,
    input logic [CLIENTS-1:0] client_write,
    output logic [CLIENTS-1:0] client_rsp_valid,
    output logic [31:0] client_rsp_data,
    output logic client_rsp_error,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error,
    output logic [INDEX_BITS-1:0] req_client,
    output logic [CLIENTS-1:0] req_grant
);
    logic busy, found, grant_locked, last_priority, defer_priority;
    logic [7:0] lock_age;
    logic [BURST_BITS-1:0] priority_count;
    logic [INDEX_BITS-1:0] owner, next_client, locked_client;
    logic [INDEX_BITS-1:0] selected;
    logic [CLIENTS-1:0] grant;
    assign req_grant = grant;
    always_comb begin
        req_valid = 0; req_address = 0; req_data = 0; req_strobe = 0; req_write = 0; req_client = 0;
        client_ready = 0; client_rsp_valid = 0;
        client_rsp_data = rsp_data; client_rsp_error = rsp_error;
        selected = 0; found = 0; grant = 0;
        defer_priority = PRIORITY_BURST > 0 && priority_count >= BURST_BITS'(PRIORITY_BURST);
        if (!busy && grant_locked) begin
            selected = locked_client;
            found = client_valid[locked_client];
        end else if (!busy) begin
            // Lowest valid client is the wrap-around fallback. Prefer the
            // lowest valid index at or above next_client. Only grant selection
            // uses priority; payloads use a parallel one-hot mux below.
            for (int i=CLIENTS-1;i>=0;i=i-1)
                if (client_valid[i] && (!defer_priority || (i!=PRIORITY_CLIENT && i!=SECOND_PRIORITY_CLIENT))) begin selected = INDEX_BITS'(i); found = 1; end
            for (int i=CLIENTS-1;i>=0;i=i-1)
                if (client_valid[i] && (!defer_priority || (i!=PRIORITY_CLIENT && i!=SECOND_PRIORITY_CLIENT)) && INDEX_BITS'(i) >= next_client)
                    selected = INDEX_BITS'(i);
            // Preserve locked requests. Alternate sound/display when both
            // need service; after a bounded burst, grant a background RR turn.
            // If no background request exists, unused bandwidth stays available.
            if (!defer_priority || !found) begin
                for (int i=0;i<CLIENTS;i=i+1)
                    if ((PRIORITY_CLIENT==i || SECOND_PRIORITY_CLIENT==i) && client_valid[i]) begin
                        selected=INDEX_BITS'(i);found=1;
                    end
                for (int i=0;i<CLIENTS;i=i+1)
                    if (((!last_priority && PRIORITY_CLIENT==i) ||
                         (last_priority && SECOND_PRIORITY_CLIENT==i)) && client_valid[i])
                        selected=INDEX_BITS'(i);
            end
        end
        if (!busy && (found || grant_locked) && (!REGISTER_GRANT || grant_locked)) begin
            req_client = selected;
            req_valid = found;
            grant[selected] = 1;
            client_ready[selected] = req_ready;
        end
        for (int i=0;i<CLIENTS;i=i+1) begin
            req_address |= client_address[i] & {32{grant[i]}};
            req_data |= client_data[i] & {32{grant[i]}};
            req_strobe |= client_strobe[i] & {4{grant[i]}};
            req_write |= client_write[i] & grant[i];
        end
        if (busy && rsp_valid) client_rsp_valid[owner] = 1;
    end
    always_ff @(posedge clk) begin
        if (reset) begin busy <= 0; owner <= 0; next_client <= 0; grant_locked <= 0; locked_client <= 0; last_priority <= 0; priority_count <= 0; lock_age <= 0; end
        else begin
            if (busy && rsp_valid) busy <= 0;
            // Lock aging / preemption of a stalled background grant (see PREEMPT_AGE).
            if (!busy && grant_locked && !(req_valid && req_ready)) begin
                if (lock_age != 8'hff) lock_age <= lock_age + 1'b1;
                if (PREEMPT_AGE > 0 && lock_age >= 8'(PREEMPT_AGE) && int'(locked_client) != PRIORITY_CLIENT && int'(locked_client) != SECOND_PRIORITY_CLIENT
                    && PRIORITY_CLIENT >= 0 && SECOND_PRIORITY_CLIENT >= 0
                    && (client_valid[PRIORITY_CLIENT] || client_valid[SECOND_PRIORITY_CLIENT])) begin
                    locked_client <= (client_valid[SECOND_PRIORITY_CLIENT] && (last_priority || !client_valid[PRIORITY_CLIENT]))
                                     ? INDEX_BITS'(SECOND_PRIORITY_CLIENT) : INDEX_BITS'(PRIORITY_CLIENT);
                    lock_age <= 0;
                end
            end else lock_age <= 0;
            // The registered mode captures selection before presenting any ready.
            // Client payload stays owned by that client until real acceptance.
            if (!busy && found && !grant_locked && (REGISTER_GRANT || !req_ready)) begin
                grant_locked <= 1; locked_client <= selected;
            end
            if (req_valid && req_ready) begin
                busy <= 1; owner <= req_client;
                if (int'(req_client)==PRIORITY_CLIENT || int'(req_client)==SECOND_PRIORITY_CLIENT) begin
                    last_priority <= int'(req_client)==PRIORITY_CLIENT;
                    if (PRIORITY_BURST>0 && priority_count<BURST_BITS'(PRIORITY_BURST)) priority_count<=priority_count+1'b1;
                end else priority_count<=0;
                grant_locked <= 0;
                // Critical turns must not reset the background round-robin pointer.
                if(PRIORITY_BURST==0 || (int'(req_client)!=PRIORITY_CLIENT && int'(req_client)!=SECOND_PRIORITY_CLIENT))
                    next_client <= (int'(req_client) + 1 >= CLIENTS) ? '0 : req_client + 1'b1;
            end
        end
    end
endmodule
