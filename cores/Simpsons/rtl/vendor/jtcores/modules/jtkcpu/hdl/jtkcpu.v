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

/* verilator tracing_off */
module jtkcpu(
    input               rst,
    input               clk,
    input               cen2 /* synthesis direct_enable */,
    output              cen_out,

    input               halt,
    input               nmi_n,
    input               irq_n,
    input               firq_n,
    input               dtack,

    // memory bus
    //output            as
    input        [ 7:0] din,
    output       [ 7:0] dout,
    output       [23:0] addr,
    output              we,    // write enable
    output       [15:0] pcbad,
    output              buserror
`ifdef JTKCPU_DEBUG ,
    output       [15:0] x, y, u, s, pc,
    output       [ 7:0] a, b, cc, dp,
    output              is_op
`endif
);

`ifndef JTKCPU_DEBUG
`ifdef VERILATOR_KEEP_CPU /* verilator tracing_on */  `endif
wire [15:0] x, y, u, s, pc;
wire [ 7:0] a, b, cc, dp;
wire        is_op;
`ifdef VERILATOR_KEEP_CPU /* verilator tracing_off */ `endif
`endif

wire [31:0] rslt;
wire [15:0] opnd0, opnd1;
wire [15:0] mdata;
wire [15:0] psh_addr;
wire [15:0] nx_u, nx_s;
wire [ 7:0] cc_out;
wire [ 7:0] op, postbyte;
wire [ 7:0] stack_bit, psh_sel, psh_mux;
wire [ 3:0] intvec;
wire [ 2:0] idx_sel;
wire        hihalf, branch, memhi, shd_en, int_en,
            up_a, up_b, up_d, up_cc, up_x, up_y, up_u, up_s, up_pc,
            up_exg,   up_tfr, up_abx,  up_div,
            up_lines, up_lea, up_lmul, up_pul_pc, up_move,
            psh_dec,  us_sel,  pul_en, opnd0_mem, div_en,
            wrq, fetch, opd, addrx, addry,
            dec_b, dec_x, incx, decu,
            clr_e, set_e, set_f, set_i;
`ifdef VERILATOR_KEEP_CPU /* verilator tracing_on */  `endif
wire        alu_busy, mem_busy, stack_busy, str_busy;
`ifdef VERILATOR_KEEP_CPU /* verilator tracing_off */ `endif

// Indexed addressing
wire [15:0] idx_addr, idx_reg, idx_racc;
wire [ 2:0] idx_rsel;
wire [ 2:0] idx_asel;
wire        idx_post, idx_pre, idxw,  idx_ld, idx_en,
            idx_acc,  idx_adv, idx_8, idx_16, idx_dp,
            idx_pc,   data2addr, uz;

reg         clken=0 ,
            clken2=0,
            phase=0;

assign cen_out = clken2;

always @(negedge clk) begin
    if( dtack & cen2 ) begin
        phase <= ~phase;
    end
    clken  <= cen2 & dtack & phase;
    clken2 <= cen2 & dtack;
end

