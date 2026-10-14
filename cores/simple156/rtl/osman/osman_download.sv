// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-wide MiSTer HPS stream to the original-ROM loader's little-endian words.
module osman_download (
    input wire clk, reset,
    input wire ioctl_download, ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [26:0] ioctl_addr,
    input wire [7:0] ioctl_dout,
    output wire ioctl_wait,
    output reg start, finish, valid,
    output reg [23:0] addr,
    output reg [15:0] data,
    input wire ready,
    input wire loader_abort,   // loader rejected the stream: drain the HPS instead of stalling it
    output reg error
);
    wire rom_download = ioctl_download && ioctl_index == 0;
    reg previous_download, finish_pending, low_pending, restart_pending;
    wire new_download = rom_download && !previous_download;
    reg [7:0] low_byte;
    reg [26:0] expected_addr;
    // A failed transfer must never hold ioctl_wait: the HPS cannot send its
    // end-of-file command while ack is withheld, so a stuck wait would freeze
    // Main_MiSTer. Bytes are discarded (not accepted) until the next download.
    // start reaches the loader one edge later. Preserve the new transfer's
    // first bytes while its previous sticky abort is being cleared.
    wire stop = error || (loader_abort && !restart_pending);
    assign ioctl_wait = rom_download && !stop && (valid || finish_pending);
    always @(posedge clk) begin
        start <= 1'b0;
        finish <= 1'b0;
        previous_download <= rom_download;
        if (reset) begin
            previous_download <= 1'b0;
            restart_pending <= 1'b0;
            finish_pending <= 1'b0;
            low_pending <= 1'b0;
            low_byte <= 0;
            expected_addr <= 0;
            start <= 1'b0;
            finish <= 1'b0;
            valid <= 1'b0;
            addr <= 0;
            data <= 0;
            error <= 1'b0;
        end else begin
            if(restart_pending && !start) restart_pending <= 1'b0;
            if (valid && ready) valid <= 1'b0;
            if (stop) valid <= 1'b0;
            if (new_download) begin
                start <= 1'b1;
                restart_pending <= 1'b1;
                expected_addr <= 0;
                low_pending <= 1'b0;
                // Overlap with an unfinished earlier transfer is an error, but a
                // transfer that already failed leaves stale state that the new
                // stream (and the loader's start reset) must not inherit.
                error <= !stop && (valid || finish_pending);
                valid <= 1'b0;
                finish_pending <= 1'b0;
            end
            if (rom_download && ioctl_wr && (!stop || new_download)) begin
                if ((!new_download && (valid || finish_pending)) || ioctl_addr[26:24] != 0 ||
                    ioctl_addr != (previous_download ? expected_addr : 27'd0)) begin
                    error <= 1'b1;
                end else begin
                    expected_addr <= ioctl_addr + 1'b1;
                    if (!ioctl_addr[0]) begin
                        low_byte <= ioctl_dout;
                        low_pending <= 1'b1;
                    end else if (low_pending) begin
                        data <= {ioctl_dout,low_byte};
                        addr <= ioctl_addr[23:0] - 1'b1;
                        valid <= 1'b1;
                        low_pending <= 1'b0;
                    end else error <= 1'b1;
                end
            end
            if (previous_download && !rom_download) begin
                if (low_pending) error <= 1'b1;
                else if (!stop) finish_pending <= 1'b1;
            end
            if (finish_pending && !valid && !stop) begin
                finish <= 1'b1;
                finish_pending <= 1'b0;
            end
        end
    end
endmodule
