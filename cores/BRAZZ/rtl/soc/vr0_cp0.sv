// SPDX-License-Identifier: GPL-3.0-or-later
// SE3208 CP0, qualified VISA2000 register profile, with a real two-way
// write-through transport cache. Geometry/descriptor are explicit parameters:
// the available related-ASIC data books disagree about geometry/configuration.
// MAME's SE3208 treats every MVTC/MVFC as a no-op, so the board never faults on them: a requested
// write-back policy (CR3 bit 6, used by topbladv/officeye) is accepted and the cache stays write-through
// (memory always current, a superset of write-back visibility); unspecified registers/ids read 0.
module vr0_cp0 #(
    parameter integer SET_BITS = 7,
    parameter logic [31:0] STATUS_DESCRIPTOR = 32'h80204b01,
    // Timing-only options (architecturally invisible, coherence unchanged):
    // CACHE_WHILE_DISABLED keeps policy-cacheable accesses in the coherent
    // write-through cache even while CR7 has it disabled (MAME models no cache;
    // CR6 still reports the CR7 setting). POSTED_WRITES answers a cacheable
    // (work RAM) write from LOOKUP and queues it in a four-entry write FIFO;
    // read hits and further posted writes proceed while it drains in order,
    // and any other access needing the backend waits until it is empty, so
    // backend order is unchanged. A
    // posted-write error invalidates the whole cache and is reported on the
    // next reply.
    // Line fills always fetch the requested word first and answer with it
    // (early restart); the other three words fill in the background while hits
    // to other sets are served. Requests to the filling set are not accepted,
    // and anything needing the backend waits, until the fill completes.
    parameter bit CACHE_WHILE_DISABLED = 0,
    parameter bit POSTED_WRITES = 0
) (
    input logic clk, reset,
    input logic cp_req_valid, output logic cp_req_ready,
    input logic cp_req_write, input logic [1:0] cp_req_id,
    input logic [2:0] cp_req_register, input logic [31:0] cp_req_data,
    output logic cp_rsp_valid, input logic cp_rsp_ready,
    output logic [31:0] cp_rsp_data, output logic cp_rsp_error,
    input logic req_valid, output logic req_ready,
    input logic [31:0] req_address, req_data,
    input logic [3:0] req_strobe, input logic req_write, req_cacheable,
    output logic rsp_valid, output logic [31:0] rsp_data, output logic rsp_error,
    output logic mem_req_valid, input logic mem_req_ready,
    output logic [31:0] mem_req_address, mem_req_data,
    output logic [3:0] mem_req_strobe, output logic mem_req_write,
    input logic mem_rsp_valid, input logic [31:0] mem_rsp_data, input logic mem_rsp_error,
    // Completed external writes invalidate matching lines. Global invalidation
    // also handles changes in ROM-bank mapping. Partners share reset.
    input logic snoop_valid, input logic [31:0] snoop_address,
    input logic invalidate_all,
    output logic cache_enabled, invalidation_busy,
    output logic [31:0] hits, misses, invalidations, forwarded_writes
);
    localparam integer SETS = 1 << SET_BITS;
    localparam integer TAG_BITS = 28 - SET_BITS;
    typedef enum logic [3:0] {IDLE, LOOKUP, HIT_READ, HIT_REPLY,
        FILL_REQUEST, FILL_RESPONSE, WRITE_REQUEST, WRITE_RESPONSE,
        BYPASS_REQUEST, BYPASS_RESPONSE, INVALIDATE} state_t;
    state_t state;
    // Tags live in block RAM (previously 5k+ ALMs of registers). Each way has a
    // lookup copy (read at request acceptance) and a snoop copy (read when a
    // completed external write is observed); both are written by fills.
    wire [TAG_BITS-1:0] lookup_tag0,lookup_tag1,snoop_tag0,snoop_tag1;
    logic snoop_s1_valid;
    logic [SET_BITS-1:0] snoop_s1_index;
    logic [TAG_BITS-1:0] snoop_s1_tag;
    logic valid [0:1][0:SETS-1];
    logic lru [0:SETS-1];
    logic [31:0] address, write_data, read_data, hit_data0, hit_data1;
    logic [3:0] strobe;
    logic write_access, cache_access, way, killed, invalidate_pending;
    logic drain_error, rsp_error_r, wb_inflight;
    logic [1:0] wb_head, wb_tail;
    logic [2:0] wb_count;
    // Registers, not inferred RAM: the head entry drives the request outputs.
    (* ramstyle = "logic" *) logic [31:0] wb_address [0:3];
    (* ramstyle = "logic" *) logic [31:0] wb_data [0:3];
    (* ramstyle = "logic" *) logic [3:0] wb_strobe [0:3];
    wire drain = wb_count != 0 || wb_inflight;
    wire wb_full = wb_count == 3'd4;
    assign rsp_error = rsp_error_r || drain_error;
    logic [1:0] fill_word, fill_count;
    logic bg_fill, bg_req, fill_killed, fill_way;
    logic [27:0] fill_line;
    wire [SET_BITS-1:0] fill_index = fill_line[SET_BITS-1:0];
    wire [TAG_BITS-1:0] fill_tag = fill_line[27:SET_BITS];
    wire mem_busy = drain || bg_fill;
    wire fill_snoop = (snoop_valid && snoop_address[31:4] == fill_line) ||
        (snoop_s1_valid && {snoop_s1_tag,snoop_s1_index} == fill_line);
    wire bg_reply = bg_fill && !bg_req && mem_rsp_valid;
    wire wb_pending = wb_count != 0 && !wb_inflight && !bg_fill;
    logic [SET_BITS-1:0] invalidate_set;
    wire [SET_BITS-1:0] index = address[SET_BITS+3:4];
    wire [TAG_BITS-1:0] tag = address[31:SET_BITS+4];
    wire [SET_BITS-1:0] snoop_index = snoop_address[SET_BITS+3:4];
    wire [TAG_BITS-1:0] snoop_tag = snoop_address[31:SET_BITS+4];
    wire same_snoop = (snoop_valid && snoop_address[31:4] == address[31:4]) ||
        (snoop_s1_valid && {snoop_s1_tag,snoop_s1_index} == address[31:4]);
    wire hit0 = valid[0][index] && lookup_tag0 == tag;
    wire hit1 = valid[1][index] && lookup_tag1 == tag;
    // A hit is answered from LOOKUP: both ways' data words are read with the
    // tags at request acceptance (one bank per way), so a hit costs two clocks
    // instead of four. The CPU fetches every instruction through this path.
    wire hit_valid = (hit0 || hit1) && !same_snoop && !invalidate_all;
    // A cacheable write may be posted while the FIFO has room, also during a
    // background fill (its set is never the filling one), except on a fill
    // word's data RAM write clock; a read hit always proceeds. Queued writes
    // reach the backend only after the fill, so a later fill never passes them.
    wire write_go = POSTED_WRITES ? (!bg_reply && !wb_full) : !mem_busy;
    wire lookup_go = !mem_busy || (cache_access && hit_valid && !write_access) ||
        (POSTED_WRITES && cache_access && write_access && write_go);
    wire wb_push = POSTED_WRITES && state==LOOKUP && lookup_go && cache_access && write_access;
    wire ireq_ready = !mem_req_valid; // backend request register is free
    wire wb_pop = wb_pending && ireq_ready;
    wire [SET_BITS+1:0] word_address = {index,address[3:2]};
    wire [SET_BITS+1:0] fill_address = {fill_index,fill_word};
    // Share the write address/data for fills and write-through hits. The
    // explicit byte banks below preserve lane enables and infer M10K RAM;
    // earlier array/write templates mapped this 4 KiB cache into registers.
    wire data_fill = !reset && (state==FILL_RESPONSE || bg_reply) && mem_rsp_valid && !mem_rsp_error;
    wire data_hit_write = !reset && state==LOOKUP && cache_access && write_access && hit_valid && write_go;
    wire data_write_way = data_fill ? fill_way : !hit0;
    wire [SET_BITS+1:0] data_write_address = data_fill ? fill_address : word_address;
    wire [31:0] data_write_value = data_fill ? mem_rsp_data : write_data;
    wire [3:0] data_write_strobe = data_fill ? 4'b1111 : strobe;
    wire control_invalidate = cp_req_valid && cp_req_write && cp_req_id==0 &&
        cp_req_register==5 && cp_req_data[0];
    assign invalidation_busy = invalidate_pending || state == INVALIDATE;
    assign req_ready = state == IDLE && !invalidate_pending && !invalidate_all && !control_invalidate &&
        !(bg_fill && req_address[SET_BITS+3:4] == fill_index);
    assign cp_req_ready = !cp_rsp_valid && (!cp_req_write || state==IDLE || state==INVALIDATE);
    logic ireq_valid, ireq_write;
    logic [31:0] ireq_address, ireq_data;
    logic [3:0] ireq_strobe;
    always_comb begin
        // A buffered posted write excludes every state request (LOOKUP holds).
        // Likewise a background fill word request.
        ireq_valid = wb_pending || bg_req || state==FILL_REQUEST || state==WRITE_REQUEST || state==BYPASS_REQUEST;
        ireq_address = wb_pending ? wb_address[wb_head] : (bg_req || state==FILL_REQUEST) ? {fill_line,fill_word,2'b00} : address;
        ireq_data = wb_pending ? wb_data[wb_head] : bg_req ? 32'b0 : write_data;
        ireq_strobe = wb_pending ? wb_strobe[wb_head] : (bg_req || state==FILL_REQUEST) ? 4'b1111 : strobe;
        ireq_write = wb_pending || state==WRITE_REQUEST || (state==BYPASS_REQUEST && write_access);
    end
    // Valid bits protect uninitialized RAM. Reading and writing occur in
    // mutually exclusive states; registered tag/data reads start at acceptance.
    wire tag_fill = !reset && bg_reply && !mem_rsp_error && fill_count==3;
    // Tag/data lookup RAMs read the presented address on every IDLE clock and
    // hold outside IDLE, so the accepting clock's read is what LOOKUP sees.
    // This keeps the requester's (late) valid out of the RAM read enables.
    wire lookup_read = !reset && state==IDLE;
    wire [SET_BITS-1:0] lookup_index = req_address[SET_BITS+3:4];
    vr0_tag_ram #(.ADDR_BITS(SET_BITS),.WIDTH(TAG_BITS)) lookup_ram0 (.clk,
        .write_enable(tag_fill && !fill_way),.write_address(fill_index),.write_data(fill_tag),
        .read_enable(lookup_read),.read_address(lookup_index),.read_data(lookup_tag0));
    vr0_tag_ram #(.ADDR_BITS(SET_BITS),.WIDTH(TAG_BITS)) lookup_ram1 (.clk,
        .write_enable(tag_fill && fill_way),.write_address(fill_index),.write_data(fill_tag),
        .read_enable(lookup_read),.read_address(lookup_index),.read_data(lookup_tag1));
    vr0_tag_ram #(.ADDR_BITS(SET_BITS),.WIDTH(TAG_BITS)) snoop_ram0 (.clk,
        .write_enable(tag_fill && !fill_way),.write_address(fill_index),.write_data(fill_tag),
        .read_enable(snoop_valid),.read_address(snoop_index),.read_data(snoop_tag0));
    vr0_tag_ram #(.ADDR_BITS(SET_BITS),.WIDTH(TAG_BITS)) snoop_ram1 (.clk,
        .write_enable(tag_fill && fill_way),.write_address(fill_index),.write_data(fill_tag),
        .read_enable(snoop_valid),.read_address(snoop_index),.read_data(snoop_tag1));
    vr0_cache_data_ram #(.ADDR_BITS(SET_BITS+2)) cache_data0 (
        .clk, .read_enable(lookup_read),
        .read_address({lookup_index,req_address[3:2]}), .read_data(hit_data0),
        .write_enable((data_fill || data_hit_write) && !data_write_way), .write_address(data_write_address),
        .write_data(data_write_value), .write_strobe(data_write_strobe)
    );
    vr0_cache_data_ram #(.ADDR_BITS(SET_BITS+2)) cache_data1 (
        .clk, .read_enable(lookup_read),
        .read_address({lookup_index,req_address[3:2]}), .read_data(hit_data1),
        .write_enable((data_fill || data_hit_write) && data_write_way), .write_address(data_write_address),
        .write_data(data_write_value), .write_strobe(data_write_strobe)
    );
    // Backend request register: the FIFO/fill/state request mux ends here, so
    // the board's MMIO/arbiter decode starts from flip-flops. One request at a
    // time (the FSM waits for the response), so a single entry suffices.
    always_ff @(posedge clk) begin
        if (reset) begin
            mem_req_valid <= 0; mem_req_address <= 0; mem_req_data <= 0; mem_req_strobe <= 0; mem_req_write <= 0;
        end else begin
            if (mem_req_valid && mem_req_ready) mem_req_valid <= 0;
            if (ireq_valid && ireq_ready) begin
                mem_req_valid <= 1; mem_req_address <= ireq_address; mem_req_data <= ireq_data;
                mem_req_strobe <= ireq_strobe; mem_req_write <= ireq_write;
            end
        end
    end
    always_ff @(posedge clk) begin
        rsp_valid <= 0;
        if (reset) begin
            state <= IDLE; cache_enabled <= 0; invalidate_pending <= 0;
            cp_rsp_valid <= 0; cp_rsp_data <= 0; cp_rsp_error <= 0;
            rsp_data <= 0; rsp_error_r <= 0; address <= 0; write_data <= 0;
            read_data <= 0; strobe <= 0; write_access <= 0;
            cache_access <= 0; way <= 0; killed <= 0; fill_word <= 0; invalidate_set <= 0;
            bg_fill <= 0; bg_req <= 0; fill_killed <= 0; fill_way <= 0; fill_line <= 0; fill_count <= 0;
            drain_error <= 0; wb_inflight <= 0; wb_head <= 0; wb_tail <= 0; wb_count <= 0;
            hits <= 0; misses <= 0; invalidations <= 0; forwarded_writes <= 0; snoop_s1_valid <= 0;
            for (integer i=0;i<SETS;i=i+1) begin
                valid[0][i] <= 0; valid[1][i] <= 0; lru[i] <= 0;
            end
        end else begin
            if (cp_rsp_valid && cp_rsp_ready) cp_rsp_valid <= 0;
            if (invalidate_all) invalidate_pending <= 1;
            if (cp_req_valid && cp_req_ready) begin
                cp_rsp_valid <= 1; cp_rsp_data <= 0; cp_rsp_error <= 0;
                if (cp_req_id != 0) ; // other coprocessors: no-op (MAME)
                else case (cp_req_register)
                    3: if (!cp_req_write) cp_rsp_data <= 32'h80;
                    5: if (cp_req_write && cp_req_data[0]) invalidate_pending <= 1;
                    6: begin
                        if (!cp_req_write) cp_rsp_data <= (STATUS_DESCRIPTOR & ~32'h00900000) |
                            (cache_enabled ? 32'h00800000 : 0) |
                            (invalidation_busy ? 32'h00100000 : 0);
                    end
                    7: begin
                        if (cp_req_write) cache_enabled <= cp_req_data[11];
                        else cp_rsp_data <= 32'h1100;
                    end
                    default: ; // unspecified control/debug register: no-op, reads 0 (MAME)
                endcase
            end
            // Capture the presented payload on every IDLE clock; it is used only
            // after the accepting clock moves to LOOKUP. This keeps the
            // requester's late valid out of these registers' enables.
            if (state == IDLE) begin
                address <= req_address; write_data <= req_data; strobe <= req_strobe;
                write_access <= req_write; cache_access <= req_cacheable && (cache_enabled || CACHE_WHILE_DISABLED);
            end
            case (state)
                IDLE: begin
                    if (invalidate_pending || invalidate_all) begin
                        invalidate_set <= 0; state <= INVALIDATE;
                        invalidations <= invalidations + 1'b1;
                    end else if (req_valid && req_ready) begin
                        // Tags cannot change during this one outstanding access.
                        // The lookup RAMs read them at acceptance; LOOKUP still
                        // checks live valid bits and snoops, including retries.
                        killed <= 0; state <= LOOKUP;
                    end
                end
                LOOKUP: begin
                    // Only a read hit may proceed while a posted write is still
                    // outstanding; everything else would issue a backend request.
                    if (!lookup_go) begin end
                    else if (!cache_access) begin
                        // A bypassed CPU write must not leave a stale line on re-enable.
                        if (write_access) begin
                            if (hit0) valid[0][index] <= 0;
                            if (hit1) valid[1][index] <= 0;
                            forwarded_writes <= forwarded_writes + 1'b1;
                        end
                        state <= BYPASS_REQUEST;
                    end else if (hit_valid) begin
                        way <= !hit0; lru[index] <= hit0;
                        hits <= hits + 1'b1; killed <= 0;
                        if (write_access) begin
                            // data_hit_write updates the hit way's lanes on this edge.
                            forwarded_writes <= forwarded_writes + 1'b1;
                            if (POSTED_WRITES) begin
                                rsp_data <= 0; rsp_error_r <= 0; rsp_valid <= 1; state <= IDLE;
                            end else state <= WRITE_REQUEST;
                        end else begin
                            rsp_data <= hit0 ? hit_data0 : hit_data1;
                            rsp_error_r <= 0; rsp_valid <= 1; state <= IDLE;
                        end
                    end else if (write_access) begin
                        // Write-through, no allocation on write miss.
                        forwarded_writes <= forwarded_writes + 1'b1;
                        if (POSTED_WRITES) begin
                            rsp_data <= 0; rsp_error_r <= 0; rsp_valid <= 1; state <= IDLE;
                        end else state <= WRITE_REQUEST;
                    end else begin
                        // Requested word first. The victim is invalid from now on,
                        // since hits to other sets continue during the fill.
                        fill_way <= !valid[0][index] ? 1'b0 : !valid[1][index] ? 1'b1 : lru[index];
                        if (valid[0][index] && valid[1][index]) valid[lru[index]][index] <= 0;
                        fill_line <= address[31:4]; fill_word <= address[3:2]; fill_count <= 0;
                        fill_killed <= 0; killed <= 0;
                        misses <= misses + 1'b1; state <= FILL_REQUEST;
                    end
                end
                FILL_REQUEST: if (ireq_ready) state <= FILL_RESPONSE;
                FILL_RESPONSE: if (mem_rsp_valid) begin
                    rsp_data <= mem_rsp_data; rsp_error_r <= mem_rsp_error; rsp_valid <= 1; state <= IDLE;
                    // Early restart: the other three words follow in the background.
                    if (!mem_rsp_error) begin
                        bg_fill <= 1; bg_req <= 1; fill_word <= fill_word + 1'b1; fill_count <= 1;
                    end
                end
                WRITE_REQUEST: if (ireq_ready) state <= WRITE_RESPONSE;
                WRITE_RESPONSE: if (mem_rsp_valid) begin
                    if (mem_rsp_error) begin
                        if (hit0) valid[0][index] <= 0;
                        if (hit1) valid[1][index] <= 0;
                    end
                    rsp_data <= mem_rsp_data; rsp_error_r <= mem_rsp_error; rsp_valid <= 1; state <= IDLE;
                end
                BYPASS_REQUEST: if (ireq_ready) state <= BYPASS_RESPONSE;
                BYPASS_RESPONSE: if (mem_rsp_valid) begin
                    rsp_data <= mem_rsp_data; rsp_error_r <= mem_rsp_error; rsp_valid <= 1; state <= IDLE;
                end
                INVALIDATE: begin
                    valid[0][invalidate_set] <= 0; valid[1][invalidate_set] <= 0;
                    if (&invalidate_set) begin invalidate_pending <= 0; state <= IDLE; end
                    else invalidate_set <= invalidate_set + 1'b1;
                end
                default: state <= IDLE;
            endcase
            if (POSTED_WRITES) begin
                // Only the in-flight posted write can respond while it is set.
                if (wb_push) begin
                    wb_address[wb_tail] <= address; wb_data[wb_tail] <= write_data;
                    wb_strobe[wb_tail] <= strobe; wb_tail <= wb_tail + 1'b1;
                end
                if (wb_pop) begin wb_head <= wb_head + 1'b1; wb_inflight <= 1; end
                wb_count <= wb_count + {2'b0,wb_push} - {2'b0,wb_pop};
                if (wb_inflight && mem_rsp_valid) begin
                    wb_inflight <= 0;
                    if (mem_rsp_error) begin drain_error <= 1; invalidate_pending <= 1; end
                end
            end
            if (drain_error && rsp_valid) drain_error <= 0;
            // Background fill engine (owns the backend port while bg_fill).
            if (bg_req && ireq_ready) bg_req <= 0;
            if ((bg_fill || state==FILL_REQUEST || state==FILL_RESPONSE) &&
                (fill_snoop || invalidate_all || invalidate_pending || control_invalidate)) fill_killed <= 1;
            if (bg_reply) begin
                if (mem_rsp_error) begin
                    // The line never becomes valid; report on the next reply.
                    bg_fill <= 0; drain_error <= 1;
                end else if (fill_count == 3) begin
                    valid[fill_way][fill_index] <= !fill_killed && !fill_snoop && !invalidate_all &&
                        !invalidate_pending && !control_invalidate;
                    lru[fill_index] <= !fill_way;
                    bg_fill <= 0;
                end else begin
                    fill_word <= fill_word + 1'b1; fill_count <= fill_count + 1'b1; bg_req <= 1;
                end
            end
            // A completed snoop wins over a same-clock fill/tag installation.
            // Snoop pipeline: stage 1 registers the address and reads the tag RAMs;
            // stage 2 compares and clears the valid bit. same_snoop covers both
            // stages so a request cannot hit a line that is being invalidated.
            snoop_s1_valid <= snoop_valid;
            snoop_s1_index <= snoop_index;
            snoop_s1_tag <= snoop_tag;
            if (snoop_s1_valid) begin
                if(valid[0][snoop_s1_index] && snoop_tag0==snoop_s1_tag) valid[0][snoop_s1_index]<=0;
                if(valid[1][snoop_s1_index] && snoop_tag1==snoop_s1_tag) valid[1][snoop_s1_index]<=0;
            end
            if (snoop_valid || snoop_s1_valid) begin
                if (state!=IDLE && same_snoop) killed <= 1;
            end
            if (invalidate_all && state!=IDLE) killed <= 1;
        end
    end
endmodule

// Simple dual-port tag RAM: one synchronous write and one registered read that
// holds its value while read_enable is low. Read-during-write returns old data.
module vr0_tag_ram #(parameter integer ADDR_BITS=7, WIDTH=21) (
    input logic clk, write_enable, read_enable,
    input logic [ADDR_BITS-1:0] write_address, read_address,
    input logic [WIDTH-1:0] write_data,
    output logic [WIDTH-1:0] read_data
);
    (* ramstyle = "M10K" *) logic [WIDTH-1:0] tag_mem [0:(1<<ADDR_BITS)-1];
    always_ff @(posedge clk) begin
        if (write_enable) tag_mem[write_address] <= write_data;
        if (read_enable) read_data <= tag_mem[read_address];
    end
endmodule

// Independent byte-wide simple-dual-port banks avoid partial packed-vector
// write inference ambiguities in Quartus 17. No RAM reset: validity is in CP0.
module vr0_cache_data_ram #(parameter integer ADDR_BITS=10) (
    input logic clk, read_enable, write_enable,
    input logic [ADDR_BITS-1:0] read_address, write_address,
    input logic [31:0] write_data,
    input logic [3:0] write_strobe,
    output logic [31:0] read_data
);
    genvar lane;
    generate for (lane=0;lane<4;lane=lane+1) begin : byte_bank
        (* ramstyle = "M10K" *) logic [7:0] byte_ram [0:(1<<ADDR_BITS)-1];
        always_ff @(posedge clk) begin
            if (write_enable && write_strobe[lane])
                byte_ram[write_address] <= write_data[lane*8+:8];
            if (read_enable)
                read_data[lane*8+:8] <= byte_ram[read_address];
        end
    end endgenerate
endmodule
