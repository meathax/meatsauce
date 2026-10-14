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
module k054539 #(
    parameter integer OUTPUT_WIDTH=16,
    parameter VOLSHIFT=0,
    // MAME Metamorphic Force applies title-specific per-channel gains:
    // chip 0 = 0.8 for ch0-3 and 1.8 for ch4-7; chip 1 = 0.8 all.
    // Q12 keeps these exact decimal ratios representable closely while
    // retaining deterministic integer arithmetic in the FPGA.
    parameter [15:0] GAIN_LO_Q12 = 16'd4096,
    parameter [15:0] GAIN_HI_Q12 = 16'd4096
) (
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
    output reg signed [OUTPUT_WIDTH-1:0] left,
    output reg signed [OUTPUT_WIDTH-1:0] right,

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
// K054539 0x227 (module 0x127) programs a real periodic timer:
//   callback period = 1 / (2*(38+data)*(clock/384/14400)), MAME
//   k054539.cpp:421-429 (call_timer_handler at k054539.cpp:309-313).
// The timer free-runs once armed by a write to 0x227; every period it
// toggles m_timer_state, but ONLY notifies/toggles while 0x22f bit5 is set
// (k054539.cpp:311). timeout mirrors that toggling state directly -- NOT
// the PCM sample-rate tick -- so the downstream edge detector (jtframe_edge)
// sees the real programmable-rate square wave.
assign timeout = timer_state;
// Sticky diagnostic: a late sample must remain observable rather than being
// mistaken for an accepted stream with fixed-rate repeated output.
assign st_dout = {7'd0, sample_deadline_miss};

// ---------------------------------------------------------------------------
// Tablas de volumen/pan (Q16) — mismas que k054539_ref.cpp modo FIXED.
// ---------------------------------------------------------------------------
reg [15:0] voltab [0:255];   // <= 0x4000
reg [16:0] pantab [0:15];    // <= 0x10000
initial begin
    // Project-owned paths keep simulation and Quartus initialization tied to
    // this core rather than the donor checkout's working directory.
    $readmemh("cores/viostorm/hdl/voltab.hex", voltab);
    $readmemh("cores/viostorm/hdl/pantab.hex", pantab);
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
    S_REVRD= 4'd10, S_RVWR = 4'd11,
    S_GAIN_BASE = 4'd12, S_GAIN_VOL = 4'd13;   // reverb: lee feedback @revpos ; RMW del canal @widx

reg [3:0]  state;
reg [8:0]  sample_cnt;
reg signed [OUTPUT_WIDTH-1:0] sample_left, sample_right;
reg sample_ready, sample_started;
// Quartus preserve prevents register merging/removal; noprune retains this
// diagnostic even in a build whose outer debug mux does not consume it.
(* preserve, noprune *) reg sample_deadline_miss;
reg [2:0]  ch;

// ---------------------------------------------------------------------------
// MAME k054539.cpp:422 first rounds Hz through IEEE single precision.
// Use that exact frequency (table below) with retained fractional carry on
// every genuine chip cen. Denominator=18432000*2^17; increment=2*Hz*2^17.
// The callback edge rounds UP by <1 CE after accepted write, never to a PCM
// sample boundary. MAME's final attotime truncation is separately bounded.
reg [41:0] timer_cnt;
reg        timer_state;
reg        timer_armed;
reg [27:0] timer_add;
localparam [41:0] TIMER_THRESH = 42'd2415919104000;
wire [42:0] timer_sum = {1'b0,timer_cnt} + {15'd0,timer_add};

// Exact IEEE-single MAME frequency table generated from the native primary
// expression, all256 data values, Q17 verified from actual exponent/bits.
// No runtime floating-point, multiply or divide. Synthesis implementation
// (logic versus ROM) and resource/timing effects require fresh qualification.
function [27:0] timer_rate(input [7:0] data);
    begin
        case (data)
            8'd0: timer_rate = 28'd33204906;
            8'd1: timer_rate = 28'd34078720;
            8'd2: timer_rate = 28'd34952532;
            8'd3: timer_rate = 28'd35826344;
            8'd4: timer_rate = 28'd36700160;
            8'd5: timer_rate = 28'd37573972;
            8'd6: timer_rate = 28'd38447784;
            8'd7: timer_rate = 28'd39321600;
            8'd8: timer_rate = 28'd40195412;
            8'd9: timer_rate = 28'd41069224;
            8'd10: timer_rate = 28'd41943040;
            8'd11: timer_rate = 28'd42816852;
            8'd12: timer_rate = 28'd43690664;
            8'd13: timer_rate = 28'd44564480;
            8'd14: timer_rate = 28'd45438292;
            8'd15: timer_rate = 28'd46312104;
            8'd16: timer_rate = 28'd47185920;
            8'd17: timer_rate = 28'd48059732;
            8'd18: timer_rate = 28'd48933544;
            8'd19: timer_rate = 28'd49807360;
            8'd20: timer_rate = 28'd50681172;
            8'd21: timer_rate = 28'd51554984;
            8'd22: timer_rate = 28'd52428800;
            8'd23: timer_rate = 28'd53302612;
            8'd24: timer_rate = 28'd54176424;
            8'd25: timer_rate = 28'd55050240;
            8'd26: timer_rate = 28'd55924052;
            8'd27: timer_rate = 28'd56797864;
            8'd28: timer_rate = 28'd57671680;
            8'd29: timer_rate = 28'd58545492;
            8'd30: timer_rate = 28'd59419304;
            8'd31: timer_rate = 28'd60293120;
            8'd32: timer_rate = 28'd61166932;
            8'd33: timer_rate = 28'd62040744;
            8'd34: timer_rate = 28'd62914560;
            8'd35: timer_rate = 28'd63788372;
            8'd36: timer_rate = 28'd64662184;
            8'd37: timer_rate = 28'd65536000;
            8'd38: timer_rate = 28'd66409812;
            8'd39: timer_rate = 28'd67283624;
            8'd40: timer_rate = 28'd68157440;
            8'd41: timer_rate = 28'd69031248;
            8'd42: timer_rate = 28'd69905064;
            8'd43: timer_rate = 28'd70778880;
            8'd44: timer_rate = 28'd71652688;
            8'd45: timer_rate = 28'd72526504;
            8'd46: timer_rate = 28'd73400320;
            8'd47: timer_rate = 28'd74274128;
            8'd48: timer_rate = 28'd75147944;
            8'd49: timer_rate = 28'd76021760;
            8'd50: timer_rate = 28'd76895568;
            8'd51: timer_rate = 28'd77769384;
            8'd52: timer_rate = 28'd78643200;
            8'd53: timer_rate = 28'd79517008;
            8'd54: timer_rate = 28'd80390824;
            8'd55: timer_rate = 28'd81264640;
            8'd56: timer_rate = 28'd82138448;
            8'd57: timer_rate = 28'd83012264;
            8'd58: timer_rate = 28'd83886080;
            8'd59: timer_rate = 28'd84759888;
            8'd60: timer_rate = 28'd85633704;
            8'd61: timer_rate = 28'd86507520;
            8'd62: timer_rate = 28'd87381328;
            8'd63: timer_rate = 28'd88255144;
            8'd64: timer_rate = 28'd89128960;
            8'd65: timer_rate = 28'd90002768;
            8'd66: timer_rate = 28'd90876584;
            8'd67: timer_rate = 28'd91750400;
            8'd68: timer_rate = 28'd92624208;
            8'd69: timer_rate = 28'd93498024;
            8'd70: timer_rate = 28'd94371840;
            8'd71: timer_rate = 28'd95245648;
            8'd72: timer_rate = 28'd96119464;
            8'd73: timer_rate = 28'd96993280;
            8'd74: timer_rate = 28'd97867088;
            8'd75: timer_rate = 28'd98740904;
            8'd76: timer_rate = 28'd99614720;
            8'd77: timer_rate = 28'd100488528;
            8'd78: timer_rate = 28'd101362344;
            8'd79: timer_rate = 28'd102236160;
            8'd80: timer_rate = 28'd103109968;
            8'd81: timer_rate = 28'd103983784;
            8'd82: timer_rate = 28'd104857600;
            8'd83: timer_rate = 28'd105731408;
            8'd84: timer_rate = 28'd106605224;
            8'd85: timer_rate = 28'd107479040;
            8'd86: timer_rate = 28'd108352848;
            8'd87: timer_rate = 28'd109226664;
            8'd88: timer_rate = 28'd110100480;
            8'd89: timer_rate = 28'd110974288;
            8'd90: timer_rate = 28'd111848104;
            8'd91: timer_rate = 28'd112721920;
            8'd92: timer_rate = 28'd113595728;
            8'd93: timer_rate = 28'd114469544;
            8'd94: timer_rate = 28'd115343360;
            8'd95: timer_rate = 28'd116217168;
            8'd96: timer_rate = 28'd117090984;
            8'd97: timer_rate = 28'd117964800;
            8'd98: timer_rate = 28'd118838608;
            8'd99: timer_rate = 28'd119712424;
            8'd100: timer_rate = 28'd120586240;
            8'd101: timer_rate = 28'd121460048;
            8'd102: timer_rate = 28'd122333864;
            8'd103: timer_rate = 28'd123207680;
            8'd104: timer_rate = 28'd124081488;
            8'd105: timer_rate = 28'd124955304;
            8'd106: timer_rate = 28'd125829120;
            8'd107: timer_rate = 28'd126702928;
            8'd108: timer_rate = 28'd127576744;
            8'd109: timer_rate = 28'd128450560;
            8'd110: timer_rate = 28'd129324368;
            8'd111: timer_rate = 28'd130198184;
            8'd112: timer_rate = 28'd131072000;
            8'd113: timer_rate = 28'd131945808;
            8'd114: timer_rate = 28'd132819624;
            8'd115: timer_rate = 28'd133693440;
            8'd116: timer_rate = 28'd134567248;
            8'd117: timer_rate = 28'd135441056;
            8'd118: timer_rate = 28'd136314880;
            8'd119: timer_rate = 28'd137188688;
            8'd120: timer_rate = 28'd138062496;
            8'd121: timer_rate = 28'd138936320;
            8'd122: timer_rate = 28'd139810128;
            8'd123: timer_rate = 28'd140683936;
            8'd124: timer_rate = 28'd141557760;
            8'd125: timer_rate = 28'd142431568;
            8'd126: timer_rate = 28'd143305376;
            8'd127: timer_rate = 28'd144179200;
            8'd128: timer_rate = 28'd145053008;
            8'd129: timer_rate = 28'd145926816;
            8'd130: timer_rate = 28'd146800640;
            8'd131: timer_rate = 28'd147674448;
            8'd132: timer_rate = 28'd148548256;
            8'd133: timer_rate = 28'd149422080;
            8'd134: timer_rate = 28'd150295888;
            8'd135: timer_rate = 28'd151169696;
            8'd136: timer_rate = 28'd152043520;
            8'd137: timer_rate = 28'd152917328;
            8'd138: timer_rate = 28'd153791136;
            8'd139: timer_rate = 28'd154664960;
            8'd140: timer_rate = 28'd155538768;
            8'd141: timer_rate = 28'd156412576;
            8'd142: timer_rate = 28'd157286400;
            8'd143: timer_rate = 28'd158160208;
            8'd144: timer_rate = 28'd159034016;
            8'd145: timer_rate = 28'd159907840;
            8'd146: timer_rate = 28'd160781648;
            8'd147: timer_rate = 28'd161655456;
            8'd148: timer_rate = 28'd162529280;
            8'd149: timer_rate = 28'd163403088;
            8'd150: timer_rate = 28'd164276896;
            8'd151: timer_rate = 28'd165150720;
            8'd152: timer_rate = 28'd166024528;
            8'd153: timer_rate = 28'd166898336;
            8'd154: timer_rate = 28'd167772160;
            8'd155: timer_rate = 28'd168645968;
            8'd156: timer_rate = 28'd169519776;
            8'd157: timer_rate = 28'd170393600;
            8'd158: timer_rate = 28'd171267408;
            8'd159: timer_rate = 28'd172141216;
            8'd160: timer_rate = 28'd173015040;
            8'd161: timer_rate = 28'd173888848;
            8'd162: timer_rate = 28'd174762656;
            8'd163: timer_rate = 28'd175636480;
            8'd164: timer_rate = 28'd176510288;
            8'd165: timer_rate = 28'd177384096;
            8'd166: timer_rate = 28'd178257920;
            8'd167: timer_rate = 28'd179131728;
            8'd168: timer_rate = 28'd180005536;
            8'd169: timer_rate = 28'd180879360;
            8'd170: timer_rate = 28'd181753168;
            8'd171: timer_rate = 28'd182626976;
            8'd172: timer_rate = 28'd183500800;
            8'd173: timer_rate = 28'd184374608;
            8'd174: timer_rate = 28'd185248416;
            8'd175: timer_rate = 28'd186122240;
            8'd176: timer_rate = 28'd186996048;
            8'd177: timer_rate = 28'd187869856;
            8'd178: timer_rate = 28'd188743680;
            8'd179: timer_rate = 28'd189617488;
            8'd180: timer_rate = 28'd190491296;
            8'd181: timer_rate = 28'd191365120;
            8'd182: timer_rate = 28'd192238928;
            8'd183: timer_rate = 28'd193112736;
            8'd184: timer_rate = 28'd193986560;
            8'd185: timer_rate = 28'd194860368;
            8'd186: timer_rate = 28'd195734176;
            8'd187: timer_rate = 28'd196608000;
            8'd188: timer_rate = 28'd197481808;
            8'd189: timer_rate = 28'd198355616;
            8'd190: timer_rate = 28'd199229440;
            8'd191: timer_rate = 28'd200103248;
            8'd192: timer_rate = 28'd200977056;
            8'd193: timer_rate = 28'd201850880;
            8'd194: timer_rate = 28'd202724688;
            8'd195: timer_rate = 28'd203598496;
            8'd196: timer_rate = 28'd204472320;
            8'd197: timer_rate = 28'd205346128;
            8'd198: timer_rate = 28'd206219936;
            8'd199: timer_rate = 28'd207093760;
            8'd200: timer_rate = 28'd207967568;
            8'd201: timer_rate = 28'd208841376;
            8'd202: timer_rate = 28'd209715200;
            8'd203: timer_rate = 28'd210589008;
            8'd204: timer_rate = 28'd211462816;
            8'd205: timer_rate = 28'd212336640;
            8'd206: timer_rate = 28'd213210448;
            8'd207: timer_rate = 28'd214084256;
            8'd208: timer_rate = 28'd214958080;
            8'd209: timer_rate = 28'd215831888;
            8'd210: timer_rate = 28'd216705696;
            8'd211: timer_rate = 28'd217579520;
            8'd212: timer_rate = 28'd218453328;
            8'd213: timer_rate = 28'd219327136;
            8'd214: timer_rate = 28'd220200960;
            8'd215: timer_rate = 28'd221074768;
            8'd216: timer_rate = 28'd221948576;
            8'd217: timer_rate = 28'd222822400;
            8'd218: timer_rate = 28'd223696208;
            8'd219: timer_rate = 28'd224570016;
            8'd220: timer_rate = 28'd225443840;
            8'd221: timer_rate = 28'd226317648;
            8'd222: timer_rate = 28'd227191456;
            8'd223: timer_rate = 28'd228065280;
            8'd224: timer_rate = 28'd228939088;
            8'd225: timer_rate = 28'd229812896;
            8'd226: timer_rate = 28'd230686720;
            8'd227: timer_rate = 28'd231560528;
            8'd228: timer_rate = 28'd232434336;
            8'd229: timer_rate = 28'd233308160;
            8'd230: timer_rate = 28'd234181968;
            8'd231: timer_rate = 28'd235055776;
            8'd232: timer_rate = 28'd235929600;
            8'd233: timer_rate = 28'd236803408;
            8'd234: timer_rate = 28'd237677216;
            8'd235: timer_rate = 28'd238551040;
            8'd236: timer_rate = 28'd239424848;
            8'd237: timer_rate = 28'd240298656;
            8'd238: timer_rate = 28'd241172480;
            8'd239: timer_rate = 28'd242046288;
            8'd240: timer_rate = 28'd242920096;
            8'd241: timer_rate = 28'd243793920;
            8'd242: timer_rate = 28'd244667728;
            8'd243: timer_rate = 28'd245541536;
            8'd244: timer_rate = 28'd246415360;
            8'd245: timer_rate = 28'd247289168;
            8'd246: timer_rate = 28'd248162976;
            8'd247: timer_rate = 28'd249036800;
            8'd248: timer_rate = 28'd249910608;
            8'd249: timer_rate = 28'd250784416;
            8'd250: timer_rate = 28'd251658240;
            8'd251: timer_rate = 28'd252532048;
            8'd252: timer_rate = 28'd253405856;
            8'd253: timer_rate = 28'd254279680;
            8'd254: timer_rate = 28'd255153488;
            8'd255: timer_rate = 28'd256027296;
        endcase
    end
endfunction

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
    .SIMHEXFILE_LO( "cores/viostorm/hdl/rram_zero.hex" ),
    .SIMHEXFILE_HI( "cores/viostorm/hdl/rram_zero.hex" ),
    .SYNFILE_LO  ( "cores/viostorm/hdl/rram_zero.hex" ),
    .SYNFILE_HI  ( "cores/viostorm/hdl/rram_zero.hex" )
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
    .SIMHEXFILE_LO( "cores/viostorm/hdl/rram_zero.hex" ),
    .SIMHEXFILE_HI( "cores/viostorm/hdl/rram_zero.hex" ),
    .SYNFILE_LO  ( "cores/viostorm/hdl/rram_zero.hex" ),
    .SYNFILE_HI  ( "cores/viostorm/hdl/rram_zero.hex" )
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
wire [15:0] gain_q12 = ch[2] ? GAIN_HI_Q12 : GAIN_LO_Q12;
// Break the three-level table * pan * per-title gain * sample chain.
 // Valid only while an active voice advances through S_GAIN_BASE and S_GAIN_VOL.
 // The same fixed-point widths, shifts, rounding and clamp are preserved.
reg [33:0] lbase_q, rbase_q;
reg [16:0] lvol_q, rvol_q;
wire [33:0] lbase = vt * pl;
wire [33:0] rbase = vt * pr;
wire [49:0] lgain_full = lbase_q * gain_q12;
wire [49:0] rgain_full = rbase_q * gain_q12;
wire [16:0] lvol = lful_clamp(lgain_full[44:28]);
wire [16:0] rvol = lful_clamp(rgain_full[44:28]);
function [16:0] lful_clamp(input [16:0] v);
    lful_clamp = (v > 17'h1CCCC) ? 17'h1CCCC : v;   // VOL_CAP=1.8 en Q16
endfunction

// contribucion del canal en Q16 (SIN truncar): w_val * vol. Se acumula asi y se redondea al final.
wire signed [33:0] cprodL = $signed(w_val) * $signed({1'b0, lvol_q});
wire signed [33:0] cprodR = $signed(w_val) * $signed({1'b0, rvol_q});
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
wire [31:0] rb_gain_full = voltab[bval] * gain_q12;
wire [16:0] rbvol = lful_clamp(rb_gain_full[28:12] >> 1);
wire signed [33:0] rprod = $signed(w_val) * $signed({1'b0, rbvol});
wire signed [15:0] rev_contrib = rprod[31:16];                   // (>>16) truncado a int16

// direcciones base del canal
wire [8:0] b1 = {1'b0, ch, 5'b0};            // 0x20*ch
wire [8:0] b2 = 9'h100 + {5'b0, ch, 1'b0};   // 0x100 + 2*ch
wire [23:0] delta_now = {regs[b1+9'd2], regs[b1+9'd1], regs[b1+9'd0]};
wire signed [31:0] delta_signed = regs[b2][5] ?
                                   -$signed({8'b0,delta_now}) :
                                    $signed({8'b0,delta_now});
// MAME k054539.cpp:195 switches explicitly on base2[0]&0xc: 0x0/0x4/0x8 are
// the three known formats; 0xc (and any other value, but only 0xc is
// reachable from these two bits) falls to `default:` at k054539.cpp:281-283,
// which performs no ROM read and no position advance -- the channel idles.
// type_now==2'd3 encodes that no-op case; see S_LOAD/S_MIX below.
wire [1:0]  type_now  = (regs[b2] & 8'h0c)==8'h00 ? 2'd0 :
                        (regs[b2] & 8'h0c)==8'h04 ? 2'd1 :
                        (regs[b2] & 8'h0c)==8'h08 ? 2'd2 : 2'd3;

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
             (v < -24'sd32768) ? 16'sh8000 : v[15:0];
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
        sample_left <= 0; sample_right <= 0;
        sample_ready <= 0; sample_started <= 0; sample_deadline_miss <= 0;
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
        timer_cnt <= 42'd0; timer_add <= 28'd0; timer_state <= 1'b0; timer_armed <= 1'b0;   // K054539 0x227 timer
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
                // edge of its decoded active-low write strobe. D7 is
                // transparent above and gates register updates, matching MAME;
                // D2/D3/D6 remain unimplemented.
                9'h12f: begin
                    regs[9'h12f][0] <= cpu_write_data[0];
                    regs[9'h12f][1] <= cpu_write_data[1];
                    regs[9'h12f][4] <= cpu_write_data[4];
                    regs[9'h12f][5] <= cpu_write_data[5];
                    // MAME k054539.cpp:444-448: disabling the timer output
                    // (bit5 low) forces m_timer_state back to 0 immediately.
                    if (!cpu_write_data[5]) timer_state <= 1'b0;
                end
                // MAME k054539.cpp:421-429 (0x227): every write reprograms
                // the period and resets the toggle state/phase, regardless
                // of the 0x22f bit5 enable.
                9'h127: begin
                    timer_cnt   <= 42'd0;
                    timer_add   <= timer_rate(cpu_write_data);
                    timer_state <= 1'b0;
                    timer_armed <= 1'b1;
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
            // Publish the preceding frame atomically at the fixed sample
            // boundary. Serial ROM service affects completion time, not the
            // DAC edge. This adds exactly one sample period of latency.
            if (sample_cnt == 9'd0) begin
                if (sample_ready) begin
                    left <= sample_left;
                    right <= sample_right;
                end
                if (sample_started && (!sample_ready || state != S_IDLE))
                    sample_deadline_miss <= 1'b1;
                sample_ready <= 1'b0;
                sample_started <= 1'b1;
            end
            // Hold an unacknowledged byte request across PCM enables.  The
            // playback states already wait for rom_ok; pausing the entire
            // chip clock here would also slow its sample divider and timer.
            if (!sample_rom_cs || rom_ok) sample_rom_cs <= 1'b0;
            rr_we  <= 1'b0;   // por defecto sin escritura de reverb (patron rom_cs)

            // Chip-clock fractional recurrence; accepted restart and disable
            // retain priority over a callback on the same clock edge.
            if (timer_armed &&
                !(cpu_write_commit && cpu_write_addr == 9'h127)) begin
                if (timer_sum >= {1'b0, TIMER_THRESH}) begin
                    timer_cnt <= timer_sum[41:0] - TIMER_THRESH;
                    if (regs[9'h12f][5] &&
                        !(cpu_write_commit && cpu_write_addr == 9'h12f && !cpu_write_data[5]))
                        timer_state <= ~timer_state;
                end else begin
                    timer_cnt <= timer_sum[41:0];
                end
            end

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
                        end else if (type_now == 2'd3) begin
                            // MAME default branch (sample type 0xc): the
                            // switch body never runs, so `cur_pfrac += delta`
                            // never executes and cur_pos/cur_val are left
                            // untouched -- freeze position and value, do not
                            // accumulate delta into the fraction.
                            w_pos   <= {1'b0, cpos[ch]};
                            w_pfrac <= $signed({16'b0, cpfrac[ch]});
                            w_val   <= cval[ch]; w_pval <= cpval[ch];
                        end else begin
                            w_pos   <= {1'b0, cpos[ch]};
                            w_pfrac <= $signed({16'b0, cpfrac[ch]}) + delta_signed;
                            w_val   <= cval[ch]; w_pval <= cpval[ch];
                        end
                    end
                    // type 0xc (2'd3) never fetches ROM data or advances
                    // position: go straight to the mix/writeback step.
                    state <= S_GAIN_BASE;
                end
            end

            // The volume+pan and title gain are combinationally identical to
            // the former one-cycle path. They are now distributed over two
            // otherwise unused 48 MHz clocks per active PCM channel.
            S_GAIN_BASE: begin
                lbase_q <= lbase;
                rbase_q <= rbase;
                state <= S_GAIN_VOL;
            end
            S_GAIN_VOL: begin
                lvol_q <= lvol;
                rvol_q <= rvol;
                state <= (w_type == 2'd3) ? S_MIX : S_ACC;
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
                sample_left  <= clip_output($signed(accL[39:16]));
                sample_right <= clip_output($signed(accR[39:16]));
                sample_ready <= 1'b1;
                if (regs[9'h12f][0]) reverb_pos <= reverb_pos + 13'd1;  // congela si chip OFF (ref: early return)
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
end


// MAME put_int is signed32 -> float without clipping. Keep release headroom
// until the shared speaker gain; OUTPUT_WIDTH=16 preserves the debug boundary.
function signed [OUTPUT_WIDTH-1:0] clip_output(input signed [23:0] v);
    reg signed [23:0] maximum,minimum;
    begin
        maximum=(24'sd1 << (OUTPUT_WIDTH-1))-24'sd1;
        minimum=-(24'sd1 << (OUTPUT_WIDTH-1));
        clip_output=v>maximum ? maximum[OUTPUT_WIDTH-1:0] :
                    v<minimum ? minimum[OUTPUT_WIDTH-1:0] : v[OUTPUT_WIDTH-1:0];
    end
endfunction

endmodule
