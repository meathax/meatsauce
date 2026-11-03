// Copyright Jamie Iles, 2017
//
// This file is part of s80x86.
//
// s80x86 is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// s80x86 is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with s80x86.  If not, see <http://www.gnu.org/licenses/>.

// `default_nettype none -- removed for ModelSim ASE compat (false vlog-2892
// "Net type must be explicitly declared" on fully-typed ANSI ports, confirmed
// specific to `default_nettype none` + `-mfcu`; see rtl/s80x86/README_VENDORING.md).
// Every port here already has an explicit type (logic/wire/reg), so this is a
// no-op for elaboration -- default_nettype only matters for identifiers with
// NO explicit declaration, and this codebase has none of those left after the
// declare-before-use fixes.
module Core #(parameter integer PACING_PROFILE=0)(input logic clk,
            input logic reset,
            // Fractional logical CPU tick for optional timing-profile accounting.
            // The legacy Core does not consume this input.
            input logic pace_ce,
            // Interrupts
            input logic nmi,
            input logic intr,
            input logic [7:0] irq,
            output logic inta,
            // Instruction bus
            output logic [19:1] instr_m_addr,
            input logic [15:0] instr_m_data_in,
            output logic instr_m_access,
            input logic instr_m_ack,
            // Data bus
            output logic [19:1] data_m_addr,
            input logic [15:0] data_m_data_in,
            output logic [15:0] data_m_data_out,
            output logic data_m_access,
            input logic data_m_ack,
            output logic data_m_wr_en,
            output logic [1:0] data_m_bytesel,
            output logic d_io,
            output logic lock,
            // Debug
            output logic debug_stopped,
            input logic debug_seize,
            input logic [7:0] debug_addr,
            input logic debug_run,
            output logic [15:0] debug_val,
            input logic [15:0] debug_wr_val,
            input logic debug_wr_en,
            // A live, non-intrusive tap of this module's own internal `ip_current` (the IP
            // module's `val` output below), for a board-level debug
            // overlay to distinguish genuine forward progress through
            // boot code from a stuck loop. The existing debug_val/
            // debug_addr/debug_run interface can't be used for this --
            // it requires debug_seize to actually HALT the CPU to read a
            // register, which would defeat the point of watching it run
            // normally. A same-module hierarchical reference
            // (`cpu.ip_current` from the parent) compiles fine under
            // ModelSim but Quartus's synthesis elaborator cannot resolve
            // it across the instance boundary (Error 10207) -- a real
            // output port is the portable way to expose this. This is a
            // pure combinational read tap, no new logic, no effect on
            // anything else in this file -- same "mechanical,
            // semantics-preserving" bar as this file's existing
            // ModelSim-compatibility patches (see
            // rtl/s80x86/README_VENDORING.md's own section on those).
            output logic [15:0] ip_out);

// verilator lint_off UNUSED
Instruction wr_instruction, cur_instruction, next_instruction_value;
// verilator lint_on UNUSED

// --- ModelSim-ASE compatibility note ---
// This tool requires strict declare-before-use ordering for wires within
// a module (unlike upstream's Verilator-only-validated build, where the
// original interleaved "wire X = expr;"-immediately-after-related-logic
// style compiles fine because Verilator does a full dependency-order
// elaboration pass). Every wire below is therefore declared bare in one
// block, with its driving expression moved to a same-named `assign`
// later in this file, in the same relative order as upstream. This is a
// pure mechanical split (`wire W X = E;` -> `wire W X; assign X = E;`,
// a standard, semantics-preserving Verilog equivalence) with no logic
// changes -- see rtl/s80x86/README_VENDORING.md for the full rationale.
// Declarations that were already bare in upstream are unchanged, just
// grouped here instead of interleaved with the assigns that use them.

// Internal busses.
wire [15:0] a_bus;
wire [15:0] b_bus;

