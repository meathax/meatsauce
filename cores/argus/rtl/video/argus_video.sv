// SPDX-License-Identifier: GPL-3.0-or-later
// Argus draft/JTFRAME queued line renderer: interfaces.md v2.
// Argus is implemented; other game IDs deliberately have no valid renderer.
module argus_video #(
    // Standalone uses cached ROM replies. Root enables direct shared GFX1
    // storage only after the joint loader and raw response path are installed.
    parameter integer SHARED_RAW_SPRITES=0,
    parameter integer CACHE_AW=12,
    // Root's shared GPU cache owns ROM storage when enabled.
    parameter integer EXTERNAL_GFX_CACHE=0
) (
    input logic clk_sys, reset,
    input logic [1:0] game_id, timing_profile,
    input logic user_flip_180,
    input logic ce_pixel,
    input logic [9:0] hpos, vpos,
    input logic active, hblank, vblank, line_start, frame_start,
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

    // No RAM reset loop: CPU must initialize RAM just as on the board.
    // Both simulation and synthesis instantiate exactly these same RAMs.
    logic [15:0] scrollx0, scrolly0, scrollx1, scrolly1, intensity;
    logic [7:0] bg_status;
    logic board_flip;
    // The ROM rewrites scroll/flip/intensity near its end-of-frame IRQ (MAME
    // raster line 240), which falls mid-picture on the 250-line output raster.
    // MAME shows the end-of-frame state for the whole frame, so the renderer
    // uses a copy captured once per output frame instead of the live registers.
    logic [15:0] scrollx0_f, scrolly0_f, scrollx1_f, scrolly1_f, intensity_f;
    logic board_flip_f;
    logic cp_run, cp_we;
    logic [6:0] cp_idx, cp_idx_q;
    logic [2:0] cp_field, cp_field_q;
    logic [7:0] spr_snap_q;
    wire [10:0] cp_addr={cp_idx,4'd11+{1'b0,cp_field}};
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            scrollx0_f<=0; scrolly0_f<=0; scrollx1_f<=0; scrolly1_f<=0;
            intensity_f<=0; board_flip_f<=0;
        end else if(frame_start) begin
            scrollx0_f<=scrollx0; scrolly0_f<=scrolly0; scrollx1_f<=scrollx1;
            scrolly1_f<=scrolly1; intensity_f<=intensity; board_flip_f<=board_flip;
        end
    end
    logic [255:0] grey_flags;
    logic bus_busy, mapped, pal_sel, tx_sel, bg_sel, spr_sel, reg_sel;
    logic accept_write;
    logic [15:0] bus_addr;
    logic [11:0] pal_cpu_addr;
    logic [10:0] spr_cpu_addr;
    logic [7:0] pal_cpu_q, tx_cpu_q, bg_cpu_q, spr_cpu_q;
    logic [10:0] map_addr, spr_addr;
    logic [7:0] tx_q, bg_q;
    logic [7:0] pal_lo_q[0:1],pal_hi_q[0:1],pal_cpu_lane[0:1];
    logic [7:0] tx_hi_q,bg_hi_q,tx_cpu_lo,tx_cpu_hi,bg_cpu_lo,bg_cpu_hi;
    logic [7:0] sprite_fields[0:4];
    logic [11:0] pal_lo_addr[0:1],pal_hi_addr[0:1];
    always_comb begin
        pal_sel = game_id==0 && vaddr>=16'hc400 && vaddr<=16'hcfff;
        tx_sel  = game_id==0 && vaddr>=16'hd000 && vaddr<=16'hd7ff;
        bg_sel  = game_id==0 && vaddr>=16'hd800 && vaddr<=16'hdfff;
        spr_sel = game_id==0 && vaddr>=16'hf200 && vaddr<=16'hf7ff;
        reg_sel = game_id==0 && (vaddr==16'hc201 || vaddr==16'hc30c ||
                  (vaddr>=16'hc300 && vaddr<=16'hc303) ||
                  (vaddr>=16'hc308 && vaddr<=16'hc30b));
        mapped = pal_sel || tx_sel || bg_sel || spr_sel || reg_sel;
        accept_write = !reset && !bus_busy && vreq && mapped && vwe;
        pal_cpu_addr = vaddr[11:0]-12'h400;
        spr_cpu_addr = vaddr[10:0]-11'h200;
        vready = bus_busy;
        vrdata=8'hff;
        casez (bus_addr)
            16'hc201: vrdata={board_flip,7'd0};
            16'hc300: vrdata=scrollx0[7:0];
            16'hc301: vrdata=scrollx0[15:8];
            16'hc302: vrdata=scrolly0[7:0];
            16'hc303: vrdata=scrolly0[15:8];
            16'hc308: vrdata=scrollx1[7:0];
            16'hc309: vrdata=scrollx1[15:8];
            16'hc30a: vrdata=scrolly1[7:0];
            16'hc30b: vrdata=scrolly1[15:8];
            16'hc30c: vrdata=bg_status;
            default: begin
                if(bus_addr>=16'hc400 && bus_addr<=16'hcfff) vrdata=pal_cpu_q;
                if(bus_addr>=16'hd000 && bus_addr<=16'hd7ff) vrdata=tx_cpu_q;
                if(bus_addr>=16'hd800 && bus_addr<=16'hdfff) vrdata=bg_cpu_q;
                if(bus_addr>=16'hf200 && bus_addr<=16'hf7ff) vrdata=spr_cpu_q;
            end
        endcase
    end

    always_ff @(posedge clk_sys) begin
        if(reset) begin
            bus_busy<=0; bus_addr<=0; scrollx0<=0; scrolly0<=0;
            scrollx1<=0; scrolly1<=0; intensity<=0; bg_status<=8'h01;
            board_flip<=0; grey_flags<=0;
        end else begin
            if(bus_busy) bus_busy<=0;
            else if(vreq && mapped) begin bus_busy<=1; bus_addr<=vaddr; end
            if(accept_write) begin
                case(vaddr)
                    16'hc201: board_flip<=vwdata[7];
                    16'hc300: scrollx0[7:0]<=vwdata;
                    16'hc301: scrollx0[15:8]<=vwdata;
                    16'hc302: scrolly0[7:0]<=vwdata;
                    16'hc303: scrolly0[15:8]<=vwdata;
                    16'hc308: scrollx1[7:0]<=vwdata;
                    16'hc309: scrollx1[15:8]<=vwdata;
                    16'hc30a: scrolly1[7:0]<=vwdata;
                    16'hc30b: scrolly1[15:8]<=vwdata;
                    16'hc30c: begin
                        bg_status<=vwdata;
                        // MAME refreshes all BG colors on entering grayscale.
                        // Clearing bit1 alone leaves already processed colors.
                        if(bg_status!=vwdata && vwdata[1]) grey_flags<='1;
                    end
                    16'hc47f: begin intensity[15:8]<=vwdata; grey_flags<={256{bg_status[1]}}; end
                    16'hc4ff: begin intensity[7:0]<=vwdata; grey_flags<={256{bg_status[1]}}; end
                    default: begin
                        if(pal_sel && (pal_cpu_addr[11:8]==4 || pal_cpu_addr[11:8]==8))
                            grey_flags[pal_cpu_addr[7:0]]<=bg_status[1];
                    end
                endcase
            end
        end
    end

    assign pal_cpu_q=pal_cpu_lane[0];
    // One synchronous low/high palette read per pixel lane. All replicas
    // receive precisely the same accepted CPU writes.
    genvar palette_lane;
    generate for(palette_lane=0;palette_lane<2;palette_lane=palette_lane+1) begin: g_palette
        jtframe_dual_ram #(.DW(8),.AW(12)) low_ram (
            .clk0(clk_sys),.addr0(pal_cpu_addr),.data0(vwdata),.we0(accept_write&&pal_sel),.q0(pal_cpu_lane[palette_lane]),
            .clk1(clk_sys),.addr1(pal_lo_addr[palette_lane]),.data1(8'd0),.we1(1'b0),.q1(pal_lo_q[palette_lane]));
        jtframe_dual_ram #(.DW(8),.AW(12)) high_ram (
            .clk0(clk_sys),.addr0(pal_cpu_addr),.data0(vwdata),.we0(accept_write&&pal_sel),.q0(),
            .clk1(clk_sys),.addr1(pal_hi_addr[palette_lane]),.data1(8'd0),.we1(1'b0),.q1(pal_hi_q[palette_lane]));
    end endgenerate
    assign tx_cpu_q=vaddr[0] ? tx_cpu_hi : tx_cpu_lo;
    assign bg_cpu_q=vaddr[0] ? bg_cpu_hi : bg_cpu_lo;
    logic [10:0] prefetch_map_addr,text_read_addr;
    jtframe_dual_ram #(.DW(8),.AW(10)) text_low (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&tx_sel&&!vaddr[0]),.q0(tx_cpu_lo),
        .clk1(clk_sys),.addr1(text_read_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(tx_q));
    jtframe_dual_ram #(.DW(8),.AW(10)) text_high (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&tx_sel&&vaddr[0]),.q0(tx_cpu_hi),
        .clk1(clk_sys),.addr1(text_read_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(tx_hi_q));
    jtframe_dual_ram #(.DW(8),.AW(10)) bg1_low (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&bg_sel&&!vaddr[0]),.q0(bg_cpu_lo),
        .clk1(clk_sys),.addr1(map_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(bg_q));
    jtframe_dual_ram #(.DW(8),.AW(10)) bg1_high (
        .clk0(clk_sys),.addr0(vaddr[10:1]),.data0(vwdata),.we0(accept_write&&bg_sel&&vaddr[0]),.q0(bg_cpu_hi),
        .clk1(clk_sys),.addr1(map_addr[10:1]),.data1(8'd0),.we1(1'b0),.q1(bg_hi_q));
    jtframe_dual_ram #(.DW(8),.AW(11)) sprite_ram (
        .clk0(clk_sys),.addr0(spr_cpu_addr),.data0(vwdata),.we0(accept_write&&spr_sel),.q0(spr_cpu_q),
        .clk1(clk_sys),.addr1(cp_addr),.data1(8'd0),.we1(1'b0),.q1(spr_snap_q));
    // Per-frame sprite snapshot, same reason as the scroll copy above: the ROM
    // rewrites the sprite list in the second half of its raster frame, i.e. in
    // the middle of the output picture. Copy the five rendering fields of all
    // 96 objects from the CPU-visible RAM at frame_start (480 cycles, blanking).
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            cp_run<=0; cp_we<=0; cp_idx<=0; cp_field<=0; cp_idx_q<=0; cp_field_q<=0;
        end else begin
            cp_we<=cp_run; cp_idx_q<=cp_idx; cp_field_q<=cp_field;
            if(frame_start) begin cp_run<=1; cp_idx<=0; cp_field<=0; end
            else if(cp_run) begin
                if(cp_field==3'd4) begin
                    cp_field<=0;
                    if(cp_idx==7'd95) cp_run<=0; else cp_idx<=cp_idx+7'd1;
                end else cp_field<=cp_field+3'd1;
            end
        end
    end
    // Only the five rendering fields are cached; every byte remains CPU-readable.
    // Single synchronous parallel field read supplies one record/system-clock.
    genvar field;
    generate for(field=0;field<5;field=field+1) begin: g_sprite_fields
        jtframe_dual_ram #(.DW(8),.AW(7)) fields (
            .clk0(clk_sys),.addr0(cp_idx_q),.data0(spr_snap_q),
            .we0(cp_we&&cp_field_q==3'(field)),.q0(),
            .clk1(clk_sys),.addr1(spr_addr[6:0]),.data1(8'd0),.we1(1'b0),.q1(sprite_fields[field]));
    end endgenerate

    typedef enum logic [3:0] {
        IDLE,SCAN_WAIT,SCAN,TILE_BEGIN,MEM_WAIT,MEM_META,V1,V2,
        CAND_WAIT,CAND_META,ROW_START,ROW_WAIT,ENQUEUE,NEXT,FINISH
    } state_t;
    state_t state;
    localparam logic [2:0] BG0=0,OBJ_BACK=1,BG1=2,OBJ_FRONT=3,TEXT=4;
    logic [2:0] pass;
    logic scan_active,scan_wait;
    logic [9:0] render_y;
    logic [8:0] render_x;
    logic [15:0] sx0_l,sy0_l,sx1_l,sy1_l,intensity_l;
    logic flip_l,bg1_enable;
    logic [9:0] source_x;
    logic [8:0] source_y;
    logic [17:0] tile_byte;
    logic [14:0] v1_addr,v2_addr;
    logic [15:0] metadata;
    logic [23:0] row_base;
    logic [11:0] row_code;
    logic row_text,row_hflip,row_vflip;
    logic [3:0] row_y,sub_x,row_pal;
    logic [4:0] issue_count;
    logic signed [10:0] draw_x;
    logic [6:0] scan_index,back_count,front_count,candidate_index;
    logic [7:0] candidate_addr;
    logic [29:0] candidate_data,candidate_q;
    logic signed [10:0] object_x,object_y,object_dy;
    logic object_visible,candidate_we;
    logic row_busy,row_done,row_req,fetch_req,fetch_ready;
    logic [23:0] row_addr,fetch_addr;
    logic [63:0] fetched_pixels,fetch_rdata;
    logic [1:0] slot_valid;
    logic [9:0] slot_tag[0:1];

    typedef struct packed {
        logic [63:0] pixels;
        logic signed [10:0] x;
        logic [4:0] count;
        logic [3:0] subx,pal;
        logic [2:0] pass;
        logic flip;
        logic [9:0] y;
        logic [15:0] intensity;
        logic last;
    } row_job_t;
    row_job_t jobs[0:1],current_job;
    logic wr_pointer,rd_pointer;
    logic [1:0] job_count;
    logic push,pop,consumer_done;
    typedef enum logic [1:0] {C_IDLE,C_ISSUE,C_DRAIN} cstate_t;
    cstate_t cstate;
    logic [4:0] issue_i;
    logic drain_phase;
    assign push=state==ENQUEUE && job_count<2;
    assign pop=cstate==C_IDLE && job_count!=0;

    always_comb begin
        source_x=0;source_y=0;
        if(pass==BG0) begin
            source_x=flip_l ? 10'd255+{2'd0,sx0_l[7:0]}-{1'b0,render_x}
                           : {2'd0,sx0_l[7:0]}+{1'b0,render_x};
            source_y=flip_l ? 9'd255+sy0_l[8:0]-render_y[8:0]
                           : sy0_l[8:0]+render_y[8:0];
        end else if(pass==BG1) begin
            source_x={1'b0,(flip_l ? 9'd255+sx1_l[8:0]-render_x : sx1_l[8:0]+render_x)};
            source_y=flip_l ? 9'd255+sy1_l[8:0]-render_y[8:0] : sy1_l[8:0]+render_y[8:0];
        end else if(pass==TEXT) begin
            source_x={2'd0,(flip_l ? 8'd255-render_x[7:0] : render_x[7:0])};
            source_y={1'b0,(flip_l ? 8'd255-render_y[7:0] : render_y[7:0])};
        end
        tile_byte={1'b0,({sx0_l[15:8],9'd0}+
                       {6'd0,source_x[9:4],source_y[8:4]})};
        tile_byte=tile_byte<<1;
        object_x=$signed({3'd0,sprite_fields[1]})-(sprite_fields[2][0] ? 11'sd256 : 11'sd0);
        object_y=$signed({3'd0,sprite_fields[0]})-(sprite_fields[2][1] ? 11'sd0 : 11'sd256);
        if(flip_l) begin object_x=11'sd240-object_x;object_y=11'sd240-object_y;end
        object_dy=$signed({1'b0,render_y})-object_y;
        object_visible=!(sprite_fields[4]==0 && sprite_fields[0]==8'hf0) &&
                       object_dy>=0 && object_dy<16 && object_x<256 && object_x> -16;
        // Prefetch next table record while evaluating the synchronous current one.
        spr_addr=scan_active && !scan_wait ? {4'd0,(scan_index==95 ? scan_index : scan_index+7'd1)} : 11'd0;
        candidate_we=scan_active && !scan_wait && object_visible;
        candidate_data={object_dy[3:0],(sprite_fields[2][5]^flip_l),(sprite_fields[2][4]^flip_l),
                        sprite_fields[4][2:0],sprite_fields[2][7:6],sprite_fields[3],object_x};
        candidate_addr={sprite_fields[4][3],(sprite_fields[4][3] ? back_count : front_count)};
        fetch_req=row_req;fetch_addr=row_addr;
        case(state)
            V1: begin fetch_req=1;fetch_addr=ARGUS_VROM1+{9'd0,v1_addr[14:3],3'd0};end
            V2: begin fetch_req=1;fetch_addr=ARGUS_VROM2+{9'd0,v2_addr[14:3],3'd0};end
            default: ;
        endcase
        metadata=state==V1 ? 16'(fetch_rdata >> {v1_addr[2:0],3'd0})
                          : 16'(fetch_rdata >> {v2_addr[2:0],3'd0});
    end
    jtframe_dual_ram #(.DW(30),.AW(8)) candidates (
        .clk0(clk_sys),.addr0(candidate_addr),.data0(candidate_data),.we0(candidate_we),.q0(),
        .clk1(clk_sys),.addr1({(pass==OBJ_BACK),candidate_index}),.data1(30'd0),.we1(1'b0),.q1(candidate_q));
    logic cached_ready,cached_mem_req;
    logic [23:0] cached_mem_addr;
    logic [63:0] cached_rdata;
    logic prefetch_req,prefetch_ready;
    logic [23:0] prefetch_addr;
    assign text_read_addr=(SHARED_RAW_SPRITES!=0 && state==IDLE) ? prefetch_map_addr : map_addr;
    argus_video_bg_prefetch #(.ENABLE(SHARED_RAW_SPRITES),.VROM1_BASE(ARGUS_VROM1),
        .VROM2_BASE(ARGUS_VROM2),.TEXT_BASE(ARGUS_GFX4)) bg_prefetch_i (
        .clk_sys(clk_sys),.reset(reset),.core_idle(state==IDLE && game_id==0),
        .line_start(line_start),.line_finish(state==FINISH && consumer_done),
        .scroll_x(scrollx0_f),.flip(board_flip_f^user_flip_180),.rendered_y(render_y),
        .text_lo(tx_q),.text_hi(tx_hi_q),.map_addr(prefetch_map_addr),
        .req(prefetch_req),.addr(prefetch_addr),.ready(prefetch_ready),.rdata(cached_rdata));
    wire shared_sprite_req=EXTERNAL_GFX_CACHE==0 && SHARED_RAW_SPRITES!=0 && fetch_req &&
                           fetch_addr>=ARGUS_GFX1 && fetch_addr<ARGUS_GFX2;
    // The row helper already holds each address until its acknowledgement.
    // Direct requests can therefore remain asserted as the next half changes
    // address, using the actual shared store's continuous-request contract.
    // Complete any accepted cached transaction before selecting another client.
    assign rom_req=cached_mem_req || shared_sprite_req;
    assign rom_addr=cached_mem_req ? cached_mem_addr : fetch_addr;
    assign fetch_ready=shared_sprite_req ? (!cached_mem_req && rom_ready) : cached_ready;
    assign fetch_rdata=shared_sprite_req ? rom_rdata : cached_rdata;
    argus_video_rom_cache #(.AW(CACHE_AW),.EXTERNAL_GFX_CACHE(EXTERNAL_GFX_CACHE)) cache_i (
        .clk_sys(clk_sys),.reset(reset),.req(fetch_req&&!shared_sprite_req),.addr(fetch_addr),
        .ready(cached_ready),.rdata(cached_rdata),
        .prefetch_req(prefetch_req),.prefetch_addr(prefetch_addr),.prefetch_ready(prefetch_ready),
        .mem_req(cached_mem_req),.mem_addr(cached_mem_addr),
        .mem_ready((EXTERNAL_GFX_CACHE!=0 || cached_mem_req)&&rom_ready),.mem_rdata(rom_rdata));
    argus_gfx_row gfx_row (
        .clk_sys(clk_sys),.reset(reset),.start(state==ROW_START),
        .base(row_base),.code(row_code),.text8(row_text),.hflip(row_hflip),.vflip(row_vflip),.y(row_y),
        .busy(row_busy),.done(row_done),.pixels(fetched_pixels),
        .req(row_req),.addr(row_addr),.ready(fetch_ready),.rdata(fetch_rdata));

    // Producer can fetch the following row while the consumer blends this row.
    // Two drain clocks protect overlapping sprite destination read-after-write.
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            wr_pointer<=0;rd_pointer<=0;job_count<=0;
            current_job<='0;cstate<=C_IDLE;issue_i<=0;drain_phase<=0;consumer_done<=0;
        end else begin
            consumer_done<=0;
            case({push,pop})
                2'b10: job_count<=job_count+2'd1;
                2'b01: job_count<=job_count-2'd1;
                default: ;
            endcase
            if(push) begin
                // Packed row_job_t field order; avoids Quartus17's ambiguous
                // interpretation of named assignment-pattern field labels.
                jobs[wr_pointer]<={fetched_pixels,draw_x,issue_count,sub_x,
                    row_pal,pass,flip_l,render_y,intensity_l,
                    (pass==TEXT && render_x+{4'd0,issue_count}>=256)};
                wr_pointer<=~wr_pointer;
            end
            if(pop) begin
                current_job<=jobs[rd_pointer];rd_pointer<=~rd_pointer;issue_i<=0;cstate<=C_ISSUE;
            end
            if(cstate==C_ISSUE) begin
                if(issue_i+5'd2>=current_job.count) begin drain_phase<=0;cstate<=C_DRAIN;end
                else issue_i<=issue_i+5'd2;
            end
            if(cstate==C_DRAIN) begin
                if(drain_phase) begin
                    cstate<=C_IDLE;
                    if(current_job.last) consumer_done<=1;
                end else drain_phase<=1;
            end
        end
    end

    logic [3:0] issue_pen[0:1],source_pixel[0:1];
    logic signed [10:0] issue_x[0:1];
    logic [4:0] issue_number[0:1];
    logic [7:0] color_index[0:1];
    logic [1:0] issue_opaque,p1_en,p2_en,p1_grey;
    logic issue_sprite,p1_bg,p1_sprite;
    logic [8:0] p1_addr[0:1],p2_addr[0:1];
    logic [7:0] line_read_addr[0:1],line_write_addr[0:1];
    logic [23:0] p2_rgb[0:1],old_rgb[0:1],scan_q[0:1],line_write_data[0:1],scan_rgb;
    logic [1:0] line_we;
    logic scan_parity;
    logic [15:0] p1_intensity;
    always_comb begin
        issue_sprite=current_job.pass==OBJ_BACK || current_job.pass==OBJ_FRONT;
        for(integer lane=0;lane<2;lane=lane+1) begin
            issue_number[lane]=issue_i+5'(lane);
            source_pixel[lane]=issue_sprite ? issue_number[lane][3:0] :
                (current_job.flip ? current_job.subx-issue_number[lane][3:0] :
                                    current_job.subx+issue_number[lane][3:0]);
            issue_pen[lane]=current_job.pixels[{source_pixel[lane],2'b00} +: 4];
            issue_x[lane]=current_job.x+$signed({6'd0,issue_number[lane]});
            issue_opaque[lane]=cstate==C_ISSUE && issue_number[lane]<current_job.count &&
                issue_x[lane]>=0 && issue_x[lane]<256 && (current_job.pass==BG0 || issue_pen[lane]!=4'hf);
            color_index[lane]={current_job.pal,issue_pen[lane]};
            case(current_job.pass)
                BG0:pal_lo_addr[lane]=12'h400+{4'd0,color_index[lane]};
                BG1:pal_lo_addr[lane]=12'h500+{4'd0,color_index[lane]};
                TEXT:pal_lo_addr[lane]=12'h700+{4'd0,color_index[lane]};
                default:pal_lo_addr[lane]={5'd0,color_index[lane][6:0]};
            endcase
            pal_hi_addr[lane]=pal_lo_addr[lane]+(issue_sprite ? 12'h080 : 12'h400);
        end
        // Consecutive native pixels occupy different parity RAM banks. An odd
        // starting X swaps lanes; unclipped addresses remain harmless when WE=0.
        for(integer bank=0;bank<2;bank=bank+1) begin
            line_read_addr[bank]={current_job.y[0],issue_x[issue_x[0][0]==1'(bank) ? 0 : 1][7:1]};
            line_write_addr[bank]=p2_addr[p2_addr[0][0]==1'(bank) ? 0 : 1][8:1];
            line_write_data[bank]=p2_rgb[p2_addr[0][0]==1'(bank) ? 0 : 1];
            line_we[bank]=p2_en[p2_addr[0][0]==1'(bank) ? 0 : 1];
        end
        scan_rgb=scan_q[scan_parity];
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            p1_en<=0;p2_en<=0;p1_bg<=0;p1_sprite<=0;p1_grey<=0;
            p1_intensity<=0;scan_parity<=0;
            for(integer lane=0;lane<2;lane=lane+1) begin p1_addr[lane]<=0;p2_addr[lane]<=0;p2_rgb[lane]<=0;end
        end else begin
            p1_en<=issue_opaque;p1_bg<=current_job.pass==BG0;
            p1_sprite<=issue_sprite;p1_intensity<=current_job.intensity;
            p2_en<=p1_en;scan_parity<=hpos[0];
            for(integer lane=0;lane<2;lane=lane+1) begin
                p1_addr[lane]<={current_job.y[0],issue_x[lane][7:0]};
                p1_grey[lane]<=grey_flags[color_index[lane]];
                p2_addr[lane]<=p1_addr[lane];
                if(p1_sprite) p2_rgb[lane]<=sprite_blend(old_rgb[p1_addr[lane][0]],
                    palette_rgb(pal_lo_q[lane],pal_hi_q[lane]),pal_hi_q[lane][3:0]);
                else if(p1_bg) p2_rgb[lane]<=background_effect(palette_rgb(pal_lo_q[lane],pal_hi_q[lane]),
                                                             p1_grey[lane],p1_intensity);
                else p2_rgb[lane]<=palette_rgb(pal_lo_q[lane],pal_hi_q[lane]);
            end
        end
    end
    genvar rgb_bank;
    generate for(rgb_bank=0;rgb_bank<2;rgb_bank=rgb_bank+1) begin: g_rgb_lines
        jtframe_dual_ram #(.DW(24),.AW(8)) scan_ram (
            .clk0(clk_sys),.addr0({vpos[0],hpos[7:1]}),.data0(24'd0),.we0(1'b0),.q0(scan_q[rgb_bank]),
            .clk1(clk_sys),.addr1(line_write_addr[rgb_bank]),.data1(line_write_data[rgb_bank]),.we1(line_we[rgb_bank]),.q1());
        jtframe_dual_ram #(.DW(24),.AW(8)) blend_ram (
            .clk0(clk_sys),.addr0(line_write_addr[rgb_bank]),.data0(line_write_data[rgb_bank]),.we0(line_we[rgb_bank]),.q0(),
            .clk1(clk_sys),.addr1(line_read_addr[rgb_bank]),.data1(24'd0),.we1(1'b0),.q1(old_rgb[rgb_bank]));
    end endgenerate
    logic sample_ce,sample_active;
    always_ff @(posedge clk_sys) begin
        if(reset) begin sample_ce<=0;sample_active<=0;pixel_valid<=0;r<=0;g<=0;b<=0;end
        else begin
            sample_ce<=ce_pixel;
            sample_active<=game_id==0 && active && !hblank && !vblank && hpos<256 &&
                           slot_valid[vpos[0]] && slot_tag[vpos[0]]==vpos;
            pixel_valid<=sample_ce&&sample_active;
            if(sample_ce) {r,g,b}<=sample_active ? scan_rgb : 24'd0;
        end
    end

    // Independent full-record scan overlaps the first immutable BG fetches.
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            scan_active<=0;scan_wait<=0;scan_index<=0;back_count<=0;front_count<=0;
        end else if(line_start && state==IDLE && game_id==0 && vpos<255) begin
            scan_active<=1;scan_wait<=1;scan_index<=0;back_count<=0;front_count<=0;
        end else if(scan_active) begin
            if(scan_wait) scan_wait<=0;
            else begin
                if(object_visible) begin
                    if(sprite_fields[4][3]) back_count<=back_count+7'd1;
                    else front_count<=front_count+7'd1;
                end
                if(scan_index==95) scan_active<=0;
                else scan_index<=scan_index+7'd1;
            end
        end
    end
    always_ff @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE;pass<=BG0;render_y<=0;render_x<=0;
            sx0_l<=0;sy0_l<=0;sx1_l<=0;sy1_l<=0;intensity_l<=0;flip_l<=0;bg1_enable<=0;
            map_addr<=0;v1_addr<=0;v2_addr<=0;row_base<=0;row_code<=0;
            row_text<=0;row_hflip<=0;row_vflip<=0;row_y<=0;sub_x<=0;row_pal<=0;issue_count<=0;draw_x<=0;
            candidate_index<=0;
            slot_valid<=0;slot_tag[0]<=0;slot_tag[1]<=0;deadline_miss<=0;
        end else begin
            if(line_start && state!=IDLE) deadline_miss<=1;
            if(ce_pixel && active && !hblank && !vblank &&
               (game_id!=0 || !slot_valid[vpos[0]] || slot_tag[vpos[0]]!=vpos)) deadline_miss<=1;
            case(state)
                IDLE: if(line_start && game_id==0 && vpos<255) begin
                    render_y<=vpos+10'd1;render_x<=0;pass<=BG0;
                    slot_valid[~vpos[0]]<=0;slot_tag[~vpos[0]]<=vpos+10'd1;
                    sx0_l<={scrollx0_f[15:8]+{7'd0,board_flip_f},scrollx0_f[7:0]};
                    sy0_l<=scrolly0_f+(board_flip_f ? 16'd256 : 16'd0);
                    sx1_l<=scrollx1_f+(board_flip_f ? 16'd256 : 16'd0);
                    sy1_l<=scrolly1_f+(board_flip_f ? 16'd256 : 16'd0);
                    intensity_l<=intensity_f;flip_l<=board_flip_f^user_flip_180;bg1_enable<=bg_status[0];
                    candidate_index<=0;state<=TILE_BEGIN;
                end
                TILE_BEGIN: begin
                    row_text<=pass==TEXT;draw_x<=$signed({2'd0,render_x});
                    row_y<=pass==TEXT ? {1'b0,source_y[2:0]} : source_y[3:0];
                    sub_x<=pass==TEXT ? {1'b0,source_x[2:0]} : source_x[3:0];
                    issue_count<=pass==TEXT ? (flip_l ? {2'd0,source_x[2:0]}+5'd1 : 5'd8-{2'd0,source_x[2:0]})
                                             : (flip_l ? {1'b0,source_x[3:0]}+5'd1 : 5'd16-{1'b0,source_x[3:0]});
                    if(pass==BG0) begin v1_addr<={tile_byte[17:4],1'b0};row_base<=ARGUS_GFX2;state<=V1;end
                    else if(pass==BG1 && !bg1_enable) begin
                        pass<=OBJ_FRONT;candidate_index<=0;state<=CAND_WAIT;
                    end else begin
                        map_addr<=pass==TEXT ? {source_x[7:3],source_y[7:3],1'b0}
                                                      : {source_x[8:4],source_y[8:4],1'b0};
                        row_base<=pass==TEXT ? ARGUS_GFX4 : ARGUS_GFX3;state<=MEM_WAIT;
                    end
                end
                MEM_WAIT: state<=MEM_META;
                MEM_META: begin
                    if(pass==TEXT) begin row_code<={2'd0,tx_hi_q[7:6],tx_q};row_pal<=tx_hi_q[3:0];
                        row_hflip<=tx_hi_q[4];row_vflip<=tx_hi_q[5];end
                    else begin row_code<={4'd0,bg_q};row_pal<=bg_hi_q[3:0];
                        row_hflip<=bg_hi_q[4];row_vflip<=bg_hi_q[5];end
                    state<=ROW_START;
                end
                V1: if(fetch_ready) begin
                    v2_addr<={metadata[10:8],metadata[7:0],tile_byte[3:0]};state<=V2;
                end
                V2: if(fetch_ready) begin
                    row_code<={2'd0,metadata[15:14],metadata[7:0]};row_pal<=metadata[11:8];
                    row_hflip<=metadata[12];row_vflip<=metadata[13];state<=ROW_START;
                end
                CAND_WAIT: begin
                    if(scan_active) state<=CAND_WAIT;
                    else if(candidate_index==(pass==OBJ_BACK ? back_count : front_count)) begin
                        pass<=pass==OBJ_BACK ? BG1 : TEXT;render_x<=0;state<=TILE_BEGIN;
                    end else state<=CAND_META;
                end
                CAND_META: begin
                    draw_x<=$signed(candidate_q[10:0]);row_code<={2'd0,candidate_q[20:11]};
                    row_pal<={1'b0,candidate_q[23:21]};row_hflip<=candidate_q[24];row_vflip<=candidate_q[25];
                    row_y<=candidate_q[29:26];row_text<=0;issue_count<=16;row_base<=ARGUS_GFX1;state<=ROW_START;
                end
                ROW_START: state<=ROW_WAIT;
                ROW_WAIT: if(row_done) state<=ENQUEUE;
                ENQUEUE: if(push) state<=NEXT;
                NEXT: begin
                    if(pass==OBJ_BACK || pass==OBJ_FRONT) begin candidate_index<=candidate_index+7'd1;state<=CAND_WAIT;end
                    else if(render_x+{4'd0,issue_count}>=256) begin
                        if(pass==TEXT) state<=FINISH;
                        else begin pass<=pass==BG0 ? OBJ_BACK : OBJ_FRONT;candidate_index<=0;state<=CAND_WAIT;end
                    end else begin render_x<=render_x+{4'd0,issue_count};state<=TILE_BEGIN;end
                end
                FINISH: if(consumer_done) begin slot_valid[render_y[0]]<=1;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
    // No raster or PLL. The provisional parent profile supplies4000 clocks/line.
endmodule

// 128x8 simple dual-port snapshot RAM (MLAB, registered read) shared by the
// Argus-family renderers for per-frame sprite-list copies.
module argus_snap_ram (
    input  logic       clk, we,
    input  logic [6:0] waddr,
    input  logic [7:0] wdata,
    input  logic [6:0] raddr,
    output logic [7:0] q
);
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] mem [0:127];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        q <= mem[raddr];
    end
endmodule
