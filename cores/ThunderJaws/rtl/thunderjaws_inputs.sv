// SPDX-License-Identifier: GPL-3.0-or-later
// Coherent clk_sys-domain cabinet/status inputs, MAME0.289 thunderj.cpp460..488.
// Buttons are numbered as driver bits; OSD Jump/Fire naming belongs to glue.
// Coins/start use the JSA board and are not invented in these two player ports.
module thunderjaws_inputs (
    input wire [1:0] p1_buttons,p2_buttons,
    // direction bits:0 right,1 left,2 down,3 up; active high pressed.
    input wire [3:0] p1_directions,p2_directions,
    input wire service_test,vblank,sound_to_main_full,main_to_sound_full,
    output wire [15:0] port_260000,port_260010,port_260012
);
    assign port_260000=16'hffff;
    assign port_260010={~p1_directions,2'b11,~p1_buttons,8'hff};
    // Raw bit4 is active-high UNUSED=0. special_port2_r XOR0010 is applied
    // exactly once in thunderjaws_io, after this physical/status construction.
    assign port_260012={~p2_directions,2'b11,~p2_buttons,3'b111,1'b0,
                       ~main_to_sound_full,~sound_to_main_full,~service_test,~vblank};
endmodule
