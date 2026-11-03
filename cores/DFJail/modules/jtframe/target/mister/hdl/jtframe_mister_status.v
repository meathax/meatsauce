/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 14-03-2025 */
module jtframe_mister_status (
    input  [63:0] status,
    output        crop_en,
    output [ 3:0] vcopt,
    output [ 2:0] crop_scale,
    output [ 3:0] voffset,
    output [ 3:0] hoffset,
    output        hsize_enable,
    output [ 3:0] hsize_scale,
    output [ 1:0] ram_save,
    output        ram_load,
    output        gun_border_en,
    output        uart_en
);

// Vertical crop
assign crop_en    = status[41];
assign vcopt      = status[45:42];
assign crop_scale = {1'b0, status[47:46]};

// H-Pos & V-Pos for CRT
`ifdef DFJAIL
assign { voffset, hoffset } = status[48] ? status[60:53] : 8'd0;
`else
assign { voffset, hoffset } = status[60:53];
`endif

// Horizontal scaling for CRT
assign hsize_enable = status[48];
assign hsize_scale  = status[52:49];

assign uart_en  = status[38]; // It can be used by the cheat engine or the game

// Sinden Lightgun white borders
assign gun_border_en = status[8];

// Save/Load
assign ram_save = status[21:20];
assign ram_load = status[22];

endmodule

// Kept as a small combinational unit so OSD mask mappings can be checked
// independently of the JTFRAME video and DDR datapaths.
module jtframe_mister_osd_mask (
    input         direct_video,
    input         lightgun_en,
    input         crop_ok,
    input         vertical,
    input         video_rotated,
    input         hsize_enable,
    output [15:0] status_menumask
);

assign status_menumask[15:7] = 0,
       status_menumask[6]    = ~lightgun_en,
       status_menumask[5]    = crop_ok,
`ifdef JTFRAME_ROTATE
       status_menumask[4]    = ~vertical,
       status_menumask[1]    = 1,
`else
       status_menumask[4]    = 1,
       status_menumask[1]    = ~vertical,
`endif
       status_menumask[3]    = ~video_rotated,
       status_menumask[2]    = ~hsize_enable,
       status_menumask[0]    = direct_video;

endmodule
