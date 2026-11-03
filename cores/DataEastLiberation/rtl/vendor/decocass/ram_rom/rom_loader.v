//============================================================================
//  DECO Cassette System — ROM/PROM Loader
//
//  Task 25 — Split hps_io download stream into BIOS, audio BIOS, MCU ROM,
//  palette PROM, dongle PROM, type-1 swap table, and metadata block per the
//  locked region map.
//
//  Region map (locked, so MRA files can target it):
//    $00000-$00FFF (4 KB)    → main BIOS ($F000-$FFFF)
//    $01000-$017FF (2 KB)    → audio BIOS ($F800-$FFFF)
//    $01800-$01BFF (1 KB)    → 8041 MCU ROM (cassmcu1.cpu)
//    $01C00-$01CFF (256 B)   → palette PROM
//    $01D00-$02CFF (4 KB)    → dongle PROM (types 2/3/4/5; Type 3 needs full 4 KB)
//    $02D00-$02DFF (256 B)   → spare / type-1 swap table
//    $02E00-$02EFF (256 B)   → game / dongle metadata
//    $02F00-$02FFF (256 B)   → reserved
//    $03000-$3FFFF (244 KB)  → cassette image (handled by cassette_loader)
//
//  Region selection: Address-based (ioctl_addr ranges). This is simpler than
//  using ioctl_index[2:0] as it doesn't require the MRA to change ioctl_index
//  per-region write sequence.
//
//  Metadata block ($01F00-$01FFF):
//    byte 0 = dongle_type (critical for auto-detection; exposed as output)
//    byte 1 = type-1 inmap LSB (reserved for future)
//    bytes 2-15 = reserved
//
//============================================================================

