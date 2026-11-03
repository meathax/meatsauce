// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer port binding. Physical SDRAM timing is a separate release gate.
module emu (
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='z;
    assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=3'b000;
    assign {SD_SCK,SD_MOSI,SD_CS}=3'bzzz;
    assign LED_POWER=2'b00;
    assign LED_DISK=2'b00;
    assign BUTTONS=2'b00;
    assign VGA_SCALER=1'b0;
    assign VGA_DISABLE=1'b0;
    assign VGA_F1=1'b0;
    assign HDMI_FREEZE=1'b0;
    assign HDMI_BLACKOUT=1'b0;
    assign HDMI_BOB_DEINT=1'b0;
    assign AUDIO_S=1'b1;
    assign AUDIO_MIX=2'b00;
`ifdef MISTER_FB
    assign FB_FORCE_BLANK=1'b0;
`ifdef MISTER_FB_PALETTE
    assign FB_PAL_CLK=CLK_VIDEO;
    assign FB_PAL_ADDR=8'd0;
    assign FB_PAL_DOUT=24'd0;
    assign FB_PAL_WR=1'b0;
`endif
`endif
`ifdef MISTER_DUAL_SDRAM
    assign {SDRAM2_CLK,SDRAM2_A,SDRAM2_BA,SDRAM2_DQ,
        SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}='z;
`endif
    // Only power-on owns PLL/raster reset. The sys RESET and OSD reset
    // are game resets; neither stops sync, refresh or the forwarded clock.
    reg [13:0] power_count=14'd0;
    reg power_ready=1'b0;
    always @(posedge CLK_50M) begin
        if(!power_ready) begin
            power_count<=power_count+14'd1;
            if(&power_count) power_ready<=1'b1;
        end
    end
    wire clk_sys,clk_sdram,system_reset;
    wire refresh,audio_sample_ce;
    wire [23:0] rgb;
    wire rom_valid,rom_fault,memory_ready,memory_fault;
    wire load_fault,owner_fault,hiscore_fault;
    wire raw_dqml,raw_dqmh,raw_ncs,raw_cke;
    reg sdram_cke_pad=1'b0;
    always @(posedge clk_sys or posedge system_reset) begin
        if(system_reset) sdram_cke_pad<=1'b0;
        else sdram_cke_pad<=raw_cke;
    end
    assign SDRAM_CKE=sdram_cke_pad;
    wire [127:0] status;
    wire [21:0] gamma_bus;
    assign {VGA_R,VGA_G,VGA_B}=rgb;
    assign DDRAM_CLK=clk_sys;
    // system_reset already includes cold power-on and synchronous release.
    assign SDRAM_nCS=raw_ncs || system_reset;
    assign SDRAM_DQML=raw_dqml;
    assign SDRAM_DQMH=raw_dqmh;
    assign LED_USER=rom_fault || memory_fault || load_fault || owner_fault || hiscore_fault || !rom_valid;

    hangzo_service_enables services(.clk(clk_sys),.reset(system_reset),
        .refresh(refresh),.audio_sample_ce(audio_sample_ce));

    // Full-rate dedicated DDIO clock forwarding, never a fabric inverter.
    // Related PLL output1 places its rising edge 8929ps after the root.
    // Independent chip/flight proof is retained; final pad STA is required.
    altddio_out #(.width(1),.power_up_high("OFF"),
        .oe_reg("UNREGISTERED"),.intended_device_family("Cyclone V"))
    sdram_clock_forward(.outclock(clk_sdram),.datain_h(1'b1),.datain_l(1'b0),
        .dataout(SDRAM_CLK),.aclr(1'b0),.aset(1'b0),.outclocken(1'b1),
        .oe(1'b1),.sclr(1'b0),.sset(1'b0));

    hangzo_clocked_platform #(.HF_CONFIG(1),.SHIFTED_CONFIG(1),
        .REFRESH_COMMANDS_CONFIG(1),.MEMORY_STARTUP_CYCLES(11200),
`ifdef MISTER_FB
        .FRAMEBUFFER_SUPPORTED(1),
`else
        .FRAMEBUFFER_SUPPORTED(0),
`endif
        .DIRECT_VIDEO_ROTATION_SUPPORTED(1),.HISCORE_SUPPORTED(1),
        .NATIVE_PROFILE_QUALIFIED(1'b1)) core(
        .refclk_50(CLK_50M),.cold_reset(!power_ready),.reset(RESET),
        .clk_sys(clk_sys),.clk_video(CLK_VIDEO),.clk_sdram(clk_sdram),.system_reset(system_reset),
        .refresh(refresh),.audio_sample_ce(audio_sample_ce),.flip(1'b0),
        .osd_open(OSD_STATUS),.HPS_BUS(HPS_BUS),.gamma_bus(gamma_bus),
        .hdmi_width(HDMI_WIDTH),.hdmi_height(HDMI_HEIGHT),
`ifdef MISTER_FB
        .fb_vblank(FB_VBL),.fb_low_latency(FB_LL),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),
        .FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),
`else
        .fb_vblank(1'b0),.fb_low_latency(1'b0),
`endif
        .status(status),.video_rgb(rgb),.video_ce(CE_PIXEL),
        .video_hs(VGA_HS),.video_vs(VGA_VS),.video_de(VGA_DE),
        .video_scanline(VGA_SL),.video_arx(VIDEO_ARX),.video_ary(VIDEO_ARY),
        .audio_left(AUDIO_L),.audio_right(AUDIO_R),
        .rom_valid(rom_valid),.rom_fault(rom_fault),.memory_ready(memory_ready),
        .memory_fault(memory_fault),.load_fault(load_fault),
        .owner_fault(owner_fault),.hiscore_fault(hiscore_fault),
        .DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_BE(DDRAM_BE),
        .DDRAM_ADDR(DDRAM_ADDR),.DDRAM_DIN(DDRAM_DIN),
        .DDRAM_RD(DDRAM_RD),.DDRAM_WE(DDRAM_WE),.DDRAM_BUSY(DDRAM_BUSY),
        .DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_DOUT(DDRAM_DOUT),
        .sdram_dq(SDRAM_DQ),.sdram_a(SDRAM_A),.sdram_ba(SDRAM_BA),
        .sdram_dqml(raw_dqml),.sdram_dqmh(raw_dqmh),
        .sdram_nwe(SDRAM_nWE),.sdram_ncas(SDRAM_nCAS),
        .sdram_nras(SDRAM_nRAS),.sdram_ncs(raw_ncs),.sdram_cke(raw_cke));
endmodule
