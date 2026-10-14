// SPDX-License-Identifier: GPL-3.0-or-later
package se3208_pkg;
    typedef enum logic [6:0] {
        OP_ADC, OP_ADCI, OP_ADD, OP_ADDI, OP_AND, OP_ANDI, OP_ASL, OP_ASR,
        OP_CALL, OP_CALLR, OP_CLR, OP_CMP, OP_CMPI, OP_EXTB, OP_EXTS,
        OP_HALT, OP_INVALIDOP, OP_JC, OP_JGE, OP_JGT, OP_JHI, OP_JLE,
        OP_JLS, OP_JLT, OP_JM, OP_JMP, OP_JNC, OP_JNV, OP_JNZ, OP_JP,
        OP_JR, OP_JV, OP_JZ, OP_LD, OP_LDB, OP_LDBSP, OP_LDBU,
        OP_LDBUSP, OP_LDI, OP_LDS, OP_LDSP, OP_LDSSP, OP_LDSU,
        OP_LDSUSP, OP_LEAFROMSP, OP_LEASPTOSP, OP_LEATOSP, OP_LERI,
        OP_LSR, OP_MOV, OP_MULS, OP_MVFC, OP_MVTC, OP_NEG, OP_OR,
        OP_ORI, OP_POP, OP_PUSH, OP_SBC, OP_SBCI, OP_SET, OP_ST,
        OP_STB, OP_STBSP, OP_STS, OP_STSP, OP_STSSP, OP_SUB, OP_SUBI,
        OP_SWI, OP_TST, OP_TSTI, OP_XOR, OP_XORI,
        OP_CCMD, OP_GETC, OP_EXC, OP_LDC, OP_STC
    } operation_t;
    localparam logic [31:0] SR_C = 32'h0080, SR_V = 32'h0010,
        SR_S = 32'h0020, SR_Z = 32'h0040, SR_M = 32'h0200,
        SR_E = 32'h0800, SR_AUT = 32'h1000, SR_ENI = 32'h2000,
        SR_NMI = 32'h4000;
endpackage
