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
    Date: 7-7-2024 */

`ifndef BUCKY_TEST_PLUSARGS
`ifdef SYNTHESIS
`define BUCKY_TEST_PLUSARGS(arg) 1'b0
`else
`define BUCKY_TEST_PLUSARGS(arg) $test$plusargs(arg)
`endif
`endif

module cowboys_sound(
    input           rst,
    input           clk,
    input           cen_8,
    input           cen_4,
    input           cen_2,
    input           cen_pcm,

    input           pair_we,
    // communication with main CPU
    input   [ 7:0]  main_dout,  // bus access for Punk Shot
    output  [ 7:0]  main_din,
    output  [ 7:0]  pair_dout,
    input   [ 4:1]  main_addr,
    input           main_rnw,

    input           snd_irq,
    // ROM
    // Z80 program ROM: 0x0000-0x7fff fixed plus 16 x 0x4000 banked bytes.
    // The bank latch uses all four low bits, so the physical address is 18 bits.
    output  [17:0]  rom_addr,
    output  reg     rom_cs,
    input   [ 7:0]  rom_data,
    input           rom_ok,
    // ADPCM ROM
    // GX173 K054539 sample ROM: 4 MiB, byte-addressed (22 bits).
    output   [21:0] pcm_addr,
    input    [ 7:0] pcm_dout,
    output          pcm_cs,
    input           pcm_ok,
    // Sound output — CANALES SEPARADOS hacia el rcmix de jtframe (mem.yaml: fm + pcm).
    // Antes salia un solo `k539_l/r` con FM+PCM ya sumados dentro del k054539 (railaba el clip16).
    // Ahora cada uno va por su canal -> jtframe mezcla en precision ancha, sin comprometer headroom.
    output     signed [15:0] fm_l,  fm_r,   // YM2151 (jt51)
    output     signed [15:0] pcm_l, pcm_r,  // K054539 PCM
    // Debug
    input    [ 7:0] debug_bus,
    output   [ 7:0] st_dout
);

assign main_din = 0;

`ifndef NOSOUND
wire        [ 7:0]  cpu_dout, cpu_din,  ram_dout, fm_dout,
                    k39_dout, latch_dout;
wire                k39_rb_wait;
wire                k39_timeout;
wire        [ 3:0]  rom_hi;
reg         [ 3:0]  bank;
wire        [15:0]  A;
wire                m1_n, mreq_n, rd_n, wr_n, iorq_n, rfsh_n, nmi_n,
                    cpu_cen, cen_g, fm_intn, latch_we, cen_fm, cen_fm2,
                    latch_intn, int_n, nmi_trig, nmi_clr;
reg                 ram_cs, fm_cs,  k39_cs, mem_acc,
                    nmi_clrr, bank_we, k21_cs;
wire  signed [15:0] fmx_l, fmx_r;   // salida cruda del jt51 (antes de trim)
// The PCM engine exposes a 24-bit internal byte address.  The GX173 sample
// region is 4 MiB, so the generated JTFRAME memory port carries its low 22
// bits.  Keep the width adaptation on a named net: connecting an output port
// directly to a concatenation is rejected by strict elaborators (and can hide
// a real top-level memory-port defect).
wire [23:0] pcm_addr_wide;
assign pcm_addr = pcm_addr_wide[21:0];

// Channel balance belongs to JTFRAME's fixed rcmix metadata. The former
// debug-bus gain inserted two variable multipliers in the release datapath.
assign fm_l = fmx_l;
assign fm_r = fmx_r;

