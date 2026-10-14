// Video-side mirror of the 315-5292 character RAM. Keeping the CPU-visible
// copy in SDRAM is useful for the two 68000 buses, but making the scanline
// renderer cross the SDRAM CDC/arbitration path for every character row can
// miss a 656-pixel line deadline on FPGA. The original device has a local
// character-RAM display port, so mirror CPU writes into four 16-bit M10K banks
// and read one aligned 64-bit row pair per renderer clock here.
module s24_char_video_ram (
    input  logic        clk,
    input  logic        wr_en,
    input  logic [15:0] wr_addr,
    input  logic [15:0] wr_data,
    input  logic [1:0]  wr_be,
    input  logic [13:0] rd_addr,
    output logic [63:0] rd_data
);
`ifdef VERILATOR
    logic [15:0] mem [0:65535];
    logic [15:0] q0,q1,q2,q3;
    integer init_word;
    initial begin
        for (init_word=0; init_word<65536; init_word=init_word+1)
            mem[init_word] = 16'h0000;
    end
    always_ff @(posedge clk) begin
        q0 <= mem[{rd_addr,2'b00}];
        q1 <= mem[{rd_addr,2'b01}];
        q2 <= mem[{rd_addr,2'b10}];
        q3 <= mem[{rd_addr,2'b11}];
        if (wr_en) begin
            if (wr_be[0]) mem[wr_addr][7:0]  <= wr_data[7:0];
            if (wr_be[1]) mem[wr_addr][15:8] <= wr_data[15:8];
        end
    end
    assign rd_data = {q3,q2,q1,q0};
`else
    logic [15:0] bank_q [0:3];
    genvar bank;
    generate
        for (bank=0; bank<4; bank=bank+1) begin : g_bank
            localparam logic [1:0] BANK_INDEX = bank[1:0];
            altsyncram ram (
                // Keep the video port in the same read-on-port-A/write-on-
                // port-B form as the proven sprite RAMs.  In particular,
                // this makes the registered read latency explicit instead
                // of relying on a write-capable port with rden_a disabled.
                .clock0(clk), .address_a(rd_addr), .data_a(16'h0000),
                .wren_a(1'b0), .q_a(bank_q[bank]),
                .clock1(clk), .address_b(wr_addr[15:2]), .data_b(wr_data),
                .wren_b(wr_en && wr_addr[1:0] == BANK_INDEX), .q_b(),
                .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
                .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(wr_be),
                .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
                .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b0)
            );
            defparam
                ram.operation_mode = "BIDIR_DUAL_PORT",
                ram.width_a = 16,
                ram.width_b = 16,
                ram.widthad_a = 14,
                ram.widthad_b = 14,
                ram.numwords_a = 16384,
                ram.numwords_b = 16384,
                ram.ram_block_type = "M10K",
                ram.intended_device_family = "Cyclone V",
                ram.lpm_type = "altsyncram",
                // UNREGISTERED, not CLOCK0.  altsyncram always registers
                // address_a, so CLOCK0 adds a SECOND register and makes the
                // synthesized read 2 clocks while the `ifdef VERILATOR model
                // above (q0 <= mem[..]) is 1 clock.  The consumer pipeline is
                // built for 1 clock, so on real hardware every character's
                // pixel bits arrived one clock after the tile/mask/scroll
                // metadata they pair with -- full-screen corruption on the
                // FPGA that simulation could never show.
                ram.outdata_reg_a = "UNREGISTERED",
                ram.read_during_write_mode_mixed_ports = "OLD_DATA",
                ram.width_byteena_a = 1,
                ram.width_byteena_b = 2,
                ram.power_up_uninitialized = "FALSE";
        end
    endgenerate
    assign rd_data = {bank_q[3],bank_q[2],bank_q[1],bank_q[0]};
`endif
endmodule

// Sega 315-5292 four-layer tile generator. Tile/control RAM and the
// video-facing character-RAM mirror are local. The inactive line is rendered
// ahead into a double-buffer, leaving deterministic time for all four layers.
module s24_tile (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce_pixel,
    input  logic [9:0]  hcount,
    input  logic [9:0]  vcount,
    input  logic        cpu_wr,
    input  logic [14:0] cpu_addr,
    input  logic [15:0] cpu_din,
    input  logic [1:0]  cpu_be,
    input  logic        char_wr,
    input  logic [15:0] char_addr,
    input  logic [15:0] char_din,
    input  logic [1:0]  char_be,
    // Flicker-blend support. Several System 24 titles obtain translucency by
    // toggling a tilemap's disable bit (vscroll bit 15) every frame, so the
    // 24 kHz CRT integrates two 57.5 Hz fields into one half-intensity image.
    // Bonanza Bros does this for the projector light shaft and the stage
    // intro card. On a fixed-pixel display that reads as a 28.75 Hz flicker
    // instead. With blend_en set, a layer detected as toggling is rendered on
    // every frame and reported in layer_blink so the mixer can also resolve
    // the "layer absent" pixel; the two are averaged downstream.
    input  logic        blend_en,
    output logic [3:0]  layer_blink,
    output logic [15:0] cpu_dout,
    output logic [11:0] layer0_pixel,
    output logic [11:0] layer1_pixel,
    output logic [11:0] layer2_pixel,
    output logic [11:0] layer3_pixel,
    output logic        layer0_cat,
    output logic        layer1_cat,
    output logic        layer2_cat,
    output logic        layer3_cat,
    output logic        layer0_valid,
    output logic        layer1_valid,
    output logic        layer2_valid,
    output logic        layer3_valid
);
    import s24_pkg::*;

    // The CPU-visible 32K-word RAM has a synchronous video read port. Keep
    // byte lanes separate so Quartus infers byte-enabled true dual-port M10Ks.
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] tile_ram_lo [0:32767];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] tile_ram_hi [0:32767];
    // Replicate only the small video-facing upper regions. Both copies use
    // synchronous video reads so their paths terminate in M10K output
    // registers instead of long asynchronous MLAB muxes.
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] line_scroll_issue_lo [0:2047];
    // Only scroll bits 9:8 are consumed by the renderer. Store those two
    // bits directly instead of carrying six dead high-byte bits through an
    // inferred RAM that Quartus later removes.
    (* ramstyle = "M10K, no_rw_check" *) logic [1:0] line_scroll_issue_hi [0:2047];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] mask_ram_lo [0:4095];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] mask_ram_hi [0:4095];
    logic [15:0] control_regs [0:7];

    function automatic logic [15:0] control_reg_value(
        input logic [2:0] index
    );
        case (index)
            3'd0: control_reg_value = control_regs[0];
            3'd1: control_reg_value = control_regs[1];
            3'd2: control_reg_value = control_regs[2];
            3'd3: control_reg_value = control_regs[3];
            3'd4: control_reg_value = control_regs[4];
            3'd5: control_reg_value = control_regs[5];
            3'd6: control_reg_value = control_regs[6];
            3'd7: control_reg_value = control_regs[7];
            default: control_reg_value = 16'h0000;
        endcase
    endfunction
    // Preserve the verification bench's diagnostic hierarchy without putting
    // this redundant array into the synthesized design.
    // synthesis translate_off
    logic [15:0] tile_ram [0:32767];
    // synthesis translate_on
    // A line entry retains validity separately from its raw palette/pen value.
    // Pen zero is transparent to the normal priority pass, but MAME's opaque
    // backdrop pass still needs color zero from the selected tile's palette.
    //
    // Masked spans are deliberately skipped to meet the scanline deadline.
    // Tag every written entry with the generation of the bank being filled so
    // an untouched cell can never resurrect content from an older line. A
    // ten-bit generation outlives a complete one-cell-per-fill bank scrub.
    localparam integer LINE_GEN_WIDTH = 10;
    localparam integer LINE_WIDTH = LINE_GEN_WIDTH + 14;

    // The Verilator/RTL test backdoor keeps the line stores visible to the
    // focused ownership tests.  Quartus uses the packed true-dual-port
    // ALTSYNCRAMs below, so this array is simulation-only and cannot consume
    // FPGA resources.
`ifndef SYNTHESIS
    logic [LINE_WIDTH-1:0] line0 [0:1023];
    logic [LINE_WIDTH-1:0] line1 [0:1023];
    logic [LINE_WIDTH-1:0] line2 [0:1023];
    logic [LINE_WIDTH-1:0] line3 [0:1023];
`endif

    // MAME's 315-5292 device clears both character and tile RAM at device
    // start. Give the local tile/control RAM and scanline stores deterministic
    // power-on contents. An initial image maps to M10K startup data and avoids
    // a 32K-cycle reset scrub or reset mux on every RAM bit.
    integer ram_init0,ram_init1,ram_init2,ram_init3;
    integer ram_init4,ram_init5,ram_init6,ram_init7;
    initial for (ram_init0=0; ram_init0<4096; ram_init0=ram_init0+1) begin
        tile_ram_lo[ram_init0] = 8'h00;
        tile_ram_hi[ram_init0] = 8'h00;
    end
    initial for (ram_init1=4096; ram_init1<8192; ram_init1=ram_init1+1) begin
        tile_ram_lo[ram_init1] = 8'h00;
        tile_ram_hi[ram_init1] = 8'h00;
    end
    initial for (ram_init2=8192; ram_init2<12288; ram_init2=ram_init2+1) begin
        tile_ram_lo[ram_init2] = 8'h00;
        tile_ram_hi[ram_init2] = 8'h00;
    end
    initial for (ram_init3=12288; ram_init3<16384; ram_init3=ram_init3+1) begin
        tile_ram_lo[ram_init3] = 8'h00;
        tile_ram_hi[ram_init3] = 8'h00;
    end
    initial for (ram_init4=16384; ram_init4<20480; ram_init4=ram_init4+1) begin
        tile_ram_lo[ram_init4] = 8'h00;
        tile_ram_hi[ram_init4] = 8'h00;
    end
    initial for (ram_init5=20480; ram_init5<24576; ram_init5=ram_init5+1) begin
        tile_ram_lo[ram_init5] = 8'h00;
        tile_ram_hi[ram_init5] = 8'h00;
    end
    initial for (ram_init6=24576; ram_init6<28672; ram_init6=ram_init6+1) begin
        tile_ram_lo[ram_init6] = 8'h00;
        tile_ram_hi[ram_init6] = 8'h00;
    end
    initial for (ram_init7=28672; ram_init7<32768; ram_init7=ram_init7+1) begin
        tile_ram_lo[ram_init7] = 8'h00;
        tile_ram_hi[ram_init7] = 8'h00;
    end

    integer small_ram_init;
    initial begin
        for (small_ram_init=0; small_ram_init<2048;
             small_ram_init=small_ram_init+1) begin
            line_scroll_issue_lo[small_ram_init] = 8'h00;
            line_scroll_issue_hi[small_ram_init] = 2'b00;
        end
        for (small_ram_init=0; small_ram_init<4096;
             small_ram_init=small_ram_init+1) begin
            mask_ram_lo[small_ram_init] = 8'h00;
            mask_ram_hi[small_ram_init] = 8'h00;
        end
    end

    integer shadow_init;
    // synthesis translate_off
    initial begin
        for (shadow_init=0; shadow_init<32768; shadow_init=shadow_init+1)
            tile_ram[shadow_init] = 16'h0000;
    end
    // synthesis translate_on

    integer control_init;
    initial begin
        for (control_init=0; control_init<8; control_init=control_init+1)
            control_regs[control_init] = 16'h0000;
    end

    logic render_active;
    logic pipeline_advance, line_stage_valid;
    logic [1:0] render_layer, issue_line_layer;
    logic [8:0] render_x, render_y;
    logic [15:0] tile_word, mask_word, line_scroll_word;
    logic [14:0] tile_addr, mask_addr;
    always_ff @(posedge clk) begin
        cpu_dout <= {tile_ram_hi[cpu_addr],tile_ram_lo[cpu_addr]};
        if (pipeline_advance) begin
            line_scroll_word <= {
                6'b0, line_scroll_issue_hi[{issue_line_layer,render_y}],
                line_scroll_issue_lo[{issue_line_layer,render_y}]
            };
            if (line_stage_valid) begin
                tile_word <= {tile_ram_hi[tile_addr],tile_ram_lo[tile_addr]};
                mask_word <= {mask_ram_hi[mask_addr[11:0]],
                              mask_ram_lo[mask_addr[11:0]]};
            end
        end
        if (cpu_wr) begin
            if (cpu_be[0]) tile_ram_lo[cpu_addr] <= cpu_din[7:0];
            if (cpu_be[1]) tile_ram_hi[cpu_addr] <= cpu_din[15:8];
            if (cpu_addr >= 15'h4000 && cpu_addr < 15'h4800) begin
                if (cpu_be[0]) begin
                    line_scroll_issue_lo[cpu_addr[10:0]] <= cpu_din[7:0];
                end
                if (cpu_be[1]) begin
                    line_scroll_issue_hi[cpu_addr[10:0]] <= cpu_din[9:8];
                end
            end
            if ((cpu_addr >= 15'h6000 && cpu_addr < 15'h66a0) ||
                (cpu_addr >= 15'h6800 && cpu_addr < 15'h6ea0)) begin
                if (cpu_be[0]) mask_ram_lo[cpu_addr[11:0]] <= cpu_din[7:0];
                if (cpu_be[1]) mask_ram_hi[cpu_addr[11:0]] <= cpu_din[15:8];
            end
            if (cpu_addr >= 15'h5000 && cpu_addr < 15'h5008)
                control_regs[cpu_addr[2:0]]
                    <= merge16(control_regs[cpu_addr[2:0]],cpu_din,cpu_be);
            // synthesis translate_off
            tile_ram[cpu_addr] <= merge16(tile_ram[cpu_addr],cpu_din,cpu_be);
            // synthesis translate_on
        end
    end

    logic display_bank, fill_bank;
    logic [9:0] line_read_addr;
    logic [13:0] line0_q,line1_q,line2_q,line3_q;
    logic [LINE_GEN_WIDTH-1:0] line0_gen_q,line1_gen_q;
    logic [LINE_GEN_WIDTH-1:0] line2_gen_q,line3_gen_q;
    logic [LINE_WIDTH-1:0] line_data_q [0:3];
    logic [LINE_GEN_WIDTH-1:0] fill_generation;
    logic [LINE_GEN_WIDTH-1:0] bank_generation [0:1];
    logic [8:0] bank_line_y [0:1];
    logic [8:0] bank_scrub [0:1];
    logic [1:0] bank_complete;
    logic [1:0] bank_epoch;
    logic fill_epoch,frame_epoch;
    logic line_sample_bank;
    logic [8:0] expected_line_y;
    logic sample_line_ready;
    logic line0_fresh,line1_fresh,line2_fresh,line3_fresh;
    logic cache_valid;
    logic [11:0] cache_char;
    logic [2:0] cache_row;
    logic [31:0] cache_bits;
    logic [11:0] request_char;
    logic [2:0] request_row;
    logic request_row_odd;
    logic char_read_pending;
    logic [63:0] char_read_data;

    assign line_sample_bank = (hcount == 10'd655)
                              ? ~display_bank : display_bank;
    assign line_read_addr = {line_sample_bank,
                             (hcount == 10'd655)
                             ? 9'd0 : hcount[8:0]+1'd1};
    assign expected_line_y = (hcount == 10'd655)
                             ? ((vcount >= 10'd423)
                                ? 9'd0 : vcount[8:0]+1'd1)
                             : vcount[8:0];
    assign sample_line_ready = bank_complete[line_sample_bank]
                               && bank_line_y[line_sample_bank]
                                  == expected_line_y
                               && bank_epoch[line_sample_bank] == frame_epoch
                               && !(render_active
                                    && fill_bank == line_sample_bank);
    assign line0_fresh = sample_line_ready && line0_q[13]
                         && line0_gen_q == bank_generation[line_sample_bank];
    assign line1_fresh = sample_line_ready && line1_q[13]
                         && line1_gen_q == bank_generation[line_sample_bank];
    assign line2_fresh = sample_line_ready && line2_q[13]
                         && line2_gen_q == bank_generation[line_sample_bank];
    assign line3_fresh = sample_line_ready && line3_q[13]
                         && line3_gen_q == bank_generation[line_sample_bank];

    logic [8:0] source_x, source_y;
    logic selected, disabled;
    logic mask_bit;
    logic [11:0] wanted_char;
    logic [2:0] wanted_row;
    logic [3:0] wanted_pen;
    logic [11:0] wanted_pixel;
    logic [9:0] line_index;
    logic lookup_valid;
    logic renderer_can_advance, fast_skip;

    s24_char_video_ram character_ram (
        .clk(clk),.wr_en(char_wr),.wr_addr(char_addr),.wr_data(char_din),
        .wr_be(char_be),.rd_addr({wanted_char,wanted_row[2:1]}),
        .rd_data(char_read_data));
    logic [1:0] lookup_layer_q;
    logic [8:0] lookup_x_q;
    logic [8:0] lookup_source_x_q,lookup_source_y_q;
    logic [1:0] lookup_ctrl_mode_q;
    logic lookup_disabled_q;
    // synthesis translate_off
    logic [14:0] lookup_tile_addr_q,lookup_mask_addr_q;
    // synthesis translate_on
    logic [1:0] issue_layer, issue_pair_even_layer, issue_fetch_layer;
    logic [8:0] issue_x;
    logic [15:0] issue_hscr_word, issue_vscr_word, issue_ctrl_word;
    logic [1:0] issue_ctrl_mode;
    logic [8:0] issue_source_x, issue_source_y;
    logic [9:0] issue_neg_vscroll;
    logic issue_chosen_odd;
    logic [1:0] line_layer_q;
    logic [8:0] line_x_q, line_render_y_q;
    logic [15:0] line_hscr_q, line_vscr_q;
    logic [1:0] line_ctrl_mode_q;
    logic [9:0] next_render_y;

    // Per-frame view of each physical tilemap's disable bit, plus a saturating
    // run length of consecutive frame-to-frame changes. Requiring two changes
    // in a row keeps an ordinary one-off enable/disable transition from
    // briefly engaging the blend; a 28.75 Hz square wave saturates it at once
    // and a layer that stops toggling clears it on the very next frame.
    logic [3:0] disable_prev;
    logic [1:0] toggle_run [0:3];
    logic [3:0] blink_layer;
    logic issue_blink, line_blink_q;
    integer frame_layer;

    assign layer_blink = blend_en ? blink_layer : 4'b0000;

    function automatic logic blink_of(input logic [1:0] index);
        case (index)
            2'd0: blink_of = blink_layer[0];
            2'd1: blink_of = blink_layer[1];
            2'd2: blink_of = blink_layer[2];
            default: blink_of = blink_layer[3];
        endcase
    endfunction

    // Coordinate and window selection are a direct streaming form of MAME's
    // draw_common(). A mask bit of one selects the odd layer in each pair.
    always_comb begin
        // tile_word and mask_word are synchronous RAM outputs. Consume them
        // only with metadata registered on the same edge as their addresses;
        // live render/control signals may already describe the next pixel.
        mask_bit = mask_word[15-lookup_x_q[6:3]];

        // In normal mode the window RAM selects the physical tilemap within
        // each pair.  MAME draw_rect() inverts the mask for the odd physical
        // map, so a zero chooses the even map and a one chooses the odd map.
        // Tile-word bit 15 is an independent mixer category and must not take
        // part in window selection (Crack Down's radar uses both values).
        selected = (lookup_ctrl_mode_q == 0)
                   ? (mask_bit == lookup_layer_q[0])
                   : !lookup_layer_q[0];
        disabled = lookup_disabled_q;
        source_x = lookup_source_x_q;
        source_y = lookup_source_y_q;

        wanted_char = tile_word[11:0];
        wanted_row = source_y[2:0];
        // MAME's STEP8(0,4) layout is MS-nibble first within each 16-bit
        // character-RAM word. Preserve the two-word left-to-right order for
        // an eight-pixel row while reversing the four nibble positions inside
        // each word: 1234_5678 renders as pens 1,2,3,4,5,6,7,8.
        wanted_pen = cache_bits[{source_x[2],~source_x[1:0],2'b00} +: 4];
        wanted_pixel = {tile_word[14:7],wanted_pen};
        line_index = {fill_bank,lookup_x_q};

        // A whole transparent eight-pixel selection span needs no writes.
        // Generation matching rejects any older entry left in that span,
        // preserving one-write-per-port RAM inference and the line budget.
        fast_skip = lookup_valid && (disabled || !selected)
                    && lookup_x_q[2:0] == 0
                    && lookup_x_q <= 9'd488;

        renderer_can_advance = lookup_valid && render_active && !char_read_pending
                               && (disabled || !selected
                                   || (cache_valid
                                       && cache_char == wanted_char
                                       && cache_row == wanted_row));
        pipeline_advance = render_active && !char_read_pending
                           && (!lookup_valid || renderer_can_advance);

        // The line-scroll stage is the tail of the two-entry lookup pipeline.
        // Advance from that tail, rather than from the renderer head, so the
        // synchronous line-scroll and tile/mask stages remain one pixel apart.
        issue_layer = line_stage_valid ? line_layer_q : render_layer;
        issue_x = line_stage_valid ? line_x_q : render_x;
        if (line_stage_valid && line_x_q == 9'd495
            && line_layer_q != 2'd3) begin
            issue_layer = line_layer_q + 1'd1;
            issue_x = 0;
        end else if (line_stage_valid && line_x_q != 9'd495) begin
            issue_x = line_x_q + 1'd1;
        end

        // Form the line-scroll request while the current pixel is consumed.
        // The matching control metadata is registered with the synchronous
        // RAM result below.
        issue_pair_even_layer = {issue_layer[1],1'b0};
        // MAME's draw_common() indexes scroll by the physical tilemap after
        // the category pass is folded out: maps 0/1/2/3 use 5000/5001/5002/
        // 5003 and 5004/5005/5006/5007 respectively. Only special modes
        // below collapse the selected physical map onto the even member of
        // its pair, matching MAME's early return for the odd map.
        issue_hscr_word = control_reg_value({1'b0,issue_layer});
        issue_vscr_word = control_regs[3'd4 + issue_layer];
        issue_ctrl_word = control_regs[3'd4 + {issue_layer[1],1'b0}];
        issue_ctrl_mode = issue_ctrl_word[14:13];
        issue_line_layer = (issue_ctrl_mode == 0) ? issue_layer
                                                  : issue_pair_even_layer;
        // The blink flag follows exactly the scroll word whose bit 15 the
        // renderer would have obeyed, so the special modes keep using the
        // even member of the pair here too.
        issue_blink = blend_en && blink_of(issue_layer);
        if (issue_ctrl_mode != 0) begin
            issue_hscr_word =
                control_reg_value({1'b0,issue_pair_even_layer});
            issue_vscr_word =
                control_regs[3'd4 + issue_pair_even_layer];
            issue_blink = blend_en && blink_of(issue_pair_even_layer);
        end

        // Consume the preceding line-scroll result and its registered
        // metadata to form the synchronous tile and mask requests.
        issue_fetch_layer = line_layer_q;
        issue_source_x = line_x_q - line_hscr_q[8:0];
        issue_source_y = line_render_y_q + line_vscr_q[8:0];
        issue_neg_vscroll = 0;
        issue_chosen_odd = 0;

        if (line_ctrl_mode_q == 0) begin
            if (line_hscr_q[15])
                issue_source_x = line_x_q - line_scroll_word[8:0];
        end else begin
            issue_source_x = line_x_q
                             - (line_hscr_q[15]
                                ? line_scroll_word[8:0]
                                : line_hscr_q[8:0]);
            issue_source_y = line_render_y_q + line_vscr_q[8:0];
            // MAME chooses the mode-1 physical map from bit 9 of the full
            // ten-bit negated scroll value. Source Y still wraps at 9 bits.
            issue_neg_vscroll = 10'd0 - line_vscr_q[9:0];
            if (line_ctrl_mode_q == 1)
                issue_chosen_odd = !issue_neg_vscroll[9]
                                   ^ (line_render_y_q
                                      >= issue_neg_vscroll[8:0]);
            else
                issue_chosen_odd =
                    !(line_hscr_q[15] ? line_scroll_word[9]
                                      : line_hscr_q[9])
                    ^ (line_x_q >= (line_hscr_q[15]
                                    ? line_scroll_word[8:0]
                                    : line_hscr_q[8:0]));
            issue_fetch_layer = {line_layer_q[1],issue_chosen_odd};
        end

        tile_addr = {1'b0,issue_fetch_layer,
                     issue_source_y[8:3],issue_source_x[8:3]};
        mask_addr = (line_layer_q[1] ? 15'h6800 : 15'h6000)
                    + {4'd0,line_render_y_q,2'b00}
                    + {13'd0,line_x_q[8:7]};
        next_render_y = (vcount >= 10'd422)
                      ? vcount - 10'd422
                      : vcount + 10'd2;
    end

    task automatic advance_renderer;
        begin
            if (lookup_x_q == 9'd495) begin
                render_x <= 0;
                cache_valid <= 1'b0;
                if (lookup_layer_q == 2'd3) begin
                    render_active <= 1'b0;
                    bank_complete[fill_bank]
                        <= fill_epoch == frame_epoch;
                end
                else render_layer <= lookup_layer_q + 1'd1;
            end else render_x <= lookup_x_q + 1'd1;
        end
    endtask

    task automatic advance_renderer_skip;
        begin
            if (lookup_x_q >= 9'd488) begin
                render_x <= 0;
                cache_valid <= 1'b0;
                if (lookup_layer_q == 2'd3) begin
                    render_active <= 1'b0;
                    bank_complete[fill_bank]
                        <= fill_epoch == frame_epoch;
                end
                else render_layer <= lookup_layer_q + 1'd1;
            end else render_x <= lookup_x_q + 9'd8;
            // Discard metadata already issued for the skipped span and
            // restart the synchronous lookup pipeline at the next boundary.
            lookup_valid <= 1'b0;
            line_stage_valid <= 1'b0;
        end
    endtask

    logic [13:0] line_write_value;
    logic line_write_fire, line_scrub_fire;
    logic [9:0] line_write_addr;

    assign line_write_value = {1'b1,tile_word[15],wanted_pixel};
    // The explicit RAM write enables mirror the sequential renderer branches
    // below. Keeping the request combinational lets the RAM see it on the same
    // edge that advances the renderer, rather than one clock later.
    assign line_write_fire = render_active && !char_read_pending
                             && lookup_valid
                             && !disabled && selected
                             && cache_valid && cache_char == wanted_char
                             && cache_row == wanted_row;
    assign line_scrub_fire = ce_pixel && hcount == 10'd655
                             && !render_active
                             && ((vcount >= 10'd422) || (vcount < 10'd382));
    assign line_write_addr = line_scrub_fire
                            ? {display_bank,bank_scrub[display_bank]}
                            : line_index;

    // Port A is display-read-only. Port B renders or performs one bounded
    // scrub write into a non-displayed bank. Keep the 14-bit pixel payload and
    // 10-bit generation tag in the same 24-bit RAM word so each layer has one
    // explicit placed memory interface; the current fit uses three M10Ks per
    // layer and preserves the existing read/write cadence.
`ifdef SYNTHESIS
    genvar line_bank;
    generate
        for (line_bank=0; line_bank<4; line_bank=line_bank+1) begin : g_line_ram
            localparam logic [1:0] LINE_INDEX = line_bank[1:0];
            altsyncram line_ram (
                .clock0(clk), .address_a(line_read_addr), .data_a(24'h000000),
                .wren_a(1'b0), .q_a(line_data_q[line_bank]),
                .clock1(clk), .address_b(line_write_addr),
                .data_b(line_scrub_fire ? 24'h000000
                                        : {fill_generation,line_write_value}),
                .wren_b(line_scrub_fire ||
                        (line_write_fire && lookup_layer_q == LINE_INDEX)),
                .q_b(), .aclr0(1'b0), .aclr1(1'b0),
                .addressstall_a(1'b0), .addressstall_b(1'b0),
                .byteena_a(1'b1), .byteena_b(1'b1),
                .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
                .clocken3(1'b1), .eccstatus(), .rden_a(1'b1),
                .rden_b(1'b0)
            );
            defparam
                line_ram.operation_mode = "BIDIR_DUAL_PORT",
                line_ram.width_a = LINE_WIDTH,
                line_ram.width_b = LINE_WIDTH,
                line_ram.widthad_a = 10,
                line_ram.widthad_b = 10,
                line_ram.numwords_a = 1024,
                line_ram.numwords_b = 1024,
                line_ram.ram_block_type = "M10K",
                line_ram.intended_device_family = "Cyclone V",
                line_ram.lpm_type = "altsyncram",
                line_ram.outdata_reg_a = "UNREGISTERED",
                line_ram.read_during_write_mode_mixed_ports = "OLD_DATA",
                line_ram.width_byteena_a = 1,
                line_ram.width_byteena_b = 1,
                line_ram.power_up_uninitialized = "FALSE";
        end
    endgenerate
`else
    integer line_init;
    initial begin
        for (line_init=0; line_init<1024; line_init=line_init+1) begin
            line0[line_init] = '0;
            line1[line_init] = '0;
            line2[line_init] = '0;
            line3[line_init] = '0;
        end
    end

    // Match the packed ALTSYNCRAM's registered read and old-data
    // read-during-write behavior for simulation and focused regressions.
    always @(posedge clk) begin
        line_data_q[0] <= line0[line_read_addr];
        line_data_q[1] <= line1[line_read_addr];
        line_data_q[2] <= line2[line_read_addr];
        line_data_q[3] <= line3[line_read_addr];
        if (line_scrub_fire) begin
            line0[line_write_addr] <= '0;
            line1[line_write_addr] <= '0;
            line2[line_write_addr] <= '0;
            line3[line_write_addr] <= '0;
        end else if (line_write_fire) begin
            case (lookup_layer_q)
                2'd0: line0[line_write_addr] <= {fill_generation,line_write_value};
                2'd1: line1[line_write_addr] <= {fill_generation,line_write_value};
                2'd2: line2[line_write_addr] <= {fill_generation,line_write_value};
                default: line3[line_write_addr] <= {fill_generation,line_write_value};
            endcase
        end
    end
`endif

    assign line0_q = line_data_q[0][13:0];
    assign line1_q = line_data_q[1][13:0];
    assign line2_q = line_data_q[2][13:0];
    assign line3_q = line_data_q[3][13:0];
    assign line0_gen_q = line_data_q[0][LINE_WIDTH-1 -: LINE_GEN_WIDTH];
    assign line1_gen_q = line_data_q[1][LINE_WIDTH-1 -: LINE_GEN_WIDTH];
    assign line2_gen_q = line_data_q[2][LINE_WIDTH-1 -: LINE_GEN_WIDTH];
    assign line3_gen_q = line_data_q[3][LINE_WIDTH-1 -: LINE_GEN_WIDTH];

    always @(posedge clk) begin
        if (pipeline_advance) begin
            line_stage_valid <= 1'b1;
            line_layer_q <= issue_layer;
            line_x_q <= issue_x;
            line_render_y_q <= render_y;
            line_hscr_q <= issue_hscr_word;
            line_vscr_q <= issue_vscr_word;
            line_ctrl_mode_q <= issue_ctrl_mode;
            line_blink_q <= issue_blink;
            lookup_valid <= line_stage_valid;
            if (line_stage_valid) begin
                lookup_layer_q <= line_layer_q;
                lookup_x_q <= line_x_q;
                lookup_source_x_q <= issue_source_x;
                lookup_source_y_q <= issue_source_y;
                lookup_ctrl_mode_q <= line_ctrl_mode_q;
                // A blinking layer keeps rendering on the frames its disable
                // bit is set; the mixer supplies the matching "absent" pixel.
                lookup_disabled_q <= line_vscr_q[15] && !line_blink_q;
                // synthesis translate_off
                lookup_tile_addr_q <= tile_addr;
                lookup_mask_addr_q <= mask_addr;
                // synthesis translate_on
            end
        end
        if (reset) begin
            display_bank <= 0;
            fill_bank <= 1;
            fill_generation <= 0;
            bank_generation[0] <= 0;
            bank_generation[1] <= 0;
            bank_line_y[0] <= 0;
            bank_line_y[1] <= 0;
            bank_scrub[0] <= 0;
            bank_scrub[1] <= 0;
            bank_complete <= 0;
            bank_epoch <= 0;
            fill_epoch <= 0;
            frame_epoch <= 0;
            render_active <= 0;
            render_layer <= 0;
            render_x <= 0;
            render_y <= 0;
            lookup_valid <= 0;
            line_stage_valid <= 0;
            line_layer_q <= 0;
            line_x_q <= 0;
            line_render_y_q <= 0;
            line_hscr_q <= 0;
            line_vscr_q <= 0;
            line_ctrl_mode_q <= 0;
            line_blink_q <= 0;
            disable_prev <= 0;
            blink_layer <= 0;
            toggle_run[0] <= 0; toggle_run[1] <= 0;
            toggle_run[2] <= 0; toggle_run[3] <= 0;
            lookup_layer_q <= 0;
            lookup_x_q <= 0;
            lookup_source_x_q <= 0;
            lookup_source_y_q <= 0;
            lookup_ctrl_mode_q <= 0;
            lookup_disabled_q <= 0;
            // synthesis translate_off
            lookup_tile_addr_q <= 0;
            lookup_mask_addr_q <= 0;
            // synthesis translate_on
            cache_valid <= 0;
            cache_char <= 0;
            cache_row <= 0;
            cache_bits <= 0;
            request_char <= 0;
            request_row <= 0;
            request_row_odd <= 0;
            char_read_pending <= 0;
            layer0_pixel <= 0; layer1_pixel <= 0;
            layer2_pixel <= 0; layer3_pixel <= 0;
            layer0_cat <= 0; layer1_cat <= 0;
            layer2_cat <= 0; layer3_cat <= 0;
            layer0_valid <= 0; layer1_valid <= 0;
            layer2_valid <= 0; layer3_valid <= 0;
        end else begin
            // Display fetches use the deterministic local mirror; the SDRAM
            // tile port (formerly p1) was removed entirely -- it was never
            // driven to anything but zero.
            // The read address is one pixel ahead because hcount advances on
            // the same edge; the line RAM output is then stable for 3 clocks.
            if (ce_pixel) begin
                if (hcount == 10'd655) begin
                    // One sample per frame of every tilemap's disable bit, on
                    // the same 383->384 boundary the rest of the core uses as
                    // its frame epoch. A layer whose bit changed on this and
                    // the preceding frame boundary is treated as blinking.
                    if (vcount == 10'd383) begin
                        frame_epoch <= ~frame_epoch;
                        // frame_layer is a 32-bit integer loop variable; every
                        // index into a 4-entry array is sliced to [1:0]
                        // (bit-identical for the only values the loop bound
                        // 0..3 ever reaches) so no array is ever indexed by
                        // an unsliced 32-bit value. Quartus 17.0.2's Verific
                        // elaborator crashed (Fatal Error: Access Violation,
                        // freeing a VeriAggregateValue mid-elaboration of
                        // this exact for loop) when toggle_run alone was
                        // indexed unsliced while disable_prev/blink_layer/
                        // control_regs beside it were not -- reproduced twice
                        // on an otherwise-idle, uncontended system, always
                        // immediately on entering s24_tile elaboration.
                        for (frame_layer=0; frame_layer<4; frame_layer=frame_layer+1) begin
                            if (control_regs[3'd4 + frame_layer[1:0]][15]
                                != disable_prev[frame_layer[1:0]]) begin
                                if (toggle_run[frame_layer[1:0]] != 2'd3)
                                    toggle_run[frame_layer[1:0]]
                                        <= toggle_run[frame_layer[1:0]] + 2'd1;
                                blink_layer[frame_layer[1:0]]
                                    <= (toggle_run[frame_layer[1:0]] >= 2'd1);
                            end else begin
                                toggle_run[frame_layer[1:0]] <= 2'd0;
                                blink_layer[frame_layer[1:0]] <= 1'b0;
                            end
                            disable_prev[frame_layer[1:0]]
                                <= control_regs[3'd4 + frame_layer[1:0]][15];
                        end
                    end
                    display_bank <= ~display_bank;
                    if (line0_fresh)
                        {layer0_valid,layer0_cat,layer0_pixel}
                            <= line0_q[13:0];
                    else begin
                        layer0_valid <= 0; layer0_cat <= 0; layer0_pixel <= 0;
                    end
                    if (line1_fresh)
                        {layer1_valid,layer1_cat,layer1_pixel}
                            <= line1_q[13:0];
                    else begin
                        layer1_valid <= 0; layer1_cat <= 0; layer1_pixel <= 0;
                    end
                    if (line2_fresh)
                        {layer2_valid,layer2_cat,layer2_pixel}
                            <= line2_q[13:0];
                    else begin
                        layer2_valid <= 0; layer2_cat <= 0; layer2_pixel <= 0;
                    end
                    if (line3_fresh)
                        {layer3_valid,layer3_cat,layer3_pixel}
                            <= line3_q[13:0];
                    else begin
                        layer3_valid <= 0; layer3_cat <= 0; layer3_pixel <= 0;
                    end

                    // At the line boundary vcount still names the old line.
                    // Render the line after the one about to be displayed.
                    if (!render_active
                        && ((vcount >= 10'd422) || (vcount < 10'd382))) begin
                        fill_bank <= display_bank;
                        fill_generation
                            <= bank_generation[display_bank] + 1'd1;
                        bank_generation[display_bank]
                            <= bank_generation[display_bank] + 1'd1;
                        bank_line_y[display_bank] <= next_render_y[8:0];
                        bank_epoch[display_bank] <= frame_epoch;
                        bank_complete[display_bank] <= 1'b0;
                        fill_epoch <= frame_epoch;
                        bank_scrub[display_bank]
                            <= bank_scrub[display_bank] + 1'd1;
                        render_layer <= 0;
                        render_x <= 0;
                        render_y <= next_render_y[8:0];
                        render_active <= 1'b1;
                        lookup_valid <= 0;
                        line_stage_valid <= 0;
                        cache_valid <= 0;
                    end
                end else if (hcount < 10'd495) begin
                    if (line0_fresh)
                        {layer0_valid,layer0_cat,layer0_pixel}
                            <= line0_q[13:0];
                    else begin
                        layer0_valid <= 0; layer0_cat <= 0; layer0_pixel <= 0;
                    end
                    if (line1_fresh)
                        {layer1_valid,layer1_cat,layer1_pixel}
                            <= line1_q[13:0];
                    else begin
                        layer1_valid <= 0; layer1_cat <= 0; layer1_pixel <= 0;
                    end
                    if (line2_fresh)
                        {layer2_valid,layer2_cat,layer2_pixel}
                            <= line2_q[13:0];
                    else begin
                        layer2_valid <= 0; layer2_cat <= 0; layer2_pixel <= 0;
                    end
                    if (line3_fresh)
                        {layer3_valid,layer3_cat,layer3_pixel}
                            <= line3_q[13:0];
                    else begin
                        layer3_valid <= 0; layer3_cat <= 0; layer3_pixel <= 0;
                    end
                end else begin
                    layer0_pixel <= 0; layer1_pixel <= 0;
                    layer2_pixel <= 0; layer3_pixel <= 0;
                    layer0_cat <= 0; layer1_cat <= 0;
                    layer2_cat <= 0; layer3_cat <= 0;
                    layer0_valid <= 0; layer1_valid <= 0;
                    layer2_valid <= 0; layer3_valid <= 0;
                end
            end

            if (char_read_pending) begin
                char_read_pending <= 1'b0;
                cache_char <= request_char;
                cache_row <= request_row;
                cache_bits <= request_row_odd ? char_read_data[63:32]
                                              : char_read_data[31:0];
                cache_valid <= 1'b1;
            end else if (render_active) begin
                // synthesis translate_off
                if (lookup_valid &&
                    (lookup_layer_q != render_layer ||
                     lookup_x_q != render_x))
                    $fatal(1,
                        "tile lookup metadata drift layer/x %0d/%0d state %0d/%0d addr %h mask %h",
                        lookup_layer_q,lookup_x_q,render_layer,render_x,
                        lookup_tile_addr_q,lookup_mask_addr_q);
                // synthesis translate_on
                if (fast_skip) begin
                    advance_renderer_skip();
                end else if (lookup_valid && (disabled || !selected)) begin
                    advance_renderer();
                end else if (lookup_valid && cache_valid
                             && cache_char == wanted_char
                             && cache_row == wanted_row) begin
                    advance_renderer();
                end else if (lookup_valid) begin
                    request_char <= wanted_char;
                    request_row <= wanted_row;
                    request_row_odd <= wanted_row[0];
                    char_read_pending <= 1'b1;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if ((1 << LINE_GEN_WIDTH) <= 512)
            $fatal(1,"tile generation tag can wrap before bank scrub");
    end
    always @(posedge clk) begin
        if (!reset && render_active)
            assert(fill_bank != display_bank)
                else $fatal(1,"tile renderer owns displayed bank");
        if (!reset && sample_line_ready)
            assert(!(render_active && fill_bank == line_sample_bank))
                else $fatal(1,"tile display accepted in-flight bank");
    end
    // synthesis translate_on
endmodule
