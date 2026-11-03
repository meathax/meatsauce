// Penguin geometry derivative; upstream Guardians commit 43bb986da05aa19adb06ac575cfcc8af5c003fb7.
// Upstream source SHA256: cef6b23ad1a2c82a86461723ff313456c5d183ca5b8a1c646d97e9d694983435
// Exact reproducible patch: sim/video/prepare_video.py; donor remains immutable.
// Allumer X1-020 / NEC DX-101 scanline renderer.
//
// This first hardware renderer implements the controller's normal multi-tile
// sprite path, floating tilemaps, global/local size selection, flips,
// transparency, opacity and 2/3/4/5/6/8-bpp masks.
//
// Format and drawing rules are derived from MAME's BSD-licensed device model
// by Luca Elia and David Haywood.
// SPDX-License-Identifier: GPL-3.0-or-later

module penguin_dx101_video
#(
    parameter bit REGISTERED_SCAN_BLANK=1'b0,
	// Thirteen line banks allow the renderer to absorb expensive tilemap rows.
	// Raster-scroll words come from the frozen preceding-frame history, so the
	// same bounded look-ahead is safe while raster effects are active.
	parameter bit AHEAD_RENDER = 1'b0,
	parameter integer ACTIVE_WIDTH = 320,
	parameter integer ACTIVE_HEIGHT = 224,
	// Synthetic MAME-reference geometry; native PCB totals remain unresolved.
	parameter integer H_TOTAL = 512,
	parameter integer V_TOTAL = 256
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        ce_pix,
	input  logic  [8:0] h_count,
	input  logic  [8:0] v_count,
    input logic scan_line_active, scan_next_line_active,
	input  logic        hblank,
	input  logic        vblank,
	input  logic        raster_active,
	input  logic        rowscroll_override_valid,
	input  logic [14:0] rowscroll_override_record,
	input  logic [15:0] rowscroll_override_data,
	input  logic        rowscroll_seed_valid,
	input  logic [15:0] rowscroll_seed_data,
	input  logic        rowscroll_live_valid,
	input  logic [14:0] rowscroll_live_record,
	input  logic [15:0] rowscroll_live_data,
	input  logic [15:0] video_control,
	input  logic        rotate_180,
	input  logic [26:0] video_x_offset,
	input  logic [26:0] video_x_zoom,
	input  logic        video_x_half_mode, video_x_fractional_mode,
	input  logic [26:0] video_y_offset,
	input  logic [26:0] video_y_zoom,

	output logic [16:0] sprite_address,
	input  logic [63:0] sprite_q,
	input  logic [15:0] sprite_seed_q,
	output logic [14:0] palette_address,
	input  logic [15:0] palette_q,

	output logic [24:0] gfx_addr,
	output logic        gfx_req,
	input  logic [63:0] gfx_dout,
	input  logic        gfx_ack,

	output logic  [7:0] red,
	output logic  [7:0] green,
	output logic  [7:0] blue,
	output logic        busy,
	output logic        line_done,
	output logic [15:0] missed_lines,
	output logic  [8:0] rowscroll_lookup_line
);

localparam integer LINE_PITCH = ACTIVE_WIDTH / 8;
localparam integer LINE_DEPTH = 13 * LINE_PITCH;
localparam integer LINE_ADDRESS_WIDTH = $clog2(LINE_DEPTH);

// Eight X-interleaved memories turn an eight-pixel draw into one write per
// physical RAM. Pack all thirteen logical line buffers into each lane.
// At 320 pixels each lane has 520 RGB555-index words. Packed addresses
// widen to ten bits; Quartus BRAM/resource consequences are not yet measured.
// The extra depth absorbs
// the clustered cache misses produced by rowscrolled tilemaps instead of
// repeating a completed scanline through foreground actors.
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank0 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank1 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank2 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank3 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank4 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank5 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank6 [0:LINE_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line_buffer_bank7 [0:LINE_DEPTH-1];
logic [14:0] line_read_data [0:7];
logic [LINE_ADDRESS_WIDTH-1:0] line_read_address;
logic [3:0] display_bank;
logic [3:0] work_bank;
logic [12:0] bank_valid;
logic [8:0] bank_line [0:12];
logic       scheduler_started;
logic       schedule_pending;
logic [8:0] next_render_line;
logic [8:0] render_distance;
logic       lookahead_ready;
logic [12:0] display_match;
logic       selected_bank_found;
logic [3:0] selected_bank;
logic       free_bank_found;
logic [3:0] free_bank;
logic [12:0] free_bank_mask;
logic [8:0] target_line;
logic [8:0] clear_x;
integer line_bank_index;
integer select_bank_index;
localparam integer V_ACTIVE = ACTIVE_HEIGHT;
localparam integer V_HALF = V_TOTAL / 2;

wire [8:0] physical_next_line = (v_count == V_TOTAL - 1)
	? 9'd0 : (v_count + 9'd1);
// BEGIN PREFETCH_TARGET_PIPELINE
// Only the row number is staged; bank tags/validity remain live until capture.
logic [8:0] prefetch_next_line_q;
always_ff @(posedge clk) prefetch_next_line_q <= physical_next_line;
wire [8:0] prefetch_target_line = (H_TOTAL > 3)
    ? prefetch_next_line_q : physical_next_line;
