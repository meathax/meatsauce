/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 6-12-2022 */

`ifdef JTFRAME_PXLCLK
module jtframe_pxlcen(
    input   clk,
    output reg pxl_cen,
    output reg pxl2_cen
);

    localparam PXLCLK = `JTFRAME_PXLCLK,
               CLK    = `ifdef JTFRAME_SDRAM96 96 `else 48 `endif,
               PXL_DIV = (PXLCLK==6 ? 8 : 6) << (CLK==96 ? 1:0),
               PX2_DIV = PXL_DIV/2;

    // JTFRAME_PXLCLK names the pixel family, not the root-clock divider.
    // Keep both enables on an integer cadence from clk: pxl2 is /PX2_DIV,
    // and pxl is /PXL_DIV. The first pulse retains jtframe_frac_cen's phase.
    reg [3:0] divcnt = 4'd0;
    reg       pxl_phase = 1'b0;

    initial begin
        if( PXLCLK!=8 && PXLCLK!=6 ) begin
            $display("JTFRAME_PXLCLK is set to %d. But that value isn't supported yet.",PXLCLK);
            $finish;
        end else begin
            $display("jtframe_pxlcen: integer pixel divider %0d, double-pixel divider %0d", PXL_DIV, PX2_DIV);
        end
    end

    always @(posedge clk) begin
        pxl_cen  <= 1'b0;
        pxl2_cen <= 1'b0;
        if( divcnt == PX2_DIV-1 ) begin
            divcnt   <= 4'd0;
            pxl2_cen <= 1'b1;
            pxl_cen  <= ~pxl_phase;
            pxl_phase <= ~pxl_phase;
        end else begin
            divcnt <= divcnt + 1'b1;
        end
    end

endmodule
`endif
