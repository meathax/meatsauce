// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from NightSlashers_MiSTer, RTL port Umberto Parisi (rmonic79).
// Original algorithm: MAME (BSD-3-Clause). See PROVENANCE.md.
module deco156_word(
    input wire [16:0] physical_word_addr,
    input wire [31:0] raw_data,
    output wire [16:0] logical_word_addr,
    output wire [31:0] decrypted_data
);
    wire [15:0] x = physical_word_addr[15:0] ^ 16'h92c6;
	wire [15:0] a_lo =
		({16{x[ 0]}} & 16'hde2f) ^ ({16{x[ 1]}} & 16'h23ea) ^
		({16{x[ 2]}} & 16'h18f5) ^ ({16{x[ 3]}} & 16'h6c0f) ^
		({16{x[ 4]}} & 16'hbe7e) ^ ({16{x[ 5]}} & 16'h8f70) ^
		({16{x[ 6]}} & 16'h800e) ^ ({16{x[ 7]}} & 16'haffc) ^
		({16{x[ 8]}} & 16'hb3f1) ^ ({16{x[ 9]}} & 16'h9e07) ^
		({16{x[10]}} & 16'h0091) ^ ({16{x[11]}} & 16'h3fbb) ^
		({16{x[12]}} & 16'hc890) ^ ({16{x[13]}} & 16'h7361) ^
		({16{x[14]}} & 16'h31c1) ^ ({16{x[15]}} & 16'h5f06);
	function [31:0] bswap0(input [31:0] d);
		bswap0 = {d[1],d[4],d[7],d[28],d[22],d[18],d[20],d[9],d[16],d[10],d[30],d[2],d[31],d[24],d[19],d[29],d[6],d[21],d[23],d[11],d[12],d[13],d[5],d[0],d[8],d[26],d[27],d[15],d[14],d[17],d[25],d[3]};
	endfunction
	function [31:0] bswap1(input [31:0] d);
		bswap1 = {d[14],d[23],d[28],d[29],d[6],d[24],d[10],d[1],d[5],d[16],d[7],d[2],d[30],d[8],d[18],d[3],d[31],d[22],d[25],d[20],d[17],d[0],d[19],d[27],d[9],d[12],d[21],d[15],d[26],d[13],d[4],d[11]};
	endfunction
	function [31:0] bswap2(input [31:0] d);
		bswap2 = {d[19],d[30],d[21],d[4],d[2],d[18],d[15],d[1],d[12],d[25],d[8],d[0],d[24],d[20],d[17],d[23],d[22],d[26],d[28],d[16],d[9],d[27],d[6],d[11],d[31],d[10],d[3],d[13],d[14],d[7],d[29],d[5]};
	endfunction
	function [31:0] bswap3(input [31:0] d);
		bswap3 = {d[30],d[6],d[15],d[0],d[31],d[18],d[26],d[22],d[14],d[23],d[19],d[17],d[10],d[8],d[11],d[20],d[1],d[28],d[2],d[4],d[9],d[24],d[25],d[27],d[7],d[21],d[13],d[29],d[5],d[3],d[16],d[12]};
	endfunction
	function [31:0] data_decrypt(input [31:0] dword, input [17:0] aa);
		reg [31:0] v;
		begin
			v = dword;
			if (aa & 18'h00004) v = v ^ 32'h04400000;
			if (aa & 18'h00008) v = v ^ 32'h40000004;
			if (aa & 18'h00010) v = v ^ 32'h00048000;
			if (aa & 18'h00020) v = v ^ 32'h00000280;
			if (aa & 18'h00040) v = v ^ 32'h00200040;
			if (aa & 18'h00080) v = v ^ 32'h09000000;
			if (aa & 18'h00100) v = v ^ 32'h00001100;
			if (aa & 18'h00200) v = v ^ 32'h20002000;
			if (aa & 18'h00400) v = v ^ 32'h00000022;
			if (aa & 18'h00800) v = v ^ 32'h000a0000;
			if (aa & 18'h01000) v = v ^ 32'h10004000;
			if (aa & 18'h02000) v = v ^ 32'h00010400;
			if (aa & 18'h04000) v = v ^ 32'h80000010;
			if (aa & 18'h08000) v = v ^ 32'h00000009;
			if (aa & 18'h10000) v = v ^ 32'h02100000;
			if (aa & 18'h20000) v = v ^ 32'h00800800;
			case (aa[1:0])
				2'd0: data_decrypt = bswap0(v ^ 32'hec63197a);
				2'd1: data_decrypt = bswap1(v ^ 32'h58a5a55f);
				2'd2: data_decrypt = bswap2(v ^ 32'he3a65f16);
				2'd3: data_decrypt = bswap3(v ^ 32'h28d93783);
			endcase
		end
	endfunction
    assign logical_word_addr = {physical_word_addr[16],a_lo};
    assign decrypted_data = data_decrypt(raw_data,{1'b0,logical_word_addr});
endmodule
