// SPDX-License-Identifier: GPL-3.0-or-later
// One byte bank of the shared battery SRAM. One synchronous address/read/write
// port, no memory reset or unrolled initializer; cold clear is a real bus write.
module cs_nvram_port (
    input logic clk, enable, write_enable,
    input logic [13:0] address,
    input logic [7:0] write_data,
    output logic [7:0] read_data
);
    (* ramstyle = "M10K" *) logic [7:0] memory [0:16383];
    always_ff @(posedge clk) begin
        if(enable) begin
            if(write_enable) memory[address]<=write_data;
            read_data<=memory[address];
        end
    end
endmodule
