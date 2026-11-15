// Lossless key17 candidate: known XOR-folded set recovers the omitted low6 tag bits.
// 2026-10-22 area repair: tag and LRU-rank storage move from register files to
// per-way MLAB (bigfight_mlab_dp, async read). Every read used below happens at
// least one full cycle after any write to the same set (writes occur only on
// edges that enter ST_HOLD_REPLY), which is the MLAB read contract.
// SPDX-License-Identifier: GPL-3.0-only
// Isolated SA4 storage-inference candidate; control/LRU match cache_sa4_256.sv.
// Compile this source instead of rtl/bigfight_rom_cache64.sv, never alongside it.
// Shared cold_reset must also cancel or flush the ROM backend transaction.
`timescale 1ns/1ps
module bigfight_rom_cache64 #(
    // 2026-10-23: per-instance set count (default 64 sets x 4 ways); the
    // sprite-pixel client uses the larger scene-qualified working set.
    parameter integer SET_BITS = 6
) (
    input  logic clk_sys,
    input  logic cold_reset,

    input  logic        client_req_valid_i,
    output logic        client_req_ready_o,
    input  logic [25:0] client_req_address_i,
    output logic        client_rsp_valid_o,
    input  logic        client_rsp_ready_i,
    output logic [63:0] client_rsp_data_o,

    output logic        rom_req_valid_o,
    input  logic        rom_req_ready_i,
    output logic [25:0] rom_req_address_o,
    input  logic        rom_rsp_valid_i,
    output logic        rom_rsp_ready_o,
    input  logic [63:0] rom_rsp_data_i
);
    localparam integer TAG_W = 23 - SET_BITS;   // stored tag; low SET_BITS recovered from the folded set
    localparam integer WAY_BITS = 2;
    localparam integer SET_COUNT = 1 << SET_BITS;
    localparam integer WAY_COUNT = 1 << WAY_BITS;
    localparam integer ENTRY_COUNT = SET_COUNT * WAY_COUNT;

    localparam logic [2:0] ST_IDLE       = 3'd0;
    localparam logic [2:0] ST_SEND_ROM   = 3'd1;
    localparam logic [2:0] ST_WAIT_ROM   = 3'd2;
    localparam logic [2:0] ST_HOLD_REPLY = 3'd3;

    localparam logic [2:0] ST_INIT=3'd4, ST_INIT_DRAIN=3'd5;
    logic [2:0] state_q;

    // Data is not reset. The accepted hit reads this array synchronously;
    // misses write it only when the matching backend reply is accepted.
    (* ramstyle = "M10K" *) logic [63:0] data_ram [0:ENTRY_COUNT-1];

    // A bounded reset sweep clears stale MLAB validity before admission.
    // The first fill initializes all four per-way valid flags atomically;
    // later fills/hits retain the original cycle/ordering/LRU contract.
    logic [SET_BITS-1:0] clear_set_q;
    wire [WAY_COUNT-1:0] way_valid;
    wire initialize_set;
    wire [TAG_W-1:0] tag_q [0:WAY_COUNT-1];       // tag of {rd_set, way}
    wire [1:0]  lru_q [0:WAY_COUNT-1];            // rank of {rd_set, way}
    logic [TAG_W+2:0] metadata_q [0:WAY_COUNT-1];
    logic [TAG_W+2:0] metadata_wdata [0:WAY_COUNT-1];
    logic [WAY_COUNT-1:0] metadata_we;
    logic [WAY_COUNT-1:0] tag_we, lru_we;
    logic [1:0]  lru_wdata [0:WAY_COUNT-1];
    logic [SET_BITS-1:0] rd_set;

    logic [22:0] request_tag;
    logic [SET_BITS-1:0] request_set;
    logic request_hit;
    logic [WAY_COUNT-1:0] request_hit_mask;
    logic [1:0] request_hit_way;
    logic [SET_BITS+1:0] request_hit_index;
    logic request_invalid_found;
    logic [1:0] request_first_invalid_way;
    logic request_lru_found;
    logic [1:0] request_lru_way;
    logic [1:0] request_lru_rank;
    logic [1:0] request_victim_way;
    logic [SET_BITS+1:0] request_victim_index;
    logic [SET_BITS+1:0] scan_index;
    integer comb_way;

    logic [25:0] accepted_address_q;
    logic [22:0] accepted_tag_q;
    logic [SET_BITS-1:0] accepted_set_q;
    logic [1:0] accepted_way_q;
    logic [SET_BITS+1:0] accepted_index;
    logic [63:0] hit_data_q;
    logic [63:0] fill_data_q;
    logic reply_is_fill_q;

    integer seq_way;
    integer valid_count_tmp;
    integer old_rank_tmp;
    logic [SET_BITS+1:0] seq_index;

    // XOR of consecutive SET_BITS-wide chunks of the 23-bit granule tag
    // (SET_BITS=6: tag[5:0]^tag[11:6]^tag[17:12]^{1'b0,tag[22:18]}).
    function automatic logic [SET_BITS-1:0] folded_set(input logic [22:0] tag);
        logic [SET_BITS-1:0] f;
        logic [22:0] t;
        begin
            f = '0;
            t = tag;
            for (int c = 0; c < (23 + SET_BITS - 1) / SET_BITS; c++) begin
                f = f ^ t[SET_BITS-1:0];
                t = t >> SET_BITS;
            end
            folded_set = f;
        end
    endfunction

    always_comb begin
        request_tag = client_req_address_i[25:3];
        request_set = folded_set(request_tag);
        request_hit_mask = '0;
        request_invalid_found = 1'b0;
        request_first_invalid_way = 2'd0;
        request_lru_found = 1'b0;
        request_lru_way = 2'd0;
        request_lru_rank = 2'd3;
        scan_index = '0;

        for (comb_way = 0; comb_way < WAY_COUNT; comb_way = comb_way + 1) begin
            scan_index = {request_set, comb_way[1:0]};
            request_hit_mask[comb_way] = way_valid[comb_way] &&
                                         (tag_q[comb_way] == request_tag[22:SET_BITS]);
            if (way_valid[comb_way]) begin
                if (!request_lru_found || lru_q[comb_way] < request_lru_rank) begin
                    request_lru_found = 1'b1;
                    request_lru_way = comb_way[1:0];
                    request_lru_rank = lru_q[comb_way];
                end
            end else if (!request_invalid_found) begin
                request_invalid_found = 1'b1;
                request_first_invalid_way = comb_way[1:0];
            end
        end

        // Keep miss detection as a parallel any-hit reduction. The selected
        // way is still lowest-index priority for the synchronous data read.
        request_hit = |request_hit_mask;
        request_hit_way = 2'd0;
        for (comb_way = WAY_COUNT - 1; comb_way >= 0; comb_way = comb_way - 1)
            if (request_hit_mask[comb_way]) request_hit_way = comb_way[1:0];
        request_hit_index = {request_set, request_hit_way};
        request_victim_way = request_invalid_found ? request_first_invalid_way : request_lru_way;
        request_victim_index = {request_set, request_victim_way};
    end

    assign accepted_index = {accepted_set_q, accepted_way_q};
    // Tags are read only in ST_IDLE (request set); ranks are read at the request
    // set in ST_IDLE and at the accepted set in ST_WAIT_ROM.
    assign rd_set = state_q == ST_INIT ? clear_set_q : (state_q == ST_WAIT_ROM) ? accepted_set_q : request_set;

    always_comb begin : storage_writes
        integer w;
        integer valid_count;
        logic [1:0] old_rank;
        logic accept_hit, accept_fill;
        // Prepare a hypothetical action independently of request qualification.
        // Data is meaningful only when metadata_commit is true. Keeping
        // valid/mode/reset controls on write enable avoids routing them
        // through every tag/rank data mux.
        accept_hit = state_q == ST_IDLE && request_hit;
        accept_fill = state_q == ST_WAIT_ROM;
        tag_we = '0;
        lru_we = '0;
        valid_count = 0;
        for (w = 0; w < WAY_COUNT; w = w + 1) begin
            lru_wdata[w] = 2'd0;
            if (way_valid[w]) valid_count = valid_count + 1;
        end
        if (accept_hit) begin
            old_rank = lru_q[request_hit_way];
            for (w = 0; w < WAY_COUNT; w = w + 1)
                if (way_valid[w] && w[1:0] != request_hit_way && lru_q[w] > old_rank) begin
                    lru_we[w] = 1'b1; lru_wdata[w] = lru_q[w] - 1'b1;
                end
            lru_we[request_hit_way] = 1'b1;
            lru_wdata[request_hit_way] = 2'(valid_count - 1);
        end else if (accept_fill) begin
            tag_we[accepted_way_q] = 1'b1;
            if (way_valid[accepted_way_q]) begin
                old_rank = lru_q[accepted_way_q];
                for (w = 0; w < WAY_COUNT; w = w + 1)
                    if (way_valid[w] && w[1:0] != accepted_way_q && lru_q[w] > old_rank) begin
                        lru_we[w] = 1'b1; lru_wdata[w] = lru_q[w] - 1'b1;
                    end
                lru_we[accepted_way_q] = 1'b1;
                lru_wdata[accepted_way_q] = 2'd3;
            end else begin
                lru_we[accepted_way_q] = 1'b1;
                lru_wdata[accepted_way_q] = valid_count[1:0];
            end
        end
    end

    wire metadata_commit = !cold_reset &&
        ((state_q == ST_IDLE && client_req_valid_i) ||
         (state_q == ST_WAIT_ROM && rom_rsp_valid_i));
    // Reset sweeps all tag/rank words before admitting requests. The drain
    // edge also covers the MLAB registered-write contract for the last set.
    // This replaces the resettable per-set validity decoder/register bank.
    assign initialize_set = 1'b0;
    genvar gw;
    generate for (gw = 0; gw < WAY_COUNT; gw = gw + 1) begin : g_way
        // A way's tag, rank and validity share one MLAB word. Default geometry
        // uses exactly 20 bits, avoiding a register-file validity mux per way.
        // Unwritten fields are retained from the asynchronous read; the write
        // edge is never consumed as a same-cycle read by the cache FSM.
        assign tag_q[gw] = metadata_q[gw][TAG_W+1:2];
        assign lru_q[gw] = metadata_q[gw][1:0];
        assign way_valid[gw] = metadata_q[gw][TAG_W+2];
        // Reset blocks the physical write enable only. Payload calculations
        // are irrelevant while disabled; keep the high-fanout reset out of
        // the tag/rank data mux, preserving every accepted-edge write.
        assign metadata_we[gw] = !cold_reset && (state_q == ST_INIT || (metadata_commit && (tag_we[gw] | lru_we[gw])));
        assign metadata_wdata[gw] = state_q == ST_INIT ? '0 : initialize_set ?
            (tag_we[gw] ? {1'b1, accepted_tag_q[22:SET_BITS], lru_wdata[gw]} : '0) : {
            metadata_q[gw][TAG_W+2] | tag_we[gw],
            tag_we[gw] ? accepted_tag_q[22:SET_BITS] : tag_q[gw],
            lru_we[gw] ? lru_wdata[gw] : lru_q[gw]
        };
        bigfight_mlab_dp #(.WIDTH(TAG_W+3), .DEPTH_BITS(SET_BITS)) metadata_store (
            .clk(clk_sys), .we(metadata_we[gw]), .waddr(rd_set), .wdata(metadata_wdata[gw]),
            .raddr(rd_set), .rdata(metadata_q[gw]));
    end endgenerate
    assign client_req_ready_o = !cold_reset && state_q == ST_IDLE;
    assign client_rsp_valid_o = !cold_reset && ((state_q == ST_HOLD_REPLY) || (state_q == ST_WAIT_ROM && rom_rsp_valid_i));
    assign client_rsp_data_o = state_q == ST_WAIT_ROM ? rom_rsp_data_i : reply_is_fill_q ? fill_data_q : hit_data_q;
    assign rom_req_valid_o = !cold_reset && ((state_q == ST_SEND_ROM) || (state_q == ST_IDLE && client_req_valid_i && !request_hit));
    assign rom_req_address_o = state_q == ST_IDLE ? {client_req_address_i[25:3],3'b000} : accepted_address_q;
    assign rom_rsp_ready_o = !cold_reset && state_q == ST_WAIT_ROM;

    // Dedicated reset-free synchronous memory port. The held fill reply is
    // separate so no reset or alternate fill-data assignment reaches RAM q.
    always_ff @(posedge clk_sys) begin
        if (!cold_reset && state_q == ST_IDLE &&
            client_req_valid_i && client_req_ready_o && request_hit)
            hit_data_q <= data_ram[request_hit_index];
        if (!cold_reset && state_q == ST_WAIT_ROM &&
            rom_rsp_valid_i && rom_rsp_ready_o)
            data_ram[accepted_index] <= rom_rsp_data_i;
    end

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_INIT;
            clear_set_q <= '0;
            accepted_address_q <= '0;
            accepted_tag_q <= '0;
            accepted_set_q <= '0;
            accepted_way_q <= '0;
            fill_data_q <= '0;
            reply_is_fill_q <= 1'b1;
        end else begin
            case (state_q)
                ST_INIT: begin
                    if (&clear_set_q) state_q <= ST_INIT_DRAIN;
                    else clear_set_q <= clear_set_q + 1'b1;
                end
                ST_INIT_DRAIN: state_q <= ST_IDLE;
                ST_IDLE: begin
                    if (client_req_valid_i && client_req_ready_o) begin
                        if (request_hit) begin
                            // The data word is sampled on the accepted hit edge.
                            reply_is_fill_q <= 1'b0;
                            state_q <= ST_HOLD_REPLY;

                            // Rank updates: storage_writes (lru_we).
                        end else begin
                            accepted_address_q <= {client_req_address_i[25:3], 3'b000};
                            accepted_tag_q <= request_tag;
                            accepted_set_q <= request_set;
                            accepted_way_q <= request_victim_way;
                            state_q <= rom_req_ready_i ? ST_WAIT_ROM : ST_SEND_ROM;
                        end
                    end
                end

                ST_SEND_ROM: begin
                    if (rom_req_valid_o && rom_req_ready_i)
                        state_q <= ST_WAIT_ROM;
                end

                ST_WAIT_ROM: begin
                    if (rom_rsp_valid_i && rom_rsp_ready_o) begin
                        // Tag and rank updates: storage_writes (tag_we/lru_we).
                        fill_data_q <= rom_rsp_data_i;
                        reply_is_fill_q <= 1'b1;
                        state_q <= client_rsp_ready_i ? ST_IDLE : ST_HOLD_REPLY;

                    end
                end

                ST_HOLD_REPLY: begin
                    if (client_rsp_valid_o && client_rsp_ready_i)
                        state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end
`ifdef VERILATOR
    // Observation-only invariant against the former per-entry validity vector.
    logic [ENTRY_COUNT-1:0] observed_valid_q;
    integer observed_way;
    always_ff @(posedge clk_sys) begin
        if (cold_reset) observed_valid_q <= '0;
        else begin
            if ((state_q == ST_IDLE && client_req_valid_i) ||
                (state_q == ST_WAIT_ROM && rom_rsp_valid_i)) begin
                for (observed_way = 0; observed_way < WAY_COUNT; observed_way = observed_way + 1)
                    if (way_valid[observed_way] !== observed_valid_q[{rd_set, observed_way[1:0]}])
                        $fatal(1, "CACHE_VALID_METADATA_INVARIANT");
            end
            if (state_q == ST_WAIT_ROM && rom_rsp_valid_i && rom_rsp_ready_o)
                observed_valid_q[accepted_index] <= 1'b1;
        end
    end
`endif
endmodule
