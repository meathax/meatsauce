// SPDX-License-Identifier: BSD-3-Clause
// Consume one native eight-line candidate band once, retaining first ownership
// in eight parallel-clear line RAMs. Rendering passes keep direct/rotated groups
// separate exactly as galastrm.cpp; background masks are applied downstream.
module gs_sprite_band #(parameter BANKS=1,parameter QUEUE_BITS=5)(
    input wire clk,reset,start,
    output wire start_ready,
    input wire [5:0] band,
    input wire start_bank,lookup_bank,
    input wire direct_mode,
    output wire ready,
    output reg done,
    output wire query,
    output wire [5:0] query_band,
    input wire query_ready,query_done,
    input wire descriptor_valid,
    output wire descriptor_ready,
    input wire [63:0] descriptor,
    output wire rom_req,
    output wire [19:0] rom_addr,
    input wire rom_ack,rom_rvalid,
    input wire [63:0] rom_rdata,
    input wire lookup_req,
    output wire lookup_ready,lookup_valid,
    input wire [2:0] lookup_row,
    input wire [8:0] lookup_x,
    output wire owner_present,
    output wire [11:0] owner_index,
    output wire [1:0] owner_priority
);
    localparam IDLE=0,CLEAR=1,QUERY=2,FETCH=3,ROW_LAUNCH=4,ROW_WAIT=5,
               NEXT_ROW=6,DRAIN=7,READY=8,CLEAR_START=9,SELECT_ROW=10;
    reg [3:0] state;
    reg [5:0] saved_band;
    reg saved_direct,query_ended;
    reg [63:0] current_descriptor;
    reg [8:0] current_y,end_y;
    reg [7:0] pending_rows;
    reg [2:0] saved_lookup_row;
    reg saved_build_bank,saved_lookup_bank;
    // Decouple arena traversal from pixel emission, so the shared list reader
    // can finish this query and serve the other plane while these rows render.
    localparam QUEUE_DEPTH=1<<QUEUE_BITS;
    (* ramstyle="MLAB, no_rw_check" *) reg [63:0] queue[0:QUEUE_DEPTH-1];
    reg [QUEUE_BITS-1:0] queue_head,queue_tail;
    reg accepting;
    reg [QUEUE_BITS:0] queue_count;
    wire queue_push=descriptor_valid && descriptor_ready;
    wire queue_pop=state==FETCH && queue_count!=0;
    reg [BANKS-1:0] store_ready;
    wire selected_start_bank=BANKS==1 ? 1'b0 : start_bank;
    wire selected_lookup_bank=BANKS==1 ? 1'b0 : lookup_bank;
    wire start_fire=start && start_ready;
    wire [BANKS*8-1:0] clear_busy,pixel_ready,lookup_ready_rows,lookup_valid_rows,present_rows,write_pending_rows;
    wire [11:0] indices[0:BANKS*8-1];
    wire [1:0] priorities[0:BANKS*8-1];
    wire [31:0] covered_groups[0:BANKS*8-1];
    wire [BANKS*8-1:0] exact_covered;
    wire [7:0] selected_clear_busy=clear_busy[8*saved_build_bank +:8];
    wire [7:0] selected_write_pending=write_pending_rows[8*saved_build_bank +:8];
    wire [7:0] selected_lookup_ready=lookup_ready_rows[8*selected_lookup_bank +:8];
    wire [3:0] lookup_slot={saved_lookup_bank,saved_lookup_row};
    wire row_ready,row_done,row_idle,row_pixel_valid,row_pixel_opaque,row_pixel_valid2,row_pixel_opaque2;
    wire [2:0] row_pixel_line;
    wire [1:0] row_pixel_priority;
    wire signed [11:0] row_pixel_x,row_pixel_x2;
    wire [11:0] row_pixel_index;
    wire [11:0] row_pixel_index2;
    wire [1:0] current_priority=current_descriptor[24:23];
    wire signed [11:0] source_x={{2{current_descriptor[36]}},current_descriptor[36:27]};
    wire signed [11:0] source_y={{2{current_descriptor[46]}},current_descriptor[46:37]};
    wire signed [11:0] row_end=source_x+$signed({5'b0,current_descriptor[53:47]});
    wire [11:0] row_last=row_end-12'd1;
    wire row_covered=source_x>=0 && row_end<=512 && row_end>source_x &&
        current_descriptor[53:47]<=64 && exact_covered[8*saved_build_bank+current_y[2:0]];
    wire signed [10:0] candidate_y=$signed(current_descriptor[46:37]);
    wire signed [10:0] candidate_end=candidate_y+$signed({4'b0,current_descriptor[60:54]});
    wire signed [10:0] band_first=$signed({2'b0,saved_band,3'b0});
    wire signed [10:0] band_end=band_first+11'sd8;
    wire signed [10:0] lower=saved_direct && band_first<84 ? 11'sd84 : band_first;
    wire signed [10:0] upper=saved_direct && band_end>316 ? 11'sd316 : band_end;
    wire signed [10:0] first_y=candidate_y>lower ? candidate_y : lower;
    wire signed [10:0] last_y=candidate_end<upper ? candidate_end : upper;
    wire matching_plane=saved_direct ? current_descriptor[24:23]==0 : current_descriptor[24:23]!=0;
    // Coverage is monotonic until this band's clear. Snapshot all useful rows
    // together, so completely hidden rows never enter the launch/advance loop.
    reg [7:0] candidate_rows;
    reg [2:0] first_candidate,next_candidate;
    wire [7:0] remaining_rows=pending_rows & ~(8'b1<<current_y[2:0]);
    integer r;
    always @* begin
        candidate_rows=0;first_candidate=0;next_candidate=0;
        for(r=7;r>=0;r=r-1) begin
            candidate_rows[r]=matching_plane && band_first+r>=first_y && band_first+r<last_y &&
                !(source_x>=0 && row_end<=512 && row_end>source_x && current_descriptor[53:47]<=64 &&
                  exact_covered[8*saved_build_bank+r]);
            if(candidate_rows[r]) first_candidate=r[2:0];
            if(remaining_rows[r]) next_candidate=r[2:0];
        end
    end
    wire pixel_in_clip=!saved_direct || (row_pixel_x>=96 && row_pixel_x<416);
    wire pixel2_in_clip=!saved_direct || (row_pixel_x2>=96 && row_pixel_x2<416);
    assign start_ready=state==IDLE || state==READY;
    assign ready=state==READY;
    assign query=state==QUERY;
    assign query_band=saved_band;
    assign descriptor_ready=accepting && queue_count!=QUEUE_DEPTH;
    assign lookup_ready=store_ready[selected_lookup_bank] && (&selected_lookup_ready);
    assign lookup_valid=store_ready[saved_lookup_bank] && lookup_valid_rows[8*saved_lookup_bank];
    assign owner_present=present_rows[lookup_slot];
    assign owner_index=indices[lookup_slot];
    assign owner_priority=priorities[lookup_slot];
    gs_sprite_row #(.SKIP_EMPTY(1),.PAIRED(1)) row_decoder(
        .clk(clk),.reset(reset),.command(state==ROW_LAUNCH && !row_covered),.command_ready(row_ready),
        .code(current_descriptor[14:0]),.color(current_descriptor[22:15]),
        .flipx(current_descriptor[25]),.flipy(current_descriptor[26]),
        .x(source_x),.y(source_y),.width(current_descriptor[53:47]),.height(current_descriptor[60:54]),
        .scanline(current_y),.priority_in(current_priority),.rom_addr(rom_addr),.rom_req(rom_req),.rom_ack(rom_ack),.rom_rvalid(rom_rvalid),.rom_rdata(rom_rdata),
        .pixel_valid(row_pixel_valid),.pixel_ready(pixel_ready[{saved_build_bank,row_pixel_line}]),
        .pixel_x(row_pixel_x),.pixel_index(row_pixel_index),.pixel_opaque(row_pixel_opaque),
        .pixel_valid2(row_pixel_valid2),.pixel_x2(row_pixel_x2),.pixel_index2(row_pixel_index2),.pixel_opaque2(row_pixel_opaque2),
        .pixel_line(row_pixel_line),.pixel_priority(row_pixel_priority),.idle(row_idle),.done(row_done)
    );
    genvar line;
    generate for(line=0;line<BANKS*8;line=line+1) begin: pool
        localparam BANK_NUMBER=line/8;
        localparam ROW_NUMBER=line%8;
        gs_sprite_line #(.PAIRED(1)) ownership(
            .clk(clk),.reset(reset),.clear_start(state==CLEAR_START && saved_build_bank==BANK_NUMBER),.clear_busy(clear_busy[line]),
            .pixel_valid(row_pixel_valid && saved_build_bank==BANK_NUMBER && row_pixel_line==ROW_NUMBER && pixel_in_clip),
            .pixel_ready(pixel_ready[line]),.pixel_x(row_pixel_x),.pixel_index(row_pixel_index),
            .pixel_priority(row_pixel_priority),.pixel_opaque(row_pixel_opaque),
            .pixel2_valid(row_pixel_valid2 && saved_build_bank==BANK_NUMBER && row_pixel_line==ROW_NUMBER && pixel2_in_clip),
            .pixel2_x(row_pixel_x2),.pixel2_index(row_pixel_index2),.pixel2_priority(row_pixel_priority),.pixel2_opaque(row_pixel_opaque2),
            .write_pending(write_pending_rows[line]),
            .lookup_mode(store_ready[BANK_NUMBER]),
            .lookup_req(lookup_req && store_ready[BANK_NUMBER] && selected_lookup_bank==BANK_NUMBER),.lookup_x(lookup_x),
            .lookup_ready(lookup_ready_rows[line]),.lookup_valid(lookup_valid_rows[line]),
            .owner_present(present_rows[line]),.owner_index(indices[line]),.owner_priority(priorities[line]),
            .covered_groups(covered_groups[line]),
            .coverage_first(source_x[8:0]),.coverage_last(row_last[8:0]),.range_covered(exact_covered[line])
        );
    end endgenerate
    always @(posedge clk) begin
        done<=0;
        if(query_done) query_ended<=1;
        if(lookup_req && lookup_ready) begin
            saved_lookup_row<=lookup_row;saved_lookup_bank<=selected_lookup_bank;
        end
        case(state)
        CLEAR_START: state<=CLEAR;
        CLEAR: if(selected_clear_busy==0) state<=QUERY;
        QUERY: if(query_ready) begin accepting<=1;state<=FETCH;end
        FETCH: if(queue_count!=0) begin
            current_descriptor<=queue[queue_head];state<=SELECT_ROW;
        end else if(query_ended && !queue_push) begin accepting<=0;state<=DRAIN;end
        SELECT_ROW: begin
            pending_rows<=candidate_rows;
            if(|candidate_rows) begin
                current_y<={saved_band,first_candidate};end_y<=last_y[8:0];
                state<=ROW_LAUNCH;
            end else state<=FETCH;
        end
        // The row decoder keeps rows in order; launch the next as soon as it accepts.
        ROW_LAUNCH: if(row_covered || row_ready) state<=NEXT_ROW;
        NEXT_ROW: begin
            pending_rows<=remaining_rows;
            if(remaining_rows==0) state<=FETCH;
            else begin current_y<={saved_band,next_candidate};state<=ROW_LAUNCH;end
        end
        DRAIN: if(row_idle && selected_write_pending==0) begin done<=1;state<=READY;store_ready[saved_build_bank]<=1;end
        endcase
        if(queue_push) begin queue[queue_tail]<=descriptor;queue_tail<=queue_tail+1'b1;end
        if(queue_pop) queue_head<=queue_head+1'b1;
        queue_count<=queue_count+{1'b0,queue_push}-{1'b0,queue_pop};
        if(start_fire) begin
            state<=CLEAR_START;accepting<=0;queue_head<=0;queue_tail<=0;queue_count<=0;saved_band<=band;saved_direct<=direct_mode;query_ended<=0;
            saved_build_bank<=selected_start_bank;store_ready[selected_start_bank]<=0;
        end
        if(reset) begin
            state<=IDLE;done<=0;saved_band<=0;saved_direct<=0;query_ended<=0;
            current_descriptor<=0;current_y<=0;end_y<=0;pending_rows<=0;saved_lookup_row<=0;
            saved_build_bank<=0;saved_lookup_bank<=0;store_ready<=0;
            accepting<=0;queue_head<=0;queue_tail<=0;queue_count<=0;
        end
    end
endmodule
