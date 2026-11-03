// SPDX-License-Identifier: GPL-3.0-or-later
// Completed-write snoop for the Midnight Resistance twin-stick additions.
// A write is committed on the first DTACK clock of a write cycle, when the 68000
// data bus is final. Both the aim bytes and the high-score window sit in the 16 kB
// work RAM at 0x100000 (jtcop sysram_cs), so a halted CPU produces no events and a
// cycle that finishes while a pause drains is still seen.
module midres_bus_snoop(
    input wire clk, as_n, rnw, dtack_n, uds_n, lds_n, sysram_cs,
    input wire [23:1] a,
    input wire [15:0] data,
    output wire wr_commit,          // any committed CPU write cycle
    output reg [1:0] aim_strobe=0,  // P1/P2 native angle written
    output reg [2:0] aim_a1=0, aim_a2=0,
    output wire score_hit,          // address inside 0x1026EA..0x102739 (CPU read or write)
    output wire [5:0] score_word,
    output wire score_wr            // committed write inside the score window
);
    reg dtack_l=0;
    always @(posedge clk) dtack_l <= ~dtack_n & ~as_n;
    assign wr_commit = ~as_n & ~rnw & ~dtack_n & ~dtack_l;
    wire [12:0] w = a[13:1];
    // Native angle bytes live in the upper byte lane: P1 0x1021BC, P2 0x102238.
    wire aim_ok = data[15:13]==0 && data[9:8]==0;
    wire wr1 = wr_commit & sysram_cs & ~uds_n & (w==13'h10DE);
    wire wr2 = wr_commit & sysram_cs & ~uds_n & (w==13'h111C);
    always @(posedge clk) begin
        aim_strobe <= 0;
        if( wr1 && aim_ok ) begin aim_a1 <= data[12:10]; aim_strobe[0] <= 1; end
        if( wr2 && aim_ok ) begin aim_a2 <= data[12:10]; aim_strobe[1] <= 1; end
    end
    assign score_hit  = sysram_cs && w>=13'h1375 && w<=13'h139C;
    assign score_word = w - 13'h1375;
    assign score_wr   = wr_commit & score_hit;
endmodule
