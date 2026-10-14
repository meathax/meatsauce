// =============================================================================
// mcr68_rom_fabric.sv -- MCR-68k (Xenophobe) SDRAM ROM-read adapter.
//
// SYNTHESIZABLE. Y Board's rtl/mem/yb_rom_fabric_ref.sv (vendored read-only
// reference) arbitrates EIGHT ROM-reading bus masters -- three CPUs sharing
// one round-robin port plus five independent graphics/sound clients -- down
// onto SIX differently-shaped SDRAM read ports (16/32/64/128-bit, some
// bursting). This core has only FOUR ROM-reading bus masters and no reason
// to share a port among them (see the SDRAM-port ASSUMPTION below), so this
// module needs none of Y Board's round-robin CPU-port arbitration or burst
// reassembly: it is a thin, mostly-combinational per-client adapter that
// (a) adds each client's fixed region base to its local address and
// (b) fixes up byte order/lane selection between how the loader placed
// bytes in SDRAM and what each client actually wants back. Genuinely no
// "arbitration" is needed under the assumed 1:1 port mapping below; if the
// real mcr68_sdram.sv instead shares fewer physical read ports across these
// four clients, round-robin arbitration would need to be ADDED here --
// flagged explicitly so the reconciliation is a scoped, visible change
// rather than a silent gap.
//
// -----------------------------------------------------------------------
// The four clients
// -----------------------------------------------------------------------
//   main -- main-CPU program-ROM reads, 000000-03FFFF (mcr68_map). 16-bit
//           word reads, word address 0..0x1FFFF (256K region / 2).
//   snd  -- sound-CPU program-ROM reads, 000000-03FFFF (soundsgood_map).
//           Same shape as main.
//   gfx1 -- tile-ROM (xeno_bg.11d/.12d) byte fetch. Byte address 0..0xFFFF
//           (64K region). Genuinely 8-bit-wide storage on real hardware
//           (see AGENTS.md's video-hardware summary and
//           rtl/video/mcr68_gfx_rom_sim.sv's own header) -- this port hands
//           back ONE raw byte, at whatever half (11d @ 0x0000-0x7FFF /
//           12d @ 0x8000-0xFFFF) the requested address falls in. Pen/tile
//           decode (code/row/pair -> byte-offset arithmetic, nibble
//           extraction, XOR-0xFF ROMREGION_INVERT) is explicitly OUT OF
//           SCOPE here, same as it is for mcr68_gfx_rom_sim.sv's PORT 1 --
//           this module only serves raw storage bytes.
//   gfx2 -- sprite-ROM (xeno_fg.7j/8j/9j/10j) raw byte fetch. The legacy
//           byte/word/pair clients remain available for diagnostics and
//           fallback users. Production sprite rows use the dedicated packed
//           `gfx2_row` client below so one request returns all sixteen bytes
//           for one 32-pixel row.
//
// -----------------------------------------------------------------------
// Client-port contract (all four)
// -----------------------------------------------------------------------
// Single-outstanding, edge-triggered, matching the assumed SDRAM contract
// this module passes straight through (see below): the client asserts
// `*_req` and holds both it and `*_addr` stable until the matching `*_ack`
// pulses (exactly one clk cycle), then drops `*_req` before issuing the
// next request. `*_data`/`*_ack` are registered outputs of this module
// (one clk of latency after the underlying SDRAM ack), not a raw
// combinational pass-through of the SDRAM port -- this normalizes whatever
// ack-stretching the SDRAM controller does (yb_sdram_ref.sv, this project's
// own reference contract, stretches acks to 2 cycles) into a single clean
// pulse per client, so a client never has to know about that stretching.
//
// -----------------------------------------------------------------------
// RECONCILED 2026-08-06 (Phase 5 integration pass): region base addresses
// below were originally a contiguous 0x000000-0x0D0000 layout, ASSUMED to
// match mcr68_rom_loader.sv. Read directly against BOTH the loader and the
// real rtl/mem/mcr68_sdram.sv (not assumed) and updated to mcr68_sdram.sv's
// own documented "suggested SDRAM base-address map": each region gets its
// own 16MB-aligned bank (bank = word addr[25:24]) so back-to-back fetches
// within one region never contend for a row with a different region's
// traffic. p0-p3_addr widened from [24:1] to [25:1] to match -- see
// mcr68_rom_loader.sv's matching "RECONCILED" note for the full derivation;
// these two files' region bases must stay numerically identical.
// -----------------------------------------------------------------------
//   main: byte 0x0000000 (bank 0)   snd: byte 0x1000000 (bank 1)
//   gfx1: byte 0x2000000 (bank 2)   gfx2: byte 0x3000000 (bank 3)
//   bg:   byte 0x1000000 (bank 1)   <- shared sound region
//
// -----------------------------------------------------------------------
// MULTI-GAME WIDENING 2026-08-13 -- wider gfx addresses
// -----------------------------------------------------------------------
// Two additive changes, exercised by the focused ROM/fabric contract bench:
//
//   1. gfx1_addr widened 16 -> 17 bits (archrivl/pigskin gfx1 is 128K, not
//      64K) and gfx2_addr 18 -> 19 bits (every title except Xenophobe has a
//      512K gfx2). The added bits are the MSBs; with them zero the computed
//      p2_addr/p3_addr are numerically unchanged. NOTE: this changes this
//      module's PORT WIDTHS, so the wires that drive them in Arcade-MCR68.sv
//      and rtl/video/mcr68_gfx_rom_sdram.sv must widen to match -- see
//      doc/integration_requests/rom_loader.md for the exact edits. Until
//      those land, the narrower drivers connect with a zero-extend warning
//      and behave exactly as they do today.
//
// -----------------------------------------------------------------------
// BG CLIENT ADDED 2026-08-14 -- Williams S11/S11C background sound board
// (Arch Rivals/Pigskin), a sixth client sharing p1
// -----------------------------------------------------------------------
// `bg` serves williams_bg.sv's MC6809E bg:cpu program ROM (rtl/mcr68_main_
// board.sv's bgrom_req/addr/data/ack, gated there by prof_rt.snd_williams_bg
// before ever reaching this module). Same raw-byte, address-LSB-lane-select
// contract as gfx1/gfx2 -- NOT the 68000 word-swap `snd` applies -- because
// the bg:cpu ROM is staged in the .mra as a flat, non-interleaved byte stream
// (confirmed against mra/Arch Rivals*.mra's and mra/Pigskin*.mra's own
// `<rom index="1">` blocks), unlike sg:cpu's `interleave output="16"` staging.
//
// Base address: mcr68_rom_loader.sv's region_base()/region_bytes() give bg:cpu
// the SAME region index (1) and SAME base (SND_BASE, byte 0x1000000, bank 1)
// as sg:cpu -- verified directly against that file's `region_bytes()` case
// 8'd1 comment ("sg:cpu (Sounds Good, 256K) OR bg:cpu (Williams Audio System,
// 576K) ... every set declares exactly one of the two, never both"). So `bg`
// reuses `snd`'s base address (SND_BASE_W below), NOT a new bank -- there is
// no separate "BG_BASE"; sg:cpu and bg:cpu never coexist in the same
// bitstream elaboration/title.
//
// Port sharing: `bg` shares p1 with `snd`, following the exact same grant/
// bg/snd exclusivity is strong: rtl/mcr68_game_pkg.sv's profile table sets
// snd_sounds_good on Xenophobe/Blasted and snd_williams_bg on ArchRivals/Pigskin --
// NEVER both for one `game` value -- and mcr68_main_board.sv masks
// sndrom_req/bgrom_req by those same two mutually-exclusive flags before they
// reach this module, so in any single bitstream's runtime only one of
// snd_req/bg_req is ever actually asserted. The grant FSM below is kept
// anyway (rather than a bare OR) so this module makes no assumption about
// that upstream masking and stays correct even if it were ever relaxed --
// defense in depth, zero extra cost when it never triggers.
// Address width: mcr68_rom_loader.sv stages 576K (SZ_576K = 589,824 bytes)
// for this region, but the REAL bg:cpu address generator (rtl/snd/
// williams_bg/williams_bg.sv: `rom_addr = {bank[3:0], cpu_addr[14:0]}`,
// forwarded straight out as bgrom_addr on rtl/mcr68_main_board.sv) can only
// ever produce byte 0..0x7FFFF -- a 4-bit bank register selecting one of 16
// 32KiB pages (MAME's own `configure_entries(0, 16, &rom[0], 0x8000)`),
// i.e. 512K, NOT 576K. bgrom_addr is therefore [18:0] (19 bits) on
// mcr68_main_board.sv, one bit NARROWER than the 20 bits a naive
// $clog2(589824) would suggest. This module's `bg_addr` port is sized to
// match that REAL 19-bit producer (verified directly against both files
// above, not assumed) -- the same width/shape as `gfx2_addr`. The loader's
// extra 64K (0x80000-0x8FFFF) stays resident in SDRAM but is simply never
// addressed by real hardware logic, same as any unbanked tail of a ROM
// region; not a truncation bug introduced here.
//
// -----------------------------------------------------------------------
// Byte-lane / word-order derivation (why main/snd need a swap, gfx1 uses a
// lane select, and production gfx2 uses a packed-row address)
// -----------------------------------------------------------------------
// mcr68_rom_loader.sv writes hps_io bytes byte-for-byte into ascending
// SDRAM byte addresses for maincpu, sg/bg:cpu and gfx1 (ioctl_dout[7:0] =
// first-streamed byte -> even SDRAM byte address, ioctl_dout[15:8] =
// second-streamed byte -> odd SDRAM byte address; see that file's header).
// Production gfx2 is the explicit exception: PACK_GFX2 permutes the incoming
// plane-concatenated stream into `{code,row,plane,byte}` rows. ASSUMING
// mcr68_sdram.sv packs SDRAM
// byte address 2n into read-port bits [7:0] and byte address 2n+1 into
// bits [15:8] of word n (the conventional little-endian byte-lane mapping
// used by every SDRAM controller surveyed in this project -- yb_sdram_ref.sv
// and third_party/Arcade-MCR3Mono_MiSTer/rtl/sdram.sv both drive DQML with
// the even/low byte and DQMH with the odd/high byte the same way):
//
//   main/snd (68000 program ROM): tools/prep_roms.py's interleave16(hi,lo)
//   places the FILE's even-offset byte as the CPU word's MSB (D15-D8) --
//   see rtl/mcr68_mem_sim.sv's own header ("Word i of the ROM =
//   {file_byte[2*i], file_byte[2*i+1]}"). SDRAM word i, per the mapping
//   above, holds {file_byte[2i+1] in bits[15:8], file_byte[2i] in
//   bits[7:0]} -- backwards from what the CPU wants. This module swaps the
//   two bytes on the way out: cpu_word = {sdram_word[7:0], sdram_word[15:8]}
//   -- the EXACT fix yb_rom_fabric_ref.sv already documents and applies for
//   its own main/subx/suby CPU ports ("The 68000 cores consume a
//   big-endian word, so cross that byte-lane boundary here").
//
//   gfx1 (raw tile ROM bytes): this client wants the RAW byte at a given file
//   offset back, with no CPU-word reassembly involved. The byte lives in
//   bits [7:0] of SDRAM word (X>>1) if X is even, or bits [15:8] of that
//   same word if X is odd. No byte-swap is needed -- only a lane SELECT.
//
//   gfx2 (production packed row): the row client does not use the raw byte
//   offset. Its byte address is already `{code,row,plane,byte}` and maps to
//   one contiguous 16-byte line. The controller returns eight SDRAM words
//   atomically; the fetcher consumes low byte first, plane 0 through plane 3.
//   The legacy gfx2 byte/word clients retain the ascending-stream contract
//   for diagnostic and fallback users.
//
// -----------------------------------------------------------------------
// SDRAM read-port ASSUMPTION (flag for reconciliation with the sibling
// mcr68_sdram.sv agent -- the single biggest open question this file
// leaves for integration)
// -----------------------------------------------------------------------
// This module assumes mcr68_sdram.sv exposes FOUR independent, DEDICATED
// 16-bit read ports (p0..p3, one per client below), each following
// yb_sdram_ref.sv's own documented port contract verbatim (that file is
// this project's only concrete SDRAM-controller reference and is treated
// as the pattern to match absent any other information):
//   - one transaction per req RISING EDGE; a request held high past its
//     ack is NOT re-serviced -- single-outstanding, edge-latched;
//   - address/data sampled on that same edge;
//   - ack is asserted for >=1 clk (yb_sdram_ref.sv stretches it to 2 clk
//     specifically so a clk/2 synchronous consumer samples exactly once --
//     this module's own edge-detected single-pulse registration above
//     tolerates ANY ack stretch length, so it is safe under either a
//     1-cycle or a multi-cycle ack).
// Ports are assumed DEDICATED (no sharing) because this core has only four
// clients total -- far fewer than Y Board's eight competing for six ports
// -- so giving each its own port is the simplest design that needs no
// arbitration logic at all in this file. If mcr68_sdram.sv instead exposes
// fewer than four read ports, this module's four `assign pN_req = ...`
// passthroughs would need to become a real round-robin arbiter (the
// yb_rom_fabric_ref.sv C_IDLE/C_WAIT/C_HOLD pattern is the proven template
// for that, already vendored read-only in this same directory) -- a scoped,
// visible change to make here, not elsewhere.
//
// This module also assumes all four SDRAM read ports, like the write port
// mcr68_rom_loader.sv assumes, are synchronous to the SAME `clk` this
// module runs on (yb_sdram_ref.sv's own `clk_ram`). If the real controller
// instead exposes ports in a different clock domain, `clk` here should
// simply be tied to whichever clock those ports are synchronous to -- this
// module makes no other clock-relative assumption.
// =============================================================================

