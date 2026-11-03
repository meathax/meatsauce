// SPDX-License-Identifier: GPL-3.0-or-later
// Raw logical stream -> packed logical storage. Addresses are 16-bit words.
// This is NOT a physical SDRAM bank/clock/latency assignment.
module hangzo_rom_map #(parameter SCHMEISER_SUPPORTED=0)(
    input wire game_id,
    input wire [23:1] download_word_address,
    output reg [23:0] download_storage_address,
    input wire [19:1] main_address,
    output wire [23:0] main_storage_address,
    input wire [15:0] main_storage_data,
    output wire [15:0] main_data,
    input wire [15:0] program_address,
    output wire [23:0] program_storage_address,
    output wire program_byte,
    input wire [18:0] oki1_address,oki2_address,
    output wire [23:0] oki1_storage_address,oki2_storage_address,
    output wire oki1_byte,oki2_byte,
    input wire [3:0] tile16,
    input wire [18:0] tile_address0,tile_address1,tile_address2,tile_address3,
    output wire [23:0] tile_storage_address0,tile_storage_address1,tile_storage_address2,tile_storage_address3,
    input wire [20:0] sprite_address,
    output wire [23:0] sprite_storage_address
);
    // Convert a bus labelled [23:1] to a zero-based word index before slicing.
    wire [22:0] raw_word=download_word_address;
    always_comb begin
        download_storage_address={1'b0,raw_word};
        if(raw_word>=23'h200000 && raw_word<23'h220000)
            download_storage_address=24'h200000+{7'd0,raw_word[15:0],raw_word[16]};
        else if(raw_word>=23'h280000 && raw_word<23'h300000)
            download_storage_address=24'h280000+{5'd0,raw_word[17:0],raw_word[18]};
        else if(raw_word>=23'h300000 && raw_word<23'h400000)
            download_storage_address=24'h300000+{4'd0,raw_word[18:0],raw_word[19]};
        else if(raw_word>=23'h400000 && raw_word<23'h600000)
            download_storage_address=24'h400000+{3'd0,raw_word[19:0],raw_word[20]};
    end
    assign main_storage_address={5'd0,main_address};
    // Raw MAME maincpu bytes are big endian; storage uses low-even/high-odd.
    assign main_data={main_storage_data[7:0],main_storage_data[15:8]};
    assign program_storage_address=24'h080000+{9'd0,program_address[15:1]};
    assign program_byte=program_address[0];
    // Native modulo bank count: Hangzo256KiB=1 bank, Schmeiser512KiB=2.
    // Parameter default preserves unconnected legacy callers' Hangzo alias.
    assign oki1_storage_address=24'h100000+
        {6'd0,(SCHMEISER_SUPPORTED && game_id ? oki1_address[18] : 1'b0),oki1_address[17:1]};
    assign oki2_storage_address=24'h180000+{6'd0,oki2_address[18:1]};
    assign oki1_byte=oki1_address[0],oki2_byte=oki2_address[0];
    function [23:0] tile_word;
        input [18:0] address;
        input large_tile,second_chip;
        begin
            if(!large_tile)tile_word=24'h200000+{7'd0,address[15:0],1'b0};
            else if(!second_chip)tile_word=24'h280000+{5'd0,address[17:0],1'b0};
            else tile_word=24'h300000+{4'd0,address[18:0],1'b0};
        end
    endfunction
    assign tile_storage_address0=tile_word(tile_address0,tile16[0],1'b0);
    assign tile_storage_address1=tile_word(tile_address1,tile16[1],1'b0);
    assign tile_storage_address2=tile_word(tile_address2,tile16[2],1'b1);
    assign tile_storage_address3=tile_word(tile_address3,tile16[3],1'b1);
    assign sprite_storage_address=24'h400000+{3'd0,sprite_address[19:0],1'b0};
endmodule
