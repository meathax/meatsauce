// SPDX-License-Identifier: GPL-3.0-or-later
// Byte interface for standard MiSTer Hiscore and the donor's 16-bit work RAM.
module arblst_hiscore_ram(
    input clk, rst, game_id, grant,
    input [23:0] address,
    input [7:0] data_to_ram,
    input write,
    output [7:0] data_from_ram,
    output [15:1] ram_address,
    output [15:0] ram_data,
    output [1:0] ram_we,
    input [15:0] ram_q
);
wire valid = game_id ? (address>=24'hf018cd && address<=24'hf01957) :
                      (address>=24'hf014e6 && address<=24'hf01571);
reg odd_q, valid_q;
always @(posedge clk) begin
    if(rst) begin odd_q<=0;valid_q<=0;end
    else begin odd_q<=address[0];valid_q<=grant && valid;end
end
assign ram_address=address[15:1];
assign ram_data={data_to_ram,data_to_ram};
assign ram_we=(!rst && grant && valid && write) ? (address[0] ? 2'b01 : 2'b10) : 2'b00;
// The lane tag and synchronous RAM output refer to the same sampled address.
assign data_from_ram=valid_q ? (odd_q ? ram_q[7:0] : ram_q[15:8]) : 8'hff;
endmodule