jtkcpu_ctrl u_ctrl(
    .rst          ( rst          ),
    .clk          ( clk          ),
    .cen          ( clken        ),

    .buserror     ( buserror     ),
    .pcbad        ( pcbad        ),
    .str_busy     ( str_busy     ),

    .op           ( op           ),
    .mdata        ( mdata        ),
    .psh_bit      ( stack_bit    ),
    .cc           ( cc           ),
    .halt         ( halt         ),
    .up_pc        ( up_pc        ),
    .uz           ( uz           ),

    .up_tfr       ( up_tfr       ),
    .up_exg       ( up_exg       ),
    .up_div       ( up_div       ),

    .opnd0_mem    ( opnd0_mem    ),
    // Indexed addressing
    .idx_addr     ( idx_addr     ),
    .idx_rsel     ( idx_rsel     ),   // register to modify
    .idx_asel     ( idx_asel     ),   // accumulator/register offset used
    .idx_post     ( idx_post     ),
    .idx_pre      ( idx_pre      ),
    .idxw         ( idxw         ),
    .idx_ld       ( idx_ld       ),
    .idx_8        ( idx_8        ),
    .idx_16       ( idx_16       ),
    .idx_acc      ( idx_acc      ),
    .idx_dp       ( idx_dp       ),
    .idx_en       ( idx_en       ),
    .idx_adv      ( idx_adv      ),
    .data2addr    ( data2addr    ),

    // System status
    .alu_busy     ( alu_busy     ),
    .mem_busy     ( mem_busy     ),
    .irq_n        ( irq_n        ),
    .firq_n       ( firq_n       ),
    .nmi_n        ( nmi_n        ),

    // Stack
    .psh_dec      ( psh_dec      ),
    .stack_busy   ( stack_busy   ),
    .psh_sel      ( psh_sel      ),
    .pul_en       ( pul_en       ),

    .addrx        ( addrx        ),
    .addry        ( addry        ),
    .up_move      ( up_move      ),
    .decu         ( decu         ),
    .incx         ( incx         ),

    .int_en       ( int_en       ),
    .clr_e        ( clr_e        ),
    .decb         ( dec_b        ),
    .decx         ( dec_x        ),
    .div_en       ( div_en       ),
    .fetch        ( fetch        ),
    .hihalf       ( hihalf       ),
    .intvec       ( intvec       ),
    .memhi        ( memhi        ),
    .opd          ( opd          ),
    .pc           ( pc           ),
    .set_e        ( set_e        ),
    .set_f        ( set_f        ),
    .set_i        ( set_i        ),
    .shd_en       ( shd_en       ),
    .up_a         ( up_a         ),
    .up_abx       ( up_abx       ),
    .up_b         ( up_b         ),
    .up_cc        ( up_cc        ),
    .up_d         ( up_d         ),
    .up_lea       ( up_lea       ),
    .up_lines     ( up_lines     ),
    .up_lmul      ( up_lmul      ),
    .up_s         ( up_s         ),
    .up_u         ( up_u         ),
    .up_x         ( up_x         ),
    .up_y         ( up_y         ),
    .us_sel       ( us_sel       ),
    .wrq          ( wrq          ),
    .up_pul_pc    ( up_pul_pc    )
);

jtkcpu_memctrl u_memctrl(
    .rst          ( rst          ),
    .clk          ( clk          ),
    .cen          ( clken        ),
    .cen2         ( clken2       ),

    // Indexed addressing
    .idx_addr     ( idx_addr     ),
    .idx_en       ( idx_en       ),
    .idx_adv      ( idx_adv      ),

    .pc           ( pc           ),
    .regs_x       ( x            ),
    .regs_y       ( y            ),
    .din          ( din          ),
    .dout         ( dout         ),
    .up_move      ( up_move      ),
    // Stack
    .psh_addr     ( psh_addr     ),
    .psh_dec      ( psh_dec      ),
    .psh_mux      ( psh_mux      ),
    .stack_busy   ( stack_busy   ),
    // Effective address
    .addr         ( addr[15:0]   ),
    .lines        ( addr[23:16]  ),

    .we           ( we           ),
    .op           ( op           ),
    .data         ( mdata        ),
    .busy         ( mem_busy     ),
    .up_pc        ( up_pc        ),
    .is_op        ( is_op        ),
    .memhi        ( memhi        ),
    .fetch        ( fetch        ),
    .halt         ( halt         ),
    .up_lines     ( up_lines     ),
    .addrx        ( addrx        ),
    .addry        ( addry        ),
    .opd          ( opd          ),
    .intvec       ( intvec       ),
    .alu_dout     ( rslt[15:0]   ),
    .wrq          ( wrq          )
);

