//============================================================================
// Ikki ROM banks — ioctl write on clk_sys, registered reads throughout so
// Quartus infers M10K without having to retime a register in from outside.
//
// The colour PROMs used to be one 1792-byte array read combinationally.  That
// only reached a block RAM because Quartus absorbed the renderer's address
// register into the M10K (docs/AUDIT.md D2); any change to that register's
// fanout would have dropped 14 kbit into logic.  They are now split the way
// the palette pipeline consumes them:
//
//   pal_r / pal_g / pal_b   256 bytes each, read together by one index
//   prom_lut               1024 bytes, the sprite and background colour tables
//
// so a pixel needs one LUT read followed by one parallel RGB read.
//
// Linear map matches verif/build_rom.py / MAME (incl. tvg17_1 ROM_CONTINUE).
//============================================================================
module ikki_rom
(
	input         clk_sys,

	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	input         ioctl_download,

	input  [15:0] main_addr,
	output reg [7:0] main_q,

	input  [12:0] sub_addr,
	output reg [7:0] sub_q,

	input         gfx_clk,
	input  [15:0] sprite_addr,
	output reg [7:0] sprite_q,
	input  [15:0] tile_addr,
	output reg [7:0] tile_q,

	// Colour table (MAME: color_prom + 0x300, indexed by the 10-bit pen).
	input   [9:0] lut_addr,
	output reg [7:0] lut_q,

	// Palette, indexed by the colour-table entry.
	input   [7:0] pal_addr,
	output reg [7:0] pal_r_q,
	output reg [7:0] pal_g_q,
	output reg [7:0] pal_b_q,

	input   [8:0] attr_addr,
	output reg [7:0] attr_q,

	// Per-colour sprite transparency mask, derived from the sprite colour LUT
	// while it downloads.  Bit p is set when pen p of that colour is
	// transparent, i.e. its colour-table entry is 0 (MAME transpen_mask).
	input   [5:0] spr_trans_addr,
	output reg [7:0] spr_trans_q
);

wire download = ioctl_download & ioctl_wr;

(* ramstyle = "no_rw_check, M10K" *) reg [7:0] main_rom   [0:40959] /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] sub_rom    [0:8191]  /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] sprite_rom [0:49151] /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] tile_rom   [0:49151] /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] pal_r      [0:255]   /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] pal_g      [0:255]   /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] pal_b      [0:255]   /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] prom_lut   [0:1023]  /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] attr_rom   [0:511]   /* verilator public_flat_rw */;
(* ramstyle = "no_rw_check, M10K" *) reg [7:0] spr_trans  [0:63]    /* verilator public_flat_rw */;

wire [12:0] sub_waddr = 13'(ioctl_addr - 25'h0A000);
wire [15:0] main_rd   = (main_addr < 16'hA000) ? main_addr : 16'h0;

// Sprite colour LUT: 0x200 bytes at ioctl 0x24300 (prom17_6).  MAME builds the
// sprite palette as `ctabentry = color_prom[0x300 + i] ^ 0xff`, so a pen is
// transparent exactly when the PROM byte is 0xFF.  Bytes arrive in pen order,
// so shift them into an 8-bit accumulator and commit one mask per colour.
wire        in_spr_lut = download && (ioctl_addr >= 25'h24300) && (ioctl_addr < 25'h24500);
wire  [8:0] spr_lut_i  = 9'(ioctl_addr - 25'h24300);
wire        pen_trans  = (ioctl_dout == 8'hFF);
reg   [7:0] trans_sh;

always @(posedge clk_sys) begin
	if (in_spr_lut) begin
		trans_sh <= {pen_trans, trans_sh[7:1]};
		if (spr_lut_i[2:0] == 3'd7)
			spr_trans[spr_lut_i[8:3]] <= {pen_trans, trans_sh[7:1]};
	end

	if (download) begin
		if (ioctl_addr < 25'h0A000)
			main_rom[ioctl_addr[15:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h0C000)
			sub_rom[sub_waddr] <= ioctl_dout;
		else if (ioctl_addr < 25'h18000)
			sprite_rom[16'(ioctl_addr - 25'h0C000)] <= ioctl_dout;
		else if (ioctl_addr < 25'h24000)
			tile_rom[16'(ioctl_addr - 25'h18000)] <= ioctl_dout;
		else if (ioctl_addr < 25'h24100)
			pal_r[8'(ioctl_addr - 25'h24000)] <= ioctl_dout;
		else if (ioctl_addr < 25'h24200)
			pal_g[8'(ioctl_addr - 25'h24100)] <= ioctl_dout;
		else if (ioctl_addr < 25'h24300)
			pal_b[8'(ioctl_addr - 25'h24200)] <= ioctl_dout;
		else if (ioctl_addr < 25'h24700)
			prom_lut[10'(ioctl_addr - 25'h24300)] <= ioctl_dout;
		else if (ioctl_addr < 25'h24900)
			attr_rom[9'(ioctl_addr - 25'h24700)] <= ioctl_dout;
	end

	main_q <= main_rom[main_rd];
	sub_q  <= sub_rom[sub_addr];
end

// Separate BRAMs — do not dual-read one array (breaks Quartus M10K inference).
always @(posedge gfx_clk) begin
	sprite_q    <= sprite_rom[sprite_addr];
	tile_q      <= tile_rom[tile_addr];
	attr_q      <= attr_rom[attr_addr];
	spr_trans_q <= spr_trans[spr_trans_addr];
	lut_q       <= prom_lut[lut_addr];
	pal_r_q     <= pal_r[pal_addr];
	pal_g_q     <= pal_g[pal_addr];
	pal_b_q     <= pal_b[pal_addr];
end

endmodule
