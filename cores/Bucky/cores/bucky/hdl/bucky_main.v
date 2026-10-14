/*  This file is part of JTCORES.
    JTCORES program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCORES program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCORES.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 7-7-2024

    FASE 1 (sesion 5, 2026-07-16): reescrito partiendo del mapa de moomesa (moo.cpp
    moo_prot_state::moo_map) pero AJUSTADO al mapa REAL de bucky_map (moo.cpp:615-649),
    que usa direcciones distintas para casi todas las regiones (programa, RAM de trabajo,
    RAM de sprites, VRAM de tiles, readback de ROM de tiles y paleta - ver la tabla
    comparativa en el HANDOFF del audit de donante). Antes heredaba el decode PAL de
    X-Men (mapa distinto). Referencias: research/moo.cpp 615-649 (bucky_map), 393-482
    (control2/IRQ), 662-714 (puertos). IRQ = patron simson/vendetta (jtframe_edge)
    mapeado a IRQ5/IRQ4. El motor de proteccion (moo_prot_w) SI es compartido bit a bit
    entre moo_map y bucky_map (moo.cpp:564,626) - implementarlo desde el donante fue
    correcto, no un residuo.
*/

`ifndef BUCKY_TEST_PLUSARGS
`ifdef SYNTHESIS
`define BUCKY_TEST_PLUSARGS(arg) 1'b0
`else
`define BUCKY_TEST_PLUSARGS(arg) $test$plusargs(arg)
`endif
`endif

module bucky_main(
    input                rst,
    input                clk, // 48 MHz
    input                LVBL,

    output        [21:1] main_addr,   // 21 bits de byte: la region maincpu son 0x180000 B (ver mem.yaml)
    output        [ 1:0] ram_dsn,
    output        [15:0] cpu_dout,
    // 8-bit interface
    output               cpu_we,
    output reg           pal_cs,
    output reg           pcu_cs,
    // Sound interface
    output               pair_we,   // K054321 (some latches)
    input         [ 7:0] pair_dout, // K054321 (X-Men)
    output               snd_wrn,   // K053260 (PCM sound)
    input         [ 7:0] snd2main,  // K053260 (PCM sound)
    output reg           sndon,     // irq trigger
    output reg           mute,

    output reg           rom_cs,
    output reg           ram_cs,
    output reg           vram_cs,
    output reg           tilereg_cs,    // K056832 main regs 0x0c0000
    output reg           tilereg_b_cs,  // K056832 VSCCS regs 0x0d8000
    output reg           ccu_cs,       // K053252 CCU window 0x0d0000
    output reg           romrd_cs,     // K056832 tile-ROM readback 0x190000
    output reg           alpha_cs,    // K054338 regs 0x0ca000
    output reg           obj_cs,

    input         [15:0] oram_dout,
    input         [15:0] vram_dout,
    input         [15:0] pal_dout,
    input         [15:0] alpha_dout,
    input         [ 7:0] pcu_dout,
    input         [ 7:0] ccu_dout,
    input         [15:0] ram_dout,
    input         [15:0] rom_data,
    input         [15:0] romrd_dout,
    input                ram_ok,
    input                rom_ok,
    input                romrd_ok,
    input                vdtac,
    input                pal_wait,
    input                tile_irqn,

    // video configuration
    output reg           objreg_cs,
    output reg           objcha_n,
    output reg           rmrd,
    input                dma_bsy,
    // EEPROM
    output      [ 6:0]   nv_addr,
    input       [ 7:0]   nv_dout,
    output      [ 7:0]   nv_din,
    output               nv_we,
    // Cabinet
    input         [ 6:0] joystick1,
    input         [ 6:0] joystick2,
    input         [ 6:0] joystick3,
    input         [ 6:0] joystick4,
    input         [ 3:0] cab_1p,
    input         [ 3:0] coin,
    input         [ 3:0] service,
    input                dip_pause,
    input                dip_test,
    input         [31:0] dipsw,
    output        [ 7:0] st_dout,
    input         [ 7:0] debug_bus
);
`ifndef NOMAIN
wire [23:1] A;
wire        cpu_cen, cpu_cenb;
wire        UDSn, LDSn, RnW, ASn, VPAn, DTACKn;
wire [ 2:0] FC;
reg  [ 2:0] IPLn;
reg  [15:0] cpu_din;
reg  [15:0] cur_control2;   // 0x0de000 (moo.cpp control2_w)
wire        eep_rdy, eep_do, bus_cs, bus_busy, BUSn;
wire        dtac_mux, iack;
wire [15:0] cpu_dout_68k;   // dato del 68k ANTES del mux del blitter (ver moo_prot, Fase 4)

// --- bus efectivo: el blitter moo_prot es BUS MASTER y suplanta al 68k mientras opera ---
wire [23:1] blt_addr;
wire [15:0] blt_dout;
wire        blt_busy, blt_we, blt_stb, blt_stall;
wire [23:1] eff_addr = blt_busy ? blt_addr :  A;
wire        eff_asn  = blt_busy ? ~blt_stb : ASn;
wire        eff_busn = blt_busy ? ~blt_stb : BUSn;
wire        eff_we   = blt_busy ?  blt_we  : ~RnW;
wire [ 1:0] eff_dsn  = blt_busy ? 2'b00    : {UDSn,LDSn};

// I/O sub-selects (0x0c0000-0x0dffff region)
reg  io_cs, collision_cs, sndirq_cs, pair_cs,
     in0_cs, in1_cs, p1p3_cs, p2p4_cs, control2_cs, prot_cs;
reg  [15:0] port_in;

`ifdef SIMULATION
wire [23:0] A_full = {A,1'b0};
`endif
/* verilator tracing_off */
assign main_addr= eff_addr[21:1];
assign ram_dsn  = eff_dsn;
// El generador de DTACK solo debe ver los accesos DEL 68k: los del blitter se le ocultan
// (~blt_busy), o su recovery contaria ciclos de bus que la CPU no ha pedido.
assign bus_cs   = (rom_cs | ram_cs | romrd_cs) & ~blt_busy;
assign bus_busy = ((rom_cs & ~rom_ok) | (ram_cs & ~ram_ok) |
                   (romrd_cs & ~romrd_ok)) & ~blt_busy;
