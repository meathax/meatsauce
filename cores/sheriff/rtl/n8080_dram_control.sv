// SPDX-License-Identifier: GPL-3.0-or-later
// Isolated zero-delay pin equations from the connected related-Bandido drawing.
// CPU_WR_RD generation, physical4116 timing and production integration are open.
module n8080_dram_control (
    input wire cpu_wr_rd_level,
    input wire [15:0] cpu_address,
    input wire cpu_wr_n, cpu_sync, phi1_ttl,
    input wire [4:0] physical_h_byte,
    input wire [7:0] physical_v,
    input wire raw_cas_n, raw_ras_n, comadr_n, hread_n,
    output wire [1:0] mux_selector,
    output reg [6:0] mux_address,
    output wire dram_cas_n, dram_ras_n, dram_we_n,
    output wire ststb, ramstb_n, disable_level,
    output wire write_predicate
);
    // LS153 A pin14 = NOT COMADR_n; B pin2 = NOT HREAD_n.
    assign mux_selector = {~hread_n, ~comadr_n};
    always @* begin
        case (mux_selector)
            2'd0: mux_address = cpu_address[6:0];
            2'd1: mux_address = cpu_address[13:7];
            2'd2: mux_address = {physical_v[1:0], physical_h_byte};
            2'd3: mux_address = {1'b0, physical_v[7:2]};
            default: mux_address = 7'bxxxxxxx;
        endcase
    end
    // 3E LS02 then 5B LS32. These are levels, not pulse/commit events.
    assign disable_level = hread_n & ~cpu_wr_rd_level;
    assign dram_cas_n = raw_cas_n | disable_level;
    assign dram_ras_n = raw_ras_n | disable_level;
    assign ststb = cpu_sync & ~phi1_ttl;
    assign ramstb_n = ~(cpu_address[14] & ststb);
    // First LS153: C0/C2/C3 high; C1 from 3F LS00.
    wire we_c1_n = ~(cpu_address[14] & ~cpu_wr_n);
    assign dram_we_n = mux_selector == 2'd1 ? we_c1_n : 1'b1;
    assign write_predicate = hread_n & ~comadr_n &
                            cpu_address[14] & ~cpu_wr_n;
endmodule
