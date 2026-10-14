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

// vi: ft=systemverilog
`ifndef MICROCODE_ROM_PATH
`define MICROCODE_ROM_PATH "."
`endif

`default_nettype none
module Microcode(input logic clk,
                 input logic ce,
                 input logic reset,
                 input logic nmi_pulse,
                 input logic intr,
                 output logic inta,
                 output logic irq_to_mdr,
                 output logic start_interrupt,
                 output logic do_escape_fault,
                 output logic starting_instruction,
                 input logic stall,
                 input logic divide_error,
                 input logic rm_is_reg,
                 input logic [2:0] modrm_reg,
                 input logic int_enabled,
                 input logic zf,
                 input logic tf,
                 output logic [15:0] microcode_immediate,
                 output logic [8:0] update_flags,
                 output logic modrm_start,
                 output logic use_microcode_immediate,
                 output logic [7:0] opcode,
                 input logic jump_taken,
                 input logic rb_zero,
                 output logic lock,
                 output logic multibit_shift,
                 output logic is_hlt,
                 output logic next_microinstruction,
                 // Microinstruction fields.
                 output logic [1:0] a_sel,
                 output logic [5:0] alu_op,
                 output logic [2:0] b_sel,
                 output logic ext_int_yield,
                 output logic io,
                 output logic load_ip,
                 output logic mar_wr_sel,
                 output logic mar_write,
                 output logic mdr_write,
                 output logic mem_read,
                 output logic mem_write,
                 output logic next_instruction,
                 output logic ra_modrm_rm_reg,
                 output logic [2:0] ra_sel,
                 output logic rb_cl,
                 output logic [2:0] rd_sel,
                 output logic [1:0] rd_sel_source,
                 output logic [1:0] reg_wr_source,
                 output logic [1:0] segment,
                 output logic segment_force,
                 output logic segment_wr_en,
                 output logic tmp_wr_en,
                 output logic tmp_wr_sel,
                 output logic width,
                 output logic reg_wr_en,
                 // Fifo Read Port.
                 output logic fifo_rd_en,
                 // verilator lint_off UNUSED
                 input Instruction next_instruction_value,
                 output Instruction cur_instruction,
                 // verilator lint_on UNUSED
                 input logic fifo_empty,
                 input logic fifo_resetting,
                 output logic loop_next,
                 input logic loop_done,
                 // Debug
                 output logic debug_stopped,
                 input logic debug_seize,
                 input logic [7:0] debug_addr,
                 input logic debug_run);

localparam num_instructions = 1196;
localparam addr_bits = 11;
localparam reset_address = 11'h129;
localparam nmi_address = 11'h12a;
localparam irq_address = 11'h12b;
localparam single_step_address = 11'h12c;
localparam divide_error_address = 11'h101;
localparam next_instruction_address = 11'h100;
localparam modrm_wait_address = 11'h12e;
localparam bad_opcode_address = 11'h12f;
localparam debug_wait_address = 11'h102;
localparam do_int_address = 11'h12d;

typedef struct packed {
    logic [10:0] next;
    logic [1:0] a_sel;
    logic [5:0] alu_op;
    logic [2:0] b_sel;
    logic ext_int_inhibit;
    logic ext_int_yield;
    logic [3:0] immediate;
    logic io;
    logic [3:0] jump_type;
    logic load_ip;
    logic mar_wr_sel;
    logic mar_write;
    logic mdr_write;
    logic mem_read;
    logic mem_write;
    logic next_instruction;
    logic ra_modrm_rm_reg;
    logic [2:0] ra_sel;
    logic rb_cl;
    logic [2:0] rd_sel;
    logic [1:0] rd_sel_source;
    logic [1:0] reg_wr_source;
    logic [1:0] segment;
    logic segment_force;
    logic segment_wr_en;
    logic tmp_wr_en;
    logic tmp_wr_sel;
    logic [3:0] update_flags;
    logic [1:0] width;
} microcode_instruction;

microcode_instruction mem[num_instructions] /* synthesis ram_init_file = "microcode.mif" */;
// verilator lint_off UNUSED
microcode_instruction current;
// verilator lint_on UNUSED
reg [addr_bits-1:0] addr;
reg [addr_bits-1:0] next_addr;
reg [addr_bits-1:0] jump_target;
assign use_microcode_immediate = |current.immediate;
assign opcode = cur_instruction.opcode;

always_comb begin
    case (current.immediate)
    1: microcode_immediate = 16'h0;
    2: microcode_immediate = 16'h18;
    3: microcode_immediate = 16'h2;
    4: microcode_immediate = 16'h14;
    5: microcode_immediate = 16'h1;
    6: microcode_immediate = 16'hffff;
    7: microcode_immediate = 16'hc;
    8: microcode_immediate = 16'hff;
    9: microcode_immediate = 16'h4;
    10: microcode_immediate = 16'h10;
    11: microcode_immediate = 16'h8;
    default: microcode_immediate = 16'h0;
    endcase
