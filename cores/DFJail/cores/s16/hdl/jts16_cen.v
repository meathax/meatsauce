/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 10-3-2021 */

module jts16_cen(
    input              clk,       // main CPU & video (50.3496 MHz)
    output             pxl2_cen,  // pixel clock enable (2x)
    output             pxl_cen,   // pixel clock enable

    input              clk24,     // sound subsystem (25.1748 MHz)
    output             mcu_cen,   // 8 MHz
    output             snd_cen,   // 5 MHz
    output             fm_cen,    // 4 MHz
    output             fm2_cen,   // 2 MHz
    output             pcm_cen,
    output             pcm_cenb
);

parameter CLK96=0;

wire nc, ncb, nc2, ncb2, nc3, nc4;

// The S16 pixel cadence is an exact integer divisor of clk. Keep both
// enables on this clock; a fractional accumulator adds needless CE jitter.
localparam integer PXL_DIV  = CLK96 ? 8 : 4;
localparam integer PXL2_DIV = PXL_DIV/2;
reg [2:0] pxl_count  = PXL_DIV-1;
reg [2:0] pxl2_count = PXL2_DIV-1;
reg pxl_cen_r  = 1'b0;
reg pxl2_cen_r = 1'b0;

assign pxl_cen  = pxl_cen_r;
assign pxl2_cen = pxl2_cen_r;

always @(posedge clk) begin
    pxl_cen_r  <= (pxl_count  == PXL_DIV-1);
    pxl2_cen_r <= (pxl2_count == PXL2_DIV-1);
    pxl_count  <= (pxl_count  == PXL_DIV-1)  ? 3'd0 : pxl_count+3'd1;
    pxl2_count <= (pxl2_count == PXL2_DIV-1) ? 3'd0 : pxl2_count+3'd1;
end


// Sound subsystem uses clk24 = 25.1748 MHz

jtframe_frac_cen u_mcucen(   // 8MHz
    .clk    ( clk24     ),
    .n      ( 10'd143   ),
    .m      ( 10'd450   ),
    .cen    ( { nc4, mcu_cen } ),
    .cenb   (           )
);

jtframe_frac_cen u_fmcen(   // 4MHz
    .clk    ( clk24     ),
    .n      ( 10'd143   ),
    .m      ( 10'd900   ),
    .cen    ( { fm2_cen, fm_cen } ),
    .cenb   (           )
);

jtframe_frac_cen #(.WC(14)) u_sndcen( // 5 MHz
    .clk    ( clk24     ),
    .n      ( 14'd1373  ),
    .m      ( 14'd6913  ),
    .cen    ( { nc3, snd_cen } ),
    .cenb   (           )
);

`ifndef S16B
    jtframe_frac_cen #(.WC(14)) u_pcmcen(  // 6 MHz
        .clk    ( clk24     ),
        .n      ( 14'd1619  ),
        .m      ( 14'd6793  ),
        .cen    ( { nc2, pcm_cen  } ),
        .cenb   ( { ncb2, pcm_cenb} )
    );
`else
    // 640 kHz
    jtframe_frac_cen  #(.WC(16)) u_pcmcen(
        .clk    ( clk24     ),
        .n      ( 16'd873   ),
        .m      ( 16'd34340 ),
        .cen    ( { nc2, pcm_cen  } ),
        .cenb   ( { ncb2, pcm_cenb} )
    );
`endif

endmodule
