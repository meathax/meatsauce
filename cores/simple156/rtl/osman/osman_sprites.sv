// SPDX-License-Identifier: GPL-3.0-or-later
// DECO52 adaptation of JTCORES jtcninja_decospr.v's candidate/row pipeline.
// Exact Simple156 format, scan order and relative flip: MAME0.289 decospr.cpp.
// One 64-bit ROM read fetches a whole 16-pixel row (osman_loader stores the
// sprite ROM row-interleaved); DRAW writes four pixels per clock. `abort`
// ends the line early (remaining descriptors are not drawn) and the engine
// drains its outstanding read before reporting line_done.
module osman_sprites (
    input logic [7:0] profile,
    input logic clk, reset,
    input logic line_start, abort,
    input logic [8:0] line_y,
    input logic frame_parity, global_flip,
    output logic busy, line_done,
    input logic [8:0] read_x,
    output logic [9:0] sprite_index,
    output logic [1:0] sprite_priority,
    output logic sprite_opaque,
    // Adjacent composition read; renderer storage/scan order is unchanged.
    output logic [9:0] sprite_index_next,
    output logic [1:0] sprite_priority_next,
    output logic sprite_opaque_next,
    output logic [9:0] sprite_index_next2, sprite_index_next3,
    output logic [1:0] sprite_priority_next2, sprite_priority_next3,
    output logic sprite_opaque_next2, sprite_opaque_next3,
    output logic state_req,
    output logic [25:0] state_addr,
    input logic state_valid,
    input logic [31:0] state_data,
    output logic sprite_req,
    output logic [22:0] sprite_byte_addr,
    input logic sprite_valid,
    input logic [63:0] sprite_data
);
    typedef enum logic [3:0] {IDLE,Y_WAIT,CODE_WAIT,X_WAIT,ROM_WAIT,DRAW,DRAIN} phase_t;
    phase_t phase;
    // Pixel and priority storage is four block RAMs, one per x[1:0] lane (word =
    // {priority, pixel index}). Only the validity bitmap stays in flip-flops so
    // it can be cleared in one clock. Reads are registered: the four outputs
    // describe the pixel group addressed by read_x on the PREVIOUS clock, and
    // the *_next* ports are only meaningful for a four-aligned read_x.
    (* ramstyle = "M10K" *) logic [11:0] line_ram0 [0:127];
    (* ramstyle = "M10K" *) logic [11:0] line_ram1 [0:127];
    (* ramstyle = "M10K" *) logic [11:0] line_ram2 [0:127];
    (* ramstyle = "M10K" *) logic [11:0] line_ram3 [0:127];
    logic [11:0] line_q0, line_q1, line_q2, line_q3;
    logic [3:0] line_vq;
    logic [1:0] line_sel;
    logic line_valid [0:319];
    logic [8:0] slot, y;
    logic parity, flip;
    logic [15:0] attrs, tilecode;
    logic [15:0] descriptor_code, previous_attrs, previous_code, previous_x;
    logic previous_descriptor;
    logic [4:0] colour;
    logic [1:0] priority_bits;
    logic [2:0] multi, part_y;
    logic [3:0] glyph_y, draw_x;
    logic fx;
    logic wide_part;
    logic signed [11:0] left_x;
    logic [15:0] row_words [0:3];
    logic signed [11:0] raw_y, raw_x, top_y, base_y, sprite_x;
    logic [2:0] candidate_multi, selected_part;
    logic [3:0] row_y;
    logic [15:0] selected_code;
    logic reject_y, duplicate_x, visible_x, wide_only_x, second_half;
    logic [15:0] request_code;
    logic rom_outstanding, state_outstanding;
    integer i;

    task automatic advance_sprite;
        if (slot == 0) begin line_done <= 1; phase <= IDLE; end
        else begin slot <= slot - 1'b1; phase <= Y_WAIT; end
    endtask

    wire [6:0] read_group = read_x[8:2];
    wire read_in_range = read_x[8:2] < 7'd80;
    wire [6:0] valid_group = read_in_range ? read_group : 7'd0;
    always_ff @(posedge clk) begin
        line_q0 <= line_ram0[read_group];
        line_q1 <= line_ram1[read_group];
        line_q2 <= line_ram2[read_group];
        line_q3 <= line_ram3[read_group];
        line_sel <= read_x[1:0];
        line_vq <= {4{read_in_range}} & {line_valid[{valid_group,2'd3}], line_valid[{valid_group,2'd2}],
                                         line_valid[{valid_group,2'd1}], line_valid[{valid_group,2'd0}]};
    end
    wire [11:0] line_primary = line_sel == 2'd0 ? line_q0 : line_sel == 2'd1 ? line_q1 :
                               line_sel == 2'd2 ? line_q2 : line_q3;
    wire line_primary_valid = line_vq[line_sel];

    // DRAW: four consecutive pixels per clock. Consecutive x always occupy the
    // four distinct lanes, so each lane RAM receives at most one write.
    logic [3:0] draw_dx [0:3];
    logic [3:0] draw_sx [0:3];
    logic [31:0] draw_packed [0:3];
    logic [3:0] draw_pen [0:3];
    logic signed [11:0] draw_pos [0:3];
    logic draw_en [0:3];
    logic [11:0] draw_word [0:3];
    logic [1:0] lane_sel [0:3];
    always_comb begin
        for (i=0;i<4;i=i+1) begin
            draw_dx[i] = draw_x + 4'(i);
            draw_sx[i] = fx ? 4'd15 - draw_dx[i] : draw_dx[i];
            draw_packed[i] = draw_sx[i][3] ? {row_words[3],row_words[2]} : {row_words[1],row_words[0]};
            draw_pen[i] = {draw_packed[i][31-32'(draw_sx[i][2:0])],draw_packed[i][23-32'(draw_sx[i][2:0])],
                           draw_packed[i][15-32'(draw_sx[i][2:0])],draw_packed[i][7-32'(draw_sx[i][2:0])]};
            draw_pos[i] = left_x + $signed({8'd0,draw_dx[i]});
            draw_en[i] = phase == DRAW && !reset && draw_pos[i] >= 0 && draw_pos[i] < 320 &&
                         draw_pen[i] != 0 && !line_valid[draw_pos[i][8:0]];
            draw_word[i] = {priority_bits, 1'b1, colour, draw_pen[i]};
            // Lane i is written by the pixel whose position has x[1:0]==i.
            lane_sel[i] = 2'(i) - left_x[1:0];
        end
    end
    always_ff @(posedge clk) if (draw_en[lane_sel[0]]) line_ram0[draw_pos[lane_sel[0]][8:2]] <= draw_word[lane_sel[0]];
    always_ff @(posedge clk) if (draw_en[lane_sel[1]]) line_ram1[draw_pos[lane_sel[1]][8:2]] <= draw_word[lane_sel[1]];
    always_ff @(posedge clk) if (draw_en[lane_sel[2]]) line_ram2[draw_pos[lane_sel[2]][8:2]] <= draw_word[lane_sel[2]];
    always_ff @(posedge clk) if (draw_en[lane_sel[3]]) line_ram3[draw_pos[lane_sel[3]][8:2]] <= draw_word[lane_sel[3]];
    assign busy = phase != IDLE;
    // The sprite RAM page is constant; decrement only the nine-bit slot.
    wire [8:0] previous_slot = slot - 9'd1;

    always_comb begin
        sprite_index = 0; sprite_priority = 0; sprite_opaque = 0;
        if (line_primary_valid) begin
            sprite_index = line_primary[9:0];
            sprite_priority = line_primary[11:10];
            sprite_opaque = 1;
        end
        sprite_index_next = 0; sprite_priority_next = 0; sprite_opaque_next = 0;
        if (line_vq[1]) begin
            sprite_index_next = line_q1[9:0];
            sprite_priority_next = line_q1[11:10];
            sprite_opaque_next = 1;
        end
        sprite_index_next2 = 0; sprite_priority_next2 = 0; sprite_opaque_next2 = 0;
        if (line_vq[2]) begin
            sprite_index_next2 = line_q2[9:0];
            sprite_priority_next2 = line_q2[11:10];
            sprite_opaque_next2 = 1;
        end
        sprite_index_next3 = 0; sprite_priority_next3 = 0; sprite_opaque_next3 = 0;
        if (line_vq[3]) begin
            sprite_index_next3 = line_q3[9:0];
            sprite_priority_next3 = line_q3[11:10];
            sprite_opaque_next3 = 1;
        end
        candidate_multi = (3'd1 << state_data[10:9]) - 1'b1;
        raw_y = $signed({3'd0,state_data[8:0]});
        if (state_data[8]) raw_y = raw_y - 12'sd512;
        // Effective flip is the board's hardcoded sprite flip XOR global flip.
        base_y = flip ? raw_y : 12'sd240 - raw_y;
        top_y = flip ? base_y : base_y - $signed({5'd0,candidate_multi,4'd0});
        selected_part = 3'((({3'd0,y} - top_y) >> 4));
        if (!flip) selected_part = candidate_multi - selected_part;
        row_y = 4'({3'd0,y} - (flip ? base_y + $signed({5'd0,selected_part,4'd0}) :
                                                 base_y - $signed({5'd0,selected_part,4'd0})));
        selected_code = state_data[15:0] & ~{13'd0,multi};
        if (attrs[14]) selected_code = selected_code + {13'd0,part_y};
        else selected_code = selected_code + {13'd0,multi} - {13'd0,part_y};
        raw_x = $signed({3'd0,state_data[8:0]});
        if (state_data[8:0] >= 320) raw_x = raw_x - 12'sd512;
        sprite_x = flip ? raw_x : 12'sd304 - raw_x;
        reject_y = (state_data[12] && parity) || $signed({3'd0,y}) < top_y ||
                   $signed({3'd0,y}) >= top_y + $signed({4'd0,candidate_multi,4'd0}) + 12'sd16;
        duplicate_x = previous_descriptor && attrs == previous_attrs &&
                      descriptor_code == previous_code && state_data[15:0] == previous_x;
        visible_x = sprite_x < 320 && sprite_x + (attrs[11] && flip ? 12'sd32 : 12'sd16) > 0;
        wide_only_x = !visible_x && attrs[11] && !flip && sprite_x - 16 < 320 && sprite_x > 0;
        second_half = attrs[11] && !wide_part &&
                      ((flip && left_x+16 < 320 && left_x+32 > 0) ||
                       (!flip && left_x-16 < 320 && left_x > 0));
        state_req = 0; state_addr = 0;
        // The board and ROM responses are registered, so accept a successor
        // on the response edge. Keep one outstanding request; do not snapshot
        // sprite RAM or add an issue-only clock for each descriptor/row word.
        // Nothing new is issued once the line is being aborted.
        if (phase == IDLE && line_start) begin
            state_req = 1; state_addr = {13'h0c8,9'd319,4'd0};
        end else if (phase == Y_WAIT && state_valid && !abort) begin
            if (!reject_y) begin state_req = 1; state_addr = {13'h0c8,slot,4'd4}; end
            else if (slot != 0) begin state_req = 1; state_addr = {13'h0c8,previous_slot,4'd0}; end
        end else if (phase == CODE_WAIT && state_valid && !abort) begin
            state_req = 1; state_addr = {13'h0c8,slot,4'd8};
        end else if ((phase == X_WAIT && state_valid && !abort && (duplicate_x || (!visible_x && !wide_only_x))) ||
                     (phase == DRAW && !abort && draw_x == 12 && !second_half)) begin
            if (slot != 0) begin state_req = 1; state_addr = {13'h0c8,previous_slot,4'd0}; end
        end
        request_code = tilecode;
        sprite_req = 0;
        if (phase == X_WAIT && state_valid && !abort && !duplicate_x && (visible_x || wide_only_x)) begin
            sprite_req = 1;
            if (wide_only_x) request_code = tilecode - ({13'd0,multi} + 1'b1);
        end else if (phase == DRAW && !abort && draw_x == 12 && second_half) begin
            sprite_req = 1;
            request_code = tilecode - ({13'd0,multi} + 1'b1);
        end
        // Row-interleaved sprite ROM: group {code, row} holds the four row
        // words (plane0/plane1 of the first source half, then of the second).
        if (profile == 8'd2) request_code = request_code & 16'h1fff;
        else if (profile == 8'd3) request_code = request_code & 16'h3fff;
        sprite_byte_addr = {request_code, glyph_y, 3'b000};
    end
    always_ff @(posedge clk) begin
        line_done <= 0;
        if (reset) begin
            phase <= IDLE; slot <= 319; y <= 0;
            parity <= 0; flip <= 1; attrs <= 0; tilecode <= 0;
            descriptor_code <= 0; previous_attrs <= 0; previous_code <= 0;
            previous_x <= 0; previous_descriptor <= 0;
            colour <= 0; priority_bits <= 0; multi <= 0;
            part_y <= 0; glyph_y <= 0; draw_x <= 0; fx <= 0; wide_part <= 0; left_x <= 0;
            rom_outstanding <= 0; state_outstanding <= 0;
            for (i=0;i<4;i=i+1) row_words[i] <= 0;
        end else begin
            if (sprite_req) rom_outstanding <= 1;
            else if (sprite_valid) rom_outstanding <= 0;
            if (state_req) state_outstanding <= 1;
            else if (state_valid) state_outstanding <= 0;
            case (phase)
            IDLE: if (line_start) begin
                y <= line_y; parity <= frame_parity; flip <= !global_flip;
                previous_descriptor <= 0;
                // Only the320-bit validity bitmap needs clearing. Pixel and
                // priority RAM remain intact and invalid reads are masked0.
                // Parallel bitmap clear removes320 measured critical clocks.
                for (i=0;i<320;i=i+1) line_valid[i] <= 0;
                slot <= 319; phase <= Y_WAIT;
            end
            Y_WAIT: if (state_valid) begin
                if (abort) phase <= DRAIN;
                else if (reject_y)
                    advance_sprite();
                else begin
                    attrs <= state_data[15:0]; multi <= candidate_multi; part_y <= selected_part;
                    glyph_y <= (state_data[14] ^ flip) ? 4'd15 - row_y : row_y;
                    fx <= state_data[13] ^ flip; phase <= CODE_WAIT;
                end
            end
            CODE_WAIT: if (state_valid) begin
                tilecode <= selected_code; descriptor_code <= state_data[15:0];
                phase <= abort ? DRAIN : X_WAIT;
            end
            X_WAIT: if (state_valid) begin
                left_x <= sprite_x; colour <= state_data[13:9]; priority_bits <= state_data[15:14];
                wide_part <= 0;
                // The line buffer never overwrites an opaque pixel. A fully
                // identical descriptor cannot add pixels after its prior draw,
                // even if intervening sprites filled earlier transparent pens.
                // Retain live descriptor reads; no sprite-RAM snapshot is made.
                if (abort) phase <= DRAIN;
                else if (duplicate_x)
                    advance_sprite();
                else if (!visible_x) begin
                    if (wide_only_x) begin
                        left_x <= sprite_x - 16; tilecode <= tilecode - ({13'd0,multi} + 1'b1);
                        wide_part <= 1; phase <= ROM_WAIT;
                    end else advance_sprite();
                end else phase <= ROM_WAIT;
                previous_descriptor <= 1;
                previous_attrs <= attrs;
                previous_code <= descriptor_code;
                previous_x <= state_data[15:0];
            end
            ROM_WAIT: if (sprite_valid) begin
                row_words[0] <= sprite_data[15:0]; row_words[1] <= sprite_data[31:16];
                row_words[2] <= sprite_data[47:32]; row_words[3] <= sprite_data[63:48];
                draw_x <= 0; phase <= abort ? DRAIN : DRAW;
            end
            DRAW: begin
                for (i=0;i<4;i=i+1) if (draw_en[i]) line_valid[draw_pos[i][8:0]] <= 1;
                if (abort) phase <= DRAIN;
                else if (draw_x == 12) begin
                    if (second_half) begin
                        left_x <= flip ? left_x + 16 : left_x - 16;
                        tilecode <= tilecode - ({13'd0,multi} + 1'b1);
                        wide_part <= 1; phase <= ROM_WAIT;
                    end else advance_sprite();
                end else draw_x <= draw_x + 4'd4;
            end
            // Aborted: wait for any outstanding response, then finish the line.
            DRAIN: if (!(rom_outstanding && !sprite_valid) && !(state_outstanding && !state_valid)) begin
                line_done <= 1; phase <= IDLE;
            end
            default: phase <= IDLE;
            endcase
        end
    end
endmodule
