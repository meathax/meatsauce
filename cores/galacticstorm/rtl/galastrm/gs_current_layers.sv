// SPDX-License-Identifier: BSD-3-Clause
// Current priority-zero sprites, followed by SCP text and then SCN text.
// The source producer seals one shared ordered candidate arena per frame.
module gs_current_layers(
    input wire clk,reset,query,
    output wire query_ready,
    input wire frame_sealed,
    input wire [383:0] scp_controls,
    input wire [127:0] scn_controls,
    output reg done,
    output wire supported,
    output wire [1:0] mem_req,
    output wire [31:0] mem_addr,
    input wire [1:0] mem_ack,
    input wire [31:0] mem_rdata,
    output wire band_query,
    output wire [5:0] query_band,
    input wire band_query_ready,band_query_done,
    input wire descriptor_valid,
    output wire descriptor_ready,
    input wire [63:0] descriptor,
    output wire rom_req,
    output wire [19:0] rom_addr,
    input wire rom_ack,rom_rvalid,
    input wire [63:0] rom_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output wire [8:0] pixel_x,pixel_y,
    output wire [15:0] pixel_index
);
    localparam IDLE=0,WAIT_ARENA=1,BAND_START=2,RUN=3,DRAIN=4;
    reg [2:0] state;
    reg [5:0] current_band;
    wire text_ready,text_done,text_valid,text_pixel_ready;
    wire [8:0] text_x,text_y;
    wire [15:0] text_index;
    wire band_ready,lookup_ready,lookup_valid,owner_present;
    wire [11:0] owner_index;
    reg pending,read_pointer,write_pointer;
    reg [1:0] count;
    reg [8:0] saved_x,saved_y;
    reg [15:0] saved_index;
    reg [33:0] fifo[0:1];
    wire pop=pixel_valid && pixel_ready;
    wire [2:0] projected={1'b0,count}+{2'b0,pending}-{2'b0,pop};
    wire lookup_fire=state==RUN && text_valid && text_y[8:3]==current_band && lookup_ready && projected<2;
    assign query_ready=state==IDLE && text_ready;
    assign pixel_valid=count!=0;
    assign {pixel_x,pixel_y,pixel_index}=fifo[read_pointer];
    assign text_pixel_ready=lookup_fire;
    gs_current_text text(
        .clk(clk),.reset(reset),.query(query && query_ready),.query_ready(text_ready),
        .scp_controls(scp_controls),.scn_controls(scn_controls),.done(text_done),.supported(supported),
        .mem_req(mem_req),.mem_addr(mem_addr),.mem_ack(mem_ack),.mem_rdata(mem_rdata),
        .pixel_valid(text_valid),.pixel_ready(text_pixel_ready),.pixel_x(text_x),.pixel_y(text_y),.pixel_index(text_index));
    gs_sprite_band_pair #(.DIRECT_MODE(1),.FIRST_BAND(10),.LAST_BAND(40)) sprites(
        .invalidate(1'b0),.limit_band(6'd40),
        .clk(clk),.reset(reset),.start(state==BAND_START),.start_ready(),.band(current_band),.ready(band_ready),.done(),
        .query(band_query),.query_band(query_band),.query_ready(band_query_ready),.query_done(band_query_done),
        .descriptor_valid(descriptor_valid),.descriptor_ready(descriptor_ready),.descriptor(descriptor),
        .rom_req(rom_req),.rom_addr(rom_addr),.rom_ack(rom_ack),.rom_rvalid(rom_rvalid),.rom_rdata(rom_rdata),
        .lookup_req(lookup_fire),.lookup_ready(lookup_ready),.lookup_valid(lookup_valid),.lookup_row(text_y[2:0]),.lookup_x(text_x),
        .owner_present(owner_present),.owner_index(owner_index),.owner_priority());
    always @(posedge clk) begin
        done<=0;pending<=lookup_fire;
        if(lookup_fire) begin saved_x<=text_x;saved_y<=text_y;saved_index<=text_index;end
        if(pending) begin
            fifo[write_pointer]<={saved_x,saved_y,saved_index!=0 ? saved_index : owner_present ? {4'b0,owner_index} : 16'b0};
            write_pointer<=!write_pointer;
        end
        if(pop) read_pointer<=!read_pointer;
        count<=count+pending-pop;
        case(state)
        IDLE: if(query && query_ready) begin current_band<=10;state<=WAIT_ARENA;end
        WAIT_ARENA: if(frame_sealed) state<=BAND_START;
        BAND_START: state<=RUN;
        RUN: begin
            if(text_done) state<=DRAIN;
            else if(text_valid && text_y[8:3]!=current_band && !pending) begin current_band<=text_y[8:3];state<=BAND_START;end
        end
        DRAIN: if(!pending && count==0) begin done<=1;state<=IDLE;end
        endcase
        if(reset) begin
            state<=IDLE;current_band<=10;done<=0;pending<=0;count<=0;read_pointer<=0;write_pointer<=0;
            saved_x<=0;saved_y<=0;saved_index<=0;fifo[0]<=0;fifo[1]<=0;
        end
    end
endmodule