// END PREFETCH_TARGET_PIPELINE
wire [9:0] recovery_line_sum = {1'b0, v_count} + 10'd12;
wire [8:0] recovery_render_line = (recovery_line_sum >= V_TOTAL)
	? (recovery_line_sum - V_TOTAL) : recovery_line_sum[8:0];
wire [8:0] logical_target_line = rotate_180 && (target_line < V_ACTIVE)
	? (V_ACTIVE - 1 - target_line) : target_line;
always_comb rowscroll_lookup_line = logical_target_line;

function automatic [8:0] line_forward_distance;
	input [8:0] from_line;
	input [8:0] to_line;
	begin
		if (to_line >= from_line)
			line_forward_distance = to_line - from_line;
		else
			line_forward_distance = to_line + V_TOTAL - from_line;
	end
endfunction

// Exact endpoints for the floating row's modulo-1024 span. Its former
// length expression reduces to last_column at the normalized upper bound:
// (first - 8) + (last - first + 1) + 8 - 1 == last.
// Signed ten-bit endpoints avoid the four integer carry chains on the
// tilemap address enable; live offsets and zoom keep their existing timing.
function automatic wrapped_column_bounds_contains;
	input logic signed [9:0] first_coordinate;
	input logic signed [9:0] last_coordinate;
	input logic signed [9:0] coordinate;
	begin
		if (last_coordinate >= first_coordinate)
			wrapped_column_bounds_contains = (coordinate >= first_coordinate)
				&& (coordinate <= last_coordinate);
		else
			wrapped_column_bounds_contains = (coordinate <= last_coordinate)
				|| (coordinate >= first_coordinate);
	end
endfunction

// Horizontal positions use a signed 10-bit coordinate ring. Objects that
// cross +511 continue at -512; a linear range comparison drops precisely the
// wrapped columns that appear at a screen edge.
function automatic wrapped_span_contains;
	input integer first_coordinate;
	input integer span_length;
	input integer coordinate;
	integer first_normalized;
	integer last_normalized;
	integer coordinate_normalized;
	begin
		first_normalized = first_coordinate & 1023;
		if (first_normalized & 512)
			first_normalized = first_normalized - 1024;
		last_normalized = (first_coordinate + span_length - 1) & 1023;
		if (last_normalized & 512)
			last_normalized = last_normalized - 1024;
		coordinate_normalized = coordinate & 1023;
		if (coordinate_normalized & 512)
			coordinate_normalized = coordinate_normalized - 1024;
		if (last_normalized >= first_normalized)
			wrapped_span_contains = (coordinate_normalized >= first_normalized)
				&& (coordinate_normalized <= last_normalized);
		else
			wrapped_span_contains = (coordinate_normalized <= last_normalized)
				|| (coordinate_normalized >= first_normalized);
	end
endfunction

// Vertical positions use a smaller 9-bit ring for both normal sprites and
// floating tilemap windows. Guardians exposes this directly when it splits a
// large picture or background across descriptors: 0x1f9 followed by 0x039 is
// a continuous pair of 64-line chunks across the 0x200 boundary. Treating a
// floating window's Y as 10-bit discards the wrapped first chunk, leaving the
// top of gameplay backgrounds black.
function automatic wrapped_vertical_y_contains;
	input integer first_coordinate;
	input integer span_length;
	input integer coordinate;
	reg signed [8:0] first_normalized;
	reg signed [8:0] last_normalized;
	reg signed [8:0] coordinate_normalized;
	begin
		first_normalized = first_coordinate[8:0];
		// Keep the original full integer arithmetic before modulo truncation.
		last_normalized = (first_coordinate + span_length - 1) & 511;
		coordinate_normalized = coordinate[8:0];
		if (last_normalized >= first_normalized)
			wrapped_vertical_y_contains =
				(coordinate_normalized >= first_normalized)
				&& (coordinate_normalized <= last_normalized);
		else
			wrapped_vertical_y_contains =
				(coordinate_normalized <= last_normalized)
				|| (coordinate_normalized >= first_normalized);
	end
endfunction


// Decode the original full integer span-1 modulo512. Merge the selected
// descriptor BEFORE decode. Unknown ANY relevant tall-height bit must poison
// the whole delta, including bit15 which is redundant only for binary inputs.
function automatic [8:0] sprite_y_last_delta;
    input floating_mode;
    input use_header_size;
    input [15:0] header_size, record_size;
    reg [15:0] selected_size;
    begin
        selected_size = use_header_size ? header_size : record_size;
        if (floating_mode) begin
            case (^selected_size[15:10])
                1'b0, 1'b1: sprite_y_last_delta = {selected_size[14:10],4'hf};
                default: sprite_y_last_delta = 9'hxxx;
            endcase
        end else begin
            case (selected_size[11:10])
                2'd0: sprite_y_last_delta = 9'd7;
                2'd1: sprite_y_last_delta = 9'd15;
                2'd2: sprite_y_last_delta = 9'd31;
                2'd3: sprite_y_last_delta = 9'd63;
                default: sprite_y_last_delta = 9'hxxx;
            endcase
        end
    end
endfunction

function automatic wrapped_vertical_y_bounds_contains;
    input [8:0] first_bits, last_bits;
    input integer coordinate;
    reg signed [8:0] first_normalized,last_normalized,coordinate_normalized;
    begin
        first_normalized=first_bits;
        last_normalized=last_bits;
        coordinate_normalized=coordinate[8:0];
        if(last_normalized>=first_normalized)
            wrapped_vertical_y_bounds_contains=(coordinate_normalized>=first_normalized)
                && (coordinate_normalized<=last_normalized);
        else
            wrapped_vertical_y_bounds_contains=(coordinate_normalized<=last_normalized)
                || (coordinate_normalized>=first_normalized);
    end
endfunction

// A DX-101 list can contain hundreds of one-tile descriptors even though
// only a few intersect a given scanline. Scan the 64-bit records into a
// compact active list, then spend renderer cycles only on contributing rows.
// Bit 128 tags the one floating descriptor whose scroll word was rewritten
// by the raster handler. The payload remains the original 128-bit header +
// descriptor record.
(* ramstyle = "M10K" *) logic [128:0] active_records [0:1535];
logic [128:0] active_record_q;
logic [10:0] active_count;
logic [10:0] active_total;
logic [10:0] active_total_last;
logic [10:0] active_index;

// Preserve already-rendered actors when the late rowscrolled heat plane is
// composited. Only non-floating descriptors populate this mask, and only the
// exact raster-rewritten descriptor consults it.
// Eight independent occupancy lanes match the fixed physical X banks.
// Each lane has one indexed read/set; no cross-lane multiwrite decoder.
logic [LINE_PITCH-1:0] foreground_occupancy_bank [0:7];
logic         record_rowscroll_target;

always_comb begin
	render_distance = line_forward_distance(v_count, next_render_line);
	lookahead_ready = AHEAD_RENDER
		&& (render_distance >= 9'd1) && (render_distance <= 9'd12);
	for (select_bank_index = 0; select_bank_index < 13;
	     select_bank_index = select_bank_index + 1) begin
		display_match[select_bank_index] = bank_valid[select_bank_index]
			&& (bank_line[select_bank_index] == v_count);
	end

	// Exact-line selection is a shallow parallel encoder.  Do not feed the
	// previous minimum-age search into the synchronous bank-valid writeback:
	// that serialized eight 9-bit comparisons into a 26-level timing path.
	// A miss simply holds the displayed row while the twelve-line reservoir
	// recovers, and stale completed rows are reclaimed independently below.
	selected_bank_found = |display_match;
	casez (display_match)
		13'b????????????1: selected_bank = 4'd0;
		13'b???????????10: selected_bank = 4'd1;
		13'b??????????100: selected_bank = 4'd2;
		13'b?????????1000: selected_bank = 4'd3;
		13'b????????10000: selected_bank = 4'd4;
		13'b???????100000: selected_bank = 4'd5;
		13'b??????1000000: selected_bank = 4'd6;
		13'b?????10000000: selected_bank = 4'd7;
		13'b????100000000: selected_bank = 4'd8;
		13'b???1000000000: selected_bank = 4'd9;
		13'b??10000000000: selected_bank = 4'd10;
		13'b?100000000000: selected_bank = 4'd11;
		13'b1000000000000: selected_bank = 4'd12;
		default: selected_bank = display_bank;
	endcase

	free_bank_mask = ~bank_valid;
	free_bank_mask[display_bank] = 1'b0;
	free_bank_found = |free_bank_mask;
	casez (free_bank_mask)
		13'b????????????1: free_bank = 4'd0;
		13'b???????????10: free_bank = 4'd1;
		13'b??????????100: free_bank = 4'd2;
		13'b?????????1000: free_bank = 4'd3;
		13'b????????10000: free_bank = 4'd4;
		13'b???????100000: free_bank = 4'd5;
		13'b??????1000000: free_bank = 4'd6;
		13'b?????10000000: free_bank = 4'd7;
		13'b????100000000: free_bank = 4'd8;
		13'b???1000000000: free_bank = 4'd9;
		13'b??10000000000: free_bank = 4'd10;
		13'b?100000000000: free_bank = 4'd11;
		13'b1000000000000: free_bank = 4'd12;
		default: free_bank = 4'd0;
	endcase
end

logic [8:0] prefetch_x;
logic [12:0] prefetch_match;
logic [3:0] prefetch_bank;
logic [3:0] boundary_bank;
logic boundary_bank_found;
wire [3:0] read_bank = (h_count >= H_TOTAL - 2 || h_count == 0)
	? boundary_bank : display_bank;
integer prefetch_bank_index;
wire [8:0] produced_x = (h_count == H_TOTAL - 1) ? 9'd0 : h_count + 9'd1;
wire [8:0] produced_line = (h_count == H_TOTAL - 1) ? physical_next_line : v_count;
logic [8:0] display_x;
logic [14:0] scan_index;
function automatic [LINE_ADDRESS_WIDTH-1:0] packed_line_address;
	input [3:0] buffer_number;
	input [5:0] row_number;
	begin
		case (buffer_number)
			4'd0: packed_line_address = LINE_ADDRESS_WIDTH'(0 * LINE_PITCH) + row_number;
			4'd1: packed_line_address = LINE_ADDRESS_WIDTH'(1 * LINE_PITCH) + row_number;
			4'd2: packed_line_address = LINE_ADDRESS_WIDTH'(2 * LINE_PITCH) + row_number;
			4'd3: packed_line_address = LINE_ADDRESS_WIDTH'(3 * LINE_PITCH) + row_number;
			4'd4: packed_line_address = LINE_ADDRESS_WIDTH'(4 * LINE_PITCH) + row_number;
			4'd5: packed_line_address = LINE_ADDRESS_WIDTH'(5 * LINE_PITCH) + row_number;
			4'd6: packed_line_address = LINE_ADDRESS_WIDTH'(6 * LINE_PITCH) + row_number;
			4'd7: packed_line_address = LINE_ADDRESS_WIDTH'(7 * LINE_PITCH) + row_number;
			4'd8: packed_line_address = LINE_ADDRESS_WIDTH'(8 * LINE_PITCH) + row_number;
			4'd9: packed_line_address = LINE_ADDRESS_WIDTH'(9 * LINE_PITCH) + row_number;
			4'd10: packed_line_address = LINE_ADDRESS_WIDTH'(10 * LINE_PITCH) + row_number;
			4'd11: packed_line_address = LINE_ADDRESS_WIDTH'(11 * LINE_PITCH) + row_number;
			default: packed_line_address = LINE_ADDRESS_WIDTH'(12 * LINE_PITCH) + row_number;
		endcase
	end
endfunction

// BEGIN BANK_SELECTION_TIMING
// Four-way groups bound the priority depth while retaining the lowest tag.
function automatic [2:0] prefetch_priority4(input logic [3:0] match_bits);
    begin
        casez (match_bits)
            4'b???1: prefetch_priority4 = 3'b100;
            4'b??10: prefetch_priority4 = 3'b101;
            4'b?100: prefetch_priority4 = 3'b110;
            4'b1000: prefetch_priority4 = 3'b111;
            default: prefetch_priority4 = 3'b000;
        endcase
    end
endfunction
(* keep *) wire [2:0] prefetch_group0 = prefetch_priority4(prefetch_match[3:0]);
(* keep *) wire [2:0] prefetch_group1 = prefetch_priority4(prefetch_match[7:4]);
(* keep *) wire [2:0] prefetch_group2 = prefetch_priority4(prefetch_match[11:8]);
(* keep *) wire [2:0] prefetch_group3 = prefetch_priority4({3'b000, prefetch_match[12]});
// An unknown lower group blocks higher groups, matching the original casez.
(* keep *) wire prefetch_zero0 = (prefetch_match[3:0] === 4'b0000);
(* keep *) wire prefetch_zero2 = (prefetch_match[11:8] === 4'b0000);
(* keep *) wire prefetch_low_empty = (prefetch_match[7:0] === 8'b00000000);
wire [4:0] prefetch_low_choice = prefetch_zero0
    ? {prefetch_group1[2], 2'b01, prefetch_group1[1:0]}
    : {prefetch_group0[2], 2'b00, prefetch_group0[1:0]};
wire [4:0] prefetch_high_choice = prefetch_zero2
    ? {prefetch_group3[2], 2'b11, prefetch_group3[1:0]}
    : {prefetch_group2[2], 2'b10, prefetch_group2[1:0]};
wire [4:0] prefetch_choice = prefetch_low_empty
    ? prefetch_high_choice : prefetch_low_choice;
// END BANK_SELECTION_TIMING

always_comb begin
	// Find the upcoming physical row. Its selection is frozen before the
	// first palette prefetch so a late row cannot replace a held row midline.
	for (prefetch_bank_index = 0; prefetch_bank_index < 13;
	     prefetch_bank_index = prefetch_bank_index + 1)
		prefetch_match[prefetch_bank_index] = bank_valid[prefetch_bank_index]
			&& (bank_line[prefetch_bank_index] == prefetch_target_line);
	prefetch_bank = prefetch_choice[4] ? prefetch_choice[3:0] : display_bank;
	if (h_count >= H_TOTAL - 2) prefetch_x = h_count - (H_TOTAL - 2);
	else prefetch_x = h_count + 9'd2;
	if (rotate_180 && (prefetch_x < 9'(ACTIVE_WIDTH)))
		display_x = 9'(ACTIVE_WIDTH-1) - prefetch_x;
	else
		display_x = prefetch_x;
	line_read_address = packed_line_address(read_bank, display_x[8:3]);
	if (prefetch_x < 9'(ACTIVE_WIDTH)) begin
		case (display_x[2:0])
			3'd0: scan_index = line_read_data[0];
			3'd1: scan_index = line_read_data[1];
			3'd2: scan_index = line_read_data[2];
			3'd3: scan_index = line_read_data[3];
			3'd4: scan_index = line_read_data[4];
			3'd5: scan_index = line_read_data[5];
			3'd6: scan_index = line_read_data[6];
			default: scan_index = line_read_data[7];
		endcase
	end
	else scan_index = 15'd0;
end

always_ff @(posedge clk) begin
	if (reset) begin
		palette_address <= 15'd0;
		red <= 8'd0;
		green <= 8'd0;
		blue <= 8'd0;
	end
	else if (ce_pix) begin
		palette_address <= scan_index;
		// Registered RGB is sampled at the following pixel enable, when the
		// timing counters have advanced. Blank the pixel being produced here.
		if (produced_x < ACTIVE_WIDTH
            && (REGISTERED_SCAN_BLANK
                ? ((h_count == H_TOTAL-1) ? scan_next_line_active : scan_line_active)
                : produced_line < ACTIVE_HEIGHT)
		    && !video_control[0]) begin
			red <= {palette_q[14:10], palette_q[14:12]};
			green <= {palette_q[9:5], palette_q[9:7]};
			blue <= {palette_q[4:0], palette_q[4:2]};
		end
		else begin
			red <= 8'd0;
			green <= 8'd0;
			blue <= 8'd0;
		end
	end
end

function automatic [31:0] normal_alignment_mask(input logic [1:0] x_exp,y_exp);
    case ({x_exp,y_exp})
        4'd0: normal_alignment_mask = 32'hffffffff;
        4'd1: normal_alignment_mask = 32'hfffffffe;
        4'd2: normal_alignment_mask = 32'hfffffffc;
        4'd3: normal_alignment_mask = 32'hfffffff8;
        4'd4: normal_alignment_mask = 32'hfffffffe;
        4'd5: normal_alignment_mask = 32'hfffffffc;
        4'd6: normal_alignment_mask = 32'hfffffff8;
        4'd7: normal_alignment_mask = 32'hfffffff0;
        4'd8: normal_alignment_mask = 32'hfffffffc;
        4'd9: normal_alignment_mask = 32'hfffffff8;
        4'd10: normal_alignment_mask = 32'hfffffff0;
        4'd11: normal_alignment_mask = 32'hffffffe0;
        4'd12: normal_alignment_mask = 32'hfffffff8;
        4'd13: normal_alignment_mask = 32'hfffffff0;
        4'd14: normal_alignment_mask = 32'hffffffe0;
        4'd15: normal_alignment_mask = 32'hffffffc0;
        default: normal_alignment_mask = 32'hxxxxxxxx;
    endcase
endfunction

// Per-line X scale set latched from X_SCALE below.
logic [11:0] line_x_bound [1:8];
logic [7:0] line_x_columns;
logic line_x_zero, line_x_shrink, line_x_wide, line_x_enlarge;
logic signed [12:0] float_clip_low,float_clip_high;
// Registered: h0 loads at the end of R_ACTIVE_WAIT and line_x_* in R_CLEAR,
// while R_FLOAT_SELECT is at least one state after R_SPRITE_PROCESS. This
// keeps the offset adder off the h0 -> FLOAT_SELECT -> sprite_address path.
always_ff @(posedge clk) begin
    integer clip_offset;
    logic clip_half;
    clip_offset=0;clip_half=0;
    if(!h0[14])clip_offset=$signed({video_x_offset[26],video_x_offset[26:16]});
    if(!h0[14] && line_x_shrink)clip_half=1;
    // Floor division by two admits [-14,639] before the shift. Beyond 2x
    // shrink the visible source span exceeds the 1024-pixel ring: no high clip.
    // Enlargement shows less than ACTIVE_WIDTH source pixels.
    float_clip_low<=13'(clip_offset+(clip_half ? -14 : -7));
    float_clip_high<=13'(clip_offset+((!h0[14] && line_x_wide) ? 2048
        : clip_half ? (2*ACTIVE_WIDTH) : ACTIVE_WIDTH));
end
typedef enum logic [4:0] {
	R_IDLE, R_CLEAR, R_HEADER_ISSUE, R_HEADER_WAIT, R_HEADER_CAPTURE,
	R_HEADER_PROCESS, R_SPRITE_ISSUE, R_SPRITE_WAIT, R_SPRITE_PIPE,
	R_SPRITE_CAPTURE,
	R_ACTIVE_LOAD, R_ACTIVE_WAIT, R_SPRITE_PROCESS, R_NORMAL_PREP, R_FLOAT_SELECT,
	R_TILEMAP_WAIT, R_TILEMAP_CAPTURE,
	R_TILEMAP_PROCESS, R_GFX_WAIT, R_GFX_DRAW,
	R_NEXT_SPRITE, R_NEXT_HEADER, R_DONE
} render_state_t;
render_state_t state;

logic [8:0] header_index;
logic [1:0] read_word;
logic [63:0] scan_record_q;
logic [15:0] scan_seed_q;
logic [15:0] h0, h1, h2, h3;
// Only consumed during descriptor capture, after the original header read edge.
// Keep h2 unchanged for payload/draw; move its constant Y subtraction off WE.
logic [9:0] scan_header_y_offset;
// Metadata from the same record capture as scan_record_q; target/zoom stay live.
logic [8:0] scan_record_y_origin;
logic [8:0] scan_record_y_last;
logic [8:0] active_y_origin,active_y_last_delta;
wire [8:0] active_y_last=active_y_origin+active_y_last_delta;
// MAME x1_020_dx_101 draw_sprites_line: a normal sprite's firstline/endline
// are signed 10-bit ((sy+yoffs)&0x3ff) and the zoomed scanline is signed
// 11-bit. Comparing them modulo 512 aliased sprites parked at Y -512..-257
// or 256..511 onto visible lines (e.g. a Y -456 tile drawn at line 56).
logic [9:0] scan_record_y_origin10;
// The low nine bits of the 10-bit end line are the registered CSA sum
// scan_record_y_last. The span is below 512, so the 9-bit sum overflowed
// exactly when it is below the origin; bit 9 follows without a RAM-output
// 10-bit three-input adder (that path missed setup by 0.9ns).
wire [9:0] scan_record_y_last10={scan_record_y_origin10[9]
    ^ (scan_record_y_last < scan_record_y_origin),scan_record_y_last};
logic [9:0] active_y_origin10;
wire [9:0] active_y_last10=active_y_origin10+{1'b0,active_y_last_delta};
function automatic normal_y_bounds_contains;
    input [9:0] first_bits, last_bits;
    input integer coordinate;
    reg signed [10:0] first_s,last_s,coordinate_s;
    begin
        first_s=$signed({first_bits[9],first_bits});
        last_s=$signed({last_bits[9],last_bits});
        coordinate_s=$signed(coordinate[10:0]);
        if(last_s>=first_s)
            normal_y_bounds_contains=(coordinate_s>=first_s)&&(coordinate_s<=last_s);
        else
            normal_y_bounds_contains=(coordinate_s<=last_s)||(coordinate_s>=first_s);
    end
endfunction
function automatic [9:0] decode_scan_header_y;
    input [15:0] header0;
    input [15:0] header2;
    begin
        decode_scan_header_y = header2[9:0];
        // Procedural if preserves the original unknown-condition semantics.
        if (header0[14]) decode_scan_header_y = header2[9:0] - 10'h090;
    end
endfunction
logic [15:0] s0, s1, s2, s3;
// Parallel increment carry prefixes shorten the RAM-to-header-count path.
wire [7:0] header_count_raw = h0[7:0];
(* keep *) wire [8:0] header_count_carry;
genvar header_count_bit;
generate
    for (header_count_bit=0; header_count_bit<9; header_count_bit=header_count_bit+1) begin : header_count_prefix
        if (header_count_bit==0) assign header_count_carry[header_count_bit]=1'b1;
        else assign header_count_carry[header_count_bit]=&header_count_raw[header_count_bit-1:0];
    end
endgenerate
logic [8:0] header_count_decoded;
always_comb begin
    // Unknown arithmetic operands produce a wholly unknown original sum.
    case (^header_count_raw)
        1'b0,1'b1: header_count_decoded={1'b0,header_count_raw}^header_count_carry;
        default: header_count_decoded=9'bx;
    endcase
end
logic [8:0] sprites_remaining;
logic [16:0] sprite_pointer;
logic last_header;
logic use_global_size;
logic opaque;
logic [2:0] bpp_mode;
logic flip_x;
logic flip_y;
logic [18:0] tile_code;
logic signed [11:0] tile_screen_x;
logic [2:0] tile_line;
logic [3:0] tiles_x;
logic [3:0] tile_x;
logic [1:0] normal_x_exp;
logic [1:0] normal_y_exp;
logic [3:0] normal_row;
logic [10:0] color_code;
logic [63:0] gfx_line;
logic float_mode;
logic [6:0] float_x;
logic [7:0] float_columns_remaining;
logic [9:0] float_scroll_x;
// Circular1024-pixel source base, prepared when the immutable descriptor
// fields are selected; live video offset and zoom remain in FLOAT_SELECT.
logic [9:0] float_dest_base;
logic [8:0] float_source_line;
logic [4:0] float_page;
logic float_is_16;
logic signed [11:0] float_sx;
logic signed [11:0] float_first_column;
logic signed [11:0] float_last_column;
logic signed [11:0] float_dest_x;
logic [15:0] tilemap_attr;
logic [15:0] tilemap_code;

// Scratch values are consumed only after R_TILEMAP_CAPTURE completes.
// Keep this data capture off the high-fanout synchronous reset cone.
always_ff @(posedge clk) begin
    if (state == R_TILEMAP_CAPTURE) begin
				if (sprite_address[1]) begin
					tilemap_attr <= sprite_q[47:32];
					tilemap_code <= sprite_q[63:48];
				end
				else begin
					tilemap_attr <= sprite_q[15:0];
					tilemap_code <= sprite_q[31:16];
				end
    end
end

logic [10:0] zoomed_target_line;
// BEGIN Y_CLEAR_PIPELINE: sampled on the original clear edge; consumed after clear.
logic [8:0] y_clear_line;
logic [26:0] y_clear_step, y_clear_offset_phase, y_clear_product;
logic y_clear_bypass;
wire [26:0] y_clear_phase = y_clear_product + y_clear_offset_phase;
always_ff @(posedge clk) begin
    if ((ACTIVE_WIDTH >= 24) && (state == R_CLEAR)) begin
        if (clear_x == 9'd0) begin
            y_clear_line <= logical_target_line;
            y_clear_step <= 27'd0 - video_y_zoom;
            y_clear_offset_phase <= 27'h7ffffff - video_y_offset;
            y_clear_bypass <= !video_y_zoom[26];
        end
        if (clear_x == 9'd8)
            y_clear_product <= y_clear_line * y_clear_step;
    end
end
// END Y_CLEAR_PIPELINE
// BEGIN X_SCALE: MAME draw_sprites() X transform. The 27-bit zoom (negated
// when bit 26 is set) Z gives a 16.16 output step inc = 2^32 / Z; each source
// pixel lands at ((x - xoffset) * inc) >> 16. Z > 1.0 shrinks (penbros stage
// start reaches 11x), Z < 1.0 enlarges (penbros round-end zoom-in reaches
// Z = 0x2400, about 7.1x, before the two halves of the screen part like doors).
// A background restoring divider tracks the live register and publishes the
// step, the enlarge column boundaries ceil(c*inc/65536), c=1..8, and the
// floating-column scan count together; each line latches one coherent set.
logic [26:0] x_scale_zoom_q, x_scale_divisor;
logic [32:0] x_scale_quotient;
logic [26:0] x_scale_remainder;
logic [5:0] x_scale_bit;
logic [3:0] x_scale_phase;
logic [26:0] x_scale_multiple;
logic [23:0] x_scale_step;
logic [11:0] x_scale_bound [1:8];
logic [7:0] x_scale_columns;
logic x_scale_zero;
// Published set and per-line latched copy.
logic [23:0] pub_x_step;
logic [11:0] pub_x_bound [1:8];
logic [7:0] pub_x_columns;
logic pub_x_zero, pub_x_shrink, pub_x_wide, pub_x_enlarge;
wire [26:0] x_zoom_magnitude = video_x_zoom[26]
	? (27'h0000000 - video_x_zoom) : video_x_zoom;
wire [35:0] x_scale_span = {x_scale_divisor, 8'd0} + {2'b00, x_scale_divisor, 6'd0};
wire [27:0] x_scale_trial = {x_scale_remainder[26:0], x_scale_quotient[32]};
always_ff @(posedge clk) begin
	if (reset) begin
		x_scale_zoom_q <= 27'h0010000;
		x_scale_divisor <= 27'h0010000;
		x_scale_phase <= 4'd0;
		pub_x_step <= 24'h010000;
		for (int c = 1; c <= 8; c++) pub_x_bound[c] <= 12'(c);
		pub_x_columns <= 8'(LINE_PITCH+2);
		pub_x_zero <= 1'b0;
		pub_x_shrink <= 1'b0;
		pub_x_wide <= 1'b0;
		pub_x_enlarge <= 1'b0;
	end
	else begin
		x_scale_zoom_q <= x_zoom_magnitude;
		case (x_scale_phase)
			4'd0: if (x_scale_zoom_q != x_scale_divisor) begin
				// Restart on any change; quotient bit 32 seeds the shifter.
				x_scale_divisor <= x_scale_zoom_q;
				x_scale_quotient <= 33'h100000000;
				x_scale_remainder <= 27'd0;
				x_scale_bit <= 6'd33;
				x_scale_phase <= 4'd1;
			end
			4'd1: begin
				// One restoring-division quotient bit per clock (33 clocks).
				if (x_scale_trial >= {1'b0, x_scale_divisor}) begin
					x_scale_remainder <= 27'(x_scale_trial - {1'b0, x_scale_divisor});
					x_scale_quotient <= {x_scale_quotient[31:0], 1'b1};
				end
				else begin
					x_scale_remainder <= x_scale_trial[26:0];
					x_scale_quotient <= {x_scale_quotient[31:0], 1'b0};
				end
				x_scale_bit <= x_scale_bit - 6'd1;
				if (x_scale_bit == 6'd1) x_scale_phase <= 4'd2;
			end
			4'd2: begin
				x_scale_zero <= (x_scale_divisor == 27'd0);
				x_scale_step <= (x_scale_quotient[32:24] != 9'd0)
					? 24'hffffff : x_scale_quotient[23:0];
				// Floating columns that can reach the active width, plus margin.
				x_scale_columns <= (x_scale_divisor > 27'h0020000)
					? (((x_scale_span >> 19) + 36'd4 > 36'd128)
						? 8'd128 : 8'((x_scale_span >> 19) + 36'd4))
					: (x_scale_divisor > 27'h0010000) ? 8'(2*LINE_PITCH+4)
					: (x_scale_divisor == 27'h0010000) ? 8'(LINE_PITCH+2)
					: 8'((x_scale_span >> 19) + 36'd4);
				x_scale_multiple <= 27'd0;
				x_scale_phase <= 4'd3;
			end
			4'd11: begin
				// Publish atomically, then wait for the next register change.
				pub_x_step <= x_scale_step;
				for (int c = 1; c <= 8; c++) pub_x_bound[c] <= x_scale_bound[c];
				pub_x_columns <= x_scale_columns;
				pub_x_zero <= x_scale_zero;
				pub_x_shrink <= (x_scale_divisor > 27'h0010000);
				pub_x_wide <= (x_scale_divisor > 27'h0020000);
				pub_x_enlarge <= (x_scale_divisor != 27'd0)
					&& (x_scale_divisor < 27'h0010000);
				x_scale_phase <= 4'd0;
			end
			default: begin
				// Phases 3..10: boundary c = ceil(c*inc/65536), c = 1..8.
				x_scale_bound[x_scale_phase - 4'd2] <=
					12'((({3'd0, x_scale_multiple} + {6'd0, x_scale_step}) + 30'hffff) >> 16);
				x_scale_multiple <= x_scale_multiple + {3'd0, x_scale_step};
				x_scale_phase <= x_scale_phase + 4'd1;
			end
		endcase
	end
end
// END X_SCALE
logic [23:0] map_x_step;
// step*k for k=0..7, registered: map_x_step is latched with the record header,
// many clocks before any tile reaches R_GFX_WAIT, so these are stable by then.
logic [26:0] map_step_mult [0:7];
always_ff @(posedge clk)
    for (int k = 0; k < 8; k++) map_step_mult[k] <= map_x_step * 3'(k);
logic signed [39:0] map_tile_base;
logic signed [11:0] prepared_map_x [0:7];
// Shrunk (zoomed-out) sprites only draw source pixels inside the unzoomed
// active window, source X 0..ACTIVE_WIDTH-1. PCB footage of the penbros
// round-start zoom shows only the playfield; MAME's unbounded transform also
// draws the player/object pool the game parks at source X -272..-248
// (header X offset 0x300), which a shrink of ~5x maps onto the screen.
// tile_screen_x is source X minus the integer X offset, so the window is
// [-offset, ACTIVE_WIDTH-offset) in that coordinate. Unit and enlarged
// views never expose source X outside the window in penbros.
logic signed [12:0] shrink_src_low, shrink_src_high;
always_ff @(posedge clk) begin
    shrink_src_low <= -$signed({video_x_offset[26],video_x_offset[26:16]});
    shrink_src_high <= 13'(ACTIVE_WIDTH)
        - $signed({video_x_offset[26],video_x_offset[26:16]});
end
// Signed13 covers tile_screen_x(-2048..2047) plus0..7 without wrap.
// Prepare during the existing cache wait; live fixed/zoom selection stays at DRAW.
logic signed [12:0] prepared_unit_x [0:7];
reg [14:0] prepared_pen_color [0:7];
reg [7:0] prepared_pen_nonzero;
reg [7:0] prepared_pen_value [0:7];
integer palette_prepare_column;
integer map_prepare_column;
// Enlarge drawing walks each tile in 8-pixel output windows. Lane j of the
// window holds output pixel k = window_k + j; its source column is the count
// of boundaries <= k, and it is valid while k < bound[8].
logic signed [15:0] enlarge_x;
logic [11:0] enlarge_k;
logic [2:0] enlarge_column [0:7];
logic [7:0] enlarge_valid;
logic enlarge_primed;
// Registered per-lane write decisions (visible, target bank, enlarge color and
// opacity). They are loaded on the same edges as prepared_map_x/enlarge_x/
// enlarge_column, so DRAW routes from register outputs only. No state change.
logic [7:0] prepared_map_vis;
logic [7:0] prepared_src_vis;
logic [7:0] prepared_unit_vis;
logic [2:0] prepared_unit_bank [0:7];
logic [2:0] prepared_map_bank [0:7];
logic [7:0] enl_vis;
logic [2:0] enl_bank [0:7];
wire enlarge_draw = line_x_enlarge && !h0[14];
wire shrink_draw = line_x_shrink && !h0[14];
// Registered copies for the DRAW write route: line_x_* and h0 are fixed from the
// record/line latch through every tile, so loading them on WAIT is exact.
logic draw_mode_enlarge, draw_mode_shrink;
logic signed [15:0] enl_row_base;
logic [2:0] enl_first_low;
function automatic [3:0] enlarge_lane;
	input [11:0] k;
	input [11:0] b1, b2, b3, b4, b5, b6, b7, b8;
	input flip;
	reg [2:0] column;
	begin
		column = 3'((k >= b1) + (k >= b2) + (k >= b3) + (k >= b4)
			+ (k >= b5) + (k >= b6) + (k >= b7));
		enlarge_lane = {k < b8, flip ? 3'd7 - column : column};
	end
endfunction

integer calc_sy;
integer calc_sx;
integer calc_firstline;
integer calc_endline;
integer calc_size_x;
integer calc_size_y;
integer calc_line;
integer calc_row;
integer calc_base_code;
integer calc_height;
integer calc_width;
integer calc_scroll_y;
integer calc_tile_x;
integer calc_tile_y;
integer calc_tile_address;
integer calc_dest_x;
integer calc_screen_x;
integer calc_used_line;
logic [7:0] draw_pen [0:7];
integer draw_pixel_x [0:7];
integer draw_calc_column;
integer route_column;
integer route_address;
integer draw_route_column;
integer draw_route_address;
logic [7:0] line_write_enable;
logic [5:0] line_write_row [0:7];
logic [14:0] line_write_data [0:7];
logic [7:0] draw_write_enable;
logic [5:0] draw_write_row [0:7];
logic [14:0] draw_write_data [0:7];
logic [7:0] draw_write_pen [0:7];

function automatic [7:0] mask_pen;
	input [7:0] value;
	input [2:0] mode;
	begin
		case (mode)
			3'd1: mask_pen = (value & 8'h30) >> 4;
			3'd2: mask_pen = value & 8'h07;
			3'd4: mask_pen = value & 8'h0f;
			3'd5: mask_pen = (value & 8'hf0) >> 4;
			3'd6: mask_pen = value & 8'h3f;
			default: mask_pen = value;
		endcase
	end
endfunction

function automatic [8:0] physical_draw_address;
	input [5:0] row;
	input [2:0] column;
	begin
		physical_draw_address = {row, column};
	end
endfunction

function automatic heat_write_enable;
	input draw_enable;
	input rowscroll_target;
	input foreground_occupied;
	begin
		heat_write_enable = draw_enable
			&& !(rowscroll_target && foreground_occupied);
	end
endfunction

// Guardians programs the DX-101's inverted Y zoom as a 16.16 source-line
// step. Unit zoom is 0x7ff0000 (-1.0); the stage-map screen uses 0x7fe0000
// (-2.0), so each physical row advances two source rows. Fixed-position
// headers bypass the global transform in the controller and are handled by
// the caller.
function automatic [10:0] global_source_line;
	input  [8:0] physical_line;
	input [26:0] y_offset;
	input [26:0] y_zoom;
	reg [26:0] offset_phase;
	reg [26:0] source_step;
	reg [26:0] source_phase;
	begin
		if (!y_zoom[26]) begin
			global_source_line = {2'b00, physical_line};
		end
		else begin
			offset_phase = 27'h7ffffff - y_offset;
			// The loading map animates through all 1/32 steps between -2.0
			// and -1.0. Keep fractional offset carry before wrapping the
			// controller's 27-bit phase. This is evaluated once during clear,
			// not on the active-list RAM write-enable path.
			source_step = 27'd0 - y_zoom;
			source_phase = physical_line * source_step + offset_phase;
			global_source_line = source_phase[26:16];
		end
	end
endfunction

// Exact graphics row for the same normal-sprite tile four physical lines
// later. This crosses an 8-pixel tile boundary using the descriptor's
// horizontal size and vertical flip, avoiding speculative sprite-state reads.
function automatic [8:0] scan_add_local(input [8:0] a,b);
reg [3:0] lo,mid0,mid1;
reg [2:0] hi0,hi1;
reg carry6;
begin
    case (^{a,b})
        1'b0,1'b1: begin
            lo={1'b0,a[2:0]}+{1'b0,b[2:0]};
            mid0={1'b0,a[5:3]}+{1'b0,b[5:3]};
            mid1={1'b0,a[5:3]}+{1'b0,b[5:3]}+4'd1;
            hi0=a[8:6]+b[8:6];
            hi1=a[8:6]+b[8:6]+3'd1;
            carry6=mid0[3]|((&(a[5:3]^b[5:3]))&lo[3]);
            scan_add_local={carry6?hi1:hi0,lo[3]?mid1[2:0]:mid0[2:0],lo[2:0]};
        end
        default: scan_add_local=9'hxxx;
    endcase
end
endfunction
function automatic [8:0] scan_last_y_csa(input [8:0] a,b,c);
    reg [8:0] sum_bits,carry_bits;
    begin
        sum_bits=a^b^c;
        carry_bits=((a&b)|(a&c)|(b&c))<<1;
        scan_last_y_csa=scan_add_local(sum_bits,carry_bits);
    end
endfunction
function automatic sprite_intersects_line;
	input [15:0] fh0;
	input [15:0] fh1;
	input [15:0] fh2;
	input [15:0] fh3;
	input [15:0] fs0;
	input [15:0] fs1;
	input  [8:0] physical_line;
	input [10:0] transformed_line;
	input [8:0] prepared_record_y;
	input [8:0] prepared_record_last;
	input [9:0] prepared_record_y10;
	input [9:0] prepared_record_last10;
	integer sy;
	integer first_line;
	integer end_line;
	integer height;
	integer size_y;
	integer width;
	integer used_line;
	begin
		if (fh0[14])
			used_line = physical_line;
		else
			used_line = transformed_line;
		if (fh3[15]) begin
			sy = fs1 & 16'h01ff;
			if (sy & 9'h100) sy = sy - 512;
			sy = sy & 9'h1ff;
			if (sy & 9'h100) sy = sy - 512;
			height = ((((fh0[12] ? fh2 : fs1) & 16'hfc00) >> 10) + 1);
			first_line = prepared_record_y;
			if (first_line & 9'h100) first_line = first_line - 512;
			end_line = first_line + height * 16 - 1;
			width = ((fh0[12] ? fh1 : fs0) & 16'hfc00) >> 10;
			sprite_intersects_line = (width != 0)
				&& wrapped_vertical_y_bounds_contains(prepared_record_y,
                    prepared_record_last,used_line);
		end
		else begin
			sy = fs1 & 16'h01ff;
			if (sy & 9'h100) sy = sy - 512;
			size_y = 1 << ((((fh0[12] ? fh2 : fs1) & 16'h0c00) >> 10));
			first_line = prepared_record_y;
			if (first_line & 9'h100) first_line = first_line - 512;
			end_line = first_line + size_y * 8 - 1;
			sprite_intersects_line = normal_y_bounds_contains(
                prepared_record_y10,prepared_record_last10,used_line);
		end
	end
endfunction

// BEGIN LATE_SCAN_ROTATION: select predicates after coordinate arithmetic.
wire [8:0] scan_flipped_target_line = (target_line < V_ACTIVE)
    ? (V_ACTIVE - 1 - target_line) : target_line;
(* keep *) wire scan_visible_normal = sprite_intersects_line(
    h0,h1,h2,h3,scan_record_q[15:0],scan_record_q[31:16],
    target_line,zoomed_target_line,scan_record_y_origin,scan_record_y_last,
    scan_record_y_origin10,scan_record_y_last10);
(* keep *) wire scan_visible_flipped = sprite_intersects_line(
    h0,h1,h2,h3,scan_record_q[15:0],scan_record_q[31:16],
    scan_flipped_target_line,zoomed_target_line,scan_record_y_origin,scan_record_y_last,
    scan_record_y_origin10,scan_record_y_last10);
wire scan_visible_unknown_rotation = sprite_intersects_line(
    h0,h1,h2,h3,scan_record_q[15:0],scan_record_q[31:16],
    logical_target_line,zoomed_target_line,scan_record_y_origin,scan_record_y_last,
    scan_record_y_origin10,scan_record_y_last10);
logic scan_record_visible;
always_comb begin
    case(rotate_180)
        1'b0: scan_record_visible=scan_visible_normal;
        1'b1: scan_record_visible=scan_visible_flipped;
        default: scan_record_visible=scan_visible_unknown_rotation;
    endcase
end
// END LATE_SCAN_ROTATION
// The intro fire trail raster-scrolls several four-record tilemap groups.
// The first plane uses packed records 12..23; the later full-screen plane uses
// 69..79. Its target moves between groups as the animation advances, and the
// current descriptor's page can still be the unmodified source page when this
// look-ahead renderer reaches it. Reuse the preceding frame's per-line trace
// within the same plane. The later group's base moves by three records at one
// transition, so its matching cannot rely on the record's low two bits; only
// the descriptor covering the requested 64-line window is made active.
wire scan_rowscroll_fire_low =
    (sprite_pointer[16:2] >= 15'd12)
    && (sprite_pointer[16:2] <= 15'd23)
    && (rowscroll_override_record >= 15'd12)
    && (rowscroll_override_record <= 15'd23)
    && (sprite_pointer[3:2] == rowscroll_override_record[1:0]);
wire scan_rowscroll_fire_high =
    (sprite_pointer[16:2] >= 15'd69)
    && (sprite_pointer[16:2] <= 15'd79)
    && (rowscroll_override_record >= 15'd69)
    && (rowscroll_override_record <= 15'd79);
// The full-screen fire plane is first packed at 69..72 immediately after the
// preceding frame's 12..15 group. It is the same raster surface at a new list
// address, so bridge that single transition by the visible 64-line window.
wire scan_rowscroll_fire_bridge =
    (sprite_pointer[16:2] >= 15'd69)
    && (sprite_pointer[16:2] <= 15'd72)
    && (rowscroll_override_record >= 15'd12)
    && (rowscroll_override_record <= 15'd15);
// On the first striped kick frame the game changes records 16..19 from its
// packed page 24 to page 30 with raster writes. The speculative renderer can
// see page 24 before that frame's CPU writes; the prior trace is still the
// correct per-line page/scroll and must win over the stale packed descriptor.
wire scan_rowscroll_fire_early_record =
    (scan_record_q[47:42] == 6'd24)
    && (sprite_pointer[16:2] >= 15'd16)
    && (sprite_pointer[16:2] <= 15'd19);
wire scan_rowscroll_fire_early_page = scan_rowscroll_fire_early_record
    && (rowscroll_override_record >= 15'd16)
    && (rowscroll_override_record <= 15'd19);
wire scan_rowscroll_fire_header =
	(h0[10:8] == 3'd5)
	&& (h1[9:0] == 10'h070) && (h2[8:0] == 9'h080)
	&& (scan_record_q[15:0] == 16'h5000)
	&& (scan_record_q[31:26] == 6'h03);
wire scan_rowscroll_fire_plane = scan_rowscroll_fire_header
	&& (((scan_record_q[47:42] >= 6'd29)
	     && (scan_record_q[47:42] <= 6'd31))
	    || scan_rowscroll_fire_early_page)
	&& (rowscroll_override_data[15:10] >= 6'd29)
	&& (rowscroll_override_data[15:10] <= 6'd31)
	&& (scan_rowscroll_fire_low || scan_rowscroll_fire_high
	    || scan_rowscroll_fire_bridge);
// The first active frame can have no per-line history for a late-packed
// 64-line chunk. Its preceding frame still provides the line-zero fire page
// and scroll. Use that scalar seed for an unwritten page-24 chunk instead of
// exposing the wrong tilemap page as a rectangular band.
wire scan_rowscroll_fire_seed = rowscroll_seed_valid && h3[15]
	&& scan_rowscroll_fire_header && scan_rowscroll_fire_early_record
	&& (rowscroll_seed_data[15:10] >= 6'd29)
	&& (rowscroll_seed_data[15:10] <= 6'd31);
wire scan_rowscroll_target = rowscroll_override_valid
	// Raster IRQ writes happen after the DX-101 has packed the display list into
	// low sprite RAM. The captured address is therefore the packed destination
	// record, exactly the identity carried by sprite_pointer while scanning the
	// rewritten private headers. Stage 1 writes packed records 2 and 3.
	&& h3[15]
	&& ((sprite_pointer[16:2] == rowscroll_override_record)
	    || scan_rowscroll_fire_plane)
	// A packed slot can be reused by a different scene in the next frame.
	// Replay its prior scroll only if the tilemap page and tile-size bits
	// still identify the same kind of floating layer.
	&& ((scan_record_q[47:42] == rowscroll_override_data[15:10])
	    || scan_rowscroll_fire_plane);
// On the very first kick frame there is no preceding-frame raster trace at
// all. The raster handler has already written earlier lines in this frame;
// use its most recent word for the same fire plane until frozen history exists.
// This keeps the early tilemap chunks on the intended graphics page instead
// of exposing the speculative renderer's partially updated packed list.
wire scan_rowscroll_fire_live = !rowscroll_override_valid
	&& rowscroll_live_valid && h3[15] && scan_rowscroll_fire_header
	&& (sprite_pointer[16:2] >= 15'd16)
    && (sprite_pointer[16:2] <= 15'd19)
    && (rowscroll_live_record >= 15'd16)
    && (rowscroll_live_record <= 15'd19)
	&& ((scan_record_q[47:42] == 6'd24)
	    || ((scan_record_q[47:42] >= 6'd29)
	        && (scan_record_q[47:42] <= 6'd31)))
	&& (rowscroll_live_data[15:10] >= 6'd29)
	&& (rowscroll_live_data[15:10] <= 6'd31);
// A frame-accurate native trace shows the late 4-bpp companion header still
// pointing at records 73..76 while software has begun writing the new 5-bpp
// fire surface there. Rendering those live page-30 words with the old 4-bpp
// header selects the lower fire bitplanes and produces one teal/garbled frame.
// Restore the actual buffered word, not a guessed constant page or scroll.
// Only that companion identity/page change is protected; the upper-bitplane
// fire layer and ordinary same-page live scrolls retain their existing path.
wire scan_companion_reused = h3[15] && (h0[10:8] == 3'd4)
	&& (h0[7:0] == 8'd3)
	&& (h1[9:0] == 10'h070) && (h2[8:0] == 9'h080)
	&& (scan_record_q[15:0] == 16'h5000)
	&& (scan_record_q[31:26] == 6'd3)
	&& (scan_seed_q[15:10] == 6'd31)
	&& ((scan_record_q[47:42] == 6'd29)
	    || (scan_record_q[47:42] == 6'd30));
wire [15:0] scan_s2 = scan_companion_reused ? scan_seed_q
	: scan_rowscroll_target
	? rowscroll_override_data
	: scan_rowscroll_fire_live ? rowscroll_live_data
	: scan_rowscroll_fire_seed ? rowscroll_seed_data
	: scan_record_q[47:32];
wire [127:0] scan_record_data = {
	h0, h1, h2, h3,
	scan_record_q[15:0], scan_record_q[31:16],
	scan_s2, scan_record_q[63:48]
};

// Keep the active list as a true synchronous one-write/one-read memory.
// Splitting the 128-bit read into fields in the main state machine causes
// Quartus 17 to implement the array as thousands of registers.
wire final_sprite_tile = float_mode ? (float_columns_remaining == 8'd1)
	: (tile_x + 4'd1 >= tiles_x);
// Publish the terminal index alongside the list count. The hot feedback
// compares directly instead of putting an increment before that comparison.
wire next_active_available = (active_total != 11'd0)
    && ((active_index == 11'h7ff) || (active_index < active_total_last));
wire prefetch_active_record = next_active_available
	&& ((state == R_NEXT_SPRITE)
	    || ((state == R_GFX_DRAW) && final_sprite_tile));
wire [10:0] active_read_index = prefetch_active_record
	? active_index + 11'd1 : active_index;
always_ff @(posedge clk) begin
	if (reset) begin
		scan_record_q <= 64'd0;
		scan_record_y_origin <= 9'd0;
        scan_record_y_last <= 9'd0;
		scan_record_y_origin10 <= 10'd0;
		scan_seed_q <= 16'd0;
	end
	else if ((state == R_SPRITE_PIPE) || (state == R_SPRITE_CAPTURE)) begin
		scan_record_q <= sprite_q;
		scan_record_y_origin <= sprite_q[24:16] + scan_header_y_offset[8:0];
        scan_record_y_last <= scan_last_y_csa(sprite_q[24:16],scan_header_y_offset[8:0],sprite_y_last_delta(h3[15],h0[12],h2,sprite_q[31:16]));
		scan_record_y_origin10 <= {sprite_q[24],sprite_q[24:16]} + scan_header_y_offset;
		scan_seed_q <= sprite_seed_q;
	end
	if ((state == R_SPRITE_CAPTURE) && scan_record_visible
	    && (active_count < 11'd1536))
		active_records[active_count] <= {
			(scan_rowscroll_target || scan_rowscroll_fire_live
			 || scan_rowscroll_fire_seed), scan_record_data
		};
	// A final tile already occupies a RAM-write clock. Use that same clock
	// to read the next descriptor, retaining the registered BRAM boundary.
	if ((state == R_ACTIVE_LOAD) || prefetch_active_record)
		active_record_q <= active_records[active_read_index];
end


// Same existing active-record capture edge; no target/zoom latch or cycle added.
wire [9:0] active_header_y_offset =
    decode_scan_header_y(active_record_q[127:112],active_record_q[95:80]);
always_ff @(posedge clk) begin
    if(reset) begin active_y_origin<=9'd0;active_y_last_delta<=9'd0;active_y_origin10<=10'd0;end
    else if(state==R_ACTIVE_WAIT) begin
        active_y_origin<=active_record_q[40:32] + active_header_y_offset[8:0];
        active_y_origin10<={active_record_q[40],active_record_q[40:32]}
            + active_header_y_offset;
        active_y_last_delta<=sprite_y_last_delta(active_record_q[79],
            active_record_q[124],active_record_q[95:80],active_record_q[47:32]);
    end
end

// MAME's STEP8(0,1) plane offsets and STEP8(7*8,-8) X offsets mean that source
// byte 7 supplies pen bit 7, byte 6 supplies bit 6, ... byte 0 supplies bit 0.
// gfx_line holds four big-endian SDRAM words, lowest-addressed word in [15:0],
// so the two source bytes in each 16-bit word occupy reversed 8-bit slices.
function automatic [7:0] decode_pen;
	input [63:0] row;
	input [2:0] column;
	begin
		decode_pen = {
			row[55-column], row[63-column],
			row[39-column], row[47-column],
			row[23-column], row[31-column],
			row[7-column], row[15-column]
		};
	end
endfunction

always_comb begin
	for (draw_calc_column = 0; draw_calc_column < 8;
	     draw_calc_column = draw_calc_column + 1) begin
		// Masked pen registered with the graphics data (bpp_mode is fixed WAIT..DRAW).
		draw_pen[draw_calc_column] = prepared_pen_value[draw_calc_column];
		draw_pixel_x[draw_calc_column] = $signed(prepared_unit_x[draw_calc_column]);
		// Header bit 14 is the DX-101 fixed-position mode and deliberately
		// bypasses the global scaling. Shrink places each source column at
		// its 16.16 position (the map screen's 2.0x gives exactly x/2);
		// enlarge indexes eight consecutive output pixels of one window.
		if (draw_mode_shrink)
			draw_pixel_x[draw_calc_column] =
				$signed(prepared_map_x[draw_calc_column]);
	end
end

// Route clear or draw writes by X[2:0]. Eight adjacent draw pixels always
// land in eight distinct banks, so every physical RAM has one write port.
always_comb begin
    integer draw_first_x;
    // The prepared unit/half/fractional span is at most seven positions.
    // Flip reverses source-column order; the first physical X is its other end.
    draw_first_x = draw_pixel_x[(flip_x && !draw_mode_enlarge) ? 7 : 0];
	draw_write_enable = 8'd0;
	for (draw_route_column = 0; draw_route_column < 8;
	     draw_route_column = draw_route_column + 1) begin
		draw_write_row[draw_route_column] = draw_mode_enlarge
			? (enl_row_base + (draw_route_column < enl_first_low))
			: ((draw_first_x >>> 3) + (draw_route_column < (draw_first_x & 7)));
		draw_write_data[draw_route_column] = 15'd0;
		draw_write_pen[draw_route_column] = 8'd0;
	end
	for (draw_route_column = 0; draw_route_column < 8;
	     draw_route_column = draw_route_column + 1) begin
		draw_route_address = draw_pixel_x[draw_route_column];
        if (draw_mode_enlarge) begin
            // Window lanes are output pixels; each selects its source column.
            // Visibility, bank, color and opacity were registered with the lane.
            if (enl_vis[draw_route_column] && enlarge_valid[draw_route_column]
                    && (prepared_pen_nonzero[enlarge_column[draw_route_column]] || opaque)) begin
                draw_write_enable[enl_bank[draw_route_column]] = 1'b1;
                draw_write_data[enl_bank[draw_route_column]] =
                    prepared_pen_color[enlarge_column[draw_route_column]];
            end
        end
        else if (draw_mode_shrink) begin
            // Registered X visibility/bank from the same prepared_map_x value.
            if (prepared_map_vis[draw_route_column] && prepared_src_vis[draw_route_column]
                && (draw_pen[draw_route_column] != 0 || opaque)) begin
                draw_write_enable[prepared_map_bank[draw_route_column]] = 1'b1;
                draw_write_pen[prepared_map_bank[draw_route_column]] = draw_pen[draw_route_column];
                draw_write_data[prepared_map_bank[draw_route_column]] = prepared_pen_color[draw_route_column];
            end
        end
        else if (prepared_unit_vis[draw_route_column]) begin
            // All visible candidates for a lane have the same row: the eight
            // unit/half/fractional positions span at most seven output pixels.
            // Keep pen/opacity selection off the RAM address carry/mux path.
            if (draw_pen[draw_route_column] != 0 || opaque) begin
                draw_write_enable[prepared_unit_bank[draw_route_column]] = 1'b1;
				// Last qualifying source column wins, including half/fractional overlap.
				// Route the color computed with this same pen during graphics capture.
				draw_write_pen[prepared_unit_bank[draw_route_column]] = draw_pen[draw_route_column];
				draw_write_data[prepared_unit_bank[draw_route_column]] = prepared_pen_color[draw_route_column];
            end
		end
	 end

end

always_comb begin
	line_write_enable = 8'd0;
	route_address = 0;
	for (route_column = 0; route_column < 8;
	     route_column = route_column + 1) begin
		line_write_row[route_column] = 6'd0;
		line_write_data[route_column] = 15'd0;
	end
	if (state == R_CLEAR) begin
		for (route_column = 0; route_column < 8;
		     route_column = route_column + 1) begin
			route_address = clear_x + route_column;
			line_write_enable[route_address & 7] = 1'b1;
			line_write_row[route_address & 7] = route_address >> 3;
			line_write_data[route_address & 7] = 15'd0;
		end
	end
	else if (state == R_GFX_DRAW) begin
		for (route_column = 0; route_column < 8;
		     route_column = route_column + 1) begin
			line_write_enable[route_column] = heat_write_enable(
				draw_write_enable[route_column], record_rowscroll_target,
				foreground_occupancy_bank[route_column][draw_write_row[route_column]]);
			line_write_row[route_column] = draw_write_row[route_column];
			line_write_data[route_column] = draw_write_data[route_column];
		end
	end
end

// Line-buffer write port is registered: the crossbar/priority routing above ends
// at these registers and the M10K sees short register-to-RAM nets. Occupancy and
// all renderer decisions still use the unregistered routing, so ordering of clear
// and draw writes is unchanged; physical RAM writes land one clock later.
logic [7:0] lw_en_q;
logic [5:0] lw_row_q [0:7];
logic [14:0] lw_data_q [0:7];
logic [3:0] lw_bank_q;
integer lw_column;
always_ff @(posedge clk) begin
	lw_en_q <= reset ? 8'd0 : line_write_enable;
	lw_bank_q <= work_bank;
	for (lw_column = 0; lw_column < 8; lw_column = lw_column + 1) begin
		lw_row_q[lw_column] <= line_write_row[lw_column];
		lw_data_q[lw_column] <= line_write_data[lw_column];
	end
end
integer occupancy_column;
always_ff @(posedge clk) begin
	if (reset || ((state == R_CLEAR) && (clear_x == 9'd0))) begin
		for (occupancy_column = 0; occupancy_column < 8;
		     occupancy_column = occupancy_column + 1)
			foreground_occupancy_bank[occupancy_column] <= '0;
	end
	else if ((state == R_GFX_DRAW) && !float_mode) begin
		for (occupancy_column = 0; occupancy_column < 8;
		     occupancy_column = occupancy_column + 1) begin
			if (draw_write_enable[occupancy_column])
				foreground_occupancy_bank[occupancy_column]
					[draw_write_row[occupancy_column]] <= 1'b1;
		end
	end

	line_read_data[0] <= line_buffer_bank0[line_read_address];
	line_read_data[1] <= line_buffer_bank1[line_read_address];
	line_read_data[2] <= line_buffer_bank2[line_read_address];
	line_read_data[3] <= line_buffer_bank3[line_read_address];
	line_read_data[4] <= line_buffer_bank4[line_read_address];
	line_read_data[5] <= line_buffer_bank5[line_read_address];
	line_read_data[6] <= line_buffer_bank6[line_read_address];
	line_read_data[7] <= line_buffer_bank7[line_read_address];
	if (lw_en_q[0]) begin
		line_buffer_bank0[packed_line_address(lw_bank_q, lw_row_q[0])]
			<= lw_data_q[0];
	end
	if (lw_en_q[1]) begin
		line_buffer_bank1[packed_line_address(lw_bank_q, lw_row_q[1])]
			<= lw_data_q[1];
	end
	if (lw_en_q[2]) begin
		line_buffer_bank2[packed_line_address(lw_bank_q, lw_row_q[2])]
			<= lw_data_q[2];
	end
	if (lw_en_q[3]) begin
		line_buffer_bank3[packed_line_address(lw_bank_q, lw_row_q[3])]
			<= lw_data_q[3];
	end
	if (lw_en_q[4]) begin
		line_buffer_bank4[packed_line_address(lw_bank_q, lw_row_q[4])]
			<= lw_data_q[4];
	end
	if (lw_en_q[5]) begin
		line_buffer_bank5[packed_line_address(lw_bank_q, lw_row_q[5])]
			<= lw_data_q[5];
	end
	if (lw_en_q[6]) begin
		line_buffer_bank6[packed_line_address(lw_bank_q, lw_row_q[6])]
			<= lw_data_q[6];
	end
	if (lw_en_q[7]) begin
		line_buffer_bank7[packed_line_address(lw_bank_q, lw_row_q[7])]
			<= lw_data_q[7];
	end
end

always_ff @(posedge clk) begin
	if (reset) begin
		state <= R_IDLE;
		busy <= 1'b0;
		line_done <= 1'b0;
		display_bank <= 4'd0;
		boundary_bank <= 4'd0;
		boundary_bank_found <= 1'b0;
		work_bank <= 4'd1;
		bank_valid <= 13'd0;
		for (line_bank_index = 0; line_bank_index < 13;
		     line_bank_index = line_bank_index + 1)
			bank_line[line_bank_index] <= 9'd0;
		scheduler_started <= 1'b0;
		schedule_pending <= 1'b0;
		next_render_line <= 9'd0;
		target_line <= 9'd0;
		clear_x <= 9'd0;
		active_count <= 11'd0;
		begin active_total <= 11'd0; active_total_last <= 11'(11'd0) - 11'd1; end
		active_index <= 11'd0;
		record_rowscroll_target <= 1'b0;
		sprite_address <= 17'd0;
		gfx_addr <= 25'd0;
		gfx_req <= 1'b0;
		missed_lines <= 16'd0;
		zoomed_target_line <= 11'd0;
		map_x_step <= 24'h010000;
		map_tile_base <= 40'sd0;
		for (int c = 1; c <= 8; c++) line_x_bound[c] <= 12'(c);
		line_x_columns <= 8'(LINE_PITCH+2);
		line_x_zero <= 1'b0;
		line_x_shrink <= 1'b0;
		line_x_wide <= 1'b0;
		line_x_enlarge <= 1'b0;
		enlarge_x <= 16'sd0;
		enlarge_k <= 12'd0;
		enlarge_valid <= 8'd0;
		enlarge_primed <= 1'b0;
		for (map_prepare_column = 0; map_prepare_column < 8;
		     map_prepare_column = map_prepare_column + 1)
			prepared_map_x[map_prepare_column] <= 12'sd0;
	end
	else begin
		line_done <= 1'b0;
		if (ce_pix && (h_count == H_TOTAL - 3)) begin
			boundary_bank <= prefetch_bank;
			boundary_bank_found <= |prefetch_match;
		end
		if (ce_pix && (h_count == 9'd0)) begin
			// Select only the line tagged for the physical raster. If DDR latency
			// makes one line unusually expensive, keep displaying the prior
			// completed line while the look-ahead queue catches up. Never substitute
			// a different completed row: that duplicates a full scanline through
			// both the rowscrolled background and foreground actors.
			if (boundary_bank_found) begin
				if (display_bank != boundary_bank)
					bank_valid[display_bank] <= 1'b0;
				display_bank <= boundary_bank;
			end
			else if (scheduler_started && (v_count < V_ACTIVE))
				missed_lines <= missed_lines + 16'd1;

			// Reclaim completed lines that arrived after their display slot.
			for (line_bank_index = 0; line_bank_index < 13;
			     line_bank_index = line_bank_index + 1) begin
				if ((line_bank_index != display_bank)
				    && !display_match[line_bank_index]
				    && bank_valid[line_bank_index]
				    && (line_forward_distance(bank_line[line_bank_index], v_count)
				        > 9'd0)
				    && (line_forward_distance(bank_line[line_bank_index], v_count)
				        <= V_HALF))
					bank_valid[line_bank_index] <= 1'b0;
			end

			schedule_pending <= 1'b1;
			if (!scheduler_started) begin
				scheduler_started <= 1'b1;
				// A cold renderer cannot finish the immediately following row before
				// its display slot. Seed it at the far end of the reservoir, then
				// render consecutive rows while the raster catches up. Exact-only
				// display selection otherwise remains permanently one row behind and
				// repeats the startup row over the whole frame.
				next_render_line <= recovery_render_line;
			end
			else if ((render_distance == 9'd0) || (render_distance > V_HALF))
				// Re-lock the same way after a genuinely late row. Twelve lines of
				// lead are available without consuming another M10K.
				next_render_line <= recovery_render_line;
		end

		// Sprite-list DMA now reads on the CPU RAM port. The renderer owns the
		// video port continuously, so a copy must not abort its in-flight row.
		case (state)
			R_IDLE: begin
				// Keep up to twelve completed rows ahead. This absorbs the clustered
				// tile-cache misses from wide floating layers instead of repeating
				// a stale whole scanline through foreground actors. Frozen rowscroll
				// history makes this safe during the Stage 1 heat effect as well.
				if (scheduler_started && free_bank_found
				    && (lookahead_ready
				        || (!AHEAD_RENDER && schedule_pending))) begin
					work_bank <= free_bank;
					bank_valid[free_bank] <= 1'b0;
					target_line <= AHEAD_RENDER
						? next_render_line
						: physical_next_line;
					clear_x <= 9'd0;
					active_count <= 11'd0;
					begin active_total <= 11'd0; active_total_last <= 11'(11'd0) - 11'd1; end
					active_index <= 11'd0;
					busy <= 1'b1;
					schedule_pending <= 1'b0;
					state <= R_CLEAR;
				end
			end
			R_CLEAR: begin
				if (clear_x == 9'd0) begin
                    if (ACTIVE_WIDTH < 24)
                        zoomed_target_line <= global_source_line(logical_target_line,
                            video_y_offset, video_y_zoom);
					map_x_step <= pub_x_step;
					for (int c = 1; c <= 8; c++) line_x_bound[c] <= pub_x_bound[c];
					line_x_columns <= pub_x_columns;
					line_x_zero <= pub_x_zero;
					line_x_shrink <= pub_x_shrink;
					line_x_wide <= pub_x_wide;
					line_x_enlarge <= pub_x_enlarge;
				end
                if ((ACTIVE_WIDTH >= 24) && (clear_x == 9'd16)) begin
                    if (y_clear_bypass)
                        zoomed_target_line <= {2'b00, y_clear_line};
                    else
                        zoomed_target_line <= y_clear_phase[26:16];
                end
				if (clear_x == 9'(ACTIVE_WIDTH-8)) begin
					// The native controller is blank below line 231. Do not rescan and
					// draw the full sprite list for invisible rows; completing them after
					// clear lets the reservoir refill before the next active frame.
					// MAME draws nothing at all while X zoom is zero.
					if ((target_line >= V_ACTIVE) || line_x_zero)
						state <= R_DONE;
					else begin
						header_index <= 9'd0;
						read_word <= 2'd0;
						state <= R_HEADER_ISSUE;
					end
				end
				else clear_x <= clear_x + 9'd8;
			end

			R_HEADER_ISSUE: begin
				sprite_address <= 17'h01800 + {header_index, 2'b00};
				state <= R_HEADER_WAIT;
			end
			R_HEADER_WAIT: state <= R_HEADER_CAPTURE;
			R_HEADER_CAPTURE: begin
				// Only consumed after the completed scan enters R_ACTIVE_LOAD.
				// Final-record completion still overwrites the exact final total.
				begin active_total <= active_count; active_total_last <= 11'(active_count) - 11'd1; end
				h0 <= sprite_q[15:0];
				h1 <= sprite_q[31:16];
				h2 <= sprite_q[47:32];
				scan_header_y_offset <= decode_scan_header_y(sprite_q[15:0], sprite_q[47:32]);
				h3 <= sprite_q[63:48];
				last_header <= sprite_q[15];

				sprite_pointer <= {sprite_q[62:48], 2'b00};
				sprite_address <= {sprite_q[62:48], 2'b00};
				// A saturated packed-list pointer is outside the 0x3000-byte
				// descriptor area; never treat base-list headers as sprites.
				if (sprite_q[62:48] >= 15'h0600) begin
					if (sprite_q[15]) begin
						active_index <= 11'd0;
						state <= (active_count == 11'd0)
							? R_DONE : R_ACTIVE_LOAD;
					end
					else begin
						header_index <= header_index + 9'd1;
						state <= R_HEADER_ISSUE;
					end
				end
				else state <= R_SPRITE_WAIT;
			end

			// The wait clocks the initial descriptor address into the four-bank
			// RAM. R_SPRITE_PIPE registers its output before the visibility
			// filter, breaking the RAM-to-filter timing path. Thereafter each
			// capture consumes one record and registers the next one, sustaining
			// one 64-bit descriptor per renderer clock.
			R_SPRITE_ISSUE: state <= R_SPRITE_WAIT;
			R_SPRITE_WAIT: begin
                // Decode the header captured on the preceding edge, before PIPE.
                sprites_remaining <= header_count_decoded;
				if (header_count_decoded > 9'd1)
					sprite_address <= sprite_pointer + 17'd4;
				else if (!last_header)
					sprite_address <= 17'h01800
						+ {(header_index + 9'd1), 2'b00};
				state <= R_SPRITE_PIPE;
			end
			R_SPRITE_PIPE: begin
				if (sprites_remaining > 9'd2)
					sprite_address <= sprite_pointer + 17'd8;
				else if ((sprites_remaining == 9'd2) && !last_header)
					sprite_address <= 17'h01800
						+ {(header_index + 9'd1), 2'b00};
				state <= R_SPRITE_CAPTURE;
			end
			R_SPRITE_CAPTURE: begin
				if (scan_record_visible && (active_count < 11'd1536)) begin
					active_count <= active_count + 11'd1;
				end

				if (sprites_remaining == 9'd1) begin
					if (last_header) begin
						begin active_total <= active_count
							+ ((scan_record_visible
							    && (active_count < 11'd1536)) ? 11'd1 : 11'd0); active_total_last <= (scan_record_visible && (active_count < 11'd1536)) ? active_count : (active_count - 11'd1); end
						active_index <= 11'd0;
						if ((active_count == 11'd0) && !scan_record_visible)
							state <= R_DONE;
						else state <= R_ACTIVE_LOAD;
					end
					else begin
						header_index <= header_index + 9'd1;
						state <= R_HEADER_CAPTURE;
					end
				end
				else begin
					sprites_remaining <= sprites_remaining - 9'd1;
					sprite_pointer <= sprite_pointer + 17'd4;
					if (sprites_remaining == 9'd3) begin
						if (!last_header)
							sprite_address <= 17'h01800
								+ {(header_index + 9'd1), 2'b00};
					end
					else if (sprites_remaining > 9'd3)
						sprite_address <= sprite_pointer + 17'd12;
				end
			end

			R_ACTIVE_LOAD: begin
				state <= R_ACTIVE_WAIT;
			end
			R_ACTIVE_WAIT: begin
				record_rowscroll_target <= active_record_q[128];
				h0 <= active_record_q[127:112];
				h1 <= active_record_q[111:96];
				h2 <= active_record_q[95:80];
				h3 <= active_record_q[79:64];
				s0 <= active_record_q[63:48];
				s1 <= active_record_q[47:32];
				s2 <= active_record_q[31:16];
				s3 <= active_record_q[15:0];
				use_global_size <= active_record_q[124];
				opaque <= active_record_q[125];
				bpp_mode <= active_record_q[122:120];
				state <= R_SPRITE_PROCESS;
			end

			R_SPRITE_PROCESS: begin
				// Inverted Y zoom is a 16.16 physical-to-source step. Gameplay
				// normally uses -1.0, while the stage-map screen uses -2.0 to
				// shrink its non-fixed layers by half. Header bit 14 bypasses the
				// global transform and uses the physical raster line directly.
				if (h0[14] || !video_y_zoom[26])
					calc_used_line = logical_target_line;
				else
					calc_used_line = zoomed_target_line;
				if (h3[15]) begin
					calc_sy = s1 & 16'h01ff;
					if (calc_sy & 9'h100) calc_sy = calc_sy - 512;
					if (h0[14]) calc_sy = calc_sy - 16'h90;
					calc_sy = calc_sy & 9'h1ff;
					if (calc_sy & 9'h100) calc_sy = calc_sy - 512;
					calc_height = (((use_global_size ? h2 : s1)
						& 16'hfc00) >> 10) + 1;
					calc_firstline = active_y_origin;
					if (calc_firstline & 9'h100) calc_firstline = calc_firstline - 512;
					calc_endline = calc_firstline + calc_height * 16 - 1;
					calc_sx = s0 & 16'h03ff;
					if (h0[14]) calc_sx = calc_sx - 16'h80;
					calc_width = ((use_global_size ? h1 : s0) & 16'hfc00) >> 10;
					calc_dest_x = (calc_sx + (h1 & 16'h03ff)) & 10'h3ff;
					calc_dest_x = (calc_dest_x & 10'h1ff)
						- (calc_dest_x & 10'h200);
					if ((calc_width == 0)
					    || !wrapped_vertical_y_bounds_contains(active_y_origin,active_y_last,calc_used_line))
						state <= R_NEXT_SPRITE;
					else begin
						calc_scroll_y = s3 & 16'h01ff;
						if (h0[14]) calc_scroll_y = calc_scroll_y - 16'h90;
						float_mode <= 1'b1;
						float_scroll_x <= s2[9:0];
						float_source_line <= (calc_used_line - calc_scroll_y) & 9'h1ff;
						float_page <= s2[14:10];
						float_is_16 <= s2[15];
						float_sx <= calc_sx;
						float_first_column <= calc_dest_x;
						float_last_column <= calc_dest_x + calc_width * 16 - 1;
						// Begin at the first source tile that can touch the
						// active screen. The scan length follows the visible
						// source width: 40 columns at unit, 80 at half scale,
						// the whole 128-column ring beyond about 3x shrink.
						calc_screen_x = h0[14] ? 0
							: $signed({video_x_offset[26],
							           video_x_offset[26:16]})
							  - (line_x_shrink ? 7 : 0);
						calc_dest_x = calc_sx + s2[9:0]
							+ (h1 & 16'h03ff) + 16'h10;
						float_dest_base <= calc_dest_x[9:0];
						calc_tile_x = (calc_screen_x - calc_dest_x) & 10'h3ff;
						float_x <= (calc_tile_x >> 3) & 7'h7f;
						float_columns_remaining <= h0[14] ? 8'(LINE_PITCH+2)
							: line_x_columns;
						state <= R_FLOAT_SELECT;
					end
				end
				else begin
					float_mode <= 1'b0;
					calc_sy = s1 & 16'h01ff;
					if (calc_sy & 9'h100) calc_sy = calc_sy - 512;
					if (h0[14]) calc_sy = calc_sy - 16'h90;
					calc_size_y = 1 << (((use_global_size ? h2 : s1)
						& 16'h0c00) >> 10);
					calc_firstline = active_y_origin;
					if (calc_firstline & 9'h100) calc_firstline = calc_firstline - 512;
					calc_endline = calc_firstline + calc_size_y * 8 - 1;
					if (normal_y_bounds_contains(active_y_origin10,active_y_last10,calc_used_line)) begin
						normal_x_exp <= ((use_global_size ? h1 : s0)
							& 16'h0c00) >> 10;
						normal_y_exp <= ((use_global_size ? h2 : s1)
							& 16'h0c00) >> 10;
						calc_size_x = 1 << (((use_global_size ? h1 : s0)
							& 16'h0c00) >> 10);
						calc_sx = ((s0 + (h1 & 16'h03ff)) & 10'h1ff)
							- ((s0 + (h1 & 16'h03ff)) & 10'h200);
						if (h0[14]) calc_sx = calc_sx - 16'h80;
						calc_line = (calc_used_line - calc_firstline) & 511;
						calc_row = calc_line >> 3;
						normal_row <= calc_row[3:0];
						flip_x <= s2[4];
						flip_y <= s2[3];
						tile_line <= s2[3] ? (3'd7 - calc_line[2:0])
							: calc_line[2:0];
						tiles_x <= calc_size_x[3:0];
						tile_x <= 4'd0;
						color_code <= h0[14] ? 11'h7ff : s2[15:5];
						// Offset X is a signed 11-bit pixel value in the high
						// half of the 27-bit register pair. Fixed-position
						// headers bypass it (their -0x80 adjustment is above).
						if (!h0[14])
							calc_sx = calc_sx
								- $signed({video_x_offset[26],
								           video_x_offset[26:16]});
						tile_screen_x <= calc_sx;
						state <= R_NORMAL_PREP;
					end
					else state <= R_NEXT_SPRITE;
				end
			end

			R_NORMAL_PREP: begin
				map_tile_base <= $signed(tile_screen_x) * $signed({1'b0, map_x_step});
				// Pipeline the normal-sprite tile-number calculation. Express
				// its power-of-two products as shifts so this address path does
				// not infer a DSP multiplier between sprite RAM and the cache.
				calc_size_x = 1 << normal_x_exp;
				calc_size_y = 1 << normal_y_exp;
                // Base and row have x_exp zero low bits; the column fits there.
                calc_base_code = (({s2[2:0], s3}
                    & normal_alignment_mask(normal_x_exp,normal_y_exp))
                    + ((s2[3] ? (calc_size_y - 1 - normal_row)
                        : normal_row) << normal_x_exp))
                    | (s2[4] ? calc_size_x - 1 : 0);
                // Preserve reference four-state arithmetic in simulation.
                // synthesis translate_off
                if ((^{normal_x_exp,normal_y_exp,normal_row,s2[4:0],s3}) === 1'bx) begin
				calc_base_code = ({s2[2:0], s3}
					& ~((1 << ({1'b0, normal_x_exp}
					             + {1'b0, normal_y_exp})) - 1))
					+ ((s2[3] ? (calc_size_y - 1 - normal_row)
						: normal_row) << normal_x_exp)
					+ (s2[4] ? calc_size_x - 1 : 0);
                end
                // synthesis translate_on
				tile_code <= calc_base_code[18:0];
				gfx_addr <= {calc_base_code[18:0], 6'd0}
					+ {19'd0, tile_line, 3'd0};
				gfx_req <= ~gfx_req;
				state <= R_GFX_WAIT;
			end

			R_FLOAT_SELECT: begin
				// A floating tilemap covers a 1024-pixel circular row. Unit
				// zoom needs about 40 entries for a 304-pixel scanline; the
				// loading screen's half-scale mode needs about 80.
				// Both legacy wrapping operations reduce to signed10(D).
				// Explicit10-bit addition performs the same modulo1024 wrap.
				calc_dest_x = $signed(10'(float_dest_base + {float_x, 3'b000}));
				calc_screen_x = calc_dest_x;
				if (!h0[14])
					calc_screen_x = calc_screen_x
						- $signed({video_x_offset[26],
						           video_x_offset[26:16]});
				if (!wrapped_column_bounds_contains(
				        $signed(10'(float_first_column - 12'sd8)),
				        $signed(float_last_column[9:0]),
				        $signed(10'(calc_dest_x)))
				    || (calc_dest_x < $signed(float_clip_low))
                    || (calc_dest_x >= $signed(float_clip_high))) begin
					if (float_columns_remaining == 8'd1)
						state <= R_NEXT_SPRITE;
					else begin
						float_x <= float_x + 7'd1;
						float_columns_remaining <= float_columns_remaining - 8'd1;
					end
				end
				else begin
					float_dest_x <= calc_screen_x;
					calc_tile_x = float_is_16 ? (float_x >> 1) : float_x;
					calc_tile_y = float_source_line >> (float_is_16 ? 4 : 3);
					calc_tile_y = calc_tile_y ^ 31;
					calc_tile_address = (float_page << 12)
						+ ((calc_tile_y & 31) << 7)
						+ ((calc_tile_x & 63) << 1);
					sprite_address <= calc_tile_address[16:0];
					read_word <= 2'd0;
					state <= R_TILEMAP_WAIT;
				end
			end

			R_TILEMAP_WAIT: state <= R_TILEMAP_CAPTURE;
			R_TILEMAP_CAPTURE: state <= R_TILEMAP_PROCESS;
			R_TILEMAP_PROCESS: begin
				map_tile_base <= $signed(float_dest_x) * $signed({1'b0, map_x_step});
				begin
					calc_base_code = {tilemap_attr[2:0], tilemap_code};
					if (float_is_16) begin
						calc_base_code = calc_base_code & ~3;
						if ((!tilemap_attr[4] && float_x[0])
						    || (tilemap_attr[4] && !float_x[0]))
							calc_base_code = calc_base_code + 1;
						if ((!tilemap_attr[3] && float_source_line[3])
						    || (tilemap_attr[3] && !float_source_line[3]))
							calc_base_code = calc_base_code + 2;
					end
					flip_x <= tilemap_attr[4];
					flip_y <= tilemap_attr[3];
					tile_code <= calc_base_code[18:0];
					tile_screen_x <= float_dest_x;
					tile_line <= tilemap_attr[3] ? (3'd7 - float_source_line[2:0])
						: float_source_line[2:0];
					color_code <= tilemap_attr[15:5];
					gfx_addr <= {calc_base_code[18:0], 6'd0}
						+ {19'd0, (tilemap_attr[3]
						? (3'd7 - float_source_line[2:0])
						: float_source_line[2:0]), 3'd0};
					gfx_req <= ~gfx_req;
					state <= R_GFX_WAIT;
				end
			end

			R_GFX_WAIT: begin
				for (map_prepare_column = 0; map_prepare_column < 8;
				     map_prepare_column = map_prepare_column + 1) begin
					logic signed [12:0] unit_x_value;
					unit_x_value = $signed({tile_screen_x[11], tile_screen_x})
						+ 13'(flip_x ? (7 - map_prepare_column) : map_prepare_column);
					prepared_unit_x[map_prepare_column] <= unit_x_value;
					prepared_src_vis[map_prepare_column] <= (unit_x_value >= shrink_src_low)
						&& (unit_x_value < shrink_src_high);
					prepared_unit_vis[map_prepare_column] <= (unit_x_value >= 0) && (unit_x_value < ACTIVE_WIDTH);
					prepared_unit_bank[map_prepare_column] <= unit_x_value[2:0];
				end
				// Prepare fractional X during the existing cache wait. Do not add
				// a tile state: even one extra clock can exhaust the line reservoir
				// during the intro. Unit and exact half-scale writes retain their
				// original direct coordinates and transparent-pixel priority.
				for (map_prepare_column = 0; map_prepare_column < 8;
					     map_prepare_column = map_prepare_column + 1) begin
						logic signed [11:0] map_x_value;
						map_x_value = 12'(($signed(map_tile_base)
							+ $signed({1'b0, flip_x ? map_step_mult[7 - map_prepare_column]
							                       : map_step_mult[map_prepare_column]})) >>> 16);
						prepared_map_x[map_prepare_column] <= map_x_value;
						prepared_map_vis[map_prepare_column] <=
							(map_x_value >= 0) && (map_x_value < ACTIVE_WIDTH);
						prepared_map_bank[map_prepare_column] <= map_x_value[2:0];
					end
				// Enlarge: first output pixel of the tile, skipping whole windows
				// left of column 0. The first DRAW clock primes the lane columns.
				begin
					logic signed [23:0] enlarge_base;
					logic [15:0] enlarge_skip;
					enlarge_base = map_tile_base[39:16];
					if (enlarge_base > 24'sd16383) enlarge_base = 24'sd16384;
					else if (enlarge_base < -24'sd16384) enlarge_base = -24'sd16384;
					enlarge_skip = (enlarge_base < 0) ? (16'(-enlarge_base) & 16'hfff8) : 16'd0;
					enlarge_x <= 16'(enlarge_base) + enlarge_skip;
					enlarge_k <= (enlarge_skip > 16'd4088) ? 12'd4088 : enlarge_skip[11:0];
					enlarge_valid <= 8'd0;
					enlarge_primed <= 1'b0;
					draw_mode_enlarge <= enlarge_draw;
					draw_mode_shrink <= shrink_draw;
				end
				if (gfx_ack == gfx_req) begin
					gfx_line <= gfx_dout;
				// Palette arithmetic precedes live coordinate/priority selection.
				// Descriptor color/bpp stay fixed from WAIT through DRAW.
				for (palette_prepare_column = 0; palette_prepare_column < 8;
				     palette_prepare_column = palette_prepare_column + 1)
					prepared_pen_color[palette_prepare_column] <=
						({color_code, 4'd0} + mask_pen(decode_pen(gfx_dout,
						 palette_prepare_column[2:0]), bpp_mode)) & 15'h7fff;
				for (palette_prepare_column = 0; palette_prepare_column < 8;
				     palette_prepare_column = palette_prepare_column + 1)
					prepared_pen_value[palette_prepare_column] <=
						mask_pen(decode_pen(gfx_dout, palette_prepare_column[2:0]), bpp_mode);
				for (palette_prepare_column = 0; palette_prepare_column < 8;
				     palette_prepare_column = palette_prepare_column + 1)
					prepared_pen_nonzero[palette_prepare_column] <=
						mask_pen(decode_pen(gfx_dout, palette_prepare_column[2:0]),
						         bpp_mode) != 8'd0;
					state <= R_GFX_DRAW;
				end
			end
			R_GFX_DRAW: begin
				// Enlarge: a priming clock (no lane valid yet), then one clock per
				// 8-pixel output window until the tile ends or leaves the right edge.
				if (enlarge_draw && (!enlarge_primed
				    || (({4'd0, enlarge_k} + 16'd8 < {4'd0, line_x_bound[8]})
				        && (enlarge_x + 16'sd8 < 16'(ACTIVE_WIDTH))))) begin
					for (int j = 0; j < 8; j++) begin
						logic [3:0] lane;
						lane = enlarge_lane(
							enlarge_primed ? enlarge_k + 12'(8 + j) : enlarge_k + 12'(j),
							line_x_bound[1], line_x_bound[2], line_x_bound[3], line_x_bound[4],
							line_x_bound[5], line_x_bound[6], line_x_bound[7], line_x_bound[8],
							flip_x);
						enlarge_valid[j] <= lane[3];
						enlarge_column[j] <= lane[2:0];
					end
					// Registered visibility/bank for the window loaded this edge. The priming
					// clock uses the registered enlarge_x (no writes until the next clock);
					// later windows use enlarge_x + 8.
					begin
						logic signed [15:0] win_x;
						win_x = enlarge_primed ? (enlarge_x + 16'sd8) : enlarge_x;
						enl_row_base <= win_x >>> 3;
						enl_first_low <= win_x[2:0];
					end
					for (int j = 0; j < 8; j++) begin
						integer lane_x;
						lane_x = (enlarge_primed ? $signed(enlarge_x + 16'sd8) : $signed(enlarge_x)) + j;
						enl_vis[j] <= (lane_x >= 0) && (lane_x < ACTIVE_WIDTH);
						enl_bank[j] <= lane_x[2:0];
					end
					if (enlarge_primed) begin
						enlarge_k <= enlarge_k + 12'd8;
						enlarge_x <= enlarge_x + 16'sd8;
					end
					enlarge_primed <= 1'b1;
				end
				else if (float_mode) begin
					if (float_columns_remaining == 8'd1) begin
						if (next_active_available) begin
							active_index <= active_index + 11'd1;
							state <= R_ACTIVE_WAIT;
						end
						else state <= R_DONE;
					end
					else begin
						float_x <= float_x + 7'd1;
						float_columns_remaining <= float_columns_remaining - 8'd1;
						state <= R_FLOAT_SELECT;
					end
				end
				else if (tile_x + 4'd1 < tiles_x) begin
					tile_x <= tile_x + 4'd1;
					tile_screen_x <= tile_screen_x + 12'sd8;
					map_tile_base <= map_tile_base + $signed({1'b0, map_x_step, 3'b000});
					tile_code <= flip_x ? tile_code - 19'd1 : tile_code + 19'd1;
					gfx_addr <= {(flip_x ? tile_code - 19'd1
						: tile_code + 19'd1), 6'd0} + {19'd0, tile_line, 3'd0};
					gfx_req <= ~gfx_req;
					state <= R_GFX_WAIT;
				end
				else if (next_active_available) begin
					active_index <= active_index + 11'd1;
					state <= R_ACTIVE_WAIT;
				end
				else state <= R_DONE;
			end

			R_NEXT_SPRITE: begin
				if (!next_active_available)
					state <= R_DONE;
				else begin
					active_index <= active_index + 11'd1;
					state <= R_ACTIVE_WAIT;
				end
			end
			R_NEXT_HEADER: state <= R_DONE;
			R_DONE: begin
				line_done <= 1'b1;
				bank_valid[work_bank] <= 1'b1;
				bank_line[work_bank] <= target_line;
				next_render_line <= (target_line == V_TOTAL - 1)
					? 9'd0 : target_line + 9'd1;
				busy <= 1'b0;
				state <= R_IDLE;
			end
			default: state <= R_IDLE;
		endcase
	end
end

endmodule
