// Gaiapolis adapter. Source provenance: rtl/vendor/violent_storm_k054539/source.json
// Omitted three donor ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW annotations on sample_rom_addr, rb_active and rb_addr_l: they preserve Violent Storm's 48->96 MHz ROM boundary. No matching Gaiapolis timing endpoints or edge proof was supplied; this import adds no timing exception.
/* Konami K054539 native PCM datapath for Violent Storm.
 * Physical sources: furrtek/SiliconRE, pinned in doc/gaiapolis_pause_pcm-accuracy.md.
 * Native formats/phase, frame-queued keys, four scheduled filter taps and
 * dumped ROM gain are implemented with fixed-width chip arithmetic.
 * CPU readback and ROM wait adapters serve the existing shared SDRAM bus.
 * Two-loop effects use independent volume sends, feedback and free-running
 * LFOs. The unresolved public pointer chronology is isolated in effects.v.
 */
module gaiapolis_pause_pcm #(parameter VOLSHIFT=0, parameter AX_INPUT_ENABLE=0, parameter BOOST_MASK=8'h00) (
    input               rst,
    input               clk,
    input freeze,
input quiesce,
output pause_idle,
    input               cen,     // Native 18.432 MHz; 384 enables per 48 kHz sample
    output              timeout,

    // CPU interface (addr = {A[9],A[7:0]}, 9 bits; A[8] se pierde en el bus)
    input      [ 8:0]   addr,
    input               we,
    input               rd,
    input               cs,
    input      [ 7:0]   din,
    output     [ 7:0]   dout,

    // ROM (PCM samples) en SDRAM COMPARTIDO -> HAY que esperar rom_ok (el dato NO es de latencia cero:
    // bajo contencion video+cpu+sonido llega tarde -> leer sin esperar = falso terminador = sonido que falta).
    output              rom_cs,
    output     [23:0]   rom_addr,
    // K054539 data-port ROM readback uses the same SDRAM byte stream as
    // playback.  These status outputs let the Z80 wait wrapper hold the
    // register read until the shared ROM response has arrived.
    output              rb_wait,
    input      [ 7:0]   rom_data,
    input               rom_ok,

    // Sound output (PCM PURO — la FM va por su propio canal en el rcmix de jtframe)
    output signed [15:0] left,
    output signed [15:0] right,
    output signed [15:0] wet_left,
    output signed [15:0] wet_right,
    output              sample_valid,
    output reg [15:0]    sample_epoch,
    output              output_enabled,
    // Optional parallel words from the physical AXDT input stream. Boards
    // without a wired source retain zero through AX_INPUT_ENABLE=0.
    input signed [15:0] axword_a,
    input signed [15:0] axword_b,

    input      [ 7:0]   debug_bus,
    output     [ 7:0]   st_dout
);

// ---------------------------------------------------------------------------
// Register file (direccionado por la addr de MODULO {A9,A7:0}).
// Mapeo offsets MAME -> modulo: canales 0x0xx igual; control 0x2xx -> 0x1xx
//   active=0x22c->0x12c  ctrl=0x22f->0x12f  keyon=0x214->0x114  keyoff=0x215->0x115
//   canal ch base1=0x20*ch (igual)   base2=0x200+2*ch -> 0x100+2*ch
// CPU y el secuenciador comparten este único proceso de escritura de regs[].
// keyon/keyoff/terminador tocan `active` en el mismo proceso para evitar
// múltiples drivers al inferir el bloque de registros en Quartus.
// ---------------------------------------------------------------------------
// Z80 decode stops at 0x22f (A[9:0] <= 0x22f), so module addresses 0x130-0x1ff
// can never be selected. Internal filter/raw words stop at 0x0ff and
// channel controls at 0x10f. Bound the unreachable storage explicitly;
// Quartus retained the upper208 bytes with the original indirect writes.
localparam [8:0] REG_TOP = 9'h12f;
reg  [7:0] regs [0:REG_TOP];
// The physical K054539 captures CPU writes when the active-low write strobe
// is released.  The Z80 can hold one bus transaction across several 48 MHz
// clocks, so retain its stable bus value and emit exactly one release commit.
reg        cpu_write_pending;
reg [8:0]  cpu_write_addr;
reg [7:0]  cpu_write_data;
wire       cpu_write_active = cs && we;
wire       cpu_write_commit = cpu_write_pending && !cpu_write_active;
integer    gi;
initial for (gi=0; gi<=REG_TOP; gi=gi+1) regs[gi] = 8'd0;

