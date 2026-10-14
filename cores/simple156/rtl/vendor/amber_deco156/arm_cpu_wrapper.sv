/*  Night Slashers (Data East DECO 156) — ARM main CPU wrapper.

    Wraps the Amber 'amber23' ARMv2a core (OpenCores, with our reset +
    cache-off patches) and presents a simple arcade-style 32-bit bus to the
    Night Slashers top level, replacing the FX68K/68000 path that the core
    inherited from Boogie Wings.

    The DECO 156 is a 26-bit ARM2/3-class CPU. The board supplies its pacing
    clock-enable (ce_cpu), currently 28 MHz for MAME comparison. The
    Amber core advances only on ce ticks and is held otherwise via its native
    i_system_rdy stall input — so a low ce, OR a not-ready bus, both stall the
    pipeline cleanly without ever resetting it (needed for pause/savestate).

    Bus model (cache is disabled in the core, so every access is a single
    32-bit Wishbone transfer — no bursts):
      - bus_req      : 1 while the CPU wants a transfer
      - bus_we       : 1 = write, 0 = read
      - bus_addr     : 26-bit byte address (ARM addr[25:0]); word-aligned
      - bus_be       : 4-bit byte enables (which of the 4 bytes are active)
      - bus_wdata    : 32-bit write data
      - bus_rdata    : 32-bit read data (must be valid when bus_ready=1)
      - bus_ready    : target asserts to complete the transfer (= !wait)

    The target completes each captured bus transaction once and holds its
    response until request withdrawal or tuple change. Osman uses HOLD_LINE
    acknowledgement at CPU exception entry through irq_ack. Its 0x140000
    address is the music OKI port.
*/

module arm_cpu_wrapper
(
    input  wire        clk,            // system clock
    input  wire        ce_cpu,         // board-supplied CPU pacing tick
    input  wire        reset,          // active-high synchronous reset

    // Interrupts (level, active high). DECO156 uses a single vblank IRQ.
    input  wire        i_irq,          // vblank HOLD pending, cleared by irq_ack
    input  wire        i_firq,         // unused on Osman; tie 0

    // Arcade bus
    output wire [25:0] bus_addr,       // byte address, ARM addr[25:0]
    output wire        bus_req,        // transfer request
    output wire        bus_we,         // 1=write 0=read
    output wire [3:0]  bus_be,         // byte enables
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_ready,      // target ready (completes transfer)

    // ── Savestate scan (approccio B: estrazione/iniezione diretta reg fisici) ──
    input  wire        ss_load,        // 1: carica reg fisici da ss_wdata (a CPU ferma, dopo reset)
    input  wire [4:0]  ss_idx,         // indice word (0..20)
    input  wire [31:0] ss_wdata,
    output wire [31:0] ss_rdata,       // word selezionata (per il save)

    // An advancing decode transition into EXECUTE is safe to park the full
    // pipeline. Register-only savestate restore is not enabled by Osman.
    output wire        irq_ack,
    output wire        cpu_at_boundary
);

    // ------------------------------------------------------------------
    // Wishbone signals between Amber and this wrapper.
    // ------------------------------------------------------------------
    wire [31:0] wb_adr;
    wire [3:0]  wb_sel;
    wire        wb_we;
    wire [31:0] wb_dat_w;   // core -> bus
    wire        wb_cyc;
    wire        wb_stb;

    wire        wb_ack;     // wrapper -> core (combinational)
    wire [31:0] wb_dat_r;   // bus -> core

    // ------------------------------------------------------------------
    // Bus request / handshake. The adapted cache-disabled bridge retains
    // completion internally across CE gaps and presents one stable request
    // per CPU access. ACK stays transparent; only pipeline advancement is
    // paced by ce_cpu and completion of the active transaction.
    // ------------------------------------------------------------------
    wire access = wb_cyc & wb_stb;        // Amber wants a transfer

    wire bus_ok     = ~access | bus_ready;        // no access, or bus completed it
    wire system_rdy = ce_cpu & bus_ok;            // pace + wait-state (here only)

    assign wb_ack   = access & bus_ready;         // TRANSPARENT ack (ungated by ce)
    assign wb_dat_r = bus_rdata;

    assign bus_addr  = wb_adr[25:0];
    assign bus_req   = access;                    // request whenever Amber wants it
    assign bus_we    = wb_we;
    assign bus_be    = wb_sel;
    assign bus_wdata = wb_dat_w;

    // ------------------------------------------------------------------
    // Amber 'amber23' core (patched: i_reset added, CP15 removed, cache off).
    // ------------------------------------------------------------------
    // Execution of the IRQ vector operation is CPU acknowledgement of
    // MAME HOLD_LINE. No Osman MMIO acknowledgement exists at 0x140000.

    a23_core u_arm (
        .i_clk          ( clk        ),
        .i_reset        ( reset      ),
        .i_irq          ( i_irq      ),
        .i_firq         ( i_firq     ),
        .i_system_rdy   ( system_rdy ),

        .o_wb_adr       ( wb_adr     ),
        .o_wb_sel       ( wb_sel     ),
        .o_wb_we        ( wb_we      ),
        .i_wb_dat       ( wb_dat_r   ),
        .o_wb_dat       ( wb_dat_w   ),
        .o_wb_cyc       ( wb_cyc     ),
        .o_wb_stb       ( wb_stb     ),
        .i_wb_ack       ( wb_ack     ),
        .i_wb_err       ( 1'b0       ),

        // ── Savestate scan (approccio B) ──
        .i_ss_load      ( ss_load    ),
        .i_ss_idx       ( ss_idx     ),
        .i_ss_wdata     ( ss_wdata   ),
        .o_ss_rdata     ( ss_rdata   ),
        .o_exec_boundary( cpu_at_boundary ),
        .o_irq_ack      ( irq_ack     )
    );

endmodule
