// SPDX-License-Identifier: GPL-3.0-or-later
// MRA board record (ioctl index 1, 16 bytes), the same format as the BrezzaSoft_Crystal_System_MiSTer core:
//   0-3 "CRYS", 4 version (1), 5 game id, 6 populated flash banks (1-8), 7-15 reserved.
// Game ids: 0 generic, 1 crysking, 2 evosocc, 3 topbladv, 4 officeye, 5 urachamu.
// Like the DIP switches it is owned by the download, not by a game reset. Without a valid record
// (older MRAs) the board is the three-bank crysking/evosocc cartridge with the standard inputs.
module cs_board_config (
    input logic clk,
    input logic ioctl_wr,
    input logic [15:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [7:0] ioctl_dout,
    output logic [7:0] game_id = 8'd0,
    output logic [3:0] cart_banks = 4'd3
);
    logic [31:0] magic = 0;
    logic [7:0] id_byte = 0, bank_byte = 0;
    always_ff @(posedge clk) begin
        if (ioctl_wr && ioctl_index == 16'd1) begin
            case (ioctl_addr)
                27'd0: magic[7:0]   <= ioctl_dout;
                27'd1: magic[15:8]  <= ioctl_dout;
                27'd2: magic[23:16] <= ioctl_dout;
                27'd3: magic[31:24] <= ioctl_dout;
                27'd5: id_byte <= ioctl_dout;
                27'd6: bank_byte <= ioctl_dout;
                27'd15: if (magic == 32'h53595243 && bank_byte >= 8'd1 && bank_byte <= 8'd8) begin // "CRYS"
                    game_id <= id_byte;
                    cart_banks <= bank_byte[3:0];
                end
                default: ;
            endcase
        end
    end
endmodule