assign int_n    = latch_intn;
assign nmi_trig = fm_intn;
assign nmi_clr  = nmi_clrr;
assign latch_we = k21_cs && !wr_n;
assign rom_hi   = A[15]? bank : {3'd0, A[14]};
assign rom_addr = {rom_hi[3:0], A[13:0]};
assign cpu_din  = rom_cs ? rom_data   :
                  ram_cs ? ram_dout   :
                  k39_cs ? k39_dout   :
                  k21_cs ? latch_dout :
                  fm_cs  ? fm_dout    : 8'hff;
// K054539 ROM-bank data-port reads use the same Z80 wait machinery as the
// program ROM. Ordinary PCM playback never asserts k39_rb_wait.
wire z80_rom_cs = rom_cs | k39_rb_wait;
wire z80_rom_ok = rom_cs ? rom_ok : ~k39_rb_wait;
assign cen_fm   = cen_4;
assign cen_fm2  = cen_2;
assign cen_g    = (ram_cs | rom_cs | k39_rb_wait) ? cen_4 : cen_8; // wait state for RAM/ROM access
// this is not 100% accurate, but quite close. It does not seem to have much of
// an effect anyway.

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        bank <= 0;
    end else begin
        if( bank_we ) { nmi_clrr, bank } <= cpu_dout[4:0];
    end
end

always @(*) begin
    mem_acc = !mreq_n && rfsh_n;
    rom_cs  = mem_acc && ((!A[15] && A[14]) || !A[14]) && !rd_n;
    ram_cs  = mem_acc && A[15:13]==3'b110;
    fm_cs   = mem_acc && A[15:12]==4'he &&  A[11];
    k39_cs  = mem_acc && A[15:12]==4'he && !A[11];
    k21_cs  = mem_acc && A[15:12]==4'hf && !A[11];
    bank_we = mem_acc && A[15:12]==4'hf &&  A[11] && !A[10];
end

// ---------------------------------------------------------------------------
// SONDA (solo sim): captura las escrituras/lecturas del Z80 al k054539 para
// compararlas con la traza REAL de MAME (debug/k539_trace.txt). Confirma si el
// Z80 del core programa el chip IGUAL que MAME (bug interno) o DISTINTO (bug
// aguas arriba). reg = A-0xe000 (0x000-0x22f), formato identico al tap de MAME.
// Inocua para sintesis (bajo `ifdef SIMULATION`).
// ---------------------------------------------------------------------------
`ifdef SIMULATION
integer fk39_w, fk39_r, fk39_ctx, fk39_fetch, fk39_span, flatch;
reg     k39w_d, k39r_d, k21r_d, latch_we_d, z80_fetch_d;
integer fz80, z80_diag_count;
reg     z80_bus_d;
integer k39w_seq, k39_fetch_count;
integer k39_span_seq, k39_span_clocks;
reg     k39_span_active, k39_span_cen_seen, k39_span_sload_seen;
reg     k39_span_bus_changed;
reg [10:0] k39_span_addr;
reg [ 7:0] k39_span_data;
initial begin
    fk39_w = $fopen("k539_core_writes.txt","w");
    fk39_r = $fopen("k539_core_reads.txt","w");
    fk39_ctx = $fopen("k539_core_context.txt","w");
    fk39_fetch = $fopen("k539_z80_fetch_context.txt","w");
    fk39_span = $fopen("k539_write_spans.txt","w");
    flatch = $fopen("snd_latch_reads.txt","w");
    fz80 = $fopen("z80_core_trace.txt","w");
    z80_diag_count = 0;
    k39w_seq = 0;
    k39_fetch_count = 0;
    k39_span_seq = 0; k39_span_clocks = 0;
    k39_span_active = 0; k39_span_cen_seen = 0;
    k39_span_sload_seen = 0; k39_span_bus_changed = 0;
    k39_span_addr = 0; k39_span_data = 0;
    k39w_d = 0; k39r_d = 0; k21r_d = 0; latch_we_d = 0;
    z80_bus_d = 0; z80_fetch_d = 0;
end
always @(posedge clk) begin
    k39w_d <= k39_cs && !wr_n;
    k39r_d <= k39_cs && !rd_n;
    k21r_d <= k21_cs && !rd_n;
    latch_we_d <= latch_we;
    z80_fetch_d <= !m1_n && !mreq_n && !rd_n;
    // Raw-clock write-span telemetry.  The chip-facing CPU port is sampled
    // at this 48 MHz clock, while a Z80 write can remain asserted across
    // several such edges.  Record the complete span and whether the PCM
    // sequencer reached S_LOAD during it; this distinguishes an authentic
    // single bus transaction from repeated level-sensitive key-on handling.
    if ((k39_cs && !wr_n) && !k39w_d) begin
        k39_span_active      <= 1'b1;
        k39_span_seq         <= k39w_seq;
        k39_span_clocks      <= 1;
        k39_span_addr        <= A[10:0] & 11'h3ff;
        k39_span_data        <= cpu_dout;
        k39_span_cen_seen    <= cen_pcm;
        k39_span_sload_seen  <= cen_pcm && (u_k054539.state == 4'd1);
        k39_span_bus_changed <= 1'b0;
    end else if (k39_cs && !wr_n) begin
        k39_span_clocks      <= k39_span_clocks + 1;
        k39_span_cen_seen    <= k39_span_cen_seen || cen_pcm;
        k39_span_sload_seen  <= k39_span_sload_seen ||
                                (cen_pcm && (u_k054539.state == 4'd1));
        k39_span_bus_changed <= k39_span_bus_changed ||
                                ((A[10:0] & 11'h3ff) != k39_span_addr) ||
                                (cpu_dout != k39_span_data);
    end else if (k39_span_active) begin
        $fwrite(fk39_span,
                "seq=%0d addr=%03x data=%02x raw_clocks=%0d cen_pcm_seen=%b sload_seen=%b bus_changed=%b\n",
                k39_span_seq, k39_span_addr, k39_span_data,
                k39_span_clocks, k39_span_cen_seen,
                k39_span_sload_seen, k39_span_bus_changed);
        k39_span_active <= 1'b0;
    end
    if( (k39_cs && !wr_n) && !k39w_d ) begin // flanco: 1 log por ciclo de bus
        $fwrite(fk39_w, "%03x %02x\n", A[10:0] & 11'h3ff, cpu_dout);
        // Domain-local accepted-write context.  Keep the legacy two-column
        // stream above unchanged for the strict MAME comparator; this paired
        // stream attributes an insertion/deletion to its Z80 producer without
        // deduplicating or otherwise altering the functional transaction.
        $fwrite(fk39_ctx,
                "seq=%0d pc=%04x sp=%04x ix=%04x iy=%04x addr=%03x data=%02x int_n=%b nmi_n=%b m1_n=%b cen_g=%b cpu_cen=%b latch_intn=%b\n",
                k39w_seq,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.PC,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.SP,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.IX,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.IY,
                A[10:0] & 11'h3ff, cpu_dout, int_n, nmi_n, m1_n,
                cen_g, cpu_cen, latch_intn);
        k39w_seq = k39w_seq + 1;
    end
    // Bounded opcode breadcrumbs around the first mismatching K054539
    // sequence.  The device-write PC is the common store subroutine (2797),
    // so retain the caller path and stack depth without opening a full wave.
    if (k39w_seq >= 18 && k39_fetch_count < 12000 &&
        (!m1_n && !mreq_n && !rd_n) && !z80_fetch_d) begin
        $fwrite(fk39_fetch,
                "seq=%0d kseq=%0d pc=%04x op=%02x sp=%04x ix=%04x int_n=%b nmi_n=%b\n",
                k39_fetch_count, k39w_seq,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.PC,
                cpu_din,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.SP,
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.IX,
                int_n, nmi_n);
        k39_fetch_count = k39_fetch_count + 1;
    end
    if( (k39_cs && !rd_n) && !k39r_d )
        $fwrite(fk39_r, "%03x\n", A[10:0] & 11'h3ff);
    // lecturas del latch de comandos (68k->Z80): A[1:0] + dato leido + estado IRQ
    if( (k21_cs && !rd_n) && !k21r_d )
        $fwrite(flatch, "addr=%01x din=%02x intn=%b\n", A[1:0], latch_dout, int_n);

    // The parent POST's second K054321 exchange is the current first
    // divergence.  Keep this probe at the Z80 transaction boundary so the
    // response can be attributed to an instruction/ROM/interrupt issue,
    // rather than guessed from the 68k latch read alone.  The PC wire is
    // exposed by the T80s simulation model and is absent from synthesis.
    z80_bus_d <= (!mreq_n || !iorq_n) && (!rd_n || !wr_n);
    if (`BUCKY_TEST_PLUSARGS("Z80_DIAG") && z80_diag_count < 4000 &&
        ((!mreq_n || !iorq_n) && (!rd_n || !wr_n)) && !z80_bus_d) begin
        $fwrite(fz80, "pc=%04x a=%04x mreq=%b iorq=%b rd=%b wr=%b din=%02x dout=%02x latch=%b saddr=%01x\n",
                u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.PC,
                A, mreq_n, iorq_n, rd_n, wr_n, cpu_din, cpu_dout,
                latch_we, A[1:0]);
        z80_diag_count = z80_diag_count + 1;
    end
    if (`BUCKY_TEST_PLUSARGS("Z80_DIAG") && latch_we && !latch_we_d)
        $display("[Z80LATCH] pc=%04x port=%01x data=%02x intn=%b",
                 u_cpu.u_sysz80_nvram.u_z80wait.u_z80_devwait.u_cpu.u_cpu.PC,
                 A[1:0], cpu_dout, int_n);
end
`endif

jtframe_edge #(.QSET(0)) u_edge (
    .rst    ( rst       ),
    .clk    ( clk       ),
    .edgeof ( nmi_trig  ),
    .clr    ( nmi_clr   ),
    .q      ( nmi_n     )
);
/* verilator tracing_off */
jtframe_sysz80 #(`ifdef SND_RAMW .RAM_AW(`SND_RAMW), `endif .CLR_INT(1)) u_cpu(
    .rst_n      ( ~rst      ),
    .clk        ( clk       ),
    .cen        ( cen_g     ),
    .cpu_cen    ( cpu_cen   ),
    .int_n      ( int_n     ),
    .nmi_n      ( nmi_n     ),
    .busrq_n    ( 1'b1      ),
    .m1_n       ( m1_n      ),
    .mreq_n     ( mreq_n    ),
    .iorq_n     ( iorq_n    ),
    .rd_n       ( rd_n      ),
    .wr_n       ( wr_n      ),
    .rfsh_n     ( rfsh_n    ),
    .halt_n     (           ),
    .busak_n    (           ),
    .A          ( A         ),
    .cpu_din    ( cpu_din   ),
    .cpu_dout   ( cpu_dout  ),
    .ram_dout   ( ram_dout  ),
    // ROM access
    .ram_cs     ( ram_cs    ),
    .rom_cs     ( z80_rom_cs ),
    .rom_ok     ( z80_rom_ok )
);
/* verilator tracing_off */
jt51 u_jt51(
    .rst        ( rst       ), // reset
    .clk        ( clk       ), // main clock
    .cen        ( cen_fm    ),
    .cen_p1     ( cen_fm2   ),
    .cs_n       ( !fm_cs    ), // chip select
    .wr_n       ( wr_n      ), // write
    .a0         ( A[0]      ),
    .din        ( cpu_dout  ), // data in
    .dout       ( fm_dout   ), // data out
    .ct1        (           ),
    .ct2        (           ),
    .irq_n      ( fm_intn   ),
    // Low resolution output (same as real chip)
    .sample     (           ), // marks new output sample
    .left       (           ),
    .right      (           ),
    // Full resolution output
    .xleft      ( fmx_l     ),
    .xright     ( fmx_r     )
);

