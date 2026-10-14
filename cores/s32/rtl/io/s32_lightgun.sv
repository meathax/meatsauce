// Generic MiSTer/JTFRAME-compatible positional-gun input adapter.
//
// The host contract is the one used by JTFRAME on MiSTer:
//   * joyana[7:0] and joyana[15:8] are signed -128..+127 X/Y axes;
//   * mouse_dx/mouse_dy are signed PS/2 relative deltas and mouse_strobe is
//     the event toggle edge decoded by the target wrapper;
//   * joy_dir is {down,up,left,right}, matching JTFRAME game_joy[3:0].
//
// This is a project-owned implementation of that interface, not a copied
// JTFRAME source file.  The behavioural contract was checked against
// jotego/jtcores c990f843c7bd8eaf26179a0632bac1436cc05b52 and the
// jlrh/taito-fpga Operation Wolf integration at
// 405a68eac741918e627cda563cc1a0c219ed18fd.
// Both upstream projects are GPL-3.0-or-later; this core is already
// GPL-3.0-or-later and the inspection/provenance record is in
// verif/donors/README.md.

module s32_lightgun #(
    parameter [8:0] DEFAULT_WIDTH  = 9'd320,
    parameter [8:0] DEFAULT_HEIGHT = 9'd224
) (
    input             clk,
    input             rst,
    input             vs,
    input       [8:0] screen_width,
    input       [8:0] screen_height,
    input       [1:0] rotate,
    input       [1:0] sensitivity,
    input      [15:0] joyana,
    input       [3:0] joy_dir,
    input       [7:0] mouse_dx,
    input       [7:0] mouse_dy,
    input             mouse_strobe,
    output reg  [8:0] gun_x,
    output reg  [8:0] gun_y,
    output reg  [7:0] adc_x,
    output reg  [7:0] adc_y,
    output reg        gun_strobe
);

    localparam [8:0] DEFAULT_W = DEFAULT_WIDTH;
    localparam [8:0] DEFAULT_H = DEFAULT_HEIGHT;

    wire [8:0] width_live  = (screen_width  == 9'd0) ? DEFAULT_W : screen_width;
    wire [8:0] height_live = (screen_height == 9'd0) ? DEFAULT_H : screen_height;

    wire [7:0] analog_x = joyana[7:0]  + 8'h80;
    wire [7:0] analog_y = joyana[15:8] + 8'h80;
    reg  [15:0] joyana_d;
    reg         vs_d;

    // A held non-centre stick must still become visible after a long ROM
    // reset/download interval.  Once the host returns to centre, the change
    // edge below commits that centre value and relative mouse/d-pad motion can
    // remain active without being overwritten every clock.
    wire analog_strobe = (joyana != joyana_d) || (|joyana);
    wire vs_edge       = vs & ~vs_d;
    wire joy_active    = |joy_dir;
    wire joy_strobe    = vs_edge && joy_active;

    // JTFRAME's base d-pad step is 7 pixels.  Keep its sensitivity ordering:
    // 0=7, 1=9, 2=3, 3=5.
    reg signed [8:0] joy_step;
    always @(*) begin
        case (sensitivity)
            2'd1:    joy_step = 9'sd9;
            2'd2:    joy_step = 9'sd3;
            2'd3:    joy_step = 9'sd5;
            default: joy_step = 9'sd7;
        endcase
    end

    // Signed relative motion after the JTFRAME rotation convention.  The
    // d-pad uses the same delta convention as the mouse: positive Y moves the
    // sight upward because the absolute-position stage subtracts dy.
    reg signed [8:0] mouse_raw_dx, mouse_raw_dy;
    reg signed [8:0] mouse_rot_dx, mouse_rot_dy;
    reg signed [8:0] joy_raw_dx, joy_raw_dy;
    reg signed [8:0] joy_rot_dx, joy_rot_dy;
    always @(*) begin
        mouse_raw_dx = $signed({mouse_dx[7], mouse_dx});
        mouse_raw_dy = $signed({mouse_dy[7], mouse_dy});
        joy_raw_dx   = 9'sd0;
        joy_raw_dy   = 9'sd0;
        if (joy_dir[0]) joy_raw_dx =  joy_step; // right
        if (joy_dir[1]) joy_raw_dx = -joy_step; // left
        if (joy_dir[2]) joy_raw_dy =  joy_step; // up
        if (joy_dir[3]) joy_raw_dy = -joy_step; // down

        case (rotate)
            2'b01: begin // clockwise: (dx,dy)=(-dy,+dx)
                mouse_rot_dx = -mouse_raw_dy;
                mouse_rot_dy =  mouse_raw_dx;
                joy_rot_dx   = -joy_raw_dy;
                joy_rot_dy   =  joy_raw_dx;
            end
            2'b11: begin // counter-clockwise: (dx,dy)=(+dy,-dx)
                mouse_rot_dx =  mouse_raw_dy;
                mouse_rot_dy = -mouse_raw_dx;
                joy_rot_dx   =  joy_raw_dy;
                joy_rot_dy   = -joy_raw_dx;
            end
            2'b10: begin // 180 degrees
                mouse_rot_dx = -mouse_raw_dx;
                mouse_rot_dy = -mouse_raw_dy;
                joy_rot_dx   = -joy_raw_dx;
                joy_rot_dy   = -joy_raw_dy;
            end
            default: begin
                mouse_rot_dx = mouse_raw_dx;
                mouse_rot_dy = mouse_raw_dy;
                joy_rot_dx   = joy_raw_dx;
                joy_rot_dy   = joy_raw_dy;
            end
        endcase
    end

    function automatic [8:0] clamp_position(
        input signed [10:0] value,
        input        [8:0]  dimension
    );
        reg [8:0] maximum;
        begin
            maximum = (dimension == 9'd0) ? 9'd0 : dimension - 1'b1;
            if (value < 0)
                clamp_position = 9'd0;
            else if (value > $signed({2'b00, maximum}))
                clamp_position = maximum;
            else
                clamp_position = value[8:0];
        end
    endfunction

    // Convert the native raster position back to the 8-bit ADC representation
    // consumed by the System 32 gun ports.  The universal profile exposes only
    // 320x224 and 416x224 native rasters.  These reciprocal constants are
    // exact floor mappings for every position in those three dimensions:
    //
    //   floor(position*255/319) = (position*819)>>10
    //   floor(position*255/415) = (position*20135)>>15
    //   floor(position*255/223) = (position*149881)>>17
    //
    // Keeping the products in an explicitly widened operand removes the
    // general lpm_divide cone that otherwise dominates the clk_sys timing path.
    // Unsupported dimensions fail closed rather than silently inferring a
    // different calibration; the top-level profile cannot select them.
    function automatic [7:0] position_to_adc(
        input [8:0] position,
        input [8:0] dimension
    );
        reg [17:0] scaled_320;
        reg [23:0] scaled_416;
        reg [24:0] scaled_224;
        begin
            scaled_320 = 18'd0;
            scaled_416 = 24'd0;
            scaled_224 = 25'd0;
            position_to_adc = 8'd0;
            case (dimension)
                9'd320: begin
                    scaled_320 = position * 18'd819;
                    // Reference the discarded fractional bits explicitly;
                    // both branches intentionally implement the same floor.
                    if (|scaled_320[9:0])
                        position_to_adc = scaled_320[17:10];
                    else
                        position_to_adc = scaled_320[17:10];
                end
                9'd416: begin
                    scaled_416 = {15'd0, position} * 18'd20135;
                    // Bit 23 is a proved-zero guard bit for the native range;
                    // keep it in the expression so Quartus/Verilator do not
                    // hide an accidental future overflow.
                    if (scaled_416[23] || |scaled_416[14:0])
                        position_to_adc = scaled_416[22:15];
                    else
                        position_to_adc = scaled_416[22:15];
                end
                9'd224: begin
                    scaled_224 = {16'd0, position} * 18'd149881;
                    if (|scaled_224[16:0])
                        position_to_adc = scaled_224[24:17];
                    else
                        position_to_adc = scaled_224[24:17];
                end
                default: ;
            endcase
        end
    endfunction

    function automatic [8:0] analog_to_position(
        input [7:0] axis,
        input [8:0] dimension
    );
        reg [16:0] product;
        begin
            product = axis * dimension;
            // The fractional remainder is intentionally discarded; reference
            // it in the branch so the implementation makes that truncation
            // explicit instead of relying on an implicit width drop.
            if (|product[7:0])
                analog_to_position = product[16:8];
            else
                analog_to_position = product[16:8];
        end
    endfunction

    wire [8:0] analog_pos_x = analog_to_position(analog_x, width_live);
    wire [8:0] analog_pos_y = analog_to_position(analog_y, height_live);

    wire signed [10:0] mouse_next_x_signed =
        $signed({1'b0, gun_x}) + {{2{mouse_rot_dx[8]}}, mouse_rot_dx};
    wire signed [10:0] mouse_next_y_signed =
        $signed({1'b0, gun_y}) - {{2{mouse_rot_dy[8]}}, mouse_rot_dy};
    wire signed [10:0] joy_next_x_signed =
        $signed({1'b0, gun_x}) + {{2{joy_rot_dx[8]}}, joy_rot_dx};
    wire signed [10:0] joy_next_y_signed =
        $signed({1'b0, gun_y}) - {{2{joy_rot_dy[8]}}, joy_rot_dy};

    wire [8:0] mouse_next_x = clamp_position(mouse_next_x_signed, width_live);
    wire [8:0] mouse_next_y = clamp_position(mouse_next_y_signed, height_live);
    wire [8:0] joy_next_x   = clamp_position(joy_next_x_signed, width_live);
    wire [8:0] joy_next_y   = clamp_position(joy_next_y_signed, height_live);

    always @(posedge clk) begin
        if (rst) begin
            gun_x       <= width_live  >> 1;
            gun_y       <= height_live >> 1;
            adc_x       <= 8'h80;
            adc_y       <= 8'h80;
            gun_strobe  <= 1'b0;
            joyana_d    <= joyana;
            vs_d        <= vs;
        end
        else begin
            gun_strobe <= 1'b0;
            joyana_d   <= joyana;
            vs_d       <= vs;

            // Match jtframe_lightgun_position's source priority: mouse,
            // absolute analog, then d-pad.  Analog remains an absolute source
            // for the ADC, while mouse/d-pad events retain an absolute screen
            // position between host reports.
            if (mouse_strobe) begin
                gun_x      <= mouse_next_x;
                gun_y      <= mouse_next_y;
                adc_x      <= position_to_adc(mouse_next_x, width_live);
                adc_y      <= position_to_adc(mouse_next_y, height_live);
                gun_strobe <= 1'b1;
            end
            else if (analog_strobe) begin
                gun_x      <= analog_pos_x;
                gun_y      <= analog_pos_y;
                adc_x      <= analog_x;
                adc_y      <= analog_y;
                gun_strobe <= 1'b1;
            end
            else if (joy_strobe) begin
                gun_x      <= joy_next_x;
                gun_y      <= joy_next_y;
                adc_x      <= position_to_adc(joy_next_x, width_live);
                adc_y      <= position_to_adc(joy_next_y, height_live);
                gun_strobe <= 1'b1;
            end
            else begin
                // A live mode change can narrow the active area.  Clamp the
                // retained relative position without manufacturing an input
                // event or changing the host-axis path.
                if (gun_x >= width_live) begin
                    gun_x <= width_live - 1'b1;
                    adc_x <= position_to_adc(width_live - 1'b1, width_live);
                end
                if (gun_y >= height_live) begin
                    gun_y <= height_live - 1'b1;
                    adc_y <= position_to_adc(height_live - 1'b1, height_live);
                end
            end
        end
    end

endmodule
