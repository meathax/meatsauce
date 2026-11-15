/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 02-11-2026 */

// Control signals
localparam [3:0] // ALU
         ADD_ALU = 4'd1,
         AND_ALU = 4'd2,
         ASR_ALU = 4'd3,
         CPX_ALU = 4'd4,
         DAA_ALU = 4'd5,
         EOR_ALU = 4'd6,
         LSL_ALU = 4'd7,
         LSR_ALU = 4'd8,
          OR_ALU = 4'd9,
         SUB_ALU = 4'd10;

localparam [1:0] // CARRY
       CIN_CARRY = 2'd1,
       SHL_CARRY = 2'd2;

localparam [3:0] // CC
           C0_CC = 4'd1,
           C1_CC = 4'd2,
        HNZVC_CC = 4'd3,
           I0_CC = 4'd4,
           I1_CC = 4'd5,
     N0Z1V0C0_CC = 4'd6,
        N0ZVC_CC = 4'd7,
          NZV_CC = 4'd8,
         NZV0_CC = 4'd9,
       NZV0C0_CC = 4'd10,
       NZV0C1_CC = 4'd11,
         NZVC_CC = 4'd12,
           V0_CC = 4'd13,
           V1_CC = 4'd14,
            Z_CC = 4'd15;

localparam [2:0] // EA
            M_EA = 3'd1,
            O_EA = 3'd2,
            P_EA = 3'd3,
            S_EA = 3'd4,
            X_EA = 3'd5;

localparam [4:0] // JSR
         DIR_JSR = 5'd1,
       DIR16_JSR = 5'd2,
        DIRA_JSR = 5'd3,
         EXT_JSR = 5'd4,
       EXT16_JSR = 5'd5,
        EXTA_JSR = 5'd6,
       FRAME_JSR = 5'd7,
         IDX_JSR = 5'd8,
       IDX16_JSR = 5'd9,
        IDXA_JSR = 5'd10,
         IMM_JSR = 5'd11,
       IMM16_JSR = 5'd12,
        IVRD_JSR = 5'd13,
      JSRIDX_JSR = 5'd14,
       PSH16_JSR = 5'd15,
        PSH8_JSR = 5'd16,
       PUL16_JSR = 5'd17,
        PUL8_JSR = 5'd18,
         RET_JSR = 5'd19,
       RTI16_JSR = 5'd20,
        RTI8_JSR = 5'd21,
    WAIFRAME_JSR = 5'd22;

localparam [3:0] // LD
            A_LD = 4'd1,
            B_LD = 4'd2,
           CC_LD = 4'd3,
           EA_LD = 4'd4,
           MD_LD = 4'd5,
           PC_LD = 4'd6,
            S_LD = 4'd7,
            X_LD = 4'd8;

localparam [1:0] // OPND
        LD0_OPND = 2'd1,
        LD1_OPND = 2'd2;

localparam [3:0] // RMUX
          A_RMUX = 4'd1,
          B_RMUX = 4'd2,
         CC_RMUX = 4'd3,
         EA_RMUX = 4'd4,
         IV_RMUX = 4'd5,
         MD_RMUX = 4'd6,
        ONE_RMUX = 4'd7,
         PC_RMUX = 4'd8,
          S_RMUX = 4'd9,
          X_RMUX = 4'd10,
       ZERO_RMUX = 4'd11;

// entry points for ucode procedures
localparam DIR_SEQA             = 13'h280;
localparam DIR16_SEQA           = 13'h2A0;
localparam DIRA_SEQA            = 13'h8A0;
localparam EXT_SEQA             = 13'h380;
localparam EXT16_SEQA           = 13'h3A0;
localparam EXTA_SEQA            = 13'hAA0;
localparam FRAME_SEQA           = 13'h240;
localparam IDLE4_SEQA           = 13'h10E0;
localparam IDLE6_SEQA           = 13'h840;
localparam IDX_SEQA             = 13'h3C0;
localparam IDX16_SEQA           = 13'h3E0;
localparam IDXA_SEQA            = 13'h960;
localparam IMM_SEQA             = 13'h11E0;
localparam IMM16_SEQA           = 13'h19E0;
localparam ISRV_SEQA            = 13'h18E0;
localparam IVRD_SEQA            = 13'h0;
localparam JSRIDX_SEQA          = 13'h340;
localparam PSH16_SEQA           = 13'h40;
localparam PSH8_SEQA            = 13'h9C0;
localparam PUL16_SEQA           = 13'h820;
localparam PUL8_SEQA            = 13'h60;
localparam RTI16_SEQA           = 13'hA40;
localparam RTI8_SEQA            = 13'hA20;
localparam WAIFRAME_SEQA        = 13'h300;