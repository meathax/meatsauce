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
    Date: 3-03-2023 */

module jtkcpu_ctrl(
    input             rst,
    input             clk,
    input             cen /* synthesis direct_enable */,

    input      [15:0] mdata,
    input      [ 7:0] psh_bit,
    input      [ 7:0] op,
    input      [ 7:0] cc,

    input             halt,

    input             up_pc,
    input             up_pul_pc,

     // System status
    input             irq_n,
    input             nmi_n,
    input             firq_n,
    input             alu_busy,
    input             mem_busy,
    input             uz,


    // indexed addressing
    input     [15:0] idx_addr,
    output    [ 2:0] idx_rsel,
    output    [ 2:0] idx_asel,
    output           idx_post,
    output           idx_pre,
    output           idxw,
    output           idx_ld,
    output           idx_8,
    output           idx_16,
    output           idx_acc,
    output           idx_dp,
    output           idx_en,
    output           data2addr,

    // stack
    output     [ 7:0] psh_sel,
    output            pul_en,
    output            stack_busy,
    output            us_sel,
    // Direct microcode outputs
    output            addrx,
    output            addry,
    output            up_move,
    output            incx,
    output            decu,
    output            div_en,

    output            int_en,
    output            up_tfr,
    output            up_exg,

    output            idx_adv,
    output            psh_dec,
    output            hihalf,
    output            memhi,
    output            opd,
    output            up_lea,
    output            up_lines,
    output            up_lmul,
    output            up_div,
    output            wrq,
    output            decb,
    output            decx,
    output            fetch,
    output            set_i,
    output            set_e,
    output            set_f,
    output            shd_en,
    output            clr_e,
    output            up_cc,

    output     [ 3:0] intvec,

    // Derived logic
    output            up_a,
    output            up_b,
    output            up_d,
    output            up_abx,
    output            up_x,
    output            up_y,
    output            up_u,
    output            up_s,
    output            opnd0_mem,

    output reg [15:0] pc, pcbad,
    output            buserror,
    output            str_busy
);

