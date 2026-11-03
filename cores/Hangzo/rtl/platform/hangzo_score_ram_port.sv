// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-side adapter for the otherwise unused registered work-RAM port.
// The caller must hold the CPU paused through acknowledgement/request release.
module hangzo_score_ram_port #(
    parameter integer BYTE_AW = 14,
    parameter [BYTE_AW-1:0] TABLE_FIRST = 'h003a,
    parameter [BYTE_AW-1:0] TABLE_LAST = 'h00c5
) (
    input wire clk, reset, paused,
    input wire request, write,
    input wire [BYTE_AW-1:0] byte_address,
    input wire [7:0] write_data,
    output reg acknowledge,
    output reg [7:0] read_data,
    output reg fault,
    output wire [BYTE_AW-2:0] ram_address,
    output wire [15:0] ram_data,
    output wire [1:0] ram_we,
    input wire [15:0] ram_q
);
    localparam IDLE=2'd0, ACCESS=2'd1, REPLY=2'd2, RELEASE=2'd3;
    reg [1:0] state;
    reg [BYTE_AW-1:0] held_address;
    reg [7:0] held_data;
    reg held_write;
    wire in_range = byte_address >= TABLE_FIRST && byte_address <= TABLE_LAST;
    assign ram_address = held_address[BYTE_AW-1:1];
    assign ram_data = {held_data,held_data};
    // ACCESS starts only after the address has been registered. The write is
    // committed once on its closing edge; registered q is sampled in REPLY.
    assign ram_we = !reset && paused && state==ACCESS && held_write ?
                    (held_address[0] ? 2'b01 : 2'b10) : 2'b00;
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE; acknowledge<=0; read_data<=0; fault<=0;
            held_address<=0; held_data<=0; held_write<=0;
        end else begin
            case(state)
                IDLE: if(request && paused) begin
                    if(!in_range) begin
                        fault<=1; state<=RELEASE;
                    end else begin
                        held_address<=byte_address; held_data<=write_data;
                        held_write<=write; state<=ACCESS;
                    end
                end
                ACCESS: if(paused) state<=REPLY;
                REPLY: if(paused) begin
                    read_data<=held_address[0] ? ram_q[7:0] : ram_q[15:8];
                    acknowledge<=1; state<=RELEASE;
                end
                RELEASE: if(!request) begin
                    acknowledge<=0; state<=IDLE;
                end
                default: begin state<=IDLE; acknowledge<=0; fault<=1; end
            endcase
        end
    end
endmodule
