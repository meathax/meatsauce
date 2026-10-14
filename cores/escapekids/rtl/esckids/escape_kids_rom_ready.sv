`timescale 1ns/1ps

module escape_kids_rom_ready(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,
    input  wire        rom_cs,
    input  wire [18:0] rom_addr,
    input  wire        rom_ok,
    output wire        cpu_rom_ok
);

reg        rom_cs_q;
reg        addr_valid;
reg        wait_fresh;
reg [18:0] last_addr_q;

wire new_addr_reentry = rom_cs && !rom_cs_q && addr_valid &&
                        rom_addr != last_addr_q;

always @(posedge clk) begin
    if (rst || !enable) begin
        rom_cs_q   <= 1'b0;
        addr_valid <= 1'b0;
        wait_fresh <= 1'b0;
        last_addr_q <= 19'd0;
    end else begin
        rom_cs_q <= rom_cs;
        if (new_addr_reentry && rom_ok)
            wait_fresh <= 1'b1;
        else if (wait_fresh && !rom_ok)
            wait_fresh <= 1'b0;
        if (rom_cs && cpu_rom_ok) begin
            addr_valid <= 1'b1;
            last_addr_q <= rom_addr;
        end
    end
end

assign cpu_rom_ok = enable ? (rom_ok & !new_addr_reentry & !wait_fresh) : rom_ok;

endmodule
