// Action Hollywood tilemap line-fill engine (BG2, BG, FG).
// For one raster line (`line`, 0..239) it walks the tile columns that cover raster x 82..433 of each layer,
// fetches the tile code/attr from the tile RAMs, fetches 1 (8x8) or 2 (16x16) GFX words and stores a
// "slot" (colour + 16 pens in display order) per tile column into the layer's slot RAM (bank `fbank`).
// The scroll offset is applied on the read side (ah_video), so each tile row is written with one wide word.
// Source: MAME kickgoal.cpp get_*_tile_info / tilemap_scan_8x8/16x16, actionhw VIDEO_START.
module ah_vid_tiles (
	input  wire         clk,
	input  wire         rst,
	input  wire         start,          // 1-clk pulse, restarts the engine
	input  wire [7:0]   line,           // line to render (0..239)
	input  wire         fbank,          // slot RAM bank to write
	input  wire [95:0]  scr,            // scroll regs: [15:0]=FGx [31:16]=FGy [47:32]=BGx [63:48]=BGy [79:64]=BG2x [95:80]=BG2y
	// tile RAM render ports (shared address, 1-clk sync read)
	output reg  [12:0]  ram_addr,
	input  wire [15:0]  ram_q_bg2,
	input  wire [15:0]  ram_q_bg,
	input  wire [15:0]  ram_q_fg,
	// gfx request (level, held until ack); gfx_b = byte offset within a plane quarter (20 bit)
	output reg          gfx_req,
	output reg  [19:0]  gfx_b,
	input  wire         gfx_ack,
	input  wire [31:0]  gfx_data,
	// slot writes
	output reg  [2:0]   slot_we,        // [0]=BG2 [1]=BG [2]=FG
	output reg  [6:0]   slot_wa,
	output reg  [67:0]  slot_wd,
	output reg          done
);
	function [31:0] dec8(input [31:0] w);
		integer x;
		begin
			for (x = 0; x < 8; x = x + 1)
				dec8[4*x +: 4] = {w[24 + 7 - x], w[16 + 7 - x], w[8 + 7 - x], w[7 - x]};
		end
	endfunction
	function [63:0] revnib(input [63:0] v);
		integer i;
		begin
			for (i = 0; i < 16; i = i + 1) revnib[4*i +: 4] = v[4*(15-i) +: 4];
		end
	endfunction

	localparam G_IDLE = 0, G_R0 = 2, G_R1 = 3, G_WR = 4;
	reg [2:0]  gs;
	reg        dv;
	wire       gtake;

	// ---------------------------------------------------------------- info (tile RAM) stage
	reg [7:0]  line_r;
	reg [1:0]  ly;              // 0 BG2, 1 BG, 2 FG
	reg [5:0]  j;
	reg [2:0]  is;
	localparam I_IDLE = 0, I_A = 1, I_B = 2, I_C = 3, I_D = 4;
	reg        info_done;

	wire        is16 = (ly != 2'd2);
	wire [15:0] sx = (ly == 2'd0) ? scr[79:64] : (ly == 2'd1) ? scr[47:32] : scr[15:0];
	wire [15:0] sy = (ly == 2'd0) ? scr[95:80] : (ly == 2'd1) ? scr[63:48] : scr[31:16];
	wire [9:0]  wmask = is16 ? 10'h3ff : 10'h1ff;
	wire [9:0]  txs = (10'd82 + sx[9:0]) & wmask;
	wire [5:0]  c0  = is16 ? txs[9:4] : txs[8:3];
	wire [5:0]  col = c0 + j;
	wire [9:0]  tys = ({2'b00, line_r} + sy[9:0]) & wmask;
	wire [5:0]  row = is16 ? tys[9:4] : tys[8:3];
	wire [3:0]  py  = is16 ? tys[3:0] : {1'b0, tys[2:0]};
	wire [11:0] idx = is16 ? {row[5:4], col, row[3:0]} : {row[5], col, row[4:0]};
	wire [5:0]  nt_m1 = is16 ? 6'd22 : 6'd44;
	wire [15:0] ram_q = (ly == 2'd0) ? ram_q_bg2 : (ly == 2'd1) ? ram_q_bg : ram_q_fg;

	reg [15:0] code_r;
	// descriptor
	reg [1:0]  d_ly;
	reg [5:0]  d_col;
	reg [15:0] d_code;
	reg [3:0]  d_color;
	reg        d_fx;
	reg [3:0]  d_py;

	wire [15:0] code_masked = (ly == 2'd2) ? {4'b0, code_r[11:0]} : {3'b0, code_r[12:0]};
	wire [15:0] code_full   = code_masked + ((ly == 2'd0) ? 16'h2000 : (ly == 2'd1) ? 16'h0000 : 16'hE000);

	always @(posedge clk) begin
		if (rst || start) begin
			is <= start ? I_A : I_IDLE;
			ly <= 0; j <= 0; info_done <= rst ? 1'b1 : 1'b0;
			dv <= 0;
			if (start) line_r <= line;
		end else begin
			if (gtake) dv <= 1'b0;
			case (is)
			I_A: begin ram_addr <= {idx, 1'b0}; is <= I_B; end
			I_B: begin ram_addr <= {idx, 1'b1}; is <= I_C; end
			I_C: begin code_r <= ram_q; is <= I_D; end
			I_D: if (!dv) begin
				// attr word on ram_q
				dv <= 1;
				d_ly <= ly; d_col <= col; d_code <= code_full; d_color <= ram_q[3:0];
				d_fx <= is16 & ram_q[5];
				d_py <= is16 ? (ram_q[6] ? ~py : py) : py;
				if (j == nt_m1) begin
					j <= 0;
					if (ly == 2'd2) begin is <= I_IDLE; info_done <= 1; end
					else begin ly <= ly + 1'b1; is <= I_A; end
				end else begin j <= j + 1'b1; is <= I_A; end
			end
			default: ;
			endcase
		end
	end

	// ---------------------------------------------------------------- gfx stage
	// A descriptor is taken in G_IDLE or during the slot write (G_WR) of the previous tile, so the next
	// fetch is issued back-to-back with the previous ack.
	reg [1:0]  w_ly;
	reg [5:0]  w_col;
	reg [3:0]  w_color;
	reg        w_fx;
	reg [19:0] w_b;
	reg        cvalid;
	reg [20:0] ckey;
	reg [31:0] cw0, cw1;
	wire       w16 = (w_ly != 2'd2);
	wire       d16 = (d_ly != 2'd2);
	wire [19:0] b_d   = d16 ? {d_code[14:0], d_py, 1'b0} : {1'b0, d_code[15:0], d_py[2:0]};
	wire [20:0] key_d = {d16, b_d};
	wire        hit_d = cvalid && (ckey == key_d);

	wire [31:0] pL = dec8(cw0);
	wire [31:0] pR = dec8(cw1);
	wire [63:0] raw = w16 ? {pR, pL} : {32'b0, pL};
	wire [63:0] pens = (w16 && w_fx) ? revnib(raw) : raw;

	assign gtake = dv && (gs == G_IDLE || gs == G_WR);

	always @(posedge clk) begin
		slot_we <= 3'b000;
		if (rst || start) begin
			gs <= G_IDLE; gfx_req <= 0; done <= 0;
			if (rst) cvalid <= 0;
			else if (gs == G_R0 || gs == G_R1) cvalid <= 0;
		end else begin
			if (gs == G_WR) begin
				slot_we[w_ly] <= 1'b1;
				slot_wa <= {fbank, w_col};
				slot_wd <= {w_color, pens};
				gs <= G_IDLE;
			end
			if (gs == G_IDLE && !dv && info_done && is == I_IDLE) done <= 1;
			if (gtake) begin
				w_ly <= d_ly; w_col <= d_col; w_color <= d_color; w_fx <= d_fx; w_b <= b_d;
				if (hit_d) gs <= G_WR;
				else begin gfx_req <= 1; gfx_b <= b_d; cvalid <= 0; gs <= G_R0; end
			end
			case (gs)
			G_R0: if (gfx_ack) begin
				cw0 <= gfx_data;
				if (w16) begin gfx_b <= {w_b[19:1], 1'b1}; gs <= G_R1; end
				else begin gfx_req <= 0; cvalid <= 1; ckey <= {1'b0, w_b}; gs <= G_WR; end
			end
			G_R1: if (gfx_ack) begin
				cw1 <= gfx_data; gfx_req <= 0; cvalid <= 1; ckey <= {1'b1, w_b}; gs <= G_WR;
			end
			default: ;
			endcase
		end
	end
endmodule
