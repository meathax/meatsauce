`timescale 1ns/1ps
// SPDX-License-Identifier: GPL-3.0-or-later
// Executable I, Robot mathbox control/datapath. The thirteen private PROM
// planes are written a nibble at a time; no ROM contents are embedded here.
module irobot_mathbox (
	input  logic       clk_12m096,
	input  logic       reset,
	input  logic       start,
	input  logic       prom_we,
	input  logic [9:0] prom_word_addr,
	input  logic [3:0] prom_plane,
	input  logic [3:0] prom_nibble,
	input  logic [15:0] memory_din,
	output logic       busy,
	output logic       done,
	output logic [9:0] micro_pc,
	output logic [15:0] alu_y,
	output logic [7:0] current_flags,
	output logic [7:0] direct_address,
	output logic [15:0] latch_mask,
	output logic [1:0] ram_select,
	output logic       direct_enable,
	output logic       memory_read,
	output logic       memory_write,
	output logic       microstep,
	output logic [11:0] debug_slices
);
	// The ROM download is plane-contiguous: all 1024 words of plane 0,
	// followed by all 1024 words of plane 1, and so on.  Keep the physical
	// four-bit planes separate so a later plane cannot overwrite the partial
	// word state of an earlier plane.  Each array is a complete memory word
	// write, which preserves block-RAM inference in Quartus.
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane0 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane1 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane2 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane3 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane4 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane5 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane6 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane7 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane8 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane9 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane10 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane11 [0:1023];
	(* ramstyle="M10K, no_rw_check" *) logic [3:0] micro_plane12 [0:1023];
	logic [3:0] micro_plane0_q, micro_plane1_q, micro_plane2_q, micro_plane3_q;
	logic [3:0] micro_plane4_q, micro_plane5_q, micro_plane6_q, micro_plane7_q;
	logic [3:0] micro_plane8_q, micro_plane9_q, micro_plane10_q, micro_plane11_q;
	logic [3:0] micro_plane12_q;
	logic [51:0] ir /* verilator public_flat_rd */; logic [9:0] fetched_pc;
	logic [3:0] areg,breg; logic [9:0] base_function,next_address;
	logic [2:0] jump_type,operation_cycles;
	logic decoded_done;
	logic [7:0] flags;
	logic prev_mult,prev_div;
	logic [9:0] effective_function;
	logic carry_now,negative_now,zero_now,q_lsb;
	logic carry_reg,negative_reg;
	logic carry_in,execute,first_op;
	logic control_prev_mult,control_prev_div;
	logic overflow_unused,q_msb_unused,ram_msb_unused;
	logic [3:0] slice_overflow_unused,slice_negative_unused;
	logic [2:0] wait_count;
	logic seq_step;

	assign ir={micro_plane12_q,micro_plane11_q,micro_plane10_q,micro_plane9_q,
		micro_plane8_q,micro_plane7_q,micro_plane6_q,micro_plane5_q,
		micro_plane4_q,micro_plane3_q,micro_plane2_q,micro_plane1_q,
		micro_plane0_q};

	mathbox_decode decode(ir,areg,breg,base_function,next_address,direct_address,
		latch_mask,flags,ram_select,jump_type,operation_cycles,direct_enable,decoded_done);

	always_comb begin
		control_prev_mult=first_op?flags[0]:prev_mult;
		control_prev_div=first_op?flags[6]:prev_div;
		effective_function=base_function;
		if (!control_prev_mult || q_lsb) effective_function[1]=~effective_function[1];
		else effective_function[1]=1'b1;
		if (control_prev_div || negative_reg) effective_function[3]=~effective_function[3];
		else effective_function[3]=1'b1;
		carry_in=1'b0;
		if(flags[4]) carry_in=carry_reg;
		else begin
			if(flags[5]) carry_in=1'b1;
			if(!control_prev_div && !negative_reg) carry_in=1'b1;
		end
	end

	am2901_quad datapath(.clk(clk_12m096),.ce(execute),.function_code(effective_function),
		.a_addr(areg),.b_addr(breg),.d(memory_din),.carry_in(carry_in),
		.flag_carry_insert(flags[5]),.y(alu_y),.carry_out(carry_now),
		.overflow(overflow_unused),.zero(zero_now),.negative(negative_now),
		.q_lsb(q_lsb),.q_msb(q_msb_unused),.slice_overflow(slice_overflow_unused),
		.slice_negative(slice_negative_unused),.ram_msb(ram_msb_unused));
	assign debug_slices={overflow_unused,q_msb_unused,ram_msb_unused,
		slice_overflow_unused,slice_negative_unused,q_lsb};

	assign execute=busy && fetched_pc==micro_pc &&
		((wait_count==0&&operation_cycles==2)||wait_count==1);
	assign seq_step=execute&&!decoded_done;
	mathbox_sequencer sequencer(.clk(clk_12m096),.reset(reset),.start(start),.step(seq_step),
		.jump_type(jump_type),.jump_address(next_address),.carry(carry_now),
		.zero_result(zero_now),.negative(negative_now),.pc(micro_pc));

	assign current_flags=flags;
	assign memory_read=busy && !flags[2] && flags[7];
	assign memory_write=execute && !flags[7];
	assign microstep=execute;

	// Each incoming byte carries one nibble from one physical PROM plane.  The
	// source stream is plane-contiguous, so write the selected plane directly
	// at its word address.  The registered reads below retain the original
	// one-clock instruction-fetch latency.
	always_ff @(posedge clk_12m096) begin
		if(prom_we && prom_plane<13) begin
			case(prom_plane)
				4'd0:  micro_plane0[prom_word_addr]  <= prom_nibble;
				4'd1:  micro_plane1[prom_word_addr]  <= prom_nibble;
				4'd2:  micro_plane2[prom_word_addr]  <= prom_nibble;
				4'd3:  micro_plane3[prom_word_addr]  <= prom_nibble;
				4'd4:  micro_plane4[prom_word_addr]  <= prom_nibble;
				4'd5:  micro_plane5[prom_word_addr]  <= prom_nibble;
				4'd6:  micro_plane6[prom_word_addr]  <= prom_nibble;
				4'd7:  micro_plane7[prom_word_addr]  <= prom_nibble;
				4'd8:  micro_plane8[prom_word_addr]  <= prom_nibble;
				4'd9:  micro_plane9[prom_word_addr]  <= prom_nibble;
				4'd10: micro_plane10[prom_word_addr] <= prom_nibble;
				4'd11: micro_plane11[prom_word_addr] <= prom_nibble;
				4'd12: micro_plane12[prom_word_addr] <= prom_nibble;
				default: ;
			endcase
		end
		if(reset) begin
			micro_plane0_q<=0; micro_plane1_q<=0; micro_plane2_q<=0;
			micro_plane3_q<=0; micro_plane4_q<=0; micro_plane5_q<=0;
			micro_plane6_q<=0; micro_plane7_q<=0; micro_plane8_q<=0;
			micro_plane9_q<=0; micro_plane10_q<=0; micro_plane11_q<=0;
			micro_plane12_q<=0;
		end else begin
			micro_plane0_q<=micro_plane0[micro_pc];
			micro_plane1_q<=micro_plane1[micro_pc];
			micro_plane2_q<=micro_plane2[micro_pc];
			micro_plane3_q<=micro_plane3[micro_pc];
			micro_plane4_q<=micro_plane4[micro_pc];
			micro_plane5_q<=micro_plane5[micro_pc];
			micro_plane6_q<=micro_plane6[micro_pc];
			micro_plane7_q<=micro_plane7[micro_pc];
			micro_plane8_q<=micro_plane8[micro_pc];
			micro_plane9_q<=micro_plane9[micro_pc];
			micro_plane10_q<=micro_plane10[micro_pc];
			micro_plane11_q<=micro_plane11[micro_pc];
			micro_plane12_q<=micro_plane12[micro_pc];
		end
		fetched_pc <= micro_pc;
		done <= 0;
		if(reset) begin busy<=0;wait_count<=0;prev_mult<=0;prev_div<=0;first_op<=1;fetched_pc<=10'h3ff;
			carry_reg<=0;negative_reg<=0;end
		else if(start && !busy) begin busy<=1;wait_count<=0;first_op<=1;end
		else if(busy && fetched_pc==micro_pc) begin
			if(execute) begin
				wait_count<=0;
				prev_mult<=flags[0];prev_div<=flags[6];first_op<=0;
				carry_reg<=carry_now;negative_reg<=negative_now;
				if(decoded_done) begin busy<=0;done<=1;end
			end else if(wait_count==0) wait_count<=operation_cycles-2'd2;
			else wait_count<=wait_count-1'd1;
		end
	end
endmodule
