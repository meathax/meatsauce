// Front-end for the two physical 68000 buses. Memory reads use independent
// CPU-A/CPU-B channels; writes and device cycles are serialized onto the shared
// board-device channel. Interrupt acknowledge cycles are autovectored with VPA
// and never appear on either transaction interface.
module s24_cpu_bus (
    input  logic        clk,
    input  logic        reset,
    input  logic        cpu_phi1,
    input  logic        a_halted_n,

    input  logic        a_as_n,
    input  logic        a_rw_n,
    input  logic        a_uds_n,
    input  logic        a_lds_n,
    input  logic [2:0]  a_fc,
    input  logic [23:1] a_addr,
    input  logic [15:0] a_dout,
    output logic [15:0] a_din,
    output logic        a_dtack_n,

    input  logic        b_as_n,
    input  logic        b_rw_n,
    input  logic        b_uds_n,
    input  logic        b_lds_n,
    input  logic [2:0]  b_fc,
    input  logic [23:1] b_addr,
    input  logic [15:0] b_dout,
    output logic [15:0] b_din,
    output logic        b_dtack_n,

    output logic        bus_req,
    output logic        bus_cpu,
    output logic        bus_rnw,
    output logic [1:0]  bus_be,
    output logic [2:0]  bus_fc,
    output logic [23:0] bus_addr,
    output logic [15:0] bus_dout,
    input  logic [15:0] bus_din,
    input  logic        bus_ack,

    input  logic        has_romboard,
    output logic        a_mem_req,
    output logic [2:0]  a_mem_fc,
    output logic [23:0] a_mem_addr,
    input  logic [15:0] a_mem_din,
    input  logic        a_mem_ack,
    output logic        b_mem_req,
    output logic [2:0]  b_mem_fc,
    output logic [23:0] b_mem_addr,
    input  logic [15:0] b_mem_din,
    input  logic        b_mem_ack
);
    logic a_seen, b_seen, a_pending, b_pending;
    logic a_mem_pending, b_mem_pending;
    logic b_cross_delay;
    logic [2:0] b_cross_clocks;
    logic a_ack, b_ack, active;
    logic a_grant, b_grant, a_complete, b_complete;
    board_transaction_t a_transaction, b_transaction, arb_transaction;
    logic a_rnw_p, b_rnw_p;
    logic [1:0] a_be_p, b_be_p;
    logic [2:0] a_fc_p, b_fc_p;
    logic [23:0] a_addr_p, b_addr_p;
    logic [15:0] a_dout_p, b_dout_p;

    assign a_dtack_n = ~a_ack;
    assign b_dtack_n = ~b_ack;
    assign bus_req = active;
    assign bus_cpu = arb_transaction.requester;
    assign bus_rnw = arb_transaction.read_nwrite;
    assign bus_be = arb_transaction.byte_enable;
    assign bus_fc = arb_transaction.function_code;
    assign bus_addr = arb_transaction.address;
    assign bus_dout = arb_transaction.write_data;
    assign a_mem_req = a_mem_pending;
    assign b_mem_req = b_mem_pending;
    assign a_mem_fc = a_fc_p;
    assign b_mem_fc = b_fc_p;
    assign a_mem_addr = a_addr_p;
    assign b_mem_addr = b_addr_p;

    always_comb begin
        a_transaction = '0;
        a_transaction.valid         = a_pending;
        a_transaction.requester     = 1'b0;
        a_transaction.address       = a_addr_p;
        a_transaction.byte_enable   = a_be_p;
        a_transaction.read_nwrite   = a_rnw_p;
        a_transaction.function_code = a_fc_p;
        a_transaction.write_data    = a_dout_p;
        a_transaction.phase         = BUS_PHASE_CAPTURE;

        b_transaction = '0;
        b_transaction.valid         = b_pending;
        b_transaction.requester     = 1'b1;
        b_transaction.address       = b_addr_p;
        b_transaction.byte_enable   = b_be_p;
        b_transaction.read_nwrite   = b_rnw_p;
        b_transaction.function_code = b_fc_p;
        b_transaction.write_data    = b_dout_p;
        b_transaction.phase         = BUS_PHASE_CAPTURE;
    end

    s24_board_arbiter board_arbiter(
        .clk(clk),.reset(reset),
        .a_transaction(a_transaction),.b_transaction(b_transaction),
        .a_pending(a_pending),.b_pending(b_pending),
        .a_grant(a_grant),.b_grant(b_grant),
        .transaction(arb_transaction),.transaction_valid(active),
        .completion(bus_ack),.a_complete(a_complete),.b_complete(b_complete));

    function automatic logic is_independent_memory(input logic [23:0] addr);
        if (addr < 24'h200000)
            is_independent_memory = 1'b1;
        else if (addr >= 24'hf00000)
            is_independent_memory = 1'b1;
        else if (addr[23:21] == 3'b001 && addr[19])
            is_independent_memory = 1'b1; // character RAM
        else if ((addr & 24'he40000) == 24'h600000)
            is_independent_memory = 1'b1; // sprite RAM and mirrors
        else if (((addr >= 24'hb80000 && addr <= 24'hbbffff) ||
                  (addr >= 24'hc80000 && addr <= 24'hcbffff)) &&
                 has_romboard)
            is_independent_memory = 1'b1;
        else
            is_independent_memory = 1'b0;
    endfunction

    always_ff @(posedge clk) begin
        if (reset) begin
            a_seen <= 0; b_seen <= 0; a_pending <= 0; b_pending <= 0;
            a_mem_pending <= 0; b_mem_pending <= 0;
            b_cross_delay <= 0; b_cross_clocks <= 0;
            a_ack <= 0; b_ack <= 0;
            a_din <= 16'hffff; b_din <= 16'hffff;
            a_rnw_p <= 0; b_rnw_p <= 0; a_be_p <= 0; b_be_p <= 0;
            a_fc_p <= 0; b_fc_p <= 0; a_addr_p <= 0; b_addr_p <= 0;
            a_dout_p <= 0; b_dout_p <= 0;
        end else begin
            if (a_as_n) begin a_seen <= 0; a_ack <= 0; end
            else if (a_ack && a_uds_n && a_lds_n) begin
                // fx68k keeps AS asserted between the read and write halves
                // of TAS/read-modify-write, but releases both byte strobes.
                // Retire the completed read here so the following write half
                // is accepted as a new transaction under the same AS pulse.
                a_seen <= 0;
                a_ack <= 0;
            end
            if (b_as_n) begin b_seen <= 0; b_ack <= 0; end
            else if (b_ack && b_uds_n && b_lds_n) begin
                b_seen <= 0;
                b_ack <= 0;
            end

            if (b_cross_delay && cpu_phi1) begin
                if (b_cross_clocks == 3'd1) begin
                    b_cross_delay <= 1'b0;
                    b_cross_clocks <= 0;
                    b_ack <= 1'b1;
                end else begin
                    b_cross_clocks <= b_cross_clocks - 1'b1;
                end
            end

            // fx68k asserts AS before the data strobes settle.  Capture only
            // once at least one active-low byte strobe is valid; sampling on
            // AS alone turns every write into a zero-byte transaction.
            if (!a_as_n && (!a_uds_n || !a_lds_n) && !a_seen
                    && a_fc != 3'b111) begin
                a_seen <= 1'b1;
                if (a_rw_n && is_independent_memory({a_addr,1'b0}))
                    a_mem_pending <= 1'b1;
                else
                    a_pending <= 1'b1;
                a_rnw_p <= a_rw_n;
                a_be_p <= {~a_uds_n,~a_lds_n};
                a_fc_p <= a_fc;
                a_addr_p <= {a_addr,1'b0};
                a_dout_p <= a_dout;
            end
            if (!b_as_n && (!b_uds_n || !b_lds_n) && !b_seen
                    && b_fc != 3'b111) begin
                b_seen <= 1'b1;
                if (b_rw_n && is_independent_memory({b_addr,1'b0}))
                    b_mem_pending <= 1'b1;
                else
                    b_pending <= 1'b1;
                b_rnw_p <= b_rw_n;
                b_be_p <= {~b_uds_n,~b_lds_n};
                b_fc_p <= b_fc;
                b_addr_p <= {b_addr,1'b0};
                b_dout_p <= b_dout;
            end

            // The dedicated arbiter owns grant/completion ordering.  The
            // front-end retains only the 68000 AS/data-strobe phase and
            // read-modify-write retirement rules.
            if (a_grant) a_pending <= 1'b0;
            if (b_grant) b_pending <= 1'b0;
            if (a_complete) begin a_din <= bus_din; a_ack <= 1'b1; end
            if (b_complete) begin
                b_din <= bus_din;
                if (b_addr_p[23:20] == 4'ha && a_halted_n) begin
                    b_cross_delay <= 1'b1;
                    b_cross_clocks <= 3'd4;
                end else begin
                    b_ack <= 1'b1;
                end
            end

            if (a_mem_pending && a_mem_ack) begin
                a_mem_pending <= 1'b0;
                a_din <= a_mem_din;
                a_ack <= 1'b1;
            end
            if (b_mem_pending && b_mem_ack) begin
                b_mem_pending <= 1'b0;
                b_din <= b_mem_din;
                b_ack <= 1'b1;
            end
        end
    end
endmodule
