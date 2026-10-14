// System 32 driving-cabinet input adapters.
// MiSTer analog-stick axes are signed -128..+127 with zero at rest.
// Steering accepts a signed analog axis, an absolute paddle, or relative
// spinner reports. D-pad left/right remain full-deflection fallbacks. Pedals
// split right-stick Y into accel(up)/brake(down), with two assignable digital
// buttons as full-scale fallbacks.
module s32_driving_controls (
    input         clk,
    input         rst,
    input         capture_wheel,
    input         wheel_sample,
    input   [7:0] left_x,
    input   [7:0] paddle,
    input   [8:0] spinner,
    input  [24:0] mouse,
    input   [1:0] wheel_source,
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

    function automatic [7:0] wheel_deadzone(input [7:0] raw);
        logic [7:0] v;
        begin
            v = raw ^ 8'h80;
            // This is algebraically the same subtractive deadzone as
            // 128 + ((v - 128) +/- WHEEL_DZ), expressed in offset-binary so
            // every intermediate and the ADC result remain explicitly 8-bit.
            if (v >= (8'd128 - WHEEL_DZ) && v <= (8'd128 + WHEEL_DZ))
                wheel_deadzone = 8'h80;
            else if (v > 8'd128)
                wheel_deadzone = v - WHEEL_DZ;
            else
                wheel_deadzone = v + WHEEL_DZ;
        end
    endfunction

    reg  [7:0] spinner_position;
    reg        spinner_toggle_d;

    function automatic [7:0] spinner_step(
        input [7:0] position,
        input signed [10:0] delta
    );
        reg signed [11:0] next_position;
        begin
            next_position = $signed({4'b0000, position}) + delta;
            if (next_position < 0)
                spinner_step = 8'h00;
            else if (next_position > 12'sd255)
                spinner_step = 8'hff;
            else
                spinner_step = next_position[7:0];
        end
    endfunction

    reg  [24:0] mouse_q;
    reg         mouse_toggle_d;
    reg         mouse_valid;

    // Match the working Arkanoid/Tempest HPS mouse transport: bit 24 is an
    // event toggle, bit 4 carries the signed Y direction, and bits 15:8
    // carry the relative Y magnitude.
    wire mouse_event = mouse_valid && (mouse_q[24] != mouse_toggle_d);
    wire signed [9:0] mouse_delta =
        $signed({mouse_q[4], mouse_q[4], mouse_q[15:8]});
    wire signed [10:0] spinner_delta_ext =
        $signed({{3{spinner[7]}}, spinner[7:0]});
    wire signed [10:0] mouse_delta_ext =
        $signed({mouse_delta[9], mouse_delta});
    wire signed [10:0] relative_delta =
        (spinner[8] != spinner_toggle_d ? spinner_delta_ext : 11'sd0) +
        (mouse_event ? mouse_delta_ext : 11'sd0);
    wire signed [10:0] relative_delta_selected =
        (wheel_source == 2'd3) ? -relative_delta : relative_delta;

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
            if ((spinner[8] != spinner_toggle_d) || mouse_event)
                spinner_position <= spinner_step(spinner_position,
                                                 relative_delta_selected);
        end
    end

    reg [7:0] wheel_source_value;
    always @(*) begin
        case (wheel_source)
            2'd1: wheel_source_value = paddle;
            2'd2,
            2'd3: wheel_source_value = spinner_position;
            default: wheel_source_value = wheel_deadzone(left_x);
        endcase
    end

    wire [7:0] wheel_live = wheel_source_value;

    function automatic [8:0] wheel_distance(
        input [7:0] a,
        input [7:0] b
    );
        wheel_distance = (a >= b) ? ({1'b0, a} - {1'b0, b})
                                  : ({1'b0, b} - {1'b0, a});
    endfunction

    reg [7:0] wheel_latest;
    reg [7:0] wheel_delivered;
    reg [7:0] wheel_pending;
    reg       wheel_pending_valid;

    wire signed [8:0] stick_y =
        $signed({right_y[7], right_y});
    wire [8:0] accel_mag = (stick_y < 0) ? -stick_y : 9'd0;
    wire [8:0] brake_mag = (stick_y > 0) ?  stick_y : 9'd0;

    function automatic [7:0] pedal(input [8:0] magnitude);
        pedal = (magnitude >= 9'd127) ? 8'hff : {magnitude[6:0], 1'b0};
    endfunction

    // Rad Mobile polls the MSM6253 more slowly than a USB stick can report a
    // complete out-and-back motion. Retain the strongest excursion between
    // channel-0 loads, then present the latest coordinate on the following
    // load. Other driving sets keep the direct positional path.
    // Digital d-pad steering is a fallback for pads without an analog stick.
    // MiSTer controller maps can also bind the left stick to the d-pad bits,
    // so a deflected stick would assert left/right beside its analog axis;
    // honour the d-pad only while the stick rests inside its deadzone.
    // Full deflection saturates the 8-bit ADC endpoint.
    wire stick_at_rest = (wheel_deadzone(left_x) == 8'h80);
    assign wheel = (stick_at_rest && digital_right) ? 8'hff :
                   (stick_at_rest && digital_left)  ? 8'h00 :
                   (capture_wheel && wheel_pending_valid)
                 ? wheel_pending : wheel_live;

    always @(posedge clk) begin
        if (rst) begin
            wheel_latest       <= 8'h80;
            wheel_delivered    <= 8'h80;
            wheel_pending      <= 8'h80;
            wheel_pending_valid <= 1'b0;
        end
        else if (!capture_wheel) begin
            wheel_latest       <= wheel_live;
            wheel_delivered    <= wheel_live;
            wheel_pending      <= wheel_live;
            wheel_pending_valid <= 1'b0;
        end
        else if (wheel_sample) begin
            // The MSM6253 captures the pre-edge value of wheel. If the stick
            // has already returned or moved elsewhere, retain that latest
            // coordinate for the next conversion so steering cannot stick.
            wheel_delivered <= wheel;
            wheel_latest    <= wheel_live;
            wheel_pending   <= wheel_live;
            wheel_pending_valid <= (wheel_live != wheel);
        end
        else if (wheel_live != wheel_latest) begin
            wheel_latest <= wheel_live;
            if (!wheel_pending_valid) begin
                if (wheel_live != wheel_delivered) begin
                    wheel_pending       <= wheel_live;
                    wheel_pending_valid <= 1'b1;
                end
            end
            else if (wheel_distance(wheel_live, wheel_delivered) >=
                     wheel_distance(wheel_pending, wheel_delivered)) begin
                wheel_pending <= wheel_live;
            end
        end
    end

    assign accel = digital_accel ? 8'hff : pedal(accel_mag);
    assign brake = digital_brake ? 8'hff : pedal(brake_mag);
endmodule
