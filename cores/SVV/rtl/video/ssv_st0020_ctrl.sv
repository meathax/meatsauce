// SPDX-License-Identifier: GPL-3.0-or-later
// ST0020 register/bank/blitter control plane used by GDFS.  Rendering and RAM
// storage remain outside this module so they can share the core SDRAM ports.
`timescale 1ns/1ps
module ssv_st0020_ctrl (
    input logic clk, input logic rst,
    input logic reg_we, input logic [6:0] reg_addr,
    input logic [15:0] reg_wdata, input logic [1:0] reg_be,
    output logic [15:0] reg_rdata, output logic [1:0] gfx_bank,
    output logic blit_start, output logic [31:0] blit_src,
    output logic [31:0] blit_dst, output logic [31:0] blit_len,
    output logic blit_valid
);
logic [15:0] regs [0:127];
logic [15:0] merged;
integer i;
always_comb begin
    merged = regs[reg_addr];
    if (reg_be[0]) merged[7:0] = reg_wdata[7:0];
    if (reg_be[1]) merged[15:8] = reg_wdata[15:8];
    reg_rdata = 16'h0000; // MAME-profile status/unknown register assumption
end
always_ff @(posedge clk) begin
    if (rst) begin
        gfx_bank<=0; blit_start<=0; blit_src<=0; blit_dst<=0;
        blit_len<=0; blit_valid<=0;
        for (i=0;i<128;i=i+1) regs[i]<=0;
    end else begin
        blit_start <= 1'b0;
        if (reg_we) begin
            regs[reg_addr] <= merged;
            if (reg_addr == 7'h45) gfx_bank <= merged[1:0]; // byte 0x8a
            if (reg_addr == 7'h65) begin // byte 0xca
                blit_src <= {regs[7'h61],regs[7'h60],1'b0};
                blit_dst <= {regs[7'h63],regs[7'h62],4'b0000};
                blit_len <= {regs[7'h64],4'b0000};
                blit_valid <= ({regs[7'h61],regs[7'h60],1'b0} +
                               {12'd0,regs[7'h64],4'b0} <= 32'h01000000) &&
                              ({regs[7'h63],regs[7'h62],4'b0} +
                               {12'd0,regs[7'h64],4'b0} <= 32'h00400000);
                blit_start <= 1'b1;
            end
        end
    end
end
endmodule
