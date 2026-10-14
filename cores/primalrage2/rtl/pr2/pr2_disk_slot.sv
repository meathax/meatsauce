// Keep PR2's ATA master on MiSTer image slot 1. Slot 0 is reserved by some
// launchers for temporary cartridge selections and its .s0 file may be deleted.
module pr2_disk_slot (
    input         clk,
    input         reset,
    input  [31:0] disk_lba,
    input         disk_rd, disk_wr,
    input  [15:0] disk_buff_din,
    output        disk_ack, disk_buff_wr,
    output reg    disk_mounted = 0,
    output reg    disk_readonly = 0,
    output reg [63:0] disk_size = 0,
    output [31:0] hps_lba [2],
    output [1:0]  hps_rd, hps_wr,
    output [15:0] hps_buff_din [2],
    input  [1:0]  hps_ack, hps_mounted,
    input         hps_buff_wr, hps_readonly,
    input  [63:0] hps_size
);
    assign hps_lba = '{32'd0, disk_lba};
    assign hps_rd = {(!reset && disk_rd), 1'b0};
    assign hps_wr = {(!reset && disk_wr), 1'b0};
    assign hps_buff_din = '{16'd0, disk_buff_din};
    assign disk_ack = hps_ack[1] && !reset;

    // Retain the selected drive while hps_io drains its buffer-write pipeline
    // after the transfer acknowledgement drops.
    reg selected_disk = 0;
    assign disk_buff_wr = hps_buff_wr && selected_disk && !reset;
    always @(posedge clk) begin
        if (reset) begin
            selected_disk <= 1'b0;
            // Keep mounted-image metadata across reset. The core's internal
            // reset waits for media_ready, so clearing these registers here
            // would erase the mount event needed to release that reset.
        end else begin
            if (|hps_ack) selected_disk <= hps_ack[1];

            // Main sends shared image metadata before the per-slot mount event.
            // Latch only our slot, and deliver its event with the matching metadata.
            disk_mounted <= hps_mounted[1];
            if (hps_mounted[1]) begin
                disk_size <= hps_size;
                disk_readonly <= hps_readonly;
            end
        end
    end
endmodule
