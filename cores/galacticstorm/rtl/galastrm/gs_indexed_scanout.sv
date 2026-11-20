// SPDX-License-Identifier: BSD-3-Clause
// Prefetch the visible 320x232 indexed rectangle into a small word FIFO.
// pixel_ce is the visible-pixel enable from the native 512x400 raster.
module gs_indexed_scanout #(parameter FIFO_BITS=5,parameter FLIP_SUPPORT=0)(
    input wire clk,reset,start,
    input wire bank,flip,
    input wire pixel_ce,
    output wire pixel_valid,
    output wire [15:0] pixel_index,
    output reg underflow,busy,
    output wire mem_req,
    output wire mem_bank,
    output wire [15:0] mem_addr,
    output wire [14:0] mem_ordinal,
    input wire mem_ack,
    input wire [63:0] mem_data
);
    localparam DEPTH=1<<FIFO_BITS;
    reg saved_bank,saved_flip;
    reg [14:0] ordinal;
    assign mem_ordinal=saved_flip ? 15'd18559-ordinal : ordinal;
    reg [8:0] read_x,read_y;
    reg [FIFO_BITS-1:0] write_pointer,read_pointer;
    reg [FIFO_BITS:0] count;
    (* ramstyle="M10K, no_rw_check" *) reg [63:0] words[0:DEPTH-1];
    reg [63:0] ram_data,heads[0:1];
    reg pending,head_read,head_write;
    reg [1:0] head_count,lane;
    reg [16:0] pixels_consumed;
    // A pixel deadline without data leaves a deficit. The late word is then
    // discarded between pixel enables, so later pixels keep their position
    // instead of the whole remaining frame shifting.
    reg [3:0] deficit;
    assign mem_req=busy && ordinal<18560 && count<DEPTH;
    assign mem_bank=saved_bank;
    wire [8:0] effective_y=saved_flip ? 9'd399-read_y : read_y;
    wire [8:0] effective_x=saved_flip ? 9'd508-read_x : read_x;
    assign mem_addr={effective_y,effective_x[8:2]};
    wire head_available=head_count!=0;
    assign pixel_valid=head_available && deficit==0;
    assign pixel_index=heads[head_read][(saved_flip ? 2'd3-lane : lane)*16 +: 16];
    wire push=mem_req && mem_ack;
    wire discard=!pixel_ce && head_available && deficit!=0;
    wire consume=(pixel_ce && head_available) || discard;
    wire pop=consume && lane==3;
    wire [2:0] projected={1'b0,head_count}+{2'b0,pending}-{2'b0,pop};
    wire issue=count!=0 && projected<2;
    always @(posedge clk) begin
        ram_data<=words[read_pointer];
        if(push) words[write_pointer]<=mem_data;
    end
    always @(posedge clk) begin
        pending<=issue;
        count<=count+push-issue;
        if(push) begin
            write_pointer<=write_pointer+1'b1;ordinal<=ordinal+1'b1;
            if(read_x==412) begin read_x<=96;read_y<=read_y+1'b1;end
            else read_x<=read_x+4;
        end
        if(issue) read_pointer<=read_pointer+1'b1;
        if(pending) begin heads[head_write]<=ram_data;head_write<=!head_write;end
        if(pop) head_read<=!head_read;
        head_count<=head_count+pending-pop;
        if(consume) begin
            lane<=lane+1'b1;pixels_consumed<=pixels_consumed+1'b1;
            if(pixels_consumed==74239) busy<=0;
        end
        if(pixel_ce && !pixel_valid) underflow<=1;
        if(pixel_ce && !head_available && deficit!=15) deficit<=deficit+1'b1;
        else if(discard) deficit<=deficit-1'b1;
        if(start || reset) begin
            saved_bank<=bank;saved_flip<=FLIP_SUPPORT && flip;read_x<=96;read_y<=84;ordinal<=0;pixels_consumed<=0;
            write_pointer<=0;read_pointer<=0;count<=0;pending<=0;
            head_read<=0;head_write<=0;head_count<=0;lane<=0;underflow<=0;busy<=start && !reset;deficit<=0;
            heads[0]<=0;heads[1]<=0;
        end
    end
endmodule
