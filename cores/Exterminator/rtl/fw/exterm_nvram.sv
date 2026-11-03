// exterm_nvram -- MiSTer NVRAM (ioctl index 4, 4096 bytes) <-> exterm_core nv_* byte port.
//
// Exterminator keeps its bookkeeping, game adjustments AND the high-score table in the
// master's 2K x 16 battery RAM (0x02800000, MAME share ":nvram" = 4096 bytes, measured).
// So the complete 4 KB image is the persistence unit:
//   * restore : MRA <nvram index="4" size="4096"/> -> Main downloads the saved file at core load
//               (ioctl_download, index 4) -> bytes are written straight into the core's NVRAM
//               through nv_we/nv_addr/nv_din (core is held in reset during every download).
//   * save    : JimmyStones "nvram" module (rtl/fw/vendor/nvram.v, same one used by the CRT
//               reference core) scans the core NVRAM through the nv_addr / nv_dout read port when
//               the OSD opens, compares with its buffer (= the last loaded/saved image) and raises
//               ioctl_upload_req when the image changed and is non-blank ("Autosave hi-scores").
//               Main then uploads index 4 from the buffer (ioctl_din).  The independent RAM port scans without stopping either CPU.
// Port contract with exterm_core: nv_dout must be a synchronous read (1 clk after nv_addr),
// nv_clk_en is tied 1.
module exterm_nvram (
	input             clk,
	input             rst,            // core reset (includes ioctl_download)
	input             autosave,       // 1 = save changed NVRAM when OSD opens
	input             OSD_STATUS,

	input             ioctl_download,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input      [15:0] ioctl_index,
	input       [7:0] ioctl_dout,
	input             ioctl_upload,
	output      [7:0] ioctl_din,
	output            ioctl_upload_req,

	// exterm_core NVRAM byte port
	output            nv_clk_en,
	output            nv_we,
	output     [11:0] nv_addr,
	output      [7:0] nv_din,
	input       [7:0] nv_dout
);

	wire        nv_dl   = ioctl_download && (ioctl_index == 16'd4);
	wire [11:0] scan_addr;

	assign nv_clk_en = 1'b1;
	assign nv_we     = nv_dl && ioctl_wr && (ioctl_addr[26:12] == 15'd0);
	assign nv_addr   = nv_dl ? ioctl_addr[11:0] : scan_addr;
	assign nv_din    = ioctl_dout;

	// The scan owns an independent RAM port. No external CPU halt is required.
	// A live save can observe bookkeeping updates occurring during the scan.

	nvram #(
		.DUMPWIDTH(12),
		.CONFIGINDEX(3),
		.DUMPINDEX(4),
		.PAUSEPAD(4)
	) u_nvram (
		.clk(clk),
		.paused(1'b1),
		.reset(rst),
		.autosave(autosave),
		.ioctl_upload(ioctl_upload),
		.ioctl_upload_req(ioctl_upload_req),
		.ioctl_download(ioctl_download),
		.ioctl_wr(ioctl_wr),
		.ioctl_addr(ioctl_addr[24:0]),
		.ioctl_index(ioctl_index[7:0]),
		.ioctl_din(ioctl_din),
		.ioctl_dout(ioctl_dout),
		.OSD_STATUS(OSD_STATUS),
		.nvram_address(scan_addr),
		.nvram_data_out(nv_dout),
		.pause_cpu()
	);

endmodule
