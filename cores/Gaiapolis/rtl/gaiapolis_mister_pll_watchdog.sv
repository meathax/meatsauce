// SPDX-License-Identifier: GPL-3.0-or-later
// PLL outputs are not a valid clock source for their own reset timer.
module gaiapolis_mister_pll_watchdog #(
    parameter integer RESET_CYCLES = 256
) (
    input wire clk_ref, reset_async, pll_locked,
    output logic pll_reset
);
    localparam integer COUNT_W = RESET_CYCLES > 1 ? $clog2(RESET_CYCLES) : 1;
    (* async_reg = "true", dont_retime *) logic [1:0] lock_sync;
    logic last_locked;
    logic [COUNT_W-1:0] remaining;
    initial begin
        lock_sync = 2'b00;
        last_locked = 1'b0;
        remaining = '0;
        pll_reset = 1'b0;
    end
    always @(posedge clk_ref or posedge reset_async) begin
        if (reset_async) begin
            lock_sync <= 2'b00;
            last_locked <= 1'b0;
            remaining <= '0;
            pll_reset <= 1'b0;
        end else begin
            lock_sync <= {lock_sync[0], pll_locked};
            last_locked <= lock_sync[1];
            if (last_locked && !lock_sync[1] && !pll_reset) begin
                remaining <= COUNT_W'(RESET_CYCLES - 1);
                pll_reset <= 1'b1;
            end else if (remaining != 0) begin
                remaining <= remaining - 1'b1;
                pll_reset <= 1'b1;
            end else begin
                pll_reset <= 1'b0;
            end
        end
    end
endmodule
