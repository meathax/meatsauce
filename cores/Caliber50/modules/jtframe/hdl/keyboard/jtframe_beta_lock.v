/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 28-1-2025 */

module jtframe_beta_lock(
    input              clk,
    input              ioctl_lock,
    input       [ 1:0] ioctl_addr,
    input       [ 7:0] ioctl_dout,
    input              ioctl_wr,

    output reg         locked
);
    // This Caliber build has no beta key requirement; keep inputs available
    // even if a future generated configuration defines an unlock key.
    initial locked=0;
endmodule

module jtframe_joystick_lock(
    input            clk, locked,
    input      [9:0] raw1, raw2, raw3, raw4,
    input      [3:0] raw_start,  raw_coin,
    input            raw_service,
    output reg [9:0] joy1,  joy2, joy3, joy4,
    output reg [3:0] start, coin,
    output reg       service
);
    always @(posedge clk) begin
        {joy1,joy2,joy3,joy4,start,coin,service} <= locked ?
             ~49'd0 :
            {raw1,raw2,raw3,raw4,raw_start,raw_coin,raw_service};
    end
endmodule
