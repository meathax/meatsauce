// SPDX-License-Identifier: GPL-3.0-or-later
// Crystal cartridge's first-word command/query interface. Pinned MAME
// crystal.cpp flashcmd_r/w: FF reads the banked ROM; 90 reports Intel 128Mbit
// for present banks; other commands read zero. Normal ROM reads remain external.
// This does not implement unreferenced NOR erase/program operations or timing.
module cs_flash_cmd (
    input logic clk, reset,
    input logic [3:0] cart_banks, // populated chips (MRA board record); 0 = legacy 3
    input logic [2:0] flash_bank,
    input logic reg_valid, output logic reg_ready,
    input logic reg_write, input logic [31:0] reg_data,
    output logic reg_rsp_valid, output logic [31:0] reg_rsp_data,
    output logic read_override, output logic [31:0] command
);
    wire [3:0] present_banks = cart_banks == 0 ? 4'd3 : cart_banks;
    assign reg_ready = 1;
    assign read_override = command[7:0] != 8'hff;
    always_ff @(posedge clk) begin
        if (reset) begin command <= 32'hff; reg_rsp_valid <= 0; reg_rsp_data <= 0; end
        else begin
            reg_rsp_valid <= reg_valid;
            if (reg_valid) begin
                reg_rsp_data <= command[7:0] == 8'h90 ?
                    ({1'b0,flash_bank} < present_banks ? 32'h00180089 : 32'hffffffff) : 32'b0;
                // The pinned 32-bit MAME handler replaces data without COMBINE_DATA.
                // Bus-access lane positioning is retained before this endpoint.
                if (reg_write) command <= reg_data;
            end
        end
    end
endmodule
