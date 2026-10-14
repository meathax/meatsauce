/*  k054539 — Konami 054539 (TOP) PCM Sound Chip. Implementacion PROPIA para COWBOYS / Moo Mesa.

    NO es el modulo privado `jt539` de Jotego (sponsor-gated, no clonable aqui). Escrito de cero
    contra el golden de MAME (k054539.cpp) y la RE de silicio de Furrtek
    (github.com/furrtek/SiliconRE/Konami/054539). Modelo de referencia: ver/cowboys/k054539_ref.cpp.

    ================================ ESTADO: Fase 3 ====================================
    Implementado:
      - Register file con el mapeo de bus real {A[9],A[7:0]} (se pierde A[8]) + read-back (POST).
      - FSM serial de 8 canales, un sample cada 384 `cen` (48 kHz), acumulador pos/frac.
      - Los TRES formatos que usa Moo Mesa (medido con el tap: 8bit 240 / 16bit 187 / DPCM 43):
          * 8-bit PCM  (type 0x0): 1 byte, val=byte<<8, terminador 0x80.
          * 16-bit PCM (type 0x4): 2 bytes LE, terminador 0x8000.
          * 4-bit DPCM (type 0x8): nibble + tabla de pasos, acumulacion, terminador 0x88.
      - Mezcla fixed-point Q16 con tablas voltab/pantab ($readmemh) + pan L/R (incl. rango 0x8x),
        key on/off. Salida = PCM PURO (canal propio hacia el rcmix de jtframe). La FM (jt51) es un
        CANAL SEPARADO (mem.yaml: fm + pcm) -> jtframe mezcla en precision ancha, sin comprometer
        headroom. Fixed channel balance is applied by JTFRAME's rcmix.
    Implemented in this revision:
      - reverb RAM 0x8000 bytes (two 16-bit BRAM banks)
      - forward and reverse playback stepping (base2 bit 5)
      - UPDATE_AT_KEYON position latches and live position register updates
      - active-channel readback at 0x22c.
      - 0x22d/0x22e pointer, complete 0x8000-byte reverb read/write behaviour,
        and serialized ROM-bank readback through the shared SDRAM port.

    ⭐ El READ-BACK del register file es comportamiento REAL y REQUISITO DE ARRANQUE (sesion 11):
    el POST del Z80 escribe/relee 0xE000-0xE1FF; con dout=0 el 68k cuelga en "RAM C4 BAD".
*/
module k054539 #(parameter VOLSHIFT=0) (
    input               rst,
    input               clk,
    input               cen,     // 18.432 MHz gated (pcm). 384 cen = 1 sample (48 kHz)
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
    output reg signed [15:0] left,
    output reg signed [15:0] right,

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
reg  [7:0] regs [0:511];
// UPDATE_AT_KEYON stores position writes outside the visible register RAM
// until the next key-on command.  Keep this flat for Quartus inference.
reg  [7:0] pos_latch [0:23];
// The physical K054539 captures CPU writes when the active-low write strobe
// is released.  The Z80 can hold one bus transaction across several 48 MHz
// clocks, so retain its stable bus value and emit exactly one release commit.
reg        cpu_write_pending;
reg [8:0]  cpu_write_addr;
reg [7:0]  cpu_write_data;
wire       cpu_write_active = cs && we;
wire       cpu_write_commit = cpu_write_pending && !cpu_write_active;
integer    gi;
initial for (gi=0; gi<512; gi=gi+1) regs[gi] = 8'd0;

