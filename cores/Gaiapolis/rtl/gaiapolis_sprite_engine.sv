// SPDX-License-Identifier: GPL-3.0-or-later
// Gaiapolis sprite geometry/control adapter. Register and coordinate reference:
// MAME0.289 k053246_k053247_k055673.h/.cpp and konamigx_v.cpp.
// RNG decode/callback and banked line-buffer structure reuse the staged
// JTCORES/Violent Storm donor. Donor snapshots remain unchanged.
// Seven descriptor words are retained for all256 entries, including equal z.
// Two bounded bitonic index lists retain GX priority/z/offset order for solid and
// separate shadow passes. OPSET[4] reverses z; OPSET[5] selects shadow priority;
// OPSET[6] selects512 wrap. OBJSET1[5] bits0/1 flip,bit3 half-width,
// bit4 enables vblank DMA,bit5 selects partial versus full mode1 shadow.
// GX accepts shadow only when both z<=previous_z and priority<previous_priority.
// SDSEL supplies8 priorities, otherwise3 presets: at most8 operations per pixel.
// The packet preserves ALL accepted shadow operations in descending global key
// order. Gai's callback has no sprite alpha flag, so the final accepted opaque
// solid erases every earlier solid color; retained shadows remain independently
// interleaved with all tile/ROZ operations by their complete32bit GX keys.
// Slots are contiguous from0 (furthest) to7 (nearest); valid/mode/key publish
// alongside pixel one clk48 edge after pxl_cen. Coefficient/RGB math is external.
// Registers remain stable for a frame's DMA/ordering snapshot, as in MAME's
// frame mixer. Mid-frame ordering-control changes need separate admission.
// clk is the selected game clk48 (48MHz), cen every6 clocks for8MHz pixels.
// solid_order/shadow_order reproduce GX's complete32bit surviving-object key;
// blank-line DMA delay is2HS, leaving38*512*6=116736clocks from40blank lines.
module gaiapolis_sprite_engine #(
    parameter integer HACTIVE_FIRST=106, VACTIVE_FIRST=271,
    parameter integer BITMAP_LEFT=40, BITMAP_TOP=16,
    parameter integer BITMAP_WIDTH=376, BITMAP_HEIGHT=224,
    parameter integer SPRITE_DX=-61, SPRITE_DY=-22,
    parameter integer PREFETCH_LINES=1
)(
    input wire monster,
    output logic [1:0] sprite_mix,
    output wire [18:0] sprite5_addr,
    output wire sprite5_cs,
    input wire [31:0] sprite5_data,
    input wire sprite5_ok,
    input logic clk,rst,pxl_cen,pxl2_cen,hs,lvbl,
    input logic [8:0] hpos,vpos,
    input logic [63:0] objset1,
    input logic [127:0] objset2,
    input logic [23:0] shadow_priorities,
    output logic [10:0] dma_word_addr,
    input logic [15:0] dma_data,
    output logic dma_busy,dma_irq_enabled,ln_done,line_overrun,
    output logic [22:2] rom_addr,
    output logic rom_cs,
    input logic [31:0] rom_data,
    input logic rom_ok,
    output logic [9:0] pixel,
    output logic [4:0] prio,
    output logic [1:0] shadow,
    output logic [2:0] shadow_prio,
    output logic [7:0] shadow_priority_full,
    output logic [31:0] solid_order,shadow_order,
    output logic [7:0] shadow_ops_valid,
    output logic [15:0] shadow_ops_mode,
    output logic [255:0] shadow_ops_order,
    output logic shadow_ops_overflow,
    output logic [8:0] buf_addr,
    output logic [18:0] buf_data,
    output logic buf_we
);
    wire [7:0] cfg=objset1[47:40];
    wire [15:0] opset=objset2[111:96];
    wire [15:0] xoffset={objset1[7:0],objset1[15:8]};
    wire [15:0] yoffset={objset1[23:16],objset1[31:24]};
    logic hs_q;
    wire hs_start=hs && !hs_q;
    logic [1:0] lvbl_history;
    logic [7:0] dma_cfg;
    logic [15:0] dma_opset;
    logic [23:0] dma_priorities;
    logic [8:0] dma_first_word;
    typedef enum logic [3:0] {D_IDLE,D_COPY,D_LOAD,D_READ,D_COMPARE,
                             D_NEXT,D_DONE} dma_state_t;
    dma_state_t dma_state;
    logic dma_wait;
    wire dma_store=!rst && dma_state==D_COPY && pxl2_cen && dma_wait;
    logic [7:0] sort_n,sort_pos,sort_distance;
    logic [8:0] sort_extent;
    logic sort_shadow;
    logic [31:0] carry,sort_read;
    logic ordered_ready;

    function automatic [7:0] preset_priority(input [1:0] mode,input [23:0] values);
        case(mode)
            2'd1:preset_priority=values[7:0];
            2'd2:preset_priority=values[15:8];
            2'd3:preset_priority=values[23:16];
            default:preset_priority=0;
        endcase
    endfunction
    always_comb begin
        dma_busy=dma_state!=D_IDLE;
        dma_irq_enabled=cfg[4];
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            hs_q<=0;lvbl_history<=0;dma_state<=D_IDLE;dma_word_addr<=0;
            dma_wait<=0;dma_cfg<=0;dma_opset<=0;dma_priorities<=0;
            sort_n<=0;sort_pos<=0;sort_distance<=1;sort_extent<=2;
            sort_shadow<=0;dma_first_word<=0;
            ordered_ready<=0;
        end else begin
            hs_q<=hs;
            if(hs_start) lvbl_history<={lvbl_history[0],lvbl};
            case(dma_state)
                D_IDLE:if(hs_start && lvbl_history==2'b10 && cfg[4]) begin
                    dma_state<=D_COPY;dma_word_addr<=0;dma_wait<=0;
                    dma_cfg<=cfg;dma_opset<=opset;dma_priorities<=shadow_priorities;
                    ordered_ready<=0;
                end
                D_COPY:if(pxl2_cen) begin
                    if(!dma_wait) dma_wait<=1;
                    else begin
                        dma_wait<=0;
                        if(dma_word_addr[2:0]==0) dma_first_word<={dma_data[15],dma_data[7:0]};
                        if(&dma_word_addr) begin
                            sort_n<=0;sort_shadow<=0;dma_state<=D_LOAD;
                        end else dma_word_addr<=dma_word_addr+1'b1;
                    end
                end
                // A bounded256-entry bitonic network, evaluated one compare
                // pair at a time. Two synchronous read/write ports are used;
                // both lists finish within the actual clk48 blanking budget.
                D_LOAD:begin
                    if(&sort_n) begin
                        sort_n<=0;
                        if(!sort_shadow) sort_shadow<=1;
                        else begin
                            sort_shadow<=0;sort_pos<=0;sort_extent<=9'd2;
                            sort_distance<=8'd1;dma_state<=D_READ;
                        end
                    end else sort_n<=sort_n+1'b1;
                end
                D_READ:begin
                    if((sort_pos & sort_distance)==0) begin
                        dma_state<=D_COMPARE;
                    end else dma_state<=D_NEXT;
                end
                D_COMPARE:begin
                    dma_state<=D_NEXT;
                end
                D_NEXT:begin
                    if(&sort_pos) begin
                        sort_pos<=0;
                        if(!sort_shadow) begin sort_shadow<=1;dma_state<=D_READ;end
                        else begin
                            sort_shadow<=0;
                            if(sort_distance>1) begin
                                sort_distance<=sort_distance>>1;dma_state<=D_READ;
                            end else if(sort_extent!=9'd256) begin
                                sort_extent<=sort_extent<<1;
                                sort_distance<=8'(sort_extent);dma_state<=D_READ;
                            end else dma_state<=D_DONE;
                        end
                    end else begin sort_pos<=sort_pos+1'b1;dma_state<=D_READ;end
                end
                D_DONE:begin ordered_ready<=1;dma_state<=D_IDLE;end
                default:dma_state<=D_IDLE;
            endcase
        end
    end

    // Elaboration-time constant ROMs, not variable hardware dividers.
    // Keep the step table at a power-of-two depth. Its boundary and only
    // 24-bit value bypass the RAM with exact constants, preserving latency.
    (* ramstyle = "M10K" *) logic [23:0] reciprocal [0:1023];
    (* ramstyle = "M10K" *) logic [22:0] source_step [0:2047];
    initial begin
        reciprocal[0]=24'h800000;
        for(integer r=1;r<1024;r=r+1)
            reciprocal[r]=24'((4194304+(r>>1))/r);
        source_step[0]=0;
        for(integer s=1;s<2048;s=s+1) source_step[s]=23'(8388608/s);
    end
    typedef enum logic [3:0] {S_IDLE,S_LIST,S_DESC,S_ZOOM,S_EDGE,S_MEASURE,S_STEP,S_GEOM,S_ROM0,S_ROM_GAP,
                             S_ROM1,S_LOOK,S_STAGE,S_TILE_NEXT,S_OBJ_NEXT,S_ABORT} scan_state_t;
    scan_state_t scan_state;
    logic [7:0] scan_n,scan_index;
    logic scan_shadow;
    logic [7:0] line_cfg;
    logic [15:0] line_opset,line_xoffset,line_yoffset;
    logic [23:0] line_priorities;
    logic [15:0] descriptor [0:6];
    logic [23:0] key_q [0:1];
    logic [31:0] ordered_a [0:1],ordered_b [0:1];
    wire [8:0] ordered_scan_word=ordered_a[scan_shadow][8:0];
    assign carry=ordered_a[sort_shadow];
    assign sort_read=ordered_b[sort_shadow];
    // MAME dadandrn selects konamigx_mixer_primode(1), which zeroes zcode in
    // the sort key itself (konamigx_v.cpp), not only in the drawn z.
    wire [7:0] key_z=monster ? 8'd0 : dma_first_word[7:0]^{8{dma_opset[4]}};
    wire [7:0] key_sp={dma_data[7:5],5'd0};
    wire [7:0] key_shp=dma_opset[5] ? key_sp :
        preset_priority(dma_data[11:10],dma_priorities);
    wire [23:0] key_data [0:1];
    assign key_data[0]=dma_first_word[8] ? {key_sp,key_z,7'd0,1'b1} : 24'd0;
    assign key_data[1]=dma_first_word[8] && dma_data[11:10]!=0 ?
        {key_shp,key_z,7'd0,1'b1} : 24'd0;
    // Prefetch the next list/key while the existing state transition executes.
    // This retains S_LIST/S_DESC/D_COMPARE latency and the blanking budget.
    wire [7:0] key_read_addr=dma_state==D_LOAD ? sort_n+8'd1 : sort_n;
    wire [7:0] list_read_addr=hs_start ? 8'd0 :
        scan_state==S_OBJ_NEXT ? scan_n+8'd1 :
        scan_state==S_LIST && !ordered_scan_word[8] && !scan_shadow ? 8'd0 : scan_n;
    wire sort_pair=dma_state==D_READ && (sort_pos & sort_distance)==0;
    wire sort_swap=dma_state==D_COMPARE &&
        (((sort_extent & {1'b0,sort_pos})==0) ? carry<sort_read : carry>sort_read);
    genvar d,k;
    generate
    for(d=0;d<7;d=d+1) begin : descriptor_word
        gaiapolis_bram #(.DW(16),.AW(8)) u_ram(
            .clk(clk),.we(dma_store && dma_word_addr[2:0]==3'(d)),
            .re(!rst && !hs_start && scan_state==S_DESC),
            .write_addr(dma_word_addr[10:3]),.read_addr(scan_index),
            .write_data(dma_data),.read_data(descriptor[d]));
    end
    for(k=0;k<2;k=k+1) begin : sorted_list
        wire load=!rst && dma_state==D_LOAD && sort_shadow==1'(k);
        wire swap=!rst && sort_swap && sort_shadow==1'(k);
        wire sort_re=!rst && sort_pair && sort_shadow==1'(k);
        wire [7:0] read_a=dma_state==D_READ ? sort_pos : list_read_addr;
        gaiapolis_bram #(.DW(24),.AW(8)) u_keys(
            .clk(clk),.we(dma_store && dma_word_addr[2:0]==6),.re(1'b1),
            .write_addr(dma_word_addr[10:3]),.read_addr(key_read_addr),
            .write_data(key_data[k]),.read_data(key_q[k]));
        gaiapolis_bram_tdp #(.DW(32),.AW(8)) u_order(
            .clk(clk),.we_a(load || swap),.we_b(swap),
            .re_a(sort_re || (!rst && !dma_busy)),.re_b(sort_re),
            .addr_a(load ? sort_n : swap ? sort_pos : read_a),
            .addr_b(sort_pos ^ sort_distance),
            .data_a(load ? {key_q[k],sort_n} : sort_read),.data_b(carry),
            .q_a(ordered_a[k]),.q_b(ordered_b[k]));
    end
    endgenerate
    logic [2:0] x_tile;
    logic signed [31:0] bitmap_y;
    logic [15:0] line_generation,bank_generation [0:1];
    logic draw_bank;
    (* dont_retime *) logic [23:0] zoom_x_q,zoom_y_q,step_x_q,step_y_q;
    (* dont_retime *) logic [11:0] geometry_width_q,geometry_height_q;
    logic [11:0] geometry_height;
    always_ff @(posedge clk) begin
        if(scan_state==S_ZOOM) begin
            zoom_y_q<=reciprocal[descriptor[4][9:0]];
            zoom_x_q<=reciprocal[descriptor[0][14] ? descriptor[4][9:0] : descriptor[5][9:0]];
        end
        // Dimension arithmetic and the source-step RAM have separate clocks.
        if(scan_state==S_MEASURE) begin
            geometry_width_q<=geometry_width;geometry_height_q<=geometry_height;
        end
        if(scan_state==S_STEP) begin
            step_y_q<=geometry_height_q==12'd2048 ? 24'd4096 : geometry_height_q==12'd1 ? 24'h800000 : {1'b0,source_step[geometry_height_q[10:0]]};
            step_x_q<=geometry_width_q==12'd2048 ? 24'd4096 : geometry_width_q==12'd1 ? 24'h800000 : {1'b0,source_step[geometry_width_q[10:0]]};
        end
    end
    logic geometry_valid,geometry_row_valid;
    logic [15:0] geometry_code;
    logic [3:0] geometry_y;
    logic geometry_flipx;
    logic [3:0] geometry_tiles;
    logic [11:0] geometry_width,geometry_skip;
    logic geometry_valid_next,geometry_row_valid_next,geometry_past_right_next,geometry_flipx_next,geometry_fy_next;
    logic [15:0] geometry_code_next;
    logic [11:0] geometry_skip_next,geometry_rel_y_next,geometry_rel_y_q;
    logic [8:0] geometry_left_next,geometry_count_next;
    logic geometry_fy_q;
    wire [35:0] geometry_y_product=geometry_rel_y_q*step_y_q;
    wire unused_geometry_y_product=^{geometry_y_product[35:23],geometry_y_product[18:0]};
    always_comb geometry_y=geometry_y_product[22:19]^{4{geometry_fy_q}};
    // S_STEP already precedes S_GEOM. Register clipping and row selection
    // here so descriptor arithmetic does not cascade into source-phase products.
    // The existing step-ROM edge and rendering state cadence are preserved.
    always_ff @(posedge clk) if(scan_state==S_STEP) begin
        geometry_valid<=geometry_valid_next; geometry_row_valid<=geometry_row_valid_next;
        geometry_code<=geometry_code_next; geometry_flipx<=geometry_flipx_next;
        geometry_skip<=geometry_skip_next; geometry_left<=geometry_left_next;
        geometry_count<=geometry_count_next; geometry_rel_y_q<=geometry_rel_y_next;
        geometry_fy_q<=geometry_fy_next;
    end
    logic [8:0] geometry_left,geometry_count;
    wire [23:0] geometry_step=step_x_q;
    logic [22:0] x_phase;
    logic [23:0] x_step;
    logic [8:0] remaining;
    logic [31:0] row_word0,row_word1;
    logic row_flipx;
    // Three-stage tile pipeline. The fetcher (scan_state) completes a whole
    // row (both ROM words, plane-5 bits) from the row cache or ROM, then
    // parks it in a stage slot; the emitter draws from its own copy. The
    // fetcher can therefore run one tile ahead of the stage slot, so ROM
    // latency overlaps drawing. Every staged/emitted field is held, and the
    // emission order is unchanged.
    logic emit_active,emit_shadow;
    logic [7:0] emit_index;
    logic [15:0] emit_plane5;
    logic [31:0] fetch_w0,fetch_w1;
    logic fetch_from_cache;
    logic stage_valid,stage_flipx,stage_shadow,stage_full_shadow;
    logic [31:0] stage_w0,stage_w1;
    logic [15:0] stage_plane5;
    logic [7:0] stage_index,stage_z,stage_shadow_priority;
    logic [2:0] stage_priority;
    logic [1:0] stage_shadow_mode;
    logic [9:0] stage_color;
    logic [8:0] stage_left,stage_count;
    logic [22:0] stage_phase;
    logic [23:0] stage_step;
    // Row cache: zoomed sprites repeat one source row on consecutive lines.
    // Entry {valid,tag,plane5,word1,word0} for one {code,y} row; ROM is
    // read-only, so entries are cleared only after reset.
    localparam integer CACHE_BITS=1+12+16+64;
    logic [CACHE_BITS-1:0] cache_q,cache_wdata;
    logic cache_clearing,cache_we;
    logic [7:0] cache_clear_addr,cache_waddr;
    wire [7:0] cache_index={geometry_code[3:0],geometry_y};
    wire cache_hit=!cache_clearing && cache_q[CACHE_BITS-1] &&
        cache_q[CACHE_BITS-2 -: 12]==geometry_code[15:4];
    logic [7:0] current_z,current_priority,current_shadow_priority;
    logic [1:0] current_shadow_mode;
    logic current_full_shadow;
    logic [9:0] current_color;
    logic [15:0] row_plane5;
    logic plane5_pending;
    logic [18:0] plane5_address;
    logic plane5_row_half;
    wire extra_pen_bit=monster && emit_plane5[{source_x[3],rom_bit}];
    assign sprite5_addr=plane5_address;
    assign sprite5_cs=monster && plane5_pending;
    logic [3:0] source_x,pen;
    logic [2:0] rom_bit;
    logic [31:0] source_word;
    logic [18:0] solid_key;
    logic [23:0] shadow_key;

    function automatic [4:0] x_code_offset(input [2:0] coordinate);
        x_code_offset={coordinate[2],1'b0,coordinate[1],1'b0,coordinate[0]};
    endfunction
    function automatic [5:0] y_code_offset(input [2:0] coordinate);
        y_code_offset={coordinate[2],1'b0,coordinate[1],1'b0,coordinate[0],1'b0};
    endfunction
    // Tile edge relative to the descriptor centre, in 1/4096 pixel units.
    // MAME truncates each piece's centring offset ((scale*size)>>13) on its
    // own, so abutting pieces of different sizes can leave a 1-pixel gap
    // (Gaiapolis stage-intro eagle wing). Subtract the exact half size before
    // rounding instead, and round a piece's outer edges outward so every pixel
    // its true extent touches is covered. Interior edges round to nearest.
    // At unit zoom every edge is an exact multiple of 16, so nothing moves.
    function automatic signed [16:0] piece_edge(input [23:0] scale, input [3:0] tile,
                                                 input [3:0] count, input [26:0] half);
        logic signed [28:0] pos;
        pos=29'(28'(scale)*28'(tile))-29'(half)+
            (tile==4'd0 ? 29'd0 : tile==count ? 29'd4095 : 29'd2048);
        piece_edge=17'(pos>>>12);
    endfunction
    (* dont_retime *) logic signed [10:0] origin_x_q,origin_y_q;
    logic origin_flipx_q,origin_flipy_q,origin_mirrorx_q,origin_mirrory_q;
    logic signed [10:0] origin_x,origin_y;
    logic origin_flipx,origin_flipy,origin_mirrorx,origin_mirrory;
    always_comb begin : prepare_origin
        integer signed ox,oy,wrapsize,xlim,ylim;
        ox=32'({22'd0,descriptor[3][9:0]});oy=32'({22'd0,descriptor[2][9:0]});
        origin_flipx=descriptor[0][12];origin_flipy=descriptor[0][13];
        origin_mirrorx=descriptor[6][14];origin_mirrory=descriptor[6][15];
        if(origin_mirrorx) origin_flipx=0;
        if(line_cfg[3]) begin ox=(ox>>1)+1;if(line_cfg[0]) ox=ox+512;end
        if(line_cfg[0]) begin ox=-ox;if(!origin_mirrorx) origin_flipx=!origin_flipx;end
        if(line_cfg[1]) begin oy=-oy;if(!origin_mirrory) origin_flipy=!origin_flipy;end
        wrapsize=line_opset[6] ? 512 : 1024;
        xlim=line_opset[6] ? 448 : 640;ylim=line_opset[6] ? 384 : 512;
        ox=(ox+(monster ? -42 : SPRITE_DX)-32'($signed(line_xoffset)))&(wrapsize-1);
        oy=(-oy+SPRITE_DY-32'($signed(line_yoffset)))&(wrapsize-1);
        if(ox>=xlim) ox=ox-wrapsize;if(oy>=ylim) oy=oy-wrapsize;
        origin_x=11'(ox);origin_y=11'(oy);
    end
    // These coordinates do not depend on reciprocal-ROM outputs. Prepare
    // them alongside that existing S_ZOOM read, before per-tile clipping.
    always_ff @(posedge clk) if(scan_state==S_ZOOM) begin
        origin_x_q<=origin_x;origin_y_q<=origin_y;
        origin_flipx_q<=origin_flipx;origin_flipy_q<=origin_flipy;
        origin_mirrorx_q<=origin_mirrorx;origin_mirrory_q<=origin_mirrory;
    end
    // Piece edges (shift + multiply-add chain from descriptor size/zoom) are
    // registered in S_EDGE, one state before S_MEASURE/S_STEP consume them, so
    // the descriptor RAM output no longer cascades into the clipping compare.
    logic signed [16:0] edge_y_n [0:8];
    logic signed [16:0] edge_x_n [0:1];
    (* dont_retime *) logic signed [16:0] edge_y_q [0:8];
    (* dont_retime *) logic signed [16:0] edge_x_q [0:1];
    always_comb begin : prepare_edges
        logic [23:0] esy,esx;
        logic [26:0] ehy,ehx;
        logic [3:0] eh,ew;
        eh=4'(1<<descriptor[0][11:10]);ew=4'(1<<descriptor[0][9:8]);
        esy=zoom_y_q;esx=line_cfg[3] ? zoom_x_q>>1 : zoom_x_q;
        ehy=27'(({3'd0,esy}<<descriptor[0][11:10])>>1);
        ehx=27'(({3'd0,esx}<<descriptor[0][9:8])>>1);
        for(integer y=0;y<9;y=y+1) edge_y_n[y]=piece_edge(esy,4'(y),eh,ehy);
        edge_x_n[0]=piece_edge(esx,{1'b0,x_tile},ew,ehx);
        edge_x_n[1]=piece_edge(esx,x_tile+4'd1,ew,ehx);
    end
    always_ff @(posedge clk) if(scan_state==S_EDGE) begin
        for(integer y=0;y<9;y=y+1) edge_y_q[y]<=edge_y_n[y];
        edge_x_q[0]<=edge_x_n[0];edge_x_q[1]<=edge_x_n[1];
    end
    always_comb begin : geometry
        integer signed ox,oy,width,height;
        integer signed sx,sy,zw,zh,left,right,xa,ya;
        logic [11:0] rel_y;
        logic [2:0] xc,yc;
        logic flipx,flipy,mirrorx,mirrory,fx,fy;
        width=1<<descriptor[0][9:8];height=1<<descriptor[0][11:10];
        ox=32'($signed(origin_x_q));oy=32'($signed(origin_y_q));
        flipx=origin_flipx_q;flipy=origin_flipy_q;
        mirrorx=origin_mirrorx_q;mirrory=origin_mirrory_q;
        xa=32'({29'd0,descriptor[1][4],descriptor[1][2],descriptor[1][0]});
        ya=32'({29'd0,descriptor[1][5],descriptor[1][3],descriptor[1][1]});
        geometry_valid_next=0;geometry_row_valid_next=0;geometry_past_right_next=0;geometry_code_next=0;geometry_rel_y_next=0;geometry_fy_next=0;geometry_flipx_next=0;
        geometry_tiles=4'(width);geometry_width=0;geometry_skip_next=0;
        geometry_left_next=0;geometry_count_next=0;geometry_height=0;
        sx=0;sy=0;zw=0;zh=0;left=0;right=0;xc=0;yc=0;rel_y=0;
        fx=0;fy=0;
        for(integer y=0;y<8;y=y+1) begin
            sy=oy+32'(edge_y_q[y]);
            zh=32'(edge_y_q[y+1])-32'(edge_y_q[y]);
            if(y<height && bitmap_y>=sy && bitmap_y<sy+zh &&
               bitmap_y>=(monster ? 17 : BITMAP_TOP) && bitmap_y<(monster ? 17 : BITMAP_TOP)+BITMAP_HEIGHT) begin
                geometry_row_valid_next=1;
                if(mirrory) fy=(!flipy)^((y<<1)>=height);else fy=flipy;
                yc=3'(fy ? height-1-y+ya : y+ya);
                rel_y=12'(bitmap_y-sy);
                geometry_height=12'(zh);
                geometry_rel_y_next=12'(rel_y);geometry_fy_next=fy;
                if(mirrorx) fx=(!flipx)^((32'(x_tile)<<1)<width);else fx=flipx;
                xc=3'(fx ? width-1-32'(x_tile)+xa : 32'(x_tile)+xa);
                geometry_code_next={descriptor[1][15:6],6'd0}+
                    {11'd0,x_code_offset(3'(xc))}+{10'd0,y_code_offset(3'(yc))};
                geometry_flipx_next=fx;
                sx=ox+32'(edge_x_q[0]);
                zw=32'(edge_x_q[1])-32'(edge_x_q[0]);
                left=sx<(monster ? 24 : BITMAP_LEFT) ? (monster ? 24 : BITMAP_LEFT) : sx;
                right=sx+zw>(monster ? 24 : BITMAP_LEFT)+(monster ? 288 : BITMAP_WIDTH) ? (monster ? 24 : BITMAP_LEFT)+(monster ? 288 : BITMAP_WIDTH) : sx+zw;
                geometry_valid_next=32'(x_tile)<width && zw>0 && right>left;
                // Later tile positions cannot move back into the viewport.
                geometry_past_right_next=sx >= (monster ? 24+288 : BITMAP_LEFT+BITMAP_WIDTH);
                geometry_width=12'(zw);geometry_skip_next=12'(left-sx);
                geometry_left_next=9'(left);geometry_count_next=9'(right-left);
            end
        end
    end
    always_comb begin
        source_x=x_phase[22:19]^{4{row_flipx}};
        rom_bit=3'd7-source_x[2:0];
        source_word=source_x[3] ? row_word1 : row_word0;
        pen={source_word[{2'b11,rom_bit}],source_word[{2'b10,rom_bit}],
             source_word[{2'b01,rom_bit}],source_word[{2'b00,rom_bit}]};
        buf_we=emit_active;
        buf_data={emit_shadow ? current_shadow_mode : 2'd0,
                  current_priority[7:5],current_color,pen};
        solid_key={current_z,2'd0,current_shadow_mode!=0,emit_index};
        shadow_key={current_z,7'd0,current_full_shadow,~emit_index};
    end
    // Pen zero is transparent, including in shadow passes. Monster pixels are
    // transparent only when the matching plane-5 bits are also clear. A row
    // that is transparent throughout is never staged; a transparent second
    // half ends the tile once drawing reaches it.
    wire emit_skip_half=x_phase[22] &&
        (row_flipx ? row_word0 : row_word1)==32'd0 &&
        (!monster || (row_flipx ? emit_plane5[7:0] : emit_plane5[15:8])==8'd0);
    wire emit_last=emit_active && (emit_skip_half || remaining==1);
    wire emit_take=stage_valid && (!emit_active || emit_last);
    // A cache hit can be staged directly from S_LOOK.
    wire fetch_cached=scan_state==S_LOOK || fetch_from_cache;
    wire [31:0] fetched_w0=fetch_cached ? cache_q[31:0] : fetch_w0;
    wire [31:0] fetched_w1=fetch_cached ? cache_q[63:32] : fetch_w1;
    wire [15:0] fetched_plane5=fetch_cached ? cache_q[79:64] : row_plane5;
    wire fetched_clear=fetched_w0==32'd0 && fetched_w1==32'd0 &&
        (!monster || fetched_plane5==16'd0);
    // The stage slot accepts a row once the slot is free or drains this cycle.
    wire stage_go=(scan_state==S_STAGE || (scan_state==S_LOOK && cache_hit)) &&
        !plane5_pending && (!stage_valid || emit_take);
    wire last_tile=x_tile+4'd1>=geometry_tiles;
    always_comb ln_done=scan_state==S_IDLE && !stage_valid && !emit_active;
    always_comb begin
        cache_we=cache_clearing || (!rst && !hs_start && stage_go && !fetch_cached);
        cache_waddr=cache_clearing ? cache_clear_addr : cache_index;
        cache_wdata=cache_clearing ? {CACHE_BITS{1'b0}} :
            {1'b1,geometry_code[15:4],row_plane5,fetch_w1,fetch_w0};
    end
    always_ff @(posedge clk) begin
        if(rst) begin cache_clearing<=1;cache_clear_addr<=0; end
        else if(cache_clearing) begin
            cache_clear_addr<=cache_clear_addr+1'b1;
            if(&cache_clear_addr) cache_clearing<=0;
        end
    end
    gaiapolis_bram #(.DW(CACHE_BITS),.AW(8)) u_row_cache(
        .clk(clk),.we(cache_we),.re(!rst && scan_state==S_GEOM),
        .write_addr(cache_waddr),.read_addr(cache_index),
        .write_data(cache_wdata),.read_data(cache_q));
    always_ff @(posedge clk) begin
        if(rst) begin
            plane5_pending<=0;plane5_address<=0;plane5_row_half<=0;row_plane5<=0;scan_state<=S_IDLE;
            emit_active<=0;emit_shadow<=0;emit_index<=0;emit_plane5<=0;
            fetch_w0<=0;fetch_w1<=0;fetch_from_cache<=0;
            stage_valid<=0;stage_flipx<=0;stage_shadow<=0;stage_full_shadow<=0;
            stage_w0<=0;stage_w1<=0;stage_plane5<=0;stage_index<=0;stage_z<=0;
            stage_shadow_priority<=0;stage_priority<=0;stage_shadow_mode<=0;stage_color<=0;
            stage_left<=0;stage_count<=0;stage_phase<=0;stage_step<=0;
            scan_n<=0;scan_index<=0;scan_shadow<=0;
            line_cfg<=0;line_opset<=0;line_xoffset<=0;line_yoffset<=0;line_priorities<=0;
            bitmap_y<=0;line_generation<=0;bank_generation[0]<=0;bank_generation[1]<=0;
            draw_bank<=0;x_tile<=0;x_phase<=0;x_step<=0;remaining<=0;
            row_word0<=0;row_word1<=0;row_flipx<=0;
            rom_addr<=0;rom_cs<=0;buf_addr<=0;line_overrun<=0;
            current_z<=0;current_priority<=0;current_shadow_priority<=0;
            current_shadow_mode<=0;current_full_shadow<=0;current_color<=0;
        end else if(hs_start) begin
            stage_valid<=0;emit_active<=0;
            if(!ln_done) line_overrun<=1;
            draw_bank<=~draw_bank;
            line_generation<=line_generation+1'b1;
            bank_generation[~draw_bank]<=line_generation+1'b1;
            bitmap_y<=(monster ? 17 : BITMAP_TOP)+32'({23'd0,vpos})-(monster ? 272 : VACTIVE_FIRST)+PREFETCH_LINES;
            line_cfg<=cfg;line_opset<=opset;line_xoffset<=xoffset;line_yoffset<=yoffset;
            line_priorities<=shadow_priorities;
            scan_n<=0;scan_shadow<=0;x_tile<=0;
            if(plane5_pending && sprite5_ok) plane5_pending<=0;
            if(rom_ok) rom_cs<=0;
            if((rom_cs && !rom_ok) || (plane5_pending && !sprite5_ok)) scan_state<=S_ABORT;
            else begin
                rom_cs<=0;
                scan_state<=ordered_ready && !dma_busy &&
                    32'({23'd0,vpos})>=(monster ? 272 : VACTIVE_FIRST)-PREFETCH_LINES &&
                    32'({23'd0,vpos})<(monster ? 272 : VACTIVE_FIRST)-PREFETCH_LINES+BITMAP_HEIGHT ?
                    S_LIST : S_IDLE;
            end
        end else begin
            if(plane5_pending && sprite5_ok) begin
                row_plane5<=plane5_row_half ? sprite5_data[31:16] : sprite5_data[15:0];
                plane5_pending<=0;
            end
            // Emitter: one pixel per clock from its held copy.
            if(emit_active) begin
                x_phase<=23'(x_phase+x_step);buf_addr<=buf_addr+1'b1;
                remaining<=remaining-1'b1;
                if(emit_last) emit_active<=0;
            end
            if(emit_take) begin
                row_word0<=stage_w0;row_word1<=stage_w1;row_flipx<=stage_flipx;
                emit_plane5<=stage_plane5;emit_shadow<=stage_shadow;emit_index<=stage_index;
                current_z<=stage_z;current_priority<={stage_priority,5'd0};
                current_shadow_mode<=stage_shadow_mode;
                current_shadow_priority<=stage_shadow_priority;
                current_full_shadow<=stage_full_shadow;current_color<=stage_color;
                buf_addr<=stage_left;remaining<=stage_count;
                x_step<=stage_step;x_phase<=stage_phase;
                emit_active<=1;
            end
            if(emit_take && !stage_go) stage_valid<=0;
            if(stage_go) begin
                // Descriptor, line and geometry registers are unchanged since
                // S_GEOM because the fetcher waits in S_STAGE.
                stage_valid<=!fetched_clear;
                stage_w0<=fetched_w0;stage_w1<=fetched_w1;stage_plane5<=fetched_plane5;
                stage_flipx<=geometry_flipx;stage_shadow<=scan_shadow;stage_index<=scan_index;
                stage_z<=monster ? 8'd0 : descriptor[0][7:0]^{8{line_opset[4]}};
                stage_priority<=descriptor[6][7:5];
                stage_shadow_mode<=descriptor[6][11:10];
                stage_shadow_priority<=line_opset[5] ? {descriptor[6][7:5],5'd0} :
                    preset_priority(descriptor[6][11:10],line_priorities);
                stage_full_shadow<=descriptor[6][11:10]==1 && !line_cfg[5];
                stage_color<=descriptor[6][9:0];
                stage_left<=geometry_left;stage_count<=geometry_count;
                stage_step<=geometry_step;
                stage_phase<=23'(geometry_skip*geometry_step);
            end
            case(scan_state)
                S_IDLE:begin end
                S_LIST:begin
                    // The record keeps priority/z/index ordering. Bit8 marks a
                    // valid list member, so even the all-zero valid GX key
                    // sorts above every invalid tail entry. No extra RAM port.
                    if(!ordered_scan_word[8]) begin
                        if(!scan_shadow) begin scan_shadow<=1;scan_n<=0;end
                        else scan_state<=S_IDLE;
                    end else begin
                        scan_index<=ordered_scan_word[7:0];scan_state<=S_DESC;
                    end
                end
                S_DESC:begin
                    scan_state<=S_ZOOM;x_tile<=0;
                end
                S_ZOOM:scan_state<=S_EDGE;
                S_EDGE:scan_state<=S_MEASURE;
                S_MEASURE:begin
                    // Reject off-line objects before the source-step RAM read.
                    // The descriptor and zoom/origin registers are already ready.
                    if(!geometry_row_valid_next || geometry_past_right_next) scan_state<=S_OBJ_NEXT;
                    else scan_state<=S_STEP;
                end
                S_STEP:scan_state<=S_GEOM;
                S_GEOM:begin
                    if(!descriptor[0][15] ||
                       (scan_shadow && descriptor[6][11:10]==0) ||
                       (!scan_shadow && descriptor[6][11:10]==1 && !line_cfg[5]))
                        scan_state<=S_OBJ_NEXT;
                    else if(!geometry_row_valid) scan_state<=S_OBJ_NEXT;
                    else if(!geometry_valid) scan_state<=S_TILE_NEXT;
                    else scan_state<=S_LOOK;
                end
                S_LOOK:begin
                    if(cache_hit) begin
                        fetch_from_cache<=1;
                        if(!stage_go) scan_state<=S_STAGE;
                        else if(last_tile) scan_state<=S_OBJ_NEXT;
                        else begin x_tile<=x_tile+1'b1;scan_state<=S_EDGE;end
                    end else if(!plane5_pending && !rom_cs && !rom_ok) begin
                        // Monster's plane-5 word uses its own port and is
                        // requested in parallel with the 4bpp row.
                        fetch_from_cache<=0;
                        rom_addr<={geometry_code,geometry_y,geometry_flipx};
                        rom_cs<=1;
                        if(monster) begin
                            plane5_address<={geometry_code,geometry_y[3:1]};
                            plane5_row_half<=geometry_y[0];
                            plane5_pending<=1;
                        end
                        scan_state<=S_ROM0;
                    end
                end
                S_ROM0:if(rom_ok) begin
                    if(rom_addr[2]) fetch_w1<=rom_data;
                    else fetch_w0<=rom_data;
                    rom_cs<=0;scan_state<=S_ROM_GAP;
                end
                S_ROM_GAP:if(!rom_ok) begin
                    rom_addr<={rom_addr[22:3],!rom_addr[2]};rom_cs<=1;scan_state<=S_ROM1;
                end
                S_ROM1:if(rom_ok) begin
                    if(rom_addr[2]) fetch_w1<=rom_data;
                    else fetch_w0<=rom_data;
                    rom_cs<=0;scan_state<=S_STAGE;
                end
                S_STAGE:if(stage_go) begin
                    if(last_tile) scan_state<=S_OBJ_NEXT;
                    else begin x_tile<=x_tile+1'b1;scan_state<=S_EDGE;end
                end
                S_TILE_NEXT:begin
                    if(last_tile) scan_state<=S_OBJ_NEXT;
                    else begin x_tile<=x_tile+1'b1;scan_state<=S_EDGE;end
                end
                S_OBJ_NEXT:begin
                    if(scan_n==255) begin
                        if(!scan_shadow) begin scan_shadow<=1;scan_n<=0;scan_state<=S_LIST;end
                        else scan_state<=S_IDLE;
                    end else begin scan_n<=scan_n+1'b1;scan_state<=S_LIST;end
                end
                S_ABORT:if((!rom_cs || rom_ok) && (!plane5_pending || sprite5_ok)) begin
                    rom_cs<=0;scan_state<=ordered_ready && !dma_busy &&
                        bitmap_y>=(monster ? 17 : BITMAP_TOP) && bitmap_y<(monster ? 17 : BITMAP_TOP)+BITMAP_HEIGHT ?
                        S_LIST : S_IDLE;
                end
                default:scan_state<=S_IDLE;
            endcase
        end
    end

    // The two banks share read address between the rendering and display
    // roles. Read/compare/write is pipelined, retaining BRAM inference.
    logic [47:0] solid_old [0:1];
    logic [49:0] shadow_old [0:1];
    localparam integer SHADOW_OP_COUNT=8,SHADOW_OP_BITS=34;
    localparam integer SHADOW_OP_DATA=SHADOW_OP_COUNT*SHADOW_OP_BITS;
    localparam integer SHADOW_PACKET_BITS=16+4+SHADOW_OP_DATA;
    logic [SHADOW_PACKET_BITS-1:0] shadow_ops_old [0:1];
    logic [1:0] shadow_ops_overflow_bank;
    assign shadow_ops_overflow=|shadow_ops_overflow_bank;
    logic clearing;
    logic [8:0] clear_addr;
    logic commit_valid,commit_bank,commit_shadow;
    logic [8:0] commit_addr;
    logic [15:0] commit_generation;
    logic [18:0] commit_solid_key;
    wire [1:0] unused_commit_solid_padding=commit_solid_key[10:9];
    logic [23:0] commit_shadow_key;
    logic [12:0] commit_pixel;
    logic [1:0] commit_sprite_mix;
    logic [1:0] commit_mode;
    logic [7:0] commit_priority;
    logic [31:0] commit_shadow_order;
    logic read_pending,read_bank,read_in_range;
    logic [15:0] read_generation;
    logic signed [31:0] display_x;
    logic [8:0] display_addr;
    logic display_in_range;
    always_comb begin
        // The pxl_cen edge that ends CCU period hpos fetches the pixel shown
        // in period hpos+1. LHBL opens at hpos 106 (Gaiapolis) / 200 (Monster
        // Maulers), where tile column 0 = bitmap x40/x24, so fetch x+1 ahead.
        display_x=(monster ? 24 : BITMAP_LEFT)+32'({23'd0,hpos})+1-(monster ? 200 : HACTIVE_FIRST);
        display_addr=9'(display_x);
        display_in_range=display_x>=0 && display_x<512;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            clearing<=1;clear_addr<=0;commit_valid<=0;commit_bank<=0;
            commit_shadow<=0;commit_addr<=0;commit_generation<=0;
            commit_solid_key<=0;commit_shadow_key<=0;commit_pixel<=0;commit_sprite_mix<=0;sprite_mix<=0;
            commit_mode<=0;commit_priority<=0;commit_shadow_order<=0;
            read_pending<=0;read_bank<=0;read_in_range<=0;read_generation<=0;
            pixel<=0;prio<=0;shadow<=0;shadow_prio<=0;shadow_priority_full<=0;
            solid_order<=0;shadow_order<=0;
            shadow_ops_valid<=0;shadow_ops_mode<=0;shadow_ops_order<=0;
        end else begin
            if(clearing) begin
                clear_addr<=clear_addr+1'b1;
                if(&clear_addr) clearing<=0;
            end
            // Empty pixels can survive indefinitely in a tagged line bank.
            // Sweep during the same blank-only boundary as descriptor DMA so
            // a 16-bit generation rollover cannot resurrect an old frame.
            // Both banks finish in 512 clocks, before active-line prefetch.
            if(hs_start && lvbl_history==2'b10) begin
                clearing<=1;clear_addr<=0;
            end
            commit_valid<=buf_we && (pen!=0 || extra_pen_bit) && !hs_start && !clearing &&
                (emit_shadow ? (current_full_shadow || (pen==15 && (!monster || extra_pen_bit))) :
                 !(current_shadow_mode!=0 && (pen==15 && (!monster || extra_pen_bit))));
            commit_bank<=draw_bank;commit_shadow<=emit_shadow;
            commit_sprite_mix<=monster ? current_color[9:8] : 2'd0;
            commit_addr<=buf_addr;commit_generation<=line_generation;
            commit_solid_key<=solid_key;commit_shadow_key<=shadow_key;
            commit_pixel<=monster ? {current_priority[7:5],current_color[4:0],extra_pen_bit,pen} : {current_priority[7:5],current_color[9],current_color[4:0],pen};
            commit_mode<=current_shadow_mode;commit_priority<=current_shadow_priority;
            commit_shadow_order<={current_shadow_priority,current_z,emit_index,
                (current_full_shadow ? 4'd5 : 4'd4),
                2'd0,2'(current_shadow_mode-1'b1)};
            read_pending<=pxl_cen && !clearing;
            if(pxl_cen) begin
                read_bank<=~draw_bank;read_generation<=bank_generation[~draw_bank];
                read_in_range<=display_in_range;
            end
            if(read_pending) begin
                shadow_ops_valid<=0;shadow_ops_mode<=0;shadow_ops_order<=0;
                if(read_in_range &&
                   shadow_ops_old[read_bank][SHADOW_PACKET_BITS-1 -: 16]==read_generation)
                    for(integer slot=0;slot<SHADOW_OP_COUNT;slot=slot+1) begin
                        if(4'(slot)<shadow_ops_old[read_bank][SHADOW_OP_DATA +: 4]) begin
                            shadow_ops_valid[slot]<=1;
                            shadow_ops_mode[slot*2 +: 2]<=
                                shadow_ops_old[read_bank][slot*SHADOW_OP_BITS +: 2];
                            shadow_ops_order[slot*32 +: 32]<=
                                shadow_ops_old[read_bank][slot*SHADOW_OP_BITS+2 +: 32];
                        end
                    end
                if(read_in_range && solid_old[read_bank][47:32]==read_generation) begin
                    pixel<=solid_old[read_bank][9:0];sprite_mix<=solid_old[read_bank][23:22];
                    prio<={2'd0,solid_old[read_bank][12:10]};
                    solid_order<={solid_old[read_bank][12:10],5'd0,
                        solid_old[read_bank][31:24],solid_old[read_bank][20:13],
                        3'd0,solid_old[read_bank][21],4'd0};
                end else begin pixel<=0;sprite_mix<=0;prio<=0;solid_order<=0;end
                if(read_in_range && shadow_old[read_bank][49:34]==read_generation) begin
                    shadow<=shadow_old[read_bank][9:8];
                    shadow_priority_full<=shadow_old[read_bank][7:0];
                    shadow_prio<=shadow_old[read_bank][7:5];
                    shadow_order<={shadow_old[read_bank][7:0],
                        shadow_old[read_bank][33:26],~shadow_old[read_bank][17:10],
                        (shadow_old[read_bank][18] ? 4'd5 : 4'd4),
                        2'd0,2'(shadow_old[read_bank][9:8]-1'b1)};
                end else begin shadow<=0;shadow_priority_full<=0;shadow_prio<=0;shadow_order<=0;end
            end
        end
    end
    genvar b;
    generate for(b=0;b<2;b=b+1) begin:buffer_bank
        wire [8:0] read_addr=draw_bank==b ? buf_addr : display_addr;
        wire [8:0] write_addr=clearing ? clear_addr : commit_addr;
        logic solid_we,shadow_we,packet_we,overflow_set;
        logic [47:0] solid_data;
        logic [49:0] shadow_data;
        logic [SHADOW_PACKET_BITS-1:0] packet_data,packet;
        logic [3:0] used;
        // Mux the clear/commit address before the RAM. Each physical bank has
        // exactly one write access and one registered, scalar read output.
        always_comb begin
            solid_we=clearing;shadow_we=clearing;packet_we=clearing;
            solid_data=0;shadow_data=0;packet_data=0;overflow_set=0;
            packet=0;used=0;
            if(!clearing && commit_valid && commit_bank==b && !hs_start) begin
                if(!commit_shadow) begin
                    if(solid_old[b][47:32]!=commit_generation ||
                       solid_old[b][3:0]==0 ||
                       solid_old[b][31:24]>=commit_solid_key[18:11]) begin
                        solid_we=1;
                        solid_data={commit_generation,commit_solid_key[18:11],commit_sprite_mix,commit_solid_key[8:0],commit_pixel};
                    end
                end else begin
                    // MAME initial shadow priority is255; even the first
                    // priority255 candidate must be rejected.
                    if(commit_priority!=8'd255 &&
                       (shadow_old[b][49:34]!=commit_generation ||
                        shadow_old[b][9:8]==0 ||
                        (shadow_old[b][33:26]>=commit_shadow_key[23:16] &&
                          shadow_old[b][7:0]>commit_priority))) begin
                        shadow_we=1;
                        shadow_data={commit_generation,commit_shadow_key,commit_mode,commit_priority};
                        packet=(shadow_ops_old[b][SHADOW_PACKET_BITS-1 -: 16]==commit_generation) ?
                                shadow_ops_old[b] : {SHADOW_PACKET_BITS{1'b0}};
                        used=packet[SHADOW_OP_DATA +: 4];
                        if(used<4'(SHADOW_OP_COUNT)) begin
                            packet[32'(used)*SHADOW_OP_BITS +: SHADOW_OP_BITS]=
                                {commit_shadow_order,commit_mode};
                            packet[SHADOW_OP_DATA +: 4]=used+1'b1;
                            packet[SHADOW_PACKET_BITS-1 -: 16]=commit_generation;
                            packet_we=1;packet_data=packet;
                        end else overflow_set=1;
                    end
                end
            end
        end
        always_ff @(posedge clk) begin
            if(rst) shadow_ops_overflow_bank[b]<=0;
            if(overflow_set) shadow_ops_overflow_bank[b]<=1;
        end
        gaiapolis_bram #(.DW(48)) u_solid(
            .clk(clk),.we(solid_we),.re(1'b1),.write_addr(write_addr),.write_data(solid_data),
            .read_addr(read_addr),.read_data(solid_old[b]));
        gaiapolis_bram #(.DW(50)) u_shadow(
            .clk(clk),.we(shadow_we),.re(1'b1),.write_addr(write_addr),.write_data(shadow_data),
            .read_addr(read_addr),.read_data(shadow_old[b]));
        gaiapolis_bram #(.DW(SHADOW_PACKET_BITS)) u_packet(
            .clk(clk),.we(packet_we),.re(1'b1),.write_addr(write_addr),.write_data(packet_data),
            .read_addr(read_addr),.read_data(shadow_ops_old[b]));
    end endgenerate
    // Unused packed fields have no Gai rendering consumer in MAME's path;
    // raw CPU ROM addressing and byte-masked storage remain in the wrapper.
    wire unused_io=&{1'b0,objset1[63:48],objset1[39:32],objset2[127:112],objset2[95:0],
                      dma_opset[15:6],dma_opset[3:0],line_cfg[7:6],line_cfg[4],line_cfg[2],
                      line_opset[15:7],line_opset[3:0],current_priority[4:0]};
    wire unused_geometry_width=&{1'b0,geometry_width};
    wire unused_dma_cfg=&{1'b0,dma_cfg};
    wire unused_order_metadata=&{1'b0,solid_key[10:0],shadow_key[15:0]};
endmodule
