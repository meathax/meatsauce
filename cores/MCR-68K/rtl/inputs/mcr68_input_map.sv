// -----------------------------------------------------------------------------
// mcr68_input_map.sv
//
// PER-TITLE INPUT CONDITIONING for the MCR-68k core. Takes one normalised,
// game-agnostic set of controls (already in MiSTer's own "active high =
// pressed" convention) and produces the three 16-bit port words the main-board
// bus mux reads back:
//
//     in0_word  -> the CPU's IN0 read      (mcr68_map 0x0D0000 / pigskin_map 0x1E0000)
//     in1_word  -> the CPU's IN1 read      (mcr68_map 0x0E0000)
//                  == pigskin_port_1_r     (pigskin_map 0x080000)
//     dsw_word  -> the CPU's DSW read      (mcr68_map 0x0F0000)
//                  == pigskin_port_2_r     (pigskin_map 0x0A0000)
//
// It also owns the two per-title input peripherals: the Williams 49-way stick
// pair (rtl/inputs/mcr68_joy49.sv).
//
// SOURCE OF TRUTH: MAME 0.289 D:\Arcade\AI\mame289\src\mame\bally\mcr68.cpp.
// Every bit below carries its line citation. Full derivation, the disagreement
// audit against tools/gen_mra.py, and the 49-way design rationale live in
// doc/rtl_inputs_multigame.md.
//
// ---------------------------------------------------------------------------
// CONVENTIONS
// ---------------------------------------------------------------------------
// * Every control INPUT to this module is ACTIVE HIGH (1 = pressed/closed).
// * Every port-word OUTPUT bit is the value the 68000 actually reads. MCR-68k
//   inputs are IP_ACTIVE_LOW, so a pressed control reads 0. The two exceptions
//   are called out at their bits:
//     - the 49-way translate49 nibbles are ACTIVE HIGH wire codes;
// * Unused/open bits follow MAME exactly: IP_ACTIVE_LOW IPT_UNUSED reads 1,
//   IP_ACTIVE_HIGH IPT_UNUSED reads 0. `map.unmap_value_high()` is irrelevant
//   here -- every one of these addresses IS mapped.
// * `dsw_in` is the DIP low byte AS THE CPU READS IT (already in the game's
//   own polarity). This module never re-polarises it: DIP meanings differ per
//   title and the OSD/MRA layer owns them (see doc/integration_requests/inputs.md).
//
// ---------------------------------------------------------------------------
// CONTRACT (rtl/mcr68_game_profile.svh)
// ---------------------------------------------------------------------------
// Rule 1 -- GAME_XENOPHOB must reproduce the verified behaviour bit-for-bit.
//   The XENOPHOB arm below is a transcription of the mapping already shipping
//   in Arcade-MCR68.sv:454-493, which is itself the verified reference. See
//   the "XENOPHOB PARITY" note on that arm.
// Rule 4 -- an unsupported profile must be inert and fail loudly in sim. The
//   default arm returns all-ones (every input released, DIPs open) so nothing
//   is asserted, plus a simulation-only $fatal.
//
// This module is NOT instantiated by rtl/mcr68_main_board.sv today; the
// current single-title build keeps its equivalent combinational mapping at the
// top level. It is the drop-in replacement for that block once the top level
// gains the analog ports listed in doc/integration_requests/inputs.md.
// -----------------------------------------------------------------------------

/* verilator lint_off IMPORTSTAR */
import mcr68_game_pkg::*;
/* verilator lint_on IMPORTSTAR */

