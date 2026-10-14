// Escape wrapper for the pinned JTFRAME target. The target bridge is 49 bits;
// Template_MiSTer exposes the stable 46-bit HPS portion.

`ifndef ESCAPE_KIDS_JTFRAME_EMU_INCLUDED
`define ESCAPE_KIDS_JTFRAME_EMU_INCLUDED

`include "vendor/jtcores/modules/jtframe/target/mister/hdl/sys/hps_io.sv"
`include "vendor/jtcores/modules/jtframe/target/mister/hdl/jtframe_emu.sv"

module jtframe_core_pll(
    input  wire refclk,
    input  wire rst,
    output wire locked,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire outclk_4,
    output wire outclk_5
);
`ifdef VERILATOR
    reg [2:0] div;
    always @(posedge refclk or posedge rst) begin
        if (rst) div <= 3'd0;
        else     div <= div + 3'd1;
    end
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign outclk_2 = div[0];
    assign outclk_3 = div[2];
    assign outclk_4 = refclk;
    assign outclk_5 = refclk;
    assign locked   = ~rst;
`else
    // Quartus binds this primitive to the device PLL; sys/PLL remains vendored.
    altera_pll #(
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(6),
        .output_clock_frequency0("48.000000 MHz"),
        .output_clock_frequency1("48.000000 MHz"),
        .output_clock_frequency2("24.000000 MHz"),
        .output_clock_frequency3("6.000000 MHz"),
        .output_clock_frequency4("96.000000 MHz"),
        .output_clock_frequency5("96.000000 MHz"),
        .duty_cycle0(50), .duty_cycle1(50), .duty_cycle2(50),
        .duty_cycle3(50), .duty_cycle4(50), .duty_cycle5(50),
        .phase_shift0("0 ps"), .phase_shift1("5208 ps"),
        .phase_shift2("0 ps"), .phase_shift3("0 ps"),
        .phase_shift4("0 ps"), .phase_shift5("5208 ps")
    ) u_pll (
        .refclk(refclk), .rst(rst),
        .outclk({outclk_5,outclk_4,outclk_3,outclk_2,outclk_1,outclk_0}),
        .locked(locked)
    );
`endif
endmodule

`endif

module emu(`include "sys/emu_ports.vh");

    // JTFRAME reserves the leading framebuffer/scanline capability bits.
    tri [48:0] jt_hps_bus;
    wire jtframe_vga_de;
`ifdef VERILATOR
    // The headless simulator has no tran primitive; preserve both directions.
    /* verilator lint_off UNOPTFLAT */
    assign jt_hps_bus[45:0] = HPS_BUS;
    assign HPS_BUS = jt_hps_bus[45:0];
    /* verilator lint_on UNOPTFLAT */
`else
    genvar hps_bit;
    generate
        for (hps_bit=0; hps_bit<46; hps_bit=hps_bit+1) begin : g_hps_bridge
            tran (jt_hps_bus[hps_bit], HPS_BUS[hps_bit]);
        end
    endgenerate
`endif
    assign jt_hps_bus[48:46] = 3'b000;

    wire jt_db15_en, jt_uart_en, jt_gun_border_en, jt_show_osd;

    escape_kids_jtframe_emu u_jtframe (
        .CLK_50M(CLK_50M), .RESET(RESET), .HPS_BUS(jt_hps_bus),
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(jtframe_vga_de),
        .VGA_F1(VGA_F1), .VGA_SL(VGA_SL), .VGA_SCALER(VGA_SCALER),
        .VGA_DISABLE(VGA_DISABLE), .HDMI_WIDTH(HDMI_WIDTH),
        .HDMI_HEIGHT(HDMI_HEIGHT), .HDMI_FREEZE(HDMI_FREEZE),
        .HDMI_BLACKOUT(HDMI_BLACKOUT), .HDMI_BOB_DEINT(HDMI_BOB_DEINT),
        .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
        .LED_USER(LED_USER), .LED_POWER(LED_POWER), .LED_DISK(LED_DISK),
        .BUTTONS(BUTTONS), .CLK_AUDIO(CLK_AUDIO), .AUDIO_L(AUDIO_L),
        .AUDIO_R(AUDIO_R), .AUDIO_S(AUDIO_S), .AUDIO_MIX(AUDIO_MIX),
        .ADC_BUS(ADC_BUS), .SD_SCK(SD_SCK), .SD_MOSI(SD_MOSI),
        .SD_MISO(SD_MISO), .SD_CS(SD_CS), .SD_CD(SD_CD),
        .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
        .UART_CTS(UART_CTS), .UART_RTS(UART_RTS), .UART_RXD(UART_RXD),
        .UART_TXD(UART_TXD), .UART_DTR(UART_DTR), .UART_DSR(UART_DSR),
        .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
        .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
        .DDRAM_WE(DDRAM_WE), .USER_IN(USER_IN), .USER_OUT(USER_OUT),
        .db15_en(jt_db15_en), .uart_en(jt_uart_en),
        .gun_border_en(jt_gun_border_en), .show_osd(jt_show_osd),
        .OSD_STATUS(OSD_STATUS)
    );

    // The imported JTFRAME path remains the source of RGB and sync.  Only
    // the final active-enable interval is cropped for Escape Kids' 288x240
    // presentation window; the game raster and all game-visible timing stay
    // on the untouched signals inside escape_kids_jtframe_emu.
    escape_kids_presentation_crop #(
        .LEFT  (12),
        .RIGHT (300)
    ) u_presentation_crop (
        .clk_video (CLK_VIDEO),
        .reset     (RESET),
        .ce_pixel  (CE_PIXEL),
        .de_in     (jtframe_vga_de),
        .de_out    (VGA_DE)
    );

endmodule
