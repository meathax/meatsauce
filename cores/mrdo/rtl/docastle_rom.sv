//============================================================================
// Universal Do! Castle family ROM store and MiSTer ioctl loader.
//
// Fixed index-0 image layout:
//   00000-0ffff  main Z80 logical address space
//   10000-13fff  sub/sound Z80
//   14000-141ff  sprite/protection Z80
//   14200-181ff  8x8 tile graphics
//   18200-381ff  16x16 sprite graphics
//   38200-481ff  Soccer ADPCM (zero-filled for other profiles)
//   48200-483ff  colour PROM
//============================================================================
module docastle_rom
(
	input         clk,
	input         ioctl_download,
	input         ioctl_wr,
	input   [7:0] ioctl_index,
	input  [24:0] ioctl_addr,
	input   [7:0] ioctl_dout,

	input  [15:0] main_addr,
	output reg [7:0] main_q,
	input  [13:0] sub_addr,
	output reg [7:0] sub_q,
	input   [8:0] sprite_cpu_addr,
	output reg [7:0] sprite_cpu_q,
	input  [13:0] char_addr,
	output reg [7:0] char_q,
	input  [16:0] sprite_gfx_addr,
	output reg [7:0] sprite_gfx_q,
	input  [15:0] adpcm_addr,
	output reg [7:0] adpcm_q,
	input   [8:0] prom_addr,
	output reg [7:0] prom_q
);

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] main_rom       [0:65535];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] sub_rom        [0:16383];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] sprite_cpu_rom [0:511];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] char_rom       [0:16383];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] sprite_gfx_rom [0:131071];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] adpcm_rom      [0:65535];
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] color_prom     [0:511];

wire rom_wr = ioctl_download && ioctl_wr && (ioctl_index == 8'd0);
wire [24:0] sub_wr_off        = ioctl_addr - 25'h10000;
wire [24:0] sprite_cpu_wr_off = ioctl_addr - 25'h14000;
wire [24:0] char_wr_off       = ioctl_addr - 25'h14200;
wire [24:0] sprite_gfx_wr_off = ioctl_addr - 25'h18200;
wire [24:0] adpcm_wr_off      = ioctl_addr - 25'h38200;
wire [24:0] prom_wr_off       = ioctl_addr - 25'h48200;

always @(posedge clk) begin
	if (rom_wr) begin
		if (ioctl_addr < 25'h10000)
			main_rom[ioctl_addr[15:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h14000)
			sub_rom[sub_wr_off[13:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h14200)
			sprite_cpu_rom[sprite_cpu_wr_off[8:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h18200)
			char_rom[char_wr_off[13:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h38200)
			sprite_gfx_rom[sprite_gfx_wr_off[16:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h48200)
			adpcm_rom[adpcm_wr_off[15:0]] <= ioctl_dout;
		else if (ioctl_addr < 25'h48400)
			color_prom[prom_wr_off[8:0]] <= ioctl_dout;
	end

	main_q       <= main_rom[main_addr];
	sub_q        <= sub_rom[sub_addr];
	sprite_cpu_q <= sprite_cpu_rom[sprite_cpu_addr];
	char_q       <= char_rom[char_addr];
	sprite_gfx_q <= sprite_gfx_rom[sprite_gfx_addr];
	adpcm_q      <= adpcm_rom[adpcm_addr];
	prom_q       <= color_prom[prom_addr];
end

endmodule
