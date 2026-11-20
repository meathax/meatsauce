// SPDX-License-Identifier: BSD-3-Clause
// Native indexed TC0610 source: SCP backgrounds plus priority 1..3 sprites.
// Ordered sprite descriptors reside in an external arena; eight ownership rows
// are reused per band. Priority zero remains a later direct-screen pass.
module gs_source_frame(
    input wire clk,reset,
    output wire initialized,
    input wire cut,cpu_bus_idle,
    output wire cut_ready,cut_ack,
    input wire cpu_req,cpu_write,
    input wire [24:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    output wire cpu_mapped,cpu_ack,
    output wire [15:0] cpu_rdata,
    input wire query,
    output wire query_ready,
    input wire [383:0] controls,
    // Optional source window: only TC0610-sampled texels need rendering.
    // window_enable=0 renders the complete 512x400 plane.
    input wire window_enable,
    input wire [8:0] window_x0,window_x1,window_y0,window_y1,
    input wire [1:0] sample_shift_x,sample_shift_y,
    input wire sample_rows_enable,sample_row_used,sample_row_ready,
    output wire [8:0] sample_y,
    input wire [1:0] text_mem_req,
    input wire [31:0] text_mem_addr,
    output wire [1:0] text_mem_ack,
    output wire [31:0] text_mem_rdata,
    output reg frame_sealed,
    input wire direct_query,
    input wire [5:0] direct_query_band,
    output wire direct_query_ready,direct_query_done,direct_descriptor_valid,
    input wire direct_descriptor_ready,
    output wire [63:0] direct_descriptor,
    input wire direct_rom_req,
    input wire [19:0] direct_rom_addr,
    output wire direct_rom_ack,direct_rom_rvalid,
    output wire [63:0] direct_rom_data,
    output reg done,
    output wire supported,overflow,
    output wire [14:0] descriptor_count,
    output wire [17:0] node_count,
    output wire scp_rom_req,
    output wire [20:0] scp_rom_addr,
    input wire scp_rom_ack,
    input wire [63:0] scp_rom_rdata,
    output wire sprite_rom_req,
    output wire [21:0] sprite_rom_addr,
    input wire sprite_rom_ack,sprite_rom_rvalid,
    input wire [63:0] sprite_rom_rdata,
    output wire map_req,
    output wire [17:0] map_word_addr,
    input wire map_ack,
    input wire [15:0] map_rdata,
    output wire arena_req,arena_write,arena_wide,
    output wire [19:0] arena_addr,
    output wire [63:0] arena_wdata,
    input wire arena_ack,
    input wire [63:0] arena_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output wire [8:0] pixel_x,pixel_y,
    output wire [15:0] pixel_index,
    output wire [3:0] pixel_priority
);
    localparam IDLE=0,SCAN_START=1,SCAN_WAIT=2,BAND_START=3,BAND_WAIT=4,SCP_START=5,RUN=6,DRAIN=7;
    reg [2:0] state;
    reg [383:0] saved_controls;
    reg saved_window_enable;
    reg [35:0] saved_window;
    reg [1:0] saved_shift_x,saved_shift_y;
    reg [5:0] current_band;
    reg scp_started,pending;
    reg [8:0] saved_x,saved_y;
    reg [15:0] saved_index;
    reg [3:0] saved_priority;
    reg [37:0] fifo[0:1];
    reg read_pointer,write_pointer;
    reg [1:0] count;
    wire pop=pixel_valid && pixel_ready;
    wire [2:0] projected_count={1'b0,count}+{2'b0,pending}-{2'b0,pop};
    wire scp_valid,scp_ready,scp_done,scp_query_ready;
    wire [8:0] scp_x,scp_y;
    wire [15:0] scp_index;
    wire [3:0] scp_priority;
    wire frame_start_ready,frame_done;
    wire sprite_mem_req,sprite_mem_ack;
    wire [13:0] sprite_mem_addr;
    wire [31:0] sprite_mem_data;
    wire [4:0] aux_ack;
    wire [159:0] aux_data;
    wire band_start_ready,band_done,band_query,band_query_ready,band_query_done;
    wire [5:0] band_query_number;
    wire descriptor_valid,descriptor_ready;
    wire frame_query_ready,frame_query_done,frame_descriptor_valid,frame_descriptor_ready;
    reg query_active,query_owner,next_query_owner;
    wire selected_direct=direct_query && (!band_query || next_query_owner);
    wire frame_query=!query_active && (band_query || direct_query);
    wire [5:0] frame_query_band=selected_direct ? direct_query_band : band_query_number;
    // The overlay may wait for an old display bank to retire. Retain the
    // arena-ready event so a delayed consumer cannot miss its one-cycle pulse.
    always @(posedge clk) begin
        if(frame_done) frame_sealed<=1;
        if(reset || (query && query_ready)) frame_sealed<=0;
    end
    assign band_query_ready=!query_active && frame_query_ready && !selected_direct;
    assign direct_query_ready=!query_active && frame_query_ready && selected_direct;
    assign band_query_done=query_active && !query_owner && frame_query_done;
    assign direct_query_done=query_active && query_owner && frame_query_done;
    assign descriptor_valid=frame_descriptor_valid && query_active && !query_owner;
    assign direct_descriptor_valid=frame_descriptor_valid && query_active && query_owner;
    assign direct_descriptor=descriptor;
    assign frame_descriptor_ready=query_owner ? direct_descriptor_ready : descriptor_ready;
    reg rom_bus_req,rom_owner,next_rom_owner;
    reg [19:0] rom_bus_addr;
    wire rom_bus_ack,rom_bus_rvalid;
    // Accepted reads complete in order; remember each reply's owner.
    reg [1:0] reply_owner;
    reg [1:0] reply_count;
    wire reply_head=reply_owner[0];
    wire [63:0] rom_bus_data;
    wire selected_rom=direct_rom_req && (!band_rom_req || next_rom_owner);
    assign band_rom_ack=rom_bus_req && rom_bus_ack && !rom_owner;
    assign direct_rom_ack=rom_bus_req && rom_bus_ack && rom_owner;
    assign band_rom_rvalid=rom_bus_rvalid && !reply_head;
    assign direct_rom_rvalid=rom_bus_rvalid && reply_head;
    assign band_rom_data=rom_bus_data;
    assign direct_rom_data=rom_bus_data;
    wire [63:0] descriptor;
    wire lookup_ready,lookup_valid,owner_present;
    wire [11:0] owner_index;
    wire [1:0] owner_priority;
    wire probe_valid,cover_take;
    wire [8:0] probe_x,probe_y;
    reg [3:0] owner_cache_valid;
    reg [17:0] owner_cache_tag[0:3];
    reg [14:0] owner_cache_data[0:3];
    reg probe_pending;
    reg [1:0] probe_saved_slot;
    reg [17:0] probe_saved_tag;
    reg [14:0] output_owner,saved_owner;
    wire [1:0] probe_slot=probe_x>>saved_shift_x;
    wire cover_valid=owner_cache_valid[probe_slot] && owner_cache_tag[probe_slot]=={probe_y,probe_x};
    wire cover_front=cover_valid && owner_cache_data[probe_slot][14] && owner_cache_data[probe_slot][13:12]==3;
    reg probe_issue;
    reg [8:0] probe_address;
    reg [1:0] issue_slot;
    reg [9:0] candidate_x;
    reg [1:0] candidate_slot;
    integer ahead;
    // Four tagged entries retain the current owner plus two pixels of lookahead.
    // No cross-row speculation: the ownership bank must already be complete.
    always @* begin
        probe_issue=0;probe_address=probe_x;issue_slot=probe_slot;candidate_x=0;candidate_slot=0;
        for(ahead=0;ahead<3;ahead=ahead+1) begin
            candidate_x={1'b0,probe_x}+(ahead<<saved_shift_x);
            candidate_slot=candidate_x>>saved_shift_x;
            if(!probe_issue && state==RUN && probe_valid && probe_y[8:3]==current_band && lookup_ready &&
               candidate_x<=(saved_window_enable ? {1'b0,saved_window[26:18]} : 10'd511) &&
               !(owner_cache_valid[candidate_slot] && owner_cache_tag[candidate_slot]=={probe_y,candidate_x[8:0]}) &&
               !(probe_pending && probe_saved_tag=={probe_y,candidate_x[8:0]})) begin
                probe_issue=1;probe_address=candidate_x[8:0];issue_slot=candidate_slot;
            end
        end
    end
    wire band_rom_req,band_rom_ack,band_rom_rvalid;
    wire [19:0] band_rom_address;
    wire [63:0] band_rom_data;
    wire lookup_fire=state==RUN && scp_valid && scp_y[8:3]==current_band &&
                     projected_count<2;
    wire owner_allowed=saved_owner[14] &&
        ((saved_owner[13:12]==1 && saved_priority<4) ||
         (saved_owner[13:12]==2 && saved_priority<8) || saved_owner[13:12]==3);
    assign query_ready=state==IDLE && initialized && frame_start_ready;
    assign scp_ready=lookup_fire;
    assign sprite_mem_ack=aux_ack[0];
    assign sprite_mem_data=aux_data[31:0];
    assign text_mem_ack={aux_ack[3],aux_ack[4]};
    assign text_mem_rdata={aux_data[111:96],aux_data[143:128]};
    assign pixel_valid=count!=0;
    assign {pixel_x,pixel_y,pixel_index,pixel_priority}=fifo[read_pointer];
    gs_scp_video #(.SPRITE_FIRST(1)) scp(
        .cover_valid(cover_valid),.cover_front(cover_front),.probe_valid(probe_valid),
        .cover_take(cover_take),.probe_x(probe_x),.probe_y(probe_y),
        .clk(clk),.reset(reset),.initialized(initialized),.cut(cut),.cpu_bus_idle(cpu_bus_idle),
        .cut_ready(cut_ready),.cut_ack(cut_ack),.cpu_req(cpu_req),.cpu_write(cpu_write),
        .cpu_addr(cpu_addr),.cpu_wdata(cpu_wdata),.cpu_bytes(cpu_bytes),
        .cpu_mapped(cpu_mapped),.cpu_ack(cpu_ack),.cpu_rdata(cpu_rdata),
        .aux_req({text_mem_req[0],text_mem_req[1],2'b0,sprite_mem_req}),.aux_wide(5'b00001),
        .aux_addr({14'b0,2'd1,text_mem_addr[15:0],14'b0,2'd2,text_mem_addr[31:16],64'b0,18'b0,sprite_mem_addr}),.aux_ack(aux_ack),.aux_rdata(aux_data),
        .query(state==SCP_START),.query_ready(scp_query_ready),.controls(saved_controls),
        .window_enable(saved_window_enable),.window_x0(saved_window[35:27]),.window_x1(saved_window[26:18]),
        .window_y0(saved_window[17:9]),.window_y1(saved_window[8:0]),
        .sample_shift_x(saved_shift_x),.sample_shift_y(saved_shift_y),
        .sample_rows_enable(sample_rows_enable),.sample_row_used(sample_row_used),.sample_row_ready(sample_row_ready),.sample_y(sample_y),
        .done(scp_done),.supported(supported),.rom_req(scp_rom_req),.rom_addr(scp_rom_addr),
        .rom_ack(scp_rom_ack),.rom_rdata(scp_rom_rdata),
        .pixel_valid(scp_valid),.pixel_ready(scp_ready),.pixel_x(scp_x),.pixel_y(scp_y),
        .pixel_index(scp_index),.pixel_priority(scp_priority));
    gs_sprite_frame #(.SPLIT_PLANES(1),.WINDOW_CLIP(1)) sprites(
        .clk(clk),.reset(reset),.start(state==SCAN_START),.start_ready(frame_start_ready),
        .busy(),.done(frame_done),.overflow(overflow),.descriptor_count(descriptor_count),.node_count(node_count),
        .sprite_mem_req(sprite_mem_req),.sprite_mem_addr(sprite_mem_addr),.sprite_mem_ack(sprite_mem_ack),.sprite_mem_rdata(sprite_mem_data),
        .window_enable(saved_window_enable),.window_x0(saved_window[35:27]),.window_x1(saved_window[26:18]),
        .window_y0(saved_window[17:9]),.window_y1(saved_window[8:0]),
        .map_req(map_req),.map_word_addr(map_word_addr),.map_ack(map_ack),.map_rdata(map_rdata),
        .arena_req(arena_req),.arena_write(arena_write),.arena_wide(arena_wide),.arena_addr(arena_addr),
        .arena_wdata(arena_wdata),.arena_ack(arena_ack),.arena_rdata(arena_rdata),
        .query(frame_query),.query_band(frame_query_band),.query_direct(selected_direct),.query_ready(frame_query_ready),.query_done(frame_query_done),
        .output_valid(frame_descriptor_valid),.output_ready(frame_descriptor_ready),.output_descriptor(descriptor));
    gs_sprite_band_pair band_renderer(
        .clk(clk),.reset(reset),.start(state==BAND_START),.start_ready(band_start_ready),
        .band(current_band),.ready(),.done(band_done),
        .invalidate(state==IDLE && query && query_ready),
        .limit_band(saved_window_enable ? saved_window[8:3]+6'd1 : 6'd50),
        .query(band_query),.query_band(band_query_number),.query_ready(band_query_ready),.query_done(band_query_done),
        .descriptor_valid(descriptor_valid),.descriptor_ready(descriptor_ready),.descriptor(descriptor),
        .rom_req(band_rom_req),.rom_addr(band_rom_address),.rom_ack(band_rom_ack),.rom_rvalid(band_rom_rvalid),.rom_rdata(band_rom_data),
        .lookup_req(probe_issue),.lookup_ready(lookup_ready),.lookup_valid(lookup_valid),
        .lookup_row(probe_y[2:0]),.lookup_x(probe_address),
        .owner_present(owner_present),.owner_index(owner_index),.owner_priority(owner_priority));
    gs_sprite_rom64 sprite_rom(
        .req(rom_bus_req),.address(rom_bus_addr),.ack(rom_bus_ack),.rvalid(rom_bus_rvalid),.data(rom_bus_data),
        .raw_req(sprite_rom_req),.raw_address(sprite_rom_addr),.raw_ack(sprite_rom_ack),.raw_rvalid(sprite_rom_rvalid),.raw_data(sprite_rom_rdata));
    always @(posedge clk) begin
        done<=0;pending<=lookup_fire;
        probe_pending<=probe_issue;
        if(probe_issue) begin probe_saved_tag<={probe_y,probe_address};probe_saved_slot<=issue_slot;end
        if(probe_pending) begin
            owner_cache_valid[probe_saved_slot]<=1;owner_cache_tag[probe_saved_slot]<=probe_saved_tag;
            owner_cache_data[probe_saved_slot]<={owner_present,owner_priority,owner_index};
        end
        if(cover_take) output_owner<=owner_cache_data[probe_slot];
        if(frame_query && frame_query_ready) begin query_active<=1;query_owner<=selected_direct;end
        if(query_active && frame_query_done) begin query_active<=0;next_query_owner<=!query_owner;end
        begin: reply_order
            reg [1:0] owners;reg [1:0] count;
            owners=reply_owner;count=reply_count;
            if(rom_bus_rvalid) begin owners={1'b0,owners[1]};count=count-1'b1;end
            if(rom_bus_req && rom_bus_ack) begin owners[count[0]]=rom_owner;count=count+1'b1;end
            reply_owner<=owners;reply_count<=count;
        end
        if(rom_bus_req) begin
            if(rom_bus_ack) begin rom_bus_req<=0;next_rom_owner<=!rom_owner;end
        end else if(band_rom_req || direct_rom_req) begin
            rom_bus_req<=1;rom_owner<=selected_rom;rom_bus_addr<=selected_rom ? direct_rom_addr : band_rom_address;
        end
        if(lookup_fire) begin saved_x<=scp_x;saved_y<=scp_y;saved_index<=scp_index;saved_priority<=scp_priority;saved_owner<=output_owner;end
        if(pending) begin
            fifo[write_pointer]<={saved_x,saved_y,owner_allowed ? {4'b0,saved_owner[11:0]} : saved_index,saved_priority};
            write_pointer<=!write_pointer;
        end
        if(pop) read_pointer<=!read_pointer;
        count<=count+pending-pop;
        case(state)
        IDLE: if(query && query_ready) begin
            owner_cache_valid<=0;probe_pending<=0;
            saved_controls<=controls;scp_started<=0;state<=SCAN_START;
            saved_window_enable<=window_enable;saved_window<={window_x0,window_x1,window_y0,window_y1};
            saved_shift_x<=sample_shift_x;saved_shift_y<=sample_shift_y;
            current_band<=window_enable ? window_y0[8:3] : 6'd0;
        end
        SCAN_START: if(frame_start_ready) state<=SCAN_WAIT;
        SCAN_WAIT: if(frame_done) state<=BAND_START;
        BAND_START: if(band_start_ready) state<=BAND_WAIT;
        BAND_WAIT: if(band_done) state<=scp_started ? RUN : SCP_START;
        SCP_START: if(scp_query_ready) begin scp_started<=1;state<=RUN;end
        RUN: begin
            if(scp_done) state<=DRAIN;
            else if(probe_valid && probe_y[8:3]!=current_band && !pending && !probe_pending && !scp_valid) begin
                current_band<=probe_y[8:3];state<=BAND_START;
            end
        end
        DRAIN: if(!pending && count==0) begin done<=1;state<=IDLE;end
        endcase
        if(reset) begin
            owner_cache_valid<=0;probe_pending<=0;probe_saved_slot<=0;probe_saved_tag<=0;output_owner<=0;saved_owner<=0;
            query_active<=0;query_owner<=0;next_query_owner<=1;
            rom_bus_req<=0;rom_owner<=0;next_rom_owner<=1;rom_bus_addr<=0;reply_owner<=0;reply_count<=0;
            state<=IDLE;saved_controls<=0;current_band<=0;saved_window_enable<=0;saved_window<=0;scp_started<=0;pending<=0;done<=0;
            saved_shift_x<=0;saved_shift_y<=0;
            saved_x<=0;saved_y<=0;saved_index<=0;saved_priority<=0;read_pointer<=0;write_pointer<=0;count<=0;
            fifo[0]<=0;fifo[1]<=0;
        end
    end
endmodule
