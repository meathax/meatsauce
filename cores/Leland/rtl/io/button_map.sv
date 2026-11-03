// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 shimian5

// Permutes the controller's button bits 8:4 from each game's MRA order to the layout the board
// expects. Each game lists player controls, then coin, then start, leaving out unused buttons.
//   board layout: [4]=button 1 (Nitro/Jump/Place)  [5]=button 2 or Off-Road coin
//                 [6]=start or Gas                 [7]=coin or Off-Road Menu Enter
//   Off-Road / Indy Heat: Gas, Nitro, Menu Enter, Coin
//   Pig Out:              Jump, Throw, Coin, Start
//   Brute Force:          Punch/Kick, Dive, Menu Enter, Coin, Start
//   Ataxx:                Place, Coin, Start
//   Asylum:               Attack, Jump, Start, Coin, Service/Test (fifth button routed separately)
// Menu Enter also comes out separately: in the service menus it acts as player 3's Nitro
// (Off-Road, Indy Heat) or player 3's Start (Brute Force, whose right-hand Join button
// activates a menu item).

module button_map
(
	input  [7:0] game_id,
	input  [8:0] joy,       // controller bits as mapped in the OSD
	output [7:0] board,     // joy with bits 7:4 reordered for the board
	output       menu,      // Menu Enter pressed (0 for games without one)
	output [7:0] menu_p3,   // board bits Menu Enter drives on player 3: Nitro, or Start for Brute Force
	output       service    // Asylum's dedicated Service/Test assignment
);

localparam [7:0] GAME_PIGOUT   = 8'd2;
localparam [7:0] GAME_ATAXX    = 8'd3;
localparam [7:0] GAME_INDYHEAT = 8'd4;
localparam [7:0] GAME_BRUTFORC = 8'd5;
localparam [7:0] GAME_ASYLUM   = 8'd6;

reg [8:0] m;
always @(*) begin
	case (game_id)
		GAME_PIGOUT:   m = {1'b0,   joy[6], joy[7], joy[5], joy[4], joy[3:0]};
		GAME_BRUTFORC: m = {joy[6], joy[7], joy[8], joy[5], joy[4], joy[3:0]};
		// The Asylum MRA action order is Button 1, Button 2, Start, Coin.
		// Preserve those host positions as board bits 4..7; the board maps each
		// player's coin to MAME's separate IN0 coin input.
		GAME_ASYLUM:   m = {1'b0,   joy[7], joy[6], joy[5], joy[4], joy[3:0]};
		GAME_ATAXX:    m = {1'b0,   joy[5], joy[6], 1'b0,   joy[4], joy[3:0]};
		GAME_INDYHEAT: m = {joy[6], joy[7], joy[4], 1'b0,   joy[5], joy[3:0]};
		default:       m = {joy[6], joy[6], joy[4], joy[7], joy[5], joy[3:0]};
	endcase
end

assign board = m[7:0];
assign menu  = m[8];
assign menu_p3 = !m[8] ? 8'h00 : (game_id == GAME_BRUTFORC) ? 8'h40 : 8'h10;
assign service = (game_id == GAME_ASYLUM) && joy[8];

endmodule
