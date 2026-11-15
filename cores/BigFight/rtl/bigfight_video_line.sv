// Assemble one tagged Big Fight tile/sprite line into a held double-buffered
// 14-bit palette/shadow bank. All handshakes use clk_sys; no new clock exists.
module bigfight_video_line (
    input wire cyclwarr_i,
    input  logic         clk_sys,
    input  logic         cold_reset,

    input  logic         snapshot_req_i,
    output logic         snapshot_ready_o,
    input  logic [15:0]  sprite_control_e0_i,
    output logic         spram_req_o,
    input  logic         spram_ready_i,
    output logic [12:0]  spram_word_addr_o,
    input  logic         spram_valid_i,
    input  logic [15:0]  spram_data_i,

    input  logic         line_req_i,
    output logic         line_ready_o,
    input  logic [8:0]   line_y_i,
    input  logic [63:0]  scrollx0_i,
    input  logic [63:0]  scrollx_line_i,
    input  logic [63:0]  scrolly0_i,
    input  logic [63:0]  scrolly_line_i,
    input  logic [63:0]  page_select_i,
    input  logic [15:0]  tile_bank_i,
    input  logic [15:0]  mixing_control_i,

    output logic         tile_map_req_o,
    input  logic         tile_map_ready_i,
    output logic         tile_map_bank_o,
    output logic [14:0]  tile_map_addr_o,
    input  logic         tile_map_rsp_valid_i,
    output logic         tile_map_rsp_ready_o,
    input  logic [15:0]  tile_map_rsp_data_i,

    output logic         tile_gfx_req_o,
    input  logic         tile_gfx_ready_i,
    output logic [16:0]  tile_gfx_row_addr_o,
    input  logic         tile_gfx_rsp_valid_i,
    output logic         tile_gfx_rsp_ready_o,
    input  logic [23:0]  tile_gfx_rsp_data_i,

    output logic         tile_clut_req_o,
    input  logic         tile_clut_ready_i,
    output logic [16:0]  tile_clut_row_addr_o,
    input  logic         tile_clut_rsp_valid_i,
    output logic         tile_clut_rsp_ready_o,
    input  logic [63:0]  tile_clut_rsp_data_i,

    output logic         sprite_rom_req_o,
    input  logic         sprite_rom_ready_i,
    output logic         sprite_rom_bank_o,
    output logic [20:0]  sprite_rom_byte_addr_o,
    input  logic         sprite_rom_valid_i,
    input  logic [31:0]  sprite_rom_data_i,

    output logic         sprite_clut_req_o,
    input  logic         sprite_clut_ready_i,
    output logic [8:0]   sprite_clut_color_o,
    input  logic         sprite_clut_valid_i,
    input  logic [127:0] sprite_clut_bytes_i,

    output logic         line_done_valid_o,
    input  logic         line_done_ready_i,
    output logic         line_done_bank_o,
    output logic [8:0]   line_done_y_o,
    output logic         line_done_late_o,
    // Accepted line request through final combined RAM write.
    output logic [11:0]  line_done_cycles_o,
    // Tile scan-query/collector interval through the same final write.
    output logic [11:0]  line_done_collect_cycles_o,
    output logic [1:0]   line_bank_valid_o,
    output logic [8:0]   line_bank_y0_o,
    output logic [8:0]   line_bank_y1_o,
    output logic [1:0]   line_bank_late_o,
    input  logic         line_release_valid_i,
    output logic         line_release_ready_o,
    input  logic         line_release_bank_i,

    input  logic         scan_req_i,
    output logic         scan_ready_o,
    input  logic         scan_bank_i,
    input  logic [8:0]   scan_y_i,
    input  logic [8:0]   scan_x_i,
    output logic         scan_rsp_valid_o,
    input  logic         scan_rsp_ready_i,
    output logic         scan_rsp_reject_o,
    output logic         scan_rsp_bank_o,
    output logic [8:0]   scan_rsp_y_o,
    output logic [8:0]   scan_rsp_x_o,
    output logic [12:0]  scan_rsp_palette_o,
    output logic         scan_rsp_shadow_o,

    output logic         deadline_miss_o,
    output logic         protocol_fault_o
);
    localparam integer LINE_WIDTH = 320;
    localparam integer LINE_BUDGET = 3200;
    localparam integer SPRITE_SNAPSHOT_WORDS = 16'h0804;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WAIT_LINES,
        ST_TILE_QUERY,
        ST_PIXEL_PAIR,
        ST_RELEASE_SUBLINES,
        ST_FAULT
    } state_t;
    state_t state_q;

    logic [55:0] output_bank0 [0:LINE_WIDTH/4-1];
    logic [55:0] output_bank1 [0:LINE_WIDTH/4-1];
    logic [1:0] resident_valid_q;
    logic [8:0] resident_y0_q, resident_y1_q;
    logic [1:0] resident_late_q;

    logic snapshot_complete_q;
    logic snapshot_active_q;
    logic [11:0] snapshot_response_count_q;

    logic [8:0] active_y_q;
    logic [15:0] mixing_control_q;
    logic assemble_bank_q;
    logic tile_done_seen_q;
    logic tile_bank_q;
    logic [8:0] tile_y_q;
    logic [8:0] collect_x_q;
    logic [11:0] line_elapsed_q;
    logic [11:0] collector_elapsed_q;
    logic active_late_q;

    logic tile_line_req;
    logic tile_line_ready;
    logic tile_line_done_valid;
    logic tile_line_done_ready;
    logic tile_line_done_bank;
    logic [8:0] tile_line_done_y;
    logic tile_line_release_valid;
    logic tile_line_release_bank;
    logic tile_scan_req;
    logic tile_scan_ready;
    logic tile_scan_rsp_valid;
    logic tile_scan_rsp_ready;
    logic tile_scan_rsp_bank;
    logic [8:0] tile_scan_rsp_y, tile_scan_rsp_x;
    logic [51:0] tile_scan_pixels;

    logic sprite_snapshot_ready;
    logic sprite_line_req;
    logic sprite_line_ready;
    logic sprite_line_late;
    logic sprite_line_bank;
    logic [8:0] sprite_line_y;
    logic sprite_line_release;
    logic sprite_pixel_valid;
    logic sprite_pixel_ready;
    logic [8:0] sprite_pixel_x;
    logic [12:0] sprite_pixel_palette;
    logic [1:0] sprite_pixel_priority;
    logic sprite_pixel_shadow;
    logic sprite_pixel_opaque;

    wire [207:0] tile_quad;
    wire [55:0] sprite_quad_a,mixed_quad;
    wire [11:0] sprite_quad_b;
    logic mixed_shadow;
    logic [12:0] mixed_palette;

    wire line_accept = line_req_i && line_ready_o;
    wire line_bank_free = !resident_valid_q[0] || !resident_valid_q[1];
    wire free_bank = resident_valid_q[0];
    wire tile_done_take = tile_line_done_valid && tile_line_done_ready;
    wire tile_done_available = tile_done_seen_q || tile_line_done_valid;
    wire sprite_done_available = sprite_line_ready;
    wire scan_accept = scan_req_i && scan_ready_o;
    wire scan_tag_match = resident_valid_q[scan_bank_i] &&
                          ((scan_bank_i ? resident_y1_q : resident_y0_q) == scan_y_i) &&
                          (scan_x_i < LINE_WIDTH);
    wire pixel_pair_valid = tile_scan_rsp_valid && sprite_pixel_valid;
    wire pixel_tags_match = (tile_scan_rsp_bank == tile_bank_q) &&
                            (tile_scan_rsp_y == active_y_q) &&
                            (tile_scan_rsp_x == collect_x_q) &&
                            (sprite_pixel_x == collect_x_q) &&
                            (sprite_line_y == active_y_q);
    wire pixel_pair_take = (state_q == ST_PIXEL_PAIR) && pixel_pair_valid;
    wire final_pixel_write = pixel_pair_take && pixel_tags_match &&
                             (collect_x_q == LINE_WIDTH-4);
    wire [13:0] mixed_pixel = {mixed_shadow, mixed_palette};

    assign line_bank_valid_o = resident_valid_q;
    assign line_bank_y0_o = resident_y0_q;
    assign line_bank_y1_o = resident_y1_q;
    assign line_bank_late_o = resident_late_q;
    assign snapshot_ready_o = sprite_snapshot_ready;
    assign line_release_ready_o = resident_valid_q[line_release_bank_i];
    assign line_ready_o = (state_q == ST_IDLE) && line_bank_free &&
                          !line_done_valid_o && snapshot_complete_q &&
                          tile_line_ready && sprite_snapshot_ready &&
                          !snapshot_req_i && !protocol_fault_o;

    assign tile_line_req = line_accept;
    assign sprite_line_req = line_accept;
    assign tile_line_done_ready = (state_q == ST_WAIT_LINES);
    // 2026-10-22 collector pipelining: while pixel x is taken, query x+1 so the
    // collector assembles one pixel per clock instead of one per two clocks.
    wire pipelined_query = pixel_pair_take && pixel_tags_match &&
                           (collect_x_q != LINE_WIDTH-4);
    wire joined_lines_ready = (tile_done_seen_q || tile_done_take) &&
                              sprite_done_available;
    wire joined_lines_match =
        ((tile_done_seen_q ? tile_y_q : tile_line_done_y) == active_y_q) &&
        (sprite_line_y == active_y_q);
    wire first_scan_query = (state_q == ST_WAIT_LINES) &&
                            joined_lines_ready && joined_lines_match;
    wire first_scan_bank = first_scan_query && !tile_done_seen_q && tile_done_take
                         ? tile_line_done_bank : tile_bank_q;
    wire [8:0] scan_query_x = (state_q == ST_PIXEL_PAIR) ? collect_x_q + 9'd4 : collect_x_q;
    assign tile_scan_req = (state_q == ST_TILE_QUERY) || pipelined_query ||
                           first_scan_query;
    assign tile_scan_rsp_ready = pixel_pair_take;
    assign sprite_pixel_ready = pixel_pair_take;
    assign tile_line_release_valid = (state_q == ST_RELEASE_SUBLINES);
    assign tile_line_release_bank = tile_bank_q;
    assign sprite_line_release = (state_q == ST_RELEASE_SUBLINES);

    assign scan_ready_o = !scan_rsp_valid_o || scan_rsp_ready_i;

    bigfight_tile_scanline #(.QUAD_COLLECT(1)) u_tile (.cyclwarr_i(cyclwarr_i), 
        .clk(clk_sys), .cold_reset(cold_reset),
        .line_req(tile_line_req), .line_ready(tile_line_ready),
        .line_y_i(line_y_i), .scrollx0_i(scrollx0_i),
        .scrollx_line_i(scrollx_line_i), .scrolly0_i(scrolly0_i),
        .scrolly_line_i(scrolly_line_i), .page_select_i(page_select_i),
        .tile_bank_i(tile_bank_i),
        .map_req(tile_map_req_o), .map_ready(tile_map_ready_i),
        .map_bank(tile_map_bank_o), .map_addr(tile_map_addr_o),
        .map_rsp_valid(tile_map_rsp_valid_i),
        .map_rsp_ready(tile_map_rsp_ready_o), .map_rsp_data(tile_map_rsp_data_i),
        .gfx_req(tile_gfx_req_o), .gfx_ready(tile_gfx_ready_i),
        .gfx_row_addr(tile_gfx_row_addr_o), .gfx_rsp_valid(tile_gfx_rsp_valid_i),
        .gfx_rsp_ready(tile_gfx_rsp_ready_o), .gfx_rsp_data(tile_gfx_rsp_data_i),
        .clut_req(tile_clut_req_o), .clut_ready(tile_clut_ready_i),
        .clut_row_addr(tile_clut_row_addr_o), .clut_rsp_valid(tile_clut_rsp_valid_i),
        .clut_rsp_ready(tile_clut_rsp_ready_o), .clut_rsp_data(tile_clut_rsp_data_i),
        .line_done_valid(tile_line_done_valid), .line_done_ready(tile_line_done_ready),
        .line_done_bank(tile_line_done_bank), .line_done_y(tile_line_done_y),
        .line_release_valid(tile_line_release_valid),
        .line_release_bank(tile_line_release_bank),
        .scan_req(tile_scan_req), .scan_ready(tile_scan_ready),
        .scan_bank(first_scan_query ? first_scan_bank : tile_bank_q),
        .scan_y(active_y_q), .scan_x(scan_query_x),
        .scan_rsp_valid(tile_scan_rsp_valid), .scan_rsp_ready(tile_scan_rsp_ready),
        .scan_rsp_bank(tile_scan_rsp_bank), .scan_rsp_y(tile_scan_rsp_y),
        .scan_rsp_x(tile_scan_rsp_x), .scan_pixels(tile_scan_pixels), .scan_quad_pixels(tile_quad),
        .deadline_check(1'b0), .deadline_y(9'b0), .deadline_miss()
    );

    bigfight_sprite_scanline #(.QUAD_COLLECT(1)) u_sprite (
        // Both games use word 5 for signed shear; Big Fight uses it on held items.
        .affine_enable_i(1'b1),
        .clk(clk_sys), .reset(cold_reset),
        .snapshot_req_i(snapshot_req_i), .snapshot_ready_o(sprite_snapshot_ready),
        .sprite_control_e0_i(sprite_control_e0_i),
        .spram_req_o(spram_req_o), .spram_ready_i(spram_ready_i),
        .spram_word_addr_o(spram_word_addr_o), .spram_valid_i(spram_valid_i),
        .spram_data_i(spram_data_i),
        .line_req_i(sprite_line_req), .line_y_i(line_y_i),
        .line_ready_o(sprite_line_ready), .line_late_o(sprite_line_late),
        .line_bank_o(sprite_line_bank), .line_y_o(sprite_line_y),
        .line_release_i(sprite_line_release), .pixel_valid_o(sprite_pixel_valid),
        .pixel_ready_i(sprite_pixel_ready), .pixel_x_o(sprite_pixel_x),
        .pixel_quad_a_o(sprite_quad_a),.pixel_quad_b_o(sprite_quad_b),
        .pixel_palette_o(sprite_pixel_palette),
        .pixel_priority_o(sprite_pixel_priority),
        .pixel_shadow_o(sprite_pixel_shadow), .pixel_opaque_o(sprite_pixel_opaque),
        .rom_req_o(sprite_rom_req_o), .rom_ready_i(sprite_rom_ready_i),
        .rom_bank_o(sprite_rom_bank_o), .rom_byte_addr_o(sprite_rom_byte_addr_o),
        .rom_valid_i(sprite_rom_valid_i), .rom_data_i(sprite_rom_data_i),
        .clut_req_o(sprite_clut_req_o), .clut_ready_i(sprite_clut_ready_i),
        .clut_color_o(sprite_clut_color_o), .clut_valid_i(sprite_clut_valid_i),
        .clut_bytes_i(sprite_clut_bytes_i)
    );

    bigfight_pixel_mixer quad_mix0(.tile_pixels(tile_quad[0+:52]),
    .sprite_opaque(sprite_quad_a[13]),.sprite_palette(sprite_quad_a[0+:13]),
    .sprite_shadow(sprite_quad_b[0]),.shadow_inverse(mixing_control_q[0]),
    .palette_index(mixed_quad[0+:13]),.palette_shadow(mixed_quad[13]));
    bigfight_pixel_mixer quad_mix1(.tile_pixels(tile_quad[52+:52]),
    .sprite_opaque(sprite_quad_a[27]),.sprite_palette(sprite_quad_a[14+:13]),
    .sprite_shadow(sprite_quad_b[3]),.shadow_inverse(mixing_control_q[0]),
    .palette_index(mixed_quad[14+:13]),.palette_shadow(mixed_quad[27]));
    bigfight_pixel_mixer quad_mix2(.tile_pixels(tile_quad[104+:52]),
    .sprite_opaque(sprite_quad_a[41]),.sprite_palette(sprite_quad_a[28+:13]),
    .sprite_shadow(sprite_quad_b[6]),.shadow_inverse(mixing_control_q[0]),
    .palette_index(mixed_quad[28+:13]),.palette_shadow(mixed_quad[41]));
    bigfight_pixel_mixer quad_mix3(.tile_pixels(tile_quad[156+:52]),
    .sprite_opaque(sprite_quad_a[55]),.sprite_palette(sprite_quad_a[42+:13]),
    .sprite_shadow(sprite_quad_b[9]),.shadow_inverse(mixing_control_q[0]),
    .palette_index(mixed_quad[42+:13]),.palette_shadow(mixed_quad[55]));
    bigfight_pixel_mixer u_mixer (
        .tile_pixels(tile_scan_pixels),
        .sprite_opaque(sprite_pixel_opaque),
        .sprite_palette(sprite_pixel_palette),
        .sprite_shadow(sprite_pixel_shadow),
        .shadow_inverse(mixing_control_q[0]),
        .palette_index(mixed_palette),
        .palette_shadow(mixed_shadow)
    );

    always_ff @(posedge clk_sys) begin
        if (!cold_reset && pixel_pair_take && pixel_tags_match) begin
            if (assemble_bank_q)
                output_bank1[collect_x_q[8:2]] <= mixed_quad;
            else
                output_bank0[collect_x_q[8:2]] <= mixed_quad;
        end
    end

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            state_q <= ST_IDLE;
            resident_valid_q <= 2'b00;
            resident_y0_q <= 9'b0;
            resident_y1_q <= 9'b0;
            resident_late_q <= 2'b00;
            snapshot_complete_q <= 1'b0;
            snapshot_active_q <= 1'b0;
            snapshot_response_count_q <= 12'b0;
            active_y_q <= 9'b0;
            mixing_control_q <= 16'b0;
            assemble_bank_q <= 1'b0;
            tile_done_seen_q <= 1'b0;
            tile_bank_q <= 1'b0;
            tile_y_q <= 9'b0;
            collect_x_q <= 9'b0;
            line_elapsed_q <= 12'b0;
            collector_elapsed_q <= 12'b0;
            active_late_q <= 1'b0;
            line_done_valid_o <= 1'b0;
            line_done_bank_o <= 1'b0;
            line_done_y_o <= 9'b0;
            line_done_late_o <= 1'b0;
            line_done_cycles_o <= 12'b0;
            line_done_collect_cycles_o <= 12'b0;
            scan_rsp_valid_o <= 1'b0;
            scan_rsp_reject_o <= 1'b0;
            scan_rsp_bank_o <= 1'b0;
            scan_rsp_y_o <= 9'b0;
            scan_rsp_x_o <= 9'b0;
            scan_rsp_palette_o <= 13'b0;
            scan_rsp_shadow_o <= 1'b0;
            deadline_miss_o <= 1'b0;
            protocol_fault_o <= 1'b0;
        end else begin
            if (snapshot_req_i && snapshot_ready_o) begin
                snapshot_complete_q <= 1'b0;
                snapshot_active_q <= 1'b1;
                snapshot_response_count_q <= 12'b0;
            end else if (snapshot_active_q && spram_valid_i) begin
                if (snapshot_response_count_q == SPRITE_SNAPSHOT_WORDS-1) begin
                    snapshot_active_q <= 1'b0;
                    snapshot_complete_q <= 1'b1;
                end else begin
                    snapshot_response_count_q <= snapshot_response_count_q + 1'b1;
                end
            end

            if (line_done_valid_o && line_done_ready_i)
                line_done_valid_o <= 1'b0;

            if (line_release_valid_i && line_release_ready_o)
                resident_valid_q[line_release_bank_i] <= 1'b0;

            if (scan_accept) begin
                scan_rsp_valid_o <= 1'b1;
                scan_rsp_bank_o <= scan_bank_i;
                scan_rsp_y_o <= scan_y_i;
                scan_rsp_x_o <= scan_x_i;
                if (scan_tag_match) begin
                    scan_rsp_reject_o <= 1'b0;
                    if (scan_bank_i)
                        {scan_rsp_shadow_o, scan_rsp_palette_o} <= output_bank1[scan_x_i[8:2]][14*scan_x_i[1:0]+:14];
                    else
                        {scan_rsp_shadow_o, scan_rsp_palette_o} <= output_bank0[scan_x_i[8:2]][14*scan_x_i[1:0]+:14];
                end else begin
                    scan_rsp_reject_o <= 1'b1;
                    scan_rsp_shadow_o <= 1'b0;
                    scan_rsp_palette_o <= 13'b0;
                end
            end else if (scan_rsp_valid_o && scan_rsp_ready_i) begin
                scan_rsp_valid_o <= 1'b0;
            end

            if (state_q != ST_IDLE && state_q != ST_RELEASE_SUBLINES && state_q != ST_FAULT) begin
                if (line_elapsed_q < LINE_BUDGET)
                    line_elapsed_q <= line_elapsed_q + 1'b1;
                if (line_elapsed_q >= LINE_BUDGET) begin
                    active_late_q <= 1'b1;
                    deadline_miss_o <= 1'b1;
                end
            end

            if ((state_q == ST_TILE_QUERY || state_q == ST_PIXEL_PAIR) &&
                collector_elapsed_q != 12'hfff)
                collector_elapsed_q <= collector_elapsed_q + 1'b1;

            if (final_pixel_write) begin
                line_done_cycles_o <= line_elapsed_q + 1'b1;
                line_done_collect_cycles_o <= collector_elapsed_q + 1'b1;
            end

            case (state_q)
                ST_IDLE: begin
                    if (line_accept) begin
                        state_q <= ST_WAIT_LINES;
                        active_y_q <= line_y_i;
                        mixing_control_q <= mixing_control_i;
                        assemble_bank_q <= free_bank;
                        tile_done_seen_q <= 1'b0;
                        tile_bank_q <= 1'b0;
                        tile_y_q <= 9'b0;
                        collect_x_q <= 9'b0;
                        line_elapsed_q <= 12'b0;
                        collector_elapsed_q <= 12'b0;
                        active_late_q <= 1'b0;
                        line_done_cycles_o <= 12'b0;
                        line_done_collect_cycles_o <= 12'b0;
                    end
                end

                ST_WAIT_LINES: begin
                    if (tile_done_take) begin
                        if (tile_line_done_y != active_y_q) begin
                            protocol_fault_o <= 1'b1;
                            state_q <= ST_FAULT;
                        end else begin
                            tile_done_seen_q <= 1'b1;
                            tile_bank_q <= tile_line_done_bank;
                            tile_y_q <= tile_line_done_y;
                        end
                    end
                    if (sprite_done_available && sprite_line_y != active_y_q) begin
                        protocol_fault_o <= 1'b1;
                        state_q <= ST_FAULT;
                    end
                    if ((tile_done_seen_q || tile_done_take) && sprite_done_available) begin
                        if ((tile_done_seen_q ? tile_y_q : tile_line_done_y) != active_y_q ||
                            sprite_line_y != active_y_q) begin
                            protocol_fault_o <= 1'b1;
                            state_q <= ST_FAULT;
                        end else begin
                            collect_x_q <= 9'b0;
                            // Issue pixel zero on the producer-join edge when
                            // the tile line is already scan-ready. This removes
                            // one idle collector clock without changing the
                            // one-cycle response/tag contract.
                            if (first_scan_query && tile_scan_ready)
                                state_q <= ST_PIXEL_PAIR;
                            else
                                state_q <= ST_TILE_QUERY;
                        end
                    end
                end

                ST_TILE_QUERY: begin
                    if (tile_scan_req && tile_scan_ready)
                        state_q <= ST_PIXEL_PAIR;
                end

                ST_PIXEL_PAIR: begin
                    if (pixel_pair_take) begin
                        if (!pixel_tags_match) begin
                            protocol_fault_o <= 1'b1;
                            state_q <= ST_FAULT;
                        end else if (collect_x_q == LINE_WIDTH-4) begin
                            if (active_late_q || line_elapsed_q >= LINE_BUDGET) begin
                                resident_late_q[assemble_bank_q] <= 1'b1;
                                line_done_late_o <= 1'b1;
                                deadline_miss_o <= 1'b1;
                            end else begin
                                resident_late_q[assemble_bank_q] <= 1'b0;
                                line_done_late_o <= 1'b0;
                            end
                            state_q <= ST_RELEASE_SUBLINES;
                        end else begin
                            collect_x_q <= collect_x_q + 9'd4;
                            if (tile_scan_ready)
                                state_q <= ST_PIXEL_PAIR;
                            else
                                state_q <= ST_TILE_QUERY;
                        end
                    end
                end

                ST_RELEASE_SUBLINES: begin
                    resident_valid_q[assemble_bank_q] <= 1'b1;
                    if (assemble_bank_q)
                        resident_y1_q <= active_y_q;
                    else
                        resident_y0_q <= active_y_q;
                    line_done_valid_o <= 1'b1;
                    line_done_bank_o <= assemble_bank_q;
                    line_done_y_o <= active_y_q;
                    state_q <= ST_IDLE;
                end

                ST_FAULT: begin
                    state_q <= ST_FAULT;
                end

                default: begin
                    protocol_fault_o <= 1'b1;
                    state_q <= ST_FAULT;
                end
            endcase
        end
    end
endmodule
