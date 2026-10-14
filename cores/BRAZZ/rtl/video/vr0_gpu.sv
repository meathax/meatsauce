// SPDX-License-Identifier: GPL-3.0-or-later
// Genuine VRender0 packet renderer. Texture/frame memory is accessed through a dedicated
// 32-byte line burst port to the SDRAM backend: a read cache (packets, palette, tile map,
// texels; invalidated at every packet) and a write-combining framebuffer line flushed as one
// posted burst. The destination is read only for alpha blending. The word bus port stays idle.
// Quad pixels run through an in-order pipeline (one pixel per clock while the tile/texel
// lines hit and the framebuffer line is unchanged); a miss, a framebuffer line change or an
// alpha destination load freezes the front of the pipeline while the FSM services it.
// MAME's unmapped video aperture returns all ones and ignores writes.
// MAME_PALETTE_HACK=1 reproduces pinned MAME exactly: converted palette entries equal to the
// transparent colour (or to the 0xecda "no transparency" sentinel) are nudged by one blue LSB.
// MAME_PALETTE_HACK=0 (shipped core) keeps the plain RGB565 palette and instead remembers per
// palette entry that it is opaque (565 equals the key but the 24-bit entry does not); there is
// no 0xecda sentinel and transparency requires packet bit 2. See docs/HACKS.md.
// SNOOP_COHERENT=1 (board): the read caches persist across packets and are kept coherent by
// snoop_valid/snoop_line, one pulse per accepted CPU/DMA word write into texture/VRAM.
// SNOOP_COHERENT=0 (unit benches that rewrite texture memory directly): invalidated per packet.
// ORDERED_FRONT=1: a CPU write of the display-list queue front is only announced (front_wr) and taken over
// into the renderer-visible queue_front when front_set returns it from the ordered texture write queue
// (cs_texq); the CPU reads its own value back. drain_ok tells the queue that the renderer has caught up.
module vr0_gpu #(parameter bit MAME_PALETTE_HACK = 1'b0, parameter bit SNOOP_COHERENT = 1'b0, parameter bit ORDERED_FRONT = 1'b0) (
    input logic clk, reset,
    input logic reg_valid, output logic reg_ready,
    input logic [15:0] reg_address,
    input logic [31:0] reg_data, input logic [3:0] reg_strobe,
    input logic reg_write,
    output logic reg_rsp_valid, output logic [31:0] reg_rsp_data,
    output logic reg_rsp_error,
    input logic vblank,
    output logic req_valid, input logic req_ready,
    output logic [31:0] req_address,req_data,
    output logic [3:0] req_strobe, output logic req_write,
    input logic rsp_valid, input logic [31:0] rsp_data, input logic rsp_error,
    output logic burst_valid, burst_write, burst_region,
    output logic [17:0] burst_line,
    output logic [7:0][31:0] burst_wdata,
    output logic [7:0][3:0] burst_wstrobe,
    input logic burst_ready, burst_done, burst_error,
    input logic [7:0][31:0] burst_rdata,
    input logic snoop_valid,
    input logic [17:0] snoop_line,
    output logic [10:0] queue_front,queue_rear,
    output logic front_wr, output logic [15:0] front_wr_val, input logic front_set, input logic [15:0] front_set_val,
    output logic drain_ok,
    output logic [7:0] flip_count,
    output logic display_bank,flip_sync,busy,fault,
    output logic [22:0] display_address,draw_address,
    output logic [31:0] fault_address,
    output logic [31:0] packets_completed,pixels_written
);
    import vr0_pixel_pkg::*;
    typedef enum logic [4:0] {IDLE,RD_LOOKUP,RD_CHECK,RD_FILL,RD_FILL_WAIT,PACKET_STORE,DECODE,PREP,
        PAL_STORE,PIX_START,PIXELS,RELOOK,DEST_LOAD,DEST_WAIT,COMPLETE,FAILED} state_t;
    state_t state, rd_ret;
    // Read caches: two independent direct-mapped caches of 256 32-byte lines (8 KiB each) of the
    // texture/VRAM region, so the first lookup (A: packet/palette words, tile map, untiled
    // texels) and the tiled texel lookup (B) of consecutive pixels proceed in the same clock and
    // never evict each other. A fill writes only the cache that missed.
    localparam int RC_BITS = 8;                 // log2(lines per cache)
    localparam int RC_LINES = 1 << RC_BITS;
    localparam int RC_TAG = 18 - RC_BITS;
    (* ramstyle = "M10K" *) logic [255:0] rca_mem [0:RC_LINES-1];
    (* ramstyle = "M10K" *) logic [255:0] rcb_mem [0:RC_LINES-1];
    (* ramstyle = "M10K" *) logic [RC_TAG-1:0] rca_tag [0:RC_LINES-1];
    (* ramstyle = "M10K" *) logic [RC_TAG-1:0] rcb_tag [0:RC_LINES-1];
    logic [255:0] rca_q, rcb_q;
    logic [RC_TAG-1:0] rca_tag_q, rcb_tag_q;
    logic rca_valid_q, rcb_valid_q;
    logic [RC_LINES-1:0] rca_valid, rcb_valid;
    logic [22:0] rd_addr;
    wire [17:0] rd_line = rd_addr[22:5];
    wire [RC_BITS-1:0] rd_index = rd_line[RC_BITS-1:0];
    wire [31:0] rd_word = rca_q[{rd_addr[4:2],5'b0} +: 32];
    logic pipe_fill, fill_b;
    // Write-combining framebuffer line (frame region); wc_loaded = holds destination data.
    logic wc_valid, wc_loaded;
    logic [17:0] wc_line;
    logic [7:0][31:0] wc_data;
    logic [7:0][3:0] wc_strobe;
    // A retired line waits in pend for the burst port while rendering continues into wc; the
    // backend latches it at acceptance (posted). Engine reads take the port first; a
    // destination load of the pending line waits until it is posted (read after write).
    logic pend_valid;
    logic [17:0] pend_line;
    logic [7:0][31:0] pend_data;
    logic [7:0][3:0] pend_strobe;
    // Alpha destination prefetch: while a loaded line is blended, the next line the quad
    // iteration will reach (next 32 bytes of the row, else the first line of the next row) is
    // read into pf when the port is free, so the line change usually needs no exposed read.
    logic pf_valid, pf_want, pf_drop;
    logic [17:0] pf_line, pf_target;
    logic [7:0][31:0] pf_data;
    // Outstanding burst not owned by an engine wait state: 0 none, 1 posted write, 2 prefetch.
    logic [1:0] nb_kind;
    logic [17:0] posted_line;
    logic [15:0] packet [0:31];
    // Palette + per-entry opaque flag live in block RAM (was ~4.6k flip-flops).
    wire [16:0] palette_q;
    logic [3:0] packet_index;
    logic [7:0] palette_index;
    logic [12:0] palette_offset,last_palette;
    logic palette_valid;
    // Palette cache: 8 converted palettes (slot = palette RAM bank), keyed by palette offset and
    // the transparent colour the conversion used. A load MAME performs (offset differs from its
    // last load) is served from a slot whose source memory has not been written since (CPU/DMA
    // write snoop; without SNOOP_COHERENT every packet invalidates all slots). MAME's stale
    // reuse of the last loaded palette (same offset, no reload) is kept by palette_valid.
    logic [2:0] pal_slot, pal_fill_slot, pal_victim;
    logic [7:0] pc_valid;
    logic [12:0] pc_offset [0:7];
    logic [23:0] pc_trans [0:7];
    logic pal_load_snooped;
    logic [7:0] pc_match;
    logic [2:0] pc_hit_slot;
    always_comb begin
        pc_hit_slot=0;
        for(int i=0;i<8;i++) begin
            pc_match[i]=pc_valid[i] && pc_offset[i]==palette_offset && pc_trans[i]==trans_color;
            if(pc_match[i]) pc_hit_slot=3'(i);
        end
    end
    logic [15:0] tile_offset,font_offset;
    logic [3:0] palette_bank;
    logic tiled;
    logic [1:0] pixel_format;
    logic [10:0] texture_width,texture_height;
    logic [31:0] texture_x_mask,texture_y_mask;
    logic [3:0] texture_width_shift;
    logic [2:0] texture_tile_shift;
    logic texture_size_configured;
    logic [31:0] rs_tx,rs_ty,rs_txdx,rs_tydx,rs_txdy,rs_tydy;
    logic [23:0] src_color,dst_color,shade_color,trans_color;
    logic [5:0] src_blend,dst_blend;
    logic [7:0] control;
    logic bank1_select;
    logic [22:0] bank1,front_address,back_address,packet_draw_address;
    logic [9:0] x,start_x,end_x;
    logic [8:0] y,end_y;
    logic [31:0] line_tx,line_ty,pixel_tx,pixel_ty;
    logic iterating;
    logic [31:0] result_data;
    logic [31:0] reg_read_data;
    logic [15:0] merged_front;
    logic [10:0] cpu_front; // the CPU's own view of the queue front (ORDERED_FRONT)
    logic [15:0] transparency;
    logic [15:0] palette_value;
    logic palette_collision;
    logic [15:0] palette_raw;
    logic use_alpha;

    // ---- pixel pipeline registers ---------------------------------------------------------
    // s1: texel coordinates; s2: tile/linear offset; s3: lookup address (RAM A read);
    // s4: copy A tag check; s5: tile index -> texel address; s6: RAM B read; s7: copy B check,
    // palette read; s8: source colour; s9: transparency/shade; s10: write / alpha destination;
    // s11..s13: alpha factors, products, sum + store (tail, never stalls).
    logic s1_v,s2_v,s3_v,s4_v,s5_v,s6_v,s7_v,s8_v,s9_v,s10_v,s11_v,s12_v,s13_v;
    logic [9:0] s1_x; logic [8:0] s1_y;
    logic [31:0] s1_tx,s1_ty,s2_part;
    logic [5:0] s2_t3,s3_t3,s4_t3,s5_t3;
    logic s2_skip,s3_skip,s4_skip,s5_skip,s6_skip,s7_skip,s8_skip;
    logic [22:0] s2_fb,s3_fb,s4_fb,s5_fb,s6_fb,s7_fb,s8_fb,s9_fb,s10_fb,s11_fb,s12_fb,s13_fb;
    logic [22:0] s3_addr,s4_addr,s6_addr,s7_addr;
    logic s3_nib,s4_nib,s5_nib,s6_nib,s7_nib;
    logic [31:0] s5_word,s6_word,s7_word;
    logic [15:0] s8_texel;
    logic [15:0] s9_source; logic s9_opaque;
    logic [15:0] s10_pixel,s11_pixel,s11_dest,s12_dest,s13_dest;
    logic [15:0] s12_pixel;
    logic [2:0][8:0] s12_src_factor,s12_dst_factor;
    logic [2:0][15:0] s13_src_product,s13_dst_product;

    wire textured = packet[0][3];
    wire lookup_b = packet[0][3] && tiled;
    wire [22:0] tile_base = {tile_offset,7'b0};
    wire [22:0] font_base = {font_offset,7'b0};
    function automatic logic [22:0] texel_address(input logic [1:0] format, input logic [31:0] offset);
        case(format)
            0: return 23'(offset>>1);
            1: return 23'(offset);
            default: return 23'(offset<<1);
        endcase
    endfunction
    // Copy A check (s4) and copy B check (s7).
    wire hit_a = rca_valid_q && rca_tag_q==s4_addr[22:5+RC_BITS];
    wire miss_a = s4_v && !s4_skip && textured && !hit_a;
    wire [31:0] word_a = rca_q[{s4_addr[4:2],5'b0} +: 32] >> {s4_addr[1:0],3'b000};
    wire hit_b = rcb_valid_q && rcb_tag_q==s7_addr[22:5+RC_BITS];
    wire miss_b = s7_v && !s7_skip && lookup_b && !hit_b;
    wire [31:0] word_b = lookup_b ? (rcb_q[{s7_addr[4:2],5'b0} +: 32] >> {s7_addr[1:0],3'b000}) : s7_word;
    wire [7:0] palette_lookup = pixel_format==0 ? {palette_bank,(s7_nib ? word_b[3:0] : word_b[7:4])} : word_b[7:0];
    // s5: tile index -> texel address.
    wire [21:0] tile_texel = {s5_word[15:0],s5_t3};
    // s8/s9: source colour, transparency and shade.
    wire [15:0] source_pixel = !textured ? (packet[0][4] ? rgb565(shade_color) : 16'hffff) :
        (pixel_format<2 ? palette_q[15:0] : s8_texel);
    wire source_opaque = textured && pixel_format<2 && !MAME_PALETTE_HACK && palette_q[16];
    wire src_transparent = packet[0][3] && s9_source==transparency && (MAME_PALETTE_HACK || (packet[0][2] && !s9_opaque));
    wire [15:0] shaded_pixel = packet[0][3] && packet[0][4] ? shade565(s9_source,shade_color) : s9_source;
    // s10: framebuffer line check. Without alpha the destination is not needed: MAME's
    // compare-before-write only skips identical stores, so writing unconditionally leaves the
    // same memory. With alpha the line must hold the destination data.
    wire [17:0] s10_line = s10_fb[22:5];
    wire [15:0] s10_dest = wc_data[s10_fb[4:2]][{s10_fb[1],4'b0} +: 16];
    wire tail_busy = s11_v || s12_v || s13_v;
    // The renderer has caught up with the frame: it reached the sync-flip packet. Software that never
    // issues sync-flip packets (evosocc, topbladv, officeye, urachamu) flips at vblank once the renderer is
    // idle with the submitted queue drained (BrezzaSoft_Crystal_System_MiSTer rule, MAME flips at vblank).
    // Once a sync-flip packet has been seen, a drained queue flips only after it stayed drained with no
    // new submission for a whole frame (drained_frame): crysking raises its flip count before submitting
    // the frame, so a momentary mid-frame drain must not flip a half-drawn buffer, while software that
    // mixes frames with and without sync-flip packets (evosocc) still flips, one frame later.
    logic uses_sync_flip, drained_frame;
    wire drained = !busy && queue_rear == queue_front;
    // Texture writes may reach SDRAM only when everything submitted before them has been drawn: the render
    // is off, stopped at a sync-flip packet (MAME also lets the CPU rewrite textures there), or idle with
    // nothing queued.
    assign drain_ok = !control[2] || flip_sync || drained;
    wire caught_up = flip_sync || ((!uses_sync_flip || drained_frame) && drained);
    wire flip_now = vblank && control[2] && caught_up && flip_count != 0;
    wire wc_dirty = wc_valid && |wc_strobe;
    wire s10_stall = s10_v && (use_alpha ? !(wc_valid && wc_line==s10_line && wc_loaded) : (wc_valid && wc_line!=s10_line && pend_valid));
    wire s10_retire = s10_v && !use_alpha && wc_valid && wc_line!=s10_line;
    wire engine_port = state==RD_FILL || state==DEST_LOAD;
    wire pend_accept = pend_valid && !engine_port && burst_ready;
    wire pf_request = state==PIXELS && use_alpha && pf_want && !pf_valid && nb_kind!=2 && !pend_valid;
    wire pf_accept = pf_request && burst_ready;
    wire [17:0] row_end_line = {s10_fb[22:11],end_x[9:4]};
    wire next_line_exists = s10_line!=row_end_line || s10_fb[19:11]!=end_y;
    wire [17:0] next_line = s10_line!=row_end_line ? s10_line+18'd1 : {s10_fb[22:20],s10_fb[19:11]+9'd1,start_x[9:4]};
    wire advance = state==PIXELS && !miss_a && !miss_b && !s10_stall;
    wire front_empty = !iterating && !s1_v && !s2_v && !s3_v && !s4_v && !s5_v && !s6_v && !s7_v && !s8_v && !s9_v && !s10_v;
    wire [15:0] alpha_final = alpha_sum565(s13_src_product,s13_dst_product);

    wire palette_we=!reset && state==PAL_STORE;
    wire palette_re=!reset && advance;
    vr0_palette_ram palette_ram (.clk,.write_enable(palette_we),.write_address({pal_fill_slot,palette_index}),
        .write_data({!MAME_PALETTE_HACK && palette_collision,palette_value}),
        .read_enable(palette_re),.read_address({pal_slot,palette_lookup}),.read_data(palette_q));
    assign req_valid=0; assign req_address=0; assign req_data=0; assign req_strobe=0; assign req_write=0;
    always_comb begin
        burst_valid=0; burst_write=0; burst_region=0; burst_line=rd_line; burst_wdata=pend_data; burst_wstrobe=pend_strobe;
        case(state)
            RD_FILL: begin burst_valid=1; burst_region=0; burst_line=rd_line; end
            DEST_LOAD: begin burst_valid=1; burst_region=1; burst_line=s10_line; end
            default: if(pend_valid) begin burst_valid=1; burst_write=1; burst_region=1; burst_line=pend_line; end
                else if(pf_request) begin burst_valid=1; burst_region=1; burst_line=pf_target; end
        endcase
    end
    // Cache data/tag RAMs: one registered read port each, one 256-bit fill write port.
    // Copy A serves the FSM (packet/palette words), the pipeline's first lookup and its
    // re-lookup after a fill; copy B the pipeline's texel lookup.
    wire [RC_BITS-1:0] rca_index = state==RD_LOOKUP ? rd_index : state==RELOOK ? s4_addr[4+RC_BITS:5] : s3_addr[4+RC_BITS:5];
    wire rca_read = state==RD_LOOKUP || state==RELOOK || advance;
    wire [RC_BITS-1:0] rcb_index = state==RELOOK ? s7_addr[4+RC_BITS:5] : s6_addr[4+RC_BITS:5];
    wire rcb_read = state==RELOOK || advance;
    wire rc_fill = state==RD_FILL_WAIT && burst_done;
    always_ff @(posedge clk) begin
        if(rca_read) begin rca_q<=rca_mem[rca_index];rca_tag_q<=rca_tag[rca_index];end
        if(rcb_read) begin rcb_q<=rcb_mem[rcb_index];rcb_tag_q<=rcb_tag[rcb_index];end
        if(rc_fill && !fill_b) begin rca_mem[rd_index]<=burst_rdata;rca_tag[rd_index]<=rd_line[17:RC_BITS];end
        if(rc_fill && fill_b) begin rcb_mem[rd_index]<=burst_rdata;rcb_tag[rd_index]<=rd_line[17:RC_BITS];end
    end
    always_comb begin
        busy=(state!=IDLE && state!=FAILED) || pend_valid;
        bank1=bank1_select ? 23'h400000 : 23'h100000;
        front_address=display_bank ? bank1 : 23'd0;
        back_address=display_bank ? 23'd0 : bank1;
        reg_ready=!(reg_write && reg_address==16'h008c && reg_strobe[0] && reg_data[3] && busy);
        reg_read_data=32'hffffffff;
        case(reg_address)
            16'h0080: reg_read_data={5'b0,queue_rear,5'b0,ORDERED_FRONT ? cpu_front : queue_front};
            16'h008c: reg_read_data={15'b0,display_bank,8'b0,control};
            16'h0090: reg_read_data={16'hffff,bank1_select,15'b0};
            16'h00a4: reg_read_data={8'b0,flip_count,16'hffff};
            default: ;
        endcase
        merged_front={5'b0,ORDERED_FRONT ? cpu_front : queue_front};
        if(reg_strobe[0]) merged_front[7:0]=reg_data[7:0];
        if(reg_strobe[1]) merged_front[15:8]=reg_data[15:8];
        transparency=(MAME_PALETTE_HACK && !packet[0][2]) ? 16'hecda : rgb565(trans_color);
        palette_raw=rgb565(result_data[23:0]);
        palette_collision=palette_raw==rgb565(trans_color) && result_data!=32'(trans_color);
        palette_value=palette_raw;
        if (MAME_PALETTE_HACK && (palette_collision || palette_raw==16'hecda))
            palette_value = palette_raw[4:0]!=5'h1f ? palette_raw+16'd1 : palette_raw-16'd1;
        use_alpha=packet[0][1] && (packet[0][3] || src_blend!=0);
    end
    // Pipeline datapath (no reset needed beyond the valid bits).
    always_ff @(posedge clk) begin
        if(advance) begin
            // s0 -> s1: texel coordinates of the iterated pixel.
            s1_x<=x;s1_y<=y;
            s1_tx<=$unsigned($signed(pixel_tx) >>> 9) & (packet[0][5] ? 32'hffffffff : texture_x_mask);
            s1_ty<=$unsigned($signed(pixel_ty) >>> 9) & (packet[0][5] ? 32'hffffffff : texture_y_mask);
            // s1 -> s2: clamp rejection, tile-map or linear texel offset, framebuffer address.
            // Packet texture dimensions are powers of two (8 << size). Preserve the reset-time
            // zero width, and use shifts after size configuration.
            s2_skip<=packet[0][3] && packet[0][5] && (s1_tx>=32'(texture_width) || s1_ty>=32'(texture_height));
            s2_part<=tiled ? (texture_size_configured ? ((s1_ty>>3)<<texture_tile_shift) : 32'd0)+(s1_tx>>3)
                           : (texture_size_configured ? (s1_ty<<texture_width_shift) : 32'd0)+s1_tx;
            s2_t3<={s1_ty[2:0],s1_tx[2:0]};
            s2_fb<=packet_draw_address+{3'b0,s1_y,s1_x,1'b0};
            // s2 -> s3: first lookup address (tile map entry, or the texel when not tiled).
            s3_addr<=tiled ? tile_base+23'(s2_part<<1) : font_base+texel_address(pixel_format,s2_part);
            s3_nib<=s2_part[0];s3_t3<=s2_t3;s3_skip<=s2_skip;s3_fb<=s2_fb;
            // s3 -> s4: copy A read (above).
            s4_addr<=s3_addr;s4_nib<=s3_nib;s4_t3<=s3_t3;s4_skip<=s3_skip;s4_fb<=s3_fb;
            // s4 -> s5
            s5_word<=word_a;s5_nib<=s4_nib;s5_t3<=s4_t3;s5_skip<=s4_skip;s5_fb<=s4_fb;
            // s5 -> s6: tile index -> texel address (index 0 is an empty tile).
            if(lookup_b) begin
                s6_addr<=font_base+texel_address(pixel_format,32'(tile_texel));
                s6_nib<=tile_texel[0];s6_skip<=s5_skip || s5_word[15:0]==0;
            end else begin
                s6_addr<=23'b0;s6_nib<=s5_nib;s6_skip<=s5_skip;
            end
            s6_word<=s5_word;s6_fb<=s5_fb;
            // s6 -> s7: copy B read (above).
            s7_addr<=s6_addr;s7_nib<=s6_nib;s7_word<=s6_word;s7_skip<=s6_skip;s7_fb<=s6_fb;
            // s7 -> s8: palette read (palette RAM) / 16 bpp texel.
            s8_texel<=word_b[15:0];s8_skip<=s7_skip;s8_fb<=s7_fb;
            // s8 -> s9
            s9_source<=source_pixel;s9_opaque<=source_opaque;s9_fb<=s8_fb;
            // s9 -> s10
            s10_pixel<=shaded_pixel;s10_fb<=s9_fb;
            // s10 -> s11 (alpha only): destination pixel from the loaded line.
            s11_pixel<=s10_pixel;s11_dest<=s10_dest;s11_fb<=s10_fb;
        end
        // Alpha tail: exact 0..256 factors registered before the DSP products, then the
        // saturated sum and MAME's unchanged-pixel compare. Rounding is unchanged.
        for(int c=0;c<3;c++) begin
            s12_src_factor[c]<=9'(factor(src_blend,channel(s11_pixel,c),channel(s11_dest,c),src_color[23-c*8 -:8],dst_color[23-c*8 -:8]));
            s12_dst_factor[c]<=9'(factor(dst_blend,channel(s11_pixel,c),channel(s11_dest,c),src_color[23-c*8 -:8],dst_color[23-c*8 -:8]));
            s13_src_product[c]<=17'(channel(s12_pixel,c))*17'(s12_src_factor[c]);
            s13_dst_product[c]<=17'(channel(s12_dest,c))*17'(s12_dst_factor[c]);
        end
        // s12_pixel is packed into the DSP input register; a plain copy of s11_pixel failed
        // hold at -40C (DSP clock skew ~0.94 ns, zero data logic). The products are used only
        // for alpha packets, so gating by use_alpha is output-identical and adds a LUT level.
        s12_pixel<=use_alpha ? s11_pixel : 16'd0;s12_dest<=s11_dest;s12_fb<=s11_fb;
        s13_dest<=s12_dest;s13_fb<=s12_fb;
    end
    always_ff @(posedge clk) begin
        if(reset) begin
            state<=IDLE;queue_front<=0;queue_rear<=0;flip_count<=0;uses_sync_flip<=0;drained_frame<=0;cpu_front<=0;front_wr<=0;front_wr_val<=0;
            control<=0;bank1_select<=0;display_bank<=0;display_address<=0;draw_address<=0;flip_sync<=0;
            reg_rsp_valid<=0;reg_rsp_data<=0;reg_rsp_error<=0;
            fault<=0;fault_address<=0;packets_completed<=0;pixels_written<=0;
            packet_index<=0;palette_index<=0;palette_valid<=0;last_palette<=0;palette_offset<=0;
            pal_slot<=0;pal_fill_slot<=0;pal_victim<=0;pc_valid<=0;pal_load_snooped<=0;
            rd_addr<=0;rd_ret<=IDLE;rca_valid<=0;rcb_valid<=0;rca_valid_q<=0;rcb_valid_q<=0;result_data<=0;pipe_fill<=0;fill_b<=0;
            wc_valid<=0;wc_loaded<=0;wc_line<=0;wc_strobe<='0;nb_kind<=0;posted_line<=0;
            pf_valid<=0;pf_want<=0;pf_drop<=0;pf_line<=0;pf_target<=0;
            pend_valid<=0;pend_line<=0;pend_strobe<='0;
            tile_offset<=0;font_offset<=0;palette_bank<=0;tiled<=0;pixel_format<=0;
            texture_width<=0;texture_height<=0;rs_tx<=0;rs_ty<=0;rs_txdx<=0;rs_tydx<=0;rs_txdy<=0;rs_tydy<=0;
            texture_x_mask<=32'hffffffff;texture_y_mask<=32'hffffffff;
            texture_width_shift<=0;texture_tile_shift<=0;texture_size_configured<=0;
            src_color<=0;dst_color<=0;shade_color<=0;trans_color<=0;src_blend<=0;dst_blend<=0;
            x<=0;y<=0;start_x<=0;end_x<=0;end_y<=0;line_tx<=0;line_ty<=0;pixel_tx<=0;pixel_ty<=0;iterating<=0;
            packet_draw_address<=0;
            {s1_v,s2_v,s3_v,s4_v,s5_v,s6_v,s7_v,s8_v,s9_v,s10_v,s11_v,s12_v,s13_v}<='0;
            for(int i=0;i<32;i++) packet[i]<=0;
        end else begin
            reg_rsp_valid<=reg_valid && reg_ready;
            reg_rsp_error<=0;
            front_wr<=0;
            if(ORDERED_FRONT && front_set) queue_front<=front_set_val[10:0];
            if(reg_valid && reg_ready) reg_rsp_data<=reg_read_data;
            // MAME master execute_flipping(): with a zero flip count nothing happens at vblank
            // (flip_sync stays set, display/draw targets unchanged); fixes trivrus/crospuzl/topbladv timing.
            // The display bank only flips once the render pipeline has reached the frame's sync-flip
            // packet (flip_sync). MAME renders a whole queue instantly so this never differs there;
            // in hardware rendering takes real time, and flipping on flip_count alone showed a
            // half-drawn buffer (flickering, tile-holed attract screens on MiSTer).
            if(flip_sync) uses_sync_flip<=1;
            if(vblank) drained_frame<=!flip_now && drained && flip_count!=0;
            if(reg_valid && reg_write && reg_address==16'h0080) drained_frame<=0; // new submission
            if(flip_now) begin
                draw_address<=control[7] ? front_address : back_address;
                display_address<=front_address;
                flip_sync<=0;
                flip_count<=flip_count-8'd1;display_bank<=~display_bank;
            end
            // Read-cache copy valid bits follow their RAM reads.
            if(rca_read) rca_valid_q<=rca_valid[rca_index];
            if(rcb_read) rcb_valid_q<=rcb_valid[rcb_index];
            // Pipeline valid bits: the front advances together, the alpha tail always.
            if(advance) begin
                s1_v<=iterating;s2_v<=s1_v;s3_v<=s2_v;s4_v<=s3_v;s5_v<=s4_v;s6_v<=s5_v;s7_v<=s6_v;
                s8_v<=s7_v && !s7_skip;s9_v<=s8_v;s10_v<=s9_v && !src_transparent;
                s11_v<=s10_v && use_alpha;
            end else s11_v<=0;
            s12_v<=s11_v;s13_v<=s12_v;
            // Iterator (s0): MAME draw_quad x/y order, texture coordinates stepped per pixel/line.
            if(advance && iterating) begin
                if(x==end_x) begin
                    if(y==end_y) iterating<=0;
                    else begin y<=y+9'd1;x<=start_x;line_tx<=line_tx+rs_txdy;line_ty<=line_ty+rs_tydy;pixel_tx<=line_tx+rs_txdy;pixel_ty<=line_ty+rs_tydy;end
                end else begin x<=x+10'd1;pixel_tx<=pixel_tx+rs_txdx;pixel_ty<=pixel_ty+rs_tydx;end
            end
            // s10 store (no alpha) and s13 store (alpha) into the write-combining line.
            if(advance && s10_v && !use_alpha) begin
                // A line change retires the combined line into pend (empty, else s10 stalls).
                if(s10_retire) begin
                    pend_valid<=1;pend_line<=wc_line;pend_data<=wc_data;pend_strobe<=wc_strobe;
                    wc_strobe<='0;wc_loaded<=0;
                end
                wc_valid<=1;wc_line<=s10_line;
                wc_data[s10_fb[4:2]][{s10_fb[1],4'b0} +: 16]<=s10_pixel;
                wc_strobe[s10_fb[4:2]][{s10_fb[1],1'b0} +: 2]<=2'b11;
                pixels_written<=pixels_written+32'd1;
            end
            if(s13_v && alpha_final!=s13_dest) begin
                wc_data[s13_fb[4:2]][{s13_fb[1],4'b0} +: 16]<=alpha_final;
                wc_strobe[s13_fb[4:2]][{s13_fb[1],1'b0} +: 2]<=2'b11;
                pixels_written<=pixels_written+32'd1;
            end
            if(burst_done && nb_kind!=0) begin
                nb_kind<=0;
                if(nb_kind==2) begin
                    if(!pf_drop && !burst_error) begin pf_valid<=1;pf_data<=burst_rdata;end
                    pf_drop<=0;
                end
            end
            if(pend_accept) begin pend_valid<=0;nb_kind<=1;posted_line<=pend_line;end
            else if(pf_accept) begin nb_kind<=2;pf_line<=pf_target;pf_want<=0;end
            case(state)
                // A new packet: the CPU/DMA may have rewritten queue/palette/texture memory.
                IDLE: if(control[2] && !flip_sync && queue_rear!=queue_front && !fault && !(reg_valid && reg_write && reg_address==16'h008c && reg_strobe[0] && reg_data[3])) begin
                    if(!SNOOP_COHERENT) begin rca_valid<=0;rcb_valid<=0;pc_valid<=0;end
                    packet_index<=0;rd_addr<={6'b0,queue_rear,6'b0};rd_ret<=PACKET_STORE;state<=RD_LOOKUP;
                end
                RD_LOOKUP: state<=RD_CHECK;
                RD_CHECK: if(rca_valid_q && rca_tag_q==rd_line[17:RC_BITS]) begin
                    result_data<=rd_word>>{rd_addr[1:0],3'b000};state<=rd_ret;
                end else state<=RD_FILL;
                RD_FILL: if(burst_ready) state<=RD_FILL_WAIT;
                RD_FILL_WAIT: if(burst_done) begin
                    if(burst_error) begin fault<=1;fault_address<=32'h03800000+32'(rd_addr);state<=FAILED;end
                    else begin
                        if(fill_b) rcb_valid[rd_index]<=1; else rca_valid[rd_index]<=1;
                        state<=pipe_fill ? RELOOK : RD_LOOKUP;
                    end
                end
                PACKET_STORE: begin
                    packet[{packet_index,1'b0}]<=result_data[15:0];
                    packet[{packet_index,1'b1}]<=result_data[31:16];
                    if(packet_index==15) state<=DECODE;
                    else begin
                        // The next word of the same (just checked) line streams from the
                        // cache output register; a new line is looked up.
                        packet_index<=packet_index+4'd1;
                        rd_addr<={6'b0,queue_rear,packet_index+4'd1,2'b0};
                        if(packet_index[2:0]!=3'd7) result_data<=rca_q[{packet_index[2:0]+3'd1,5'b0} +: 32];
                        else state<=RD_LOOKUP;
                    end
                end
                DECODE: if(packet[0][0] || packet[0][7]) begin
                    palette_valid<=0;
                    if(packet[0][0]) flip_sync<=1;
                    if(packet[0][7]) draw_address<=control[7]?back_address:front_address;
                    state<=COMPLETE;
                end else begin
                    // MAME quad.dest is fixed when this packet is dispatched.
                    // Vblank/global draw-bank changes affect subsequent packets.
                    packet_draw_address<=draw_address;
                    rs_tx<=packet[0][9] ? {11'b0,packet[6][4:0],packet[5]} : 32'd0;
                    rs_ty<=packet[0][9] ? {11'b0,packet[8][4:0],packet[7]} : 32'd0;
                    rs_txdx<=packet[0][10] ? {11'b0,packet[10][4:0],packet[9]} : 32'd512;
                    rs_tydx<=packet[0][10] ? {11'b0,packet[12][4:0],packet[11]} : 32'd0;
                    rs_txdy<=packet[0][10] ? {11'b0,packet[14][4:0],packet[13]} : 32'd0;
                    rs_tydy<=packet[0][10] ? {11'b0,packet[16][4:0],packet[15]} : 32'd512;
                    if(packet[0][11]) begin
                        src_color<={packet[18][7:0],packet[17]};src_blend<=packet[18][13:8];
                        dst_color<={packet[20][7:0],packet[19]};dst_blend<=packet[20][13:8];
                    end
                    if(packet[0][12]) shade_color<={packet[22][7:0],packet[21]};
                    if(packet[0][13]) trans_color<={packet[24][7:0],packet[23]};
                    if(packet[0][14]) begin
                        tile_offset<=packet[25];font_offset<=packet[26];palette_offset<=packet[27][15:3];
                        palette_bank<=packet[28][11:8];tiled<=packet[28][12];pixel_format<=packet[28][7:6];
                        texture_width<=11'd8<<packet[28][2:0];texture_height<=11'd8<<packet[28][5:3];
                        texture_x_mask<=(32'd8<<packet[28][2:0])-32'd1;
                        texture_y_mask<=(32'd8<<packet[28][5:3])-32'd1;
                        texture_width_shift<=4'd3+{1'b0,packet[28][2:0]};
                        texture_tile_shift<=packet[28][2:0];texture_size_configured<=1;
                    end
                    state<=PREP;
                end
                PREP: begin
                    start_x<=packet[1][9:0];x<=packet[1][9:0];y<=packet[2][8:0];end_x<=packet[3][9:0];end_y<=packet[4][8:0];
                    line_tx<=rs_tx;line_ty<=rs_ty;pixel_tx<=rs_tx;pixel_ty<=rs_ty;
                    if(packet[0][6] && (!palette_valid || palette_offset!=last_palette)) begin
                        if(|pc_match) begin
                            pal_slot<=pc_hit_slot;last_palette<=palette_offset;palette_valid<=1;state<=PIX_START;
                        end else begin
                            pal_fill_slot<=pal_victim;pal_slot<=pal_victim;pal_victim<=pal_victim+3'd1;
                            pc_valid[pal_victim]<=0;pal_load_snooped<=0;
                            palette_index<=0;rd_addr<={palette_offset,10'b0};rd_ret<=PAL_STORE;state<=RD_LOOKUP;
                        end
                    end else state<=PIX_START;
                end
                PAL_STORE: begin
                    if(palette_index==255) begin
                        last_palette<=palette_offset;palette_valid<=1;state<=PIX_START;
                        pc_offset[pal_fill_slot]<=palette_offset;pc_trans[pal_fill_slot]<=trans_color;
                        pc_valid[pal_fill_slot]<=!pal_load_snooped && !(SNOOP_COHERENT && snoop_valid && snoop_line[17:5]==palette_offset);
                    end
                    else begin
                        palette_index<=palette_index+8'd1;
                        rd_addr<={palette_offset,palette_index+8'd1,2'b0};
                        if(palette_index[2:0]!=3'd7) result_data<=rca_q[{palette_index[2:0]+3'd1,5'b0} +: 32];
                        else state<=RD_LOOKUP;
                    end
                end
                PIX_START: if(!packet[0][8] || end_x<start_x || end_y<y) state<=COMPLETE;
                else begin iterating<=1;state<=PIXELS;end
                PIXELS: if(front_empty && !tail_busy) state<=COMPLETE;
                else if(s10_stall) begin
                    // No alpha: wait for pend to post. Alpha line change: once the tail has
                    // stored its pixels, retire a modified line into pend, then load the
                    // destination (after pend posts if it holds that very line).
                    if(use_alpha && !tail_busy) begin
                        if(wc_dirty) begin
                            if(!pend_valid) begin
                                pend_valid<=1;pend_line<=wc_line;pend_data<=wc_data;pend_strobe<=wc_strobe;
                                wc_valid<=0;wc_loaded<=0;wc_strobe<='0;
                            end
                        end else if(pf_valid && pf_line==s10_line) begin
                            wc_data<=pf_data;wc_strobe<='0;wc_valid<=1;wc_loaded<=1;wc_line<=s10_line;
                            pf_valid<=0;pf_want<=next_line_exists;pf_target<=next_line;
                        end else if(!(nb_kind==2 && !pf_drop && pf_line==s10_line) && !(pend_valid && pend_line==s10_line)) begin
                            if(nb_kind==2 && !burst_done) pf_drop<=1;
                            pf_valid<=0;pf_want<=0;state<=DEST_LOAD;
                        end
                    end
                end else if(miss_b) begin rd_addr<={s7_addr[22:5],5'b0};pipe_fill<=1;fill_b<=1;state<=RD_FILL;end
                else if(miss_a) begin rd_addr<={s4_addr[22:5],5'b0};pipe_fill<=1;fill_b<=0;state<=RD_FILL;end
                RELOOK: begin pipe_fill<=0;fill_b<=0;state<=PIXELS;end
                DEST_LOAD: if(burst_ready) state<=DEST_WAIT;
                DEST_WAIT: if(burst_done) begin
                    if(burst_error) begin fault<=1;fault_address<=32'h04000000+{9'b0,s10_line,5'b0};state<=FAILED;end
                    else begin
                        wc_data<=burst_rdata;wc_strobe<='0;wc_valid<=1;wc_loaded<=1;wc_line<=s10_line;state<=PIXELS;
                        pf_want<=next_line_exists;pf_target<=next_line;
                    end
                end
                // The packet's last modified line is retired into pend (posted later, also
                // while idle); completion of posted writes is tracked by nb_kind. A prefetch
                // still in flight is dropped on arrival.
                COMPLETE: if(wc_dirty) begin
                    if(!pend_valid) begin
                        pend_valid<=1;pend_line<=wc_line;pend_data<=wc_data;pend_strobe<=wc_strobe;
                        wc_valid<=0;wc_loaded<=0;wc_strobe<='0;
                    end
                end else begin
                    wc_valid<=0;wc_loaded<=0;pf_valid<=0;pf_want<=0;if(nb_kind==2 && !burst_done) pf_drop<=1;
                    queue_rear<=queue_rear+11'd1;packets_completed<=packets_completed+32'd1;state<=IDLE;
                end
                default: ;
            endcase
            // A snooped texture write invalidates the line in both caches (tag-agnostic); it
            // wins over a fill completing on the same clock (that fill may hold old data).
            if(SNOOP_COHERENT && snoop_valid) begin
                rca_valid[snoop_line[RC_BITS-1:0]]<=0;rcb_valid[snoop_line[RC_BITS-1:0]]<=0;
                for(int i=0;i<8;i++) if(pc_offset[i]==snoop_line[17:5]) pc_valid[i]<=0;
                if(state==PAL_STORE || state==RD_LOOKUP || state==RD_CHECK || state==RD_FILL || state==RD_FILL_WAIT)
                    if(snoop_line[17:5]==palette_offset) pal_load_snooped<=1;
            end
            if(nb_kind!=0 && burst_done && burst_error) begin
                fault<=1;fault_address<=32'h04000000+{9'b0,nb_kind==1 ? posted_line : pf_line,5'b0};state<=FAILED;
            end
            // Serialized MMIO after engine/vblank updates; byte strobes are authoritative.
            if(reg_valid && reg_ready && reg_write) case(reg_address)
                16'h0080: if(|reg_strobe[1:0]) begin
                    if(ORDERED_FRONT) begin cpu_front<=merged_front[10:0];front_wr<=1;front_wr_val<=merged_front; end
                    else queue_front<=merged_front[10:0];
                end
                16'h008c: if(reg_strobe[0]) begin control<=reg_data[7:0]&8'h8f;if(reg_data[3]) begin queue_front<=0;queue_rear<=0;cpu_front<=0;end end
                16'h0090: if(|reg_strobe[1:0]) bank1_select<=reg_data[15];
                16'h00a4: if(reg_strobe[2]) begin
                    if(reg_data[23:16]==1) flip_count<=(flip_now?flip_count-8'd1:flip_count)+8'd1;
                    else if(reg_data[23:16]==0) flip_count<=0;
                end
                default: ;
            endcase
        end
    end
endmodule

// 8 x 256-entry RGB565 palettes + opaque flag: one synchronous write, one registered read.
module vr0_palette_ram (
    input logic clk, write_enable, read_enable,
    input logic [10:0] write_address, read_address,
    input logic [16:0] write_data,
    output logic [16:0] read_data
);
    (* ramstyle = "M10K" *) logic [16:0] palette_mem [0:2047];
    always_ff @(posedge clk) begin
        if (write_enable) palette_mem[write_address] <= write_data;
        if (read_enable) read_data <= palette_mem[read_address];
    end
endmodule
