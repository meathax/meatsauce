// SPDX-License-Identifier: BSD-3-Clause
// One native big-endian attribute/code pair and one canonical 64-bit ROM row.
module gs_scp_tile_pair64 #(parameter CACHE=0)(
    input wire invalidate,
    input wire clk,reset,query,
    output wire query_ready,
    input wire [1:0] layer,
    input wire double_width,
    input wire [9:0] source_x,
    input wire [8:0] source_y,
    output wire ram_req,
    output wire [15:0] ram_addr,
    input wire ram_ack,
    input wire [31:0] ram_rdata,
    output wire rom_req,
    output wire [20:0] rom_addr,
    input wire rom_ack,
    input wire [63:0] rom_rdata,
    output reg valid,
    output reg [7:0] palette,
    output reg [63:0] pens
);
    localparam IDLE=0,PAIR=1,ROM=2,LOOKUP=3;
    reg [1:0] state;
    reg [15:0] tile_address,attribute;
    reg [13:0] tile_code;
    reg [3:0] tile_y;
    wire [10:0] tile_index=double_width ? {source_y[8:4],source_x[9:4]} : {1'b0,source_y[8:4],source_x[8:4]};
    wire [15:0] tile_base=double_width ? {1'b0,layer,13'b0} : {2'b0,layer,12'b0};
    wire [15:0] query_address=tile_base+{3'b0,tile_index,2'b0};
    reg [63:0] pair_valid;
    reg [7:0] pair_tags[0:63];
    (* ramstyle="M10K, no_rw_check" *) reg [31:0] pair_data[0:63];
    reg [31:0] cached_pair;
    wire [5:0] read_slot=state==IDLE ? query_address[7:2] : tile_address[7:2];
    always @(posedge clk) begin
        cached_pair<=pair_data[read_slot];
        if(CACHE && state==PAIR && ram_ack) pair_data[tile_address[7:2]]<=ram_rdata;
    end
    wire [3:0] rom_y=tile_y^{4{attribute[15]}};
    wire [63:0] decoded;
    genvar w;
    generate for(w=0;w<4;w=w+1) begin: word_decode
        wire [15:0] d=rom_rdata[w*16 +: 16];
        assign decoded[w*16 +: 16]={d[7:4],d[3:0],d[15:12],d[11:8]};
    end endgenerate
    assign query_ready=state==IDLE;
    assign ram_req=state==PAIR;
    assign ram_addr=tile_address;
    assign rom_req=state==ROM;
    assign rom_addr={tile_code,rom_y,3'b0};
    integer k;
    always @(posedge clk) begin
        valid<=0;
        case(state)
        IDLE: if(query && query_ready) begin tile_address<=query_address;tile_y<=source_y[3:0];state<=CACHE ? LOOKUP : PAIR;end
        LOOKUP: if(pair_valid[tile_address[7:2]] && pair_tags[tile_address[7:2]]==tile_address[15:8]) begin
            attribute<=cached_pair[31:16];palette<=cached_pair[23:16];tile_code<=cached_pair[13:0];state<=ROM;
        end else state<=PAIR;
        PAIR: if(ram_ack) begin
            attribute<=ram_rdata[31:16];palette<=ram_rdata[23:16];tile_code<=ram_rdata[13:0];state<=ROM;
            if(CACHE) begin pair_valid[tile_address[7:2]]<=1;pair_tags[tile_address[7:2]]<=tile_address[15:8];end
        end
        ROM: if(rom_ack) begin
            for(k=0;k<16;k=k+1) pens[k*4 +: 4]<=attribute[14] ? decoded[(15-k)*4 +: 4] : decoded[k*4 +: 4];
            valid<=1;state<=IDLE;
        end
        endcase
        if(reset || invalidate) pair_valid<=0;
        if(reset) begin state<=IDLE;valid<=0;palette<=0;pens<=0;tile_address<=0;attribute<=0;tile_code<=0;tile_y<=0;end
    end
endmodule
