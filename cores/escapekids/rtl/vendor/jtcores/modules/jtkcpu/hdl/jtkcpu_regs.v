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

module jtkcpu_regs(
    input               rst,
    input               clk,
    input               cen /* synthesis direct_enable */,
    input               cen2,

    input        [15:0] pc,
    input        [15:0] mdata,     // postbyte used to select specific registers
    input        [ 7:0] op,        // op code used to select specific registers
    input               opnd0_mem,

    // Register update
    input        [31:0] alu,
    input               up_a,
    input               up_b,
    input               up_d,
    input               up_x,
    input               up_abx,
    input               up_y,
    input               up_u,
    input               up_s,
    input               up_lmul,
    input               up_div,
    input               up_lea,

    // Exchange / Transfer
    input               up_tfr,
    input               up_exg,

    // MOVE/BSET
    input               up_move,
    input               incx,
    input               decu,

    // Flags from ALU
    input        [ 7:0] alu_cc,
    input               up_cc,
    // Flags from control
    input               int_en,
    input               set_e,
    input               set_i,
    input               set_f,
    input               clr_e,

    // Direct increment/decrement
    input               dec_x,
    input               dec_b,

    // Stack
    input        [ 7:0] psh_sel,
    input               psh_hihalf,
    input               psh_ussel,
    input               pul_en,
    input               psh_dec,
    input               stack_busy,

    output       [15:0] psh_addr,
    output       [ 7:0] stack_bit,
    output   reg [ 7:0] psh_mux,
    output   reg        up_pul_pc,

    // Index addressing
    input        [15:0] idx_addr,
    input        [ 2:0] idx_rsel,   // register to modify
    input        [ 2:0] idx_asel,   // accumulator/register offset used
    input               idx_post,
    input               idx_pre,
    input               idxw,
    output              idx_pc,

    output       [15:0] idx_racc,
    output       [15:0] idx_reg,

    output   reg [15:0] opnd0,
    output   reg [15:0] opnd1,
    output   reg [15:0] nx_u,
    output   reg [15:0] nx_s,
    output   reg [15:0] x,
    output   reg [15:0] y,
    output   reg [15:0] u,
    output   reg [15:0] s,
    output   reg [ 7:0] a,
    output   reg [ 7:0] b,
    output   reg [ 7:0] cc,
    output   reg [ 7:0] dp,
    output   reg        uz
);

