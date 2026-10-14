/*  This file is part of JTCORES (fork COWBOYS / Moo Mesa). GPLv3.

    cowboys_video — integra el tilemap K056832 (cowboys_k056832, validado 0.00% vs golden) con
    los sprites (cowboys_obj: FORK PROPIO desde simson, ses.24 - ver cabecera del fichero) y el colmix (K053251 + K054338 alpha).

    Arquitectura del tilemap = estilo rungun (Camino A): el modulo K056832 lleva su PROPIO vtimer
    (fuente de timing del core) + VRAM interna paginada + 1 bus ROM SERIAL (scr) que multiplexa las 4
    capas. Sustituye a jtaliens_scroll (que era el K052109 de X-Men, chip distinto).

    Release boundary: K053251/K054338 scene accuracy, native timing and the
    sprite-source correction still require their documented regression and
    hardware gates; they are not represented as selectable experimental RTL.
*/
`ifndef BUCKY_TEST_PLUSARGS
`ifdef SYNTHESIS
`define BUCKY_TEST_PLUSARGS(arg) 1'b0
`else
`define BUCKY_TEST_PLUSARGS(arg) $test$plusargs(arg)
`endif
`endif

module bucky_video(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,

    // Base Video (las genera el vtimer del K056832)
    output            lhbl,
    output            lvbl,
    output            hs,
    output            vs,

    // Observabilidad para el harness de validacion (cowboys_vfull lo INSTANCIA: sesion 16). En
    // produccion se dejan ABIERTOS -> no cambian el comportamiento (son taps del framebuffer y del
    // pixel de sprite). Eliminan la COPIA que derivaba en silencio (orama, EDGE_TRIGGER): las 2 caras
    // del C-06 de las sesiones 12-14.
    output     [ 8:0] hdump,
    output     [ 8:0] vdump,
    output     [ 8:0] lyro_pxl_o,   // pixel de sprite (dbg_spr en el tb)

    output            tile_irqn,
    output            tile_nmin,

    // Object source RAM
    input      [13:1] oram_addr,
    input      [ 1:0] oram_we,
    // Word offset within Bucky's 0x090000-0x09ffff sprite source RAM.
    // main_addr carries the 68000 A1.. bus bits; the absolute base address
    // must not leak into this relative 64 KiB RAM address.
    input      [15:0] obj_cpu_addr,
    // CPU interface
    input      [16:1] cpu_addr,
    input      [ 1:0] cpu_dsn,
    input      [15:0] cpu_dout,
    input             cpu_we,

    input             pcu_cs,
    input             alpha_cs,     // K054338 regs 0x0ca000
    input             pal_cs,
    output     [15:0] pal_dout,
    output     [15:0] alpha_dout,
    output     [ 7:0] pcu_dout,
    output            pal_wait,
    output     [15:0] tilesys_dout,

    output            dma_bsy,
    output     [15:0] objsys_dout,
    input             objsys_cs,
    input             objreg_cs,
    input             objcha_n,

    output            vdtac,
    input             tilesys_cs,   // Bucky VRAM window 0x180000-0x183fff
    input             tilereg_cs,   // K056832 regs 0x0c0000
    input             tilereg_b_cs, // K056832 VSCCS regs 0x0d8000
    output            rst8,

    // control
    input             rmrd,
    input             romrd_cs,      // CPU tile-ROM passthrough 0x190000
    output            romrd_ok,
    output     [15:0] romrd_dout,
    output            flip,

    // Tile ROM (K056832) — 1 bus serial DW32
    output     [20:2] scr_addr,
    output            scr_cs,
    input      [31:0] scr_data,
    input             scr_ok,

    // Sprite ROM — [22:2] (21 bits word addr) = 8MB completos. Antes [21:2] truncaba rom_addr[22]
    // (bug: los sprites de code alto, moomesa 0xf6xx, leian la mitad equivocada -> transparentes).
    output     [22:2] lyro_addr,
    output            lyro_cs,
    input             lyro_ok,
    input      [31:0] lyro_data,

    // Color
    input      [ 2:0] dim,
    input             dimmod,
    input             dimpol,

    output     [ 7:0] red,
    output     [ 7:0] green,
    output     [ 7:0] blue,

    // Debug
    input      [15:0] ioctl_addr,
    input             ioctl_ram,
    output     [ 7:0] ioctl_din,

    input      [ 3:0] gfx_en,
    input      [ 7:0] debug_bus,
    output     [ 7:0] st_dout
);

wire [ 8:0] vrender, vrender1, lyro_pxl;   // hdump/vdump/lyro_pxl_o ya son PUERTOS (observabilidad)
assign lyro_pxl_o = lyro_pxl;
wire [ 7:0] lyrf_pxl, lyra_pxl, lyrb_pxl, lyrc_pxl, dump_obj, obj_mmr;
wire [ 1:0] lyra_mix, lyrb_mix, lyrc_mix;   // flag de mezcla por tile (attr[2]) - ses.24
wire [ 4:0] lyro_pri;
wire [ 1:0] shadow;
wire [15:0] tile_din;
wire [18:0] rom_addr;
wire [ 7:0] scr_rom_bank;
wire [ 1:0] rom_lyr;
wire        rom_cs, cpu_weg;
wire        tile_rom_ok;
wire [ 3:0] ommra;
wire [15:1] orama;
wire [ 1:0] orama_we;

assign cpu_weg     = cpu_we && cpu_dsn!=2'b11;
assign flip        = 1'b0;
assign tile_nmin   = 1'b1;
assign rst8        = 1'b0;
assign st_dout     = 8'd0;
assign tilesys_dout= tile_din;         // lectura CPU 16-bit (ram_word_r): la VRAM del K056832 es de words
// The tile fetcher and the CPU ROM passthrough share one JTFRAME 32-bit slot.
// The arbiter inserts a low-CS break before every CPU request so JTFRAME's
// edge-triggered ROM request logic cannot reuse a stale tile response.
bucky_k056832_romrd u_romrd(
    .rst       ( rst          ),
    .clk       ( clk          ),
    .rd_cs     ( romrd_cs    ),
    .rd_addr   ( cpu_addr[12:1]),
    .rd_bank   ( scr_rom_bank ),
    .rd_ok     ( romrd_ok    ),
    .rd_data   ( romrd_dout  ),
    .tile_addr ( rom_addr    ),
    .tile_cs   ( rom_cs      ),
    .tile_ok   ( tile_rom_ok ),
    .scr_addr  ( scr_addr    ),
    .scr_cs    ( scr_cs      ),
    .scr_data  ( scr_data    ),
    .scr_ok    ( scr_ok      )
);

// The K056832 VRAM/register read port is a registered word RAM.  Hold DTACK
// for the first cycle of a tile-system bus phase, then leave it asserted for
// the remainder of that phase so the 68000 samples the registered cpu_din.
// This replaces the old unconditional one, which allowed the CPU to sample
// stale VRAM data on the first access after a bus phase.
wire tile_bus_cs = tilesys_cs | tilereg_cs | tilereg_b_cs;
reg  tile_wait_seen;
assign vdtac = ~tile_bus_cs | tile_wait_seen;
always @(posedge clk) begin
    if (rst)
        tile_wait_seen <= 1'b0;
    else if (!tile_bus_cs)
        tile_wait_seen <= 1'b0;
    else
        tile_wait_seen <= 1'b1;
end

/* verilator tracing_on */
// ---------------- TILEMAP K056832 (validado) ----------------
cowboys_k056832 u_scroll(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),

    .lhbl       ( lhbl      ),
    .lvbl       ( lvbl      ),
    .hs         ( hs        ),
    .vs         ( vs        ),
    .hdump      ( hdump     ),
    .vdump      ( vdump     ),
    .vrender    ( vrender   ),
    .vrender1   ( vrender1  ),

    // CPU (68000, bus 16b)
    .vram_cs    ( tilesys_cs),
    .reg_cs     ( tilereg_cs),
    .regb_cs    ( tilereg_b_cs),
    .cpu_we     ( cpu_weg   ),
    .cpu_addr   (cpu_addr[12:1]),
    .cpu_dout   ( cpu_dout  ),
    .cpu_din    ( tile_din  ),

    // ROM de tiles (1 bus serial)
    .rom_addr   ( rom_addr  ),
    .rom_lyr    ( rom_lyr   ),
    .rom_cs     ( rom_cs    ),
    .rom_data   ( scr_data  ),
    .rom_ok     ( tile_rom_ok ),

    // pixel out (4 capas)
    .lyrf_pxl   ( lyrf_pxl  ),
    .lyra_pxl   ( lyra_pxl  ),
    .lyrb_pxl   ( lyrb_pxl  ),
    .lyrc_pxl   ( lyrc_pxl  ),
    .lyra_mix   ( lyra_mix  ),
    .lyrb_mix   ( lyrb_mix  ),
    .lyrc_mix   ( lyrc_mix  ),
    .rom_bank   ( scr_rom_bank ),

    .gfx_en     ( gfx_en    ),
    .debug_bus  ( 8'd0      )
);

assign tile_irqn = 1'b1;   // Bucky map has no K056832 IRQ window; IRQ4 comes from object DMA.

/* verilator tracing_on */
assign ommra = {cpu_addr[3:1],cpu_dsn[1]};

// GX173 has a CPU-visible 0x10000-byte source RAM at 0x090000.  Each of its
// 256 object slots is 0x80 words: words 0..7 feed K053246 DMA while the rest
// hold live game metadata.  Compacting the CPU address aliases metadata reads
// onto draw words (for example MAME frame 516 reads 0 at 0x091424 while the
// compact path returned sprite code 0x3900).  Preserve the complete source
// address here; cowboys_obj translates only the DMA port to slot*0x80+word.
assign orama    = obj_cpu_addr[14:0];
assign orama_we = oram_we & {2{objsys_cs}};

// SONDA (sesion 12): saca el `cfg` REAL de dentro de `k053246_mmr` sin tocar nada compartido.
// `cowboys_obj` -> `st_addr = ioctl_ram ? ioctl_addr : debug_bus` y `k053246_mmr: 5: st_dout <= cfg`,
// que sale por `dump_reg` (= `obj_mmr`). Forzando debug_bus=5 en sim, `obj_mmr` ES el cfg del registro.
// VERIFICADO que es inerte para el render: el UNICO uso de debug_bus aguas abajo (`k053246_scan.sv:215`)
// esta COMENTADO. Aun asi hay que re-correr vfull/vmix: la sonda es de sim, pero el mux no.
wire [7:0] obj_dbg;
`ifdef SIMULATION
assign obj_dbg = 8'd5;
`else
assign obj_dbg = 8'd0;
`endif

