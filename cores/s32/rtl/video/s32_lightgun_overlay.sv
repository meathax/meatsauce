// Core-side lightgun presentation stage.
//
// JTFRAME normally draws the crosshair in its video wrapper and asks the
// MiSTer scaler to emit the Sinden white border.  This System 32 repository
// keeps the vendored sys/ascal framework read-only, so the equivalent RGB-only
// stage lives here.  HS/VS/DE/CE are passed through unchanged; the stage only
// decorates pixels already inside the native active window.

module s32_lightgun_overlay #(
    parameter [8:0] BORDER_WIDTH = 9'd4
) (
    input             clk,
    input             rst,
    input             pxl_cen,
    input             hs,
    input             vs,
    input             de,
    input       [8:0] screen_width,
    input       [8:0] screen_height,
    input       [8:0] gun1_x,
    input       [8:0] gun1_y,
    input       [8:0] gun2_x,
    input       [8:0] gun2_y,
    input             gun1_en,
    input             gun2_en,
    input             border_en,
    input             crosshair_en,
    input      [23:0] rgb_in,
    output reg [23:0] rgb_out,
    output      [8:0] raster_x,
    output      [8:0] raster_y
);

    localparam [8:0] BORDER = BORDER_WIDTH;
    reg [8:0] x;
    reg [8:0] y;
    reg       de_d;
    reg       hs_d;
    reg       vs_d;
    reg       frame_pending;
    reg       have_frame_line;

    assign raster_x = x;
    assign raster_y = y;

    // The native System 32 syncs and DE all change on pixel-enable edges.
    // Reconstruct the active raster from DE transitions rather than assuming
    // a particular front/back porch.  A falling VS arms the next DE rise as
    // line zero, which also works through the optional CRT-adjust path.
    always @(posedge clk) begin
        if (rst) begin
            x                <= 9'd0;
            y                <= 9'd0;
            de_d             <= 1'b0;
            hs_d             <= hs;
            vs_d             <= vs;
            frame_pending    <= 1'b1;
            have_frame_line  <= 1'b0;
        end
        else begin
            if (pxl_cen) begin
                // Sync and DE transitions are defined on pixel-enable edges.
                // Sample their history at the same cadence as the raster
                // counters; updating history on every clk_sys cycle can erase
                // a fractional-CE transition before it is observed here.
                vs_d <= vs;
                de_d <= de;
                hs_d <= hs;

                if (vs_d && !vs)
                    frame_pending <= 1'b1;

                if (hs_d && !hs && !de) begin
                    x <= 9'd0;
                end
                else if (!de_d && de) begin
                    x <= 9'd0;
                    if (frame_pending || !have_frame_line) begin
                        y               <= 9'd0;
                        frame_pending   <= 1'b0;
                        have_frame_line <= 1'b1;
                    end
                    else if (y < screen_height - 1'b1)
                        y <= y + 1'b1;
                    else
                        y <= 9'd0;
                end
                else if (de) begin
                    if (x < screen_width - 1'b1)
                        x <= x + 1'b1;
                end
            end
        end
    end

    function automatic [1:0] crosshair_pixel(
        input [2:0] dx,
        input [2:0] dy
    );
        begin
            // The 8x8 footprint is the JTFRAME pattern: value 1 is the black
            // outline and value 3 is the white interior/arms.
            case (dy)
                3'd0, 3'd1, 3'd6, 3'd7: begin
                    case (dx)
                        3'd2, 3'd5: crosshair_pixel = 2'd3;
                        3'd3, 3'd4: crosshair_pixel = 2'd1;
                        default:    crosshair_pixel = 2'd0;
                    endcase
                end
                3'd2, 3'd5: begin
                    case (dx)
                        3'd0, 3'd1, 3'd2, 3'd5, 3'd6, 3'd7:
                            crosshair_pixel = 2'd3;
                        3'd3, 3'd4: crosshair_pixel = 2'd1;
                        default: crosshair_pixel = 2'd0;
                    endcase
                end
                3'd3, 3'd4: begin
                    case (dx)
                        3'd0, 3'd1, 3'd2, 3'd5, 3'd6, 3'd7:
                            crosshair_pixel = 2'd1;
                        3'd3, 3'd4: crosshair_pixel = 2'd3;
                        default: crosshair_pixel = 2'd0;
                    endcase
                end
                default: crosshair_pixel = 2'd0;
            endcase
        end
    endfunction

    wire [9:0] gun1_dx = {1'b0, x} - {1'b0, gun1_x};
    wire [9:0] gun1_dy = {1'b0, y} - {1'b0, gun1_y};
    wire [9:0] gun2_dx = {1'b0, x} - {1'b0, gun2_x};
    wire [9:0] gun2_dy = {1'b0, y} - {1'b0, gun2_y};
    wire       gun1_in = gun1_dx[9:3] == 7'd0 && gun1_dy[9:3] == 7'd0;
    wire       gun2_in = gun2_dx[9:3] == 7'd0 && gun2_dy[9:3] == 7'd0;
    wire [1:0] gun1_cross = gun1_in ? crosshair_pixel(gun1_dx[2:0], gun1_dy[2:0]) : 2'd0;
    wire [1:0] gun2_cross = gun2_in ? crosshair_pixel(gun2_dx[2:0], gun2_dy[2:0]) : 2'd0;

    wire border_pixel = border_en && de &&
                        ((x < BORDER) || (y < BORDER) ||
                         (x >= screen_width - BORDER) ||
                         (y >= screen_height - BORDER));

    always @(*) begin
        rgb_out = rgb_in;
        if (de) begin
            if (border_pixel)
                rgb_out = 24'hffffff;
            else if (crosshair_en && gun1_en && gun1_cross != 2'd0)
                rgb_out = (gun1_cross == 2'd3) ? 24'hffffff : 24'h000000;
            else if (crosshair_en && gun2_en && gun2_cross != 2'd0)
                rgb_out = (gun2_cross == 2'd3) ? 24'hffffff : 24'h000000;
        end
    end

endmodule
