//============================================================================
// Sega 315-5560 MultiPCM (Yamaha YMW-258-F GEW8)
//
// Register, descriptor, pitch and PCM semantics follow MAME multipcm.cpp and
// gew.cpp (base class gew_pcm_device shared by the GEW family).  This
// revision adds an envelope generator, LFO (vibrato/tremolo) and 12-bit
// packed-sample playback, all MAME-behavioural: no silicon reverse
// engineering exists for 315-5560, so every curve below is reconstructed
// from MAME's gew.cpp/gew.h (envelope_generator_calc/_update, lfo_init,
// lfo_compute_step, sound_stream_update) rather than die measurements.
//
// Provenance notes for the tables/logic added in this revision:
//   - Envelope generator: state_t {ATTACK,DECAY1,DECAY2,RELEASE} and the
//     update/calc functions in gew.cpp (envelope_generator_update,
//     envelope_generator_calc, get_rate). BASE_TIMES[64] and the
//     attack/decay-release step-per-sample formulas
//     (envelope_generator_init) are reproduced exactly, evaluated offline
//     for a 44100 Hz-class per-voice update rate (HYPOTHESIS: this design's
//     224-ce-tick voice cadence, 28 slots * 8 ticks, is the same clock
//     divider MAME uses for GEW8's m_clock_divider, so the two update rates
//     match; the true integrated ce frequency for this project has not been
//     independently confirmed against real 315-5560 hardware).
//   - TL table: gew.cpp's per-level dB curve (-24dB over 64 steps) used to
//     build m_left_pan_table/m_right_pan_table, taken as a standalone 128-
//     entry linear gain table (TL_GAIN_ROM) here; the pan attenuation stays
//     the pre-existing shift-based approximation in pan_sample(), unchanged.
//   - LFO: LFO_FREQ[8]/PHASE_SCALE_LIMIT[8]/AMPLITUDE_SCALE_LIMIT[8] and the
//     m_pitch_table/m_amplitude_table piecewise-linear waveform generators
//     in gew.cpp's lfo_init() are reproduced exactly. The depth (vibrato/
//     tremolo register bits 2:0) to linear-gain conversion is NOT MAME's
//     raw powf()-derived 256-entry-per-depth table (2048 entries would be
//     synthesis-heavy for a 28-voice multiplex); it is re-derived
//     analytically from the same PHASE_SCALE_LIMIT/AMPLITUDE_SCALE_LIMIT
//     constants: PLFO uses a first-order (linear-in-cents) approximation of
//     2^(x/1200) - valid to <0.2% error because MAME's own PHASE_SCALE_LIMIT
//     tops out at 79.3 cents (~4.7% pitch ratio); ALFO reuses TL_GAIN_ROM
//     (whose -0.375dB/step matches AMPLITUDE_SCALE_LIMIT's near-power-of-two
//     0/0.4/0.8/1.5/3/6/12/24 dB progression almost exactly) rather than a
//     second dedicated exponential table. Both are HYPOTHESIS-labelled
//     approximations of MAME's exact float table, not bit-exact ports.
//   - 12-bit sample fetch: gew.cpp's sound_stream_update() bit layout for
//     format&4 (two 12-bit samples packed into 3 bytes) is reproduced
//     exactly: read_byte(adr)<<8 | (read_byte(adr+1)&0xf)<<4 for the even
//     sample, read_byte(adr+2)<<8 | (read_byte(adr+1)&0xf0) for the odd one.
//============================================================================

module s32_multipcm (
    input             clk,
    input             ce,
    input             rst,

    input             cs,
    input             we,
    input       [1:0] addr,
    input       [7:0] wdata,
    output      [7:0] rdata,

    output reg        rom_req,
    output reg [21:0] rom_addr,
    input       [7:0] rom_data,
    input             rom_ack,

    input       [2:0] bank_lo,
    input       [2:0] bank_hi,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

assign rdata = 8'h00;

// Envelope generator states (gew.h state_t).
localparam [1:0] ENV_ATTACK  = 2'd0;
localparam [1:0] ENV_DECAY1  = 2'd1;
localparam [1:0] ENV_DECAY2  = 2'd2;
localparam [1:0] ENV_RELEASE = 2'd3;

// ---------------------------------------------------------------------
// Per-voice state storage.
//
// Every per-voice array lives in a 32-entry MLAB (single write port,
// asynchronous read), one copy per read address, instead of 28-entry
// flip-flop arrays with wide 28:1 read multiplexers (the previous form used
// ~7.4k registers / ~5.7k ALMs).  Asynchronous MLAB reads return the
// pre-edge contents exactly like the register arrays did, so every read
// keeps its original cycle.
//
// Arrays the old code reset, or cleared with a constant from a second writer,
// keep a 28-bit flag vector instead: a set flag makes the read return the
// reset/constant value, and the RAM's own writer clears it.  Flag updates use
// the same NBA order as the old array writes, so same-edge write priority is
// unchanged.  Descriptor fields and the sample hold need no flag: they are
// only read for active voices, and the key-on descriptor completion that sets
// s_active rewrites every one of them.
//
// Arrays with three writers (s_active, s_env_state) and the two LFO
// registers that descriptor completion also writes (sreg 6/7) stay as
// flip-flops.
// ---------------------------------------------------------------------
reg [4:0] cur_slot;
reg       cur_slot_valid;
reg [2:0] cur_reg;

// Voice registers 0..5 (MLAB, Z80 is the only writer).  Register 4 (key
// on/off) is never read back and has no storage.
(* ramstyle = "MLAB, no_rw_check" *) reg [3:0] r0_mem  [0:31]; // [7:4] pan
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] r1_mem  [0:31]; // sample[7:0]
(* ramstyle = "MLAB, no_rw_check" *) reg       r2p_mem [0:31]; // [0] sample[8]
(* ramstyle = "MLAB, no_rw_check" *) reg [5:0] r2s_mem [0:31]; // [7:2] pitch lo
(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] r3s_mem [0:31]; // octave/pitch hi
(* ramstyle = "MLAB, no_rw_check" *) reg [4:0] r3d_mem [0:31]; // [7:3] for rate base
(* ramstyle = "MLAB, no_rw_check" *) reg [6:0] r5_mem  [0:31]; // [7:1] total level
reg [27:0] zr0, zr1, zr2, zr3, zr5;   // 1 = register still at reset value 0
reg  [7:0] sreg6 [0:27];               // LFO freq/pitch depth (Z80 + descriptor)
reg  [7:0] sreg7 [0:27];               // amplitude LFO depth (Z80 + descriptor)

// Descriptor-derived fields, written together on descriptor completion.
// da: read by the voice at `slot`; dl: read by the pitch stage-2 slot.
(* ramstyle = "MLAB, no_rw_check" *) reg [42:0] da_mem [0:31]; // start,fmt12,rel,att,d1,d2,dl
(* ramstyle = "MLAB, no_rw_check" *) reg [32:0] dl_mem [0:31]; // loop,end
(* ramstyle = "MLAB, no_rw_check" *) reg  [6:0] rb_mem [0:31]; // envelope rate base