`ifdef SIMULATION
integer obj_src_diag_count;
integer obj_live_diag_count;
integer obj_nonzero_diag_count;
integer obj_reg_diag_count;
initial obj_src_diag_count = 0;
initial obj_live_diag_count = 0;
initial obj_nonzero_diag_count = 0;
initial obj_reg_diag_count = 0;
always @(posedge clk) if (`BUCKY_TEST_PLUSARGS("OBJ_DIAG") && objsys_cs && cpu_we && obj_src_diag_count < 32) begin
    $display("OBJ_SRC_WR n=%0d cpu_addr=%04x obj_off=%04x orama=%04x dsn=%b data=%04x we=%b",
        obj_src_diag_count, cpu_addr, obj_cpu_addr, orama, cpu_dsn, cpu_dout, orama_we);
    obj_src_diag_count <= obj_src_diag_count + 1;
end
// Focused, counter-free probe for the first live gameplay object metadata.
// Keep this behind a runtime plusarg: it adds no state and is absent from
// production behaviour.
always @(posedge clk) if (`BUCKY_TEST_PLUSARGS("OBJ_TARGET_DIAG") && objsys_cs && cpu_we &&
                         (|orama_we) &&
                         (obj_cpu_addr[14:0] == 15'h0a10 ||
                          obj_cpu_addr[14:0] == 15'h0a12 ||
                          obj_cpu_addr[14:0] == 15'h0a13 ||
                          obj_cpu_addr[14:0] == 15'h0a16)) begin
    $display("OBJ_TARGET_WR time=%0t cpu_addr=%04x obj_off=%04x orama=%04x dsn=%b data=%04x we=%b",
        $time, cpu_addr, obj_cpu_addr, orama, cpu_dsn, cpu_dout, orama_we);
end
always @(posedge clk) if (`BUCKY_TEST_PLUSARGS("OBJ_DIAG") && objsys_cs && cpu_we &&
                         obj_cpu_addr[14:7] >= 8'h40 && obj_cpu_addr[6:3] == 4'd0 &&
                         obj_live_diag_count < 96) begin
    $display("OBJ_LIVE_WR n=%0d cpu_addr=%04x obj_off=%04x orama=%04x dsn=%b data=%04x we=%b",
        obj_live_diag_count, cpu_addr, obj_cpu_addr, orama, cpu_dsn, cpu_dout, orama_we);
    obj_live_diag_count <= obj_live_diag_count + 1;
