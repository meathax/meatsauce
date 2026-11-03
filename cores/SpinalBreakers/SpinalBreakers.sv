// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer integration candidate. Physical SDRAM and board timing require
// qualification on this complete design before an RBF can be released.
`include "rtl/spinal_mister_menu.svh"
module emu (
    `include "sys/emu_ports.vh"
);
    wire clk_sys,pll_locked;
    pll pll(.refclk(CLK_50M),.rst(1'b0),.outclk_0(clk_sys),.locked(pll_locked));
    (* ASYNC_REG = "TRUE" *) reg [2:0] release_pipe=3'b111;
    always @(posedge clk_sys or negedge pll_locked)
        if(!pll_locked) release_pipe<=3'b111;
        else release_pipe<={release_pipe[1:0],1'b0};
    wire cold_reset=release_pipe[2];
`ifdef MISTER_FB
    localparam bit HAVE_FB=1;
    wire fb_vblank=FB_VBL;
`else
    localparam bit HAVE_FB=0;
    wire fb_vblank=1'b0;
`endif
    wire [2:0] req,write_enable,ack;
    wire [74:0] address;
    wire [47:0] write_data;
    wire [191:0] reply;
    wire [1:0] buttons;
    wire [127:0] status;
    wire game_reset,download_error,fence_fault,rotation_overflow;
    wire main_video_error,sound_program_error,adpcma_overflow,adpcma_late,halted_n;
    wire fb_enable;
    wire [4:0] fb_format;
    wire [11:0] fb_width,fb_height;
    wire [31:0] fb_base;
    wire [13:0] fb_stride;
    wire signed [15:0] sound_l,sound_r;
    spinal_mister_system #(.CONF_STR(`SPINAL_CONF_STR),.WITH_MENU(1),.WITH_CRT(1),.WITH_ROTATION(HAVE_FB)) system (
        .clk(clk_sys),.reset(cold_reset),.user_reset(RESET | buttons[1]),.pause_request(1'b0),
        .service_in(1'b0),.test_in(1'b0),.osd_status(OSD_STATUS),.hiscore_autosave(1'b1),
        .new_vmode(1'b0),.status_menumask(16'b0),.video_effects(3'b0),
        .hdmi_width(HDMI_WIDTH),.hdmi_height(HDMI_HEIGHT),.aspect_choice(2'b0),.scale_choice(2'b0),
        .rotation_request(1'b0),.rotation_ccw(1'b0),.fb_vblank(fb_vblank),.ddram_busy(DDRAM_BUSY),
        .HPS_BUS(HPS_BUS),.status(status),.buttons(buttons),.direct_video(),
        .ioctl_wait(),.game_reset(game_reset),.download_error(download_error),.fence_fault(fence_fault),
        .pause_button(),.paused(),.hiscore_configured(),
        .physical_req(req),.physical_write(write_enable),.physical_addr(address),.physical_data(write_data),
        .physical_ack(ack),.physical_reply(reply),
        .ce_pixel(),.hs(),.vs(),.de(),.red(),.green(),.blue(),.pixel_x(),.pixel_y(),
        .video_clk(CLK_VIDEO),.video_ce(CE_PIXEL),.video_hs(VGA_HS),.video_vs(VGA_VS),.video_de(VGA_DE),
        .video_r(VGA_R),.video_g(VGA_G),.video_b(VGA_B),.video_scanlines(VGA_SL),.video_hq2x_unavailable(),
        .video_arx(VIDEO_ARX),.video_ary(VIDEO_ARY),.video_rotated(),
        .fb_enable(fb_enable),.fb_format(fb_format),.fb_width(fb_width),.fb_height(fb_height),
        .fb_base(fb_base),.fb_stride(fb_stride),
        .ddram_clk(DDRAM_CLK),.ddram_we(DDRAM_WE),.ddram_rd(DDRAM_RD),.ddram_address(DDRAM_ADDR),
        .ddram_data(DDRAM_DIN),.ddram_byteenable(DDRAM_BE),.ddram_burstcount(DDRAM_BURSTCNT),
        .rotation_overflow(rotation_overflow),.pixel_valid(),.underruns(),
        .sound_l(sound_l),.sound_r(sound_r),.sound_sample(),.main_video_error(main_video_error),
        .sound_program_error(sound_program_error),.adpcma_overflow(adpcma_overflow),.adpcma_late(adpcma_late),.halted_n(halted_n)
    );
    spinal_sdram_candidate memory (
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA(SDRAM_BA),.SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),.SDRAM_CLK(SDRAM_CLK),.SDRAM_CKE(SDRAM_CKE),.init(cold_reset),.clk(clk_sys),
        .addr0(address[24:0]),.wrl0(write_enable[0]),.wrh0(write_enable[0]),.din0(write_data[15:0]),.dout0(reply[63:0]),.req0(req[0]),.ack0(ack[0]),
        .addr1(address[49:25]),.wrl1(write_enable[1]),.wrh1(write_enable[1]),.din1(write_data[31:16]),.dout1(reply[127:64]),.req1(req[1]),.ack1(ack[1]),
        .addr2(address[74:50]),.wrl2(write_enable[2]),.wrh2(write_enable[2]),.din2(write_data[47:32]),.dout2(reply[191:128]),.req2(req[2]),.ack2(ack[2])
    );
`ifdef MISTER_FB
    assign FB_EN=fb_enable;
    assign FB_FORMAT=fb_format;
    assign FB_WIDTH=fb_width;
    assign FB_HEIGHT=fb_height;
    assign FB_BASE=fb_base;
    assign FB_STRIDE=fb_stride;
    assign FB_FORCE_BLANK=1'b0;
`ifdef MISTER_FB_PALETTE
    assign {FB_PAL_CLK,FB_PAL_ADDR,FB_PAL_DOUT,FB_PAL_WR}='0;
`endif
`endif
    assign AUDIO_L=sound_l;
    assign AUDIO_R=sound_r;
    assign AUDIO_S=1'b1;
    assign AUDIO_MIX=0;
    assign LED_USER=download_error | fence_fault | main_video_error | sound_program_error | adpcma_overflow | adpcma_late | rotation_overflow;
    assign {LED_DISK,LED_POWER,BUTTONS}=0;
    assign {VGA_F1,VGA_SCALER,VGA_DISABLE,HDMI_FREEZE,HDMI_BLACKOUT,HDMI_BOB_DEINT}=0;
    assign ADC_BUS='z;
    assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='z;
`ifdef MISTER_DUAL_SDRAM
    assign {SDRAM2_CLK,SDRAM2_A,SDRAM2_BA,SDRAM2_DQ,SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}='z;
`endif
endmodule
