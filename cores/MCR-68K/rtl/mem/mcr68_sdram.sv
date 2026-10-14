// =============================================================================
// mcr68_sdram.sv -- Bally/Midway MCR-68k (Xenophobe) external SDRAM controller.
//
// Adapted from the vendored, READ-ONLY reference `rtl/mem/yb_sdram_ref.sv`
// (Sega Y Board's 6-port, 2-CPU-sharing, burst-heavy open-row controller for
// the same physical MiSTer DE10-nano 128MB SDRAM daughterboard) per the
// approved plan, `C:\Users\meath\.claude\plans\you-a-makeing-a-fizzy-rabin.md`,
// and AGENTS.md's condensed hardware reference. This is NOT a port of that
// file -- it is a from-scratch controller for MCR-68k's much smaller, much
// simpler memory reality, reusing only the donor's PROVEN physical-module
// assumptions (see "What is kept from the donor" below), not its port count,
// arbitration width, or burst machinery.
//
// =============================================================================
// SCOPE DECISION -- what lives in SDRAM vs on-chip block RAM
// =============================================================================
// Per AGENTS.md's "Main CPU memory map" and "Sound board" sections, this
// core's memory regions are:
//
//   main CPU program ROM   256K  read-only, downloaded once at boot
//   sound CPU program ROM  256K  read-only, downloaded once at boot
//   gfx1 (tile) ROM         64K  read-only, downloaded once at boot
//   gfx2 (sprite) ROM      256K  read-only, downloaded once at boot
//   -------------------------------------------------------------- (SDRAM, this file)
//   main-board work RAM     16K  read/write, CPU-accessed every cycle
//   video RAM                4K  read/write, CPU + video-engine accessed
//   aux RAM                  4K  read/write, CPU-accessed
//   sprite RAM                4K  read/write, CPU + sprite-engine accessed
//   palette RAM             128B  write-only from CPU, read by colormix
//   sound RAM                4K  read/write, sound-CPU-accessed
//   -------------------------------------------------------------- (on-chip, elsewhere)
//
// Only the four ROM regions (832KB total) are wired to this controller.
// The six read/write RAM regions stay in on-chip dual-port block RAM,
// exactly as `rtl/mcr68_mem_sim.sv` and `rtl/snd/mcr68_snd_mem_sim.sv`
// already model for simulation -- for the real synthesis target those sim
// files' `always_ff`/array pattern maps directly onto inferred M10K/MLAB
// (see CLAUDE.md's "Diagnosing a design that does not fit" section for the
// inference pitfalls to avoid when that port lands), not onto this
// controller.
//
// Reasoning, confirmed against the donor's OWN port allocation before
// committing (per this task's instruction) rather than assumed by default:
// `yb_sdram_ref.sv`'s six read ports (p0..p5) plus its download write port
// are, without exception, ALL read-only ROM regions -- main/X/Y 68000
// program ROM, tile ROM, sprite ROM, aux Z80 ROM, Z80 ROM, sample ROM, V25
// program ROM. Nowhere does the donor expose a port for Y Board's work RAM,
// video RAM, sprite RAM, palette RAM, NVRAM or any other CPU-read/write
// scratch memory -- those regions are simply absent from yb_sdram_ref.sv's
// entire port list, confirming they live on-chip in that donor design too.
// This is exactly the split this file follows, not a novel assumption:
//   - Every SDRAM port below is a ROM region, downloaded once via the write
//     port while the CPUs are held in reset, then read-only for the rest of
//     the core's lifetime -- no CPU ever writes through p0-p3.
//   - Every small, frequently-written, low-latency-sensitive RAM (work RAM,
//     videoram, auxram, spriteram, paletteram, soundram -- 32.125KB total,
//     comfortably inside a handful of M10K/MLAB blocks) is deliberately kept
//     OFF this controller, matching the donor's own choice at 100x this
//     core's RAM footprint. Round-tripping every CPU RAM access through an
//     SDRAM arbiter (with its multi-cycle row-open/CAS latency) would add
//     real DTACK wait-states to accesses the donor itself never routes
//     through SDRAM, for no benefit -- on-chip dual-port RAM gives the CPU
//     and video/sprite engines independent, single-cycle simultaneous access
//     to the same storage, which SDRAM's single command bus cannot.
//
// =============================================================================
// Port count and arbitration width vs the donor -- why this is much smaller
// =============================================================================
// The donor serves THREE 68000-family CPUs sharing one ROM port (p0), a
// dedicated 8-word/128-bit sprite-ROM burst port (p2) built for a
// high-resolution System 32-derived video engine, plus 3 more single-word
// ports for two auxiliary sound CPUs and a sample ROM -- six read ports
// total, because Y Board genuinely has six independent hot ROM readers.
//
// MCR-68k has exactly TWO independent bus masters that ever read ROM (main
// 68000, sound 68000) plus two video-side ROM-fetch consumers (tile engine,
// sprite engine). The tile engine keeps its existing single-word cache
// contract. The production sprite engine is different: its line builder
// must fetch one complete four-plane 32-pixel row before the raster consumes
// it, so it uses the optional p3 packed-row transaction below. The row is
// returned atomically to the requester, while the controller performs the
// eight adjacent 16-bit SDRAM reads internally. The legacy single-word and
// two-word p3 contracts remain available for focused benches and fallback
// users.
// mcr68_gfx_rom_sim.sv's gfx1 port already decomposes into two independently
// addressable, WORD-ALIGNED half-region reads (see that file's derivation:
// the "byte A"/"byte B" pair for one tile row is 2 ADJACENT bytes, i.e. one
// natural 16-bit word, per half), and its gfx2 port decomposes into up to
// four independently addressable per-lane byte reads. Neither needs a
// wide/bursting SDRAM transaction to reproduce in hardware: a future
// synthesizable tile/sprite fetch engine (not part of this task) issues 2
// (gfx1) or up to 4 (gfx2) sequential single-word requests through the SAME
// uniform 16-bit port this file exposes, trading the sim model's N-way
// *combinational* parallelism for N sequential *clocked* SDRAM fetches --
// affordable because video runs at a ~10 MHz dot clock while clk_ram runs at
// ~85-100 MHz (roughly 8-10 clk_ram cycles per pixel dwell time), the same
// margin `mcr68_main_board.sv`'s integration note B already relies on for
// the tilemap engine's existing 2-cycle VRAM fetch FSM.
//
// p0-p2 remain ordinary single 16-bit transactions. The p3 compatibility
// port is also single-word, while p3_burst returns two adjacent words and
// p3_row returns eight adjacent words atomically. The latter needs explicit
// rd_total/rd_issued/rd_captured bookkeeping and a cap_buf[0:7] assembly
// buffer; keeping that machinery local to the optional p3 path avoids adding
// variable-width behavior to the CPU and tile ports.
//
// Four read ports total (half the donor's six), one write/download port,
// same as the donor:
//   wr : download/write port -- ROM loading only, all 4 regions share it
//   p0 : main-board 68000 program ROM read  (mcr68_map,        256K)
//   p1 : sound-board 68000 program ROM read (soundsgood_map,   256K)
//   p2 : gfx1 tile-ROM fetch                (mcr68_bg_layout,   64K)
//   p3 : gfx2 sprite-ROM fetch              (mcr68_sprite_layout,256K)
//        plus optional packed 8-word row response for the production line
//        builder
//
// p0/p1 are NOT merged into one shared/arbitrated port the way the donor
// merges its 3 CPUs onto p0. That merge exists in the donor specifically
// because Y Board's three CPUs share ONE ROM region/image; MCR-68k's two
// CPUs read two entirely disjoint ROM images with no shared timing budget,
// so merging them would only add an unneeded internal arbiter layer for no
// port-count benefit (this controller already arbitrates all 4 read ports
// centrally regardless of how they are grouped) while making the main CPU's
// fetch latency depend on unrelated sound-CPU traffic. Two dedicated ports
// is both simpler to wire and strictly better for main-CPU fetch latency.
//
// =============================================================================
// What is kept from the donor -- physical-module assumptions, per this
// task's instruction to size this "for a Cyclone V DE10-nano 128MB SDRAM
// module (matching the donor's assumptions about the physical module)"
// =============================================================================
//   - 16-bit SDR SDRAM, CL2, sequential burst-length-1 MRS encoding.
//   - DQM is SHORTED to A[12:11] on this physical 128MB module (verified by
//     the donor against Arcade-IremM92_MiSTer and jtframe's
//     jtframe_sdram_bank_core.v -- "a limitation in MiSTer's 128MB module").
//     Reused verbatim: DQM is not an independent output here either.
//   - SDRAM_CKE tied permanently high -- this core never uses SDRAM
//     power-down/self-refresh, so a "stuck at VCC" report on this pin at
//     synthesis time is the expected, correct result (see CLAUDE.md's
//     "Never edit RTL... to silence a benign warning", which names this
//     exact pin/pattern as previously-broken-by-"fixing").
//   - Row/bank/column geometry: 13 row bits, 2 bank bits, 10 column bits
//     (SDRAM_A[12:0], SDRAM_BA[1:0] -- same port widths as the donor),
//     open-row tracking (a bank stays open across back-to-back same-row
//     accesses; only a genuine same-bank row miss or refresh closes it) and
//     the same command timings (tRP=2 cyc precharge-to-active, tRCD=2 cyc
//     ACT-to-CAS via RCD1/RCD2, CL2 read latency, 2-cycle write recovery,
//     ~700-clk_ram refresh interval / ~7 cyc tRC(ref) wait) -- all reused
//     from the donor's proven values, not re-derived from a datasheet here.
//
// =============================================================================
// What is DROPPED from the donor -- the 2nd physical SDRAM device
// =============================================================================
// The donor's 128MB module is populated with TWO physical 64MB chips, muxed
// onto one shared command/address/data bus via SDRAM_nCS acting as a
// device-select line (donor header: "on the 128 MB module it is the device
// selector, driven from address bit 26" -- NOT a traditional per-chip
// deselect; whichever value SDRAM_nCS holds is the ONLY device that ever
// sees a live command, and the other device simply never gets selected).
// The donor initializes and periodically refreshes BOTH devices because Y
// Board's own region map genuinely places live ROM data in device 1 (its
// sprite-ROM region).
//
// This core's total ROM footprint is 832KB -- under 1.3% of a SINGLE 64MB
// device, with vast headroom to spare. There is no reason to ever select
// device 1 at all. Per the standard SDRAM electrical contract (a chip that
// never receives a live command while its CS is held permanently at its
// "not this device" value never drives DQ and needs no MRS/refresh to
// remain electrically safe -- a permanently-unselected chip is exactly the
// deselected state a real controller relies on during ordinary NOP cycles),
// SDRAM_nCS is tied low here permanently: device 0 is always selected,
// device 1 is simply never chosen, matching how the donor's own idle NOPs
// already leave whichever device ISN'T `chip_sel` untouched every cycle.
// This drops the donor's entire second init/refresh sequence, the device
// dimension of open-row tracking (row_open[0:7] -> row_open[0:3], 4 banks
// instead of 8 device*bank slots), and the address-bit gymnastics the donor
// needed to fit a device-select bit at addr[26] alongside 13 row + 2 bank +
// 10 column bits (which is why the donor's column bit 9 is oddly parked at
// addr[25], divorced from column bits [8:0] at addr[9:1] -- there was no
// spare contiguous bit left once addr[26] was reserved for device select).
// With no device bit needed, this file's 25-bit word address field
// decomposes contiguously and naturally: column = addr[10:1] (10 bits),
// row = addr[23:11] (13 bits), bank = addr[25:24] (2 bits) -- exactly
// spanning addr[25:1], no scattered bits, nothing to explain twice.
//
// =============================================================================
// Suggested SDRAM base-address map (DOCUMENTATION ONLY -- not wired in this
// file, matching the donor's own convention: yb_sdram_ref.sv itself never
// references its sibling yb_pkg's SDR_xxx_BASE constants either; that
// wiring belongs to the future ROM-loader/CPU-bus-wrapper integration step,
// out of this task's scope). Each region gets its own bank (bank = word
// address bits [25:24], i.e. every 16MB) so back-to-back fetches within one
// region never contend for a row with a different region's traffic, mirror-
// ing the donor's own "region map deliberately gives each hot reader its
// own bank... so these rows never evict one another" rationale -- 16MB of
// headroom per 64-256KB region is generous on purpose, leaving room for a
// future larger MCR-68k title without redesigning this map:
//
//   SDR_MAIN_ROM_BASE  = 26'h000_0000  (bank 0, byte 0)       256K used of 16M
//   SDR_SOUND_ROM_BASE = 26'h100_0000  (bank 1, byte 16M)     256K used of 16M
//   SDR_GFX1_ROM_BASE  = 26'h200_0000  (bank 2, byte 32M)      64K used of 16M
//   SDR_GFX2_ROM_BASE  = 26'h300_0000  (bank 3, byte 48M)     256K used of 16M
//
// =============================================================================
// REQUEST CONTRACT (identical to the donor's, reused verbatim): one
// transaction per req RISING EDGE; the address (and write data/be) is
// sampled on that edge. A request held high is serviced exactly ONCE -- a
// requester expecting re-service per ack from a held level will hang.
// Requesters must be single-outstanding: drop req after (or pulse it
// before) each ack, and produce a fresh rising edge for the next
// transaction. ack is stretched to 2 clk cycles so a clk_sys-domain (/2
// synchronous) requester samples it exactly once.
// =============================================================================

