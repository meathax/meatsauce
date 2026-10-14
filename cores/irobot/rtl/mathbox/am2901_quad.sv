`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Four cascaded AM2901 slices forming the board's 16-bit datapath. Carry and
// RAM/Q shift pins are chained exactly across nibble boundaries.
module am2901_quad (
	input logic clk,
	input logic ce,
	input logic [9:0] function_code,
	input logic [3:0] a_addr,
	input logic [3:0] b_addr,
	input logic [15:0] d,
	input logic carry_in,
	input logic flag_carry_insert,
	output logic [15:0] y,
	output logic carry_out,
	output logic overflow,
	output logic zero,
	output logic negative,
	output logic q_lsb,
	output logic q_msb,
	output logic [3:0] slice_overflow,
	output logic [3:0] slice_negative,
	output logic ram_msb
);
	logic [3:0] sy[0:3]; logic [4:0] carry;
	logic [3:0] ov,z,n,ram0,ram3,q0,q3;
	logic [3:0] ram0_in,ram3_in,q0_in,q3_in;
	logic shift;
	assign shift=function_code[9];
	assign carry[0]=carry_in;
	assign ram3_in[0]=ram0[1]; assign ram3_in[1]=ram0[2]; assign ram3_in[2]=ram0[3];
	assign q3_in[0]=q0[1]; assign q3_in[1]=q0[2]; assign q3_in[2]=q0[3];
	assign ram3_in[3]=shift?(negative^overflow):flag_carry_insert;
	assign q3_in[3]=shift?ram0[0]:flag_carry_insert;
	assign ram0_in[3]=ram3[2]; assign ram0_in[2]=ram3[1]; assign ram0_in[1]=ram3[0];
	assign q0_in[3]=q3[2]; assign q0_in[2]=q3[1]; assign q0_in[1]=q3[0];
	assign ram0_in[0]=shift?q3[3]:1'b0;
	assign q0_in[0]=shift?1'b0:~negative;
	genvar i;
	generate for(i=0;i<4;i=i+1) begin:slice
		am2901_slice u(.clk(clk),.ce(ce),.instruction(function_code[8:0]),
			.a_addr(a_addr),.b_addr(b_addr),.d(d[i*4+:4]),.carry_in(carry[i]),
			.ram0_in(ram0_in[i]),.ram3_in(ram3_in[i]),.q0_in(q0_in[i]),.q3_in(q3_in[i]),
			.y(sy[i]),.carry_out(carry[i+1]),.overflow(ov[i]),.zero(z[i]),.negative(n[i]),
			.ram0_out(ram0[i]),.ram3_out(ram3[i]),.q0_out(q0[i]),.q3_out(q3[i]));
	end endgenerate
	assign y={sy[3],sy[2],sy[1],sy[0]};
	assign carry_out=carry[4]; assign overflow=ov[3]; assign zero=&z; assign negative=n[3];
	assign q_lsb=q0[0]; assign q_msb=q3[3];
	assign slice_overflow=ov; assign slice_negative=n; assign ram_msb=ram3[3];
endmodule