`default_nettype none

module mcr68_input_map #(
    parameter mcr68_game_e GAME_STATIC      = GAME_XENOPHOB,
    parameter bit          RUNTIME_GAME_SEL = 1'b0,
    // Synchroniser depth for the genuinely asynchronous control bits.
    parameter int          SYNC_STAGES      = 2,
    parameter bit          SIM_FATAL_ON_BAD_PROFILE = 1'b1
) (
    input  wire              clk,
    input  wire              rst,        // active-high synchronous
    input  mcr68_game_e      game,       // used only when RUNTIME_GAME_SEL

    // ---- normalised controls, ACTIVE HIGH, asynchronous ------------------
    input  wire [2:0]        coin,        // COIN1, COIN2, COIN3
    input  wire [1:0]        start_btn,   // START1, START2
    input  wire              tilt,
    input  wire              service1,    // momentary SERVICE / SERVICE1
    input  wire              service_dip, // "Test" -- the PORT_SERVICE DIP
    // MiSTer joystick direction order: [0]=right [1]=left [2]=down [3]=up,
    // matching Arcade-MCR68.sv's existing joystick_N[3:0] usage.
    input  wire [3:0]        joy1,
    input  wire [3:0]        joy2,
    input  wire [3:0]        joy3,
    // Indexed by MAME BUTTON number: btnN[k] == that player's IPT_BUTTONk.
    input  wire [7:1]        btn1,
    input  wire [7:1]        btn2,
    input  wire [7:1]        btn3,

    // ---- 49-way analog axes (archrivl / pigskin) -------------------------
    // Signed, -128 = left/up .. +127 = right/down. Tie to 0 when the pad has
    // no analog stick; that reads as centre and the d-pad still works.
    input  wire signed [7:0] an_x1,
    input  wire signed [7:0] an_y1,
    input  wire signed [7:0] an_x2,
    input  wire signed [7:0] an_y2,

    // ---- DIP switches, low byte, in CPU-read polarity --------------------
    input  wire [7:0]        dsw_in,

    // ---- assembled port words --------------------------------------------
    output logic [15:0]      in0_word,
    output logic [15:0]      in1_word,
    output logic [15:0]      dsw_word,

    // ---- observability ----------------------------------------------------
    output logic [2:0]       dbg_pos_x1,
    output logic [2:0]       dbg_pos_y1,
    output logic [2:0]       dbg_pos_x2,
    output logic [2:0]       dbg_pos_y2
);

    // =========================================================================
    // Profile selection. Same shape as rtl/mcr68_addr_decode.sv so an
    // instantiation that connects neither `game` nor the new controls keeps
    // exactly the GAME_STATIC behaviour.
    // =========================================================================
    mcr68_game_e    sel_game;
    mcr68_profile_t prof;

    assign sel_game = RUNTIME_GAME_SEL ? game : GAME_STATIC;
    assign prof     = mcr68_profile(sel_game);

    // =========================================================================
    // Input synchronisation.
    //
    // The digital control bits arrive from hps_io/joystick decode and, on a
    // real board, from mechanical switches -- synchronise them with a
    // SYNC_STAGES flop chain before they can reach the CPU-visible port words.
    //
    // The multi-bit buses (analog axes and DIP byte) are NOT true
    // asynchronous crossings: hps_io drives them synchronously to clk_sys,
    // which is this module's clk in the current single-clock design. They get
    // ONE pipeline register for timing only. Do NOT treat that register as
    // making them CDC-safe -- if a future build feeds them from another clock
    // domain they need a proper handshake or gray-coded transfer, not a flop
    // chain (a per-bit chain on a multi-bit bus permits skewed sampling).
    // =========================================================================
    localparam int NSYNC = 3 + 2 + 3 + 12 + 21;   // see the packing below

    wire [NSYNC-1:0] async_in = {
        btn3, btn2, btn1,               // 21 bits
        joy3, joy2, joy1,               // 12 bits
        service_dip, service1, tilt,    // 3 bits
        start_btn,                      // 2 bits
        coin                            // 3 bits
    };

    logic [NSYNC-1:0] sync_q [SYNC_STAGES];
    integer s;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (s = 0; s < SYNC_STAGES; s = s + 1)
                sync_q[s] <= '0;
        end else begin
            sync_q[0] <= async_in;
            for (s = 1; s < SYNC_STAGES; s = s + 1)
                sync_q[s] <= sync_q[s-1];
        end
    end

    wire [NSYNC-1:0] sy = sync_q[SYNC_STAGES-1];

    wire [2:0] s_coin        = sy[2:0];
    wire [1:0] s_start       = sy[4:3];
    wire       s_tilt        = sy[5];
    wire       s_service1    = sy[6];
    wire       s_service_dip = sy[7];
    wire [3:0] s_joy1        = sy[11:8];
    wire [3:0] s_joy2        = sy[15:12];
    wire [3:0] s_joy3        = sy[19:16];
    /* verilator lint_off UNUSEDSIGNAL */
    wire [7:1] s_btn1        = sy[26:20];
    wire [7:1] s_btn2        = sy[33:27];
    // Player 3 exists only on xenophob, which uses BUTTON1..BUTTON3 -- the
    // upper bits are carried through the synchroniser for symmetry with
    // players 1/2 and to keep the packing arithmetic uniform, and are
    // intentionally unreferenced.
    wire [7:1] s_btn3        = sy[40:34];
    /* verilator lint_on UNUSEDSIGNAL */

    logic signed [7:0] r_an_x1, r_an_y1, r_an_x2, r_an_y2;
    logic        [7:0] r_dsw;
    always_ff @(posedge clk) begin
        if (rst) begin
            r_an_x1 <= 8'sd0; r_an_y1 <= 8'sd0;
            r_an_x2 <= 8'sd0; r_an_y2 <= 8'sd0;
            r_dsw   <= 8'hFF;
        end else begin
            r_an_x1 <= an_x1; r_an_y1 <= an_y1;
            r_an_x2 <= an_x2; r_an_y2 <= an_y2;
            r_dsw   <= dsw_in;
        end
    end

    // =========================================================================
    // 49-way sticks. pigskin PORT_REVERSEs both X axes and neither Y axis
    // (mcr68.cpp:1081,1087 vs :1084,1090); archrivl reverses nothing
    // (mcr68.cpp:952,955,958,961).
    // =========================================================================
    wire j49_invert_x = prof.joy_49way & prof.map_pigskin;  // pigskin only
    wire j49_invert_y = 1'b0;

    logic [3:0] code_x1, code_y1, code_x2, code_y2;

    mcr68_joy49 u_joy49_p1 (
        .invert_x   (j49_invert_x),
        .invert_y   (j49_invert_y),
        .analog_x   (r_an_x1),
        .analog_y   (r_an_y1),
        .dpad_up    (s_joy1[3]),
        .dpad_down  (s_joy1[2]),
        .dpad_left  (s_joy1[1]),
        .dpad_right (s_joy1[0]),
        .pos_x      (dbg_pos_x1),
        .pos_y      (dbg_pos_y1),
        .code_x     (code_x1),
        .code_y     (code_y1)
    );

    mcr68_joy49 u_joy49_p2 (
        .invert_x   (j49_invert_x),
        .invert_y   (j49_invert_y),
        .analog_x   (r_an_x2),
        .analog_y   (r_an_y2),
        .dpad_up    (s_joy2[3]),
        .dpad_down  (s_joy2[2]),
        .dpad_left  (s_joy2[1]),
        .dpad_right (s_joy2[0]),
        .pos_x      (dbg_pos_x2),
        .pos_y      (dbg_pos_y2),
        .code_x     (code_x2),
        .code_y     (code_y2)
    );

    // =========================================================================
    // Per-title port assembly.
    //
    // Written as explicit bit-indexed assignments (not concatenations) so each
    // line can carry its own mcr68.cpp citation and a reviewer can diff a
    // single bit against the INPUT_PORTS block without counting positions.
    // =========================================================================
    always_comb begin
        // Defaults = everything released, all DIPs open, nothing driven.
        // This is also the CONTRACT RULE 4 inert value.
        in0_word = 16'hFFFF;
        in1_word = 16'hFFFF;
        dsw_word = 16'hFFFF;

        case (sel_game)

        // -------------------------------------------------------------------
        // XENOPHOBE -- INPUT_PORTS_START(xenophob), mcr68.cpp:674-731
        //
        // XENOPHOB PARITY: this arm is a bit-for-bit transcription of the
        // mapping already shipping at Arcade-MCR68.sv:454-493 (the verified
        // reference -- frame 300 pixel-exact vs MAME). In particular:
        //   * IN0.13 is BUTTON3 and IN0.14 is BUTTON2 (mcr68.cpp:688-689) --
        //     note the swap versus every other title. Preserved here via
        //     btn1[3]/btn1[2]. The MRA names the pad fields in MAME BUTTON
        //     order: BUTTON1 "Fire", BUTTON2 "Left Button", BUTTON3
        //     "Right Button" (tools/gen_mra.py GAME_METADATA). Those are OSD
        //     labels only -- the bit placement below is MAME-exact and must
        //     not be reordered to follow a label change.
        //   * btn1[4] is deliberately unread here: Xenophobe exposes only
        //     BUTTON1..BUTTON3, while higher transport bits carry cabinet
        //     controls at the top-level boundary.
        //   * The cabinet has no START line; the top level ORs each player's
        //     Coin and Start controls onto that player's COIN input before
        //     they reach `coin[]`. That stays a top-level concern -- this
        //     module simply has no START bit to place for xenophob.
        // -------------------------------------------------------------------
        GAME_XENOPHOB: begin
            in0_word[0]     = ~s_coin[0];        // :676 COIN1
            in0_word[1]     = ~s_coin[1];        // :677 COIN2
            in0_word[2]     = ~s_coin[2];        // :678 COIN3
            in0_word[4:3]   = 2'b11;             // :679 0x0018 UNUSED (active low)
            in0_word[5]     = ~s_tilt;           // :680 TILT
            in0_word[6]     = ~s_service1;       // :681 SERVICE1
            in0_word[7]     = ~s_service_dip;    // :682 PORT_SERVICE
            in0_word[8]     = ~s_joy1[3];        // :683 P1 UP
            in0_word[9]     = ~s_joy1[2];        // :684 P1 DOWN
            in0_word[10]    = ~s_joy1[1];        // :685 P1 LEFT
            in0_word[11]    = ~s_joy1[0];        // :686 P1 RIGHT
            in0_word[12]    = ~s_btn1[1];        // :687 P1 BUTTON1
            in0_word[13]    = ~s_btn1[3];        // :688 P1 BUTTON3
            in0_word[14]    = ~s_btn1[2];        // :689 P1 BUTTON2
            in0_word[15]    = 1'b1;              // :690 UNUSED

            in1_word[0]     = ~s_joy2[3];        // :693 P2 UP
            in1_word[1]     = ~s_joy2[2];        // :694 P2 DOWN
            in1_word[2]     = ~s_joy2[1];        // :695 P2 LEFT
            in1_word[3]     = ~s_joy2[0];        // :696 P2 RIGHT
            in1_word[4]     = ~s_btn2[1];        // :697 P2 BUTTON1
            in1_word[5]     = ~s_btn2[3];        // :698 P2 BUTTON3
            in1_word[6]     = ~s_btn2[2];        // :699 P2 BUTTON2
            in1_word[7]     = 1'b1;              // :700 UNUSED
            in1_word[8]     = ~s_joy3[3];        // :701 P3 UP
            in1_word[9]     = ~s_joy3[2];        // :702 P3 DOWN
            in1_word[10]    = ~s_joy3[1];        // :703 P3 LEFT
            in1_word[11]    = ~s_joy3[0];        // :704 P3 RIGHT
            in1_word[12]    = ~s_btn3[1];        // :705 P3 BUTTON1
            in1_word[13]    = ~s_btn3[3];        // :706 P3 BUTTON3
            in1_word[14]    = ~s_btn3[2];        // :707 P3 BUTTON2
            in1_word[15]    = 1'b1;              // :708 UNUSED

            dsw_word[7:0]   = r_dsw;             // :710-729 SW1:1..8
            dsw_word[15:8]  = 8'hFF;             // :730 0xff00 UNUSED (active low)
        end

        // -------------------------------------------------------------------
        // BLASTED -- INPUT_PORTS_START(blasted), mcr68.cpp:802-851
        //
        // TWO TRAPS vs xenophob, both easy to copy wrong:
        //   * TILT moves from bit 5 to bit 4 (:807 vs :680).
        //   * IN1's direction order is UP,RIGHT,DOWN,LEFT (:819-826), NOT
        //     xenophob's UP,DOWN,LEFT,RIGHT (:693-696).
        // Blasted is a 2-player game whose only per-player control is
        // BUTTON1, and it has no START lines.
        // -------------------------------------------------------------------
        GAME_BLASTED: begin
            in0_word[0]     = ~s_coin[0];        // :804 COIN1
            in0_word[1]     = ~s_coin[1];        // :805 COIN2
            in0_word[2]     = 1'b1;              // :806 UNUSED (credit w/bill)
            in0_word[3]     = 1'b1;              // :807 UNUSED
            in0_word[4]     = ~s_tilt;           // :808 TILT  <-- bit 4, not 5
            in0_word[5]     = 1'b1;              // :809 UNUSED
            in0_word[6]     = ~s_service1;       // :810 SERVICE1
            in0_word[7]     = ~s_service_dip;    // :811 PORT_SERVICE
            in0_word[8]     = ~s_btn1[1];        // :812 P1 BUTTON1
            in0_word[9]     = ~s_btn2[1];        // :813 P2 BUTTON1
            in0_word[10]    = 1'b1;              // :814 UNUSED (credit 1 w/bill)
            in0_word[11]    = 1'b1;              // :815 UNUSED (credit 2 w/bill)
            in0_word[15:12] = 4'hF;              // :816 0xf000 UNUSED

            in1_word[0]     = ~s_joy1[3];        // :819 P1 UP
            in1_word[1]     = ~s_joy1[0];        // :820 P1 RIGHT
            in1_word[2]     = ~s_joy1[2];        // :821 P1 DOWN
            in1_word[3]     = ~s_joy1[1];        // :822 P1 LEFT
            in1_word[4]     = ~s_joy2[3];        // :823 P2 UP
            in1_word[5]     = ~s_joy2[0];        // :824 P2 RIGHT
            in1_word[6]     = ~s_joy2[2];        // :825 P2 DOWN
            in1_word[7]     = ~s_joy2[1];        // :826 P2 LEFT
            in1_word[15:8]  = 8'hFF;             // :827 0xff00 UNUSED

            dsw_word[7:0]   = r_dsw;             // :829-849 SW1:1..8
            dsw_word[15:8]  = 8'hFF;             // :850 0xff00 UNUSED
        end

        // -------------------------------------------------------------------
        // ARCH RIVALS -- INPUT_PORTS_START(archrivl), mcr68.cpp:905-962.
        //
        // init_archrivl (:1907-1919) REPLACES the plain portr("IN1") read at
        // 0x0E0000 with archrivl_port_1_r (:477-483):
        //
        //     (translate49[49WAYY2] << 12) | (translate49[49WAYX2] << 8) |
        //     (translate49[49WAYY1] <<  4) | (translate49[49WAYX1] << 0)
        //
        // The IN1 ioport is NOT read by that handler at all, and is declared
        // 0xffff IP_ACTIVE_HIGH IPT_UNUSED (:923) -- so under archrivl this
        // port word is PURE 49-WAY, all four nibbles, ACTIVE HIGH.
        // Nibble order here is  {Y2, X2, Y1, X1}  -- note pigskin uses the
        // OPPOSITE within-player order ({X, Y}); they are not interchangeable.
        // -------------------------------------------------------------------
        GAME_ARCHRIVL: begin
            in0_word[0]     = ~s_coin[0];        // :907 COIN1
            in0_word[1]     = ~s_coin[1];        // :908 COIN2
            in0_word[3:2]   = 2'b11;             // :909 0x000c UNUSED
            in0_word[4]     = ~s_tilt;           // :910 TILT  <-- bit 4
            in0_word[5]     = 1'b1;              // :911 UNUSED
            in0_word[6]     = ~s_service1;       // :912 SERVICE1
            in0_word[7]     = ~s_service_dip;    // :913 PORT_SERVICE
            in0_word[8]     = ~s_start[0];       // :914 START1
            in0_word[9]     = ~s_start[1];       // :915 START2
            in0_word[11:10] = 2'b11;             // :916 0x0c00 UNUSED
            in0_word[12]    = ~s_btn1[1];        // :917 P1 BUTTON1
            in0_word[13]    = ~s_btn1[2];        // :918 P1 BUTTON2
            in0_word[14]    = ~s_btn2[1];        // :919 P2 BUTTON1
            in0_word[15]    = ~s_btn2[2];        // :920 P2 BUTTON2

            in1_word[3:0]   = code_x1;           // :482 translate49(49WAYX1), port :952
            in1_word[7:4]   = code_y1;           // :481 translate49(49WAYY1), port :955
            in1_word[11:8]  = code_x2;           // :480 translate49(49WAYX2), port :958
            in1_word[15:12] = code_y2;           // :479 translate49(49WAYY2), port :961

            dsw_word[7:0]   = r_dsw;             // :925-948 SW1:1..8
            dsw_word[15:8]  = 8'hFF;             // :949 0xff00 UNUSED (active low)
        end

        // -------------------------------------------------------------------
        // PIGSKIN 621AD -- INPUT_PORTS_START(pigskin), mcr68.cpp:1028-1091,
        // read through pigskin_map's own two composite ports:
        //
        //   pigskin_port_1_r (:553-559), CPU 0x080000, -> in1_word
        //       IN1 | (translate49[49WAYX1] << 12) | (translate49[49WAYY1] << 8)
        //   pigskin_port_2_r (:562-568), CPU 0x0A0000, -> dsw_word
        //       DSW | (translate49[49WAYX2] << 12) | (translate49[49WAYY2] << 8)
        //
        // Both ports' upper bytes are declared IP_ACTIVE_HIGH IPT_UNUSED
        // (:1053, :1078) so they read 0 and the OR is clean. Under pigskin the
        // within-player nibble order is {X, Y} -- the MIRROR of archrivl's
        // {Y, X}. Both X axes are additionally PORT_REVERSEd (:1081, :1087),
        // handled inside mcr68_joy49 via invert_x.
        //
        // IN0 TRAP: pigskin SWAPS the two service bits relative to every other
        // title in this family -- PORT_SERVICE (the test DIP) is at bit 5
        // (:1034) and IPT_SERVICE1 (the momentary button) is at bit 6 (:1035).
        // xenophob/blasted/archrivl have exactly the opposite (SERVICE1 at 6,
        // PORT_SERVICE at 7).
        //
        // Pigskin's IN0 also carries a genuine 8-WAY P1 joystick at bits 8-11
        // (:1036-1039) in addition to the 49-way stick. Transcribed faithfully;
        // see doc/rtl_inputs_multigame.md for what is and is not known about
        // why both exist (DSW SW1:8 "Joystick: Standard/Rotated", :1075-1077).
        // -------------------------------------------------------------------
        GAME_PIGSKIN: begin
            in0_word[0]     = ~s_coin[0];        // :1030 COIN1
            in0_word[1]     = ~s_coin[1];        // :1031 COIN2
            in0_word[2]     = ~s_start[0];       // :1032 START1
            in0_word[3]     = ~s_start[1];       // :1033 START2
            in0_word[4]     = ~s_tilt;           // :1034 TILT  <-- bit 4
            in0_word[5]     = ~s_service_dip;    // :1035 PORT_SERVICE   <-- bit 5!
            in0_word[6]     = ~s_service1;       // :1036 SERVICE1       <-- bit 6!
            in0_word[7]     = 1'b1;              // :1037 IPT_UNKNOWN (active low)
            in0_word[8]     = ~s_joy1[3];        // :1038 P1 UP    (8-way, see note)
            in0_word[9]     = ~s_joy1[2];        // :1039 P1 DOWN
            in0_word[10]    = ~s_joy1[1];        // :1040 P1 LEFT
            in0_word[11]    = ~s_joy1[0];        // :1041 P1 RIGHT
            in0_word[12]    = ~s_btn1[1];        // :1042 P1 BUTTON1
            in0_word[13]    = ~s_btn1[2];        // :1043 P1 BUTTON2
            in0_word[14]    = ~s_btn1[3];        // :1044 P1 BUTTON3
            in0_word[15]    = 1'b1;              // :1045 UNUSED

            in1_word[3:0]   = 4'hF;              // :1048 0x000f UNUSED (active low)
            in1_word[4]     = ~s_btn2[1];        // :1049 P2 BUTTON1
            in1_word[5]     = ~s_btn2[2];        // :1050 P2 BUTTON2
            in1_word[6]     = ~s_btn2[3];        // :1051 P2 BUTTON3
            in1_word[7]     = 1'b1;              // :1052 UNUSED (active low)
            in1_word[11:8]  = code_y1;           // :558 translate49(49WAYY1) << 8
            in1_word[15:12] = code_x1;           // :557 translate49(49WAYX1) << 12

            dsw_word[7:0]   = r_dsw;             // :1055-1077 SW1:1..8
            dsw_word[11:8]  = code_y2;           // :568 translate49(49WAYY2) << 8
            dsw_word[15:12] = code_x2;           // :567 translate49(49WAYX2) << 12
        end

        // CONTRACT RULE 4 -- unsupported profile stays at the all-released
        // default assigned above.
        default: ;
        endcase
    end

`ifndef SYNTHESIS
    logic bad_profile_reported;
    initial bad_profile_reported = 1'b0;
    always @(sel_game) begin
        case (sel_game)
            GAME_XENOPHOB, GAME_BLASTED,
            GAME_ARCHRIVL, GAME_PIGSKIN: ;
            default: if (!bad_profile_reported) begin
                bad_profile_reported = 1'b1;
                $display("%%Error: mcr68_input_map: UNSUPPORTED GAME PROFILE (game=%0d) -- all inputs read released.", sel_game);
                if (SIM_FATAL_ON_BAD_PROFILE)
                    $fatal(1, "mcr68_input_map: unsupported game profile");
            end
        endcase
    end

    // Cross-check against the shared descriptor: the titles this file treats
    // as 49-way titles must be exactly the ones the profile marks.
    always @(sel_game or prof) begin
        if (((sel_game == GAME_ARCHRIVL) || (sel_game == GAME_PIGSKIN)) && prof.joy_49way !== 1'b1)
            $fatal(1, "mcr68_input_map: profile drift -- 49-way title with joy_49way=0");
    end
`endif

endmodule

`default_nettype wire