wire reg_updates     = ~regs[9'h12f][7];
wire [7:0] keyon_retrigger = (cpu_write_commit &&
                              (cpu_write_addr == 9'h114)) ?
                              cpu_write_data : 8'h00;

assign dout    = (addr == 9'h12c) ? active :
                 (addr == 9'h12d) ? ((rd && regs[9'h12f][4]) ?
                                      (regs[9'h12e][7] ? rr_cpu_data : rb_data) : 8'h00) :
                 (addr > REG_TOP) ? 8'h00 : regs[addr];
// The native /128 divider clocks an 8-bit reload counter independently of
// sample-memory waits. REG227 changes its reload, not the running phase.
assign timeout = timer_state;
assign st_dout = 8'd0;
// ROM requests must drain before the complete native chip state can freeze.
assign pause_idle = state == S_IDLE && !sample_rom_cs && !rb_pending &&
                    !rb_active && !cpu_write_pending && !(cs && (we || rd));

// ---------------------------------------------------------------------------
// Estado por canal (autoritativo; en unidades de BYTE entre samples)
// ---------------------------------------------------------------------------
reg [23:0] cpos   [0:7];
reg [15:0] cpfrac [0:7];
reg [39:0] cphase [0:7];
reg signed [15:0] cval  [0:7];
wire signed [15:0] cpval_read;

wire [7:0] active, restart, loop_pending, pending_keyon;
wire [7:0] saved_valid, eof_history;

// ---------------------------------------------------------------------------
// Secuenciador
// ---------------------------------------------------------------------------
localparam [3:0]
    S_IDLE = 4'd0, S_LOAD = 4'd1, S_GAINV = 4'd2,
    S_R8   = 4'd3, S_R16L = 4'd4, S_R16H = 4'd5, S_RD = 4'd6,
    S_MIX  = 4'd7, S_NEXT = 4'd8, S_DONE = 4'd9,
    S_WAIT = 4'd10,
    S_GAING= 4'd12, S_GAINP= 4'd13, S_RODD=4'd14, S_FILTER=4'd15;

reg [3:0]  state;
reg [8:0]  sample_cnt;
reg [15:0] free_frame_epoch;
reg [2:0]  ch;
localparam [2:0] G_IDLE=3'd0, G_VOLUME=3'd1, G_GLOBAL=3'd2,
                 G_PAN=3'd3, G_MIX=3'd4;
reg [2:0] gain_state, gain_ch;
reg [3:0] gain_source;
// Gain results wait here for the bank controller. The array has one write port
// and one read port, so it lives in LAB RAM; mix_written makes a source that
// has not been written since reset read as zero, like the cleared registers.
(* ramstyle = "MLAB, no_rw_check" *) reg [95:0] mix_contributions [0:15];
reg [11:0] mix_written;
reg [11:0] mix_ready;
reg [1:0] loop_gain_pending, external_gain_pending;
reg effects_gain_seen;
reg signed [15:0] external_sample_a, external_sample_b;
reg frame_gain_done;
wire [31:0] voice_cache_read;
reg [7:0] gain_volume_register, gain_pan_register, gain_control_register;
reg [7:0] gain_effect_volume_register;

// ---------------------------------------------------------------------------
// Native timer, recovered from the counter wiring rather than MAME's rate.
// ---------------------------------------------------------------------------
wire [7:0] timer_cnt;
wire       timer_state;
gaiapolis_k054539_timer u_timer(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen), .master_phase(sample_cnt),
    .enable(regs[9'h12f][5]), .load_value(regs[9'h127]),
    .timeout(timer_state), .count(timer_cnt)
);

// registros de trabajo del canal en curso
reg [24:0] w_pos;              // 25b: DPCM trabaja en unidades de NIBBLE (pos<<1)
reg signed [15:0] w_val, w_pval, w_filtered;
reg [23:0] w_loop;
reg [23:0] w_base;
reg [39:0] w_phase, w_next_phase;
reg        w_dpcm_update;
reg        w_loop_restart;
reg [7:0]  w_lo;              // byte bajo del sample 16-bit
reg [7:0]  w_vol;
reg [3:0]  w_pan;
reg [7:0]  w_pan_raw, w_control;
reg [1:0]  w_type;           // 0=8bit, 1=16bit(0x4), 2=DPCM(0x8)
reg [2:0]  w_dtype;
reg        w_loopen;
reg        w_reverse;

// Playback ROM request registers.  The external port is arbitrated with the
// diagnostic/readback request below; only one request is presented at once.
reg         sample_rom_cs;
// These registers and the rb_active select feed the 48 MHz -> 96 MHz ROM request
// crossing directly. Physical synthesis retimed the select mux past them, leaving a
// bare register-to-register hop that missed hold by up to 0.44 ns; keep the registers
// and the mux in front of the crossing (ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW).
reg [23:0] sample_rom_addr;

reg rb_active;
reg         rb_pending, rb_read_seen, rb_data_valid;
reg         rr_cpu_read_seen, rr_cpu_data_valid;
reg         data_access_seen;
reg [23:0] rb_addr_l;
reg  [14:0] rr_cpu_addr_l;
reg   [7:0] rb_data, rr_cpu_data;
wire        rb_rom_bank = !regs[9'h12e][7];
wire        data_access = cs && (rd || we) && (addr == 9'h12d);
wire        rb_cpu_read = cs && rd && (addr == 9'h12d) && regs[9'h12f][4] && rb_rom_bank;
wire        rr_cpu_read = cs && rd && (addr == 9'h12d) &&
                          regs[9'h12e][7] && regs[9'h12f][4];

assign rom_cs   = sample_rom_cs | rb_active;
assign rom_addr = rb_active ? rb_addr_l : sample_rom_addr;
assign rb_wait  = rb_pending | rb_active |
                  (rb_cpu_read && !rb_data_valid) |
                  (rr_cpu_read && !rr_cpu_data_valid);

// Native dry contributions and mixer arithmetic are fixed-width integers.
wire signed [15:0] fx_send_e, fx_send_f;

// Complete 32 KiB effects RAM retains the CPU data-port contract. The old
// mono MAME delay is removed: bytes 06/07 belong to the voice filter.
reg  [16:0] read_ptr;             // K054539 0x22d pointer, wraps at 0x1ffff
wire [14:0] rr_port_addr = {read_ptr[16], read_ptr[13:0]};
wire [14:0] effects_ram_addr;
wire [7:0] effects_ram_din, effects_ram_dout;
wire effects_ram_we;
wire [1:0] effects_ram_byte_we = effects_ram_we ?
    (effects_ram_addr[0] ? 2'b10 : 2'b01) : 2'b00;
wire [15:0] effects_ram_word_din = effects_ram_addr[0] ?
    {effects_ram_din,8'd0} : {8'd0,effects_ram_din};

// The reverb store has two independent 0x4000-byte banks.  Keep the CPU
// data port on RAM port 0 and the audio read/modify/write path on port 1 so
// Quartus can infer two dual-port M10K memories instead of expanding the
// 262,144 bits into registers.  The CPU read is deliberately registered and
// participates in rb_wait below, matching the existing wait-state contract
// used by the serial ROM data port.
wire        rr_cpu_write = cpu_write_commit && (cpu_write_addr == 9'h12d) &&
                            regs[9'h12e][7];
wire [1:0]  rr_cpu_we = rr_cpu_write ?
                        (rr_port_addr[0] ? 2'b10 : 2'b01) : 2'b00;
wire [15:0] rr_cpu_din = rr_port_addr[0] ? {cpu_write_data,8'h00} :
                                                   {8'h00,cpu_write_data};
wire [15:0] rr_lo_cpu_q, rr_hi_cpu_q, rr_audio_q, rr_hi_audio_q;
wire [12:0] rr_cpu_word_addr = rr_cpu_read_seen ? rr_cpu_addr_l[13:1] :
                                                   rr_port_addr[13:1];
wire [15:0] rr_cpu_q = rr_cpu_addr_l[14] ? rr_hi_cpu_q : rr_lo_cpu_q;
wire [15:0] effects_ram_word_dout = effects_ram_addr[14] ? rr_hi_audio_q : rr_audio_q;
assign effects_ram_dout = effects_ram_addr[0] ? effects_ram_word_dout[15:8] : effects_ram_word_dout[7:0];

gaiapolis_k054539_ram16 #(
    .AW          ( 13 ),
    .SIMHEXFILE_LO( "rtl/vendor/violent_storm_k054539/rram_zero.hex" ),
    .SIMHEXFILE_HI( "rtl/vendor/violent_storm_k054539/rram_zero.hex" ),
    .SYNFILE_LO  ( "rtl/vendor/violent_storm_k054539/rram_zero.hex" ),
    .SYNFILE_HI  ( "rtl/vendor/violent_storm_k054539/rram_zero.hex" )
) u_rram_lo (.freeze(freeze),
    .clk0  ( clk           ),
    .data0 ( rr_cpu_din    ),
    .addr0 ( rr_cpu_word_addr ),
    .we0   ( !freeze ? (rr_port_addr[14] ? 2'b00 : rr_cpu_we) : 2'b00),
    .q0    ( rr_lo_cpu_q   ),
    .clk1  ( clk           ),
    .data1 ( effects_ram_word_din ),
    .addr1 ( effects_ram_addr[13:1] ),
    .we1   ( !freeze ? (effects_ram_addr[14] ? 2'b00 : effects_ram_byte_we) : 2'b00),
    .q1    ( rr_audio_q    )
);

gaiapolis_k054539_ram16 #(
    .AW          ( 13 ),
    .SIMHEXFILE_LO( "rtl/vendor/violent_storm_k054539/rram_zero.hex" ),
    .SIMHEXFILE_HI( "rtl/vendor/violent_storm_k054539/rram_zero.hex" ),
    .SYNFILE_LO  ( "rtl/vendor/violent_storm_k054539/rram_zero.hex" ),
    .SYNFILE_HI  ( "rtl/vendor/violent_storm_k054539/rram_zero.hex" )
) u_rram_hi (.freeze(freeze),
    .clk0  ( clk           ),
    .data0 ( rr_cpu_din    ),
    .addr0 ( rr_cpu_word_addr ),
    .we0   ( !freeze ? (rr_port_addr[14] ? rr_cpu_we : 2'b00) : 2'b00),
    .q0    ( rr_hi_cpu_q   ),
    .clk1  ( clk           ),
    .data1 ( effects_ram_word_din ),
    .addr1 ( effects_ram_addr[13:1] ),
    .we1   ( !freeze ? (effects_ram_addr[14] ? effects_ram_byte_we : 2'b00) : 2'b00),
    .q1    ( rr_hi_audio_q  )
);

wire [15:0] rram_port_word = rr_cpu_q;
wire [7:0] rram_port_dout = rr_cpu_addr_l[0] ?
                              rram_port_word[15:8] :
                              rram_port_word[7:0];

// The common gain sequencer serves eight voices, two RAM-loop words and
// two optional AXDT input words. Its presets retain the unhalved low-pan
// products used by the high-pan stage; RVVOL independently starts at volume.
wire signed [15:0] volume_coefficient, global_coefficient;
wire signed [15:0] main_left_coefficient, main_right_coefficient;
wire signed [15:0] effect_left_coefficient, effect_right_coefficient;
wire signed [15:0] send_a_coefficient, send_b_coefficient;
gaiapolis_k054539_gain u_gain_rom(
    .volume(gain_volume_register), .channel_control(gain_control_register),
    .global_228(regs[9'h128][6:0]), .global_229(regs[9'h129][6:0]),
    .global_22a(regs[9'h12a][6:0]), .global_22b(regs[9'h12b][6:0]),
    .pan(gain_pan_register), .effect_volume(gain_effect_volume_register),
    .fixed_pan(regs[9'h12f][1]), .global_select(),
    .volume_coefficient(volume_coefficient), .global_coefficient(global_coefficient),
    .main_left_coefficient(main_left_coefficient), .main_right_coefficient(main_right_coefficient),
    .effect_left_coefficient(effect_left_coefficient), .effect_right_coefficient(effect_right_coefficient),
    .effect_a_coefficient(send_a_coefficient), .effect_b_coefficient(send_b_coefficient)
);
wire gain_ready, gain_busy, gain_done;
wire signed [15:0] gain_dry_l, gain_dry_r, gain_wet_l, gain_wet_r, gain_send_e, gain_send_f;
wire signed [15:0] gain_volume, gain_global, gain_preset_l, gain_preset_r;
gaiapolis_k054539_gain_pipeline u_gain_pipeline(.freeze(freeze), 
    .clk(clk), .reset(rst), .cen(cen), .start(gain_state==G_VOLUME),
    .boost_twice(gain_source < 4'd8 && BOOST_MASK[gain_source[2:0]]),
    .sample(w_filtered), .volume_coefficient(volume_coefficient), .global_coefficient(global_coefficient),
    .main_left_coefficient(main_left_coefficient), .main_right_coefficient(main_right_coefficient),
    .effect_left_coefficient(effect_left_coefficient), .effect_right_coefficient(effect_right_coefficient),
    .effect_a_coefficient(send_a_coefficient), .effect_b_coefficient(send_b_coefficient),
    .ready(gain_ready), .busy(gain_busy), .done(gain_done),
    .dry_left(gain_dry_l), .dry_right(gain_dry_r), .wet_left(gain_wet_l), .wet_right(gain_wet_r),
    .send_a(gain_send_e), .send_b(gain_send_f),
    .after_volume(gain_volume), .after_global(gain_global),
    .preset_left(gain_preset_l), .preset_right(gain_preset_r)
);

// direcciones base del canal
wire [8:0] b1 = {1'b0, ch, 5'b0};            // 0x20*ch
wire [8:0] b2 = 9'h100 + {5'b0, ch, 1'b0};   // 0x100 + 2*ch
wire [23:0] delta_now = {regs[b1+9'd2], regs[b1+9'd1], regs[b1+9'd0]};
// Physical DTYPE[2:1] selects PCM or one of three DPCM precisions. DTYPE0
// chooses byte-pair addressing; all six DPCM formats have an active decoder.
wire [2:0]  dtype_now = regs[b2][4:2];
wire [1:0]  type_now  = dtype_now == 3'd0 ? 2'd0 :
                        dtype_now == 3'd1 ? 2'd1 :
                        2'd2;

wire [39:0] phase_current, phase_next;
wire [23:0] phase_address;
wire phase_step, phase_clear;
wire phase_loop = loop_pending[ch] && !restart[ch];
wire [23:0] base_now = phase_loop ?
    {regs[b1+9'ha],regs[b1+9'h9],regs[b1+9'h8]} :
    {regs[b1+9'he],regs[b1+9'hd],regs[b1+9'hc]};
gaiapolis_k054539_phase u_phase(
    .phase({regs[b1+9'h0f],regs[b1+9'h11],regs[b1+9'h10],regs[b1+9'h13],regs[b1+9'h12]}), .pitch(active[ch] ? delta_now : 24'd0),
    .base(base_now),
    .dtype(dtype_now), .reverse(regs[b2][5]), .byte_select(1'b0),
    .key_on(restart[ch]), .loop_restart(phase_loop), .hold(1'b0),
    .current_phase(phase_current), .next_phase(phase_next),
    .rom_addr(phase_address), .nibble_select(),
    .dpcm_update(phase_step), .clear_previous(phase_clear)
);

// nibble DPCM actual segun paridad de la posicion (unidad nibble)
wire [3:0] dnib = (w_reverse ^ w_phase[16]) ? rom_data[7:4] : rom_data[3:0];
wire signed [15:0] ds, dpcm_value;
wire dpcm_eof, dpcm_valid;
gaiapolis_k054539_decode u_decode(
    .dtype(w_dtype), .nibble(dnib), .pcm_word(16'sd0),
    .previous(w_val), .advance(w_dpcm_update),
    .step(ds), .sample(dpcm_value), .eof(dpcm_eof), .valid(dpcm_valid)
);

// Literal ROMA filter schedule. Its negative chip half is serviced on the
// following host clock; production cen has intervening 48 MHz host cycles.
wire filter_request, filter_sample_valid, filter_stalled, filter_ram_write;
wire [2:0] filter_request_channel, filter_sample_channel, filter_tap_channel;
wire [6:0] filter_ram_address, filter_write_address;
wire [15:0] filter_ram_word = {regs[{1'b0,filter_ram_address,1'b0}+9'd1],
                              regs[{1'b0,filter_ram_address,1'b0}]};
wire [15:0] filter_write_word, filter_sample_value;
wire raw_ram_write;
wire [6:0] raw_ram_write_address;
wire [63:0] raw_position_read;
wire [15:0] raw_sample_read;
wire [2:0] raw_write_channel = raw_ram_write_address[6:4];
wire [15:0] raw_write_word =
    raw_ram_write_address[3:0] == 4'h6 ? raw_position_read[55:40] :
    raw_ram_write_address[3:0] == 4'h7 ? {raw_position_read[39:32],raw_position_read[63:56]} :
    raw_ram_write_address[3:0] == 4'h8 ? raw_position_read[31:16] :
    raw_ram_write_address[3:0] == 4'h9 ? raw_position_read[15:0] :
                                      raw_sample_read;
wire [8:0] filter_raw_slot, filter_delayed_slot;
wire [8:0] filter_mode_address = 9'h101 + {5'd0,filter_tap_channel,1'b0};
reg [7:0] decode_requested, filter_ready, decoded_slot_done, decoded_good;
reg [15:0] filtered_samples [0:7];
reg filter_decode_pending, frame_pending;
function [2:0] first_filter_ready(input [7:0] ready);
    if(ready[0]) first_filter_ready=0;
    else if(ready[1]) first_filter_ready=1;
    else if(ready[2]) first_filter_ready=2;
    else if(ready[3]) first_filter_ready=3;
    else if(ready[4]) first_filter_ready=4;
    else if(ready[5]) first_filter_ready=5;
    else if(ready[6]) first_filter_ready=6;
    else first_filter_ready=7;
endfunction
wire [2:0] gain_pick = first_filter_ready(filter_ready);
wire filter_decode_valid = filter_decode_pending && decode_requested[ch] &&
                           (filter_request_channel == ch);
gaiapolis_k054539_filter_slots u_filter(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen),
    .inhibit_state_write(!reg_updates),
    .active_channels(active), .raw_ram_write(raw_ram_write),
    .raw_ram_write_address(raw_ram_write_address),
    .decoded_sample_request(filter_request),
    .decoded_sample_channel(filter_request_channel),
    .decoded_sample_valid(filter_decode_valid), .decoded_sample(w_val),
    .stalled(filter_stalled), .ram_address(filter_ram_address),
    .ram_word(filter_ram_word), .ram_write(filter_ram_write),
    .ram_write_address(filter_write_address), .ram_write_word(filter_write_word),
    .tap_channel(filter_tap_channel), .tap_mode(regs[filter_mode_address][5:4]),
    .sample_valid(filter_sample_valid), .sample_channel(filter_sample_channel),
    .sample_value(filter_sample_value),
    .raw_slot(filter_raw_slot), .delayed_slot(filter_delayed_slot)
);

wire native_frame_tick = cen && sample_cnt == 9'd0;
wire effects_slot_tick = cen && !filter_stalled;
wire [7:0] lfo_a, lfo_b;
gaiapolis_k054539_lfo u_lfo_a(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen), .frame_tick(native_frame_tick),
    .rate(regs[9'h11b]), .depth(regs[9'h11c]), .value(lfo_a)
);
gaiapolis_k054539_lfo u_lfo_b(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen), .frame_tick(native_frame_tick),
    .rate(regs[9'h122]), .depth(regs[9'h123]), .value(lfo_b)
);

wire signed [15:0] aux_volume_a, aux_global_a, aux_pan_al, aux_pan_ar;
wire signed [15:0] aux_volume_b, aux_global_b, aux_pan_bl, aux_pan_br;
gaiapolis_k054539_gain u_aux_coeff_a(
    .volume(regs[9'h09f]), .channel_control(regs[9'h112]),
    .global_228(regs[9'h128][6:0]), .global_229(regs[9'h129][6:0]),
    .global_22a(regs[9'h12a][6:0]), .global_22b(regs[9'h12b][6:0]),
    .pan(regs[9'h0bf]), .effect_volume(8'd0), .fixed_pan(regs[9'h12f][1]),
    .global_select(), .volume_coefficient(aux_volume_a), .global_coefficient(aux_global_a),
    .main_left_coefficient(aux_pan_al), .main_right_coefficient(aux_pan_ar),
    .effect_left_coefficient(), .effect_right_coefficient(),
    .effect_a_coefficient(), .effect_b_coefficient()
);
gaiapolis_k054539_gain u_aux_coeff_b(
    .volume(regs[9'h0df]), .channel_control(regs[9'h113]),
    .global_228(regs[9'h128][6:0]), .global_229(regs[9'h129][6:0]),
    .global_22a(regs[9'h12a][6:0]), .global_22b(regs[9'h12b][6:0]),
    .pan(regs[9'h0ff]), .effect_volume(8'd0), .fixed_pan(regs[9'h12f][1]),
    .global_select(), .volume_coefficient(aux_volume_b), .global_coefficient(aux_global_b),
    .main_left_coefficient(aux_pan_bl), .main_right_coefficient(aux_pan_br),
    .effect_left_coefficient(), .effect_right_coefficient(),
    .effect_a_coefficient(), .effect_b_coefficient()
);

wire signed [15:0] effects_raw_a, effects_raw_b, effects_aux_l, effects_aux_r;
wire effects_ready, effects_valid, effects_busy, effects_overrun;
wire [14:0] effects_frame_counter, effects_frame;
gaiapolis_k054539_effects u_effects(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen), .frame_tick(native_frame_tick),
    .slot_tick(effects_slot_tick), .sample_cnt(filter_raw_slot), .mem_enable(!regs[9'h12f][4]),
    .mode224(regs[9'h124][6:0]), .mode225(regs[9'h125][5:0]),
    .offset_a0(~{regs[9'h117],regs[9'h116]}), .offset_a1(~{regs[9'h119],regs[9'h118]}),
    .offset_b0(~{regs[9'h11e],regs[9'h11d]}), .offset_b1(~{regs[9'h120],regs[9'h11f]}),
    .gain_a(~regs[9'h11a]), .gain_b(~regs[9'h121]), .lfo_a(lfo_a), .lfo_b(lfo_b),
    .send_e(fx_send_e), .send_f(fx_send_f),
    .volume_a(aux_volume_a), .global_a(aux_global_a), .pan_al(aux_pan_al), .pan_ar(aux_pan_ar),
    .volume_b(aux_volume_b), .global_b(aux_global_b), .pan_bl(aux_pan_bl), .pan_br(aux_pan_br),
    .ram_addr(effects_ram_addr), .ram_din(effects_ram_din), .ram_we(effects_ram_we), .ram_dout(effects_ram_dout),
    .wet_a(effects_raw_a), .wet_b(effects_raw_b), .wet_l(effects_aux_l), .wet_r(effects_aux_r),
    .wet_ready(effects_ready), .wet_valid(effects_valid), .busy(effects_busy),
    .frame_overrun(effects_overrun), .frame_counter(effects_frame_counter), .wet_frame(effects_frame)
);

// Native ROMA scheduling retires loop212/213 in groups0/1, real voices
// in groups2..9 and AXWORD210/211 in groups10/11. Preparation can overlap
// sample-ROM waits; all six destination banks retire only at their strobes.
wire [3:0] mix_group = filter_raw_slot[8:5];
wire [3:0] mix_source = mix_group < 4'd2 ? mix_group + 4'd8 :
                        mix_group < 4'd10 ? mix_group - 4'd2 : mix_group;
wire [95:0] mix_contribution = (mix_source < 4'd12 && mix_written[mix_source]) ?
                               mix_contributions[mix_source] : 96'd0;
wire signed [15:0] native_dry_l, native_dry_r, native_wet_l, native_wet_r;
wire banks_underrun;
wire output_enable = regs[9'h12f][0] && !(cpu_write_commit &&
                     cpu_write_addr==9'h12f && !cpu_write_data[0]);
assign output_enabled = output_enable;
gaiapolis_k054539_banks u_banks(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen), .slot_tick(effects_slot_tick), .sample_cnt(filter_raw_slot),
    .output_enable(output_enable), .contribution(mix_contribution),
    .contribution_valid(mix_ready[mix_source]),
    .dry_left(native_dry_l), .dry_right(native_dry_r),
    .wet_left(native_wet_l), .wet_right(native_wet_r),
    .sample_valid(sample_valid), .send_e(fx_send_e), .send_f(fx_send_f), .underrun(banks_underrun), .underrun_pulse(), .bank_values()
);
// D0 clears serializers, independently of all accumulators and send shadows.
assign left = output_enable ? native_dry_l : 16'sd0;
assign right = output_enable ? native_dry_r : 16'sd0;
assign wet_left = output_enable ? native_wet_l : 16'sd0;
assign wet_right = output_enable ? native_wet_r : 16'sd0;

// The physical key/EOF block is independent of RAM write inhibition.
wire [7:0] loop_enabled, odd_bit2;
genvar ev;
generate for(ev=0;ev<8;ev=ev+1) begin: event_controls
    assign loop_enabled[ev] = regs[9'h101+2*ev][0];
    assign odd_bit2[ev] = regs[9'h101+2*ev][2];
end endgenerate
wire [2:0] event_channel = filter_raw_slot[7:5] - 3'd1;
wire event_boundary = cen && !filter_stalled &&
                      (filter_raw_slot[4:0] == 5'd0) &&
                      (filter_raw_slot >= 9'd32) && (filter_raw_slot <= 9'd256);
wire [7:0] sample_event = event_boundary && decoded_slot_done[event_channel] ?
                          (8'b1 << event_channel) : 8'd0;
gaiapolis_k054539_events u_events(.freeze(freeze), 
    .clk(clk), .rst(rst), .cen(cen),
    .frame_tick(cen && !filter_stalled && filter_raw_slot == 9'd0),
    .keyon_release(cpu_write_commit && cpu_write_addr == 9'h114),
    .keyon_mask(cpu_write_data),
    .keyoff_mask((cpu_write_active && addr == 9'h115) ? din : 8'd0),
    .sample_event(sample_event), .sample_valid(decoded_good),
    .loop_enable(loop_enabled), .odd_bit2(odd_bit2),
    .pending(pending_keyon), .active(active), .start(restart),
    .loop_reset(loop_pending), .saved_valid(saved_valid), .history(eof_history)
);

always @(posedge clk)
    begin
    if (!freeze || rst) begin
    if (gain_done)
        mix_contributions[gain_source] <= {gain_send_f,gain_send_e,gain_wet_r,gain_wet_l,gain_dry_r,gain_dry_l};

    end
end

integer ci;
always @(posedge clk) begin
    if (!freeze || rst) begin
    if (rst) begin
        state <= S_IDLE; sample_cnt <= 0; ch <= 0;
        free_frame_epoch <= 16'hffff; sample_epoch <= 16'd0;
        sample_rom_cs <= 0; sample_rom_addr <= 0;
        gain_effect_volume_register <= 0;
        gain_source <= 0; mix_ready <= 12'hfff;
        loop_gain_pending <= 0; external_gain_pending <= 0; effects_gain_seen <= 0;
        external_sample_a <= 0; external_sample_b <= 0;
        w_loop_restart <= 0;
        decode_requested <= 0; filter_ready <= 0; decoded_slot_done <= 0;
        decoded_good <= 8'hff; filter_decode_pending <= 0; frame_pending <= 0;
        w_filtered <= 0; gain_state <= G_IDLE; gain_ch <= 0;
        gain_volume_register <= 0; gain_pan_register <= 0; gain_control_register <= 0;
        frame_gain_done <= 0;
        cpu_write_pending <= 1'b0;
        cpu_write_addr <= 9'd0;
        cpu_write_data <= 8'd0;
        read_ptr <= 0;
        rb_pending <= 1'b0;
        rb_active <= 1'b0;
        rb_read_seen <= 1'b0;
        rb_data_valid <= 1'b0;
        rr_cpu_read_seen <= 1'b0;
        data_access_seen <= 1'b0;
        rr_cpu_data_valid <= 1'b0;
        rr_cpu_data <= 8'd0;
        rr_cpu_addr_l <= 15'd0;
        rb_addr_l <= 24'd0;
        rb_data <= 8'd0;
        mix_written <= 12'd0;
        for (ci=0; ci<8; ci=ci+1) begin
            cpos[ci] <= 0; cpfrac[ci] <= 0; cval[ci] <= 0;
            cphase[ci] <= 0; filtered_samples[ci] <= 0;
        end
    end else begin
        // These are single host-clock pulses and must be captured outside cen.
        if (filter_request) begin
            decode_requested[filter_request_channel] <= 1'b1;
            decoded_slot_done[filter_request_channel] <= 1'b0;
            if (filter_request_channel == 3'd0) begin
                frame_pending <= 1'b1;
                mix_ready[7:0] <= 8'd0; mix_ready[11:10] <= 2'd0;
                external_gain_pending <= 2'b11;
                external_sample_a <= AX_INPUT_ENABLE ? axword_a : 16'sd0;
                external_sample_b <= AX_INPUT_ENABLE ? axword_b : 16'sd0;
            end
        end
        if (filter_sample_valid) begin
            filtered_samples[filter_sample_channel] <= filter_sample_value;
            filter_ready[filter_sample_channel] <= 1'b1;
        end
        // The filter schedule only retires words 0xb-0xe of a voice and the raw
        // schedule words 0x6-0xa, so the other bytes keep a single (CPU) writer.
        if (filter_ram_write && filter_write_address[3:0] >= 4'hb && filter_write_address[3:0] <= 4'he) begin
            regs[{1'b0,filter_write_address,1'b0}] <= filter_write_word[7:0];
            regs[{1'b0,filter_write_address,1'b0}+9'd1] <= filter_write_word[15:8];
        end
        if (raw_ram_write && raw_ram_write_address[3:0] >= 4'h6 && raw_ram_write_address[3:0] <= 4'ha) begin
            // P89 samples live active before the physical negative write half.
            // BASE is rewritten every active frame, including its mixed Q word.
            regs[{1'b0,raw_ram_write_address,1'b0}] <= raw_write_word[7:0];
            regs[{1'b0,raw_ram_write_address,1'b0}+9'd1] <= raw_write_word[15:8];
        end
        if (filter_decode_valid) begin
            // Exactly one response per request. Save the decoder result;
            // architectural RAM retires only at its scheduled word strobes.
            filter_decode_pending <= 1'b0;
            decode_requested[ch] <= 1'b0;
            decoded_slot_done[ch] <= 1'b1;
            cpos[ch] <= w_pos[23:0]; cpfrac[ch] <= w_next_phase[15:0];
            cphase[ch] <= w_next_phase; cval[ch] <= w_val;
        end
        // done is one HOST-clock pulse. Consuming it only inside cen would
        // lose the six-output packet between native chip enables.
        if (gain_done) begin
            mix_written[gain_source] <= 1'b1;
            mix_ready[gain_source] <= 1'b1;
            if (gain_source == 4'd7) frame_gain_done <= 1'b1;
            gain_state <= G_IDLE;
        end
        if (!effects_ready) effects_gain_seen <= 1'b0;
        else if (!effects_gain_seen) begin
            effects_gain_seen <= 1'b1; loop_gain_pending <= 2'b11;
        end

        data_access_seen <= data_access;
        if (cpu_write_active) begin
            cpu_write_pending <= 1'b1;
            cpu_write_addr <= addr;
            cpu_write_data <= din;
        end else begin
            cpu_write_pending <= 1'b0;
        end

        // ROM-bank data-port reads are serialized behind the playback
        // sequencer. The Z80 holds its register cycle through rb_wait while
        // native chip timing continues and the shared SDRAM byte is fetched.
        if (!rb_cpu_read) begin
            rb_read_seen <= 1'b0;
            rb_data_valid <= 1'b0;
            if (rb_pending && !rb_active)
                rb_pending <= 1'b0;
        end else if (!rb_read_seen) begin
            rb_read_seen <= 1'b1;
            if (!rb_pending && !rb_active) begin
                // Capture the byte address at the start of the CPU
                // transaction. Keep it stable through the entire held CPU
                // access; ADDRCNT advances only when that access releases.
                rb_pending <= 1'b1;
                rb_addr_l  <= {regs[9'h12e][6:0], read_ptr};
            end
        end

        // The dual-port RAM presents the reverb data-port byte one clock
        // after the CPU read begins.  Hold the Z80 cycle until that output is
        // valid, just as for a serialized ROM-bank read.
        if (!rr_cpu_read) begin
            rr_cpu_read_seen <= 1'b0;
            rr_cpu_data_valid <= 1'b0;
        end else if (!rr_cpu_read_seen) begin
            rr_cpu_read_seen <= 1'b1;
            rr_cpu_data_valid <= 1'b0;
            rr_cpu_addr_l <= rr_port_addr;
        end else begin
            // Capture the registered RAM result before the live serial
            // pointer selects the following byte.
            rr_cpu_data <= rram_port_dout;
            rr_cpu_data_valid <= 1'b1;
        end
        // Use only idle slack for the CPU data port. The physical K054539
        // keeps its 48 kHz stream running while this port is accessed, so a
        // diagnostic read must never freeze the sample counter.
        if (rb_pending && !rb_active && (state == S_IDLE) &&
            (sample_cnt != 9'd0) && (sample_cnt < 9'd320)) begin
            rb_pending <= 1'b0;
            rb_active  <= 1'b1;
        end
        if (rb_active && rom_ok) begin
            rb_data       <= rom_data;
            rb_active     <= 1'b0;
            rb_data_valid <= 1'b1;
        end

        // Ordinary register storage is transparent for the duration of the
        // physical chip's active-low write enable. BASE is ordinary RAM;
        // control D0 has no fanout into its write or key-on path.
        if (cpu_write_active) begin
            // CPU-visible phase bytes are not ordered linearly in the die RAM.
            if (!addr[8]) begin
                case (addr[4:0])
                    5'h0f: cphase[addr[7:5]][39:32] <= din;
                    5'h11: cphase[addr[7:5]][31:24] <= din;
                    5'h10: cphase[addr[7:5]][23:16] <= din;
                    5'h13: cphase[addr[7:5]][15:8]  <= din;
                    5'h12: cphase[addr[7:5]][7:0]   <= din;
                    default: ;
                endcase
            end
            if (addr == 9'h12f) begin
                // 0x22f D7 is transparent; D0/D1/D4/D5 commit below.
                regs[9'h12f][7] <= din[7];
            end else if (addr[8] && (addr[7:4] == 4'h0) && addr[0]) begin
                // Odd channel-control D0 is release-latched; its D2/D4/D5
                // fields are transparent while the strobe is active.
                case (addr)
                    9'h101: regs[9'h101][7:1] <= din[7:1];
                    9'h103: regs[9'h103][7:1] <= din[7:1];
                    9'h105: regs[9'h105][7:1] <= din[7:1];
                    9'h107: regs[9'h107][7:1] <= din[7:1];
                    9'h109: regs[9'h109][7:1] <= din[7:1];
                    9'h10b: regs[9'h10b][7:1] <= din[7:1];
                    9'h10d: regs[9'h10d][7:1] <= din[7:1];
                    9'h10f: regs[9'h10f][7:1] <= din[7:1];
                    default: ;
                endcase
            end else if (addr <= REG_TOP) begin
                regs[addr] <= din;
            end
        end

        // The decapped start/stop block captures key-on at nKONWR release.
        if (cpu_write_commit) begin
            case (cpu_write_addr)
                // SiliconRE shows 0x22f bits 0/1/4/5 captured on the rising
                // edge of its decoded active-low write strobe. D7 remains
                // transparent above and D2/D3/D6 are unimplemented.
                9'h12f: begin
                    regs[9'h12f][0] <= cpu_write_data[0];
                    regs[9'h12f][1] <= cpu_write_data[1];
                    regs[9'h12f][4] <= cpu_write_data[4];
                    regs[9'h12f][5] <= cpu_write_data[5];
            end
                9'h101: regs[9'h101][0] <= cpu_write_data[0];
                9'h103: regs[9'h103][0] <= cpu_write_data[0];
                9'h105: regs[9'h105][0] <= cpu_write_data[0];
                9'h107: regs[9'h107][0] <= cpu_write_data[0];
                9'h109: regs[9'h109][0] <= cpu_write_data[0];
                9'h10b: regs[9'h10b][0] <= cpu_write_data[0];
                9'h10d: regs[9'h10d][0] <= cpu_write_data[0];
                9'h10f: regs[9'h10f][0] <= cpu_write_data[0];
                default: ;
            endcase
        end
        // Physical ADDRCNT17: access release clocks the counter; REG22F.D4
        // holds it at zero. REG22E only changes bank/address bits. Its D7
        // selects RAM for every 80..FF value (SDF Y109/X110 and T94..T96).
        if (!regs[9'h12f][4] || (cpu_write_commit &&
            cpu_write_addr == 9'h12f && !cpu_write_data[4]))
            read_ptr <= 17'd0;
        else if (data_access_seen && !data_access)
            read_ptr <= read_ptr + 17'd1;

        if (cen) begin
            sample_cnt <= (sample_cnt == 9'd383) ? 9'd0 : sample_cnt + 9'd1;
            if(sample_cnt==9'd0) free_frame_epoch <= free_frame_epoch + 16'd1;
            // Tag the same atomic bank load with the free physical frame,
            // including when the external sample-ROM adapter is delayed.
            if(!filter_stalled && filter_raw_slot==9'd72)
                sample_epoch <= (sample_cnt==9'd0) ? free_frame_epoch + 16'd1 : free_frame_epoch;

            // The physical schedule decodes voice n while filtering/mixing
            // voice n-1. Keep gain independent of external sample-ROM waits.
            case(gain_state)
            G_IDLE: if(gain_ready) begin
                if(|filter_ready) begin
                    gain_source <= {1'b0,gain_pick}; gain_ch <= gain_pick;
                    w_filtered <= $signed(filtered_samples[gain_pick]);
                    gain_volume_register <= voice_cache_read[31:24];
                    gain_pan_register <= voice_cache_read[15:8];
                    gain_control_register <= voice_cache_read[7:0];
                    gain_effect_volume_register <= voice_cache_read[23:16];
                    filter_ready[gain_pick] <= 1'b0; gain_state <= G_VOLUME;
                end else if(|loop_gain_pending) begin
                    if(loop_gain_pending[0]) begin
                        gain_source <= 4'd8; w_filtered <= effects_raw_a;
                        gain_volume_register <= regs[9'h09f]; gain_pan_register <= regs[9'h0bf];
                        gain_control_register <= regs[9'h112]; gain_effect_volume_register <= regs[9'h0be];
                        loop_gain_pending[0] <= 1'b0;
                    end else begin
                        gain_source <= 4'd9; w_filtered <= effects_raw_b;
                        gain_volume_register <= regs[9'h0df]; gain_pan_register <= regs[9'h0ff];
                        gain_control_register <= regs[9'h113]; gain_effect_volume_register <= regs[9'h0fe];
                        loop_gain_pending[1] <= 1'b0;
                    end
                    gain_state <= G_VOLUME;
                end else if(|external_gain_pending) begin
                    if(external_gain_pending[0]) begin
                        gain_source <= 4'd10; w_filtered <= external_sample_a;
                        gain_volume_register <= regs[9'h01f]; gain_pan_register <= regs[9'h03f];
                        gain_control_register <= regs[9'h110]; gain_effect_volume_register <= regs[9'h03e];
                        external_gain_pending[0] <= 1'b0;
                    end else begin
                        gain_source <= 4'd11; w_filtered <= external_sample_b;
                        gain_volume_register <= regs[9'h05f]; gain_pan_register <= regs[9'h07f];
                        gain_control_register <= regs[9'h111]; gain_effect_volume_register <= regs[9'h07e];
                        external_gain_pending[1] <= 1'b0;
                    end
                    gain_state <= G_VOLUME;
                end
            end
            G_VOLUME: gain_state <= G_GLOBAL;
            G_GLOBAL: ; // Wait for the host-cycle completion above.
            default: gain_state <= G_IDLE;
            endcase

            case (state)
            S_IDLE: if (frame_pending && !rb_active && !quiesce) begin
                ch <= 0; frame_pending <= 1'b0;
                frame_gain_done <= 0; state <= S_LOAD;
            end

            S_LOAD: if (decode_requested[ch]) begin
                w_vol <= regs[b1+9'd3];
                w_loop <= {regs[b1+9'ha],regs[b1+9'h9],regs[b1+9'h8]};
                w_loopen <= regs[b2+1][0];
                w_pan_raw <= regs[b1+9'd5]; w_control <= regs[b2];
                w_type <= type_now; w_dtype <= dtype_now; w_reverse <= regs[b2][5];
                w_base <= base_now; w_phase <= phase_current; w_next_phase <= phase_next;
                // Phase/base arithmetic precedes ROM decoding, so long sample
                // replies cannot postpone the earlier scheduled Q/BASE words.
                w_dpcm_update <= phase_step; w_loop_restart <= phase_loop;
                w_pos <= {1'b0,phase_address};
                w_val <= phase_clear ? 16'sd0 :
                         (active[ch] || dtype_now >= 3'd2) ?
                         $signed({regs[b1+9'h15],regs[b1+9'h14]}) : 16'sd0;
                w_pval <= phase_clear ? 16'sd0 : cpval_read;
                decoded_good[ch] <= 1'b1;
                if (active[ch]) begin
                    sample_rom_addr <= phase_address; sample_rom_cs <= 1'b1;
                    case(type_now)
                        2'd0: state <= S_R8;
                        2'd1: state <= S_R16L;
                        default: state <= dtype_now[0] ? S_RODD : S_RD;
                    endcase
                end else begin
                    filter_decode_pending <= 1'b1; state <= S_FILTER;
                end
            end

            // ---------- captura 8-bit (espera rom_ok: dato del SDRAM listo) ----------
            S_R8: if (rom_ok) begin
                sample_rom_cs <= 1'b0;
                w_pval <= w_val; filter_decode_pending <= 1'b1;
                if (rom_data == 8'h80) begin
                    decoded_good[ch] <= 1'b0;
                    w_val <= 16'sd0; state <= S_FILTER;
                end else begin
                    w_val <= $signed({rom_data, 8'h00}); state <= S_FILTER;
                end
            end

            // ---------- captura 16-bit (byte bajo, luego alto) — espera rom_ok en cada byte ----------
            S_R16L: if (rom_ok) begin
                w_lo     <= rom_data;
                sample_rom_addr <= w_reverse ? w_pos[23:0]-24'd1 : w_pos[23:0]+24'd1;
                sample_rom_cs   <= 1'b1; state <= S_R16H;
            end
            S_R16H: if (rom_ok) begin
                sample_rom_cs <= 1'b0;
                w_pval <= w_val; filter_decode_pending <= 1'b1;
                if ({rom_data, w_lo} == 16'h8000) begin
                    decoded_good[ch] <= 1'b0;
                    w_val <= 16'sd0; state <= S_FILTER;
                end else begin
                    w_val <= $signed({rom_data, w_lo}); state <= S_FILTER;
                end
            end

            // Odd DPCM types fetch a byte pair. RD_REGA/DEC consumes the
            // second byte; the preceding RD_REGB byte has no decoder fanout.
            S_RODD: if (rom_ok) begin
                sample_rom_addr <= w_reverse ? w_pos[23:0]-24'd1 : w_pos[23:0]+24'd1;
                sample_rom_cs <= 1'b1; state <= S_RD;
            end

            // ---------- captura DPCM (espera rom_ok) ----------
            S_RD: if (rom_ok) begin
                sample_rom_cs <= 1'b0; filter_decode_pending <= 1'b1;
                if (dpcm_eof) begin
                    decoded_good[ch] <= 1'b0;
                    w_val <= 16'sd0; state <= S_FILTER;
                end else begin
                    w_pval <= w_val;
                    if (dpcm_valid) w_val <= dpcm_value;
                    state <= S_FILTER;
                end
            end

            S_FILTER: if (!filter_decode_pending) state <= S_NEXT;
            S_NEXT: begin
                if (ch == 3'd7) state <= S_WAIT;
                else begin ch <= ch + 3'd1; state <= S_LOAD; end
            end
            S_WAIT: if (frame_gain_done) state <= S_DONE;

            S_DONE: begin
                // Decoder/gain preparation is complete. The bank controller
                // independently publishes all four words at native LOADSR.
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    end
end


wire cache_load=cen && state==S_LOAD && decode_requested[ch];
gaiapolis_pcm_cache #(.DW(64)) u_raw_position_cache(
    .clk(clk),.rst(rst),.freeze(freeze),.we(cache_load),
    .write_address(ch),.read_address(raw_write_channel),
    .write_data({base_now,phase_next}),.read_data(raw_position_read));
gaiapolis_pcm_cache #(.DW(32)) u_voice_cache(
    .clk(clk),.rst(rst),.freeze(freeze),.we(cache_load),
    .write_address(ch),.read_address(gain_pick),
    .write_data({regs[b1+9'd3],regs[b1+9'd4],regs[b1+9'd5],regs[b2]}),.read_data(voice_cache_read));
gaiapolis_pcm_cache #(.DW(16)) u_previous_cache(
    .clk(clk),.rst(rst),.freeze(freeze),.we(filter_decode_valid),
    .write_address(ch),.read_address(ch),.write_data(w_pval),.read_data(cpval_read));
gaiapolis_pcm_cache #(.DW(16)) u_raw_sample_cache(
    .clk(clk),.rst(rst),.freeze(freeze),.we(filter_decode_valid),
    .write_address(ch),.read_address(raw_write_channel),.write_data(w_val),.read_data(raw_sample_read));
`ifdef VERILATOR
wire signed [15:0] cpval [0:7];
wire [23:0] raw_base [0:7]; wire [39:0] raw_phase [0:7]; wire [15:0] raw_sample [0:7];
wire [7:0] voice_volume [0:7],voice_effect_volume [0:7],voice_pan [0:7],voice_control [0:7];
genvar cache_debug_row;
generate for(cache_debug_row=0;cache_debug_row<8;cache_debug_row=cache_debug_row+1) begin:g_cache_debug
    assign cpval[cache_debug_row]=u_previous_cache.debug_rows[cache_debug_row];
    assign raw_base[cache_debug_row]=u_raw_position_cache.debug_rows[cache_debug_row][63:40];
    assign raw_phase[cache_debug_row]=u_raw_position_cache.debug_rows[cache_debug_row][39:0];
    assign raw_sample[cache_debug_row]=u_raw_sample_cache.debug_rows[cache_debug_row];
    assign voice_volume[cache_debug_row]=u_voice_cache.debug_rows[cache_debug_row][31:24];
    assign voice_effect_volume[cache_debug_row]=u_voice_cache.debug_rows[cache_debug_row][23:16];
    assign voice_pan[cache_debug_row]=u_voice_cache.debug_rows[cache_debug_row][15:8];
    assign voice_control[cache_debug_row]=u_voice_cache.debug_rows[cache_debug_row][7:0];
end endgenerate
`endif

endmodule

// SPDX-License-Identifier: GPL-3.0-or-later
// Project-owned whole-row PCM cache; generated into gaiapolis_pause_pcm.sv.
// Logical NBA old-state reads are independent of the MLAB collision mode:
// commit the preceding write, and forward its pending value until committed.
module gaiapolis_pcm_cache #(parameter DW=16) (
    input clk, rst, freeze, we,
    input [2:0] write_address, read_address,
    input [DW-1:0] write_data,
    output [DW-1:0] read_data
);
    reg [7:0] valid;
    reg pending_write;
    reg [2:0] pending_address;
    reg [DW-1:0] pending_data;
    wire [4:0] physical_write_address={2'b00,pending_address};
    wire [4:0] physical_read_address={2'b00,read_address};
    wire [DW-1:0] physical_read;
`ifdef GAIAPOLIS_PCM_CACHE_INTEL_MODEL
    altdpram #(.width(DW),.widthad(5),.numwords(32),
        .ram_block_type("MLAB"),.intended_device_family("Cyclone V"),
        .indata_reg("INCLOCK"),.wraddress_reg("INCLOCK"),.wrcontrol_reg("INCLOCK"),
        .rdaddress_reg("UNREGISTERED"),.rdcontrol_reg("UNREGISTERED"),
        .outdata_reg("UNREGISTERED")) storage(
        .inclock(clk),.inclocken(1'b1),.outclock(1'b0),.outclocken(1'b1),
        .aclr(1'b0),.sclr(1'b0),.wren(pending_write && !rst),
        .data(pending_data),.wraddress(physical_write_address),
        .rden(1'b1),.rdaddress(physical_read_address),
        .wraddressstall(1'b0),.rdaddressstall(1'b0),.byteena(1'b1),.q(physical_read));
`else
    (* ramstyle="MLAB, no_rw_check" *) reg [DW-1:0] rows [0:31];
    always @(posedge clk)
        if(!rst && pending_write) rows[physical_write_address]<=pending_data;
    assign physical_read=rows[physical_read_address];
`endif
    assign read_data=!valid[read_address] ? {DW{1'b0}} :
        pending_write && pending_address==read_address ? pending_data : physical_read;
    always @(posedge clk) begin
        if(rst) begin valid<=0; pending_write<=0; end
        else begin
            // A pending physical write may drain on the first frozen edge.
            // Forwarding -> committed memory must preserve the visible word.
            pending_write<=!freeze && we;
            if(!freeze && we) begin
                pending_address<=write_address; pending_data<=write_data;
                valid[write_address]<=1;
            end
        end
    end
`ifdef VERILATOR
    // Private equivalence observation only; never add physical read ports.
    wire [DW-1:0] debug_rows [0:7];
    genvar debug_row;
    generate for(debug_row=0;debug_row<8;debug_row=debug_row+1) begin:g_debug
        assign debug_rows[debug_row]=!valid[debug_row] ? {DW{1'b0}} :
            pending_write && pending_address==3'(debug_row) ? pending_data : rows[debug_row];
    end endgenerate
`endif
endmodule
