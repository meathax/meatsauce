// SPDX-License-Identifier: GPL-3.0-or-later
// REFERENCE ONLY: exact MAME0.289 synthetic58Hz/256x256 event/coordinate
// schedule. This is NOT native Heavy Unit CRT timing or an oscillator divider.
// The rational CE pattern is permitted only for compatibility simulation.
// HS/VS have no proven native geometry and stay idle; sync_qualified is zero.
// No run-time division, multiplication or generated clocks are used.
module airbustr_reference_timing (
    input logic clk,reset,
    input logic tile_busy,line_pending,
    output logic main_event_64,main_event_240,sub_vblank,eof,vis_start,
    output logic prepare_line,line_commit,
    output logic [7:0] prepare_y,scan_x,scan_y,
    output logic scan_valid,raw_ce_pixel,raw_hs,raw_vs,raw_hb,raw_vb,raw_de,
    output logic sync_qualified,
    output logic [31:0] frame_number,missed_lines,blocked_preparations
);
    // Units are attoseconds*48MHz: one master clock is exactly10^18 units.
    // Half-tick comparison produces exact nearest-integer48MHz event ticks.
    // Source constants: F=floor(10^18/58),S=floor(F/256),P=floor(F/65536).
    localparam logic signed [95:0] FRAME = 96'sd17241379310344827 * 96'sd48000000;
    localparam logic signed [95:0] SCAN = 96'sd67349137931034 * 96'sd48000000;
    localparam logic signed [95:0] PIXEL = 96'sd263082570043 * 96'sd48000000;
    localparam logic signed [95:0] TICK = 96'sd1000000000000000000;
    localparam logic signed [95:0] HALF_TICK = 96'sd500000000000000000;
    logic signed [95:0] phase,pixel_target,line_target;
    logic [7:0] beam_line,beam_x;
    logic [7:0] held_x,held_y;
    logic held_de;
    logic current_line_valid,frame_boundary,pixel_due,visible,first_pixel;
    logic prep_candidate;
    // Upcoming coordinate is visible on its CE sampling edge; hold that pixel
    // and its DE for the whole interval until the next reference CE.
    assign scan_x = pixel_due ? beam_x : held_x;
    assign scan_y = pixel_due ? beam_line + 8'd240 : held_y;
    assign frame_boundary = !reset && phase + HALF_TICK >= FRAME;
    assign pixel_due = !reset && phase + HALF_TICK >= pixel_target;
    assign first_pixel = pixel_due && beam_x == 0;
    assign visible = scan_y >= 16 && scan_y < 240;
    assign raw_ce_pixel = pixel_due;
    assign raw_hs = 1'b1; // UNQUALIFIED idle placeholder, never native HS.
    assign raw_vs = 1'b1; // UNQUALIFIED idle placeholder, never native VS.
    assign raw_hb = 1'b0; // MAME logical width has no horizontal blank interval.
    assign raw_vb = !visible;
    assign raw_de = !reset && (pixel_due ? visible && (beam_x == 0 ? line_pending : current_line_valid) : held_de);
    assign scan_valid = raw_ce_pixel && raw_de;
    assign sync_qualified = 1'b0;
    assign eof = frame_boundary;
    assign sub_vblank = frame_boundary;
    assign main_event_240 = frame_boundary; // startupy240 does not invent an IRQ.
    assign main_event_64 = first_pixel && scan_y == 64;
    assign vis_start = first_pixel && scan_y == 16;
    assign line_commit = first_pixel && visible && line_pending;
    assign prep_candidate = first_pixel && scan_y >= 15 && scan_y < 239;
    assign prepare_line = prep_candidate && (!tile_busy || line_commit);
    assign prepare_y = scan_y + 8'd1;
    always_ff @(posedge clk) begin
        if(reset) begin
            phase <= 0;pixel_target <= 0;line_target <= 0;beam_line <= 0;beam_x <= 0;
            current_line_valid <= 0;frame_number <= 0;missed_lines <= 0;blocked_preparations <= 0;
            held_x <= 0;held_y <= 240;held_de <= 0;
        end else begin
            phase <= phase + TICK - (frame_boundary ? FRAME : 96'sd0);
            if(frame_boundary) frame_number <= frame_number + 32'd1;
            if(first_pixel) begin
                current_line_valid <= visible && line_pending;
                if(visible && !line_pending) missed_lines <= missed_lines + 32'd1;
                if(prep_candidate && !prepare_line) blocked_preparations <= blocked_preparations + 32'd1;
            end
            if(pixel_due) begin
                held_x <= scan_x;held_y <= scan_y;held_de <= raw_de;
                beam_x <= beam_x + 8'd1;
                if(beam_x == 255) begin
                    beam_line <= beam_line + 8'd1;
                    if(beam_line == 255) begin line_target <= FRAME;pixel_target <= FRAME; end
                    else begin line_target <= line_target + SCAN;pixel_target <= line_target + SCAN; end
                end else pixel_target <= pixel_target + PIXEL - (frame_boundary ? FRAME : 96'sd0);
                if(frame_boundary) line_target <= 0;
            end
        end
    end
endmodule
