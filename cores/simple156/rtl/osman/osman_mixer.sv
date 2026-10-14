// SPDX-License-Identifier: GPL-3.0-or-later
// MAME0.289 Simple156 tile bitmap priority2/4 and sprite masks0/f0/fc.
module osman_mixer (
    input logic [8:0] pf1_index, pf2_index,
    input logic pf1_opaque, pf2_opaque,
    input logic [9:0] sprite_index,
    input logic [1:0] sprite_priority,
    input logic sprite_opaque,
    output logic [9:0] palette_index
);
    logic sprite_allowed;
    always_comb begin
        palette_index = 10'h100;
        if (pf2_opaque) palette_index = {1'b0,pf2_index};
        if (pf1_opaque) palette_index = {1'b0,pf1_index};
        case (sprite_priority)
            0: sprite_allowed = 1;
            1: sprite_allowed = !pf1_opaque;
            default: sprite_allowed = !pf1_opaque && !pf2_opaque;
        endcase
        if (sprite_opaque && sprite_allowed) palette_index = sprite_index;
    end
endmodule
