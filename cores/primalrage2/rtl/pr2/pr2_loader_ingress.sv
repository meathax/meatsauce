module pr2_loader_ingress #(
	parameter logic [26:0] BIOS_START = 27'h0800000,
	parameter logic [26:0] FIXEDROM_START = 27'h0880000
) (
	input  logic        clk,
	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic [15:0] ioctl_dout,
	input  logic        sdram_ch3_done,
	input  logic [20:0] cheats_addr,
	input  logic        cheats_rnw,
	input  logic [3:0]  cheats_be,
	input  logic [31:0] cheats_dout,
	input  logic        cheats_ena,
	output logic        bios_download,
	output logic        fixedrom_download,
	output logic        ioctl_wait = 1'b0,
	output wire         rom_download_active,
	output wire [26:0]  ch3_addr,
	output wire [31:0]  ch3_din,
	output wire         ch3_req,
	output wire         ch3_rnw,
	output wire [3:0]   ch3_be
);
	logic [26:0] ramdownload_wraddr;
	logic [31:0] ramdownload_wrdata;
	logic        ramdownload_wr;

	// Keep stream ownership combinational with the hps_io contract.  The
	// previous registered decode could miss a legal first write when
	// ioctl_download and ioctl_wr asserted on the same clk edge.
	assign bios_download     = ioctl_download & (ioctl_index == 16'd0);
	assign fixedrom_download = ioctl_download & (ioctl_index == 16'd2);

	always @(posedge clk) begin
		ramdownload_wr <= 0;
		if (bios_download | fixedrom_download) begin
			if (ioctl_wr) begin
				if (~ioctl_addr[1]) begin
					ramdownload_wrdata[15:0] <= ioctl_dout;
					if (bios_download)
						ramdownload_wraddr <= BIOS_START + {8'b0, ioctl_addr[18:0]};
					else
						ramdownload_wraddr <= FIXEDROM_START + {6'b0, ioctl_addr[20:0]};
				end else begin
					ramdownload_wrdata[31:16] <= ioctl_dout;
					ramdownload_wr            <= 1;
					ioctl_wait                <= 1;
				end
			end
			if (sdram_ch3_done) ioctl_wait <= 0;
		end else begin
			ioctl_wait <= 0;
		end
	end

	assign rom_download_active = bios_download | fixedrom_download;
	assign ch3_addr = rom_download_active ? ramdownload_wraddr : {6'b0, cheats_addr};
	assign ch3_din  = rom_download_active ? ramdownload_wrdata : cheats_dout;
	assign ch3_req  = rom_download_active ? ramdownload_wr     : cheats_ena;
	assign ch3_rnw  = rom_download_active ? 1'b0               : cheats_rnw;
	assign ch3_be   = rom_download_active ? 4'b1111            : cheats_be;
endmodule