// Play position: one copy for the tick-0 fetch, one for the pitch stage.
(* ramstyle = "MLAB, no_rw_check" *) reg [37:0] pa_mem [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [37:0] pb_mem [0:31];
reg [27:0] zp;                         // 1 = position reads as 0

reg  [1:0] s_env_state [0:27];
reg [27:0] s_active;

// Envelope accumulator (EG_SHIFT=16 fixed point), converted linear gain
// (Q12, consumed by the mix MAC), LFO phase (top 8 bits index the waveform)
// and amplitude-LFO gain (Q10, 1024 = neutral).
(* ramstyle = "MLAB, no_rw_check" *) reg [26:0] ev_mem [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [11:0] eg_mem [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [23:0] lf_mem [0:31];
(* ramstyle = "MLAB, no_rw_check" *) reg [10:0] ag_mem [0:31];
reg [27:0] ze, zg, zl, za;             // reset/zero flags for the four above

`ifdef MPCM_GARBAGE_INIT
// Simulation only: start every MLAB with junk to prove no read depends on
// power-up contents.
integer gi;
initial begin
    for (gi = 0; gi < 32; gi = gi + 1) begin
        r0_mem[gi] = $random; r1_mem[gi] = $random; r2p_mem[gi] = $random;
        r2s_mem[gi] = $random; r3s_mem[gi] = $random; r3d_mem[gi] = $random;
        r5_mem[gi] = $random; da_mem[gi] = {$random, $random};
        dl_mem[gi] = {$random, $random}; rb_mem[gi] = $random;
        pa_mem[gi] = {$random, $random}; pb_mem[gi] = {$random, $random};
        ev_mem[gi] = $random; eg_mem[gi] = $random; lf_mem[gi] = $random;
        ag_mem[gi] = $random;
    end
end
`endif

// Descriptor work is queued by sample writes and key-on.  key_wait records
// that completion must start/retrigger the voice.
reg [27:0] desc_pending;
reg [27:0] key_wait;
reg [4:0]  df_slot;
reg [8:0]  df_sample;
reg [3:0]  df_idx;
reg        df_busy;
reg [7:0]  df_buf [0:11];

reg [2:0] tick;
reg [4:0] slot;

// Position-update pipeline (Quartus timing fix): s_pos's commit for the
// *next* sample was originally add+loop-wrap-compare+subtract, all
// combinational in the tick==0 cycle -- report_timing showed this as the
// design's worst path by a wide margin (Add21/Add22 ripple chains into
// LessThan13, 37ns arrival against a 20.7ns clk_sys budget). s_pos[slot] is
// not read again until this slot's next tick==0, 224 ticks later (28 slots x
// 8 ticks), so only the *commit* needs to move, not the read that issues
// this sample's ROM fetch (still tick==0, still the pre-update value, per
// the play_base3 comment below). Splitting the add (tick==0) from the
// compare+subtract+commit (tick==1) removes the second chain link from the
// same cycle without changing when any other tick==0 signal is valid.
reg        pos_commit_pending;
reg [4:0]  pos_commit_slot;
reg [37:0] pos_commit_add;
reg [33:0] pos_commit_loop_span;
reg [37:0] pos_commit_end16;
reg [4:0] play_slot;
reg       rom_is_desc;
reg       rom_beat12;
reg       play_beat2_pending;
reg       play_fmt12;
reg       play_odd;
reg [7:0] play_mid;
reg [21:0] play_base3;
reg signed [21:0] acc_l, acc_r;

// Per-voice sample holding registers. The real 315-5560 runs a FIXED
// 224-clock sample frame (MAME models its stream at clk/224); ROM access is
// interleaved into that fixed slot schedule and can never stretch it. The
// previous implementation stalled the tick/slot counter while each SDRAM
// fetch was outstanding, so the output sample rate sagged with voice count
// and memory latency: measured 125%..175% frame stretch at 10..30-clk ack
// latency with 8..28 voices (scratch/tb_mpcm_cadence.sv), heard on hardware
// as slow, warbling music. The scheduler now free-runs; fetches are
// best-effort into s_hold and the mixer reads s_hold at a fixed slot phase.
// A fetch that misses its slot leaves the previous byte in s_hold for one
// frame (a 22us first-order hold) -- fidelity degrades gracefully under
// worst-case bus load while pitch and tempo stay exact.

// Timing-driven pipeline for the per-sample mix MAC (sample*tl_gain ->
// *env_gain -> *alfo_gain -> pan -> accumulate). The original code chained
// all three multiplies plus the pan mux and the acc_l/acc_r adds combinationally
// in the same cycle as the ROM ack, which measured -12.239ns worst-case setup
// slack on Cyclone V (3 back-to-back DSP multiplies is too deep for one
// clk_sys period). Voice slots are only revisited once per full 28-slot pass
// (tick 0..7 then slot 0..27, ~7+ idle tick cycles between one voice's ROM
// ack and the next slot-27 frame-wrap acc_l/acc_r reset -- see s32_core.sv
// timing note above s_pos's own pipeline), so spreading the three multiplies
// over three extra clk_sys cycles is free: nothing else reads mac_p1_val/
// mac_p2_val, and acc_l/acc_r only ever receive one pipelined contribution at
// a time because ROM acks for successive voices are separated by that same
// idle-tick margin.
reg        mac_p1_valid, mac_p2_valid;
reg [4:0]  mac_p1_slot, mac_p2_slot;
reg signed [15:0] mac_p1_val;   // sample*tl_gain, already >>>10
reg signed [15:0] mac_p2_val;   // *env_gain, already >>>12

// Same rationale, second offender found once the acc_l/acc_r MAC above was
// fixed: STA's next worst path was s_lfo_phase->pos_commit_add at -4.679ns,
// through pitch_delta_q24 (9x17) chained straight into pitch_adj_mul (a
// 25x26 multiply -- deep enough on its own to miss timing) before ever
// reaching the pos_commit_add register. Split the two multiplies across a
// clk_sys cycle: stage 1 below computes pitch_delta_q24 (small) at tick==0
// same as before; stage 2 (unconditional, next cycle) does the 25x26
// multiply and hands off to the existing pos_commit pipeline. Same margin
// argument as pos_commit's own stages: tick 0->7 gives >=7 idle cycles
// before this slot's next tick==0 visit.
reg        pitch_p1_valid;
reg [4:0]  pitch_p1_slot;
reg [24:0] pitch_p1_step;
reg signed [25:0] pitch_p1_delta;

// Envelope-generator gain pipeline. env_step()'s internal attack/decay
// rate-table lookup, chained straight through newvol's arithmetic into the
// exp_vol_rom[] gain lookup in the same tick==0 cycle, measured -1.187ns at
// Slow 100C once the cadence rewrite (s_hold/sample_will_issue) changed
// fitter placement pressure elsewhere in this module. Register newvol's top
// 10 bits (the exp_vol_rom index) at the end of the case block; the ROM
// lookup and s_env_gain commit move one cycle later, in the same
// unconditional every-clk stage already used by mac_p1/pitch_p1 above.
// s_env_vol/s_env_state/s_active still commit same-cycle at tick==0 --
// only the gain lookup that feeds the mix MAC is deferred, and that MAC
// itself already runs 4 ticks later (tick==4), so this adds no audible
// latency.
reg        env_p1_valid;
reg [4:0]  env_p1_slot;
reg [9:0]  env_p1_idx;

integer ri;
integer rj;

// ---------------------------------------------------------------------
// Envelope-generator rate tables (gew.cpp envelope_generator_init, called
// as envelope_generator_init(BASE_TIMES, 14.32833)). Values below are
// BASE_TIMES[64] evaluated through MAME's exact formula
//   step[i] = (0x400<<EG_SHIFT) / (BASE_TIMES[i] * srate/1000)               (attack)
//   step[i] = (0x400<<EG_SHIFT) / (BASE_TIMES[i]*14.32833 * srate/1000)      (decay/release)
// with EG_SHIFT=16 and srate=44100 (see file header HYPOTHESIS note on the
// assumed per-voice update rate), precomputed offline and stored as ROM.
reg [26:0] attack_step_rom [0:63];
reg [26:0] decay_step_rom  [0:63];

// m_linear_to_exp_volume: gew.cpp builds this as
//   db = -(96 - 96*i/1024); exp_volume = 10^(db/20); table[i]=round(exp_volume*4096)
// for i = 0..1023, TL_SHIFT=12. Reproduced exactly below.
reg [11:0] exp_vol_rom [0:1023];

// TL_GAIN_ROM: gew.cpp's per-level total-level curve, -24dB over 64 steps
// (i.e. -0.375dB/step), i.e. gain(level) = 10^(level*-24/64/20); stored as
// a pure Q10 linear gain (1024 = unity) rather than MAME's pan-table-fused
// form, since this design keeps TL and pan as separate multiplies. The
// device's /4 output headroom is applied to the completed sum below.
reg [10:0] tl_gain_rom [0:127];

// LFO_FREQ[8] phase-step-per-voice-tick (gew.cpp lfo_compute_step:
// step = LFO_FREQ[freq]*256/srate, LFO_SHIFT=8), evaluated for the assumed
// srate=44100 with 16 extra fractional bits (this design's choice, see
// s_lfo_phase comment above).
reg [15:0] lfo_phase_step_rom [0:7];

// PITCH_K_ROM: per-depth linear-in-cents coefficient reproducing gew.cpp's
// PHASE_SCALE_LIMIT[8]/128 * ln2/1200, Q24 fixed point (see file header
// LFO provenance note for the approximation this stands in for).
reg [15:0] pitch_k_rom [0:7];

// AMP_STEP_POW2: per-depth normalization of AMPLITUDE_SCALE_LIMIT[8] into
// units of TL_GAIN_ROM's 0.375dB step (24dB/0.375dB = 64); the eight limits
// 0/0.4/0.8/1.5/3/6/12/24 dB land within ~7% of 0/1/2/4/8/16/32/64, a
// power-of-two ladder that lets amplitude-LFO attenuation reuse
// TL_GAIN_ROM directly via a shift-multiply instead of a second table.
function automatic [6:0] amp_step_pow2(input [2:0] depth);
begin
    case (depth)
        3'd0: amp_step_pow2 = 7'd0;
        3'd1: amp_step_pow2 = 7'd1;
        3'd2: amp_step_pow2 = 7'd2;
        3'd3: amp_step_pow2 = 7'd4;
        3'd4: amp_step_pow2 = 7'd8;
        3'd5: amp_step_pow2 = 7'd16;
        3'd6: amp_step_pow2 = 7'd32;
        default: amp_step_pow2 = 7'd64;
    endcase
end
endfunction

initial begin

    attack_step_rom[0]=27'd0; attack_step_rom[1]=27'd0; attack_step_rom[2]=27'd0; attack_step_rom[3]=27'd0; attack_step_rom[4]=27'd245; attack_step_rom[5]=27'd306; attack_step_rom[6]=27'd367; attack_step_rom[7]=27'd428;
    attack_step_rom[8]=27'd489; attack_step_rom[9]=27'd611; attack_step_rom[10]=27'd734; attack_step_rom[11]=27'd856; attack_step_rom[12]=27'd978; attack_step_rom[13]=27'd1223; attack_step_rom[14]=27'd1467; attack_step_rom[15]=27'd1712;
    attack_step_rom[16]=27'd1956; attack_step_rom[17]=27'd2445; attack_step_rom[18]=27'd2934; attack_step_rom[19]=27'd3423; attack_step_rom[20]=27'd3913; attack_step_rom[21]=27'd4891; attack_step_rom[22]=27'd5868; attack_step_rom[23]=27'd6846;
    attack_step_rom[24]=27'd7825; attack_step_rom[25]=27'd9780; attack_step_rom[26]=27'd11736; attack_step_rom[27]=27'd13690; attack_step_rom[28]=27'd15651; attack_step_rom[29]=27'd19555; attack_step_rom[30]=27'd23466; attack_step_rom[31]=27'd27369;
    attack_step_rom[32]=27'd31299; attack_step_rom[33]=27'd39109; attack_step_rom[34]=27'd46924; attack_step_rom[35]=27'd54739; attack_step_rom[36]=27'd62597; attack_step_rom[37]=27'd78199; attack_step_rom[38]=27'd93703; attack_step_rom[39]=27'd109321;
    attack_step_rom[40]=27'd125246; attack_step_rom[41]=27'd156076; attack_step_rom[42]=27'd187407; attack_step_rom[43]=27'd218015; attack_step_rom[44]=27'd250287; attack_step_rom[45]=27'd310560; attack_step_rom[46]=27'd372976; attack_step_rom[47]=27'd436029;
    attack_step_rom[48]=27'd500573; attack_step_rom[49]=27'd611142; attack_step_rom[50]=27'd714433; attack_step_rom[51]=27'd800917; attack_step_rom[52]=27'd884734; attack_step_rom[53]=27'd1079250; attack_step_rom[54]=27'd1289613; attack_step_rom[55]=27'd1463214;
    attack_step_rom[56]=27'd1672245; attack_step_rom[57]=27'd2084579; attack_step_rom[58]=27'd2579225; attack_step_rom[59]=27'd3043486; attack_step_rom[60]=27'd3381651; attack_step_rom[61]=27'd3381651; attack_step_rom[62]=27'd3381651; attack_step_rom[63]=27'd67108864;

    decay_step_rom[0]=27'd0; decay_step_rom[1]=27'd0; decay_step_rom[2]=27'd0; decay_step_rom[3]=27'd0; decay_step_rom[4]=27'd17; decay_step_rom[5]=27'd21; decay_step_rom[6]=27'd26; decay_step_rom[7]=27'd30;
    decay_step_rom[8]=27'd34; decay_step_rom[9]=27'd43; decay_step_rom[10]=27'd51; decay_step_rom[11]=27'd60; decay_step_rom[12]=27'd68; decay_step_rom[13]=27'd85; decay_step_rom[14]=27'd102; decay_step_rom[15]=27'd119;
    decay_step_rom[16]=27'd137; decay_step_rom[17]=27'd171; decay_step_rom[18]=27'd205; decay_step_rom[19]=27'd239; decay_step_rom[20]=27'd273; decay_step_rom[21]=27'd341; decay_step_rom[22]=27'd410; decay_step_rom[23]=27'd478;
    decay_step_rom[24]=27'd546; decay_step_rom[25]=27'd683; decay_step_rom[26]=27'd819; decay_step_rom[27]=27'd955; decay_step_rom[28]=27'd1092; decay_step_rom[29]=27'd1365; decay_step_rom[30]=27'd1638; decay_step_rom[31]=27'd1910;
    decay_step_rom[32]=27'd2184; decay_step_rom[33]=27'd2730; decay_step_rom[34]=27'd3275; decay_step_rom[35]=27'd3820; decay_step_rom[36]=27'd4369; decay_step_rom[37]=27'd5458; decay_step_rom[38]=27'd6540; decay_step_rom[39]=27'd7630;
    decay_step_rom[40]=27'd8741; decay_step_rom[41]=27'd10893; decay_step_rom[42]=27'd13079; decay_step_rom[43]=27'd15216; decay_step_rom[44]=27'd17468; decay_step_rom[45]=27'd21675; decay_step_rom[46]=27'd26031; decay_step_rom[47]=27'd30431;
    decay_step_rom[48]=27'd34936; decay_step_rom[49]=27'd42653; decay_step_rom[50]=27'd49862; decay_step_rom[51]=27'd55897; decay_step_rom[52]=27'd61747; decay_step_rom[53]=27'd75323; decay_step_rom[54]=27'd90004; decay_step_rom[55]=27'd102120;
    decay_step_rom[56]=27'd116709; decay_step_rom[57]=27'd145487; decay_step_rom[58]=27'd180009; decay_step_rom[59]=27'd212410; decay_step_rom[60]=27'd236012; decay_step_rom[61]=27'd236012; decay_step_rom[62]=27'd236012; decay_step_rom[63]=27'd236012;

    tl_gain_rom[0]=11'd1024; tl_gain_rom[1]=11'd981; tl_gain_rom[2]=11'd939; tl_gain_rom[3]=11'd900; tl_gain_rom[4]=11'd862; tl_gain_rom[5]=11'd825; tl_gain_rom[6]=11'd790; tl_gain_rom[7]=11'd757;
    tl_gain_rom[8]=11'd725; tl_gain_rom[9]=11'd694; tl_gain_rom[10]=11'd665; tl_gain_rom[11]=11'd637; tl_gain_rom[12]=11'd610; tl_gain_rom[13]=11'd584; tl_gain_rom[14]=11'd559; tl_gain_rom[15]=11'd536;
    tl_gain_rom[16]=11'd513; tl_gain_rom[17]=11'd492; tl_gain_rom[18]=11'd471; tl_gain_rom[19]=11'd451; tl_gain_rom[20]=11'd432; tl_gain_rom[21]=11'd414; tl_gain_rom[22]=11'd396; tl_gain_rom[23]=11'd379;
    tl_gain_rom[24]=11'd363; tl_gain_rom[25]=11'd348; tl_gain_rom[26]=11'd333; tl_gain_rom[27]=11'd319; tl_gain_rom[28]=11'd306; tl_gain_rom[29]=11'd293; tl_gain_rom[30]=11'd280; tl_gain_rom[31]=11'd269;
    tl_gain_rom[32]=11'd257; tl_gain_rom[33]=11'd246; tl_gain_rom[34]=11'd236; tl_gain_rom[35]=11'd226; tl_gain_rom[36]=11'd216; tl_gain_rom[37]=11'd207; tl_gain_rom[38]=11'd199; tl_gain_rom[39]=11'd190;
    tl_gain_rom[40]=11'd182; tl_gain_rom[41]=11'd174; tl_gain_rom[42]=11'd167; tl_gain_rom[43]=11'd160; tl_gain_rom[44]=11'd153; tl_gain_rom[45]=11'd147; tl_gain_rom[46]=11'd141; tl_gain_rom[47]=11'd135;
    tl_gain_rom[48]=11'd129; tl_gain_rom[49]=11'd123; tl_gain_rom[50]=11'd118; tl_gain_rom[51]=11'd113; tl_gain_rom[52]=11'd108; tl_gain_rom[53]=11'd104; tl_gain_rom[54]=11'd99; tl_gain_rom[55]=11'd95;
    tl_gain_rom[56]=11'd91; tl_gain_rom[57]=11'd87; tl_gain_rom[58]=11'd84; tl_gain_rom[59]=11'd80; tl_gain_rom[60]=11'd77; tl_gain_rom[61]=11'd74; tl_gain_rom[62]=11'd70; tl_gain_rom[63]=11'd67;
    tl_gain_rom[64]=11'd65; tl_gain_rom[65]=11'd62; tl_gain_rom[66]=11'd59; tl_gain_rom[67]=11'd57; tl_gain_rom[68]=11'd54; tl_gain_rom[69]=11'd52; tl_gain_rom[70]=11'd50; tl_gain_rom[71]=11'd48;
    tl_gain_rom[72]=11'd46; tl_gain_rom[73]=11'd44; tl_gain_rom[74]=11'd42; tl_gain_rom[75]=11'd40; tl_gain_rom[76]=11'd38; tl_gain_rom[77]=11'd37; tl_gain_rom[78]=11'd35; tl_gain_rom[79]=11'd34;
    tl_gain_rom[80]=11'd32; tl_gain_rom[81]=11'd31; tl_gain_rom[82]=11'd30; tl_gain_rom[83]=11'd28; tl_gain_rom[84]=11'd27; tl_gain_rom[85]=11'd26; tl_gain_rom[86]=11'd25; tl_gain_rom[87]=11'd24;
    tl_gain_rom[88]=11'd23; tl_gain_rom[89]=11'd22; tl_gain_rom[90]=11'd21; tl_gain_rom[91]=11'd20; tl_gain_rom[92]=11'd19; tl_gain_rom[93]=11'd18; tl_gain_rom[94]=11'd18; tl_gain_rom[95]=11'd17;
    tl_gain_rom[96]=11'd16; tl_gain_rom[97]=11'd16; tl_gain_rom[98]=11'd15; tl_gain_rom[99]=11'd14; tl_gain_rom[100]=11'd14; tl_gain_rom[101]=11'd13; tl_gain_rom[102]=11'd13; tl_gain_rom[103]=11'd12;
    tl_gain_rom[104]=11'd11; tl_gain_rom[105]=11'd11; tl_gain_rom[106]=11'd11; tl_gain_rom[107]=11'd10; tl_gain_rom[108]=11'd10; tl_gain_rom[109]=11'd9; tl_gain_rom[110]=11'd9; tl_gain_rom[111]=11'd8;
    tl_gain_rom[112]=11'd8; tl_gain_rom[113]=11'd8; tl_gain_rom[114]=11'd7; tl_gain_rom[115]=11'd7; tl_gain_rom[116]=11'd7; tl_gain_rom[117]=11'd7; tl_gain_rom[118]=11'd6; tl_gain_rom[119]=11'd6;
    tl_gain_rom[120]=11'd6; tl_gain_rom[121]=11'd6; tl_gain_rom[122]=11'd5; tl_gain_rom[123]=11'd5; tl_gain_rom[124]=11'd5; tl_gain_rom[125]=11'd5; tl_gain_rom[126]=11'd4; tl_gain_rom[127]=11'd4;

    exp_vol_rom[0]=12'd0; exp_vol_rom[1]=12'd0; exp_vol_rom[2]=12'd0; exp_vol_rom[3]=12'd0; exp_vol_rom[4]=12'd0; exp_vol_rom[5]=12'd0; exp_vol_rom[6]=12'd0; exp_vol_rom[7]=12'd0; exp_vol_rom[8]=12'd0; exp_vol_rom[9]=12'd0;
    exp_vol_rom[10]=12'd0; exp_vol_rom[11]=12'd0; exp_vol_rom[12]=12'd0; exp_vol_rom[13]=12'd0; exp_vol_rom[14]=12'd0; exp_vol_rom[15]=12'd0; exp_vol_rom[16]=12'd0; exp_vol_rom[17]=12'd0; exp_vol_rom[18]=12'd0; exp_vol_rom[19]=12'd0;
    exp_vol_rom[20]=12'd0; exp_vol_rom[21]=12'd0; exp_vol_rom[22]=12'd0; exp_vol_rom[23]=12'd0; exp_vol_rom[24]=12'd0; exp_vol_rom[25]=12'd0; exp_vol_rom[26]=12'd0; exp_vol_rom[27]=12'd0; exp_vol_rom[28]=12'd0; exp_vol_rom[29]=12'd0;
    exp_vol_rom[30]=12'd0; exp_vol_rom[31]=12'd0; exp_vol_rom[32]=12'd0; exp_vol_rom[33]=12'd0; exp_vol_rom[34]=12'd0; exp_vol_rom[35]=12'd0; exp_vol_rom[36]=12'd0; exp_vol_rom[37]=12'd0; exp_vol_rom[38]=12'd0; exp_vol_rom[39]=12'd0;
    exp_vol_rom[40]=12'd0; exp_vol_rom[41]=12'd0; exp_vol_rom[42]=12'd0; exp_vol_rom[43]=12'd0; exp_vol_rom[44]=12'd0; exp_vol_rom[45]=12'd0; exp_vol_rom[46]=12'd0; exp_vol_rom[47]=12'd0; exp_vol_rom[48]=12'd0; exp_vol_rom[49]=12'd0;
    exp_vol_rom[50]=12'd0; exp_vol_rom[51]=12'd0; exp_vol_rom[52]=12'd0; exp_vol_rom[53]=12'd0; exp_vol_rom[54]=12'd0; exp_vol_rom[55]=12'd0; exp_vol_rom[56]=12'd0; exp_vol_rom[57]=12'd0; exp_vol_rom[58]=12'd0; exp_vol_rom[59]=12'd0;
    exp_vol_rom[60]=12'd0; exp_vol_rom[61]=12'd0; exp_vol_rom[62]=12'd0; exp_vol_rom[63]=12'd0; exp_vol_rom[64]=12'd0; exp_vol_rom[65]=12'd0; exp_vol_rom[66]=12'd0; exp_vol_rom[67]=12'd0; exp_vol_rom[68]=12'd0; exp_vol_rom[69]=12'd0;
    exp_vol_rom[70]=12'd0; exp_vol_rom[71]=12'd0; exp_vol_rom[72]=12'd0; exp_vol_rom[73]=12'd0; exp_vol_rom[74]=12'd0; exp_vol_rom[75]=12'd0; exp_vol_rom[76]=12'd0; exp_vol_rom[77]=12'd0; exp_vol_rom[78]=12'd0; exp_vol_rom[79]=12'd0;
    exp_vol_rom[80]=12'd0; exp_vol_rom[81]=12'd0; exp_vol_rom[82]=12'd0; exp_vol_rom[83]=12'd0; exp_vol_rom[84]=12'd0; exp_vol_rom[85]=12'd0; exp_vol_rom[86]=12'd0; exp_vol_rom[87]=12'd0; exp_vol_rom[88]=12'd0; exp_vol_rom[89]=12'd0;
    exp_vol_rom[90]=12'd0; exp_vol_rom[91]=12'd0; exp_vol_rom[92]=12'd0; exp_vol_rom[93]=12'd0; exp_vol_rom[94]=12'd0; exp_vol_rom[95]=12'd0; exp_vol_rom[96]=12'd0; exp_vol_rom[97]=12'd0; exp_vol_rom[98]=12'd0; exp_vol_rom[99]=12'd0;
    exp_vol_rom[100]=12'd0; exp_vol_rom[101]=12'd0; exp_vol_rom[102]=12'd0; exp_vol_rom[103]=12'd0; exp_vol_rom[104]=12'd0; exp_vol_rom[105]=12'd0; exp_vol_rom[106]=12'd0; exp_vol_rom[107]=12'd0; exp_vol_rom[108]=12'd0; exp_vol_rom[109]=12'd0;
    exp_vol_rom[110]=12'd0; exp_vol_rom[111]=12'd0; exp_vol_rom[112]=12'd0; exp_vol_rom[113]=12'd0; exp_vol_rom[114]=12'd0; exp_vol_rom[115]=12'd0; exp_vol_rom[116]=12'd0; exp_vol_rom[117]=12'd0; exp_vol_rom[118]=12'd0; exp_vol_rom[119]=12'd0;
    exp_vol_rom[120]=12'd0; exp_vol_rom[121]=12'd0; exp_vol_rom[122]=12'd0; exp_vol_rom[123]=12'd0; exp_vol_rom[124]=12'd0; exp_vol_rom[125]=12'd0; exp_vol_rom[126]=12'd0; exp_vol_rom[127]=12'd0; exp_vol_rom[128]=12'd0; exp_vol_rom[129]=12'd0;
    exp_vol_rom[130]=12'd0; exp_vol_rom[131]=12'd0; exp_vol_rom[132]=12'd0; exp_vol_rom[133]=12'd0; exp_vol_rom[134]=12'd0; exp_vol_rom[135]=12'd0; exp_vol_rom[136]=12'd0; exp_vol_rom[137]=12'd0; exp_vol_rom[138]=12'd0; exp_vol_rom[139]=12'd0;
    exp_vol_rom[140]=12'd0; exp_vol_rom[141]=12'd0; exp_vol_rom[142]=12'd0; exp_vol_rom[143]=12'd0; exp_vol_rom[144]=12'd0; exp_vol_rom[145]=12'd0; exp_vol_rom[146]=12'd0; exp_vol_rom[147]=12'd0; exp_vol_rom[148]=12'd0; exp_vol_rom[149]=12'd0;
    exp_vol_rom[150]=12'd0; exp_vol_rom[151]=12'd0; exp_vol_rom[152]=12'd0; exp_vol_rom[153]=12'd0; exp_vol_rom[154]=12'd0; exp_vol_rom[155]=12'd0; exp_vol_rom[156]=12'd0; exp_vol_rom[157]=12'd0; exp_vol_rom[158]=12'd0; exp_vol_rom[159]=12'd0;
    exp_vol_rom[160]=12'd0; exp_vol_rom[161]=12'd0; exp_vol_rom[162]=12'd0; exp_vol_rom[163]=12'd0; exp_vol_rom[164]=12'd0; exp_vol_rom[165]=12'd0; exp_vol_rom[166]=12'd0; exp_vol_rom[167]=12'd0; exp_vol_rom[168]=12'd0; exp_vol_rom[169]=12'd0;
    exp_vol_rom[170]=12'd0; exp_vol_rom[171]=12'd0; exp_vol_rom[172]=12'd0; exp_vol_rom[173]=12'd0; exp_vol_rom[174]=12'd0; exp_vol_rom[175]=12'd0; exp_vol_rom[176]=12'd0; exp_vol_rom[177]=12'd0; exp_vol_rom[178]=12'd0; exp_vol_rom[179]=12'd0;
    exp_vol_rom[180]=12'd0; exp_vol_rom[181]=12'd0; exp_vol_rom[182]=12'd0; exp_vol_rom[183]=12'd0; exp_vol_rom[184]=12'd0; exp_vol_rom[185]=12'd0; exp_vol_rom[186]=12'd0; exp_vol_rom[187]=12'd0; exp_vol_rom[188]=12'd0; exp_vol_rom[189]=12'd0;
    exp_vol_rom[190]=12'd1; exp_vol_rom[191]=12'd1; exp_vol_rom[192]=12'd1; exp_vol_rom[193]=12'd1; exp_vol_rom[194]=12'd1; exp_vol_rom[195]=12'd1; exp_vol_rom[196]=12'd1; exp_vol_rom[197]=12'd1; exp_vol_rom[198]=12'd1; exp_vol_rom[199]=12'd1;
    exp_vol_rom[200]=12'd1; exp_vol_rom[201]=12'd1; exp_vol_rom[202]=12'd1; exp_vol_rom[203]=12'd1; exp_vol_rom[204]=12'd1; exp_vol_rom[205]=12'd1; exp_vol_rom[206]=12'd1; exp_vol_rom[207]=12'd1; exp_vol_rom[208]=12'd1; exp_vol_rom[209]=12'd1;
    exp_vol_rom[210]=12'd1; exp_vol_rom[211]=12'd1; exp_vol_rom[212]=12'd1; exp_vol_rom[213]=12'd1; exp_vol_rom[214]=12'd1; exp_vol_rom[215]=12'd1; exp_vol_rom[216]=12'd1; exp_vol_rom[217]=12'd1; exp_vol_rom[218]=12'd1; exp_vol_rom[219]=12'd1;
    exp_vol_rom[220]=12'd1; exp_vol_rom[221]=12'd1; exp_vol_rom[222]=12'd1; exp_vol_rom[223]=12'd1; exp_vol_rom[224]=12'd1; exp_vol_rom[225]=12'd1; exp_vol_rom[226]=12'd1; exp_vol_rom[227]=12'd1; exp_vol_rom[228]=12'd1; exp_vol_rom[229]=12'd1;
    exp_vol_rom[230]=12'd1; exp_vol_rom[231]=12'd1; exp_vol_rom[232]=12'd1; exp_vol_rom[233]=12'd1; exp_vol_rom[234]=12'd1; exp_vol_rom[235]=12'd1; exp_vol_rom[236]=12'd1; exp_vol_rom[237]=12'd1; exp_vol_rom[238]=12'd1; exp_vol_rom[239]=12'd1;
    exp_vol_rom[240]=12'd1; exp_vol_rom[241]=12'd1; exp_vol_rom[242]=12'd1; exp_vol_rom[243]=12'd1; exp_vol_rom[244]=12'd1; exp_vol_rom[245]=12'd1; exp_vol_rom[246]=12'd1; exp_vol_rom[247]=12'd1; exp_vol_rom[248]=12'd1; exp_vol_rom[249]=12'd1;
    exp_vol_rom[250]=12'd1; exp_vol_rom[251]=12'd1; exp_vol_rom[252]=12'd1; exp_vol_rom[253]=12'd1; exp_vol_rom[254]=12'd1; exp_vol_rom[255]=12'd1; exp_vol_rom[256]=12'd1; exp_vol_rom[257]=12'd1; exp_vol_rom[258]=12'd1; exp_vol_rom[259]=12'd1;
    exp_vol_rom[260]=12'd1; exp_vol_rom[261]=12'd1; exp_vol_rom[262]=12'd1; exp_vol_rom[263]=12'd1; exp_vol_rom[264]=12'd1; exp_vol_rom[265]=12'd1; exp_vol_rom[266]=12'd1; exp_vol_rom[267]=12'd1; exp_vol_rom[268]=12'd1; exp_vol_rom[269]=12'd1;
    exp_vol_rom[270]=12'd1; exp_vol_rom[271]=12'd1; exp_vol_rom[272]=12'd1; exp_vol_rom[273]=12'd1; exp_vol_rom[274]=12'd1; exp_vol_rom[275]=12'd1; exp_vol_rom[276]=12'd1; exp_vol_rom[277]=12'd1; exp_vol_rom[278]=12'd1; exp_vol_rom[279]=12'd1;
    exp_vol_rom[280]=12'd1; exp_vol_rom[281]=12'd1; exp_vol_rom[282]=12'd1; exp_vol_rom[283]=12'd1; exp_vol_rom[284]=12'd1; exp_vol_rom[285]=12'd1; exp_vol_rom[286]=12'd1; exp_vol_rom[287]=12'd1; exp_vol_rom[288]=12'd1; exp_vol_rom[289]=12'd1;
    exp_vol_rom[290]=12'd1; exp_vol_rom[291]=12'd2; exp_vol_rom[292]=12'd2; exp_vol_rom[293]=12'd2; exp_vol_rom[294]=12'd2; exp_vol_rom[295]=12'd2; exp_vol_rom[296]=12'd2; exp_vol_rom[297]=12'd2; exp_vol_rom[298]=12'd2; exp_vol_rom[299]=12'd2;
    exp_vol_rom[300]=12'd2; exp_vol_rom[301]=12'd2; exp_vol_rom[302]=12'd2; exp_vol_rom[303]=12'd2; exp_vol_rom[304]=12'd2; exp_vol_rom[305]=12'd2; exp_vol_rom[306]=12'd2; exp_vol_rom[307]=12'd2; exp_vol_rom[308]=12'd2; exp_vol_rom[309]=12'd2;
    exp_vol_rom[310]=12'd2; exp_vol_rom[311]=12'd2; exp_vol_rom[312]=12'd2; exp_vol_rom[313]=12'd2; exp_vol_rom[314]=12'd2; exp_vol_rom[315]=12'd2; exp_vol_rom[316]=12'd2; exp_vol_rom[317]=12'd2; exp_vol_rom[318]=12'd2; exp_vol_rom[319]=12'd2;
    exp_vol_rom[320]=12'd2; exp_vol_rom[321]=12'd2; exp_vol_rom[322]=12'd2; exp_vol_rom[323]=12'd2; exp_vol_rom[324]=12'd2; exp_vol_rom[325]=12'd2; exp_vol_rom[326]=12'd2; exp_vol_rom[327]=12'd2; exp_vol_rom[328]=12'd2; exp_vol_rom[329]=12'd2;
    exp_vol_rom[330]=12'd2; exp_vol_rom[331]=12'd2; exp_vol_rom[332]=12'd2; exp_vol_rom[333]=12'd2; exp_vol_rom[334]=12'd2; exp_vol_rom[335]=12'd2; exp_vol_rom[336]=12'd2; exp_vol_rom[337]=12'd2; exp_vol_rom[338]=12'd2; exp_vol_rom[339]=12'd3;
    exp_vol_rom[340]=12'd3; exp_vol_rom[341]=12'd3; exp_vol_rom[342]=12'd3; exp_vol_rom[343]=12'd3; exp_vol_rom[344]=12'd3; exp_vol_rom[345]=12'd3; exp_vol_rom[346]=12'd3; exp_vol_rom[347]=12'd3; exp_vol_rom[348]=12'd3; exp_vol_rom[349]=12'd3;
    exp_vol_rom[350]=12'd3; exp_vol_rom[351]=12'd3; exp_vol_rom[352]=12'd3; exp_vol_rom[353]=12'd3; exp_vol_rom[354]=12'd3; exp_vol_rom[355]=12'd3; exp_vol_rom[356]=12'd3; exp_vol_rom[357]=12'd3; exp_vol_rom[358]=12'd3; exp_vol_rom[359]=12'd3;
    exp_vol_rom[360]=12'd3; exp_vol_rom[361]=12'd3; exp_vol_rom[362]=12'd3; exp_vol_rom[363]=12'd3; exp_vol_rom[364]=12'd3; exp_vol_rom[365]=12'd3; exp_vol_rom[366]=12'd3; exp_vol_rom[367]=12'd3; exp_vol_rom[368]=12'd3; exp_vol_rom[369]=12'd3;
    exp_vol_rom[370]=12'd4; exp_vol_rom[371]=12'd4; exp_vol_rom[372]=12'd4; exp_vol_rom[373]=12'd4; exp_vol_rom[374]=12'd4; exp_vol_rom[375]=12'd4; exp_vol_rom[376]=12'd4; exp_vol_rom[377]=12'd4; exp_vol_rom[378]=12'd4; exp_vol_rom[379]=12'd4;
    exp_vol_rom[380]=12'd4; exp_vol_rom[381]=12'd4; exp_vol_rom[382]=12'd4; exp_vol_rom[383]=12'd4; exp_vol_rom[384]=12'd4; exp_vol_rom[385]=12'd4; exp_vol_rom[386]=12'd4; exp_vol_rom[387]=12'd4; exp_vol_rom[388]=12'd4; exp_vol_rom[389]=12'd4;
    exp_vol_rom[390]=12'd4; exp_vol_rom[391]=12'd4; exp_vol_rom[392]=12'd4; exp_vol_rom[393]=12'd5; exp_vol_rom[394]=12'd5; exp_vol_rom[395]=12'd5; exp_vol_rom[396]=12'd5; exp_vol_rom[397]=12'd5; exp_vol_rom[398]=12'd5; exp_vol_rom[399]=12'd5;
    exp_vol_rom[400]=12'd5; exp_vol_rom[401]=12'd5; exp_vol_rom[402]=12'd5; exp_vol_rom[403]=12'd5; exp_vol_rom[404]=12'd5; exp_vol_rom[405]=12'd5; exp_vol_rom[406]=12'd5; exp_vol_rom[407]=12'd5; exp_vol_rom[408]=12'd5; exp_vol_rom[409]=12'd5;
    exp_vol_rom[410]=12'd5; exp_vol_rom[411]=12'd5; exp_vol_rom[412]=12'd6; exp_vol_rom[413]=12'd6; exp_vol_rom[414]=12'd6; exp_vol_rom[415]=12'd6; exp_vol_rom[416]=12'd6; exp_vol_rom[417]=12'd6; exp_vol_rom[418]=12'd6; exp_vol_rom[419]=12'd6;
    exp_vol_rom[420]=12'd6; exp_vol_rom[421]=12'd6; exp_vol_rom[422]=12'd6; exp_vol_rom[423]=12'd6; exp_vol_rom[424]=12'd6; exp_vol_rom[425]=12'd6; exp_vol_rom[426]=12'd6; exp_vol_rom[427]=12'd7; exp_vol_rom[428]=12'd7; exp_vol_rom[429]=12'd7;
    exp_vol_rom[430]=12'd7; exp_vol_rom[431]=12'd7; exp_vol_rom[432]=12'd7; exp_vol_rom[433]=12'd7; exp_vol_rom[434]=12'd7; exp_vol_rom[435]=12'd7; exp_vol_rom[436]=12'd7; exp_vol_rom[437]=12'd7; exp_vol_rom[438]=12'd7; exp_vol_rom[439]=12'd7;
    exp_vol_rom[440]=12'd7; exp_vol_rom[441]=12'd8; exp_vol_rom[442]=12'd8; exp_vol_rom[443]=12'd8; exp_vol_rom[444]=12'd8; exp_vol_rom[445]=12'd8; exp_vol_rom[446]=12'd8; exp_vol_rom[447]=12'd8; exp_vol_rom[448]=12'd8; exp_vol_rom[449]=12'd8;
    exp_vol_rom[450]=12'd8; exp_vol_rom[451]=12'd8; exp_vol_rom[452]=12'd9; exp_vol_rom[453]=12'd9; exp_vol_rom[454]=12'd9; exp_vol_rom[455]=12'd9; exp_vol_rom[456]=12'd9; exp_vol_rom[457]=12'd9; exp_vol_rom[458]=12'd9; exp_vol_rom[459]=12'd9;
    exp_vol_rom[460]=12'd9; exp_vol_rom[461]=12'd9; exp_vol_rom[462]=12'd10; exp_vol_rom[463]=12'd10; exp_vol_rom[464]=12'd10; exp_vol_rom[465]=12'd10; exp_vol_rom[466]=12'd10; exp_vol_rom[467]=12'd10; exp_vol_rom[468]=12'd10; exp_vol_rom[469]=12'd10;
    exp_vol_rom[470]=12'd10; exp_vol_rom[471]=12'd10; exp_vol_rom[472]=12'd11; exp_vol_rom[473]=12'd11; exp_vol_rom[474]=12'd11; exp_vol_rom[475]=12'd11; exp_vol_rom[476]=12'd11; exp_vol_rom[477]=12'd11; exp_vol_rom[478]=12'd11; exp_vol_rom[479]=12'd11;
    exp_vol_rom[480]=12'd12; exp_vol_rom[481]=12'd12; exp_vol_rom[482]=12'd12; exp_vol_rom[483]=12'd12; exp_vol_rom[484]=12'd12; exp_vol_rom[485]=12'd12; exp_vol_rom[486]=12'd12; exp_vol_rom[487]=12'd12; exp_vol_rom[488]=12'd13; exp_vol_rom[489]=12'd13;
    exp_vol_rom[490]=12'd13; exp_vol_rom[491]=12'd13; exp_vol_rom[492]=12'd13; exp_vol_rom[493]=12'd13; exp_vol_rom[494]=12'd13; exp_vol_rom[495]=12'd14; exp_vol_rom[496]=12'd14; exp_vol_rom[497]=12'd14; exp_vol_rom[498]=12'd14; exp_vol_rom[499]=12'd14;
    exp_vol_rom[500]=12'd14; exp_vol_rom[501]=12'd14; exp_vol_rom[502]=12'd15; exp_vol_rom[503]=12'd15; exp_vol_rom[504]=12'd15; exp_vol_rom[505]=12'd15; exp_vol_rom[506]=12'd15; exp_vol_rom[507]=12'd15; exp_vol_rom[508]=12'd16; exp_vol_rom[509]=12'd16;
    exp_vol_rom[510]=12'd16; exp_vol_rom[511]=12'd16; exp_vol_rom[512]=12'd16; exp_vol_rom[513]=12'd16; exp_vol_rom[514]=12'd17; exp_vol_rom[515]=12'd17; exp_vol_rom[516]=12'd17; exp_vol_rom[517]=12'd17; exp_vol_rom[518]=12'd17; exp_vol_rom[519]=12'd18;
    exp_vol_rom[520]=12'd18; exp_vol_rom[521]=12'd18; exp_vol_rom[522]=12'd18; exp_vol_rom[523]=12'd18; exp_vol_rom[524]=12'd19; exp_vol_rom[525]=12'd19; exp_vol_rom[526]=12'd19; exp_vol_rom[527]=12'd19; exp_vol_rom[528]=12'd19; exp_vol_rom[529]=12'd20;
    exp_vol_rom[530]=12'd20; exp_vol_rom[531]=12'd20; exp_vol_rom[532]=12'd20; exp_vol_rom[533]=12'd20; exp_vol_rom[534]=12'd21; exp_vol_rom[535]=12'd21; exp_vol_rom[536]=12'd21; exp_vol_rom[537]=12'd21; exp_vol_rom[538]=12'd22; exp_vol_rom[539]=12'd22;
    exp_vol_rom[540]=12'd22; exp_vol_rom[541]=12'd22; exp_vol_rom[542]=12'd23; exp_vol_rom[543]=12'd23; exp_vol_rom[544]=12'd23; exp_vol_rom[545]=12'd23; exp_vol_rom[546]=12'd24; exp_vol_rom[547]=12'd24; exp_vol_rom[548]=12'd24; exp_vol_rom[549]=12'd24;
    exp_vol_rom[550]=12'd25; exp_vol_rom[551]=12'd25; exp_vol_rom[552]=12'd25; exp_vol_rom[553]=12'd25; exp_vol_rom[554]=12'd26; exp_vol_rom[555]=12'd26; exp_vol_rom[556]=12'd26; exp_vol_rom[557]=12'd27; exp_vol_rom[558]=12'd27; exp_vol_rom[559]=12'd27;
    exp_vol_rom[560]=12'd27; exp_vol_rom[561]=12'd28; exp_vol_rom[562]=12'd28; exp_vol_rom[563]=12'd28; exp_vol_rom[564]=12'd29; exp_vol_rom[565]=12'd29; exp_vol_rom[566]=12'd29; exp_vol_rom[567]=12'd30; exp_vol_rom[568]=12'd30; exp_vol_rom[569]=12'd30;
    exp_vol_rom[570]=12'd30; exp_vol_rom[571]=12'd31; exp_vol_rom[572]=12'd31; exp_vol_rom[573]=12'd31; exp_vol_rom[574]=12'd32; exp_vol_rom[575]=12'd32; exp_vol_rom[576]=12'd33; exp_vol_rom[577]=12'd33; exp_vol_rom[578]=12'd33; exp_vol_rom[579]=12'd34;
    exp_vol_rom[580]=12'd34; exp_vol_rom[581]=12'd34; exp_vol_rom[582]=12'd35; exp_vol_rom[583]=12'd35; exp_vol_rom[584]=12'd35; exp_vol_rom[585]=12'd36; exp_vol_rom[586]=12'd36; exp_vol_rom[587]=12'd37; exp_vol_rom[588]=12'd37; exp_vol_rom[589]=12'd37;
    exp_vol_rom[590]=12'd38; exp_vol_rom[591]=12'd38; exp_vol_rom[592]=12'd39; exp_vol_rom[593]=12'd39; exp_vol_rom[594]=12'd40; exp_vol_rom[595]=12'd40; exp_vol_rom[596]=12'd40; exp_vol_rom[597]=12'd41; exp_vol_rom[598]=12'd41; exp_vol_rom[599]=12'd42;
    exp_vol_rom[600]=12'd42; exp_vol_rom[601]=12'd43; exp_vol_rom[602]=12'd43; exp_vol_rom[603]=12'd44; exp_vol_rom[604]=12'd44; exp_vol_rom[605]=12'd44; exp_vol_rom[606]=12'd45; exp_vol_rom[607]=12'd45; exp_vol_rom[608]=12'd46; exp_vol_rom[609]=12'd46;
    exp_vol_rom[610]=12'd47; exp_vol_rom[611]=12'd47; exp_vol_rom[612]=12'd48; exp_vol_rom[613]=12'd49; exp_vol_rom[614]=12'd49; exp_vol_rom[615]=12'd50; exp_vol_rom[616]=12'd50; exp_vol_rom[617]=12'd51; exp_vol_rom[618]=12'd51; exp_vol_rom[619]=12'd52;
    exp_vol_rom[620]=12'd52; exp_vol_rom[621]=12'd53; exp_vol_rom[622]=12'd53; exp_vol_rom[623]=12'd54; exp_vol_rom[624]=12'd55; exp_vol_rom[625]=12'd55; exp_vol_rom[626]=12'd56; exp_vol_rom[627]=12'd56; exp_vol_rom[628]=12'd57; exp_vol_rom[629]=12'd58;
    exp_vol_rom[630]=12'd58; exp_vol_rom[631]=12'd59; exp_vol_rom[632]=12'd60; exp_vol_rom[633]=12'd60; exp_vol_rom[634]=12'd61; exp_vol_rom[635]=12'd62; exp_vol_rom[636]=12'd62; exp_vol_rom[637]=12'd63; exp_vol_rom[638]=12'd64; exp_vol_rom[639]=12'd64;
    exp_vol_rom[640]=12'd65; exp_vol_rom[641]=12'd66; exp_vol_rom[642]=12'd66; exp_vol_rom[643]=12'd67; exp_vol_rom[644]=12'd68; exp_vol_rom[645]=12'd69; exp_vol_rom[646]=12'd69; exp_vol_rom[647]=12'd70; exp_vol_rom[648]=12'd71; exp_vol_rom[649]=12'd72;
    exp_vol_rom[650]=12'd72; exp_vol_rom[651]=12'd73; exp_vol_rom[652]=12'd74; exp_vol_rom[653]=12'd75; exp_vol_rom[654]=12'd76; exp_vol_rom[655]=12'd76; exp_vol_rom[656]=12'd77; exp_vol_rom[657]=12'd78; exp_vol_rom[658]=12'd79; exp_vol_rom[659]=12'd80;
    exp_vol_rom[660]=12'd81; exp_vol_rom[661]=12'd81; exp_vol_rom[662]=12'd82; exp_vol_rom[663]=12'd83; exp_vol_rom[664]=12'd84; exp_vol_rom[665]=12'd85; exp_vol_rom[666]=12'd86; exp_vol_rom[667]=12'd87; exp_vol_rom[668]=12'd88; exp_vol_rom[669]=12'd89;
    exp_vol_rom[670]=12'd90; exp_vol_rom[671]=12'd91; exp_vol_rom[672]=12'd92; exp_vol_rom[673]=12'd93; exp_vol_rom[674]=12'd94; exp_vol_rom[675]=12'd95; exp_vol_rom[676]=12'd96; exp_vol_rom[677]=12'd97; exp_vol_rom[678]=12'd98; exp_vol_rom[679]=12'd99;
    exp_vol_rom[680]=12'd100; exp_vol_rom[681]=12'd101; exp_vol_rom[682]=12'd102; exp_vol_rom[683]=12'd103; exp_vol_rom[684]=12'd104; exp_vol_rom[685]=12'd106; exp_vol_rom[686]=12'd107; exp_vol_rom[687]=12'd108; exp_vol_rom[688]=12'd109; exp_vol_rom[689]=12'd110;
    exp_vol_rom[690]=12'd111; exp_vol_rom[691]=12'd113; exp_vol_rom[692]=12'd114; exp_vol_rom[693]=12'd115; exp_vol_rom[694]=12'd116; exp_vol_rom[695]=12'd118; exp_vol_rom[696]=12'd119; exp_vol_rom[697]=12'd120; exp_vol_rom[698]=12'd121; exp_vol_rom[699]=12'd123;
    exp_vol_rom[700]=12'd124; exp_vol_rom[701]=12'd125; exp_vol_rom[702]=12'd127; exp_vol_rom[703]=12'd128; exp_vol_rom[704]=12'd130; exp_vol_rom[705]=12'd131; exp_vol_rom[706]=12'd132; exp_vol_rom[707]=12'd134; exp_vol_rom[708]=12'd135; exp_vol_rom[709]=12'd137;
    exp_vol_rom[710]=12'd138; exp_vol_rom[711]=12'd140; exp_vol_rom[712]=12'd141; exp_vol_rom[713]=12'd143; exp_vol_rom[714]=12'd144; exp_vol_rom[715]=12'd146; exp_vol_rom[716]=12'd147; exp_vol_rom[717]=12'd149; exp_vol_rom[718]=12'd151; exp_vol_rom[719]=12'd152;
    exp_vol_rom[720]=12'd154; exp_vol_rom[721]=12'd156; exp_vol_rom[722]=12'd157; exp_vol_rom[723]=12'd159; exp_vol_rom[724]=12'd161; exp_vol_rom[725]=12'd162; exp_vol_rom[726]=12'd164; exp_vol_rom[727]=12'd166; exp_vol_rom[728]=12'd168; exp_vol_rom[729]=12'd170;
    exp_vol_rom[730]=12'd171; exp_vol_rom[731]=12'd173; exp_vol_rom[732]=12'd175; exp_vol_rom[733]=12'd177; exp_vol_rom[734]=12'd179; exp_vol_rom[735]=12'd181; exp_vol_rom[736]=12'd183; exp_vol_rom[737]=12'd185; exp_vol_rom[738]=12'd187; exp_vol_rom[739]=12'd189;
    exp_vol_rom[740]=12'd191; exp_vol_rom[741]=12'd193; exp_vol_rom[742]=12'd195; exp_vol_rom[743]=12'd197; exp_vol_rom[744]=12'd199; exp_vol_rom[745]=12'd202; exp_vol_rom[746]=12'd204; exp_vol_rom[747]=12'd206; exp_vol_rom[748]=12'd208; exp_vol_rom[749]=12'd211;
    exp_vol_rom[750]=12'd213; exp_vol_rom[751]=12'd215; exp_vol_rom[752]=12'd217; exp_vol_rom[753]=12'd220; exp_vol_rom[754]=12'd222; exp_vol_rom[755]=12'd225; exp_vol_rom[756]=12'd227; exp_vol_rom[757]=12'd230; exp_vol_rom[758]=12'd232; exp_vol_rom[759]=12'd235;
    exp_vol_rom[760]=12'd237; exp_vol_rom[761]=12'd240; exp_vol_rom[762]=12'd242; exp_vol_rom[763]=12'd245; exp_vol_rom[764]=12'd248; exp_vol_rom[765]=12'd250; exp_vol_rom[766]=12'd253; exp_vol_rom[767]=12'd256; exp_vol_rom[768]=12'd258; exp_vol_rom[769]=12'd261;
    exp_vol_rom[770]=12'd264; exp_vol_rom[771]=12'd267; exp_vol_rom[772]=12'd270; exp_vol_rom[773]=12'd273; exp_vol_rom[774]=12'd276; exp_vol_rom[775]=12'd279; exp_vol_rom[776]=12'd282; exp_vol_rom[777]=12'd285; exp_vol_rom[778]=12'd288; exp_vol_rom[779]=12'd291;
    exp_vol_rom[780]=12'd294; exp_vol_rom[781]=12'd297; exp_vol_rom[782]=12'd301; exp_vol_rom[783]=12'd304; exp_vol_rom[784]=12'd307; exp_vol_rom[785]=12'd310; exp_vol_rom[786]=12'd314; exp_vol_rom[787]=12'd317; exp_vol_rom[788]=12'd321; exp_vol_rom[789]=12'd324;
    exp_vol_rom[790]=12'd328; exp_vol_rom[791]=12'd331; exp_vol_rom[792]=12'd335; exp_vol_rom[793]=12'd338; exp_vol_rom[794]=12'd342; exp_vol_rom[795]=12'd346; exp_vol_rom[796]=12'd350; exp_vol_rom[797]=12'd353; exp_vol_rom[798]=12'd357; exp_vol_rom[799]=12'd361;
    exp_vol_rom[800]=12'd365; exp_vol_rom[801]=12'd369; exp_vol_rom[802]=12'd373; exp_vol_rom[803]=12'd377; exp_vol_rom[804]=12'd381; exp_vol_rom[805]=12'd385; exp_vol_rom[806]=12'd389; exp_vol_rom[807]=12'd394; exp_vol_rom[808]=12'd398; exp_vol_rom[809]=12'd402;
    exp_vol_rom[810]=12'd407; exp_vol_rom[811]=12'd411; exp_vol_rom[812]=12'd416; exp_vol_rom[813]=12'd420; exp_vol_rom[814]=12'd425; exp_vol_rom[815]=12'd429; exp_vol_rom[816]=12'd434; exp_vol_rom[817]=12'd439; exp_vol_rom[818]=12'd443; exp_vol_rom[819]=12'd448;
    exp_vol_rom[820]=12'd453; exp_vol_rom[821]=12'd458; exp_vol_rom[822]=12'd463; exp_vol_rom[823]=12'd468; exp_vol_rom[824]=12'd473; exp_vol_rom[825]=12'd478; exp_vol_rom[826]=12'd483; exp_vol_rom[827]=12'd489; exp_vol_rom[828]=12'd494; exp_vol_rom[829]=12'd499;
    exp_vol_rom[830]=12'd505; exp_vol_rom[831]=12'd510; exp_vol_rom[832]=12'd516; exp_vol_rom[833]=12'd521; exp_vol_rom[834]=12'd527; exp_vol_rom[835]=12'd533; exp_vol_rom[836]=12'd538; exp_vol_rom[837]=12'd544; exp_vol_rom[838]=12'd550; exp_vol_rom[839]=12'd556;
    exp_vol_rom[840]=12'd562; exp_vol_rom[841]=12'd568; exp_vol_rom[842]=12'd574; exp_vol_rom[843]=12'd581; exp_vol_rom[844]=12'd587; exp_vol_rom[845]=12'd593; exp_vol_rom[846]=12'd600; exp_vol_rom[847]=12'd606; exp_vol_rom[848]=12'd613; exp_vol_rom[849]=12'd620;
    exp_vol_rom[850]=12'd626; exp_vol_rom[851]=12'd633; exp_vol_rom[852]=12'd640; exp_vol_rom[853]=12'd647; exp_vol_rom[854]=12'd654; exp_vol_rom[855]=12'd661; exp_vol_rom[856]=12'd668; exp_vol_rom[857]=12'd675; exp_vol_rom[858]=12'd683; exp_vol_rom[859]=12'd690;
    exp_vol_rom[860]=12'd698; exp_vol_rom[861]=12'd705; exp_vol_rom[862]=12'd713; exp_vol_rom[863]=12'd721; exp_vol_rom[864]=12'd728; exp_vol_rom[865]=12'd736; exp_vol_rom[866]=12'd744; exp_vol_rom[867]=12'd752; exp_vol_rom[868]=12'd761; exp_vol_rom[869]=12'd769;
    exp_vol_rom[870]=12'd777; exp_vol_rom[871]=12'd786; exp_vol_rom[872]=12'd794; exp_vol_rom[873]=12'd803; exp_vol_rom[874]=12'd811; exp_vol_rom[875]=12'd820; exp_vol_rom[876]=12'd829; exp_vol_rom[877]=12'd838; exp_vol_rom[878]=12'd847; exp_vol_rom[879]=12'd856;
    exp_vol_rom[880]=12'd866; exp_vol_rom[881]=12'd875; exp_vol_rom[882]=12'd885; exp_vol_rom[883]=12'd894; exp_vol_rom[884]=12'd904; exp_vol_rom[885]=12'd914; exp_vol_rom[886]=12'd924; exp_vol_rom[887]=12'd934; exp_vol_rom[888]=12'd944; exp_vol_rom[889]=12'd954;
    exp_vol_rom[890]=12'd964; exp_vol_rom[891]=12'd975; exp_vol_rom[892]=12'd985; exp_vol_rom[893]=12'd996; exp_vol_rom[894]=12'd1007; exp_vol_rom[895]=12'd1018; exp_vol_rom[896]=12'd1029; exp_vol_rom[897]=12'd1040; exp_vol_rom[898]=12'd1051; exp_vol_rom[899]=12'd1063;
    exp_vol_rom[900]=12'd1074; exp_vol_rom[901]=12'd1086; exp_vol_rom[902]=12'd1098; exp_vol_rom[903]=12'd1110; exp_vol_rom[904]=12'd1122; exp_vol_rom[905]=12'd1134; exp_vol_rom[906]=12'd1146; exp_vol_rom[907]=12'd1159; exp_vol_rom[908]=12'd1171; exp_vol_rom[909]=12'd1184;
    exp_vol_rom[910]=12'd1197; exp_vol_rom[911]=12'd1210; exp_vol_rom[912]=12'd1223; exp_vol_rom[913]=12'd1236; exp_vol_rom[914]=12'd1249; exp_vol_rom[915]=12'd1263; exp_vol_rom[916]=12'd1277; exp_vol_rom[917]=12'd1291; exp_vol_rom[918]=12'd1305; exp_vol_rom[919]=12'd1319;
    exp_vol_rom[920]=12'd1333; exp_vol_rom[921]=12'd1348; exp_vol_rom[922]=12'd1362; exp_vol_rom[923]=12'd1377; exp_vol_rom[924]=12'd1392; exp_vol_rom[925]=12'd1407; exp_vol_rom[926]=12'd1422; exp_vol_rom[927]=12'd1438; exp_vol_rom[928]=12'd1453; exp_vol_rom[929]=12'd1469;
    exp_vol_rom[930]=12'd1485; exp_vol_rom[931]=12'd1501; exp_vol_rom[932]=12'd1517; exp_vol_rom[933]=12'd1534; exp_vol_rom[934]=12'd1551; exp_vol_rom[935]=12'd1567; exp_vol_rom[936]=12'd1584; exp_vol_rom[937]=12'd1602; exp_vol_rom[938]=12'd1619; exp_vol_rom[939]=12'd1637;
    exp_vol_rom[940]=12'd1654; exp_vol_rom[941]=12'd1672; exp_vol_rom[942]=12'd1690; exp_vol_rom[943]=12'd1709; exp_vol_rom[944]=12'd1727; exp_vol_rom[945]=12'd1746; exp_vol_rom[946]=12'd1765; exp_vol_rom[947]=12'd1784; exp_vol_rom[948]=12'd1803; exp_vol_rom[949]=12'd1823;
    exp_vol_rom[950]=12'd1843; exp_vol_rom[951]=12'd1863; exp_vol_rom[952]=12'd1883; exp_vol_rom[953]=12'd1903; exp_vol_rom[954]=12'd1924; exp_vol_rom[955]=12'd1945; exp_vol_rom[956]=12'd1966; exp_vol_rom[957]=12'd1987; exp_vol_rom[958]=12'd2009; exp_vol_rom[959]=12'd2031;
    exp_vol_rom[960]=12'd2053; exp_vol_rom[961]=12'd2075; exp_vol_rom[962]=12'd2098; exp_vol_rom[963]=12'd2120; exp_vol_rom[964]=12'd2143; exp_vol_rom[965]=12'd2167; exp_vol_rom[966]=12'd2190; exp_vol_rom[967]=12'd2214; exp_vol_rom[968]=12'd2238; exp_vol_rom[969]=12'd2262;
    exp_vol_rom[970]=12'd2287; exp_vol_rom[971]=12'd2312; exp_vol_rom[972]=12'd2337; exp_vol_rom[973]=12'd2362; exp_vol_rom[974]=12'd2388; exp_vol_rom[975]=12'd2414; exp_vol_rom[976]=12'd2440; exp_vol_rom[977]=12'd2466; exp_vol_rom[978]=12'd2493; exp_vol_rom[979]=12'd2520;
    exp_vol_rom[980]=12'd2547; exp_vol_rom[981]=12'd2575; exp_vol_rom[982]=12'd2603; exp_vol_rom[983]=12'd2631; exp_vol_rom[984]=12'd2660; exp_vol_rom[985]=12'd2689; exp_vol_rom[986]=12'd2718; exp_vol_rom[987]=12'd2747; exp_vol_rom[988]=12'd2777; exp_vol_rom[989]=12'd2807;
    exp_vol_rom[990]=12'd2838; exp_vol_rom[991]=12'd2869; exp_vol_rom[992]=12'd2900; exp_vol_rom[993]=12'd2931; exp_vol_rom[994]=12'd2963; exp_vol_rom[995]=12'd2995; exp_vol_rom[996]=12'd3028; exp_vol_rom[997]=12'd3061; exp_vol_rom[998]=12'd3094; exp_vol_rom[999]=12'd3127;
    exp_vol_rom[1000]=12'd3161; exp_vol_rom[1001]=12'd3196; exp_vol_rom[1002]=12'd3230; exp_vol_rom[1003]=12'd3265; exp_vol_rom[1004]=12'd3301; exp_vol_rom[1005]=12'd3337; exp_vol_rom[1006]=12'd3373; exp_vol_rom[1007]=12'd3409; exp_vol_rom[1008]=12'd3446; exp_vol_rom[1009]=12'd3484;
    exp_vol_rom[1010]=12'd3522; exp_vol_rom[1011]=12'd3560; exp_vol_rom[1012]=12'd3598; exp_vol_rom[1013]=12'd3637; exp_vol_rom[1014]=12'd3677; exp_vol_rom[1015]=12'd3717; exp_vol_rom[1016]=12'd3757; exp_vol_rom[1017]=12'd3798; exp_vol_rom[1018]=12'd3839; exp_vol_rom[1019]=12'd3881;
    exp_vol_rom[1020]=12'd3923; exp_vol_rom[1021]=12'd3965; exp_vol_rom[1022]=12'd4009; exp_vol_rom[1023]=12'd4052;

    lfo_phase_step_rom[0]=16'd64; lfo_phase_step_rom[1]=16'd768; lfo_phase_step_rom[2]=16'd1216; lfo_phase_step_rom[3]=16'd1600; lfo_phase_step_rom[4]=16'd1984; lfo_phase_step_rom[5]=16'd2240; lfo_phase_step_rom[6]=16'd2368; lfo_phase_step_rom[7]=16'd2688;

    pitch_k_rom[0]=16'd0; pitch_k_rom[1]=16'd256; pitch_k_rom[2]=16'd383; pitch_k_rom[3]=16'd511; pitch_k_rom[4]=16'd766; pitch_k_rom[5]=16'd1527; pitch_k_rom[6]=16'd3042; pitch_k_rom[7]=16'd6004;
end

function automatic [21:0] banked(input [21:0] a);
begin
    if (a < 22'h100000)      banked = a;
    else if (a < 22'h180000) banked = {bank_lo, a[18:0]};
    else                     banked = {bank_hi, a[18:0]};
end
endfunction

// MAME update_step: base=(1+pitch/1024), exponent=(signed octave-1).
// This RTL position uses sixteen fractional bits instead of MAME's TL_SHIFT.
function automatic [24:0] pitch_step(input [3:0] oct_bits, input [9:0] pitch);
    reg signed [4:0] oct;
    reg [24:0] base;
begin
    oct = oct_bits[3] ? $signed({1'b1, oct_bits}) : $signed({1'b0, oct_bits});
    base = {8'b0, 1'b1, pitch, 6'b0};
    if (oct >= 1) pitch_step = base << (oct - 1);
    else          pitch_step = base >> (1 - oct);
end
endfunction

// gew.cpp envelope_generator_calc: rate = (octave + key_rate_scale)*2 +
// pitch_bit9, unless key_rate_scale==0xf (key scaling disabled -> rate=0).
// octave here is the SAME raw pitch-register octave nibble used by
// pitch_step() above, sign-extended the same way (not the oct-1 used
// inside pitch_step's shift amount).
function automatic signed [6:0] calc_rate_base(
    input [3:0] oct_bits,
    input       pbit9,
    input [3:0] krs
);
    reg signed [5:0] oct_s;
    reg signed [6:0] sum;
begin
    oct_s = oct_bits[3] ? $signed({2'b11, oct_bits}) : $signed({2'b00, oct_bits});
    if (krs == 4'hf)
        calc_rate_base = 7'sd0;
    else begin
        sum = (oct_s + $signed({3'b0, krs})) <<< 1;
        calc_rate_base = sum + $signed({6'b0, pbit9});
    end
end
endfunction

// gew.cpp get_rate(): val==0 -> step[0] (=0, infinite time); val==0xf ->
// step[0x3f] (fastest); otherwise clamp(4*val+rate_base, 0, 63).
function automatic [26:0] env_step(
    input [1:0] state,
    input [3:0] attack_reg, decay1_reg, decay2_reg, release_reg,
    input signed [6:0] rate_base
);
    reg [3:0] val;
    reg [5:0] idx;
    reg signed [8:0] r;
    reg is_attack;
begin
    is_attack = (state == ENV_ATTACK);
    case (state)
        ENV_ATTACK:  val = attack_reg;
        ENV_DECAY1:  val = decay1_reg;
        ENV_DECAY2:  val = decay2_reg;
        default:     val = release_reg; // ENV_RELEASE
    endcase
    if (val == 4'h0)
        idx = 6'd0;
    else if (val == 4'hf)
        idx = 6'd63;
    else begin
        r = ($signed({5'b0, val}) <<< 2) + rate_base;
        if (r < 0)        idx = 6'd0;
        else if (r > 63)  idx = 6'd63;
        else              idx = r[5:0];
    end
    env_step = is_attack ? attack_step_rom[idx] : decay_step_rom[idx];
end
endfunction

// gew.cpp lfo_init(): m_pitch_table piecewise-linear triangle, stored as an
// offset+128 value 1..255 (so it can index a scale table built for i in
// -128..127); returned here already converted back to a signed -127..127
// offset for direct use in the linear cents approximation.
function automatic signed [8:0] lfo_pitch_wave(input [7:0] i);
    reg [9:0] v;
begin
    if (i < 8'd64)        v = {2'b0, i} * 10'd2 + 10'd128;
    else if (i < 8'd128)  v = 10'd383 - ({2'b0, i} * 10'd2);
    else if (i < 8'd192)  v = 10'd384 - ({2'b0, i} * 10'd2);
    else                  v = ({2'b0, i} * 10'd2) - 10'd383;
    lfo_pitch_wave = $signed({1'b0, v[7:0]}) - 9'sd128;
end
endfunction

// gew.cpp lfo_init(): m_amplitude_table, unipolar triangle 0..255 (tremolo
// only ever attenuates, matching AMPLITUDE_SCALE_LIMIT being <=0 in MAME).
function automatic [7:0] lfo_amp_wave(input [7:0] i);
    reg [9:0] v;
begin
    if (i < 8'd128) v = 10'd255 - ({2'b0, i} * 10'd2);
    else            v = ({2'b0, i} * 10'd2) - 10'd256;
    lfo_amp_wave = v[7:0];
end
endfunction

function automatic [10:0] pan_gain(input [2:0] distance);
begin
    case (distance)
        3'd0: pan_gain = 11'd1024;
        3'd1: pan_gain = 11'd724;
        3'd2: pan_gain = 11'd513;
        3'd3: pan_gain = 11'd363;
        3'd4: pan_gain = 11'd257;
        3'd5: pan_gain = 11'd182;
        3'd6: pan_gain = 11'd128;
        default: pan_gain = 11'd0;
    endcase
end
endfunction

function automatic signed [15:0] pan_attenuate(
    input signed [15:0] sample,
    input [2:0] distance
);
    reg signed [26:0] product;
begin
    product = sample * $signed({1'b0, pan_gain(distance)});
    pan_attenuate = product >>> 10;
end
endfunction

function automatic signed [15:0] pan_sample(
    input signed [15:0] sample,
    input [3:0] pan,
    input is_left
);
    reg [3:0] distance;
begin
    if (pan == 4'h8) begin
        pan_sample = 16'sd0;
    end
    else if (pan == 4'h0) begin
        pan_sample = sample;
    end
    else if (!pan[3]) begin
        // 1..7 attenuate left; 7 is hard-left mute. MAME uses a 3 dB
        // exponential step, represented here as the exact Q10 table.
        if (!is_left) pan_sample = sample;
        else pan_sample = pan_attenuate(sample, pan[2:0]);
    end
    else begin
        // 9..15 attenuate right using MAME's inverted distance.
        distance = 4'd0 - pan;
        if (is_left) pan_sample = sample;
        else pan_sample = pan_attenuate(sample, distance[2:0]);
    end
end
endfunction

function automatic signed [15:0] clamp16(input signed [21:0] value);
begin
    if (value > 22'sd32767)       clamp16 = 16'sh7fff;
    else if (value < -22'sd32768) clamp16 = -16'sh8000;
    else                          clamp16 = value[15:0];
end
endfunction

// ---------------------------------------------------------------------
// Storage read ports.
// ---------------------------------------------------------------------
reg [4:0] desc_pick;    // lowest pending descriptor slot
integer pi;
always @* begin
    desc_pick = 5'd0;
    for (pi = 27; pi >= 0; pi = pi - 1)
        if (desc_pending[pi]) desc_pick = pi[4:0];
end

wire [3:0]  pan_q      = zr0[mac_p2_slot] ? 4'h0 : r0_mem[mac_p2_slot];
wire [7:0]  r1_pick_q  = zr1[desc_pick]   ? 8'h00 : r1_mem[desc_pick];
wire        r2_pick_q  = zr2[desc_pick]   ? 1'b0 : r2p_mem[desc_pick];
wire [5:0]  r2_slot_q  = zr2[slot]        ? 6'd0 : r2s_mem[slot];
wire [7:0]  r3_slot_q  = zr3[slot]        ? 8'h00 : r3s_mem[slot];
wire [4:0]  r3_df_q    = zr3[df_slot]     ? 5'd0 : r3d_mem[df_slot];
wire [6:0]  tl_slot_q  = zr5[slot]        ? 7'd0 : r5_mem[slot];
wire [7:0]  r6_slot_q  = sreg6[slot];
wire [7:0]  r7_slot_q  = sreg7[slot];

wire [42:0] da_q       = da_mem[slot];
wire [21:0] start_q    = da_q[42:21];
wire        fmt12_q    = da_q[20];
wire [3:0]  rel_q      = da_q[19:16];
wire [3:0]  att_q      = da_q[15:12];
wire [3:0]  d1_q       = da_q[11:8];
wire [3:0]  d2_q       = da_q[7:4];
wire [3:0]  dlev_q     = da_q[3:0];
wire [32:0] dl_q       = dl_mem[pitch_p1_slot];
wire [15:0] loop_p1_q  = dl_q[32:17];
wire [16:0] end_p1_q   = dl_q[16:0];
wire signed [6:0] rb_q = rb_mem[slot];

wire [37:0] pos_slot_q = zp[slot]          ? 38'd0 : pa_mem[slot];
wire [37:0] pos_p1_q   = zp[pitch_p1_slot] ? 38'd0 : pb_mem[pitch_p1_slot];
wire [26:0] vol_q      = ze[slot]          ? 27'd0 : ev_mem[slot];
wire [11:0] egain_q    = zg[mac_p1_slot]   ? 12'd0 : eg_mem[mac_p1_slot];
wire [23:0] lfo_q      = zl[slot]          ? 24'd0 : lf_mem[slot];
wire [12:0] again_q    = za[mac_p2_slot]   ? 13'd1024 : {2'b00, ag_mem[mac_p2_slot]};
wire signed [15:0] hold_q;

// ---------------------------------------------------------------------
// Tick-0 voice update (combinational): LFO step, pitch-LFO stage 1,
// amplitude-LFO gain and the envelope generator for the voice at `slot`.
// Committed by the sequential block below and the RAM write ports.
// ---------------------------------------------------------------------
reg [24:0] t0_step;
reg [23:0] t0_lfo_next;
reg signed [25:0] t0_pdelta;
reg [12:0] t0_alfo;
reg [26:0] t0_newvol;
reg  [1:0] t0_state;
reg        t0_state_we;
reg        t0_release_done;
always @* begin
    reg [9:0] pitch;
    reg [7:0]  lfo_idx;
    reg signed [8:0] pitch_off;
    reg [7:0]  amp_off;
    reg [14:0] amp_idx_wide;
    reg [6:0]  amp_idx;
    reg [26:0] evstep;
    reg [26:0] d1step;
    reg  [1:0] st;

    pitch = {r3_slot_q[3:0], r2_slot_q};
    t0_step = pitch_step(r3_slot_q[7:4], pitch);

    // --- LFO: advance phase, then apply PLFO/ALFO. ---
    t0_lfo_next = lfo_q + lfo_phase_step_rom[r6_slot_q[5:3]];
    lfo_idx = t0_lfo_next[23:16];

    // Pitch-LFO pipeline stage 1/2: only the small (9x17) multiply happens
    // here; the 25x26 step*delta multiply runs in the pitch_p1_valid stage.
    pitch_off = 9'sd0;
    if (r6_slot_q[2:0] != 3'd0) begin
        pitch_off = lfo_pitch_wave(lfo_idx);
        t0_pdelta = $signed(pitch_off) *
            $signed({1'b0, pitch_k_rom[r6_slot_q[2:0]]});
    end
    else
        t0_pdelta = 26'sd0;

    amp_off = 8'd0;
    amp_idx_wide = 15'd0;
    amp_idx = 7'd0;
    if (r7_slot_q[2:0] != 3'd0) begin
        amp_off = lfo_amp_wave(lfo_idx);
        amp_idx_wide = amp_off * amp_step_pow2(r7_slot_q[2:0]);
        // Index is the SHIFTED product (tri*K)>>8, i.e. bits [14:8] --
        // taking the raw low bits [6:0] swept the index 0..127 (up to -48dB,
        // oscillating at the LFO rate) instead of the intended 0..K-1 range.
        // OutRunners' engine voice is the only voice with tremolo enabled
        // (driver writes r7=01 every frame; all sample descriptors carry
        // lfo_amp=0), so that bug silenced exactly the car engine. With
        // K<=64 and tri<=255 the >>8 result maxes at 63, so the 127 clamp is
        // headroom only.
        amp_idx = (amp_idx_wide >> 8) > 15'd127 ? 7'd127 : amp_idx_wide[14:8];
        t0_alfo = {2'b0, tl_gain_rom[amp_idx]};
    end
    else
        t0_alfo = 13'd1024;

    // --- Envelope generator: one update per voice per output-sample tick,
    // matching gew.cpp's envelope_generator_update() call cadence. ---
    st = s_env_state[slot];
    evstep = env_step(st, att_q, d1_q, d2_q, rel_q, rb_q);
    d1step = 27'd0;
    t0_state = st;
    t0_state_we = 1'b0;
    t0_release_done = 1'b0;
    case (st)
        ENV_ATTACK: begin
            t0_newvol = vol_q + evstep;
            if (t0_newvol >= 27'h4000000) begin
                d1step = env_step(ENV_DECAY1, att_q, d1_q, d2_q, rel_q, rb_q);
                t0_state = (d1step >= 27'h4000000) ? ENV_DECAY2 : ENV_DECAY1;
                t0_state_we = 1'b1;
                t0_newvol = 27'h3ff0000;
            end
        end
        ENV_DECAY1: begin
            t0_newvol = (vol_q > evstep) ? (vol_q - evstep) : 27'd0;
            if ((t0_newvol >> 22) <= {23'd0, dlev_q}) begin
                t0_state = ENV_DECAY2;
                t0_state_we = 1'b1;
            end
        end
        ENV_DECAY2: begin
            t0_newvol = (vol_q > evstep) ? (vol_q - evstep) : 27'd0;
        end
        default: begin // ENV_RELEASE
            t0_newvol = (vol_q > evstep) ? (vol_q - evstep) : 27'd0;
            t0_release_done = (t0_newvol == 27'd0);
        end
    endcase
end

// Stage 3 of the s_pos position-update pipeline: loop-wrap compare and
// conditional subtract of the raw add registered by the pitch stage.
wire [37:0] pos_committed =
    (pos_commit_add >= pos_commit_end16 && pos_commit_loop_span != 0) ?
        pos_commit_add - {4'd0, pos_commit_loop_span} : pos_commit_add;

// ---------------------------------------------------------------------
// RAM write ports.  Every enable is the exact condition under which the old
// array assignment executed (never during rst).
// ---------------------------------------------------------------------
wire z_reg_we   = !rst && cs && we && (addr == 2'd0) && cur_slot_valid;
wire desc_done  = !rst && rom_req && rom_ack && rom_is_desc && (df_idx == 4'd11);
wire desc_key   = desc_done && key_wait[df_slot];
wire hold_ack   = !rst && rom_req && rom_ack && !rom_is_desc && !rom_beat12;
wire t0_we      = !rst && ce && (tick == 3'd0) && s_active[slot];
wire pos_we     = !rst && ce && pos_commit_pending;
wire egain_we   = !rst && ce && env_p1_valid;

wire signed [15:0] hold_sample =
    play_fmt12 ? (play_odd ? {rom_data, play_mid[7:4], 4'h0}
                           : {rom_data, play_mid[3:0], 4'h0})
               : {rom_data, 8'h00};
// Sample-byte ack and key-on descriptor completion are exclusive (one ROM
// ack is either a descriptor beat or a sample beat).
wire               hold_we   = hold_ack || desc_key;
wire        [4:0]  hold_wa   = hold_ack ? play_slot : df_slot;
wire signed [15:0] hold_wd   = hold_ack ? hold_sample : 16'sd0;

(* ramstyle = "MLAB, no_rw_check" *) reg [15:0] hd_mem [0:31];
`ifdef MPCM_GARBAGE_INIT
initial for (gi = 0; gi < 32; gi = gi + 1) hd_mem[gi] = $random;
`endif
assign hold_q = hd_mem[slot];

always @(posedge clk) begin
    if (z_reg_we) begin
        case (cur_reg)
            3'd0: r0_mem[cur_slot] <= wdata[7:4];
            3'd1: r1_mem[cur_slot] <= wdata;
            3'd5: r5_mem[cur_slot] <= wdata[7:1];
            default: ;
        endcase
        if (cur_reg == 3'd2) r2p_mem[cur_slot] <= wdata[0];
        if (cur_reg == 3'd2) r2s_mem[cur_slot] <= wdata[7:2];
        if (cur_reg == 3'd3) r3s_mem[cur_slot] <= wdata;
        if (cur_reg == 3'd3) r3d_mem[cur_slot] <= wdata[7:3];
    end
end

always @(posedge clk) begin
    if (desc_done) begin
        da_mem[df_slot] <= {df_buf[0][5:0], df_buf[1], df_buf[2], df_buf[0][6],
                            df_buf[10][3:0], df_buf[8][7:4], df_buf[8][3:0],
                            df_buf[9][3:0], df_buf[9][7:4]};
        dl_mem[df_slot] <= {df_buf[3], df_buf[4],
                            17'h10000 - {1'b0, df_buf[5], df_buf[6]}};
    end
    // gew.cpp retrigger_sample()+envelope_generator_calc: key-scaled rate
    // base from the raw octave nibble, pitch bit 9 and key_rate_scale.
    if (desc_key)
        rb_mem[df_slot] <= calc_rate_base(r3_df_q[4:1], r3_df_q[0],
                                          df_buf[10][7:4]);
    if (hold_we) hd_mem[hold_wa] <= hold_wd;
end

always @(posedge clk) begin
    if (pos_we) begin
        pa_mem[pos_commit_slot] <= pos_committed;
        pb_mem[pos_commit_slot] <= pos_committed;
    end
    if (t0_we) begin
        ev_mem[slot] <= t0_newvol;
        lf_mem[slot] <= t0_lfo_next;
        ag_mem[slot] <= t0_alfo[10:0];
    end
    if (egain_we) eg_mem[env_p1_slot] <= exp_vol_rom[env_p1_idx];
end

always @(posedge clk) begin
    if (rst) begin
        cur_slot <= 0;
        cur_slot_valid <= 1'b1;
        cur_reg <= 0;
        rom_req <= 0;
        rom_addr <= 0;
        rom_is_desc <= 0;
        rom_beat12 <= 0;
        pos_commit_pending <= 1'b0;
        mac_p1_valid <= 1'b0;
        mac_p2_valid <= 1'b0;
        pitch_p1_valid <= 1'b0;
        env_p1_valid <= 1'b0;
        play_beat2_pending <= 0;
        play_fmt12 <= 0;
        play_odd <= 0;
        play_mid <= 0;
        play_base3 <= 0;
        desc_pending <= 0;
        key_wait <= 0;
        df_slot <= 0;
        df_sample <= 0;
        df_idx <= 0;
        df_busy <= 0;
        tick <= 0;
        slot <= 0;
        play_slot <= 0;
        acc_l <= 0;
        acc_r <= 0;
        out_l <= 0;
        out_r <= 0;
        s_active <= 28'd0;
        zr0 <= {28{1'b1}};
        zr1 <= {28{1'b1}};
        zr2 <= {28{1'b1}};
        zr3 <= {28{1'b1}};
        zr5 <= {28{1'b1}};
        zp  <= {28{1'b1}};
        ze  <= {28{1'b1}};
        zg  <= {28{1'b1}};
        zl  <= {28{1'b1}};
        za  <= {28{1'b1}};
        for (ri = 0; ri < 28; ri = ri + 1) begin
            s_env_state[ri] <= ENV_RELEASE;
            sreg6[ri] <= 0;
            sreg7[ri] <= 0;
        end
        for (ri = 0; ri < 12; ri = ri + 1)
            df_buf[ri] <= 0;
    end
    else begin
        // Default-pulse mac_p1_valid low; the tick==4 MAC stage 0 below
        // overrides this with <= 1'b1 (default-then-override NBA idiom).
        mac_p1_valid <= 1'b0;
        // NOTE: pitch_p1_valid deliberately has NO every-clk default clear.
        // The pitch-LFO pipeline is produced and consumed inside the
        // `ce`-gated voice state machine below; a default clear here would
        // fire long before the next `ce` and drop every deferred position
        // update. It is cleared explicitly by its stage-2 consumer instead,
        // exactly like pos_commit_pending.
        // Register writes are on the Z80 clock domain represented by clk and
        // must not be dropped merely because the audio sample CE is low.
        if (cs && we) begin
            case (addr)
                2'd1: begin
                    // VALUE_TO_CHANNEL: every eighth selector is a hole.
                    cur_slot_valid <= (wdata[2:0] != 3'd7);
                    if (wdata[2:0] != 3'd7)
                        cur_slot <= wdata[4:0] - {3'b000, wdata[4:3]};
                end
                2'd2: cur_reg <= (wdata > 8'd7) ? 3'd7 : wdata[2:0];
                2'd0: if (cur_slot_valid) begin
                    case (cur_reg)
                        3'd0: zr0[cur_slot] <= 1'b0;
                        3'd1: zr1[cur_slot] <= 1'b0;
                        3'd2: zr2[cur_slot] <= 1'b0;
                        3'd3: zr3[cur_slot] <= 1'b0;
                        3'd5: zr5[cur_slot] <= 1'b0;
                        3'd6: sreg6[cur_slot] <= wdata;
                        3'd7: sreg7[cur_slot] <= wdata;
                        default: ;
                    endcase
                    if (cur_reg == 3'd1) begin
                        // Sample index is nine bits; bit 8 lives in pitch reg2.
                        desc_pending[cur_slot] <= 1'b1;
                        if (s_active[cur_slot]) begin
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b1;
                        end
                    end
                    if (cur_reg == 3'd4) begin
                        if (wdata[7]) begin
                            // Fetch current metadata before starting so no
                            // uninitialized start/end state can be sampled.
                            s_active[cur_slot] <= 1'b0;
                            key_wait[cur_slot] <= 1'b1;
                            desc_pending[cur_slot] <= 1'b1;
                        end
                        else begin
                            // gew.cpp write(): key-off just sets
                            // envelope_gen.m_state=RELEASE; the voice keeps
                            // playing (s_active stays set) while the release
                            // rate ramps m_volume to zero, matching
                            // envelope_generator_update()'s RELEASE case
                            // which only clears m_playing at volume==0.
                            s_env_state[cur_slot] <= ENV_RELEASE;
                            key_wait[cur_slot] <= 1'b0;
                        end
                    end
                end
                default: ;
            endcase
        end

        // ROM acknowledgements are sampled every clk, not only on ce.  The
        // SDRAM/cache response is a clk-domain pulse and may fall between CEs.
        if (rom_req && rom_ack) begin
            rom_req <= 1'b0;
            if (rom_is_desc) begin
                df_buf[df_idx] <= rom_data;
                if (df_idx == 4'd11) begin
                    // Descriptor fields commit through da/dl/rb_mem above.
                    df_busy <= 1'b0;
                    // Hardware copies descriptor defaults into LFO registers.
                    sreg6[df_slot] <= df_buf[7];
                    sreg7[df_slot] <= {4'b0000, rom_data[3:0]};
                    if (key_wait[df_slot]) begin
                        s_active[df_slot] <= 1'b1;
                        // Position and envelope volume restart at zero; the
                        // hold RAM is cleared through its write port so the
                        // retriggered voice does not replay one frame of its
                        // previous sample.  A same-edge tick-0 or position
                        // commit for this slot clears the flag again below,
                        // matching the old later-NBA-wins order.
                        zp[df_slot] <= 1'b1;
                        ze[df_slot] <= 1'b1;
                        key_wait[df_slot] <= 1'b0;
                        // A stage-2 position commit may still be in flight
                        // for this same slot from before the retrigger;
                        // cancel it so it cannot land after this reset.
                        if (pos_commit_pending && pos_commit_slot == df_slot)
                            pos_commit_pending <= 1'b0;
                        // Same cancellation, one stage earlier: a pitch-LFO
                        // multiply in flight for this slot must not resolve
                        // into a pos_commit after this reset either.
                        if (pitch_p1_valid && pitch_p1_slot == df_slot)
                            pitch_p1_valid <= 1'b0;
                        // Same cancellation for the envelope-gain pipeline:
                        // a stale pre-retrigger newvol index must not land
                        // in the envelope gain after ATTACK/vol=0 below.
                        if (env_p1_valid && env_p1_slot == df_slot)
                            env_p1_valid <= 1'b0;
                        // gew.cpp retrigger_sample(): restart the envelope
                        // from ATTACK/vol=0. LFO phase is NOT reset here.
                        s_env_state[df_slot] <= ENV_ATTACK;
                    end
                end
                else begin
                    df_idx <= df_idx + 1'b1;
                end
            end
            else if (rom_beat12) begin
                // First beat of a 12-bit fetch: the shared nibble byte.
                // The second beat reuses play_base3, latched at issue time
                // in the tick==0 branch below. rom_req is left deasserted
                // this cycle so the responder sees a clean request boundary
                // between beats.
                play_mid <= rom_data;
                rom_beat12 <= 1'b0;
                play_beat2_pending <= 1'b1;
            end
            // else: the sample byte lands in the hold RAM (hold_we above);
            // the MAC launches from it at the slot's fixed mix phase
            // (tick==4), so a late ack can never stall the frame cadence.
        end

        // Pipeline stage 1/3: *env_gain (EXP_VOL_ROM, Q12). Runs every clk,
        // one cycle after stage 0 registers mac_p1_val/mac_p1_slot.
        if (mac_p1_valid) begin
            reg signed [31:0] mul2;
            mul2 = mac_p1_val * $signed({1'b0, egain_q});
            mac_p2_valid <= 1'b1;
            mac_p2_slot  <= mac_p1_slot;
            mac_p2_val   <= mul2 >>> 12;
        end
        else
            mac_p2_valid <= 1'b0;

        // Pipeline stage 2/3: amplitude-LFO (tremolo) gain, Q10 via
        // TL_GAIN_ROM reuse (neutral 1024 when tremolo depth is zero), then
        // pan and commit to acc_l/acc_r.
        if (mac_p2_valid) begin
            reg signed [31:0] mul3;
            reg signed [15:0] attenuated;
            reg signed [15:0] pan_attenuated;
            reg signed [15:0] panned_l;
            reg signed [15:0] panned_r;
            reg [3:0] pan_code;
            reg [3:0] pan_distance;
            mul3 = mac_p2_val * $signed({1'b0, again_q});
            attenuated = mul3 >>> 10;
            pan_code = pan_q;
            pan_distance = pan_code[3] ? (4'd0 - pan_code) : pan_code;
            pan_attenuated = pan_attenuate(attenuated, pan_distance[2:0]);
            if (pan_code == 4'h8) begin
                panned_l = 16'sd0;
                panned_r = 16'sd0;
            end
            else if (pan_code == 4'h0) begin
                panned_l = attenuated;
                panned_r = attenuated;
            end
            else if (!pan_code[3]) begin
                panned_l = pan_attenuated;
                panned_r = attenuated;
            end
            else begin
                panned_l = attenuated;
                panned_r = pan_attenuated;
            end
            acc_l <= acc_l + {{6{panned_l[15]}}, panned_l};
            acc_r <= acc_r + {{6{panned_r[15]}}, panned_r};
        end

        if (ce) begin
            reg sample_will_issue;
            // Will the tick==0 voice logic below claim the ROM port on this
            // edge? Arbitration must skip this edge so two writers never
            // race rom_addr/rom_is_desc.
            sample_will_issue = (tick == 3'd0) && s_active[slot] && !rom_req &&
                                !df_busy && !play_beat2_pending;

            // Fixed 224-ce frame cadence: tick/slot advance every ce and are
            // never gated by ROM traffic.
            tick <= tick + 1'b1;
            if (tick == 3'd7) begin
                tick <= 0;
                if (slot == 5'd27) begin
                    slot <= 0;
                    out_l <= clamp16(acc_l >>> 2);
                    out_r <= clamp16(acc_r >>> 2);
                    acc_l <= 0;
                    acc_r <= 0;
                end
                else slot <= slot + 1'b1;
            end

            // MAC stage 0 at the slot's fixed mix phase, from the hold RAM.
            // tick==4 gives a same-frame fresh byte whenever the fetch issued
            // at this slot's tick==0 acks within ~19 clk; slower acks mix the
            // previous frame's byte (a 22us hold).
            if (tick == 3'd4 && s_active[slot]) begin
                reg signed [31:0] mul1;
                mul1 = hold_q * $signed({1'b0, tl_gain_rom[tl_slot_q]});
                mac_p1_valid <= 1'b1;
                mac_p1_slot  <= slot;
                mac_p1_val   <= mul1 >>> 10;
            end

            if (!sample_will_issue && !df_busy && desc_pending != 0 &&
                !rom_req && !play_beat2_pending) begin
                df_slot <= desc_pick;
                df_sample <= {r2_pick_q, r1_pick_q};
                df_idx <= 0;
                df_busy <= 1'b1;
                desc_pending[desc_pick] <= 1'b0;
            end
            else if (!sample_will_issue && df_busy && !rom_req) begin
                rom_req <= 1'b1;
                rom_is_desc <= 1'b1;
                rom_addr <= (df_sample * 22'd12) + {18'd0, df_idx};
            end
            else if (!sample_will_issue && play_beat2_pending && !rom_req) begin
                rom_req <= 1'b1;
                rom_is_desc <= 1'b0;
                rom_addr <= banked(play_base3 + (play_odd ? 22'd2 : 22'd0));
                play_beat2_pending <= 1'b0;
            end

            if (tick == 0 && s_active[slot]) begin
                reg [21:0] base3_comb;

                // LFO phase, amplitude-LFO gain and envelope volume commit
                // through their RAM write ports (t0_we).
                zl[slot] <= 1'b0;
                za[slot] <= 1'b0;
                ze[slot] <= 1'b0;

                pitch_p1_valid <= 1'b1;
                pitch_p1_slot  <= slot;
                pitch_p1_step  <= t0_step;
                pitch_p1_delta <= t0_pdelta;

                if (sample_will_issue) begin
                    play_slot <= slot;
                    play_fmt12 <= fmt12_q;
                    play_odd <= pos_slot_q[16];
                    rom_req <= 1'b1;
                    rom_is_desc <= 1'b0;
                    if (fmt12_q) begin
                        // First beat fetches the shared nibble byte (adr+1);
                        // the second beat (adr for even samples, adr+2 for
                        // odd) follows from play_base3.
                        base3_comb = start_q + (pos_slot_q[37:17] * 22'd3);
                        play_base3 <= base3_comb;
                        rom_beat12 <= 1'b1;
                        rom_addr <= banked(base3_comb + 22'd1);
                    end
                    else begin
                        rom_beat12 <= 1'b0;
                        rom_addr <= banked(start_q + pos_slot_q[37:16]);
                    end
                end
                // else: ROM port busy this edge -- skip this frame's fetch;
                // the hold RAM keeps the previous byte and the position still
                // advances, so tempo and pitch are unaffected.

                if (t0_state_we)
                    s_env_state[slot] <= t0_state;
                if (t0_release_done)
                    s_active[slot] <= 1'b0;
                env_p1_valid <= 1'b1;
                env_p1_slot  <= slot;
                env_p1_idx   <= t0_newvol[25:16];
            end

            // Pitch-LFO pipeline stage 2/2: the 25x26 step*delta multiply,
            // feeding the pos_commit pipeline one idle-tick cycle later.
            if (pitch_p1_valid) begin
                reg signed [50:0] pitch_adj_mul;
                reg signed [24:0] step_lfo;
                reg [37:0] next_pos;
                reg [33:0] loop_span;
                pitch_p1_valid <= 1'b0;
                pitch_adj_mul = $signed({1'b0, pitch_p1_step}) * pitch_p1_delta;
                step_lfo = $signed({1'b0, pitch_p1_step}) +
                    (pitch_adj_mul >>> 24);
                next_pos = pos_p1_q + {13'd0, step_lfo[24:0]};
                loop_span = ({17'd0, end_p1_q} - {18'd0, loop_p1_q}) << 16;
                pos_commit_pending  <= 1'b1;
                pos_commit_slot     <= pitch_p1_slot;
                pos_commit_add      <= next_pos;
                pos_commit_loop_span<= loop_span;
                pos_commit_end16    <= {21'd0, end_p1_q} << 16;
            end

            // Envelope-generator gain pipeline stage 2: the exp_vol_rom
            // lookup commits through eg_mem's write port (egain_we).
            if (env_p1_valid) begin
                env_p1_valid <= 1'b0;
                zg[env_p1_slot] <= 1'b0;
            end

            // Position-update pipeline stage 3: commit through pa/pb_mem.
            if (pos_commit_pending) begin
                pos_commit_pending <= 1'b0;
                zp[pos_commit_slot] <= 1'b0;
            end
        end
    end
end

endmodule
