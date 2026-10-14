// SPDX-License-Identifier: GPL-3.0-or-later
module quad_pokey (
	input logic clk, input logic reset, input logic ena, input logic cs, input logic rw,
	input logic [5:0] addr, input logic [7:0] din,
	input logic [7:0] pin0, pin1, pin2, pin3,
	input logic [7:0] allpot0,
	output logic [7:0] dout, output logic [9:0] audio,
	// The four AUD pins are strapped together on the board (SP-251 sheet 4A).
	// They are also brought out individually so irobot_audio_mix can model the
	// C9/R19 and C8/R24 analog stage; `audio` remains the plain 1:1:1:1 sum.
	output logic [7:0] ch0, ch1, ch2, ch3
);
	wire [7:0] d0,d1,d2,d3,a0,a1,a2,a3;
	// MAME quad_pokeyn_r/w wiring: chip=(offset>>3)&~0x04,
	// control=(offset&0x20)>>2, local register=(offset&7)|control.
	wire [2:0] pokey_num = addr[5:3] & 3'b011;
	wire [3:0] pokey_reg = {addr[5],addr[2:0]};
	pokey_sv p0(.reset(reset),.addr(pokey_reg),.din(din),.dout(d0),.rw_l(rw),.cs(cs),.cs_l(~(cs&&pokey_num==3'd0)),.audio_out(a0),.pin(pin0),.ena(ena),.clk(clk));
	pokey_sv p1(.reset(reset),.addr(pokey_reg),.din(din),.dout(d1),.rw_l(rw),.cs(cs),.cs_l(~(cs&&pokey_num==3'd1)),.audio_out(a1),.pin(pin1),.ena(ena),.clk(clk));
	pokey_sv p2(.reset(reset),.addr(pokey_reg),.din(din),.dout(d2),.rw_l(rw),.cs(cs),.cs_l(~(cs&&pokey_num==3'd2)),.audio_out(a2),.pin(pin2),.ena(ena),.clk(clk));
	pokey_sv p3(.reset(reset),.addr(pokey_reg),.din(din),.dout(d3),.rw_l(rw),.cs(cs),.cs_l(~(cs&&pokey_num==3'd3)),.audio_out(a3),.pin(pin3),.ena(ena),.clk(clk));
	assign ch0=a0; assign ch1=a1; assign ch2=a2; assign ch3=a3;
	always_comb begin
		case(pokey_num) 0:dout=d0; 1:dout=d1; 2:dout=d2; default:dout=d3; endcase
		// On I, Robot the second DIP bank is hard-wired to POKEY 0's
		// ALLPOT pins (MAME's DSW2 callback).  The generic POKEY model's
		// capacitor-scan result is intentionally not used for this board-level
		// input: software reads the physical switch byte at offset $20/$28.
		if (cs && rw && pokey_num == 3'd0 && pokey_reg == 4'h8)
			dout = allpot0;
		audio={2'b0,a0}+{2'b0,a1}+{2'b0,a2}+{2'b0,a3};
	end
endmodule
