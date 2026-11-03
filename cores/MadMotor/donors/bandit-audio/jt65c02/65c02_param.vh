/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 03-10-2026 */

// Control signals
localparam [3:0] // CC
           C0_CC = 4'd1,
           C1_CC = 4'd2,
           D0_CC = 4'd3,
           D1_CC = 4'd4,
           I0_CC = 4'd5,
           I1_CC = 4'd6,
         NVZC_CC = 4'd7,
           NZ_CC = 4'd8,
          NZC_CC = 4'd9,
         NZCP_CC = 4'd10,
           V0_CC = 4'd11,
          XXZ_CC = 4'd12,
            Z_CC = 4'd13;

localparam [3:0] // ALU
         ADD_ALU = 4'd1,
         AND_ALU = 4'd2,
        BCLR_ALU = 4'd3,
        BINV_ALU = 4'd4,
        BSET_ALU = 4'd5,
         DAA_ALU = 4'd6,
         DAS_ALU = 4'd7,
         EOR_ALU = 4'd8,
         LSL_ALU = 4'd9,
         LSR_ALU = 4'd10,
          OR_ALU = 4'd11,
         SUB_ALU = 4'd12,
         TRB_ALU = 4'd13,
         TSB_ALU = 4'd14;

localparam [1:0] // BCD
         DAA_BCD = 2'd1,
         DAS_BCD = 2'd2;

localparam [1:0] // CARRY
       ALT_CARRY = 2'd1,
       CIN_CARRY = 2'd2,
       ONE_CARRY = 2'd3;

localparam [1:0] // EA
            M_EA = 2'd1,
           M1_EA = 2'd2,
            S_EA = 2'd3;

localparam [4:0] // JSR
         ABS_JSR = 5'd1,
        ABSA_JSR = 5'd2,
        ABSX_JSR = 5'd3,
       ABSXA_JSR = 5'd4,
        ABSY_JSR = 5'd5,
       ABSYA_JSR = 5'd6,
         IMM_JSR = 5'd7,
         IND_JSR = 5'd8,
        INDA_JSR = 5'd9,
        INDX_JSR = 5'd10,
       INDXA_JSR = 5'd11,
        INDY_JSR = 5'd12,
       INDYA_JSR = 5'd13,
        IVRD_JSR = 5'd14,
        PSH8_JSR = 5'd15,
        PUL8_JSR = 5'd16,
         RET_JSR = 5'd17,
       WAIT4_JSR = 5'd18,
          ZP_JSR = 5'd19,
         ZPA_JSR = 5'd20,
         ZPX_JSR = 5'd21,
        ZPXA_JSR = 5'd22,
         ZPY_JSR = 5'd23,
        ZPYA_JSR = 5'd24;

localparam [3:0] // LD
            A_LD = 4'd1,
         EA16_LD = 4'd2,
        EA2PC_LD = 4'd3,
           IV_LD = 4'd4,
           MD_LD = 4'd5,
            P_LD = 4'd6,
         PC16_LD = 4'd7,
            S_LD = 4'd8,
            X_LD = 4'd9,
            Y_LD = 4'd10,
           ZP_LD = 4'd11;

localparam [1:0] // OPND
        LD0_OPND = 2'd1,
        LD1_OPND = 2'd2;

localparam [3:0] // RMUX
          A_RMUX = 4'd1,
       EALO_RMUX = 4'd2,
         IV_RMUX = 4'd3,
         MD_RMUX = 4'd4,
        ONE_RMUX = 4'd5,
          P_RMUX = 4'd6,
         PB_RMUX = 4'd7,
       PCHI_RMUX = 4'd8,
       PCLO_RMUX = 4'd9,
          S_RMUX = 4'd10,
        SEX_RMUX = 4'd11,
          X_RMUX = 4'd12,
          Y_RMUX = 4'd13,
       ZERO_RMUX = 4'd14;

// entry points for ucode procedures
localparam ABS_SEQA             = 12'h330;
localparam ABSA_SEQA            = 12'h930;
localparam ABSX_SEQA            = 12'h430;
localparam ABSXA_SEQA           = 12'h4B0;
localparam ABSY_SEQA            = 12'h530;
localparam ABSYA_SEQA           = 12'h5B0;
localparam DAA_SEQA             = 12'hE30;
localparam DAS_SEQA             = 12'hF30;
localparam IMM_SEQA             = 12'hAB0;
localparam IND_SEQA             = 12'h830;
localparam INDA_SEQA            = 12'h9B0;
localparam INDX_SEQA            = 12'h630;
localparam INDXA_SEQA           = 12'h6B0;
localparam INDY_SEQA            = 12'h730;
localparam INDYA_SEQA           = 12'h7B0;
localparam ISRV_SEQA            = 12'h8B0;
localparam IVRD_SEQA            = 12'h30;
localparam NOBRANCH_SEQA        = 12'hC30;
localparam PSH8_SEQA            = 12'hB0;
localparam PUL8_SEQA            = 12'h2B0;
localparam WAIT4_SEQA           = 12'hBB0;
localparam ZP_SEQA              = 12'h130;
localparam ZPA_SEQA             = 12'h1B0;
localparam ZPX_SEQA             = 12'h230;
localparam ZPXA_SEQA            = 12'hB30;
localparam ZPY_SEQA             = 12'hA30;
localparam ZPYA_SEQA            = 12'hCB0;