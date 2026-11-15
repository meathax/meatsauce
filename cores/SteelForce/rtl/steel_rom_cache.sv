// Small set-associative immutable-ROM cache. All storage/lookup uses clk.
// Data/tag arrays have synchronous reads; reset/invalidation clears valid bits only.
module steel_rom_cache #(
    parameter SET_BITS=9, WAY_BITS=1
)(
    input wire clk,reset,invalidate,request,
    input wire [24:0] address,
    output wire ready,
    output reg [63:0] data,
    output reg memory_request,
    output reg [24:0] memory_address,
    input wire memory_acknowledged,
    input wire [63:0] memory_data,
    output reg [31:0] hits,misses
);
    localparam SETS=1<<SET_BITS, WAYS=1<<WAY_BITS, TAG_BITS=22-SET_BITS;
    localparam IDLE=0,LOOKUP=1,FILL=2,REPLY=3;
    reg [1:0] state;
    reg [24:0] owned_address;
    wire [SET_BITS-1:0] index=address[SET_BITS+2:3];
    wire [SET_BITS-1:0] owned_index=owned_address[SET_BITS+2:3];
    wire [TAG_BITS-1:0] owned_tag=owned_address[24:SET_BITS+3];
    reg [SETS-1:0] valid[0:WAYS-1];
    reg [WAY_BITS-1:0] replacement[0:SETS-1],victim;
    reg [63:0] lookup_data[0:WAYS-1];
    reg [TAG_BITS-1:0] lookup_tag[0:WAYS-1];
    reg [WAYS-1:0] lookup_valid;
    reg response_valid,found,invalidating;
    reg [WAY_BITS-1:0] hit_way;
    // Each statically selected way is an independent synchronous RAM.
    // A variable first array index on writes prevents Quartus RAM inference.
    genvar way;
    generate for(way=0;way<WAYS;way=way+1)begin:cache_way
        localparam [WAY_BITS-1:0] WAY_ID=way;
        reg [63:0] lines[0:SETS-1];
        reg [TAG_BITS-1:0] tags[0:SETS-1];
        always @(posedge clk)begin
            if(state==IDLE)begin
                lookup_data[way]<=lines[index];
                lookup_tag[way]<=tags[index];
            end
            if(!reset && !invalidate && state==FILL && memory_acknowledged && victim==WAY_ID)begin
                lines[owned_index]<=memory_data;
                tags[owned_index]<=owned_tag;
            end
        end
    end endgenerate
    integer w,s;
    always @(*) begin
        found=0;hit_way=0;
        for(integer k=0;k<WAYS;k=k+1)
            if(lookup_valid[k] && lookup_tag[k]==owned_tag)begin
                found=1;hit_way=k[WAY_BITS-1:0];
            end
    end
    assign ready=response_valid && request && address==owned_address && !reset && !invalidate;
    always @(posedge clk) begin
        // Unconditional IDLE payload/array sampling keeps late request valid
        // out of the enables of wide address/data registers.
        if(state==IDLE)begin
            owned_address<=address;victim<=replacement[index];
            for(w=0;w<WAYS;w=w+1)begin
                lookup_valid[w]<=valid[w][index];
            end
        end
        if(reset || invalidate)begin
            state<=IDLE;memory_request<=0;memory_address<=0;response_valid<=0;
            data<=0;hits<=0;misses<=0;
            // Image invalidation is held for millions of download clocks.
            // Clear validity/replacement once on entry; data/tag RAM is untouched.
            if(reset || !invalidating)begin
                for(w=0;w<WAYS;w=w+1)valid[w]<=0;
                for(s=0;s<SETS;s=s+1)replacement[s]<=0;
            end
            invalidating<=!reset;
        end else begin
            invalidating<=0;
            case(state)
            IDLE:if(request)state<=LOOKUP;
            LOOKUP:if(found)begin
                data<=lookup_data[hit_way];response_valid<=1;hits<=hits+1'b1;state<=REPLY;
            end else begin
                memory_address<={owned_address[24:3],3'b000};
                memory_request<=1;misses<=misses+1'b1;state<=FILL;
            end
            FILL:if(memory_acknowledged)begin
                valid[victim][owned_index]<=1;replacement[owned_index]<=victim+1'b1;
                data<=memory_data;response_valid<=1;memory_request<=0;state<=REPLY;
            end
            REPLY:if(!request || address!=owned_address)begin response_valid<=0;state<=IDLE;end
            endcase
        end
    end
endmodule
