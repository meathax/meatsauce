// MiSTer MRA DIP transfer: with WIDE=1, index 254 sends both DIP bytes in one
// 16-bit beat at byte offset zero (low byte is SWA, high byte is SWB).
module daikaiju_dip_switches (
    input  logic        clk_sys,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    output logic [7:0]  dip_a = 8'hfc,
    output logic [7:0]  dip_b = 8'hff
);
    always_ff @(posedge clk_sys) begin
        if (ioctl_wr && (ioctl_index == 16'd254) && (ioctl_addr == 27'd0)) begin
            dip_a <= ioctl_dout[7:0];
            dip_b <= ioctl_dout[15:8];
        end
    end
endmodule
