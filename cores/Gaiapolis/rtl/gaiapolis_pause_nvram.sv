// SPDX-License-Identifier: GPL-3.0-or-later
// Related clk48->clk96 held grant/event bridge for standard sav_*.
// freeze_req is platform sav_ack; restore_pending is sav_wr[0]. The controller
// synchronizes these held requests itself. This bridge never resets on the
// game/initializer's held reset, which would drop grant during valid restore.
module gaiapolis_pause_nvram (
    input logic clk,rst,freeze_req,safe_grant48,dirty_toggle48,
    output logic safe_grant96,sav_wait,sav_change
);
    logic [1:0] grant_sync,dirty_sync;
    logic dirty_last;
    always_comb begin
        // MiSTer Main holds status[0] (game reset) across the whole MRA load,
        // including the <nvram> restore. A held game reset is already a safe
        // boundary (CPUs, EEPROM and hiscore in reset, seed writes gated), and
        // the pause controller cannot grant while reset, so grant here.
        safe_grant96=freeze_req && (grant_sync[1] || rst);
        sav_wait=!safe_grant96;
        sav_change=dirty_sync[1]^dirty_last;
    end
    always_ff @(posedge clk) begin
        if(rst) begin grant_sync<=0;dirty_sync<=0;dirty_last<=0;end
        else begin
            grant_sync<={grant_sync[0],safe_grant48};
            dirty_sync<={dirty_sync[0],dirty_toggle48};
            dirty_last<=dirty_sync[1];
        end
    end
endmodule
