// =============================================================================
// mcr68_snd_mem_hw.sv -- synthesizable Sounds Good RAM path.
//
// Sound program ROM is served by the shared SDRAM ROM fabric in the
// production top level.  This module therefore contains only the 4 KiB
// full-width sound RAM and a harmless inert ROM select port retained for
// interface symmetry with the simulation model.
//
// --- Memory inference (CORRECTED 2026-09-12, audit finding SND-02) ---
// The two 2048x8 halves were previously read with an `always_comb` over the
// live index while still tagged `ramstyle = "M10K"`.  Quartus cannot infer
// block RAM from an unregistered read address: it either fails with
// `Error (276003)` or silently drops the array to registers plus a 2048-way
// mux.  This is the identical pattern already diagnosed and fixed for the
// main-board RAMs (rtl/mcr68_mem_hw.sv:88-101, 2026-08-13) and already correct
// in rtl/snd/williams_bg/williams_bg_mem_hw.sv:65-74, which is the template
// followed here:
//
//   * ONE flat unpacked array per byte lane (never multidimensional -- Quartus
//     17 silently drops those to logic with no diagnostic),
//   * ONE write port and ONE UNCONDITIONAL registered read in the SAME
//     always_ff, with no write-first bypass and no condition around the array
//     read,
//   * no reset on either the array or its read register.
//
// --- Why the DTACK gate is mandatory here, unlike the Williams board ---
// williams_bg_mem_hw can absorb the new read latency silently because its
// MC6809E bus cycle is ~20 clk long and the read is launched from the address.
// The Sounds Good 68000 is different: rtl/snd/sounds_good.sv asserts DTACK
// combinationally from `ram_cs` (":cpu_dtack_n"), so an ungated one-clock-late
// read would be sampled by FX68K on the bus phase that launched it and return
// the PREVIOUS word.  `ram_ready` is therefore exported and threaded into that
// DTACK term exactly the way `rom_ready` already is, so the CPU waits for the
// registered word instead of sampling a stale one.
//
// Write cycles do not wait: the array write completes in the clock it is
// presented, so ram_ready is asserted immediately for them and write bus
// timing is unchanged from the pre-fix model.
// =============================================================================

`default_nettype none

module mcr68_snd_mem_hw (
    input  logic        clk,
    input  logic [17:0] cpu_addr,
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic        cpu_uds_n,
    input  logic        cpu_lds_n,
    input  logic        cpu_we_n,
    input  logic        rom_cs,
    input  logic        ram_cs,
    // 1 = cpu_dout carries the word addressed by cpu_addr this clock.  Feeds
    // sounds_good.sv's DTACK term; see the header.
    output logic        ram_ready
);
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] ram_hi [0:2047];
    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] ram_lo [0:2047];

    wire [10:0] ram_idx   = cpu_addr[10:0];
    wire        cpu_write = !cpu_we_n;
    wire        ram_wr    = cpu_write && ram_cs;

    logic [7:0]  ram_hi_q, ram_lo_q;
    logic [10:0] ram_idx_q;
    logic        ram_cs_q, rom_cs_q, ram_wr_q;

    always_ff @(posedge clk) begin
        if (ram_wr) begin
            if (!cpu_uds_n) ram_hi[ram_idx] <= cpu_din[15:8];
            if (!cpu_lds_n) ram_lo[ram_idx] <= cpu_din[7:0];
        end

        ram_hi_q <= ram_hi[ram_idx];   // unconditional single read port
        ram_lo_q <= ram_lo[ram_idx];
    end

    always_ff @(posedge clk) begin
        ram_cs_q  <= ram_cs;
        rom_cs_q  <= rom_cs;
        ram_idx_q <= ram_idx;
        ram_wr_q  <= ram_wr;
    end

    // A registered read is valid only once the index that produced it still
    // matches the live index, and only if that capture clock was not itself a
    // write to the same cell (M10K read-during-write under `no_rw_check`
    // returns undefined data).  Writes ack in-cycle -- see the header.
    assign ram_ready = ram_wr |
                       (ram_cs_q & ~ram_wr_q & (ram_idx_q == ram_idx));

    always_comb begin
        cpu_dout = rom_cs_q ? 16'hFFFF : 16'h0000;
        if (ram_cs_q)
            cpu_dout = {ram_hi_q, ram_lo_q};
    end
endmodule

`default_nettype wire
