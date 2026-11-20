// SPDX-License-Identifier: GPL-3.0-or-later
// Main_MiSTer has one arcade NVRAM file per MRA. Preserve the EEPROM at
// bytes 0..127 and append the standard 400-byte hiscore dump at 128..527.
module gs_nv_image(
    input wire download,upload,input wire [15:0] index,
    input wire [26:0] address,input wire [15:0] eeprom_data,score_data,
    output wire loader_download,score_download,score_upload,
    output wire [15:0] loader_index,score_index,save_data,
    output wire [26:0] score_address,nv_save_address
);
    wire combined=index==254;
    wire score_region=address>=128 && address<528;
    assign loader_download=download && (!combined || address<128);
    assign loader_index=combined && address>=128 ? 16'hffff : index;
    assign score_download=download && (!combined || score_region);
    assign score_index=combined ? (address>=128 ? 16'd4 : 16'hffff) : index;
    assign score_address=combined && address>=128 ? address-27'd128 : address;
    assign score_upload=upload && combined && address>=128;
    assign nv_save_address=combined && address>=128 ? 27'd128 : address;
    assign save_data=address<128 ? eeprom_data : score_data;
endmodule
