// SPDX-License-Identifier: GPL-3.0-or-later
// Valtric scanline renderer. MAME 0.289 argus_v.cpp is the functional reference.
module argus_video_valtric #(
    parameter integer CACHE_AW=13,
    parameter bit RAW_OBJECT_STORE=1'b0,
    parameter bit EXTERNAL_GFX_CACHE=1'b0
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
    `include "argus_video_rom_bases.vh"
    // *_r are the CPU-visible registers. The renderer uses the *-named copies,
    // captured once per output frame: the ROM rewrites them near its end-of-
    // frame IRQ (MAME raster line 240), which is mid-picture on the 250-line
    // output raster, and MAME shows that end-of-frame state for the whole frame.
    logic [15:0] scrollx_r, scrolly_r, intensity_r;
    logic [7:0] bg_status_r, mosaic_reg_r, unknown_reg;
    logic board_flip_r;
    logic [15:0] scrollx, scrolly, intensity;
    logic [7:0] bg_status, mosaic_reg;
    logic board_flip;
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            scrollx<=0; scrolly<=0; intensity<=0; bg_status<=1; mosaic_reg<=8'h0f; board_flip<=0;
        end else if(frame_start) begin
            scrollx<=scrollx_r; scrolly<=scrolly_r; intensity<=intensity_r;
            bg_status<=bg_status_r; mosaic_reg<=mosaic_reg_r; board_flip<=board_flip_r;
        end
    end
    logic [4:0] mosaic_held_step;
    logic mosaic_held_negative;
    logic [255:0] grey_flags;
    logic [15:0] bg_generation,glyph_generation;
    logic bus_busy, mapped, pal_sel, tx_sel, bg_sel, spr_sel, reg_sel, accept_write;
    logic [15:0] bus_addr;
    logic [11:0] pal_cpu_addr;
    logic [10:0] spr_cpu_addr, map_addr,ram_map_addr;
    logic [7:0] pal_cpu_q, tx_cpu_lo, tx_cpu_hi, bg_cpu_lo, bg_cpu_hi, spr_cpu_q;
    logic [7:0] tx_lo, tx_hi, bg_lo, bg_hi, pal_lo_q, pal_hi_q;
    logic [11:0] pal_lo_addr, pal_hi_addr;
    logic [7:0] spr_q[0:4],spr_cpu_values[0:4];
    logic [6:0] spr_index,sprite_read_index;

    always_comb begin
        pal_sel = game_id==1 && vaddr>=16'hc400 && vaddr<=16'hcfff;
        tx_sel = game_id==1 && vaddr>=16'hd000 && vaddr<=16'hd7ff;
        bg_sel = game_id==1 && vaddr>=16'hd800 && vaddr<=16'hdfff;
        spr_sel = game_id==1 && vaddr>=16'hf200 && vaddr<=16'hf7ff;
        reg_sel = game_id==1 && (vaddr==16'hc201 || vaddr==16'hc300 ||
                  (vaddr>=16'hc308 && vaddr<=16'hc30d));
        mapped = pal_sel || tx_sel || bg_sel || spr_sel || reg_sel;
        accept_write = !reset && !bus_busy && vreq && mapped && vwe;
        pal_cpu_addr = vaddr[11:0]-12'h400;
        spr_cpu_addr = vaddr[10:0]-11'h200;
        vready = bus_busy;
        vrdata = 8'hff;
        case(bus_addr)
            16'hc308: vrdata=scrollx_r[7:0];
            16'hc309: vrdata=scrollx_r[15:8];
            16'hc30a: vrdata=scrolly_r[7:0];
            16'hc30b: vrdata=scrolly_r[15:8];
            default: begin
                if(bus_addr>=16'hc400 && bus_addr<=16'hcfff) vrdata=pal_cpu_q;
                if(bus_addr>=16'hd000 && bus_addr<=16'hd7ff) vrdata=bus_addr[0] ? tx_cpu_hi : tx_cpu_lo;
                if(bus_addr>=16'hd800 && bus_addr<=16'hdfff) vrdata=bus_addr[0] ? bg_cpu_hi : bg_cpu_lo;
                if(bus_addr>=16'hf200 && bus_addr<=16'hf7ff) vrdata=spr_cpu_q;
            end
        endcase
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            bus_busy<=0; bus_addr<=0; scrollx_r<=0; scrolly_r<=0; intensity_r<=0;
            bg_status_r<=1; mosaic_reg_r<=8'h0f; unknown_reg<=0; board_flip_r<=0;
            grey_flags<=0;
            bg_generation<=0;
        end else begin
            if(bus_busy) bus_busy<=0;
            else if(vreq && mapped) begin bus_busy<=1; bus_addr<=vaddr; end
            if(accept_write) begin
                if(bg_sel)bg_generation<=bg_generation+16'd1;
                case(vaddr)
                    16'hc201: board_flip_r<=vwdata[7];
                    16'hc300: unknown_reg<=vwdata;
                    16'hc308: scrollx_r[7:0]<=vwdata;
                    16'hc309: scrollx_r[15:8]<=vwdata;
                    16'hc30a: scrolly_r[7:0]<=vwdata;
                    16'hc30b: scrolly_r[15:8]<=vwdata;
                    16'hc30c: begin
                        bg_status_r<=vwdata;
                        // MAME preserves processed grey colors when bit1 is cleared.
                        if(bg_status_r!=vwdata && vwdata[1]) grey_flags<='1;
                    end
                    16'hc30d: mosaic_reg_r<=vwdata;
                    16'hc5fe: begin intensity_r[15:8]<=vwdata; grey_flags<={256{bg_status_r[1]}}; end
                    16'hc5ff: begin intensity_r[7:0]<=vwdata; grey_flags<={256{bg_status_r[1]}}; end
                    default: if(pal_sel && pal_cpu_addr>=12'h400 && pal_cpu_addr<=12'h5ff)
                        grey_flags[pal_cpu_addr[8:1]]<=bg_status_r[1];
                endcase
            end
        end
    end
    jtframe_dual_ram #(.DW(8),.AW(12)) pal_low (
        .clk0(clk_sys),.addr0(pal_cpu_addr),.data0(vwdata),.we0(accept_write&&pal_sel),.q0(pal_cpu_q),
        .clk1(clk_sys),.addr1(pal_lo_addr),.data1(8'd0),.we1(1'b0),.q1(pal_lo_q));
    jtframe_dual_ram #(.DW(8),.AW(12)) pal_high (
        .clk0(clk_sys),.addr0(pal_cpu_addr),.data0(vwdata),.we0(accept_write&&pal_sel),.q0(),
        .clk1(clk_sys),.addr1(pal_hi_addr),.data1(8'd0),.we1(1'b0),.q1(pal_hi_q));
    jtframe_dual_ram #(.DW(8),.AW(10)) text_low (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&tx_sel&&!vaddr[0]),.q0(tx_cpu_lo),
        .clk1(clk_sys),.addr1(ram_map_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(tx_lo));
    jtframe_dual_ram #(.DW(8),.AW(10)) text_high (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&tx_sel&&vaddr[0]),.q0(tx_cpu_hi),
        .clk1(clk_sys),.addr1(ram_map_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(tx_hi));
    jtframe_dual_ram #(.DW(8),.AW(10)) bg_low (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&bg_sel&&!vaddr[0]),.q0(bg_cpu_lo),
        .clk1(clk_sys),.addr1(ram_map_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(bg_lo));
    jtframe_dual_ram #(.DW(8),.AW(10)) bg_high (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&bg_sel&&vaddr[0]),.q0(bg_cpu_hi),
        .clk1(clk_sys),.addr1(ram_map_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(bg_hi));
    // Five synchronous read mirrors allow all meaningful descriptor fields to
    // be tested together. CPU writes reach every mirror; no frame latch is guessed.
    assign spr_cpu_q=spr_cpu_values[0];
    // Per-frame sprite snapshot (see the register note above): the ROM rewrites
    // the list in the second half of its raster frame, i.e. mid-picture. Copy
    // the five fields of all 96 objects at frame_start (96 cycles, blanking);
    // the renderer reads the snapshot with the same one-clock read latency.
    logic cp_run, cp_we;
    logic [6:0] cp_idx, cp_idx_q;
    logic [7:0] spr_snap_q[0:4];
    always_ff @(posedge clk_sys) begin
        if(reset) begin cp_run<=0; cp_we<=0; cp_idx<=0; cp_idx_q<=0; end
        else begin
            cp_we<=cp_run; cp_idx_q<=cp_idx;
            if(frame_start) begin cp_run<=1; cp_idx<=0; end
            else if(cp_run) begin
                if(cp_idx==7'd95) cp_run<=0; else cp_idx<=cp_idx+7'd1;
            end
        end
    end
    genvar f;
    generate for(f=0;f<5;f=f+1) begin: sprite_fields
        jtframe_dual_ram #(.DW(8),.AW(11)) sprite_ram (
            .clk0(clk_sys),.addr0(spr_cpu_addr),.data0(vwdata),.we0(accept_write&&spr_sel),
            .q0(spr_cpu_values[f]),
            .clk1(clk_sys),.addr1({cp_idx,4'b0000}+11'(11+f)),
            .data1(8'd0),.we1(1'b0),.q1(spr_snap_q[f]));
        argus_snap_ram snapshot (
            .clk(clk_sys),.we(cp_we),.waddr(cp_idx_q),.wdata(spr_snap_q[f]),
            .raddr(sprite_read_index),.q(spr_q[f]));
    end endgenerate

    typedef enum logic [3:0] {IDLE,TILE_BEGIN,TILE_WAIT,TILE_META,ROW_START,
        ROW_WAIT,ISSUE,DRAIN,NEXT,SPR_WAIT,SPR_TEST} state_t;
    state_t state;
    localparam logic [1:0] BACKGROUND=0,SPRITES=1,TEXT=2,CLEAR=3;
    logic [1:0] pass;
    logic [9:0] render_y;
    logic [8:0] render_x;
    logic [15:0] sx_l,sy_l,intensity_l;
    logic flip_l,user_flip_l;
    logic [4:0] mosaic_step;
    logic mosaic_negative;
    logic [8:0] sample_x,sample_y,source_x,source_y;
    // Bottom-right mosaic sampling leaves the incomplete right-edge block black.
    // Constants equal floor(256/step)*step, avoiding another variable divider.
    function automatic logic [8:0] mosaic_painted_end(input logic [4:0] step);
        case(step)
            3,5,15:mosaic_painted_end=9'd255;
            6,7,9,12,14:mosaic_painted_end=9'd252;
            10:mosaic_painted_end=9'd250;
            11:mosaic_painted_end=9'd253;
            13:mosaic_painted_end=9'd247;
            default:mosaic_painted_end=9'd256;
        endcase
    endfunction
    // Exact unsigned modulo for the complete 9-bit coordinate domain.
    // value=32*high4+low5; each table residue is below step, so one
    // 5-bit conditional subtraction combines them. No divider or cycle
    // is added; row/prefetch scheduling and held 0x80 state are unchanged.
    function automatic logic [3:0] mosaic_remainder9(input logic [8:0] value, input logic [4:0] step);
        logic [63:0] high_remainders;
        logic [127:0] low_remainders;
        logic [4:0] remainder_sum;
        begin
            high_remainders=0; low_remainders=0;
            case(step)
            5'd1: begin high_remainders=64'h0000000000000000; low_remainders=128'h00000000000000000000000000000000; end
            5'd2: begin high_remainders=64'h0000000000000000; low_remainders=128'h10101010101010101010101010101010; end
            5'd3: begin high_remainders=64'h0120120120120120; low_remainders=128'h10210210210210210210210210210210; end
            5'd4: begin high_remainders=64'h0000000000000000; low_remainders=128'h32103210321032103210321032103210; end
            5'd5: begin high_remainders=64'h0314203142031420; low_remainders=128'h10432104321043210432104321043210; end
            5'd6: begin high_remainders=64'h0420420420420420; low_remainders=128'h10543210543210543210543210543210; end
            5'd7: begin high_remainders=64'h4036251403625140; low_remainders=128'h32106543210654321065432106543210; end
            5'd8: begin high_remainders=64'h0000000000000000; low_remainders=128'h76543210765432107654321076543210; end
            5'd9: begin high_remainders=64'h3726150483726150; low_remainders=128'h43210876543210876543210876543210; end
            5'd10: begin high_remainders=64'h0864208642086420; low_remainders=128'h10987654321098765432109876543210; end
            5'd11: begin high_remainders=64'h789a0123456789a0; low_remainders=128'h9876543210a9876543210a9876543210; end
            5'd12: begin high_remainders=64'h0480480480480480; low_remainders=128'h76543210ba9876543210ba9876543210; end
            5'd13: begin high_remainders=64'hc60718293a4b5c60; low_remainders=128'h543210cba9876543210cba9876543210; end
            5'd14: begin high_remainders=64'h40a62c840a62c840; low_remainders=128'h3210dcba9876543210dcba9876543210; end
            5'd15: begin high_remainders=64'h0db97531eca86420; low_remainders=128'h10edcba9876543210edcba9876543210; end
            5'd16: begin high_remainders=64'h0000000000000000; low_remainders=128'hfedcba9876543210fedcba9876543210; end
                default: begin high_remainders=0; low_remainders=0; end
            endcase
            remainder_sum={1'b0,high_remainders[{value[8:5],2'b00} +: 4]}+
                          {1'b0,low_remainders[{value[4:0],2'b00} +: 4]};
            mosaic_remainder9=remainder_sum>=step ? 4'(remainder_sum-step) : remainder_sum[3:0];
        end
    endfunction
    logic [5:0] next_count;
    logic [4:0] mosaic_first,mosaic_distance,mosaic_left;
    logic [3:0] mosaic_sub_x,mosaic_x_remainder;
    logic sample_outside;
    logic [23:0] row_base;
    logic [11:0] row_code;
    logic row_text,row_hflip,row_vflip;
    logic [3:0] row_y,sub_x,row_pal;
    logic [5:0] issue_count,issue_i;
    logic signed [10:0] draw_x,object_x,object_y,object_dy;
    logic object_visible,row_busy,row_done;
    logic [63:0] row_pixels,fetched_pixels;
    logic [1:0] drain_count,slot_valid;
    logic [9:0] slot_tag[0:1];
    logic [9:0] next_y;
    logic glyph_valid;
    logic [10:0] glyph_map_addr;
    logic [8:0] glyph_source_y;
    logic [63:0] glyph_pixels;
    logic [3:0] glyph_pal;
    typedef enum logic [1:0] {PF_SCAN,PF_TEST,PF_START,PF_WAIT} pf_state_t;
    pf_state_t pf_state;
    logic [6:0] pf_index;
    logic [2:0] pf_pair;
    logic pf_half,pf_done,pf_start;
    logic [23:0] pf_addr;
    logic signed [10:0] pf_y,pf_dy;
    logic [3:0] pf_gfx_y;
    logic pf_visible;
    typedef enum logic [2:0] {SP_SCAN,SP_TEST,SP_ROW_START,SP_ROW_WAIT,SP_HOLD,SP_FINISHED} sp_state_t;
    sp_state_t sp_state;
    logic [6:0] sp_index;
    logic [11:0] sp_code;
    logic [3:0] sp_pal,sp_y;
    logic sp_hflip,sp_vflip,sp_active,sp_take,sp_push;
    logic signed [10:0] sp_x;
    logic [63:0] sp_pixels;
    logic [2:0] sp_count;
    logic [1:0] sp_read,sp_write;
    logic [63:0] sp_queue_pixels[0:3];
    logic [3:0] sp_queue_pal[0:3];
    logic signed [10:0] sp_queue_x[0:3];
    typedef enum logic [2:0] {TP_BEGIN,TP_MAP_WAIT,TP_META,TP_START,TP_WAIT,TP_DONE} tp_state_t;
    tp_state_t tp_state;
    logic [9:0] tp_target_y,tp_future_y;
    logic [8:0] tp_bg_y,tp_calc_bg_y,tp_sample_y;
    logic [7:0] tp_tx_y;
    logic [4:0] tp_column,tp_bg_column,tp_bg_last,tp_calc_step;
    logic tp_text,tp_half,tp_negative,tp_flip,tp_sample_outside,tp_access,tp_start;
    logic [10:0] tp_map_addr;
    logic [23:0] tp_word_addr;
    assign sp_active=pass==SPRITES;
    assign sp_take=state==SPR_WAIT && sp_count!=0;
    assign sp_push=sp_active && sp_state==SP_HOLD && sp_count<4;
    assign sprite_read_index=sp_active ? sp_index : pf_index;
    assign next_y = vpos==10'd249 ? 10'd0 : vpos+10'd1;
    assign tp_future_y=vpos>=248 ? vpos-10'd248 : vpos+10'd2;
    assign tp_access=RAW_OBJECT_STORE && (state==IDLE || sp_active);
    assign tp_map_addr=tp_text ? {tp_column,tp_tx_y[7:3],1'b0} :
                                      {5'(tp_bg_column+tp_column),tp_bg_y[8:4],1'b0};
    assign ram_map_addr=tp_access ? tp_map_addr : map_addr;
    assign tp_start=tp_access && tp_state==TP_START && !row_busy && !line_start &&
                    (state==IDLE || (sp_count==4 && state==ISSUE));
    always_comb begin
        tp_flip=board_flip^user_flip_180;
        tp_calc_step=mosaic_reg==8'h80 ? mosaic_held_step :
                     (mosaic_reg[3:0]==4'hf ? 5'd0 : 5'd16-{1'b0,mosaic_reg[3:0]});
        tp_negative=mosaic_reg==8'h80 ? mosaic_held_negative : mosaic_reg[7];
        tp_sample_y=user_flip_180 ? 9'd255-tp_future_y[8:0] : tp_future_y[8:0];
        if(tp_calc_step!=0)begin
            tp_sample_y=tp_sample_y-{5'd0,mosaic_remainder9(tp_sample_y,tp_calc_step)};
            if(tp_negative)tp_sample_y=tp_sample_y+{4'd0,tp_calc_step}-9'd1;
        end
        tp_sample_outside=tp_sample_y<16 || tp_sample_y>239;
        if(user_flip_180)tp_sample_y=9'd255-tp_sample_y;
        tp_calc_bg_y=tp_flip ? 9'd255+scrolly[8:0]-tp_sample_y : scrolly[8:0]+tp_sample_y;
    end
    always_comb begin
        sample_x=render_x; sample_y=render_y[8:0];
        next_count=6'd16;mosaic_first=5'd16;mosaic_distance=0;mosaic_x_remainder=0;
        sample_outside=0;
        if(pass==BACKGROUND && mosaic_step!=0) begin
            // A user 180-degree rotation mirrors the completed board image,
            // including its mosaic grid and clipped edge blocks.
            if(user_flip_l) begin
                sample_x=9'd255-render_x;sample_y=9'd255-render_y[8:0];
            end
            mosaic_x_remainder=mosaic_remainder9(sample_x,mosaic_step);
            mosaic_first=user_flip_l ? {1'b0,mosaic_x_remainder}+5'd1 :
                                      mosaic_step-{1'b0,mosaic_x_remainder};
            next_count={1'b0,mosaic_first};
            sample_x=sample_x-{5'd0,mosaic_x_remainder};
            sample_y=sample_y-{5'd0,mosaic_remainder9(sample_y,mosaic_step)};
            if(mosaic_negative) begin
                sample_x=sample_x+{4'd0,mosaic_step}-9'd1;
                sample_y=sample_y+{4'd0,mosaic_step}-9'd1;
            end
            // MAME's mosaic bitmap is only painted inside native y16..239.
            sample_outside=sample_x>255 || sample_y<16 || sample_y>239;
            if(user_flip_l) begin sample_x=9'd255-sample_x;sample_y=9'd255-sample_y;end
        end
        if(pass==TEXT) begin
            source_x={1'b0,(flip_l ? (8'd255-render_x[7:0]) : render_x[7:0])};
            source_y={1'b0,(flip_l ? (8'd255-render_y[7:0]) : render_y[7:0])};
            next_count=6'd8-{3'd0,source_x[2:0]};
            if(flip_l) next_count={3'd0,source_x[2:0]}+6'd1;
        end else begin
            source_x=flip_l ? (9'd255+sx_l[8:0]-sample_x) : (sx_l[8:0]+sample_x);
            source_y=flip_l ? (9'd255+sy_l[8:0]-sample_y) : (sy_l[8:0]+sample_y);
            if(mosaic_step==0) begin
                next_count=6'd16-{2'd0,source_x[3:0]};
                if(flip_l) next_count={2'd0,source_x[3:0]}+6'd1;
            end else if(pass==BACKGROUND && !sample_outside)begin
                // Group all mosaic samples that use this one source glyph.
                mosaic_distance=flip_l ? {1'b0,source_x[3:0]} : 5'd15-{1'b0,source_x[3:0]};
                next_count={1'b0,mosaic_first}+{1'b0,(mosaic_distance-{1'b0,mosaic_remainder9({4'd0,mosaic_distance},mosaic_step)})};
            end
        end
        if({3'd0,next_count}>9'd256-render_x) next_count=6'(9'd256-render_x);
        if(pass==BACKGROUND && mosaic_step!=0 && mosaic_negative && !user_flip_l && !sample_outside &&
           {3'd0,next_count}>mosaic_painted_end(mosaic_step)-render_x)
            next_count=6'(mosaic_painted_end(mosaic_step)-render_x);
        object_x=$signed({3'd0,spr_q[1]})-(spr_q[2][0] ? 11'sd256 : 11'sd0);
        object_y=$signed({3'd0,spr_q[0]})-(spr_q[2][1] ? 11'sd0 : 11'sd256);
        if(flip_l) begin object_x=11'sd240-object_x; object_y=11'sd240-object_y; end
        object_dy=$signed({1'b0,render_y})-object_y;
        object_visible=!(spr_q[4]==0 && spr_q[0]==8'hf0) && object_dy>=0 && object_dy<16 &&
                       object_x<256 && object_x> -16;
    end
    always_comb begin
        pf_y=$signed({3'd0,spr_q[0]})-(spr_q[2][1] ? 11'sd0 : 11'sd256);
        if(board_flip^user_flip_180)pf_y=11'sd240-pf_y;
        pf_dy=$signed({1'b0,next_y})-pf_y;
        pf_visible=!(spr_q[4]==0 && spr_q[0]==8'hf0) && pf_y>=0 && pf_y<240;
        pf_gfx_y={pf_pair,1'b0};
        if(pf_dy>=-8 && pf_dy<16)pf_gfx_y=pf_dy<0 ? 4'd0 : pf_dy[3:0];
        if(spr_q[2][5]^board_flip^user_flip_180)pf_gfx_y=4'd15-pf_gfx_y;
    end
    assign pf_start=!RAW_OBJECT_STORE && state==IDLE && pf_state==PF_START && !row_busy && !line_start;
    valtric_gfx_row #(.CACHE_AW(CACHE_AW),.EXTERNAL_GFX_CACHE(EXTERNAL_GFX_CACHE)) gfx_row (
        .clk_sys(clk_sys),.reset(reset),
        .start((state==ROW_START || (sp_active && sp_state==SP_ROW_START && sp_count<4)) && !row_busy),
        .base(sp_active ? VALTRIC_GFX1 : row_base),.code(sp_active ? sp_code : row_code),
        .text8(sp_active ? 1'b0 : row_text),.hflip(sp_active ? sp_hflip : row_hflip),
        .vflip(sp_active ? sp_vflip : row_vflip),.bypass(sp_active && RAW_OBJECT_STORE),
        .preload_start(pf_start || tp_start),.preload_addr(tp_start ? tp_word_addr : pf_addr),.preload_done(pf_done),
        .y(sp_active ? sp_y : row_y),.busy(row_busy),.done(row_done),.pixels(fetched_pixels),
        .req(rom_req),.addr(rom_addr),.ready(rom_ready),.rdata(rom_rdata));

    // Idle-time prefetch changes neither descriptor RAM nor the board latch model.
    always_ff @(posedge clk_sys) begin
        if(reset || RAW_OBJECT_STORE)begin pf_state<=PF_SCAN;pf_index<=0;pf_pair<=0;pf_half<=0;pf_addr<=0;end
        else if(pf_state==PF_WAIT && pf_done)begin
            if(pf_half)begin
                pf_half<=0;
                if(pf_index==95)begin pf_index<=0;pf_pair<=pf_pair+3'd1;end
                else pf_index<=pf_index+7'd1;
            end else pf_half<=1;
            pf_state<=PF_SCAN;
        end else if(state==IDLE && !line_start)begin
            case(pf_state)
                PF_SCAN:pf_state<=PF_TEST;
                PF_TEST:if(pf_visible)begin
                    pf_addr<=VALTRIC_GFX1+{7'd0,spr_q[2][7:6],spr_q[3],7'd0}
                            +(pf_half ? 24'd64 : 24'd0)+{18'd0,pf_gfx_y[3:1],3'd0};
                    pf_state<=PF_START;
                end else begin
                    pf_half<=0;
                    if(pf_index==95)begin pf_index<=0;pf_pair<=pf_pair+3'd1;end
                    else pf_index<=pf_index+7'd1;
                    pf_state<=PF_SCAN;
                end
                PF_START:if(pf_start)pf_state<=PF_WAIT;
                default:;
            endcase
        end else if(state!=IDLE && pf_state!=PF_WAIT)pf_state<=PF_SCAN;
    end
    // ROM-only lookahead never changes CPU-visible RAM or the current row.
    // A full four-row queue covers a slow fill while ordered sprite drawing runs.
    always_ff @(posedge clk_sys)begin
        if(reset || !RAW_OBJECT_STORE)begin
            tp_state<=TP_BEGIN;tp_target_y<=0;tp_bg_y<=0;tp_tx_y<=0;tp_column<=0;
            tp_bg_column<=0;tp_bg_last<=0;tp_text<=0;tp_half<=0;tp_word_addr<=0;
        end else if(tp_state==TP_WAIT && pf_done)begin
            if(!tp_text && !tp_half)begin
                tp_half<=1;tp_word_addr<=tp_word_addr+24'd64;tp_state<=TP_START;
            end else begin
                tp_half<=0;
                if(tp_column==(tp_text ? 5'd31 : tp_bg_last))begin
                    if(tp_text)tp_state<=TP_DONE;
                    else begin tp_text<=1;tp_column<=0;tp_state<=TP_MAP_WAIT;end
                end else begin tp_column<=tp_column+5'd1;tp_state<=TP_MAP_WAIT;end
            end
        end else if(tp_access)begin
            case(tp_state)
                TP_BEGIN:if(tp_future_y>=16 && tp_future_y<=239)begin
                    tp_target_y<=tp_future_y;tp_bg_y<=tp_calc_bg_y;
                    tp_tx_y<=tp_flip ? 8'd255-tp_future_y[7:0] : tp_future_y[7:0];
                    tp_bg_column<=scrollx[8:4];tp_bg_last<=scrollx[3:0]==0 ? 5'd15 : 5'd16;
                    tp_text<=!bg_status[0] || tp_sample_outside;
                    tp_column<=0;tp_half<=0;tp_state<=TP_MAP_WAIT;
                end
                TP_MAP_WAIT:tp_state<=TP_META;
                TP_META:begin
                    if(tp_text)tp_word_addr<=VALTRIC_GFX3+{9'd0,tx_hi[7:6],tx_lo,5'd0}
                                              +{19'd0,(tp_tx_y[2:0]^(tx_hi[5] ? 3'd7 : 3'd0)),2'd0};
                    else tp_word_addr<=VALTRIC_GFX2+{6'd0,bg_hi[5],bg_hi[7:6],bg_lo,7'd0}
                                              +{18'd0,tp_bg_y[3:0],2'd0};
                    tp_word_addr[2:0]<=0;tp_state<=TP_START;
                end
                TP_START:if(tp_start)tp_state<=TP_WAIT;
                TP_DONE:if(tp_target_y!=tp_future_y)tp_state<=TP_BEGIN;
                default:;
            endcase
        end else if(tp_state==TP_META)tp_state<=TP_MAP_WAIT;
    end
    always_ff @(posedge clk_sys)begin
        if(reset || !sp_active)begin sp_count<=0;sp_read<=0;sp_write<=0;end
        else begin
            case({sp_push,sp_take})
                2'b10:sp_count<=sp_count+3'd1;
                2'b01:sp_count<=sp_count-3'd1;
                default:;
            endcase
            if(sp_push)begin
                sp_queue_pixels[sp_write]<=sp_pixels;sp_queue_pal[sp_write]<=sp_pal;
                sp_queue_x[sp_write]<=sp_x;sp_write<=sp_write+2'd1;
            end
            if(sp_take)sp_read<=sp_read+2'd1;
        end
    end
    // Preserve descriptor order while the next row fetch overlaps current drawing.
    // A four-entry ordered FIFO plus SP_HOLD buffers rows, not a frame buffer.
    always_ff @(posedge clk_sys)begin
        if(reset)begin
            sp_state<=SP_SCAN;sp_index<=0;sp_code<=0;sp_pal<=0;sp_y<=0;
            sp_hflip<=0;sp_vflip<=0;sp_x<=0;sp_pixels<=0;
        end else if(!sp_active)begin sp_state<=SP_SCAN;sp_index<=0;end
        else case(sp_state)
            SP_SCAN:sp_state<=SP_TEST;
            SP_TEST:if(object_visible)begin
                sp_code<={2'd0,spr_q[2][7:6],spr_q[3]};sp_pal<=spr_q[4][3:0];
                sp_hflip<=spr_q[2][4]^flip_l;sp_vflip<=spr_q[2][5]^flip_l;
                sp_y<=object_dy[3:0];sp_x<=object_x;sp_state<=SP_ROW_START;
            end else if(sp_index==95)sp_state<=SP_FINISHED;
            else begin sp_index<=sp_index+7'd1;sp_state<=SP_SCAN;end
            SP_ROW_START:if(!row_busy && sp_count<4)sp_state<=SP_ROW_WAIT;
            SP_ROW_WAIT:if(row_done)begin sp_pixels<=fetched_pixels;sp_state<=SP_HOLD;end
            SP_HOLD:if(sp_push)begin
                if(sp_index==95)sp_state<=SP_FINISHED;
                else begin sp_index<=sp_index+7'd1;sp_state<=SP_SCAN;end
            end
            default:;
        endcase
    end
    logic [3:0] source_pixel,issue_pen;
    logic signed [10:0] issue_x;
    logic [7:0] color_index;
    logic issue_opaque,p1_en,p2_en,p1_bg,p1_sprite,p1_grey,p1_clear;
    logic [8:0] p1_addr,p2_addr,line_read_addr;
    logic [23:0] p2_rgb,old_rgb,scan_rgb;
    logic [15:0] p1_intensity;
    always_comb begin
        source_pixel=pass==SPRITES ? issue_i[3:0] :
                     (pass==BACKGROUND && mosaic_step!=0 ? mosaic_sub_x :
                     (flip_l ? sub_x-issue_i[3:0] : sub_x+issue_i[3:0]));
        issue_pen=row_pixels[{source_pixel,2'b00} +: 4];
        issue_x=draw_x+$signed({5'd0,issue_i});
        issue_opaque=state==ISSUE && issue_x>=0 && issue_x<256 &&
                     (pass==BACKGROUND || pass==CLEAR || issue_pen!=4'hf);
        color_index={row_pal,issue_pen};
        case(pass)
            BACKGROUND: pal_lo_addr=12'h400+{3'd0,color_index,1'b0};
            TEXT: pal_lo_addr=12'h600+{3'd0,color_index,1'b0};
            default: pal_lo_addr={3'd0,color_index,1'b0};
        endcase
        pal_hi_addr=pal_lo_addr+12'd1;
        line_read_addr={render_y[0],issue_x[7:0]};
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            p1_en<=0;p2_en<=0;p1_bg<=0;p1_sprite<=0;p1_grey<=0;p1_clear<=0;
            p1_addr<=0;p2_addr<=0;p2_rgb<=0;p1_intensity<=0;
        end else begin
            p1_en<=issue_opaque;p1_addr<=line_read_addr;
            p1_bg<=pass==BACKGROUND;p1_sprite<=pass==SPRITES;
            p1_clear<=pass==CLEAR || (pass==BACKGROUND && sample_outside);
            p1_grey<=grey_flags[color_index];p1_intensity<=intensity_l;
            p2_en<=p1_en;p2_addr<=p1_addr;
            if(p1_clear) p2_rgb<=0;
            else if(p1_sprite) p2_rgb<=sprite_blend(old_rgb,palette_rgb(pal_lo_q,pal_hi_q),pal_hi_q[3:0]);
            else if(p1_bg) p2_rgb<=background_effect(palette_rgb(pal_lo_q,pal_hi_q),p1_grey,p1_intensity);
            else p2_rgb<=palette_rgb(pal_lo_q,pal_hi_q);
        end
    end

    argus_sync_line_ram #(.DW(24),.AW(9)) scan_lines(
        .clk(clk_sys),.raddr({vpos[0],hpos[7:0]}),.q(scan_rgb),
        .waddr(p2_addr),.wdata(p2_rgb),.we(p2_en));

    argus_sync_line_ram #(.DW(24),.AW(9)) blend_lines(
        .clk(clk_sys),.raddr(line_read_addr),.q(old_rgb),
        .waddr(p2_addr),.wdata(p2_rgb),.we(p2_en));
    logic sample_ce,sample_active;
    always_ff @(posedge clk_sys) begin
        if(reset) begin sample_ce<=0;sample_active<=0;pixel_valid<=0;r<=0;g<=0;b<=0;end
        else begin
            sample_ce<=ce_pixel;
            sample_active<=active && game_id==1 && slot_valid[vpos[0]] && slot_tag[vpos[0]]==vpos;
            pixel_valid<=sample_ce && sample_active;
            if(sample_ce) begin
                r<=sample_active ? scan_rgb[23:16] : 8'd0;
                g<=sample_active ? scan_rgb[15:8] : 8'd0;
                b<=sample_active ? scan_rgb[7:0] : 8'd0;
            end
        end
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE;pass<=BACKGROUND;render_y<=0;render_x<=0;
            sx_l<=0;sy_l<=0;intensity_l<=0;flip_l<=0;user_flip_l<=0;
            mosaic_step<=0;mosaic_negative<=0;mosaic_held_step<=0;mosaic_held_negative<=0;
            map_addr<=0;row_base<=0;row_code<=0;row_text<=0;row_hflip<=0;row_vflip<=0;
            row_y<=0;sub_x<=0;row_pal<=0;issue_count<=0;issue_i<=0;draw_x<=0;
            mosaic_left<=0;mosaic_sub_x<=0;
            row_pixels<=0;drain_count<=0;spr_index<=0;slot_valid<=0;slot_tag[0]<=0;slot_tag[1]<=0;
            deadline_miss<=0;
            glyph_valid<=0;glyph_map_addr<=0;glyph_source_y<=0;glyph_pixels<=0;glyph_pal<=0;
            glyph_generation<=0;
        end else begin
            if(accept_write && bg_sel && vaddr[10:1]==glyph_map_addr[10:1])glyph_valid<=0;
            if(ce_pixel && active && game_id==1 && (!slot_valid[vpos[0]] || slot_tag[vpos[0]]!=vpos))
                deadline_miss<=1;
            if(line_start && state!=IDLE) deadline_miss<=1;
            case(state)
                IDLE: if(line_start && game_id==1 && next_y>=16 && next_y<=239) begin
                    render_y<=next_y;render_x<=0;sx_l<=scrollx;sy_l<=scrolly;intensity_l<=intensity;
                    flip_l<=board_flip^user_flip_180;user_flip_l<=user_flip_180;
                    if(bg_status[0] && mosaic_reg!=8'h80) begin
                        mosaic_step<=mosaic_reg[3:0]==4'hf ? 5'd0 : 5'd16-{1'b0,mosaic_reg[3:0]};
                        mosaic_negative<=mosaic_reg[7];
                        mosaic_held_step<=mosaic_reg[3:0]==4'hf ? 5'd0 : 5'd16-{1'b0,mosaic_reg[3:0]};
                        mosaic_held_negative<=mosaic_reg[7];
                    end else begin mosaic_step<=mosaic_held_step;mosaic_negative<=mosaic_held_negative;end
                    slot_valid[next_y[0]]<=0;glyph_valid<=0;
                    pass<=bg_status[0] ? BACKGROUND : CLEAR;state<=TILE_BEGIN;
                end
                TILE_BEGIN: begin
                    draw_x<=$signed({2'd0,render_x});issue_count<=next_count;issue_i<=0;
                    mosaic_left<=mosaic_first;mosaic_sub_x<=source_x[3:0];
                    sub_x<=pass==TEXT ? {1'b0,source_x[2:0]} : source_x[3:0];
                    row_text<=pass==TEXT;row_hflip<=0;row_vflip<=0;
                    row_y<=pass==TEXT ? {1'b0,source_y[2:0]} : source_y[3:0];
                    if(pass==TEXT) begin map_addr<={source_x[7:3],source_y[7:3],1'b0};state<=TILE_WAIT;end
                    else if(pass==CLEAR || sample_outside) begin row_pixels<=0;state<=ISSUE;end
                    else if(glyph_valid && glyph_generation==bg_generation
                            && glyph_map_addr=={source_x[8:4],source_y[8:4],1'b0}
                            && glyph_source_y==source_y)begin
                        row_pixels<=glyph_pixels;row_pal<=glyph_pal;state<=ISSUE;
                    end else begin map_addr<={source_x[8:4],source_y[8:4],1'b0};state<=TILE_WAIT;end
                end
                TILE_WAIT: state<=TILE_META;
                TILE_META: begin
                    glyph_generation<=bg_generation;
                    if(pass==TEXT) begin
                        row_base<=VALTRIC_GFX3;row_code<={2'd0,tx_hi[7:6],tx_lo};row_pal<=tx_hi[3:0];
                        // Coordinate reversal already applies the global flip.
                        row_hflip<=tx_hi[4];row_vflip<=tx_hi[5];
                    end else begin
                        row_base<=VALTRIC_GFX2;row_code<={1'b0,bg_hi[5],bg_hi[7:6],bg_lo};row_pal<=bg_hi[3:0];
                    end
                    state<=ROW_START;
                end
                ROW_START:if(!row_busy)state<=ROW_WAIT;
                ROW_WAIT:if(row_done)begin
                    row_pixels<=fetched_pixels;state<=ISSUE;
                    if(pass==BACKGROUND)begin
                        glyph_valid<=1;glyph_map_addr<=map_addr;glyph_source_y<=source_y;
                        glyph_pixels<=fetched_pixels;glyph_pal<=row_pal;
                    end
                end
                ISSUE:begin
                    if(pass==BACKGROUND && mosaic_step!=0)begin
                        if(mosaic_left==1)begin
                            mosaic_left<=mosaic_step;
                            mosaic_sub_x<=flip_l ? mosaic_sub_x-mosaic_step[3:0] : mosaic_sub_x+mosaic_step[3:0];
                        end else mosaic_left<=mosaic_left-5'd1;
                    end
                    if(issue_i+6'd1>=issue_count)begin drain_count<=0;state<=DRAIN;end
                    else issue_i<=issue_i+6'd1;
                end
                // Last pixel commits before NEXT can publish or consume another row.
                DRAIN: if(drain_count==1) state<=NEXT;else drain_count<=drain_count+2'd1;
                NEXT: begin
                    if(pass==SPRITES) begin
                        state<=SPR_WAIT;
                    end else if(render_x+{3'd0,issue_count}>=256) begin
                        if(pass==TEXT) begin slot_tag[render_y[0]]<=render_y;slot_valid[render_y[0]]<=1;state<=IDLE;end
                        else begin pass<=SPRITES;spr_index<=0;state<=SPR_WAIT;end
                    end else begin render_x<=render_x+{3'd0,issue_count};state<=TILE_BEGIN;end
                end
                SPR_WAIT:begin
                    if(sp_count!=0)begin
                        row_pixels<=sp_queue_pixels[sp_read];row_pal<=sp_queue_pal[sp_read];draw_x<=sp_queue_x[sp_read];
                        issue_i<=0;issue_count<=16;state<=ISSUE;
                    end else if(sp_state==SP_FINISHED)begin pass<=TEXT;render_x<=0;state<=TILE_BEGIN;end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
