/*  This file is part of JTKCPU.
    JTKCPU program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTKCPU program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTKCPU.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 14-02-2023 */

module jtkcpu_alu(
    input             rst,
    input             clk,
    input             cen /* synthesis direct_enable */,

    input      [ 7:0] op,
    input      [15:0] opnd0,
    input      [15:0] opnd1, // data from memory
    input      [ 7:0] cc_in,
    output     [ 7:0] cc_out,

    // Special OPs
    input             dec8,
    input             dec16,
    input             div_en,
    input             shd_en,
    input             idx_en,

    output            busy,

    output reg [15:0] rslt,
    output reg [15:0] rslt_hi // used only in lmul
);

`include "jtkcpu.inc"

wire [3:0] msb;
wire       div_busy;
reg        shd_busy, alu16, up_z, up_n;
reg        c_out, v_out, z_out, n_out, h_out, e_out, i_out, f_out;

// Multi-bit shift
reg  [15:0] shd_data;
reg  [ 3:0] shd_cnt;
wire [ 3:0] shd_mux;
// Divider
wire [15:0] div_quot;
wire [ 7:0] div_rem;
wire        div_v;
reg         div_sign = 0;

assign cc_out   = { e_out, f_out, h_out, i_out, n_out, z_out, v_out, c_out };
assign msb      = alu16 ? 4'd15 : 4'd7;
assign busy     = div_busy | shd_busy;
assign shd_mux  = idx_en ? opnd0[11:8] : opnd1[3:0];

always @(posedge clk) begin
    case( op )
        CMPD_IMM, CMPD_IDX, ASRD_IMM, ASRD_IDX, ASRW, ADDD_IMM, INCD, NEGD, ABSD,
        CMPX_IMM, CMPX_IDX, ASLD_IMM, ASLD_IDX, ASLW, ADDD_IDX, INCW, NEGW,  ABX,
        CMPY_IMM, CMPY_IDX, ROLD_IMM, ROLD_IDX, ROLW, SUBD_IMM, DECD, TSTD,  SEX,
        CMPU_IMM, CMPU_IDX, RORD_IMM, RORD_IDX, LSRW, SUBD_IDX, DECW, TSTW,
        CMPS_IMM, CMPS_IDX, LSRD_IMM, LSRD_IDX, RORW, DIVXB,
        LEAX,     LDD_IMM,  LDX_IMM,  LDY_IMM,  STX,
        LEAY,     LDD_IDX,  LDX_IDX,  LDY_IDX,  STY,
        LEAU,     LDU_IMM,  LDS_IMM,  CLRD,     STU,
        LEAS,     LDU_IDX,  LDS_IDX,  CLRW,     STS, STD:
                 alu16 <= 1;
        default: alu16 <= 0;
    endcase
    if( dec16 ) alu16 <= 1;
    up_n  <= op!=LEAX && op!=LEAY  && op!=LEAU  && op!=LEAS  && op!=ABX &&
             op!=MUL  && op!=LMUL  && op!=DIVXB && op!=ANDCC && op!=ORCC;
    up_z  <= op!=LEAU && op!=LEAS  && op!=ABX   && op!=ABSA  && op!=ABSB &&
             op!=ABSD && op!=ANDCC && op!=ORCC;
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        shd_cnt  <= 0;
        shd_data <= 0;
    end else if(cen) begin
        shd_busy <= shd_cnt!=0;
        if( shd_en && shd_mux!=0 ) begin
            shd_data <= opnd1;
            shd_cnt  <= shd_mux;
            shd_busy <= 1;
        end else if( shd_cnt!=0 ) begin
            shd_cnt  <= shd_cnt-1'd1;
            shd_data <= rslt;
        end
    end
end

jtkcpu_div u_div(
    .rst  ( rst         ),
    .clk  ( clk         ),
    .cen  ( cen         ),
    .op0  ( opnd0       ),
    .op1  ( opnd1[7:0]  ),
    .len  ( 1'b1        ),
    .sign ( div_sign    ),
    .start( div_en      ),
    .quot ( div_quot    ),
    .rem  ( div_rem     ),
    .busy ( div_busy    ),
    .v    ( div_v       )
);

always @* begin
    c_out   = cc_in[CC_C];
    v_out   = cc_in[CC_V];
    z_out   = cc_in[CC_Z];
    n_out   = cc_in[CC_N];
    h_out   = cc_in[CC_H];
    e_out   = cc_in[CC_E];
    i_out   = cc_in[CC_I];
    f_out   = cc_in[CC_F];
    rslt    = opnd0;  // default value
    rslt_hi = 0;

    case (op)
        TSTA, TSTB, TSTD,
        STA,  STB,  STD,
        STX,  STY,  STU,  STS: begin
            rslt  = opnd0;
            v_out = 0;
        end
        LEAX, LEAY, LEAU, LEAS: begin
            rslt  = opnd0;
        end
        LDA_IMM, LDB_IMM, LDA_IDX, LDB_IDX, TST,
        LDD_IMM, LDD_IDX, LDX_IMM, LDX_IDX, LDY_IMM,
        LDY_IDX, LDU_IMM, LDU_IDX, LDS_IMM, LDS_IDX, TSTW: begin  // LD, ST, TST, TSTD, TSTW
            rslt  = opnd1;
            v_out = 0;
        end
        ADDA_IMM,ADDB_IMM,ADDA_IDX,ADDB_IDX: begin  // ADD
            {c_out, rslt[7:0]} = {1'b0, opnd0[7:0]} + {1'b0, opnd1[7:0]};
            v_out = opnd0[7]==opnd1[7] && opnd0[7]!=rslt[7];
            h_out = opnd0[4] ^ opnd1[4] ^ rslt[4];
        end
        ADDD_IMM,ADDD_IDX: begin  // ADD
            {c_out, rslt} = {1'b0, opnd0} + {1'b0, opnd1};
            v_out = opnd0[15]==opnd1[15] && opnd0[15]!=rslt[15];
        end
        ADCA_IMM,ADCB_IMM,ADCA_IDX,ADCB_IDX: begin  // ADC
            {c_out, rslt[7:0]} =  {1'b0, opnd0[7:0]} + {1'b0, opnd1[7:0]} + {8'd0,cc_in[CC_C]};
            v_out = opnd0[7]==opnd1[7] && opnd0[7]!=rslt[7];
            h_out = opnd0[4] ^ opnd1[4] ^ rslt[4];
        end
        SUBA_IMM, SUBB_IMM,
        SUBA_IDX, SUBB_IDX,
        CMPA_IMM, CMPB_IMM,
        CMPA_IDX, CMPB_IDX: begin  // SUB
            {c_out, rslt[7:0]} = {1'b0, opnd0[7:0]} - {1'b0, opnd1[7:0]};
            v_out = opnd0[7]!=opnd1[7] && opnd0[7]!=rslt[7];
        end
        SUBD_IMM, SUBD_IDX,
        CMPD_IMM, CMPD_IDX,
        CMPX_IMM, CMPX_IDX,
        CMPY_IMM, CMPY_IDX,
        CMPU_IMM, CMPU_IDX,
        CMPS_IMM, CMPS_IDX:  begin  // SUB/CMP
            {c_out, rslt} = {1'b0, opnd0} - {1'b0, opnd1};
            v_out = opnd0[15]!=opnd1[15] && opnd0[15]!=rslt[15];
        end
        SBCA_IMM,SBCB_IMM,SBCA_IDX,SBCB_IDX: begin   // SBC
            {c_out, rslt[7:0]} = {1'b0, opnd0[7:0]} - {1'b0, opnd1[7:0]} - {8'd0,cc_in[CC_C]};
            v_out = opnd0[7]!=opnd1[7] && opnd0[7]!=rslt[7];
        end
        ANDA_IMM, ANDB_IMM,
        ANDA_IDX, ANDB_IDX,
        BITA_IMM, BITB_IMM,
        BITA_IDX, BITB_IDX: begin  // AND, BIT
            rslt  = opnd0 & opnd1;
            v_out = 0;
        end
        EORA_IMM, EORB_IMM,
        EORA_IDX, EORB_IDX: begin    // EOR
            rslt  = opnd0 ^ opnd1;
            v_out = 0;
        end
        ORA_IMM, ORB_IMM,
        ORA_IDX, ORB_IDX: begin  // OR
            rslt  = opnd0 | opnd1;
            v_out = 0;
        end
        ANDCC: begin
            { e_out, f_out, h_out, i_out, n_out, z_out, v_out, c_out } = cc_in & opnd1[7:0];
        end
        ORCC: begin
            { e_out, f_out, h_out, i_out, n_out, z_out, v_out, c_out } = cc_in | opnd1[7:0];
        end
        CLRA,CLRB,CLR,CLRD,CLRW: begin  // CLR, CLRD, CLRW
            rslt  = 0;
            c_out = 0;
            v_out = 0;
        end
        COMA,COMB,COM: begin  // COM
            rslt  = ~opnd0;
            c_out = 1;
            v_out = 0;
        end
        NEGA,NEGB,NEG: begin  // NEG, NEGA , NEGB
            rslt[7:0] = ~opnd0[7:0] + 8'b1;
            c_out = opnd0[7:0]!=0; // done this way to match MAME's result
            v_out = opnd0[7]==rslt[7] && opnd0[7:0]!=0;
        end
        NEGD,NEGW: begin
            { c_out, rslt } = ~{ opnd0[15], opnd0 } + 17'b1;
            v_out = opnd0[15]==rslt[15];
        end
        INCA,INCB,INC,INCD,INCW: begin
            rslt  = opnd0 + 1'b1;
            v_out = ~opnd0[msb] & rslt[msb];
        end
        DECA,DECB,DEC,DECD,DECW: begin  // DEC, DECD, DECW
            rslt  = opnd0 - 1'b1;
            v_out = opnd0[msb] & ~rslt[msb];
        end

        LSRA,LSRB,LSR: begin
            {rslt[7:0], c_out} = {1'b0, opnd0[7:0]};
        end
        LSRW: begin
            {rslt[15:0], c_out} = {1'b0, opnd0[15:0]};
        end
        RORA,RORB,ROR: begin
            {rslt[7:0], c_out} = {cc_in[CC_C], opnd0[7:0]};
        end
        RORW: begin
            {rslt[15:0], c_out} = {cc_in[CC_C], opnd0[15:0]};
        end
        ROLW: begin
            {c_out, rslt[15:0]} = {opnd0[15:0], cc_in[CC_C]};
            v_out         =  opnd0[msb] ^ rslt[msb];
        end
        ASRA,ASRB,ASR,ASRW: begin
            rslt      = opnd0>>1;
            rslt[msb] = opnd0[msb];
            c_out     = opnd0[0];
        end
        ASLA,ASLB,ASL,ASLW: begin
            rslt  = opnd0 << 1;
            c_out = opnd0[msb];
            v_out = opnd0[msb] ^ rslt[msb];
        end
        ROLA,ROLB,ROL: begin
            {c_out, rslt[7:0]} = {opnd0[7:0], cc_in[CC_C]};
            v_out =  opnd0[msb] ^ rslt[msb];
        end

        ////////////// multi-shift operations on D register
        ASRD_IMM: if( shd_busy ) begin
            rslt      = opnd0>>1;
            rslt[msb] = opnd0[msb];
            c_out     = opnd0[0];
        end
        LSRD_IMM: if( shd_busy ) begin
            {rslt[15:0], c_out} = {1'b0, opnd0[15:0]};
        end
        ASLD_IMM: if( shd_busy ) begin
            rslt  = opnd0 << 1;
            c_out = opnd0[15];
            v_out = opnd0[15] ^ rslt[15];
        end
        RORD_IMM: if( shd_busy ) begin
            {rslt[15:0], c_out} = {cc_in[CC_C], opnd0[15:0]};
        end
        ROLD_IMM: if( shd_busy ) begin
            {c_out, rslt[15:0]} = {opnd0[15:0], cc_in[CC_C]};
            v_out =  opnd0[msb] ^ rslt[msb];
        end

        ////////////// multi-shift operations on 16-bit memory
        ASRD_IDX: if( shd_busy ) begin
            rslt      = shd_data>>1;
            rslt[msb] = shd_data[msb];
            c_out     = shd_data[0];
        end else begin
            rslt  = shd_data;
        end
        LSRD_IDX: if( shd_busy ) begin
            {rslt[15:0], c_out} = {1'b0, shd_data[15:0]};
        end else begin
            rslt  = shd_data;
        end
        ASLD_IDX: if( shd_busy ) begin
            rslt  = shd_data << 1;
            c_out = shd_data[15];
            v_out = shd_data[15] ^ rslt[15];
        end else begin
            rslt  = shd_data;
        end
        RORD_IDX: if( shd_busy ) begin
            {rslt[15:0], c_out} = {cc_in[CC_C], shd_data[15:0]};
        end else begin
            rslt  = shd_data;
        end
        ROLD_IDX: if( shd_busy ) begin
            {c_out, rslt[15:0]} = {shd_data[15:0], cc_in[CC_C]};
            v_out =  shd_data[msb] ^ rslt[msb];
        end else begin
            rslt  = shd_data;
        end

        ABX: rslt =  {8'h0, opnd0[7:0]} + opnd1 ;  // ABX
        DAA: begin  // DAA
            if ( c_out || opnd0[7:4] > 9 || (opnd0[7:4] > 8 && opnd0[3:0] > 9 ))
                rslt[7:4] = 6;
            else
                rslt[7:4] = 0;
            if ( h_out || opnd0[3:0] > 9 )
                rslt[3:0] = 6;
            else
                rslt[3:0] = 0;
            {rslt[8], rslt[7:0]} = {1'b0, opnd0[7:0]} + rslt[7:0];
            c_out = c_out | rslt[8];
            v_out = 0;
        end
        SEX: begin  // SEX
            rslt  = {{8{opnd0[7]}}, opnd0[7:0]};
            v_out = 0;
        end
        MUL: begin
            rslt  = opnd0[15:8]*opnd0[7:0];
            c_out = rslt[7];
        end
        LMUL: begin
            { rslt_hi, rslt }  = opnd0*opnd1;
            c_out = rslt_hi[15];
        end
        //
        ABSA, ABSB, ABSD: begin  // ABS
            if (opnd0[msb] )
                rslt = alu16 ? -opnd0 : {opnd0[15:8],-opnd0[7:0]};
            else
                rslt = opnd0;
            c_out = 0;
            v_out = opnd0[msb] & rslt[msb];
        end
        DIVXB: begin
            rslt    = div_quot;
            rslt_hi = {8'd0, div_rem};
        end
        default:
            rslt = opnd0;
    endcase

    if( dec8 || dec16 ) begin // this should be moved with the DEC above
        rslt  = opnd0 - 1'b1;
        v_out = opnd0[msb] & ~rslt[msb];
    end

    if( up_z )
        z_out = alu16 ? rslt==0 : rslt[7:0]==0;
    if( up_n )
        n_out = rslt[msb];
end

endmodule