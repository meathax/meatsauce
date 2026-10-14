// Elaboration-only vendor interface stubs. Not executable PLL/HPS models and
// never included in the FPGA source list. These do not qualify boot or timing.
module alpha68kn_pll(input wire refclk,rst,output wire clk_sys,clk_sdram,locked);
    assign clk_sys=refclk;
    assign clk_sdram=refclk;
    assign locked=!rst;
endmodule

module hps_io #(parameter CONF_STR="",WIDE=0) (
    input wire clk_sys,
    inout wire [45:0] HPS_BUS,
    output wire [31:0] joystick_0,joystick_1,
    output wire [127:0] status,
    output wire [1:0] buttons,
    output wire ioctl_download,ioctl_upload,ioctl_wr,
    input wire ioctl_upload_req,
    input wire [7:0] ioctl_upload_index,ioctl_din,
    input wire [15:0] status_menumask,
    output wire [26:0] ioctl_addr,
    output wire [7:0] ioctl_dout,
    output wire [15:0] ioctl_index,
    input wire ioctl_wait,
    output wire forced_scandoubler,direct_video,
    inout wire [21:0] gamma_bus
);
    assign joystick_0=0;
    assign joystick_1=0;
    assign status=0;
    assign buttons=0;
    assign ioctl_download=0;
    assign ioctl_upload=0;
    assign ioctl_wr=0;
    assign ioctl_addr=0;
    assign ioctl_dout=0;
    assign ioctl_index=0;
    assign forced_scandoubler=0;
    assign direct_video=0;
    assign gamma_bus[20:0]={clk_sys,20'd0};
endmodule