end

always_comb begin
    case (current.update_flags)
    0: update_flags = 9'h0;
    1: update_flags = 9'h5;
    2: update_flags = 9'h1a;
    3: update_flags = 9'h11f;
    4: update_flags = 9'h11b;
    5: update_flags = 9'h1;
    6: update_flags = 9'h1f;
    7: update_flags = 9'h40;
    8: update_flags = 9'h80;
    9: update_flags = 9'h11e;
    10: update_flags = 9'h60;
    11: update_flags = 9'h109;
    12: update_flags = 9'h1ff;
    13: update_flags = 9'h101;
    14: update_flags = 9'h1b;
    default: update_flags = 9'h0;
    endcase
end

assign a_sel = current.a_sel;
assign alu_op = current.alu_op;
assign b_sel = current.b_sel;
assign ext_int_yield = current.ext_int_yield;
assign io = current.io;
assign load_ip = current.load_ip;
assign mar_wr_sel = current.mar_wr_sel;
assign mar_write = current.mar_write;
assign mdr_write = current.mdr_write;
assign mem_read = current.mem_read;
assign mem_write = current.mem_write;
assign next_instruction = current.next_instruction;
assign ra_modrm_rm_reg = current.ra_modrm_rm_reg;
assign ra_sel = current.ra_sel;
assign rb_cl = current.rb_cl;
assign rd_sel = current.rd_sel;
assign rd_sel_source = current.rd_sel_source;
assign reg_wr_source = current.reg_wr_source;
assign segment = current.segment;
assign segment_force = current.segment_force;
assign segment_wr_en = current.segment_wr_en;
assign tmp_wr_en = current.tmp_wr_en;
assign tmp_wr_sel = current.tmp_wr_sel;

