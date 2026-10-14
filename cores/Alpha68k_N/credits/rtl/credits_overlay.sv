// SPDX-License-Identifier: MIT
// Native progressive video overlay. All inputs are in clk_video except the
// menu trigger / dismiss, which have their own two-register synchronizers.
module credits_overlay #(
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 240,
    parameter integer SCALE_LOG2 = 0,
    parameter integer SCROLL_FRAMES = 4,
    parameter integer ROTATE_CCW = 0,
    parameter integer OPEN_AT_TOP = 0,
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
    localparam integer CANVAS_WIDTH = ROTATE_CCW ? HEIGHT : WIDTH;
    localparam integer CANVAS_HEIGHT = ROTATE_CCW ? WIDTH : HEIGHT;
    localparam integer X_BITS = $clog2(WIDTH + 1);
    localparam integer Y_BITS = $clog2(HEIGHT + 1);
    localparam integer PHASE_BITS = CREDIT_SCROLL_ROW_BITS + 3;
    localparam integer TIMER_BITS = (SCROLL_FRAMES < 2) ? 1 : $clog2(SCROLL_FRAMES);
    localparam integer CARD_WIDTH = (CREDIT_COLUMNS * 6 + 16) * SCALE;
    localparam integer LEFT = (CANVAS_WIDTH - CARD_WIDTH) / 2;
    localparam integer RIGHT = LEFT + CARD_WIDTH;
    localparam integer TOP = 8 * SCALE;
    localparam integer BOTTOM = CANVAS_HEIGHT - 8 * SCALE;
    localparam integer TEXT_LEFT = LEFT + 8 * SCALE;
    localparam integer TEXT_TOP = 24 * SCALE;
    localparam integer TEXT_BOTTOM = CANVAS_HEIGHT - 24 * SCALE;
    // Portrait credits open one blank row below the top fade; other layouts
    // retain the centered subtitle opening.
    localparam [PHASE_BITS-1:0] START_PHASE = OPEN_AT_TOP ? -8 : CREDIT_SUBTITLE_ROW*8 +
        (CREDIT_SUBTITLE_LINES-1)*4 + 4 - ((CANVAS_HEIGHT/2-TEXT_TOP) >> SCALE_LOG2);

    // Quartus recognizes these as CDC synchronizer chains.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] trigger_sync;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [1:0] dismiss_sync;
    reg trigger_last, pending;
    reg dismiss_armed, dismiss_pending;
    wire trigger_edge = trigger_sync[1] && !trigger_last;
    reg hblank_last, vblank_last;
    wire frame_start = ce_pixel && vblank_in && !vblank_last;
    reg [X_BITS-1:0] x;
    reg [Y_BITS-1:0] y;
    localparam integer POS_BITS = (X_BITS > Y_BITS) ? X_BITS : Y_BITS;
    // Inverse of a 90-degree counterclockwise rotation: (u,v)=(H-1-y,x).
    // Raster counters and sync pipeline retain the native video geometry.
    wire [POS_BITS-1:0] canvas_x = ROTATE_CCW ? HEIGHT-1-y : x;
    wire [POS_BITS-1:0] canvas_y = ROTATE_CCW ? x : y;
    wire [Y_BITS-1:0] rotated_text_x = (canvas_x-TEXT_LEFT) >> SCALE_LOG2;
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
                // Six-pixel cells use a tiny walker, avoiding a divide-by-six.
                if (hblank_in || vblank_in) begin
                    text_column <= 0;
                    text_sub_x <= 0;
                end else if (x >= TEXT_LEFT && x < RIGHT - 8*SCALE) begin
                    if (text_sub_x == 6*SCALE-1) begin
                        text_sub_x <= 0;
                        text_column <= text_column + 1'b1;
                    end else text_sub_x <= text_sub_x + 1'b1;
                end
            end
            // Changes are committed in vertical blank so the panel never tears.
            if (frame_start) begin
                pending <= 0;
                if (active && (dismiss_pending || (dismiss_armed && dismiss_sync[1]))) begin
                    active <= 0;
                    dismiss_armed <= 0;
                    dismiss_pending <= 0;
                    phase <= START_PHASE;
                    frame_timer <= 0;
                end else if (pending ^ trigger_edge) begin
                    active <= !active;
                    phase <= START_PHASE;
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
    wire [PHASE_BITS-1:0] sheet_y = ((canvas_y - TEXT_TOP) >> SCALE_LOG2) + phase;
    wire [CREDIT_COL_BITS-1:0] cell_x = ROTATE_CCW ? rotated_text_x / 6 : text_column;
    wire [CREDIT_SCROLL_ROW_BITS-1:0] scroll_row = sheet_y[PHASE_BITS-1:3];
    wire [CREDIT_ROW_BITS-1:0] cell_y = CREDIT_ROW_MAP[scroll_row*CREDIT_ROW_BITS +: CREDIT_ROW_BITS];
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

    credits_rom text_rom (.clk(clk_video), .ce(ce_pixel),
        .map_addr(map_address), .row(cell_y),
        .font_addr({cell_q[CREDIT_GLYPH_BITS-1:0], a.font_y}),
        .cell_q(cell_q), .font_q(font_q));

    wire [2:0] line_y = sheet_y[2:0];
    wire in_panel = (canvas_x >= LEFT) && (canvas_x < RIGHT) && (canvas_y >= TOP) && (canvas_y < BOTTOM);
    wire in_text = (canvas_x >= TEXT_LEFT) && (canvas_x < RIGHT - 8*SCALE) &&
                   (canvas_y >= TEXT_TOP) && (canvas_y < TEXT_BOTTOM);
    wire on_border = in_panel && ((canvas_x == LEFT) || (canvas_x == RIGHT-1) ||
                                 (canvas_y == TOP) || (canvas_y == BOTTOM-1));
    wire on_ornament = in_panel &&
        (((canvas_y == TOP + 7*SCALE) || (canvas_y == BOTTOM - 7*SCALE)) &&
         (canvas_x >= LEFT + 12*SCALE) && (canvas_x < RIGHT - 12*SCALE));
    wire faded = (canvas_y < TEXT_TOP + 8*SCALE) || (canvas_y >= TEXT_BOTTOM - 8*SCALE);

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
            a.text_cell <= active && !hblank_in && !vblank_in && in_text && (line_y >= 1);
            // Both tier headings are ten characters wide. Underline the whole
            // phrase, including its internal space and each sixth pixel column.
            a.underline <= active && !hblank_in && !vblank_in && in_text &&
                CREDIT_UNDERLINE_ROWS[scroll_row] && (line_y == 1) &&
                (cell_x >= (CREDIT_COLUMNS-10)/2) && (cell_x < (CREDIT_COLUMNS-10)/2+10);
            a.sub_x <= ROTATE_CCW ? rotated_text_x % 6 : text_sub_x >> SCALE_LOG2;
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
        if (LEFT < 0 || CANVAS_HEIGHT < 64*SCALE || SCALE_LOG2 < 0 || SCALE_LOG2 > 3 || SCROLL_FRAMES < 1)
            $fatal(1, "Credits geometry does not fit; reduce columns/scale or correct WIDTH/HEIGHT");
    end
    // synthesis translate_on
endmodule