/* verilator tracing_on */
k054539 #(.VOLSHIFT(1)) u_k054539(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen_pcm   ),
    .timeout    ( k39_timeout ),
    // CPU interface
    .addr       ({A[9],A[7:0]}),
    .we         ( ~wr_n     ),
    .rd         ( ~rd_n     ),
    .cs         ( k39_cs    ),
    .din        ( cpu_dout  ),
    .dout       ( k39_dout  ),
    // ROM
    .rom_cs     ( pcm_cs    ),
    // K054539 exposes a wider internal byte address; the GX173 sample slot
    // consumes its complete 22-bit 4 MiB range.
    .rom_addr   ( pcm_addr_wide ),
    .rom_data   ( pcm_dout  ),
    .rom_ok     ( pcm_ok    ),
    .rb_wait    ( k39_rb_wait ),
    // Sound output (PCM puro — la FM va por su propio canal, ya no entra aqui)
    .left       ( pcm_l     ),
    .right      ( pcm_r     ),
    // debug
    .debug_bus  ( 8'd0      ),
    .st_dout    ( st_dout   )
);

jt054321 u_54321(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .maddr      ( main_addr ),
    .mdout      ( main_dout ),
    .mdin       ( pair_dout ),
    .mwe        ( pair_we   ),

    .saddr      ( A[1:0]    ),
    .sdout      ( cpu_dout  ),
    .sdin       ( latch_dout),
    .swe        ( latch_we  ),

    // Z80 bus control
    .snd_on     ( snd_irq   ),
    .siorq_n    ( iorq_n    ),
    .int_n      ( latch_intn)
);
`else
assign  main_din = 0;
assign  pcm_addr_wide = 0;
assign  pcm_cs   = 0;
assign  rom_addr = 0;
assign  st_dout  = 0;
initial rom_cs   = 0;
assign  { pair_dout, fm_l, fm_r, pcm_l, pcm_r } = 0;
`endif
endmodule