`include "jtkcpu.inc"

reg         psh_dec_u, psh_dec_s, inc_pul,
            up_pul_x, up_pul_y, up_pul_other,
            up_pul_a, up_pul_b, up_pul_dp, up_pul_cc;
reg  [ 7:0] psh_bit, pul_bit;
reg  [15:0] stfr, dtfr;
wire [15:0] psh_other;
wire        idx_upx, idx_upy, idx_upu, idx_ups;
wire [15:0] idx_step;
wire        idx_x, idx_y, idx_u, idx_s;

assign stack_bit = pul_en ? pul_bit : psh_bit;
assign psh_addr  = psh_ussel ? u : s;
assign psh_other = psh_ussel ? s : u;
// Indexed increments/decrements
assign idx_x     = idx_rsel==2,
       idx_y     = idx_rsel==3,
       idx_u     = idx_rsel==5,
       idx_s     = idx_rsel==6,
       idx_pc    = idx_rsel==7;
assign idx_reg   = idx_x ? x : idx_y ? y : idx_u ? u : idx_s ? s : pc;
assign idx_racc  = idx_asel==0 ? { {8{a[7]}},a } :
                   idx_asel==1 ? { {8{b[7]}},b } :
                   idx_asel==2 ? x :
                   idx_asel==3 ? y :
                   idx_asel==5 ? u :
                   idx_asel==6 ? s : { a, b };
assign idx_upx   = (idx_post || idx_pre) && idx_x,
       idx_upy   = (idx_post || idx_pre) && idx_y,
       idx_upu   = (idx_post || idx_pre) && idx_u,
       idx_ups   = (idx_post || idx_pre) && idx_s;
assign idx_step  = idx_post ? (idxw ? 16'd2 : 16'd1) : (idxw ? -16'd2 : -16'd1);

// exg/tfr
always @* begin
    stfr = u;
    dtfr = u;
    case( mdata[6:4] )
        3'b000:  dtfr[7:0] = a;
        3'b001:  dtfr[7:0] = b;
        3'b010:  dtfr      = x;
        3'b011:  dtfr      = y;
        3'b100:  dtfr      = s;
        3'b101:  dtfr      = u;
        default:;
    endcase

    case( mdata[2:0] )
        3'b000:  stfr[7:0] = a;
        3'b001:  stfr[7:0] = b;
        3'b010:  stfr      = x;
        3'b011:  stfr      = y;
        3'b100:  stfr      = s;
        3'b101:  stfr      = u;
        default:;
    endcase
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        opnd0 <= 0;
    end else if( cen2 ) begin
        case ( op )
            ADDB_IMM, SUBB_IMM, ANDB_IMM, EORB_IMM, ORB_IMM, CLRB, NEGB, ASRB, ABX,
            ADDB_IDX, SUBB_IDX, ANDB_IDX, EORB_IDX, ORB_IDX, COMB, TSTB, ASLB, MUL,
            ADCB_IMM, SBCB_IMM, BITB_IMM, CMPB_IMM, DECB,    LSRB, ROLB,       SEX,
            ADCB_IDX, SBCB_IDX, BITB_IDX, CMPB_IDX, INCB,          RORB, ABSB, STB: opnd0 <= {a, b}; // "a" will be ignored

            CMPD_IDX, ADDD_IMM, SUBD_IMM, LSRD_IMM, RORD_IMM, ASRD_IMM, ASLD_IMM, ROLD_IMM,
            CMPD_IMM, ADDD_IDX, SUBD_IDX, LSRD_IDX, RORD_IDX, ASRD_IDX, ASLD_IDX, ROLD_IDX,
                CLRD,     NEGD,     ABSD,      STD: opnd0 <= {a, b};

            CMPX_IMM, CMPX_IDX, STX, DIVXB: opnd0 <= x;
            CMPY_IMM, CMPY_IDX, STY, LMUL:  opnd0 <= y;
            CMPU_IMM, CMPU_IDX, STU:        opnd0 <= u;
            CMPS_IMM, CMPS_IDX, STS:        opnd0 <= s;
            LEAX, LEAY, LEAU, LEAS:         opnd0 <= idx_addr;

            ANDCC, ORCC: opnd0 <= {a, cc};

            default : opnd0 <= {a, a};
        endcase
        if( opnd0_mem    ) opnd0 <= mdata;
        if( dec_b | incx | up_d ) opnd0 <= {a, b};
        if( incx & decu  ) opnd0 <= {a, a};
        if( dec_x        ) opnd0 <= x;
    end
end

always @* begin
    case ( op )
        DIVXB:     opnd1 = {8'h0,  b};
        ABX, LMUL: opnd1 = x;
        default:   opnd1 = mdata;
    endcase
end

// U/S next value
always @* begin
    inc_pul = psh_sel!=0 && stack_busy;
    psh_dec_u = 0;
    psh_dec_s = 0;
    if ( psh_dec && psh_sel!=0 ) begin
        if (psh_ussel)
            psh_dec_u = 1;
        else
            psh_dec_s = 1;
    end
    nx_u = u;
    nx_s = s;
    if( up_s  ) nx_s = up_lea ? idx_addr : mdata;
    if( up_u  ) nx_u = up_lea ? idx_addr : mdata;
    if( psh_dec_u | up_move | decu ) nx_u = u - 16'd1;
    if( psh_dec_s         ) nx_s = s - 16'd1;
    if( up_pul_other &&  psh_hihalf ) begin
        if( psh_ussel )
            nx_s[15:8] = mdata[7:0];
        else
            nx_u[15:8] = mdata[7:0];
    end
    if( up_pul_other && !psh_hihalf ) begin
        if( psh_ussel )
            nx_s[ 7:0] = mdata[7:0];
        else
            nx_u[ 7:0] = mdata[7:0];
    end
    if( !psh_dec && inc_pul &&  psh_ussel ) nx_u = u + 16'd1;
    if( !psh_dec && inc_pul && !psh_ussel ) nx_s = s + 16'd1;
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        psh_mux <= 0;
        psh_bit <= 0;
        pul_bit <= 0;
    end else if( cen2 ) begin
        // PUSH
        casez( psh_sel )
            8'b1???_????: begin psh_mux <= psh_hihalf ? pc[15:8] : pc[7:0]; psh_bit <= 8'h80; end
            8'b01??_????: begin psh_mux <= psh_hihalf ? psh_other[15:8] : psh_other[7:0]; psh_bit <= 8'h40; end
            8'b001?_????: begin psh_mux <= psh_hihalf ? y[15:8] : y[7:0]; psh_bit <= 8'h20; end
            8'b0001_????: begin psh_mux <= psh_hihalf ? x[15:8] : x[7:0]; psh_bit <= 8'h10; end
            8'b0000_1???: begin psh_mux <= dp; psh_bit <= 8'h8; end
            8'b0000_01??: begin psh_mux <=  b; psh_bit <= 8'h4; end
            8'b0000_001?: begin psh_mux <=  a; psh_bit <= 8'h2; end
            8'b0000_0001: begin psh_mux <= cc; psh_bit <= 8'h1; end
            default:      begin psh_mux <= 0;  psh_bit <= 8'h0; end
        endcase
        // PULL bit
        casez( psh_sel )
            8'b????_???1: pul_bit <= 8'h01;
            8'b????_??10: pul_bit <= 8'h02;
            8'b????_?100: pul_bit <= 8'h04;
            8'b????_1000: pul_bit <= 8'h08;
            8'b???1_0000: pul_bit <= 8'h10;
            8'b??10_0000: pul_bit <= 8'h20;
            8'b?100_0000: pul_bit <= 8'h40;
            8'b1000_0000: pul_bit <= 8'h80;
            default:      pul_bit <= 0;
        endcase
    end
end

// PULL
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        up_pul_cc    <= 0;
        up_pul_a     <= 0;
        up_pul_b     <= 0;
        up_pul_dp    <= 0;
        up_pul_x     <= 0;
        up_pul_y     <= 0;
        up_pul_other <= 0;
        up_pul_pc    <= 0;
    end else if( cen ) begin
        up_pul_cc    <= 0;
        up_pul_a     <= 0;
        up_pul_b     <= 0;
        up_pul_dp    <= 0;
        up_pul_x     <= 0;
        up_pul_y     <= 0;
        up_pul_other <= 0;
        up_pul_pc    <= 0;
        casez( psh_sel )
            8'b????_???1: up_pul_cc    <= pul_en;
            8'b????_??10: up_pul_a     <= pul_en;
            8'b????_?100: up_pul_b     <= pul_en;
            8'b????_1000: up_pul_dp    <= pul_en;
            8'b???1_0000: up_pul_x     <= pul_en;
            8'b??10_0000: up_pul_y     <= pul_en;
            8'b?100_0000: up_pul_other <= pul_en;
            8'b1000_0000: up_pul_pc    <= pul_en;
            default:;
        endcase
    end
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        a  <= 0;
        b  <= 0;
        dp <= 0;
        x  <= 0;
        y  <= 0;
        u  <= 0;
        s  <= 0;
        cc <= 0;
        uz <= 0;
    end else if(cen) begin
        uz <= u==0;
        u <= nx_u;
        s <= nx_s;
        if( idx_upx ) x <= x + idx_step;
        if( idx_upy ) y <= y + idx_step;
        if( idx_upu ) u <= u + idx_step;
        if( idx_ups ) s <= s + idx_step;

        if( up_a         ) a <= alu[7:0];
        if( up_b | dec_b ) b <= alu[7:0];
        if( up_div       ) b <= alu[16+:8];
        if( up_pul_a     ) a <= mdata[7:0];
        if( up_pul_b     ) b <= mdata[7:0];

        if( up_d ) begin
            a <= alu[15:8];
            b <= alu[ 7:0];
        end

        if( up_pul_dp ) dp <= mdata[7:0];

        if( up_x    ) x <= up_lea ? idx_addr : mdata;
        if( up_lmul ) x <= alu[31:16];
        if( up_abx || up_div || dec_x ) x <= alu[15: 0];

        if( up_y    ) y <= up_lea ? idx_addr : mdata;
        if( up_lmul ) y <= alu[15:0];
        // 16-bit registers from memory (PULL)
        if( up_pul_x &&  psh_hihalf ) x[15:8] <= mdata[7:0];
        if( up_pul_x && !psh_hihalf ) x[ 7:0] <= mdata[7:0];
        if( up_pul_y &&  psh_hihalf ) y[15:8] <= mdata[7:0];
        if( up_pul_y && !psh_hihalf ) y[ 7:0] <= mdata[7:0];

        // inc/dec
        if( up_move | incx ) x <= x + 16'd1;
        if( up_move        ) y <= y + 16'd1;

        if( up_cc     ) cc <= alu_cc;
        if( up_pul_cc ) cc <= mdata[7:0];
        if( set_e ) cc[CC_E] <= 1;
        if( set_i & int_en ) cc[CC_I] <= 1;
        if( set_f & int_en ) cc[CC_F] <= 1;
        if( clr_e ) cc[CC_E] <= 0;

        if( up_tfr || up_exg ) begin
            case(mdata[6:4])
                0: a <= stfr[7:0];
                1: b <= stfr[7:0];
                2: x <= stfr;
                3: y <= stfr;
                4: s <= stfr;
                5: u <= stfr;
                default:;
            endcase
        end
        if( up_exg ) begin
            case(mdata[2:0])
                0: a <= dtfr[7:0];
                1: b <= dtfr[7:0];
                2: x <= dtfr;
                3: y <= dtfr;
                4: s <= dtfr;
                5: u <= dtfr;
                default:;
            endcase
        end
    end
end

endmodule
