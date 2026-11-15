/*  This file is part of JTOPL.

    JTOPL is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTOPL is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTOPL.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 17-6-2020

    */

module psychos_jtopl_eg (
    input               rst,
    input               clk,
    input               cenop,
    input               zero,
    input               eg_stop,
    // envelope configuration
    input               en_sus_I, // enable sustain
    input       [3:0]   keycode_II,
    input       [3:0]   arate_I, // attack  rate
    input       [3:0]   drate_I, // decay   rate
    input       [3:0]   rrate_I, // release rate
    input       [3:0]   sl_I,   // sustain level
    input               ksr_II,     // key scale
    // envelope operation
    input               keyon_I,
    // envelope number
    input       [9:0]   fnum_I,
    input       [2:0]   block_I,
    input       [3:0]   lfo_mod,
    input               amsen_IV,
    input               ams_IV,
    input       [5:0]   tl_IV,
    input       [1:0]   ksl_IV,

    output  reg [9:0]   eg_V,
    output  reg         pg_rst_II
);

parameter SLOTS=18;

wire [14:0] eg_cnt;

psychos_jtopl_eg_cnt u_egcnt(
    .rst    ( rst   ),
    .clk    ( clk   ),
    .cen    ( cenop & ~eg_stop ),
    .zero   ( zero  ),
    .eg_cnt ( eg_cnt)
);

wire keyon_last_I;
wire keyon_now_I  = !keyon_last_I && keyon_I;
wire keyoff_now_I = keyon_last_I && !keyon_I;

wire cnt_in_II, cnt_lsb_II, step_II, pg_rst_I;

wire [2:0] state_in_I, state_next_I;

reg attack_II, attack_III;
wire [4:0] base_rate_I;
reg  [4:0] base_rate_II;
wire  [5:0] rate_out_II;
reg  [5:1] rate_in_III;
reg step_III;
reg [3:0] drate_II, rrate_II, sl_II;
reg en_sus_II;
reg fast_stage_II_valid;
wire [6:0] keyon_rate_II = {1'b0,base_rate_II,1'b0} +
    ({3'd0,keycode_II} >> (ksr_II ? 2'd0 : 2'd2));
wire fast_keyon_II = !rst && fast_stage_II_valid && pg_rst_II && attack_II &&
    keyon_rate_II >= 7'd62;
wire [4:0] fast_base_rate_II;
wire [2:0] fast_state_II;
wire [4:0] effective_base_rate_II = fast_keyon_II ? fast_base_rate_II : base_rate_II;
wire effective_attack_II = fast_keyon_II ? fast_state_II[0] : attack_II;

// Keycode/KSR belong to this operator in Stage II. A fast keyon first
// clamps its attenuation to zero, then performs the normal zero-EG
// attack-to-decay/sustain transition before its first envelope increment.
psychos_jtopl_eg_ctrl u_fast_keyon_ctrl(
    .keyon_now(1'b0), .keyoff_now(1'b0), .state_in(3'b001), .eg(10'd0),
    .en_sus(en_sus_II), .arate(4'd0), .drate(drate_II),
    .rrate(rrate_II), .sl(sl_II), .base_rate(fast_base_rate_II),
    .state_next(fast_state_II), .pg_rst()
);
always @(posedge clk)
    if(rst) fast_stage_II_valid <= 1'b0;
    else if(cenop) fast_stage_II_valid <= 1'b1;
wire sum_out_II;
reg sum_in_III;

wire [9:0] eg_in_I, pure_eg_out_III, eg_next_III, eg_out_IV;
reg  [9:0] eg_in_II, eg_in_III, eg_in_IV;
reg  [3:0] keycode_III, keycode_IV;
wire [3:0] fnum_IV;
wire [2:0] block_IV;


psychos_jtopl_eg_comb u_comb(
    ///////////////////////////////////
    // I
    .keyon_now      ( keyon_now_I   ),
    .keyoff_now     ( keyoff_now_I  ),
    .state_in       ( state_in_I    ),
    .eg_in          ( eg_in_I       ),
    // envelope configuration
    .en_sus         ( en_sus_I      ),
    .arate          ( arate_I       ), // attack  rate
    .drate          ( drate_I       ), // decay   rate
    .rrate          ( rrate_I       ),
    .sl             ( sl_I          ),   // sustain level

    .base_rate      ( base_rate_I   ),
    .state_next     ( state_next_I  ),
    .pg_rst         ( pg_rst_I      ),
    ///////////////////////////////////
    // II
    .step_attack    ( effective_attack_II ),
    .step_rate_in   ( effective_base_rate_II ),
    .keycode        ( keycode_II    ),
    .eg_cnt         ( eg_cnt        ),
    .cnt_in         ( cnt_in_II     ),
    .ksr            ( ksr_II        ),
    .cnt_lsb        ( cnt_lsb_II    ),
    .step           ( step_II       ),
    .step_rate_out  ( rate_out_II   ),
    .sum_up_out     ( sum_out_II    ),
    ///////////////////////////////////
    // III
    .pure_attack    ( attack_III        ),
    .pure_step      ( step_III          ),
    .pure_rate      ( rate_in_III[5:1]  ),
    .pure_eg_in     ( eg_in_III         ),
    .pure_eg_out    ( pure_eg_out_III   ),
    .sum_up_in      ( sum_in_III        ),
    ///////////////////////////////////
    // IV
    .fnum           ( fnum_IV       ),
    .block          ( block_IV      ),
    .lfo_mod        ( lfo_mod       ),
    .amsen          ( amsen_IV      ),
    .ams            ( ams_IV        ),
    .ksl            ( ksl_IV        ),
    .tl             ( tl_IV         ),
    .final_keycode  ( keycode_IV    ),
    .final_eg_in    ( eg_in_IV      ),
    .final_eg_out   ( eg_out_IV     )
);

always @(posedge clk) if(cenop) begin
    eg_in_II    <= eg_in_I;
    attack_II   <= state_next_I[0];
    base_rate_II<= base_rate_I;
    drate_II <= drate_I;
    rrate_II <= rrate_I;
    sl_II <= sl_I;
    en_sus_II <= en_sus_I;
    pg_rst_II   <= pg_rst_I;

    eg_in_III   <= fast_keyon_II ? 10'd0 : eg_in_II;
    attack_III  <= effective_attack_II;
    rate_in_III <= rate_out_II[5:1];
    step_III    <= step_II;
    sum_in_III  <= sum_out_II;

    eg_in_IV    <= pure_eg_out_III;
    eg_V        <= eg_out_IV;

    keycode_III <= keycode_II;
    keycode_IV  <= keycode_III;
end

psychos_jtopl_sh #( .width(1), .stages(SLOTS) ) u_cntsh(
    .clk    ( clk       ),
    .cen    ( cenop     ),
    .din    ( cnt_lsb_II),
    .drop   ( cnt_in_II )
);

psychos_jtopl_sh #( .width(4), .stages(3) ) u_fnumsh(
    .clk    ( clk         ),
    .cen    ( cenop       ),
    .din    ( fnum_I[9:6] ),
    .drop   ( fnum_IV     )
);

psychos_jtopl_sh #( .width(3), .stages(3) ) u_blocksh(
    .clk    ( clk         ),
    .cen    ( cenop       ),
    .din    ( block_I     ),
    .drop   ( block_IV    )
);

