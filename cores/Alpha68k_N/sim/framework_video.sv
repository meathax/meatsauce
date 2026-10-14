// Diagnostic of the pinned framework boundary. The input is a captured real
// game RGB field; this fixture is not CPU execution or whole-core acceptance.
module alpha68kn_framework_video (
    input wire clk,ce,
    input wire [23:0] rgb,
    input wire hb,vb,hs,vs,
    input wire [2:0] fx,
    input wire forced,
    input wire no_rotate,fb_vblank,
    output wire output_ce,output_de,output_hs,output_vs,
    output wire [23:0] output_rgb,
    output wire [1:0] output_sl,
    output wire capture_ce,capture_hb,capture_vb,
    output wire [23:0] capture_rgb,
    output wire rotated,fb_en,
    output wire [11:0] fb_width,fb_height,
    output wire [31:0] fb_base,
    output wire [13:0] fb_stride,
    output wire ddr_we,
    output wire [28:0] ddr_addr,
    output wire [63:0] ddr_data,
    output wire [7:0] ddr_be
);
    wire [21:0] gamma_bus;
    assign gamma_bus[20:0]={clk,20'd0};
    arcade_video #(.WIDTH(256),.DW(24)) video (
        .clk_video(clk),.ce_pix(ce),.RGB_in(rgb),.HBlank(hb),.VBlank(vb),.HSync(hs),.VSync(vs),
        .CLK_VIDEO(),.CE_PIXEL(output_ce),.VGA_R(output_rgb[23:16]),
        .VGA_G(output_rgb[15:8]),.VGA_B(output_rgb[7:0]),
        .VGA_HS(output_hs),.VGA_VS(output_vs),.VGA_DE(output_de),.VGA_SL(output_sl),
        .fx(fx),.forced_scandoubler(forced),.gamma_bus(gamma_bus)
    );
    // Observe the input register independently of downstream generated nets.
    assign capture_ce=video.CE;
    assign capture_hb=video.HBL;
    assign capture_vb=video.VBL;
    assign capture_rgb=video.RGB_fix;
    screen_rotate rotation (
        .CLK_VIDEO(clk),.CE_PIXEL(output_ce),.VGA_R(output_rgb[23:16]),
        .VGA_G(output_rgb[15:8]),.VGA_B(output_rgb[7:0]),
        .VGA_HS(output_hs),.VGA_VS(output_vs),.VGA_DE(output_de),
        .rotate_ccw(1'b0),.no_rotate(no_rotate),.flip(1'b0),.video_rotated(rotated),
        .FB_EN(fb_en),.FB_FORMAT(),.FB_WIDTH(fb_width),.FB_HEIGHT(fb_height),
        .FB_BASE(fb_base),.FB_STRIDE(fb_stride),.FB_VBL(fb_vblank),.FB_LL(1'b0),
        .DDRAM_CLK(),.DDRAM_BUSY(1'b0),.DDRAM_BURSTCNT(),.DDRAM_ADDR(ddr_addr),
        .DDRAM_DIN(ddr_data),.DDRAM_BE(ddr_be),.DDRAM_WE(ddr_we),.DDRAM_RD()
    );
endmodule
