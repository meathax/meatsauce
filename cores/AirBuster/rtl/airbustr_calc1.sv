// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko CALC1 (MAME kaneko_hit type 0) behind Air Buster's 8-bit main bus at
// EFE0-EFF5. Collision/multiplier logic from the Sand Scorpion core's
// kaneko_hit.sv (d3ca399c). The 8-bit glue follows airbustr.cpp calc1_w/_r:
// every byte write also lands in devram, and the 16-bit register is rebuilt
// from the devram byte pair. Every byte read is a separate kaneko_hit_r call,
// so a random read advances MAME's running_machine::rand() LCG once per byte.
module airbustr_calc1 (
    input  logic       clk, reset,
    input  logic       wr, rd,           // one-cycle strobes, addr in EFE0-EFF5
    input  logic [4:0] addr,             // offset from EFE0
    input  logic [7:0] din,
    output logic [7:0] dout,             // valid the cycle after rd (registered)
    output logic       watchdog_kick
);
    logic [7:0] shadow [0:21];           // devram copy of EFE0-EFF5
    logic [15:0] x1p, x1s, y1p, y1s, x2p, x2s, y2p, y2s, mult_a, mult_b;
    logic [31:0] seed;
    wire [15:0] x12 = x1p - (x2p + x2s);
    wire [15:0] y12 = y1p - (y2p + y2s);
    wire [15:0] x21 = (x1p + x1s) - x2p;
    wire [15:0] y21 = (y1p + y1s) - y2p;
    wire overlap = x12[15] & y12[15] & ~x21[15] & ~y21[15];
    wire [15:0] collide = {(y1p < y2p), (y1p == y2p), (y1p > y2p), 1'b0,
                           (x1p < x2p), (x1p == x2p), (x1p > x2p), 1'b0,
                           7'd0, overlap};
    wire [31:0] product = mult_a * mult_b;
    wire [31:0] next_seed = 32'd1664525 * seed + 32'd1013904223;
    // MAME returns the seed rotated by 16; the low 16 bits are seed[31:16].
    wire [15:0] word_in = addr[0] ? {din, shadow[{addr[4:1],1'b0}]}
                                  : {shadow[{addr[4:1],1'b1}], din};
    assign watchdog_kick = rd && addr[4:1] == 4'd0;
    always_ff @(posedge clk) begin
        if (reset) begin
            {x1p, x1s, y1p, y1s, x2p, x2s, y2p, y2s, mult_a, mult_b} <= '0;
            seed <= 32'h9d14abd7;
            dout <= 8'h00;
            for (int i = 0; i < 22; i++) shadow[i] <= 8'h00;
        end else begin
            if (wr) begin
                shadow[addr] <= din;
                case (addr[4:1])
                    4'd0: x1p <= word_in;   4'd1: x1s <= word_in;
                    4'd2: y1p <= word_in;   4'd3: y1s <= word_in;
                    4'd4: x2p <= word_in;   4'd5: x2s <= word_in;
                    4'd6: y2p <= word_in;   4'd7: y2s <= word_in;
                    4'd8: mult_a <= word_in; 4'd9: mult_b <= word_in;
                    default: ;
                endcase
            end
            if (rd) begin
                case (addr[4:1])
                    4'd2: dout <= addr[0] ? collide[15:8] : collide[7:0];
                    4'd8: dout <= addr[0] ? product[31:24] : product[23:16];
                    4'd9: dout <= addr[0] ? product[15:8] : product[7:0];
                    4'd10: begin
                        seed <= next_seed;
                        dout <= addr[0] ? next_seed[31:24] : next_seed[23:16];
                    end
                    default: dout <= 8'h00;
                endcase
            end
        end
    end
endmodule
