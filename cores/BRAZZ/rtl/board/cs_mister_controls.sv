// SPDX-License-Identifier: GPL-3.0-or-later
// Crystal System active-low pins, from MAME 0.289 crystal.cpp input ports, selected by the MRA board
// record game id: crystal (crysking/evosocc), topbladv, officeye and urachamu (three players).
module cs_mister_controls (
    input logic clk, reset,
    input logic [7:0] game_id,
    input logic [31:0] joystick_0, joystick_1, joystick_2,
    input logic osd_open, persistence_pause,
    input logic test_switch, // OSD Test switch (held while On), as the board's test/service input
    input logic ioctl_download, ioctl_wr,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [7:0] ioctl_dout,
    output logic [31:0] p1_p2_n, p3_p4_n,
    output logic [7:0] system_n,
    output logic [7:0] dips_n = 8'hff,
    output logic pause_cpu
);
    localparam logic [7:0] TOPBLADV = 8'd3, OFFICEYE = 8'd4, URACHAMU = 8'd5;
    // MAME PORT_IMPULSE(1): Top Blade V sees a coin as a one-frame pulse (60.054 Hz frame).
    localparam int FRAME_CLOCKS = 1430520;
    logic pause_latched = 0, pause_previous = 0;
    logic [1:0] coin_previous = 0;
    logic [20:0] coin_pulse [0:1];
    initial begin coin_pulse[0] = 0; coin_pulse[1] = 0; end
    wire pause_button = joystick_0[10] | joystick_1[10] | joystick_2[10];
    wire three_player = game_id == OFFICEYE || game_id == URACHAMU;
    wire [1:0] coin_button = {joystick_1[9] | (three_player & joystick_2[9]), joystick_0[9]};
    // DIP bytes are owned by Main_MiSTer's index-254 transport, independently
    // of a game reset. A reset must not silently discard the selected switches.
    always_ff @(posedge clk) begin
        if (ioctl_wr && ioctl_index == 16'd254 && ioctl_addr == 0)
            dips_n <= ioctl_dout;
        pause_previous <= pause_button;
        coin_previous <= coin_button;
        for (int i = 0; i < 2; i++)
            if (coin_button[i] && !coin_previous[i]) coin_pulse[i] <= 21'(FRAME_CLOCKS);
            else if (coin_pulse[i] != 0) coin_pulse[i] <= coin_pulse[i] - 21'd1;
        if (reset) pause_latched <= 0;
        else if (pause_button && !pause_previous) pause_latched <= !pause_latched;
    end
    always_comb begin
        p1_p2_n = 32'hffffffff;
        p3_p4_n = 32'hffffffff;
        system_n = 8'hff;
        if (three_player) begin
            // officeye/urachamu: P2 buttons and start in the low byte, P1/P3 interleaved above.
            p1_p2_n[0] = !joystick_1[4]; p1_p2_n[2] = !joystick_1[5]; p1_p2_n[4] = !joystick_1[6];
            p1_p2_n[6] = !joystick_1[8];
            p1_p2_n[16] = !joystick_0[4]; p1_p2_n[17] = !joystick_2[4];
            p1_p2_n[18] = !joystick_0[5]; p1_p2_n[19] = !joystick_2[5];
            p1_p2_n[20] = !joystick_0[6]; p1_p2_n[21] = !joystick_2[6];
            p1_p2_n[22] = !joystick_0[8]; p1_p2_n[23] = !joystick_2[8];
            system_n[4] = !coin_button[0]; system_n[5] = !coin_button[1];
            system_n[6] = !(joystick_0[11] | joystick_1[11] | joystick_2[11]); // service credit
            system_n[7] = !(joystick_0[12] | joystick_1[12] | joystick_2[12] | test_switch); // test/menu
        end else begin
            // Buttons 1-4 (topbladv: 1-2) on even/odd player bits (MAME crystal P1_P2 bits 0-7).
            for (int i = 0; i < 4; i++) begin
                if (game_id != TOPBLADV || i < 2) begin
                    p1_p2_n[2*i]   = !joystick_0[4+i];
                    p1_p2_n[2*i+1] = !joystick_1[4+i];
                end
            end
            p1_p2_n[16] = !joystick_0[3]; p1_p2_n[17] = !joystick_1[3];
            p1_p2_n[18] = !joystick_0[2]; p1_p2_n[19] = !joystick_1[2];
            p1_p2_n[20] = !joystick_0[1]; p1_p2_n[21] = !joystick_1[1];
            p1_p2_n[22] = !joystick_0[0]; p1_p2_n[23] = !joystick_1[0];
            system_n[0] = !joystick_0[8]; system_n[1] = !joystick_1[8];
            if (game_id == TOPBLADV) begin
                // MAME topbladv: impulse coins, test on bit 6, service credit on bit 7.
                system_n[4] = coin_pulse[0] == 0; system_n[5] = coin_pulse[1] == 0;
                system_n[6] = !(joystick_0[12] | joystick_1[12] | test_switch);
                system_n[7] = !(joystick_0[11] | joystick_1[11]);
            end else begin
                system_n[4] = !joystick_0[9]; system_n[5] = !joystick_1[9];
                system_n[6] = !(joystick_0[11] | joystick_1[11]); // service credit
                system_n[7] = !(joystick_0[12] | joystick_1[12] | test_switch); // momentary test/menu
            end
        end
        pause_cpu = pause_latched | osd_open | persistence_pause;
    end
endmodule
