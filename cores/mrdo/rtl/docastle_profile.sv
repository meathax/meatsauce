//============================================================================
// Runtime game/profile decoder for the Universal Do! Castle hardware family.
//
// The one-byte game ID is part of the MRA/RTL ABI. Keep assigned values stable.
// Unknown values are deliberately invalid so the machine remains in reset.
//============================================================================
module docastle_profile
(
	input      [7:0] game_id,
	output reg       valid,
	output reg [1:0] profile,
	output reg       low_pen_priority,
	output reg       soccer_sprites,
	output reg       has_adpcm,
	output reg       has_joys2,
	output reg       native_vertical
);

localparam [1:0] PROFILE_CASTLE = 2'd0;
localparam [1:0] PROFILE_RUNRUN = 2'd1;
localparam [1:0] PROFILE_SOCCER = 2'd2;

always @(*) begin
	valid = 1'b1;
	profile = PROFILE_CASTLE;
	low_pen_priority = 1'b0;
	soccer_sprites = 1'b0;
	has_adpcm = 1'b0;
	has_joys2 = 1'b0;
	native_vertical = 1'b0;

	case (game_id)
		8'h00: begin // Mr. Do's Castle
			native_vertical = 1'b1;
		end
		8'h01: begin // Mr. Do! vs. Unicorns
			native_vertical = 1'b1;
		end
		8'h02: begin // Do! Run Run
			profile = PROFILE_RUNRUN;
			low_pen_priority = 1'b1;
		end
		8'h03: begin // Mr. Do's Wild Ride
			profile = PROFILE_RUNRUN;
			low_pen_priority = 1'b1;
		end
		8'h04: begin // Jumping Jack
			profile = PROFILE_RUNRUN;
			low_pen_priority = 1'b1;
			native_vertical = 1'b1;
		end
		8'h05: begin // Kick Rider
			profile = PROFILE_RUNRUN;
			low_pen_priority = 1'b1;
		end
		8'h06: begin // Super Pierrot
			profile = PROFILE_RUNRUN;
			low_pen_priority = 1'b1;
		end
		8'h07: begin // Indoor Soccer
			profile = PROFILE_SOCCER;
			low_pen_priority = 1'b1;
			soccer_sprites = 1'b1;
			has_adpcm = 1'b1;
			has_joys2 = 1'b1;
		end
		8'h08: begin // American Soccer
			profile = PROFILE_SOCCER;
			low_pen_priority = 1'b1;
			soccer_sprites = 1'b1;
			has_adpcm = 1'b1;
			has_joys2 = 1'b1;
		end
		8'h09: begin // Do! Run Run set 2 (board-sequence oracle)
			profile = PROFILE_RUNRUN;
			low_pen_priority = 1'b1;
		end
		default: begin
			valid = 1'b0;
			profile = PROFILE_CASTLE;
		end
	endcase
end

endmodule
