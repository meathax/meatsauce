// Gaiapolis adapter. Source provenance: rtl/vendor/violent_storm_k054539/source.json
// K054539 native sample phase and address arithmetic.
// Public evidence: furrtek/SiliconRE c926ce92, 054539.v:1312-1316,
// 1430-1519 and 1551-1563. The controller owns key/loop detection and the
// register-RAM write schedule; those are deliberately explicit inputs here.
// SPDX-License-Identifier: GPL-2.0-or-later
module gaiapolis_k054539_phase(
    input      [39:0] phase,
    input      [23:0] pitch,
    input      [23:0] base,
    input      [ 2:0] dtype,
    input             reverse,
    input             byte_select,
    input             key_on,
    input             loop_restart,
    input             hold,
    output     [39:0] current_phase,
    output     [39:0] next_phase,
    output     [23:0] rom_addr,
    output            nibble_select,
    output            dpcm_update,
    output            clear_previous
);

// Key-on clears all 40 bits. A loop clears the integer portion while
// retaining the 16 fractional bits. Neither event subtracts signed pitch.
// Hold inhibits the subsequent add, not an explicitly requested reset.
assign current_phase = key_on       ? 40'd0 :
                       loop_restart ? {24'd0,phase[15:0]} : phase;
assign next_phase = current_phase + (hold ? 40'd0 : {16'd0,pitch});

wire dpcm = |dtype[2:1];
wire [23:0] offset = dtype[0] ? {current_phase[38:16],byte_select} :
                    dpcm    ? {1'b0,current_phase[39:17]} :
                              current_phase[39:16];

// The fetch uses the old phase. Odd formats have two byte addresses per
// integer phase unit. Reverse negates the entire byte offset, including
// the second-byte selector. Both addresses and phase wrap at their widths.
assign rom_addr = reverse ? base - offset : base + offset;
assign nibble_select = reverse ^ current_phase[16];

// Native DPCM decodes at most one nibble per update. An even number of
// crossed nibble boundaries leaves bit 16 unchanged and produces no step.
assign dpcm_update = dpcm && (current_phase[16] ^ next_phase[16]);
assign clear_previous = key_on | loop_restart;

endmodule