jtkcpu_alu u_alu(
    .rst          ( rst          ),
    .clk          ( clk          ),
    .cen          ( clken        ),

    .op           ( op           ),
    .opnd0        ( opnd0        ),
    .opnd1        ( opnd1        ),
    .cc_in        ( cc           ),
    .cc_out       ( cc_out       ),
    .busy         ( alu_busy     ),
    // Special instructions
    .dec8         ( dec_b        ),
    .dec16        ( dec_x        ),
    .div_en       ( div_en       ),
    .shd_en       ( shd_en       ),
    .idx_en       ( idx_en       ),

    .rslt         ( rslt[15:0]   ),
    .rslt_hi      ( rslt[31:16]  )
);

jtkcpu_regs u_regs(
    .rst          ( rst          ),
    .clk          ( clk          ),
    .cen          ( clken        ),
    .cen2         ( clken2       ),

    .opnd0_mem    ( opnd0_mem    ),
    .pc           ( pc           ),
    .a            ( a            ),
    .b            ( b            ),
    .dp           ( dp           ),
    .x            ( x            ),
    .y            ( y            ),
    .u            ( u            ),
    .s            ( s            ),
    .cc           ( cc           ),
    .mdata        ( mdata        ),
    .op           ( op           ),
    .alu          ( rslt         ),
    .up_move      ( up_move      ),
    .uz           ( uz           ),
    .decu         ( decu         ),
    .incx         ( incx         ),

    .up_exg       ( up_exg       ),
    .up_tfr       ( up_tfr       ),

    .psh_sel      ( psh_sel      ),
    .psh_hihalf   ( hihalf       ),
    .psh_ussel    ( us_sel       ),
    .pul_en       ( pul_en       ),
    .stack_busy   ( stack_busy   ),

    // Indexed addressing
    .idx_rsel     ( idx_rsel     ),   // register to modify
    .idx_asel     ( idx_asel     ),   // accumulator/register offset used
    .idx_reg      ( idx_reg      ),
    .idx_racc     ( idx_racc     ),
    .idx_addr     ( idx_addr     ),
    .idx_post     ( idx_post     ),
    .idx_pre      ( idx_pre      ),
    .idxw         ( idxw         ),
    .idx_pc       ( idx_pc       ),

    .up_a         ( up_a         ),
    .up_b         ( up_b         ),
    .up_d         ( up_d         ),
    .up_abx       ( up_abx       ),
    .up_x         ( up_x         ),
    .up_y         ( up_y         ),
    .up_u         ( up_u         ),
    .up_s         ( up_s         ),
    .up_lmul      ( up_lmul      ),
    .up_div       ( up_div       ),
    .up_lea       ( up_lea       ),
    .up_cc        ( up_cc        ),
    .alu_cc       ( cc_out       ),
    .int_en       ( int_en       ),
    .set_e        ( set_e        ),
    .set_i        ( set_i        ),
    .set_f        ( set_f        ),
    .clr_e        ( clr_e        ),
    .dec_x        ( dec_x        ),
    .dec_b        ( dec_b        ),
    .psh_dec      ( psh_dec      ),

    .opnd0        ( opnd0        ),
    .opnd1        ( opnd1        ),
    .nx_u         ( nx_u         ),
    .nx_s         ( nx_s         ),
    .psh_addr     ( psh_addr     ),
    .psh_mux      ( psh_mux      ),
    .stack_bit    ( stack_bit    ),
    .up_pul_pc    ( up_pul_pc    )
);

jtkcpu_idx u_idx(
    .rst          ( rst          ),
    .clk          ( clk          ),
    .cen          ( clken        ),

    .idx_reg      ( idx_reg      ),
    .idx_racc     ( idx_racc     ),
    .dp           ( dp           ),
    .mdata        ( mdata        ),
    // Control
    .idx_ld       ( idx_ld       ),
    .idx_8        ( idx_8        ),
    .idx_16       ( idx_16       ),
    .idx_acc      ( idx_acc      ),
    .idx_dp       ( idx_dp       ),
    .idx_pc       ( idx_pc       ),
    .data2addr    ( data2addr    ),

    .addr         ( idx_addr     )
);

endmodule