`default_nettype none

module mcr68_sdram #(
    // clk-cycle interval between refresh requests. Default (~700) matches
    // the donor's proven value for a ~96.6 MHz clk_ram (~7.25us, comfortably
    // inside the 7.8us/row average-refresh-interval budget for a 64ms/8192-
    // row part). clk_ram's actual rate is not yet fixed for this core (no
    // sys_top/PLL integration exists at the time of writing -- see
    // mcr68_main_board.sv's assumption 2) -- retune this parameter once it
    // is, rather than assuming 96.6 MHz silently carries over.
    parameter int unsigned REFRESH_CYCLES = 700,
    // Optional eight-word gfx2 row transaction.  It is disabled by default
    // so the existing single-word/two-word port contract remains unchanged
    // for focused controller users; the production top enables it only after
    // the loader has row-packed gfx2.
    parameter bit P3_ROW_ENABLE = 1'b0
) (
    input  wire         clk,          // clk_ram
    input  wire         init,         // reset/init request (level-held)
    output logic        ready,

    // ---- SDRAM chip interface (single physical device -- see header) ----
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE,

    // ---- download/write port (word writes, ROM load; all 4 ROM regions
    //      below share this single port -- the future ROM loader selects
    //      the destination region purely by which base address it adds to
    //      the incoming ioctl offset, see the suggested base map above) ----
    input  wire          wr_req,
    input  wire  [25:1]  wr_addr,
    input  wire  [15:0]  wr_din,
    input  wire  [1:0]   wr_be,
    output logic         wr_ack,

    // ---- p0: main-board 68000 program ROM read ----
    // mcr68_map 000000-03FFFF (mcr68.cpp:598-613), 256K, word-addressed.
    input  wire          p0_req,
    input  wire  [25:1]  p0_addr,
    output logic [15:0]  p0_dout,
    output logic         p0_ack,

    // ---- p1: "Sounds Good" sound-board 68000 program ROM read ----
    // soundsgood_map 000000-03FFFF (midway_sound.cpp:591-598), 256K,
    // word-addressed. A SEPARATE 68000 program from p0 -- different CPU,
    // different image, different address space; not merged with p0 (see
    // header rationale).
    input  wire          p1_req,
    input  wire  [25:1]  p1_addr,
    output logic [15:0]  p1_dout,
    output logic         p1_ack,

    // ---- p2: gfx1 tile-ROM fetch ----
    // mcr68_bg_layout, 64K. One 16-bit word per request, word-addressed
    // into the flat gfx1.bin layout documented in
    // rtl/video/mcr68_gfx_rom_sim.sv's header (half 0 = 11d @ word 0x0000,
    // half 1 = 12d @ word 0x4000). A future tile-fetch engine issues one
    // request per half (2 total) per tile-row lookup -- see header.
    input  wire          p2_req,
    input  wire  [25:1]  p2_addr,
    output logic [15:0]  p2_dout,
    output logic         p2_ack,

    // ---- p3: gfx2 sprite-ROM fetch ----
    // mcr68_sprite_layout, 256K (4 ROM lanes x 64K). One 16-bit word per
    // request, word-addressed into the legacy flat gfx2.bin layout (lane 0
    // = 7j @ word 0x00000, lane1 = 8j @ 0x08000, lane2 = 9j @ 0x10000,
    // lane3 = 10j @ 0x18000). The production path uses p3_row below after
    // the loader's internal row permutation; this client remains the raw
    // fallback.
    input  wire          p3_req,
    input  wire  [25:1]  p3_addr,
    output logic [15:0]  p3_dout,
    output logic         p3_ack,

    // Optional two-word gfx2 plane-pair transaction. The first word is
    // returned in bits [15:0], the adjacent second word in [31:16]. It is
    // still one arbitrated grant, so the legacy sprite row path can reduce
    // four parallel-plane pairs to four grants without exposing partial data.
    input  wire          p3_burst_req,
    input  wire  [25:1]  p3_burst_addr,
    output logic [31:0]  p3_burst_dout,
    output logic         p3_burst_ack,

    // Optional eight-word gfx2 row transaction. The response contains eight
    // adjacent SDRAM words, with the first word in bits [15:0].
    input  wire          p3_row_req,
    input  wire  [25:1]  p3_row_addr,
    output logic [127:0] p3_row_dout,
    output logic         p3_row_ack
);

    logic [15:0] dq_out;
    logic        dq_oe;

    // No SDRAM power-down/self-refresh is used by this core -- CKE stuck at
    // VCC is the expected, correct synthesis report for that (CLAUDE.md).
    assign SDRAM_CKE = 1'b1;

    // Single physical device: device 0 is always selected, device 1 (if
    // populated on this module) is simply never chosen -- see header
    // "What is DROPPED from the donor" for why that is electrically safe
    // without any init/refresh sequence of its own.
    assign SDRAM_nCS = 1'b0;

    // DQM is shorted to A[12:11] on this physical 128MB module (see
    // header) -- reused verbatim from the donor. A[12:11] must be 2'b00 for
    // any cycle whose data must not be masked, and carries ~be during a
    // WRITE CAS.
    assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

    // commands {nRAS,nCAS,nWE}. nCS is driven by the continuous assign
    // above, not by this encoding -- CMD_NOP therefore only needs the
    // RAS/CAS/WE bits, no separate "deselected" encoding exists or is
    // needed since nCS never toggles in this single-device design.
    localparam bit [2:0] CMD_NOP   = 3'b111;
    localparam bit [2:0] CMD_ACT   = 3'b011;
    localparam bit [2:0] CMD_READ  = 3'b101;
    localparam bit [2:0] CMD_WRITE = 3'b100;
    localparam bit [2:0] CMD_PRE   = 3'b010;
    localparam bit [2:0] CMD_REF   = 3'b001;
    localparam bit [2:0] CMD_MRS   = 3'b000;

    logic [2:0] cmd;
    assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
    assign SDRAM_DQ = dq_oe ? dq_out : 16'hZZZZ;

    // ---- init sequencer ----
    logic [15:0] init_cnt;

    // ---- refresh scheduling: ~REFRESH_CYCLES clk_ram cycles/refresh ----
    logic [9:0] ref_cnt;
    logic       ref_pend;

    typedef enum logic [3:0] {
        ST_IDLE, ST_DISPATCH, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW,
        ST_WR, ST_WRRC, ST_PRE_XFER, ST_PRE_REF, ST_REFW
    } state_t;
    state_t state;

    // Grant encodes which of the 4 read ports (or the write port) owns the
    // in-flight transaction. Unlike the donor, every read port is a single
    // 16-bit word, so no per-port burst-length/capture-count bookkeeping is
    // needed -- one flag (is_write) and one 2-bit read-port index suffice.
    logic [1:0] grant;         // which read port (p0=0..p3=3) when !is_write
    logic [1:0] rr_next;       // next round-robin starting point among reads
    // One physical sprite-ROM row is four parallel-ROM pairs on the PCB.
    // The production adapter serializes that row into eight 16-bit p3 reads;
    // keep those reads together as a bounded service quantum so unrelated
    // CPU/tile traffic cannot multiply the row-fetch latency by four. After
    // eight consecutive p3 grants, one waiting non-p3 reader is mandatory.
    localparam logic [3:0] P3_ROW_WORDS = 4'd8;
    logic [3:0] p3_grant_run;
    logic [1:0] burst_mode;       // 0=single, 1=pair, 2=packed row
    logic       is_write;
    logic [25:1] xfer_addr;
    logic [15:0] din_r;
    logic [1:0]  be_r;
    logic [2:0]  wrrc_cnt;
    logic [1:0]  pre_cnt;
    logic [2:0]  refw_cnt;

    // Open-row tracking, indexed by bank only (4 slots) -- no device
    // dimension, see header. A bank stays open across back-to-back same-row
    // accesses; only a genuine same-bank row miss or a refresh closes it.
    logic [3:0]  row_open;
    logic [12:0] open_row [0:3];
    integer      ri;
    logic [1:0]  ack_stretch;   // acks held 2 clk cycles (clk_sys is /2 sync)

    // Normal reads capture one word; the optional gfx2 pair/row captures two
    // or eight adjacent words and acknowledges the response atomically.
    logic [3:0]  rd_total;
    logic [3:0]  rd_issued;
    logic [3:0]  rd_captured;
    logic [15:0] cap_buf [0:7];

    wire [1:0] xfer_bank = xfer_addr[25:24];

    // ---- Request mailboxes ----
    // Capture every transaction's metadata with its request; arbitration
    // may delay a lower-priority port after the producer moves on. Mirrors
    // the donor's own latched per-slot request interfaces.
    logic p0_pend, p1_pend, p2_pend, p3_pend, p3_burst_pend, p3_row_pend, wr_pend;
    logic [25:1] p0_addr_p, p1_addr_p, p2_addr_p, p3_addr_p,
                 p3_burst_addr_p, p3_row_addr_p, wr_addr_p;
    logic [15:0] wr_din_p;
    logic [1:0]  wr_be_p;

    // p3 gets bounded deadline priority for one serialized sprite-ROM row.
    // All other service remains round-robin; the eight-grant cap prevents a
    // busy sprite producer from starving either CPU or the tile preload.
    logic       read_valid;
    logic [1:0] read_grant;
    logic [1:0] read_mode;        // 0=single, 1=pair, 2=packed row
    logic       non_p3_pend;
    logic       p3_any_pend;
    always_comb begin
        non_p3_pend = p0_pend | p1_pend | p2_pend;
        p3_any_pend = p3_pend | p3_burst_pend | (P3_ROW_ENABLE && p3_row_pend);
        read_valid  = 1'b1;
        read_grant  = 2'd3;
        read_mode = 2'd0;

        if (p3_any_pend && ((p3_grant_run < P3_ROW_WORDS) || !non_p3_pend)) begin
            read_grant = 2'd3;
            if (P3_ROW_ENABLE && p3_row_pend)
                read_mode = 2'd2;
            else if (p3_burst_pend)
                read_mode = 2'd1;
        end else begin
            // p3 is absent or has consumed its complete eight-word quantum.
            // Choose one non-p3 reader using the existing rotation point.
            case (rr_next)
                2'd0: if (p0_pend) read_grant = 2'd0; else if (p1_pend) read_grant = 2'd1; else if (p2_pend) read_grant = 2'd2; else read_valid = 1'b0;
                2'd1: if (p1_pend) read_grant = 2'd1; else if (p2_pend) read_grant = 2'd2; else if (p0_pend) read_grant = 2'd0; else read_valid = 1'b0;
                default: if (p2_pend) read_grant = 2'd2; else if (p0_pend) read_grant = 2'd0; else if (p1_pend) read_grant = 2'd1; else read_valid = 1'b0;
            endcase
        end
    end

    // Latch each port on the RISING EDGE of its request -- see the donor's
    // header for the full derivation of why edge-detection (not a level
    // guard) is required to avoid a one-cycle drop window for a requester
    // that re-asserts req in direct response to its own previous ack.
    logic p0_req_d, p1_req_d, p2_req_d, p3_req_d, p3_burst_req_d,
          p3_row_req_d, wr_req_d;
    logic p0_ack_d2, p1_ack_d2, p2_ack_d2, p3_ack_d2, p3_burst_ack_d2,
          p3_row_ack_d2, wr_ack_d2;
    always_ff @(posedge clk) begin
        p0_ack_d2 <= p0_ack; p1_ack_d2 <= p1_ack;
        p2_ack_d2 <= p2_ack; p3_ack_d2 <= p3_ack;
        p3_burst_ack_d2 <= p3_burst_ack;
        if (P3_ROW_ENABLE) p3_row_ack_d2 <= p3_row_ack;
        wr_ack_d2 <= wr_ack;
        if (p0_ack && !p0_ack_d2) p0_pend <= 1'b0;
        if (p1_ack && !p1_ack_d2) p1_pend <= 1'b0;
        if (p2_ack && !p2_ack_d2) p2_pend <= 1'b0;
        if (p3_ack && !p3_ack_d2) p3_pend <= 1'b0;
        if (p3_burst_ack && !p3_burst_ack_d2) p3_burst_pend <= 1'b0;
        if (P3_ROW_ENABLE && p3_row_ack && !p3_row_ack_d2)
            p3_row_pend <= 1'b0;
        if (wr_ack && !wr_ack_d2) wr_pend <= 1'b0;
        p0_req_d <= p0_req; p1_req_d <= p1_req;
        p2_req_d <= p2_req; p3_req_d <= p3_req;
        p3_burst_req_d <= p3_burst_req;
        if (P3_ROW_ENABLE) p3_row_req_d <= p3_row_req;
        wr_req_d <= wr_req;
        // Every requester keeps at most one transaction outstanding (pulse,
        // or level held until ack), so an unqualified rising-edge latch is
        // exact -- see REQUEST CONTRACT in the header.
        if (p0_req && !p0_req_d) begin p0_pend <= 1'b1; p0_addr_p <= p0_addr; end
        if (p1_req && !p1_req_d) begin p1_pend <= 1'b1; p1_addr_p <= p1_addr; end
        if (p2_req && !p2_req_d) begin p2_pend <= 1'b1; p2_addr_p <= p2_addr; end
        if (p3_req && !p3_req_d) begin p3_pend <= 1'b1; p3_addr_p <= p3_addr; end
        if (p3_burst_req && !p3_burst_req_d) begin
            p3_burst_pend <= 1'b1;
            p3_burst_addr_p <= p3_burst_addr;
        end
        if (P3_ROW_ENABLE && p3_row_req && !p3_row_req_d) begin
            p3_row_pend <= 1'b1;
            p3_row_addr_p <= p3_row_addr;
        end
        if (wr_req && !wr_req_d) begin
            wr_pend <= 1'b1; wr_addr_p <= wr_addr;
            wr_din_p <= wr_din; wr_be_p <= wr_be;
        end
        if (init) begin
            {p0_pend, p1_pend, p2_pend, p3_pend, p3_burst_pend, p3_row_pend, wr_pend} <= '0;
            {p0_req_d, p1_req_d, p2_req_d, p3_req_d, p3_burst_req_d, p3_row_req_d, wr_req_d} <= '0;
            {p0_ack_d2, p1_ack_d2, p2_ack_d2, p3_ack_d2, p3_burst_ack_d2, p3_row_ack_d2, wr_ack_d2} <= '0;
            p0_addr_p <= '0; p1_addr_p <= '0; p2_addr_p <= '0; p3_addr_p <= '0;
            p3_burst_addr_p <= '0; p3_row_addr_p <= '0;
            wr_addr_p <= '0; wr_din_p <= '0; wr_be_p <= '0;
        end
    end

`ifdef SIMULATION
    // Contract watchdog (sim only): a request held high long after its pend
    // cleared means the requester expects per-ack re-service from a level --
    // the pre-edge-latch semantics. It would receive exactly one
    // transaction and hang silently in hardware; make that loud here.
    generate
        genvar gi;
        for (gi = 0; gi < 7; gi = gi + 1) begin : g_reqwatch
            logic [7:0] held;
            wire req_i  = gi==0 ? p0_req  : gi==1 ? p1_req  : gi==2 ? p2_req  :
                          gi==3 ? p3_req  : gi==4 ? p3_burst_req :
                          gi==5 ? (P3_ROW_ENABLE ? p3_row_req : 1'b0) : wr_req;
            wire pend_i = gi==0 ? p0_pend : gi==1 ? p1_pend : gi==2 ? p2_pend :
                          gi==3 ? p3_pend : gi==4 ? p3_burst_pend :
                          gi==5 ? (P3_ROW_ENABLE ? p3_row_pend : 1'b0) : wr_pend;
            always_ff @(posedge clk) begin
                if (init || !req_i || pend_i) held <= 8'd0;
                else if (held != 8'hff) begin
                    held <= held + 8'd1;
                    if (held == 8'd200)
                        $display("MCR68 SDRAM CONTRACT WARNING: port %0d req held %0d cycles after service -- held levels are serviced once, not per ack", gi, held);
                end
            end
        end
    endgenerate
`endif

    // Centre the SDRAM board interface with SDRAM_CLK forwarded at 180
    // degrees (top-level responsibility, not this file). Commands and write
    // data launched here have half a cycle of setup at the chip. CL2 read
    // data returns to this direct pin-to-register sample under the SDC
    // input-delay/multicycle constraints.
    logic [15:0] dq_in;
    logic [3:0]  cl_pipe;
    always_ff @(posedge clk) dq_in <= SDRAM_DQ;

`ifdef SIMULATION
    // DQM is the shorted A[12:11] net with 2-cycle READ latency. Row mode
    // issues adjacent CAS commands, but every READ still drives A[12:11]=00;
    // nothing may pipeline a masked command across a return window. A future
    // edit that violates this would look like sporadic ROM corruption rather
    // than a protocol error, so make it loud here (mirrors the donor's own
    // identical assertion).
    logic a_mask_flagged;
    always_ff @(posedge clk) begin
        if (init) a_mask_flagged <= 1'b0;
        else if (ready && cl_pipe != 0 && SDRAM_A[12:11] != 2'b00 && !a_mask_flagged) begin
            a_mask_flagged <= 1'b1;
            $display("MCR68 SDRAM ERROR: A[12:11]=%b during read return (cl_pipe=%b) -- DQM is shorted to these pins and would mask read data",
                     SDRAM_A[12:11], cl_pipe);
            $stop;
        end
    end
`endif

    task automatic deliver(input logic [15:0] word);
        // p0..p2 and the legacy p3 port return one word. The optional p3
        // pair/row clients assemble their complete response atomically so a
        // sprite consumer never observes a partially returned line.
        case (grant)
            2'd0: begin p0_dout <= word; p0_ack <= 1'b1; end
            2'd1: begin p1_dout <= word; p1_ack <= 1'b1; end
            2'd2: begin p2_dout <= word; p2_ack <= 1'b1; end
            default: begin
                if (burst_mode == 2'd2) begin
                    p3_row_dout <= {word, cap_buf[6], cap_buf[5], cap_buf[4],
                                    cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]};
                    p3_row_ack  <= 1'b1;
                end else if (burst_mode == 2'd1) begin
                    p3_burst_dout <= {word, cap_buf[0]};
                    p3_burst_ack  <= 1'b1;
                end else begin
                    p3_dout <= word;
                    p3_ack  <= 1'b1;
                end
            end
        endcase
    endtask

    always_ff @(posedge clk) begin
        cmd   <= CMD_NOP;
        dq_oe <= 1'b0;

        // acks: assert for 2 cycles so a clk_sys (=clk/2, synchronous)
        // requester always samples exactly one rising edge with ack high.
        if (ack_stretch != 0) ack_stretch <= ack_stretch - 1'd1;
        else begin
            p0_ack <= 1'b0; p1_ack <= 1'b0; p2_ack <= 1'b0; p3_ack <= 1'b0;
            p3_burst_ack <= 1'b0;
            p3_row_ack   <= 1'b0;
            wr_ack <= 1'b0;
        end

        if (init) begin
            init_cnt <= 16'hffff;
            ready    <= 1'b0;
            state    <= ST_IDLE;
            ref_pend <= 1'b0;
            ref_cnt  <= 10'd0;
            row_open <= 4'h0;
            for (ri = 0; ri < 4; ri = ri + 1) open_row[ri] <= 13'd0;
            pre_cnt     <= 2'd0;
            cl_pipe     <= 4'b0000;
            ack_stretch <= 0;
            rr_next     <= 2'd0;
            p3_grant_run <= 4'd0;
            burst_mode  <= 2'd0;
            rd_total    <= 4'd1;
            rd_issued   <= 4'd0;
            rd_captured <= 4'd0;
            for (ri = 0; ri < 8; ri = ri + 1) cap_buf[ri] <= 16'd0;
            p3_burst_dout <= 32'd0;
            p3_row_dout   <= 128'd0;
        end
        else if (!ready) begin
            init_cnt <= init_cnt - 1'd1;
            // Standard single-device SDRAM init: wait >100us, then PRE-ALL,
            // 8x AUTO REFRESH, MRS -- values reused verbatim from the
            // donor's own proven device-0 sequence (see header "What is
            // DROPPED" for why no second device's sequence is needed here).
            case (init_cnt)
                16'h0800: begin cmd <= CMD_PRE; SDRAM_A <= 13'h0400; end // PRE-ALL
                16'h07c0, 16'h0780, 16'h0740, 16'h0700,
                16'h06c0, 16'h0680, 16'h0640, 16'h0600: cmd <= CMD_REF;
                16'h0500: begin
                    cmd      <= CMD_MRS;
                    SDRAM_BA <= 2'b00;
                    SDRAM_A  <= 13'b000_0_00_010_0_000; // CL2, sequential, burst 1
                end
                16'h0010: SDRAM_A <= 13'h0000;
                16'h0001: ready <= 1'b1;
                default: ;
            endcase
        end
        else begin
            // refresh scheduling
            ref_cnt <= ref_cnt + 1'd1;
            if (ref_cnt == 10'(REFRESH_CYCLES)) begin ref_cnt <= 0; ref_pend <= 1'b1; end

            // Read capture after CL2 and the centred IOE register above.
            cl_pipe <= {cl_pipe[2:0], 1'b0};
            if (cl_pipe[3]) begin
                // A packed row has eight captures; indexing by bit zero
                // would overwrite slots 0/1 and return six stale words.
                cap_buf[rd_captured] <= dq_in;
                rd_captured <= rd_captured + 4'd1;
                if (rd_captured + 4'd1 == rd_total) begin
                    deliver(dq_in);
                    ack_stretch <= 2'd1; // hold ack this cycle + next
                end
            end

            case (state)
            ST_IDLE: begin
                if (ref_pend && cl_pipe == 0) begin
                    cmd      <= CMD_PRE;
                    SDRAM_A  <= 13'h0400;   // A10=1: all banks
                    row_open <= 4'h0;
                    refw_cnt <= 3'd1;       // tRP >= 2 cycles before REF
                    state    <= ST_PRE_REF;
                end
                else if (wr_pend | read_valid) begin
                    logic [25:1] a;
                    if (wr_pend) begin
                        a = wr_addr_p;
                        is_write <= 1'b1;
                    end
                    else begin
                        grant    <= read_grant;
                        is_write <= 1'b0;
                        rr_next  <= (read_grant == 2'd3) ? 2'd0 : read_grant + 1'd1;
                        burst_mode <= read_mode;
                        if (read_grant == 2'd3) begin
                            if (p3_grant_run < P3_ROW_WORDS) begin
                                if (read_mode == 2'd2)
                                    p3_grant_run <= P3_ROW_WORDS;
                                else if (read_mode == 2'd1 &&
                                         p3_grant_run >= (P3_ROW_WORDS - 4'd2))
                                    p3_grant_run <= P3_ROW_WORDS;
                                else if (read_mode == 2'd1)
                                    p3_grant_run <= p3_grant_run + 4'd2;
                                else
                                    p3_grant_run <= p3_grant_run + 4'd1;
                            end
                        end else begin
                            p3_grant_run <= 4'd0;
                        end
                        case (read_grant)
                            2'd0: a = p0_addr_p;
                            2'd1: a = p1_addr_p;
                            2'd2: a = p2_addr_p;
                            default: begin
                                if (read_mode == 2'd2)
                                    a = p3_row_addr_p;
                                else if (read_mode == 2'd1)
                                    a = p3_burst_addr_p;
                                else
                                    a = p3_addr_p;
                            end
                        endcase
                    end
                    xfer_addr <= a;
                    din_r     <= wr_din_p;
                    be_r      <= wr_be_p;
                    // Register arbitration before command generation, same
                    // dedicated dispatch cycle as the donor -- requesters
                    // already wait for ack, so the extra clk cycle changes
                    // latency but not semantics.
                    if (!wr_pend) begin
                        case (read_mode)
                            2'd2: rd_total <= 4'd8;
                            2'd1: rd_total <= 4'd2;
                            default: rd_total <= 4'd1;
                        endcase
                    end
                    rd_issued   <= 4'd0;
                    rd_captured <= 4'd0;
                    state <= ST_DISPATCH;
                end
            end

            ST_DISPATCH: begin
                // Bank-only row compare (no device dimension -- see header).
                if (row_open[xfer_bank] && open_row[xfer_bank] == xfer_addr[23:11]) begin
                    // Row hit: skip ACT and both tRCD cycles.
                    state <= is_write ? ST_WR : ST_RD;
                end
                else if (row_open[xfer_bank]) begin
                    // Same-bank row miss: close only that bank.
                    cmd      <= CMD_PRE;
                    SDRAM_BA <= xfer_bank;
                    SDRAM_A  <= 13'd0;      // A10=0: single-bank precharge
                    row_open[xfer_bank] <= 1'b0;
                    pre_cnt  <= 2'd1;       // tRP >= 2 cycles before ACT
                    state    <= ST_PRE_XFER;
                end
                else begin
                    state <= ST_ACT;
                end
            end

            ST_PRE_XFER: begin
                if (pre_cnt == 0) state <= ST_ACT;
                else pre_cnt <= pre_cnt - 1'd1;
            end

            ST_ACT: begin
                cmd      <= CMD_ACT;
                SDRAM_BA <= xfer_bank;
                SDRAM_A  <= xfer_addr[23:11];   // 13 row bits
                open_row[xfer_bank] <= xfer_addr[23:11];
                row_open[xfer_bank] <= 1'b1;
                state    <= ST_RCD1;
            end

            // tRCD >= 21ns = 2 cycles ACT->READ/WRITE
            ST_RCD1: state <= ST_RCD2;
            ST_RCD2: state <= is_write ? ST_WR : ST_RD;

            ST_WR: begin
                cmd      <= CMD_WRITE;
                SDRAM_BA <= xfer_bank;
                // A[12:11] = ~be -> shorted DQMH/DQML byte mask.
                // A[10]    = 0   -> no auto-precharge, keep row open.
                // A[9:0]   = column, contiguous (no scattered bit -- see header).
                SDRAM_A  <= {~be_r, 1'b0, xfer_addr[10:1]};
                dq_out   <= din_r;
                dq_oe    <= 1'b1;
                // No auto-precharge for download writes. A conservative
                // 2-cycle write-recovery gap is enough before another WRITE
                // on the same row; row changes still get an explicit PRE.
                wrrc_cnt <= 3'd2;
                state    <= ST_WRRC;
            end
            ST_WRRC: begin
                if (wrrc_cnt == 3'd2) begin wr_ack <= 1'b1; ack_stretch <= 2'd1; end
                if (wrrc_cnt == 0) state <= ST_IDLE;
                else wrrc_cnt <= wrrc_cnt - 1'd1;
            end

            ST_RD: begin
                cmd      <= CMD_READ;
                SDRAM_BA <= xfer_bank;
                // A[12:11] MUST be 00: shorted DQM pins, 2-cycle read
                // latency -- anything else here masks returning data.
                // A[10] = 0: no auto-precharge, row stays open.
                SDRAM_A    <= {2'b00, 1'b0, xfer_addr[10:1]};
                cl_pipe[0] <= 1'b1;
                if (rd_issued + 4'd1 < rd_total) begin
                    rd_issued <= rd_issued + 4'd1;
                    xfer_addr[10:1] <= xfer_addr[10:1] + 1'd1;
                    state <= ST_RD;     // issue adjacent CAS next cycle
                end
                else begin
                    state <= ST_RDW;    // row left open
                end
            end
            ST_RDW: begin
                // wait for the capture pipeline (delivery happens in the
                // capture logic above); also covers tRC for a single read.
                if (cl_pipe == 0) state <= ST_IDLE;
            end

            ST_PRE_REF: begin
                if (refw_cnt == 0) begin
                    cmd      <= CMD_REF;
                    row_open <= 4'h0;
                    ref_pend <= 1'b0;
                    refw_cnt <= 3'd6;      // tRC(ref) >= 63ns = 7 cycles total
                    state    <= ST_REFW;
                end
                else refw_cnt <= refw_cnt - 1'd1;
            end
            ST_REFW: begin
                if (refw_cnt == 0) state <= ST_IDLE;
                else refw_cnt <= refw_cnt - 1'd1;
            end
            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
