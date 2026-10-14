// SPDX-License-Identifier: GPL-3.0-or-later
// Simple156 option semantics adapted to Metamorphic's existing status map.
module jtmetamrph_crt_controls(
    input wire [127:0] status,
    input wire direct_video,
    output wire adjust,
    output wire signed [4:0] hsize,hposition,vposition,
    output wire [2:0] scale,fx,
    output wire [1:0] aspect,rotation,
    output wire [11:0] crop_size,
    output wire [15:0] hide_mask
);
    wire [4:0] size_code=status[68:64];
    wire [2:0] scale_code=status[81:79];
    assign adjust=status[48];
    assign hsize=size_code<=5'd6 ? $signed(size_code) :
                 size_code<=5'd16 ? $signed(size_code-5'd17) : 5'sd0;
    assign hposition=$signed(status[73:69]);
    assign vposition=$signed(status[78:74]);
    assign rotation=direct_video ? 2'd0 : status[62:61];
    assign aspect=direct_video ? 2'd0 : status[17:16];
    assign scale=direct_video ? 3'd0 : (scale_code<=3'd4 ? scale_code : 3'd0);
    // Preserve the current rotator's native-raster input contract.
    assign fx=rotation!=0 ? 3'd0 : (status[5:3]<=3'd4 ? status[5:3] : 3'd0);
    // Metamorphic is already 224 lines: Simple156's 240->224 crop maps to 216.
    assign crop_size=(!direct_video && status[41]) ? 12'd216 : 12'd0;
    assign hide_mask=(direct_video ? 16'h0001 : 16'h0000) |
                     (!adjust ? 16'h0004 : 16'h0000) |
                     (rotation!=0 ? 16'h0080 : 16'h0000);
endmodule
