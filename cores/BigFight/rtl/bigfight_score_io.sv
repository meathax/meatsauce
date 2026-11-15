// SPDX-License-Identifier: GPL-3.0-or-later
// Serialize WIDE downloads for the byte-oriented standard hiscore controller.
module bigfight_score_io(
    input wire cyclwarr_i,
    input wire clk, reset, hard_reset, paused, autosave, osd_open,
    input wire download, upload, wr,
    input wire [26:0] address,
    input wire [15:0] index, data,
    output wire [15:0] upload_data,
    output wire wait_hps, upload_request, pause_request, configured, ready,
    output wire access_ram, write_ram,
    output wire [15:0] ram_address,
    output wire [7:0] ram_data,
    input wire [7:0] ram_q
);
    // Cycle Warriors has100 fourteen-byte ranks; Big Fight keeps its existing
    // 58-byte file. Seven200-byte config entries preserve the standard format.
    wire [26:0] config_bytes = cyclwarr_i ? 27'd72 : 27'd24;
    wire [26:0] dump_bytes = cyclwarr_i ? 27'd1400 : 27'd58;
    wire selected = !address[0] &&
                    ((index == 16'd3 && address < config_bytes) ||
                     (index == 16'd4 && address < dump_bytes));
    wire new_profile = download && index == 16'd0;
    reg pending = 0, byte_wr = 0;
    reg [7:0] high_byte, byte_data, byte_index;
    reg [24:0] byte_address;
    assign wait_hps = pending;
    always @(posedge clk) begin
        byte_wr <= 0;
        // Config/dump files can arrive while the game is still bootstrapping.
        // CPU reset must stop RAM access without discarding their transport.
        if (hard_reset || new_profile) begin
            pending <= 0;
            byte_wr <= 0;
            byte_index <= 8'hff;
            byte_address <= 0;
            high_byte <= 0;
            byte_data <= 0;
        end else if (pending) begin
            byte_address <= byte_address + 25'd1;
            byte_data <= high_byte;
            byte_wr <= 1;
            pending <= 0;
        end else if (download && wr && selected) begin
            byte_address <= address[24:0];
            byte_data <= data[7:0];
            high_byte <= data[15:8];
            byte_index <= index[7:0];
            byte_wr <= 1;
            pending <= 1;
        end
    end
    wire read_intent, write_intent, write_strobe;
    wire [15:0] dump_word;
    // An upload can precede the first saved file. Its live namespace/address
    // must not inherit the last serialized configuration-download byte.
    wire dump_upload = upload && index == 16'd4 && address < dump_bytes && !address[0];
    assign upload_data = index == 16'd4 && address < dump_bytes && !address[0] ? dump_word : 16'd0;
    bigfight_hiscore #(.HS_ADDRESSWIDTH(16), .HS_SCOREWIDTH(11), .HS_DUMP_SIZE(1400),
        .CFG_ADDRESSWIDTH(3), .CFG_LENGTHWIDTH(1)) controller(
        .clk(clk), .reset(reset), .clear_config(new_profile || hard_reset), .paused(paused), .autosave(autosave),
        .ioctl_download((download && selected) || pending || byte_wr),
        .ioctl_upload(dump_upload),
        .ioctl_wr(byte_wr), .ioctl_addr(dump_upload ? address[24:0] : byte_address),
        .ioctl_index(dump_upload ? 8'd4 : byte_index),
        .data_from_hps(byte_data), .data_to_hps(), .ioctl_upload_req(upload_request),
        .wide_addr(address[24:0]), .wide_dout(dump_word), .OSD_STATUS(osd_open),
        .data_from_ram(ram_q), .ram_address(ram_address), .data_to_ram(ram_data),
        .ram_write(write_strobe), .ram_intent_read(read_intent),
        .ram_intent_write(write_intent), .pause_cpu(pause_request),
        .configured(configured), .ready(ready)
    );
    wire profile_address_ok = cyclwarr_i ?
        (ram_address >= 16'h6b04 && ram_address <= 16'h707b) :
        (ram_address >= 16'h22a8 && ram_address <= 16'h22e1);
    assign access_ram = paused && !reset && !new_profile && profile_address_ok && (read_intent || write_intent);
    assign write_ram = access_ram && write_intent && write_strobe;
endmodule