assign BUSn     = ASn | (LDSn & UDSn);
assign cpu_we   = eff_we;
assign cpu_dout = blt_busy ? blt_dout : cpu_dout_68k;
assign st_dout  = { rmrd, cur_control2[11], cur_control2[5], objcha_n, 4'd0 };
// 6800-style autovector during interrupt acknowledge (FC==7 CPU space)
assign VPAn     = ~(&FC & ~ASn);
assign iack     =  &FC & ~ASn;
// blt_stall estanca al 68k DENTRO del propio ciclo de escritura del trigger (0x0ce018): la CPU
// no completa el ciclo hasta que el blitter termina, igual que el chip real (que retiene el bus).
assign dtac_mux = DTACKn | ~vdtac | blt_stall | pal_wait;
// K054321 sound latch write (0x0d6000): LDS byte access
assign pair_we  = pair_cs & ~RnW & ~LDSn;
// K053260/PCM read strobe (unused path in moomesa reuse; keep inactive)
assign snd_wrn  = ~(sndirq_cs & ~RnW);

// ---------------- Bucky O'Hare address decode (moo_prot_state::bucky_map) ----------------
// CPU byte map: program 000000-07ffff, work RAM 080000-08ffff, sprite RAM 090000-09ffff,
// extra RAM 0a0000-0affff, I/O 0c0000-0dffff, tile VRAM 180000-183fff,
// tile ROM readback 190000-191fff, palette 1b0000-1b3fff, data ROM 200000-23ffff.
`ifdef SIMULATION
reg none_cs;
wire sim_diag = `BUCKY_TEST_PLUSARGS("DIAG");
`endif
always @* begin
    rom_cs      = 0; ram_cs   = 0; obj_cs   = 0; vram_cs  = 0; pal_cs  = 0;
    tilereg_cs  = 0; tilereg_b_cs = 0; alpha_cs = 0; pcu_cs = 0; objreg_cs = 0;
    prot_cs     = 0; ccu_cs   = 0; collision_cs = 0; sndirq_cs= 0; pair_cs  = 0;
    romrd_cs    = 0; in0_cs   = 0; in1_cs  = 0; p1p3_cs = 0; p2p4_cs = 0;
    control2_cs = 0; io_cs    = 0;
    if( !eff_asn ) begin
        rom_cs  = (eff_addr[23:19]==5'b00000) ||
                  ((eff_addr[23:18]==6'b001000) && !eff_busn); // 000000-07ffff, 200000-23ffff
        // The SDRAM RAM port is 128 KiB: main_addr[17] selects 080000 vs 0a0000 in jtbucky_game.
        ram_cs  = ((eff_addr[23:16]==8'h08) || (eff_addr[23:16]==8'h0a) ||
                   (eff_addr[23:14]==10'h061)) & ~eff_busn; // includes 184000-187fff
        obj_cs  = (eff_addr[23:16]==8'h09);
        vram_cs = (eff_addr[23:14]==10'b00_0110_0000);          // 180000-183fff, mirror included
        romrd_cs= (eff_addr[23:13]==11'b000_1100_1000) & ~blt_busy; // 190000-191fff
        pal_cs  = (eff_addr[23:14]==10'b00_0110_1100);          // 1b0000-1b3fff, 4096 xRGB888
        // Exact custom-chip windows. The inherited nibble decode aliased every
        // device across an 8 KiB slot, which is not GX173 open-bus behavior.
        io_cs         = (eff_addr[23:17]==7'b0000_110); // 0c0000-0dffff
        tilereg_cs    = (eff_addr[23: 6]==18'h03000);
        objreg_cs     = (eff_addr[23: 3]==21'h18400) |
                        (eff_addr[23: 1]==23'h62000);
        alpha_cs      = (eff_addr[23: 5]==19'h06500);
        pcu_cs        = (eff_addr[23: 5]==19'h06600);
        prot_cs       = (eff_addr[23: 5]==19'h06700);
        ccu_cs        = (eff_addr[23: 5]==19'h06800);
        collision_cs  = (eff_addr[23: 6]==18'h03480);
        sndirq_cs     = (eff_addr[23: 1]==23'h6a000);
        pair_cs       = (eff_addr[23: 5]==19'h06b00);
        tilereg_b_cs  = (eff_addr[23: 3]==21'h1b000);
        p1p3_cs       = (eff_addr[23: 1]==23'h6d000);
        p2p4_cs       = (eff_addr[23: 1]==23'h6d001);
        in0_cs        = (eff_addr[23: 1]==23'h6e000);
        in1_cs        = (eff_addr[23: 1]==23'h6e001);
        control2_cs   = (eff_addr[23: 1]==23'h6f000);
    end
`ifdef SIMULATION
    none_cs = ~eff_busn & ~|{ rom_cs, ram_cs, obj_cs, vram_cs, pal_cs, romrd_cs,
        tilereg_cs, tilereg_b_cs, alpha_cs, pcu_cs, objreg_cs, prot_cs, ccu_cs,
        collision_cs, sndirq_cs, pair_cs, in0_cs, in1_cs, p1p3_cs, p2p4_cs,
        control2_cs };
`endif
end

wire [7:0] collision_dout;
bucky_k054000 u_collision(
    .clk  ( clk ),
    .cs   ( collision_cs & ~eff_dsn[0] ),
    .we   ( eff_we ),
    .addr ( eff_addr[5:1] ),
    .din  ( cpu_dout_68k[7:0] ),
    .dout ( collision_dout )
);
// K056832 regs: word_w (0x0c0000) and b_word_w (VSCCS 0x0d8000) both go to the tile system reg port.
// tilereg_cs (above) already carries 0x0c0000; the video reg decoder must also accept VSCCS if needed.

// ---------------- input ports ----------------
// ⚠ POLARIDAD (GOTCHAS §A3) — los bits de cabina Konami son ACTIVO-BAJO, y jtframe YA los entrega en
// ACTIVO-BAJO: van **DIRECTOS, SIN INVERTIR**. Evidencia (no suposicion):
//   · `jtframe_dip.v:87` -> `assign dip_test = ~status[10] & game_test; // assumes it is always active low`
//   · `jtframe_inputs.v:184` -> el puerto interno se llama **`coin_n`** (_n = activo bajo)
//   · el core hermano simson los usa CRUDOS: `port_in <= { dipsw[23:20], coin[1:0], dip_test, service }`
// El `~` que habia aqui dejaba IN1 bit3 (PORT_SERVICE_NO_TOGGLE, moo.cpp:677, ACTIVE_LOW) clavado a 0
// = **SERVICIO ACTIVO** -> el juego arrancaba en **MODO TEST** (por eso el POST hacia el test de 64KB
// de work RAM, el del N4 y el BORRADO DESTRUCTIVO del EEPROM), y ademas dejaba las MONEDAS metidas.
// JTFRAME_JOY_DURL is selected in macros.def.  Its output order is
// {B3,B2,B1,DOWN,UP,RIGHT,LEFT}, which is exactly KONAMI16_LSB's
// low-byte order when the start bit is added above: {START,B3,B2,B1,
// DOWN,UP,RIGHT,LEFT}.  Keep this explicit because a direct, un-reordered
// JTFRAME joystick would silently swap all four directions on the PCB map.
function [7:0] konami_player( input [6:0] joy, input start );
    konami_player = { start, joy[6:0] };
endfunction

// ---- DIPs de IN1: standard JTFRAME HPS index 254 path ---------------------
// JTFRAME exposes the MRA switch byte through dipsw[23:16].  The EAB default
// is 0xA (Stereo/Common/four players), but the live value must remain visible
// so the generated OSD and hardware configuration can change it.
always @(*) begin
    // MiSTer MRA switch byte is exposed as dipsw[23:16]; IN1 consumes its upper nibble.
    port_in = 16'hffff;
    if( p1p3_cs ) port_in = { konami_player(joystick3, cab_1p[2]), konami_player(joystick1, cab_1p[0]) };
    if( p2p4_cs ) port_in = { konami_player(joystick4, cab_1p[3]), konami_player(joystick2, cab_1p[1]) };
    // IN0 (moo.cpp:664-671): bit0-3 COIN1-4, bit4-7 SERVICE1-4 — todos ACTIVE_LOW
    if( in0_cs  ) port_in = { 8'hff, service[3:0], coin[3:0] };
    // IN1 (moo.cpp:674-687): bit0 eep_do, bit1 eep_rdy, bit2 unk(1), bit3 SERVICE (ACTIVE_LOW),
    // bit4 SndOut(0=Stereo), bit5 CoinMech(1=Common), bit7:6 Players(10=4).
    if( in1_cs  ) port_in = { 8'hff, dipsw[23:20], dip_test, 1'b1, eep_rdy, eep_do };
end

/* verilator tracing_off */
always @(posedge clk) begin
    cpu_din <= rom_cs     ? rom_data        :
               ram_cs     ? ram_dout        :
               obj_cs     ? oram_dout       :
               vram_cs    ? vram_dout       :  // ram_word_r: la VRAM del K056832 se lee en words
               pal_cs     ? pal_dout        :
               romrd_cs   ? romrd_dout       :
               alpha_cs   ? alpha_dout       :
               pcu_cs     ? {8'hff,pcu_dout} :
               ccu_cs     ? {8'hff,ccu_dout}  :
               collision_cs? {8'hff,collision_dout}:
               pair_cs    ? {8'hff,pair_dout}:
               control2_cs? cur_control2    :
               (p1p3_cs|p2p4_cs|in0_cs|in1_cs) ? port_in : 16'hffff;
end

// ---------------- control2 (0x0de000) + EEPROM ----------------
// moo.cpp control2_w: bit0 eep di, bit1 eep cs, bit2 eep clk, bit5 IRQ5 en, bit8 objcha (spr ROM read),
//                     bit10 watchdog, bit11 IRQ4 en. (control2 latched as a 16-bit register.)
wire eep_di  = cur_control2[0];
wire eep_cs  = cur_control2[1];
wire eep_clk = cur_control2[2];
wire irq5en  = cur_control2[5];
wire irq4en  = cur_control2[11];

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cur_control2 <= 0;
        objcha_n     <= 1;
        rmrd         <= 0;
        mute         <= 0;
    end else begin
        if( control2_cs & cpu_we ) begin
            if( !LDSn ) cur_control2[ 7:0] <= cpu_dout[ 7:0];
            if( !UDSn ) cur_control2[15:8] <= cpu_dout[15:8];
        end
        // objcha line (sprite ROM readback) = control2[8]
        objcha_n <= ~cur_control2[8];
        // rmrd: tile ROM passthrough active during a 0x190000 read (moo.cpp:639). 0x1b0000 is
        // Bucky's PALETTE (moo.cpp:640) - that was moomesa's tile-ROM address, not Bucky's.
        rmrd     <= romrd_cs;
        mute     <= 1'b0;   // moomesa has no explicit mute bit in control2
    end
end

// sound IRQ trigger: any write to 0x0d4000 pulses the Z80 IRQ (sound_irq_w -> HOLD_LINE)
always @(posedge clk, posedge rst) begin
    if( rst ) sndon <= 0;
    else      sndon <= sndirq_cs & cpu_we;
end

// ---------------- interrupts (IRQ5 vblank, IRQ4 dmaend) ----------------
// moo_interrupt: IRQ5 on vblank if control2[5]; IRQ4 (dmaend) if control2[11]. m68k autovector.
// jtframe_edge latches the request; cleared by the CPU's interrupt-ack cycle at that level.
wire irq5_edge = ~LVBL;      // enter vblank (LVBL high=active)
wire irq4_edge = ~dma_bsy;   // end of object DMA
wire irq5_q, irq4_q;
wire irq5_ack = iack & (A[3:1]==3'd5);
wire irq4_ack = iack & (A[3:1]==3'd4);

// QSET(1): q=1 (IRQ pending) on the edge, cleared to 0 by clr (disable or ack). Active-HIGH pending.
jtframe_edge #(.QSET(1)) u_irq5(
    .rst( rst ), .clk( clk ), .edgeof( irq5_edge ), .clr( ~irq5en | irq5_ack ), .q( irq5_q ));
jtframe_edge #(.QSET(1)) u_irq4(
    .rst( rst ), .clk( clk ), .edgeof( irq4_edge ), .clr( ~irq4en | irq4_ack ), .q( irq4_q ));

always @(posedge clk) begin
    // level 5 (IPLn=010) > level 4 (IPLn=011) > none (111).
    IPLn <= irq5_q ? 3'b010 :
            irq4_q ? 3'b011 : 3'b111;
end

// ================= moo_prot (053990): HLE del blitter — FASE 4 =================
// Spec EXACTA = research/moo.cpp:520-545 (moo_prot_state::moo_prot_w), autoridad validada.
//   protram[0..0xf] = 16 words en 0x0ce000-0x0ce01f (indice = A[4:1]).
//   Escribir el indice 0xc DISPARA:
//     src1={protram[1][7:0],protram[0]}  src2={protram[3][7:0],protram[2]}
//     dst ={protram[5][7:0],protram[4]}  length=protram[0xf]
//     while(length--) { *dst = *src1 + 2 * *src2; src1+=2; src2+=2; dst+=2; }
//   (protram[8..0xb] los escribe el juego pero MAME los IGNORA y funciona -> se ignoran aqui.)
//
// POR QUE ES REQUISITO DE ARRANQUE (medido, sesion 6): el POST programa y dispara el blitter en
// 0x49e7c..0x49edc y VERIFICA EL RESULTADO POR SOFTWARE en 0x49ee4..0x49f04. Sin blitter, dst
// sigue a 0 -> la verificacion falla -> rama de error -> "N4 DEVICE ERROR" -> address error ->
// cuelgue infinito en 0x1000. No es un extra posterior: sin esto el juego NO bootea.
//
// ⚠ TRAMPA DEL BUS (jtframe_ram_rq): "It requires addr_ok signal to toggle for each request" —
// solo lanza peticion en el FLANCO DE SUBIDA de cs, y mantiene data_ok mientras cs siga alto.
// El 68k estancado mantiene ASn/BUSn BAJOS todo el rato, asi que el blitter NO puede reusarlos:
// genera su PROPIO strobe (blt_stb) y BAJA cs entre accesos. Sin eso ram_ok se quedaria pegado a
// 1 del acceso anterior y el blitter leeria 255 veces el mismo word creyendo que va bien.
// (El propio jtframe_68kdtack lo dice: "DSn must also gate the SDRAM requests so you get a cs
// toggle in the middle of the read-modify-write cycles".)
localparam [2:0] BLT_IDLE=3'd0, BLT_RD1=3'd1, BLT_RD2=3'd2, BLT_WR=3'd3, BLT_STEP=3'd4,
                 BLT_VFY=3'd5;  // solo SIMULATION: relee dst[0] para probar que la escritura aterrizo

reg  [15:0] protram[0:15];
reg  [23:1] blt_src1, blt_src2, blt_dst, blt_addr_r;
reg  [15:0] blt_len, blt_a, blt_dout_r;
reg  [ 2:0] blt_st;
reg  [ 1:0] blt_wc;
reg         blt_busy_r, blt_we_r, blt_stb_r, blt_ph, blt_served;
integer     bi;

// direccion de byte de 24 bits (MAME) -> direccion de WORD [23:1]; +=2 bytes == +1 word
wire [23:0] blt_s1b = {protram[1][7:0], protram[0]};
wire [23:0] blt_s2b = {protram[3][7:0], protram[2]};
wire [23:0] blt_dsb = {protram[5][7:0], protram[4]};

// El trigger es COMBINACIONAL para que el estancamiento entre en el MISMO ciclo en que el 68k
// decodifica la escritura: si esperasemos un ciclo, DTACKn podria asertarse antes y la CPU
// completaria el ciclo mientras el blitter le muxea la direccion del bus bajo los pies.
// blt_served impide RE-disparar: al acabar el blitter el 68k sigue en el mismo ciclo de bus
// (prot_cs y cpu_we siguen activos) -> sin este latch el blitter se relanzaria para siempre.
wire blt_trig = prot_cs & eff_we & ~eff_busn & (eff_addr[4:1]==4'hc) & ~blt_served;
assign blt_stall = blt_busy_r | blt_trig;
assign blt_busy  = blt_busy_r;
assign blt_we    = blt_we_r;
assign blt_stb   = blt_stb_r;
assign blt_addr  = blt_addr_r;
assign blt_dout  = blt_dout_r;

// Destino del acceso ACTUAL del blitter (mismo decode que el principal). MAME hace los
// read_word/write_word a traves del mapa completo, por lo que el HLE debe distinguir las
// tres RAMs que realmente existen en GX173: work/extra RAM, K056832 VRAM y la paleta.
// El POST de Bucky usa precisamente el area 0x180000/0x181000; si se devolviera la paleta
// por defecto en ese camino, el N4 check podria fallar aunque el sumador fuese correcto.
wire blt_isram = (blt_addr_r[23:16]==8'h08) || (blt_addr_r[23:16]==8'h0a) ||
                 (blt_addr_r[23:14]==10'h061); // 0x184000-0x187fff extra tile RAM
// The GX173 protection engine can target the 0x090000 sprite source window.
// It is a synchronous on-core object RAM port (not the SDRAM work-RAM client),
// so reads use the object data return after the same bounded phase wait and
// writes are accepted by the normal objsys_cs/oram_we path.
wire blt_isobj = (blt_addr_r[23:16]==8'h09);
wire blt_isvram = (blt_addr_r[23:14]==10'h060); // 0x180000-0x183fff, incl. mirror
wire blt_ispal = (blt_addr_r[23:14]==10'h06c); // 0x1b0000-0x1b3fff, 4096 entries
wire blt_isrom = (blt_addr_r[23:19]==5'b00000) || (blt_addr_r[23:18]==6'b001000);
wire [15:0] blt_rdata = blt_isram ? ram_dout : blt_isobj ? oram_dout : blt_isvram ? vram_dout :
                        blt_isrom ? rom_data : blt_ispal ? pal_dout : 16'hffff;
// SDRAM: handshake real (ram_ok/rom_ok). Paleta: es BRAM del colmix (q0 registrado, ~1 clk) y no
// tiene handshake -> espera fija holgada de 4 ciclos. La VRAM expone dos registros en serie
// (dual-port qcpu y luego tile_din), así que además de esperar el wait-state de K056832 (`vdtac`)
// dejamos el mismo margen fijo de 4 ciclos para no capturar la palabra anterior.
// Coste total 255x3 accesos ~= 100 us: nada.
wire blt_rdy   = blt_isram ? ram_ok : blt_isobj ? (blt_wc==2'd3) : blt_isvram ? (vdtac && blt_wc==2'd3) :
                 blt_isrom ? rom_ok : (blt_wc==2'd3);

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        blt_st <= BLT_IDLE; blt_busy_r <= 0; blt_we_r <= 0; blt_stb_r <= 0; blt_ph <= 0;
        blt_served <= 0; blt_wc <= 0; blt_len <= 0; blt_a <= 0; blt_dout_r <= 0;
        blt_src1 <= 0; blt_src2 <= 0; blt_dst <= 0; blt_addr_r <= 0;
        for( bi=0; bi<16; bi=bi+1 ) protram[bi] <= 0;
    end else begin
        // protram: escritura A NIVEL (direccion y dato ASENTADOS), no por flanco -> FASE-4 §4.2-3
        // y GOTCHAS §D1/§D2. Durante el blitter prot_cs=0 (eff_addr ya no apunta ahi) -> no se corrompe.
        if( prot_cs & eff_we & ~eff_busn ) begin
            if( !LDSn ) protram[eff_addr[4:1]][ 7:0] <= cpu_dout_68k[ 7:0];
            if( !UDSn ) protram[eff_addr[4:1]][15:8] <= cpu_dout_68k[15:8];
        end
        if( BUSn ) blt_served <= 0; else if( blt_trig ) blt_served <= 1;

        case( blt_st )
            BLT_IDLE: begin
                blt_stb_r <= 0; blt_we_r <= 0; blt_ph <= 0; blt_busy_r <= 0;
                if( blt_trig ) begin
                    blt_src1 <= blt_s1b[23:1];
                    blt_src2 <= blt_s2b[23:1];
                    blt_dst  <= blt_dsb[23:1];
                    blt_len  <= protram[15];
                    if( protram[15]!=16'd0 ) begin // length==0 -> MAME no hace NADA (while(length))
                        blt_busy_r <= 1;
                        blt_st     <= BLT_RD1;
                    end
                end
            end
            // Cada acceso = 2 fases. ph=0: cs BAJO (fuerza el toggle que exige jtframe_ram_rq y
            // limpia data_ok del acceso anterior) y coloca la direccion. ph=1: cs alto, esperar rdy.
            BLT_RD1: if( !blt_ph ) begin
                blt_addr_r <= blt_src1; blt_we_r <= 0; blt_wc <= 0; blt_stb_r <= 1; blt_ph <= 1;
            end else begin
                blt_wc <= blt_wc + 2'd1;
                if( blt_rdy ) begin
                    blt_a <= blt_rdata; blt_stb_r <= 0; blt_ph <= 0; blt_st <= BLT_RD2;
                end
            end
            BLT_RD2: if( !blt_ph ) begin
                blt_addr_r <= blt_src2; blt_we_r <= 0; blt_wc <= 0; blt_stb_r <= 1; blt_ph <= 1;
            end else begin
                blt_wc <= blt_wc + 2'd1;
                if( blt_rdy ) begin
                    // res = a + 2*b. MAME lo calcula en 32 bits y write_word TRUNCA a 16 ->
                    // el desbordamiento de 16 bits es el comportamiento correcto, no un bug.
                    blt_dout_r <= blt_a + {blt_rdata[14:0],1'b0};
                    blt_stb_r <= 0; blt_ph <= 0; blt_st <= BLT_WR;
                end
            end
            BLT_WR: if( !blt_ph ) begin
                blt_addr_r <= blt_dst; blt_we_r <= 1; blt_wc <= 0; blt_stb_r <= 1; blt_ph <= 1;
            end else begin
                blt_wc <= blt_wc + 2'd1;
                if( blt_rdy ) begin
                    blt_stb_r <= 0; blt_we_r <= 0; blt_ph <= 0; blt_st <= BLT_STEP;
                end
            end
            BLT_STEP: begin
                blt_src1 <= blt_src1 + 1'd1;   // +2 bytes = +1 word
                blt_src2 <= blt_src2 + 1'd1;
                blt_dst  <= blt_dst  + 1'd1;
                blt_len  <= blt_len  - 1'd1;
                if( blt_len==16'd1 ) begin
`ifdef SIMULATION
                    blt_st <= BLT_VFY;   // relee dst[0] antes de soltar el bus
`else
                    blt_busy_r <= 0; blt_st <= BLT_IDLE;
`endif
                end else                   blt_st <= BLT_RD1;
            end
`ifdef SIMULATION
            // Relectura de dst[0] por el MISMO camino que usa el blitter. Zanja la pregunta que la
            // sonda del lado CPU no consigue contestar: 0000 = la escritura aterrizo; 0080 = NO
            // aterrizo y sigue el VENENO que el POST dejo en 0x181000 (0x49e6a rellena 0x180f00-
            // 0x1810fe con 0..0xff; en 0x181000 toca 0x80).
            BLT_VFY: if( !blt_ph ) begin
                blt_addr_r <= blt_dsb[23:1]; blt_we_r <= 0; blt_wc <= 0; blt_stb_r <= 1; blt_ph <= 1;
            end else begin
                blt_wc <= blt_wc + 2'd1;
                if( blt_rdy ) begin
                    if (sim_diag)
                        $display("PROT: RELECTURA dst[0]=%06x -> %04x   (0000=escritura OK | 0080=veneno intacto)",
                            {blt_dsb[23:1],1'b0}, blt_rdata);
                    blt_stb_r <= 0; blt_ph <= 0; blt_busy_r <= 0; blt_st <= BLT_IDLE;
                end
            end
`endif
            default: blt_st <= BLT_IDLE;
        endcase
    end
end

`ifdef SIMULATION
// Testigo del blitter: dice si DISPARO y con que parametros. Si el POST sigue muriendo, esta
// linea distingue "no dispara" (decode/trigger mal) de "dispara pero calcula mal" (datos).
reg blt_busy_l;
reg [7:0] blt_shown;
reg [15:0] blt_nwr;   // escrituras que REALMENTE cerraron su handshake (ram_ok) durante el blitter
always @(posedge clk) begin
    blt_busy_l <= blt_busy_r;
    if( blt_st==BLT_WR && blt_ph && blt_rdy ) blt_nwr <= blt_nwr + 16'd1;
    if( blt_busy_r & ~blt_busy_l ) begin
        blt_shown <= 0; blt_nwr <= 0;
        if (sim_diag)
            $display("PROT: blitter DISPARADO src1=%06x src2=%06x dst=%06x len=%0d",
                blt_s1b, blt_s2b, blt_dsb, protram[15]);
    end
    // Primeras 4 operaciones con sus OPERANDOS: el check exige pal[k]==0 para todo k (ver
    // desensamblado 0x49efa). Si algun a=... sale != 0, el check NO puede pasar y el problema
    // esta en la PALETA (lectura con perdida del byte alto, §D), no en el blitter.
    if( blt_st==BLT_WR && !blt_ph && blt_shown<8'd4 ) begin
        blt_shown <= blt_shown + 8'd1;
        if (sim_diag)
            $display("PROT:   op%0d dst=%06x <= a(pal)=%04x + 2*b(ram)=%04x => %04x",
                blt_shown, {blt_dst,1'b0}, blt_a, (blt_dout_r-blt_a)>>1, blt_dout_r);
    end
    if( ~blt_busy_r & blt_busy_l )
        if (sim_diag)
            $display("PROT: blitter FIN (ultimo dst=%06x dato=%04x) escrituras COMPLETADAS=%0d (deben ser 255)",
                {blt_dst,1'b0}, blt_dout_r, blt_nwr);
end

// ¿PASA el check de proteccion? Desensamblado: 0x49f04 `beq $49f28` (=dbra, sigue el bucle de 257
// iteraciones); si NO casa cae a 0x49f06 = rama de error -> "N4 DEVICE ERROR". 0x49f2c = el dbra
// se agoto SIN error = CHECK SUPERADO. Esta sonda distingue "sigue fallando el N4" de "el N4 pasa
// y lo que muere es OTRA cosa mas adelante" (ambos acaban en el mismo impresor 0x4a5e4 -> el
// backtrace por si solo NO los distingue).
// Que lee REALMENTE la CPU en las 3 direcciones del check. El anillo generico no sirve aqui (su
// ventana de captura no coincide con el instante en que el 68k toma el dato). Aqui se muestrea justo
// cuando la CPU LATCHEA: ciclo de lectura con DTACK ya asertado (~dtac_mux).
// ARMADO tras el disparo del blitter: el test de work RAM (f=13..28) machaca estas mismas
// direcciones con sus patrones (5555/aaaa...) y se comia el presupuesto de prints antes del check.
reg [7:0] chk_n;
reg       chk_arm;
always @(posedge clk, posedge rst) begin
    if( rst ) chk_arm <= 0; else if( blt_busy_r ) chk_arm <= 1;
end
always @(posedge clk, posedge rst) begin
    if( rst ) chk_n <= 0;
    else if( chk_arm && chk_n<8'd9 && ~ASn && RnW && ~BUSn && ~dtac_mux &&
             ( {A,1'b0}==24'h1b0000 || {A,1'b0}==24'h181000 || {A,1'b0}==24'h180000 ) ) begin
        chk_n <= chk_n + 8'd1;
        if (sim_diag)
            $display("CHK: la CPU lee %06x -> cpu_din=%04x (pal_dout=%04x ram_dout=%04x pal_cs=%0d ram_cs=%0d)",
                {A,1'b0}, cpu_din, pal_dout, ram_dout, pal_cs, ram_cs);
    end
end

`endif

`ifdef SIMULATION
// ---------------- TELEMETRIA DE BOOT (Fase 1, sesion 6) — solo simulacion ----------------
// A 28 s/frame no se puede diagnosticar el boot "corriendo mas frames": una linea por vblank
// dice si el 68k AVANZA (rango de PC) y si TOCA el hardware. Sin control2[5] no hay IRQ5 y el
// bucle principal nunca corre -> ese bit es el testigo clave de "arranco de verdad".
// RANGO DE DATOS POR FRAME (`dato=[lo-hi]`): el bucle de checksum de ROM (0x4a388) no se puede juzgar
// por el PC — el PC se queda quieto dentro del bucle tanto si AVANZA como si se repite. Lo que dice la
// verdad es POR DONDE VA EL PUNTERO (A0): si el checksum progresa, este rango BARRE hasta 0x07ffff.
reg [23:1] daf_lo, daf_hi;
wire       data_acc = ~ASn & ~FC[1] & FC[0];   // espacio de DATOS (FC=x01)
reg [23:1] pc_lo, pc_hi, pc_last, pcf_lo, pcf_hi;
reg [31:0] n_prog, n_ram_w, n_vram_w, n_pal_w, n_obj_w, n_ctl2_w, n_irq5, n_irq4;
reg [31:0] n_dma, n_objreg;
reg [ 7:0] cfg_seen;      // ultimo valor escrito al registro 5 del K053246 (= cfg; bit4 = dma_en)
reg        dmab_l;
integer    sound_diag_count;
initial    sound_diag_count = 0;
integer    post_ram_probe_count;
initial    post_ram_probe_count = 0;
integer    obj_cfg_ram_diag_count;
initial    obj_cfg_ram_diag_count = 0;
integer    prot_diag_count;
initial    prot_diag_count = 0;
integer    obj_bus_diag_count;
initial    obj_bus_diag_count = 0;
integer    obj_read_diag_count;
initial    obj_read_diag_count = 0;
reg [15:0] frame_id;
reg        lvbl_l, busn_l;
wire       prog_fetch = ~ASn & RnW & FC[1] & ~FC[0]; // FC=x10 program space (user/supervisor)
// OJO: contar `cpu_we & ~BUSn` por CICLO DE RELOJ infla ~13x (el 68k mantiene el strobe varios clk de 48MHz).
// Hay que contar 1 por CICLO DE BUS = flanco de bajada de BUSn (un long access da 2 strobes: correcto).
wire       wr_stb = busn_l & ~BUSn & cpu_we;
always @(posedge clk, posedge rst) begin
    if( rst ) begin
        pc_lo <= ~23'd0; pc_hi <= 0; pc_last <= 0; frame_id <= 0; lvbl_l <= 0;
        pcf_lo <= ~23'd0; pcf_hi <= 0; busn_l <= 1;
        daf_lo <= ~23'd0; daf_hi <= 0;
        n_prog<=0; n_ram_w<=0; n_vram_w<=0; n_pal_w<=0; n_obj_w<=0; n_ctl2_w<=0; n_irq5<=0; n_irq4<=0;
        n_dma<=0; n_objreg<=0; cfg_seen<=0; dmab_l<=0;
    end else begin
        lvbl_l <= LVBL;
        busn_l <= BUSn;
        // ¿CORRE el DMA de objetos? 1 por flanco de SUBIDA de dma_bsy. Si esto es 0 con irq4en=1,
        // la IRQ4 NO PUEDE dispararse nunca (irq4_edge = ~dma_bsy no tiene flanco que detectar).
        dmab_l <= dma_bsy;
        if( ~dmab_l & dma_bsy ) n_dma <= n_dma+1;
        if( data_acc ) begin
            if( A < daf_lo ) daf_lo <= A;
            if( A > daf_hi ) daf_hi <= A;
        end
        if( prog_fetch ) begin
            pc_last <= A; n_prog <= n_prog+1;
            if( A < pc_lo ) pc_lo <= A;   // acumulado (cuanto codigo se ha tocado)
            if( A > pc_hi ) pc_hi <= A;
            if( A < pcf_lo ) pcf_lo <= A; // POR FRAME = extension del bucle actual
            if( A > pcf_hi ) pcf_hi <= A;
        end
        if( wr_stb ) begin
            if( ram_cs      ) n_ram_w  <= n_ram_w +1;
            if( vram_cs     ) n_vram_w <= n_vram_w+1;
            if( pal_cs      ) n_pal_w  <= n_pal_w +1;
            if( obj_cs      ) n_obj_w  <= n_obj_w +1;
            if( control2_cs ) n_ctl2_w <= n_ctl2_w+1;
            // Capture actual writes into the active parent sprite-source
            // slots. This is simulation-only evidence for the source-RAM
            // address/byte-lane comparison against MAME.
            if (`BUCKY_TEST_PLUSARGS("OBJ_BUS_DIAG") && obj_cs &&
                (frame_id >= 16'd400) && (eff_addr[15:8] >= 8'h40) &&
                obj_bus_diag_count < 512) begin
                $display("OBJ_BUS_WR pc=%06x addr=%06x dsn=%b data=%04x",
                         {pc_last,1'b0}, {eff_addr,1'b0}, eff_dsn, cpu_dout_68k);
                obj_bus_diag_count = obj_bus_diag_count + 1;
            end
            if( objreg_cs   ) begin
                n_objreg <= n_objreg+1;
                // reg 5 del K053246 = cfg. El juego hace `move.b $180013,$c2005` (BYTE a impar -> LDS).
                // Mismo decode que jt053246_mmr en modo 16-bit: case(cpu_addr[2:1])==2 + ~cpu_dsn[0].
                if( eff_addr[2:1]==2'd2 && !eff_dsn[0] ) cfg_seen <= cpu_dout[7:0];
            end
            // The parent sprite path should program the protection blitter
            // through 0x0ce000-0x0ce01f. Keep this separate from the blitter
            // state logger so we can tell a missing CPU write/decode from a
            // broken state machine or memory handshake.
            if (`BUCKY_TEST_PLUSARGS("PROT_DIAG") && prot_cs && prot_diag_count < 128) begin
                $display("PROT_WR addr=%06x dsn=%b data=%04x len=%04x trig=%b",
                         {eff_addr,1'b0}, eff_dsn, cpu_dout_68k,
                         protram[15], blt_trig);
                prot_diag_count = prot_diag_count + 1;
            end
            // The parent POST stores its accumulated error word at $080bfc
            // immediately before entering the diagnostic renderer at $1d24.
            // Observe the real accepted bus write (rather than the CPU's
            // internal stack, which is not the architectural D7 register) so
            // a failing test can be identified without altering the design.
            if (`BUCKY_TEST_PLUSARGS("POST_DIAG") &&
                ram_cs &&
                ((eff_addr[23:1] == 23'h0405fe) ||
                 (eff_addr[23:1] == 23'h0405ff))) begin
                $display("[POSTRAM] pc=%06x addr=%06x dsn=%b data=%04x",
                         {pc_last,1'b0}, {eff_addr,1'b0}, eff_dsn, cpu_dout);
                post_ram_probe_count = post_ram_probe_count + 1;
                // Earlier RAM self-tests deliberately touch the same mailbox
                // words with 0x5555/0xaaaa/0xffff.  Only stop after the final
                // sound/checksum phase has reached the post-1a00 code.
                if (`BUCKY_TEST_PLUSARGS("POST_DIAG_STOP") &&
                    ({pc_last,1'b0} >= 24'h001a00) &&
                    (eff_addr[23:1] == 23'h0405ff)) $finish;
            end
        end
        // Capture the value actually presented on the CPU return bus for
        // object-source reads.  The source RAM is registered; this probe is
        // intentionally read-only and makes any stale-read timing visible.
        if (`BUCKY_TEST_PLUSARGS("OBJ_READ_DIAG") && obj_cs && RnW &&
            !BUSn && !dtac_mux && (frame_id >= 16'd480) &&
            obj_read_diag_count < 256) begin
            $display("OBJ_BUS_RD frame=%0d pc=%06x addr=%06x din=%04x",
                     frame_id, {pc_last,1'b0}, {eff_addr,1'b0}, cpu_din);
            obj_read_diag_count = obj_read_diag_count + 1;
        end
        if (`BUCKY_TEST_PLUSARGS("PROT_DIAG") && blt_trig && prot_diag_count < 128) begin
            $display("PROT_TRIG addr=%06x data=%04x len=%04x busy=%b",
                     {eff_addr,1'b0}, cpu_dout_68k, protram[15], blt_busy_r);
            prot_diag_count = prot_diag_count + 1;
        end
        // The game publishes K053246 DMA-enable bit 4 through the byte latch
        // at 0x080013.  Probe only this address when requested so a RAM
        // byte-lane/readback failure is distinguishable from a sprite ASIC
        // problem without enabling the verbose general diagnostics.
        if (`BUCKY_TEST_PLUSARGS("OBJ_DIAG") && obj_cfg_ram_diag_count < 64 &&
            // A0 is not present on the 68000 bus: an odd-byte access to
            // 0x080013 is presented with the even word address 0x080012 and
            // LDSn asserted.
            ({A,1'b0} == 24'h080012) && ~ASn && ~BUSn &&
            ((cpu_dout_68k[7:0] != 8'h00) && (cpu_dout_68k[7:0] != 8'h55) &&
             (cpu_dout_68k[7:0] != 8'haa) && (cpu_dout_68k[7:0] != 8'hff) ||
             (RnW && (cpu_din[7:0] != 8'h00) && (cpu_din[7:0] != 8'h55) &&
                     (cpu_din[7:0] != 8'haa) && (cpu_din[7:0] != 8'hff)))) begin
            $display("OBJ_CFG_RAM rnw=%b we=%b dsn=%b dout=%04x din=%04x ram_cs=%b ram_ok=%b",
                RnW, cpu_we, {UDSn,LDSn}, cpu_dout_68k, cpu_din, ram_cs, ram_ok);
            obj_cfg_ram_diag_count <= obj_cfg_ram_diag_count + 1;
        end
        // The parent POST polls K054321 at 0x0d6015 after sending Z80
        // commands.  Keep an opt-in edge-level probe here so a failed POST
        // can be separated into a main-bus decode, latch, or Z80 response
        // problem without changing synthesizable behavior.
        if (`BUCKY_TEST_PLUSARGS("SOUND_DIAG") && sound_diag_count < 256 &&
            pair_cs && !BUSn) begin
            if (busn_l)
                $display("[SOUND] addr=%06x rnw=%b we=%b dout=%02x pair=%02x din=%04x irq=%b",
                         {eff_addr,1'b0}, RnW, cpu_we, cpu_dout[7:0],
                         pair_dout, cpu_din, sndon);
            sound_diag_count = sound_diag_count + 1;
        end
        if( irq5_ack ) n_irq5 <= n_irq5+1;
        if( irq4_ack ) n_irq4 <= n_irq4+1;
        if( lvbl_l & ~LVBL ) begin // caida de LVBL = 1 informe por frame
            frame_id <= frame_id+1;
            if (sim_diag)
                $display("BOOT f=%0d PC=%06x bucle=[%06x-%06x] dato=[%06x-%06x] visto=[%06x-%06x] | wr ram=%0d vram=%0d pal=%0d obj=%0d ctl2=%0d | ctl2=%04x irq5en=%0d irq4en=%0d ack5=%0d ack4=%0d | objreg=%0d cfg=%02x dma_en=%0d DMA/f=%0d",
                    frame_id, {pc_last,1'b0}, {pcf_lo,1'b0}, {pcf_hi,1'b0}, {daf_lo,1'b0}, {daf_hi,1'b0},
                    {pc_lo,1'b0}, {pc_hi,1'b0},
                    n_ram_w, n_vram_w, n_pal_w, n_obj_w, n_ctl2_w,
                    cur_control2, irq5en, irq4en, n_irq5, n_irq4,
                    n_objreg, cfg_seen, cfg_seen[4], n_dma);
            // contadores y rango `bucle` = POR FRAME; `visto` = acumulado. wr_* = ciclos de BUS reales.
            n_prog<=0; n_ram_w<=0; n_vram_w<=0; n_pal_w<=0; n_obj_w<=0; n_ctl2_w<=0;
            n_dma<=0; n_objreg<=0;   // por frame (cfg_seen NO: es un estado, no un contador)
            pcf_lo <= ~23'd0; pcf_hi <= 0;
            daf_lo <= ~23'd0; daf_hi <= 0;
        end
    end
end
`endif

// pause via HALTn (as the inherited main did): dip_pause low -> CPU halted
reg HALTn;
always @(posedge clk) HALTn <= dip_pause & ~rst;

jt5911 #(.SIMFILE("nvram.bin")) u_eeprom(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .sclk       ( eep_clk   ),
    .sdi        ( eep_di    ),
    .sdo        ( eep_do    ),
    .rdy        ( eep_rdy   ),
    .scs        ( eep_cs    ),
    .mem_addr   ( nv_addr   ),
    .mem_din    ( nv_din    ),
    .mem_we     ( nv_we     ),
    .mem_dout   ( nv_dout   ),
    .dump_clr   ( 1'b0      ),
    .dump_flag  (           )
);

// Cached SDRAM waits create a bounded recovery debt during the long parent
// POST.  The JTFRAME default total width (W+WD=12) saturates near frame 14;
// retain the generated enables exactly and widen only that accumulator.
jtframe_68kdtack_cen #(.W(6),.RECOVERY(1),.WD(12)) u_dtack(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cpu_cen    ( cpu_cen   ),
    .cpu_cenb   ( cpu_cenb  ),
    .bus_cs     ( bus_cs    ),
    .bus_busy   ( bus_busy  ),
    .bus_legit  ( 1'b0      ),
    .bus_ack    ( 1'b0      ),
    .ASn        ( ASn       ),
    .DSn        ({UDSn,LDSn}),
    .num        ( 5'd1      ),  // 16MHz = 48/3
    .den        ( 6'd3      ),
    .DTACKn     ( DTACKn    ),
    .wait2      ( 1'b0      ),
    .wait3      ( 1'b0      ),
    .fave       (           ),
    .fworst     (           )
);

jtframe_m68k u_cpu(
    .clk        ( clk         ),
    .rst        ( rst         ),
    .RESETn     (             ),
    .cpu_cen    ( cpu_cen     ),
    .cpu_cenb   ( cpu_cenb    ),

    .eab        ( A           ),
    .iEdb       ( cpu_din     ),
    .oEdb       ( cpu_dout_68k),

    .eRWn       ( RnW         ),
    .LDSn       ( LDSn        ),
    .UDSn       ( UDSn        ),
    .ASn        ( ASn         ),
    .VPAn       ( VPAn        ),
    .FC         ( FC          ),

    .BERRn      ( 1'b1        ),
    .HALTn      ( HALTn       ),
    .BRn        ( 1'b1        ),
    .BGACKn     ( 1'b1        ),
    .BGn        (             ),

    .DTACKn     ( dtac_mux    ),
    .IPLn       ( IPLn        )
);

`else
    initial begin
        obj_cs    = 0;
        objcha_n  = 1;
        objreg_cs = 0;
        pal_cs    = 0;
        pcu_cs    = 0;
        ram_cs    = 0;
        rmrd      = 0;
        rom_cs    = 0;
        sndon     = 0;
        vram_cs   = 0;
        ccu_cs    = 0;
        romrd_cs  = 0;
        tilereg_cs= 0;
        tilereg_b_cs=0;
        alpha_cs  = 0;
        mute      = 0;
    end
    assign
        cpu_dout  = 0,
        cpu_we    = 0,
        main_addr = 0,
        ram_dsn   = 0,
        snd_wrn   = 0,
        st_dout   = 0,
        nv_addr   = 0,
        nv_din    = 0,
        pair_we   = 0,
        nv_we     = 0;
`endif
endmodule