`include "jtkcpu.inc"

wire branch,  niuz,   ni;
wire pul_go,  psh_go, psh_all, psh_cc, psh_pc,
     up_ld16, up_ld8,  up_lda, up_ldb,  up_ab,
     rti_cc,  rti_other,
     set_pc_branch16, set_pc_branch8, branch_bnz,
     pc_jmp, pc_inc1, pc_inc2, pc_step,
     intsrv;

assign up_a    = ( up_ld8 && ~op[0] ) || up_lda;
assign up_b    = ( up_ld8 &&  op[0] ) || up_ldb || up_div;

assign up_d    = (up_ld16 && op[3:1]==0) || up_ab;
assign up_x    = (up_ld16 && op[3:1]==1) || (up_lea && op[1:0]==LEAX[1:0]) || up_lmul || up_div;
assign up_y    = (up_ld16 && op[3:1]==2) || (up_lea && op[1:0]==LEAY[1:0]) || up_lmul;
assign up_u    = (up_ld16 && op[3:1]==3) || (up_lea && op[1:0]==LEAU[1:0]);
assign up_s    = (up_ld16 && op[3:1]==4) || (up_lea && op[1:0]==LEAS[1:0]);
assign pc_inc1 = idx_post && !idxw && idx_rsel==7;
assign pc_inc2 = idx_post &&  idxw && idx_rsel==7;
assign fetch   = ni || (niuz&&uz);
assign pc_step = (ni&&!intsrv) || opd || pc_inc1 || (niuz && uz );

wire sbranch   = (set_pc_branch8  & branch) | ( branch_bnz & ~cc[CC_Z]);
wire lbranch   = (set_pc_branch16 & branch);
reg  bdone;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        pc    <= 0;
        bdone <= 0;
        pcbad <= 0;
    end else if(cen) begin
        pc <= pc_jmp  ? idx_addr :
              pc_step ? pc+16'd1 :
              pc_inc2 ? pc+16'd2 :
              sbranch && !bdone ? { {8{mdata[7]}}, mdata[7:0]}+pc :
              lbranch && !bdone ? mdata+pc :
              up_pc        ? mdata    : pc;
        if( buserror ) pcbad <= pc;
        bdone <= sbranch | lbranch;
        if( up_pul_pc && pul_en ) begin
            if( hihalf )  pc[15:8] <= mdata[7:0];
                     else pc[ 7:0] <= mdata[7:0];
        end

    end
end

jtkcpu_ucode u_ucode(
    .rst               ( rst               ),
    .clk               ( clk               ),
    .cen               ( cen               ),
    .buserror          ( buserror          ),
    .str_busy          ( str_busy          ),

    .cc                ( cc                ),
    .op                ( op                ),
    .mdata             ( mdata             ),
    .intsrv            ( intsrv            ),

    .alu_busy          ( alu_busy          ),
    .mem_busy          ( mem_busy          ),
    .stack_busy        ( stack_busy        ),

    .branch            ( branch            ),
    .irq_n             ( irq_n             ),
    .nmi_n             ( nmi_n             ),
    .firq_n            ( firq_n            ),
    .intvec            ( intvec            ),
    .uz                ( uz                ),

    .addrx             ( addrx             ),
    .addry             ( addry             ),
    .up_move           ( up_move           ),
    .decu              ( decu              ),
    .incx              ( incx              ),
    .clr_e             ( clr_e             ),
    .decb              ( decb              ),
    .decx              ( decx              ),
    .up_abx            ( up_abx            ),
    // Indexed addressing
    .idx_rsel          ( idx_rsel          ),
    .idx_asel          ( idx_asel          ),
    .idx_post          ( idx_post          ),
    .idx_pre           ( idx_pre           ),
    .idxw              ( idxw              ),
    .idx_ld            ( idx_ld            ),
    .idx_8             ( idx_8             ),
    .idx_16            ( idx_16            ),
    .idx_acc           ( idx_acc           ),
    .idx_dp            ( idx_dp            ),
    .idx_en            ( idx_en            ),
    .idx_adv           ( idx_adv           ),
    .data2addr         ( data2addr         ),

    .up_tfr            ( up_tfr            ),
    .up_exg            ( up_exg            ),

    .branch_bnz        ( branch_bnz        ),
    .div_en            ( div_en            ),
    .int_en            ( int_en            ),
    .memhi             ( memhi             ),
    .ni                ( ni                ),
    .niuz              ( niuz              ),
    .opd               ( opd               ),
    .pc_jmp            ( pc_jmp            ),
    .psh_all           ( psh_all           ),
    .psh_cc            ( psh_cc            ),
    .psh_go            ( psh_go            ),
    .psh_pc            ( psh_pc            ),
    .pul_go            ( pul_go            ),
    .rti_cc            ( rti_cc            ),
    .rti_other         ( rti_other         ),
    .set_e             ( set_e             ),
    .set_f             ( set_f             ),
    .set_i             ( set_i             ),
    .set_opn0_mem      ( opnd0_mem         ),
    .set_pc_branch16   ( set_pc_branch16   ),
    .set_pc_branch8    ( set_pc_branch8    ),
    .shd_en            ( shd_en            ),
    .up_ab             ( up_ab             ),
    .up_cc             ( up_cc             ),
    .up_ld16           ( up_ld16           ),
    .up_ld8            ( up_ld8            ),
    .up_lda            ( up_lda            ),
    .up_ldb            ( up_ldb            ),
    .up_lea            ( up_lea            ),
    .up_lines          ( up_lines          ),
    .up_lmul           ( up_lmul           ),
    .up_div            ( up_div            ),
    .we                ( wrq               ),
    // Debug
    .irq_bsy           (                   )

);

jtkcpu_branch u_branch(
    .op         ( op         ),
    .cc         ( cc         ),
    .branch     ( branch     )
);

jtkcpu_pshpul u_pshpul(
    .rst        ( rst        ),
    .clk        ( clk        ),
    .cen        ( cen        ),

    .op         ( op         ),
    .postdata   ( mdata      ),
    .cc         ( cc         ),
    .psh_all    ( psh_all    ),
    .rti_cc     ( rti_cc     ),
    .rti_other  ( rti_other  ),
    .psh_cc     ( psh_cc     ),
    .pul_go     ( pul_go     ),
    .psh_go     ( psh_go     ),
    .psh_pc     ( psh_pc     ),
    .psh_bit    ( psh_bit    ),
    .hihalf     ( hihalf     ),
    .pul_en     ( pul_en     ),
    .psh_dec    ( psh_dec    ),
    .psh_sel    ( psh_sel    ),
    .busy       ( stack_busy ),
    .us_sel     ( us_sel     )
);

endmodule
