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

`ifndef MICROCODE_TYPES
`define MICROCODE_TYPES

typedef enum bit [1:0] {
    ADriver_RA = 2'd0,
    ADriver_IP = 2'd1,
    ADriver_MAR = 2'd2,
    ADriver_MDR = 2'd3
} MC_ADriver_t;
`define MC_ADriver_t_BITS 2

typedef enum bit [2:0] {
    BDriver_RB = 3'd0,
    BDriver_IMMEDIATE = 3'd1,
    BDriver_SR = 3'd2,
    BDriver_TEMP = 3'd3,
    BDriver_IMMEDIATE2 = 3'd4
} MC_BDriver_t;
`define MC_BDriver_t_BITS 3

typedef enum bit [5:0] {
    ALUOp_SELA = 6'd0,
    ALUOp_SELB = 6'd1,
    ALUOp_ADD = 6'd2,
    ALUOp_ADC = 6'd3,
    ALUOp_AND = 6'd4,
    ALUOp_XOR = 6'd5,
    ALUOp_OR = 6'd6,
    ALUOp_SUB = 6'd7,
    ALUOp_SUBREV = 6'd8,
    ALUOp_SBB = 6'd9,
    ALUOp_SBBREV = 6'd10,
    ALUOp_GETFLAGS = 6'd11,
    ALUOp_SETFLAGSB = 6'd12,
    ALUOp_SETFLAGSA = 6'd13,
    ALUOp_CMC = 6'd14,
    ALUOp_SHR = 6'd15,
    ALUOp_SHL = 6'd16,
    ALUOp_SAR = 6'd17,
    ALUOp_ROR = 6'd18,
    ALUOp_ROL = 6'd19,
    ALUOp_RCL = 6'd20,
    ALUOp_RCR = 6'd21,
    ALUOp_NOT = 6'd22,
    ALUOp_NEXT = 6'd23,
    ALUOp_AAA = 6'd24,
    ALUOp_AAS = 6'd25,
    ALUOp_DAA = 6'd26,
    ALUOp_DAS = 6'd27,
    ALUOp_MUL = 6'd28,
    ALUOp_IMUL = 6'd29,
    ALUOp_DIV = 6'd30,
    ALUOp_IDIV = 6'd31,
    ALUOp_EXTEND = 6'd32,
    ALUOp_BOUNDL = 6'd33,
    ALUOp_BOUNDH = 6'd34,
    ALUOp_ENTER_FRAME_TEMP_ADDR = 6'd35
} MC_ALUOp_t;
`define MC_ALUOp_t_BITS 6

typedef enum bit [3:0] {
    JumpType_UNCONDITIONAL = 4'd0,
    JumpType_RM_REG_MEM = 4'd1,
    JumpType_OPCODE = 4'd2,
    JumpType_DISPATCH_REG = 4'd3,
    JumpType_HAS_NO_REP_PREFIX = 4'd4,
    JumpType_ZERO = 4'd5,
    JumpType_REP_NOT_COMPLETE = 4'd6,
    JumpType_JUMP_TAKEN = 4'd7,
    JumpType_RB_ZERO = 4'd8,
    JumpType_LOOP_DONE = 4'd9
} MC_JumpType_t;
`define MC_JumpType_t_BITS 4

typedef enum bit [1:0] {
    RDSelSource_NONE = 2'd0,
    RDSelSource_MODRM_REG = 2'd1,
    RDSelSource_MODRM_RM_REG = 2'd2,
    RDSelSource_MICROCODE_RD_SEL = 2'd3
} MC_RDSelSource_t;
`define MC_RDSelSource_t_BITS 2

typedef enum bit [0:0] {
    MARWrSel_EA = 1'd0,
    MARWrSel_Q = 1'd1
} MC_MARWrSel_t;
`define MC_MARWrSel_t_BITS 1

typedef enum bit [0:0] {
    TEMPWrSel_Q_LOW = 1'd0,
    TEMPWrSel_Q_HIGH = 1'd1
} MC_TEMPWrSel_t;
`define MC_TEMPWrSel_t_BITS 1

typedef enum bit [3:0] {
    UpdateFlags_CF = 4'd0,
    UpdateFlags_PF = 4'd1,
    UpdateFlags_AF = 4'd2,
    UpdateFlags_ZF = 4'd3,
    UpdateFlags_SF = 4'd4,
    UpdateFlags_TF = 4'd5,
    UpdateFlags_IF = 4'd6,
    UpdateFlags_DF = 4'd7,
    UpdateFlags_OF = 4'd8
} MC_UpdateFlags_t;
`define MC_UpdateFlags_t_BITS 4

typedef enum bit [1:0] {
    RegWrSource_Q = 2'd0,
    RegWrSource_QUOTIENT = 2'd1,
    RegWrSource_REMAINDER = 2'd2
} MC_RegWrSource_t;
`define MC_RegWrSource_t_BITS 2

typedef enum bit [1:0] {
    WidthType_W16 = 2'd0,
    WidthType_W8 = 2'd1,
    WidthType_WAUTO = 2'd2
} MC_WidthType_t;
`define MC_WidthType_t_BITS 2

`endif // MICROCODE_TYPES
