"""Replace only the template game adapter, retaining its license and ports."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'Nintendo8080.sv'
old=p.read_text()
prefix=old[:old.index('///////// Default values')]
body=r'''
// Sheriff CPU/video skeleton. Audio, rotation, CRT and persistence integration
// are explicitly pending; this wrapper is also used for early framework fit.
assign ADC_BUS='Z;
assign USER_OUT='1;
assign {UART_RTS,UART_TXD,UART_DTR}=0;
assign {SD_SCK,SD_MOSI,SD_CS}='Z;
assign {SDRAM_DQ,SDRAM_A,SDRAM_BA,SDRAM_CLK,SDRAM_CKE,SDRAM_DQML,SDRAM_DQMH,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,SDRAM_nCS}='Z;
assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_DIN,DDRAM_BE,DDRAM_RD,DDRAM_WE}='0;
assign VGA_SL=0;
assign VGA_F1=0;
assign VGA_SCALER=0;
assign VGA_DISABLE=0;
assign HDMI_FREEZE=0;
assign HDMI_BLACKOUT=0;
assign HDMI_BOB_DEINT=0;
assign AUDIO_S=1;
assign AUDIO_L=0;
assign AUDIO_R=0;
assign AUDIO_MIX=0;
assign LED_DISK=0;
assign LED_POWER=0;
assign BUTTONS=0;
assign VIDEO_ARX=12'd4;
assign VIDEO_ARY=12'd3;
`include "build_id.v"
localparam CONF_STR={
    "Nintendo8080;;",
    "F,Sheriff ROM;",
    "O[9:8],Lives,3,4,5,6;",
    "O[10],Cabinet,Upright,Cocktail;",
    "J,Fire,Start 1,Start 2,Coin,Aim Right,Aim Left,Aim Up,Aim Down;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    "V,v",`BUILD_DATE
};
wire clk_sys,pll_locked;
pll pll(.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.locked(pll_locked));
wire [127:0] status;
wire [1:0] buttons;
wire [31:0] joy0,joy1;
wire ioctl_download,ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire [15:0] ioctl_index;
hps_io #(.CONF_STR(CONF_STR)) hps_io(
    .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(),
    .status(status),.buttons(buttons),.joystick_0(joy0),.joystick_1(joy1),
    .ioctl_download(ioctl_download),.ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),.ioctl_index(ioctl_index),.ioctl_wr(ioctl_wr)
);
wire loading=ioctl_download && ioctl_index==0;
reg was_loading=0,rom_loaded=0;
reg [7:0] reset_stretch=0;
always @(posedge clk_sys) begin
    was_loading<=loading;
    if (was_loading && !loading) rom_loaded<=1;
    if (RESET || status[0] || buttons[1] || loading || !pll_locked || !rom_loaded)
        reset_stretch<=0;
    else if (reset_stretch!=255) reset_stretch<=reset_stretch+1'b1;
end
wire reset=reset_stretch!=255;
wire [7:0] input0={joy0[11:8],joy0[2],joy0[3],joy0[1:0]};
wire [7:0] input1={joy1[11:8],joy1[2],joy1[3],joy1[1:0]};
wire [7:0] input2={joy0[7]|joy1[7],3'b000,joy0[6]|joy1[6],joy0[5]|joy1[5],joy1[4],joy0[4]};
wire [7:0] input3={!status[10],5'b11111,status[9:8]};
wire [2:0] board_rgb;
wire board_hblank,board_vblank,board_hsync,board_vsync;
n8080_board board(
    .clk(clk_sys),.reset(reset),.pause(1'b0),
    .input0(input0),.input1(input1),.input2(input2),.input3(input3),
    .load_wr(ioctl_wr && loading),.load_addr(ioctl_addr[15:0]),.load_data(ioctl_dout),
    .debug_req(1'b0),.debug_addr(14'b0),.debug_data(),
    .ce_pixel(CE_PIXEL),.pixel_x(),.pixel_y(),.rgb(board_rgb),
    .hblank(board_hblank),.vblank(board_vblank),.hsync(board_hsync),.vsync(board_vsync),
    .cpu_address(),.cpu_dout(),.cpu_din(),.cpu_status(),
    .cpu_sync(),.cpu_dbin(),.cpu_wr_n(),.cpu_inte(),.cpu_read(),.cpu_write(),.cpu_ack(),
    .irq(),.irq_vector(),.sound1(),.sound2(),.color_mode(),.color_data(),.flip(),.shift_data(),.shift_count()
);
assign CLK_VIDEO=clk_sys;
assign VGA_R={8{board_rgb[0]}};
assign VGA_G={8{board_rgb[1]}};
assign VGA_B={8{board_rgb[2]}};
assign VGA_HS=board_hsync;
assign VGA_VS=board_vsync;
assign VGA_DE=!(board_hblank||board_vblank);
assign LED_USER=loading;
endmodule
'''
p.write_text(prefix+body,newline='\n')
print('Installed Sheriff CPU/video skeleton wrapper; final features pending')