// Register file.
wire [15:0] si, di, bp, bx;
wire reg_is_8_bit;
wire [2:0] reg_rd_sel[2];
wire [2:0] reg_wr_sel;
wire [15:0] reg_wr_val;
wire reg_wr_en;
wire [15:0] reg_rd_val[2];
wire rb_cl;
wire [`MC_RDSelSource_t_BITS-1:0] rd_sel_source;

// Segment register file.
wire io_operation;
wire segment_force;
wire [15:0] seg_rd_val;
wire [15:0] seg_wr_val;
wire [15:0] cs;
wire [1:0] segment;
wire segment_wr_en;

wire decode_immed_start;
wire decode_immed_is_8bit;
wire decode_fifo_rd_en;
wire decode_complete;
wire instruction_empty;
wire instruction_fifo_full;
wire instruction_fifo_nearly_full;

// Prefetch FIFO
wire fifo_wr_en;
wire fifo_rd_en;
wire [7:0] fifo_rd_data;
wire [7:0] fifo_wr_data;
wire fifo_empty;
wire fifo_full;
wire fifo_reset;

// CS:IP Synchronizer
wire cs_updating;
wire [15:0] prefetch_cs;
wire ip_wr_en;
wire [15:0] ip_current;
wire prefetch_load_new_ip;
wire [15:0] prefetch_new_ip;

// Immediate Reader
wire immed_start;
wire immed_complete;
wire immed_is_8bit;
wire [15:0] immediate_reader_immediate;
wire [15:0] immediate;
`ifndef SYNTHESIS
initial begin
 if(PACING_PROFILE!=0 && PACING_PROFILE!=1)
  $fatal(1,"Unsupported PACING_PROFILE=%0d",PACING_PROFILE);
end
`endif
wire immed_fifo_rd_en;

wire instruction_fifo_rd_en;
// Production admission has one owner: diag_cycle_ready.

// ModRM Decoder
wire modrm_clear;
wire modrm_start;
wire modrm_uses_bp_as_base;
wire [2:0] regnum;
wire rm_is_reg;
wire [2:0] rm_regnum;
wire ra_modrm_rm_reg;

// Flags
wire [15:0] flags;
wire [8:0] update_flags;

// LoadStore
wire [15:0] mar;
wire [15:0] mdr;
wire microcode_write_mdr;
wire write_mdr;
wire [15:0] mdr_in;
wire microcode_write_mar;
wire write_mar;
wire mem_read;
wire mem_write;
wire mar_wr_sel;
wire [15:0] mar_wr_val;
wire loadstore_start;
wire loadstore_is_store;
wire loadstore_complete;
wire loadstore_busy;

// ALU
wire [`MC_ALUOp_t_BITS-1:0] alu_op;
wire [31:0] alu_out;
wire [15:0] alu_flags_out;
wire alu_busy;

// Microcode
wire [2:0] microcode_reg_rd_sel[2];
wire [2:0] microcode_reg_wr_sel;
wire [1:0] reg_wr_source;
wire [1:0] seg_wr_sel;
wire [1:0] a_sel;
wire [2:0] b_sel;
wire next_instruction;
wire is_8_bit;
wire [15:0] effective_address;
wire microcode_tmp_wr_en;
wire tmp_wr_en;
wire [15:0] tmp_wr_val;
wire tmp_wr_sel;
wire [15:0] tmp_val;
wire [15:0] microcode_immediate;
wire use_microcode_immediate;
wire [1:0] microcode_segment;
wire [7:0] opcode;
wire jump_taken;
wire multibit_shift;
wire rb_zero;
wire nmi_pulse;
wire ext_int_yield;
wire irq_to_mdr;
wire loop_next;
wire loop_done;
wire is_hlt;
wire next_microinstruction;

// Misc control signals
wire debug_set_ip;
wire do_next_instruction;
wire do_stall;
wire start_interrupt;

// IP
wire do_escape_fault;
wire starting_instruction;
wire ip_rollback;

// Divider
wire [31:0] dividend8;
wire [31:0] dividend;
wire [15:0] divisor8;
wire [15:0] divisor;
wire [15:0] quotient;
wire [15:0] remainder;
wire divide_error;
wire divide_busy;
wire divide;
wire divide_signed;
wire divide_complete;
wire do_divide;

// --- end of hoisted declarations; driving expressions follow, in the
// same relative order upstream has them ---

assign a_bus =
    a_sel == ADriver_RA ? reg_rd_val[0] :
    a_sel == ADriver_IP ? ip_current :
    a_sel == ADriver_MAR ? mar : mdr;
assign b_bus =
    b_sel == BDriver_RB ? reg_rd_val[1] :
    b_sel == BDriver_IMMEDIATE ? immediate :
    b_sel == BDriver_IMMEDIATE2 ? cur_instruction.immediates[1] :
    b_sel == BDriver_SR ? seg_rd_val : tmp_val;

assign reg_is_8_bit = is_8_bit;
assign reg_rd_sel[0] = ra_modrm_rm_reg ? rm_regnum : microcode_reg_rd_sel[0];
assign reg_rd_sel[1] = rb_cl ? CL : regnum;
assign reg_wr_sel =
    rd_sel_source == RDSelSource_MODRM_REG ? regnum :
    rd_sel_source == RDSelSource_MODRM_RM_REG ? rm_regnum :
    microcode_reg_wr_sel;
