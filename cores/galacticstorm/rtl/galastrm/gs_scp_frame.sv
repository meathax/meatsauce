// SPDX-License-Identifier: BSD-3-Clause
// Clocked full indexed source-plane renderer: four actual SCP line/tile lanes.
// Memory ports are held logical masters; physical arbitration/cache is external.
module gs_scp_frame #(parameter WIDE_TILE=0,parameter PREFETCH=0,parameter SPRITE_FIRST=0)(
    input wire cover_valid,cover_front,
    output wire probe_valid,cover_take,
    output wire [8:0] probe_x,probe_y,
    input wire clk,reset,query,
    output wire query_ready,
    input wire [383:0] controls,
    // Optional source window: only TC0610-sampled texels need rendering.
    // window_enable=0 renders the complete 512x400 plane.
    input wire window_enable,
    input wire [8:0] window_x0,window_x1,window_y0,window_y1,
    input wire [1:0] sample_shift_x,sample_shift_y,
    input wire sample_rows_enable,sample_row_used,sample_row_ready,
    output wire [8:0] sample_y,
    output reg done,supported,
    output wire [3:0] line_mem_req,
    output wire [63:0] line_mem_addr,
    input wire [3:0] line_mem_ack,
    input wire [63:0] line_mem_rdata,
    output wire [3:0] tile_mem_req,
    output wire [63:0] tile_mem_addr,
    input wire [3:0] tile_mem_ack,
    input wire [127:0] tile_mem_rdata,
    output wire [3:0] rom_req,
    output wire [127:0] rom_addr,
    input wire [3:0] rom_ack,
    input wire [255:0] rom_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output reg [8:0] pixel_x,pixel_y,
    output reg [15:0] pixel_index,
    output reg [3:0] pixel_priority
);
    localparam IDLE=0,LINE_QUERY=1,LINE_WAIT=2,STREAM=3,TILE_WAIT=4,FINISH=5,SKIP=6;
    reg [2:0] state;
    reg [383:0] saved_controls;
    reg [8:0] stream_x,stream_y;
    reg [8:0] x_first,x_last,y_last;
    reg [8:0] skip_remaining;
    reg [3:0] skip_bit;
    reg [1:0] shift_x,shift_y;
    wire [9:0] sample_step_x=10'd1<<shift_x,sample_step_y=10'd1<<shift_y;
    reg output_valid;
    reg [3:0] line_seen,tile_pending,cached_valid,prefetched;
    reg [5:0] requested_column[0:3];
    reg [31:0] u[0:3],step[0:3];
    reg [8:0] source_y[0:3];
    reg [3:0] wide;
    reg [5:0] cached_column[0:3];
    reg [63:0] cached_pens[0:3];
    reg [7:0] cached_palette[0:3];
    wire [3:0] line_ready,line_valid,line_supported,line_wide,tile_ready,tile_valid;
    wire [31:0] line_u[0:3],line_step[0:3];
    wire [8:0] line_y[0:3];
    wire [63:0] tile_pens[0:3];
    wire [7:0] tile_palette[0:3];
    wire [9:0] source_x[0:3];
    wire [9:0] query_x[0:3];
    wire [3:0] tile_query;
    wire [3:0] miss;
    wire all_line_ready=&line_ready;
    wire tiles_idle=(&tile_ready) && !(|tile_pending);
    wire row_needed=!sample_rows_enable || sample_row_used;
    wire row_ready=!sample_rows_enable || sample_row_ready;
    assign sample_y=stream_y;
    wire [47:0] layer_pixels;
    wire [3:0] layer_opaque;
    wire [11:0] composed_index;
    wire [3:0] composed_priority;
    wire unused_sprite_allowed;
    wire output_ready=!output_valid || pixel_ready;
    wire covered=SPRITE_FIRST && cover_front;
    wire stream_fire=state==STREAM && (!SPRITE_FIRST || cover_valid) &&
        (covered || !(|miss)) && output_ready;
    assign probe_valid=state==STREAM;
    assign probe_x=stream_x;
    assign probe_y=stream_y;
    assign cover_take=stream_fire;
    assign query_ready=state==IDLE;
    assign pixel_valid=output_valid;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: layers
        wire [20:0] lane_rom_address;
        wire [3:0] pen=cached_pens[lane][source_x[lane][3:0]*4 +: 4];
        assign source_x[lane]=wide[lane] ? u[lane][25:16] : {1'b0,u[lane][24:16]};
        assign miss[lane]=!cached_valid[lane] || cached_column[lane]!=source_x[lane][9:4];
        // SCP steps lie in [-65024,65536] fixed-point units, so looking
        // sixteen screen pixels ahead reaches at most the adjacent tile.
        wire [31:0] ahead_u=u[lane]+(step[lane]<<4);
        wire [9:0] ahead_x=wide[lane] ? ahead_u[25:16] : {1'b0,ahead_u[24:16]};
        wire buffered_hit=prefetched[lane] && requested_column[lane]==source_x[lane][9:4];
        wire fetch_ahead=PREFETCH && !miss[lane] && !prefetched[lane] &&
            {1'b0,stream_x}+10'd16<={1'b0,x_last} && ahead_x[9:4]!=source_x[lane][9:4];
        assign query_x[lane]=miss[lane] ? source_x[lane] : ahead_x;
        assign tile_query[lane]=state==STREAM && (!SPRITE_FIRST || (cover_valid && !covered)) && tile_ready[lane] && !tile_pending[lane] &&
            ((miss[lane] && !buffered_hit) || fetch_ahead);
        assign layer_pixels[lane*12 +: 12]={cached_palette[lane],pen};
        assign layer_opaque[lane]=pen!=0;
        assign rom_addr[lane*32 +: 32]={11'b0,lane_rom_address};
        gs_scp_line coordinate(
            .clk(clk),.reset(reset),.query(state==LINE_QUERY && all_line_ready && tiles_idle && row_ready && row_needed),
            .query_ready(line_ready[lane]),.layer(lane[1:0]),.screen_y(stream_y),.controls(saved_controls),
            .mem_req(line_mem_req[lane]),.mem_addr(line_mem_addr[lane*16 +: 16]),
            .mem_ack(line_mem_ack[lane]),.mem_rdata(line_mem_rdata[lane*16 +: 16]),
            .valid(line_valid[lane]),.supported(line_supported[lane]),.double_width(line_wide[lane]),
            .source_y(line_y[lane]),.u_start(line_u[lane]),.x_step(line_step[lane]));
        if(WIDE_TILE) begin: paired
        gs_scp_tile_pair64 #(.CACHE(1)) tile(
            .invalidate(query && query_ready),
            .clk(clk),.reset(reset),.query(tile_query[lane]),
            .query_ready(tile_ready[lane]),.layer(lane[1:0]),.double_width(wide[lane]),
            .source_x(query_x[lane]),.source_y(source_y[lane]),
            .ram_req(tile_mem_req[lane]),.ram_addr(tile_mem_addr[lane*16 +: 16]),
            .ram_ack(tile_mem_ack[lane]),.ram_rdata(tile_mem_rdata[lane*32 +: 32]),
            .rom_req(rom_req[lane]),.rom_addr(lane_rom_address),
            .rom_ack(rom_ack[lane]),.rom_rdata(rom_rdata[lane*64 +: 64]),
            .valid(tile_valid[lane]),.palette(tile_palette[lane]),.pens(tile_pens[lane]));
        end else begin: narrow
        gs_scp_tile_row64 tile(
            .clk(clk),.reset(reset),.query(tile_query[lane]),
            .query_ready(tile_ready[lane]),.layer(lane[1:0]),.double_width(wide[lane]),
            .source_x(query_x[lane]),.source_y(source_y[lane]),
            .ram_req(tile_mem_req[lane]),.ram_addr(tile_mem_addr[lane*16 +: 16]),
            .ram_ack(tile_mem_ack[lane]),.ram_rdata(tile_mem_rdata[lane*32 +: 16]),
            .rom_req(rom_req[lane]),.rom_addr(lane_rom_address),
            .rom_ack(rom_ack[lane]),.rom_rdata(rom_rdata[lane*64 +: 64]),
            .valid(tile_valid[lane]),.palette(tile_palette[lane]),.pens(tile_pens[lane]));
        end
    end endgenerate
    gs_scp_compose compose(
        .layer_pixels(layer_pixels),.layer_opaque(layer_opaque),
        .priority_order(saved_controls[244:242]),
        .pixel_index(composed_index),.background_priority(composed_priority),
        .sprite_present(1'b0),.sprite_priority(2'b0),.sprite_allowed(unused_sprite_allowed));
    integer l;
    always @(posedge clk) begin
        done<=0;
        if(output_valid && pixel_ready) output_valid<=0;
        if(stream_fire) begin
            output_valid<=1;pixel_x<=stream_x;pixel_y<=stream_y;
            pixel_index<=covered ? 16'b0 : {4'b0,composed_index};pixel_priority<=covered ? 4'b0 : composed_priority;
        end
        // Each tile decoder's existing output registers hold the prefetched
        // row. Promote it only on a matching column, then reuse that output
        // slot for another read while the current cached row is displayed.
        for(l=0;l<4;l=l+1) begin
            if(tile_query[l]) begin
                tile_pending[l]<=1;prefetched[l]<=0;requested_column[l]<=query_x[l][9:4];
            end
            if(tile_valid[l] && tile_pending[l]) begin tile_pending[l]<=0;prefetched[l]<=1;end
            if(state==STREAM && miss[l] && prefetched[l] && requested_column[l]==source_x[l][9:4]) begin
                cached_pens[l]<=tile_pens[l];cached_palette[l]<=tile_palette[l];
                cached_column[l]<=requested_column[l];cached_valid[l]<=1;prefetched[l]<=0;
            end
        end
        case(state)
        IDLE: if(query && query_ready) begin
            saved_controls<=controls;stream_x<=0;supported<=1;state<=LINE_QUERY;
            stream_y<=window_enable ? window_y0 : 9'd0;
            x_first<=window_enable ? window_x0 : 9'd0;
            x_last<=window_enable ? window_x1 : 9'd511;
            y_last<=window_enable ? window_y1 : 9'd399;
            shift_x<=sample_shift_x;shift_y<=sample_shift_y;
        end
        LINE_QUERY: if(all_line_ready && tiles_idle && row_ready) begin
            line_seen<=0;cached_valid<=0;prefetched<=0;
            if(row_needed) state<=LINE_WAIT;
            else if(stream_y==y_last) state<=FINISH;
            else stream_y<=stream_y+1'b1;
        end
        LINE_WAIT: begin
            for(l=0;l<4;l=l+1) if(line_valid[l]) begin
                line_seen[l]<=1;u[l]<=line_u[l];step[l]<=line_step[l];
                source_y[l]<=line_y[l];wide[l]<=line_wide[l];
            end
            if(|(line_valid&~line_supported)) supported<=0;
            if(&(line_seen|line_valid)) begin
                skip_remaining<=x_first;skip_bit<=0;
                stream_x<=x_first;
                state<=x_first!=0 ? SKIP : STREAM;
            end
        end
        // Add the clipped prefix in binary, modulo the same 32-bit phase.
        // This is exact for negative steps and coordinate wrap as well.
        SKIP: begin
            if(skip_remaining[0])
                for(l=0;l<4;l=l+1) u[l]<=u[l]+(step[l]<<skip_bit);
            skip_remaining<=skip_remaining>>1;
            skip_bit<=skip_bit+1'b1;
            if(skip_remaining[8:1]==0) state<=STREAM;
        end
        STREAM: begin
            if(stream_fire) begin
                for(l=0;l<4;l=l+1) u[l]<=u[l]+(step[l]<<shift_x);
                if({1'b0,stream_x}+sample_step_x>{1'b0,x_last}) begin
                    stream_x<=0;
                    if({1'b0,stream_y}+sample_step_y>{1'b0,y_last}) state<=FINISH;
                    else begin stream_y<=stream_y+sample_step_y[8:0];state<=LINE_QUERY;end
                end else stream_x<=stream_x+sample_step_x[8:0];
            end
        end
        FINISH: if((!output_valid || pixel_ready) && tiles_idle) begin done<=1;state<=IDLE;end
        endcase
        if(reset) begin
            state<=IDLE;saved_controls<=0;done<=0;supported<=0;pixel_x<=0;pixel_y<=0;
            stream_x<=0;stream_y<=0;output_valid<=0;pixel_index<=0;pixel_priority<=0;
            x_first<=0;x_last<=511;y_last<=399;
            skip_remaining<=0;skip_bit<=0;
            shift_x<=0;shift_y<=0;
            line_seen<=0;tile_pending<=0;cached_valid<=0;prefetched<=0;wide<=0;
            for(l=0;l<4;l=l+1) begin
                u[l]<=0;step[l]<=0;source_y[l]<=0;cached_column[l]<=0;cached_pens[l]<=0;cached_palette[l]<=0;requested_column[l]<=0;
            end
        end
    end
endmodule