end
always @(posedge clk) if (`BUCKY_TEST_PLUSARGS("OBJ_DIAG") && objsys_cs && cpu_we &&
                         obj_cpu_addr[14:7] >= 8'h40 && obj_cpu_addr[14:7] <= 8'h70 &&
                         obj_cpu_addr[6:3] == 4'd0 && cpu_dout[15] &&
                         cpu_dout[7:0] != 8'h00 && cpu_dout != 16'h5555 &&
                         cpu_dout != 16'haaaa && cpu_dout != 16'hffff &&
                         obj_nonzero_diag_count < 96) begin
    $display("OBJ_NONZERO_WR n=%0d cpu_addr=%04x obj_off=%04x orama=%04x dsn=%b data=%04x we=%b",
        obj_nonzero_diag_count, cpu_addr, obj_cpu_addr, orama, cpu_dsn, cpu_dout, orama_we);
    obj_nonzero_diag_count <= obj_nonzero_diag_count + 1;
end

// SONDA (sesion 12): que ve EXACTAMENTE el k053246_mmr en una escritura de registro.
// Ojo: el tb de video NUNCA ejercita este camino — `k053246_mmr.v:51` hace `mmr_init[5][4]=1`,
// o sea que en sim el mmr CARGA cfg de un dump y fuerza dma_en=1. Por eso `vfull` da sprites
// pixel-exactos con el DMA "funcionando" y el boot real puede tener este camino ROTO sin que
// ninguna regresion de video lo cace. (Mismo patron que el pxl_cen UNDRIVEN de la sesion 5.)
// El mmr latchea con: cs && cpu_we, case(cpu_addr[2:1])==2, !cpu_dsn[0] -> cfg <= cpu_dout[7:0].
// MEDIDO sesion 12: SI latchea (`dsn=10 dout=3030 -> LATCHEA cfg`) => dma_en=1 dentro del modulo.
// Luego el fallo esta en el TRIGGER del DMA: dma_en && (lvbl_sh==2'b10 && hs_pos), que depende
// de `hs` y `lvbl` — las señales que el tb de video INYECTA y el core real debe GENERAR.
always @(posedge clk) if( objreg_cs && cpu_we ) begin
    if (`BUCKY_TEST_PLUSARGS("DIAG") || (`BUCKY_TEST_PLUSARGS("OBJ_DIAG") && obj_reg_diag_count < 64 &&
        (cpu_dout[7:0] != 8'h00) && (cpu_dout[7:0] != 8'h20))) begin
        $display("OBJREG_WR ommra=%b (addr[2:1]=%0d) dsn=%b dout=%04x -> %s",
            ommra, ommra[2:1], cpu_dsn, cpu_dout,
            (ommra[2:1]==2'd2 && !cpu_dsn[0]) ? "LATCHEA cfg" : "no toca cfg");
        if (`BUCKY_TEST_PLUSARGS("OBJ_DIAG")) obj_reg_diag_count <= obj_reg_diag_count + 1;
    end
end

// ¿Pulsan `hs` y `lvbl` en el CORE REAL? El DMA necesita hs_pos (flanco de HS muestreado a pxl2_cen)
// y ver lvbl 1->0. Si hs no pulsa, lvbl_sh nunca vale 2'b10 y el DMA NO ARRANCA NUNCA.
reg hs_l, lvbl_l2, p2c_seen;
integer n_hs=0, n_lvbl=0, n_p2c=0;
always @(posedge clk) begin
    hs_l <= hs; lvbl_l2 <= lvbl;
    if( pxl2_cen ) n_p2c <= n_p2c+1;
    if( ~hs_l & hs ) n_hs <= n_hs+1;
    if( lvbl_l2 & ~lvbl ) begin
        n_lvbl <= n_lvbl+1;
        if (`BUCKY_TEST_PLUSARGS("DIAG"))
            $display("VTIMER frame=%0d | hs_pos=%0d pxl2_cen=%0d (por frame) | MMRCFG cfg=%02x dma_en=%b",
                n_lvbl, n_hs, n_p2c, obj_mmr, obj_mmr[4]);
        n_hs <= 0; n_p2c <= 0;
    end
end
`endif

// voffset del K053246/247: moomesa usa el valor SIMSON (0x117), NO el "no-simson" (0x107). Hallado con
// probe single-cell (spr0) — el sweep grueso 0x105..0x10d no lo tocaba. Antes 0xff (heredado, mal).
localparam [9:0] OVOFFSET=10'h117;
// Offset H del obj: el K053246 espera hdump 0x20-based (Konami CRTC); nuestro hdump es 0-based. Calibracion
// de origen CRT (constante). OBJ_HOFF=149 + OVOFFSET=0x117 => sprites PIXEL-EXACTOS vs golden --mode full en
// escenas 600/900/1800 (0 diffs de sprite; solo residuo col-0/pipeline conocido). Validado run_vfull sesion 4.
// ⚠ El 149 de arriba se calibro contra golden de MOO MESA (escenas 600/900/1800 del donante). MAME
// configura el K053246 DISTINTO por juego: moo.cpp:789 set_config(...,-48+1,23) para moo y :868
// set_config(...,-48,23) para BUCKY -> los sprites de Bucky van 1 px a la IZQUIERDA de los de Moo.
// El offset equivalente de TILES si se re-derivo (cowboys_k056832.v:59 {-2,2,4,6} vs donante
// {-1,3,5,7}), asi que los sprites quedaban 1 px descolgados respecto a los tiles.
// Signo: k053246_scan.sv:226 xadj<=xoffset-HOFFSET y :414 x<=x-xadj, y bucky_video.v alimenta
// .hdump(hdump+OBJ_HOFF) -> subir OBJ_HOFF mueve los sprites a la IZQUIERDA. 149 -> 150.
// El retoque +1 de HB_START/HB_END/HS_START (cowboys_k056832.v:82-84) NO es un offset de juego: es
// compensacion de UNA etapa extra de pipeline (bucky_k054338.v:150-156 registra color_bgr en pxl_cen,
// el donante mezclaba de forma puramente combinacional), afecta por igual a todas las capas y no se
// toca. PENDIENTE DE VERIFICAR contra posicion real de sprite en MAME/PCB.
localparam [8:0] OBJ_HOFF=9'd150;

// ⭐ EDGE_TRIGGER (sesion 12) — el DMA de sprites de moomesa es un ARMADO DE UN SOLO DISPARO.
// Desensamblado del juego (coste 0 sims), protocolo REAL:
//   1) el juego ARMA:            `move.b #$30,$0c2005` (0x20ce/0x2114) o `ori.b #$10,$180013`+publica
//   2) al vblank el HW hace el DMA y, al terminar, pide IRQ4 (`dmaend`)
//   3) el handler de IRQ5 (vector 0x74 -> 0x2482) DESARMA en su PRIMERA instruccion util:
//        2484: andi.b #$ef,$180013   ; limpia bit4
//        248c: move.b $180013,$0c2005 ; publica -> cfg[4]=0
// El trigger por defecto (`dma_en && lvbl_sh==2'b10 && hs_pos`) muestrea ~2 LINEAS (~127us) DESPUES de
// que caiga lvbl; para entonces el 68k YA ha ejecutado el handler de IRQ5 y `dma_en` vale 0 => el DMA
// NO ARRANCA NUNCA => sin flanco de `dma_bsy` no hay IRQ4 => cuelgue en 0x1214. MAME no tiene la carrera
// porque `moo_interrupt` muestrea `k053246_is_irq_enabled()` en el INSTANTE del vblank, antes de la ISR.
// `trigger_at_dmaen = ~dma_en & dmaen_l` (flanco de BAJADA) modela el protocolo tal cual.
// PRECEDENTE: `rungun` (Konami, cerrado) hace EXACTAMENTE esto en `jtrungun_video.v:94`.
// Ojo al `ifndef`: con NOMAIN (los tb de video vmix/vfull) NO hay CPU que desarme y `k053246_mmr.v:51`
// fuerza `mmr_init[5][4]=1` fijo => con EDGE_TRIGGER=1 el flanco no llegaria NUNCA y los sprites
// DESAPARECERIAN del tb. Por eso el trigger viejo se queda para NOMAIN. (Y por eso `vfull`=0.0000%
// convivia con el DMA real muerto: el tb NO puede ver este bug — el C-06 de la sesion 12.)
localparam EDGE_TRIGGER = `ifndef NOMAIN 1 `else 0 `endif;

cowboys_obj #(.RAMW(15),.SHADOW(1),.EDGE_TRIGGER(EDGE_TRIGGER)) u_obj(   // 64 KiB GX173 source RAM
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),
    .pxl2_cen   ( pxl2_cen  ),
    .simson     ( 1'b1      ),
    .ln_done    (           ),

    .voffset    ( OVOFFSET  ),
    .hs         ( hs        ),
    .lvbl       ( lvbl      ),
    .hdump      ( hdump + OBJ_HOFF ),
    .vdump      ( vrender   ),   // como simson: el obj usa vrender (linea a preparar), no vdump
    // CPU interface
    .ram_cs     ( objsys_cs ),
    .ram_addr   ( orama     ),
    .ram_din    ( cpu_dout  ),
    .ram_we     ( orama_we  ),
    .cpu_din    (objsys_dout),

    .reg_cs     ( objreg_cs ),
    .mmr_addr   ( ommra     ),
    .mmr_din    ( cpu_dout  ),
    .mmr_we     ( cpu_we    ),
    .mmr_dsn    ( cpu_dsn   ),

    .dma_bsy    ( dma_bsy   ),
    // ROM
    .rom_addr   ( lyro_addr ),
    .rom_data   ( lyro_data ),
    .rom_ok     ( lyro_ok   ),
    .rom_cs     ( lyro_cs   ),
    .objcha_n   ( objcha_n  ),
    // pixel output
    .pxl        ( lyro_pxl  ),
    .shd        ( shadow    ),
    .prio       ( lyro_pri  ),
    // Debug
    .ioctl_ram  ( ioctl_ram ),
    .ioctl_addr ( ioctl_addr ),
    .dump_ram   ( dump_obj  ),
    .dump_reg   ( obj_mmr   ),
    .gfx_en     ( gfx_en    ),
    .debug_bus  ( obj_dbg   )   // sonda cfg: =5 en sim, debug_bus en HW (ver arriba)
);

/* verilator tracing_on */
bucky_colmix u_colmix(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl_cen    ( pxl_cen   ),

    .lhbl       ( lhbl      ),
    .lvbl       ( lvbl      ),

    // CPU interface (Bucky palette 0x1b0000, prio K053251 0x0cc000)
    .cpu_addr   (cpu_addr[13:1]),
    .cpu_we     ( cpu_weg   ),
    .cpu_din    ( pal_dout  ),
    .alpha_dout ( alpha_dout ),
    .pcu_dout   ( pcu_dout   ),
    .pal_wait   ( pal_wait   ),
    .cpu_d8     ( cpu_dout[7:0] ),
    .cpu_dout   ( cpu_dout  ),
    .cpu_dsn    ( cpu_dsn   ),
    .pal_cs     ( pal_cs    ),
    .pcu_cs     ( pcu_cs    ),
    .alpha_cs   ( alpha_cs  ),

    // Final pixels (4 capas de tile 8b {colnib,pen} + sprites)
    .lyrf_pxl   ( lyrf_pxl  ),
    .lyra_pxl   ( lyra_pxl  ),
    .lyrb_pxl   ( lyrb_pxl  ),
    .lyrc_pxl   ( lyrc_pxl  ),
    .lyra_mix   ( lyra_mix  ),
    .lyrb_mix   ( lyrb_mix  ),
    .lyrc_mix   ( lyrc_mix  ),
    .lyro_pxl   ( lyro_pxl  ),   // 9b sprites -> ci1
    .lyro_pri   ( lyro_pri  ),

    .dimmod     ( dimmod    ),
    .dimpol     ( dimpol    ),
    .dim        ( dim       ),
    .shadow     ( shadow    ),

    .red        ( red       ),
    .green      ( green     ),
    .blue       ( blue      ),

    // Debug
    .ioctl_addr ( ioctl_addr[11:0]),
    .ioctl_ram  ( ioctl_ram ),
    .ioctl_din  ( ioctl_din ),
    .dump_mmr   (           ),

    .debug_bus  ( 8'd0      )
);

endmodule
