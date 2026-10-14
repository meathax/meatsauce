`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Clean-room AM2901-compatible four-bit datapath, organized by the AMD 2900
// family data book's source, function and destination fields.
module am2901_slice (
	input  logic       clk,
	input  logic       ce,
	input  logic [8:0] instruction,
	input  logic [3:0] a_addr,
	input  logic [3:0] b_addr,
	input  logic [3:0] d,
	input  logic       carry_in,
	input  logic       ram0_in,
	input  logic       ram3_in,
	input  logic       q0_in,
	input  logic       q3_in,
	output logic [3:0] y,
	output logic       carry_out,
	output logic       overflow,
	output logic       zero,
	output logic       negative,
	output logic       ram0_out,
	output logic       ram3_out,
	output logic       q0_out,
	output logic       q3_out
);
	logic [3:0] ram [0:15];
	logic [3:0] q, r, s, f;
	logic [4:0] wide;
	logic [3:0] a, b;
	logic [2:0] src, fn, dst;

	assign src = instruction[2:0];
	assign fn  = instruction[5:3];
	assign dst = instruction[8:6];
	assign a = ram[a_addr];
	assign b = ram[b_addr];
	always_comb begin
		case (src)
			3'd0: begin r = a;    s = q;    end
			3'd1: begin r = a;    s = b;    end
			// Source code 2 is the inhibited R input plus Q (0,Q), as used by
			// the AM2901 matrix and MAME's 0x02 ADD(0,Q) decode.
			3'd2: begin r = 0;    s = q;    end
			3'd3: begin r = 0;    s = b;    end
			3'd4: begin r = 0;    s = a;    end
			3'd5: begin r = d;    s = a;    end
			3'd6: begin r = d;    s = q;    end
			default: begin r = d; s = 0;    end
		endcase
		wide = 0;
		case (fn)
			3'd0: begin wide = {1'b0,r}+{1'b0,s}+carry_in; f=wide[3:0]; end
			3'd1: begin wide = {1'b0,s}+{1'b0,~r}+carry_in; f=wide[3:0]; end
			3'd2: begin wide = {1'b0,r}+{1'b0,~s}+carry_in; f=wide[3:0]; end
			3'd3: begin f = r | s;  wide={1'b0,f}; end
			3'd4: begin f = r & s;  wide={1'b0,f}; end
			3'd5: begin f = ~r & s; wide={1'b0,f}; end
			3'd6: begin f = r ^ s;  wide={1'b0,f}; end
			default: begin f = ~(r ^ s); wide={1'b0,f}; end
		endcase
		case (dst)
			3'd0: y = f;
			3'd1: y = f;
			3'd2: y = a;
			3'd3: y = f;
			3'd4: y = f;
			3'd5: y = f;
			3'd6: y = f;
			default: y = f;
		endcase
	end
	assign carry_out = wide[4];
	always_comb begin
		case(fn)
			3'd0: overflow = (r[3] == s[3]) && (f[3] != r[3]);
			3'd1: overflow = (s[3] != r[3]) && (f[3] != s[3]);
			3'd2: overflow = (r[3] != s[3]) && (f[3] != r[3]);
			default: overflow = 1'b0;
		endcase
	end
	assign zero = (f == 0);
	assign negative = f[3];
	assign ram0_out = f[0]; assign ram3_out = f[3];
	assign q0_out = q[0]; assign q3_out = q[3];
	always_ff @(posedge clk) if (ce) begin
		case (dst)
			3'd0: q <= f;
			3'd1: ;
			3'd2: ram[b_addr] <= f;
			3'd3: ram[b_addr] <= f;
			3'd4: begin ram[b_addr] <= {ram3_in,f[3:1]}; q <= {q3_in,q[3:1]}; end
			3'd5: ram[b_addr] <= {ram3_in,f[3:1]};
			3'd6: begin ram[b_addr] <= {f[2:0],ram0_in}; q <= {q[2:0],q0_in}; end
			3'd7: ram[b_addr] <= {f[2:0],ram0_in};
			default: ;
		endcase
	end
endmodule
