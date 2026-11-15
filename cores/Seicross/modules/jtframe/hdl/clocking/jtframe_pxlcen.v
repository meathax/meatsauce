/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 6-12-2022 */

`ifdef JTFRAME_PXLCLK
module jtframe_pxlcen(
    input   clk,
    output reg pxl_cen=0,
    output reg pxl2_cen=0
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

    // Fixed n=1 cadence. Preserve the upstream initial phase: both
    // enables first pulse at M, then pixels repeat every 2*M clocks.
    // Raster timing runs independently of game reset and pause.
    reg [4:0] count=0;
    always @(posedge clk) begin
        pxl2_cen <= count==M-1 || count==2*M-1;
        pxl_cen  <= count==M-1;
        count <= count==2*M-1 ? 5'd0 : count+5'd1;
    end

endmodule
`endif
