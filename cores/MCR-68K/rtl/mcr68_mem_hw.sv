// =============================================================================
// mcr68_mem_hw.sv -- synthesizable MCR-68k main-board RAM path.
//
// The Verilator bring-up model in mcr68_mem_sim.sv owns host-file ROM loading
// and is deliberately not used by the production SDRAM_ROM=1 path.  This
// module contains only the on-chip RAM devices that remain after the four ROM
// regions move to external SDRAM.  The storage is split into flat byte arrays
// so Quartus 17 can classify each physical lane independently; there are no
// $fopen/$fread calls, host paths or simulation-only initialization semantics.
//
// The video engines currently consume asynchronous read ports.  Keeping that
// contract here is intentional: it preserves the validated tile/sprite timing
// while making the production path synthesizable.  The ramstyle requests are
// advisory; the post-map report must still be checked for actual inference.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module mcr68_mem_hw (
    input  logic        clk,
    input  logic [19:0] cpu_addr,
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic        cpu_uds_n,
    input  logic        cpu_lds_n,
    input  logic        cpu_we_n,

    input  logic        rom_cs,
    input  logic        work_ram_cs,
    input  logic        vram_cs,
    input  logic        extra_ram_cs,
    input  logic        sprite_cs,
    input  logic        palette_cs,

    input  logic [10:0] vram_rd_addr,
    output logic [7:0]  vram_rd_data,
    input  logic [8:0]  sprite_desc_addr,
    output logic [31:0] sprite_desc_data,
    input  logic [5:0]  palette_rd_addr,
    output logic [15:0] palette_rd_data,

    // ---- NVRAM save/load port, independent of the CPU port ----
    // Arch Rivals schematic sheet 2 (16-4001-K-101): work RAM is two 2064s,
    // 4B (LOW byte -- LDS side, this core's `work_lo` plane) is a
    // battery-backed non-volatile part; 4C (high byte) is plain static RAM.
    // Hometown Heroes rosters and high scores live in that low byte.  This
    // port lets the top-level wrapper stream `work_lo` to/from HPS storage
    // via hps_io's ioctl_download/ioctl_upload without disturbing the CPU
    // port's timing.  The integrator is responsible for holding
    // `nvram_wr`/`nvram_addr` inactive whenever the CPU could be issuing a
    // colliding access (e.g. during ioctl_download, when core_reset already
    // holds the CPU inert) -- no arbitration is done here beyond ordinary
    // last-write-wins on a shared array.
    input  logic         nvram_wr,
    input  logic [12:0]  nvram_addr,
    input  logic [7:0]   nvram_din,
    output logic [7:0]   nvram_dout
);
    localparam int WORK_WORDS  = 'h2000;
    localparam int SMALL_WORDS = 'h0800;
    localparam int PAL_WORDS   = 'h0040;

    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] work_hi  [0:WORK_WORDS-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] work_lo  [0:WORK_WORDS-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] extra_hi [0:SMALL_WORDS-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] extra_lo [0:SMALL_WORDS-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] vram     [0:SMALL_WORDS-1];
    // sprite_desc is split into four byte-lane arrays instead of one 32-bit
    // array written through a byte-select case: the same array written by
    // four different 8-bit-slice assignments defeated M10K/MLAB inference
    // for the reason documented on work_lo above, whereas the byte-plane
    // split used by work_hi/work_lo/extra_hi/extra_lo already infers
    // cleanly. Bit order preserved: b0=[7:0], b1=[15:8], b2=[23:16],
    // b3=[31:24], matching the original case's byte-lane mapping exactly.
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] sprite_desc_b0 [0:(SMALL_WORDS/4)-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] sprite_desc_b1 [0:(SMALL_WORDS/4)-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] sprite_desc_b2 [0:(SMALL_WORDS/4)-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] sprite_desc_b3 [0:(SMALL_WORDS/4)-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] palette_hi[0:PAL_WORDS-1];
    (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] palette_lo[0:PAL_WORDS-1];

    wire [12:0] work_idx  = cpu_addr[12:0];
    wire [10:0] small_idx = cpu_addr[10:0];
    wire [5:0]  pal_idx   = cpu_addr[5:0];
    wire        cpu_write = !cpu_we_n;

    // work_hi/work_lo/extra_hi/extra_lo registered CPU read data.  Read
    // unconditionally every clk so Quartus 17 infers a plain single-port
    // synchronous M10K read instead of building read-during-write bypass
    // logic to fake the async read this mux used to do directly from
    // work_ram_cs/extra_ram_cs -- the bypass logic for all of work/extra/
    // sound RAM together exceeded the device's register budget (Analysis &
    // Synthesis Error (276003), 2026-08-13). Safe to add one clk of read
    // latency: clk (CLK_HZ) runs ~6.5x faster than cpu_ce, and dtack_n_r
    // below already waits a full cpu_ce period after the address is valid
    // before acking, so the registered value is settled with wide margin
    // before the CPU ever samples it. vram/sprite/palette keep their
    // existing async CPU-side read (untouched -- not implicated in the
    // synthesis error) because they also feed a separate async video read
    // port whose validated tile/sprite timing must not change.
    logic [7:0] work_hi_q, work_lo_q, extra_hi_q, extra_lo_q;

    // work_lo is true dual-port: the CPU side (work_idx) and the NVRAM
    // bridge side (nvram_addr, see mcr68_nvram_bridge.sv -- download/upload
    // never overlap so this is a genuine second port, not contention) each
    // get their own self-contained always_ff so Quartus's altsyncram
    // true-dual-port template match applies to both read+write pairs on
    // this array. Folding the NVRAM read/write into the shared CPU-side
    // block below defeated M10K/MLAB inference for this array alone
    // (Error (170011)/(170048), 2026-08-21) and forced ~70k ALUTs of
    // register+mux logic instead of a handful of M10K blocks.
    always_ff @(posedge clk) begin
        if (nvram_wr) work_lo[nvram_addr] <= nvram_din;
        nvram_dout <= work_lo[nvram_addr];
    end

    always_ff @(posedge clk) begin
        if (cpu_write && work_ram_cs) begin
            if (!cpu_uds_n) work_hi[work_idx] <= cpu_din[15:8];
            if (!cpu_lds_n) work_lo[work_idx] <= cpu_din[7:0];
        end
        if (cpu_write && extra_ram_cs) begin
            if (!cpu_uds_n) extra_hi[small_idx] <= cpu_din[15:8];
            if (!cpu_lds_n) extra_lo[small_idx] <= cpu_din[7:0];
        end
        if (cpu_write && vram_cs && !cpu_lds_n)
            vram[small_idx] <= cpu_din[7:0];
        if (cpu_write && sprite_cs && !cpu_lds_n) begin
            case (small_idx[1:0])
                2'd0: sprite_desc_b0[small_idx[10:2]] <= cpu_din[7:0];
                2'd1: sprite_desc_b1[small_idx[10:2]] <= cpu_din[7:0];
                2'd2: sprite_desc_b2[small_idx[10:2]] <= cpu_din[7:0];
                default: sprite_desc_b3[small_idx[10:2]] <= cpu_din[7:0];
            endcase
        end
        if (cpu_write && palette_cs) begin
            if (!cpu_uds_n) palette_hi[pal_idx] <= cpu_din[15:8];
            if (!cpu_lds_n) palette_lo[pal_idx] <= cpu_din[7:0];
        end

        work_hi_q  <= work_hi[work_idx];
        work_lo_q  <= work_lo[work_idx];
        extra_hi_q <= extra_hi[small_idx];
        extra_lo_q <= extra_lo[small_idx];
    end

    always_comb begin
        // ROM is served by mcr68_rom_fabric when SDRAM_ROM=1.  The value here
        // is deliberately inert; mcr68_main_board selects mainrom_data first.
        cpu_dout = rom_cs ? 16'hFFFF : 16'h0000;
        if (work_ram_cs)
            cpu_dout = {work_hi_q, work_lo_q};
        else if (extra_ram_cs)
            cpu_dout = {extra_hi_q, extra_lo_q};
        else if (vram_cs)
            cpu_dout = {8'h00, vram[small_idx]};
        else if (sprite_cs) begin
            case (small_idx[1:0])
                2'd0: cpu_dout = {8'h00, sprite_desc_b0[small_idx[10:2]]};
                2'd1: cpu_dout = {8'h00, sprite_desc_b1[small_idx[10:2]]};
                2'd2: cpu_dout = {8'h00, sprite_desc_b2[small_idx[10:2]]};
                default: cpu_dout = {8'h00, sprite_desc_b3[small_idx[10:2]]};
            endcase
        end
        else if (palette_cs)
            cpu_dout = 16'h0000;
    end

    assign vram_rd_data   = vram[vram_rd_addr];
    assign sprite_desc_data = {sprite_desc_b3[sprite_desc_addr], sprite_desc_b2[sprite_desc_addr],
                                sprite_desc_b1[sprite_desc_addr], sprite_desc_b0[sprite_desc_addr]};
    assign palette_rd_data = {palette_hi[palette_rd_addr], palette_lo[palette_rd_addr]};

endmodule

`default_nettype wire
