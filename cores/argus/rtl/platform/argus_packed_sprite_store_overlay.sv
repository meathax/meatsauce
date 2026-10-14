// SPDX-License-Identifier: GPL-3.0-or-later
// Complete, lossless GFX1 word dictionary built from standard raw ioctl bytes.
// RAM is retained through game resets; only cold_reset/start_load invalidates it.
module argus_packed_sprite_store_overlay #(
    parameter integer DICT_BITS = 14,
    parameter integer HASH_BITS = 15,
    parameter integer INDEX_BITS = 16,
    // Reuse unused dictionary/index capacity for Argus BG1/text lookup ROMs.
    parameter integer ARGUS_AUX_ROMS = 0,
    parameter bit EXTERNAL_HASH_RUNTIME = 1'b0
) (
    input  logic         clk,
    input  logic         cold_reset,
    input  logic         start_load,
    input  logic [1:0]   game_id,
    input  logic         load_valid,
    input  logic [24:0]  load_addr,
    input  logic [7:0]   load_data,
    output logic         load_byte_ready,
    input  logic         load_end,
    output logic         image_ready,
    output logic         fault,
    output logic [3:0]   fault_code,
    input  logic         read_abort,
    input  logic         read_req,
    input  logic [23:0]  read_addr,
    output logic         read_region,
    output logic         read_ready,
    output logic [63:0]  read_data,
    output logic [16:0]  debug_words_loaded,
    output logic [16:0]  debug_unique_words,
    output logic [31:0]  debug_probes_total,
    output logic [16:0]  debug_max_probes,
    output logic [31:0]  debug_backpressure_cycles,
    input  logic         runtime_hash_re,
    input  logic [11:0]  runtime_hash_raddr,
    output logic [119:0] runtime_hash_q,
    input  logic         runtime_hash_we,
    input  logic [11:0]  runtime_hash_waddr,
    input  logic [119:0] runtime_hash_wdata
);
    import argus_rom_layout_pkg::*;

    localparam integer DICT_ENTRIES = 1 << DICT_BITS;
    localparam integer HASH_ENTRIES = 1 << HASH_BITS;
    // Each primitive page is explicitly 256 x 40: no deep-RAM rounding.
    localparam integer DICT_PACK = 5, INDEX_PACK = 20, HASH_PACK = 8;
    localparam integer DICT_PACK_ENTRIES = (DICT_ENTRIES + DICT_PACK - 1) / DICT_PACK;
    localparam integer DICT_PACK_ADDR_BITS = (DICT_PACK_ENTRIES > 1) ? $clog2(DICT_PACK_ENTRIES) : 1;
    // Store a decoded dictionary group/lane, removing division from rendering.
    localparam integer INDEX_ENTRY_BITS = DICT_PACK_ADDR_BITS + 3;
    localparam integer INDEX_PACK_BITS = INDEX_PACK * INDEX_ENTRY_BITS;
    localparam integer INDEX_PACK_ENTRIES = ((1 << INDEX_BITS) + INDEX_PACK - 1) / INDEX_PACK;
    localparam integer INDEX_PACK_ADDR_BITS = (INDEX_PACK_ENTRIES > 1) ? $clog2(INDEX_PACK_ENTRIES) : 1;
    localparam integer HASH_PACK_ENTRIES = (HASH_ENTRIES + HASH_PACK - 1) / HASH_PACK;
    localparam integer HASH_PACK_ADDR_BITS = (HASH_PACK_ENTRIES > 1) ? $clog2(HASH_PACK_ENTRIES) : 1;
    localparam integer HASH_PACK_BITS = HASH_PACK * (DICT_BITS + 1);
    localparam logic [HASH_BITS-1:0] HASH_PACK_LAST = HASH_BITS'(HASH_PACK_ENTRIES - 1);
    localparam logic [16:0] DICT_LIMIT = 17'(DICT_ENTRIES);
    localparam logic [16:0] HASH_LIMIT = 17'(HASH_ENTRIES);
    localparam logic [HASH_BITS-1:0] HASH_LAST = {HASH_BITS{1'b1}};
    localparam logic [3:0] ERR_GAME = 4'd1, ERR_ORDER = 4'd2,
        ERR_DICTIONARY = 4'd3, ERR_HASH = 4'd4, ERR_INCOMPLETE = 4'd5,
        ERR_QUERY_ALIGN = 4'd6;

    typedef enum logic [3:0] {L_IDLE, L_CLEAR, L_STREAM, L_HASH_READ,
        L_HASH_WAIT, L_DICT_READ, L_DICT_WAIT, L_FINAL, L_DONE, L_FAULT} load_state_t;
    typedef enum logic [1:0] {Q_IDLE, Q_INDEX_WAIT, Q_DICT_WAIT, Q_HOLD} query_state_t;
    load_state_t load_state;
    query_state_t query_state;

    // Sequential dictionary/index builders hold an incomplete group in registers.
    // Collision lookup bypasses the uncommitted dictionary group while loading.
    logic [319:0] dictionary_pack, dictionary_mem_q, dictionary_wdata, dictionary_partial_q;
    logic [DICT_PACK_ADDR_BITS-1:0] dictionary_build_group, dictionary_pack_raddr;
    logic [2:0] dictionary_build_lane, dictionary_read_lane;
    logic dictionary_partial_read, dictionary_mem_re;
    logic [INDEX_PACK_ADDR_BITS-1:0] index_build_group;
    logic [4:0] index_build_lane;
    logic [HASH_PACK_BITS-1:0] hash_mem_q, hash_mem_wdata;
    logic [HASH_PACK_ADDR_BITS-1:0] hash_mem_raddr, hash_mem_waddr;
    logic hash_mem_re, hash_mem_we;

    logic [24:0] gfx_base, gfx_end, expected_addr, load_offset, configured_size;
    logic [24:0] load_final_addr;
    logic argus_aux;
    // Gaps remain physical ROM address gaps; compact offsets only index this RAM.
    function automatic logic aux_region(input logic [24:0] value);
        aux_region = ((value >= 25'h080000 && value < 25'h088000) ||
                      (value >= 25'h090000 && value < 25'h098000) ||
                      (value >= 25'h0a0000 && value < 25'h0a8000) ||
                      (value >= 25'h0b0000 && value < 25'h0b8000));
    endfunction
    function automatic logic [24:0] compact_offset(input logic [24:0] value);
        compact_offset = value - gfx_base;
        if (argus_aux) begin
            if (value >= 25'h080000 && value < 25'h088000) compact_offset=value-25'h080000+25'h020000;
            if (value >= 25'h090000 && value < 25'h098000) compact_offset=value-25'h090000+25'h028000;
            if (value >= 25'h0a0000 && value < 25'h0a8000) compact_offset=value-25'h0a0000+25'h030000;
            if (value >= 25'h0b0000 && value < 25'h0b8000) compact_offset=value-25'h0b0000+25'h038000;
        end
    endfunction
    logic [16:0] expected_words;
    logic session_valid, loaded, end_seen, loader_fault, query_fault;
    logic [3:0] loader_fault_code;
    logic [HASH_BITS-1:0] clear_addr, hash_addr;
    logic [63:0] assembly_word, candidate_word, dictionary_q;
    logic [DICT_BITS:0] hash_q;
    logic [INDEX_PACK_BITS-1:0] index_pack, index_q;
    logic [INDEX_BITS-1:0] candidate_index;
    logic [16:0] probe_count;

    logic [23:0] query_addr, read_offset;
    logic [4:0] query_lane;
    logic reply_valid;
    logic query_accept, query_stable;
    logic insert_word, existing_word, complete_word;
    logic [DICT_BITS-1:0] resolved_index;
    logic [INDEX_ENTRY_BITS-1:0] resolved_packed_index, hash_dictionary_packed_index;
    logic [DICT_PACK_ADDR_BITS-1:0] dictionary_loader_group;
    logic dictionary_re, dictionary_we, index_re, index_we, hash_re, hash_we;
    logic [DICT_BITS-1:0] dictionary_raddr;
    logic [DICT_PACK_ADDR_BITS-1:0] dictionary_waddr;
    // Exact division by five on the declared unsigned dictionary address.
    // C=ceil(2^(DICT_BITS+2)/5), q=(x*C)>>(DICT_BITS+2). Since x<2^DICT_BITS,
    // reciprocal error contributes less than1/5, so q=floor(x/5) for every x.
    // This is combinational: dictionary enable/lane/data/valid cycles are unchanged.
    localparam integer DICT_DIV_SHIFT = DICT_BITS + 2;
    localparam integer DICT_DIV_PRODUCT_BITS = 2*DICT_BITS + 1;
    localparam logic [DICT_BITS:0] DICT_DIV_RECIP =
        (DICT_BITS+1)'(((64'd1 << DICT_DIV_SHIFT) + DICT_PACK - 1) / DICT_PACK);
    (* multstyle = "dsp" *) logic [DICT_DIV_PRODUCT_BITS-1:0] dictionary_divide_product;
    logic [2:0] dictionary_divide_lane;
    // Hash results are decoded at L_HASH_WAIT, before the existing L_DICT_READ.
    assign dictionary_divide_product = dictionary_raddr * DICT_DIV_RECIP;
    assign dictionary_loader_group = DICT_PACK_ADDR_BITS'(dictionary_divide_product >> DICT_DIV_SHIFT);
    assign resolved_packed_index = insert_word ?
        {dictionary_build_group, dictionary_build_lane} : hash_dictionary_packed_index;
    // Remainder is0..4; its low3 bits equal x-5*q modulo8, with no wide divider.
    assign dictionary_divide_lane = 3'(dictionary_raddr) -
        ((3'(dictionary_loader_group) << 2) + 3'(dictionary_loader_group));

    // floor(x/20)=floor((x>>2)/5), on the declared INDEX_BITS input.
    // This removes a widened divider from the request-to-index RAM path.
    // Quotient and remainder stay combinational; request/reply edges are unchanged.
    localparam integer INDEX_DIV_BITS = (INDEX_BITS > 2) ? INDEX_BITS-2 : 1;
    localparam integer INDEX_DIV_SHIFT = INDEX_DIV_BITS + 2;
    localparam logic [INDEX_DIV_BITS:0] INDEX_DIV_RECIP =
        (INDEX_DIV_BITS+1)'(((64'd1 << INDEX_DIV_SHIFT) + 4) / 5);
    logic [INDEX_DIV_BITS-1:0] index_divide_input;
    (* multstyle = "dsp" *) logic [2*INDEX_DIV_BITS:0] index_divide_product;
    logic [INDEX_PACK_ADDR_BITS-1:0] index_divide_quotient;
    logic [4:0] index_divide_lane;
    assign index_divide_input = INDEX_DIV_BITS'(read_offset[INDEX_BITS+2:3] >> 2);
    assign index_divide_product = index_divide_input * INDEX_DIV_RECIP;
    assign index_divide_quotient = INDEX_PACK_ADDR_BITS'(index_divide_product >> INDEX_DIV_SHIFT);
    assign index_divide_lane = 5'(read_offset[INDEX_BITS+2:3]) -
        ((5'(index_divide_quotient) << 4) + (5'(index_divide_quotient) << 2));

    logic [INDEX_PACK_ADDR_BITS-1:0] index_raddr, index_waddr;
    logic [HASH_BITS-1:0] hash_waddr;
    logic [DICT_BITS:0] hash_wdata;
    logic [INDEX_PACK_BITS-1:0] index_wdata;

    // CRC-16/CCITT, init ffff, eight little-endian bytes, low HASH_BITS.
    // Each bit is a balanced XOR reduction of a constant mask: no 64-step chain.
    function automatic logic [HASH_BITS-1:0] hash_word(input logic [63:0] word);
        integer h;
        begin
            hash_word = '0;
            for (h=0; h<HASH_BITS; h=h+1) begin
                case (h)
                0: hash_word[h] = ^(word & 64'h1119581c0b049b85) ^ 1'b0;
                1: hash_word[h] = ^(word & 64'h2232b0381608360b) ^ 1'b1;
                2: hash_word[h] = ^(word & 64'h446460712c106c16) ^ 1'b1;
                3: hash_word[h] = ^(word & 64'h88c8c0e25820d82c) ^ 1'b1;
                4: hash_word[h] = ^(word & 64'h109181c5b140b059) ^ 1'b1;
                5: hash_word[h] = ^(word & 64'h313b5b976885fb36) ^ 1'b1;
                6: hash_word[h] = ^(word & 64'h6276b62ed10af76d) ^ 1'b0;
                7: hash_word[h] = ^(word & 64'hc4ec6c5da215eedb) ^ 1'b0;
                8: hash_word[h] = ^(word & 64'h88d9d9ba442bdcb7) ^ 1'b1;
                9: hash_word[h] = ^(word & 64'h10b3b3758956b86f) ^ 1'b0;
                10: hash_word[h] = ^(word & 64'h206667eb12ad70df) ^ 1'b0;
                11: hash_word[h] = ^(word & 64'h40ccced6255ae1be) ^ 1'b0;
                12: hash_word[h] = ^(word & 64'h9181c5b140b059f8) ^ 1'b1;
                13: hash_word[h] = ^(word & 64'h22038b638160b3f0) ^ 1'b1;
                14: hash_word[h] = ^(word & 64'h440616c702c166e1) ^ 1'b0;
                15: hash_word[h] = ^(word & 64'h880c2c8e0582cdc2) ^ 1'b0;
                    default: hash_word[h] = 1'b0;
                endcase
            end
        end
    endfunction

    assign fault = loader_fault | query_fault;
    assign fault_code = loader_fault ? loader_fault_code :
                        query_fault ? ERR_QUERY_ALIGN : 4'd0;
    assign image_ready = loaded && !fault && !cold_reset && !start_load;
    assign load_byte_ready = (load_state == L_STREAM) && !fault &&
                             !cold_reset && !start_load && !end_seen;
    assign read_offset = 24'(compact_offset({1'b0,read_addr}));
    assign load_offset = compact_offset(load_addr);
    assign configured_size = (ARGUS_AUX_ROMS != 0 && game_id == 0) ? 25'h040000 :
                             rom_region_size(game_id, REGION_GFX1);
    assign read_region = session_valid &&
        ((({1'b0,read_addr} >= gfx_base) && ({1'b0,read_addr} < gfx_end)) ||
         (argus_aux && aux_region({1'b0,read_addr}))); 
    assign query_stable = read_req && (read_addr == query_addr) &&
                          read_region && (read_addr[2:0] == 3'b000);
    assign query_accept = image_ready && !read_abort && read_req && read_region &&
                          (read_addr[2:0] == 3'b000) &&
                          ((query_state == Q_IDLE) ||
                           ((query_state == Q_HOLD) && (read_addr != query_addr)));
    assign read_ready = reply_valid && query_stable && image_ready && !read_abort;

    assign insert_word = !cold_reset && !start_load && !fault &&
        (load_state == L_HASH_WAIT) && !hash_q[DICT_BITS] &&
        (debug_unique_words < DICT_LIMIT);
    assign existing_word = !cold_reset && !start_load && !fault &&
        (load_state == L_DICT_WAIT) && (dictionary_q == candidate_word);
    assign complete_word = insert_word | existing_word;
    assign resolved_index = insert_word ? debug_unique_words[DICT_BITS-1:0] :
                            hash_q[DICT_BITS-1:0];

    assign dictionary_q = dictionary_partial_read ?
        dictionary_partial_q[dictionary_read_lane*64 +: 64] :
        dictionary_mem_q[dictionary_read_lane*64 +: 64];
    assign runtime_hash_q = 120'(hash_mem_q);
    assign hash_q = hash_mem_q[32'(hash_addr % HASH_PACK)*(DICT_BITS+1) +: DICT_BITS+1];

    always_comb begin
        dictionary_we = !cold_reset && !start_load && !fault &&
            ((insert_word && dictionary_build_lane == 3'd4) ||
             (load_state == L_FINAL && dictionary_build_lane != 0));
        dictionary_waddr = dictionary_build_group;
        dictionary_wdata = dictionary_pack;
        if (insert_word) dictionary_wdata[dictionary_build_lane*64 +: 64] = candidate_word;
        dictionary_re = !cold_reset && !start_load && !fault &&
            ((load_state == L_DICT_READ) ||
             (image_ready && !read_abort && (query_state == Q_INDEX_WAIT) && query_stable));
        dictionary_raddr = hash_q[DICT_BITS-1:0];
        dictionary_pack_raddr = image_ready ?
            index_q[query_lane*INDEX_ENTRY_BITS+3 +: DICT_PACK_ADDR_BITS] :
            hash_dictionary_packed_index[3 +: DICT_PACK_ADDR_BITS];
        dictionary_mem_re = dictionary_re &&
            !(!image_ready && dictionary_pack_raddr == dictionary_build_group && dictionary_build_lane != 0);
        index_re = query_accept;
        index_raddr = index_divide_quotient;
        index_we = !cold_reset && !start_load && !fault &&
            ((complete_word && index_build_lane == 5'd19) ||
             (load_state == L_FINAL && index_build_lane != 0));
        index_waddr = index_build_group;
        index_wdata = index_pack;
        if (complete_word) index_wdata[index_build_lane*INDEX_ENTRY_BITS +: INDEX_ENTRY_BITS] = resolved_packed_index;
        hash_re = !cold_reset && !start_load && !fault && (load_state == L_HASH_READ);
        hash_we = !cold_reset && !start_load &&
                  ((load_state == L_CLEAR) || insert_word);
        hash_mem_re = hash_re;
        hash_mem_we = hash_we;
        hash_mem_raddr = HASH_PACK_ADDR_BITS'(32'(hash_addr) / HASH_PACK);
        hash_mem_waddr = (load_state == L_CLEAR) ? HASH_PACK_ADDR_BITS'(clear_addr) : hash_mem_raddr;
        hash_mem_wdata = (load_state == L_CLEAR) ? '0 : hash_mem_q;
        if (insert_word) hash_mem_wdata[32'(hash_addr % HASH_PACK)*(DICT_BITS+1) +: DICT_BITS+1] =
            {1'b1,resolved_index};
        if (EXTERNAL_HASH_RUNTIME && image_ready) begin
            hash_mem_re = runtime_hash_re;
            hash_mem_raddr = HASH_PACK_ADDR_BITS'(runtime_hash_raddr);
            hash_mem_we = runtime_hash_we;
            hash_mem_waddr = HASH_PACK_ADDR_BITS'(runtime_hash_waddr);
            hash_mem_wdata = HASH_PACK_BITS'(runtime_hash_wdata);
        end
    end

    // dictionary_q is consumed only after the gated lane/partial metadata read.
    // Read all pages continuously: same active-edge data, no added lookup cycle.
    argus_paged_sdp_ram40 #(.DATA_W(320), .DEPTH(DICT_PACK_ENTRIES), .ALWAYS_READ(1'b1)) dictionary_ram (
        .clk(clk), .we(dictionary_we), .waddr(dictionary_waddr), .wdata(dictionary_wdata),
        .re(dictionary_mem_re), .raddr(dictionary_pack_raddr), .q(dictionary_mem_q));
    argus_paged_sdp_ram40 #(.DATA_W(INDEX_PACK_BITS), .DEPTH(INDEX_PACK_ENTRIES)) index_ram (
        .clk(clk), .we(index_we), .waddr(index_waddr), .wdata(index_wdata),
        .re(index_re), .raddr(index_raddr), .q(index_q));
    // Named packed-hash port permits a separately owned lifetime-overlay mux.
    argus_paged_sdp_ram40 #(.DATA_W(HASH_PACK_BITS), .DEPTH(HASH_PACK_ENTRIES)) hash_ram (
        .clk(clk), .we(hash_mem_we), .waddr(hash_mem_waddr), .wdata(hash_mem_wdata),
        .re(hash_mem_re), .raddr(hash_mem_raddr), .q(hash_mem_q));

    always_ff @(posedge clk) begin
        if (dictionary_re) begin
            dictionary_read_lane <= image_ready ?
                index_q[query_lane*INDEX_ENTRY_BITS +: 3] : hash_dictionary_packed_index[2:0];
            dictionary_partial_read <= !image_ready && dictionary_pack_raddr == dictionary_build_group && dictionary_build_lane != 0;
            dictionary_partial_q <= dictionary_pack;
        end
        if (cold_reset || start_load) begin
            hash_dictionary_packed_index <= '0;
            dictionary_pack <= '0;
            dictionary_build_group <= '0;
            dictionary_build_lane <= '0;
            index_pack <= '0;
            index_build_group <= '0;
            index_build_lane <= '0;
        end else begin
            if (load_state == L_HASH_WAIT && hash_q[DICT_BITS])
                hash_dictionary_packed_index <= {dictionary_loader_group, dictionary_divide_lane};
            if (insert_word) begin
                if (dictionary_build_lane == 3'd4) begin
                    dictionary_pack <= '0;
                    dictionary_build_lane <= '0;
                    dictionary_build_group <= dictionary_build_group + 1'b1;
                end else begin
                    dictionary_pack[dictionary_build_lane*64 +: 64] <= candidate_word;
                    dictionary_build_lane <= dictionary_build_lane + 1'b1;
                end
            end
            if (complete_word) begin
                if (index_build_lane == 5'd19) begin
                    index_pack <= '0;
                    index_build_lane <= '0;
                    index_build_group <= index_build_group + 1'b1;
                end else begin
                    index_pack[index_build_lane*INDEX_ENTRY_BITS +: INDEX_ENTRY_BITS] <= resolved_packed_index;
                    index_build_lane <= index_build_lane + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (cold_reset) begin
            load_state <= L_IDLE;
            gfx_base <= '0;
            load_final_addr <= '0;
            argus_aux <= 1'b0;
            gfx_end <= '0;
            expected_addr <= '0;
            expected_words <= '0;
            session_valid <= 1'b0;
            loaded <= 1'b0;
            end_seen <= 1'b0;
            loader_fault <= 1'b0;
            loader_fault_code <= 4'd0;
            clear_addr <= '0;
            hash_addr <= '0;
            candidate_word <= '0;
            assembly_word <= '0;
            candidate_index <= '0;
            probe_count <= '0;
            debug_words_loaded <= '0;
            debug_unique_words <= '0;
            debug_probes_total <= '0;
            debug_max_probes <= '0;
            debug_backpressure_cycles <= '0;
        end else if (start_load) begin
            gfx_base <= rom_region_base(game_id, REGION_GFX1);
            argus_aux <= (ARGUS_AUX_ROMS != 0 && game_id == 0);
            load_final_addr <= (ARGUS_AUX_ROMS != 0 && game_id == 0) ? 25'h0b8000 :
                rom_region_base(game_id, REGION_GFX1) + rom_region_size(game_id, REGION_GFX1);
            gfx_end <= rom_region_base(game_id, REGION_GFX1) +
                       rom_region_size(game_id, REGION_GFX1);
            expected_addr <= rom_region_base(game_id, REGION_GFX1);
            expected_words <= configured_size[19:3];
            session_valid <= (game_id != 2'd3);
            loaded <= 1'b0;
            end_seen <= 1'b0;
            loader_fault <= (game_id == 2'd3);
            loader_fault_code <= (game_id == 2'd3) ? ERR_GAME : 4'd0;
            load_state <= (game_id == 2'd3) ? L_FAULT : L_CLEAR;
            clear_addr <= '0;
            hash_addr <= '0;
            candidate_word <= '0;
            assembly_word <= '0;
            candidate_index <= '0;
            probe_count <= '0;
            debug_words_loaded <= '0;
            debug_unique_words <= '0;
            debug_probes_total <= '0;
            debug_max_probes <= '0;
            debug_backpressure_cycles <= '0;
        end else begin
            if (load_end && session_valid) end_seen <= 1'b1;
            if (load_valid && !load_byte_ready &&
                (load_state != L_DONE) && (load_state != L_FAULT))
                debug_backpressure_cycles <= debug_backpressure_cycles + 1'b1;
            case (load_state)
                L_CLEAR: begin
                    clear_addr <= clear_addr + 1'b1;
                    if (clear_addr == HASH_PACK_LAST) load_state <= L_STREAM;
                end
                L_STREAM: begin
                    if (end_seen) begin
                        if ((expected_addr == load_final_addr) &&
                            (debug_words_loaded == expected_words)) begin
                            load_state <= L_FINAL;
                        end else begin
                            loader_fault <= 1'b1;
                            loader_fault_code <= ERR_INCOMPLETE;
                            load_state <= L_FAULT;
                        end
                    end else if (load_valid && load_byte_ready &&
                                 (((load_addr >= gfx_base) && (load_addr < gfx_end)) ||
                                  (argus_aux && aux_region(load_addr)))) begin
                        if (load_addr != expected_addr) begin
                            loader_fault <= 1'b1;
                            loader_fault_code <= ERR_ORDER;
                            load_state <= L_FAULT;
                        end else begin
                            expected_addr <= expected_addr + 1'b1;
                            if (argus_aux) case (load_addr)
                                25'h05ffff: expected_addr <= 25'h080000;
                                25'h087fff: expected_addr <= 25'h090000;
                                25'h097fff: expected_addr <= 25'h0a0000;
                                25'h0a7fff: expected_addr <= 25'h0b0000;
                                default: ;
                            endcase
                            assembly_word[load_addr[2:0]*8 +: 8] <= load_data;
                            if (load_addr[2:0] == 3'd7) begin
                                candidate_word <= {load_data,assembly_word[55:0]};
                                hash_addr <= hash_word({load_data,assembly_word[55:0]});
                                candidate_index <= load_offset[INDEX_BITS+2:3];
                                probe_count <= 17'd1;
                                load_state <= L_HASH_READ;
                            end
                        end
                    end
                end
                // Both partial final groups are committed on this edge before publication.
                L_FINAL: begin
                    loaded <= 1'b1;
                    load_state <= L_DONE;
                end
                L_HASH_READ: load_state <= L_HASH_WAIT;
                L_HASH_WAIT: begin
                    debug_probes_total <= debug_probes_total + 1'b1;
                    if (!hash_q[DICT_BITS]) begin
                        if (debug_unique_words >= DICT_LIMIT) begin
                            loader_fault <= 1'b1;
                            loader_fault_code <= ERR_DICTIONARY;
                            load_state <= L_FAULT;
                        end else begin
                            debug_unique_words <= debug_unique_words + 1'b1;
                            debug_words_loaded <= debug_words_loaded + 1'b1;
                            
                            if (probe_count > debug_max_probes) debug_max_probes <= probe_count;
                            load_state <= L_STREAM;
                        end
                    end else load_state <= L_DICT_READ;
                end
                L_DICT_READ: load_state <= L_DICT_WAIT;
                L_DICT_WAIT: begin
                    if (dictionary_q == candidate_word) begin
                        debug_words_loaded <= debug_words_loaded + 1'b1;
                        
                        if (probe_count > debug_max_probes) debug_max_probes <= probe_count;
                        load_state <= L_STREAM;
                    end else if (probe_count == HASH_LIMIT) begin
                        loader_fault <= 1'b1;
                        loader_fault_code <= ERR_HASH;
                        load_state <= L_FAULT;
                    end else begin
                        hash_addr <= hash_addr + 1'b1;
                        probe_count <= probe_count + 1'b1;
                        load_state <= L_HASH_READ;
                    end
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (cold_reset || start_load || read_abort) begin
            query_state <= Q_IDLE;
            query_addr <= '0;
            query_lane <= '0;
            read_data <= '0;
            reply_valid <= 1'b0;
        end else begin
            reply_valid <= 1'b0;
            if (!image_ready) query_state <= Q_IDLE;
            else if (query_accept) begin
                query_addr <= read_addr;
                query_lane <= index_divide_lane;
                query_state <= Q_INDEX_WAIT;
            end else case (query_state)
                Q_INDEX_WAIT: query_state <= query_stable ? Q_DICT_WAIT : Q_IDLE;
                Q_DICT_WAIT: begin
                    if (query_stable) begin
                        read_data <= dictionary_q;
                        reply_valid <= 1'b1;
                        query_state <= Q_HOLD;
                    end else query_state <= Q_IDLE;
                end
                Q_HOLD: if (!read_req || !read_region) query_state <= Q_IDLE;
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (cold_reset || start_load) query_fault <= 1'b0;
        else if (image_ready && !read_abort && read_req && read_region &&
                 (read_addr[2:0] != 3'b000)) query_fault <= 1'b1;
    end
endmodule
