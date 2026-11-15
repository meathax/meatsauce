// SPDX-License-Identifier: GPL-3.0-or-later
// Two held-CS ROM clients share one JTFRAME read slot. A completed request
// retains its response until its owner drops CS; every external request has
// a full CS gap before a different address/owner can be selected.
module gaiapolis_rom_arb #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer DATA_WIDTH = 32
)(
    input logic clk, rst,
    input logic a_cs,
    input logic [ADDR_WIDTH-1:0] a_addr,
    output logic [DATA_WIDTH-1:0] a_data,
    output logic a_ok,
    input logic b_cs,
    input logic [ADDR_WIDTH-1:0] b_addr,
    output logic [DATA_WIDTH-1:0] b_data,
    output logic b_ok,
    output logic rom_cs,
    output logic [ADDR_WIDTH-1:0] rom_addr,
    input logic [DATA_WIDTH-1:0] rom_data,
    input logic rom_ok
);
    typedef enum logic [1:0] { IDLE, WAIT_ROM, RESPONSE } phase_t;
    phase_t phase;
    logic owner_b;
    logic [DATA_WIDTH-1:0] response;

    always_comb begin
        rom_cs = !rst && phase == WAIT_ROM;
        a_ok = !rst && !owner_b &&
            (phase == RESPONSE || (phase == WAIT_ROM && rom_ok));
        b_ok = !rst && owner_b &&
            (phase == RESPONSE || (phase == WAIT_ROM && rom_ok));
        a_data = phase == RESPONSE ? response : rom_data;
        b_data = phase == RESPONSE ? response : rom_data;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            phase <= IDLE;
            owner_b <= 1'b0;
            rom_addr <= '0;
            response <= '0;
        end else begin
            case (phase)
                IDLE: begin
                    if (a_cs || b_cs) begin
                        owner_b <= !a_cs;
                        rom_addr <= a_cs ? a_addr : b_addr;
                        phase <= WAIT_ROM;
                    end
                end
                WAIT_ROM: if (rom_ok) begin
                    response <= rom_data;
                    phase <= RESPONSE;
                end
                RESPONSE: if (owner_b ? !b_cs : !a_cs)
                    phase <= IDLE;
                default: phase <= IDLE;
            endcase
        end
    end
endmodule
