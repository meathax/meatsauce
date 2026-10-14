// Sound Z80 memory/IO decode. Covers the three documented address maps
// (suna8.cpp):
//   - hardhead_sound_map / hardhead_sound_io_map: hardhead, sparkman,
//     starfigh. ROM 0000-7fff, RAM c000-c7ff, ymsnd rw a000-a001, aysnd w
//     a002-a003 (chip register decode lives in suna8_sound_chips.sv,
//     wired as a peer of this module -- see chip_dout/chip_sel below),
//     ymsnd status_r c800, soundlatch2 w d000 (to main), soundlatch r
//     d800 (from main). IO: 01 nopr ("? IRQ Ack" -- no functional effect
//     needed here; the Z80's own M1+IORQ interrupt-acknowledge cycle
//     already clears the pending sound IRQ in suna8_core.sv regardless of
//     what address is read).
//   - rranger_sound_map: sranger. ROM 0000-7fff, RAM c000-c7ff, ym1 w
//     a000-a001, ym2 w a002-a003 (also suna8_sound_chips.sv), soundlatch2
//     w d000, soundlatch r d800. No IO map/ymsnd status register.
//   - brickzn_sound_map: hardhea2 AND brickzn. hardhea2's machine_config
//     literally calls brickzn(config) first and only overrides the main
//     CPU (suna8.cpp:2100), so it inherits brickzn's entire sound section
//     UNCHANGED -- this project's RTL previously ran hardhea2's sound CPU
//     against hardhead_sound_map's addresses and 32 KiB ROM window
//     instead, a real correctness bug (wrong RAM location, wrong latch
//     addresses, half-size ROM window) independent of chip synthesis,
//     fixed here. ROM 0000-bfff (48 KiB -- the physical ROM chip is only
//     32 KiB per suna8.cpp's ROM_LOAD, so 8000-bfff reads the region's
//     default/unpopulated fill, matching real hardware's address decoder
//     mapping a window wider than any specific ROM revision populates),
//     RAM e000-e7ff, ymsnd/aysnd at c000-c003 (write-only, no status_r
//     mapped), soundlatch2 w f000 (to the separate PCM Z80), soundlatch r f800
//     (from main).
//
// Audio chip register reads/writes (ymsnd/aysnd/ym1/ym2) are decoded and
// synthesized in suna8_sound_chips.sv, a peer module wired alongside this
// one at suna8_core.sv -- this module only arbitrates cpu_din between
// ROM/RAM/soundlatch/chip-status sources, it does not know the chip
// register protocols itself.
module suna8_sound_memory
(
    input  logic clk,
    input  logic reset,
    input  logic [2:0] profile_id,

    input  logic [15:0] cpu_addr,
    input  logic [7:0] cpu_dout,
    input  logic cpu_mreq_n,
    input  logic cpu_iorq,
    input  logic cpu_rd_n,
    input  logic cpu_wr_n,
    output logic [7:0] cpu_din,

    output logic [15:0] rom_addr,
    input  logic [7:0] rom_q,

    // From main CPU: main_latch_wr is a level held for the whole Z80 write
    // (about six raw clocks at ce_cpu = 1-in-4), not a one-cycle pulse. The
    // capture below is idempotent so that is harmless, but anything edge-
    // sensitive added here (a latch-write NMI, a FIFO) must detect the
    // rising edge first (2026-09-07 audit item 21.8).
    input  logic main_latch_wr,
    input  logic [7:0] main_latch_data,
    // SRanger's C004 status read acknowledges the sound-to-main latch.
    input  logic soundlatch2_clear,

    // To main CPU (currently unconsumed by any profile's main map except
    // hardhead's $DA80 read and sranger's soundstatus_r -- both already
    // implemented directly in suna8_main_memory.sv against this output).
    // For HARDHEA2/BRICKZN this is consumed by the separate PCM Z80 through
    // suna8_pcm.sv; the latch remains visible here for the other profiles'
    // sound-to-main status path.
    output logic [7:0] soundlatch2_q,

    // ymsnd's status byte, from suna8_sound_chips.sv's jtopl2 instance --
    // mirrored at $C800 for the hardhead_sound_map profiles only (real
    // hardware quirk, both a000/a001 rw and c800 r return the same
    // physical status register). brickzn_sound_map and rranger_sound_map
    // don't map a status register at all.
    input  logic [7:0] ym3812_dout
);

    import suna8_profile_pkg::*;

    // Registered (one cycle of latency) rather than combinational: Quartus
    // cannot map a combinational read onto Cyclone V's M10K block RAM and
    // reported this array "uninferred due to asynchronous read logic",
    // falling back to one register per bit. The sound CPU only runs on
    // sound_ce (itself gated to at most 1 in 4 raw clk cycles), so the
    // extra raw-clk cycle of latency resolves well before its next sample
    // point -- see suna8_sprite_ram.sv for the same fix and fuller
    // rationale.
    logic [7:0] work_ram [0:2047];
    logic [7:0] work_ram_q;
    logic [7:0] soundlatch_reg;
    logic [7:0] soundlatch2_reg;

    logic is_brickzn_group;   // HARDHEA2, BRICKZN (brickzn_sound_map)
    logic rom_selected;
    logic ram_selected;
    logic [10:0] ram_addr;
    logic [15:0] rom_top;      // exclusive upper bound of the ROM window
    logic [15:0] ram_base;     // RAM window base address
    logic [15:0] latch2_addr;  // soundlatch2 write address
    logic [15:0] latch_addr;   // soundlatch read address
    logic cpu_write;

    assign is_brickzn_group = (profile_id == PROFILE_HARDHEA2) ||
                               (profile_id == PROFILE_BRICKZN);
    assign cpu_write = !cpu_mreq_n && !cpu_iorq && !cpu_wr_n;
    assign soundlatch2_q = soundlatch2_reg;

    always_comb begin
        if (is_brickzn_group) begin
            rom_top     = 16'hc000;
            ram_base    = 16'he000;
            latch2_addr = 16'hf000;
            latch_addr  = 16'hf800;
        end else begin
            rom_top     = 16'h8000;
            ram_base    = 16'hc000;
            latch2_addr = 16'hd000;
            latch_addr  = 16'hd800;
        end
    end

    always_ff @(posedge clk)
        work_ram_q <= work_ram[ram_addr];

    always_comb begin
        rom_selected = 1'b0;
        ram_selected = 1'b0;
        ram_addr = 11'd0;
        rom_addr = 16'd0;
        cpu_din = 8'hff;

        if (cpu_addr < rom_top) begin
            rom_selected = 1'b1;
            rom_addr = cpu_addr;
        end else if ((cpu_addr >= ram_base) && (cpu_addr < ram_base + 16'h0800)) begin
            ram_selected = 1'b1;
            ram_addr = cpu_addr[10:0];
        end

        if (rom_selected)
            cpu_din = rom_q;
        else if (ram_selected)
            cpu_din = work_ram_q;
        else if (!is_brickzn_group && profile_id != PROFILE_SRANGER &&
                 ((cpu_addr == 16'ha000) || (cpu_addr == 16'ha001) || (cpu_addr == 16'hc800)))
            // hardhead_sound_map maps ymsnd .rw at a000-a001 (not .w-only
            // like aysnd) plus the same physical status byte mirrored
            // again at c800 -- all three addresses read the identical
            // jtopl2 status register.
            cpu_din = ym3812_dout;
        else if (cpu_addr == latch_addr)
            cpu_din = soundlatch_reg;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            soundlatch_reg <= 8'd0;
            soundlatch2_reg <= 8'd0;
        end else begin
            if (cpu_write && ram_selected)
                work_ram[ram_addr] <= cpu_dout;
            if (cpu_write && cpu_addr == latch2_addr)
                soundlatch2_reg <= cpu_dout;
            if (soundlatch2_clear)
                soundlatch2_reg <= 8'd0;
            if (main_latch_wr)
                soundlatch_reg <= main_latch_data;
        end
    end

endmodule
