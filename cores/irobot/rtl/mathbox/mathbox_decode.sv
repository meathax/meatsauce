`timescale 1ns/1ps
// SPDX-License-Identifier: BSD-3-Clause
// Semantic decode of the thirteen dumped 1Kx4 control PROMs. Field placement
// follows MAME 0.289 irobot_m.cpp load_oproms(); hardware timing remains owned
// by the corrected Atari drawings.
module mathbox_decode (
	input  logic [51:0] planes,
	output logic [3:0] areg,
	output logic [3:0] breg,
	output logic [9:0] function_code,
	output logic [9:0] next_address,
	output logic [7:0] direct_address,
	output logic [15:0] latch_mask,
	output logic [7:0] flags,
	output logic [1:0] ram_select,
	output logic [2:0] jump_type,
	output logic [2:0] operation_cycles,
	output logic direct_enable,
	output logic done
);
	logic [3:0] p[0:12];
	logic [7:0] direct_raw,direct_mask;
	always_comb begin
		for(integer n=0;n<13;n=n+1) p[n]=planes[n*4+:4];
		areg=p[0]; breg=p[1];
		function_code={1'b0,p[2],p[3],p[4][3]};
		flags={p[11][3],p[11][0],p[10],p[9][0],p[4][2]};
		next_address={p[6],p[7],p[5][3:2]};
		ram_select=p[11][2:1];
		jump_type=p[9][3:1];
		direct_raw={p[12][1:0],p[8],p[5][1:0]};
		direct_enable=(ram_select==0);
		if(ram_select==0) begin direct_mask=8'hff; latch_mask=16'h3000; end
		else begin direct_mask=8'h00; latch_mask=16'h3ffc; end
		if(ram_select[1]) latch_mask|=16'h0003; else direct_mask|=8'h03;
		direct_address=direct_raw&direct_mask;
		operation_cycles=(p[4][1:0]==3)?3'd2:3'(3+p[4][1:0]);
		done=(p[10][3:2]==2'b11);
		if(p[9][0]) function_code[9]=1'b1;
	end
endmodule
