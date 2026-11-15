// F3 relative dial adapter. One frame tick, 12-bit wrap, four fractional bits.
// No inertia: a centred stick holds position. Small movements retain fractions.
module rf_paddle (
    input  wire        clk, reset, tick, enabled, hold_input,
    input  wire [7:0]  axis,
    input  wire        left, right,
    input  wire [1:0]  deadzone, sensitivity,
    output wire [15:0] dial
);
    reg [15:0] position;
    reg [7:0] magnitude, threshold, travel;
    reg [9:0] speed;
    reg [10:0] scaled;
    reg negative;

    always @* begin
        // Clamp -128 to match +127, including inexpensive controllers.
        magnitude = axis == 8'h80 ? 8'd127 : axis[7] ? (~axis + 8'd1) : axis;
        case (deadzone)
            2'd0: threshold = 8'd8;
            2'd1: threshold = 8'd0;
            2'd2: threshold = 8'd16;
            default: threshold = 8'd24;
        endcase
        travel = magnitude > threshold ? magnitude - threshold : 8'd0;
        negative = axis[7];
        // Continuous two-slope curve: precision near centre, fast edge travel.
        speed = travel <= 8'd32 ? {2'd0, travel} :
                10'd32 + ({2'd0, travel} - 10'd32) * 10'd4;
        if (travel == 0) begin
            negative = left;
            speed = (left ^ right) ? 10'd400 : 10'd0;
        end
        case (sensitivity)
            2'd0: scaled = {1'b0, speed};
            2'd1: scaled = {2'b0, speed[9:1]};
            2'd2: scaled = {1'b0, speed} + {2'b0, speed[9:1]};
            default: scaled = {speed, 1'b0};
        endcase
    end

    always @(posedge clk) begin
        if (reset || !enabled) position <= 16'd0;
        else if (tick && !hold_input) begin
            if (negative) position <= position - {5'd0, scaled};
            else          position <= position + {5'd0, scaled};
        end
    end
    // MAME taito_f3_state::f3_analog_r: ((count & 15)<<12)|(count>>4).
    assign dial = {position[7:4], 4'b0000, position[15:8]};
endmodule