assign reg_wr_val =
    reg_wr_source == RegWrSource_Q ? alu_out[15:0] :
    reg_wr_source == RegWrSource_QUOTIENT ? quotient : remainder;

assign d_io = io_operation;
assign seg_wr_sel = segment_force ?
    microcode_segment : reg_wr_sel[1:0];
assign seg_wr_val = alu_out[15:0];

assign fifo_rd_en = immed_fifo_rd_en | decode_fifo_rd_en;

assign cs_updating = seg_wr_sel == CS && segment_wr_en;
assign prefetch_cs = cs_updating ? seg_wr_val : cs;

assign immed_start = decode_immed_start;
assign immed_is_8bit = decode_immed_is_8bit;
assign immediate = use_microcode_immediate ? microcode_immediate :
    cur_instruction.immediates[0];

assign modrm_clear = reset | do_next_instruction | start_interrupt | fifo_reset;

assign write_mdr = microcode_write_mdr | irq_to_mdr;
assign mdr_in = microcode_write_mdr ? alu_out[15:0] : {8'b0, irq};
assign write_mar = microcode_write_mar & next_microinstruction;
assign loadstore_start = (mem_read | mem_write) & ~loadstore_complete;
assign loadstore_is_store = mem_write;
assign mar_wr_val = mar_wr_sel == MARWrSel_EA ?
    effective_address : alu_out[15:0];

assign tmp_wr_en = microcode_tmp_wr_en | (debug_wr_en && debug_stopped);
assign tmp_wr_val = debug_stopped && debug_wr_en ? debug_wr_val :
    (tmp_wr_sel == TEMPWrSel_Q_LOW) ?  alu_out[15:0] :
    alu_out[31:16];

assign rb_zero = ~|reg_rd_val[1];

assign debug_set_ip = debug_stopped && ip_wr_en;
assign do_next_instruction = (next_instruction & ~do_stall) | debug_set_ip;
assign do_stall = loadstore_busy | divide_busy | alu_busy;

// Logical pacing tick comes from pace_ce; diag names remain for observer compatibility.
wire diag_ce=pace_ce;
wire [2:0] diag_phase=3'd0; // observer compatibility; no local pacing divider.
function automatic [11:0] diag_rep_base(input [7:0] op);
 case(op)
  8'ha4,8'ha5,8'h6c,8'h6d,8'h6e,8'h6f:diag_rep_base=8;
  8'ha6,8'ha7,8'hae,8'haf:diag_rep_base=5;
  8'haa,8'hab,8'hac,8'had:diag_rep_base=6;
  default:diag_rep_base=0;
 endcase
endfunction
function automatic [11:0] diag_rep_step(input [7:0] op);
 case(op)
  8'ha4,8'ha5,8'h6c,8'h6d,8'h6e,8'h6f:diag_rep_step=8;
  8'ha6,8'ha7:diag_rep_step=22;
  8'hae,8'haf:diag_rep_step=15;
  8'haa,8'hab:diag_rep_step=9;
  8'hac,8'had:diag_rep_step=11;
  default:diag_rep_step=0;
 endcase
endfunction

// Same-edge previews match the Flags/RegisterFile writes on this dispatch edge.
wire [15:0] diag_cx_raw;
reg [15:0] diag_cx, diag_flags;
always @* begin
 diag_cx=diag_cx_raw;
 if(reg_wr_en) begin
  if(!reg_is_8_bit && reg_wr_sel==CX) diag_cx=reg_wr_val;
  else if(reg_is_8_bit && reg_wr_sel==CL) diag_cx[7:0]=reg_wr_val[7:0];
  else if(reg_is_8_bit && reg_wr_sel==CH) diag_cx[15:8]=reg_wr_val[7:0];
 end
 diag_flags=flags;
 if(update_flags[UpdateFlags_CF]) diag_flags[CF_IDX]=alu_flags_out[CF_IDX];
 if(update_flags[UpdateFlags_PF]) diag_flags[PF_IDX]=alu_flags_out[PF_IDX];
 if(update_flags[UpdateFlags_AF]) diag_flags[AF_IDX]=alu_flags_out[AF_IDX];
 if(update_flags[UpdateFlags_ZF]) diag_flags[ZF_IDX]=alu_flags_out[ZF_IDX];
 if(update_flags[UpdateFlags_SF]) diag_flags[SF_IDX]=alu_flags_out[SF_IDX];
 if(update_flags[UpdateFlags_TF]) diag_flags[TF_IDX]=alu_flags_out[TF_IDX];
 if(update_flags[UpdateFlags_IF]) diag_flags[IF_IDX]=alu_flags_out[IF_IDX];
 if(update_flags[UpdateFlags_DF]) diag_flags[DF_IDX]=alu_flags_out[DF_IDX];
 if(update_flags[UpdateFlags_OF]) diag_flags[OF_IDX]=alu_flags_out[OF_IDX];
end
wire diag_jcc;
JumpTest diag_jump(.opcode(next_instruction_value.opcode),.flags(diag_flags),.taken(diag_jcc));
wire [7:0] diag_next_op=next_instruction_value.opcode;
wire diag_branch=diag_next_op==8'he3 ? diag_cx==0 :
 diag_next_op==8'he2 ? diag_cx!=1 :
 diag_next_op==8'he1 ? (diag_cx!=1 && diag_flags[ZF_IDX]) :
 diag_next_op==8'he0 ? (diag_cx!=1 && !diag_flags[ZF_IDX]) : diag_jcc;
wire [4:0] diag_shift=(diag_next_op==8'hd2 || diag_next_op==8'hd3) ? diag_cx[4:0] : next_instruction_value.immediates[0][4:0];
wire diag_cl_shift=diag_next_op==8'hd2 || diag_next_op==8'hd3;
// Keep the early cone structurally independent of forwarded CX. A nested
// selection through diag_shift retained an ALU-to-decoder timing path in Q17.
// The instruction costs depend only on the decoded instruction, so they are
// resolved from the registered decoder output and carried through CostFifo
// beside the instruction. The FIFO head then feeds the ledger directly.
wire diag_wr_cl_shift=wr_instruction.opcode==8'hd2 || wr_instruction.opcode==8'hd3;
(* keep *) wire [4:0] diag_shift_early=diag_wr_cl_shift ? 5'd0 : wr_instruction.immediates[0][4:0];
wire [11:0] diag_shift_extra=diag_cl_shift ? {7'd0,diag_shift} : 12'd0;
wire diag_wr_valid_untaken,diag_wr_exact_untaken,diag_wr_valid_taken,diag_wr_exact_taken;
wire [11:0] diag_wr_minimum_untaken,diag_wr_maximum_untaken,diag_wr_minimum_taken,diag_wr_maximum_taken;
wire diag_cost_valid_untaken,diag_cost_exact_untaken;
wire diag_cost_valid_taken,diag_cost_exact_taken;
wire diag_cost_valid_form=diag_branch ? diag_cost_valid_taken : diag_cost_valid_untaken;
wire diag_cost_exact=diag_branch ? diag_cost_exact_taken : diag_cost_exact_untaken;
wire diag_reference_mul=1'b1 && (diag_next_op==8'hf6 || diag_next_op==8'hf7) && next_instruction_value.mod_rm[5:3]==3'd4;
wire [11:0] diag_instruction_cost=(diag_branch ? diag_instruction_cost_taken : diag_instruction_cost_untaken)+diag_shift_extra;
wire [11:0] diag_minimum_untaken;
wire [11:0] diag_minimum_taken;
wire [11:0] diag_minimum=(diag_branch ? diag_minimum_taken : diag_minimum_untaken)+diag_shift_extra;
wire [11:0] diag_maximum=diag_minimum;
wire [11:0] diag_instruction_cost_untaken=diag_minimum_untaken+12'd0;
wire [11:0] diag_instruction_cost_taken=diag_minimum_taken+12'd0;
wire [5:0] diag_unused_step,diag_unused_step_taken;
// Resolve opcode/prefix costs before the same-edge flag/branch preview.
InstructionCycleCost diag_decoder(.opcode(wr_instruction.opcode),.modrm(wr_instruction.mod_rm),
 .rep(wr_instruction.rep!=REP_PREFIX_NONE),.prefix_count(wr_instruction.timing_prefix_count),
 .branch_taken(1'b0),.shift_count(diag_shift_early),.enter_level(wr_instruction.immediates[1][4:0]),
 .valid(diag_wr_valid_untaken),.exact(diag_wr_exact_untaken),.minimum(diag_wr_minimum_untaken),.maximum(diag_wr_maximum_untaken),.rep_step(diag_unused_step));
InstructionCycleCost diag_decoder_taken(.opcode(wr_instruction.opcode),.modrm(wr_instruction.mod_rm),
 .rep(wr_instruction.rep!=REP_PREFIX_NONE),.prefix_count(wr_instruction.timing_prefix_count),
 .branch_taken(1'b1),.shift_count(diag_shift_early),.enter_level(wr_instruction.immediates[1][4:0]),
 .valid(diag_wr_valid_taken),.exact(diag_wr_exact_taken),.minimum(diag_wr_minimum_taken),.maximum(diag_wr_maximum_taken),.rep_step(diag_unused_step_taken));
// Same write enable, flush and pointers as InstructionFifo keep each cost on its instruction.
Fifo #(.data_width(28),.depth(4),.full_threshold(1))
     CostFifo(.clk(clk),.reset(reset),.flush(fifo_reset),.wr_en(decode_complete),
              .wr_data({diag_wr_valid_untaken,diag_wr_exact_untaken,diag_wr_minimum_untaken,
                        diag_wr_valid_taken,diag_wr_exact_taken,diag_wr_minimum_taken}),
              .rd_en(instruction_fifo_rd_en),
              .rd_data({diag_cost_valid_untaken,diag_cost_exact_untaken,diag_minimum_untaken,
                        diag_cost_valid_taken,diag_cost_exact_taken,diag_minimum_taken}),
              .empty(),.nearly_full(),.full());
wire diag_interrupt_event=start_interrupt && next_microinstruction;
reg diag_halt_epoch=0;
always @(posedge clk) begin
 if(reset || PACING_PROFILE!=1 || diag_interrupt_event) diag_halt_epoch<=0;
 else if(instruction_fifo_rd_en) diag_halt_epoch<=diag_next_op==8'hf4;
 if(PACING_PROFILE==1 && !reset && instruction_fifo_rd_en && (!diag_cost_valid_form || (!diag_cost_exact && !diag_reference_mul)))
  $fatal(1,"Unresolved instruction timing op=%02x modrm=%02x cs=%04x ip=%04x bounds=%0d/%0d",diag_next_op,next_instruction_value.mod_rm,cs,ip_current,diag_minimum,diag_maximum);
 if(PACING_PROFILE==1 && !reset && ((instruction_fifo_rd_en && diag_rep_iteration) ||
    (diag_interrupt_event && (instruction_fifo_rd_en || diag_rep_iteration))))
  $fatal(1,"Overlapping timing cost owners");
end

wire diag_next_rep=next_instruction_value.rep!=REP_PREFIX_NONE && diag_rep_base(next_instruction_value.opcode)!=0;
wire diag_begin_rep=instruction_fifo_rd_en && diag_next_rep;
wire diag_rep_iteration;
wire diag_budget_can_issue,diag_budget_fault,diag_budget_armed,diag_budget_pending;
wire signed [31:0] diag_budget_balance;
wire diag_cycle_ready=(PACING_PROFILE==0)?1'b1:(PACING_PROFILE==1)?diag_budget_can_issue:1'b0;
wire diag_cycle_fault=(PACING_PROFILE==1)&&diag_budget_fault;
wire diag_cycle_armed=(PACING_PROFILE==1)&&diag_budget_armed;
wire signed [31:0] diag_cycle_balance=(PACING_PROFILE==1)?diag_budget_balance:32'sd0;
(* keep *) wire diag_cost_valid=(PACING_PROFILE==1) && (instruction_fifo_rd_en | diag_rep_iteration | diag_interrupt_event);
(* keep *) wire [1:0] diag_event_kind=diag_interrupt_event ? 2'd3 : instruction_fifo_rd_en ? 2'd1 : 2'd2;
wire [11:0] diag_cost=(PACING_PROFILE==1) ? (diag_interrupt_event ? 12'd42 : instruction_fifo_rd_en ? diag_instruction_cost : diag_rep_step(cur_instruction.opcode)) : 12'd0;
wire [11:0] diag_cost_untaken=(PACING_PROFILE==1) ? diag_instruction_cost_untaken : 12'd0;
wire [11:0] diag_cost_taken=(PACING_PROFILE==1) ? diag_instruction_cost_taken : 12'd0;
wire diag_restart=(PACING_PROFILE==1) && diag_halt_epoch && diag_cycle_ready && !diag_cost_valid;
PhysicalCycleBudget #(.PARALLEL_COSTS(1),.LATE_COSTS(1),.PARALLEL_EVENTS(1),.DEFER_CHARGE(1)) diag_budget(.clk(clk),.reset(reset),.restart(diag_restart),.run(PACING_PROFILE==1),.ce_cpu(pace_ce),.rebase((PACING_PROFILE==1)&&diag_interrupt_event),
 .cost_valid(diag_cost_valid),.cost_cycles(diag_cost_untaken),.alternate_cost_cycles(diag_cost_taken),.select_alternate_cost(diag_branch),.can_issue(diag_budget_can_issue),
 .fault(diag_budget_fault),.armed(diag_budget_armed),.pending(diag_budget_pending),.balance(diag_budget_balance),
 .late_cost_cycles(diag_cl_shift ? diag_shift : 5'd0),
 .rep_cost_cycles(diag_rep_step(cur_instruction.opcode)),.interrupt_cost_cycles(12'd42),.select_event(diag_event_kind));
// At a completed iteration, include its newly charged cost before admitting IRQ.
wire signed [32:0] diag_after_cost=$signed(diag_cycle_balance)+$signed({1'b0,diag_cost})-(diag_ce?33'sd1:33'sd0);
// This preview is consumed only at a REP iteration boundary, where the
// mutually exclusive cost owner is the current instruction's REP step.
// Using the generic event/dispatch selector here feeds microcode's IRQ/next
// address decision back into its own readiness input (a structural loop).
wire signed [32:0] diag_rep_after_cost=$signed(diag_cycle_balance)+$signed({1'b0,diag_rep_step(cur_instruction.opcode)})-(diag_ce?33'sd1:33'sd0);
wire diag_after_cost_paid=diag_rep_after_cost<=0;
wire diag_rep_ready=(PACING_PROFILE==0)?1'b1:(PACING_PROFILE==1)?(diag_rep_iteration ? (diag_cycle_armed && !diag_cycle_fault && !diag_budget_pending && diag_after_cost_paid) : diag_cycle_ready):1'b0;


assign ip_rollback = (start_interrupt & ext_int_yield & ~is_hlt) | do_escape_fault;

assign dividend8 = divide_signed ? {{16{tmp_val[15]}}, tmp_val} : {16'b0, tmp_val};
assign dividend = is_8_bit ? dividend8 : {reg_rd_val[0], tmp_val};
assign divisor8 = divide_signed ? {{8{mdr[7]}}, mdr[7:0]} : mdr;
assign divisor = is_8_bit ? divisor8 : mdr;
assign divide = alu_op == ALUOp_DIV || alu_op == ALUOp_IDIV;
assign divide_signed = alu_op == ALUOp_IDIV;
assign do_divide = divide & ~divide_complete;

assign debug_val = tmp_val;

RegisterFile    RegisterFile(.clk(clk),.timing_cx(diag_cx_raw),
                             .reset(reset),
                             .si(si),
                             .di(di),
                             .bp(bp),
                             .bx(bx),
                             .is_8_bit(reg_is_8_bit),
                             .rd_sel(reg_rd_sel),
                             .rd_val(reg_rd_val),
                             .wr_sel(reg_wr_sel),
                             .wr_val(reg_wr_val),
                             .wr_en(reg_wr_en));

SegmentOverride SegmentOverride(.clk(clk),
                                .reset(reset),
                                .flush(fifo_reset),
                                .next_instruction(do_next_instruction),
                                .force_segment(segment_force),
                                .bp_is_base(modrm_uses_bp_as_base),
                                .update(starting_instruction),
                                .segment_override(next_instruction_value.has_segment_override),
                                .override_in(next_instruction_value.segment),
                                .microcode_sr_rd_sel(microcode_segment),
                                .sr_rd_sel(segment));

SegmentRegisterFile SegmentRegisterFile(.clk(clk),
                                        .reset(reset),
                                        .rd_sel(segment),
                                        .rd_val(seg_rd_val),
                                        .wr_en(segment_wr_en),
                                        .wr_sel(seg_wr_sel),
                                        .wr_val(seg_wr_val),
                                        .cs(cs));

Fifo            #(.data_width(8),
                  .depth(6))
                PrefetchFifo(.clk(clk),
                             .reset(reset),
                             .flush(fifo_reset),
                             .wr_en(fifo_wr_en),
                             .wr_data(fifo_wr_data),
                             .rd_en(fifo_rd_en),
                             .rd_data(fifo_rd_data),
                             .empty(fifo_empty),
                             .nearly_full(fifo_full),
                             // verilator lint_off PINCONNECTEMPTY
                             .full()
                             // verilator lint_on PINCONNECTEMPTY
                            );

CSIPSync        CSIPSync(.clk(clk),
                         .reset(reset),
                         .cs_update(cs_updating),
                         .ip_update(ip_wr_en),
                         .ip_in(ip_current),
                         .new_ip(alu_out[15:0]),
                         .propagate(do_next_instruction),
                         .ip_out(prefetch_new_ip),
                         .update_out(prefetch_load_new_ip));

TempReg         TempReg(.clk(clk),
                        .reset(reset),
                        .wr_val(tmp_wr_val),
                        .wr_en(tmp_wr_en),
                        .val(tmp_val));

Prefetch        Prefetch(.clk(clk),
                         .reset(reset),
                         .new_cs(prefetch_cs),
                         .new_ip(prefetch_new_ip),
                         .load_new_ip(prefetch_load_new_ip),
                         .fifo_wr_en(fifo_wr_en),
                         .fifo_wr_data(fifo_wr_data),
                         .fifo_reset(fifo_reset),
                         .fifo_full(fifo_full),
                         .mem_access(instr_m_access),
                         .mem_ack(instr_m_ack),
                         .mem_address(instr_m_addr),
                         .mem_data(instr_m_data_in));

ImmediateReader ImmediateReader(.clk(clk),
                                .reset(reset),
                                // Control
                                .start(immed_start),
                                .flush(fifo_reset),
                                // verilator lint_off PINCONNECTEMPTY
                                .busy(),
                                // verilator lint_on PINCONNECTEMPTY
                                .complete(immed_complete),
                                .is_8bit(immed_is_8bit),
                                // Result
                                .immediate(immediate_reader_immediate),
                                // Fifo read port
                                .fifo_rd_en(immed_fifo_rd_en),
                                .fifo_rd_data(fifo_rd_data),
                                .fifo_empty(fifo_empty));

LoopCounter LoopCounter(.clk(clk),
                        .count_in(next_instruction_value.immediates[1][4:0]),
                        .load(instruction_fifo_rd_en),
                        .next(loop_next),
                        .done(loop_done));

Fifo            #(.data_width($bits(Instruction)),
                  .depth(4),
                  .full_threshold(1))
                InstructionFifo(.clk(clk),
                                .reset(reset),
                                .flush(fifo_reset),
                                .wr_en(decode_complete),
                                .wr_data(wr_instruction),
                                .rd_en(instruction_fifo_rd_en),
                                .rd_data(next_instruction_value),
                                .empty(instruction_empty),
                                .nearly_full(instruction_fifo_nearly_full),
                                .full(instruction_fifo_full));

InsnDecoder InsnDecoder(.clk(clk),
                        .reset(reset),
                        .flush(fifo_reset),
                        .stall(instruction_fifo_full),
                        .nearly_full(instruction_fifo_nearly_full),
                        .fifo_rd_en(decode_fifo_rd_en),
                        .fifo_rd_data(fifo_rd_data),
                        .fifo_empty(fifo_empty),
                        .instruction(wr_instruction),
                        .complete(decode_complete),
                        .immed_start(decode_immed_start),
                        .immed_complete(immed_complete),
                        .immed_is_8bit(decode_immed_is_8bit),
                        .immediate(immediate_reader_immediate));

ModRMDecode     ModRMDecode(.clk(clk),
                            .reset(reset),
                            .si(si),
                            .di(di),
                            .bp(bp),
                            .bx(bx),
                            // Control
                            .start(modrm_start),
                            .clear(modrm_clear),
                            .modrm(next_instruction_value.mod_rm),
                            .displacement(next_instruction_value.displacement),
                            // Results
                            .effective_address(effective_address),
                            .regnum(regnum),
                            .rm_is_reg(rm_is_reg),
                            .rm_regnum(rm_regnum),
                            .bp_as_base(modrm_uses_bp_as_base));

Flags           Flags(.clk(clk),
                      .reset(reset),
                      .flags_in(alu_flags_out),
                      .flags_out(flags),
                      .update_flags(update_flags));

JumpTest        JumpTest(.opcode(opcode),
                         .flags(flags),
                         .taken(jump_taken));

LoadStore       LoadStore(.clk(clk),
                          .reset(reset),
                          // MAR
                          .write_mar(write_mar),
                          .segment(seg_rd_val),
                          .mar_in(mar_wr_val),
                          // MDR
                          .mar_out(mar),
                          .mdr_out(mdr),
                          .write_mdr(write_mdr),
                          .mdr_in(mdr_in),
                          // Memory bus
                          .m_addr(data_m_addr),
                          .m_data_in(data_m_data_in),
                          .m_data_out(data_m_data_out),
                          .m_access(data_m_access),
                          .m_ack(data_m_ack),
                          .m_wr_en(data_m_wr_en),
                          .m_bytesel(data_m_bytesel),
                          // Control
                          .start(loadstore_start),
                          .is_8bit(is_8_bit),
                          .wr_en(loadstore_is_store),
                          .busy(loadstore_busy),
                          .complete(loadstore_complete),
                          .io(io_operation));

PosedgeToPulse PosedgeToPulse(.d(nmi),
                              .q(nmi_pulse),
                              .*);

Microcode #(.PACING_PROFILE(PACING_PROFILE)) Microcode(.clk(clk),
                          .reset(reset),
                          .nmi_pulse(nmi_pulse),
                          .intr(intr),
                          .inta(inta),
                          .irq_to_mdr(irq_to_mdr),
                          .start_interrupt(start_interrupt),
                          .do_escape_fault(do_escape_fault),
                          .starting_instruction(starting_instruction),
                          .stall(do_stall),
                          .diagnostic_rep_ready(diag_rep_ready),
                          .diagnostic_rep_iteration(diag_rep_iteration),
                          .divide_error(divide_error),
                          .modrm_reg(regnum),
                          .int_enabled(flags[IF_IDX]),
                          .zf(flags[ZF_IDX]),
                          .tf(flags[TF_IDX]),
                          .microcode_immediate(microcode_immediate),
                          .use_microcode_immediate(use_microcode_immediate),
                          .opcode(opcode),
                          .jump_taken(jump_taken),
                          .rb_zero(rb_zero),
                          .lock(lock),
                          .multibit_shift(multibit_shift),
                          .rm_is_reg(rm_is_reg),
                          .a_sel(a_sel),
                          .alu_op(alu_op),
                          .b_sel(b_sel),
                          .ext_int_yield(ext_int_yield),
                          .io(io_operation),
                          .next_instruction(next_instruction),
                          .load_ip(ip_wr_en),
                          .mar_wr_sel(mar_wr_sel),
                          .mar_write(microcode_write_mar),
                          .mdr_write(microcode_write_mdr),
                          .mem_read(mem_read),
                          .mem_write(mem_write),
                          .modrm_start(modrm_start),
                          .ra_modrm_rm_reg(ra_modrm_rm_reg),
                          .ra_sel(microcode_reg_rd_sel[0]),
                          .rb_cl(rb_cl),
                          .rd_sel_source(rd_sel_source),
                          .rd_sel(microcode_reg_wr_sel),
                          .reg_wr_en(reg_wr_en),
                          .reg_wr_source(reg_wr_source),
                          .segment(microcode_segment),
                          .segment_force(segment_force),
                          .segment_wr_en(segment_wr_en),
                          .tmp_wr_en(microcode_tmp_wr_en),
                          .tmp_wr_sel(tmp_wr_sel),
                          .update_flags(update_flags),
                          .width(is_8_bit),
                          .fifo_rd_en(instruction_fifo_rd_en),
                          .cur_instruction(cur_instruction),
                          .next_instruction_value(next_instruction_value),
                          .fifo_empty(instruction_empty | ~diag_cycle_ready),
                          .fifo_resetting(fifo_reset),
                          .loop_next(loop_next),
                          .loop_done(loop_done),
                          .is_hlt(is_hlt),
                          .next_microinstruction(next_microinstruction),
                          // Debug
                          .debug_stopped(debug_stopped),
                          .debug_seize(debug_seize),
                          .debug_addr(debug_addr),
                          .debug_run(debug_run));

IP              IP(.clk(clk),
                   .reset(reset),
                   .inc(next_instruction_value.length),
                   .start_instruction(instruction_fifo_rd_en),
                   .next_instruction(do_next_instruction),
                   .rollback(ip_rollback),
                   .wr_en(prefetch_load_new_ip),
                   .wr_val(prefetch_new_ip),
                   .val(ip_current));

assign ip_out = ip_current;

ALU             ALU(.a(a_bus),
                    .b(b_bus),
                    .out(alu_out),
                    .op(alu_op),
                    .is_8_bit(is_8_bit),
                    .flags_in(flags),
                    .flags_out(alu_flags_out),
                    .multibit_shift(multibit_shift),
                    .shift_count(tmp_val[4:0]),
                    .busy(alu_busy));

Divider         Divider(.clk(clk),
                        .reset(reset),
                        .start(do_divide),
                        .is_8_bit(is_8_bit),
                        .is_signed(divide_signed),
                        .busy(divide_busy),
                        .complete(divide_complete),
                        .error(divide_error),
                        .dividend(dividend),
                        .divisor(divisor),
                        .quotient(quotient),
                        .remainder(remainder));

`ifdef verilator
// verilator lint_off BLKANDNBLK
int instr_length;
// verilator lint_on BLKANDNBLK

always @(posedge clk)
    if (instruction_fifo_rd_en)
        instr_length <= {28'b0, next_instruction_value.length};

export "DPI-C" function get_and_clear_instr_length;

function int get_and_clear_instr_length;
    get_and_clear_instr_length = instr_length;
    instr_length = 0;
endfunction

`endif

endmodule
