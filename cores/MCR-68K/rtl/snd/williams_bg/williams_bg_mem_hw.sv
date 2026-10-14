// =============================================================================
// williams_bg_mem_hw.sv -- synthesizable Williams S11/S11C background board
// work-RAM path.
//
// Hardware counterpart of rtl/snd/williams_bg/williams_bg_mem_sim.sv, selected
// by williams_bg.sv's SDRAM_ROM parameter. Structured exactly like
// This Williams memory wrapper is separate from the removed alternate board:
// the program ROM is
// served by the shared external ROM fabric (williams_bg.sv drives
// bgrom_req/bgrom_addr and latches bgrom_data), so this module holds only the
// 2 KiB work RAM plus an inert rom_cs port kept for interface symmetry with the
// simulation model.
//
// The ROM *must* come from the fabric here, not from on-chip memory: the
// board's bank window spans 16 x 32 KiB = 512 KiB of the 576 KiB "bg:cpu"
// region, which is comparable to the whole 5CSEBA6U23 M10K budget (~700 KiB).
// Putting it on-chip is not an option, so there is no "small enough to inline"
// variant of this module.
//
// Region (s11c_bg_map, s11c_bg.cpp:285):
//   0000-07FF mirror 1800   RAM 2 KiB   -- indexed by A10:0, mirror folds free
//
// --- Memory inference ---
// The RAM is a single FLAT 2048x8 array (never a multidimensional unpacked
// array -- Quartus 17 silently drops those to logic with no diagnostic at all)
// with ONE write port and ONE UNCONDITIONAL registered read in the same
// always_ff, and no reset on the array or its read register: the shape Quartus
// needs to infer M10K. There is deliberately no write-first bypass and no
// condition wrapped around the array read; adding either is the documented way
// this project's memories fall back to logic ("uninferred due to asynchronous
// read logic"). Byte-wide and 2 KiB, so M10K rather than MLAB (a byte-wide MLAB
// wastes 12 of every 20 bits per row). See CLAUDE.md, "Diagnosing a design that
// does not fit".
//
// The one-clk read latency is invisible to the CPU: williams_bg.sv runs the
// 6809 at one bus cycle per CLK_HZ/CPU_HZ clk cycles (20 by default) and the
// read is launched from the address, not from the bus-cycle enable, per
// mc6809e.sv's clocking contract.
// =============================================================================

`default_nettype none

module williams_bg_mem_hw (
    input  logic        clk,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [18:0] rom_addr,   // inert here -- ROM comes from the fabric
    input  logic [15:0] cpu_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [7:0]  cpu_din,
    output logic [7:0]  cpu_dout,
    input  logic        cpu_we,     // already qualified with the bus-cycle enable
    input  logic        rom_cs,     // inert here -- ROM comes from the fabric
    input  logic        ram_cs
);

    (* ramstyle = "M10K, no_rw_check" *) logic [7:0] ram_mem [0:2047];

    wire [10:0] ram_idx = cpu_addr[10:0];

    logic [7:0] ram_q;
    logic       ram_cs_q;
    logic       rom_cs_q;

    always_ff @(posedge clk) begin
        if (cpu_we && ram_cs)
            ram_mem[ram_idx] <= cpu_din;

        ram_q <= ram_mem[ram_idx];   // unconditional single read port
    end

    always_ff @(posedge clk) begin
        ram_cs_q <= ram_cs;
        rom_cs_q <= rom_cs;
    end

    always_comb begin
        if      (ram_cs_q) cpu_dout = ram_q;
        else if (rom_cs_q) cpu_dout = 8'h00;   // ROM served by the fabric; this
                                                // value is never selected by
                                                // williams_bg.sv's mux when
                                                // SDRAM_ROM == 1
        else               cpu_dout = 8'h00;   // s11c_bg_map default unmap value
    end

endmodule

`default_nettype wire
