/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 6-12-2022 */

`ifdef JTFRAME_PXLCLK
module jtframe_pxlcen(
    input   clk,
    output reg pxl_cen = 0,
    output reg pxl2_cen = 0
);

    localparam PXLCLK = `JTFRAME_PXLCLK,
               CLK    = `ifdef JTFRAME_SDRAM96 96 `else 48 `endif,
               M      = (PXLCLK==12 ? 2 : PXLCLK==8 ? 3 : 4) << (CLK==96 ? 1:0);

    initial begin
        if( PXLCLK!=8 && PXLCLK!=6 ) begin
            $display("JTFRAME_PXLCLK is set to %d. But that value isn't supported yet.",PXLCLK);
            $finish;
        end else begin
            $display("jtframe_pxlcen: using %0d as clock divider", M[3:0]);
        end
    end

    // Fixed integer cadence, preserving the original n=1 divider's startup
    // phase and its 1x/2x enable alignment for both supported clock rates.
    reg [3:0] pixel_count = 0;
    always @(posedge clk) begin
        pxl_cen  <= pixel_count == M-1;
        pxl2_cen <= pixel_count == M-1 || pixel_count == 2*M-1;
        pixel_count <= pixel_count == 2*M-1 ? 0 : pixel_count + 1'b1;
    end

endmodule
`endif
