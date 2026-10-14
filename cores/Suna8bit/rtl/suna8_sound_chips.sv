// Sound chip synthesis: real YM3812 (OPL2), AY-3-8910 and dual YM2203
// cores (vendored jtopl2/jt49/jt03 -- see third_party/README.md),
// replacing the previous write-captured-only stub (audio_l/audio_r were
// hardcoded to zero). Independently decodes the sound Z80 bus's chip
// register window -- it does not touch ROM/RAM/latch addresses, which
// stay in suna8_sound_memory.sv -- so this is a self-contained peer,
// wired in parallel at suna8_core.sv the same way suna8_palette.sv/
// suna8_sprite_ram.sv already are.
//
// Chip mapping per suna8.cpp's machine configs:
//   HARDHEAD/SPARKMAN/STARFIGH (hardhead_sound_map): ymsnd (YM3812) rw
//     a000-a001, aysnd (AY8910) address_data_w a002-a003 (offset 0
//     latches the register address, offset 1 writes data to it -- MAME's
//     ay8910_device::address_data_w abstraction; jt49 wants the register
//     address directly, so that two-step latch is reproduced below).
//     ymsnd's status_r is also mirrored at $C800 in suna8_sound_memory.sv
//     -- same physical status byte, since jtopl2's dout output ignores
//     addr on reads and always presents the status byte (see
//     third_party/jtopl/jtopl.v: "assign dout = {~irq_n,flag_A,flag_B,..}").
//   HARDHEA2/BRICKZN (brickzn_sound_map -- hardhea2's machine_config
//     literally calls brickzn(config) first and only overrides the main
//     CPU, so it inherits brickzn's entire sound section unchanged,
//     confirmed against suna8.cpp:2100 -- this was NOT what this
//     project's RTL implemented before this pass, which ran hardhea2's
//     sound CPU against hardhead_sound_map's addresses/ROM size instead,
//     a real correctness bug independent of chip synthesis; see
//     suna8_sound_memory.sv): same ymsnd(YM3812)+aysnd(AY8910) chip
//     *types*, but at c000-c001/c002-c003 instead, write-only (no ymsnd
//     status read mapped at all), and ymsnd's own IRQ output drives the
//     sound CPU's IRQ0 directly (NOT the periodic-timer IRQ the other
//     profiles use -- suna8.cpp: "ymsnd.irq_handler().set_inputline
//     (audiocpu, 0)" -- see suna8_core.sv's sound_irq_n mux).
//   SRANGER (rranger_sound_map): two independent YM2203 ("ym1"/"ym2")
//     chips at a000-a001/a002-a003, write-only, each a full standalone
//     OPN chip (not an AY8910 -- MAME's own device type is
//     ym2203_device). jt03 wraps a single YM2203 (JT12 family,
//     use_lfo=0/use_ssg=1/num_ch=3/use_pcm=0/use_adpcm=0 per its own
//     definition) -- see third_party/jt12/jt03.v. jt03's embedded
//     YM2149-compatible PSG I/O only supports port INPUT, not output, so
//     ym1's sample-trigger callback is snooped from the register bus below.
//
// SAMPLES device (suna8_a.cpp): raw 4-bit/8kHz PCM voice-clip playback,
// triggered by AY8910 (aysnd, hardhead/sparkman/starfigh)/YM2203 (ym1,
// sranger) port A/B writes, is now implemented below -- see the "SAMPLES
// device" section. hardhea2/brickzn have no SAMPLES device in suna8.cpp
// at all (matches is_hardhead_group/is_sranger gating already used
// elsewhere in this file for exactly this reason).
//
// The separate hardhea2/brickzn PCM Z80 and four DAC channels are implemented
// in suna8_pcm.sv and mixed below. Exact resistor values remain a hardware
// evidence item; the profile-gated fixed-point gains below match the MAME
// route values as the current behavioural contract.
module suna8_sound_chips
(
    input  logic clk,
    input  logic reset,
    input  logic [2:0] profile_id,

    input  logic [15:0] cpu_addr,
    input  logic [7:0] cpu_dout,
    input  logic cpu_write,      // combinational !mreq_n && !iorq && !wr_n

    output logic [7:0] ym3812_dout,    // status byte, valid every cycle
                                        // regardless of address
    output logic ym3812_irq_n,         // for hardhea2/brickzn's chip-IRQ
                                        // -driven sound IRQ0

    // SAMPLES device ROM window (MEDIA_SAMPLES, 64KB, up to 32 slots of
    // 2048 bytes each -- see suna8_media_pkg.sv). Combinational read in
    // the sim media backing store (verif/suna8_sim_media.sv), same cycle.
    output logic [15:0] sample_media_read_addr,
    input  logic [7:0] sample_media_read_q,
    input  logic sample_media_read_ready,

    // hardhea2/brickzn's separate PCM Z80 + 4x DAC (suna8_pcm.sv),
    // pre-summed and pre-saturated there; zero on every other profile
    // (that module is held in reset). Mixed in as a 6th term below.
    input  logic signed [15:0] pcm_snd,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);

    import suna8_profile_pkg::*;

    // ------------------------------------------------------------------
    // Chip-rate clock enables, derived from the raw 24 MHz system clock.
    // Every chip here runs at a clock the real PCB derives from the same
    // 24 MHz XTAL as everything else (suna8.cpp: "24_MHz_XTAL / 8" for
    // ymsnd = 3.000 MHz, "24_MHz_XTAL / 16" for aysnd/ym1/ym2 = 1.500 MHz
    // -- confirmed against adb.arcadeitalia.net's independently measured
    // "YM3812 @ 3 Mhz" / "AY8910 @ 1.5 Mhz").
    // ------------------------------------------------------------------
    logic [2:0] cen_div8;
    logic [3:0] cen_div16;
    logic cen_3m, cen_1m5;

    always_ff @(posedge clk) begin
        if (reset) begin
            cen_div8  <= 3'd0;
            cen_div16 <= 4'd0;
        end else begin
            cen_div8  <= cen_div8  + 3'd1;
            cen_div16 <= cen_div16 + 4'd1;
        end
    end
    assign cen_3m  = (cen_div8  == 3'd0);
    assign cen_1m5 = (cen_div16 == 4'd0);

    // ------------------------------------------------------------------
    // Profile grouping and register-window decode. Kept as plain address
    // comparisons (not bit-slicing tricks) so the mapping is directly
    // readable against the suna8.cpp address maps quoted above.
    // ------------------------------------------------------------------
    logic is_hardhead_group;   // HARDHEAD, SPARKMAN, STARFIGH
    logic is_brickzn_group;    // HARDHEA2, BRICKZN (share brickzn_sound_map)
    logic is_sranger;

    assign is_hardhead_group = (profile_id == PROFILE_HARDHEAD) ||
                                (profile_id == PROFILE_SPARKMAN) ||
                                (profile_id == PROFILE_STARFIGH);
    assign is_brickzn_group  = (profile_id == PROFILE_HARDHEA2) ||
                                (profile_id == PROFILE_BRICKZN);
    assign is_sranger        = (profile_id == PROFILE_SRANGER);

    logic ymsnd_sel, aysnd_addr_sel, aysnd_data_sel;
    logic ym1_sel, ym2_sel;

    always_comb begin
        ymsnd_sel      = 1'b0;
        aysnd_addr_sel = 1'b0;
        aysnd_data_sel = 1'b0;
        ym1_sel        = 1'b0;
        ym2_sel        = 1'b0;
        if (is_hardhead_group) begin
            ymsnd_sel      = (cpu_addr == 16'ha000) || (cpu_addr == 16'ha001);
            aysnd_addr_sel = (cpu_addr == 16'ha002);
            aysnd_data_sel = (cpu_addr == 16'ha003);
        end else if (is_brickzn_group) begin
            ymsnd_sel      = (cpu_addr == 16'hc000) || (cpu_addr == 16'hc001);
            aysnd_addr_sel = (cpu_addr == 16'hc002);
            aysnd_data_sel = (cpu_addr == 16'hc003);
        end else if (is_sranger) begin
            ym1_sel = (cpu_addr == 16'ha000) || (cpu_addr == 16'ha001);
            ym2_sel = (cpu_addr == 16'ha002) || (cpu_addr == 16'ha003);
        end
    end

    // ------------------------------------------------------------------
    // ymsnd: YM3812 (jtopl2). addr is the raw bit0 (register-select vs
    // data-write) -- matches MAME's ym3812_device::write(offset,data)
    // taking the offset directly, no separate address-latch step needed
    // (unlike the AY8910 below).
    // ------------------------------------------------------------------
    logic signed [15:0] ymsnd_snd;

    // CPU writes reach jtopl2 through suna8_fm_write_queue: Spark Man and
    // Star Fighter write faster than jtopl applies a register update, and
    // every write inside that window dropped the previous one (see the
    // queue's header for the MAME/bench evidence). cpu_write is level-true
    // for a whole bus cycle, so the queue takes one entry per rising edge.
    logic ymsnd_cpu_wr, ymsnd_cpu_wr_d;
    logic ymq_cs_n, ymq_wr_n, ymq_a0;
    logic [7:0] ymq_din;
    assign ymsnd_cpu_wr = cpu_write && ymsnd_sel;
    always_ff @(posedge clk) ymsnd_cpu_wr_d <= reset ? 1'b0 : ymsnd_cpu_wr;

    suna8_fm_write_queue u_ymsnd_queue (
        .clk       (clk),
        .reset     (reset),
        .wr_stb    (ymsnd_cpu_wr && !ymsnd_cpu_wr_d),
        .wr_a0     (cpu_addr[0]),
        .wr_data   (cpu_dout),
        .chip_cs_n (ymq_cs_n),
        .chip_wr_n (ymq_wr_n),
        .chip_a0   (ymq_a0),
        .chip_din  (ymq_din),
        .overflow  ()           // sticky; the headless harness checks it
    );

    jtopl2 u_ymsnd (
        .rst    (reset),
        .clk    (clk),
        .cen    (cen_3m),
        .din    (ymq_din),
        .addr   (ymq_a0),
        .cs_n   (ymq_cs_n),
        .wr_n   (ymq_wr_n),
        .dout   (ym3812_dout),
        .irq_n  (ym3812_irq_n),
        .snd    (ymsnd_snd),
        .sample ()
    );

    // ------------------------------------------------------------------
    // aysnd: AY8910 (jt49). MAME's address_data_w is a two-step protocol
    // (offset 0 latches the register address, offset 1 writes data to
    // it); jt49 wants the 4-bit register address directly every write,
    // so the address latch is reproduced here.
    // ------------------------------------------------------------------
    logic [3:0] aysnd_addr_latch;
    logic [9:0] aysnd_sound;

    always_ff @(posedge clk) begin
        if (reset)
            aysnd_addr_latch <= 4'd0;
        else if (cpu_write && aysnd_addr_sel)
            aysnd_addr_latch <= cpu_dout[3:0];
    end

    jt49 u_aysnd (
        .rst_n   (!reset),
        .clk     (clk),
        .clk_en  (cen_1m5),
        .addr    (aysnd_addr_latch),
        .cs_n    (!aysnd_data_sel),
        .wr_n    (!cpu_write),
        .din     (cpu_dout),
        .sel     (1'b1),        // standard AY8910 rate, no extra /2
        .dout    (),            // never read by the CPU on any profile
        .sound   (aysnd_sound),
        .A       (), .B (), .C (),
        .sample  (),
        .IOA_in  (8'd0), .IOA_out (), .IOA_oe (),
        .IOB_in  (8'd0), .IOB_out (), .IOB_oe ()
    );

    // jt49's "sound" is unsigned (10-bit, centered mid-scale) -- a static
    // level shift around its midpoint is enough to make it a proper
    // AC-coupled signed value before mixing with ymsnd's already-signed
    // output; the JT49 package's own optional DC-servo filter
    // (jt49/filter/jt49_dcrm*.v) is not vendored into this project's
    // source list and isn't needed for correctness here, just for a
    // slightly more authentic DC-blocking response.
    // ZERO-extend: jt49's `sound` is `reg [9:0] acc`, an unsigned 0..1023
    // accumulator, so bit 9 is a magnitude bit, not a sign bit. Sign-
    // extending it (the previous form, {{6{sound[9]}}, sound}) turned every
    // sample in the upper half of the range into a large negative number:
    // 1023 became -1 instead of +511, folding the waveform about its
    // midpoint on every profile that uses the AY -- audibly garbled music
    // and effects on Hard Head, Spark Man, Star Fighter, Brick Zone and
    // Hard Head 2. Subtracting the 512 midpoint after zero-extension is
    // what makes the unsigned code an AC-coupled signed sample.
    //
    // Scale, too: jt49's 10-bit sum (three 8-bit linearised channels, so at
    // most 765) is a chip-native range, not a 16-bit sample. jtopl2 and jt03
    // deliver 16-bit samples, and jt12_top itself mixes its internal PSG into
    // its FM shifted left five bits (x32) for this reason; without it every AY
    // effect sat about 30 dB under the FM music (R080). Here the stem is kept
    // at that native x32 scale (0..24480, unipolar like the chip: a silent AY
    // adds no DC), and the mixer below applies twice MAME's route gain.
    // MAME's AY8910 defaults to AY8910_LEGACY_OUTPUT, whose normalised table
    // gives each channel a 0.5 full-scale swing (-0.125..+0.375); one jt49
    // channel at x32 swings 255*32 = 8160, a quarter of full scale. Measured
    // against MAME per-source stems the AY sat 4-9 dB low in every game.
    logic signed [15:0] aysnd_snd;
    assign aysnd_snd = signed'({1'b0, aysnd_sound, 5'd0});

    // ------------------------------------------------------------------
    // ym1/ym2: dual YM2203 (jt03), sranger only. Each is a fully
    // independent chip instance (not a shared bus), matching MAME's two
    // separate ym2203_device instances.
    // ------------------------------------------------------------------
    logic signed [15:0] ym1_snd, ym2_snd;   // jt03's own FM+PSG sum (stems only)
    // The mixer takes FM and SSG separately, each rescaled to MAME's YM2203
    // level. FM: ymfm's YM2203 outputs the full 14-bit operator sum with no
    // shift (ymfm_opn.cpp ym2203::clock_fm, "OPN is full 14-bit"), while
    // jt03_acc accumulates into 18 bits and keeps [17:2] -- exactly a quarter.
    // Replaying MAME's Super Ranger ym1 register stream into jt03 alone gave
    // FM 12.1 dB under MAME's FM-only stem with an envelope correlation of
    // 1.00, i.e. the same music at one quarter level. SSG: ymfm's per-channel
    // amplitude table peaks at 16382 (0.5 full scale), jt49's linearised
    // channel at 255, which jt12_top mixes at x32 (0.25 full scale), so x64
    // would match MAME at full volume. But jt12_top builds its jt49 with
    // COMP=2'b01, a compressed (load-modelled) curve that sits 2-4 dB above
    // ymfm's table at the volumes Super Ranger uses (11-13; 7 dB at vol 7),
    // and the replay measured ym2's SSG ~4 dB and ym1's ~0-2 dB over MAME at
    // x64. x48 puts both within about +-2 dB of MAME without editing the
    // vendored curve (whose load model may be closer to the real board).
    logic signed [15:0] ym1_fm, ym2_fm;
    logic [9:0] ym1_psg, ym2_psg;
    logic [7:0] ym1_dout_unused, ym2_dout_unused;
    logic ym1_irq_n_unused, ym2_irq_n_unused;

    jt03 u_ym1 (
        .rst          (reset),
        .clk          (clk),
        .cen          (cen_1m5),
        .din          (cpu_dout),
        .addr         (cpu_addr[0]),
        .cs_n         (!ym1_sel),
        .wr_n         (!cpu_write),
        .dout         (ym1_dout_unused),
        .irq_n        (ym1_irq_n_unused),
        .IOA_in       (8'd0),
        .IOB_in       (8'd0),
        .psg_A        (), .psg_B (), .psg_C (),
        .fm_snd       (ym1_fm),
        .psg_snd      (ym1_psg),
        .snd          (ym1_snd),
        .snd_sample   (),
        .debug_view   ()
    );

    jt03 u_ym2 (
        .rst          (reset),
        .clk          (clk),
        .cen          (cen_1m5),
        .din          (cpu_dout),
        .addr         (cpu_addr[0]),
        .cs_n         (!ym2_sel),
        .wr_n         (!cpu_write),
        .dout         (ym2_dout_unused),
        .irq_n        (ym2_irq_n_unused),
        .IOA_in       (8'd0),
        .IOB_in       (8'd0),
        .psg_A        (), .psg_B (), .psg_C (),
        .fm_snd       (ym2_fm),
        .psg_snd      (ym2_psg),
        .snd          (ym2_snd),
        .snd_sample   (),
        .debug_view   ()
    );

    // ------------------------------------------------------------------
    // SAMPLES device (suna8_a.cpp): raw 4-bit unsigned PCM, mono, 8kHz
    // voice clips, triggered via AY8910/YM2203 port A/B writes.
    // samples_number_w (port B) just latches the sample index;
    // play_samples_w/rranger_play_samples_w (port A) fire only on an
    // exact two-write handshake (tracking the PREVIOUS port A value, not
    // triggering on every write) -- reproduced faithfully below, not
    // approximated as "any write with this value".
    //
    // Port A/B write events are detected by independently snooping the
    // same register-select-then-data-write bus sequence the chips
    // themselves decode (reusing aysnd_addr_latch for the AY8910 route;
    // a new, equivalent ym1_addr_latch for the YM2203 route, since jt03's
    // vendored core is I/O-input-only and can't be snooped via its own
    // IOA_out/IOB_out the way jt49 could -- see this file's header
    // comment). This gives one uniform mechanism for both chip families
    // instead of two different ones.
    // ------------------------------------------------------------------
    logic aysnd_porta_wr, aysnd_portb_wr;
    assign aysnd_porta_wr = cpu_write && aysnd_data_sel && (aysnd_addr_latch == 4'd14);
    assign aysnd_portb_wr = cpu_write && aysnd_data_sel && (aysnd_addr_latch == 4'd15);

    logic [7:0] ym1_addr_latch;
    always_ff @(posedge clk) begin
        if (reset)
            ym1_addr_latch <= 8'd0;
        else if (cpu_write && ym1_sel && !cpu_addr[0])
            ym1_addr_latch <= cpu_dout;
    end
    logic ym1_porta_wr, ym1_portb_wr;
    assign ym1_porta_wr = cpu_write && ym1_sel && cpu_addr[0] && (ym1_addr_latch == 8'h0e);
    assign ym1_portb_wr = cpu_write && ym1_sel && cpu_addr[0] && (ym1_addr_latch == 8'h0f);

    // Exactly one of {aysnd, ym1} is ever active for a given profile
    // (same reasoning as the mixer below), so a plain OR safely combines
    // both routes into one samples engine instance.
    logic samples_porta_wr, samples_portb_wr;
    assign samples_porta_wr = aysnd_porta_wr || ym1_porta_wr;
    assign samples_portb_wr = aysnd_portb_wr || ym1_portb_wr;

    logic [7:0] sample_number;
    always_ff @(posedge clk) begin
        if (reset)
            sample_number <= 8'd0;
        else if (samples_portb_wr)
            sample_number <= cpu_dout;
    end

    // suna8_a.cpp: "m_play == 0xe9 && data == 0xf9" (play_samples_w,
    // first sample rom, hardhead/sparkman/starfigh) / "m_play == 0xb9 &&
    // data == 0xf9" (play_samples_w, second sample rom, same three
    // profiles) / "m_play == 0x60 && data == 0x70"
    // (rranger_play_samples_w, sranger, first sample rom only -- no
    // second-rom path exists for sranger in suna8.cpp).
    logic [7:0] play_prev;
    always_ff @(posedge clk) begin
        if (reset)
            play_prev <= 8'd0;
        else if (samples_porta_wr)
            play_prev <= cpu_dout;
    end
    logic play_trigger_first, play_trigger_second, play_start;
    logic [4:0] play_index;
    assign play_trigger_first  = samples_porta_wr &&
        ((is_sranger && (play_prev == 8'h60) && (cpu_dout == 8'h70)) ||
         (is_hardhead_group && (play_prev == 8'he9) && (cpu_dout == 8'hf9)));
    assign play_trigger_second = samples_porta_wr && is_hardhead_group &&
        (play_prev == 8'hb9) && (cpu_dout == 8'hf9);
    assign play_start = play_trigger_first || play_trigger_second;
    // "m_sample & 0x0f" (first rom) / "((m_sample >> 4) & 0x0f) + 0x10"
    // (second rom, i.e. bit4 set + the high nibble -- equivalent to the
    // concatenation below).
    assign play_index = play_trigger_second ? {1'b1, sample_number[7:4]}
                                             : {1'b0, sample_number[3:0]};

    // Playback engine. 8kHz sample rate against the raw 24MHz system
    // clock (ce_pix = clk/4 = 6MHz pixel clock, confirmed in
    // suna8_raster.sv, same 24MHz derivation used for SOUND_IRQ_PERIOD in
    // suna8_core.sv): 24,000,000 / 8,000 = 3,000 raw-clk cycles/sample.
    // SAMPLEN=4096 nibbles (suna8_a.cpp), 2 nibbles/rom-byte, so each of
    // the up to 32 slots occupies 2048 (0x800) consecutive rom bytes in
    // the 64KB MEDIA_SAMPLES window. sound_start()'s conversion for
    // nibble i: even i -> low nibble of rom-byte i/2, odd i -> high
    // nibble, each XORed on its own MSB (offset-binary/excess-8 ->
    // two's-complement) then placed as the top 4 bits of a 16-bit signed
    // sample ("(int8_t)(...)*0x100" in the original -- equivalent to
    // {signed_nibble, 12'b0} here).
    localparam int SAMPLE_TICK_PERIOD = 3_000;
    logic [11:0] sample_tick_counter;
    logic sample_tick;
    always_ff @(posedge clk) begin
        if (reset || sample_tick_counter >= SAMPLE_TICK_PERIOD[11:0] - 12'd1)
            sample_tick_counter <= 12'd0;
        else
            sample_tick_counter <= sample_tick_counter + 12'd1;
    end
    assign sample_tick = (sample_tick_counter == SAMPLE_TICK_PERIOD[11:0] - 12'd1);

    logic playing;
    logic [4:0] play_base;
    logic [11:0] nibble_pos;      // 0..4095 within the current slot
    logic [3:0] cur_nibble;
    logic signed [15:0] samples_snd;

    assign sample_media_read_addr = {play_base, nibble_pos[11:1]};
    assign cur_nibble = nibble_pos[0] ? sample_media_read_q[7:4] : sample_media_read_q[3:0];

    always_ff @(posedge clk) begin
        if (reset) begin
            playing     <= 1'b0;
            play_base   <= 5'd0;
            nibble_pos  <= 12'd0;
            samples_snd <= 16'sd0;
        end else begin
            if (play_start) begin
                // A new trigger always (re)starts playback immediately,
                // matching MAME's samples_device::start_raw always
                // replacing channel 0's current playback outright.
                playing    <= 1'b1;
                play_base  <= play_index;
                nibble_pos <= 12'd0;
            end else if (playing && sample_tick) begin
                if (nibble_pos == 12'd4095)
                    playing <= 1'b0;
                else
                    nibble_pos <= nibble_pos + 12'd1;
            end

            // Hold the last sample while the fetch is outstanding rather
            // than forcing silence. sample_media_read_ready is always high
            // in the zero-latency stub memory, but on real SDRAM it drops
            // for the duration of every cache fill -- once per rom byte,
            // i.e. every other 8 kHz tick. Slamming the output to zero
            // there punched a hole into every played clip at up to 4 kHz,
            // which is heard as a buzzing, broken voice rather than a
            // missing one. Only a finished playback returns to silence.
            if (!playing)
                samples_snd <= 16'sd0;
            else if (sample_media_read_ready)
                samples_snd <= {cur_nibble ^ 4'b1000, 12'd0};
        end
    end

    // Linear interpolation between the last two samples. Holding each 4-bit
    // step for a whole 8 kHz period (the raw samples_snd above) images the
    // clip around every multiple of 8 kHz; against MAME's per-source stems
    // the voice clips carried 9-14 dB more 4-12 kHz energy than MAME's, which
    // plays the 8 kHz stream through its interpolating resampler. That excess
    // is the harsh, distorted edge on the voice and hit samples. The output
    // runs one sample period (125 us) behind the raw value, so a fetch that
    // is still outstanding at a tick never reaches the interpolator.
    logic signed [15:0] smp_prev, smp_cur, samples_out;
    logic [21:0] smp_phase;       // 0..4095 in [21:10] across one period
    logic signed [16:0] smp_delta;
    logic signed [29:0] smp_prod;
    assign smp_delta = 17'(smp_cur) - 17'(smp_prev);
    assign smp_prod  = smp_delta * $signed({1'b0, smp_phase[21:10]});
    always_ff @(posedge clk) begin
        if (reset) begin
            smp_prev    <= 16'sd0;
            smp_cur     <= 16'sd0;
            smp_phase   <= 22'd0;
            samples_out <= 16'sd0;
        end else begin
            if (sample_tick) begin
                smp_prev  <= smp_cur;
                smp_cur   <= samples_snd;
                smp_phase <= 22'd0;
            end else begin
                // 1398/1024 per clock: 2999 clocks reach 4094.
                smp_phase <= smp_phase + 22'd1398;
            end
            samples_out <= 16'(17'(smp_prev) + 17'(smp_prod >>> 12));
        end
    end

    // ------------------------------------------------------------------
    // Mix. Exactly one of {ymsnd+aysnd, ym1+ym2} is ever active for a
    // given profile -- the address decode above gates chip writes so an
    // inactive profile's chips never receive a register write and stay
    // silent at their post-reset state -- so an unconditional sum is
    // safe and correct; no profile-based output mux is needed. Summed in
    // a wider accumulator and saturated rather than truncated, so a loud
    // combined signal clips cleanly instead of wrapping into harsh
    // digital distortion.
    // ------------------------------------------------------------------
    // 20 bits: 6 signed 16-bit terms' theoretical worst-case magnitude is
    // 6*32768=196608, needing headroom past 18 bits (max magnitude
    // 131072) to avoid the wide accumulator itself wrapping before the
    // saturate compare below ever runs. In practice at most 2-3 of these
    // six are ever simultaneously nonzero for a given profile (exactly
    // one of the {ymsnd+aysnd+samples}/{ym1+ym2}/{ymsnd+pcm} groups is
    // ever selected -- see the address decode above and pcm_cpu_reset in
    // suna8_core.sv), but the accumulator is sized for the full
    // architectural worst case regardless, not the runtime invariant.
    logic signed [19:0] mix_wide;
    logic signed [15:0] mix_sat;

    // The PCB routes each source through a different passive gain.  The
    // previous equal-weight sum made a digital-level approximation that was
    // audibly wrong (especially AY/DAC-heavy Brick Zone scenes).  These
    // shift/add forms are fixed-point approximations of the documented MAME
    // board routes while keeping the result synthesizable without a wide
    // per-sample multiplier:
    //   AY hardhead/sparkman .30, starfigh .50, Brick Zone .33, YM2203 .90,
    //   samples .50, Brick Zone four-DAC bus .17.
    // The AY terms use twice those routes because the AY stem is at half
    // MAME's per-channel swing (see aysnd_snd above).
    logic signed [19:0] ymsnd_ext, aysnd_ext, ym1_ext, ym2_ext;
    logic signed [19:0] samples_ext, pcm_ext;

    function automatic logic signed [19:0] sx16(input logic signed [15:0] s);
        sx16 = {{4{s[15]}}, s};
    endfunction
    function automatic logic signed [19:0] gain_09(input logic signed [19:0] s);
        gain_09 = s - (s >>> 4) + (s >>> 6) - (s >>> 8);
    endfunction
    function automatic logic signed [19:0] gain_06(input logic signed [19:0] s);
        gain_06 = (s >>> 1) + (s >>> 4) + (s >>> 5) + (s >>> 7);
    endfunction
    function automatic logic signed [19:0] gain_066(input logic signed [19:0] s);
        gain_066 = s - (s >>> 2) - (s >>> 4) - (s >>> 6);
    endfunction
    function automatic logic signed [19:0] gain_017(input logic signed [19:0] s);
        gain_017 = (s >>> 3) + (s >>> 5) + (s >>> 7);
    endfunction

    always_comb begin
        ymsnd_ext  = sx16(ymsnd_snd);
        aysnd_ext  = sx16(aysnd_snd);
        ym1_ext    = (sx16(ym1_fm) <<< 2) + 20'({ym1_psg, 5'd0}) + 20'({ym1_psg, 4'd0});
        ym2_ext    = (sx16(ym2_fm) <<< 2) + 20'({ym2_psg, 5'd0}) + 20'({ym2_psg, 4'd0});
        samples_ext = sx16(samples_out);
        pcm_ext     = sx16(pcm_snd);
        case (profile_id)
            PROFILE_SRANGER:
                mix_wide = gain_09(ym1_ext) + gain_09(ym2_ext) +
                           (samples_ext >>> 1);
            PROFILE_BRICKZN, PROFILE_HARDHEA2:
                mix_wide = ymsnd_ext + gain_066(aysnd_ext) +
                           gain_017(pcm_ext);
            PROFILE_STARFIGH:
                mix_wide = ymsnd_ext + aysnd_ext +
                           (samples_ext >>> 1);
            default:
                mix_wide = ymsnd_ext + gain_06(aysnd_ext) +
                           (samples_ext >>> 1);
        endcase
    end

    always_comb begin
        if (mix_wide > 20'sd32767)
            mix_sat = 16'sd32767;
        else if (mix_wide < -20'sd32768)
            mix_sat = 16'sh8000;  // -32768; the decimal literal doesn't fit
                                  // a signed 16-bit constant (max positive is
                                  // 32767) and triggers Quartus's "constant
                                  // value overflow" -- the bit pattern is
                                  // unambiguous and needs no sign extension.
        else
            mix_sat = mix_wide[15:0];
    end

    assign audio_l = mix_sat;
    assign audio_r = mix_sat;

endmodule
