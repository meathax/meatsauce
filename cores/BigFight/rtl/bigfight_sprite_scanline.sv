// SPDX-License-Identifier: GPL-2.0-or-later
// TZB315 command-list snapshot and scanline renderer for Big Fight.
// ROM and sprite-RAM service timing is supplied by the integrating board.
module bigfight_sprite_scanline #(parameter QUAD_COLLECT=0) (
    input wire affine_enable_i,
    input  logic        clk,
    input  logic        reset,

    input  logic        snapshot_req_i,
    output logic        snapshot_ready_o,
    input  logic [15:0] sprite_control_e0_i,
    output logic        spram_req_o,
    input  logic        spram_ready_i,
    output logic [12:0] spram_word_addr_o,
    input  logic        spram_valid_i,
    input  logic [15:0] spram_data_i,

    input  logic        line_req_i,
    input  logic [8:0]  line_y_i,
    output logic        line_ready_o,
    output logic        line_late_o,
    output logic        line_bank_o,
    output logic [8:0]  line_y_o,
    input  logic        line_release_i,
    output logic        pixel_valid_o,
    input  logic        pixel_ready_i,
    output logic [8:0]  pixel_x_o,
    output wire [55:0] pixel_quad_a_o,
    output wire [11:0] pixel_quad_b_o,
    output logic [12:0] pixel_palette_o,
    output logic [1:0]  pixel_priority_o,
    output logic        pixel_shadow_o,
    output logic        pixel_opaque_o,

    output logic        rom_req_o,
    input  logic        rom_ready_i,
    output logic        rom_bank_o,
    output logic [20:0] rom_byte_addr_o,
    input  logic        rom_valid_i,
    input  logic [31:0] rom_data_i,

    output logic        clut_req_o,
    input  logic        clut_ready_i,
    output logic [8:0]  clut_color_o,
    input  logic        clut_valid_i,
    // Raw bytes: byte 0 is [127:120], byte 15 is [7:0].
    // Bytes 0..7 are sprites_l, bytes 8..15 are sprites_h.
    input  logic [127:0] clut_bytes_i
);

    localparam integer SPRITE_WORDS = 16'h0804;
    localparam integer COMMANDS = 342;
    localparam integer LINE_WIDTH = 320;
    localparam integer LINE_CLOCK_BUDGET = 3200;

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_SNAPSHOT_REQ,
        ST_SNAPSHOT_WAIT,
        ST_LINE_CLEAR,
        ST_COMMAND,
        ST_ROM_REQ,
        ST_ROM_WAIT,
        ST_CLUT_REQ,
        ST_CLUT_WAIT,
        ST_ROW_CHECK,
        ST_ROW_NEXT,
        ST_TILE_SETUP,
        ST_TILE_SKIP,
        ST_TILE_DRAW,
        ST_PF_WAIT,
        ST_LINE_DONE,
        ST_AFFINE
    } state_t;

    localparam logic [1:0] ROM_HEADER = 2'd0;
    localparam logic [1:0] ROM_ROW    = 2'd1;
    localparam logic [1:0] ROM_TILE   = 2'd2;

    state_t state_q;
    // Command words and the line buffer are block RAMs (2026-10-22 area
    // repair). Each RAM is read every clock at the *next* value of its
    // registered index, so cmd_wN_q / line_*_q equal the former asynchronous
    // array reads at command_index_q / scanout_x_q on every cycle they are used.
    // Word 5 was never read. Under Verilator the former arrays are kept as a
    // shadow and every consumed read is asserted equal.
    logic [15:0] command_ram0 [0:COMMANDS-1];
    logic [15:0] command_ram1 [0:COMMANDS-1];
    logic [15:0] command_ram2 [0:COMMANDS-1];
    logic [15:0] command_ram3 [0:COMMANDS-1];
    logic [15:0] command_ram4 [0:COMMANDS-1];
    logic [15:0] command_ram5 [0:COMMANDS-1];
    // Registered copy of (state_q == ST_AFFINE): keeps the state decode off the
    // sprite -> ROM arbiter request path. Set on entry, cleared on exit.
    logic        affine_state_q;
    logic [15:0] cmd_w0_q, cmd_w1_q, cmd_w2_q, cmd_w3_q, cmd_w4_q, cmd_w5_q;
    logic [8:0]  cmd_rd_idx, cmd_rd_idx_q;
    logic [15:0] cmd_a0_q, cmd_a1_q, cmd_a2_q, cmd_a3_q, cmd_a4_q, cmd_a5_q;
    logic [15:0] cmd_b0_q, cmd_b1_q, cmd_b2_q, cmd_b3_q, cmd_b4_q, cmd_b5_q;
    logic [15:0] command_ram0b [0:COMMANDS-1];
    logic [15:0] command_ram1b [0:COMMANDS-1];
    logic [15:0] command_ram2b [0:COMMANDS-1];
    logic [15:0] command_ram3b [0:COMMANDS-1];
    logic [15:0] command_ram4b [0:COMMANDS-1];
    logic [15:0] command_ram5b [0:COMMANDS-1];
    logic [8:0]  snap_index;
    logic [2:0]  snap_lane;
    logic        snap_we;
    logic [11:0] snapshot_word_count_q;
    logic        snapshot_bank_q;
    logic        snapshot_valid_q;
    wire         line_start_accept = (state_q == ST_IDLE) && line_req_i &&
                                     snapshot_valid_q && !line_ready_o;

    logic [8:0]  clear_x_q;
    logic [8:0]  command_index_q;
    logic [8:0]  line_y_q;
    logic        line_bank_q;
    // Four column-interleaved line RAMs (bank = x mod 4): up to four columns
    // are cleared or drawn per clock (2026-10-23 throughput repair).
    logic [13:0] line_a_q;
    logic [2:0]  line_b_q;
    logic [8:0]  line_rd_x_q;
    logic [13:0] lb_a_q [0:3];
    logic [2:0]  lb_b_q [0:3];
    logic        draw_active;
    logic [2:0]  draw_lanes;
    logic [9:0]  draw_remaining;
    logic [8:0]  lane_base;
    logic [8:0]  lane_x [0:3];
    logic        lane_a_we [0:3];
    logic        lane_b_we [0:3];
    logic [13:0] lane_a_wdata [0:3];
    logic [2:0]  lane_b_wdata [0:3];
    logic        bank_a_we [0:3];
    logic        bank_b_we [0:3];
    logic [6:0]  bank_addr [0:3];
    logic [13:0] bank_a_wdata [0:3];
    logic [2:0]  bank_b_wdata [0:3];
    logic [8:0]  scanout_x_q;
    logic [12:0] line_elapsed_q;
    logic        line_late_q;

    logic [15:0] sprite_index_q;
    logic [8:0]  sprite_color_q;
    logic        sprite_flip_x_q;
    logic        sprite_flip_y_q;
    logic [8:0]  sprite_scale_raw_q;
    logic [8:0] sprite_rotation_q;
    logic [17:0] sprite_scale_q;   // raw[8:0] << 9; raw >= 0x100 needs bit 17
    logic signed [31:0] sprite_x_q;
    logic signed [31:0] render_y_q;
    logic signed [31:0] tile_x_q;
    logic [8:0]  row_width_q;
    logic [7:0]  row_x_offset_q;
    logic [15:0] row_base_q;
    logic [8:0]  tile_number_q;
    logic [16:0] tile_base2_q;
    logic [5:0]  row_number_q;
    logic signed [10:0] rows_remaining_q;
    logic [7:0]  source_y_q;
    logic [8:0]  tile_screen_width_q;
    logic signed [10:0] tile_screen_x_q;
    logic [8:0]  draw_x_q;
    logic [8:0]  draw_end_x_q;
    logic [31:0] tile_row_bits_q;
    logic [20:0] dx_q;
    logic [127:0] clut_bytes_q;
    // 2026-10-23 throughput: the sprite CLUT fetch runs in parallel with the
    // row-word/tile fetches. Drawing waits for it; the next command waits until
    // it completes (clut_color_o = sprite_color_q must hold until accepted).
    logic        clut_req_q, clut_wait_q;
    wire         clut_busy = clut_req_q || clut_wait_q;

    logic [1:0]  rom_purpose_q;
    logic [20:0] rom_address_q;
    logic        rom_bank_q;
    logic [15:0] clut_word_q;
    logic [15:0] scale_word_q;
    logic [20:0] block_size_q;
    logic [8:0]  geometry_width;
    logic [8:0]  geometry_height;
    logic signed [31:0] geometry_x;
    logic signed [31:0] geometry_y;
    logic [31:0] pixel_x_offset;
    logic [31:0] pixel_source_x_fixed;
    logic signed [5:0] pixel_source_index;
    logic [3:0]  decoded_pen;
    logic [3:0]  clut_byte_index;
    logic [7:0]  mapped_palette_byte;
    logic [31:0] lane_fixed [0:3];
    logic [3:0]  lane_pen [0:3];
    logic [7:0]  lane_byte [0:3];
    logic signed [31:0] line_delta_y;
    logic [20:0] dy_fixed;
    logic [31:0] source_y_fixed;
    logic [20:0] source_pixel_fixed;
    logic [4:0]  source_x_bit_base;

    function automatic [8:0] extent_for(input logic [31:0] position,
                                         input logic [17:0] scale);
        logic [21:0] total;
        begin
            // MAME: ((ssx & 0xffff) + 8*scale) >> 16, 0..32 for scale <= 0x3fe00.
            total = {6'b0, position[15:0]} + {1'b0, scale, 3'b000};
            extent_for = {3'b0, total[21:16]};
        end
    endfunction

    // Exact 5x21-bit product in 32 bits (operands are 0..31 and <=2^19).
    function automatic [31:0] m5(input logic [4:0] a, input logic [20:0] b);
        m5 = {27'd0, a} * {11'd0, b};
    endfunction

    // Subtract source indices before multiplication. Six signed bits preserve
    // every difference of two unsigned five-bit indices, including clipping.
    // The signed 28-bit product is exact for the full 21-bit step range.
    function automatic [31:0] source_product(input logic signed [5:0] a,
                                            input logic [20:0] b);
        logic signed [27:0] product;
        begin
            product = a * $signed({1'b0, b});
            source_product = {{4{product[27]}}, product};
        end
    endfunction

    // Pen of the source pixel at fixed-point position f (former inline decode).
    function automatic [3:0] pen_at(input logic [31:0] f, input logic [31:0] bits);
        begin
            case (f[31:16])
                3'd0: pen_at = bits[23:20];
                3'd1: pen_at = bits[19:16];
                3'd2: pen_at = bits[31:28];
                3'd3: pen_at = bits[27:24];
                3'd4: pen_at = bits[7:4];
                3'd5: pen_at = bits[3:0];
                3'd6: pen_at = bits[15:12];
                3'd7: pen_at = bits[11:8];
                default: pen_at = 4'b0;
            endcase
        end
    endfunction
    function automatic [7:0] clut_at(input logic [3:0] pen, input logic [127:0] cb);
        logic [3:0] idx;
        begin
            idx = {pen[2], pen[3], (pen[1:0] ^ 2'b01)};
            clut_at = cb[127 - (idx * 8) -: 8];
        end
    endfunction

    // 524288/extent. extent_for() yields total[21:16], so every caller's extent
    // is 0..32 (2026-10-23: 32 reached by raw scale >= 0x1f9); a 33-entry table replaces the former combinational divider
    // (2026-10-23 timing repair, values identical for all reachable inputs).
    function automatic [20:0] fixed_step(input logic [8:0] extent);
        begin
            case (extent[5:0])
                6'd1: fixed_step = 21'd524288;
                6'd2: fixed_step = 21'd262144;
                6'd3: fixed_step = 21'd174762;
                6'd4: fixed_step = 21'd131072;
                6'd5: fixed_step = 21'd104857;
                6'd6: fixed_step = 21'd87381;
                6'd7: fixed_step = 21'd74898;
                6'd8: fixed_step = 21'd65536;
                6'd9: fixed_step = 21'd58254;
                6'd10: fixed_step = 21'd52428;
                6'd11: fixed_step = 21'd47662;
                6'd12: fixed_step = 21'd43690;
                6'd13: fixed_step = 21'd40329;
                6'd14: fixed_step = 21'd37449;
                6'd15: fixed_step = 21'd34952;
                6'd16: fixed_step = 21'd32768;
                6'd17: fixed_step = 21'd30840;
                6'd18: fixed_step = 21'd29127;
                6'd19: fixed_step = 21'd27594;
                6'd20: fixed_step = 21'd26214;
                6'd21: fixed_step = 21'd24966;
                6'd22: fixed_step = 21'd23831;
                6'd23: fixed_step = 21'd22795;
                6'd24: fixed_step = 21'd21845;
                6'd25: fixed_step = 21'd20971;
                6'd26: fixed_step = 21'd20164;
                6'd27: fixed_step = 21'd19418;
                6'd28: fixed_step = 21'd18724;
                6'd29: fixed_step = 21'd18078;
                6'd30: fixed_step = 21'd17476;
                6'd31: fixed_step = 21'd16912;
                6'd32: fixed_step = 21'd16384;
                default: fixed_step = 21'd0;
            endcase
        end
    endfunction

    always @* begin
        geometry_width  = extent_for(tile_x_q, sprite_scale_q);
        geometry_height = extent_for(render_y_q, sprite_scale_q);
        geometry_x      = $signed(tile_x_q) >>> 16;
        geometry_y      = $signed(render_y_q) >>> 16;

        // Both operands must be signed before extension: an unsigned destination
        // otherwise zero-extends the negative clipped tile origin.
        pixel_x_offset = $signed({23'b0,draw_x_q}) -
                         $signed({{21{tile_screen_x_q[10]}},tile_screen_x_q});
        if (sprite_flip_x_q)
            pixel_source_index = {1'b0, (5'(tile_screen_width_q - 1'b1))} -
                                 {1'b0, pixel_x_offset[4:0]};
        else
            pixel_source_index = {1'b0, pixel_x_offset[4:0]};
        pixel_source_x_fixed = source_product(pixel_source_index, dx_q);

        case (pixel_source_x_fixed[31:16])
            3'd0: source_x_bit_base = 5'd8;
            3'd1: source_x_bit_base = 5'd12;
            3'd2: source_x_bit_base = 5'd0;
            3'd3: source_x_bit_base = 5'd4;
            3'd4: source_x_bit_base = 5'd24;
            3'd5: source_x_bit_base = 5'd28;
            3'd6: source_x_bit_base = 5'd16;
            default: source_x_bit_base = 5'd20;
        endcase
        decoded_pen = 4'b0;
        if (pixel_source_x_fixed[31:16] < 8) begin
            decoded_pen[3] = tile_row_bits_q[31 - source_x_bit_base];
            decoded_pen[2] = tile_row_bits_q[30 - source_x_bit_base];
            decoded_pen[1] = tile_row_bits_q[29 - source_x_bit_base];
            decoded_pen[0] = tile_row_bits_q[28 - source_x_bit_base];
        end
        clut_byte_index = {decoded_pen[2], decoded_pen[3],
                           (decoded_pen[1:0] ^ 2'b01)};
        mapped_palette_byte = clut_bytes_q[127 - (clut_byte_index * 8) -: 8];

        // Lanes k = 0..3 (draw_x_q + k): offset+k changes the product by +/-k*dx.
        for (int k = 0; k < 4; k++) begin
            if (sprite_flip_x_q)
                lane_fixed[k] = pixel_source_x_fixed - 32'(k) * {11'd0, dx_q};
            else
                lane_fixed[k] = pixel_source_x_fixed + 32'(k) * {11'd0, dx_q};
            lane_pen[k] = pen_at(lane_fixed[k], tile_row_bits_q);
            lane_byte[k] = clut_at(lane_pen[k], clut_bytes_q);
        end

        line_delta_y = $signed({1'b0, line_y_q}) - geometry_y;
        dy_fixed = fixed_step(geometry_height);
        if (sprite_flip_y_q)
            source_y_fixed = ((geometry_height - 1'b1) * dy_fixed) -
                             (line_delta_y * dy_fixed);
        else
            source_y_fixed = line_delta_y * dy_fixed;
        source_pixel_fixed = source_y_fixed[31:16];
    end

    assign snapshot_ready_o = (state_q == ST_IDLE) && !line_ready_o;
    assign spram_req_o = (state_q == ST_SNAPSHOT_REQ);
    assign spram_word_addr_o = (snapshot_bank_q ? 13'h1000 : 13'h0000) +
                               {1'b0,snapshot_word_count_q};
    // 2026-10-23 tile-row prefetch: while a tile is drawn, the next tile's
    // row word is requested on the same port. Sprite ROM is read-only, so a
    // held word is reused only on an exact {bank,address} match; the main FSM
    // issues its own request only after any prefetch transaction has drained.
    logic        pf_req_q, pf_pending_q, pf_valid_q, pf_bank_q;
    logic [20:0] pf_addr_q;
    logic [31:0] pf_data_q;
    logic        header_prefetch_started_q, prefetched_response_q;
    wire pf_matches_main = pf_valid_q && (pf_bank_q == rom_bank_q) &&
                           (pf_addr_q == rom_address_q);
    wire [31:0] rom_response_data = prefetched_response_q ? pf_data_q : rom_data_i;
    wire main_rom_req = (state_q == ST_ROM_REQ) && !pf_req_q && !pf_pending_q &&
                        !pf_matches_main;
    logic affine_done, affine_rom_req, affine_rom_bank, affine_pixel_valid;
    logic [20:0] affine_rom_addr;
    logic [8:0] affine_pixel_x;
    logic [3:0] affine_pen;
    assign rom_req_o = (affine_state_q) ? affine_rom_req : main_rom_req || pf_req_q;
    assign rom_bank_o = (affine_state_q) ? affine_rom_bank : pf_req_q ? pf_bank_q : rom_bank_q;
    assign rom_byte_addr_o = (affine_state_q) ? affine_rom_addr : pf_req_q ? pf_addr_q : rom_address_q;
    // Next tile (tile_number_q+1) of the current row; its source row index is
    // the current row's (render_y and scale are constant across the row).
    wire [16:0] pf_next_base = tile_base2_q + 1'b1;
    wire        pf_next_exists = (tile_number_q + 1'b1 < row_width_q);
    wire [7:0] affine_palette = clut_at(affine_pen, clut_bytes_q);
    wire affine_write = affine_state_q && affine_pixel_valid && !clut_busy;
    wire affine_start = affine_enable_i && sprite_rotation_q != 0 &&
        state_q == ST_ROM_WAIT && rom_purpose_q == ROM_HEADER &&
        (rom_valid_i || prefetched_response_q) &&
        ({1'b0,rom_response_data[15:8]} > {1'b0,rom_response_data[31:27],3'b0});
    bigfight_affine_scanline affine (
        .clk(clk),.reset(reset),.start(affine_start),.done(affine_done),
        .index_i(sprite_index_q),.x_i(cmd_w2_q),.y_i(cmd_w3_q),
        .scale_i(sprite_scale_raw_q),.rotation_i(sprite_rotation_q),.line_i(line_y_q),
        .flip_x_i(sprite_flip_x_q),.flip_y_i(sprite_flip_y_q),.header_i(rom_response_data),
        .rom_req(affine_rom_req),.rom_bank(affine_rom_bank),.rom_addr(affine_rom_addr),
        .rom_ready(rom_ready_i && affine_state_q),
        .rom_valid(rom_valid_i && affine_state_q),.rom_data(rom_data_i),
        .pixel_valid(affine_pixel_valid),.pixel_ready(!clut_busy && affine_state_q),
        .pixel_x(affine_pixel_x),.pixel_pen(affine_pen));
    assign clut_req_o = clut_req_q;
    assign clut_color_o = sprite_color_q;
    assign pixel_valid_o = line_ready_o && (scanout_x_q < LINE_WIDTH);
    assign pixel_x_o = scanout_x_q;
    assign line_a_q = QUAD_COLLECT ? pixel_quad_a_o[13:0] : lb_a_q[scanout_x_q[1:0]];
    assign line_b_q = QUAD_COLLECT ? pixel_quad_b_o[2:0] : lb_b_q[scanout_x_q[1:0]];
    assign cmd_rd_idx = (state_q == ST_LINE_CLEAR) ? 9'd0 : command_index_q;
    wire cmd_sel_b = (command_index_q != cmd_rd_idx_q);
    assign cmd_w0_q = cmd_sel_b ? cmd_b0_q : cmd_a0_q;
    assign cmd_w1_q = cmd_sel_b ? cmd_b1_q : cmd_a1_q;
    assign cmd_w2_q = cmd_sel_b ? cmd_b2_q : cmd_a2_q;
    assign cmd_w3_q = cmd_sel_b ? cmd_b3_q : cmd_a3_q;
    assign cmd_w4_q = cmd_sel_b ? cmd_b4_q : cmd_a4_q;
    assign cmd_w5_q = cmd_sel_b ? cmd_b5_q : cmd_a5_q;
    assign pixel_palette_o = line_a_q[12:0];
    assign pixel_opaque_o = line_a_q[13];
    assign pixel_priority_o = line_b_q[2:1];
    assign pixel_shadow_o = line_b_q[0];

    // Read addresses come only from registers (2026-10-23 timing repair):
    // command RAMs are read at idx and idx+1 every clock (duplicated RAMs) and
    // the current index selects one; the line RAMs are read at columns x and
    // x+1 (opposite parity banks). Indices advance by at most one per clock,
    // and every reset-to-zero happens while the RAM is not consumed.
    always_comb begin : storage_controls
        snap_index = 9'(snapshot_word_count_q / 6);
        snap_lane = 3'(snapshot_word_count_q % 6);
        snap_we = !reset && (state_q == ST_SNAPSHOT_WAIT) && spram_valid_i;
        draw_active = (state_q == ST_TILE_DRAW) && !clut_busy && (draw_x_q < draw_end_x_q);
        draw_remaining = {1'b0, draw_end_x_q} - {1'b0, draw_x_q};
        draw_lanes = !draw_active ? 3'd0 : (draw_remaining >= 10'd4) ? 3'd4 : draw_remaining[2:0];
        lane_base = (state_q == ST_LINE_CLEAR) ? clear_x_q :
                    line_start_accept ? 9'd0 : (affine_state_q) ? affine_pixel_x : draw_x_q;
        for (int k = 0; k < 4; k++) begin
            lane_x[k] = lane_base + 9'(k);
            lane_a_we[k] = !reset && ((state_q == ST_LINE_CLEAR) || line_start_accept ||
                ((3'(k) < draw_lanes) && (lane_pen[k] != 0) && (lane_byte[k] != 8'hff)));
            lane_b_we[k] = !reset && ((state_q == ST_LINE_CLEAR) || line_start_accept ||
                ((3'(k) < draw_lanes) && (lane_pen[k] != 0)));
            lane_a_wdata[k] = ((state_q == ST_LINE_CLEAR) || line_start_accept)
                            ? 14'd0 : {1'b1, 13'd4096 + {5'd0, lane_byte[k]}};
            lane_b_wdata[k] = ((state_q == ST_LINE_CLEAR) || line_start_accept)
                            ? 3'd0 : {2'b01, (lane_byte[k] == 8'hff)};
        end
        if (affine_state_q) begin
            for (int k=0;k<4;k++) begin
                lane_a_we[k] = !reset && k==0 && affine_write && affine_pen!=0 && affine_palette!=8'hff;
                lane_b_we[k] = !reset && k==0 && affine_write && affine_pen!=0;
                lane_a_wdata[k] = {1'b1,13'd4096+{5'd0,affine_palette}};
                lane_b_wdata[k] = {2'b01,affine_palette==8'hff};
            end
        end
        // Four consecutive columns occupy all four banks exactly once.
        for (int b = 0; b < 4; b++) begin
            logic [1:0] lk;
            lk = 2'(b) - lane_base[1:0];
            bank_a_we[b] = lane_a_we[lk];
            bank_b_we[b] = lane_b_we[lk];
            bank_addr[b] = lane_x[lk][8:2];
            bank_a_wdata[b] = lane_a_wdata[lk];
            bank_b_wdata[b] = lane_b_wdata[lk];
        end
    end

    always_ff @(posedge clk) begin : command_memory
        if (snap_we) begin
            case (snap_lane)
                3'd0: command_ram0[snap_index] <= spram_data_i;
                3'd1: command_ram1[snap_index] <= spram_data_i;
                3'd2: command_ram2[snap_index] <= spram_data_i;
                3'd3: command_ram3[snap_index] <= spram_data_i;
                3'd4: command_ram4[snap_index] <= spram_data_i;
                3'd5: command_ram5[snap_index] <= spram_data_i;
                default: ;
            endcase
        end
        cmd_rd_idx_q <= cmd_rd_idx;
        cmd_a0_q <= command_ram0[(cmd_rd_idx < COMMANDS) ? cmd_rd_idx : 9'd0];
        cmd_a1_q <= command_ram1[(cmd_rd_idx < COMMANDS) ? cmd_rd_idx : 9'd0];
        cmd_a2_q <= command_ram2[(cmd_rd_idx < COMMANDS) ? cmd_rd_idx : 9'd0];
        cmd_a3_q <= command_ram3[(cmd_rd_idx < COMMANDS) ? cmd_rd_idx : 9'd0];
        cmd_a4_q <= command_ram4[(cmd_rd_idx < COMMANDS) ? cmd_rd_idx : 9'd0];
        cmd_a5_q <= command_ram5[(cmd_rd_idx < COMMANDS) ? cmd_rd_idx : 9'd0];
    end

    // Second copy, read one entry ahead.
    always_ff @(posedge clk) begin : command_memory_ahead
        if (snap_we) begin
            case (snap_lane)
                3'd0: command_ram0b[snap_index] <= spram_data_i;
                3'd1: command_ram1b[snap_index] <= spram_data_i;
                3'd2: command_ram2b[snap_index] <= spram_data_i;
                3'd3: command_ram3b[snap_index] <= spram_data_i;
                3'd4: command_ram4b[snap_index] <= spram_data_i;
                3'd5: command_ram5b[snap_index] <= spram_data_i;
                default: ;
            endcase
        end
        cmd_b0_q <= command_ram0b[(cmd_rd_idx + 1'b1 < COMMANDS) ? cmd_rd_idx + 1'b1 : 9'd0];
        cmd_b1_q <= command_ram1b[(cmd_rd_idx + 1'b1 < COMMANDS) ? cmd_rd_idx + 1'b1 : 9'd0];
        cmd_b2_q <= command_ram2b[(cmd_rd_idx + 1'b1 < COMMANDS) ? cmd_rd_idx + 1'b1 : 9'd0];
        cmd_b3_q <= command_ram3b[(cmd_rd_idx + 1'b1 < COMMANDS) ? cmd_rd_idx + 1'b1 : 9'd0];
        cmd_b4_q <= command_ram4b[(cmd_rd_idx + 1'b1 < COMMANDS) ? cmd_rd_idx + 1'b1 : 9'd0];
        cmd_b5_q <= command_ram5b[(cmd_rd_idx + 1'b1 < COMMANDS) ? cmd_rd_idx + 1'b1 : 9'd0];
    end

    // Bank b is read at the first column >= scanout_x_q in that bank, so the
    // registered outputs cover columns x..x+3 (x advances at most one per clock).
    always_ff @(posedge clk) line_rd_x_q <= scanout_x_q;
    // Colour and flags share one byte-enabled word per bank. Independent
    // enables retain colour on shadow-only updates. The normal/ahead copies
    // retain both simultaneous reads and every original bank address.
    logic [13:0] ahead_a [0:3];
    logic [2:0] ahead_b [0:3];
    logic [6:0] bank_rd_addr [0:3];
    always_comb begin
        for(int b=0;b<4;b++)begin
            logic [8:0] col;
            col=scanout_x_q+{7'd0,2'(b)-scanout_x_q[1:0]};
            bank_rd_addr[b]=(col<LINE_WIDTH)?col[8:2]:7'd0;
        end
    end
    genvar packed_bank;
    generate for(packed_bank=0;packed_bank<4;packed_bank=packed_bank+1)begin:g_packed_line
        wire [31:0] normal_q,ahead_q;
        wire [31:0] data={8'd0,5'd0,bank_b_wdata[packed_bank],2'd0,bank_a_wdata[packed_bank]};
        wire [3:0] enables={1'b0,bank_b_we[packed_bank],bank_a_we[packed_bank],bank_a_we[packed_bank]};
        bigfight_sprite_packed_ram #(.WORDS(LINE_WIDTH/4)) normal_ram(
          .clk(clk),.wr_en(|enables),.wr_addr(bank_addr[packed_bank]),.wr_data(data),
          .wr_byteena(enables),.rd_en(1'b1),.rd_addr(bank_rd_addr[packed_bank]),.rd_data(normal_q));
        bigfight_sprite_packed_ram #(.WORDS(LINE_WIDTH/4)) ahead_ram(
          .clk(clk),.wr_en(|enables),.wr_addr(bank_addr[packed_bank]),.wr_data(data),
          .wr_byteena(enables),.rd_en(1'b1),
          .rd_addr((scanout_x_q<316)?scanout_x_q[8:2]+7'd1:7'd0),.rd_data(ahead_q));
        assign lb_a_q[packed_bank]=normal_q[13:0];
        assign lb_b_q[packed_bank]=normal_q[18:16];
        assign ahead_a[packed_bank]=ahead_q[13:0];
        assign ahead_b[packed_bank]=ahead_q[18:16];
        assign pixel_quad_a_o[14*packed_bank+:14]=(scanout_x_q==line_rd_x_q)?lb_a_q[packed_bank]:ahead_a[packed_bank];
        assign pixel_quad_b_o[3*packed_bank+:3]=(scanout_x_q==line_rd_x_q)?lb_b_q[packed_bank]:ahead_b[packed_bank];
    end endgenerate

`ifdef VERILATOR
    // Shadow of the former register arrays; every consumed read must match.
    logic [15:0] shadow_w0 [0:COMMANDS-1];
    logic [15:0] shadow_w1 [0:COMMANDS-1];
    logic [15:0] shadow_w2 [0:COMMANDS-1];
    logic [15:0] shadow_w3 [0:COMMANDS-1];
    logic [15:0] shadow_w4 [0:COMMANDS-1];
    logic [15:0] shadow_w5 [0:COMMANDS-1];
    logic [12:0] shadow_palette [0:LINE_WIDTH-1];
    logic        shadow_opaque [0:LINE_WIDTH-1];
    logic        shadow_shadow [0:LINE_WIDTH-1];
    logic [1:0]  shadow_priority [0:LINE_WIDTH-1];
    always_ff @(posedge clk) begin
        if (snap_we) case (snap_lane)
            3'd0: shadow_w0[snap_index] <= spram_data_i;
            3'd1: shadow_w1[snap_index] <= spram_data_i;
            3'd2: shadow_w2[snap_index] <= spram_data_i;
            3'd3: shadow_w3[snap_index] <= spram_data_i;
            3'd4: shadow_w4[snap_index] <= spram_data_i;
            3'd5: shadow_w5[snap_index] <= spram_data_i;
            default: ;
        endcase
        for (int k = 0; k < 4; k++) begin
            if (lane_a_we[k]) begin shadow_palette[lane_x[k]] <= lane_a_wdata[k][12:0]; shadow_opaque[lane_x[k]] <= lane_a_wdata[k][13]; end
            if (lane_b_we[k]) begin shadow_shadow[lane_x[k]] <= lane_b_wdata[k][0]; shadow_priority[lane_x[k]] <= lane_b_wdata[k][2:1]; end
        end
        if (!reset && ((state_q == ST_COMMAND) || (state_q == ST_ROM_WAIT)) && (command_index_q < COMMANDS) && snapshot_valid_q)
            if ({cmd_w0_q,cmd_w1_q,cmd_w2_q,cmd_w3_q,cmd_w4_q,cmd_w5_q} !=
                {shadow_w0[command_index_q],shadow_w1[command_index_q],shadow_w2[command_index_q],
                 shadow_w3[command_index_q],shadow_w4[command_index_q],shadow_w5[command_index_q]})
                $fatal(1, "SPRITE_COMMAND_RAM_SHADOW_MISMATCH index=%0d", command_index_q);
        if (!reset && pixel_valid_o && !((scanout_x_q == line_rd_x_q) || (scanout_x_q == line_rd_x_q + (QUAD_COLLECT ? 9'd4 : 9'd1))))
            $fatal(1, "SPRITE_LINE_READ_WINDOW x=%0d read=%0d", scanout_x_q, line_rd_x_q);
        if (!reset && ((state_q == ST_COMMAND) || (state_q == ST_ROM_WAIT)) &&
            !((command_index_q == cmd_rd_idx_q) || (command_index_q == cmd_rd_idx_q + 1'b1)))
            $fatal(1, "SPRITE_COMMAND_READ_WINDOW index=%0d read=%0d", command_index_q, cmd_rd_idx_q);
        if (!reset && pixel_valid_o)
            if ({pixel_palette_o,pixel_opaque_o,pixel_shadow_o,pixel_priority_o} !=
                {shadow_palette[scanout_x_q],shadow_opaque[scanout_x_q],shadow_shadow[scanout_x_q],shadow_priority[scanout_x_q]})
                $fatal(1, "SPRITE_LINE_RAM_SHADOW_MISMATCH x=%0d", scanout_x_q);
    end
`endif
    assign line_bank_o = line_bank_q;
    assign line_y_o = line_y_q;
    assign line_late_o = line_late_q;

    always_ff @(posedge clk) begin : sprite_engine
        logic [8:0]  response_word_index;
        logic [2:0]  response_word_lane;
        logic [7:0]  header_y_offset;
        logic signed [10:0] header_lines;
        logic [8:0]  tile_width_calc;
        logic [8:0]  tile_height_calc;
        logic signed [31:0] x_screen;
        logic signed [31:0] y_screen;
        logic signed [31:0] x_end_screen;
        logic signed [31:0] y_end_screen;
        logic signed [31:0] line_y_screen;
        logic signed [31:0] next_x;
        logic signed [31:0] row_x_offset_fixed;
        logic [20:0] tile_step;
        logic [15:0] base_word;
        logic [8:0]  width_word;
        logic [7:0]  xoff_word;
        logic [7:0]  next_pen;
        logic [31:0] y_delta;
        logic [31:0] y_step;
        logic [31:0] y_index;
        logic [31:0] fixed_x;
        logic [31:0] fixed_y;
        integer i;
        integer c;
        integer row_byte_offset;
        integer sample_x;
        integer src_x;
        begin
            if (reset) begin
                state_q <= ST_IDLE;
                affine_state_q <= 1'b0;
                snapshot_word_count_q <= 0;
                snapshot_bank_q <= 0;
                snapshot_valid_q <= 0;
                clear_x_q <= 0;
                command_index_q <= 0;
                line_y_q <= 0;
                line_bank_q <= 0;
                line_ready_o <= 0;
                line_late_q <= 0;
                line_elapsed_q <= 0;
                scanout_x_q <= 0;
                sprite_index_q <= 0;
                sprite_color_q <= 0;
                sprite_flip_x_q <= 0;
                sprite_flip_y_q <= 0;
                sprite_scale_raw_q <= 0;
                sprite_rotation_q <= 0;
                sprite_scale_q <= 0;
                sprite_x_q <= 0;
                render_y_q <= 0;
                tile_x_q <= 0;
                row_width_q <= 0;
                row_x_offset_q <= 0;
                row_base_q <= 0;
                tile_number_q <= 0;
                tile_base2_q <= 0;
                row_number_q <= 0;
                rows_remaining_q <= 0;
                source_y_q <= 0;
                tile_screen_width_q <= 0;
                tile_screen_x_q <= 0;
                draw_x_q <= 0;
                draw_end_x_q <= 0;
                tile_row_bits_q <= 0;
                dx_q <= 0;
                clut_bytes_q <= 0;
                clut_req_q <= 1'b0;
                clut_wait_q <= 1'b0;
                rom_purpose_q <= ROM_HEADER;
                rom_address_q <= 0;
                rom_bank_q <= 0;
                pf_req_q <= 1'b0;
                pf_pending_q <= 1'b0;
                pf_valid_q <= 1'b0;
                pf_bank_q <= 1'b0;
                pf_addr_q <= 0;
                pf_data_q <= 0;
                header_prefetch_started_q <= 1'b0;
                prefetched_response_q <= 1'b0;
                clut_word_q <= 0;
                scale_word_q <= 0;
                block_size_q <= 0;
            end else begin
                if ((state_q >= ST_LINE_CLEAR) && (state_q <= ST_AFFINE)) begin
                    if (line_elapsed_q < LINE_CLOCK_BUDGET)
                        line_elapsed_q <= line_elapsed_q + 1'b1;
                    else
                        line_late_q <= 1'b1;
                end

                if (line_ready_o && pixel_valid_o && pixel_ready_i) begin
                    if (scanout_x_q == LINE_WIDTH-1)
                        scanout_x_q <= LINE_WIDTH;
                    else
                        scanout_x_q <= scanout_x_q + (QUAD_COLLECT ? 9'd4 : 9'd1);
                end
                if (line_ready_o && line_release_i && (scanout_x_q == LINE_WIDTH)) begin
                    line_ready_o <= 1'b0;
                    scanout_x_q <= 0;
                    state_q <= ST_IDLE;
                end

                if (pf_req_q && rom_ready_i) begin
                    pf_req_q <= 1'b0;
                    pf_pending_q <= 1'b1;
                end
                if (pf_pending_q && rom_valid_i) begin
                    pf_pending_q <= 1'b0;
                    pf_valid_q <= 1'b1;
                    pf_data_q <= rom_data_i;
                end
                if (line_start_accept)
                    header_prefetch_started_q <= 1'b0;
                // The command RAM is synchronous. Once command zero is
                // visible, overlap its header fetch with the four-wide line
                // clear and hold the response for the main sprite FSM.
                if ((state_q == ST_LINE_CLEAR) && !header_prefetch_started_q) begin
                    if (pf_valid_q)
                        pf_valid_q <= 1'b0;
                    else if (!pf_req_q && !pf_pending_q &&
                             (command_index_q == 0) && (cmd_rd_idx_q == 0)) begin
                        header_prefetch_started_q <= 1'b1;
                        if ((cmd_w0_q != 16'hffff) && (cmd_w4_q != 16'hffff) &&
                            (cmd_w0_q < 16'h4000) && (cmd_w4_q[8:0] != 0)) begin
                            pf_req_q <= 1'b1;
                            pf_valid_q <= 1'b0;
                            pf_bank_q <= 1'b0;
                            pf_addr_q <= {cmd_w0_q, 2'b00};
                        end
                    end
                end
                if (clut_req_q && clut_ready_i) begin
                    clut_req_q <= 1'b0;
                    clut_wait_q <= 1'b1;
                end
                if (clut_wait_q && clut_valid_i) begin
                    clut_wait_q <= 1'b0;
                    clut_bytes_q <= clut_bytes_i;
                end

                case (state_q)
                    ST_AFFINE: if (affine_done) begin
                        command_index_q <= command_index_q + 1'b1;
                        affine_state_q <= 1'b0;
                        state_q <= ST_COMMAND;
                    end
                    ST_IDLE: begin
                        if (snapshot_req_i && snapshot_ready_o) begin
                            snapshot_bank_q <= sprite_control_e0_i[12];
                            snapshot_word_count_q <= 0;
                            snapshot_valid_q <= 0;
                            state_q <= ST_SNAPSHOT_REQ;
                        end else if (line_start_accept) begin
                            line_y_q <= line_y_i;
                            line_bank_q <= snapshot_bank_q;
                            line_late_q <= 1'b0;
                            line_elapsed_q <= 0;
                            command_index_q <= 0;
                            // Clear columns zero through three on the accepted
                            // line edge; the remaining clear stays four-wide.
                            clear_x_q <= 4;
                            state_q <= ST_LINE_CLEAR;
                        end
                    end

                    ST_SNAPSHOT_REQ: begin
                        if (spram_ready_i)
                            state_q <= ST_SNAPSHOT_WAIT;
                    end

                    ST_SNAPSHOT_WAIT: begin
                        if (spram_valid_i) begin
                            // command_memory stores this word (snap_we).
                            if (snapshot_word_count_q == SPRITE_WORDS-1) begin
                                snapshot_valid_q <= 1'b1;
                                state_q <= ST_IDLE;
                            end else begin
                                snapshot_word_count_q <= snapshot_word_count_q + 1'b1;
                                state_q <= ST_SNAPSHOT_REQ;
                            end
                        end
                    end

                    ST_LINE_CLEAR: begin
                        // line_memory clears this column (line_*_we).
                        if (clear_x_q >= LINE_WIDTH-4) begin
                            command_index_q <= 0;
                            state_q <= ST_COMMAND;
                        end else
                            clear_x_q <= clear_x_q + 9'd4;
                    end

                    ST_COMMAND: begin
                        if (clut_busy) begin
                            // Previous sprite's CLUT transfer still in flight.
                        end else if (command_index_q == COMMANDS) begin
                            state_q <= ST_LINE_DONE;
                        end else if ((cmd_w0_q == 16'hffff) ||
                                     (cmd_w4_q == 16'hffff)) begin
                            state_q <= ST_LINE_DONE;
                        end else if ((cmd_w0_q >= 16'h4000) ||
                                     (cmd_w4_q[8:0] == 0)) begin
                            command_index_q <= command_index_q + 1'b1;
                        end else begin
                            sprite_index_q <= cmd_w0_q;
                            sprite_color_q <= cmd_w1_q[11:3];
                            sprite_flip_x_q <= cmd_w1_q[15];
                            sprite_flip_y_q <= cmd_w1_q[14];
                            sprite_scale_raw_q <= cmd_w4_q[8:0];
                            sprite_rotation_q <= cmd_w5_q[8:0];
                            sprite_scale_q <= {cmd_w4_q[8:0], 9'b0};
                            sprite_x_q <= $signed({cmd_w2_q,16'b0});
                            fixed_y = $signed({cmd_w3_q,16'b0});
                            rom_address_q <= {cmd_w0_q, 2'b00};
                            rom_bank_q <= 1'b0;
                            rom_purpose_q <= ROM_HEADER;
                            state_q <= ST_ROM_REQ;
                        end
                    end

                    ST_ROM_REQ: begin
                        if (pf_matches_main) begin
                            pf_valid_q <= 1'b0;
                            prefetched_response_q <= 1'b1;
                            state_q <= ST_ROM_WAIT;
                        end else if (rom_ready_i && main_rom_req)
                            state_q <= ST_ROM_WAIT;
                    end

                    ST_ROM_WAIT: begin
                        if (rom_valid_i || prefetched_response_q) begin
                            prefetched_response_q <= 1'b0;
                            case (rom_purpose_q)
                                ROM_HEADER: begin
                                    header_y_offset = {rom_response_data[31:27],3'b000};
                                    header_lines = $signed({1'b0,rom_response_data[15:8]}) -
                                                   $signed({1'b0,header_y_offset});
                                    rows_remaining_q <= header_lines;
                                    row_number_q <= 0;
                                    fixed_y = $signed({cmd_w3_q,16'b0});
                                    if (sprite_flip_y_q)
                                        render_y_q <= fixed_y -
                                            ({24'b0,header_y_offset} * {14'b0,sprite_scale_q});
                                    else
                                        render_y_q <= fixed_y +
                                            ({24'b0,header_y_offset} * {14'b0,sprite_scale_q});
                                    if (header_lines > 0) begin
                                        clut_req_q <= 1'b1;
                                        rom_address_q <= {sprite_index_q,2'b00};
                                        rom_bank_q <= 1'b1;
                                        rom_purpose_q <= ROM_ROW;
                                        if (affine_enable_i && sprite_rotation_q != 0) begin
                                            affine_state_q <= 1'b1;
                                            state_q <= ST_AFFINE;
                                        end
                                        else
                                            state_q <= ST_ROW_CHECK;
                                    end else begin
                                        command_index_q <= command_index_q + 1'b1;
                                        state_q <= ST_COMMAND;
                                    end
                                end
                                ROM_ROW: begin
                                    width_word = {1'b0,rom_response_data[31:24]} + 1'b1;
                                    xoff_word = rom_response_data[23:16];
                                    base_word = {rom_response_data[7:0],rom_response_data[15:8]};
                                    row_width_q <= width_word;
                                    row_x_offset_q <= xoff_word;
                                    row_base_q <= base_word;
                                    tile_number_q <= 0;
                                    tile_base2_q <= {base_word,1'b0};
                                    row_x_offset_fixed = {24'b0,xoff_word} *
                                                         {11'b0,sprite_scale_q,3'b000};
                                    tile_step = {sprite_scale_q,3'b000};
                                    if (sprite_flip_x_q)
                                        tile_x_q <= sprite_x_q - row_x_offset_fixed - tile_step;
                                    else
                                        tile_x_q <= sprite_x_q + row_x_offset_fixed;
                                    tile_width_calc = extent_for(tile_x_q, sprite_scale_q);
                                    tile_height_calc = extent_for(render_y_q, sprite_scale_q);
                                    x_screen = $signed(tile_x_q) >>> 16;
                                    y_screen = $signed(render_y_q) >>> 16;
                                    y_end_screen = y_screen + $signed({23'b0,tile_height_calc});
                                    line_y_screen = $signed({23'b0,line_y_q});
                                    if ((tile_height_calc != 0) &&
                                        (line_y_screen >= y_screen) &&
                                        (line_y_screen < y_end_screen)) begin
                                        y_delta = line_y_screen - y_screen;
                                        y_step = {11'd0, fixed_step(tile_height_calc)};
                                        if (sprite_flip_y_q)
                                            y_index = m5(tile_height_calc-1, y_step[20:0]) -
                                                      m5(y_delta, y_step[20:0]);
                                        else
                                            y_index = m5(y_delta, y_step[20:0]);
                                        source_y_q <= y_index[31:16];
                                        state_q <= ST_TILE_SETUP;
                                    end else
                                        state_q <= ST_ROW_NEXT;
                                end
                                default: begin
                                    tile_row_bits_q <= rom_response_data;
                                    state_q <= ST_TILE_DRAW;
                                    if (pf_next_exists) begin
                                        pf_req_q <= 1'b1;
                                        pf_valid_q <= 1'b0;
                                        pf_bank_q <= pf_next_base[0];
                                        pf_addr_q <= {pf_next_base[16:1],5'b0} + ({13'd0, source_y_q} << 2);
                                    end
                                end
                            endcase
                        end
                    end

                    // ST_CLUT_REQ/ST_CLUT_WAIT are unused since the CLUT fetch overlap.

                    ST_TILE_SETUP: begin
                        tile_width_calc = extent_for(tile_x_q, sprite_scale_q);
                        tile_height_calc = extent_for(render_y_q, sprite_scale_q);
                        x_screen = $signed(tile_x_q) >>> 16;
                        y_screen = $signed(render_y_q) >>> 16;
                        x_end_screen = x_screen + $signed({23'b0,tile_width_calc});
                        y_end_screen = y_screen + $signed({23'b0,tile_height_calc});
                        line_y_screen = $signed({23'b0,line_y_q});
                        if ((tile_width_calc == 0) || (tile_height_calc == 0) ||
                            (line_y_screen < y_screen) ||
                            (line_y_screen >= y_end_screen)) begin
                            state_q <= ST_TILE_SKIP;
                        end else begin
                            y_delta = line_y_screen - y_screen;
                            y_step = {11'd0, fixed_step(tile_height_calc)};
                            if (sprite_flip_y_q)
                                y_index = m5(tile_height_calc-1, y_step[20:0]) -
                                          m5(y_delta, y_step[20:0]);
                            else
                                y_index = m5(y_delta, y_step[20:0]);
                            source_y_q <= y_index[31:16];
                            tile_screen_width_q <= tile_width_calc;
                            tile_screen_x_q <= x_screen[10:0];
                            dx_q <= fixed_step(tile_width_calc);
                            if ((x_end_screen <= 0) || (x_screen >= LINE_WIDTH)) begin
                                state_q <= ST_TILE_SKIP;
                            end else begin
                                if (x_screen < 0)
                                    draw_x_q <= 0;
                                else
                                    draw_x_q <= x_screen[8:0];
                                if (x_end_screen > LINE_WIDTH)
                                    draw_end_x_q <= LINE_WIDTH;
                                else
                                    draw_end_x_q <= x_end_screen[8:0];
                                rom_address_q <= ({tile_base2_q[16:1],5'b0}) +
                                                 (y_index[31:16] << 2);
                                rom_bank_q <= tile_base2_q[0];
                                rom_purpose_q <= ROM_TILE;
                                state_q <= ST_ROM_REQ;
                                if ((pf_req_q || pf_pending_q || pf_valid_q) &&
                                    (pf_bank_q == tile_base2_q[0]) &&
                                    (pf_addr_q == 21'(({tile_base2_q[16:1],5'b0}) + (y_index[31:16] << 2)))) begin
                                    if (pf_valid_q) begin
                                        tile_row_bits_q <= pf_data_q;
                                        pf_valid_q <= 1'b0;
                                        state_q <= ST_TILE_DRAW;
                                        if (pf_next_exists) begin
                                            pf_req_q <= 1'b1;
                                            pf_bank_q <= pf_next_base[0];
                                            pf_addr_q <= {pf_next_base[16:1],5'b0} + ({13'd0, y_index[23:16]} << 2);
                                        end
                                    end else
                                        state_q <= ST_PF_WAIT;
                                end
                            end
                        end
                    end

                    ST_TILE_DRAW: begin
                        if (clut_busy) begin
                            // Wait for this sprite's CLUT (draw_active is low).
                        end else if (draw_x_q < draw_end_x_q) begin
                            // line_memory writes this pixel (line_*_we).
                            draw_x_q <= draw_x_q + {6'd0, draw_lanes};
                            // 2026-10-23: on the clock that writes the tile's last
                            // pixel(s), perform ST_TILE_SKIP's advance directly
                            // (saves the end-detect and skip clocks per tile).
                            if ({1'b0, draw_x_q} + {7'd0, draw_lanes} >= {1'b0, draw_end_x_q}) begin
                                if (tile_number_q + 1'b1 < row_width_q) begin
                                    tile_number_q <= tile_number_q + 1'b1;
                                    tile_base2_q <= tile_base2_q + 1'b1;
                                    tile_step = {sprite_scale_q,3'b000};
                                    if (sprite_flip_x_q)
                                        tile_x_q <= tile_x_q - tile_step;
                                    else
                                        tile_x_q <= tile_x_q + tile_step;
                                    state_q <= ST_TILE_SETUP;
                                end else begin
                                    state_q <= ST_ROW_NEXT;
                                end
                            end
                        end else
                            state_q <= ST_TILE_SKIP;
                    end

                    ST_PF_WAIT: begin
                        // Prefetch of this tile is in flight; consume it on arrival.
                        if (pf_valid_q || (pf_pending_q && rom_valid_i)) begin
                            tile_row_bits_q <= pf_valid_q ? pf_data_q : rom_data_i;
                            pf_valid_q <= 1'b0;
                            state_q <= ST_TILE_DRAW;
                            if (pf_next_exists) begin
                                pf_req_q <= 1'b1;
                                pf_bank_q <= pf_next_base[0];
                                pf_addr_q <= {pf_next_base[16:1],5'b0} + ({13'd0, source_y_q} << 2);
                            end
                        end
                    end

                    ST_TILE_SKIP: begin
                        if (tile_number_q + 1'b1 < row_width_q) begin
                            tile_number_q <= tile_number_q + 1'b1;
                            tile_base2_q <= tile_base2_q + 1'b1;
                            tile_step = {sprite_scale_q,3'b000};
                            if (sprite_flip_x_q)
                                tile_x_q <= tile_x_q - tile_step;
                            else
                                tile_x_q <= tile_x_q + tile_step;
                            state_q <= ST_TILE_SETUP;
                        end else begin
                            state_q <= ST_ROW_NEXT;
                        end
                    end

                    ST_ROW_CHECK: begin
                        tile_height_calc = extent_for(render_y_q, sprite_scale_q);
                        y_screen = $signed(render_y_q) >>> 16;
                        y_end_screen = y_screen + $signed({23'b0,tile_height_calc});
                        line_y_screen = $signed({23'b0,line_y_q});
                        if ((tile_height_calc != 0) &&
                            (line_y_screen >= y_screen) &&
                            (line_y_screen < y_end_screen))
                            state_q <= ST_ROM_REQ;
                        else if ((!sprite_flip_y_q && (line_y_screen < y_screen)) ||
                                 (sprite_flip_y_q && (line_y_screen >= y_end_screen))) begin
                            // 2026-10-23 throughput repair: rows advance monotonically
                            // (y_end of every later row is floor((render_y +/- k*step +
                            // step)/2^16)), so once a row lies wholly past the line in
                            // the row direction no later row of this sprite can be
                            // visible. The skipped ROW_NEXT bookkeeping is reloaded by
                            // the next command's header before any use.
                            command_index_q <= command_index_q + 1'b1;
                            state_q <= ST_COMMAND;
                        end else begin
                            // Invisible row before the line: ROW_NEXT inline (one
                            // clock per skipped row instead of two).
                            row_number_q <= row_number_q + 1'b1;
                            rows_remaining_q <= rows_remaining_q - 11'sd8;
                            tile_step = {sprite_scale_q,3'b000};
                            if (sprite_flip_y_q)
                                render_y_q <= render_y_q - tile_step;
                            else
                                render_y_q <= render_y_q + tile_step;
                            if (rows_remaining_q > 8) begin
                                rom_bank_q <= row_number_q[0];
                                rom_address_q <= {sprite_index_q,2'b00} +
                                                 (((row_number_q + 2'd2) >> 1) << 2);
                                rom_purpose_q <= ROM_ROW;
                                state_q <= ST_ROW_CHECK;
                            end else begin
                                command_index_q <= command_index_q + 1'b1;
                                state_q <= ST_COMMAND;
                            end
                        end
                    end

                    ST_ROW_NEXT: begin
                        row_number_q <= row_number_q + 1'b1;
                        rows_remaining_q <= rows_remaining_q - 11'sd8;
                        tile_step = {sprite_scale_q,3'b000};
                        if (sprite_flip_y_q)
                            render_y_q <= render_y_q - tile_step;
                        else
                            render_y_q <= render_y_q + tile_step;
                        if (rows_remaining_q > 8) begin
                            if ((row_number_q[0] == 0))
                                rom_bank_q <= 1'b0;
                            else
                                rom_bank_q <= 1'b1;
                            rom_address_q <= {sprite_index_q,2'b00} +
                                             (((row_number_q + 2'd2) >> 1) << 2);
                            rom_purpose_q <= ROM_ROW;
                            state_q <= ST_ROW_CHECK;
                        end else begin
                            command_index_q <= command_index_q + 1'b1;
                            state_q <= ST_COMMAND;
                        end
                    end

                    ST_LINE_DONE: begin
                        line_ready_o <= 1'b1;
                        scanout_x_q <= 0;
                        state_q <= ST_IDLE;
                    end

                    default: state_q <= ST_IDLE;
                endcase
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) if (!reset && affine_state_q !== (state_q == ST_AFFINE))
        $fatal(1, "affine_state_q diverged from state_q");
    // synthesis translate_on

endmodule

// Experimental TZB315 scanline transform. No frame buffer and no new clock.
// Signed shear model: https://github.com/orgs/mamedev/discussions/275.
// This candidate must pass geometry, bandwidth and fitted checks before promotion.
module bigfight_affine_scanline (
    input logic clk, reset, start,
    input logic [15:0] index_i, x_i, y_i,
    input logic [8:0] scale_i, rotation_i, line_i,
    input logic flip_x_i, flip_y_i,
    input logic [31:0] header_i,
    output logic done,
    output logic rom_req, rom_bank,
    output logic [20:0] rom_addr,
    input logic rom_ready, rom_valid,
    input logic [31:0] rom_data,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [8:0] pixel_x,
    output logic [3:0] pixel_pen
);
    typedef enum logic [4:0] {IDLE, LOOKUP, DESC_REQ, DESC_WAIT, RECIP,
        DIVIDE, BOUNDS, BOUND_MUL, BOUND_RANGE, BOUND_CHECK, COORD, COORD_MUL, COORD_SUM,
        SAMPLE, ROW_LOAD, WORD_REQ, WORD_WAIT, DRAW, LOCATE} state_t;
    state_t state;
    logic [15:0] index_q;
    logic signed [15:0] anchor_x, anchor_y;
    logic signed [8:0] shear;
    logic [8:0] scale, line_y;
    logic flip_x, flip_y;
    logic [8:0] top_y, bottom_y;
    logic [5:0] rows, load_row;
    // Prepare descriptor addresses before DESC_REQ. Keep the row-to-address
    // addition out of the asynchronous ROM-cache metadata lookup path.
    logic [20:0] descriptor_addr_q;
    logic [11:0] left_x, right_x;
    logic [2:0] object_slot;
    logic [7:0] object_valid;
    wire [39:0] object_entry;
    wire [11:0] desc_left = {1'b0,rom_data[23:16],3'b0};
    wire [11:0] desc_right = ({4'b0,rom_data[23:16]}+{4'b0,rom_data[31:24]}+12'd1)<<3;
    wire [11:0] merged_left = desc_left > left_x ? left_x : desc_left;
    wire [11:0] merged_right = desc_right < right_x ? right_x : desc_right;
    // Fills are consumed only on a subsequent command's LOOKUP, after e+1.
    bigfight_mlab_dp #(.WIDTH(40),.DEPTH_BITS(3)) object_memory (
        .clk(clk),.we(!reset && state==DESC_WAIT && rom_valid && load_row+1>=rows),
        .waddr(object_slot),.wdata({index_q,merged_left,merged_right}),
        .raddr(object_slot),.rdata(object_entry));
    (* ramstyle="MLAB" *) logic [31:0] descriptors [0:255];
    logic [31:0] row_desc;
    logic [5:0] current_row, wanted_row;
    logic row_valid;
    logic [63:0] reciprocal;
    logic [63:0] numerator, quotient;
    logic [31:0] divisor;
    logic [32:0] remainder;
    logic [5:0] divide_count;
    logic [63:0] reciprocal_valid;
    wire [57:0] reciprocal_entry;
    wire [5:0] reciprocal_slot = scale[5:0] ^ shear[5:0];
    wire [17:0] reciprocal_key = {scale,shear};
    wire [32:0] final_remainder = (remainder<<1)|{32'd0,numerator[55]};
    wire [39:0] final_quotient = {quotient[38:0],final_remainder>={1'b0,divisor}};
    // The fill feeds the reciprocal register directly. Cache reads occur
    // on later RECIP visits, so no consumed read overlaps its write edge.
    bigfight_mlab_dp #(.WIDTH(58),.DEPTH_BITS(6)) reciprocal_memory (
        .clk(clk),.we(!reset && state==DIVIDE && divide_count==1),
        .waddr(reciprocal_slot),.wdata({reciprocal_key,final_quotient}),
        .raddr(reciprocal_slot),.rdata(reciprocal_entry));
    logic signed [63:0] u, v, du, dv;
    logic [8:0] cursor_x;
    logic [9:0] end_x;
    logic [19:0] word_key_q;
    logic [15:0] word_valid;

    logic signed [31:0] source_x, source_y;
    logic signed [47:0] exact_u, exact_v, exact_du, exact_dv;
    // Bounds: source X <= 4095, Y <= 511, |shear| <= 256, scale <= 511.
    // Keep each multiply separated from the following range comparison.
    logic signed [22:0] bound_base [0:3];
    logic signed [32:0] bound_scaled [0:3];
    logic signed [20:0] bound_min_x, bound_max_x, bound_min_y, bound_max_y;
    // Reciprocal <= 2^39; the sheared coefficient has no larger magnitude.
    logic signed [40:0] coef_a, coef_b, coef_c, coef_d;
    logic signed [17:0] delta_x, delta_y;
    logic signed [58:0] coord_products [0:3];
    // Q32 locates the source pixel to within one integer for all 16-bit
    // anchors. Compare against the exact rational numerator to resolve ties.
    function automatic signed [31:0] exact_floor(
        input logic signed [63:0] approx,
        input logic signed [47:0] numerator_i,
        input logic [31:0] denominator_i);
        logic signed [63:0] guess, product, den;
        begin
            guess=approx>>>32;den=$signed({1'b0,denominator_i});
            product=guess*den;
            if($signed(numerator_i)<product)guess=guess-1;
            else if($signed(numerator_i)>=product+den)guess=guess+1;
            exact_floor=guess[31:0];
        end
    endfunction
    wire source_y_inside = source_y >= $signed({1'b0,top_y}) && source_y < $signed({1'b0,bottom_y});
    wire [5:0] sample_row = (source_y - top_y) >> 3;
    wire [11:0] strip_left = {1'b0,row_desc[23:16],3'b0};
    wire [12:0] strip_right = {1'b0,strip_left} + (({5'b0,row_desc[31:24]}+13'd1)<<3);
    wire source_x_inside = source_x >= $signed({1'b0,strip_left}) && source_x < $signed({1'b0,strip_right});
    wire [16:0] tile = {row_desc[7:0],row_desc[15:8],1'b0} + ((source_x-strip_left)>>3);
    wire [20:0] sample_addr = {tile[16:1],5'b0} + {16'b0,source_y[2:0],2'b0};
    wire [19:0] sample_key = {tile[0],sample_addr[20:2]};
    function automatic [3:0] word_slot(input logic [19:0] key);
        word_slot=key[3:0]^key[7:4]^key[11:8]^key[15:12]^key[19:16];
    endfunction
    wire [51:0] word_entry;
    // WORD_WAIT supplies the pixel directly; DRAW/SAMPLE separate the next
    // LOCATE read from the fill by more than the MLAB e+1 requirement.
    bigfight_mlab_dp #(.WIDTH(52),.DEPTH_BITS(4)) word_memory (
        .clk(clk),.we(!reset && state==WORD_WAIT && rom_valid),
        .waddr(word_slot(word_key_q)),.wdata({word_key_q,rom_data}),
        .raddr(word_slot(sample_key)),.rdata(word_entry));
    wire word_hit = word_valid[word_slot(sample_key)] && word_entry[51:32]==sample_key;
    function automatic [3:0] pen(input logic [31:0] bits,input logic [2:0] x);
        case(x)
            0:pen=bits[23:20];1:pen=bits[19:16];2:pen=bits[31:28];3:pen=bits[27:24];
            4:pen=bits[7:4];5:pen=bits[3:0];6:pen=bits[15:12];7:pen=bits[11:8];
        endcase
    endfunction
    assign pixel_valid=!reset && state==DRAW;
    assign pixel_x=cursor_x;
    always_comb begin
        rom_req=!reset && (state==DESC_REQ || state==WORD_REQ);
        rom_bank=state==DESC_REQ ? !load_row[0] : word_key_q[19];
        rom_addr=state==DESC_REQ ? descriptor_addr_q : {word_key_q[18:0],2'b0};
    end
    task automatic advance_pixel;
        begin
            u<=u+du;v<=v+dv;cursor_x<=cursor_x+1'b1;
            exact_u<=exact_u+exact_du;exact_v<=exact_v+exact_dv;
            if({1'b0,cursor_x}+10'd1>=end_x)begin done<=1;state<=IDLE;end
            else state<=SAMPLE;
        end
    endtask
    always_ff @(posedge clk) begin : engine
        logic [32:0] next_remainder;
        logic [63:0] next_quotient;
        logic signed [63:0] sx,sy,xx,yy,xn,yn,minx,maxx,miny,maxy;
        logic signed [63:0] ax,ay,bx,by,dx2,dy2;
        logic [11:0] new_left,new_right;
        logic [2:0] slot;
        if(reset)begin
            state<=IDLE;done<=0;object_valid<=0;reciprocal_valid<=0;word_valid<=0;
            pixel_pen<=0;cursor_x<=0;end_x<=0;row_valid<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start)begin
                    index_q<=index_i;anchor_x<=$signed(x_i);anchor_y<=$signed(y_i);
                    scale<=scale_i;shear<=$signed(rotation_i);line_y<=line_i;
                    flip_x<=flip_x_i;flip_y<=flip_y_i;
                    top_y<={1'b0,header_i[31:27],3'b0};
                    rows<=({1'b0,header_i[15:8]}-{1'b0,header_i[31:27],3'b0}+9'd7)>>3;
                    bottom_y<=({1'b0,header_i[15:8]}+9'd7)&9'h1f8;
                    object_slot<=index_i[2:0]^index_i[5:3]^index_i[8:6]^index_i[11:9]^{1'b0,index_i[13:12]};
                    row_valid<=0;state<=LOOKUP;
                end
                LOOKUP:begin
                    if(object_valid[object_slot] && object_entry[39:24]==index_q)begin
                        {left_x,right_x}<=object_entry[23:0];state<=RECIP;
                    end else begin
                        left_x<=12'd2048;right_x<=0;load_row<=0;
                        descriptor_addr_q<={index_q,2'b0};state<=DESC_REQ;
                    end
                end
                DESC_REQ:if(rom_ready)state<=DESC_WAIT;
                DESC_WAIT:if(rom_valid)begin
                    descriptors[{object_slot,load_row[4:0]}]<=rom_data;
                    new_left={1'b0,rom_data[23:16],3'b0};
                    new_right=({4'b0,rom_data[23:16]}+{4'b0,rom_data[31:24]}+12'd1)<<3;
                    if(new_left>left_x)new_left=left_x;
                    if(new_right<right_x)new_right=right_x;
                    left_x<=new_left;right_x<=new_right;
                    if(load_row+1>=rows)begin
                        object_valid[object_slot]<=1;state<=RECIP;
                    end else begin
                        load_row<=load_row+1'b1;
                        if(!load_row[0])descriptor_addr_q<=descriptor_addr_q+21'd4;
                        state<=DESC_REQ;
                    end
                end
                RECIP:begin
                    divisor<=32'(scale)*(32'd65536+32'($signed(shear)*$signed(shear)));
                    if(reciprocal_valid[reciprocal_slot] && reciprocal_entry[57:40]==reciprocal_key)begin
                        reciprocal<={24'd0,reciprocal_entry[39:0]};state<=BOUNDS;
                    end else begin
                        divisor<=32'(scale)*(32'd65536+32'($signed(shear)*$signed(shear)));
                        numerator<=64'h0080000000000000;quotient<=0;remainder<=0;
                        divide_count<=56;state<=DIVIDE;
                    end
                end
                DIVIDE:begin
                    next_remainder=(remainder<<1)|{32'd0,numerator[55]};
                    next_quotient=quotient<<1;
                    if(next_remainder>={1'b0,divisor})begin next_remainder=next_remainder-divisor;next_quotient[0]=1;end
                    remainder<=next_remainder;quotient<=next_quotient;numerator<=numerator<<1;
                    divide_count<=divide_count-1'b1;
                    if(divide_count==1)begin
                        reciprocal<=next_quotient;reciprocal_valid[reciprocal_slot]<=1;state<=BOUNDS;
                    end
                end
                BOUNDS:begin
                    // Each axis is linear. Select its extremal source corner
                    // directly instead of evaluating all four corners twice.
                    // Screen = Fx*R*Fy*source: Y flip mirrors the source
                    // before rotation, X flip mirrors the rotated result.
                    sx=flip_x ? right_x : left_x;
                    sy=(flip_x ^ flip_y ? shear>=0 : shear<=0) ? top_y : bottom_y;
                    if(flip_y)sy=-sy;
                    bound_base[0]<=23'(sx*256-$signed(shear)*sy);
                    sx=flip_x ? left_x : right_x;
                    sy=(flip_x ^ flip_y ? shear>=0 : shear<=0) ? bottom_y : top_y;
                    if(flip_y)sy=-sy;
                    bound_base[1]<=23'(sx*256-$signed(shear)*sy);
                    sx=shear>=0 ? left_x : right_x;
                    sy=flip_y ? bottom_y : top_y;
                    if(flip_y)sy=-sy;
                    bound_base[2]<=23'($signed(shear)*sx+sy*256);
                    sx=shear>=0 ? right_x : left_x;
                    sy=flip_y ? top_y : bottom_y;
                    if(flip_y)sy=-sy;
                    bound_base[3]<=23'($signed(shear)*sx+sy*256);
                    state<=BOUND_MUL;
                end
                BOUND_MUL:begin
                    for(integer k=0;k<4;k=k+1)begin
                        if(k<2 && flip_x)
                            bound_scaled[k]<=-($signed(bound_base[k])*$signed({1'b0,scale}));
                        else bound_scaled[k]<=$signed(bound_base[k])*$signed({1'b0,scale});
                    end
                    state<=BOUND_RANGE;
                end
                BOUND_RANGE:begin
                    bound_min_x<=$signed(anchor_x)+(bound_scaled[0]>>>15);
                    bound_max_x<=$signed(anchor_x)+((bound_scaled[1]+33'sd32767)>>>15);
                    bound_min_y<=$signed(anchor_y)+(bound_scaled[2]>>>15);
                    bound_max_y<=$signed(anchor_y)+((bound_scaled[3]+33'sd32767)>>>15);
                    state<=BOUND_CHECK;
                end
                BOUND_CHECK:begin
                    minx=bound_min_x;maxx=bound_max_x;
                    if(minx<0)minx=0;if(maxx>320)maxx=320;
                    if(maxx<=minx || $signed({1'b0,line_y})<bound_min_y || $signed({1'b0,line_y})>=bound_max_y)begin done<=1;state<=IDLE;end
                    else begin cursor_x<=minx[8:0];end_x<=maxx[9:0];state<=COORD;end
                end
                COORD:begin
                    ax=$signed(reciprocal);by=ax;
                    bx=(ax*$signed(shear))>>>8;ay=-bx;
                    if(flip_x)begin ax=-ax;ay=-ay;end
                    if(flip_y)begin ay=-ay;by=-by;end
                    coef_a<=ax[40:0];coef_b<=bx[40:0];coef_c<=ay[40:0];coef_d<=by[40:0];
                    delta_x<=18'(2*$signed({1'b0,cursor_x})+1-2*$signed(anchor_x));
                    delta_y<=18'(2*$signed({1'b0,line_y})+1-2*$signed(anchor_y));
                    du<=ax;dv<=ay;state<=COORD_MUL;
                end
                COORD_MUL:begin
                    coord_products[0]<=coef_a*delta_x;coord_products[1]<=coef_b*delta_y;
                    coord_products[2]<=coef_c*delta_x;coord_products[3]<=coef_d*delta_y;
                    dx2=delta_x;dy2=delta_y;
                    sx=flip_x ? -dx2 : dx2;
                    sy=dy2;
                    exact_u<=(sx*256+sy*$signed(shear))*16384;
                    exact_v<=(flip_y ? sx*$signed(shear)-sy*256 : -sx*$signed(shear)+sy*256)*16384;
                    exact_du<=flip_x ? -48'sd8388608 : 48'sd8388608;
                    exact_dv<=(flip_x ^ flip_y ? 48'sd32768 : -48'sd32768)*$signed(shear);
                    state<=COORD_SUM;
                end
                COORD_SUM:begin
                    u<=(64'(coord_products[0])+64'(coord_products[1]))>>>1;
                    v<=(64'(coord_products[2])+64'(coord_products[3]))>>>1;
                    state<=SAMPLE;
                end
                SAMPLE:begin
                    source_x<=exact_floor(u,exact_u,divisor);
                    source_y<=exact_floor(v,exact_v,divisor);
                    state<=LOCATE;
                end
                LOCATE:begin
                    if(!source_y_inside)advance_pixel();
                    else if(!row_valid || current_row!=sample_row)begin wanted_row<=sample_row;state<=ROW_LOAD;end
                    else if(!source_x_inside)advance_pixel();
                    else if(word_hit)begin pixel_pen<=pen(word_entry[31:0],source_x[2:0]);state<=DRAW;end
                    else begin word_key_q<=sample_key;state<=WORD_REQ;end
                end
                ROW_LOAD:begin
                    row_desc<=descriptors[{object_slot,wanted_row[4:0]}];
                    current_row<=wanted_row;row_valid<=1;state<=SAMPLE;
                end
                WORD_REQ:if(rom_ready)state<=WORD_WAIT;
                WORD_WAIT:if(rom_valid)begin
                    word_valid[word_slot(word_key_q)]<=1;
                    pixel_pen<=pen(rom_data,source_x[2:0]);state<=DRAW;
                end
                DRAW:if(pixel_ready)advance_pixel();
                default:state<=IDLE;
            endcase
        end
    end
endmodule

// Cyclone V simple-dual-port byte-enable layout. Address registration gives
// the same one-clock read as the behavioural model; mixed-port OLD_DATA is
// retained. Parameter pattern follows corpus ki_fb_ram/gd_word_ram; neither
// donor clocks nor timing constraints are imported.
module bigfight_sprite_packed_ram #(parameter WORDS=80)(
 input wire clk,wr_en,rd_en,input wire [6:0] wr_addr,rd_addr,
 input wire [31:0] wr_data,input wire [3:0] wr_byteena,
 output wire [31:0] rd_data);
`ifdef VERILATOR
 `define BIGFIGHT_PACKED_RAM_MODEL
`elsif __ICARUS__
 `define BIGFIGHT_PACKED_RAM_MODEL
`endif
`ifdef BIGFIGHT_PACKED_RAM_MODEL
 reg [31:0] memory[0:WORDS-1];
 reg [31:0] q;
 integer b;
 always @(posedge clk) begin
   if(wr_en) for(b=0;b<4;b=b+1)
     if(wr_byteena[b]) memory[wr_addr][8*b+:8]<=wr_data[8*b+:8];
   if(rd_en) q<=memory[rd_addr];
 end
 assign rd_data=q;
`else
 altsyncram #(
   .operation_mode("DUAL_PORT"),.intended_device_family("Cyclone V"),
   .lpm_type("altsyncram"),.ram_block_type("M10K"),.byte_size(8),
   .width_a(32),.width_b(32),.widthad_a(7),.widthad_b(7),
   .numwords_a(WORDS),.numwords_b(WORDS),.width_byteena_a(4),
   // Variable read-enable and every B-port input use the same clock
   // selector. Q17 otherwise defaults read control to CLOCK1.
   .address_reg_b("CLOCK0"),.rdcontrol_reg_b("CLOCK0"),
   .indata_reg_b("CLOCK0"),.byteena_reg_b("CLOCK0"),
   .wrcontrol_wraddress_reg_b("CLOCK0"),.outdata_reg_b("UNREGISTERED"),
   .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),
   .clock_enable_output_b("BYPASS"),
   .read_during_write_mode_mixed_ports("OLD_DATA")
 ) ram_i(
   .clock0(clk),.clock1(1'b1),.clocken0(1'b1),.clocken1(1'b1),
   .clocken2(1'b1),.clocken3(1'b1),.aclr0(1'b0),.aclr1(1'b0),
   .address_a(wr_addr),.data_a(wr_data),.byteena_a(wr_byteena),
   .wren_a(wr_en),.address_b(rd_addr),.rden_b(rd_en),.q_b(rd_data)
 );
`endif
endmodule
