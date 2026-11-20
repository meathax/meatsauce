// SPDX-License-Identifier: BSD-3-Clause
// One Galastrm frame's native front-to-back sprite candidate stream.
// The caller supplies a stable render snapshot. This is not a line-time RAM scan.
module gs_sprite_scan #(
    parameter WINDOW_CLIP=0,
    // Canonical Galactic Storm sprite ROM tile zero contains only pen zero.
    parameter SKIP_TILE_ZERO=1
) (
    input wire clk,reset,start,
    output wire busy,
    output reg done,
    output wire sprite_mem_req,
    output reg [13:0] sprite_mem_addr,
    input wire sprite_mem_ack,
    input wire [31:0] sprite_mem_rdata,
    input wire window_enable,
    input wire [8:0] window_x0,window_x1,window_y0,window_y1,
    output wire map_req,
    output wire [17:0] map_word_addr,
    input wire map_ack,
    input wire [15:0] map_rdata,
    output wire descriptor_valid,
    input wire descriptor_ready,
    output wire [9:0] record_index,
    output wire [3:0] chunk_index,
    output wire [14:0] code,
    output wire [7:0] color,
    output wire [1:0] sprite_priority,
    output wire flipx,flipy,
    output wire signed [11:0] x,y,
    output wire [6:0] width,height
);
    localparam IDLE=0,READ0=1,GAP2=2,READ2=3,GAP3=4,READ3=5,
               LAUNCH=6,WAIT_CHUNK=7,NEXT_CHUNK=8,NEXT_RECORD=9;
    reg [3:0] state;
    reg [9:0] current_record;
    reg [3:0] current_chunk;
    reg [31:0] record0,record2,record3;
    wire command_ready,chunk_valid,chunk_enabled;
    wire signed [12:0] right=$signed(x)+$signed({6'b0,width});
    wire signed [12:0] bottom=$signed(y)+$signed({6'b0,height});
    wire direct=sprite_priority==0;
    wire clipped=WINDOW_CLIP && window_enable;
    wire intersects=direct ? (x<416 && right>96 && y<316 && bottom>84) :
        clipped ? ($signed(x)<=$signed({1'b0,window_x1}) && right>$signed({1'b0,window_x0}) &&
                   $signed(y)<=$signed({1'b0,window_y1}) && bottom>$signed({1'b0,window_y0})) :
                  (x<512 && right>0 && y<400 && bottom>0);
    wire emit_candidate=chunk_enabled && intersects && (!SKIP_TILE_ZERO || code!=0);
    wire consume=state==WAIT_CHUNK && chunk_valid && (!emit_candidate || descriptor_ready);
    assign descriptor_valid=state==WAIT_CHUNK && chunk_valid && emit_candidate;
    assign busy=state!=IDLE;
    assign record_index=current_record;
    assign chunk_index=current_chunk;
    assign sprite_mem_req=state==READ0 || state==READ2 || state==READ3;
    always @* begin
        sprite_mem_addr={current_record,4'b0};
        if(state==READ2) sprite_mem_addr={current_record,4'b1000};
        if(state==READ3) sprite_mem_addr={current_record,4'b1100};
    end
    gs_sprite_chunk setup(
        .clk(clk),.reset(reset),.command(state==LAUNCH),.command_ready(command_ready),
        .record0(record0),.record2(record2),.record3(record3),.chunk(current_chunk),
        .map_req(map_req),.map_word_addr(map_word_addr),.map_ack(map_ack),.map_rdata(map_rdata),
        .valid(chunk_valid),.ready(consume),.enabled(chunk_enabled),
        .code(code),.color(color),.sprite_priority(sprite_priority),.flipx(flipx),.flipy(flipy),
        .x(x),.y(y),.width(width),.height(height)
    );
    always @(posedge clk) begin
        done<=0;
        case(state)
        IDLE: if(start) begin current_record<=0;state<=READ0;end
        READ0: if(sprite_mem_ack) begin
            record0<=sprite_mem_rdata;
            state<=sprite_mem_rdata[14:0]==0 ? NEXT_RECORD : GAP2;
        end
        GAP2: state<=READ2;
        READ2: if(sprite_mem_ack) begin record2<=sprite_mem_rdata;state<=GAP3;end
        GAP3: state<=READ3;
        READ3: if(sprite_mem_ack) begin
            record3<=sprite_mem_rdata;
            current_chunk<=sprite_mem_rdata[18] ? 15 : 3;
            state<=LAUNCH;
        end
        LAUNCH: if(command_ready) state<=WAIT_CHUNK;
        WAIT_CHUNK: if(consume) state<=NEXT_CHUNK;
        NEXT_CHUNK: if(current_chunk==0) state<=NEXT_RECORD;
                    else begin current_chunk<=current_chunk-1'b1;state<=LAUNCH;end
        NEXT_RECORD: if(current_record==1023) begin done<=1;state<=IDLE;end
                     else begin current_record<=current_record+1'b1;state<=READ0;end
        endcase
        if(reset) begin
            state<=IDLE;done<=0;current_record<=0;current_chunk<=0;
            record0<=0;record2<=0;record3<=0;
        end
    end
endmodule
