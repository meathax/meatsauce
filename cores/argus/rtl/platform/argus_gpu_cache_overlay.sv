// SPDX-License-Identifier: GPL-3.0-or-later
// Runtime ROM cache controller for the loader hash RAM's second lifetime.
// No storage is declared here: the packed sprite store owns the one 4096x120 RAM.
module argus_gpu_cache_overlay #(
    parameter bit FOLD_INDEX = 1'b1
) (
    input  logic         clk,
    input  logic         cold_reset,
    input  logic         start_load,
    input  logic         loader_done,
    input  logic         preheat_enable,
    input  logic [23:0]  preheat_base,
    input  logic [12:0]  preheat_words,
    output logic         cache_ready,
    output logic         fault,
    input  logic         read_abort,
    input  logic         read_req,
    input  logic [23:0]  read_addr,
    output logic         read_ready,
    output logic [63:0]  read_data,
    output logic         hash_mem_re,
    output logic [11:0]  hash_mem_raddr,
    input  logic [119:0] hash_mem_q,
    output logic         hash_mem_we,
    output logic [11:0]  hash_mem_waddr,
    output logic [119:0] hash_mem_wdata,
    output logic         backing_req,
    output logic [23:0]  backing_addr,
    input  logic         backing_ready,
    input  logic [63:0]  backing_data,
    output logic [31:0]  debug_hits,
    output logic [31:0]  debug_misses,
    output logic [31:0]  debug_discarded
);
    typedef enum logic [2:0] {I_WAIT,I_CLEAR,I_PREHEAT,I_GAP,I_RUN} init_state_t;
    typedef enum logic [1:0] {Q_IDLE,Q_LOOKUP,Q_FETCH,Q_HOLD} query_state_t;
    init_state_t init_state;
    query_state_t query_state;
    logic [11:0] clear_addr;
    logic [23:0] preheat_addr;
    logic [12:0] preheat_left;
    logic [23:0] query_addr;
    logic query_cancelled,reply_valid;
    logic query_accept,query_stable,cache_hit,cache_operational;

    // A full word-address tag is required because the index is folded.
    // This maps every 21-bit aligned word address losslessly into 86 row bits.
    function automatic logic [11:0] cache_index(input logic [23:0] addr);
        logic [11:0] upper;
        begin
            upper={3'd0,addr[23:15]};
            cache_index=addr[14:3];
            if (FOLD_INDEX) cache_index=cache_index ^ upper ^ (upper << 3);
        end
    endfunction

    assign cache_operational=(init_state==I_RUN) && loader_done &&
                             !cold_reset && !start_load;
    assign cache_ready=cache_operational && !fault;
    assign query_stable=read_req && read_addr==query_addr &&
                        read_addr[2:0]==0 && !read_abort;
    assign query_accept=cache_ready && !read_abort && read_req &&
                        read_addr[2:0]==0 &&
                        (query_state==Q_IDLE ||
                         (query_state==Q_HOLD && read_addr!=query_addr));
    assign cache_hit=hash_mem_q[85] && hash_mem_q[84:64]==query_addr[23:3];
    assign read_ready=reply_valid && query_stable && cache_ready;

    // An accepted physical read is drained even when its client is cancelled.
    // The backing controller is allowed to complete it, fill immutable ROM data,
    // then observe req low before admitting a new address.
    assign backing_req=((query_state==Q_FETCH) && cache_operational) ||
                       (init_state==I_PREHEAT && loader_done && !cold_reset && !start_load);
    assign backing_addr=init_state==I_PREHEAT ? preheat_addr : query_addr;

    always_comb begin
        hash_mem_re=query_accept;
        hash_mem_raddr=cache_index(read_addr);
        hash_mem_we=(init_state==I_CLEAR) && loader_done &&
                    !cold_reset && !start_load;
        hash_mem_waddr=clear_addr;
        hash_mem_wdata=120'd0;
        if (init_state==I_PREHEAT && backing_ready && loader_done &&
            !cold_reset && !start_load) begin
            hash_mem_we=1'b1;
            hash_mem_waddr=cache_index(preheat_addr);
            hash_mem_wdata={34'd0,1'b1,preheat_addr[23:3],backing_data};
        end
        if (query_state==Q_FETCH && backing_ready && cache_operational) begin
            hash_mem_we=1'b1;
            hash_mem_waddr=cache_index(query_addr);
            hash_mem_wdata={34'd0,1'b1,query_addr[23:3],backing_data};
        end
    end

    always_ff @(posedge clk) begin
        if (cold_reset || start_load) begin
            init_state<=I_WAIT;
            clear_addr<=0;
            preheat_addr<=0;preheat_left<=0;
        end else case (init_state)
            I_WAIT: if (loader_done) begin
                init_state<=I_CLEAR;clear_addr<=0;
                preheat_addr<={preheat_base[23:3],3'd0};
                preheat_left<=preheat_enable ? preheat_words : 13'd0;
            end
            I_CLEAR: if (loader_done) begin
                if (clear_addr==12'hfff) init_state<=preheat_left!=0 ? I_PREHEAT : I_RUN;
                else clear_addr<=clear_addr+12'd1;
            end
            I_PREHEAT: if (loader_done && backing_ready) begin
                preheat_addr<=preheat_addr+24'd8;
                preheat_left<=preheat_left-13'd1;
                init_state<=I_GAP;
            end
            // Give the physical port one full low-request edge between fills.
            I_GAP: if(loader_done) init_state<=preheat_left!=0 ? I_PREHEAT : I_RUN;
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (cold_reset || start_load) begin
            query_state<=Q_IDLE;
            query_addr<=0;
            query_cancelled<=0;
            reply_valid<=0;
            read_data<=0;
            fault<=0;
            debug_hits<=0;debug_misses<=0;debug_discarded<=0;
        end else begin
            reply_valid<=0;
            if (cache_ready && !read_abort && read_req && read_addr[2:0]!=0)
                fault<=1'b1;
            if (!cache_operational) begin
                query_state<=Q_IDLE;
                query_cancelled<=0;
            end else if (fault) begin
                // Alignment faults stop new work but cannot cut off an accepted
                // physical transaction. Drain it before leaving the query idle.
                if (query_state==Q_FETCH) begin
                    query_cancelled<=1'b1;
                    if (backing_ready) begin
                        query_state<=Q_IDLE;
                        debug_discarded<=debug_discarded+32'd1;
                    end
                end else query_state<=Q_IDLE;
            end else if (query_accept) begin
                query_addr<=read_addr;
                query_cancelled<=0;
                query_state<=Q_LOOKUP;
            end else case (query_state)
                Q_IDLE: ;
                Q_LOOKUP: begin
                    if (!query_stable) query_state<=Q_IDLE;
                    else if (cache_hit) begin
                        read_data<=hash_mem_q[63:0];reply_valid<=1'b1;
                        query_state<=Q_HOLD;debug_hits<=debug_hits+32'd1;
                    end else begin
                        query_state<=Q_FETCH;debug_misses<=debug_misses+32'd1;
                    end
                end
                Q_FETCH: begin
                    if (!query_stable) query_cancelled<=1'b1;
                    if (backing_ready) begin
                        if (query_stable && !query_cancelled) begin
                            read_data<=backing_data;reply_valid<=1'b1;
                            query_state<=Q_HOLD;
                        end else begin
                            query_state<=Q_IDLE;
                            debug_discarded<=debug_discarded+32'd1;
                        end
                    end
                end
                Q_HOLD: if (!read_req || read_abort) query_state<=Q_IDLE;
                default: query_state<=Q_IDLE;
            endcase
        end
    end
endmodule
