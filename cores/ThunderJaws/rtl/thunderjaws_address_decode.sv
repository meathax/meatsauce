// SPDX-License-Identifier: GPL-3.0-or-later
// ThunderJaws target-specific glue, from MAME 0.289 thunderj.cpp main_map/extra_map.
// Reviewed SkullXBones decoder structure; its PAL mirrors do not apply here.
// Combinational selection only: the bus owner must latch/hold transactions and
// responses through the active data strobe; TAS can span two strobes under AS.
// No DTACK, arbitration, side effects or clocks.
module thunderjaws_address_decode #(parameter EXTRA_CPU = 0) (
    input wire as_active, input wire rw,
    input wire uds_n, input wire lds_n,
    input wire [2:0] fc, input wire [23:1] address,
    output reg [14:0] select
);
    // bit 0 ROM, 1 shared RAM, 2 EEPROM, 3 EEPROM unlock,
    // 4/5/6 input ports 260000/260010/260012, 7 sound response,
    // 8 watchdog, 9 latch, 10 sound reset, 11 sound command,
    // 12 palette, 13 VAD control, 14 video/work RAM.
    wire [23:0] a = {address,1'b0};
    always @* begin
        select = 15'b0;
        if (as_active && (!uds_n || !lds_n) && fc != 3'b111) begin
            select[0] = rw && (EXTRA_CPU ?
                (a <= 24'h03ffff || (a >= 24'h060000 && a <= 24'h07ffff)) :
                (a <= 24'h09ffff));
            select[1] = a >= 24'h160000 && a <= 24'h16ffff;
            select[4] = rw && a >= 24'h260000 && a <= 24'h26000f;
            select[5] = rw && a == 24'h260010;
            select[6] = rw && a == 24'h260012;
            select[7] = rw && !lds_n && a == 24'h260030;
            select[9] = !rw && a == 24'h360010;
            select[10] = !rw && a == 24'h360020;
            select[11] = !rw && !lds_n && a == 24'h360030;
            if (!EXTRA_CPU) begin
                select[2] = !lds_n && a >= 24'h0e0000 && a <= 24'h0e0fff;
                select[3] = !rw && a >= 24'h1f0000 && a <= 24'h1fffff;
                select[8] = !rw && a == 24'h2e0000;
                select[12] = a >= 24'h3e0000 && a <= 24'h3e0fff;
                select[13] = a >= 24'h3effc0 && a <= 24'h3effff;
                select[14] = a >= 24'h3f0000 && a <= 24'h3fffff;
            end
        end
    end
endmodule