psychos_jtopl_sh_rst #( .width(10), .stages(SLOTS-3), .rstval(1'b1) ) u_egsh(
    .clk    ( clk       ),
    .cen    ( cenop     ),
    .rst    ( rst       ),
    .din    ( eg_in_IV  ),
    .drop   ( eg_in_I   )
);

psychos_jtopl_eg_state #(.STAGES(SLOTS)) u_egstate(
    .clk    ( clk           ),
    .cen    ( cenop         ),
    .rst    ( rst           ),
    .din    ( state_next_I  ),
    .patch  ( fast_keyon_II ),
    .patch_state ( fast_state_II ),
    .drop   ( state_in_I    )
);

psychos_jtopl_sh_rst #( .width(1), .stages(SLOTS), .rstval(1'b0) ) u_konsh(
    .clk    ( clk           ),
    .cen    ( cenop         ),
    .rst    ( rst           ),  
    .din    ( keyon_I       ),
    .drop   ( keyon_last_I  )
);


endmodule // psychos_jtopl_eg

// Preserve the original 18-enable state history and reset values. Stage II
// corrects only the preceding Stage-I entry as it advances into stage 1.
// Its consumer epoch, normal shifts and asserted-reset behavior stay fixed.
module psychos_jtopl_eg_state #(parameter STAGES=18)(
    input clk, input cen, input rst, input [2:0] din,
    input patch, input [2:0] patch_state, output [2:0] drop
);
reg [3*STAGES-1:0] shreg;
assign drop=shreg[3*STAGES-1 -: 3];
always @(posedge clk) begin
    if(cen) begin
        shreg <= {shreg[3*STAGES-4:0],rst ? 3'b111 : din};
        if(!rst && patch) shreg[5:3] <= patch_state;
    end
end
endmodule