`timescale 1ns / 1ps

module mcr68_rom_fabric #(
    // Opt-in packed gfx2 row client; the default preserves the existing
    // raw/word/pair contract for diagnostic users.
    parameter bit USE_GFX2_ROW = 1'b0
) (
    input  logic        clk,
    input  logic        rst,

    // -------------------------------------------------------------------
    // Client 0 -- main-CPU program ROM. Word address 0..0x1FFFF.
    // -------------------------------------------------------------------
    input  logic         main_req,
    input  logic [16:0]  main_addr,
    output logic [15:0]  main_data,
    output logic         main_ack,

    // -------------------------------------------------------------------
    // Client 1 -- sound-CPU program ROM. Word address 0..0x1FFFF.
    // -------------------------------------------------------------------
    input  logic         snd_req,
    input  logic [16:0]  snd_addr,
    output logic [15:0]  snd_data,
    output logic         snd_ack,

    // -------------------------------------------------------------------
    // Client 2 -- tile ROM (gfx1), raw byte fetch. Byte address 0..0xFFFF
    // (Xenophobe/blasted, 64K) or 0..0x1FFFF (archrivl/pigskin,
    // 128K). See "MULTI-GAME WIDENING" in the header.
    // -------------------------------------------------------------------
    input  logic         gfx1_req,
    input  logic [16:0]  gfx1_addr,
    output logic  [7:0]  gfx1_data,
    output logic         gfx1_ack,

    // -------------------------------------------------------------------
    // Client 3 -- sprite ROM (gfx2), raw byte fetch. Byte address
    // 0..0x3FFFF for Xenophobe (four concatenated 64K planes, ROM order
    // 7j/8j/9j/10j); 0..0x7FFFF (512K) for every other title.
    // -------------------------------------------------------------------
    input  logic         gfx2_req,
    input  logic [18:0]  gfx2_addr,
    output logic  [7:0]  gfx2_data,
    output logic         gfx2_ack,

    // Production sprite-row word client. `gfx2_word_addr` is an aligned
    // byte address in the same flat gfx2 region; the response preserves the
    // SDRAM lane convention, with byte address A in [7:0] and A+1 in [15:8].
    input  logic         gfx2_word_req,
    input  logic [18:0]  gfx2_word_addr,
    output logic [15:0]  gfx2_word_data,
    output logic         gfx2_word_ack,

    // Production sprite-row plane-pair client. One request returns two
    // adjacent raw gfx2 words, preserving the SDRAM byte-lane convention.
    input  logic         gfx2_burst_req,
    input  logic [18:0]  gfx2_burst_addr,
    output logic [31:0]  gfx2_burst_data,
    output logic         gfx2_burst_ack,

    // Packed production row: one request returns eight adjacent words (the
    // four gfx2 planes were permuted into one 16-byte SDRAM line by the
    // production ROM loader).
    input  logic         gfx2_row_req,
    input  logic [18:0]  gfx2_row_addr,
    output logic [127:0] gfx2_row_data,
    output logic         gfx2_row_ack,

    // -------------------------------------------------------------------
    // Client 4 -- Williams S11/S11C background-sound-board MC6809E bg:cpu
    // program ROM (archrivl/pigskin only), raw byte fetch, byte address
    // 0..0x7FFFF (512K -- the real 4-bit-bank-register address range; see
    // "BG CLIENT ADDED" header note). Shares p1 and SND_BASE with `snd`;
    // tie bg_req low on every other title.
    // -------------------------------------------------------------------
    input  logic         bg_req,
    input  logic [18:0]  bg_addr,
    output logic  [7:0]  bg_data,
    output logic         bg_ack,

    // -------------------------------------------------------------------
    // SDRAM controller read ports -- read directly against
    // rtl/mem/mcr68_sdram.sv (not assumed): word address, byte address
    // bits [25:1] -- 26-bit/64MB byte address space, bank = addr[25:24].
    // See "RECONCILED 2026-08-06" header note (widened from [24:1]).
    // -------------------------------------------------------------------
    output logic         p0_req,
    output logic [25:1]  p0_addr,
    input  logic [15:0]  p0_data,
    input  logic         p0_ack,

    output logic         p1_req,
    output logic [25:1]  p1_addr,
    input  logic [15:0]  p1_data,
    input  logic         p1_ack,

    output logic         p2_req,
    output logic [25:1]  p2_addr,
    input  logic [15:0]  p2_data,
    input  logic         p2_ack,

    output logic         p3_req,
    output logic [25:1]  p3_addr,
    input  logic [15:0]  p3_data,
    input  logic         p3_ack,
    output logic         p3_burst_req,
    output logic [25:1]  p3_burst_addr,
    input  logic [31:0]  p3_burst_data,
    input  logic         p3_burst_ack,
    output logic         p3_row_req,
    output logic [25:1]  p3_row_addr,
    input  logic [127:0] p3_row_data,
    input  logic         p3_row_ack
);

    // -------------------------------------------------------------------
    // Region base word addresses -- must stay numerically identical to
    // mcr68_rom_loader.sv's byte-address bases, shifted right by 1 (see
    // that file's "RECONCILED" note: one 16MB-aligned bank per region,
    // matching mcr68_sdram.sv's own suggested base-address map).
    // -------------------------------------------------------------------
    localparam logic [24:0] MAIN_BASE_W = 25'h000_0000; // 0x0000000 >> 1, bank 0
    localparam logic [24:0] SND_BASE_W  = 25'h080_0000; // 0x1000000 >> 1, bank 1
    localparam logic [24:0] GFX1_BASE_W = 25'h100_0000; // 0x2000000 >> 1, bank 2
    localparam logic [24:0] GFX2_BASE_W = 25'h180_0000; // 0x3000000 >> 1, bank 3
    // bg:cpu has NO base of its own -- it shares SND_BASE_W (region index 1),
    // never both loaded in the same bitstream. See "BG CLIENT ADDED" header.

    // -------------------------------------------------------------------
    // p1 ownership, shared two ways: `snd` (default/no grant) plus the
    // optional Williams `bg` client. `bg_grant` is
    // registered and can each only be RAISED on a cycle where snd_req is
    // low, so p1_req/p1_addr below stay a pure combinational passthrough of
    // the snd client whenever neither is granted -- the snd path gains no
    // latency and no registered request stage. See "MULTI-GAME WIDENING"
    // and "BG CLIENT ADDED" in the header.
    //
    // Two details the SDRAM contract forces (mcr68_sdram.sv services one
    // transaction per req RISING EDGE, and the client contract has a client
    // hold req high until its ack):
    //
    //   - `bg_pend` latches each request on its own rising edge and is
    //     cleared by the matching ack, so a grant cannot immediately
    //     re-arm off a req the client has not dropped yet and issue a
    //     second, spurious read for the same request.
    //   - `handover` forces p1_req LOW for exactly one cycle whenever
    //     ownership changes. Without it, releasing the port to an already-
    //     asserted snd_req would leave p1_req continuously high, the SDRAM
    //     would never see a rising edge, and the snd read would hang
    //     forever. (Found by sim/tb_mcr68_rom_loader.sv test J3.)
    //
    // All of this is inert when bg_req is tied low: bg_pend/bg_grant stay 0,
    // handover stays 0, and p1_req is exactly
    // snd_req -- bit- and cycle-identical to the module before either
    // client existed.
    // -------------------------------------------------------------------
    logic bg_grant,  bg_grant_d,  bg_pend,  bg_req_d;
    logic p1_ack_d;
    wire  p1_ack_pulse = p1_ack && !p1_ack_d;
    wire  handover      = (bg_grant != bg_grant_d);

    always_ff @(posedge clk) begin
        if (rst) begin
            bg_grant    <= 1'b0;
            bg_grant_d  <= 1'b0;
            bg_pend     <= 1'b0;
            bg_req_d    <= 1'b0;
        end else begin
            bg_grant_d  <= bg_grant;
            bg_req_d    <= bg_req;

            if (bg_req && !bg_req_d)                    bg_pend <= 1'b1;
            else if (bg_grant && p1_ack_pulse)          bg_pend <= 1'b0;

            if (bg_grant) begin
                if (p1_ack_pulse) bg_grant <= 1'b0;    // bg transaction retired
            end else if (bg_pend && !snd_req)
                bg_grant <= 1'b1;
        end
    end

    // -------------------------------------------------------------------
    // Request/address passthrough. No arbitration needed on p0/p2/p3 under
    // the dedicated-port assumption (see header) -- each client's req/addr
    // maps directly onto its own SDRAM port every cycle. p1 is shared
    // between snd and bg by the grant above.
    // -------------------------------------------------------------------
    assign p0_req  = main_req;
    assign p0_addr = MAIN_BASE_W + {8'd0, main_addr};

    assign p1_req  = handover  ? 1'b0
                   : bg_grant  ? bg_pend
                               : snd_req;
    assign p1_addr = bg_grant  ? (SND_BASE_W + {7'd0, bg_addr[18:1]})
                               : (SND_BASE_W + {8'd0, snd_addr});

    assign p2_req  = gfx1_req;
    assign p2_addr = GFX1_BASE_W + {9'd0, gfx1_addr[16:1]};

    // The word client is the production bounded row path. The raw-byte
    // client remains available as a compatibility/fallback interface; the
    // explicit priority makes an accidental overlap deterministic.
    assign p3_burst_req  = gfx2_burst_req;
    assign p3_burst_addr = GFX2_BASE_W + {7'd0, gfx2_burst_addr[18:1]};
    assign p3_row_req    = USE_GFX2_ROW ? gfx2_row_req : 1'b0;
    assign p3_row_addr   = GFX2_BASE_W + {7'd0, gfx2_row_addr[18:1]};

    assign p3_req  = gfx2_word_req | gfx2_req;
    assign p3_addr = GFX2_BASE_W +
                     (gfx2_word_req ? {7'd0, gfx2_word_addr[18:1]} :
                                       {7'd0, gfx2_addr[18:1]});

    // -------------------------------------------------------------------
    // Response registration: turn each SDRAM port's (possibly
    // multi-cycle-stretched) ack into a single clean one-cycle pulse on
    // the matching client port, applying the byte-swap (main/snd) or
    // lane-select (gfx1/gfx2) derived in the header comment.
    // -------------------------------------------------------------------
    logic p0_ack_d, p2_ack_d, p3_ack_d, p3_burst_ack_d, p3_row_ack_d;
    // p1_ack_d is declared above.

    always_ff @(posedge clk) begin
        if (rst) begin
            p0_ack_d  <= 1'b0;
            p1_ack_d  <= 1'b0;
            p2_ack_d  <= 1'b0;
            p3_ack_d  <= 1'b0;
            p3_burst_ack_d <= 1'b0;
            p3_row_ack_d <= 1'b0;
            main_ack  <= 1'b0;
            snd_ack   <= 1'b0;
            gfx1_ack  <= 1'b0;
            gfx2_ack  <= 1'b0;
            gfx2_word_ack  <= 1'b0;
            bg_ack    <= 1'b0;
            main_data <= 16'h0000;
            snd_data  <= 16'h0000;
            gfx1_data <= 8'h00;
            gfx2_data <= 8'h00;
            gfx2_word_data <= 16'h0000;
            gfx2_burst_data <= 32'h00000000;
            gfx2_burst_ack  <= 1'b0;
            gfx2_row_data   <= 128'h0;
            gfx2_row_ack    <= 1'b0;
            bg_data   <= 8'h00;
        end else begin
            p0_ack_d <= p0_ack;
            p1_ack_d <= p1_ack;
            p2_ack_d <= p2_ack;
            p3_ack_d <= p3_ack;
            p3_burst_ack_d <= p3_burst_ack;
            p3_row_ack_d <= p3_row_ack;

            // main: 68000 word reassembly needs the byte swap (see header).
            main_ack <= p0_ack && !p0_ack_d;
            if (p0_ack && !p0_ack_d)
                main_data <= {p0_data[7:0], p0_data[15:8]};

            // p1 is shared: route its ack to whichever client owns the
            // port. With bg_grant constant 0 (every title but
            // archrivl/pigskin) this is bit-identical
            // to the previous unconditional `snd_ack <= p1_ack && !p1_ack_d`.
            // snd: same 68000 word reassembly as main.
            snd_ack <= p1_ack_pulse && !bg_grant;
            if (p1_ack_pulse && !bg_grant)
                snd_data <= {p1_data[7:0], p1_data[15:8]};

            // bg: MC6809E, raw byte, lane-selected by the request address's
            // LSB -- same contract as gfx1/gfx2, no word reassembly.
            bg_ack <= p1_ack_pulse && bg_grant;
            if (p1_ack_pulse && bg_grant)
                bg_data <= bg_addr[0] ? p1_data[15:8] : p1_data[7:0];

            // gfx1: raw byte, lane-selected by the request address's LSB
            // (still valid here -- the client contract requires *_addr to
            // stay stable from req until ack).
            gfx1_ack <= p2_ack && !p2_ack_d;
            if (p2_ack && !p2_ack_d)
                gfx1_data <= gfx1_addr[0] ? p2_data[15:8] : p2_data[7:0];

            // gfx2 word client: preserve both adjacent raw bytes for the
            // bounded row assembler. Request/address remain stable until the
            // ack pulse, so selecting on gfx2_word_req is unambiguous here.
            gfx2_word_ack <= p3_ack && !p3_ack_d && gfx2_word_req;
            if (p3_ack && !p3_ack_d && gfx2_word_req)
                gfx2_word_data <= p3_data;

            gfx2_burst_ack <= p3_burst_ack && !p3_burst_ack_d && gfx2_burst_req;
            if (p3_burst_ack && !p3_burst_ack_d && gfx2_burst_req)
                gfx2_burst_data <= p3_burst_data;

            gfx2_row_ack <= USE_GFX2_ROW && p3_row_ack && !p3_row_ack_d && gfx2_row_req;
            if (USE_GFX2_ROW && p3_row_ack && !p3_row_ack_d && gfx2_row_req)
                gfx2_row_data <= p3_row_data;

            // Legacy gfx2 raw-byte client remains usable when the word client
            // is idle. It is not asserted by the production row path.
            gfx2_ack <= p3_ack && !p3_ack_d && !gfx2_word_req && gfx2_req;
            if (p3_ack && !p3_ack_d && !gfx2_word_req && gfx2_req)
                gfx2_data <= gfx2_addr[0] ? p3_data[15:8] : p3_data[7:0];
        end
    end

endmodule
