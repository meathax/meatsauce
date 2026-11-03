// exterm_boot_video -- framework-owned test raster shown while the game core is held in reset
// (ROM / NVRAM download, PLL not yet locked).  Same raster as the game (hwspec.md):
// 318 x 264 at ce = clk/4 (5 MHz), HSync = hcount 0..9, VSync = lines 0..14,
// active 256 x 240 at hcount 0x28..0x127 / line 0x10..0xFF.  Keeps HS/VS/DE/CE_PIXEL alive so
// the HDMI scaler and CRT stay locked during loading (NARC/Sega System 32 precedent):
//   blue = a download is in progress, red = idle but core still in reset.
module exterm_boot_video (
	input        clk,
	input        loading,
	output       ce,
	output reg   hs, vs, hb, vb,
	output reg [7:0] r, g, b
);
	reg [1:0] div = 2'd0;
	always @(posedge clk) div <= div + 2'd1;
	assign ce = (div == 2'd3);

	reg [8:0] hc = 9'd0, vc = 9'd0;
	always @(posedge clk) if (ce) begin
		if (hc == 9'd317) begin
			hc <= 9'd0;
			vc <= (vc == 9'd263) ? 9'd0 : vc + 9'd1;
		end else hc <= hc + 9'd1;
	end

	wire act_h = (hc >= 9'd40) && (hc < 9'd296);
	wire act_v = (vc >= 9'd16) && (vc < 9'd256);

	always @(posedge clk) if (ce) begin
		hs <= (hc < 9'd10);
		vs <= (vc < 9'd15);
		hb <= !act_h;
		vb <= !act_v;
		r <= (act_h && act_v && !loading) ? 8'hC0 : 8'h00;
		g <= 8'h00;
		b <= (act_h && act_v &&  loading) ? 8'hC0 : 8'h00;
	end
endmodule
