// Filter one scanline's descriptors while the tile renderer runs.
// Descending source order is retained in descending compact-list addresses.
// Entries use common-clock RAM; no derived clock or combinational memory read.
module steel_sprite_list(
    input wire clk,reset,start,
    input wire [7:0] line_y,
    output reg ready,
    output wire empty,
    output wire [7:0] last_index,
    output wire source_en,
    output wire [7:0] source_index,
    input wire [63:0] source_data,
    input wire read_en,
    input wire [7:0] read_index,
    output wire [63:0] read_data
);
    localparam IDLE=0,FIRST=1,SCAN=2,DRAIN=3;
    reg [1:0] state;
    reg [7:0] index,y;
    reg [8:0] count;
    wire [8:0] candidate_y={1'b0,y}+source_data[8:0]+9'd1;
    wire [8:0] height={1'b0,source_data[15:12],4'b0}+9'd16;
    wire signed [10:0] x=$signed({1'b0,source_data[57:48]})-11'sd7;
    wire eligible=source_data[11] && candidate_y<height && x<=373 && x+11'sd15>=8;
    wire write_entry=state==SCAN && eligible && !reset;
    wire [7:0] write_addr=8'd255-count[7:0];
    assign source_en=state==FIRST || (state==SCAN && index!=0);
    assign source_index=state==FIRST ? 8'd255 : index-8'd1;
    assign empty=count==0;
    assign last_index=8'b0-count[7:0];
    genvar b;
    generate for(b=0;b<8;b=b+1) begin: descriptor_bytes
        wire [7:0] unused;
        steel_dpram8 #(.AW(8)) bank(.clk(clk),.cpu_we(write_entry),.cpu_addr(write_addr),
            .cpu_data(source_data[b*8+:8]),.cpu_q(unused),.video_en(read_en),.video_addr(read_index),
            .video_q(read_data[b*8+:8]));
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin state<=IDLE;ready<=0;index<=0;y<=0;count<=0;end
        else case(state)
            IDLE:if(start) begin state<=FIRST;ready<=0;index<=255;y<=line_y;count<=0;end
            FIRST:state<=SCAN;
            SCAN:begin
                if(eligible)count<=count+1'b1;
                if(index==0)state<=DRAIN;else index<=index-1'b1;
            end
            DRAIN:begin ready<=1;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
