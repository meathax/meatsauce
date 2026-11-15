// Complete palette-index/priority scanline renderer with real double-buffer RAM.
// Front can be scanned while the back is cleared, tiled and sprite-composited.
// Every active operation uses clk. Main RAM and sprite descriptors have one-cycle reads.
module steel_video_line(
    input wire clk,reset,mortalr,start,swap,
    input wire [7:0] line_y,
    output wire busy,
    output reg done,
    output reg line_ready,
    output wire ram_en,
    output wire [16:0] ram_addr,
    input wire [15:0] ram_data,
    output wire sprite_en,
    output wire [7:0] sprite_index,
    input wire [63:0] sprite_data,
    output wire gfx_req,
    output wire [22:0] gfx_addr,
    input wire gfx_ready,
    input wire [63:0] gfx_data,
    input wire scan_en,
    input wire [8:0] scan_x,
    output wire [10:0] scan_index,
    output wire [4:0] scan_priority
);
    localparam IDLE=0,CLEAR=1,TILE_START=2,TILE_RUN=3,SPR_START=4,SPR_RUN=5,FLUSH0=6,FLUSH1=7;
    reg [2:0] state;
    reg [7:0] y,clear_addr;
    reg front,scan_front,scan_lane;
    // Rendering completion publishes a ready back bank. Only the raster may swap it.
    wire display_bank=(swap && line_ready && state==IDLE) ? !front : front;
    wire tile_done,spr_done,sprites_enabled,tile_gfx,spr_gfx;
    wire list_ready,list_empty,list_en;
    wire [7:0] list_last,list_index;
    wire [63:0] list_data;
    wire accept_start=state==IDLE && start && (!line_ready || swap);
    steel_sprite_list sprite_list(.clk(clk),.reset(reset),.start(accept_start),.line_y(line_y),
        .ready(list_ready),.empty(list_empty),.last_index(list_last),
        .source_en(sprite_en),.source_index(sprite_index),.source_data(sprite_data),
        .read_en(list_en),.read_index(list_index),.read_data(list_data));
    wire [22:0] tile_addr,spr_addr;
    wire [1:0] tile_valid,spr_valid;
    wire [8:0] tile_x,spr_x;
    wire [10:0] tile_index0,tile_index1,spr_index0,spr_index1;
    wire [4:0] tile_priority,spr_threshold;
    steel_tile_line tile(.clk(clk),.reset(reset),.mortalr(mortalr),.start(state==TILE_START),.line_y(y),
        .busy(),.done(tile_done),.ram_en(ram_en),.ram_addr(ram_addr),.ram_data(ram_data),
        .gfx_req(tile_gfx),.gfx_addr(tile_addr),.gfx_ready(gfx_ready && state==TILE_RUN),.gfx_data(gfx_data),
        .pixel_valid(tile_valid),.pixel_x(tile_x),.pixel_index0(tile_index0),.pixel_index1(tile_index1),
        .pixel_priority(tile_priority),.sprites_enabled(sprites_enabled));
    steel_sprite_line sprites(.clk(clk),.reset(reset),.mortalr(mortalr),.start(state==SPR_START && list_ready),.enabled(sprites_enabled && !list_empty),
        .line_y(y),.first_index(8'hff),.last_index(list_last),.busy(),.done(spr_done),
        .sprite_en(list_en),.sprite_index(list_index),.sprite_data(list_data),
        .gfx_req(spr_gfx),.gfx_addr(spr_addr),.gfx_ready(gfx_ready && state==SPR_RUN),.gfx_data(gfx_data),
        .pixel_valid(spr_valid),.pixel_x(spr_x),.pixel_index0(spr_index0),.pixel_index1(spr_index1),
        .pixel_threshold(spr_threshold));
    assign busy=state!=IDLE;
    assign gfx_req=state==TILE_RUN ? tile_gfx : state==SPR_RUN ? spr_gfx : 1'b0;
    assign gfx_addr=state==SPR_RUN ? spr_addr : tile_addr;
    wire is_sprite=state==SPR_RUN;
    wire active=state==TILE_RUN || state==SPR_RUN;
    wire [1:0] in_valid=active ? (is_sprite ? spr_valid : tile_valid) : 2'b0;
    wire [8:0] in_x=is_sprite ? spr_x : tile_x;
    wire [10:0] in_index0=is_sprite ? spr_index0 : tile_index0;
    wire [10:0] in_index1=is_sprite ? spr_index1 : tile_index1;
    wire [4:0] in_priority=is_sprite ? spr_threshold : tile_priority;
    reg [1:0] pending_valid;
    reg [7:0] pending_addr[0:1];
    reg [10:0] pending_index[0:1];
    reg [4:0] pending_priority;
    reg pending_sprite,pending_bank;
    wire [15:0] q[0:3];
    wire [15:0] scan_word=q[{scan_front,scan_lane}];
    assign scan_index=scan_word[10:0];
    assign scan_priority=scan_word[15:11];
    genvar b,l;
    generate for(b=0;b<2;b=b+1) begin: buffers
        for(l=0;l<2;l=l+1) begin: lanes
            localparam [0:0] BANK=b,LANE=l;
            wire second=in_x[0]!=LANE;
            wire valid=in_valid[second];
            wire [8:0] rx=in_x+{8'b0,second};
            wire [15:0] old=q[b*2+l];
            wire [4:0] next_priority=pending_sprite ? 5'd31 : old[15:11]|pending_priority;
            wire [10:0] next_index=(pending_sprite && old[15:11]>pending_priority) ? old[10:0] : pending_index[l];
            wire write_pixel=pending_valid[l] && pending_bank==BANK;
            wire clearing=state==CLEAR && front!=BANK;
            wire we=!reset && (clearing || write_pixel);
            wire [7:0] wa=clearing ? clear_addr : pending_addr[l];
            wire [15:0] wd=clearing ? 16'b0 : {next_priority,next_index};
            wire read_front=display_bank==BANK && scan_en && scan_x[0]==LANE;
            wire read_back=front!=BANK && valid;
            wire re=read_front || read_back;
            wire [7:0] ra=display_bank==BANK ? scan_x[8:1] : rx[8:1];
            wire [15:0] unused;
            steel_dpram8 #(.AW(8)) hi_bank(.clk(clk),.cpu_we(we),.cpu_addr(wa),.cpu_data(wd[15:8]),.cpu_q(unused[15:8]),
                .video_en(re),.video_addr(ra),.video_q(q[b*2+l][15:8]));
            steel_dpram8 #(.AW(8)) lo_bank(.clk(clk),.cpu_we(we),.cpu_addr(wa),.cpu_data(wd[7:0]),.cpu_q(unused[7:0]),
                .video_en(re),.video_addr(ra),.video_q(q[b*2+l][7:0]));
        end
    end endgenerate
    genvar m;
    generate for(m=0;m<2;m=m+1) begin: pending_lanes
        localparam [0:0] LANE=m;
        wire second=in_x[0]!=LANE;
        wire [8:0] rx=in_x+{8'b0,second};
        always_ff @(posedge clk) begin
            if(reset) pending_valid[m]<=0;
            else begin
                pending_valid[m]<=in_valid[second];
                pending_addr[m]<=rx[8:1];
                pending_index[m]<=second ? in_index1 : in_index0;
            end
        end
    end endgenerate
    always_ff @(posedge clk) begin
        pending_bank<=!front;pending_sprite<=is_sprite;pending_priority<=in_priority;
        if(scan_en) begin scan_front<=display_bank;scan_lane<=scan_x[0];end
        done<=0;
        if(reset) begin state<=IDLE;front<=0;line_ready<=0;y<=0;clear_addr<=0;scan_front<=0;scan_lane<=0;end
        else case(state)
            IDLE: begin
                if(swap && line_ready) begin front<=!front;line_ready<=0;end
                if(start && (!line_ready || swap)) begin y<=line_y;clear_addr<=0;state<=CLEAR;end
            end
            CLEAR: if(clear_addr==182) state<=TILE_START;else clear_addr<=clear_addr+1'b1;
            TILE_START:state<=TILE_RUN;
            TILE_RUN:if(tile_done)state<=SPR_START;
            SPR_START:if(list_ready)state<=SPR_RUN;
            SPR_RUN:if(spr_done)state<=FLUSH0;
            FLUSH0:state<=FLUSH1;
            FLUSH1:begin line_ready<=1;done<=1;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
