//============================================================================
//  GunCon-only PSX/SNAC serial adapter for the System 32 positional-gun sets.
//
//  The transaction timing and GunCon packet interpretation are adapted from
//  the Point Blank 2 implementation in SYSTEM11_MiSTer, pinned at:
//    https://github.com/misteraddons/SYSTEM11_MiSTer/commit/
//      c2f2374386c28923d98588d25d509ea075ef9746
//  That donor is GPL-2.0-or-later; this file remains inside the core's GPLv3
//  source tree and deliberately carries only the GunCon controller transport.
//  neGcon, JogCon, wheel, mouse, and the donor's other SNAC device modes are
//  not included.
//
//  The small response store is explicitly register-sized (9 x 8 bits), not a
//  memory intended for M10K inference. Coordinates use the donor's initial
//  NTSC GunCon ranges; CRT/light-gun testing must validate calibration.
//============================================================================

module s32_guncon_snac #(
    // clk_sys = 48.317307 MHz. These values preserve the donor's approximately
    // 249 kHz serial clock and its select/ACK/inter-byte timing.
    parameter integer HALF_PERIOD     = 97,
    parameter integer SELECT_DELAY   = 364,
    parameter integer ACK_TIMEOUT    = 2567,
    parameter integer INTERBYTE_DELAY = 247,
    parameter integer DESELECT_DELAY = 2415
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        enable_p1,
    input  wire        enable_p2,
    input  wire        frame_sync,
    input  wire        data_in,
    input  wire        ack_in,

    output reg         select1_n,
    output reg         select2_n,
    output reg         command,
    output reg         serial_clk,

    output reg         p1_connected,
    output reg         p2_connected,
    output reg         p1_sample_valid,
    output reg         p2_sample_valid,
    output reg [7:0]   p1_device_id,
    output reg [7:0]   p2_device_id,
    output reg [15:0]  p1_buttons,
    output reg [15:0]  p2_buttons,
    output reg [8:0]   p1_raw_x,
    output reg [8:0]   p1_raw_y,
    output reg [8:0]   p2_raw_x,
    output reg [8:0]   p2_raw_y,
    output reg         p1_gun_aim_valid,
    output reg         p2_gun_aim_valid,
    output reg [9:0]   p1_gun_x,
    output reg [9:0]   p2_gun_x,
    output reg [7:0]   p1_gun_y,
    output reg [7:0]   p2_gun_y
);

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_SELECT     = 4'd1;
    localparam [3:0] ST_BIT_LOW    = 4'd2;
    localparam [3:0] ST_BIT_HIGH   = 4'd3;
    localparam [3:0] ST_WAIT_ACK   = 4'd4;
    localparam [3:0] ST_INTERBYTE  = 4'd5;
    localparam [3:0] ST_FINISH     = 4'd6;
    localparam [3:0] ST_DESELECT   = 4'd7;

    // The donor maps raw X 0x04d..0x1cd to 0..1023 and raw Y 0x019..0x0f8
    // to 0..255. Shift/add forms preserve that mapping without a wide
    // variable multiplier.
    function automatic [9:0] normalize_x(input [8:0] raw);
        reg [8:0] delta;
        reg [18:0] scaled;
        begin
            if (raw <= 9'h04d)
                normalize_x = 10'd0;
            else if (raw >= 9'h1cd)
                normalize_x = 10'h3ff;
            else begin
                delta = raw - 9'h04d;
                // 341 = 256 + 64 + 16 + 4 + 1; divide by 128.
                scaled = ({10'd0, delta} << 8) +
                         ({10'd0, delta} << 6) +
                         ({10'd0, delta} << 4) +
                         ({10'd0, delta} << 2) + delta;
                normalize_x = scaled >> 7;
            end
        end
    endfunction

    function automatic [7:0] normalize_y(input [8:0] raw);
        reg [8:0] delta;
        reg [18:0] scaled;
        begin
            if (raw <= 9'h019)
                normalize_y = 8'd0;
            else if (raw >= 9'h0f8)
                normalize_y = 8'hff;
            else begin
                delta = raw - 9'h019;
                // 293 = 256 + 32 + 4 + 1; divide by 256.
                scaled = ({10'd0, delta} << 8) +
                         ({10'd0, delta} << 5) +
                         ({10'd0, delta} << 2) + delta;
                normalize_y = scaled >> 8;
            end
        end
    endfunction

    // Two-stage synchronizers are required for the external DATA/ACK lines.
    // frame_sync is generated in clk_sys, but is also synchronized here so a
    // stand-alone harness can drive the adapter from an independent source.
    reg data_meta, data_sync;
    reg ack_meta, ack_sync;
    reg frame_meta, frame_sync_i, frame_d;
    reg enable_p1_d, enable_p2_d;
    wire frame_rise = frame_sync_i & ~frame_d;
    wire poll_request = frame_rise |
                        (enable_p1 & ~enable_p1_d) |
                        (enable_p2 & ~enable_p2_d);

    reg [3:0] state;
    reg [12:0] timer;
    reg [3:0] byte_index;
    reg [2:0] bit_index;
    reg       active_port; // 0 = P1, 1 = P2
    reg [7:0] tx_byte;
    reg [7:0] rx_shift;

    // Deliberately individual registers: the response is a tiny protocol
    // scratchpad and must remain in ordinary logic rather than an M10K.
    reg [7:0] rx0, rx1, rx2, rx3, rx4, rx5, rx6, rx7, rx8;
    wire [8:0] decoded_gun_x = {rx6[0], rx5};
    wire [8:0] decoded_gun_y = {rx8[0], rx7};
    wire response_valid = (rx1 != 8'h00) && (rx1 != 8'hff) &&
                          (rx2 == 8'h5a);
    // Match the donor's GunCon validity contract: an identified controller
    // is connected even when its optical sample is outside the NTSC window,
    // but only an in-range sample may replace the USB/ADC fallback.
    wire gun_coordinates_valid = response_valid && (rx1 == 8'h63) &&
                                 (decoded_gun_x >= 9'h04d) &&
                                 (decoded_gun_x <= 9'h1cd) &&
                                 (decoded_gun_y >= 9'h019) &&
                                 (decoded_gun_y <= 9'h0f8);

    always @(posedge clk) begin
        if (rst) begin
            data_meta <= 1'b1;
            data_sync <= 1'b1;
            ack_meta <= 1'b1;
            ack_sync <= 1'b1;
            frame_meta <= 1'b0;
            frame_sync_i <= 1'b0;
            frame_d <= 1'b0;
            enable_p1_d <= 1'b0;
            enable_p2_d <= 1'b0;

            state <= ST_IDLE;
            timer <= 13'd0;
            byte_index <= 4'd0;
            bit_index <= 3'd0;
            active_port <= 1'b0;
            tx_byte <= 8'h01;
            rx_shift <= 8'd0;
            rx0 <= 0; rx1 <= 0; rx2 <= 0; rx3 <= 0; rx4 <= 0;
            rx5 <= 0; rx6 <= 0; rx7 <= 0; rx8 <= 0;

            select1_n <= 1'b1;
            select2_n <= 1'b1;
            command <= 1'b1;
            serial_clk <= 1'b1;

            p1_connected <= 1'b0;
            p2_connected <= 1'b0;
            p1_sample_valid <= 1'b0;
            p2_sample_valid <= 1'b0;
            p1_device_id <= 0;
            p2_device_id <= 0;
            p1_buttons <= 0;
            p2_buttons <= 0;
            p1_raw_x <= 0;
            p1_raw_y <= 0;
            p2_raw_x <= 0;
            p2_raw_y <= 0;
            p1_gun_aim_valid <= 1'b0;
            p2_gun_aim_valid <= 1'b0;
            p1_gun_x <= 10'd512;
            p2_gun_x <= 10'd512;
            p1_gun_y <= 8'd128;
            p2_gun_y <= 8'd128;
        end
        else begin
            data_meta <= data_in;
            data_sync <= data_meta;
            ack_meta <= ack_in;
            ack_sync <= ack_meta;
            frame_meta <= frame_sync;
            frame_sync_i <= frame_meta;
            frame_d <= frame_sync_i;
            enable_p1_d <= enable_p1;
            enable_p2_d <= enable_p2;

            p1_sample_valid <= 1'b0;
            p2_sample_valid <= 1'b0;

            // Turning a port off invalidates its last sample immediately; the
            // next enabled frame starts a fresh identification transaction.
            if (!enable_p1) begin
                p1_connected <= 1'b0;
                p1_gun_aim_valid <= 1'b0;
                p1_buttons <= 16'd0;
            end
            if (!enable_p2) begin
                p2_connected <= 1'b0;
                p2_gun_aim_valid <= 1'b0;
                p2_buttons <= 16'd0;
            end

            case (state)
                ST_IDLE: begin
                    select1_n <= 1'b1;
                    select2_n <= 1'b1;
                    command <= 1'b1;
                    serial_clk <= 1'b1;
                    timer <= 13'd0;
                    if (poll_request) begin
                        if (enable_p1) begin
                            active_port <= 1'b0;
                            select1_n <= 1'b0;
                            select2_n <= 1'b1;
                            tx_byte <= 8'h01;
                            byte_index <= 4'd0;
                            bit_index <= 3'd0;
                            rx_shift <= 8'd0;
                            rx0 <= 0; rx1 <= 0; rx2 <= 0; rx3 <= 0; rx4 <= 0;
                            rx5 <= 0; rx6 <= 0; rx7 <= 0; rx8 <= 0;
                            state <= ST_SELECT;
                        end
                        else if (enable_p2) begin
                            active_port <= 1'b1;
                            select1_n <= 1'b1;
                            select2_n <= 1'b0;
                            tx_byte <= 8'h01;
                            byte_index <= 4'd0;
                            bit_index <= 3'd0;
                            rx_shift <= 8'd0;
                            rx0 <= 0; rx1 <= 0; rx2 <= 0; rx3 <= 0; rx4 <= 0;
                            rx5 <= 0; rx6 <= 0; rx7 <= 0; rx8 <= 0;
                            state <= ST_SELECT;
                        end
                    end
                end

                ST_SELECT: begin
                    if (timer == SELECT_DELAY-1) begin
                        timer <= 13'd0;
                        bit_index <= 3'd0;
                        rx_shift <= 8'd0;
                        command <= 1'b1; // 0x01 bit 0
                        serial_clk <= 1'b0;
                        state <= ST_BIT_LOW;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                // The host changes COMMAND while CLK is low and samples DATA
                // on the low-to-high edge. PSX sends each byte LSB first.
                ST_BIT_LOW: begin
                    if (timer == HALF_PERIOD-1) begin
                        timer <= 13'd0;
                        serial_clk <= 1'b1;
                        rx_shift <= {data_sync, rx_shift[7:1]};
                        state <= ST_BIT_HIGH;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                ST_BIT_HIGH: begin
                    if (timer == HALF_PERIOD-1) begin
                        timer <= 13'd0;
                        if (bit_index == 3'd7) begin
                            case (byte_index)
                                4'd0: rx0 <= rx_shift;
                                4'd1: rx1 <= rx_shift;
                                4'd2: rx2 <= rx_shift;
                                4'd3: rx3 <= rx_shift;
                                4'd4: rx4 <= rx_shift;
                                4'd5: rx5 <= rx_shift;
                                4'd6: rx6 <= rx_shift;
                                4'd7: rx7 <= rx_shift;
                                default: rx8 <= rx_shift;
                            endcase
                            state <= ST_WAIT_ACK;
                        end
                        else begin
                            bit_index <= bit_index + 1'b1;
                            command <= tx_byte[bit_index + 1'b1];
                            serial_clk <= 1'b0;
                            state <= ST_BIT_LOW;
                        end
                    end
                    else
                        timer <= timer + 1'b1;
                end

                // ACK is an active-low pulse from the controller. A timeout
                // is intentional: an empty SNAC port must not stall gameplay.
                ST_WAIT_ACK: begin
                    if (!ack_sync || timer == ACK_TIMEOUT-1) begin
                        timer <= 13'd0;
                        state <= ST_INTERBYTE;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                ST_INTERBYTE: begin
                    if (timer == INTERBYTE_DELAY-1) begin
                        timer <= 13'd0;
                        if (byte_index == 4'd8) begin
                            state <= ST_FINISH;
                        end
                        else begin
                            byte_index <= byte_index + 1'b1;
                            bit_index <= 3'd0;
                            rx_shift <= 8'd0;
                            if (byte_index == 4'd0) begin
                                tx_byte <= 8'h42;
                                command <= 1'b0; // 0x42 bit 0
                            end
                            else begin
                                tx_byte <= 8'h00;
                                command <= 1'b0;
                            end
                            serial_clk <= 1'b0;
                            state <= ST_BIT_LOW;
                        end
                    end
                    else
                        timer <= timer + 1'b1;
                end

                ST_FINISH: begin
                    command <= 1'b1;
                    serial_clk <= 1'b1;
                    timer <= 13'd0;
                    if (active_port == 1'b0) begin
                        p1_device_id <= rx1;
                        p1_sample_valid <= 1'b1;
                        if (response_valid) begin
                            p1_connected <= 1'b1;
                            p1_buttons <= ~{rx4, rx3};
                            p1_raw_x <= decoded_gun_x;
                            p1_raw_y <= decoded_gun_y;
                            p1_gun_aim_valid <= gun_coordinates_valid;
                            p1_gun_x <= gun_coordinates_valid ? normalize_x(decoded_gun_x) : 10'd0;
                            p1_gun_y <= gun_coordinates_valid ? normalize_y(decoded_gun_y) : 8'd0;
                        end
                        else begin
                            p1_connected <= 1'b0;
                            p1_buttons <= 16'd0;
                            p1_raw_x <= 0;
                            p1_raw_y <= 0;
                            p1_gun_aim_valid <= 1'b0;
                            p1_gun_x <= 10'd0;
                            p1_gun_y <= 8'd0;
                        end
                    end
                    else begin
                        p2_device_id <= rx1;
                        p2_sample_valid <= 1'b1;
                        if (response_valid) begin
                            p2_connected <= 1'b1;
                            p2_buttons <= ~{rx4, rx3};
                            p2_raw_x <= decoded_gun_x;
                            p2_raw_y <= decoded_gun_y;
                            p2_gun_aim_valid <= gun_coordinates_valid;
                            p2_gun_x <= gun_coordinates_valid ? normalize_x(decoded_gun_x) : 10'd0;
                            p2_gun_y <= gun_coordinates_valid ? normalize_y(decoded_gun_y) : 8'd0;
                        end
                        else begin
                            p2_connected <= 1'b0;
                            p2_buttons <= 16'd0;
                            p2_raw_x <= 0;
                            p2_raw_y <= 0;
                            p2_gun_aim_valid <= 1'b0;
                            p2_gun_x <= 10'd0;
                            p2_gun_y <= 8'd0;
                        end
                    end
                    state <= ST_DESELECT;
                end

                ST_DESELECT: begin
                    if (timer == DESELECT_DELAY-1) begin
                        timer <= 13'd0;
                        select1_n <= 1'b1;
                        select2_n <= 1'b1;
                        // Poll P2 after P1 in the same frame. P1 is never
                        // restarted here; the next frame owns the next cycle.
                        if ((active_port == 1'b0) && enable_p2) begin
                            active_port <= 1'b1;
                            select2_n <= 1'b0;
                            tx_byte <= 8'h01;
                            byte_index <= 4'd0;
                            bit_index <= 3'd0;
                            rx_shift <= 8'd0;
                            rx0 <= 0; rx1 <= 0; rx2 <= 0; rx3 <= 0; rx4 <= 0;
                            rx5 <= 0; rx6 <= 0; rx7 <= 0; rx8 <= 0;
                            state <= ST_SELECT;
                        end
                        else
                            state <= ST_IDLE;
                    end
                    else
                        timer <= timer + 1'b1;
                end

                default: begin
                    state <= ST_IDLE;
                    select1_n <= 1'b1;
                    select2_n <= 1'b1;
                    command <= 1'b1;
                    serial_clk <= 1'b1;
                    timer <= 13'd0;
                end
            endcase
        end
    end

endmodule
