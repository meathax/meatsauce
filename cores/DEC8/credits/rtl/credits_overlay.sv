// SPDX-License-Identifier: MIT
// Native progressive video overlay. All inputs are in clk_video except the
// menu trigger / dismiss, which have their own two-register synchronizers.
module credits_overlay #(
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 240,
    parameter integer SCALE_LOG2 = 0,
    parameter integer SCROLL_FRAMES = 4,
    parameter [23:0] PANEL_COLOR = 24'h1a151f,
    parameter [23:0] GOLD_LIGHT = 24'hffe5a0,
    parameter [23:0] GOLD_MID = 24'he9b949,
    parameter [23:0] GOLD_DARK = 24'hb77924,
    parameter [23:0] MEAT_LIGHT = 24'hffc0b6,
    parameter [23:0] MEAT_MID = 24'hd97b79,
    parameter [23:0] MEAT_DARK = 24'hb75461
)(
    input wire clk_video,
    input wire reset,
    input wire ce_pixel,
    input wire menu_trigger,
    input wire dismiss,
    // Same transform as the downstream video/cabinet: 0, CW, 180, CCW.
    input wire [1:0] rotation,
    input wire [7:0] r_in, g_in, b_in,
    input wire hs_in, vs_in,
    input wire hblank_in, vblank_in,
    output reg [7:0] r_out, g_out, b_out,
    output reg hs_out, vs_out,
    output reg hblank_out, vblank_out,
    output wire de_out,
    output reg active
);
    `include "credits_layout.vh"
    localparam integer SCALE = 1 << SCALE_LOG2;
    localparam integer X_BITS = $clog2(WIDTH + 1);
    localparam integer Y_BITS = $clog2(HEIGHT + 1);
    localparam integer COORD_BITS = (X_BITS > Y_BITS) ? X_BITS : Y_BITS;
    localparam integer PHASE_BITS = CREDIT_SCROLL_ROW_BITS + 3;
    localparam integer TIMER_BITS = (SCROLL_FRAMES < 2) ? 1 : $clog2(SCROLL_FRAMES);
    localparam integer CARD_WIDTH = (CREDIT_COLUMNS * 6 + 16) * SCALE;
    localparam integer TOP = 8 * SCALE;
    localparam integer TEXT_TOP = 24 * SCALE;
    // Center the subtitle block on opening, with the title above it.
    localparam [PHASE_BITS-1:0] START_PHASE = CREDIT_SUBTITLE_ROW*8 +
        (CREDIT_SUBTITLE_LINES-1)*8 + 4 - ((HEIGHT/2-TEXT_TOP) >> SCALE_LOG2);
    localparam [PHASE_BITS-1:0] START_PHASE_VERTICAL = CREDIT_SUBTITLE_ROW*8 +
        (CREDIT_SUBTITLE_LINES-1)*8 + 4 - ((WIDTH/2-TEXT_TOP) >> SCALE_LOG2);
    reg [1:0] orientation;
    reg [X_BITS-1:0] x;
    reg [Y_BITS-1:0] y;
    wire reverse_columns = orientation[0] ^ orientation[1];
    wire [COORD_BITS-1:0] px = orientation[0] ?
        (orientation[1] ? y : HEIGHT-1-y) : (orientation[1] ? WIDTH-1-x : x);
    wire [COORD_BITS-1:0] py = orientation[0] ?
        (orientation[1] ? WIDTH-1-x : x) : (orientation[1] ? HEIGHT-1-y : y);
    wire [COORD_BITS-1:0] panel_left = orientation[0] ?
        (HEIGHT-CARD_WIDTH)/2 : (WIDTH-CARD_WIDTH)/2;
    wire [COORD_BITS-1:0] panel_right = panel_left + CARD_WIDTH;
    wire [COORD_BITS-1:0] view_height = orientation[0] ? WIDTH : HEIGHT;
    wire [COORD_BITS-1:0] text_left = panel_left + 8*SCALE;
    wire [COORD_BITS-1:0] text_right = panel_right - 8*SCALE;
    wire [COORD_BITS-1:0] text_bottom = view_height - 24*SCALE;

    // Quartus recognizes these as CDC synchronizer chains.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] trigger_sync;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] dismiss_sync;
    reg trigger_last, pending;
    reg dismiss_armed, dismiss_pending;
    wire trigger_edge = trigger_sync[1] && !trigger_last;
    reg hblank_last, vblank_last;
    wire frame_start = ce_pixel && vblank_in && !vblank_last;
    reg [PHASE_BITS-1:0] phase;
    reg [TIMER_BITS-1:0] frame_timer;
    reg [CREDIT_COL_BITS-1:0] text_column;
    reg [$clog2(6*SCALE)-1:0] text_sub_x;

    always @(posedge clk_video) begin
        if (reset) begin
            trigger_sync <= 0;
            dismiss_sync <= 0;
            trigger_last <= 0;
            pending <= 0;
            dismiss_armed <= 0;
            dismiss_pending <= 0;
            active <= 0;
            hblank_last <= 1;
            vblank_last <= 1;
            x <= 0;
            y <= 0;
            phase <= START_PHASE;
            frame_timer <= 0;
            text_column <= 0;
            text_sub_x <= 0;
            orientation <= 0;
        end else begin
            trigger_sync <= {trigger_sync[0], menu_trigger};
            dismiss_sync <= {dismiss_sync[0], dismiss};
            trigger_last <= trigger_sync[1];
            pending <= pending ^ trigger_edge;
            // Ignore the held opening button until inputs are released. Latch
            // later presses so a short press cannot disappear before VBlank.
            if (!active) begin
                dismiss_armed <= 0;
                dismiss_pending <= 0;
            end else begin
                if (!dismiss_sync[1]) dismiss_armed <= 1;
                if (dismiss_armed && dismiss_sync[1]) dismiss_pending <= 1;
            end
            if (ce_pixel) begin
                hblank_last <= hblank_in;
                vblank_last <= vblank_in;
                if (vblank_in) begin
                    x <= 0;
                    y <= 0;
                end else if (hblank_in) begin
                    x <= 0;
                    if (!hblank_last) y <= y + 1'b1;
                end else x <= x + 1'b1;
                // Step across pixels in landscape, across scanlines in portrait.
                // Reverse walking also avoids divide/modulo hardware for CW/180.
                if (vblank_in || (!orientation[0] && hblank_in)) begin
                    text_column <= reverse_columns ? CREDIT_COLUMNS-1 : 0;
                    text_sub_x <= reverse_columns ? 6*SCALE-1 : 0;
                end else if (active && px >= text_left && px < text_right &&
                    (orientation[0] ? (hblank_in && !hblank_last) : !hblank_in)) begin
                    if (reverse_columns) begin
                        if (text_sub_x == 0) begin
                            text_sub_x <= 6*SCALE-1;
                            text_column <= text_column - 1'b1;
                        end else text_sub_x <= text_sub_x - 1'b1;
                    end else begin
                        if (text_sub_x == 6*SCALE-1) begin
                            text_sub_x <= 0;
                            text_column <= text_column + 1'b1;
                        end else text_sub_x <= text_sub_x + 1'b1;
                    end
                end
            end
            // Changes are committed in vertical blank so the panel never tears.
            if (frame_start) begin
                orientation <= rotation;
                pending <= 0;
                if (active && (dismiss_pending || (dismiss_armed && dismiss_sync[1]))) begin
                    active <= 0;
                    dismiss_armed <= 0;
                    dismiss_pending <= 0;
                    phase <= rotation[0] ? START_PHASE_VERTICAL : START_PHASE;
                    frame_timer <= 0;
                end else if (pending ^ trigger_edge) begin
                    active <= !active;
                    phase <= rotation[0] ? START_PHASE_VERTICAL : START_PHASE;
                    frame_timer <= 0;
                end else if (orientation != rotation) begin
                    phase <= rotation[0] ? START_PHASE_VERTICAL : START_PHASE;
                    frame_timer <= 0;
                end else if (active) begin
                    if (frame_timer == SCROLL_FRAMES - 1) begin
                        frame_timer <= 0;
                        phase <= phase + 1'b1;
                    end else frame_timer <= frame_timer + 1'b1;
                end
            end
        end
    end

    // Increasing the sheet coordinate moves the text upward. Power-of-two
    // wrapping and shared blank rows avoid a framebuffer or expanded text ROM.
    wire [PHASE_BITS-1:0] sheet_y = ((py - TEXT_TOP) >> SCALE_LOG2) + phase;
    wire [CREDIT_COL_BITS-1:0] cell_x = text_column;
    wire [CREDIT_SCROLL_ROW_BITS-1:0] scroll_row = sheet_y[PHASE_BITS-1:3];
    wire [CREDIT_ROW_BITS-1:0] cell_y = scroll_row[CREDIT_SCROLL_ROW_BITS-1:1];
    wire [CREDIT_ADDRESS_BITS-1:0] map_address = cell_y * CREDIT_MAP_STRIDE + cell_x;
    wire [CREDIT_GLYPH_BITS:0] cell_q;
    wire [4:0] font_q;

    typedef struct packed {
        logic [23:0] rgb;
        logic hs, vs, hb, vb;
        logic border, ornament, fade, text_cell, underline;
        logic [2:0] sub_x, font_y;
    } pixel_meta;
    pixel_meta a, b;
    reg b_tier;

    credits_rom text_rom (.clk(clk_video), .ce(ce_pixel && active),
        .map_addr(map_address), .row(cell_y),
        .font_addr({cell_q[CREDIT_GLYPH_BITS-1:0], a.font_y}),
        .cell_q(cell_q), .font_q(font_q));

    wire [2:0] line_y = sheet_y[2:0];
    wire in_panel = (px >= panel_left) && (px < panel_right) &&
                   (py >= TOP) && (py < view_height-8*SCALE);
    wire in_text = (px >= text_left) && (px < text_right) &&
                   (py >= TEXT_TOP) && (py < text_bottom);
    wire on_border = in_panel && ((px == panel_left) || (px == panel_right-1) ||
                                 (py == TOP) || (py == view_height-8*SCALE-1));
    wire on_ornament = in_panel &&
        (((py == TOP + 7*SCALE) || (py == view_height - 15*SCALE)) &&
         (px >= panel_left + 12*SCALE) && (px < panel_right - 12*SCALE));
    wire faded = (py < TEXT_TOP + 8*SCALE) || (py >= text_bottom - 8*SCALE);

    wire ink, shadow;
    wire [6:0] shifted_font = {1'b0,font_q,1'b0} << b.sub_x;
    assign ink = (b.text_cell && shifted_font[5]) || b.underline;
    assign shadow = b.text_cell && shifted_font[6];
    reg [3:0] paint;
    reg [23:0] painted_rgb;
    always @* begin
        // A single palette lookup replaces cascaded 24-bit overlay muxes.
        paint = 4'd15;
        if (b.border) paint = 4'd3;
        if (b.ornament) paint = 4'd7;
        if (shadow) paint = 4'd11;
        if (ink) paint = {b.fade,b_tier,((b.font_y < 2) ? 2'd0 :
                                     ((b.font_y < 5) ? 2'd1 : 2'd2))};
    end

    assign de_out = !(hblank_out || vblank_out);
    always @(posedge clk_video) begin
        if (reset) begin
            a <= 0;
            b <= 0;
            b_tier <= 0;
            r_out <= 0; g_out <= 0; b_out <= 0;
            hs_out <= 0; vs_out <= 0;
            hblank_out <= 1; vblank_out <= 1;
        end else if (ce_pixel) begin
            // Three enabled register stages, shared by RGB and every timing signal.
            a.rgb <= {r_in, g_in, b_in};
            if (active && !hblank_in && !vblank_in) begin
                a.rgb <= {1'b0,r_in[7:1],1'b0,g_in[7:1],1'b0,b_in[7:1]};
                if (in_panel) begin
                    a.rgb <= PANEL_COLOR;
                end
            end
            a.hs <= hs_in; a.vs <= vs_in;
            a.hb <= hblank_in; a.vb <= vblank_in;
            a.border <= active && !hblank_in && !vblank_in && on_border;
            a.ornament <= active && !hblank_in && !vblank_in && on_ornament;
            a.fade <= faded;
            a.text_cell <= active && !hblank_in && !vblank_in && in_text &&
                           !scroll_row[0] && (line_y >= 1);
            // Both tier headings are ten characters wide. Underline the whole
            // phrase, including its internal space and each sixth pixel column.
            a.underline <= active && !hblank_in && !vblank_in && in_text &&
                CREDIT_HEADING_ROWS[cell_y] && scroll_row[0] && (line_y == 1) &&
                (cell_x >= (CREDIT_COLUMNS-10)/2) && (cell_x < (CREDIT_COLUMNS-10)/2+10);
            a.sub_x <= text_sub_x >> SCALE_LOG2;
            a.font_y <= line_y - 1;
            b <= a;
            b_tier <= cell_q[CREDIT_GLYPH_BITS];
            hs_out <= b.hs; vs_out <= b.vs;
            hblank_out <= b.hb; vblank_out <= b.vb;
            {r_out,g_out,b_out} <= painted_rgb;
        end
    end

    always @* begin
        case (paint)
             0: painted_rgb = GOLD_LIGHT;
             1: painted_rgb = GOLD_MID;
             2: painted_rgb = GOLD_DARK;
             3: painted_rgb = 24'h79552d;
             4: painted_rgb = MEAT_LIGHT;
             5: painted_rgb = MEAT_MID;
             6: painted_rgb = MEAT_DARK;
             7: painted_rgb = 24'hb77924;
             8: painted_rgb = (GOLD_LIGHT >> 1) & 24'h7f7f7f;
             9: painted_rgb = (GOLD_MID >> 1) & 24'h7f7f7f;
            10: painted_rgb = (GOLD_DARK >> 1) & 24'h7f7f7f;
            11: painted_rgb = 24'h080a10;
            12: painted_rgb = (MEAT_LIGHT >> 1) & 24'h7f7f7f;
            13: painted_rgb = (MEAT_MID >> 1) & 24'h7f7f7f;
            14: painted_rgb = (MEAT_DARK >> 1) & 24'h7f7f7f;
            default: painted_rgb = b.rgb;
        endcase
    end

    // synthesis translate_off
    initial begin
        if (WIDTH < CARD_WIDTH || HEIGHT < CARD_WIDTH ||
            WIDTH < 64*SCALE || HEIGHT < 64*SCALE || SCALE_LOG2 < 0 || SCALE_LOG2 > 3 || SCROLL_FRAMES < 1)
            $fatal(1, "Credits geometry does not fit; reduce columns/scale or correct WIDTH/HEIGHT");
    end
    // synthesis translate_on
endmodule
