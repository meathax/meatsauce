`timescale 1ns/1ps
// SPDX-License-Identifier: BSD-2-Clause
//
// POKEY behavioural translation for the Verilator/SV build lane.
//
// This module follows the register, divider, polynomial, pot and four-channel
// mixer behaviour of rtl/io/pokey.vhd (MikeJ/FPGAArcade, BSD-style notice
// retained there).  It intentionally keeps the same pin names and active-low
// bus semantics as that donor so quad_pokey_sv can be a drop-in replacement.
// Keyboard/serial/IRQ functions that are unused by the I, Robot board remain
// tied to their documented idle values.  This is a behavioural model, not a
// claim of cycle-perfect POKEY silicon timing; directed register/noise tests
// must pass before an acceptance lane is enabled.
module pokey_sv (
	input  logic       reset,
	input  logic [3:0] addr,
	input  logic [7:0] din,
	output logic [7:0] dout,
	input  logic       rw_l,
	input  logic       cs,
	input  logic       cs_l,
	output logic [7:0] audio_out,
	input  logic [7:0] pin,
	input  logic       ena,
	input  logic       clk
);
	logic [7:0] audf [0:3];
	logic [7:0] audc [0:3];
	logic [7:0] audctl;
	logic [2:0] skctls;
	logic [7:0] pin_reg;
	logic [7:0] pot_val [0:7];
	logic [7:0] pot_cnt;
	logic       potgo;
	logic       pot_fin;
	logic [4:0] div64;
	logic [6:0] div15;
	logic       ena64;
	logic       ena15;
	logic [3:0] poly4;
	logic [4:0] poly5;
	logic [8:0] poly9;
	logic [16:0] poly17;
	logic [7:0] tone_cnt [0:3];
	logic [7:0] tone_pipe [0:3];
	logic [3:0] tone_div;
	logic [3:0] tone_done_load;
	logic [3:0] tone_final;
	logic [1:0] high_pass;
	logic [3:0] channel_output;
	logic [3:0] audio_clock;
	logic [3:0] audio_sample;
	logic [3:0] chan_enable;
	logic [3:0] tone_zero;
	logic [3:0] chan_load;
	logic [3:0] chan_dec;
	logic       ena64_15k;
	logic [5:0] mix_level;
	logic       chip_reset;
	logic       read_enable;
	logic       write_enable;

	assign chip_reset = (skctls[1:0] == 2'b00);
	assign read_enable = cs && !cs_l && rw_l;
	assign write_enable = cs && !cs_l && !rw_l && ena;
	assign ena64_15k = audctl[0] ? ena15 : ena64;
	always_comb begin
		chan_enable[0] = audctl[6] ? 1'b1 : ena64_15k;
		chan_enable[1] = audctl[4] ? chan_enable[0] : ena64_15k;
		chan_enable[2] = audctl[5] ? 1'b1 : ena64_15k;
		chan_enable[3] = audctl[3] ? chan_enable[2] : ena64_15k;
		for (int n = 0; n < 4; n++) tone_zero[n] = (tone_cnt[n] == 8'h00) && chan_enable[n];
		chan_load = 4'b0000;
		chan_dec = 4'b1111;
		if (audctl[4]) begin
			if (tone_pipe[0][5] && tone_pipe[1][5] && !tone_done_load[0]) begin chan_load[0] = 1'b1; chan_load[1] = 1'b1; end
			chan_dec[1] = tone_zero[0];
		end else begin
			chan_load[0] = tone_pipe[0][2] && !tone_done_load[0];
			chan_load[1] = tone_pipe[1][2] && !tone_done_load[1];
		end
		if (audctl[3]) begin
			if (tone_pipe[2][5] && tone_pipe[3][5] && !tone_done_load[2]) begin chan_load[2] = 1'b1; chan_load[3] = 1'b1; end
			chan_dec[3] = tone_zero[2];
		end else begin
			chan_load[2] = tone_pipe[2][2] && !tone_done_load[2];
			chan_load[3] = tone_pipe[3][2] && !tone_done_load[3];
		end
	end

	always_comb begin
		dout = 8'h00;
		if (read_enable) begin
			case (addr)
				4'h0: dout = pot_val[0];
				4'h1: dout = pot_val[1];
				4'h2: dout = pot_val[2];
				4'h3: dout = pot_val[3];
				4'h4: dout = pot_val[4];
				4'h5: dout = pot_val[5];
				4'h6: dout = pot_val[6];
				4'h7: dout = pot_val[7];
				4'h8: dout = (chip_reset || pot_fin) ? 8'h00 : ~pin_reg;
				4'ha: dout = (audctl[7] ? poly9[7:0] : poly17[15:8]);
				4'hb, 4'hc: dout = 8'hff;
				default: dout = 8'h00;
			endcase
		end
	end

	always_comb begin
		for (int n = 0; n < 4; n++) begin
			audio_clock[n] = audc[n][7] ? tone_div[n] : (poly5[0] & tone_div[n]);
			audio_sample[n] = audc[n][6] ? poly4[0] : (audctl[7] ? poly9[0] : poly17[0]);
			channel_output[n] = tone_final[n];
		end
		if (audctl[2]) channel_output[0] = tone_final[0] ^ high_pass[0];
		if (audctl[1]) channel_output[1] = tone_final[1] ^ high_pass[1];
	end

	always_comb begin
		integer sum;
		sum = 0;
		for (int n = 0; n < 4; n++) begin
			if (audc[n][4] || channel_output[n]) sum += {28'd0, audc[n][3:0]};
		end
		// The donor registers the mixer result on ENA.  Keep the arithmetic
		// six bits wide (the four 4-bit volumes sum to at most 60).
		mix_level = sum[5:0];
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			for (int n = 0; n < 4; n++) begin
				audf[n] <= 8'h00;
				audc[n] <= 8'h00;
				tone_cnt[n] <= 8'h00;
				tone_pipe[n] <= 8'h00;
			end
			for (int n = 0; n < 8; n++) pot_val[n] <= 8'h00;
			audctl <= 8'h00;
			skctls <= 3'b000;
			pin_reg <= 8'h00;
			pot_cnt <= 8'h00;
			potgo <= 1'b0;
			pot_fin <= 1'b1;
			div64 <= 5'd27;
			div15 <= 7'd113;
			ena64 <= 1'b0;
			ena15 <= 1'b0;
			poly4 <= 4'b0001;
			poly5 <= 5'b00001;
			poly9 <= 9'b011111111;
			poly17 <= 17'b11111111101111111;
			tone_div <= 4'b0000;
			tone_done_load <= 4'b0000;
			tone_final <= 4'b0000;
			high_pass <= 2'b00;
			audio_out <= 8'h00;
		end else begin
			// POTGO is a one-clock write strobe; clear it before decoding
			// this cycle's bus write, matching the donor process ordering.
			potgo <= 1'b0;
			if (write_enable) begin
			case (addr)
				4'h0: audf[0] <= din;
				4'h1: audc[0] <= din;
				4'h2: audf[1] <= din;
				4'h3: audc[1] <= din;
				4'h4: audf[2] <= din;
				4'h5: audc[2] <= din;
				4'h6: audf[3] <= din;
				4'h7: audc[3] <= din;
				4'h8: audctl <= din;
				4'hb: potgo <= 1'b1;
				4'hf: skctls <= din[2:0];
				default: ;
			endcase
			end else begin
				potgo <= 1'b0;
			end

		pin_reg <= pin;
		// POT samples in the donor update every CLK, not only the audio
		// clock-enable phase.  The previous pin sample is intentionally used
		// here, matching the separate VHDL process' signal-update ordering.
		for (int n = 0; n < 8; n++) pot_val[n] <= pin_reg[n] ? 8'h00 : 8'he4;
		if (chip_reset) pot_fin <= 1'b1;
		else if (potgo) pot_fin <= 1'b0;
		else if (pot_cnt == 8'he4) pot_fin <= 1'b1;
		if (potgo) pot_cnt <= 8'h00;
		else if (ena && (ena15 || skctls[2])) pot_cnt <= pot_cnt + 1'b1;
		if (ena) begin
			// POKEY's 1.79 MHz input is divided to nominal 64 kHz and 15 kHz
			// enables by the same reload values as the audited VHDL donor.
			if (chip_reset) begin
				div64 <= 5'd27;
				div15 <= 7'd113;
				ena64 <= 1'b0;
				ena15 <= 1'b0;
			end else begin
				if (div64 == 0) begin div64 <= 5'd27; ena64 <= 1'b1; end
				else begin div64 <= div64 - 1'b1; ena64 <= 1'b0; end
				if (div15 == 0) begin div15 <= 7'd113; ena15 <= 1'b1; end
				else begin div15 <= div15 - 1'b1; ena15 <= 1'b0; end
			end

			if (chip_reset) begin
				poly4 <= 4'b0001;
				poly5 <= 5'b00001;
				poly9 <= 9'b011111111;
				poly17 <= 17'b11111111101111111;
			end else begin
				poly4 <= {poly4[2:0], ~(poly4[3] ^ poly4[2])};
				poly5 <= {poly5[3:0], ~(poly5[4] ^ poly5[2])};
				poly9 <= {(poly9[0] ^ poly9[5]), poly9[8:1]};
				poly17[16] <= poly17[0];
				poly17[15:8] <= poly17[16:9];
				poly17[7] <= poly17[8] ^ poly17[13];
				poly17[6:0] <= poly17[7:1];
			end
			tone_div <= 4'b0000;
			for (int n = 0; n < 4; n++) begin
				if (chan_load[n]) begin
					tone_done_load[n] <= 1'b1;
					tone_div[n] <= 1'b1;
					tone_cnt[n] <= audf[n];
				end else if (chan_dec[n] && chan_enable[n]) begin
					tone_done_load[n] <= 1'b0;
					tone_cnt[n] <= tone_cnt[n] - 1'b1;
				end
				tone_pipe[n] <= {tone_pipe[n][6:0], tone_zero[n]};
				if (!chip_reset && audio_clock[n]) begin
					if (audc[n][5]) tone_final[n] <= ~tone_final[n];
					else tone_final[n] <= audio_sample[n];
				end
			end
			if (chip_reset) begin
				tone_final <= 4'b0000;
				high_pass <= 2'b00;
				audio_out <= 8'h00;
			end else begin
				if (tone_div[2]) high_pass[0] <= tone_final[0];
				if (tone_div[3]) high_pass[1] <= tone_final[1];
				audio_out <= {mix_level, 2'b00};
			end
		end
		end
	end
endmodule
