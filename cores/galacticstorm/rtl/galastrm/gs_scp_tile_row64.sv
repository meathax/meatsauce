// SPDX-License-Identifier: BSD-3-Clause
// TC0480SCP row fetch with one canonical 64-bit ROM beat (four BE words).
module gs_scp_tile_row64(
    input wire clk,reset,query,
    output wire query_ready,
    input wire [1:0] layer,
    input wire double_width,
    input wire [9:0] source_x,
    input wire [8:0] source_y,
    output wire ram_req,
    output wire [15:0] ram_addr,
    input wire ram_ack,
    input wire [15:0] ram_rdata,
    output wire rom_req,
    output wire [20:0] rom_addr,
    input wire rom_ack,
    input wire [63:0] rom_rdata,
    output reg valid,
    output reg [7:0] palette,
    output reg [63:0] pens
);
    localparam IDLE=0,ATTR=1,GAP_C=2,CODE=3,GAP_R=4,ROM=5;
    reg [2:0] state;
    reg [15:0] tile_address,attribute;
    reg [13:0] tile_code;
    reg [3:0] tile_y;
    wire [10:0] tile_index=double_width ? {source_y[8:4],source_x[9:4]} :
                                                        {1'b0,source_y[8:4],source_x[8:4]};
    wire [15:0] tile_base=double_width ? {1'b0,layer,13'b0} : {2'b0,layer,12'b0};
    wire [3:0] rom_y=tile_y^{4{attribute[15]}};
    wire [63:0] decoded;
    genvar w;
    generate for(w=0;w<4;w=w+1) begin: word_decode
        wire [15:0] d=rom_rdata[w*16 +: 16];
        assign decoded[w*16 +: 16]={d[7:4],d[3:0],d[15:12],d[11:8]};
    end endgenerate
    assign query_ready=state==IDLE;
    assign ram_req=state==ATTR || state==CODE;
    assign ram_addr=tile_address+(state==CODE ? 16'd2 : 16'd0);
    assign rom_req=state==ROM;
    assign rom_addr={tile_code,rom_y,3'b0};
    integer k;
    always @(posedge clk) begin
        valid<=0;
        case(state)
        IDLE: if(query && query_ready) begin
            tile_address<=tile_base+{3'b0,tile_index,2'b0};tile_y<=source_y[3:0];state<=ATTR;
        end
        ATTR: if(ram_ack) begin attribute<=ram_rdata;palette<=ram_rdata[7:0];state<=GAP_C;end
        GAP_C: state<=CODE;
        CODE: if(ram_ack) begin tile_code<=ram_rdata[13:0];state<=GAP_R;end
        GAP_R: state<=ROM;
        ROM: if(rom_ack) begin
            for(k=0;k<16;k=k+1) pens[k*4 +: 4]<=attribute[14] ? decoded[(15-k)*4 +: 4] : decoded[k*4 +: 4];
            valid<=1;state<=IDLE;
        end
        endcase
        if(reset) begin
            state<=IDLE;valid<=0;palette<=0;pens<=0;tile_address<=0;attribute<=0;tile_code<=0;tile_y<=0;
        end
    end
endmodule
