// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only aligned ROM cache, invalidated on game reset/load completion.
module argus_video_rom_cache #(
    parameter integer AW=12,
    parameter logic [23:0] BYPASS_BASE=24'd0,
    parameter logic [23:0] BYPASS_BYTES=24'd0,
    parameter integer EXTERNAL_GFX_CACHE=0
) (
    input logic clk_sys,reset,
    input logic req,
    input logic [23:0] addr,
    output logic ready,
    output logic [63:0] rdata,
    input logic prefetch_req,
    input logic [23:0] prefetch_addr,
    output logic prefetch_ready,
    output logic mem_req,
    output logic [23:0] mem_addr,
    input logic mem_ready,
    input logic [63:0] mem_rdata
);
    // Keep the observation name stable; neither branch duplicates shared RAM.
    logic prefetch_l;
    generate if(EXTERNAL_GFX_CACHE!=0) begin: g_external
        argus_video_rom_forwarder forwarder_i (
            .clk_sys(clk_sys),.reset(reset),.req(req),.addr(addr),
            .ready(ready),.rdata(rdata),.prefetch_req(prefetch_req),
            .prefetch_addr(prefetch_addr),.prefetch_ready(prefetch_ready),
            .prefetch_active(prefetch_l),.mem_req(mem_req),.mem_addr(mem_addr),
            .mem_ready(mem_ready),.mem_rdata(mem_rdata));
    end else begin: g_local
    localparam integer TW=21-AW;
    typedef enum logic [1:0] {IDLE,LOOKUP,FETCH} state_t;
    state_t state;
    logic [23:0] address_l;
    logic [(1<<AW)-1:0] valid;
    logic [TW+63:0] cache_q;
    logic bypass_l;
    wire [23:0] next_address=req ? addr : prefetch_addr;
    wire [AW-1:0] latched_index=address_l[AW+2:3];
    wire [AW-1:0] next_index=next_address[AW+2:3];
    wire [AW-1:0] read_index=state==IDLE ? next_index : latched_index;
    wire [TW-1:0] tag=address_l[23:AW+3];
    wire next_bypass=BYPASS_BYTES!=0 && next_address>=BYPASS_BASE &&
                     next_address<BYPASS_BASE+BYPASS_BYTES;
    wire fill=state==FETCH && mem_ready && !bypass_l;
    wire hit=valid[latched_index] && cache_q[TW+63:64]==tag;
    wire response=(state==LOOKUP && hit) || (state==FETCH && mem_ready);
    jtframe_dual_ram #(.DW(TW+64),.AW(AW)) data_ram (
        .clk0(clk_sys),.addr0(read_index),.data0({tag,mem_rdata}),.we0(fill),.q0(cache_q),
        .clk1(clk_sys),.addr1({AW{1'b0}}),.data1({(TW+64){1'b0}}),.we1(1'b0),.q1());
    assign mem_req=(state==FETCH)&&!reset;
    assign mem_addr=address_l;
    // Return directly on a RAM hit / physical response. The requester changes
    // its next address only after this edge; every physical miss stays stable.
    assign ready=response && !prefetch_l && !reset;
    assign prefetch_ready=response && prefetch_l && !reset;
    assign rdata=state==LOOKUP ? cache_q[63:0] : mem_rdata;
    always_ff @(posedge clk_sys) begin
        if(reset) begin state<=IDLE;address_l<=0;valid<=0;prefetch_l<=0;bypass_l<=0;end
        else case(state)
            IDLE: if(req || prefetch_req) begin
                address_l<={next_address[23:3],3'd0};prefetch_l<=!req;bypass_l<=next_bypass;
                // Shared GFX1 storage is already a lossless local ROM. Keep
                // the stable transaction latch, but do not duplicate its data.
                // Invalid slots cannot hit: start the physical fill without
                // spending a clock reading an irrelevant synchronous tag.
                state<=(next_bypass || !valid[next_index]) ? FETCH : LOOKUP;
            end
            LOOKUP: state<=hit ? IDLE : FETCH;
            FETCH: if(mem_ready) begin
                if(!bypass_l) valid[latched_index]<=1;
                state<=IDLE;
            end
            default: state<=IDLE;
        endcase
    end
    end endgenerate
endmodule

// One held transaction arbiter, with no graphics/tag/valid RAM. A speculative
// read already accepted by the external cache drains before a new demand read.
module argus_video_rom_forwarder (
    input logic clk_sys,reset,req,
    input logic [23:0] addr,
    output logic ready,
    output logic [63:0] rdata,
    input logic prefetch_req,
    input logic [23:0] prefetch_addr,
    output logic prefetch_ready,prefetch_active,
    output logic mem_req,
    output logic [23:0] mem_addr,
    input logic mem_ready,
    input logic [63:0] mem_rdata
);
    logic active,owner_prefetch;
    logic [23:0] address_l;
    assign mem_req=active && !reset;
    assign mem_addr=address_l;
    assign rdata=mem_rdata;
    assign ready=active && !owner_prefetch && mem_ready && !reset && req &&
                 {addr[23:3],3'd0}==address_l;
    // Accepted speculation may finish after the renderer has left idle.
    assign prefetch_ready=active && owner_prefetch && mem_ready && !reset;
    assign prefetch_active=active && owner_prefetch;
    always_ff @(posedge clk_sys) begin
        if(reset) begin active<=0;owner_prefetch<=0;address_l<=0;end
        else if(active) begin
            if(mem_ready) active<=0;
        end else if(!mem_ready && (req || prefetch_req)) begin
            // The low-ready guard also absorbs a held/stale reply after reset
            // or an acknowledgement before accepting another transaction.
            active<=1;owner_prefetch<=!req;
            address_l<=req ? {addr[23:3],3'd0} : {prefetch_addr[23:3],3'd0};
        end
    end
endmodule

// Speculation fills the existing immutable ROM cache only. Live map/palette
// fields and object order are still sampled by the demand renderer.
module argus_video_bg_prefetch #(
    parameter integer ENABLE=1,
    parameter logic [23:0] VROM1_BASE=24'd0,VROM2_BASE=24'd0,TEXT_BASE=24'd0
) (
    input logic clk_sys,reset,core_idle,line_start,line_finish,
    input logic [15:0] scroll_x,
    input logic flip,
    input logic [9:0] rendered_y,
    input logic [7:0] text_lo,text_hi,
    output logic [10:0] map_addr,
    output logic req,
    output logic [23:0] addr,
    input logic ready,
    input logic [63:0] rdata
);
    typedef enum logic [3:0] {
        WINDOW_BEGIN,V1_SETUP,V1_REQUEST,V2_SETUP,V2_REQUEST,
        WAIT_LINE,TEXT_WAIT1,TEXT_WAIT2,TEXT_REQUEST
    } pf_state_t;
    pf_state_t state;
    logic [15:0] window_scroll;
    logic window_flip;
    logic [4:0] window_column,text_column;
    logic [1:0] entry_index;
    logic upper_half,text_pending;
    logic [63:0] v1_word;
    logic [9:0] next_y,text_target_y;
    logic next_flip,text_target_flip;
    logic [9:0] sx;
    logic [17:0] tile_byte;
    logic [14:0] v1_byte;
    logic [15:0] pointer_word;
    logic [7:0] text_source_y;
    logic [2:0] glyph_y;
    wire window_dirty=window_scroll!=scroll_x || window_flip!=flip;
    always_comb begin
        sx=window_flip ? 10'd511+{2'd0,window_scroll[7:0]}-{1'b0,window_column,4'd0}
                       : {2'd0,window_scroll[7:0]}+{1'b0,window_column,4'd0};
        tile_byte={1'b0,({(window_scroll[15:8]+{7'd0,window_flip}),9'd0}+
                         {6'd0,sx[9:4],5'd0})};
        tile_byte=tile_byte<<1;
        v1_byte={tile_byte[17:4],1'b0};
        pointer_word=16'(v1_word >> {entry_index,4'd0});
        text_source_y=text_target_flip ? 8'd255-text_target_y[7:0] : text_target_y[7:0];
        glyph_y=text_source_y[2:0]^{3{text_hi[5]}};
        map_addr={text_column,text_source_y[7:3],1'b0};
        req=ENABLE!=0 && core_idle && !line_start &&
            (state==V1_REQUEST || state==V2_REQUEST || state==TEXT_REQUEST);
    end
    always_ff @(posedge clk_sys) begin
        if(reset || ENABLE==0) begin
            state<=WINDOW_BEGIN;window_scroll<=0;window_flip<=0;
            window_column<=0;text_column<=0;entry_index<=0;upper_half<=0;
            text_pending<=0;v1_word<=0;addr<=0;next_y<=0;text_target_y<=0;
            next_flip<=0;text_target_flip<=0;
        end else begin
            if(line_finish) begin
                next_y<=rendered_y+10'd1;next_flip<=flip;text_pending<=1;
            end
            case(state)
                WINDOW_BEGIN: if(core_idle && !line_start) begin
                    window_scroll<=scroll_x;window_flip<=flip;window_column<=0;
                    state<=V1_SETUP;
                end
                V1_SETUP: begin
                    addr<=VROM1_BASE+{9'd0,v1_byte[14:3],3'd0};state<=V1_REQUEST;
                end
                V1_REQUEST: if(ready) begin
                    if(window_dirty) state<=WINDOW_BEGIN;
                    else begin v1_word<=rdata;entry_index<=0;upper_half<=0;state<=V2_SETUP;end
                end
                V2_SETUP: begin
                    addr<=VROM2_BASE+{9'd0,pointer_word[10:8],pointer_word[7:0],upper_half,3'd0};
                    state<=V2_REQUEST;
                end
                V2_REQUEST: if(ready) begin
                    if(window_dirty) state<=WINDOW_BEGIN;
                    else if(!upper_half) begin upper_half<=1;state<=V2_SETUP;end
                    else if(entry_index!=3) begin entry_index<=entry_index+2'd1;upper_half<=0;state<=V2_SETUP;end
                    else if(window_column!=16) begin window_column<=window_column+5'd1;state<=V1_SETUP;end
                    else state<=WAIT_LINE;
                end
                WAIT_LINE: begin
                    if(window_dirty) state<=WINDOW_BEGIN;
                    else if(text_pending && core_idle && !line_start) begin
                        text_target_y<=next_y;text_target_flip<=next_flip;
                        text_column<=0;text_pending<=0;state<=TEXT_WAIT1;
                    end
                end
                TEXT_WAIT1: if(core_idle && !line_start) state<=TEXT_WAIT2;
                TEXT_WAIT2: if(core_idle && !line_start) begin
                    addr<=TEXT_BASE+{9'd0,text_hi[7:6],text_lo,5'd0}+{19'd0,glyph_y[2:1],3'd0};
                    state<=TEXT_REQUEST;
                end
                TEXT_REQUEST: if(ready) begin
                    if(window_dirty) state<=WINDOW_BEGIN;
                    else if(text_pending) state<=WAIT_LINE;
                    else if(text_column!=31) begin text_column<=text_column+5'd1;state<=TEXT_WAIT1;end
                    else state<=WAIT_LINE;
                end
                default: state<=WINDOW_BEGIN;
            endcase
        end
    end
endmodule

// Immutable sprite graphics can be fetched ahead of the line without changing
// when the renderer samples live sprite fields. Scan all 96 records in rounds:
// both halves of the first visible pair, then the following pairs. Demand reads
// have priority in the shared cache; an accepted physical read is never aborted.
module argus_video_sprite_prefetch #(
    parameter logic [23:0] GFX_BASE=24'd0
) (
    input logic clk_sys,reset,
    input logic cpu_write,
    input logic [10:0] cpu_addr,
    input logic [7:0] cpu_data,
    input logic flip,line_seen,
    input logic [9:0] native_y,
    output logic req,
    output logic [23:0] addr,
    input logic ready
);
    typedef enum logic [2:0] {WAIT_FIELDS,EVALUATE,REQUEST,NEXT_RECORD,URGENT_WAIT} pf_state_t;
    pf_state_t state;
    logic [6:0] index;
    logic [3:0] word_round;
    logic [7:0] fields[0:4];
    logic signed [10:0] object_x,object_y,dy;
    logic eligible;
    logic restart_pending,last_flip;
    logic urgent_active;
    logic [6:0] saved_index,urgent_write_pointer,urgent_read_pointer,urgent_q;
    logic [3:0] saved_round;
    logic [7:0] urgent_count;
    wire urgent_push=cpu_write && cpu_addr[3:0]==14 && urgent_count<128;
    wire urgent_pop=state==EVALUATE && !urgent_active && urgent_count!=0;
    logic [2:0] row_pair;
    genvar field;
    generate for(field=0;field<5;field=field+1) begin: g_fields
        jtframe_dual_ram #(.DW(8),.AW(7)) field_ram (
            .clk0(clk_sys),.addr0(cpu_addr[10:4]),.data0(cpu_data),
            .we0(cpu_write && cpu_addr[3:0]==4'(11+field)),.q0(),
            .clk1(clk_sys),.addr1(index),.data1(8'd0),.we1(1'b0),.q1(fields[field]));
    end endgenerate
    // The code low-byte write follows its attribute byte in the game tables.
    // Queue that record's first visible row pair immediately. Queue overflow
    // only discards speculation; demand rendering still reads every object.
    jtframe_dual_ram #(.DW(7),.AW(7)) urgent_records (
        .clk0(clk_sys),.addr0(urgent_write_pointer),.data0(cpu_addr[10:4]),.we0(urgent_push),.q0(),
        .clk1(clk_sys),.addr1(urgent_read_pointer),.data1(7'd0),.we1(1'b0),.q1(urgent_q));
    always_comb begin
        object_x=$signed({3'd0,fields[1]})-(fields[2][0] ? 11'sd256 : 11'sd0);
        object_y=$signed({3'd0,fields[0]})-(fields[2][1] ? 11'sd0 : 11'sd256);
        if(flip) begin object_x=11'sd240-object_x;object_y=11'sd240-object_y;end
        dy=$signed({1'b0,native_y})+11'sd1-object_y;
        eligible=!(fields[4]==0 && fields[0]==8'hf0) && object_x<256 && object_x> -16 &&
                 (!line_seen || (dy>=-32 && dy<16));
        row_pair=word_round[3:1] ^ {3{fields[2][5]^flip}};
        req=state==REQUEST;
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            state<=WAIT_FIELDS;index<=0;word_round<=0;addr<=0;restart_pending<=0;last_flip<=0;
            urgent_active<=0;saved_index<=0;saved_round<=0;
            urgent_write_pointer<=0;urgent_read_pointer<=0;urgent_count<=0;
        end
        else begin
        last_flip<=flip;
        if(urgent_push) urgent_write_pointer<=urgent_write_pointer+7'd1;
        if(urgent_pop) urgent_read_pointer<=urgent_read_pointer+7'd1;
        case({urgent_push,urgent_pop})
            2'b10:urgent_count<=urgent_count+8'd1;
            2'b01:urgent_count<=urgent_count-8'd1;
            default: ;
        endcase
        if((cpu_write && cpu_addr[3:0]>=11) || flip!=last_flip) restart_pending<=1;
        case(state)
            WAIT_FIELDS: state<=EVALUATE;
            EVALUATE: if(urgent_pop) begin
                saved_index<=index;saved_round<=word_round;urgent_active<=1;state<=URGENT_WAIT;
            end else if(restart_pending && !urgent_active) begin
                index<=0;word_round<=0;state<=WAIT_FIELDS;
                restart_pending<=(cpu_write && cpu_addr[3:0]>=11) || flip!=last_flip;
            end else if(eligible) begin
                addr<=GFX_BASE+{7'd0,fields[2][7:6],fields[3],7'd0}+
                      {17'd0,word_round[0],6'd0}+{18'd0,row_pair,3'd0};
                state<=REQUEST;
            end else state<=NEXT_RECORD;
            REQUEST: if(ready) state<=NEXT_RECORD;
            URGENT_WAIT: begin index<=urgent_q;word_round<=0;state<=WAIT_FIELDS;end
            NEXT_RECORD: begin
                if(urgent_active) begin
                    if(word_round[0]) begin
                        urgent_active<=0;index<=saved_index;word_round<=saved_round;
                    end else word_round<=1;
                end else if(index==95) begin index<=0;word_round<=word_round+4'd1;end
                else index<=index+7'd1;
                state<=WAIT_FIELDS;
            end
            default: state<=WAIT_FIELDS;
        endcase
        end
    end
endmodule
