// SPDX-License-Identifier: GPL-3.0-or-later
// MAME0.289 Simple156 IN0/IN1. HPS J1 slots: attack,jump,special,start,coin,pause,service,test.
module osman_inputs (
    input wire clk, reset, game_reset,
    input wire [31:0] joystick_0, joystick_1,
    input wire [15:0] analog_0, analog_1,
    input wire [10:0] ps2_key,
    input wire menu_pause, menu_service, menu_test,
    output wire [15:0] inputs_0, inputs_1,
    output wire pause_request
);
    reg key_toggle;
    reg up, down, left, right, attack, jump, special;
    reg right_attack, right_jump;
    reg coin1, coin2, start1, start2, service, test, pause_key;
    reg pause_previous, hot_pause;
    wire pause_pressed = pause_key || joystick_0[9] || joystick_1[9];
    wire signed [7:0] ax0 = analog_0[7:0], ay0 = analog_0[15:8];
    wire signed [7:0] ax1 = analog_1[7:0], ay1 = analog_1[15:8];
    wire [7:0] player1 = {
        start1 || joystick_0[7], special || joystick_0[6], jump || right_jump || joystick_0[5], attack || right_attack || joystick_0[4],
        right || joystick_0[0] || ax0 > 8'sd64, left || joystick_0[1] || ax0 < -8'sd64,
        down || joystick_0[2] || ay0 > 8'sd64, up || joystick_0[3] || ay0 < -8'sd64
    };
    wire [7:0] player2 = {
        start2 || joystick_1[7], joystick_1[6], joystick_1[5], joystick_1[4],
        joystick_1[0] || ax1 > 8'sd64, joystick_1[1] || ax1 < -8'sd64,
        joystick_1[2] || ay1 > 8'sd64, joystick_1[3] || ay1 < -8'sd64
    };
    // Bits7/8 of IN0 are supplied by the actual raster/EEPROM in osman_bus.
    // Unspecified low bits match MAME's zero default; upper CPU lanes pull up.
    assign inputs_0 = {12'd0,
        !(test || menu_test || joystick_0[11] || joystick_1[11]),
        !(service || menu_service || joystick_0[10] || joystick_1[10]),
        !(coin2 || joystick_1[8]), !(coin1 || joystick_0[8])};
    assign inputs_1 = ~{player2,player1};
    assign pause_request = menu_pause || hot_pause;
    always @(posedge clk) begin
        if (reset) begin
            key_toggle <= ps2_key[10];
            up <= 0; down <= 0; left <= 0; right <= 0;
            attack <= 0; jump <= 0; special <= 0;
            right_attack <= 0; right_jump <= 0;
            coin1 <= 0; coin2 <= 0; start1 <= 0; start2 <= 0;
            service <= 0; test <= 0; pause_key <= 0;
            pause_previous <= 0; hot_pause <= 0;
        end else begin
            key_toggle <= ps2_key[10];
            pause_previous <= pause_pressed;
            if (game_reset) hot_pause <= 0;
            else if (pause_pressed && !pause_previous) hot_pause <= !hot_pause;
            if (key_toggle != ps2_key[10]) begin
                case (ps2_key[7:0])
                    8'h75: up <= ps2_key[9];
                    8'h72: down <= ps2_key[9];
                    8'h6b: left <= ps2_key[9];
                    8'h74: right <= ps2_key[9];
                    8'h14: begin // Track left/right Ctrl independently.
                        if (ps2_key[8]) right_attack <= ps2_key[9];
                        else attack <= ps2_key[9];
                    end
                    8'h11: begin // Track left/right Alt independently.
                        if (ps2_key[8]) right_jump <= ps2_key[9];
                        else jump <= ps2_key[9];
                    end
                    8'h29: special <= ps2_key[9]; // Space
                    8'h2e: coin1 <= ps2_key[9];  // 5
                    8'h36: coin2 <= ps2_key[9];  // 6
                    8'h16: start1 <= ps2_key[9]; // 1
                    8'h1e: start2 <= ps2_key[9]; // 2
                    8'h46: service <= ps2_key[9]; // 9: service credit
                    8'h06: test <= ps2_key[9];   // F2: test/service switch
                    8'h4d: pause_key <= ps2_key[9]; // P
                    default: begin end
                endcase
            end
        end
    end
endmodule
