// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from NightSlashers_MiSTer, RTL port Umberto Parisi (rmonic79).
// Original algorithm: MAME (BSD-3-Clause). See PROVENANCE.md.
module deco56_word #(
    parameter TABLE_DIR = "rtl/vendor/deco_crypto",
    parameter MCF_QUARTER_SWAP = 1
)(
    input wire [19:0] physical_word_addr,
    input wire [15:0] raw_data,
    output wire [19:0] logical_word_addr,
    output wire [15:0] decrypted_data
);
    reg [10:0] inverse_address [0:2047];
    reg [3:0] xor_table [0:2047];
    reg [2:0] swap_of_p [0:2047];
    initial begin
        $readmemh({TABLE_DIR,"/deco56_inv_address_table.hex"},inverse_address);
        $readmemh({TABLE_DIR,"/deco56_xor_table.hex"},xor_table);
        $readmemh({TABLE_DIR,"/deco56_swap_of_p.hex"},swap_of_p);
    end
	function [15:0] xor_mask(input [3:0] idx);
		case (idx)
			4'h0: xor_mask = 16'hd556; 4'h1: xor_mask = 16'h73cb;
			4'h2: xor_mask = 16'h2963; 4'h3: xor_mask = 16'h4b9a;
			4'h4: xor_mask = 16'hb3bc; 4'h5: xor_mask = 16'hbc73;
			4'h6: xor_mask = 16'hcbc9; 4'h7: xor_mask = 16'haeb5;
			4'h8: xor_mask = 16'h1e6d; 4'h9: xor_mask = 16'hd5b5;
			4'ha: xor_mask = 16'he676; 4'hb: xor_mask = 16'h5cc5;
			4'hc: xor_mask = 16'h395a; 4'hd: xor_mask = 16'hdaae;
			4'he: xor_mask = 16'h2629; 4'hf: xor_mask = 16'he59e;
		endcase
	endfunction
	function [15:0] bitswap_apply(input [2:0] pat_idx, input [15:0] d);
		case (pat_idx)
			3'd0: bitswap_apply = {d[15],d[ 8],d[ 9],d[12],d[10],d[13],d[11],d[14], d[ 2],d[ 7],d[ 4],d[ 3],d[ 1],d[ 5],d[ 6],d[ 0]};
			3'd1: bitswap_apply = {d[12],d[10],d[11],d[ 9],d[ 8],d[15],d[14],d[13], d[ 6],d[ 0],d[ 3],d[ 5],d[ 7],d[ 4],d[ 2],d[ 1]};
			3'd2: bitswap_apply = {d[ 8],d[12],d[11],d[ 9],d[13],d[14],d[15],d[10], d[ 4],d[ 6],d[ 5],d[ 0],d[ 3],d[ 1],d[ 7],d[ 2]};
			3'd3: bitswap_apply = {d[ 8],d[ 9],d[10],d[13],d[11],d[15],d[14],d[12], d[ 5],d[ 4],d[ 0],d[ 7],d[ 2],d[ 6],d[ 1],d[ 3]};
			3'd4: bitswap_apply = {d[12],d[13],d[14],d[15],d[ 8],d[ 9],d[10],d[11], d[ 1],d[ 5],d[ 0],d[ 3],d[ 2],d[ 7],d[ 6],d[ 4]};
			3'd5: bitswap_apply = {d[14],d[15],d[13],d[ 8],d[12],d[10],d[11],d[ 9], d[ 1],d[ 2],d[ 7],d[ 6],d[ 4],d[ 3],d[ 0],d[ 5]};
			3'd6: bitswap_apply = {d[13],d[14],d[10],d[11],d[ 9],d[ 8],d[12],d[15], d[ 3],d[ 1],d[ 7],d[ 4],d[ 5],d[ 0],d[ 2],d[ 6]};
			3'd7: bitswap_apply = {d[ 9],d[ 8],d[14],d[10],d[15],d[11],d[13],d[12], d[ 6],d[ 0],d[ 5],d[ 2],d[ 4],d[ 1],d[ 3],d[ 7]};
		endcase
	endfunction
    wire [10:0] p = physical_word_addr[10:0];
    wire [15:0] decoded = bitswap_apply(swap_of_p[p],
        {raw_data[7:0],raw_data[15:8]} ^ xor_mask(xor_table[p]));
    // MCF00's raw quarter order maps to 0,2,1,3; the block-local transform
    // is independent of that swap. Store bytes in MAME's post-init order.
    assign logical_word_addr = MCF_QUARTER_SWAP ?
        {physical_word_addr[18],physical_word_addr[19],physical_word_addr[17:11],inverse_address[p]} :
        {physical_word_addr[19:11],inverse_address[p]};
    assign decrypted_data = {decoded[7:0],decoded[15:8]};
endmodule
