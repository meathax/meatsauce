/* SPDX-FileCopyrightText: 2026 Violent Storm core contributors
 * SPDX-License-Identifier: GPL-3.0-or-later */
// Gaiapolis adaptation: factor the common DQM term after source selection.
// No register, command, priority or SDRAM capture latency is changed.
module jtviostorm_sdram_hi(
    input        init,
    input        rfshing,
    input        prog_en,
    input  [3:1] bg,
    input  [6:0] active,
    input [13:0] row_hi,
    input  [1:0] write_mask,
    output [1:0] a_hi
);
wire [6:0] sel;
wire normal;
assign normal = ~init & ~rfshing & ~prog_en;
assign sel = {init, ~init & rfshing, ~init & ~rfshing & prog_en,
              normal & bg[3], normal & ~bg[3] & bg[2],
              normal & ~bg[3] & ~bg[2] & bg[1],
              normal & ~bg[3] & ~bg[2] & ~bg[1]};

// Exactly one source is selected, including the bank-zero idle fallback.
// With no selected ACTIVATE, all seven original branches return write_mask.
wire [6:0] row_selected = sel & active;
wire [13:0] selected;
genvar k;
generate for(k=0; k<7; k=k+1) begin: g_src
    assign selected[k*2+:2] = {2{row_selected[k]}} & row_hi[k*2+:2];
end endgenerate
assign a_hi = selected[13:12] | selected[11:10] | selected[9:8] |
              selected[7:6] | selected[5:4] | selected[3:2] | selected[1:0] |
              ({2{~(|row_selected)}} & write_mask);
endmodule
