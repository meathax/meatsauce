// SPDX-License-Identifier: GPL-3.0-or-later
// Packed-MSB 8x8 / 16x16 rows, using aligned little-endian 64-bit ROM bursts.
// The direct-mapped cache retains adjacent-row data across scanlines. It is
// invalidated by reset (and therefore by a ROM/game change), never by VRAM writes.
module butasan_gfx_row #(
    parameter integer RAW_OBJECT_STORE = 0,
    parameter integer SHARED_GFX_CACHE = 0
) (
    input logic clk_sys, reset, start,
    input logic [23:0] base,
    input logic [11:0] code,
    input logic text8, hflip, vflip,
    input logic [1:0] cache_lane,
    input logic [3:0] y,
    output logic busy, done,
    output logic [63:0] pixels,
    output logic req,
    output logic [23:0] addr,
    input logic ready,
    input logic [63:0] rdata
);
    typedef enum logic [1:0] {IDLE, CACHE_WAIT, FETCH} state_t;
    state_t state;
    // Shared preloaded object ROM needs no local object RAM, tags or valid bits.
    // Standalone mode retains 8192 object entries. BG0/BG1/text each retain
    // 1024 entries in both modes. Reads remain synchronous M10K-compatible.
    localparam integer CACHE_ENTRIES = RAW_OBJECT_STORE ? 3072 : 11264;
    localparam integer CACHE_BITS = RAW_OBJECT_STORE ? 12 : 14;
    logic [63:0] cache_q, decode_word;
    logic [10:0] tag_q;
    logic cache_valid_q;
    logic text_l, flip_l, half_l, upper_l;
    logic [1:0] lane_l;
    logic [CACHE_BITS-1:0] cache_index, lookup_index;
    logic cache_hit, consume_word;
    logic [23:0] first_addr;
    logic [3:0] row_y;
    logic [23:0] byte_addr;
    function automatic logic [CACHE_BITS-1:0] cache_address(input logic [1:0] lane,input logic [23:0] a);
        if(RAW_OBJECT_STORE) begin
            case(lane)
                2'd0: cache_address=CACHE_BITS'({2'b00,a[12:3]});
                2'd1: cache_address=CACHE_BITS'({2'b01,a[12:3]});
                2'd2: cache_address='0;
                default: cache_address=CACHE_BITS'({2'b10,a[12:3]});
            endcase
        end else begin
            case(lane)
                2'd0: cache_address=CACHE_BITS'({4'b1000,a[12:3]});
                2'd1: cache_address=CACHE_BITS'({4'b1001,a[12:3]});
                2'd2: cache_address=CACHE_BITS'({1'b0,a[15:3]});
                default: cache_address=CACHE_BITS'({4'b1010,a[12:3]});
            endcase
        end
    endfunction
    function automatic logic [10:0] cache_address_tag(input logic [1:0] lane,input logic [23:0] a);
        cache_address_tag=lane==2 ? {3'd0,a[23:16]} : a[23:13];
    endfunction
    always_comb begin
        row_y=y^(vflip ? (text8 ? 4'd7 : 4'd15) : 4'd0);
        byte_addr=base+(text8 ? {7'd0,code,5'd0} : {5'd0,code,7'd0})+
                  {18'd0,row_y,2'd0};
        busy=(state!=IDLE);
        req=(state==FETCH)&&!reset;
        cache_index=cache_address(lane_l,addr);
        cache_hit=!(SHARED_GFX_CACHE||(RAW_OBJECT_STORE&&lane_l==2))&&cache_valid_q&&
                  tag_q==cache_address_tag(lane_l,addr);
        consume_word=(state==CACHE_WAIT&&cache_hit)||(state==FETCH&&ready);
        decode_word=state==FETCH ? rdata : cache_q;
        // Prefetch the RAM lookup while starting/decoding, keeping synchronous
        // inferred memories without an extra address-only state for each burst.
        lookup_index=cache_index;
        if(state==IDLE) lookup_index=cache_address(cache_lane,byte_addr);
        else if(consume_word&&!text_l&&!half_l)
            lookup_index=cache_address(lane_l,first_addr+24'd64);
    end
    // The production shared-word path owns ROM lifetime and cache storage.
    // This generate branch removes every local data/tag/valid entry when used;
    // the default keeps standalone behavior and the historical comparison mode.
    generate
        if(SHARED_GFX_CACHE==0) begin: local_cache
            logic [63:0] cache_data [0:CACHE_ENTRIES-1];
            logic [10:0] cache_tag [0:CACHE_ENTRIES-1];
            logic [CACHE_ENTRIES-1:0] cache_valid;
            assign cache_valid_q=cache_valid[cache_index];
            always_ff @(posedge clk_sys) begin
                cache_q<=cache_data[lookup_index];
                tag_q<=cache_tag[lookup_index];
                if(reset) cache_valid<=0;
                else if(state==FETCH&&ready&&!(RAW_OBJECT_STORE&&lane_l==2)) begin
                    cache_valid[cache_index]<=1;
                    cache_data[cache_index]<=rdata;
                    cache_tag[cache_index]<=cache_address_tag(lane_l,addr);
                end
            end
        end else begin: shared_cache
            assign cache_q=64'd0;
            assign tag_q=11'd0;
            assign cache_valid_q=1'b0;
        end
    endgenerate
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE; addr<=0; first_addr<=0;
            done<=0; pixels<=0; text_l<=0; flip_l<=0;
            half_l<=0; upper_l<=0; lane_l<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    addr<={byte_addr[23:3],3'd0}; first_addr<={byte_addr[23:3],3'd0};
                    upper_l<=byte_addr[2]; text_l<=text8; flip_l<=hflip;
                    lane_l<=cache_lane;
                    half_l<=0; pixels<=0;
                    state<=SHARED_GFX_CACHE||(RAW_OBJECT_STORE&&cache_lane==2) ? FETCH : CACHE_WAIT;
                end
                CACHE_WAIT: begin
                    if(!cache_hit) state<=FETCH;
                end
                FETCH: ;
                default: state<=IDLE;
            endcase
            // Decode at acceptance; adjacent word lookup runs on this same edge.
            // Avoid a serialization bubble while retaining the held ROM protocol.
            if(consume_word) begin
                for(int x=0;x<8;x++) begin
                    pixels[((flip_l ? (text_l ? 7 : 15)-(half_l?8:0)-x : (half_l?8:0)+x)*4) +: 4]
                        <=decode_word[((upper_l?32:0)+(x/2)*8+((x%2)==0?4:0)) +: 4];
                end
                if(text_l || half_l) begin done<=1; state<=IDLE; end
                else begin
                    half_l<=1; addr<=first_addr+24'd64;
                    // Shared store accepts a new address while req stays high
                    // after ready. No cache lookup or low-req bubble needed.
                    state<=SHARED_GFX_CACHE||(RAW_OBJECT_STORE&&lane_l==2) ? FETCH : CACHE_WAIT;
                end
            end
        end
    end
endmodule