wire update_at_keyon = regs[9'h12f][0];
wire reg_updates     = ~regs[9'h12f][7];
wire [7:0] keyon_retrigger = (cpu_write_commit &&
                              (cpu_write_addr == 9'h114) && reg_updates) ?
                              cpu_write_data : 8'h00;

assign dout    = (addr == 9'h12c) ? active :
                 (addr == 9'h12d) ? ((rd && regs[9'h12f][4]) ?
                                      (regs[9'h12e] == 8'h80 ? rr_cpu_data : rb_data) : 8'h00) :
                 regs[addr];
// A real K054539 commits one mix every 384 input clocks.  Missing a boundary
// makes the serialized FPGA implementation wait a whole extra period, which
// is heard as pitch slowdown/warble.  Keep this pulse available as a release
// diagnostic and as a hard regression contract.
assign timeout = cen && (sample_cnt == 9'd0) &&
                 ((state != S_IDLE) || rb_active);
assign st_dout = 8'd0;

// ---------------------------------------------------------------------------
// Tablas de volumen/pan (Q16) — mismas que k054539_ref.cpp modo FIXED.
// ---------------------------------------------------------------------------
reg [15:0] voltab [0:255];   // <= 0x4000
reg [16:0] pantab [0:14];    // <= 0x10000
initial begin
    $readmemh("voltab.hex", voltab);
    $readmemh("pantab.hex", pantab);
end

// ---------------------------------------------------------------------------
// Estado por canal (autoritativo; en unidades de BYTE entre samples)
// ---------------------------------------------------------------------------
reg [23:0] cpos   [0:7];
reg [15:0] cpfrac [0:7];
reg signed [15:0] cval  [0:7];
reg signed [15:0] cpval [0:7];

reg  [7:0] active;    // canales sonando (MAME 0x22c)
reg  [7:0] restart;   // re-arranque por flanco de keyon

// ---------------------------------------------------------------------------
// Secuenciador
// ---------------------------------------------------------------------------
localparam [3:0]
    S_IDLE = 4'd0, S_LOAD = 4'd1, S_ACC = 4'd2,
    S_R8   = 4'd3, S_R16L = 4'd4, S_R16H = 4'd5, S_RD = 4'd6,
    S_MIX  = 4'd7, S_NEXT = 4'd8, S_DONE = 4'd9,
    S_REVRD= 4'd10, S_RVWR = 4'd11;   // reverb: lee feedback @revpos ; RMW del canal @widx

reg [3:0]  state;
reg [8:0]  sample_cnt;
reg [2:0]  ch;

// registros de trabajo del canal en curso
reg [24:0] w_pos;              // 25b: DPCM trabaja en unidades de NIBBLE (pos<<1)
reg signed [31:0] w_pfrac;
reg signed [15:0] w_val, w_pval;
reg [23:0] w_loop;
reg [7:0]  w_lo;              // byte bajo del sample 16-bit
reg [7:0]  w_vol;
reg [3:0]  w_pan;
reg [1:0]  w_type;           // 0=8bit, 1=16bit(0x4), 2=DPCM(0x8)
reg        w_loopen;
reg        w_reverse;

// Playback ROM request registers.  The external port is arbitrated with the
// diagnostic/readback request below; only one request is presented at once.
reg         sample_rom_cs;
reg  [23:0] sample_rom_addr;

reg         rb_pending, rb_active, rb_read_seen, rb_data_valid;
reg         rr_cpu_read_seen, rr_cpu_data_valid;
reg  [23:0] rb_addr_l;
reg  [14:0] rr_cpu_addr_l;
reg   [7:0] rb_data, rr_cpu_data;
wire        rb_rom_bank = regs[9'h12e] != 8'h80;
wire        rb_cpu_read = cs && rd && (addr == 9'h12d) && regs[9'h12f][4] && rb_rom_bank;
wire        rr_cpu_read = cs && rd && (addr == 9'h12d) &&
                          (regs[9'h12e] == 8'h80) && regs[9'h12f][4];

assign rom_cs   = sample_rom_cs | rb_active;
assign rom_addr = rb_active ? rb_addr_l : sample_rom_addr;
assign rb_wait  = rb_pending | rb_active |
                  (rb_cpu_read && !rb_data_valid) |
                  (rr_cpu_read && !rr_cpu_data_valid);

// acumuladores en Q16 (como MAME: suma en full-precision, >>16 UNA vez al final)
reg signed [39:0] accL, accR;

// ---------------------------------------------------------------------------
// Reverb — linea de retardo mono (MAME k054539.cpp). The audio delay uses
// int16[0x2000] words; the CPU data port exposes the complete 0x8000-byte
// store, with the pointer's bit 16 selecting the upper 0x4000-byte half.
// Por sample: se LEE+LIMPIA rram[reverb_pos] (feedback, se suma a L y R por igual);
// cada canal ACUMULA su muestra atenuada en rram[(rdelta+reverb_pos)&0x1fff]; luego reverb_pos++.
// Lectura REGISTRADA (sincrona) -> infiere BRAM (leccion sesion 16: async => logica).
// Init 0 via $readmemh (NO `initial for`: Quartus limita el desenrollado a 5000 iter -> Error 10106
// con 8192; Verilator/lint lo tragan -> nueva cara del C-06). rram_zero.hex = 8192x"0000".
// ---------------------------------------------------------------------------
reg  [16:0] read_ptr;             // K054539 0x22d pointer, wraps at 0x1ffff
reg  [12:0] reverb_pos;
reg  [12:0] rr_addr;             // direccion de ESCRITURA (clear @revpos / RMW @widx)
reg         rr_we;
reg  signed [15:0] rr_din;
wire [14:0] rr_port_addr = {read_ptr[16], read_ptr[13:0]};
// direccion de LECTURA combinacional: en S_MIX lee @widx (para el RMW del canal en S_RVWR);
// en cualquier otro estado lee @reverb_pos (feedback, usado en S_REVRD tras emitir en S_IDLE).
wire [12:0] rd_addr = ((state==S_MIX) || (state==S_RVWR)) ? widx : reverb_pos;

// The reverb store has two independent 0x4000-byte banks.  Keep the CPU
// data port on RAM port 0 and the audio read/modify/write path on port 1 so
// Quartus can infer two dual-port M10K memories instead of expanding the
// 262,144 bits into registers.  The CPU read is deliberately registered and
// participates in rb_wait below, matching the existing wait-state contract
// used by the serial ROM data port.
wire        rr_cpu_write = cpu_write_commit && (cpu_write_addr == 9'h12d) &&
                            (regs[9'h12e] == 8'h80);
wire [1:0]  rr_cpu_we = rr_cpu_write ?
                        (rr_port_addr[0] ? 2'b10 : 2'b01) : 2'b00;
wire [15:0] rr_cpu_din = rr_port_addr[0] ? {cpu_write_data,8'h00} :
                                                   {8'h00,cpu_write_data};
wire [15:0] rr_lo_cpu_q, rr_hi_cpu_q, rr_audio_q;
wire [12:0] rr_cpu_word_addr = rr_cpu_read_seen ? rr_cpu_addr_l[13:1] :
                                                   rr_port_addr[13:1];
wire [15:0] rr_cpu_q = rr_cpu_addr_l[14] ? rr_hi_cpu_q : rr_lo_cpu_q;
wire signed [15:0] rr_dout = rr_audio_q;

jtframe_dual_ram16 #(
    .AW          ( 13 ),
    .SIMHEXFILE_LO( "rram_zero.hex" ),
    .SIMHEXFILE_HI( "rram_zero.hex" ),
    .SYNFILE_LO  ( "rram_zero.hex" ),
    .SYNFILE_HI  ( "rram_zero.hex" )
) u_rram_lo (
    .clk0  ( clk           ),
    .data0 ( rr_cpu_din    ),
    .addr0 ( rr_cpu_word_addr ),
    .we0   ( rr_port_addr[14] ? 2'b00 : rr_cpu_we ),
    .q0    ( rr_lo_cpu_q   ),
    .clk1  ( clk           ),
    .data1 ( rr_din        ),
    .addr1 ( rr_we ? rr_addr : rd_addr ),
    .we1   ( rr_we ? 2'b11 : 2'b00 ),
    .q1    ( rr_audio_q    )
);

jtframe_dual_ram16 #(
    .AW          ( 13 ),
    .SIMHEXFILE_LO( "rram_zero.hex" ),
    .SIMHEXFILE_HI( "rram_zero.hex" ),
    .SYNFILE_LO  ( "rram_zero.hex" ),
    .SYNFILE_HI  ( "rram_zero.hex" )
) u_rram_hi (
    .clk0  ( clk           ),
    .data0 ( rr_cpu_din    ),
    .addr0 ( rr_cpu_word_addr ),
    .we0   ( rr_port_addr[14] ? rr_cpu_we : 2'b00 ),
    .q0    ( rr_hi_cpu_q   ),
    .clk1  ( clk           ),
    .data1 ( 16'h0000      ),
    .addr1 ( 13'd0         ),
    .we1   ( 2'b00         ),
    .q1    (               )
);

wire [15:0] rram_port_word = rr_cpu_q;
wire [7:0] rram_port_dout = rr_cpu_addr_l[0] ?
                              rram_port_word[15:8] :
                              rram_port_word[7:0];

// --- volumen L/R del canal en curso (Q16) ---
wire [16:0] vt   = {1'b0, voltab[w_vol]};
wire [16:0] pl   = pantab[w_pan];
wire [16:0] pr   = pantab[4'd14 - w_pan];
wire [33:0] lfull= vt * pl;
wire [33:0] rfull= vt * pr;
wire [16:0] lvol = lful_clamp(lfull[32:16]);
wire [16:0] rvol = lful_clamp(rfull[32:16]);
function [16:0] lful_clamp(input [16:0] v);
    lful_clamp = (v > 17'h1CCCC) ? 17'h1CCCC : v;   // VOL_CAP=1.8 en Q16
endfunction

// contribucion del canal en Q16 (SIN truncar): w_val * vol. Se acumula asi y se redondea al final.
wire signed [33:0] cprodL = $signed(w_val) * $signed({1'b0, lvol});
wire signed [33:0] cprodR = $signed(w_val) * $signed({1'b0, rvol});
wire signed [39:0] contribL = {{6{cprodL[33]}}, cprodL};
wire signed [39:0] contribR = {{6{cprodR[33]}}, cprodR};

// --- Reverb: parametros del canal en curso (MAME, modo FIXED) ---
//   rdelta = ({base1[7],base1[6]} >> 3);  rdelta = (rdelta+revpos)&0x3fff;
//   widx   = (rdelta + revpos) & 0x1fff;  (revpos sumado DOS veces: quirk exacto de MAME)
//   bval   = min(vol + base1[4], 255);    rbvol = (voltab[bval]*32768)>>16 = voltab[bval]>>1
//   rev_contrib = (int16)((cur_val * rbvol) >> 16)  -> se ACUMULA (int16, wrap) en rram[widx]
wire [15:0] rdelta_word = {regs[b1+9'd7], regs[b1+9'd6]};
wire [12:0] rrd  = rdelta_word[15:3];                            // 16b >>3 = 13b
wire [13:0] rd14 = ({1'b0,rrd} + {1'b0,reverb_pos}) & 14'h3fff;
wire [14:0] wsum = {1'b0,rd14} + {2'b0,reverb_pos};
wire [12:0] widx = wsum[12:0];                                    // &0x1fff
wire [8:0]  bsum = {1'b0,w_vol} + {1'b0, regs[b1+9'd4]};
wire [7:0]  bval = bsum[8] ? 8'd255 : bsum[7:0];                  // clamp 255
wire [15:0] rbvol = {1'b0, voltab[bval][15:1]};                   // voltab>>1 (< VOL_CAP siempre)
wire signed [32:0] rprod = $signed(w_val) * $signed({1'b0, rbvol});
wire signed [15:0] rev_contrib = rprod[31:16];                   // (>>16) truncado a int16

// direcciones base del canal
wire [8:0] b1 = {1'b0, ch, 5'b0};            // 0x20*ch
wire [8:0] b2 = 9'h100 + {5'b0, ch, 1'b0};   // 0x100 + 2*ch
wire [23:0] delta_now = {regs[b1+9'd2], regs[b1+9'd1], regs[b1+9'd0]};
wire signed [31:0] delta_signed = regs[b2][5] ?
                                   -$signed({8'b0,delta_now}) :
                                    $signed({8'b0,delta_now});
wire [1:0]  type_now  = (regs[b2] & 8'h0c)==8'h00 ? 2'd0 :
                        (regs[b2] & 8'h0c)==8'h04 ? 2'd1 : 2'd2;

// tabla de pasos DPCM (x0x100)
function signed [15:0] dpcm_step(input [3:0] n);
    case (n)
        4'd0:  dpcm_step =  16'sd0;      4'd1:  dpcm_step =  16'sd256;
        4'd2:  dpcm_step =  16'sd512;    4'd3:  dpcm_step =  16'sd1024;
        4'd4:  dpcm_step =  16'sd2048;   4'd5:  dpcm_step =  16'sd4096;
        4'd6:  dpcm_step =  16'sd8192;   4'd7:  dpcm_step =  16'sd16384;
        4'd8:  dpcm_step =  16'sd0;      4'd9:  dpcm_step = -16'sd16384;
        4'd10: dpcm_step = -16'sd8192;   4'd11: dpcm_step = -16'sd4096;
        4'd12: dpcm_step = -16'sd2048;   4'd13: dpcm_step = -16'sd1024;
        4'd14: dpcm_step = -16'sd512;    4'd15: dpcm_step = -16'sd256;
    endcase
endfunction

// clamp a int16
function signed [15:0] clip16(input signed [23:0] v);
    clip16 = (v >  24'sd32767) ? 16'sd32767 :
             (v < -24'sd32768) ? -16'sd32768 : v[15:0];
endfunction
function [3:0] pan_idx(input [7:0] p);
    if      (p >= 8'h81 && p <= 8'h8f) pan_idx = p[3:0] - 4'd1;
    else if (p >= 8'h11 && p <= 8'h1f) pan_idx = p[3:0] - 4'd1;
    else                               pan_idx = 4'd7;
endfunction

// nibble DPCM actual segun paridad de la posicion (unidad nibble)
wire [3:0] dnib = w_pos[0] ? rom_data[7:4] : rom_data[3:0];
wire signed [15:0] ds = dpcm_step(dnib);

// avance de posicion (unidades de w_pos)
wire [24:0] npos1 = w_reverse ? w_pos - 25'd1 : w_pos + 25'd1;
wire [24:0] npos2 = w_reverse ? w_pos - 25'd2 : w_pos + 25'd2;

integer ci;
always @(posedge clk) begin
    if (rst) begin
        state <= S_IDLE; sample_cnt <= 0; ch <= 0;
        sample_rom_cs <= 0; sample_rom_addr <= 0;
        left <= 0; right <= 0; accL <= 0; accR <= 0;
        active <= 0; restart <= 0;
        cpu_write_pending <= 1'b0;
        cpu_write_addr <= 9'd0;
        cpu_write_data <= 8'd0;
        read_ptr <= 0;
        rb_pending <= 1'b0;
        rb_active <= 1'b0;
        rb_read_seen <= 1'b0;
        rb_data_valid <= 1'b0;
        rr_cpu_read_seen <= 1'b0;
        rr_cpu_data_valid <= 1'b0;
        rr_cpu_data <= 8'd0;
        rr_cpu_addr_l <= 15'd0;
        rb_addr_l <= 24'd0;
        rb_data <= 8'd0;
        reverb_pos <= 0; rr_we <= 0; rr_addr <= 0; rr_din <= 0;   // reverb (rram init por `initial`)
        for (ci=0; ci<8; ci=ci+1) begin
            cpos[ci] <= 0; cpfrac[ci] <= 0; cval[ci] <= 0; cpval[ci] <= 0;
        end
        for (ci=0; ci<24; ci=ci+1) pos_latch[ci] <= 0;
    end else begin
        if (cpu_write_active) begin
            cpu_write_pending <= 1'b1;
            cpu_write_addr <= addr;
            cpu_write_data <= din;
        end else begin
            cpu_write_pending <= 1'b0;
        end

        // ROM-bank data-port reads are serialized behind the playback
        // sequencer.  The Z80 holds its register cycle through rb_wait while
        // the shared SDRAM byte is fetched; sample timing is paused only for
        // this diagnostic transaction.
        if (!rb_cpu_read) begin
            rb_read_seen <= 1'b0;
            rb_data_valid <= 1'b0;
            if (rb_pending && !rb_active)
                rb_pending <= 1'b0;
        end else if (!rb_read_seen) begin
            rb_read_seen <= 1'b1;
            if (!rb_pending && !rb_active) begin
                // Capture the byte address at the start of the CPU
                // transaction.  The serial pointer is incremented by the
                // same clock edge below; deriving the request address later
                // would therefore skip the byte being read.
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
        // physical chip's active-low write enable. Position bytes are
        // diverted to the UPDATE_AT_KEYON latches until key-on release.
        if (cpu_write_active) begin
            if (addr == 9'h12f) begin
                // 0x22f D7 is transparent; D0/D1/D4/D5 commit below.
                regs[9'h12f][7] <= din[7];
            end else if (update_at_keyon && !addr[8] &&
                         (addr[4:0] >= 5'h0c) && (addr[4:0] <= 5'h0e)) begin
                pos_latch[(addr[8:5] * 3) + (addr[4:0] - 5'h0c)] <= din;
            end else if (addr[8] && (addr[7:4] == 4'h0) && addr[0]) begin
                // Odd channel-control D0 is release-latched; its D2/D4/D5
                // fields are transparent while the strobe is active.
                regs[addr] <= {din[7:1], regs[addr][0]};
            end else begin
                regs[addr] <= din;
            end
        end

        // The decapped start/stop block captures key-on at nKONWR release.
        if (cpu_write_commit) begin
            case (cpu_write_addr)
                9'h114: begin
                    // MAME suppresses all register updates while bit 7 of
                    // the global control is set.  With UPDATE_AT_KEYON,
                    // copy the three latched position bytes atomically.
                    if (reg_updates) begin
                        active  <= active | cpu_write_data;
                        // Key-on restarts every selected voice, including a
                        // voice whose active bit is already set.  Bucky
                        // rapidly reuses voices for event effects; suppressing
                        // an active-to-active retrigger leaves the new sample
                        // position latch unconsumed and silences later SFX.
                        restart <= restart | cpu_write_data;
                    end
                    if (update_at_keyon) begin
                        for (ci=0; ci<8; ci=ci+1) begin
                            if (cpu_write_data[ci]) begin
                                regs[(ci*32)+32'd12] <= pos_latch[(ci*3)+0];
                                regs[(ci*32)+32'd13] <= pos_latch[(ci*3)+1];
                                regs[(ci*32)+32'd14] <= pos_latch[(ci*3)+2];
                            end
                        end
                    end
                end
                // SiliconRE shows 0x22f bits 0/1/4/5 captured on the rising
                // edge of its decoded active-low write strobe. D7 remains
                // transparent above and D2/D3/D6 are unimplemented.
                9'h12f: begin
                    regs[9'h12f][0] <= cpu_write_data[0];
                    regs[9'h12f][1] <= cpu_write_data[1];
                    regs[9'h12f][4] <= cpu_write_data[4];
                    regs[9'h12f][5] <= cpu_write_data[5];
                end
                default: begin
                    if (cpu_write_addr[8] &&
                        (cpu_write_addr[7:4] == 4'h0) && cpu_write_addr[0])
                        regs[cpu_write_addr][0] <= cpu_write_data[0];
                end
            endcase
        end
        // Key-off is level-visible for the full decoded write strobe in the
        // decapped start/stop block; release must not apply it a second time.
        if (cpu_write_active) begin
            case (addr)
                9'h115: if (reg_updates) active <= active & ~din;
                9'h12c: if (reg_updates) active <= din;
                default: ;
            endcase
        end

        // 0x22d advances the serial pointer for both writes and reads;
        // 0x22e selects a bank and resets the pointer.  ROM-bank reads are
        // serviced by the streaming-ROM integration; the reverb bank is
        // available immediately through rram_port_dout above.
        if (cpu_write_commit && (cpu_write_addr == 9'h12d))
            read_ptr <= read_ptr + 17'd1;
        else if ((rb_cpu_read && !rb_read_seen) ||
                 (rr_cpu_read && !rr_cpu_read_seen))
            read_ptr <= read_ptr + 17'd1;
        else if (cpu_write_active && (addr == 9'h12e))
            read_ptr <= 17'd0;

        if (cen) begin
            sample_cnt <= (sample_cnt == 9'd383) ? 9'd0 : sample_cnt + 9'd1;
            sample_rom_cs <= 1'b0;
            rr_we  <= 1'b0;   // por defecto sin escritura de reverb (patron rom_cs)

            case (state)
            S_IDLE: if ((sample_cnt == 9'd0) && !rb_active) begin
                        ch <= 0;
                        if (regs[9'h12f][0]) begin
                            state <= S_REVRD;   // rd_addr=reverb_pos (emitido); rr_dout listo en S_REVRD
                        end else begin
                            accL <= 0; accR <= 0; state <= S_LOAD;     // chip off: sin reverb
                        end
                    end

            // ---------- reverb: feedback @reverb_pos -> init de accL/accR, y LIMPIA el slot ----------
            S_REVRD: begin
                accL <= { {8{rr_dout[15]}}, rr_dout, 16'b0 };   // rbase[revpos]<<16 (Q40, sext)
                accR <= { {8{rr_dout[15]}}, rr_dout, 16'b0 };
                rr_addr <= reverb_pos; rr_din <= 16'sd0; rr_we <= 1'b1;   // rram[reverb_pos] <= 0
                state <= S_LOAD;
            end

            // ---------- carga de parametros + setup del acumulador ----------
            S_LOAD: begin
                if (!active[ch] || !regs[9'h12f][0]) begin
                    state <= S_NEXT;
                end else begin
                    w_vol    <=  regs[b1+3];
                    w_loop   <= {regs[b1+9'ha], regs[b1+9'h9], regs[b1+9'h8]};
                    w_loopen <=  regs[b2+1][0];
                    w_pan    <=  pan_idx(regs[b1+5]);
                    w_type   <=  type_now;
                    w_reverse<=  regs[b2][5];
                    // pos/frac base (unidad byte). Para DPCM se escala a nibble abajo.
                    if (type_now == 2'd2) begin
                        // DPCM: pos<<1, frac<<1, ajuste de acarreo, +=delta
                        if (restart[ch]) begin
                            w_pos   <= {regs[b1+9'he], regs[b1+9'hd], regs[b1+9'hc]} << 1;
                            w_pfrac <= delta_signed;                     // (0<<1)=0, +/-delta
                            w_val   <= 0; w_pval <= 0;
                            // Do not lose a same-clock CPU retrigger while
                            // the sample sequencer consumes the old request.
                            restart[ch] <= keyon_retrigger[ch];
                        end else begin
                            // frac<<1; si bit16 -> pos|1, frac&0xffff; luego +delta
                            w_pos   <= ({cpos[ch],1'b0}) | (cpfrac[ch][15] ? 25'd1 : 25'd0);
                            w_pfrac <= $signed({15'b0, cpfrac[ch], 1'b0}) + delta_signed
                                       - (cpfrac[ch][15] ? 32'h0001_0000 : 32'd0);
                            w_val   <= cval[ch]; w_pval <= cpval[ch];
                        end
                    end else begin
                        if (restart[ch]) begin
                            w_pos   <= {1'b0, regs[b1+9'he], regs[b1+9'hd], regs[b1+9'hc]};
                            w_pfrac <= delta_signed;
                            w_val   <= 0; w_pval <= 0;
                            restart[ch] <= keyon_retrigger[ch];
                        end else begin
                            w_pos   <= {1'b0, cpos[ch]};
                            w_pfrac <= $signed({16'b0, cpfrac[ch]}) + delta_signed;
                            w_val   <= cval[ch]; w_pval <= cpval[ch];
                        end
                    end
                    state <= S_ACC;
                end
            end

            // ---------- while(cur_pfrac & ~0xffff): avanza y lee ----------
            S_ACC: begin
                if (|w_pfrac[31:16]) begin
                    // Forward playback subtracts one whole fraction; reverse
                    // playback adds it back while the signed fraction is
                    // negative, matching MAME's fdelta/pdelta pair.
                    w_pfrac <= w_pfrac +
                               (w_reverse ? 32'sh0001_0000 : -32'sh0001_0000);
                    case (w_type)
                    2'd0: begin // 8-bit: +1 byte
                        w_pos    <= npos1;
                        sample_rom_addr <= npos1[23:0];
                        sample_rom_cs   <= 1'b1; state <= S_R8;
                    end
                    2'd1: begin // 16-bit: +2 bytes (lee low y luego high)
                        w_pos    <= npos2;
                        sample_rom_addr <= npos2[23:0];
                        sample_rom_cs   <= 1'b1; state <= S_R16L;
                    end
                    default: begin // DPCM: +1 nibble; lee byte pos>>1
                        w_pos    <= npos1;
                        sample_rom_addr <= npos1[24:1];
                        sample_rom_cs   <= 1'b1; state <= S_RD;
                    end
                    endcase
                end else begin
                    state <= S_MIX;
                end
            end

            // ---------- captura 8-bit (espera rom_ok: dato del SDRAM listo) ----------
            S_R8: if (rom_ok) begin
                w_pval <= w_val;
                if (rom_data == 8'h80) begin
                    if (w_loopen) begin
                        w_pos <= {1'b0, w_loop}; sample_rom_addr <= w_loop; sample_rom_cs <= 1'b1; state <= S_R8;
                    end else begin
                        // A key-on queued after this channel's S_LOAD belongs
                        // to the replacement voice.  Do not let the old
                        // in-flight sample's terminator retire it before the
                        // next S_LOAD consumes the pending restart.
                        if (reg_updates && !restart[ch] && !keyon_retrigger[ch]) active[ch] <= 1'b0;
                        w_val <= 16'sd0; state <= S_MIX;
                    end
                end else begin
                    w_val <= $signed({rom_data, 8'h00}); state <= S_ACC;
                end
            end

            // ---------- captura 16-bit (byte bajo, luego alto) — espera rom_ok en cada byte ----------
            S_R16L: if (rom_ok) begin
                w_lo     <= rom_data;
                sample_rom_addr <= w_pos[23:0] + 24'd1;   // byte alto
                sample_rom_cs   <= 1'b1; state <= S_R16H;
            end
            S_R16H: if (rom_ok) begin
                w_pval <= w_val;
                if ({rom_data, w_lo} == 16'h8000) begin
                    if (w_loopen) begin
                        w_pos <= {1'b0, w_loop}; sample_rom_addr <= w_loop; sample_rom_cs <= 1'b1; state <= S_R16L;
                    end else begin
                        if (reg_updates && !restart[ch] && !keyon_retrigger[ch]) active[ch] <= 1'b0;
                        w_val <= 16'sd0; state <= S_MIX;
                    end
                end else begin
                    w_val <= $signed({rom_data, w_lo}); state <= S_ACC;
                end
            end

            // ---------- captura DPCM (espera rom_ok) ----------
            S_RD: if (rom_ok) begin
                if (rom_data == 8'h88) begin
                    if (w_loopen) begin
                        w_pos <= {w_loop, 1'b0}; sample_rom_addr <= w_loop; sample_rom_cs <= 1'b1; state <= S_RD;
                    end else begin
                        if (reg_updates && !restart[ch] && !keyon_retrigger[ch]) active[ch] <= 1'b0;
                        w_val <= 16'sd0; state <= S_MIX;
                    end
                end else begin
                    w_pval <= w_val;
                    w_val  <= clip16( {{8{w_val[15]}}, w_val} + {{8{ds[15]}}, ds} );
                    state  <= S_ACC;
                end
            end

            // ---------- mezcla + writeback (des-escala DPCM) ----------
            S_MIX: begin
                accL <= accL + contribL;
                accR <= accR + contribR;
                if (w_type == 2'd2) begin
                    cpos[ch]   <= w_pos[24:1];                             // pos>>1
                    cpfrac[ch] <= w_pfrac[16:1] | (w_pos[0] ? 16'h8000 : 16'h0000);
                end else begin
                    cpos[ch]   <= w_pos[23:0];
                    cpfrac[ch] <= w_pfrac[15:0];
                end
                // The silicon mirrors the current sample position into the
                // channel's 0x0c..0x0e bytes while register updates are
                // enabled.  This is observable through the Z80 readback
                // path and is required by diagnostics.
                // A CPU key-on may commit a new latched start on this exact
                // master-clock edge.  Give that command priority over the
                // retiring voice's live-position mirror; otherwise S_LOAD
                // consumes restart from the just-overwritten old/end address
                // and the replacement effect is silent or malformed.
                if (reg_updates && !restart[ch] && !keyon_retrigger[ch]) begin
                    regs[b1+9'h0c] <= (w_type == 2'd2) ? w_pos[8:1]  : w_pos[7:0];
                    regs[b1+9'h0d] <= (w_type == 2'd2) ? w_pos[16:9] : w_pos[15:8];
                    regs[b1+9'h0e] <= (w_type == 2'd2) ? w_pos[24:17] : w_pos[23:16];
                end
                cval[ch]  <= w_val;
                cpval[ch] <= w_pval;
                state <= S_RVWR;        // rd_addr=widx (emitido en S_MIX); rr_dout listo en S_RVWR
            end

            // ---------- reverb RMW: rram[widx] += rev_contrib (int16, wrap) ----------
            S_RVWR: begin
                rr_addr <= widx;                   // direccion de escritura (ch aun sin incrementar)
                rr_din  <= rr_dout + rev_contrib;  // rr_dout = rram[widx] (viejo, leido via rd_addr en S_MIX)
                rr_we   <= 1'b1;                    // commit durante S_NEXT
                state   <= S_NEXT;
            end

            S_NEXT: begin
                if (ch == 3'd7) state <= S_DONE;
                else begin ch <= ch + 3'd1; state <= S_LOAD; end
            end

            S_DONE: begin  // Q16 -> entero (>>16), clamp del PCM (como MAME), y trim de PCM en vivo
                left  <= clip16($signed(accL[39:16]));
                right <= clip16($signed(accR[39:16]));
                if (regs[9'h12f][0]) reverb_pos <= reverb_pos + 13'd1;  // congela si chip OFF (ref: early return)
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
end

endmodule
