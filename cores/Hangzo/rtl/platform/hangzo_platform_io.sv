// SPDX-License-Identifier: GPL-3.0-or-later
// Hangzo cabinet inputs and the three MRA-loaded DIP bytes.
module hangzo_platform_io (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] joystick_0,
    input  wire [31:0] joystick_1,
    input  wire [10:0] ps2_key,
    // The caller qualifies ioctl_index == 254 before asserting dip_write.
    input  wire        dip_write,
    input  wire [26:0] dip_address,
    input  wire [7:0]  dip_data,
    output wire [15:0] player_inputs,
    output wire [15:0] dips,
    output wire [7:0]  dips3,
    output wire [2:0]  coin_service,
    // One-cycle toggle request from either controller Pause or keyboard F4.
    output reg         pause_toggle_request
);
    reg [31:0] key_p1, key_p2;
    reg key_service;
    reg key_pause_down;
    reg key_toggle;
    reg [1:0] pause_previous;

    reg [7:0] dip_sw1;
    reg [7:0] dip_sw2;
    reg [7:0] dip_sw3;

    wire [31:0] joy_p1 = joystick_0 | key_p1;
    wire [31:0] joy_p2 = joystick_1 | key_p2;

    // MAME Hangzo INPUTS is active-low: P1 occupies bits 0-7 and P2 8-15.
    // MiSTer joystick bits are active-high; its directions are R,L,D,U at 0-3.
    wire [7:0] player_1_n = {
        ~joy_p1[10], ~joy_p1[6], ~joy_p1[5], ~joy_p1[4],
        ~joy_p1[0],  ~joy_p1[1], ~joy_p1[2], ~joy_p1[3]
    };
    wire [7:0] player_2_n = {
        ~joy_p2[10], ~joy_p2[6], ~joy_p2[5], ~joy_p2[4],
        ~joy_p2[0],  ~joy_p2[1], ~joy_p2[2], ~joy_p2[3]
    };
    assign player_inputs = {player_2_n, player_1_n};

    // MAME SYSTEM bits 0-2 are active-low COIN1, COIN2 and SERVICE1.
    assign coin_service = {
        ~(joy_p1[13] | joy_p2[13] | key_service),
        ~(joy_p2[11]),
        ~(joy_p1[11])
    };

    // MAME's 16-bit DSW port is low byte first; DSW3 is a separate byte.
    assign dips  = {dip_sw2, dip_sw1};
    assign dips3 = dip_sw3;

    always @(posedge clk) begin
        if (reset) begin
            key_p1 <= 32'd0;
            key_p2 <= 32'd0;
            key_service <= 1'b0;
            key_pause_down <= 1'b0;
            key_toggle <= ps2_key[10];
            pause_previous <= {joystick_1[12], joystick_0[12]};
            pause_toggle_request <= 1'b0;
        end else begin
            pause_toggle_request <= 1'b0;
            if ((joystick_0[12] && !pause_previous[0]) ||
                (joystick_1[12] && !pause_previous[1]))
                pause_toggle_request <= 1'b1;
            pause_previous <= {joystick_1[12], joystick_0[12]};

            // hps_io publishes {event_toggle, pressed, extended, scan_code}.
            // Consume an event only when bit 10 changes; bit 9 is a held level.
            if (key_toggle != ps2_key[10]) begin
                key_toggle <= ps2_key[10];
                case ({ps2_key[8], ps2_key[7:0]})
                    9'h075, 9'h175: key_p1[3] <= ps2_key[9]; // Up
                    9'h072, 9'h172: key_p1[2] <= ps2_key[9]; // Down
                    9'h06b, 9'h16b: key_p1[1] <= ps2_key[9]; // Left
                    9'h074, 9'h174: key_p1[0] <= ps2_key[9]; // Right
                    9'h01d: key_p2[3] <= ps2_key[9]; // W
                    9'h01b: key_p2[2] <= ps2_key[9]; // S
                    9'h01c: key_p2[1] <= ps2_key[9]; // A
                    9'h023: key_p2[0] <= ps2_key[9]; // D
                    9'h014, 9'h114: if (ps2_key[8]) key_p2[4] <= ps2_key[9];
                            else key_p1[4] <= ps2_key[9]; // Ctrl: Button 1
                    9'h011, 9'h111: if (ps2_key[8]) key_p2[5] <= ps2_key[9];
                            else key_p1[5] <= ps2_key[9]; // Alt: Button 2
                    9'h01a: key_p1[6] <= ps2_key[9]; // Z: Button 3
                    9'h022: key_p2[6] <= ps2_key[9]; // X: Button 3
                    9'h016: key_p1[10] <= ps2_key[9]; // 1: Start 1
                    9'h01e: key_p2[10] <= ps2_key[9]; // 2: Start 2
                    9'h02e: key_p1[11] <= ps2_key[9]; // 5: Coin 1
                    9'h036: key_p2[11] <= ps2_key[9]; // 6: Coin 2
                    9'h006: key_service <= ps2_key[9]; // F2: Service
                    9'h00c: begin // F4: toggle pause on make, ignore typematic repeats
                        if (ps2_key[9] && !key_pause_down)
                            pause_toggle_request <= 1'b1;
                        key_pause_down <= ps2_key[9];
                    end
                    default: begin end
                endcase
            end
        end
    end

    // Defaults match Hangzo's MAME 0.289 ports: DSW=7FFF, DSW3=FF.
    // The bytes are loaded independently at addresses 0, 1 and 2.
    always @(posedge clk) begin
        if (reset) begin
            dip_sw1 <= 8'hff;
            dip_sw2 <= 8'h7f;
            dip_sw3 <= 8'hff;
        end else if (dip_write) begin
            case (dip_address)
                27'd0: dip_sw1 <= dip_data;
                27'd1: dip_sw2 <= dip_data;
                27'd2: dip_sw3 <= dip_data;
                default: begin end
            endcase
        end
    end
endmodule
