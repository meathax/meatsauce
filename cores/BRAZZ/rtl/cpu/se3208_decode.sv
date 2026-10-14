// SPDX-License-Identifier: GPL-3.0-or-later
// SE3208 opcode decode. MAME aliases outside FC00..FFFF; primary ADChips
// assembler/disassembler classification inside that range (see vendor probe).
module se3208_decode (
    input logic [15:0] opcode,
    output se3208_pkg::operation_t operation
);
    import se3208_pkg::*;
    always_comb begin
        operation = OP_INVALIDOP;
        case (opcode[15:14])
            2'b00: case (opcode[13:11])
                0: operation = OP_LDB;
                1: operation = OP_LDS;
                2: operation = OP_LD;
                3: operation = OP_LDBU;
                4: operation = OP_STB;
                5: operation = OP_STS;
                6: operation = OP_ST;
                7: operation = OP_LDSU;
            endcase
            2'b01: operation = OP_LERI;
            2'b10: case (opcode[13:11])
                0: operation = OP_LDSP;
                1: operation = OP_STSP;
                2: operation = OP_PUSH;
                3: operation = OP_POP;
                default: case (opcode[8:6])
                    0: operation = OP_ADDI;
                    1: operation = OP_ADCI;
                    2: operation = OP_SUBI;
                    3: operation = OP_SBCI;
                    4: operation = OP_ANDI;
                    5: operation = OP_ORI;
                    6: operation = OP_XORI;
                    7: case (opcode[2:0])
                        0: operation = OP_CMPI;
                        1: operation = OP_TSTI;
                        2: operation = OP_LEATOSP;
                        3: operation = OP_LEAFROMSP;
                        default: operation = OP_INVALIDOP;
                    endcase
                endcase
            endcase
            2'b11: case (opcode[13:12])
                0: case (opcode[8:6])
                    0: operation = OP_ADD;
                    1: operation = OP_ADC;
                    2: operation = OP_SUB;
                    3: operation = OP_SBC;
                    4: operation = OP_AND;
                    5: operation = OP_OR;
                    6: operation = OP_XOR;
                    7: case (opcode[2:0])
                        0: operation = OP_CMP;
                        1: operation = OP_TST;
                        2: operation = OP_MOV;
                        3: operation = OP_NEG;
                        default: operation = OP_INVALIDOP;
                    endcase
                endcase
                1: case (opcode[11:8])
                    0: operation = OP_JNV;
                    1: operation = OP_JV;
                    2: operation = OP_JP;
                    3: operation = OP_JM;
                    4: operation = OP_JNZ;
                    5: operation = OP_JZ;
                    6: operation = OP_JNC;
                    7: operation = OP_JC;
                    8: operation = OP_JGT;
                    9: operation = OP_JLT;
                    10: operation = OP_JGE;
                    11: operation = OP_JLE;
                    12: operation = OP_JHI;
                    13: operation = OP_JLS;
                    14: operation = OP_JMP;
                    15: operation = OP_CALL;
                endcase
                2: begin
                    if (opcode[11]) operation = OP_LDI;
                    else if (opcode[10]) case (opcode[9:7])
                        0: operation = OP_LDBSP;
                        1: operation = OP_LDSSP;
                        3: operation = OP_LDBUSP;
                        4: operation = OP_STBSP;
                        5: operation = OP_STSSP;
                        7: operation = OP_LDSUSP;
                        default: operation = OP_INVALIDOP;
                    endcase
                    else if (opcode[9]) operation = OP_LEASPTOSP;
                    else if (!opcode[8]) case (opcode[7:4])
                        0: operation = OP_EXTB;
                        1: operation = OP_EXTS;
                        8: operation = OP_JR;
                        9: operation = OP_CALLR;
                        10: operation = OP_SET;
                        11: operation = OP_CLR;
                        12: operation = OP_SWI;
                        13: operation = OP_HALT;
                        default: operation = OP_INVALIDOP;
                    endcase
                end
                3: case (opcode[11:9])
                    0,1,2,3: case (opcode[4:3])
                        0: operation = OP_ASR;
                        1: operation = OP_LSR;
                        2: operation = OP_ASL;
                        default: operation = OP_INVALIDOP;
                    endcase
                    4: operation = OP_MULS;
                    6,7: begin
                        // [9:8] is the vendor's numeric first operand (0..3).
                        // Its meaning and coprocessor effects are not established
                        // by decoding. The sequencer still faults on these ops.
                        casez (opcode[7:0])
                            8'b00??????: operation = OP_CCMD;
                            8'b0100????: operation = OP_GETC;
                            8'b0101????: operation = OP_EXC;
                            8'b01100???: operation = OP_MVTC;
                            8'b01101???: operation = OP_MVFC;
                            8'b10000???: operation = OP_LDC;
                            8'b10010???: operation = OP_STC;
                            default: operation = OP_INVALIDOP;
                        endcase
                    end
                    default: operation = OP_INVALIDOP;
                endcase
            endcase
        endcase
    end
endmodule
