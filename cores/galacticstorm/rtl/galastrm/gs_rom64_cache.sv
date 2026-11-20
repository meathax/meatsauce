// SPDX-License-Identifier: BSD-3-Clause
// Immutable aligned ROM row cache: registered RAM data, one-clock cache hits.
// Requests are held through ACK and released before the next transaction.
module gs_rom64_cache #(
    parameter ADDR_BITS=21,
    parameter INDEX_BITS=7
)(
    input wire clk,reset,req,
    input wire [ADDR_BITS-1:0] address,
    output wire ack,
    output wire [63:0] data,
    output wire raw_req,
    output wire [ADDR_BITS-1:0] raw_address,
    input wire raw_ack,
    input wire [63:0] raw_data
);
    localparam IDLE=0,FETCH=1,REPLY=2,WAIT_DROP=3;
    localparam KEY_BITS=ADDR_BITS-3,TAG_BITS=KEY_BITS-INDEX_BITS,LINES=1<<INDEX_BITS;
    reg [1:0] state;
    reg [ADDR_BITS-1:0] saved_address;
    reg [INDEX_BITS-1:0] saved_slot;
    reg [LINES-1:0] valid;
    // The slot equals the low key bits XOR folds of the high bits. A valid
    // slot and its high tag therefore uniquely determine the complete key.
    // Keep the asynchronous lookup latency while storing tags in LUT memory.
    (* ramstyle="MLAB, no_rw_check" *) reg [TAG_BITS-1:0] tags[0:LINES-1];
    (* ramstyle="M10K, no_rw_check" *) reg [63:0] rows[0:LINES-1];
    reg [63:0] ram_data,miss_data;
    reg reply_hit;
    wire [KEY_BITS-1:0] key=address[ADDR_BITS-1:3];
    wire [INDEX_BITS-1:0] slot=key^(key>>INDEX_BITS)^(key>>(INDEX_BITS*2));
    wire [INDEX_BITS-1:0] read_slot=state==IDLE ? slot : saved_slot;
    wire write_row=state==FETCH && raw_ack;
    assign raw_req=state==FETCH;
    assign raw_address=saved_address;
    assign ack=state==REPLY && req;
    assign data=reply_hit ? ram_data : miss_data;
    always @(posedge clk) begin
        ram_data<=rows[read_slot];
        if(write_row) rows[saved_slot]<=raw_data;
    end
    always @(posedge clk) begin
        case(state)
        IDLE: if(req) begin
            saved_address<=address;saved_slot<=slot;
            reply_hit<=valid[slot] && tags[slot]==key[KEY_BITS-1:INDEX_BITS];
            state<=valid[slot] && tags[slot]==key[KEY_BITS-1:INDEX_BITS] ? REPLY : FETCH;
        end
        FETCH: if(raw_ack) begin
            tags[saved_slot]<=saved_address[ADDR_BITS-1:INDEX_BITS+3];valid[saved_slot]<=1;
            miss_data<=raw_data;state<=REPLY;
        end
        REPLY: state<=WAIT_DROP;
        WAIT_DROP: if(!req) state<=IDLE;
        endcase
        if(reset) begin state<=IDLE;saved_address<=0;saved_slot<=0;valid<=0;reply_hit<=0;miss_data<=0;end
    end
endmodule
