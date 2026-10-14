// SPDX-License-Identifier: GPL-3.0-or-later
// Keep HPS transfers in byte mode for DIPs/hiscore; assemble little-endian ROMs.
module ZeroTeam_download (
    input wire clk,reset,download,wr,
    input wire [15:0] index,
    input wire [26:0] address,
    input wire [7:0] data,
    input wire memory_wait,
    output wire wait_hps,
    output reg word_wr,
    output reg [26:0] word_address,
    output reg [15:0] word_data
);
    reg [7:0] low_byte;
    reg [26:0] low_address;
    reg have_low;
    assign wait_hps = index==0 && (word_wr || memory_wait);
    always @(posedge clk) begin
        word_wr<=0;
        if(reset || !download || index!=0) have_low<=0;
        else if(wr) begin
            if(!address[0]) begin
                low_byte<=data; low_address<=address; have_low<=1;
            end else if(have_low && address==low_address+27'd1) begin
                word_address<=low_address;
                word_data<={data,low_byte}; word_wr<=1; have_low<=0;
            end
        end
    end
endmodule
