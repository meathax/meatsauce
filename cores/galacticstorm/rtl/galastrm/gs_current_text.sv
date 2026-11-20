// SPDX-License-Identifier: BSD-3-Clause
// Current-frame SCP text followed by SCN text, in native visible pixel order.
// Eight-pixel row records are retained across output stalls and fetched only
// at each chip's own scroll-adjusted tile boundary. Zero denotes transparency.
module gs_current_text(
    input wire clk,reset,query,
    output wire query_ready,
    input wire [383:0] scp_controls,
    input wire [127:0] scn_controls,
    output reg done,
    output wire supported,
    output wire [1:0] mem_req,
    output wire [31:0] mem_addr,
    input wire [1:0] mem_ack,
    input wire [31:0] mem_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg [8:0] pixel_x,pixel_y,
    output wire [15:0] pixel_index
);
    localparam IDLE=0,CHECK=1,WAIT_ROWS=2,PIXEL=3;
    reg [1:0] state;
    reg [383:0] saved_scp;
    reg [127:0] saved_scn;
    reg [1:0] row_valid;
    reg [14:0] scp_tag,scn_tag;
    wire [8:0] scp_x=pixel_x-saved_scp[192 +: 9]-9'd37;
    wire [8:0] scp_y=pixel_y-saved_scp[208 +: 9]+9'd3;
    wire [8:0] scn_x=pixel_x-saved_scn[32 +: 9]-9'd32;
    wire [8:0] scn_y=pixel_y-saved_scn[80 +: 9]-9'd64;
    wire need_scp=!row_valid[0] || scp_tag!={scp_y,scp_x[8:3]};
    wire need_scn=!row_valid[1] || scn_tag!={scn_y,scn_x[8:3]};
    wire [1:0] row_done,row_supported;
    wire [95:0] scp_indices,scn_indices;
    wire [7:0] scp_opaque,scn_opaque;
    wire [11:0] scp_index=scp_indices[scp_x[2:0]*12 +: 12];
    wire [11:0] scn_index=scn_indices[scn_x[2:0]*12 +: 12];
    assign query_ready=state==IDLE;
    assign supported=&row_supported;
    assign pixel_valid=state==PIXEL;
    assign pixel_index=scn_opaque[scn_x[2:0]] ? {4'b0,scn_index} :
                       scp_opaque[scp_x[2:0]] ? {4'b0,scp_index} : 16'b0;
    gs_scp_text #(.CACHE_FONT(1)) scp(
        .invalidate(query && query_ready),
        .clk(clk),.reset(reset),.query(state==CHECK && need_scp),.x(pixel_x),.y(pixel_y),.controls(saved_scp),
        .valid(row_done[0]),.opaque(),.supported(row_supported[0]),.pixel_index(),
        .row_indices(scp_indices),.row_opaque(scp_opaque),
        .mem_req(mem_req[0]),.mem_addr(mem_addr[15:0]),.mem_ack(mem_ack[0]),.mem_rdata(mem_rdata[15:0]));
    gs_scn_text #(.CACHE_FONT(1)) scn(
        .invalidate(query && query_ready),
        .clk(clk),.reset(reset),.query(state==CHECK && need_scn),.x(pixel_x),.y(pixel_y),.controls(saved_scn),
        .valid(row_done[1]),.opaque(),.supported(row_supported[1]),.pixel_index(),
        .row_indices(scn_indices),.row_opaque(scn_opaque),
        .mem_req(mem_req[1]),.mem_addr(mem_addr[31:16]),.mem_ack(mem_ack[1]),.mem_rdata(mem_rdata[31:16]));
    always @(posedge clk) begin
        done<=0;
        if(row_done[0]) begin row_valid[0]<=1;scp_tag<={scp_y,scp_x[8:3]};end
        if(row_done[1]) begin row_valid[1]<=1;scn_tag<={scn_y,scn_x[8:3]};end
        case(state)
        IDLE: if(query) begin
            saved_scp<=scp_controls;saved_scn<=scn_controls;
            pixel_x<=96;pixel_y<=84;row_valid<=0;state<=CHECK;
        end
        CHECK: begin
            if(need_scp) row_valid[0]<=0;
            if(need_scn) row_valid[1]<=0;
            state<=(need_scp || need_scn) ? WAIT_ROWS : PIXEL;
        end
        WAIT_ROWS: if(&(row_valid | row_done)) state<=PIXEL;
        PIXEL: if(pixel_ready) begin
            if(pixel_x==415) begin
                pixel_x<=96;
                if(pixel_y==315) begin done<=1;state<=IDLE;end
                else begin pixel_y<=pixel_y+1'b1;state<=CHECK;end
            end else begin
                pixel_x<=pixel_x+1'b1;
                // Both retained rows still contain the successor pixel until
                // either independently scrolled tile crosses its boundary.
                state<=(scp_x[2:0]==7 || scn_x[2:0]==7) ? CHECK : PIXEL;
            end
        end
        endcase
        if(reset) begin
            state<=IDLE;done<=0;saved_scp<=0;saved_scn<=0;row_valid<=0;
            pixel_x<=96;pixel_y<=84;scp_tag<=0;scn_tag<=0;
        end
    end
endmodule
