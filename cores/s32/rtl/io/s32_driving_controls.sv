`timescale 1ns/1ps

// System 32 driving-cabinet input adapters.
// Paddle/spinner/mouse source handling is adapted from meathax/s32multi
// commit 1e89f67005ae0eb11ae0622cb52e8214c78ed76e.
module s32_driving_controls (
    input         clk,
    input         rst,
    input         wheel_sample,  // one clk_sys pulse per real MSM6253 an0 load
    input         capture_wheel,
    input   [7:0] left_x,
    input   [7:0] paddle,
    input   [8:0] spinner,
    input  [24:0] mouse,
    input   [1:0] wheel_source,
    input   [1:0] steering_sensitivity,
    input   [7:0] right_y,
    input         digital_accel,
    input         digital_brake,
    input         digital_left,
    input         digital_right,
    output  [7:0] wheel,
    output  [7:0] accel,
    output  [7:0] brake
);
    localparam [7:0] WHEEL_DZ = 8'd6;
    localparam [7:0] WHEEL_STEP = 8'h38;
    localparam [1:0] STEER_SENS_NORMAL = 2'd0;
    localparam [1:0] STEER_SENS_LOW    = 2'd1;
    localparam [1:0] STEER_SENS_HIGH   = 2'd2;

    function automatic [7:0] wheel_deadzone(input [7:0] raw);
        reg [7:0] v;
        begin
            v = raw ^ 8'h80;
            if (v >= (8'd128 - WHEEL_DZ) && v <= (8'd128 + WHEEL_DZ))
                wheel_deadzone = 8'h80;
            else if (v > 8'd128)
                wheel_deadzone = v - WHEEL_DZ;
            else
                wheel_deadzone = v + WHEEL_DZ;
        end
    endfunction

    // Scale absolute sources about the neutral ADC coordinate. D-pad
    // endpoints remain digital full-scale overrides below.
    function automatic [7:0] scale_position(
        input [7:0] raw,
        input [1:0] sensitivity
    );
        reg signed [8:0] centered;
        reg signed [10:0] scaled;
        begin
            centered = $signed({1'b0, raw}) - 9'sd128;
            case (sensitivity)
                STEER_SENS_LOW:
                    scaled = $signed({{2{centered[8]}}, centered}) >>> 1;
                STEER_SENS_HIGH:
                    scaled = $signed({{2{centered[8]}}, centered}) <<< 1;
                STEER_SENS_NORMAL:
                    scaled = $signed({{2{centered[8]}}, centered});
                default:
                    scaled = $signed({{2{centered[8]}}, centered});
            endcase
            if (scaled < -11'sd128)
                scale_position = 8'h00;
            else if (scaled > 11'sd127)
                scale_position = 8'hff;
            else
                // scaled is bounded to -128..127 above, so this 8-bit
                // offset-binary addition is exact modulo 256.
                scale_position = scaled[7:0] + 8'h80;
        end
    endfunction

    function automatic signed [12:0] scale_relative(
        input signed [12:0] delta,
        input        [1:0] sensitivity
    );
        begin
            case (sensitivity)
                STEER_SENS_LOW:  scale_relative = delta >>> 1;
                STEER_SENS_HIGH: scale_relative = delta <<< 1;
                STEER_SENS_NORMAL: scale_relative = delta;
                default:         scale_relative = delta;
            endcase
        end
    endfunction

    function automatic [7:0] spinner_step(
        input [7:0] position,
        input signed [12:0] delta
    );
        reg signed [13:0] next_position;
        begin
            next_position = $signed({6'd0, position}) + delta;
            if (next_position < 14'sd0)
                spinner_step = 8'h00;
            else if (next_position > 14'sd255)
                spinner_step = 8'hff;
            else
                spinner_step = next_position[7:0];
        end
    endfunction

    wire [7:0] wheel_analog = scale_position(
        wheel_deadzone(left_x), steering_sensitivity);
    wire [7:0] wheel_paddle = scale_position(paddle, steering_sensitivity);

    // HPS spinner reports carry a signed delta and toggle bit 8. The shared
    // PS/2 packet uses its signed Y report for the mouse-relative spinner path.
    reg [7:0] spinner_position;
    reg       spinner_toggle_d;
    reg [24:0] mouse_q;
    reg        mouse_toggle_d;
    reg        mouse_valid;
    wire       spinner_event = spinner[8] != spinner_toggle_d;
    wire       mouse_event = mouse_valid && (mouse_q[24] != mouse_toggle_d);
    wire signed [11:0] spinner_delta =
        $signed({{4{spinner[7]}}, spinner[7:0]});
    wire signed [9:0] mouse_delta =
        $signed({mouse_q[4], mouse_q[4], mouse_q[15:8]});
    wire signed [12:0] spinner_delta_wide =
        $signed({spinner_delta[11], spinner_delta});
    wire signed [11:0] mouse_delta_ext =
        $signed({{2{mouse_delta[9]}}, mouse_delta});
    wire signed [12:0] mouse_delta_wide =
        $signed({mouse_delta_ext[11], mouse_delta_ext});
    wire signed [12:0] relative_delta =
        (spinner_event ? spinner_delta_wide : 13'sd0) +
        (mouse_event ? mouse_delta_wide : 13'sd0);
    wire signed [12:0] relative_delta_selected =
        (wheel_source == 2'd3) ? -relative_delta : relative_delta;
    wire signed [12:0] relative_delta_scaled = scale_relative(
        relative_delta_selected, steering_sensitivity);

    always @(posedge clk) begin
        if (rst) begin
            spinner_position <= 8'h80;
            spinner_toggle_d <= spinner[8];
            mouse_q <= mouse;
            mouse_toggle_d <= mouse[24];
            mouse_valid <= 1'b0;
        end
        else begin
            spinner_toggle_d <= spinner[8];
            mouse_q <= mouse;
            mouse_toggle_d <= mouse_q[24];
            mouse_valid <= 1'b1;
            if (spinner_event || mouse_event)
                spinner_position <= spinner_step(
                    spinner_position, relative_delta_scaled);
        end
    end

    reg [7:0] wheel_source_value;
    always @(*) begin
        case (wheel_source)
            2'd1: wheel_source_value = wheel_paddle;
            2'd2,
            2'd3: wheel_source_value = spinner_position;
            default: wheel_source_value = wheel_analog;
        endcase
    end

    // Positional-wheel profiles retain the existing digital endpoint fallback.
    wire [7:0] wheel_live = capture_wheel
                          ? ((digital_left && digital_right) ? 8'h80 :
                             digital_left ? 8'h00 :
                             digital_right ? 8'hff : wheel_source_value)
                          : wheel_source_value;

    // Rad Mobile's firmware rejects an ADC sample whose signed delta exceeds
    // 0x40. Advance only on the real channel-0 load and keep the old safe step.
    reg [7:0] wheel_q;
    wire signed [8:0] wheel_diff =
        $signed({1'b0, wheel_live}) - $signed({1'b0, wheel_q});
    always @(posedge clk) begin
        if (rst)
            wheel_q <= 8'h80;
        else if (wheel_sample) begin
            if (wheel_diff > $signed({1'b0, WHEEL_STEP}))
                wheel_q <= wheel_q + WHEEL_STEP;
            else if (wheel_diff < -$signed({1'b0, WHEEL_STEP}))
                wheel_q <= wheel_q - WHEEL_STEP;
            else
                wheel_q <= wheel_live;
        end
    end

    wire signed [8:0] stick_y = $signed({right_y[7], right_y});
    wire [8:0] accel_mag = (stick_y < 0) ? -stick_y : 9'd0;
    wire [8:0] brake_mag = (stick_y > 0) ?  stick_y : 9'd0;

    function automatic [7:0] pedal(input [8:0] magnitude);
        pedal = (magnitude >= 9'd127) ? 8'hff : {magnitude[6:0], 1'b0};
    endfunction

    assign wheel = wheel_q;
    assign accel = digital_accel ? 8'hff : pedal(accel_mag);
    assign brake = digital_brake ? 8'hff : pedal(brake_mag);
endmodule
