// SPDX-License-Identifier: BSD-3-Clause
// Prefetch the next ordered eight-row ownership band while SCP consumes this one.
// One external descriptor/ROM transaction stream is shared by the two banks.
module gs_sprite_band_pair #(parameter DIRECT_MODE=0,parameter FIRST_BAND=0,parameter LAST_BAND=50)(
    input wire clk,reset,start,
    output wire start_ready,
    input wire [5:0] band,
    // invalidate: a new frame begins (its first band need not be FIRST_BAND).
    // limit_band: no prefetch at or beyond this band in the current frame.
    input wire invalidate,
    input wire [5:0] limit_band,
    output wire ready,done,
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
    localparam IDLE=0,START=1,WAIT=2;
    reg [1:0] state,valid;
    reg active,build_bank;
    reg [5:0] desired_band,build_band;
    reg [5:0] tags[0:1];
    wire selected_bank=desired_band[0];
    wire desired_ready=valid[selected_bank] && tags[selected_bank]==desired_band;
    wire [5:0] next_band=desired_band+1'b1;
    wire next_ready=valid[next_band[0]] && tags[next_band[0]]==next_band;
    wire builder_ready,builder_done,builder_query,builder_descriptor_ready;
    wire builder_rom_req,store_lookup_ready;
    wire [5:0] builder_query_band;
    assign start_ready=1;
    assign ready=active && desired_ready;
    assign done=ready;
    assign query=state!=IDLE && builder_query;
    assign query_band=builder_query_band;
    assign descriptor_ready=state!=IDLE && builder_descriptor_ready;
    assign rom_req=state!=IDLE && builder_rom_req;
    assign lookup_ready=ready && store_lookup_ready;
    // Only one bank is built at a time. Keep both ownership stores, but share
    // the complete builder/row decoder while the other bank serves lookups.
    gs_sprite_band #(.BANKS(2)) renderer(
        .clk(clk),.reset(reset),.start(state==START),.start_ready(builder_ready),
        .band(build_band),.start_bank(build_bank),.lookup_bank(selected_bank),
        .direct_mode(DIRECT_MODE!=0),.ready(),.done(builder_done),
        .query(builder_query),.query_band(builder_query_band),
        .query_ready(query_ready && state!=IDLE),.query_done(query_done && state!=IDLE),
        .descriptor_valid(descriptor_valid && state!=IDLE),.descriptor_ready(builder_descriptor_ready),.descriptor(descriptor),
        .rom_req(builder_rom_req),.rom_addr(rom_addr),.rom_ack(rom_ack && state!=IDLE),.rom_rvalid(rom_rvalid && state!=IDLE),.rom_rdata(rom_rdata),
        .lookup_req(lookup_req && ready),.lookup_ready(store_lookup_ready),
        .lookup_valid(lookup_valid),.lookup_row(lookup_row),.lookup_x(lookup_x),
        .owner_present(owner_present),.owner_index(owner_index),.owner_priority(owner_priority));
    always @(posedge clk) begin
        if(start) begin
            desired_band<=band;active<=1;
            if(band==FIRST_BAND) valid<=0;
        end
        if(invalidate) valid<=0;
        case(state)
        IDLE: if(active) begin
            if(!desired_ready) begin
                build_band<=desired_band;build_bank<=selected_bank;valid[selected_bank]<=0;state<=START;
            end else if(next_band<LAST_BAND && next_band<limit_band && !next_ready) begin
                build_band<=next_band;build_bank<=next_band[0];valid[next_band[0]]<=0;state<=START;
            end
        end
        START: if(builder_ready) state<=WAIT;
        WAIT: if(builder_done) begin
            valid[build_bank]<=1;tags[build_bank]<=build_band;state<=IDLE;
        end
        endcase
        if(reset) begin
            state<=IDLE;valid<=0;active<=0;build_bank<=0;
            desired_band<=0;build_band<=0;tags[0]<=0;tags[1]<=0;
        end
    end
endmodule
