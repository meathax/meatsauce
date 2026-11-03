/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 26-9-2021 */

module jtcop_ongen(
    input                rst,
    input                clk,
    input                cen_opn,
    input                cen_opl,

    input                cpu_a0,
    input                cpu_rnw,
    input         [ 7:0] cpu_dout,

    input                opl_cs,
    output               opl_irqn,
    output        [ 7:0] opl_dout,

    input                oki_wrn,
    output        [ 7:0] oki_dout,

    input                opn_cs,
    output               opn_irqn,
    output        [ 7:0] opn_dout,
    // ADPCM ROM
    output        [17:0] adpcm_addr,
    output               adpcm_cs,
    input         [ 7:0] adpcm_data,
    input                adpcm_ok,

    output signed [15:0] opn, opl,
    output signed [13:0] pcm,
    output        [ 9:0] psg
);

wire signed [15:0] opl_snd, opn_snd;
wire signed [15:0] adpcm_snd;
wire signed [13:0] oki_pre;

/* verilator tracing_on */
jtopl2 u_opl(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .cen    ( cen_opl   ),
    .din    ( cpu_dout  ),
    .addr   ( cpu_a0    ),
    .cs_n   ( ~opl_cs   ),
    .wr_n   ( cpu_rnw   ),
    .dout   ( opl_dout  ),
    .irq_n  ( opl_irqn  ),
    .snd    ( opl       ),
    .sample (           )
);
/* verilator tracing_off */
jt03 u_2203(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .cen    ( cen_opn   ),
    .din    ( cpu_dout  ),
    .addr   ( cpu_a0    ),
    .cs_n   ( ~opn_cs   ),
    .wr_n   ( cpu_rnw   ),

    .dout   ( opn_dout  ),
    .irq_n  ( opn_irqn  ),
    // I/O pins used by YM2203 embedded YM2149 chip
    .IOA_in (           ),
    .IOB_in (           ),
    .IOA_out(           ),
    .IOB_out(           ),
    .debug_view(        ),
    .IOA_oe (           ),
    .IOB_oe (           ),
    // 10 kOhm resistors
    .psg_A  (           ),
    .psg_B  (           ),
    .psg_C  (           ),
    .fm_snd ( opn       ),
    .psg_snd( psg       ),
    .snd    (           ),
    .snd_sample()
);

`ifndef NOPCM
reg         cen_oki;
`ifdef MIDRES_TWINSTICK
// Board resonator is 1.056 MHz: 48 MHz * 11/500. This is an audio CE,
// independent of the OPL divider and of transient ADPCM ROM backpressure.
reg [8:0] oki_phase;
always @(posedge clk) begin
    if(rst) begin
        oki_phase <= 0;
        cen_oki <= 0;
    end else if(oki_phase >= 9'd489) begin
        oki_phase <= oki_phase - 9'd489;
        cen_oki <= adpcm_ok;
    end else begin
        oki_phase <= oki_phase + 9'd11;
        cen_oki <= 0;
    end
end
`else
reg  [ 2:0] cen_sh=1;

assign adpcm_cs = 1;

always @(posedge clk) begin
    // 1 MHz clock enable
    if( cen_opl ) cen_sh <= cen_sh==0 ? 3'd1 : { cen_sh[1:0], cen_sh[2] };
    cen_oki <= cen_sh[0] & cen_opl & adpcm_ok;
end
`endif

jt6295 u_adpcm(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen_oki   ),  // 1.056 MHz on Midnight Resistance
    .ss         ( 1'b1      ),
    // CPU interface
    .wrn        ( oki_wrn   ),  // active low
    .din        ( cpu_dout  ),
    .dout       ( oki_dout  ),
    // ROM interface
    .rom_addr   ( adpcm_addr),
    .rom_data   ( adpcm_data),
    .rom_ok     ( adpcm_ok  ),
    // Sound output
    .sound      ( pcm       ),
    .sample     (           )
);
`else
    assign adpcm_snd  = 0;
    assign adpcm_addr = 0;
    assign adpcm_cs   = 0;
    assign oki_dout   = 0;
    assign pcm        = 0;
`endif

endmodule
