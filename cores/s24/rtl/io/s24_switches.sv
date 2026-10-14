// Capture MiSTer MRA switch payloads. hps_io WIDE=1 presents the normal
// two-byte payload as one 16-bit word at byte address zero.
module s24_switches (
    input  logic        clk,
    input  logic        reset,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic [7:0]  coinage,
    output logic [7:0]  dsw
);
    always_ff @(posedge clk) begin
        if (reset) begin
            coinage <= 8'hff;
            dsw <= 8'hff;
        end else if (ioctl_wr && ioctl_index == 16'd254) begin
            if (ioctl_addr == 0) begin
                coinage <= ioctl_dout[7:0];
                dsw <= ioctl_dout[15:8];
            end else if (ioctl_addr == 1) begin
                // Compatibility with byte-wide/manual switch downloads.
                dsw <= ioctl_dout[7:0];
            end
        end
    end
endmodule
