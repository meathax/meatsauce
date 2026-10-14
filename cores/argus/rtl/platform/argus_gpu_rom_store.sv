// SPDX-License-Identifier: GPL-3.0-or-later
// Single graphics ROM port: direct dictionary regions plus shared runtime cache.
module argus_gpu_rom_store #(
    parameter bit ARGUS_AUX_ROMS=1'b1,
    parameter bit PREHEAT_BUTASAN_TEXT=1'b1
) (
    input logic clk,cold_reset,start_load,
    input logic [1:0] game_id,
    input logic load_valid,
    input logic [24:0] load_addr,
    input logic [7:0] load_data,
    output logic load_byte_ready,
    input logic load_end,
    output logic image_ready,fault,
    output logic [3:0] fault_code,
    input logic read_abort,read_req,
    input logic [23:0] read_addr,
    output logic direct_region,read_ready,
    output logic [63:0] read_data,
    output logic backing_req,
    output logic [23:0] backing_addr,
    input logic backing_ready,
    input logic [63:0] backing_data,
    output logic [16:0] debug_words_loaded,debug_unique_words,debug_max_probes,
    output logic [31:0] debug_probes_total,debug_backpressure_cycles,
    output logic [31:0] debug_cache_hits,debug_cache_misses,debug_cache_discarded
);
    logic dictionary_ready,dictionary_fault,dictionary_read_ready;
    logic loader_completed;
    logic [3:0] dictionary_fault_code;
    logic [63:0] dictionary_read_data,cache_read_data;
    logic cache_ready,cache_fault,cache_read_ready;
    logic hash_mem_re,hash_mem_we;
    logic [11:0] hash_mem_raddr,hash_mem_waddr;
    logic [119:0] hash_mem_q,hash_mem_wdata;
    // Query faults suppress public readiness but cannot revoke an accepted
    // physical cache miss. Loading ends once per cold/download session.
    always_ff @(posedge clk) begin
        if (cold_reset || start_load) loader_completed<=1'b0;
        else if (dictionary_ready) loader_completed<=1'b1;
    end
    assign fault=dictionary_fault || cache_fault;
    assign fault_code=dictionary_fault ? dictionary_fault_code : cache_fault ? 4'd6 : 4'd0;
    assign image_ready=dictionary_ready && cache_ready && !fault;
    assign read_ready=image_ready && (direct_region ? dictionary_read_ready : cache_read_ready);
    assign read_data=direct_region ? dictionary_read_data : cache_read_data;
    argus_packed_sprite_store_overlay #(.ARGUS_AUX_ROMS(32'(ARGUS_AUX_ROMS)),.EXTERNAL_HASH_RUNTIME(1'b1)) dictionary(
        .clk(clk),.cold_reset(cold_reset),.start_load(start_load),.game_id(game_id),
        .load_valid(load_valid),.load_addr(load_addr),.load_data(load_data),
        .load_byte_ready(load_byte_ready),.load_end(load_end),.image_ready(dictionary_ready),
        .fault(dictionary_fault),.fault_code(dictionary_fault_code),
        .read_abort(read_abort),.read_req(read_req && image_ready && direct_region),.read_addr(read_addr),
        .read_region(direct_region),.read_ready(dictionary_read_ready),.read_data(dictionary_read_data),
        .debug_words_loaded(debug_words_loaded),.debug_unique_words(debug_unique_words),
        .debug_probes_total(debug_probes_total),.debug_max_probes(debug_max_probes),
        .debug_backpressure_cycles(debug_backpressure_cycles),
        .runtime_hash_re(hash_mem_re),.runtime_hash_raddr(hash_mem_raddr),.runtime_hash_q(hash_mem_q),
        .runtime_hash_we(hash_mem_we),.runtime_hash_waddr(hash_mem_waddr),.runtime_hash_wdata(hash_mem_wdata));
    argus_gpu_cache_overlay cache(
        .clk(clk),.cold_reset(cold_reset),.start_load(start_load),.loader_done(loader_completed),
        .preheat_enable(PREHEAT_BUTASAN_TEXT && game_id==2),.preheat_base(24'h0f0000),.preheat_words(13'd4096),
        .cache_ready(cache_ready),.fault(cache_fault),.read_abort(read_abort),
        .read_req(read_req && image_ready && !direct_region),.read_addr(read_addr),
        .read_ready(cache_read_ready),.read_data(cache_read_data),
        .hash_mem_re(hash_mem_re),.hash_mem_raddr(hash_mem_raddr),.hash_mem_q(hash_mem_q),
        .hash_mem_we(hash_mem_we),.hash_mem_waddr(hash_mem_waddr),.hash_mem_wdata(hash_mem_wdata),
        .backing_req(backing_req),.backing_addr(backing_addr),.backing_ready(backing_ready),.backing_data(backing_data),
        .debug_hits(debug_cache_hits),.debug_misses(debug_cache_misses),.debug_discarded(debug_cache_discarded));
endmodule
