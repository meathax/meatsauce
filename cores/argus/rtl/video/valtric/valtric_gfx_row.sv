// SPDX-License-Identifier: GPL-3.0-or-later
// Packed-MSB row adapter with a bounded synchronous ROM working cache.
module valtric_gfx_row #(
    parameter integer CACHE_AW=13,
    parameter bit EXTERNAL_GFX_CACHE=1'b0
) (
    input logic clk_sys,reset,start,
    input logic [23:0] base,
    input logic [11:0] code,
    input logic text8,hflip,vflip,bypass,
    input logic [3:0] y,
    input logic preload_start,
    input logic [23:0] preload_addr,
    output logic preload_done,
    output logic busy,done,
    output logic [63:0] pixels,
    output logic req,
    output logic [23:0] addr,
    input logic ready,
    input logic [63:0] rdata
);
    typedef enum logic [2:0] {INITIALIZE,IDLE,LOOKUP,READ_CACHE,REQUEST,DECODE} state_t;
    state_t state;
    logic [23:0] byte_addr,second_addr;
    logic [63:0] word_l,cache_q;
    logic [31:0] first_half,row_bytes;
    localparam integer CACHE_WORDS=1<<CACHE_AW,TAG_W=22-CACHE_AW;
    logic text_l,hflip_l,half_l,preload_l,bypass_l;
    logic [CACHE_AW-1:0] init_index,cache_index;
    logic [TAG_W-1:0] tag_q;
    logic [63:0] decoded;
    integer p;
    // Spread high tile/domain bits across row and tile bits. Folding only into
    // the low row bits aliases the BG/text column-stride working sets. The tag
    // still stores every upper bit, so this XOR remains lossless for all words.
    assign cache_index=state==INITIALIZE ? init_index :
                       byte_addr[CACHE_AW+2:3]^CACHE_AW'(byte_addr[23:CACHE_AW+3])^
                       (CACHE_AW'(byte_addr[23:CACHE_AW+3])<<3);
    assign busy=state!=IDLE;
    assign req=state==REQUEST;
    assign addr={byte_addr[23:3],3'b000};
    assign row_bytes=byte_addr[2] ? word_l[63:32] : word_l[31:0];
    generate if(!EXTERNAL_GFX_CACHE)begin: local_cache
        (* ramstyle="M10K,no_rw_check" *) logic [TAG_W-1:0] cache_tag[0:CACHE_WORDS-1];
        (* ramstyle="M10K,no_rw_check" *) logic [63:0] cache_data[0:CACHE_WORDS-1];
        always_ff @(posedge clk_sys) begin
            cache_q<=cache_data[cache_index];tag_q<=cache_tag[cache_index];
            if(!reset && state==INITIALIZE)cache_tag[cache_index]<='0;
            else if(!reset && state==REQUEST && ready && !bypass_l)begin
                cache_tag[cache_index]<={1'b1,byte_addr[23:CACHE_AW+3]};cache_data[cache_index]<=rdata;
            end
        end
    end else begin: external_cache
        assign cache_q=64'd0;
        assign tag_q='0;
    end endgenerate
    always_comb begin
        decoded='0;
        for(integer k=0;k<8;k=k+1)
            decoded[k*4 +: 4]=row_bytes[(k/2)*8+(k%2==0 ? 4 : 0) +: 4];
    end
    always_ff @(posedge clk_sys)begin
        if(reset)begin
            state<=EXTERNAL_GFX_CACHE ? IDLE : INITIALIZE;init_index<=0;done<=0;preload_done<=0;pixels<=0;
            byte_addr<=0;second_addr<=0;word_l<=0;first_half<=0;
            text_l<=0;hflip_l<=0;half_l<=0;preload_l<=0;bypass_l<=0;
        end else begin
            done<=0;preload_done<=0;
            case(state)
                INITIALIZE:if(EXTERNAL_GFX_CACHE || &init_index)state<=IDLE;else init_index<=init_index+CACHE_AW'(1);
                IDLE:if(start)begin
                    text_l<=text8;hflip_l<=hflip;half_l<=0;preload_l<=0;bypass_l<=bypass || EXTERNAL_GFX_CACHE;
                    byte_addr<=base+(text8 ? {7'd0,code,5'd0} : {5'd0,code,7'd0})
                        +{18'd0,((text8 ? {1'b0,y[2:0]} : y)
                                ^(vflip ? (text8 ? 4'd7 : 4'd15) : 4'd0)),2'd0};
                    second_addr<=base+{5'd0,code,7'd0}+24'd64
                        +{18'd0,(y^(vflip ? 4'd15 : 4'd0)),2'd0};state<=bypass || EXTERNAL_GFX_CACHE ? REQUEST : LOOKUP;
                end else if(preload_start)begin
                    // The shared cache accepts preload and demand through the
                    // same held request; only our completion pulse distinguishes them.
                    byte_addr<={preload_addr[23:3],3'b000};preload_l<=1;bypass_l<=EXTERNAL_GFX_CACHE;
                    state<=EXTERNAL_GFX_CACHE ? REQUEST : LOOKUP;
                end
                LOOKUP:state<=READ_CACHE;
                READ_CACHE:if(tag_q=={1'b1,byte_addr[23:CACHE_AW+3]})begin
                    if(preload_l)begin preload_done<=1;state<=IDLE;end
                    else begin word_l<=cache_q;state<=DECODE;end
                end else state<=REQUEST;
                REQUEST:if(ready)begin word_l<=rdata;state<=DECODE;end
                DECODE:if(preload_l)begin preload_done<=1;state<=IDLE;end
                else if(!text_l && !half_l)begin
                    first_half<=decoded[31:0];half_l<=1;byte_addr<=second_addr;state<=bypass_l ? REQUEST : LOOKUP;
                end else begin
                    for(p=0;p<16;p=p+1)begin
                        if(text_l)begin
                            if(p<8)pixels[p*4 +: 4]<=decoded[(hflip_l ? 7-p : p)*4 +: 4];
                            else pixels[p*4 +: 4]<=4'hf;
                        end else if(hflip_l)begin
                            if(p<8)pixels[p*4 +: 4]<=decoded[(7-p)*4 +: 4];
                            else pixels[p*4 +: 4]<=first_half[(15-p)*4 +: 4];
                        end else begin
                            if(p<8)pixels[p*4 +: 4]<=first_half[p*4 +: 4];
                            else pixels[p*4 +: 4]<=decoded[(p-8)*4 +: 4];
                        end
                    end
                    done<=1;state<=IDLE;
                end
                default:state<=INITIALIZE;
            endcase
        end
    end
endmodule
