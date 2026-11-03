// SPDX-License-Identifier: GPL-3.0-or-later
// One held client -> one held aligned-granule backend, same clock domain.
// A request must drop between transactions. An accepted backend read is never
// canceled by reset; it is drained before a later request may be admitted.
module spinal_rom_bridge #(parameter bit CACHE_ENABLE=0, parameter integer CACHE_LINES=1,
                          parameter bit SYNC_CACHE=0) (
    input logic clk, reset, invalidate,
    input logic request,
    input logic [3:0] region,
    input logic [21:0] offset,
    output wire ready,
    output logic error,
    output wire [63:0] data,
    output wire backend_request,output wire idle,
    output wire [24:0] backend_address,
    input logic backend_ready,
    input logic [63:0] backend_data
);
    typedef enum logic [2:0] {IDLE, ARM, WAIT_REPLY, RESPONSE, DRAIN, CACHE_LOOKUP} state_t;
    state_t state=IDLE;
    logic [3:0] held_region;
    logic [21:0] held_offset;
    logic discard, released;
    logic [63:0] response_data;
    localparam integer CACHE_INDEX_BITS=CACHE_LINES>1 ? $clog2(CACHE_LINES) : 1;
    logic [CACHE_LINES-1:0] cache_valid='0;
    logic fill_inhibit;
    logic [25:0] cache_address[0:CACHE_LINES-1];
    logic cache_clearing=CACHE_ENABLE && SYNC_CACHE;
    logic [CACHE_INDEX_BITS-1:0] clear_index='0;
    assign idle=state==IDLE && !backend_ready && !(SYNC_CACHE && cache_clearing);
    // Read on the admission edge, so a hit still replies in RESPONSE on
    // exactly the original edge. Keeping the data array out of the asynchronous
    // tag lookup allows block RAM instead of 4096 flip-flops per 64-line cache.
    logic [63:0] cache_data[0:CACHE_LINES-1];
    logic [63:0] cache_read_data;
    logic [25:0] cache_read_address;
    logic cache_response;
    wire [63:0] cache_response_data;
    wire live_valid, held_valid;
    wire [24:0] live_address, mapped_address;
    wire [2:0] unused_live_lane, unused_held_lane;
    wire [63:0] unused_live_data, mapped_data;
    function automatic [CACHE_INDEX_BITS-1:0] index_for(input [24:0] a);
        index_for=((a >> 3) ^ (SYNC_CACHE ? (a >> (3+CACHE_INDEX_BITS)) : 0)) & (CACHE_LINES-1);
    endfunction
    wire [CACHE_INDEX_BITS-1:0] live_index=index_for(live_address);
    wire [CACHE_INDEX_BITS-1:0] fill_index=index_for(mapped_address);
    wire cache_hit;
    generate if(SYNC_CACHE)begin
        assign cache_hit=0;
    end else begin
        assign cache_hit=CACHE_ENABLE && cache_valid[live_index] && !reset && !invalidate && live_valid && live_address==cache_address[live_index][24:0];
    end endgenerate
    wire sync_hit=cache_read_address[25] && !cache_clearing && !reset && !invalidate &&
        !fill_inhibit && held_valid && mapped_address==cache_read_address[24:0];
    spinal_rom_map incoming(.region(region),.offset(offset),.granule_data(64'd0),
        .valid(live_valid),.granule_address(live_address),.lane(unused_live_lane),.data(unused_live_data));
    spinal_rom_map held(.region(held_region),.offset(held_offset),.granule_data(backend_data),
        .valid(held_valid),.granule_address(mapped_address),.lane(unused_held_lane),.data(mapped_data));
    spinal_rom_map cached(.region(held_region),.offset(held_offset),.granule_data(cache_read_data),
        .valid(),.granule_address(),.lane(),.data(cache_response_data));
    // These ports never operate together: admission reads in IDLE and a fill
    // writes in WAIT_REPLY. The original array contents have no reset contract.
    always_ff @(posedge clk) begin
        if(CACHE_ENABLE && state==IDLE && !reset && request && !(SYNC_CACHE && cache_clearing))begin
            cache_read_data<=cache_data[live_index];
            if(SYNC_CACHE)cache_read_address<=cache_address[live_index];
        end
        if(CACHE_ENABLE && state==WAIT_REPLY && backend_ready && !discard && request &&
           !fill_inhibit && !reset && !invalidate)
            cache_data[fill_index]<=backend_data;
        if(CACHE_ENABLE && SYNC_CACHE && cache_clearing && state==IDLE && !reset)
            cache_address[clear_index]<=0;
        else if(CACHE_ENABLE && state==WAIT_REPLY && backend_ready && !discard && request &&
                !fill_inhibit && !reset && !invalidate)
            cache_address[fill_index]<={1'b1,mapped_address};
    end
    // Scrub tag validity through its RAM write port. An accepted backend
    // transaction drains first; new requests remain held until the scrub ends.
    // No per-entry validity flip-flops or stale generation wrap are required.
    always_ff @(posedge clk)begin
        if(CACHE_ENABLE && SYNC_CACHE)begin
            if(reset || invalidate)begin cache_clearing<=1;clear_index<=0;end
            else if(cache_clearing && state==IDLE)begin
                if(clear_index==CACHE_LINES-1)cache_clearing<=0;
                else clear_index<=clear_index+1'b1;
            end
        end
    end
    // The backend samples the registered request/owned address on clk. A low ready
    // proves that a previously held acknowledgement has drained.
    // Admit the tuple on an edge; never feed backend ready into request.
    assign backend_request=state==WAIT_REPLY;
    assign backend_address=state==IDLE ? live_address : mapped_address;
    // Forward an owned reply on its acknowledgement edge, then hold the same
    // data in RESPONSE until the client releases its request.
    assign ready=request && ((state==WAIT_REPLY && backend_ready && !discard) || state==RESPONSE);
    assign data=state==WAIT_REPLY && backend_ready ? mapped_data :
        cache_response ? cache_response_data : response_data;
    always_ff @(posedge clk) begin
        if(reset || invalidate) cache_valid<='0;
        if((state==ARM || state==WAIT_REPLY || state==CACHE_LOOKUP) && (reset || invalidate)) fill_inhibit<=1;
        case(state)
            IDLE: if(!reset && request && !(SYNC_CACHE && cache_clearing)) begin
                held_region<=region;held_offset<=offset;discard<=0;released<=0;
                response_data<=0;cache_response<=0;error<=!live_valid;fill_inhibit<=invalidate;
                if(!live_valid) state<=RESPONSE;
                else if(CACHE_ENABLE && SYNC_CACHE) state<=CACHE_LOOKUP;
                else if(cache_hit) begin cache_response<=1;state<=RESPONSE;end
                else if(backend_ready) state<=ARM;
                else state<=WAIT_REPLY;
            end
            CACHE_LOOKUP: begin
                if(!request)begin discard<=1;released<=1;state<=DRAIN;end
                else if(sync_hit)begin cache_response<=1;state<=RESPONSE;end
                else if(backend_ready)state<=ARM;
                else state<=WAIT_REPLY;
            end
            ARM: begin
                if(!request) begin discard<=1;released<=1;end
                if(!backend_ready) begin
                    if(discard || !request) state<=DRAIN;
                    else state<=WAIT_REPLY;
                end
            end
            WAIT_REPLY: begin
                if(!request) begin discard<=1;released<=1;end
                if(backend_ready) begin
                    if(discard || !request) state<=DRAIN;
                    else begin
                        response_data<=mapped_data;error<=0;state<=RESPONSE;
                        if(CACHE_ENABLE && !fill_inhibit && !reset && !invalidate) begin
                            cache_valid[fill_index]<=1;
                        end
                    end
                end
            end
            RESPONSE: if(!request) begin
                released<=1;
                // If both levels are already low, this edge completes the
                // drain; otherwise retain DRAIN until the old ack is gone.
                if(!reset && !backend_ready) state<=IDLE;
                else state<=DRAIN;
            end
            DRAIN: begin
                if(!request) released<=1;
                if(!reset && !backend_ready && (released || !request)) state<=IDLE;
            end
            default: state<=IDLE;
        endcase
    end
endmodule
