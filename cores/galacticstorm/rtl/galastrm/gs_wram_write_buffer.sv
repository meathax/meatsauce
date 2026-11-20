// SPDX-License-Identifier: GPL-3.0-or-later
// Ordered main-owned RAM writes with coherent forwarding. LINE_READS is an
// optional four-word spatial WRAM cache; its production path remains disabled.
// Reads outside the owned regions drain all queued writes. Snapshot requests
// stop CPU issue at a whole-transfer boundary, then wait for idle before capture.
module gs_wram_write_buffer #(
    parameter integer DEPTH=8,
    parameter integer VIDEO_WRITES=0,
    parameter integer LINE_WRITES=0,
    parameter integer LINE_READS=0,
    parameter bit FAST_WRITE_ACK=0,
    // Main program ROM (0x000000-0x0fffff) reads fetch and return the aligned
    // SDRAM line on up_rline, like private WRAM line reads; ROM reads may
    // bypass queued RAM writes because ROM cannot alias any queued write.
    parameter bit ROM_LINES=0,
    // N>0: 2**N-line write-through M10K store for private WRAM reads
    // (0x200000-0x21ffff), looked up one edge early via look_addr.
    parameter integer WRAM_LINE_IW=0
)(
    input wire clk,reset,
    input wire up_req,up_write,
    input wire [23:0] look_addr,        // CPU's next bus address while no request is held
    input wire [23:0] up_addr,
    input wire [1:0] up_be,
    input wire [15:0] up_wdata,
    output wire up_ack,
    output wire [15:0] up_rdata,
    output wire [63:0] up_rline,
    output wire down_req,down_write,
    output wire [23:0] down_addr,
    output wire [1:0] down_be,
    output wire [15:0] down_wdata,
    output wire down_write_line,
    output wire [63:0] down_wline,
    input wire down_ack,
    input wire [15:0] down_rdata,
    input wire [63:0] down_rline,
    output wire idle
);
    localparam integer PTR_BITS=$clog2(DEPTH);
    localparam integer TAG_BITS=VIDEO_WRITES ? 18 : 16;
    localparam integer CACHE_TAG_BITS=TAG_BITS-(LINE_READS ? 2 : 0);
    localparam integer CACHE_WORDS=LINE_READS ? 4 : 1;
    localparam [1:0] IDLE=0,WRITE=1,DIRECT=2,GAP=3;
    reg [1:0] state=IDLE;
    (* ramstyle="MLAB, no_rw_check" *) reg [TAG_BITS+17:0] queue[0:DEPTH-1];
    reg [PTR_BITS-1:0] write_ptr=0,read_ptr=0;
    reg [PTR_BITS:0] count=0;
    reg accepted=0,reply_valid=0,direct_cancel=0;
    reg [15:0] reply_data=0;
    reg [63:0] reply_line=0;
    reg [23:0] held_addr=0;
    reg [15:0] held_data=0;
    reg [1:0] held_be=0;
    reg held_write=0;
    reg [2:0] held_words=1;
    reg [63:0] held_line=0;
    reg cache_valid=0;
    reg [CACHE_TAG_BITS-1:0] cache_tag=0;
    reg [16*CACHE_WORDS-1:0] cache_data=0;
    reg [2*CACHE_WORDS-1:0] cache_mask=0;
    reg held_read_line=0;
    reg [1:0] held_lane=0;
    function automatic owned(input [23:0] a);
        owned=a[23:17]==7'h10 || (VIDEO_WRITES &&
            (a[23:16]==8'h80 || a[23:16]==8'hd0 || a[23:14]==10'h0c0));
    endfunction
    // Owned writes occupy four disjoint regions. Keep a two-bit region code
    // and the largest region's 16-bit word offset instead of a full bus tag.
    function automatic [TAG_BITS-1:0] encode_word(input [23:0] a);
        reg [1:0] region;
        begin
            region=a[23:17]==7'h10 ? 2'd0 :
                a[23:16]==8'h80 ? 2'd1 : a[23:16]==8'hd0 ? 2'd2 : 2'd3;
            encode_word=VIDEO_WRITES ? TAG_BITS'({region,a[16:1]}) : TAG_BITS'(a[16:1]);
        end
    endfunction
    function automatic [23:0] decode_word(input [TAG_BITS-1:0] tag);
        begin
            decode_word={7'h10,tag[15:0],1'b0};
            if(VIDEO_WRITES) case(tag[TAG_BITS-1 -: 2])
                2'd1:decode_word={8'h80,tag[14:0],1'b0};
                2'd2:decode_word={8'hd0,tag[14:0],1'b0};
                2'd3:decode_word={8'h30,tag[14:0],1'b0};
                default: ;
            endcase
        end
    endfunction
    wire is_owned=owned(up_addr);
    wire [TAG_BITS-1:0] word_tag=encode_word(up_addr);
    wire [TAG_BITS-1:0] held_tag=encode_word(held_addr);
    wire [CACHE_TAG_BITS-1:0] request_cache_tag=LINE_READS ? word_tag[TAG_BITS-1:2] : word_tag;
    wire [1:0] cache_lane=LINE_READS ? up_addr[2:1] : 2'b00;
    wire [1:0] selected_mask=cache_mask[2*cache_lane +: 2];
    wire [15:0] selected_data=cache_data[16*cache_lane +: 16];
    wire [2*CACHE_WORDS-1:0] write_mask=(2*CACHE_WORDS)'(up_be) << (2*cache_lane);
    wire hit=is_owned && !up_write && cache_valid && |up_be &&
        cache_tag==request_cache_tag && (up_be & ~selected_mask)==0;
    wire available=!reset && up_req && !accepted && !reply_valid;
    wire push=available && is_owned && up_write && count<DEPTH;
    wire pop=state==WRITE && down_ack;
    wire [PTR_BITS-1:0] next1=read_ptr+1'b1,next2=read_ptr+2'd2,next3=read_ptr+2'd3;
    wire [TAG_BITS-1:0] head_tag=queue[read_ptr][TAG_BITS+17:18];
    // Only four already-queued, aligned full-word stores may combine.
    // Never cross a line, reorder a store or acknowledge physical completion early.
    // Since the head is aligned, subsequent tags differ only in their lane bits.
    wire combine=LINE_WRITES && DEPTH>=4 && count>=4 && head_tag[1:0]==0 &&
        queue[read_ptr][17:16]==3 && queue[next1][17:16]==3 &&
        queue[next2][17:16]==3 && queue[next3][17:16]==3 &&
        queue[next1][TAG_BITS+17:18]=={head_tag[TAG_BITS-1:2],2'd1} &&
        queue[next2][TAG_BITS+17:18]=={head_tag[TAG_BITS-1:2],2'd2} &&
        queue[next3][TAG_BITS+17:18]=={head_tag[TAG_BITS-1:2],2'd3};
    wire wram_sel=up_addr[23:17]==7'h10;
    wire lc_known,lc_resident;
    wire [15:0] lc_word;
    wire lc_fill;
    generate if(WRAM_LINE_IW>0) begin : wram_lines
        gs_wram_line_cache #(.IW(WRAM_LINE_IW)) store(
            .clk(clk),.reset(reset),.rd_addr(up_req ? up_addr : look_addr),.req_addr(up_addr),
            .known(lc_known),.resident(lc_resident),.word(lc_word),
            .write_hit(push && wram_sel && lc_resident),
            .write_invalidate(push && wram_sel && !lc_known),
            .write_addr(up_addr),.write_be(up_be),.write_data(up_wdata),
            .fill(lc_fill),.fill_addr(held_addr),.fill_line(down_rline));
    end else begin : no_wram_lines
        assign lc_known=0;assign lc_resident=0;assign lc_word=0;
    end endgenerate
    wire line_hit=WRAM_LINE_IW>0 && wram_sel && !up_write && |up_be && lc_resident;
    // The resident line is coherent with every accepted write: writes update
    // it on admission, and fills happen only after the queue has drained.
    assign lc_fill=WRAM_LINE_IW>0 && state==DIRECT && down_ack && !direct_cancel && !reset && up_req &&
        held_read_line && held_addr[23:17]==7'h10 && !held_write;
    wire direct_request=available && !(is_owned && up_write) && !hit && !line_hit;
    wire rom_line=ROM_LINES && up_addr[23:20]==4'h0 && !up_write;
    wire line_read=(LINE_READS && up_addr[23:17]==7'h10 && !up_write) || rom_line;
    // A full-word private WRAM write retires on queue admission. Keep byte
    // stores on the registered path, including the game's byte RAM self-test.
    // The registered reply retains acknowledgement for a held request; push
    // excludes accepted requests, reset and a full queue. Physical completion
    // and the read/snapshot drain barriers retain their existing ownership.
    wire fast_write_ack=FAST_WRITE_ACK && push && up_addr[23:17]==7'h10 && up_be==2'b11;
    assign up_ack=(reply_valid || fast_write_ack) && up_req && !reset;
    // Match the registered posted-write reply even on the admission edge.
    assign up_rdata=fast_write_ack ? 16'h0000 : reply_data;
    assign up_rline=reply_line;
    assign down_req=state==WRITE || state==DIRECT;
    assign down_addr=held_addr;
    assign down_be=held_be;
    assign down_write=held_write;
    assign down_wdata=held_data;
    assign down_write_line=state==WRITE && held_words==4;
    assign down_wline=held_line;
    assign idle=state==IDLE && count==0 && !accepted && !reply_valid && !up_req;

    always @(posedge clk) begin
        if(!up_req || reset) begin accepted<=0;reply_valid<=0;end
        if(reset) cache_valid<=0;
        if(state==DIRECT && (reset || !up_req)) direct_cancel<=1;
        case({push,pop})
            2'b10: count<=count+1'b1;
            2'b01: count<=count-held_words;
            2'b11: count<=count+1'b1-held_words;
            default: ;
        endcase
        if(push) begin
            queue[write_ptr]<={word_tag,up_be,up_wdata};
            write_ptr<=write_ptr+1'b1;
            accepted<=1;reply_valid<=1;reply_data<=0;
            cache_valid<=1;cache_tag<=request_cache_tag;
            if(!cache_valid || cache_tag!=request_cache_tag) begin
                cache_mask<=write_mask;
                cache_data<=0;
            end else cache_mask<=cache_mask|write_mask;
            if(up_be[1]) cache_data[16*cache_lane+8 +: 8]<=up_wdata[15:8];
            if(up_be[0]) cache_data[16*cache_lane +: 8]<=up_wdata[7:0];
        end
        if(available && hit) begin
            accepted<=1;reply_valid<=1;reply_data<=selected_data;
        end else if(available && line_hit) begin
            accepted<=1;reply_valid<=1;reply_data<=lc_word;
        end
        case(state)
            IDLE: if(!down_ack) begin
                if(rom_line && direct_request) begin
                    held_read_line<=1;held_lane<=up_addr[2:1];
                    held_addr<={up_addr[23:3],3'b000};
                    held_be<=up_be;held_data<=up_wdata;
                    held_write<=0;accepted<=1;direct_cancel<=0;state<=DIRECT;
                end else if(count!=0) begin
                    held_addr<=decode_word(queue[read_ptr][TAG_BITS+17:18]);
                    held_be<=queue[read_ptr][17:16];held_data<=queue[read_ptr][15:0];
                    held_write<=1;state<=WRITE;held_words<=combine ? 4 : 1;
                    held_line<=combine ? {queue[next3][15:0],queue[next2][15:0],
                        queue[next1][15:0],queue[read_ptr][15:0]} : 64'b0;
                end else if(direct_request) begin
                    // Only private WRAM reads fetch an aligned spatial line. ROM,
                    // shared storage and video reads retain scalar address semantics.
                    held_read_line<=line_read;
                    held_lane<=LINE_READS ? up_addr[2:1] : 2'b00;
                    held_addr<=line_read ? {up_addr[23:3],3'b000} : up_addr;
                    held_be<=up_be;held_data<=up_wdata;
                    held_write<=up_write;accepted<=1;direct_cancel<=0;state<=DIRECT;
                end
            end
            WRITE: if(down_ack) begin read_ptr<=read_ptr+held_words;state<=GAP;end
            DIRECT: if(down_ack) begin
                state<=GAP;
                if(!direct_cancel && !reset && up_req) begin
                    reply_data<=held_read_line ? down_rline[16*held_lane +: 16] : down_rdata;reply_valid<=1;
                    reply_line<=down_rline;
                    if(owned(held_addr) && !held_write) begin
                        cache_valid<=1;
                        cache_tag<=LINE_READS ? held_tag[TAG_BITS-1:2] : held_tag;
                        if(held_read_line) begin
                            cache_mask<='1;cache_data<=down_rline;
                        end else begin
                            // Scalar owned-video reads fill only their own word.
                            cache_mask<=(2*CACHE_WORDS)'(2'b11) << (2*held_lane);
                            cache_data<=0;
                            cache_data[16*held_lane +: 16]<=down_rdata;
                        end
                    end
                end else accepted<=0;
            end
            GAP: if(!down_ack) state<=IDLE;
        endcase
    end
endmodule
