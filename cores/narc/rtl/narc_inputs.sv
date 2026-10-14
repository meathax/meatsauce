`timescale 1ns/1ps
`default_nettype none
// MiSTer joystick inputs to the active-low Williams Z-unit input words.
//
// Bit assignments are taken from the rev-7 game source, not guessed:
// `reference/narc-main/NARC/NARC.ASM` SWTAB enumerates switches 0..27 across the
// 32-bit long read at SWITCH (`SYS.INC:37`), so IN0 carries switches 0..15 and
// IN1 (COINS, `SYS.INC:38`) carries switches 16..31.
//
//   IN0  0..7   P1 up, down, left, right, crouch, fire, jump, rocket bomb
//        8..15  P2 same
//   IN1  0..2   left / right / center coin      3   slam tilt
//        4      advance                         5   auto-up(1) / manual-down(0)
//        6      high score reset                7   fourth coin slot
//        8..9   P1 / P2 start                  10   master sound sync (active high)
//       11      slave sound sync / cmos protect (held inactive)
//
// SWSCAN (`NARC.ASM:2795`) activates a switch on a 1->0 edge, so every cabinet
// control is active-low; FREEZE (`NARC.ASM:2995`) spins while IN1 bit 5 is 0,
// which fixes AUTO-UP as the 1 state.
module narc_inputs (
  input  wire [31:0] joystick_0,
  input  wire [31:0] joystick_1,
  input  wire [31:0] joystick_2,
  input  wire [1:0]  sound_sync,
  input  wire [7:0]  sound_talkback,
  // Coin-door service switch (OSD). 0 = AUTO-UP (normal play),
  // 1 = MANUAL-DOWN, which is the position the operator menu requires.
  input  wire        service_manual,
  output wire [15:0] in0,
  output wire [15:0] in1,
  output wire [15:0] in2
);
  // MiSTer: [0]=Right [1]=Left [2]=Down [3]=Up, [4..7]=buttons,
  // [8]=Start, [9]=Coin, [10]=Advance, [11]=High Score Reset.
  // Williams cabinet controls read active-low.
  function automatic [7:0] player_bits(input logic [31:0] joystick);
    player_bits = {joystick[6], joystick[5], joystick[4], joystick[7],
                   joystick[0], joystick[1], joystick[2], joystick[3]};
  endfunction

  // The coin-door buttons are single physical controls, so accept them from any
  // connected pad rather than tying diagnostics to player 1's controller.
  wire advance_btn = joystick_0[10] | joystick_1[10] | joystick_2[10];
  wire hiscore_btn = joystick_0[11] | joystick_1[11] | joystick_2[11];

  assign in0 = ~{player_bits(joystick_1), player_bits(joystick_0)};
  assign in1 = {
    4'b1111, 1'b1, sound_sync[0], ~joystick_1[8], ~joystick_0[8],
    1'b1, ~hiscore_btn, ~service_manual, ~advance_btn,
    1'b1, ~joystick_2[9], ~joystick_1[9], ~joystick_0[9]
  };
  assign in2 = {8'hff, sound_talkback};
endmodule
`default_nettype wire
