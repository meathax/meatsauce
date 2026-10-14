// SPDX-License-Identifier: GPL-3.0-or-later
// DDR3 ROM transfer for MRA <rom index="0" address="...">.
//
// Without an address Main_MiSTer sends the ROM one byte per GPIO handshake
// (about 1 us each, so the 13 MB image took 14-25 s of black screen). With an
// address Main copies the assembled image straight into DDR3, announces its
// length in ioctl_addr when the download starts, and sends no bytes. This
// module then replays the image from DDR3 into the unchanged byte loader path,
// holding the HPS in ioctl_wait until the image is accepted or rejected.
// A byte-stream download (ioctl_addr 0 at start) passes through untouched.
module osman_ddr_rom #(
    parameter [28:0] BASE = 29'h6000000,      // 0x30000000 in 64-bit words
    parameter integer WATCHDOG_BITS = 25      // ~0.7 s without progress
) (
    input wire clk, reset,
    // hps_io side
    input wire hps_download, hps_wr,
    input wire [15:0] hps_index,
    input wire [26:0] hps_addr,
    input wire [7:0] hps_dout,
    output wire hps_wait,
    // machine side
    output wire download, wr,
    output wire [15:0] index,
    output wire [26:0] addr,
    output wire [7:0] dout,
    input wire core_wait, image_ready, load_error,
    // DDR3 read port (burst length 1)
    input wire ddr_busy,
    output reg ddr_rd,
    output reg [28:0] ddr_addr,
    input wire [63:0] ddr_dout,
    input wire ddr_dout_ready
);
    localparam [1:0] IDLE=0, HOLD=1, COPY=2, DRAIN=3;
    reg [1:0] phase;
    reg previous_rom;
    reg [26:0] length, position, copy_addr;
    reg [23:0] next_qword;
    reg [63:0] current, prefetch;
    reg current_valid, prefetch_valid, read_pending, gap, copy_wr;
    reg [7:0] copy_byte;
    reg [WATCHDOG_BITS-1:0] idle_count;
    wire rom_download = hps_download && hps_index == 16'd0;
    wire active = phase != IDLE;
    wire [23:0] qwords = length[26:3] + {23'd0,|length[2:0]};

    assign download = active ? phase != DRAIN : hps_download;
    assign index = active ? 16'd0 : hps_index;
    assign addr = active ? copy_addr : hps_addr;
    assign wr = active ? copy_wr : hps_wr;
    assign dout = active ? copy_byte : hps_dout;
    // Hold every later HPS command until the replayed image has been judged.
    assign hps_wait = active ? phase != HOLD : core_wait;

    always @(posedge clk) begin : replay
        reg have_current;
        previous_rom <= rom_download;
        copy_wr <= 1'b0;
        if (reset) begin
            phase <= IDLE; previous_rom <= 1'b0; length <= 0; position <= 0; next_qword <= 0;
            current_valid <= 1'b0; prefetch_valid <= 1'b0; read_pending <= 1'b0; gap <= 1'b0;
            ddr_rd <= 1'b0; ddr_addr <= BASE; copy_byte <= 0; copy_addr <= 0; idle_count <= 0;
        end else begin
            case (phase)
                IDLE: if (rom_download && !previous_rom && hps_addr != 0) begin
                    phase <= HOLD; length <= hps_addr; position <= 0; copy_addr <= 0; next_qword <= 0;
                    current_valid <= 1'b0; prefetch_valid <= 1'b0; read_pending <= 1'b0; gap <= 1'b0;
                end
                // Main is copying the image into DDR3; its download ends when done.
                HOLD: if (!rom_download) begin phase <= COPY; idle_count <= 0; end
                COPY: begin
                    have_current = current_valid;
                    idle_count <= idle_count + 1'b1;
                    // One byte, then one idle edge so the loader's wait is visible
                    // before the next byte is offered.
                    if (gap) gap <= 1'b0;
                    else if (have_current && !core_wait) begin
                        copy_wr <= 1'b1; copy_addr <= position; copy_byte <= current[{position[2:0],3'b000} +: 8];
                        position <= position + 1'b1; gap <= 1'b1; idle_count <= 0;
                        if (position[2:0] == 3'd7 || position + 1'b1 == length) have_current = 1'b0;
                    end
                    if (!have_current && prefetch_valid) begin
                        current <= prefetch; have_current = 1'b1; prefetch_valid <= 1'b0;
                    end
                    current_valid <= have_current;
                    if (ddr_rd && !ddr_busy) begin ddr_rd <= 1'b0; read_pending <= 1'b1; end
                    else if (!ddr_rd && !read_pending && !prefetch_valid && next_qword < qwords) begin
                        ddr_rd <= 1'b1; ddr_addr <= BASE + {5'd0,next_qword}; next_qword <= next_qword + 1'b1;
                    end
                    if (read_pending && ddr_dout_ready) begin
                        prefetch <= ddr_dout; prefetch_valid <= 1'b1; read_pending <= 1'b0; idle_count <= 0;
                    end
                    // A rejected image or a stalled DDR3 read must never leave
                    // Main_MiSTer blocked: end the stream and let the loader judge it.
                    if (load_error || (position == length && !gap) || &idle_count) begin
                        phase <= DRAIN; idle_count <= 0;
                    end
                end
                DRAIN: begin
                    // Keep any accepted read from dangling on the Avalon port.
                    if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;
                    if (read_pending && ddr_dout_ready) read_pending <= 1'b0;
                    idle_count <= idle_count + 1'b1;
                    if (&idle_count) begin
                        phase <= IDLE; ddr_rd <= 1'b0; read_pending <= 1'b0;
                    end else if (!ddr_rd && !read_pending && (image_ready || load_error))
                        phase <= IDLE;
                end
            endcase
        end
    end
endmodule
