// SPDX-License-Identifier: GPL-3.0-or-later
// HPS download/upload glue (clk domain = 48 MHz game clock).
//  ioctl index 0 (MRA ROM stream, 16-bit wide words, low byte = even address): written word by word into SDRAM
//     through the ah_sdram write port, ioctl_wait held until each write is acknowledged.
//  ioctl index 4 (the MRA's single nvram file, 168 bytes): bytes 0..127 = EEPROM, bytes 128..167 = hiscore table
//     (rtl/hiscore/ah_hiscore.sv; one nvram index per MRA, so both live in one file).  MAME stores 93C46 words
//     big endian -> byte swap against the little-endian HPS word; EEPROM download feeds nv_* of ah_main, EEPROM upload
//     reads nv_dout (registered here); upload words at byte address >= 128 come from hs_din (score tail).
module ah_loader(
    input  wire        clk, rst,
    input  wire        ioctl_download, ioctl_upload, ioctl_wr,
    input  wire [15:0] ioctl_index,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output wire        ioctl_wait,
    output reg  [15:0] ioctl_din,
    input  wire        sdram_ready,
    output reg         wr_req,
    output reg  [21:0] wr_addr,
    output reg  [15:0] wr_data,
    input  wire        wr_ack,
    output reg   [5:0] nv_addr,
    output reg  [15:0] nv_din,
    output reg         nv_we,
    input  wire [15:0] nv_dout,
    input  wire [15:0] hs_din,           // score tail upload data (ah_hiscore)
    output wire        rom_active,       // ROM stream in progress
    output wire        busy              // any download in progress
);
    localparam [15:0] IDX_ROM = 16'd0, IDX_NVRAM = 16'd4;
    localparam [26:0] EE_BYTES = 27'd128;
    reg pend;
    assign ioctl_wait = pend | ~sdram_ready;
    assign rom_active = ioctl_download && ioctl_index[7:0] == IDX_ROM[7:0];
    assign busy = ioctl_download;
    wire nv_idx = ioctl_index[7:0] == IDX_NVRAM[7:0];
    always @(posedge clk) begin
        nv_we <= 1'b0;
        if (rst) begin
            pend <= 1'b0; wr_req <= 1'b0;
        end else begin
            if (ioctl_download && ioctl_wr && rom_active && !pend) begin
                wr_req <= 1'b1; pend <= 1'b1;
                wr_addr <= ioctl_addr[22:1]; wr_data <= ioctl_dout;
            end
            if (pend && wr_ack) begin wr_req <= 1'b0; pend <= 1'b0; end
            if (ioctl_download && ioctl_wr && nv_idx && ioctl_addr < EE_BYTES) begin
                nv_addr <= ioctl_addr[6:1]; nv_din <= {ioctl_dout[7:0], ioctl_dout[15:8]}; nv_we <= 1'b1;
            end
        end
        if (ioctl_upload) nv_addr <= ioctl_addr[6:1];
        ioctl_din <= (ioctl_addr >= EE_BYTES) ? hs_din : {nv_dout[7:0], nv_dout[15:8]};
    end
endmodule
