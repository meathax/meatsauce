// SPDX-License-Identifier: BSD-3-Clause
// MAME's zero destination fill and affine painting as one indexed visible stream.
// Sorted native shader pixels are held while zero gaps are emitted. No framebuffer.
module gs_tc0610_plane #(parameter STREAM_FILL=0)(
    input wire clk,reset,query,
    output wire query_ready,
    input wire signed [15:0] rzx,rzy,
    input wire pcb_mode,
    input wire [111:0] pcb_regs,
    output reg done,
    output wire mem_req,
    output wire [15:0] mem_addr,
    input wire mem_ack,
    input wire [63:0] mem_rdata,
    input wire mem_line_valid,
    input wire [2:0] mem_line_word,
    input wire [63:0] mem_line_data,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg [8:0] pixel_y,pixel_x,
    output wire [15:0] pixel_index
);
    localparam IDLE=0,ACTIVE=1,WAIT_DONE=2;
    reg [1:0] state;
    reg core_finished;
    wire core_ready,core_done,core_valid,core_pixel_ready;
    wire [8:0] core_x,core_y;
    wire [15:0] core_index;
    wire [17:0] core_position={core_y,core_x},position={pixel_y,pixel_x};
    wire match=core_valid && core_position==position;
    assign query_ready=state==IDLE && core_ready;
    assign pixel_valid=state==ACTIVE && ((core_valid && core_position>=position) || core_finished || core_done);
    assign pixel_index=match ? core_index : 16'b0;
    assign core_pixel_ready=state==ACTIVE && match && pixel_ready;
    gs_tc0610_cached #(.STREAM_FILL(STREAM_FILL)) renderer(
        .clk(clk),.reset(reset),.query(query && state==IDLE),.query_ready(core_ready),.rzx(rzx),.rzy(rzy),.pcb_mode(pcb_mode),.pcb_regs(pcb_regs),.done(core_done),
        .mem_req(mem_req),.mem_addr(mem_addr),.mem_ack(mem_ack),.mem_rdata(mem_rdata),
        .mem_line_valid(mem_line_valid),.mem_line_word(mem_line_word),.mem_line_data(mem_line_data),
        .pixel_valid(core_valid),.pixel_ready(core_pixel_ready),.pixel_y(core_y),.pixel_x(core_x),.pixel_index(core_index));
    always @(posedge clk) begin
        done<=0;
        if(core_done) core_finished<=1;
        case(state)
        IDLE: if(query && query_ready) begin state<=ACTIVE;core_finished<=0;pixel_x<=96;pixel_y<=84;end
        ACTIVE: if(pixel_valid && pixel_ready) begin
            if(pixel_x==415) begin
                pixel_x<=96;
                if(pixel_y==315) begin
                    if(core_finished || core_done) begin done<=1;state<=IDLE;end
                    else state<=WAIT_DONE;
                end else pixel_y<=pixel_y+1'b1;
            end else pixel_x<=pixel_x+1'b1;
        end
        WAIT_DONE: if(core_finished || core_done) begin done<=1;state<=IDLE;end
        endcase
        if(reset) begin state<=IDLE;core_finished<=0;pixel_x<=96;pixel_y<=84;done<=0;end
    end
endmodule
