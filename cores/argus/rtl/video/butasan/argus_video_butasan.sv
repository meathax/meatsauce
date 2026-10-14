// SPDX-License-Identifier: GPL-3.0-or-later
// Butasan / butasanj scanline renderer, MAME 0.289 argus_v.cpp baseline.
// No frame buffer; two scanline slots, pipelined palette/blend, cached ROM rows.
module argus_video_butasan #(
    parameter integer RAW_OBJECT_STORE = 0,
    parameter integer SHARED_GFX_CACHE = 0
) (
    input logic clk_sys, reset,
    input logic [1:0] game_id, timing_profile,
    input logic ce_pixel,
    input logic [9:0] hpos, vpos,
    input logic active, hblank, vblank, line_start, frame_start,
    input logic user_flip_180,
    input logic vreq, vwe,
    input logic [15:0] vaddr,
    input logic [7:0] vwdata,
    output logic vready,
    output logic [7:0] vrdata,
    output logic rom_req,
    output logic [23:0] rom_addr,
    input logic rom_ready,
    input logic [63:0] rom_rdata,
    output logic [7:0] r, g, b,
    output logic pixel_valid, deadline_miss
);
    import argus_video_math::*;
    `include "butasan_rom_bases.vh"
    // *_r are the CPU-visible registers. The renderer uses the *-named copies,
    // captured once per output frame: the ROM rewrites them near its end-of-
    // frame IRQ (MAME raster line 248), which is mid-picture on the 250-line
    // output raster, and MAME shows that end-of-frame state for the whole frame.
    logic [15:0] scrollx0_r, scrolly0_r, scrollx1_r, scrolly1_r;
    logic [7:0] bg0_status_r, bg1_status_r, unknown_reg;
    logic board_flip_r, page_latch, bus_busy;
    logic [15:0] scrollx0, scrolly0, scrollx1, scrolly1;
    logic [7:0] bg0_status, bg1_status;
    logic board_flip;
    logic cp_run, cp_we;
    logic [6:0] cp_idx, cp_idx_q;
    logic [2:0] cp_fsel, cp_fsel_q;
    logic [7:0] spr_snap_q;
    wire [10:0] cp_addr={cp_idx,1'b1,cp_fsel};
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            scrollx0<=0; scrolly0<=0; scrollx1<=0; scrolly1<=0;
            bg0_status<=1; bg1_status<=1; board_flip<=0;
        end else if(frame_start) begin
            scrollx0<=scrollx0_r; scrolly0<=scrolly0_r; scrollx1<=scrollx1_r; scrolly1<=scrolly1_r;
            bg0_status<=bg0_status_r; bg1_status<=bg1_status_r; board_flip<=board_flip_r;
        end
    end
    logic [15:0] bus_addr;
    logic bus_page;
    logic pal_sel, page_sel, bg1_sel, spr_sel, reg_sel, mapped, accept_write;
    logic [7:0] pal_cpu_q, bg0_cpu_q, text_cpu_q, bg1_cpu_q;
    logic [7:0] bg0_cpu_lo,bg0_cpu_hi,text_cpu_lo,text_cpu_hi;
    logic [7:0] bg0_q,bg0_hi_q,text_q,text_hi_q,bg1_q;
    logic [11:0] map_addr,map_read_addr;
    logic [6:0] spr_index;
    logic [7:0] spr_cpu_q, spr_render_bytes [8:15];
    always_comb begin
        pal_sel=game_id==2 && vaddr>=16'hc800 && vaddr<=16'hcfff;
        page_sel=game_id==2 && vaddr>=16'hd000 && vaddr<=16'hdfff;
        bg1_sel=game_id==2 && vaddr>=16'hc400 && vaddr<=16'hc7ff;
        spr_sel=game_id==2 && vaddr>=16'hf000 && vaddr<=16'hf67f;
        reg_sel=game_id==2 && (vaddr==16'hc100 || vaddr==16'hc201 || vaddr==16'hc203 ||
                  vaddr==16'hc304 || vaddr==16'hc30c ||
                  (vaddr>=16'hc300 && vaddr<=16'hc303) ||
                  (vaddr>=16'hc308 && vaddr<=16'hc30b));
        mapped=pal_sel||page_sel||bg1_sel||spr_sel||reg_sel;
        accept_write=!reset && !bus_busy && vreq && mapped && vwe;
        vready=bus_busy;
        vrdata=8'hff;
        case(bus_addr)
            16'hc300: vrdata=scrollx0_r[7:0];
            16'hc301: vrdata=scrollx0_r[15:8];
            16'hc302: vrdata=scrolly0_r[7:0];
            16'hc303: vrdata=scrolly0_r[15:8];
            16'hc308: vrdata=scrollx1_r[7:0];
            16'hc309: vrdata=scrollx1_r[15:8];
            16'hc30a: vrdata=scrolly1_r[7:0];
            16'hc30b: vrdata=scrolly1_r[15:8];
            default: begin
                if(bus_addr>=16'hc800 && bus_addr<=16'hcfff) vrdata=pal_cpu_q;
                if(bus_addr>=16'hc400 && bus_addr<=16'hc7ff) vrdata=bg1_cpu_q;
                if(bus_addr>=16'hd000 && bus_addr<=16'hdfff)
                    vrdata=bus_page ? text_cpu_q : bg0_cpu_q;
                if(bus_addr>=16'hf000 && bus_addr<=16'hf67f) vrdata=spr_cpu_q;
            end
        endcase
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            scrollx0_r<=0;scrolly0_r<=0;scrollx1_r<=0;scrolly1_r<=0;
            bg0_status_r<=1;bg1_status_r<=1;board_flip_r<=0;page_latch<=0;
            unknown_reg<=0;bus_busy<=0;bus_addr<=0;bus_page<=0;
        end else begin
            if(bus_busy) bus_busy<=0;
            else if(vreq&&mapped) begin
                bus_busy<=1;bus_addr<=vaddr;
                // MAME: upper-half reads always access page0; writes use latch.
                bus_page<=page_latch&&!vaddr[11];
            end
            if(accept_write) case(vaddr)
                16'hc100: unknown_reg<=vwdata;
                16'hc201: board_flip_r<=vwdata[7];
                16'hc203: page_latch<=vwdata[0];
                16'hc300: scrollx0_r[7:0]<=vwdata;
                16'hc301: scrollx0_r[15:8]<=vwdata;
                16'hc302: scrolly0_r[7:0]<=vwdata;
                16'hc303: scrolly0_r[15:8]<=vwdata;
                16'hc304: bg0_status_r<=vwdata;
                16'hc308: scrollx1_r[7:0]<=vwdata;
                16'hc309: scrollx1_r[15:8]<=vwdata;
                16'hc30a: scrolly1_r[7:0]<=vwdata;
                16'hc30b: scrolly1_r[15:8]<=vwdata;
                16'hc30c: bg1_status_r<=vwdata;
                default: ;
            endcase
        end
    end
    // CPU initializes all RAM. No fabricated reset-clear loop or PROM behavior.
    // Even/odd byte planes return code and attributes together. CPU byte
    // addressing, both page halves, and the asymmetric upper read remain exact.
    assign bg0_cpu_q=bus_addr[0] ? bg0_cpu_hi : bg0_cpu_lo;
    assign text_cpu_q=bus_addr[0] ? text_cpu_hi : text_cpu_lo;
    jtframe_dual_ram #(.DW(8),.AW(11)) page0_low(
        .clk0(clk_sys),.addr0(vaddr[11:1]),.data0(vwdata),
        .we0(accept_write&&page_sel&&!page_latch&&!vaddr[0]),.q0(bg0_cpu_lo),
        .clk1(clk_sys),.addr1(map_read_addr[11:1]),.data1(8'd0),.we1(1'b0),.q1(bg0_q));
    jtframe_dual_ram #(.DW(8),.AW(11)) page0_high(
        .clk0(clk_sys),.addr0(vaddr[11:1]),.data0(vwdata),
        .we0(accept_write&&page_sel&&!page_latch&&vaddr[0]),.q0(bg0_cpu_hi),
        .clk1(clk_sys),.addr1(map_read_addr[11:1]),.data1(8'd0),.we1(1'b0),.q1(bg0_hi_q));
    jtframe_dual_ram #(.DW(8),.AW(11)) page1_low(
        .clk0(clk_sys),.addr0(vaddr[11:1]),.data0(vwdata),
        .we0(accept_write&&page_sel&&page_latch&&!vaddr[0]),.q0(text_cpu_lo),
        .clk1(clk_sys),.addr1(map_read_addr[11:1]),.data1(8'd0),.we1(1'b0),.q1(text_q));
    jtframe_dual_ram #(.DW(8),.AW(11)) page1_high(
        .clk0(clk_sys),.addr0(vaddr[11:1]),.data0(vwdata),
        .we0(accept_write&&page_sel&&page_latch&&vaddr[0]),.q0(text_cpu_hi),
        .clk1(clk_sys),.addr1(map_read_addr[11:1]),.data1(8'd0),.we1(1'b0),.q1(text_hi_q));
    jtframe_dual_ram #(.DW(8),.AW(10)) bg1_ram(
        .clk0(clk_sys),.addr0(vaddr[9:0]),.data0(vwdata),.we0(accept_write&&bg1_sel),.q0(bg1_cpu_q),
        .clk1(clk_sys),.addr1(map_read_addr[9:0]),.data1(8'd0),.we1(1'b0),.q1(bg1_q));
    // Full byte copy supports CPU reads, including ignored descriptor bytes.
    // Eight small field banks supply one synchronous metadata read per object.
    jtframe_dual_ram #(.DW(8),.AW(11)) sprite_cpu_ram(
        .clk0(clk_sys),.addr0(vaddr[10:0]),.data0(vwdata),.we0(accept_write&&spr_sel),.q0(spr_cpu_q),
        .clk1(clk_sys),.addr1(cp_addr),.data1(8'd0),.we1(1'b0),.q1(spr_snap_q));
    // Per-frame sprite snapshot (see the register note above): copy the eight
    // descriptor bytes of all 104 objects at frame_start (832 cycles, blanking).
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            cp_run<=0; cp_we<=0; cp_idx<=0; cp_fsel<=0; cp_idx_q<=0; cp_fsel_q<=0;
        end else begin
            cp_we<=cp_run; cp_idx_q<=cp_idx; cp_fsel_q<=cp_fsel;
            if(frame_start) begin cp_run<=1; cp_idx<=0; cp_fsel<=0; end
            else if(cp_run) begin
                cp_fsel<=cp_fsel+3'd1;
                if(cp_fsel==3'd7) begin
                    if(cp_idx==7'd103) cp_run<=0; else cp_idx<=cp_idx+7'd1;
                end
            end
        end
    end
    genvar field;
    generate
        for(field=8;field<16;field=field+1) begin: sprite_banks
            jtframe_dual_ram #(.DW(8),.AW(7)) mem(
                .clk0(clk_sys),.addr0(cp_idx_q),.data0(spr_snap_q),
                .we0(cp_we&&cp_fsel_q==3'(field-8)),.q0(),
                .clk1(clk_sys),.addr1(spr_index),.data1(8'd0),.we1(1'b0),.q1(spr_render_bytes[field]));
        end
    endgenerate

    typedef enum logic [4:0] {IDLE,TILE_BEGIN,MEM_WAIT_LO,MEM_LO,
        ROW_START,ROW_WAIT,ROW_DELIVER,DRAIN,SPR_BEGIN,SPR_EVAL,SPR_NEXT_TILE,DONE} state_t;
    state_t state;
    localparam logic [1:0] BG0=0,BG1=1,OBJECTS=2,TEXT=3;
    logic [1:0] pass;
    logic [9:0] render_y;
    logic [8:0] render_x;
    logic [8:0] sx0_l,sy0_l,sx1_l,sy1_l,source_x,source_y;
    logic flip_l,user_rotate_l,bg0_enable,bg1_enable,bg1_code_hi,clear_row;
    logic [23:0] row_base;
    logic [11:0] row_code;
    logic row_text,row_hflip,row_vflip,row_busy,row_done;
    logic [3:0] row_y,row_pal,sub_x;
    logic [63:0] row_pixels,fetched_pixels;
    logic [4:0] issue_count;
    logic signed [10:0] draw_x;
    logic [1:0] drain_count;
    logic [1:0] slot_valid;
    logic [9:0] slot_tag[0:1];
    logic signed [10:0] object_x,object_y,object_dy;
    logic [2:0] object_width,object_height,object_i;
    logic object_fx,object_fy,object_visible;
    logic signed [10:0] spr_x_l;
    logic [2:0] spr_width_l,spr_height_l,spr_i_l,spr_j;
    logic [11:0] spr_code_l;
    logic spr_fx_l,spr_fy_l;
    logic [3:0] spr_row_l;
    logic [9:0] tile_index;
    logic [2:0] tile_i,next_tile_j,first_tile_i,first_tile_j;
    logic emit_busy,row_delivery,emit_clear,emit_flip,emit_slot;
    logic [1:0] emit_pass;
    logic [4:0] emit_i,emit_count;
    logic [3:0] emit_pal,emit_sub_x;
    logic [63:0] emit_pixels;
    logic signed [10:0] emit_draw_x;

    // The producer may prepare/fetch the following tile while this one emits.
    // Only one completed row is queued; object and alpha order never changes.
    assign row_delivery=((state==ROW_WAIT&&row_done)||state==ROW_DELIVER)&&!emit_busy;
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            emit_busy<=0;emit_clear<=0;emit_flip<=0;emit_slot<=0;emit_pass<=BG0;
            emit_i<=0;emit_count<=0;emit_pal<=0;emit_sub_x<=0;emit_pixels<=0;emit_draw_x<=0;
        end else if(row_delivery) begin
            emit_busy<=1;emit_i<=0;emit_count<=issue_count;
            emit_pixels<=state==ROW_WAIT ? fetched_pixels : row_pixels;
            emit_pal<=row_pal;emit_sub_x<=sub_x;emit_draw_x<=draw_x;
            emit_clear<=clear_row;emit_flip<=flip_l;emit_slot<=render_y[0];emit_pass<=pass;
        end else if(emit_busy) begin
            if(emit_i+5'd4>=emit_count) emit_busy<=0;
            else emit_i<=emit_i+5'd4;
        end
    end
    always_comb begin
        source_x=0;source_y=0;
        if(pass==BG0) begin
            source_x=flip_l ? 9'd255+sx0_l-render_x : sx0_l+render_x;
            source_y=flip_l ? 9'd255+sy0_l-render_y[8:0] : sy0_l+render_y[8:0];
        end else if(pass==BG1) begin
            source_x=flip_l ? 9'd255+sx1_l-render_x : sx1_l+render_x;
            source_y=flip_l ? 9'd255+sy1_l-render_y[8:0] : sy1_l+render_y[8:0];
        end else if(pass==TEXT) begin
            source_x={1'b0,flip_l ? 8'd255-render_x[7:0] : render_x[7:0]};
            source_y={1'b0,flip_l ? 8'd255-render_y[7:0] : render_y[7:0]};
        end
        if(pass==TEXT) tile_index={source_y[7:3]^5'h1f,source_x[7:3]};
        else tile_index={source_x[8],source_y[8:4]^5'h0f,source_x[7:4]};
        object_x=$signed({3'd0,spr_render_bytes[10]})-(spr_render_bytes[11][0]?11'sd256:11'sd0);
        object_y=11'sd240-$signed({3'd0,spr_render_bytes[12]})+(spr_render_bytes[13][0]?11'sd256:11'sd0);
        object_fx=spr_render_bytes[8][0];object_fy=spr_render_bytes[8][2];
        if(flip_l) begin
            object_x=11'sd240-object_x;object_y=11'sd240-object_y;
            object_fx=!object_fx;object_fy=!object_fy;
        end
        object_width=1;object_height=1;
        if(spr_index<16 || (spr_index>=48 && spr_index<64)) object_width=2;
        if(spr_index>=88 && spr_index<98) begin object_width=2;object_height=2;end
        if(spr_index>=98) begin object_width=4;object_height=4;end
        // User rotation reverses the complete composite bounding box.
        // The ASIC board flip retains its MAME16x16 anchor convention.
        if(user_rotate_l) begin
            object_x=object_x-$signed({4'd0,(object_width-3'd1),4'd0});
            object_y=object_y+$signed({4'd0,(object_height-3'd1),4'd0});
        end
        object_dy=$signed({1'b0,render_y})-object_y;
        object_i=3'(-(object_dy>>>4));
        object_visible=(object_dy<11'sd16) &&
                       (object_dy>=11'sd16-($signed({8'd0,object_height})<<<4)) &&
                       object_x<11'sd256 && object_x>-($signed({8'd0,object_width})<<<4);
        tile_i=spr_fy_l ? spr_height_l-3'd1-spr_i_l : spr_i_l;
        next_tile_j=spr_fx_l ? spr_width_l-3'd2-spr_j : spr_j+3'd1;
        first_tile_i=object_fy ? object_height-3'd1-object_i : object_i;
        first_tile_j=object_fx ? object_width-3'd1 : 3'd0;
    end

    // Idle clocks preheat only background/text ROM for the following line.
    // Metadata is read afresh on demand; writes/scroll changes cannot create
    // stale pixels. A started ROM transaction finishes unchanged at line_start.
    typedef enum logic [3:0] {P_IDLE,P_BEGIN,P_WAIT,P_META,P_START,P_ROW,P_NEXT} prefetch_t;
    prefetch_t prefetch_state;
    logic [1:0] prefetch_pass;
    logic [9:0] prefetch_y;
    logic [8:0] prefetch_x,pre_sx0,pre_sy0,pre_sx1,pre_sy1,pre_source_x,pre_source_y;
    logic pre_flip,pre_bg0,pre_bg1,pre_bg1_hi,pre_text,pre_hflip,pre_vflip;
    logic [11:0] pre_map_addr,pre_code;
    logic [23:0] pre_base;
    logic [3:0] pre_row_y;
    logic [4:0] pre_count;
    logic [9:0] pre_tile_index;
    logic row_start_mux;
    always_comb begin
        pre_source_x=0;pre_source_y=0;
        if(prefetch_pass==BG0) begin
            pre_source_x=pre_flip ? 9'd255+pre_sx0-prefetch_x : pre_sx0+prefetch_x;
            pre_source_y=pre_flip ? 9'd255+pre_sy0-prefetch_y[8:0] : pre_sy0+prefetch_y[8:0];
        end else if(prefetch_pass==BG1) begin
            pre_source_x=pre_flip ? 9'd255+pre_sx1-prefetch_x : pre_sx1+prefetch_x;
            pre_source_y=pre_flip ? 9'd255+pre_sy1-prefetch_y[8:0] : pre_sy1+prefetch_y[8:0];
        end else begin
            pre_source_x={1'b0,pre_flip ? 8'd255-prefetch_x[7:0] : prefetch_x[7:0]};
            pre_source_y={1'b0,pre_flip ? 8'd255-prefetch_y[7:0] : prefetch_y[7:0]};
        end
        pre_tile_index=prefetch_pass==TEXT ? {pre_source_y[7:3]^5'h1f,pre_source_x[7:3]} :
            {pre_source_x[8],pre_source_y[8:4]^5'h0f,pre_source_x[7:4]};
        map_read_addr=state==IDLE ? pre_map_addr : map_addr;
        row_start_mux=!row_busy&&((state==ROW_START)||
            (state==IDLE&&prefetch_state==P_START&&!line_start));
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            prefetch_state<=P_IDLE;prefetch_pass<=BG0;prefetch_y<=0;prefetch_x<=0;
            pre_sx0<=0;pre_sy0<=0;pre_sx1<=0;pre_sy1<=0;pre_flip<=0;
            pre_bg0<=0;pre_bg1<=0;pre_bg1_hi<=0;pre_text<=0;pre_hflip<=0;pre_vflip<=0;
            pre_map_addr<=0;pre_code<=0;pre_base<=0;pre_row_y<=0;pre_count<=0;
        end else if(line_start) prefetch_state<=P_IDLE;
        else if(state==DONE&&render_y<254) begin
            prefetch_state<=P_BEGIN;prefetch_pass<=BG0;prefetch_y<=render_y+10'd1;prefetch_x<=0;
            pre_sx0<=scrollx0[8:0]+{board_flip,8'd0};pre_sy0<=scrolly0[8:0]+{board_flip,8'd0};pre_sx1<=scrollx1[8:0]+{board_flip,8'd0};pre_sy1<=scrolly1[8:0]+{board_flip,8'd0};
            pre_flip<=board_flip^user_flip_180;pre_bg0<=bg0_status[0];
            pre_bg1<=bg1_status[0];pre_bg1_hi<=bg1_status[1];
        end else if(state==IDLE) case(prefetch_state)
            P_BEGIN: begin
                pre_text<=prefetch_pass==TEXT;
                pre_row_y<=prefetch_pass==TEXT ? {1'b0,pre_source_y[2:0]} : pre_source_y[3:0];
                pre_count<=prefetch_pass==TEXT ?
                    (pre_flip ? {2'd0,pre_source_x[2:0]}+5'd1 : 5'd8-{2'd0,pre_source_x[2:0]}) :
                    (pre_flip ? {1'b0,pre_source_x[3:0]}+5'd1 : 5'd16-{1'b0,pre_source_x[3:0]});
                if(prefetch_pass==BG0&&!pre_bg0) begin prefetch_pass<=BG1;prefetch_x<=0;end
                else if(prefetch_pass==BG1&&!pre_bg1) begin prefetch_pass<=TEXT;prefetch_x<=0;end
                else begin
                    pre_map_addr<=prefetch_pass==BG1 ? {2'd0,pre_tile_index} : {1'b0,pre_tile_index,1'b0};
                    pre_base<=prefetch_pass==TEXT ? BUTASAN_GFX4 :
                        (prefetch_pass==BG0 ? BUTASAN_GFX2 : BUTASAN_GFX3);
                    prefetch_state<=P_WAIT;
                end
            end
            P_WAIT: prefetch_state<=P_META;
            P_META: begin
                if(prefetch_pass==BG1) begin
                    pre_code<={3'd0,pre_bg1_hi,bg1_q};pre_hflip<=0;pre_vflip<=0;
                end else if(prefetch_pass==TEXT) begin
                    pre_code<={2'd0,text_hi_q[7:6],text_q};pre_hflip<=text_hi_q[4];pre_vflip<=text_hi_q[5];
                end else begin
                    pre_code<={2'd0,bg0_hi_q[7:6],bg0_q};pre_hflip<=bg0_hi_q[4];pre_vflip<=bg0_hi_q[5];
                end
                prefetch_state<=P_START;
            end
            P_START: if(!row_busy) prefetch_state<=P_ROW;
            P_ROW: if(row_done) prefetch_state<=P_NEXT;
            P_NEXT: begin
                if(prefetch_x+{4'd0,pre_count}>=256) begin
                    prefetch_x<=0;
                    if(prefetch_pass==BG0) begin prefetch_pass<=BG1;prefetch_state<=P_BEGIN;end
                    else if(prefetch_pass==BG1) begin prefetch_pass<=TEXT;prefetch_state<=P_BEGIN;end
                    else prefetch_state<=P_IDLE;
                end else begin prefetch_x<=prefetch_x+{4'd0,pre_count};prefetch_state<=P_BEGIN;end
            end
            default: ;
        endcase
    end
    butasan_gfx_row #(.RAW_OBJECT_STORE(RAW_OBJECT_STORE),.SHARED_GFX_CACHE(SHARED_GFX_CACHE)) row_fetch(
        .clk_sys(clk_sys),.reset(reset),.start(row_start_mux),
        .base(state==IDLE ? pre_base : row_base),.code(state==IDLE ? pre_code : row_code),
        .text8(state==IDLE ? pre_text : row_text),.hflip(state==IDLE ? pre_hflip : row_hflip),
        .vflip(state==IDLE ? pre_vflip : row_vflip),.y(state==IDLE ? pre_row_y : row_y),
        .cache_lane(state==IDLE ? prefetch_pass : pass),
        .busy(row_busy),.done(row_done),.pixels(fetched_pixels),
        .req(rom_req),.addr(rom_addr),.ready(rom_ready),.rdata(rom_rdata));

    // Four consecutive pixels issue together. The x-low two bits select four
    // independent line RAM banks, preserving object order and alpha blending.
    // Palette copies provide four synchronous read ports; CPU writes update all.
    logic [23:0] scan_rgb_bank [0:3];
    logic [7:0] pal_cpu_bank [0:3];
    assign pal_cpu_q=pal_cpu_bank[0];
    genvar pixel_bank;
    generate
        for(pixel_bank=0;pixel_bank<4;pixel_bank=pixel_bank+1) begin: pixel_banks
            logic [1:0] lane_offset;
            logic [4:0] pixel_i;
            logic [3:0] source_pixel,issue_pen;
            logic signed [10:0] issue_x;
            logic [7:0] color_index,pal_lo_q,pal_hi_q;
            logic [10:0] pal_lo_addr,pal_hi_addr;
            logic issue_opaque,p1_en,p2_en,p1_sprite,p1_clear,p1_forward;
            logic [6:0] p1_addr,p2_addr,line_read_addr;
            logic [23:0] p2_rgb,old_rgb,p1_forward_rgb,blend_dst;
            always_comb begin
                lane_offset=2'(pixel_bank)-emit_draw_x[1:0];
                pixel_i=emit_i+{3'd0,lane_offset};
                source_pixel=emit_pass==OBJECTS ? pixel_i[3:0] :
                             (emit_flip ? emit_sub_x-pixel_i[3:0] : emit_sub_x+pixel_i[3:0]);
                issue_pen=emit_pixels[{source_pixel,2'b00} +: 4];
                issue_x=emit_draw_x+$signed({6'd0,pixel_i});
                issue_opaque=emit_busy && pixel_i<emit_count && issue_x>=0 && issue_x<256 &&
                              (emit_pass==BG0 || issue_pen!=(emit_pass==OBJECTS?4'd7:4'd15));
                color_index={emit_pal,issue_pen};
                case(emit_pass)
                    BG0: pal_lo_addr={2'd0,color_index,1'b0};
                    BG1: pal_lo_addr=11'h200+{5'd0,emit_pal[0],issue_pen,1'b0};
                    TEXT:pal_lo_addr=11'h600+{2'd0,color_index,1'b0};
                    default: begin
                        if(color_index<64) pal_lo_addr=11'h400+{2'd0,color_index,1'b0};
                        else if(color_index<192) pal_lo_addr=11'h480+{3'd0,(color_index-8'd64)&8'h70}+{7'd0,color_index[2:0],1'b0};
                        else if(color_index<224) pal_lo_addr=11'h200+{5'd0,color_index[4:0],1'b0};
                        else if(color_index<240) pal_lo_addr=11'h240+{6'd0,color_index[3:0],1'b0};
                        else pal_lo_addr=11'h500+{6'd0,color_index[3:0],1'b0};
                    end
                endcase
                pal_hi_addr=pal_lo_addr+11'd1;
                line_read_addr={emit_slot,issue_x[7:2]};
                // Forward both pending writes around the synchronous RAM read.
                // Closely spaced overlapping objects must blend in source order.
                blend_dst=(p2_en&&p2_addr==p1_addr) ? p2_rgb :
                    (p1_forward ? p1_forward_rgb : old_rgb);
            end
            jtframe_dual_ram #(.DW(8),.AW(11)) pal_low(
                .clk0(clk_sys),.addr0(vaddr[10:0]),.data0(vwdata),.we0(accept_write&&pal_sel),.q0(pal_cpu_bank[pixel_bank]),
                .clk1(clk_sys),.addr1(pal_lo_addr),.data1(8'd0),.we1(1'b0),.q1(pal_lo_q));
            jtframe_dual_ram #(.DW(8),.AW(11)) pal_high(
                .clk0(clk_sys),.addr0(vaddr[10:0]),.data0(vwdata),.we0(accept_write&&pal_sel),.q0(),
                .clk1(clk_sys),.addr1(pal_hi_addr),.data1(8'd0),.we1(1'b0),.q1(pal_hi_q));
            always_ff @(posedge clk_sys) begin
                if(reset) begin
                    p1_en<=0;p2_en<=0;p1_sprite<=0;p1_clear<=0;p1_addr<=0;p2_addr<=0;p2_rgb<=0;
                    p1_forward<=0;p1_forward_rgb<=0;
                end else begin
                    p1_en<=issue_opaque;p1_addr<=line_read_addr;
                    p1_sprite<=emit_pass==OBJECTS;p1_clear<=emit_clear&&emit_pass==BG0;
                    p1_forward<=p2_en&&p2_addr==line_read_addr;p1_forward_rgb<=p2_rgb;
                    p2_en<=p1_en;p2_addr<=p1_addr;
                    if(p1_clear) p2_rgb<=0;
                    else if(p1_sprite) p2_rgb<=sprite_blend(blend_dst,palette_rgb(pal_lo_q,pal_hi_q),pal_hi_q[3:0]);
                    else p2_rgb<=palette_rgb(pal_lo_q,pal_hi_q);
                end
            end
            jtframe_dual_ram #(.DW(24),.AW(7)) scan_lines(
                .clk0(clk_sys),.addr0({vpos[0],hpos[7:2]}),.data0(24'd0),.we0(1'b0),.q0(scan_rgb_bank[pixel_bank]),
                .clk1(clk_sys),.addr1(p2_addr),.data1(p2_rgb),.we1(p2_en),.q1());
            jtframe_dual_ram #(.DW(24),.AW(7)) blend_lines(
                .clk0(clk_sys),.addr0(p2_addr),.data0(p2_rgb),.we0(p2_en),.q0(),
                .clk1(clk_sys),.addr1(line_read_addr),.data1(24'd0),.we1(1'b0),.q1(old_rgb));
        end
    endgenerate
    logic sample_ce,sample_active;
    logic [1:0] sample_bank;
    always_ff @(posedge clk_sys) begin
        if(reset) begin sample_ce<=0;sample_active<=0;sample_bank<=0;pixel_valid<=0;r<=0;g<=0;b<=0;end
        else begin
            sample_ce<=ce_pixel;
            sample_bank<=hpos[1:0];
            sample_active<=game_id==2&&active&&!hblank&&!vblank&&hpos<256&&
                           slot_valid[vpos[0]]&&slot_tag[vpos[0]]==vpos;
            pixel_valid<=sample_ce&&sample_active;
            if(sample_ce) {r,g,b}<=sample_active ? scan_rgb_bank[sample_bank] : 24'd0;
        end
    end

    always_ff @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE;pass<=BG0;render_y<=0;render_x<=0;
            sx0_l<=0;sy0_l<=0;sx1_l<=0;sy1_l<=0;flip_l<=0;user_rotate_l<=0;
            bg0_enable<=0;bg1_enable<=0;bg1_code_hi<=0;clear_row<=0;
            map_addr<=0;row_base<=0;row_code<=0;row_text<=0;
            row_hflip<=0;row_vflip<=0;row_y<=0;row_pal<=0;sub_x<=0;
            row_pixels<=0;issue_count<=0;draw_x<=0;drain_count<=0;
            spr_index<=0;spr_x_l<=0;spr_width_l<=0;spr_height_l<=0;
            spr_i_l<=0;spr_j<=0;spr_code_l<=0;spr_fx_l<=0;spr_fy_l<=0;spr_row_l<=0;
            slot_valid<=0;slot_tag[0]<=0;slot_tag[1]<=0;deadline_miss<=0;
        end else begin
            if(line_start&&state!=IDLE) deadline_miss<=1;
            if(ce_pixel&&active&&!hblank&&!vblank&&
               (game_id!=2||!slot_valid[vpos[0]]||slot_tag[vpos[0]]!=vpos)) deadline_miss<=1;
            case(state)
                IDLE: if(line_start&&game_id==2&&vpos<255) begin
                    render_y<=vpos+10'd1;render_x<=0;pass<=BG0;
                    slot_valid[~vpos[0]]<=0;slot_tag[~vpos[0]]<=vpos+10'd1;
                    sx0_l<=scrollx0[8:0]+{board_flip,8'd0};sy0_l<=scrolly0[8:0]+{board_flip,8'd0};sx1_l<=scrollx1[8:0]+{board_flip,8'd0};sy1_l<=scrolly1[8:0]+{board_flip,8'd0};
                    flip_l<=board_flip^user_flip_180;user_rotate_l<=user_flip_180;bg0_enable<=bg0_status[0];
                    bg1_enable<=bg1_status[0];bg1_code_hi<=bg1_status[1];state<=TILE_BEGIN;
                end
                TILE_BEGIN: begin
                    clear_row<=0;row_text<=pass==TEXT;draw_x<=$signed({2'd0,render_x});
                    row_y<=pass==TEXT ? {1'b0,source_y[2:0]} : source_y[3:0];
                    sub_x<=pass==TEXT ? {1'b0,source_x[2:0]} : source_x[3:0];
                    issue_count<=pass==TEXT ? (flip_l?{2'd0,source_x[2:0]}+5'd1:5'd8-{2'd0,source_x[2:0]}) :
                                                (flip_l?{1'b0,source_x[3:0]}+5'd1:5'd16-{1'b0,source_x[3:0]});
                    if(pass==BG0&&!bg0_enable) begin
                        clear_row<=1;row_pixels<=0;state<=ROW_DELIVER;
                    end else if(pass==BG1&&!bg1_enable) begin pass<=OBJECTS;spr_index<=0;state<=SPR_BEGIN;end
                    else begin
                        map_addr<=pass==BG1 ? {2'd0,tile_index} : {1'b0,tile_index,1'b0};
                        row_base<=pass==TEXT ? BUTASAN_GFX4 : (pass==BG0 ? BUTASAN_GFX2 : BUTASAN_GFX3);
                        state<=MEM_WAIT_LO;
                    end
                end
                MEM_WAIT_LO: state<=MEM_LO;
                MEM_LO: begin
                    if(pass==BG1) begin
                        row_code<={3'd0,bg1_code_hi,bg1_q};row_pal<={3'd0,bg1_q[7]};
                        row_hflip<=0;row_vflip<=0;state<=ROW_START;
                    end else begin
                        if(pass==TEXT) begin
                            row_code<={2'd0,text_hi_q[7:6],text_q};row_pal<=text_hi_q[3:0];
                            row_hflip<=text_hi_q[4];row_vflip<=text_hi_q[5];
                        end else begin
                            row_code<={2'd0,bg0_hi_q[7:6],bg0_q};row_pal<=bg0_hi_q[3:0];
                            row_hflip<=bg0_hi_q[4];row_vflip<=bg0_hi_q[5];
                        end
                        state<=ROW_START;
                    end
                end
                ROW_START: if(!row_busy) state<=ROW_WAIT;
                ROW_WAIT: if(row_done) begin row_pixels<=fetched_pixels;if(emit_busy) state<=ROW_DELIVER;end
                ROW_DELIVER: ;
                DRAIN: if(!emit_busy) begin
                    if(drain_count==1) state<=DONE;
                    else drain_count<=drain_count+2'd1;
                end
                SPR_BEGIN: state<=SPR_EVAL;
                SPR_EVAL: begin
                    if(object_visible) begin
                        spr_x_l<=object_x;spr_width_l<=object_width;spr_height_l<=object_height;
                        spr_i_l<=object_i;spr_j<=0;spr_code_l<={spr_render_bytes[15][3:0],spr_render_bytes[14]};
                        spr_fx_l<=object_fx;spr_fy_l<=object_fy;spr_row_l<=object_dy[3:0];
                        row_pal<=spr_render_bytes[9][3:0];
                        row_text<=0;row_base<=BUTASAN_GFX1;clear_row<=0;
                        row_code<={spr_render_bytes[15][3:0],spr_render_bytes[14]}+
                            12'(first_tile_i*object_width+first_tile_j);
                        row_hflip<=object_fx;row_vflip<=object_fy;row_y<=object_dy[3:0];
                        draw_x<=object_x;issue_count<=16;sub_x<=0;
                        if(object_x<11'sd256&&object_x>-11'sd16) state<=ROW_START;
                        else state<=SPR_NEXT_TILE;
                    end else if(spr_index==103) begin pass<=TEXT;render_x<=0;state<=TILE_BEGIN;end
                    else begin spr_index<=spr_index+7'd1;state<=SPR_BEGIN;end
                end
                SPR_NEXT_TILE: begin
                    if(spr_j+3'd1==spr_width_l) begin
                        if(spr_index==103) begin pass<=TEXT;render_x<=0;state<=TILE_BEGIN;end
                        else begin spr_index<=spr_index+7'd1;state<=SPR_BEGIN;end
                    end else begin
                        spr_j<=spr_j+3'd1;
                        row_code<=spr_code_l+12'(tile_i*spr_width_l+next_tile_j);
                        draw_x<=spr_x_l+$signed({4'd0,(spr_j+3'd1),4'd0});
                        if(spr_x_l+$signed({4'd0,(spr_j+3'd1),4'd0})<11'sd256&&
                           spr_x_l+$signed({4'd0,(spr_j+3'd1),4'd0})>-11'sd16) state<=ROW_START;
                    end
                end
                DONE: begin slot_valid[render_y[0]]<=1;state<=IDLE;end
                default: state<=IDLE;
            endcase
            if(row_delivery) begin
                if(pass==OBJECTS) state<=SPR_NEXT_TILE;
                else if(render_x+{4'd0,issue_count}>=256) begin
                    if(pass==BG0) begin render_x<=0;pass<=BG1;state<=TILE_BEGIN;end
                    else if(pass==BG1) begin render_x<=0;pass<=OBJECTS;spr_index<=0;state<=SPR_BEGIN;end
                    else begin drain_count<=0;state<=DRAIN;end
                end else begin render_x<=render_x+{4'd0,issue_count};state<=TILE_BEGIN;end
            end
        end
    end
endmodule
