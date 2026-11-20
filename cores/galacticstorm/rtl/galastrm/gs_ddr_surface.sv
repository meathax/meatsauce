// SPDX-License-Identifier: BSD-3-Clause
// Held 64-bit indexed transactions to the unchanged MiSTer DDRAM interface.
// Writes retire only when accepted by DDRAM; reads use aligned eight-word bursts.
// A small direct-mapped indexed cache is invalidated by overlapping writes.
module gs_ddr_surface #(
    parameter [28:0] DDR_BASE_WORD=29'h6000000,
    parameter CACHE_BITS=6,
    parameter STREAM_LINES=0,
    parameter SPLIT_CLASSES=1,
    parameter HASH_INDEX=0,
    parameter TAG_RAM=0,
    parameter TAG_M10K=0,
    parameter WRITE_THROUGH=0,
    // The client always drops REQ on the ACK edge (gs_memory_arb2): skip RETIRE.
    parameter FAST_RETIRE=0
)(
    input wire clk,reset,
    input wire req,write,
    input wire stream_line,
    output wire line_valid,
    output wire [2:0] line_word,
    output wire [63:0] line_data,
    input wire [24:0] addr,
    input wire [63:0] wdata,
    input wire [7:0] bytes,
    output wire ack,
    output wire [63:0] rdata,
    output wire busy,
    input wire DDRAM_BUSY,
    output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    input wire [63:0] DDRAM_DOUT,
    input wire DDRAM_DOUT_READY,
    output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,
    output wire [7:0] DDRAM_BE,
    output wire DDRAM_WE
);
    localparam IDLE=0,LOOKUP=1,READ_CMD=2,FILL=3,REPLY=4,WRITE_CMD=5,RETIRE=6,CACHE_STREAM=7,LINE_REPLY=8,WRITE_LOOKUP=9;
    // Source, display, arena descriptors and arena nodes get separate slots.
    // The otherwise-unused class zero holds nodes at arena offset >=0x20000.
    localparam LINES=(SPLIT_CLASSES ? 4:1)<<CACHE_BITS;
    localparam SLOT_BITS=CACHE_BITS+(SPLIT_CLASSES ? 2:0);
    localparam WORD_BITS=SLOT_BITS+3;
    localparam TAG_BITS=19-CACHE_BITS;
    reg [3:0] state;
    reg [7:0] cached_write_bytes;
    reg saved_stream,stream_pending;
    reg [3:0] stream_count;
    reg [2:0] stream_index;
    reg [24:0] saved_addr;
    reg [63:0] saved_data,reply_data;
    wire [63:0] cache_data;
    reg [7:0] saved_bytes;
    reg [2:0] fill_word;
    reg [LINES-1:0] valid;
    function automatic [1:0] cache_class(input [24:0] a);
        cache_class=!SPLIT_CLASSES ? 2'b00:
            ((a[24:20]==5'h15 && |a[19:17]) ? 2'b00:a[21:20]);
    endfunction
    function automatic [CACHE_BITS-1:0] cache_index(input [24:0] a);
        cache_index=a[6 +: CACHE_BITS] ^ (HASH_INDEX ? (a>>(6+CACHE_BITS)):25'b0) ^
            (HASH_INDEX==2 ? (((a>>(6+CACHE_BITS))<<4) ^ (a>>(8+CACHE_BITS))):25'b0);
    endfunction
    wire [SLOT_BITS-1:0] saved_slot={cache_class(saved_addr),cache_index(saved_addr)};
    wire [TAG_BITS-1:0] saved_tag=saved_addr[24:6+CACHE_BITS];
    wire [SLOT_BITS-1:0] input_slot={cache_class(addr),cache_index(addr)};
    wire [TAG_BITS-1:0] input_tag=addr[24:6+CACHE_BITS];
    wire [WORD_BITS-1:0] lookup_address=state==CACHE_STREAM ? {saved_slot,stream_count[2:0]} : {input_slot,addr[5:3]};
    wire [WORD_BITS-1:0] fill_address={saved_slot,fill_word};
    wire [TAG_BITS-1:0] lookup_tag,input_lookup_tag;
    wire cache_hit=valid[saved_slot] && lookup_tag==saved_tag;
    generate if(TAG_RAM)begin:ram_tags
        reg [TAG_BITS-1:0] tag_q;
        if(TAG_M10K)begin:block_tags
            (* ramstyle="M10K" *) reg [TAG_BITS-1:0] tags[0:LINES-1];
            always @(posedge clk)begin
                tag_q<=tags[input_slot];
                if(state==FILL && DDRAM_DOUT_READY && fill_word==7)tags[saved_slot]<=saved_tag;
            end
        end else begin:distributed_tags
            (* ramstyle="MLAB" *) reg [TAG_BITS-1:0] tags[0:LINES-1];
            always @(posedge clk)begin
                tag_q<=tags[input_slot];
                if(state==FILL && DDRAM_DOUT_READY && fill_word==7)tags[saved_slot]<=saved_tag;
            end
        end
        assign lookup_tag=tag_q;assign input_lookup_tag=tag_q;
    end else begin:logic_tags
        reg [TAG_BITS-1:0] tags[0:LINES-1];
        always @(posedge clk)if(state==FILL && DDRAM_DOUT_READY && fill_word==7)tags[saved_slot]<=saved_tag;
        assign lookup_tag=tags[saved_slot];assign input_lookup_tag=tags[input_slot];
    end endgenerate
    assign ack=req && ((state==REPLY) || (state==LINE_REPLY) || (state==WRITE_CMD && !DDRAM_BUSY));
    assign line_valid=saved_stream && ((state==FILL && DDRAM_DOUT_READY) || (state==CACHE_STREAM && stream_pending));
    assign line_word=state==FILL ? fill_word : stream_index;
    assign line_data=state==FILL ? DDRAM_DOUT : cache_data;
    assign rdata=reply_data;
    assign busy=state!=IDLE;
    assign DDRAM_RD=state==READ_CMD;
    assign DDRAM_WE=state==WRITE_CMD;
    assign DDRAM_BURSTCNT=state==WRITE_CMD?8'd1:8'd8;
    assign DDRAM_ADDR=DDR_BASE_WORD+{7'b0,saved_addr[24:3] & (state==WRITE_CMD?22'h3fffff:22'h3ffff8)};
    assign DDRAM_DIN=saved_data;
    assign DDRAM_BE=state==WRITE_CMD?saved_bytes:8'hff;
    generate if(WRITE_THROUGH)begin:write_through_data
        wire filling=state==FILL;
        wire [WORD_BITS-1:0] write_address=filling ? fill_address:{saved_slot,saved_addr[5:3]};
        wire [63:0] write_data=filling ? DDRAM_DOUT:saved_data;
        wire [7:0] write_bytes=filling && DDRAM_DOUT_READY ? 8'hff:
            (state==WRITE_CMD && !DDRAM_BUSY ? cached_write_bytes:8'h00);
        // Whole-byte banks keep the coherent write enables as physical RAM
        // enables. Quartus 17 expands partial writes to a wide array into FFs.
        genvar b;
        for(b=0;b<8;b=b+1)begin:byte_bank
            (* ramstyle="M10K, no_rw_check" *) reg [7:0] data[0:LINES*8-1];
            reg [7:0] q;
            assign cache_data[8*b +:8]=q;
            always @(posedge clk)begin
                q<=data[lookup_address];
                if(write_bytes[b])data[write_address]<=write_data[8*b +:8];
            end
        end
    end else begin:fill_only_data
        (* ramstyle="M10K, no_rw_check" *) reg [63:0] data[0:LINES*8-1];
        reg [63:0] q;
        assign cache_data=q;
        always @(posedge clk)begin
            q<=data[lookup_address];
            if(state==FILL && DDRAM_DOUT_READY)data[fill_address]<=DDRAM_DOUT;
        end
    end endgenerate
    always @(posedge clk) begin
        case(state)
        IDLE: if(req) begin
            saved_addr<=addr;saved_data<=wdata;saved_bytes<=bytes;
            saved_stream<=STREAM_LINES && stream_line && !write;
            if(write) begin
                if(!WRITE_THROUGH && !TAG_RAM && valid[input_slot] && input_lookup_tag==input_tag) valid[input_slot]<=0;
                state<=WRITE_THROUGH || TAG_RAM ? WRITE_LOOKUP : WRITE_CMD;
            end else state<=LOOKUP;
        end
        // Synchronous tags become available after request capture. Check the
        // captured line before invalidating it or enabling coherent byte writes.
        WRITE_LOOKUP: begin
            if(!WRITE_THROUGH && cache_hit)valid[saved_slot]<=0;
            cached_write_bytes<=WRITE_THROUGH && cache_hit ? saved_bytes : 8'h00;
            state<=WRITE_CMD;
        end
        LOOKUP: begin
            if(cache_hit) begin
                reply_data<=cache_data;
                if(saved_stream) begin stream_count<=0;stream_pending<=0;state<=CACHE_STREAM;end
                else state<=REPLY;
            end
            else begin valid[saved_slot]<=0;fill_word<=0;state<=READ_CMD;end
        end
        READ_CMD: if(!DDRAM_BUSY) state<=FILL;
        FILL: if(DDRAM_DOUT_READY) begin
            if(fill_word==saved_addr[5:3]) reply_data<=DDRAM_DOUT;
            fill_word<=fill_word+1'b1;
            if(fill_word==7) begin valid[saved_slot]<=1;state<=saved_stream ? LINE_REPLY : REPLY;end
        end
        CACHE_STREAM: begin
            stream_pending<=stream_count<8;stream_index<=stream_count[2:0];
            if(stream_count==8) state<=LINE_REPLY;
            else stream_count<=stream_count+1'b1;
        end
        LINE_REPLY: state<=FAST_RETIRE ? IDLE : RETIRE;
        REPLY: state<=FAST_RETIRE ? IDLE : RETIRE;
        WRITE_CMD: if(!DDRAM_BUSY) state<=FAST_RETIRE ? IDLE : RETIRE;
        RETIRE: if(!req) state<=IDLE;
        endcase
        if(reset) begin state<=IDLE;valid<=0;saved_addr<=0;saved_data<=0;saved_bytes<=0;cached_write_bytes<=0;reply_data<=0;fill_word<=0;
            saved_stream<=0;stream_pending<=0;stream_count<=0;stream_index<=0;
        end
    end
endmodule
