// SPDX-License-Identifier: GPL-3.0-or-later
// Spinal Breakers sound I/O decode and separate-acknowledge command latch.
module spinal_sound_control (
    input  logic       clk,
    input  logic       reset,
    input  logic       command_write,
    input  logic [7:0] command_data,
    input  logic [15:0] z80_address,
    input  logic [7:0] z80_data_out,
    input  logic       iorq_n, m1_n, rd_n, wr_n,
    input  logic [7:0] ym_data,
    input  logic       ym_irq_n,
    output logic [7:0] io_data,
    output logic       ym_cs_n,
    output logic       nmi_n,
    output logic       int_n,
    output logic [1:0] bank,
    output logic       rom_banked,
    output logic [16:0] rom_address
);
    logic [7:0] latch_data = 8'h00;
    logic pending;
    logic io_write_seen;
    wire io_cycle = !iorq_n && m1_n;
    wire io_write = io_cycle && !wr_n;

    assign ym_cs_n = !(io_cycle && z80_address[7:2] == 6'h06);
    assign nmi_n = !pending;
    assign int_n = ym_irq_n;
    assign rom_banked = z80_address[15];
    assign rom_address = {z80_address[15] ? bank : 2'b00, z80_address[14:0]};

    always_comb begin
        io_data = 8'hff;
        if (io_cycle && !rd_n) begin
            if (z80_address[7:0] == 8'h14) io_data = latch_data;
            else if (!ym_cs_n) io_data = ym_data;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pending <= 1'b0;
            bank <= 2'b00;
            io_write_seen <= 1'b0;
        end else begin
            if (!io_write) io_write_seen <= 1'b0;
            else io_write_seen <= 1'b1;

            if (io_write && !io_write_seen && z80_address[7:0] == 8'h00)
                bank <= z80_data_out[1:0];
            if (command_write) begin
                latch_data <= command_data;
                pending <= 1'b1;
            end else if (io_write && !io_write_seen && z80_address[7:0] == 8'h14)
                pending <= 1'b0;
        end
    end
endmodule
