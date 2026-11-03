// Action Hollywood sprite line engine.
// SCAN: walks sprite RAM (4 words/sprite: y|end, attr, code, x) for one line, in list order, stops at the
//       first entry with word0 bit 8; in-range sprites (16 lines tall) are pushed to a FIFO.
// FETCH: pops the FIFO, reads the 2 GFX words of the sprite row (16x16, flipx only), hands them to WRITE.
// WRITE: writes up to 16 pixels (pen != 15) into the line buffer (bank `fbank`), later sprites overwrite earlier.
// Source: MAME kickgoal.cpp draw_sprites: ypos = 0x110 - y, drawn at (x-12, ypos-32), tile = code + 0x4000, pen 15 transparent.
module ah_vid_spr (
	input  wire         clk,
	input  wire         rst,
	input  wire         start,
	input  wire [7:0]   line,
	input  wire         gate,           // GFX requests allowed (tile engine finished)
	output reg  [9:0]   spr_addr,       // sprite RAM word address (sync read, 1 clk)
	input  wire [15:0]  spr_q,
	output reg          gfx_req,
	output reg  [19:0]  gfx_b,
	input  wire         gfx_ack,
	input  wire [31:0]  gfx_data,
	output reg          buf_we,
	output reg  [8:0]   buf_wa,         // line buffer index = raster x - 82
	output reg  [9:0]   buf_wd,         // {2'b11, colour(4), pen(4)}
	output reg          done
);
	function [31:0] dec8(input [31:0] w);
		integer x;
		begin
			for (x = 0; x < 8; x = x + 1)
				dec8[4*x +: 4] = {w[24 + 7 - x], w[16 + 7 - x], w[8 + 7 - x], w[7 - x]};
		end
	endfunction

	// ------------------------------------------------------------ FIFO (32 x 39)
	reg [38:0] fifo [0:31];
	reg [5:0]  wp, rp;
	wire       f_empty = (wp == rp);
	wire       f_full  = (wp[4:0] == rp[4:0]) && (wp[5] != rp[5]);

	// ------------------------------------------------------------ SCAN
	localparam S_IDLE = 0, S_A = 1, S_A2 = 2, S_B = 3, S_B2 = 4, S_C = 5, S_C2 = 6, S_D = 7, S_D2 = 8, S_E = 9;
	reg [3:0]  ss;
	reg [7:0]  line_r;
	reg [7:0]  si;
	reg        scan_done;
	reg [3:0]  s_ry;
	reg [15:0] s_attr, s_code;
	wire [9:0] ty = {2'b00, line_r} + {2'b00, spr_q[7:0]} - 10'd240;
	wire       inr = (ty[9:4] == 6'd0);

	always @(posedge clk) begin
		if (rst || start) begin
			ss <= start ? S_A : S_IDLE;
			si <= 0; wp <= 0; scan_done <= rst ? 1'b1 : 1'b0;
			if (start) line_r <= line;
		end else begin
			case (ss)
			S_A: begin spr_addr <= {si, 2'b00}; ss <= S_A2; end
			S_A2: ss <= S_B;
			S_B: begin
				if (spr_q[8]) begin scan_done <= 1; ss <= S_IDLE; end
				else if (inr) begin s_ry <= ty[3:0]; spr_addr <= {si, 2'b01}; ss <= S_B2; end
				else if (si == 8'd255) begin scan_done <= 1; ss <= S_IDLE; end
				else begin si <= si + 1'b1; ss <= S_A; end
			end
			S_B2: ss <= S_C;
			S_C: begin s_attr <= spr_q; spr_addr <= {si, 2'b10}; ss <= S_C2; end
			S_C2: ss <= S_D;
			S_D: begin s_code <= spr_q; spr_addr <= {si, 2'b11}; ss <= S_D2; end
			S_D2: ss <= S_E;
			S_E: if (!f_full) begin
				// spr_q = x word. entry: {ry[3:0], flipx, colour[3:0], code[13:0], x[15:0]}
				fifo[wp[4:0]] <= {s_ry, s_attr[5], s_attr[3:0], s_code[13:0], spr_q};
				wp <= wp + 1'b1;
				if (si == 8'd255) begin scan_done <= 1; ss <= S_IDLE; end
				else begin si <= si + 1'b1; ss <= S_A; end
			end
			default: ;
			endcase
		end
	end

	// ------------------------------------------------------------ WRITE
	reg        wact;
	reg [3:0]  wcnt;
	reg [63:0] w_pens;
	reg [15:0] w_x;
	reg        w_fx;
	reg [3:0]  w_col;
	wire [3:0] wsrc = w_fx ? ~wcnt : wcnt;
	wire [3:0] wpen = w_pens[{wsrc, 2'b00} +: 4];
	wire [17:0] wX  = {2'b00, w_x} + {14'b0, wcnt} - 18'd12;
	wire       wvis = (wX >= 18'd82) && (wX <= 18'd433);
	wire [17:0] wk  = wX - 18'd82;

	// ------------------------------------------------------------ FETCH
	localparam F_IDLE = 0, F_REQ0 = 1, F_R0 = 2, F_R1 = 3, F_HAND = 4;
	reg [2:0]  fs;
	reg [38:0] fe;
	reg [31:0] fw0, fw1;
	wire [14:0] fcode = {1'b1, fe[29:16]};   // code + 0x4000
	wire [19:0] fb = {fcode, fe[38:35], 1'b0};

	always @(posedge clk) begin
		buf_we <= 1'b0;
		if (rst || start) begin
			fs <= F_IDLE; rp <= 0; gfx_req <= 0; wact <= 0; wcnt <= 0; done <= 0;
		end else begin
			// writer
			if (wact) begin
				buf_we <= wpen != 4'hF && wvis;
				buf_wa <= wk[8:0];
				buf_wd <= {2'b11, w_col, wpen};
				wcnt <= wcnt + 1'b1;
				if (wcnt == 4'd15) wact <= 0;
			end
			// fetch
			case (fs)
			F_IDLE: begin
				if (!f_empty) begin fe <= fifo[rp[4:0]]; rp <= rp + 1'b1; fs <= F_REQ0; end
				else if (scan_done && !wact) done <= 1;
			end
			F_REQ0: if (gate) begin gfx_req <= 1; gfx_b <= fb; fs <= F_R0; end
			F_R0: if (gfx_ack) begin fw0 <= gfx_data; gfx_b <= {fb[19:1], 1'b1}; fs <= F_R1; end
			F_R1: if (gfx_ack) begin fw1 <= gfx_data; gfx_req <= 0; fs <= F_HAND; end
			F_HAND: if (!wact) begin
				w_pens <= {dec8(fw1), dec8(fw0)};
				w_x <= fe[15:0]; w_fx <= fe[34]; w_col <= fe[33:30];
				wact <= 1; wcnt <= 0; fs <= F_IDLE;
			end
			default: fs <= F_IDLE;
			endcase
		end
	end
endmodule
