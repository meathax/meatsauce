import s24_pkg::*;

// Converts an absolute analog-stick X deflection into the relative
// toggle+magnitude spinner event format consumed by s24_upd4701. Native
// spinner events retain their payload and bypass all synthetic-stick shaping.
module s24_wheel_input (
    input  logic               clk,
    input  logic               reset,
    input  logic               tick,
    input  logic               stick_enable,
    input  logic signed [7:0]  stick_x,
    input  logic [2:0]         speed_code,
    input  logic [1:0]         response_code,
    input  logic [1:0]         analogue_profile,
    input  logic               digital_left,
    input  logic               digital_right,
    input  logic [8:0]         spinner_in,
    output logic [8:0]         spinner_out
);
    localparam logic [7:0] HOTROD_ENTER = 8'd12;
    localparam logic [7:0] HOTROD_EXIT  = 8'd8;
    localparam logic [7:0] ROUGH_ENTER  = 8'd16;
    localparam logic [7:0] ROUGH_EXIT   = 8'd10;

    // Exact threshold form of floor(value^2/1024) +
    // floor(value^2/4096) + 1, saturated at 14.
    function automatic [5:0] standard_speed_base(input logic [7:0] value);
        begin
            if(value==0)        standard_speed_base=6'd0;
            else if(value<32)   standard_speed_base=6'd1;
            else if(value<46)   standard_speed_base=6'd2;
            else if(value<56)   standard_speed_base=6'd3;
            else if(value<64)   standard_speed_base=6'd4;
            else if(value<72)   standard_speed_base=6'd6;
            else if(value<79)   standard_speed_base=6'd7;
            else if(value<85)   standard_speed_base=6'd8;
            else if(value<91)   standard_speed_base=6'd9;
            else if(value<96)   standard_speed_base=6'd11;
            else if(value<102)  standard_speed_base=6'd12;
            else if(value<107)  standard_speed_base=6'd13;
            else                standard_speed_base=6'd14;
        end
    endfunction

    logic [7:0] stick_abs,deadzone_enter,deadzone_exit;
    logic stick_active,motion_active;
    logic [7:0] effective_raw,effective;
    logic [9:0] response_scaled;
    logic [14:0] curve_square;
    logic [14:0] curve_scaled;
    logic [5:0] speed_base;
    logic [7:0] speed_mag;
    logic [18:0] rough_product;
    logic [10:0] rough_rate,rough_rate_q;
    logic [2:0] speed_factor;
    logic [1:0] response_select;
    logic [13:0] analog_source;
    logic [15:0] analog_scaled;
    logic [7:0] normal_product;
    logic [16:0] analog_sum;
    logic [10:0] analog_remainder;
    logic [6:0] analog_step;
    logic [2:0] speed_code_q;
    logic [1:0] response_code_q;
    logic signed [7:0] steering_step;
    logic stick_toggle;

    // response_effective is capped at 150, so 150^2*23=517500 fits 19 bits.
    assign rough_product = curve_square * 6'd23;

    always_comb begin
        case(speed_code)
            3'd1: speed_factor=3'd1;
            3'd2: speed_factor=3'd2;
            3'd3: speed_factor=3'd3;
            3'd4: speed_factor=3'd5;
            3'd5: speed_factor=3'd6;
            3'd6: speed_factor=3'd7;
            default: speed_factor=3'd4;
        endcase
        response_select = response_code == 2'd3 ? 2'd0 : response_code;

        stick_abs = stick_x[7] ? (~stick_x + 8'd1) : stick_x;
        if(analogue_profile==ANALOGUE_ROUGHRAC) begin
            deadzone_enter=ROUGH_ENTER;
            deadzone_exit=ROUGH_EXIT;
        end else begin
            deadzone_enter=HOTROD_ENTER;
            deadzone_exit=HOTROD_EXIT;
        end
        motion_active=stick_active || stick_abs>=deadzone_enter;
        effective_raw = motion_active && stick_abs>deadzone_exit
                      ? stick_abs-deadzone_exit : 8'd0;
        case(response_select)
            2'd1: response_scaled=({2'd0,effective_raw}+
                                    {1'd0,effective_raw,1'd0}+10'd2)>>2;
            2'd2: response_scaled=({2'd0,effective_raw}+
                                    {effective_raw,2'd0}+10'd2)>>2;
            default: response_scaled={2'd0,effective_raw};
        endcase
        effective = response_scaled > 10'd150 ? 8'd150
                                              : response_scaled[7:0];
        curve_square = effective * effective;
        curve_scaled = {10'd0,curve_square[14:10]} +
                       {12'd0,curve_square[14:12]} + 15'd1;
        if(effective==0) speed_base=0;
        else if(stick_abs>=8'd120 || curve_scaled>15'd14) speed_base=6'd14;
        else speed_base=curve_scaled[5:0];
        speed_mag = speed_base<=6'd5 ? {2'd0,speed_base}
                                     : {2'd0,speed_base-1'b1};
        // In the standard profile analog_source is speed_mag << 9 and the
        // factor case below only multiplies it by 1..7.  Compute the small
        // exact product first so Quartus does not build a wide mux of
        // parallel shifted adders on the stick_x -> analog_step path.
        normal_product = speed_mag[4:0] * speed_factor;

        // Preserve the old Q8 numerator. The common Q11 accumulator and
        // default factor four reproduce its previous Q9 half-rate cadence.
        if(stick_abs>=8'd120) rough_rate=11'd1280;
        else rough_rate=rough_product[18:8];

        analog_source = analogue_profile==ANALOGUE_ROUGHRAC
                      ? {3'd0,rough_rate_q} : {speed_mag[4:0],9'd0};
        if(analogue_profile==ANALOGUE_ROUGHRAC) begin
            // Rough Racer keeps the original Q11 source and exact factors.
            // Exact quarter factors k=1..7 using shifts/adds only.
            case(speed_factor)
                3'd1: analog_scaled={2'd0,analog_source};
                3'd2: analog_scaled={1'd0,analog_source,1'd0};
                3'd3: analog_scaled={2'd0,analog_source}+
                                    {1'd0,analog_source,1'd0};
                3'd5: analog_scaled={2'd0,analog_source}+{analog_source,2'd0};
                3'd6: analog_scaled={1'd0,analog_source,1'd0}+
                                    {analog_source,2'd0};
                3'd7: analog_scaled={2'd0,analog_source}+
                                    {1'd0,analog_source,1'd0}+
                                    {analog_source,2'd0};
                default: analog_scaled={analog_source,2'd0};
            endcase
        end else begin
            // speed_mag is at most 13, so normal_product is at most 91 and
            // its nine-bit shift is exactly the former analog_scaled value.
            analog_scaled={normal_product[6:0],9'd0};
        end
        analog_sum={6'd0,analog_remainder}+{1'b0,analog_scaled};

        steering_step=0;
        if(digital_left!=digital_right) begin
            if(analogue_profile==ANALOGUE_ROUGHRAC)
                steering_step=digital_left ? -8'sd4 : 8'sd4;
            else
                steering_step=digital_left ? -8'sd7 : 8'sd7;
        end
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            stick_toggle<=0;
            stick_active<=0;
            rough_rate_q<=0;
            analog_remainder<=0;
            analog_step<=0;
            speed_code_q<=0;
            response_code_q<=0;
        end else if(tick) begin
            rough_rate_q<=rough_rate;
            if(stick_active) begin
                if(stick_abs<=deadzone_exit) stick_active<=0;
            end else if(stick_abs>=deadzone_enter) stick_active<=1;

            if(speed_code!=speed_code_q || response_code!=response_code_q) begin
                speed_code_q<=speed_code;
                response_code_q<=response_code;
                analog_remainder<=0;
            end else if(stick_enable && !digital_left && !digital_right) begin
                analog_remainder<=analog_sum[10:0];
                if(analog_sum[16:11]!=0) begin
                    analog_step<={1'd0,analog_sum[16:11]};
                    stick_toggle<=~stick_toggle;
                end
            end else begin
                analog_remainder<=0;
                if(stick_enable && steering_step!=0)
                    stick_toggle<=~stick_toggle;
            end
        end else begin
            rough_rate_q<=rough_rate;
        end
    end

    logic hw_toggle_d,stick_toggle_d;
    always_ff @(posedge clk) begin
        if(reset) begin
            hw_toggle_d<=spinner_in[8];
            stick_toggle_d<=0;
            spinner_out<=0;
        end else begin
            hw_toggle_d<=spinner_in[8];
            stick_toggle_d<=stick_toggle;
            if(spinner_in[8]!=hw_toggle_d)
                spinner_out<={~spinner_out[8],spinner_in[7:0]};
            if(stick_toggle!=stick_toggle_d)
                spinner_out<={~spinner_out[8],
                    stick_enable && !digital_left && !digital_right
                    ? (stick_x[7] ? -$signed({1'b0,analog_step})
                                  :  $signed({1'b0,analog_step}))
                    : steering_step[7:0]};
        end
    end
endmodule
