/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 6-12-2022 */

`ifdef JTFRAME_PXLCLK
module jtframe_pxlcen(
    input   clk,
    output  pxl_cen,
    output  pxl2_cen
);

    localparam PXLCLK = `JTFRAME_PXLCLK,
               CLK    = `ifdef JTFRAME_SDRAM96 96 `else 48 `endif,
               M      = PXLCLK==16 ? 3 : (PXLCLK==12 ? 2 : PXLCLK==8 ? 3 : 4) << (CLK==96 ? 1:0); // 12: X-Men 6P composed raster, 48/4

    initial begin
        if( PXLCLK==16 && CLK!=96 ) begin
            $fatal(1,"JTFRAME_PXLCLK=16 requires JTFRAME_SDRAM96");
        end else if( PXLCLK!=16 && PXLCLK!=12 && PXLCLK!=8 && PXLCLK!=6 ) begin
            $display("JTFRAME_PXLCLK is set to %d. But that value isn't supported yet.",PXLCLK);
            $finish;
        end else begin
            $display("jtframe_pxlcen: using %0d as clock divider", M[3:0]);
        end
    end

    // Plain integer counter, cycle-identical to the former jtframe_frac_cen
    // n=1/m=M instance: pxl2_cen every M clocks, pxl_cen on every other one,
    // both first asserted at the M-th clock edge after configuration.
    localparam [4:0] HALF = M-1, LAST = 2*M-1;
    reg [4:0] cnt = 0;
    reg       pxl_r = 0, pxl2_r = 0;

    assign pxl_cen  = pxl_r;
    assign pxl2_cen = pxl2_r;

    always @(posedge clk) begin
        cnt    <= cnt == LAST ? 5'd0 : cnt + 5'd1;
        pxl2_r <= cnt == HALF || cnt == LAST;
        pxl_r  <= cnt == HALF;
    end

endmodule
`endif
