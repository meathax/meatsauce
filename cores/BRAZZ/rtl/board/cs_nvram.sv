// SPDX-License-Identifier: GPL-3.0-or-later
// 64KiB battery-backed board SRAM, with Main_MiSTer index-4 persistence.
// The game MMIO port must replace 0x01400000-0x0140ffff in the final board.
module cs_nvram #(parameter WORD_BITS = 14) (
    input logic clk, reset, osd_open,
    input logic cpu_valid, cpu_write,
    input logic [WORD_BITS-1:0] cpu_address,
    input logic [31:0] cpu_data,
    input logic [3:0] cpu_strobe,
    output logic cpu_ready, cpu_response = 0,
    output logic [31:0] cpu_result = 0,
    input logic ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [7:0] ioctl_dout,
    output logic [7:0] ioctl_din = 0,
    output logic ioctl_upload_req = 0, pause_cpu,
    output logic dirty = 0
);
    localparam WORDS = 1 << WORD_BITS;
    localparam BYTES = WORDS * 4;
    logic [7:0] bank0 [0:WORDS-1], bank1 [0:WORDS-1];
    logic [7:0] bank2 [0:WORDS-1], bank3 [0:WORDS-1];
    logic osd_previous = 0, upload_previous = 0;
    logic upload_complete = 0;
    logic upload_invalid = 0;
    logic [WORD_BITS+2:0] upload_count = 0;
    logic [2:0] pause_pad = 0;
    logic saving = 0;
    wire host_selected = ioctl_index == 16'd4;
    wire host_range = ioctl_addr < 27'(BYTES);
    wire restoring = ioctl_download && host_selected;
    wire uploading = ioctl_upload && host_selected;
    wire [WORD_BITS-1:0] host_word = ioctl_addr[WORD_BITS+1:2];
    initial begin
        for (int i = 0; i < WORDS; i++) begin
            bank0[i] = 0; bank1[i] = 0; bank2[i] = 0; bank3[i] = 0;
        end
    end
    assign pause_cpu = saving || restoring || uploading;
    assign cpu_ready = !pause_cpu && !reset;
    always @(posedge clk) begin
        osd_previous <= osd_open;
        upload_previous <= uploading;
        cpu_response <= cpu_valid && cpu_ready;
        if (cpu_valid && cpu_ready) begin
            cpu_result <= {bank3[cpu_address],bank2[cpu_address],bank1[cpu_address],bank0[cpu_address]};
            if (cpu_write && |cpu_strobe) dirty <= 1;
            if (cpu_write && cpu_strobe[0]) bank0[cpu_address] <= cpu_data[7:0];
            if (cpu_write && cpu_strobe[1]) bank1[cpu_address] <= cpu_data[15:8];
            if (cpu_write && cpu_strobe[2]) bank2[cpu_address] <= cpu_data[23:16];
            if (cpu_write && cpu_strobe[3]) bank3[cpu_address] <= cpu_data[31:24];
        end
        case (ioctl_addr[1:0])
            0: ioctl_din <= bank0[host_word];
            1: ioctl_din <= bank1[host_word];
            2: ioctl_din <= bank2[host_word];
            3: ioctl_din <= bank3[host_word];
        endcase
        if (!host_selected || !host_range) ioctl_din <= 0;
        if (restoring && ioctl_wr && host_range) case (ioctl_addr[1:0])
            0: bank0[host_word] <= ioctl_dout;
            1: bank1[host_word] <= ioctl_dout;
            2: bank2[host_word] <= ioctl_dout;
            3: bank3[host_word] <= ioctl_dout;
        endcase
        // Capture requests on OSD opening; latch until HPS acknowledges index 4.
        if (osd_open && !osd_previous && (dirty || (cpu_valid && cpu_ready && cpu_write && |cpu_strobe))) begin
            saving <= 1; pause_pad <= 0;
        end
        if (saving && !ioctl_upload_req && !uploading) begin
            if (pause_pad == 4) ioctl_upload_req <= 1;
            else pause_pad <= pause_pad + 1'd1;
        end
        if (uploading) begin
            saving <= 1; ioctl_upload_req <= 0;
            if (!upload_previous) begin upload_count <= 0; upload_complete <= 0; upload_invalid <= 0; end
            // Never mark a short, reordered or cancelled save as successful.
            if (ioctl_rd && host_range && ioctl_addr == (upload_previous ? 27'(upload_count) : 27'd0)) begin
                upload_count <= (upload_previous ? upload_count : 0) + 1'd1;
                if (ioctl_addr == 27'(BYTES-1) && !upload_invalid) upload_complete <= 1;
            end
            if (ioctl_rd && (!host_range || ioctl_addr != (upload_previous ? 27'(upload_count) : 27'd0))) begin
                upload_invalid <= 1; upload_complete <= 0;
            end
        end
        if (!uploading && upload_previous) begin
            saving <= 0; ioctl_upload_req <= 0;
            if (upload_complete) dirty <= 0;
        end
        // Warm game reset preserves both SRAM and an outstanding save request.
        if (reset) cpu_response <= 0;
    end
endmodule
