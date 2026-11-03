/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 25-10-2026 */

// Control signals
localparam [3:0] // ALU
         ADD_ALU = 4'd1,
         AND_ALU = 4'd2,
        BCLR_ALU = 4'd3,
        BSET_ALU = 4'd4,
         EOR_ALU = 4'd5,
         LSL_ALU = 4'd6,
         LSR_ALU = 4'd7,
          OR_ALU = 4'd8,
         SUB_ALU = 4'd9;

localparam [1:0] // BRT
         CLR_BRT = 2'd1,
         SET_BRT = 2'd2;

localparam [1:0] // CARRY
       CIN_CARRY = 2'd1,
       MSB_CARRY = 2'd2;

localparam [3:0] // CC
            C_CC = 4'd1,
           C0_CC = 4'd2,
           C1_CC = 4'd3,
         HNZC_CC = 4'd4,
           I0_CC = 4'd5,
           I1_CC = 4'd6,
         N0Z1_CC = 4'd7,
           NZ_CC = 4'd8,
          NZC_CC = 4'd9,
         NZC1_CC = 4'd10;

localparam [1:0] // EA
            M_EA = 2'd1,
            S_EA = 2'd2;

localparam [4:0] // JSR
         DIR_JSR = 5'd1,
        DIRA_JSR = 5'd2,
         EXT_JSR = 5'd3,
        EXTA_JSR = 5'd4,
       IDLE3_JSR = 5'd5,
       IDLE4_JSR = 5'd6,
       IDLE6_JSR = 5'd7,
       IDLE7_JSR = 5'd8,
       IDLE9_JSR = 5'd9,
         IDX_JSR = 5'd10,
       IDX16_JSR = 5'd11,
      IDX16A_JSR = 5'd12,
        IDX8_JSR = 5'd13,
       IDX8A_JSR = 5'd14,
         IMM_JSR = 5'd15,
        IVRD_JSR = 5'd16,
     JSRDIRA_JSR = 5'd17,
     JSREXTA_JSR = 5'd18,
    JSRIDX16A_JSR = 5'd19,
    JSRIDX8A_JSR = 5'd20,
       PSH16_JSR = 5'd21,
        PSH8_JSR = 5'd22,
         RET_JSR = 5'd23,
      RMWDIR_JSR = 5'd24,
      RMWIDX_JSR = 5'd25,
     RMWIDX8_JSR = 5'd26,
        RTI8_JSR = 5'd27,
      STDIRA_JSR = 5'd28,
      STEXTA_JSR = 5'd29,
    STIDX16A_JSR = 5'd30,
     STIDX8A_JSR = 5'd31;

localparam [2:0] // LD
            A_LD = 3'd1,
           CC_LD = 3'd2,
           EA_LD = 3'd3,
           MD_LD = 3'd4,
           PC_LD = 3'd5,
            S_LD = 3'd6,
            X_LD = 3'd7;

localparam [1:0] // OPND
        LD0_OPND = 2'd1,
        LD1_OPND = 2'd2;

localparam [3:0] // RMUX
          A_RMUX = 4'd1,
         CC_RMUX = 4'd2,
         EA_RMUX = 4'd3,
         IV_RMUX = 4'd4,
         MD_RMUX = 4'd5,
        ONE_RMUX = 4'd6,
         PC_RMUX = 4'd7,
          S_RMUX = 4'd8,
          X_RMUX = 4'd9,
       ZERO_RMUX = 4'd10;

// entry points for ucode procedures
localparam DIR_SEQA             = 12'h910;
localparam DIRA_SEQA            = 12'h870;
localparam EXT_SEQA             = 12'h920;
localparam EXTA_SEQA            = 12'h840;
localparam IDLE3_SEQA           = 12'h510;
localparam IDLE4_SEQA           = 12'h8C0;
localparam IDLE5_SEQA           = 12'h520;
localparam IDLE6_SEQA           = 12'hAF0;
localparam IDLE7_SEQA           = 12'h550;
localparam IDLE9_SEQA           = 12'h5B0;
localparam IDX_SEQA             = 12'h930;
localparam IDX16_SEQA           = 12'h950;
localparam IDX16A_SEQA          = 12'h960;
localparam IDX8_SEQA            = 12'h940;
localparam IDX8A_SEQA           = 12'h850;
localparam IMM_SEQA             = 12'h900;
localparam ISRV_SEQA            = 12'h9E0;
localparam IVRD_SEQA            = 12'h820;
localparam JSRDIRA_SEQA         = 12'h310;
localparam JSREXTA_SEQA         = 12'h320;
localparam JSRIDX_SEQA          = 12'h350;
localparam JSRIDX16A_SEQA       = 12'h410;
localparam JSRIDX8A_SEQA        = 12'h3E0;
localparam PSH16_SEQA           = 12'h4B0;
localparam PSH8_SEQA            = 12'h3B0;
localparam RMWDIR_SEQA          = 12'h420;
localparam RMWIDX_SEQA          = 12'h450;
localparam RMWIDX8_SEQA         = 12'h4E0;
localparam RTI8_SEQA            = 12'h7B0;
localparam STDIRA_SEQA          = 12'h860;
localparam STEXTA_SEQA          = 12'h880;
localparam STIDX_SEQA           = 12'h890;
localparam STIDX16A_SEQA        = 12'h8B0;
localparam STIDX8A_SEQA         = 12'h8A0;