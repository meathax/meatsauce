//============================================================================
//  Sega System 32 / Multi 32 for MiSTer
//  Common package: board descriptor, SDRAM region map, shared types
//  Reference: docs/DESIGN.md §3.4, §4.2, §9.3
//============================================================================

package s32_pkg;

    // ------------------------------------------------------------------
    // Public System 32 board timing contract
    // ------------------------------------------------------------------
    // The standard 837-7428 / 171-5964E board is documented with a
    // 32.2159 MHz master oscillator. The FPGA clock tree exposes the
    // corresponding 48.317307 MHz system clock; these fractional-enable
    // increments express the board-domain rates in one shared location.
    //
    // These are board facts, not a claim that the public schematics reveal
    // every custom-ASIC wait state. Unknown ASIC latency remains an explicit
    // verification item in docs/pcb/system32_evidence.json.
    localparam integer PCB_OSC_HZ       = 32_215_900;
    localparam integer PCB_CLK_SYS_HZ   = 48_317_307;
    localparam integer PCB_V60_HZ       = 16_107_950; // PCB_OSC_HZ / 2
    localparam integer PCB_Z80_HZ       =  8_053_975; // PCB_OSC_HZ / 4
    localparam integer PCB_PCM_HZ       = 12_500_000; // separate 50 MHz / 4

    // CE numerators use a 16-bit phase accumulator. Keep the rounded values
    // in one place so Standard and Real-V25 profiles cannot drift silently.
    localparam [15:0] PCB_V60_CE_INC   = 16'd21848;
    localparam [15:0] PCB_Z80_CE_INC   = 16'd10924;
    localparam [15:0] PCB_PCM_CE_INC   = 16'd16955;

    // Main-bus target classes are used by diagnostics and by the future
    // measured-wait-state model. They describe board resources, not games.
    localparam [3:0] PCB_TARGET_ROM    = 4'd0;
    localparam [3:0] PCB_TARGET_WRAM   = 4'd1;
    localparam [3:0] PCB_TARGET_VRAM   = 4'd2;
    localparam [3:0] PCB_TARGET_SPRRAM = 4'd3;
    localparam [3:0] PCB_TARGET_VIDEO  = 4'd4;
    localparam [3:0] PCB_TARGET_IO     = 4'd5;
    localparam [3:0] PCB_TARGET_SHARED = 4'd6;
    localparam [3:0] PCB_TARGET_PROT   = 4'd7;
    localparam [3:0] PCB_TARGET_OTHER  = 4'd15;

    function automatic [3:0] pcb_target_for_address(input logic [23:0] address);
        begin
            if (address < 24'h200000 || address[23:20] == 4'hf)
                pcb_target_for_address = PCB_TARGET_ROM;
            else if (address[23:20] == 4'h2)
                pcb_target_for_address = PCB_TARGET_WRAM;
            else if (address[23:20] == 4'h3)
                pcb_target_for_address = PCB_TARGET_VRAM;
            else if (address[23:20] == 4'h4)
                pcb_target_for_address = PCB_TARGET_SPRRAM;
            else if (address[23:20] == 4'h5 || address[23:20] == 4'h6)
                pcb_target_for_address = PCB_TARGET_VIDEO;
            else if (address[23:20] == 4'h7 || address[23:20] == 4'h8 ||
                     address[23:20] == 4'h9)
                pcb_target_for_address = PCB_TARGET_SHARED;
            else if (address[23:20] == 4'ha)
                pcb_target_for_address = PCB_TARGET_PROT;
            else if (address[23:20] == 4'hc || address[23:20] == 4'hd)
                pcb_target_for_address = PCB_TARGET_IO;
            else
                pcb_target_for_address = PCB_TARGET_OTHER;
        end
    endfunction

    // ------------------------------------------------------------------
    // SDRAM region bases (byte addresses) — DESIGN.md §4.2
    // ------------------------------------------------------------------
    localparam [24:0] SDR_MAINCPU_BASE  = 25'h000_0000; // 2 MB
    localparam [24:0] SDR_SOUNDCPU_BASE = 25'h020_0000; // 4 MB
    localparam [24:0] SDR_TILES_BASE    = 25'h060_0000; // 4 MB
    localparam [24:0] SDR_MULTIPCM_BASE = 25'h0A0_0000; // 4 MB
    localparam [24:0] SDR_MCU_BASE      = 25'h0E0_0000; // V25 ROM (64 KiB)
    localparam [24:0] SDR_SPARE_BASE    = SDR_MCU_BASE; // remainder of 2 MB slot
    localparam [24:0] SDR_SPRITES_BASE  = 25'h100_0000; // 16 MB

    // ------------------------------------------------------------------
    // Board descriptor (first 64 bytes of ioctl stream) — DESIGN.md §3.4
    // ------------------------------------------------------------------
    typedef struct packed {
        logic       multi32;       // V70 dual-screen board
        logic       _reserved0;    // was has_v25 -- OutRunners has no V25 MCU
        logic       _reserved1;    // was v25_table
        logic       has_adc;       // MSM6253 analog board
        logic       has_ppi;       // i8255 4/6-player board
        logic       has_motor_hle; // Rad Mobile 837-7753 mailbox responder
        logic       dual_pcb;      // reserved descriptor bit; unsupported
        logic [6:0] _reserved2;    // was prot_sel -- OutRunners is unprotected
        logic       comm_link_hle; // descriptor-selected comm-board link HLE
        // Sprite ROMs contain one, two, or four 4 MiB banks.  MAME mirrors
        // the controller's 2-bit bank selection modulo that physical count.
        // Old all-zero descriptors have no valid field and retain four banks.
        logic       sprite_bank_valid;
        logic [1:0] sprite_bank_mask; // 0/1/3 for 4/8/16 MiB respectively
        logic       flip_y;         // cabinet/game orientation (holo)
        logic       gun_aim;        // positional-gun input adapter (Alien3/JPark)
        logic       coin_swap;      // Alien3 cabinet trigger/start/coin wiring
        logic [1:0] analog_profile; // ADC source/default layout (ANALOG_*)
        logic       dual_comm_ff;   // dual-PCB comm RAM reset state (F1 Exhaust Note)
        logic       gear_toggle;    // edge-latched two-state cabinet gear input
        logic [1:0] digital_profile; // player-port layout (DIGITAL_*)
        // Multi 32 title-specific I/O/audio conventions.  This is deliberately
        // a small descriptor selector rather than a synthesis-time game macro:
        // all supported titles share the same dual-video/MultiPCM hardware.
        logic [2:0] game_profile;
    } board_desc_t;

    localparam [1:0] ANALOG_CENTERED = 2'd0; // sticks/guns: all channels rest at 80
    localparam [1:0] ANALOG_DRIVING  = 2'd1; // wheel=80, gas/brake=00
    localparam [1:0] ANALOG_ALL_FF   = 2'd2; // unknown pull-ups (dbzvrvs)
    localparam [1:0] DIGITAL_GENERIC = 2'd0;
    localparam [1:0] DIGITAL_RADM    = 2'd1; // bit0 unused, Light/Wiper on 1/2

    localparam [2:0] MULTI32_OUTRUNNERS   = 3'd0;
    localparam [2:0] MULTI32_TITLE_FIGHT  = 3'd1;
    localparam [2:0] MULTI32_HARD_DUNK   = 3'd2;
    localparam [2:0] MULTI32_STADIUM_CROSS = 3'd3;

    // HLE protection selects (prot_sel)
    localparam [6:0] PROT_NONE     = 7'd0;
    localparam [6:0] PROT_BRIVAL   = 7'd2;
    localparam [6:0] PROT_DARKEDGE = 7'd3;
    localparam [6:0] PROT_F1LAP    = 7'd4;
    localparam [6:0] PROT_DBZVRVS  = 7'd5;
    localparam [6:0] PROT_JLEAGUE  = 7'd6;

    // ------------------------------------------------------------------
    // V60 interrupt sources — DESIGN.md §5.5
    // ------------------------------------------------------------------
    localparam int MAIN_IRQ_VBSTART = 0;
    localparam int MAIN_IRQ_VBSTOP  = 1;
    localparam int MAIN_IRQ_SOUND   = 2;
    localparam int MAIN_IRQ_TIMER0  = 3;
    localparam int MAIN_IRQ_TIMER1  = 4;

    // Z80 sound interrupt sources — DESIGN.md §7.2
    localparam int SOUND_IRQ_YM3438 = 0;
    localparam int SOUND_IRQ_V60    = 1;

endpackage