assign fifo_rd_en = starting_instruction;
assign starting_instruction = !stall && (next_addr == {{addr_bits-8{1'b0}}, next_instruction_value.opcode});
assign modrm_start = addr == modrm_wait_address ||
    (addr == next_instruction_address && !fifo_empty && next_instruction_value.has_modrm);
wire has_rep_prefix = cur_instruction.rep != REP_PREFIX_NONE;
reg rep_complete;
assign debug_stopped = addr == debug_wait_address;
assign multibit_shift = cur_instruction.opcode == 8'hd2 ||
                        cur_instruction.opcode == 8'hd3 ||
                        cur_instruction.opcode == 8'hc0 ||
                        cur_instruction.opcode == 8'hc1;
assign do_escape_fault = cur_instruction.opcode[7:3] == 5'b11011 && next_addr == do_int_address;
reg nmi_pending;
reg ext_int_inhibit;
wire take_nmi = (nmi_pending | nmi_pulse) & !ext_int_inhibit & !current.ext_int_inhibit;
wire take_irq = intr & int_enabled & !ext_int_inhibit & !current.ext_int_inhibit;
wire do_single_step = current.next_instruction & !ext_int_inhibit &
    trap_flag_set & current.next != debug_wait_address & !current.ext_int_inhibit;
assign start_interrupt = next_addr == nmi_address ||
                         next_addr == irq_address;
assign irq_to_mdr = next_addr == irq_address;
reg trap_flag_set;
assign is_hlt = cur_instruction.opcode == 8'hf4;
reg seized;
wire seizing = debug_seize & ~seized;
assign loop_next = !stall && current.jump_type == JumpType_LOOP_DONE;
assign reg_wr_en = current.rd_sel_source != RDSelSource_NONE & ~segment_wr_en;
assign next_microinstruction = addr != next_addr;
assign lock = cur_instruction.lock;

always_comb begin
    case (current.width)
    WidthType_W8: width = 1'b1;
    WidthType_W16: width = 1'b0;
    WidthType_WAUTO: width = ~cur_instruction.opcode[0];
    default: width = 1'b0;
    endcase
end

always_ff @(posedge clk)
    if (ce)
        inta <= next_addr == irq_address && addr != irq_address;

always_ff @(posedge clk or posedge reset)
    if (reset)
        trap_flag_set <= 1'b0;
    else if (ce && next_addr == single_step_address)
        trap_flag_set <= 1'b0;
    else if (ce && starting_instruction)
        trap_flag_set <= tf;

always_ff @(posedge clk or posedge reset)
    if (reset)
        ext_int_inhibit <= 1'b0;
    else if (ce && current.ext_int_inhibit && current.next != debug_wait_address)
        ext_int_inhibit <= 1'b1;
    else if (ce && starting_instruction && !stall)
        ext_int_inhibit <= 1'b0;

`ifdef verilator
initial $readmemb({{`MICROCODE_ROM_PATH, "/microcode.bin"}}, mem);
`endif

always_comb begin
    case (cur_instruction.rep)
    REP_PREFIX_E: rep_complete = ~zf;
    REP_PREFIX_NE: rep_complete = zf;
    default: rep_complete = 1'b0;
    endcase
end

always_ff @(posedge clk or posedge reset)
    if (reset)
        nmi_pending <= 1'b0;
    else if (ce && next_addr == nmi_address)
        nmi_pending <= 1'b0;
    else if (ce && nmi_pulse)
        nmi_pending <= 1'b1;

always_ff @(posedge clk or posedge reset)
    if (reset)
        seized <= 1'b0;
    else if (ce && debug_stopped)
        seized <= 1'b1;
    else if (ce && !debug_seize)
        seized <= 1'b0;

always_comb begin
    unique case (current.jump_type)
    JumpType_RM_REG_MEM: jump_target = current.next + {{addr_bits-1{1'b0}}, ~rm_is_reg};
    JumpType_OPCODE: jump_target = !fifo_empty ? {{addr_bits-8{1'b0}}, next_instruction_value.opcode} : addr;
    JumpType_DISPATCH_REG: jump_target = current.next + {{addr_bits-3{1'b0}}, modrm_reg};
    JumpType_HAS_NO_REP_PREFIX: jump_target = ~has_rep_prefix ? current.next : addr + 1'b1;
    JumpType_ZERO: jump_target = zf ? current.next : addr + 1'b1;
    JumpType_REP_NOT_COMPLETE: jump_target = !rep_complete ? current.next : addr + 1'b1;
    JumpType_RB_ZERO: jump_target = rb_zero ? current.next : addr + 1'b1;
    JumpType_LOOP_DONE: jump_target = loop_done ? current.next : addr + 1'b1;
    JumpType_JUMP_TAKEN: jump_target = jump_taken ? current.next : addr + 1'b1;
    default: jump_target = current.next;
    endcase
end

always_comb begin
    if (reset)
        next_addr = reset_address;
    else if (debug_stopped && debug_run)
        next_addr = {{addr_bits - 9{1'b0}}, 1'b1, debug_addr};
    else if (stall)
        next_addr = addr;
    else if (current.ext_int_yield && seizing)
        next_addr = debug_wait_address;
    else if (current.ext_int_yield && take_nmi)
        next_addr = nmi_address;
    else if (current.ext_int_yield && take_irq)
        next_addr = irq_address;
    else if (addr == next_instruction_address && !fifo_empty && !fifo_resetting &&
             next_instruction_value.invalid)
        next_addr = bad_opcode_address;
    else if (current.jump_type != JumpType_UNCONDITIONAL)
        next_addr = jump_target;
    else if (divide_error)
        next_addr = divide_error_address;
    else if (current.next_instruction && take_nmi)
        next_addr = nmi_address;
    else if (current.next_instruction && take_irq)
        next_addr = irq_address;
    else if ((current.next_instruction && do_single_step) ||
             (is_hlt && trap_flag_set))
        next_addr = single_step_address;
    else if (current.next_instruction && debug_seize)
        next_addr = debug_wait_address;
    else if (current.next_instruction || (is_hlt && intr))
        next_addr = !fifo_empty && !fifo_resetting ?
            (next_instruction_value.has_modrm ? modrm_wait_address :
             {{addr_bits-8{1'b0}}, next_instruction_value.opcode}) :
            next_instruction_address;
    else
        next_addr = current.next;
end

always @(posedge clk)
    if (ce)
        addr <= next_addr;

always @(posedge clk)
    if (ce)
        current <= mem[next_addr];

always_ff @(posedge clk)
    if (ce && fifo_rd_en)
        cur_instruction <= next_instruction_value;

`ifdef verilator
export "DPI-C" function get_microcode_address;

function bit [addr_bits-1:0] get_microcode_address;
    get_microcode_address = addr;
endfunction

export "DPI-C" function get_ext_int_yield;

function bit get_ext_int_yield;
    get_ext_int_yield = current.ext_int_yield;
endfunction

int microcode_coverage[num_instructions];

always_ff @(posedge clk)
    if (ce)
        microcode_coverage[addr] <= microcode_coverage[addr] + 1;

export "DPI-C" function get_microcode_num_instructions;

function int get_microcode_num_instructions;
    get_microcode_num_instructions = num_instructions;
endfunction

export "DPI-C" function get_microcode_coverage_bin;

function int get_microcode_coverage_bin;
    input int bin;
    get_microcode_coverage_bin = microcode_coverage[bin];
endfunction
`endif

endmodule
