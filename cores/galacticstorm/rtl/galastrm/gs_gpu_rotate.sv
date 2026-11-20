// SPDX-License-Identifier: BSD-3-Clause
// Real source producer -> indexed external surface -> cached TC0610 renderer.
// Source and affine actors overlap across two banks; display lifetime is external.
// No RGB framebuffer. Four 512x512 indexed pages occupy physical 18..20 MiB.
module gs_gpu_rotate #(parameter CURRENT_TEXT=0)(
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
    input wire query,bank,
    output wire query_ready,
    input wire [383:0] controls,
    input wire [127:0] scn_controls,
    input wire current_restart,
    input wire signed [15:0] rzx,rzy,
    // affine_pcb selects the PCB-fitted TC0610 mapper (all of r0-r5,r7).
    input wire affine_pcb,
    input wire [111:0] affine_regs,
    output reg done,done_bank,
    // presentable[b]: both rotation and overlay for the latest query drained.
    output reg [1:0] presentable,
    output wire supported,overflow,
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
    input wire display_req,display_bank,
    // display_active: scanout still owes pixels of its current frame.
    // display_restart: scanout started a new frame (pair cache reset).
    input wire display_active,display_restart,
    input wire [15:0] display_addr,
    input wire [14:0] display_ordinal,
    output wire display_ack,
    output wire [63:0] display_data,
    output wire surface_req,
    output reg surface_write,
    output wire surface_line,
    input wire line_valid,
    input wire [2:0] line_word,
    input wire [63:0] line_data,
    output reg [24:0] surface_addr,
    output reg [63:0] surface_wdata,
    output reg [7:0] surface_bytes,
    input wire surface_ack,
    input wire [63:0] surface_rdata
);
    localparam S_IDLE=0,S_START=1,S_RUN=2,S_DRAIN=3;
    localparam R_IDLE=0,R_START=1,R_RUN=2,R_DRAIN=3;
    reg [1:0] source_state,rotate_state,slot_busy,slot_ready;
    // A rotated page keeps its last complete image until its next rotation
    // starts writing. A late query no longer withdraws the frame on screen,
    // and that rotation waits while the page is still being scanned.
    reg [1:0] rotated_complete;
    reg [1:0] render_complete,overlay_complete;
    reg keep_valid,keep_bank;
    // Overlay data and masks are double buffered with the rotated image.
    reg source_bank,rotate_bank;
    reg [1:0] source_direct;
    // Source writes retire in raster order. Once a write in tile-row N has
    // reached DDR, every sampled texel in rows below N is stable. Rotation
    // can consume those completed rows while source rendering continues.
    reg [1:0] source_stream_valid;
    reg [5:0] source_stream_row[0:1];
    // This exact register tuple maps visible coordinates to themselves in
    // both ordinary and full-matrix PCB modes. Compose directly into the
    // final indexed page instead of writing, reading and copying a source page.
    wire identity_transform=affine_pcb && affine_regs[31:0]==32'h0430ff10 &&
        affine_regs[63:32]==32'h00001000 &&
        (affine_regs[111:96]==0 || affine_regs[95:64]==32'h10000000);
    wire source_output_held=(keep_valid && keep_bank==source_bank) ||
        (display_active && display_bank==source_bank);
    wire source_start_allowed=!source_direct[source_bank] || !source_output_held;
    reg [14:0] committed_words[0:1];
    reg [383:0] saved_controls;
    reg source_window_enable,pcb_window_pending;
    wire pcb_window_busy,pcb_window_enable;
    wire [8:0] pcb_window_x0,pcb_window_x1,pcb_window_y0,pcb_window_y1;
    reg [35:0] source_window;
    reg [1:0] source_shift_x,source_shift_y;
    reg [2:0] source_phase_x,source_phase_y;
    wire rows_busy,rows_enable,row_used,row_ready;
    wire [8:0] sample_y;
    gs_tc0610_sample_rows sampled_rows(
        .clk(clk),.reset(reset),.start(query && query_ready),.pcb_mode(affine_pcb),.regs(affine_regs),
        .busy(rows_busy),.enabled(rows_enable),.lookup_y(sample_y),.used(row_used),.lookup_ready(row_ready));
    // Axis-aligned even integer X zoom reads one fixed parity lattice.
    // A parity superset keeps every requested texel, including 24-bit wrap.
    // Arbitrary rotation/shear and ordinary rotation use every texel.
    function automatic [1:0] grid_shift(input [15:0] coefficient);
        case(coefficient)
        16'h2000,16'he000,16'h4000,16'hc000,16'h6000,16'ha000,16'h8000: grid_shift=1;
        default: grid_shift=0;
        endcase
    endfunction
    wire grid_axis=affine_pcb && affine_regs[111:96]!=0 && affine_regs[63:48]==0 && affine_regs[79:64]==0;
    function automatic [9:0] align_grid(input [8:0] low,input [2:0] phase,input [1:0] shift);
        reg [2:0] mask,delta;
        begin
            mask=(4'b0001<<shift)-1'b1;delta=(phase-low[2:0])&mask;
            align_grid={1'b0,low}+{7'b0,delta};
        end
    endfunction
    // The PCB mapper never requests texels outside x40..445/y0..399,
    // including a wrapped accumulator. Keep that safe clip on wrap fallback.
    wire [8:0] pcb_xlo=pcb_window_enable ? pcb_window_x0 : 9'd40;
    wire [8:0] pcb_xhi=pcb_window_enable ? pcb_window_x1 : 9'd445;
    wire [8:0] pcb_ylo=pcb_window_enable ? pcb_window_y0 : 9'd0;
    wire [8:0] pcb_yhi=pcb_window_enable ? pcb_window_y1 : 9'd399;
    wire [9:0] grid_xlo=align_grid(pcb_xlo,source_phase_x,source_shift_x);
    wire [9:0] grid_ylo=align_grid(pcb_ylo,source_phase_y,source_shift_y);
    reg signed [15:0] rotation_x[0:1],rotation_y[0:1];
    // {r7,r5,r4,r1,r0}; r2/r3 stay in rotation_x/y (one register per bit for the held-bank SDC).
    reg [79:0] rotation_regs[0:1];
    reg [1:0] rotation_pcb;
    wire [24:0] source_base=source_bank ? 25'h1280000 : 25'h1200000;
    wire [24:0] rotated_base=rotate_bank ? 25'h1380000 : 25'h1300000;
    wire [24:0] affine_source_base=rotate_bank ? 25'h1280000 : 25'h1200000;
    // Pack source pages as 8x8 indexed tiles. Each TC cache fill then spans
    // two contiguous eight-word DDR bursts rather than eight separate rows.
    function automatic [15:0] tile_word(input [15:0] linear_word);
        tile_word={linear_word[15:10],linear_word[6:1],linear_word[9:7],linear_word[0]};
    endfunction
    wire source_supported;
    // TC0610 samples texel C+R(d)*|rz|/4096 for screen offset d (MAME
    // galastrm.cpp:422-579: unit zcs/zsn, zx*|rz|=256*4096). The visible
    // 320x232 rectangle therefore reads within these half extents. The margin
    // covers loop-count rounding, (lx-1)/(2zx-1) scaling and pixel centres.
    wire [16:0] abs_rzx=rzx[15] ? -{rzx[15],rzx} : {1'b0,rzx};
    wire [16:0] abs_rzy=rzy[15] ? -{rzy[15],rzy} : {1'b0,rzy};
    wire [24:0] reach_x_num=({8'b0,abs_rzx}<<7)+({8'b0,abs_rzx}<<5)+({8'b0,abs_rzy}<<6)+({8'b0,abs_rzy}<<5)+({8'b0,abs_rzy}<<4)+({8'b0,abs_rzy}<<2);
    wire [24:0] reach_y_num=({8'b0,abs_rzy}<<7)+({8'b0,abs_rzy}<<5)+({8'b0,abs_rzx}<<6)+({8'b0,abs_rzx}<<5)+({8'b0,abs_rzx}<<4)+({8'b0,abs_rzx}<<2);
    wire [12:0] half_x=reach_x_num[24:12],half_y=reach_y_num[24:12];
    wire [12:0] zoom_margin=13'd6+{8'b0,abs_rzx[16:12]}+{8'b0,abs_rzy[16:12]};
    wire [12:0] reach_x=half_x+{5'b0,half_x[12:5]}+zoom_margin;
    wire [12:0] reach_y=half_y+{5'b0,half_y[12:5]}+zoom_margin;
    wire [8:0] window_x0=reach_x>=256 ? 9'd0 : 9'd256-reach_x[8:0];
    wire [8:0] window_x1=reach_x>=256 ? 9'd511 : 9'd255+reach_x[8:0];
    wire [8:0] window_y0=reach_y>=200 ? 9'd0 : 9'd200-reach_y[8:0];
    wire [8:0] window_y1=reach_y>=200 ? 9'd399 : 9'd199+reach_y[8:0];
    // The PCB-fitted mapper samples a different area; gs_tc0610_pcb_window
    // bounds it from all of r0-r5 before the source pass starts.
    gs_tc0610_pcb_window pcb_window(
        .clk(clk),.reset(reset),.start(query && query_ready && affine_pcb),.regs(affine_regs),
        .busy(pcb_window_busy),.enable(pcb_window_enable),
        .x0(pcb_window_x0),.x1(pcb_window_x1),.y0(pcb_window_y0),.y1(pcb_window_y1));
    wire window_enable=abs_rzx!=0 || abs_rzy!=0;
    assign supported=source_supported && text_supported;
    wire source_ready,source_done,source_valid,source_pixel_ready,source_idle,source_cut_ready;
    wire [8:0] source_x,source_y;
    wire [15:0] source_index;
    wire source_write_req,source_write_ack;
    wire [24:0] source_write_addr;
    wire [63:0] source_write_data;
    wire [7:0] source_write_bytes;
    wire affine_ready,affine_done,affine_valid,affine_pixel_ready,affine_idle;
    wire [8:0] affine_x,affine_y;
    wire [15:0] affine_index;
    wire affine_read_req,affine_read_ack,affine_write_req,affine_write_ack;
    wire [15:0] affine_read_addr;
    wire [24:0] affine_write_addr;
    wire [63:0] affine_write_data;
    wire [7:0] affine_write_bytes;
    wire frame_sealed,direct_query,direct_query_ready,direct_query_done,direct_descriptor_valid,direct_descriptor_ready;
    wire [5:0] direct_query_band;
    wire [63:0] direct_descriptor;
    wire direct_rom_req,direct_rom_ack,direct_rom_rvalid;
    wire [19:0] direct_rom_addr;
    wire [63:0] direct_rom_data;
    wire [1:0] text_mem_req,text_mem_ack;
    wire [31:0] text_mem_addr,text_mem_rdata;
    wire text_ready,text_done,text_valid,text_pixel_ready,text_idle,text_supported;
    wire [8:0] text_x,text_y;
    wire [15:0] text_index;
    wire text_write_req,text_write_ack;
    wire [24:0] text_write_addr;
    wire [63:0] text_write_data;
    wire [7:0] text_write_bytes;
    reg [1:0] text_state;
    reg [127:0] saved_scn;
    reg [14:0] text_committed[0:1];
    // One bit per four-pixel word, grouped in the same eight-word lines as
    // scanout. Every completed group replaces its mask, even if transparent.
    // The committed ordinal prevents reading an old mask after a native cut.
    (* ramstyle="M10K, no_rw_check" *) reg [7:0] current_masks[0:4639];
    reg [7:0] current_mask,mask_read,display_mask;
    wire text_transparent=text_write_data==0;
    reg display_text_phase;
    reg display_pair_valid;
    reg [13:0] display_pair_tag;
    // Single-read/single-write shallow caches; a validity mask replaces bulk clear.
    (* ramstyle="MLAB, no_rw_check" *) reg [63:0] rotated_display_line[0:7];
    (* ramstyle="MLAB, no_rw_check" *) reg [63:0] current_display_line[0:7];
    reg [7:0] current_display_valid;
    // Expose one full-word RAM read; all lane tests share this port.
    wire [63:0] current_display_word=current_display_line[display_addr[2:0]];
    reg [63:0] merged_display_data;
    integer lane;
    generate if(CURRENT_TEXT) begin: current_text
        gs_current_layers renderer(
            .clk(clk),.reset(reset),.query(text_state==S_START && !source_output_held),.query_ready(text_ready),.frame_sealed(frame_sealed),
            .band_query(direct_query),.query_band(direct_query_band),.band_query_ready(direct_query_ready),.band_query_done(direct_query_done),
            .descriptor_valid(direct_descriptor_valid),.descriptor_ready(direct_descriptor_ready),.descriptor(direct_descriptor),
            .rom_req(direct_rom_req),.rom_addr(direct_rom_addr),.rom_ack(direct_rom_ack),.rom_rvalid(direct_rom_rvalid),.rom_rdata(direct_rom_data),
            .scp_controls(saved_controls),.scn_controls(saved_scn),.done(text_done),.supported(text_supported),
            .mem_req(text_mem_req),.mem_addr(text_mem_addr),.mem_ack(text_mem_ack),.mem_rdata(text_mem_rdata),
            .pixel_valid(text_valid),.pixel_ready(text_pixel_ready),.pixel_x(text_x),.pixel_y(text_y),.pixel_index(text_index));
        gs_indexed_writer writer(
            .clk(clk),.reset(reset),.flush(text_state==S_DRAIN),.pixel_valid(text_valid),.pixel_ready(text_pixel_ready),
            .pixel_x(text_x),.pixel_y(text_y),.pixel_index(text_index),.base_address(source_bank ? 25'h1480000 : 25'h1400000),.idle(text_idle),
            .mem_req(text_write_req),.mem_addr(text_write_addr),.mem_data(text_write_data),.mem_bytes(text_write_bytes),.mem_ack(text_write_ack));
    end else begin: no_current_text
        assign direct_query=0;assign direct_query_band=0;assign direct_descriptor_ready=0;
        assign direct_rom_req=0;assign direct_rom_addr=0;
        assign text_mem_req=0;assign text_mem_addr=0;assign text_ready=1;assign text_done=0;
        assign text_write_req=0;assign text_write_addr=0;assign text_write_data=0;assign text_write_bytes=0;
        assign text_supported=1;assign text_idle=1;
    end endgenerate
    reg [2:0] held_owner,next_owner;
    reg surface_active;
    wire [2:0] owner=surface_active ? held_owner:selected;
    assign surface_req=!reset && (surface_active || found);
    reg found;
    reg [2:0] selected;
    integer n,candidate;
    wire [14:0] display_last_word=CURRENT_TEXT ? {display_ordinal[14:3],3'b111} : display_ordinal;
    // The two committed-ordinal comparators used to sit at the head of the
    // arbiter -> owner -> ACK cone. Register their results and validate them
    // against the scanout key (bank + group): committed counters only grow
    // between producer restarts, so a stale result is conservative (one cycle
    // late), and every restart that lowers a counter clears its result on the
    // same edge the counter is cleared.
    localparam KEY_W=CURRENT_TEXT ? 12 : 15;
    wire [KEY_W-1:0] display_key=display_last_word[14 -: KEY_W];
    reg [KEY_W-1:0] display_key_q;
    reg display_key_bank_q,display_words_q,display_text_q;
    wire display_key_same=display_key_q==display_key && display_key_bank_q==display_bank;
    wire display_words_lt=display_last_word<committed_words[display_bank];
    wire display_text_lt=display_last_word<text_committed[display_bank];
    wire committed_words_clear=reset || (query && query_ready);
    wire text_committed_clear=reset || (CURRENT_TEXT && text_state==S_START && text_ready && !source_output_held);
    always @(posedge clk) begin
        display_key_q<=display_key;display_key_bank_q<=display_bank;
        display_words_q<=display_words_lt && !committed_words_clear;
        display_text_q<=display_text_lt && !text_committed_clear;
    end
    wire display_available=display_key_same && (rotated_complete[display_bank] || display_words_q) &&
        (!CURRENT_TEXT || display_text_q);
    wire [1:0] rotate_hold={(keep_valid && keep_bank) || (display_active && display_bank && rotated_complete[1]),
                            (keep_valid && !keep_bank) || (display_active && !display_bank && rotated_complete[0])};
    wire [1:0] rotate_ready=slot_busy & (slot_ready | source_stream_valid) & ~rotate_hold & ~source_direct & ~render_complete;
    wire [1:0] completed=slot_busy & render_complete & (CURRENT_TEXT ? overlay_complete : 2'b11);
    wire completed_bank=!completed[0];
    wire rotate_candidate=!rotate_ready[0];
    wire display_pair_hit=display_pair_valid && display_pair_tag=={display_bank,display_addr[15:3]};
    // A cache fill reads an entire 8x8 tile, including both four-row bursts.
    // Fence it behind the next tile-row's first retired write, not merely
    // behind the requested pixel or a pixel queued in the indexed writer.
    wire affine_source_available=slot_ready[rotate_bank] ||
        (source_stream_valid[rotate_bank] && affine_read_addr[15:10]<source_stream_row[rotate_bank]);
    wire [4:0] requests={text_write_req && !text_transparent,display_req && display_available && (!CURRENT_TEXT || !display_pair_hit),affine_write_req,affine_read_req && affine_source_available,source_write_req};
    wire [24:0] display_base=display_bank ? 25'h1380000 : 25'h1300000;
    assign display_ack=CURRENT_TEXT ? display_req && display_available && display_pair_hit : surface_req && surface_ack && owner==3;
    assign display_data=CURRENT_TEXT ? merged_display_data : surface_rdata;
    always @* begin
        merged_display_data=rotated_display_line[display_addr[2:0]];
        for(lane=0;lane<4;lane=lane+1)
            if(current_display_valid[display_addr[2:0]] &&
                current_display_word[lane*16 +: 16]!=0)
                merged_display_data[lane*16 +: 16]=current_display_word[lane*16 +: 16];
    end
    assign surface_line=CURRENT_TEXT && surface_req && (owner==3 || owner==1);
    assign text_write_ack=text_write_req && (text_transparent || (surface_req && surface_ack && owner==4));
    assign query_ready=source_state==S_IDLE && initialized && source_ready && !slot_busy[bank] && (!CURRENT_TEXT || text_state==S_IDLE);
    assign cut_ready=source_state==S_IDLE && source_cut_ready && (!CURRENT_TEXT || text_state==S_IDLE);
    assign source_write_ack=surface_req && surface_ack && owner==0;
    assign affine_read_ack=surface_req && surface_ack && owner==1;
    assign affine_write_ack=surface_req && surface_ack && owner==2;
    gs_source_frame source(
        .clk(clk),.reset(reset),.initialized(initialized),.cut(cut && source_state==S_IDLE),.cpu_bus_idle(cpu_bus_idle),.cut_ready(source_cut_ready),.cut_ack(cut_ack),
        .cpu_req(cpu_req),.cpu_write(cpu_write),.cpu_addr(cpu_addr),.cpu_wdata(cpu_wdata),.cpu_bytes(cpu_bytes),
        .cpu_mapped(cpu_mapped),.cpu_ack(cpu_ack),.cpu_rdata(cpu_rdata),
        .frame_sealed(frame_sealed),.direct_query(direct_query),.direct_query_band(direct_query_band),.direct_query_ready(direct_query_ready),.direct_query_done(direct_query_done),
        .direct_descriptor_valid(direct_descriptor_valid),.direct_descriptor_ready(direct_descriptor_ready),.direct_descriptor(direct_descriptor),
        .direct_rom_req(direct_rom_req),.direct_rom_addr(direct_rom_addr),.direct_rom_ack(direct_rom_ack),.direct_rom_rvalid(direct_rom_rvalid),.direct_rom_data(direct_rom_data),
        .text_mem_req(text_mem_req),.text_mem_addr(text_mem_addr),.text_mem_ack(text_mem_ack),.text_mem_rdata(text_mem_rdata),
        .query(source_state==S_START && !pcb_window_pending && source_start_allowed),.query_ready(source_ready),.controls(saved_controls),.done(source_done),
        .window_enable(source_window_enable),.window_x0(source_window[35:27]),.window_x1(source_window[26:18]),
        .window_y0(source_window[17:9]),.window_y1(source_window[8:0]),
        .sample_shift_x(source_shift_x),.sample_shift_y(source_shift_y),
        .sample_rows_enable(rows_enable),.sample_row_used(row_used),.sample_row_ready(row_ready),.sample_y(sample_y),
        .supported(source_supported),.overflow(overflow),.descriptor_count(),.node_count(),
        .scp_rom_req(scp_rom_req),.scp_rom_addr(scp_rom_addr),.scp_rom_ack(scp_rom_ack),.scp_rom_rdata(scp_rom_rdata),
        .sprite_rom_req(sprite_rom_req),.sprite_rom_addr(sprite_rom_addr),.sprite_rom_ack(sprite_rom_ack),.sprite_rom_rvalid(sprite_rom_rvalid),.sprite_rom_rdata(sprite_rom_rdata),
        .map_req(map_req),.map_word_addr(map_word_addr),.map_ack(map_ack),.map_rdata(map_rdata),
        .arena_req(arena_req),.arena_write(arena_write),.arena_wide(arena_wide),.arena_addr(arena_addr),
        .arena_wdata(arena_wdata),.arena_ack(arena_ack),.arena_rdata(arena_rdata),
        .pixel_valid(source_valid),.pixel_ready(source_pixel_ready),.pixel_x(source_x),.pixel_y(source_y),.pixel_index(source_index),.pixel_priority());
    gs_indexed_writer source_writer(
        .clk(clk),.reset(reset),.flush(source_state==S_DRAIN),.pixel_valid(source_valid),.pixel_ready(source_pixel_ready),
        .pixel_x(source_x),.pixel_y(source_y),.pixel_index(source_index),.base_address(source_base),.idle(source_idle),
        .mem_req(source_write_req),.mem_addr(source_write_addr),.mem_data(source_write_data),.mem_bytes(source_write_bytes),.mem_ack(source_write_ack));
    gs_tc0610_plane #(.STREAM_FILL(CURRENT_TEXT)) affine(
        .clk(clk),.reset(reset),.query(rotate_state==R_START),.query_ready(affine_ready),.rzx(rotation_x[rotate_bank]),.rzy(rotation_y[rotate_bank]),.pcb_mode(rotation_pcb[rotate_bank]),.pcb_regs({rotation_regs[rotate_bank][79:32],rotation_y[rotate_bank],rotation_x[rotate_bank],rotation_regs[rotate_bank][31:0]}),.done(affine_done),
        .mem_req(affine_read_req),.mem_addr(affine_read_addr),.mem_ack(affine_read_ack),.mem_rdata(surface_rdata),
        .mem_line_valid(surface_req && owner==1 && line_valid),.mem_line_word(line_word),.mem_line_data(line_data),
        .pixel_valid(affine_valid),.pixel_ready(affine_pixel_ready),.pixel_x(affine_x),.pixel_y(affine_y),.pixel_index(affine_index));
    gs_indexed_writer rotated_writer(
        .clk(clk),.reset(reset),.flush(rotate_state==R_DRAIN),.pixel_valid(affine_valid),.pixel_ready(affine_pixel_ready),
        .pixel_x(affine_x),.pixel_y(affine_y),.pixel_index(affine_index),.base_address(rotated_base),.idle(affine_idle),
        .mem_req(affine_write_req),.mem_addr(affine_write_addr),.mem_data(affine_write_data),.mem_bytes(affine_write_bytes),.mem_ack(affine_write_ack));
    always @* begin
        found=0;selected=0;
        for(n=0;n<5;n=n+1) begin
            candidate=next_owner+n;if(candidate>=5) candidate=candidate-5;
            if(!found && requests[candidate]) begin found=1;selected=candidate[2:0];end
        end
        // Scanout has a fixed pixel deadline; producers can accept backpressure.
        if(requests[3]) begin found=1;selected=3;end
    end
    // Native producers retain their packet through ACK. Select it directly
    // and lock only its owner, removing a complete packet-copy handoff.
    always @* begin
        surface_write=owner==0 || owner==2 || owner==4;
        surface_addr=0;surface_wdata=0;surface_bytes=0;
            case(owner)
            0: begin
                surface_addr=source_direct[source_bank] ?
                    (source_bank ? 25'h1380000 : 25'h1300000)+{6'b0,source_write_addr[18:3],3'b0} :
                    source_base+{6'b0,tile_word(source_write_addr[18:3]),3'b0};
                surface_wdata=source_write_data;surface_bytes=source_write_bytes;
            end
            1: begin surface_addr=affine_source_base+{6'b0,tile_word(affine_read_addr),3'b0};surface_wdata=0;surface_bytes=0;end
            2: begin surface_addr=affine_write_addr;surface_wdata=affine_write_data;surface_bytes=affine_write_bytes;end
            3: begin surface_addr=(CURRENT_TEXT && display_text_phase ? (display_bank ? 25'h1480000 : 25'h1400000) : display_base)+{6'b0,display_addr,3'b0};surface_wdata=0;surface_bytes=0;end
            4: begin surface_addr=text_write_addr;surface_wdata=text_write_data;surface_bytes=text_write_bytes;end
            endcase
    end
    always @(posedge clk) begin
        mask_read<=current_masks[(display_bank ? 13'd2320 : 13'd0)+{1'b0,display_ordinal[14:3]}];
        if(CURRENT_TEXT && text_write_ack && text_committed[source_bank][2:0]==7)
            current_masks[(source_bank ? 13'd2320 : 13'd0)+{1'b0,text_committed[source_bank][14:3]}]<={!text_transparent,current_mask[6:0]};
    end
    always @(posedge clk) begin
        done<=0;
        if(CURRENT_TEXT && text_write_ack) begin
            current_mask[text_committed[source_bank][2:0]]<=!text_transparent;
            text_committed[source_bank]<=text_committed[source_bank]+1'b1;
        end
        if(CURRENT_TEXT && surface_req && owner==3 && line_valid) begin
            if(display_text_phase) begin
                current_display_line[line_word]<=line_data;
                current_display_valid[line_word]<=display_mask[line_word];
            end
            else rotated_display_line[line_word]<=line_data;
        end
        if(surface_req) begin
            if(!surface_active) begin
                held_owner<=selected;surface_active<=1;
                if(owner==3 && CURRENT_TEXT && !display_text_phase) display_pair_valid<=0;
            end
            if(surface_ack) begin
                surface_active<=0;next_owner<=owner==4 ? 0 : owner+1'b1;
                if(owner==3 && CURRENT_TEXT) begin
                    if(display_text_phase || mask_read==0) begin
                        display_pair_valid<=1;display_pair_tag<={display_bank,display_addr[15:3]};display_text_phase<=0;
                        if(!display_text_phase) begin
                            current_display_valid<=0;
                        end
                    end else begin display_mask<=mask_read;display_text_phase<=1;end
                end
                if(owner==2) committed_words[rotate_bank]<=committed_words[rotate_bank]+1'b1;
                if(owner==0 && source_direct[source_bank]) committed_words[source_bank]<=committed_words[source_bank]+1'b1;
                if(owner==0 && !source_direct[source_bank]) begin
                    source_stream_valid[source_bank]<=1;
                    source_stream_row[source_bank]<=source_write_addr[18:13];
                end
            end
        end
        if(display_restart && CURRENT_TEXT) begin display_text_phase<=0;display_pair_valid<=0;end
        if(query && query_ready) begin
            source_bank<=bank;saved_controls<=controls;saved_scn<=scn_controls;
            source_direct[bank]<=identity_transform;
            source_stream_valid[bank]<=0;source_stream_row[bank]<=0;
            render_complete[bank]<=0;overlay_complete[bank]<=0;
            source_window_enable<=window_enable && !affine_pcb;source_window<={window_x0,window_x1,window_y0,window_y1};
            pcb_window_pending<=affine_pcb;
            source_shift_x<=grid_axis ? grid_shift(affine_regs[47:32]) : 2'd0;
            source_shift_y<=0;
            // UB_OFFSET=44, VB_OFFSET=-5 in the paired PCB mapper.
            source_phase_x<=affine_regs[6:4]+3'd4;source_phase_y<=affine_regs[22:20]+3'd3;
            if(CURRENT_TEXT) begin
                text_state<=S_START;
            end
            rotation_x[bank]<=rzx;rotation_y[bank]<=rzy;rotation_regs[bank]<={affine_regs[111:64],affine_regs[31:0]};rotation_pcb[bank]<=affine_pcb;
            slot_busy[bank]<=1;slot_ready[bank]<=0;committed_words[bank]<=0;source_state<=S_START;presentable[bank]<=0;
        end
        if(pcb_window_pending && !pcb_window_busy && !rows_busy && !(query && query_ready)) begin
            pcb_window_pending<=0;source_window_enable<=1;
            source_window<={grid_xlo<={1'b0,pcb_xhi} ? grid_xlo[8:0] : pcb_xlo,pcb_xhi,
                            grid_ylo<={1'b0,pcb_yhi} ? grid_ylo[8:0] : pcb_ylo,pcb_yhi};
            if(source_direct[source_bank]) source_window<={9'd96,9'd415,9'd84,9'd315};
            if(grid_xlo>{1'b0,pcb_xhi}) source_shift_x<=0;
            if(grid_ylo>{1'b0,pcb_yhi}) source_shift_y<=0;
        end
        case(source_state)
        S_START: if(source_ready && !pcb_window_pending && source_start_allowed) begin
            source_state<=S_RUN;
            if(source_direct[source_bank]) begin
                rotated_complete[source_bank]<=0;
            end
        end
        S_RUN: if(source_done) source_state<=S_DRAIN;
        S_DRAIN: if(source_idle && (!surface_req || owner!=0) && (!source_direct[source_bank] || rotate_state==R_IDLE)) begin
            source_state<=S_IDLE;
            if(source_direct[source_bank]) begin
                rotated_complete[source_bank]<=1;render_complete[source_bank]<=1;
            end else begin
                slot_ready[source_bank]<=1;
            end
        end
        endcase
        case(text_state)
        // Keep the overlay intact if an overdue query reuses the page still
        // on screen. Overlay data and masks belong to the rotated frame bank.
        S_START: if(text_ready && !source_output_held) begin
            text_committed[source_bank]<=0;current_mask<=0;text_state<=S_RUN;
        end
        S_RUN: if(text_done) text_state<=S_DRAIN;
        S_DRAIN: if(text_idle && (!surface_req || owner!=4)) begin
            text_state<=S_IDLE;overlay_complete[source_bank]<=1;
        end
        endcase
        case(rotate_state)
        R_IDLE: if(affine_ready && |rotate_ready) begin
            rotate_bank<=rotate_candidate;rotated_complete[rotate_candidate]<=0;rotate_state<=R_START;
        end
        R_START: if(affine_ready) rotate_state<=R_RUN;
        R_RUN: if(affine_done) rotate_state<=R_DRAIN;
        R_DRAIN: if(affine_idle && slot_ready[rotate_bank] && (!surface_req || owner!=2)) begin
            rotated_complete[rotate_bank]<=1;render_complete[rotate_bank]<=1;rotate_state<=R_IDLE;
        end
        endcase
        // Publish only a complete image/overlay pair. Keep that entire pair
        // immutable, including during vblank, until another pair completes.
        // Producers may prepare the other source page while scanout repeats.
        if(|completed) begin
            slot_busy[completed_bank]<=0;slot_ready[completed_bank]<=0;
            presentable[completed_bank]<=1;keep_valid<=1;keep_bank<=completed_bank;
            done<=1;done_bank<=completed_bank;
        end
        if(reset) begin
            source_state<=S_IDLE;rotate_state<=R_IDLE;text_state<=S_IDLE;saved_scn<=0;text_committed[0]<=0;text_committed[1]<=0;display_text_phase<=0;display_pair_valid<=0;display_pair_tag<=0;slot_busy<=0;slot_ready<=0;
            rotated_complete<=0;presentable<=0;
            render_complete<=0;overlay_complete<=0;keep_valid<=0;keep_bank<=0;
            source_direct<=0;
            source_stream_valid<=0;source_stream_row[0]<=0;source_stream_row[1]<=0;
            current_mask<=0;display_mask<=0;current_display_valid<=0;
            source_bank<=0;rotate_bank<=0;saved_controls<=0;source_window_enable<=0;source_window<=0;pcb_window_pending<=0;done<=0;done_bank<=0;
            source_shift_x<=0;source_shift_y<=0;source_phase_x<=0;source_phase_y<=0;
            committed_words[0]<=0;committed_words[1]<=0;rotation_x[0]<=0;rotation_x[1]<=0;rotation_y[0]<=0;rotation_y[1]<=0;rotation_regs[0]<=0;rotation_regs[1]<=0;rotation_pcb<=0;
            surface_active<=0;held_owner<=0;next_owner<=0;
        end
    end
`ifndef SYNTHESIS
    reg stalled_packet;
    reg [97:0] retained_packet;
    always @(posedge clk) begin
        if(reset) stalled_packet<=0;
        else begin
            if(stalled_packet)
                assert(surface_req && {surface_write,surface_addr,surface_wdata,surface_bytes}==retained_packet)
                    else $fatal(1,"GPU packet changed before its physical ACK");
            stalled_packet<=surface_req && !surface_ack;
            retained_packet<={surface_write,surface_addr,surface_wdata,surface_bytes};
        end
    end
    always @(posedge clk) if(!reset) begin
        if(source_write_ack && !source_direct[source_bank] && source_stream_valid[source_bank])
            assert(source_write_addr[18:13]>=source_stream_row[source_bank])
                else $fatal(1,"Source streaming watermark moved backwards");
        if(surface_req && !surface_write && owner==1)
            assert(affine_source_available)
                else $fatal(1,"Rotation read an unfinished source tile-row");
        if(rotate_state==R_DRAIN && affine_idle && !slot_ready[rotate_bank])
            assert(slot_busy[rotate_bank])
                else $fatal(1,"Rotation released a bank before source completion");
        if(keep_valid && surface_req && surface_write) begin
            if(owner==2) assert(rotate_bank!=keep_bank) else $fatal(1,"Overwrote retained rotation");
            if(owner==4 || (owner==0 && source_direct[source_bank]))
                assert(source_bank!=keep_bank) else $fatal(1,"Overwrote retained frame/overlay");
        end
    end
`endif
endmodule

// For an axis-aligned PCB transform, source V depends only on output Y.
// Mark the exact rows read by all232 outputs, including fractional/negative
// zoom and 24-bit wrap. Unmarked rows need neither tile fetches nor writes.
module gs_tc0610_sample_rows(
    input wire clk,reset,start,pcb_mode,
    input wire [111:0] regs,
    output wire busy,output reg enabled,
    input wire [8:0] lookup_y,output wire used,lookup_ready
);
    localparam IDLE=0,CLEAR=1,SEED=2,MARK=3,FLUSH=4;
    reg [2:0] state;
    reg [7:0] cursor;
    reg [15:0] r1,r5;
    reg [23:0] v;
    (* ramstyle="MLAB" *) reg [31:0] rows[0:15];
    reg acc_valid;
    reg [3:0] acc_addr;
    reg [31:0] acc_word,row_word;
    reg [8:0] lookup_y_q;
    reg read_valid;
    wire [23:0] dy={{8{r5[15]}},r5};
    wire [23:0] origin={r1,8'b0}+(dy<<4)+(dy<<2)+(dy<<1);
    wire signed [12:0] row=$signed(v[23:12])-13'sd5;
    wire mark_valid=row>=0 && row<400;
    assign busy=state!=IDLE;
    assign used=!enabled || row_word[lookup_y_q[4:0]];
    assign lookup_ready=!enabled || (state==IDLE && read_valid && lookup_y_q==lookup_y);
    always @(posedge clk) begin
        row_word<=rows[lookup_y[8:5]];
        lookup_y_q<=lookup_y;
        // A FLUSH collision is never consumed. Read the completed RAM again
        // in IDLE before publishing a matching lookup address.
        read_valid<=state==IDLE;
        if(state==CLEAR) rows[cursor[3:0]]<=0;
        else if(state==MARK && mark_valid && acc_valid && acc_addr!=row[8:5]) rows[acc_addr]<=acc_word;
        else if(state==FLUSH && acc_valid) rows[acc_addr]<=acc_word;
        case(state)
        IDLE: if(start) begin
            enabled<=pcb_mode && regs[111:96]!=0 && regs[63:48]==0 && regs[79:64]==0;
            r1<=regs[31:16];r5<=regs[95:80];cursor<=0;acc_valid<=0;
            if(pcb_mode && regs[111:96]!=0 && regs[63:48]==0 && regs[79:64]==0) state<=CLEAR;
        end
        CLEAR: if(cursor==15) state<=SEED;else cursor<=cursor+1'b1;
        SEED: begin v<=origin;cursor<=0;state<=MARK;end
        MARK: begin
            // Signed V travels at most1848 texels over231 steps. The gap
            // between wrapped visits to0..399 is3696, so each accepted word
            // is visited once, monotonically; no RAM read-modify-write.
            if(mark_valid) begin
                acc_valid<=1;acc_addr<=row[8:5];
                if(acc_valid && acc_addr==row[8:5]) acc_word<=acc_word | (32'b1<<row[4:0]);
                else acc_word<=32'b1<<row[4:0];
            end
            v<=v+dy;
            if(cursor==231) state<=FLUSH;else cursor<=cursor+1'b1;
        end
        FLUSH: state<=IDLE;
        endcase
        if(reset) begin
            state<=IDLE;enabled<=0;cursor<=0;r1<=0;r5<=0;v<=0;
            acc_valid<=0;acc_addr<=0;acc_word<=0;lookup_y_q<=0;read_valid<=0;
        end
    end
endmodule