`timescale 1 ps / 1 ps

module rom_loader (
    input  wire        clk_sys,
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    input  wire [7:0]  ioctl_index,         // LSB selects region; currently only ioctl_addr is used

    // BIOS BRAM (main 6502, $F000-$FFFF = 4 KB)
    output reg         bios_we,
    output reg  [11:0] bios_addr,
    output reg  [7:0]  bios_dout,

    // Audio BIOS BRAM (audio 6502, $F800-$FFFF = 2 KB)
    output reg         abios_we,
    output reg  [10:0] abios_addr,
    output reg  [7:0]  abios_dout,

    // MCU ROM BRAM (port A of T48 mcu_pmem, task 15, 1 KB)
    output reg         mcurom_we,
    output reg  [9:0]  mcurom_addr,
    output reg  [7:0]  mcurom_dout,

    // Palette PROM (256 B)
    output reg         palprom_we,
    output reg  [7:0]  palprom_addr,
    output reg  [7:0]  palprom_dout,

    // Dongle PROM (4 KB, used by types 2/3/4/5; Type 3 uses full 12-bit counter)
    output reg         dongleprom_we,
    output reg  [17:0] dongleprom_addr,   // legacy 4 KB region uses low bits; 256 KB multigame via index 1
    output reg  [7:0]  dongleprom_dout,

    // Metadata block ($02E00):
    //   byte 0 = dongle_type
    //   byte 1 = game_id    (Type 1 inmap selector / per-game variant)
    //   byte 2 = swap_mode  (Type 1 swap-table index)
    output reg  [7:0]  metadata_dongle_type,
    output reg  [7:0]  metadata_game_id,
    output reg  [7:0]  metadata_swap_mode
);

    //------------------------------------------------------------------------
    // Region decode: combinational based on ioctl_addr
    //
    // When ioctl_wr is asserted and ioctl_download is active, we check which
    // region the address falls into and route the write to the appropriate
    // output port. The address lines map directly to BRAM address bits.
    //------------------------------------------------------------------------

    wire [24:0] addr = ioctl_addr;
    wire [7:0]  data = ioctl_dout;

    // Region selects (mutually exclusive)
    wire sel_bios     = (addr >= 25'h00000) && (addr <= 25'h00FFF);  // 4 KB
    wire sel_abios    = (addr >= 25'h01000) && (addr <= 25'h017FF);  // 2 KB
    wire sel_mcurom   = (addr >= 25'h01800) && (addr <= 25'h01BFF);  // 1 KB
    wire sel_palprom  = (addr >= 25'h01C00) && (addr <= 25'h01CFF);  // 256 B
    wire sel_dongprom = (addr >= 25'h01D00) && (addr <= 25'h02CFF);  // 4 KB
    wire sel_spare    = (addr >= 25'h02D00) && (addr <= 25'h02DFF);  // 256 B (type-1 swap table)
    wire sel_metadata = (addr >= 25'h02E00) && (addr <= 25'h02EFF);  // 256 B metadata
    // $02F00-$02FFF reserved padding before cassette region

    // Address offsets within each region (subtract region base)
    wire [11:0] bios_addr_rel     = addr[11:0];                     // 0x000-0xFFF
    wire [10:0] abios_addr_rel    = addr[10:0];                     // 0x000-0x7FF
    wire [9:0]  mcurom_addr_rel   = addr[9:0];                      // 0x000-0x3FF
    wire [7:0]  prom_addr_rel     = addr[7:0];                      // 0x00-0xFF (palette PROM)
    wire [11:0] dongprom_addr_rel = addr - 25'h01D00;               // 0x000-0xFFF (dongle PROM)
    wire [7:0]  metadata_addr_rel = addr[7:0];                      // 0x00-0xFF (metadata)

    //------------------------------------------------------------------------
    // Sequential writes on ioctl_wr pulse
    //------------------------------------------------------------------------

    always @(posedge clk_sys) begin
        // Clear all write enables by default
        bios_we       <= 1'b0;
        abios_we      <= 1'b0;
        mcurom_we     <= 1'b0;
        palprom_we    <= 1'b0;
        dongleprom_we <= 1'b0;

        // ROM-LOADER-IOCTL-FIX-2026-06-03: gate on ioctl_index==0 (the MRA <rom index="0">
        // stream). WITHOUT this, the DIP-switch download (ioctl_index==254, addr 0..7) was
        // routed by address into sel_bios and OVERWROTE BIOS $F000..$F003 (the reset JMP
        // table) with the DIP default bytes -> 6502 crashed/looped at $F00A. The DIP page
        // only appeared once an MRA <switches> block existed, which is exactly when booting
        // "broke." sw[] still loads via its own index==254 gate in the wrapper.
        // ORIGINAL (buggy): if (ioctl_download && ioctl_wr) begin
        if (ioctl_download && ioctl_wr && ioctl_index == 8'd0) begin
            if (sel_bios) begin
                // Main BIOS: route to BIOS BRAM
                bios_we    <= 1'b1;
                bios_addr  <= bios_addr_rel;
                bios_dout  <= data;
            end
            else if (sel_abios) begin
                // Audio BIOS: route to audio BIOS BRAM
                abios_we   <= 1'b1;
                abios_addr <= abios_addr_rel;
                abios_dout <= data;
            end
            else if (sel_mcurom) begin
                // MCU ROM: route to MCU BRAM (task 15)
                mcurom_we   <= 1'b1;
                mcurom_addr <= mcurom_addr_rel;
                mcurom_dout <= data;
            end
            else if (sel_palprom) begin
                // Palette PROM: route to palette PROM BRAM
                palprom_we   <= 1'b1;
                palprom_addr <= prom_addr_rel;
                palprom_dout <= data;
            end
            else if (sel_dongprom) begin
                // Dongle PROM: route to dongle PROM BRAM (4 KB, 12-bit addr)
                dongleprom_we   <= 1'b1;
                dongleprom_addr <= {6'd0, dongprom_addr_rel};
                dongleprom_dout <= data;
            end
            else if (sel_metadata) begin
                // Metadata block: latch dongle_type / game_id / swap_mode
                case (metadata_addr_rel)
                    8'h00: metadata_dongle_type <= data;
                    8'h01: metadata_game_id     <= data;
                    8'h02: metadata_swap_mode   <= data;
                    default: ; // reserved
                endcase
            end
            // sel_spare is ignored (type-1 swap table reserved for future)
        end
        else if (ioctl_download && ioctl_wr && ioctl_index == 8'd1 && !ioctl_addr[24:18]) begin
            // Multigame dongle ROM (Darksoft/Widel) on its OWN ioctl index — loaded straight by
            // ioctl_addr, no region math. Stage-1 keeps only the FIRST 256 KB (the menu lives at the
            // start of the ROM); the !ioctl_addr[24:18] gate drops everything past 256 KB so a 1 MB
            // ROM can't wrap over the menu. Full games need the rest -> SDRAM (Stage 2).
            dongleprom_we   <= 1'b1;
            dongleprom_addr <= ioctl_addr[17:0];
            dongleprom_dout <= data;
        end
    end

endmodule
