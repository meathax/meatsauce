module suna8_core
(
    input  logic clk,
    input  logic reset,
    input  logic media_ready,
    input  logic ioctl_download,
    input  logic ioctl_wr,
    input  logic [7:0] ioctl_index,
    input  logic [24:0] ioctl_addr,
    input  logic [7:0] ioctl_dout,

    // Hiscore access to the main CPU's work RAM (Suna8bit.sv's hiscore
    // instance, MAME hiscore.dat addresses). hs_pause stalls the main Z80
    // by withholding its clock enable; while it is high the work-RAM port
    // is addressed by hs_addr instead of the CPU, so the module can read
    // the score table and write a restored one back.
    input  logic hs_pause,
    input  logic [15:0] hs_addr,
    input  logic [7:0] hs_din,
    input  logic hs_wr,
    output logic [7:0] hs_dout,

    // Player inputs and DIP switches. Active-low idle-high convention
    // (buttons/joystick bits read 1 when not pressed) matching every
    // profile's suna8.cpp input port map. DIP defaults must match the
    // MAME INPUT_PORTS_START default for the profile under test, not just
    // 0xff, or DIP-dependent boot-time code paths (difficulty/lives/coinage
    // -derived branches) will diverge from a MAME comparison run with no
    // DIP override -- see verif/NOTES.md iteration 2.
    input  logic [7:0] input_p1,
    input  logic [7:0] input_p2,
    input  logic [7:0] dip_1,
    input  logic [7:0] dip_2,
    input  logic [7:0] buttons,
    input  logic [7:0] spinner_1,
    input  logic [7:0] spinner_2,
    input  logic [7:0] cheats,

    output logic ce_pix,
    output logic hblank,
    output logic vblank,
    output logic hsync,
    output logic vsync,
    output logic [7:0] video_r,
    output logic [7:0] video_g,
    output logic [7:0] video_b,
    output logic [8:0] video_x,
    output logic [8:0] video_y,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic [2:0] profile_id,
    output logic profile_valid,
    output logic [24:0] image_size,
    output logic [31:0] image_crc,
    output logic [31:0] frame_counter,
    output logic core_ready,
    output logic debug_download_active,
    output logic [31:0] debug_framebuffer_write_count,
    output logic debug_sprite_collision,
    output logic debug_palette_collision,
    output logic [1:0] start_leds,
    output logic [1:0] coin_counters,
    output logic [1:0] coin_lockouts,

    // Source-only media backend boundary.  The first implementation keeps
    // these writes/address buses visible for the SDRAM integration phase.
    output logic media_wr_valid,
    output logic [2:0] media_wr_region,
    output logic [24:0] media_wr_addr,
    output logic [24:0] media_wr_offset,
    output logic [7:0] media_wr_data,

    // Media read backend boundary. On real hardware these are serviced by
    // the eventual SDRAM controller; in Verilator simulation they are
    // serviced by a sim-only memory model (see verif/). Address buses carry
    // the same region-relative offsets as media_wr_offset above.
    output logic [19:0] main_media_read_addr,
    output logic main_media_read_req,
    input  logic [7:0] main_media_read_q,
    input  logic main_media_read_ready,
    output logic [15:0] sound_media_read_addr,
    output logic sound_media_read_req,
    input  logic [7:0] sound_media_read_q,
    input  logic sound_media_read_ready,
    output logic [15:0] pcm_media_read_addr,
    output logic pcm_media_read_req,
    input  logic [7:0] pcm_media_read_q,
    input  logic pcm_media_read_ready,
    output logic [19:0] gfx1_media_read_addr,
    input  logic [7:0] gfx1_media_read_q,
    input  logic [63:0] gfx1_media_line_q,
    input  logic gfx1_media_read_ready,
    output logic [19:0] gfx2_media_read_addr,
    input  logic [7:0] gfx2_media_read_q,
    input  logic [63:0] gfx2_media_line_q,
    input  logic gfx2_media_read_ready,
    output logic [15:0] sample_media_read_addr,
    input  logic [7:0] sample_media_read_q,
    input  logic sample_media_read_ready,
    output logic [7:0] prom_media_read_addr,
    input  logic [7:0] prom_media_read_q,
    input  logic prom_media_read_ready
`ifdef VERILATOR
    // Simulation-only CPU bus trace mirror. Never defined for Quartus, so
    // these ports and their driving assigns do not reach synthesis.
    ,
    output logic [15:0] dbg_cpu_addr,
    output logic [7:0] dbg_cpu_dout,
    output logic [7:0] dbg_cpu_din,
    output logic dbg_cpu_mreq_n,
    output logic dbg_cpu_iorq,
    output logic dbg_cpu_rd_n,
    output logic dbg_cpu_wr_n,
    output logic dbg_cpu_m1_n,

    // Same mirror, for the sound Z80 -- added so the sound CPU's own
    // execution can finally be traced/differentially compared against
    // MAME's audiocpu, retained as a simulation-only observation mirror.
    output logic [15:0] dbg_sound_cpu_addr,
    output logic [7:0] dbg_sound_cpu_dout,
    output logic [7:0] dbg_sound_cpu_din,
    output logic dbg_sound_cpu_mreq_n,
    output logic dbg_sound_cpu_iorq,
    output logic dbg_sound_cpu_rd_n,
    output logic dbg_sound_cpu_wr_n,
    output logic dbg_sound_cpu_m1_n,

    // PCM Z80 and renderer observations are simulation-only. They expose
    // completed-domain evidence without changing the synthesizable datapath.
    output logic [15:0] dbg_pcm_cpu_addr,
    output logic [7:0] dbg_pcm_cpu_dout,
    output logic [7:0] dbg_pcm_cpu_din,
    output logic dbg_pcm_cpu_mreq_n,
    output logic dbg_pcm_cpu_iorq,
    output logic dbg_pcm_cpu_rd_n,
    output logic dbg_pcm_cpu_wr_n,
    output logic dbg_pcm_cpu_m1_n,
    output logic [31:0] dbg_renderer_write_count,
    output logic [31:0] dbg_renderer_done_count,
    output logic dbg_renderer_deadline_miss
`endif
);

    import suna8_profile_pkg::*;
    import suna8_bus_pkg::*;

    logic [8:0] pixel_x;
    logic [8:0] pixel_y;
    logic download_active;
    logic [7:0] main_q;
    logic [7:0] sound_q;
    logic [7:0] pcm_q;
    logic [7:0] gfx1_q;
    logic [7:0] gfx2_q;
    logic [7:0] sample_q;
    logic [7:0] prom_q;
    logic [19:0] main_rom_addr;
    logic [15:0] cpu_addr;
    logic [7:0] cpu_dout;
    logic [7:0] cpu_din;
    logic cpu_mreq_n;
    logic cpu_iorq;
    logic cpu_rd_n;
    logic cpu_wr_n;
    logic cpu_m1_n;
    logic [19:0] opcode_rom_addr;
    logic [9:0] palette_wr_addr;
    logic [9:0] palette_rd_addr;
    logic [7:0] palette_wr_data;
    logic [7:0] palette_rd_q;
    logic palette_wr;
    logic [15:0] sprite_wr_addr;
    logic [15:0] sprite_rd_addr;
    logic [7:0] sprite_wr_data;
    logic [7:0] sprite_rd_q;
    logic sprite_wr;
    logic sound_latch_wr;
    logic [7:0] sound_latch_data;
    logic [7:0] rom_bank_latch;
    logic [2:0] sprite_bank;
    logic [1:0] work_ram_bank;
    logic palette_bank;
    logic flip_screen;
    logic nmi_enable;
    logic palette_write_enable;
    logic [2:0] gfx_bank_latch;
    logic [7:0] protection_2_prev_state;
    logic [7:0] protection_2_state;
    logic soundlatch2_clear;
    logic [7:0] palette_r;
    logic [7:0] palette_g;
    logic [7:0] palette_b;
    logic [7:0] sprite_renderer_q;
    logic [15:0] sprite_renderer_addr;
    logic [19:0] sprite_gfx1_addr;
    logic [19:0] sprite_gfx2_addr;
    logic fb_wr_en;
    logic [7:0] fb_wr_x;
    logic [7:0] fb_wr_y;
    logic [8:0] fb_wr_data;
    logic fb_priority_en;
    logic [7:0] fb_priority_y;
    logic fb_render_done;
    logic fb_render_active;
    logic fb_frame_valid;
    logic [8:0] fb_rd_data;
    logic vblank_prev;
    logic irq_pending;
    logic irq_n;
    logic [8:0] pixel_y_prev;
    logic nmi_pulse;
    logic [2:0] nmi_pulse_counter;
    logic nmi_n;
    logic [26:0] watchdog_counter;
    logic [3:0] watchdog_pulse_counter;
    logic watchdog_reset_active;
    logic fb_vblank_prev;
    logic fb_frame_tick;
    logic fb_clear_active, fb_clear_prev;
    logic sprite_snapshot_start, sprite_snapshot_busy;
    logic cpu_read_c000_sranger;

    logic runtime_ready;
    logic sprite_collision_seen;
    logic palette_collision_seen;

    assign runtime_ready = profile_valid && media_ready && !download_active;
    assign core_ready = runtime_ready;
    assign debug_download_active = download_active;
    assign debug_sprite_collision = sprite_collision_seen;
    assign debug_palette_collision = palette_collision_seen;

    // Sound Z80 subsystem (hardhead/sparkman/starfigh/hardhea2/sranger/
    // brickzn all share this one path via suna8_sound_memory.sv's
    // profile-dependent decode -- see is_brickzn_group there).
    logic [15:0] sound_cpu_addr;
    logic [7:0] sound_cpu_dout;
    logic [7:0] sound_cpu_din;
    logic sound_cpu_mreq_n;
    logic sound_cpu_iorq;
    logic sound_cpu_rd_n;
    logic sound_cpu_wr_n;
    logic sound_cpu_m1_n;
    logic [15:0] sound_rom_addr;
    logic [7:0] soundlatch2_q;
    logic sound_div2;
    logic sound_ce;
    logic [16:0] sound_irq_counter;
    logic sound_irq_pending;
    logic sound_irq_n;
    logic sound_cpu_reset;
    logic sound_cpu_write;
    logic [7:0] ym3812_dout;
    logic ym3812_irq_n;

    // hardhea2/brickzn's separate no-RAM PCM Z80 (suna8_pcm.sv) -- driven
    // via the sound Z80's own soundlatch2_q above, held permanently in
    // reset for every other profile (see pcm_cpu_reset below).
    logic [15:0] pcm_cpu_addr;
    logic [7:0] pcm_cpu_dout;
    logic [7:0] pcm_cpu_din;
    logic pcm_cpu_mreq_n;
    logic pcm_cpu_iorq;
    logic pcm_cpu_rd_n;
    logic pcm_cpu_wr_n;
    logic pcm_cpu_m1_n;
    logic pcm_cpu_reset;
    logic main_rom_read_cycle;
    logic sound_rom_read_cycle;
    logic pcm_rom_read_cycle;
    logic main_wait_n;
    logic sound_wait_n;
    logic pcm_wait_n;

    assign main_rom_read_cycle = !cpu_mreq_n && !cpu_rd_n && !cpu_iorq &&
        (suna8_is_fixed_rom(cpu_addr) || suna8_is_banked_rom(cpu_addr));
    assign sound_rom_read_cycle = !sound_cpu_mreq_n && !sound_cpu_rd_n &&
        !sound_cpu_iorq &&
        (sound_cpu_addr < ((profile_id == PROFILE_HARDHEA2 ||
                            profile_id == PROFILE_BRICKZN)
            ? 16'hc000 : 16'h8000));
    assign pcm_rom_read_cycle = !pcm_cpu_mreq_n && !pcm_cpu_rd_n && !pcm_cpu_iorq;

    // Snapshot-tear fix: hold the main Z80 in a wait state on any write to
    // sprite RAM for the whole duration of the sprite-list snapshot copy
    // (the copy covers all 32 KiB: every tile page is renderer-visible,
    // pages 4-7 through the 4x4 sprite format). Without this,
    // a write landing on a slot the copy has already passed is silently lost
    // from this frame's shadow, while a write landing on a slot not yet
    // reached is captured -- so the rendered frame is built from a mix of
    // two different list states, split by write-address-versus-copy-pointer
    // race rather than by time. Confirmed on hardware and in simulation as a
    // one-pixel seam between sprite tiles that comes and goes with scrolling
    // (2026-09-08 user report); the sim probe (suna8_sprite_ram.sv,
    // snapshot_tear_writes) measured 347 of 1,067 frames (32.5%) affected,
    // up to 380 torn writes in one frame.
    //
    // Blocking every write in the bank for the whole copy window (not just
    // ones landing ahead of the copy pointer) is what makes this atomic:
    // the copy then always reads a region the CPU cannot touch, so it
    // captures the renderer-visible sprite RAM exactly as it stood at
    // snapshot_start (frame_tick) -- the same "read the list once" model
    // MAME's software draw uses. A write attempted during the window is
    // simply delayed until the copy completes and lands normally afterward,
    // where it is picked up by next frame's copy -- one frame later than an
    // unstalled write, never lost, never split.
    //
    // This only affects the main Z80's own wait-state count, not its
    // instruction sequence: the trace comparator matches PC/opcode fetch
    // order, which extra wait T-states never change (the same class of
    // divergence the existing ROM-read wait states already produce and the
    // comparator already tolerates). Measured cost: up to ~380 single-cycle
    // stalls in the frame's worst case, against 405,503 clocks/frame --
    // under 0.1%, and it does not touch the SDRAM arbiter or the renderer's
    // own budget.
    logic sprite_snapshot_write_stall;
    assign sprite_snapshot_write_stall = sprite_wr && sprite_snapshot_busy;

    // WAIT_n alone does not stop the write from committing: sprite_wr is
    // driven combinationally from cpu_write/address decode and feeds
    // suna8_sprite_ram's wr_en directly, with no dependency on the CPU's
    // own notion of whether it is still waiting. Holding wait_n low without
    // also gating wr_en does not defer the write -- it commits on every
    // clock the condition holds regardless, and holding the CPU stalled
    // only makes that repeated-commit window LONGER (measured: it raised
    // the tear-probe's cumulative count roughly 40x, from 15,320 to
    // 615,822, with no change in the affected-frame count -- proving the
    // first attempt at this fix did nothing to prevent the write and made
    // the observable race window worse). The actual RAM write-enable must
    // be masked directly; sprite_wr_gated is what suna8_sprite_ram sees.
    logic sprite_wr_gated;
    assign sprite_wr_gated = sprite_wr && !sprite_snapshot_write_stall;

    // Main CPU fixed-ROM shadow (suna8_rom_shadow). The first 32 KiB of the
    // main ROM image -- everything the Z80 fetches from 0000-7fff, after any
    // per-profile address scramble, which only swaps bits inside a 4 KiB
    // block -- is served from M10K and never goes to SDRAM. Real boards run
    // the CPU with zero wait states; the SDRAM cache stalled it on every
    // miss. main_shadow_q is the RAW byte, so every decryption below still
    // sees exactly what SDRAM would have returned. The byte counts as
    // ready only when the address it was read for is the one on the bus now,
    // so the one-clock M10K latency can never be sampled.
    logic main_shadow_sel;
    logic main_shadow_ready;
    logic [7:0] main_shadow_q;
    logic [14:0] main_shadow_addr_q;
    logic [7:0] main_rom_byte;
    assign main_shadow_sel = (main_rom_addr[19:15] == 5'd0);
    assign main_shadow_ready = (main_shadow_addr_q == main_rom_addr[14:0]);
    assign main_rom_byte = main_shadow_sel ? main_shadow_q : main_media_read_q;

    suna8_rom_shadow #(.DEPTH(32768), .AW(15), .BASE(25'h000000)) u_main_rom_shadow
    (
        .clk(clk),
        .wr_valid(media_wr_valid),
        .wr_addr(media_wr_addr),
        .wr_data(media_wr_data),
        .rd_addr(main_rom_addr[14:0]),
        .rd_q(main_shadow_q),
        .rd_addr_q(main_shadow_addr_q)
    );

    assign main_wait_n = (!main_rom_read_cycle ||
                          (main_shadow_sel ? main_shadow_ready : main_media_read_ready)) &&
                          !sprite_snapshot_write_stall;
    // Sound CPU shadow of audio ROM 0000-7fff, same scheme as the main one.
    // That is the whole sound ROM on four profiles and all but a rarely read
    // tail on hardhea2/brickzn (measured 0-320 wait clocks a frame above
    // 7fff, against up to 52,000 below it), so 8000-bfff stays on SDRAM.
    logic sound_shadow_sel;
    logic sound_shadow_ready;
    logic [7:0] sound_shadow_q;
    logic [14:0] sound_shadow_addr_q;
    logic [7:0] sound_rom_byte;
    assign sound_shadow_sel = !sound_rom_addr[15];
    assign sound_shadow_ready = (sound_shadow_addr_q == sound_rom_addr[14:0]);
    assign sound_rom_byte = sound_shadow_sel ? sound_shadow_q : sound_media_read_q;

    suna8_rom_shadow #(.DEPTH(32768), .AW(15), .BASE(25'h080000)) u_sound_rom_shadow
    (
        .clk(clk),
        .wr_valid(media_wr_valid),
        .wr_addr(media_wr_addr),
        .wr_data(media_wr_data),
        .rd_addr(sound_rom_addr[14:0]),
        .rd_q(sound_shadow_q),
        .rd_addr_q(sound_shadow_addr_q)
    );

    assign sound_wait_n = !sound_rom_read_cycle ||
                          (sound_shadow_sel ? sound_shadow_ready : sound_media_read_ready);
    assign pcm_wait_n = !pcm_rom_read_cycle || pcm_media_read_ready;
    logic signed [15:0] pcm_snd;

    suna8_rom_loader u_rom_loader
    (
        .clk(clk),
        .ioctl_download(ioctl_download),
        .ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .profile_id(profile_id),
        .profile_valid(profile_valid),
        .image_size(image_size),
        .image_crc(image_crc),
        .download_active(download_active),
        .media_wr_valid(media_wr_valid),
        .media_wr_region(media_wr_region),
        .media_wr_addr(media_wr_addr),
        .media_wr_offset(media_wr_offset),
        .media_wr_data(media_wr_data),
        .main_addr(main_rom_addr),
        .main_mem_q(main_rom_byte),
        .main_q(main_q),
        .main_media_addr(),
        .sound_addr(sound_rom_addr),
        .sound_mem_q(sound_rom_byte),
        .sound_q(sound_q),
        .sound_media_addr(),
        .pcm_addr(16'd0),
        .pcm_mem_q(pcm_media_read_q),
        .pcm_q(pcm_q),
        .pcm_media_addr(),
        .gfx1_addr(20'd0),
        .gfx1_mem_q(gfx1_media_read_q),
        .gfx1_q(gfx1_q),
        .gfx1_media_addr(),
        .gfx2_addr(20'd0),
        .gfx2_mem_q(gfx2_media_read_q),
        .gfx2_q(gfx2_q),
        .gfx2_media_addr(),
        .sample_addr(16'd0),
        .sample_mem_q(sample_media_read_q),
        .sample_q(sample_q),
        .sample_media_addr(),
        .prom_addr(8'd0),
        .prom_mem_q(prom_media_read_q),
        .prom_q(prom_q),
        .prom_media_addr()
    );

    assign main_media_read_addr = main_rom_addr;
    assign sound_media_read_addr = sound_rom_addr;
    // The Z80s present a decoded ROM address on every bus cycle, including
    // RAM and I/O cycles. Only a real ROM read may ask the media arbiter for
    // a line, otherwise the CPU-priority arbiter fetches lines the CPU never
    // reads and starves the sprite renderer (2026-09-07 audit, W21.1).
    // A read the shadow serves never asks SDRAM for a line, which also frees
    // that bandwidth for the sprite renderer.
    assign main_media_read_req = main_rom_read_cycle && !main_shadow_sel;
    assign sound_media_read_req = sound_rom_read_cycle && !sound_shadow_sel;
    assign pcm_media_read_req = pcm_rom_read_cycle;
    // pcm_media_read_addr is driven directly by u_pcm below (bypasses
    // u_rom_loader's own pcm_addr/pcm_q translation layer, same as the
    // SAMPLES device bypasses its sample_addr/sample_q -- see u_pcm).
    // Sprite ROM mirrors (W26). suna8.cpp fills part of these regions with
    // ROM_COPY rather than real ROMs, because the boards do not decode the
    // upper bank-address lines: Star Fighter's gfx1 has half the ROM of its
    // 1 MiB bank space (banks 08-0f alias 00-07 and 18-1f alias 10-17, in both
    // plane halves -- one address bit), and Spark Man's gfx2 has a single
    // 64 KiB chip per half (banks 04-1f alias 00-03 -- three address bits).
    // Folding the address here is equivalent to the copies and costs nothing.
    //
    // The mirrors were first expressed as repeated <part> entries in the MRA;
    // that assembled a byte-identical image and passed every local check, but
    // MiSTer Main could not load it and both games stopped at the boot
    // diagnostic's "profile byte not accepted" on real hardware (R068). Keep
    // this in RTL: the MRA stays a plain sequential image with zero fill.
    assign gfx1_media_read_addr = (profile_id == PROFILE_STARFIGH)
        ? {sprite_gfx1_addr[19:18], 1'b0, sprite_gfx1_addr[16:0]}
        : sprite_gfx1_addr;
    assign gfx2_media_read_addr = (profile_id == PROFILE_SPARKMAN)
        ? {sprite_gfx2_addr[19], 3'b000, sprite_gfx2_addr[15:0]}
        : sprite_gfx2_addr;
    assign prom_media_read_addr = 8'd0;

    // sranger/rranger's own hardware watchdog (suna8.cpp's rranger() machine
    // config: WATCHDOG_TIMER(config,"watchdog"), read-triggered/fed at
    // $C000, rranger_map's only mapping there -- no other profile has this
    // device at all). MAME's watchdog_timer_device defaults (no explicit
    // set_time()/set_vblank_count()) to a 3-real-second timeout
    // (watchdog.cpp: "default to an obscene amount of time (3 seconds)"),
    // re-armed on every $C000 read, and fires machine().schedule_soft_reset()
    // if never fed. At the 6 MHz CPU clock (24 MHz XTAL / 4) that's
    // 18,000,000 T-states; since ce_pix/ce_cpu ticks once every 4 raw clk
    // cycles here, that's 72,000,000 raw clk cycles. Without this, sranger's
    // boot code reaches an unconditional `jr $-2` idle loop that never
    // enables interrupts and never reads $C000 again, and the CPU spins
    // there forever in simulation -- on real hardware/MAME the watchdog
    // times out, forcing a reset that restarts boot with different residual
    // work-RAM state, eventually reaching a real interrupt. See
    // verif/NOTES.md's "no working watchdog timer" investigation.
    localparam int WATCHDOG_TIMEOUT = 72_000_000;
    assign cpu_read_c000_sranger = (profile_id == 3'd1) && !cpu_mreq_n && !cpu_iorq &&
                                    !cpu_rd_n && (cpu_addr == 16'hc000);
    assign watchdog_reset_active = (watchdog_pulse_counter != 4'd0);

    always_ff @(posedge clk) begin
        if (reset || !runtime_ready) begin
            watchdog_counter <= 27'd0;
            watchdog_pulse_counter <= 4'd0;
        end else if (watchdog_pulse_counter != 4'd0) begin
            watchdog_counter <= 27'd0;
            watchdog_pulse_counter <= watchdog_pulse_counter - 4'd1;
        end else if (profile_id != 3'd1) begin
            // Bug fix: this counter previously free-ran and fired for every
            // profile, not just sranger/rranger (the only one with a
            // WATCHDOG_TIMER device in MAME's machine config) -- every other
            // profile was getting a spurious full CPU reset every
            // WATCHDOG_TIMEOUT cycles (~3 real seconds), invisible in any
            // regression run shorter than that. Hold at 0 for everyone else.
            watchdog_counter <= 27'd0;
        end else if (cpu_read_c000_sranger) begin
            watchdog_counter <= 27'd0;
        end else if (watchdog_counter >= WATCHDOG_TIMEOUT[26:0] - 27'd1) begin
            watchdog_counter <= 27'd0;
            watchdog_pulse_counter <= 4'd8;
        end else begin
            watchdog_counter <= watchdog_counter + 27'd1;
        end
    end

    // Main CPU vblank interrupt (IRQ0, MAME's irq0_line_hold): every SunA8
    // profile registers set_vblank_int for the main CPU. Level-held from
    // vblank entry until the CPU's own interrupt-acknowledge cycle
    // (M1_n & IORQ_n both low) clears it, matching how a real hold-until-ack
    // interrupt line behaves. NMI is not wired yet -- profiles that also use
    // NMI (per suna8.cpp machine-config comments) need it added per-profile.
    always_ff @(posedge clk) begin
        if (reset || !runtime_ready || watchdog_reset_active) begin
            vblank_prev <= 1'b0;
            irq_pending <= 1'b0;
        end else begin
            vblank_prev <= vblank;
            if (vblank && !vblank_prev)
                irq_pending <= 1'b1;
            else if (!cpu_m1_n && cpu_iorq)
                irq_pending <= 1'b0;
        end
    end
    assign irq_n = !irq_pending;

    // Hiscore pause. The CPU stays stopped for two clocks after hs_pause
    // drops: while paused, the work-RAM read port is addressed by the
    // hiscore module, and that read is registered, so work_ram_q still holds
    // the module's last byte on the first clock after release. Letting the
    // Z80 resume on that clock (ce_pix can be high there) handed a CPU read
    // that the pause had interrupted the hiscore module's byte instead of its
    // own -- one corrupted read per interrupted access, enough to derail
    // Brick Zone during a table restore while MAME, poking the same bytes
    // atomically, carried on normally.
    logic hs_pause_d1, hs_pause_d2;
    always_ff @(posedge clk) begin
        hs_pause_d1 <= hs_pause;
        hs_pause_d2 <= hs_pause_d1;
    end
    wire main_cpu_hold = hs_pause || hs_pause_d1 || hs_pause_d2;

    // Scanline-112 NMI, gated by nmi_enable (suna8.cpp's hardhea2_interrupt,
    // shared by sparkman/starfigh/hardhea2's machine configs -- hardhead and
    // sranger only use the plain vblank IRQ above, and brickzn's interrupt
    // source has not been checked yet).
    //
    // Held for multiple clk cycles, not just one: verif/tv80's NMI edge
    // detector (tv80_core.v's sync_inputs block) only samples nmi_n on
    // cen(=ce_cpu=ce_pix)-qualified cycles, which are high on exactly 1 of
    // every 4 raw clk cycles. pixel_y's own update (driven by the same
    // div==3 condition that generates ce_pix) becomes visible the cycle
    // *after* ce_pix was high, i.e. deterministically on a div==0
    // (non-cen) cycle -- so a single-clk-wide pulse asserted the instant
    // pixel_y==112 lands on a cycle TV80 never samples, every single time,
    // and NMI never fires at all (confirmed: zero NMI vector fetches over
    // hundreds of millions of simulated cycles for hardhea2, despite
    // nmi_enable being correctly, continuously set). Held for 6 cycles
    // (more than the 4-cycle cen period) to guarantee the pulse overlaps
    // at least one cen-sampled cycle regardless of phase. Z80 NMI is
    // edge-triggered internally (TV80's own Oldnmi_n/NMI_s tracking only
    // fires once per falling edge), so holding it low longer than one
    // T-state does not cause a second trigger.
    always_ff @(posedge clk) begin
        if (reset || !runtime_ready || watchdog_reset_active) begin
            pixel_y_prev <= 9'd0;
            nmi_pulse_counter <= 3'd0;
        end else begin
            pixel_y_prev <= pixel_y;
            if ((pixel_y == 9'd112) && (pixel_y_prev != 9'd112) && nmi_enable &&
                (profile_id == PROFILE_SPARKMAN || profile_id == PROFILE_STARFIGH ||
                 profile_id == PROFILE_HARDHEA2))
                nmi_pulse_counter <= 3'd6;
            // Held while the hiscore module has the CPU paused, so an NMI
            // that fires during the pause is still seen as an edge.
            else if (nmi_pulse_counter != 3'd0 && !main_cpu_hold)
                nmi_pulse_counter <= nmi_pulse_counter - 3'd1;
        end
    end
    assign nmi_pulse = (nmi_pulse_counter != 3'd0);
    assign nmi_n = !nmi_pulse;

    // Sound Z80 clock: suna8.cpp's machine configs run hardhead/rranger's
    // audiocpu at 24MHz XTAL/8 (3MHz -- half of ce_pix's 6MHz) and every
    // other implemented profile's at 24MHz XTAL/4 (6MHz -- same rate as
    // ce_pix). sound_div2 toggles once per ce_pix pulse, halving the rate
    // for the /8 profiles.
    //
    // BRICKZN's own sound Z80 now runs (previously held permanently in
    // reset, back when this project ran hardhea2's sound CPU against the
    // wrong memory map). Its separate no-RAM PCM Z80 (brickzn_pcm_map,
    // driving four DAC channels) is also clocked and fed from the sound
    // latch path in suna8_pcm.sv.
    assign sound_cpu_reset = reset || !runtime_ready;
    always_ff @(posedge clk) begin
        if (sound_cpu_reset)
            sound_div2 <= 1'b0;
        else if (ce_pix)
            sound_div2 <= ~sound_div2;
    end
    assign sound_ce = ce_pix &&
        ((profile_id == PROFILE_HARDHEAD || profile_id == PROFILE_SRANGER) ?
         sound_div2 : 1'b1);

    // Sound Z80 IRQ0 source. Two different mechanisms, per suna8.cpp:
    //   - hardhead/rranger/sparkman/starfigh: set_periodic_int(
    //     irq0_line_hold, attotime::from_hz(4*60)), a free-running timer
    //     independent of ymsnd, and -- this is the important part --
    //     independent of the video/vblank timer too: attotime::from_hz()
    //     is a flat real-time-seconds rate (exactly 240.000Hz), NOT
    //     derived from the screen's actual refresh. An earlier version of
    //     this comment assumed the two were the same 60Hz and reused the
    //     video frame period (405,504 raw-clk cycles) / 4 = 101,376 --
    //     WRONG: hardhead's screen is set_raw(24_MHz_XTAL/4, 384,0,256,
    //     264,16,240), i.e. 6,000,000 / (384*264) = 59.186477Hz, not an
    //     exact 60Hz, so 4x that (236.746Hz) is a different rate than the
    //     flat 240Hz set_periodic_int actually uses. Confirmed as a real,
    //     accumulating divergence via a MAME-audiocpu-vs-Verilator SEV
    //     trace diff (verif/NOTES.md iteration 43): the sim-vs-mame
    //     instruction-index shift grew roughly monotonically (0->431->564
    //     by ~28,000 sound instructions) instead of staying bounded like
    //     the vblank-synced main-CPU IRQ0's jitter -- the signature of a
    //     genuine rate mismatch, not sampling jitter. The raw clock itself
    //     is exactly 24MHz (ce_pix = clk/4 = 6MHz pixel clock, confirmed
    //     in suna8_raster.sv), so the correct period is simply
    //     24,000,000 / 240 = 100,000 cycles exactly -- computed directly
    //     from the real-time rate, not borrowed from an unrelated video
    //     timing constant. Free-running, not synchronized to vblank, since
    //     MAME's periodic_int is its own independent timer. Held until the
    //     sound CPU's own interrupt-acknowledge cycle, same hold-until-ack
    //     pattern as the main CPU's vblank IRQ0 above.
    //   - hardhea2/brickzn: "ymsnd.irq_handler().set_inputline(audiocpu,
    //     0)" -- the chip's OWN irq_n output drives the CPU's INT line
    //     directly and continuously (level-sensitive, not a hold-until-ack
    //     pulse), confirmed against suna8.cpp:2060 -- hardhea2's
    //     machine_config inherits this unchanged from brickzn(config), see
    //     suna8_sound_memory.sv's header comment. jtopl2 (suna8_sound_chips
    //     .sv) already derives its own irq_n from the same internal
    //     timer-overflow flags that back its status byte, so no extra
    //     hold-until-ack logic is needed here -- it's simply wired through.
    localparam int SOUND_IRQ_PERIOD = 100_000;
    logic sound_irq_group_uses_timer;
    assign sound_irq_group_uses_timer = (profile_id == PROFILE_HARDHEAD) ||
                                         (profile_id == PROFILE_SRANGER) ||
                                         (profile_id == PROFILE_SPARKMAN) ||
                                         (profile_id == PROFILE_STARFIGH);
    always_ff @(posedge clk) begin
        if (sound_cpu_reset) begin
            sound_irq_counter <= 17'd0;
            sound_irq_pending <= 1'b0;
        end else begin
            if (sound_irq_counter >= SOUND_IRQ_PERIOD[16:0] - 17'd1)
                sound_irq_counter <= 17'd0;
            else
                sound_irq_counter <= sound_irq_counter + 17'd1;

            if (sound_irq_counter >= SOUND_IRQ_PERIOD[16:0] - 17'd1)
                sound_irq_pending <= 1'b1;
            else if (!sound_cpu_m1_n && sound_cpu_iorq)
                sound_irq_pending <= 1'b0;
        end
    end
    assign sound_irq_n = sound_irq_group_uses_timer ? !sound_irq_pending : ym3812_irq_n;

    suna8_main_cpu u_sound_cpu
    (
        .clk(clk),
        .reset(sound_cpu_reset),
        .ce_cpu(sound_ce),
        .wait_n(sound_wait_n),
        .data_in(sound_cpu_din),
        .irq_n(sound_irq_n),
        .nmi_n(1'b1),
        .address(sound_cpu_addr),
        .data_out(sound_cpu_dout),
        .mreq_n(sound_cpu_mreq_n),
        .iorq(sound_cpu_iorq),
        .rd_n(sound_cpu_rd_n),
        .wr_n(sound_cpu_wr_n),
        .m1_n(sound_cpu_m1_n)
    );

    suna8_sound_memory u_sound_memory
    (
        .clk(clk),
        .reset(sound_cpu_reset),
        .profile_id(profile_id),
        .cpu_addr(sound_cpu_addr),
        .cpu_dout(sound_cpu_dout),
        .cpu_mreq_n(sound_cpu_mreq_n),
        .cpu_iorq(sound_cpu_iorq),
        .cpu_rd_n(sound_cpu_rd_n),
        .cpu_wr_n(sound_cpu_wr_n),
        .cpu_din(sound_cpu_din),
        .rom_addr(sound_rom_addr),
        .rom_q(sound_q),
        .main_latch_wr(sound_latch_wr),
        .main_latch_data(sound_latch_data),
        .soundlatch2_clear(soundlatch2_clear),
        .soundlatch2_q(soundlatch2_q),
        .ym3812_dout(ym3812_dout)
    );

    assign sound_cpu_write = !sound_cpu_mreq_n && !sound_cpu_iorq && !sound_cpu_wr_n;

    suna8_sound_chips u_sound_chips
    (
        .clk(clk),
        .reset(sound_cpu_reset),
        .profile_id(profile_id),
        .cpu_addr(sound_cpu_addr),
        .cpu_dout(sound_cpu_dout),
        .cpu_write(sound_cpu_write),
        .ym3812_dout(ym3812_dout),
        .ym3812_irq_n(ym3812_irq_n),
        .sample_media_read_addr(sample_media_read_addr),
        .sample_media_read_q(sample_media_read_q),
        .sample_media_read_ready(sample_media_read_ready),
        .pcm_snd(pcm_snd),
        .audio_l(audio_l),
        .audio_r(audio_r)
    );

    // hardhea2/brickzn's separate PCM Z80 -- suna8.cpp's brickzn_pcm_map/
    // brickzn_pcm_io_map, "PCM Z80, 4 DACs (4 bits per sample), NO RAM".
    // Held permanently in reset for every other profile: this CPU/ROM
    // simply doesn't exist in those games' hardware, and pcm_snd stays at
    // its reset value of 0 (suna8_pcm.sv) whenever it isn't running, so
    // this is a correct, safe no-op for the other four profiles.
    assign pcm_cpu_reset = sound_cpu_reset ||
                            !(profile_id == PROFILE_HARDHEA2 || profile_id == PROFILE_BRICKZN);

    suna8_main_cpu u_pcm_cpu
    (
        .clk(clk),
        .reset(pcm_cpu_reset),
        .ce_cpu(ce_pix),          // 24MHz/4 = 6MHz, suna8.cpp: Z80(config,
        .wait_n(pcm_wait_n),
                                   // "pcm", 24_MHz_XTAL/4) -- same rate as
                                   // the main CPU, no extra division.
        .data_in(pcm_cpu_din),
        .irq_n(1'b1),             // brickzn_pcm_io_map has no interrupt
                                   // source at all.
        .nmi_n(1'b1),
        .address(pcm_cpu_addr),
        .data_out(pcm_cpu_dout),
        .mreq_n(pcm_cpu_mreq_n),
        .iorq(pcm_cpu_iorq),
        .rd_n(pcm_cpu_rd_n),
        .wr_n(pcm_cpu_wr_n),
        .m1_n(pcm_cpu_m1_n)
    );

    suna8_pcm u_pcm
    (
        .clk(clk),
        .reset(pcm_cpu_reset),
        .cpu_addr(pcm_cpu_addr),
        .cpu_dout(pcm_cpu_dout),
        .cpu_din(pcm_cpu_din),
        .cpu_mreq_n(pcm_cpu_mreq_n),
        .cpu_iorq(pcm_cpu_iorq),
        .cpu_rd_n(pcm_cpu_rd_n),
        .cpu_wr_n(pcm_cpu_wr_n),
        .pcm_media_read_addr(pcm_media_read_addr),
        .pcm_media_read_q(pcm_media_read_q),
        .soundlatch2_q(soundlatch2_q),
        .pcm_snd(pcm_snd)
    );

    suna8_main_cpu u_main_cpu
    (
        .clk(clk),
        .reset(reset || !runtime_ready || watchdog_reset_active),
        .ce_cpu(ce_pix && !main_cpu_hold),
        .wait_n(main_wait_n),
        .data_in(cpu_din),
        .irq_n(irq_n),
        .nmi_n(nmi_n),
        .address(cpu_addr),
        .data_out(cpu_dout),
        .mreq_n(cpu_mreq_n),
        .iorq(cpu_iorq),
        .rd_n(cpu_rd_n),
        .wr_n(cpu_wr_n),
        .m1_n(cpu_m1_n)
    );

    suna8_main_memory u_main_memory
    (
        .clk(clk),
        .reset(reset),
        .profile_id(profile_id),
        .cpu_addr(cpu_addr),
        .cpu_dout(cpu_dout),
        .cpu_mreq_n(cpu_mreq_n),
        .cpu_iorq(cpu_iorq),
        .cpu_rd_n(cpu_rd_n),
        .cpu_wr_n(cpu_wr_n),
        .cpu_m1_n(cpu_m1_n),
        .hs_pause(hs_pause),
        .hs_addr(hs_addr),
        .hs_din(hs_din),
        .hs_wr(hs_wr),
        .hs_dout(hs_dout),
        .cpu_din(cpu_din),
        .main_rom_addr(main_rom_addr),
        .opcode_rom_addr(opcode_rom_addr),
        .main_rom_q(main_q),
        .opcode_rom_q(main_q),
        .input_p1(input_p1),
        .input_p2(input_p2),
        .dip_1(dip_1),
        .dip_2(dip_2),
        .buttons(buttons),
        .spinner_1(spinner_1),
        .spinner_2(spinner_2),
        .cheats(cheats),
        .frame_counter(frame_counter),
        .vblank(vblank),
        .soundlatch2_in(soundlatch2_q),
        .palette_wr(palette_wr),
        .palette_wr_addr(palette_wr_addr),
        .palette_wr_data(palette_wr_data),
        .palette_rd_addr(palette_rd_addr),
        .palette_rd_q(palette_rd_q),
        .sprite_wr(sprite_wr),
        .sprite_wr_addr(sprite_wr_addr),
        .sprite_wr_data(sprite_wr_data),
        .sprite_rd_addr(sprite_rd_addr),
        .sprite_rd_q(sprite_rd_q),
        .sound_latch_wr(sound_latch_wr),
        .sound_latch_data(sound_latch_data),
        .rom_bank_latch(rom_bank_latch),
        .sprite_bank(sprite_bank),
        .work_ram_bank(work_ram_bank),
        .palette_bank(palette_bank),
        .flip_screen(flip_screen),
        .nmi_enable(nmi_enable),
        .palette_write_enable(palette_write_enable),
        .gfx_bank_latch(gfx_bank_latch),
        .protection_2_prev_state(protection_2_prev_state),
        .protection_2_state(protection_2_state),
        .soundlatch2_clear(soundlatch2_clear),
        .start_leds(start_leds),
        .coin_counters(coin_counters),
        .coin_lockouts(coin_lockouts)
    );

    suna8_palette u_palette
    (
        .clk(clk),
        .reset(reset),
        .palette_wr(palette_wr),
        .palette_wr_addr(palette_wr_addr),
        .palette_wr_data(palette_wr_data),
        .palette_rd_data(palette_rd_q),
        .palette_rd_addr(palette_rd_addr),
        .profile_id(profile_id),
        .protection_2_prev(protection_2_prev_state),
        .protection_2(protection_2_state),
        .pixel_palette_index(fb_rd_data),
        .pixel_r(palette_r),
        .pixel_g(palette_g),
        .pixel_b(palette_b),
        .collision_seen(palette_collision_seen)
    );

    suna8_sprite_ram u_sprite_ram
    (
        .clk(clk),
        .reset(reset),
        .wr_en(sprite_wr_gated),
        .wr_addr(sprite_wr_addr),
        .wr_data(sprite_wr_data),
        .cpu_rd_addr(sprite_rd_addr),
        .cpu_rd_data(sprite_rd_q),
        .renderer_rd_addr(sprite_renderer_addr),
        .renderer_rd_data(sprite_renderer_q),
        .snapshot_start(sprite_snapshot_start),
        .snapshot_busy(sprite_snapshot_busy),
        .collision_seen(sprite_collision_seen)
    );

    // Snapshot the sprite list when the framebuffer starts clearing the
    // new back bank (frame tick with the previous pass complete, or the
    // boot-time clear). The copy runs under that clear; the renderer is
    // additionally held until the copy has drained.
    always_ff @(posedge clk) begin
        if (reset || !runtime_ready) begin
            fb_clear_prev <= 1'b0;
            sprite_snapshot_start <= 1'b0;
        end else begin
            fb_clear_prev <= fb_clear_active;
            sprite_snapshot_start <= fb_clear_active && !fb_clear_prev;
        end
    end

    suna8_sprite_render u_sprite_render
    (
        .clk(clk),
        .reset(reset || !runtime_ready),
        .active(fb_render_active && !sprite_snapshot_busy),
        .profile(profile_id),
        .flip_screen(flip_screen),
        .sprite_bank(sprite_bank),
        .palette_bank(palette_bank),
        .gfx_bank_latch(gfx_bank_latch),
        .sprite_rd_addr(sprite_renderer_addr),
        .sprite_rd_data(sprite_renderer_q),
        .gfx1_addr(sprite_gfx1_addr),
        .gfx1_q(gfx1_media_read_q),
        .gfx1_line_q(gfx1_media_line_q),
        .gfx1_ready(gfx1_media_read_ready),
        .gfx2_addr(sprite_gfx2_addr),
        .gfx2_q(gfx2_media_read_q),
        .gfx2_line_q(gfx2_media_line_q),
        .gfx2_ready(gfx2_media_read_ready),
        .fb_wr_en(fb_wr_en),
        .fb_wr_x(fb_wr_x),
        .fb_wr_y(fb_wr_y),
        .fb_wr_data(fb_wr_data),
        .fb_priority_en(fb_priority_en),
        .fb_priority_y(fb_priority_y),
        .render_done(fb_render_done)
    );

    // Frame-boundary tick for the framebuffer's display/draw bank swap and
    // clear-to-0xFF, independent of the IRQ-tracking vblank_prev above (in
    // particular, not suppressed by watchdog_reset_active -- the video
    // timing generator is not part of sranger's watchdog reset scope, see
    // verif/NOTES.md iteration 16, so the framebuffer swap must not be
    // gated by it either).
    always_ff @(posedge clk) begin
        if (reset || !runtime_ready) begin
            fb_vblank_prev <= 1'b0;
            fb_frame_tick <= 1'b0;
        end else begin
            fb_vblank_prev <= vblank;
            fb_frame_tick <= vblank && !fb_vblank_prev;
        end
    end

    suna8_framebuffer u_framebuffer
    (
        .clk(clk),
        .reset(reset || !runtime_ready),
        .frame_tick(fb_frame_tick),
        .wr_en(fb_wr_en),
        .wr_x(fb_wr_x),
        .wr_y(fb_wr_y),
        .wr_data(fb_wr_data),
        .priority_en(fb_priority_en),
        .priority_y(fb_priority_y),
        .render_done(fb_render_done),
        .render_active(fb_render_active),
        .clear_active(fb_clear_active),
        .frame_valid(fb_frame_valid),
        // pixel_y is raw vcount (suna8_raster.sv): active display is
        // vcount 16..239 (suna8.cpp's set_visarea(0,255,0+16,255-16) on
        // every profile), but the framebuffer's own row storage is 0..223
        // (matching suna8_sprite_render.sv's px_screen_y8, itself now
        // re-based to the same 0-223 convention -- see that file's
        // px_screen_y_active comment). Subtracting 16 here makes both
        // sides agree on which physical CRT line a given buffer row is;
        // for vcount < 16 (vblank) this underflows to a don't-care high
        // value, which is fine since suna8_core.sv's own video_r/g/b mux
        // forces black output during vblank/hblank regardless of
        // fb_rd_data's content.
        .rd_x(pixel_x[7:0]),
        .rd_y(pixel_y[7:0] - 8'd16),
        .rd_data(fb_rd_data)
    );

    suna8_raster u_raster
    (
        .clk(clk),
        .profile_id(profile_id),
        // Gated identically to u_main_cpu's reset: on real hardware the CPU
        // and video-timing generator come out of reset together at power-on.
        // Leaving the raster free-running through the (simulation-only)
        // ROM-download period desyncs its phase from where a synchronized
        // power-on would leave it by the time the CPU's first instruction
        // runs, breaking the CPU-boot-code-length-to-first-vblank
        // relationship MAME's own trace exhibits (a short first inter-IRQ
        // interval, since IRQ is level-held from whatever vblank edge
        // occurred before EI, not a full frame period) -- see
        // verif/NOTES.md's "Interrupt-phase timing" investigation.
        //
        // Deliberately NOT included in sranger's watchdog reset scope:
        // tried it (reasoning that MAME's schedule_soft_reset() resets
        // every device including the screen), but it made the next
        // divergence happen *earlier* (instruction 1,906,183 instead of
        // 3,520,188), not later -- so whatever governs the post-watchdog
        // interrupt-phase relationship isn't simply "raster also resets to
        // vcount=240 here". Reverted; real hardware's video timing
        // generator plausibly free-runs through a CPU-only watchdog reset
        // regardless of what MAME's abstraction does. See verif/NOTES.md's
        // sranger post-watchdog interrupt-phase-timing investigation.
        .reset(reset || !runtime_ready),
        .ce_pix(ce_pix),
        .hblank(hblank),
        .vblank(vblank),
        .hsync(hsync),
        .vsync(vsync),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .frame_counter(frame_counter)
    );

`ifdef VERILATOR
    logic [31:0] renderer_write_count_r;
    // renderer_write_count_r is cleared by the same frame tick that a reader
    // sampling on the frame boundary sees, so it always read back as zero.
    // Latch the finished frame's total before clearing it.
    logic [31:0] renderer_write_frame_r;
    logic [31:0] renderer_done_count_r;
    logic renderer_deadline_miss_r;

    always_ff @(posedge clk) begin
        if (reset || !runtime_ready) begin
            renderer_write_count_r <= 32'd0;
            renderer_write_frame_r <= 32'd0;
            renderer_done_count_r <= 32'd0;
            renderer_deadline_miss_r <= 1'b0;
        end else begin
            if (fb_frame_tick) begin
                renderer_write_frame_r <= renderer_write_count_r;
                renderer_write_count_r <= 32'd0;
            end else if (fb_wr_en)
                renderer_write_count_r <= renderer_write_count_r + 32'd1;
            if (fb_render_done)
                renderer_done_count_r <= renderer_done_count_r + 32'd1;
            // Once a displayed frame exists, every frame boundary must have
            // a completed producer pass. A missing completion means the
            // previous bank would be displayed again.
            if (fb_frame_tick && fb_frame_valid && fb_render_active)
                renderer_deadline_miss_r <= 1'b1;
        end
    end

    assign dbg_cpu_addr = cpu_addr;
    assign dbg_cpu_dout = cpu_dout;
    assign dbg_cpu_din = cpu_din;
    assign dbg_cpu_mreq_n = cpu_mreq_n;
    assign dbg_cpu_iorq = cpu_iorq;
    assign dbg_cpu_rd_n = cpu_rd_n;
    assign dbg_cpu_wr_n = cpu_wr_n;
    assign dbg_cpu_m1_n = cpu_m1_n;

    assign dbg_sound_cpu_addr = sound_cpu_addr;
    assign dbg_sound_cpu_dout = sound_cpu_dout;
    assign dbg_sound_cpu_din = sound_cpu_din;
    assign dbg_sound_cpu_mreq_n = sound_cpu_mreq_n;
    assign dbg_sound_cpu_iorq = sound_cpu_iorq;
    assign dbg_sound_cpu_rd_n = sound_cpu_rd_n;
    assign dbg_sound_cpu_wr_n = sound_cpu_wr_n;
    assign dbg_sound_cpu_m1_n = sound_cpu_m1_n;
    assign dbg_pcm_cpu_addr = pcm_cpu_addr;
    assign dbg_pcm_cpu_dout = pcm_cpu_dout;
    assign dbg_pcm_cpu_din = pcm_cpu_din;
    assign dbg_pcm_cpu_mreq_n = pcm_cpu_mreq_n;
    assign dbg_pcm_cpu_iorq = pcm_cpu_iorq;
    assign dbg_pcm_cpu_rd_n = pcm_cpu_rd_n;
    assign dbg_pcm_cpu_wr_n = pcm_cpu_wr_n;
    assign dbg_pcm_cpu_m1_n = pcm_cpu_m1_n;
    assign dbg_renderer_write_count = renderer_write_frame_r;
    assign dbg_renderer_done_count = renderer_done_count_r;
    assign dbg_renderer_deadline_miss = renderer_deadline_miss_r;
`endif

    assign video_x = pixel_x;
    assign video_y = pixel_y;

    // sound_q/pcm_q/gfx1_q/gfx2_q/sample_q/prom_q (suna8_rom_loader's
    // per-region download-time passthroughs) are reserved for the not-yet
    // -wired PCM Z80 (task: hardhea2/brickzn's brickzn_pcm_map) and gfx2
    // sprite bank -- gfx1 pixel fetch reads gfx1_media_read_q directly
    // (see u_sprite_render above), not this passthrough copy, and the
    // SAMPLES device (u_sound_chips) reads sample_media_read_q directly
    // too, same as gfx1 -- this loader's own sample_q stays unread.
    // Intentionally unread until the PCM Z80/gfx2 consumers exist, same
    // convention as the *_media_read_addr stubs above.

    // audio_l/audio_r are driven directly by u_sound_chips above -- real
    // YM3812/AY8910/YM2203 synthesis, not a stub (previously hardcoded to
    // 16'sd0, i.e. permanent silence -- see suna8_sound_chips.sv).
    // TEMPORARY HARDWARE DIAGNOSTIC (2026-08-07): user reports a solid
    // black screen on real hardware across all 6 profiles, after the
    // framebuffer RAM-inference rewrite + earlier sprite-Y visarea fix,
    // neither of which reproduces in Verilator simulation. This replaces
    // the content source (palette_r/g/b) with a fixed gradient test
    // pattern while leaving the hblank/vblank/profile_valid/
    // download_active gate untouched, to discriminate two hypotheses in
    // one hardware test:
    //   - gradient visible  => the enable gate is fine; the bug is in
    //     the framebuffer/palette/sprite content pipeline.
    //   - still solid black => the gate itself never opens (profile_valid
    //     stuck low or download_active stuck high); the bug is upstream
    //     of anything touched this session.
    // Revert by deleting this block and restoring the plain assignment
    // below it once the hardware report comes back.
`ifdef SUNA8_DEBUG_VIDEO_TEST_PATTERN
    // v2 (2026-08-07): the v1 gradient test (gated identically to the
    // real content) still came back solid black -- ruling out the
    // framebuffer/palette/sprite pipeline entirely (it was never even
    // reached). This version bypasses hblank/vblank/profile_valid/
    // download_active completely and paints a flat color that encodes
    // {profile_valid, download_active} directly, so a single hardware
    // test identifies which flag is stuck:
    //   RED    = profile_valid == 0  (profile byte never recognized)
    //   YELLOW = profile_valid == 1, download_active == 1 (ROM download
    //            never signals complete)
    //   GREEN  = profile_valid == 1, download_active == 0 (gate logic
    //            thinks everything is fine -- if this shows, the real
    //            blocker is hblank/vblank never clearing, contradicting
    //            the working-OSD assumption)
    always_comb begin
        if (!profile_valid) begin
            video_r = 8'hff; video_g = 8'h00; video_b = 8'h00; // RED
        end else if (download_active) begin
            video_r = 8'hff; video_g = 8'hff; video_b = 8'h00; // YELLOW
        end else begin
            video_r = 8'h00; video_g = 8'hff; video_b = 8'h00; // GREEN
        end
    end
`else
    always_comb begin
        video_r = 8'd0;
        video_g = 8'd0;
        video_b = 8'd0;

        if (!hblank && !vblank && runtime_ready && fb_frame_valid) begin
            video_r = palette_r;
            video_g = palette_g;
            video_b = palette_b;
        end
    end
`endif

    // Sticky renderer heartbeat for SignalTap and the hardware diagnostic
    // LED path. It proves that the sprite engine is producing framebuffer
    // writes even when the displayed colour is black.
    always_ff @(posedge clk) begin
        if (reset || !runtime_ready)
            debug_framebuffer_write_count <= 32'd0;
        else if (fb_wr_en)
            debug_framebuffer_write_count <= debug_framebuffer_write_count + 32'd1;
    end

endmodule
