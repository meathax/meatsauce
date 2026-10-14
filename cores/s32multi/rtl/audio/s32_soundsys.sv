//============================================================================
//  System 32 / Multi 32 sound subsystem glue (DESIGN.md §7, Appendix B)
//  Z80 (T80s) + memory/IO decode + banking + interrupt controller +
//  2x jt12 (YM3438) or 1x jt12 + MultiPCM, RF5C68, shared RAM.
//============================================================================

import s32_pkg::*;

module s32_soundsys #(
    parameter SYSTEM32_ONLY = 1'b0,
    // Two ways per set.  The original two-word cache is represented by one
    // set; production keeps four sets so short ROM-resident loops and a
    // simultaneous banked-data stream remain resident without speculative
    // SDRAM reads.  Keep this a power of two.
    parameter integer ZROM_CACHE_SETS = 4
) (
    input             clk,          // clk_sys
    input             ce_z80,       // 8.054 / 8.0 MHz
    input             ce_fm,        // YM3438 clock enable (chip-internal /6)
    input             ce_pcm,       // 12.5 MHz (RF5C68) / 10 MHz (MultiPCM)
    input             rst,          // board/system reset
    input             z80_reset,    // I/O-chip CNT2: sound-CPU reset only
    input             is_multi32,
    input      [2:0]  game_profile, // descriptor-selected Multi 32 title

    // V60 side of shared RAM (16-bit byte-enabled port on the 0x700000 window)
    input             sh_cs,
    input             sh_we,
    input      [11:0] sh_addr,      // word address within the 8 KB window
    input       [1:0] sh_be,
    input      [15:0] sh_wdata,
    output     [15:0] sh_rdata,

    // main CPU doorbell (int_control offsets 12-15 write)
    input             v60_doorbell,
    // sound -> main IRQ (Z80 port 0xc0.. bit2 set)
    output reg        irq_to_v60,

    // Z80 sound ROM via SDRAM (p3 port)
    output            zrom_req,
    output     [23:0] zrom_addr,    // byte address within soundcpu region
    input      [15:0] zrom_data,
    input             zrom_ack,

    // MultiPCM sample ROM via SDRAM
    output            mpcm_req,
    output     [21:0] mpcm_addr,
    input       [7:0] mpcm_data,
    input             mpcm_ack,

    // System 32 RF5C68 mutable wave RAM backing. The universal profile maps
    // this onto the otherwise-unused MultiPCM SDRAM aperture; Multi 32 keeps
    // the original internal RF RAM and leaves these ports inactive.
    output            wave_rd_req,
    output     [15:0] wave_rd_addr,
    input      [15:0] wave_rd_data,
    input             wave_rd_ack,
    output            wave_wr_req,
    output     [15:0] wave_wr_addr,
    output      [7:0] wave_wr_data,
    input             wave_wr_ack,

    output signed [15:0] audio_l,
    output signed [15:0] audio_r
);

// ---------------------------------------------------------------------------
// Z80 core (T80s, VHDL). Fast all-Verilog core tests use a behavioral
// stub, while S32_REAL_Z80_SIM enables the same mixed-language CPU used by
// hardware for dedicated sound-ROM boot and bus-integration regressions.
// ---------------------------------------------------------------------------
wire [15:0] z_addr;
wire [7:0]  z_dout;
reg  [7:0]  z_din;
wire        z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_m1_n;
reg         z_int_n;
wire        z_wait_n;

`ifdef SIMULATION
`ifndef S32_REAL_Z80_SIM
`define S32_Z80_STUB
`endif
`endif
`ifndef S32_Z80_STUB
T80s z80 (
    .RESET_n (~(rst | z80_reset)),
    .CLK     (clk),
    .CEN     (ce_z80),
    .WAIT_n  (z_wait_n),
    .INT_n   (z_int_n),
    .NMI_n   (1'b1),
    .BUSRQ_n (1'b1),
    .M1_n    (z_m1_n),
    .MREQ_n  (z_mreq_n),
    .IORQ_n  (z_iorq_n),
    .RD_n    (z_rd_n),
    .WR_n    (z_wr_n),
    .RFSH_n  (),
    .HALT_n  (),
    .BUSAK_n (),
    .OUT0    (1'b0),
    .A       (z_addr),
    .DI      (z_din),
    .DO      (z_dout),
    .REG     (),
    .DIRSet  (1'b0),
    .DIR     (230'd0),
    .ISet_out()
);
`else
assign z_addr = 16'h0000; assign z_dout = 8'h00;
assign z_mreq_n = 1'b1; assign z_iorq_n = 1'b1;
assign z_rd_n = 1'b1; assign z_wr_n = 1'b1; assign z_m1_n = 1'b1;
`endif
`ifdef S32_Z80_STUB
`undef S32_Z80_STUB
`endif

wire z_mem_rd = ~z_mreq_n & ~z_rd_n;
wire z_mem_wr = ~z_mreq_n & ~z_wr_n;
wire z_io_rd  = ~z_iorq_n & ~z_rd_n & z_m1_n;
wire z_io_wr  = ~z_iorq_n & ~z_wr_n;
wire z_intack = ~z_iorq_n & ~z_m1_n;

// ---------------------------------------------------------------------------
// memory decode:
//  0000-9FFF ROM (fixed)  A000-BFFF ROM bank  C000-DFFF PCM chip
//  E000-FFFF shared RAM (8KB)
// ---------------------------------------------------------------------------
reg [8:0] sound_bank;
wire [23:0] rom_byte_addr = (z_addr < 16'ha000) ? {8'b0, z_addr}
                          : {2'b0, sound_bank, z_addr[12:0]};

// ROM fetch through the SDRAM word port with byte select + a two-way cache.
// A single cached word thrashed on copy loops (LDIR from banked ROM to wave
// RAM alternates opcode-word and data-word fetches), stalling the Z80 on nearly
// every access.  Two ways preserve those independent streams; several sets
// additionally retain the short instruction loops that feed them.  Misses
// are still demand-only: this cache never creates prefetch/idle SDRAM traffic.
localparam integer ZROM_SET_BITS = (ZROM_CACHE_SETS <= 1) ? 1 : $clog2(ZROM_CACHE_SETS);
reg        rreq;
reg [23:1] raddr;               // outstanding SDRAM request address
reg [ZROM_SET_BITS-1:0] rreq_set;
reg        rreq_way;
// The production arrays are deliberately tiny (four asynchronous-read rows
// per way, 312 tag+data bits total).  Keep them as flat per-way arrays and let
// force them into ALM logic so they do not consume scarce M10K blocks.
(* ramstyle = "logic" *) reg [23:1] rtag0 [0:ZROM_CACHE_SETS-1];
(* ramstyle = "logic" *) reg [23:1] rtag1 [0:ZROM_CACHE_SETS-1];
(* ramstyle = "logic" *) reg [15:0] rdata0 [0:ZROM_CACHE_SETS-1];
(* ramstyle = "logic" *) reg [15:0] rdata1 [0:ZROM_CACHE_SETS-1];
reg [ZROM_CACHE_SETS-1:0] rvalid0;
reg [ZROM_CACHE_SETS-1:0] rvalid1;
reg [ZROM_CACHE_SETS-1:0] rreplace; // next victim when both ways are valid
assign zrom_req  = rreq;
assign zrom_addr = {raddr, 1'b0};
wire rom_sel = (z_addr < 16'hc000);
wire [ZROM_SET_BITS-1:0] rom_set = (ZROM_CACHE_SETS <= 1) ?
                                      {ZROM_SET_BITS{1'b0}} :
                                      rom_byte_addr[ZROM_SET_BITS:1];
wire hit0 = rvalid0[rom_set] && (rtag0[rom_set] == rom_byte_addr[23:1]);
wire hit1 = rvalid1[rom_set] && (rtag1[rom_set] == rom_byte_addr[23:1]);
wire rom_hit = hit0 || hit1;
wire [15:0] rom_word = hit0 ? rdata0[rom_set] : rdata1[rom_set];
// No RF5C68 on this board -- see the tie-off comment near pcm_cs below.
wire        rf_cpu_wait = 1'b0;
assign z_wait_n = ~((rom_sel && z_mem_rd && !rom_hit) || rf_cpu_wait);

always @(posedge clk) begin
    if (rst) begin
        rreq <= 1'b0;
        rvalid0 <= {ZROM_CACHE_SETS{1'b0}};
        rvalid1 <= {ZROM_CACHE_SETS{1'b0}};
        rreplace <= {ZROM_CACHE_SETS{1'b0}};
    end
    else begin
        // ACK must return low before another request is armed.  This makes a
        // stretched completion unambiguous: it cannot be mistaken for the
        // response to a newly launched miss on the following address.
        if (rom_sel && z_mem_rd && !rom_hit && !rreq && !zrom_ack) begin
            rreq  <= 1'b1;
            raddr <= rom_byte_addr[23:1];
            rreq_set <= rom_set;
            // Fill an invalid way first; use the per-set LRU victim only once
            // both ways in this set contain demand-fetched data.
            if (!rvalid0[rom_set])      rreq_way <= 1'b0;
            else if (!rvalid1[rom_set]) rreq_way <= 1'b1;
            else                        rreq_way <= rreplace[rom_set];
        end
        // Consume exactly one completion for the outstanding request.  Some
        // integration models (and a conservatively stretched CDC pulse) can
        // hold ACK beyond one clk edge; a second fill must not advance the
        // victim state or duplicate the same word into both ways.
        if (zrom_ack && rreq) begin
            rreq <= 0;
            if (rreq_way) begin
                rdata1[rreq_set]  <= zrom_data;
                rtag1[rreq_set]   <= raddr;
                rvalid1[rreq_set] <= 1'b1;
            end
            else begin
                rdata0[rreq_set]  <= zrom_data;
                rtag0[rreq_set]   <= raddr;
                rvalid0[rreq_set] <= 1'b1;
            end
            rreplace[rreq_set] <= ~rreq_way;
        end
        else if (rom_sel && z_mem_rd && rom_hit) begin
            // True LRU for each two-way set.  An LDIR-style hot opcode word
            // is touched between streaming source words, so the source stream
            // repeatedly replaces its own old word instead of the opcode.
            rreplace[rom_set] <= hit0;
        end
    end
end

// Byte-packed 8 KB shared RAM.  MAME installs the Z80's 0xE000-0xFFFF onto the
// V60's 0x700000 window with 8-bit handlers on BOTH byte lanes and no umask16,
// so V60 byte k maps to Z80 0xE000+k (byte granularity, 8 KB mirror).  Store it
// as a 4Kx16 dual-port RAM: the V60 gets a real 16-bit byte-enabled port at word
// address A[12:1]; the Z80's 8-bit port reads/writes a single lane selected by
// its low address bit.  The previous 8-bit port addressed at A[13:1] reached
// only even Z80 bytes at halved addresses and dropped every odd byte, corrupting
// any multi-byte V60<->Z80 command block (audit R20 IO-1 / AU-1).
wire [15:0] shz_rd16;
s32_big_dpram #(.ADDR_WIDTH(12), .NUM_WORDS(4096), .MIXED_RDW_MODE("OLD_DATA")) shared_ram (
    .clock_a(clk),
    .address_a(sh_addr), .data_a(sh_wdata), .byteena_a(sh_be),
    .wren_a(sh_cs && sh_we), .q_a(sh_rdata),
    .clock_b(clk),
    .address_b(z_addr[12:1]),
    .data_b({z_dout, z_dout}),
    .byteena_b(z_addr[0] ? 2'b10 : 2'b01),
    .wren_b(z_mem_wr && z_addr[15:13] == 3'b111), .q_b(shz_rd16)
);
// Z80 8-bit read: pick the lane matching the byte address.  q_b carries a
// one-clock registered read exactly as the previous byte RAM did, and the Z80
// holds its address stable across the access, so the current low bit selects
// the correct lane of the word that was fetched.
wire [7:0] shz_rd_r = z_addr[0] ? shz_rd16[15:8] : shz_rd16[7:0];

// ---------------------------------------------------------------------------
// PCM chips
// ---------------------------------------------------------------------------
wire        pcm_cs = (z_addr[15:13] == 3'b110);   // C000-DFFF

// RF5C68 removed: the real Multi 32 board carries one 315-5560 MultiPCM at
// this window and no RF5C68 (confirmed by physical board photos and MAME's
// device config). rf_cpu_wait (declared near the top of the file, before its
// z_wait_n use) and the wave_rd/wave_wr port pair (System 32's external-SDRAM
// wave-RAM aperture, never used on hardware -- see the removed 2026-08-14
// revert note in git history) are tied inactive so the port list and the
// wait-state OR term above need no change.
assign wave_rd_req = 1'b0;
assign wave_rd_addr = 16'h0000;
assign wave_wr_req = 1'b0;
assign wave_wr_addr = 16'h0000;
assign wave_wr_data = 8'h00;

reg [2:0] mpcm_bank_lo, mpcm_bank_hi;
wire signed [15:0] mp_l, mp_r;
s32_multipcm multipcm (
    .clk(clk), .ce(ce_pcm), .rst(rst),
    .cs(pcm_cs & (z_mem_rd | z_mem_wr)),
    .we(z_mem_wr),
    .addr(z_addr[1:0]), .wdata(z_dout), .rdata(),
    .rom_req(mpcm_req), .rom_addr(mpcm_addr),
    .rom_data(mpcm_data), .rom_ack(mpcm_ack),
    .bank_lo(mpcm_bank_lo), .bank_hi(mpcm_bank_hi),
    .out_l(mp_l), .out_r(mp_r)
);

// ---------------------------------------------------------------------------
// FM: 2x jt12 in YM2612/3438 mode (jt12 top: jt12; using jt03-style wrapper).
// The board's real part is the YM3438 (no accumulator limiter); jt12 always has
// the YM2612-style limiter enabled (jt12_acc.v: "JT12 always has a limiter") with
// no mode parameter to disable it.  This is the canonical, community-accepted
// YM3438 approximation (same jt12 core every MiSTer YM3438 game uses); the only
// difference is peak-level linearity on the loudest legal samples.  Accepted, not
// patched -- forking the vendored core for that cosmetic delta is not sim-verifiable
// (the sim path uses jt12_stub) and would diverge from the canonical core.
// ---------------------------------------------------------------------------
// One YM3438: the real Multi 32 board carries a single YM3438 (physical
// board photos, MAME device config) -- port 0x90-0x9F is unmapped hardware,
// not a second FM chip.
wire [7:0] fm1_dout;
wire       fm1_irq_n;
wire signed [15:0] fm1_l, fm1_r;

wire fm1_cs = z_io_rd | z_io_wr ? (z_addr[7:4] == 4'h8) : 1'b0;

jt12 fm1 (
    .rst(rst), .clk(clk), .cen(ce_fm),
    .din(z_dout), .addr(z_addr[1:0]),
    .cs_n(~fm1_cs), .wr_n(z_wr_n | z_iorq_n),
    .dout(fm1_dout), .irq_n(fm1_irq_n),
    .en_hifi_pcm(1'b1),
    .snd_left(fm1_l), .snd_right(fm1_r), .snd_sample()
);

// ---------------------------------------------------------------------------
// sound interrupt controller (Appendix B.2): 3 vector slots
// ---------------------------------------------------------------------------
reg [7:0] snd_irq_ctl [0:2];
reg [2:0] snd_irq_input;
reg [2:0] snd_irq_next;
reg [7:0] snd_irq_mask;   // slot 3 = mask reg (MAME: m_sound_irq_control[3])
reg [7:0] sound_dummy_value;

wire ym_irq = ~fm1_irq_n;   // only YM #1 wired (MAME)
reg  ym_irq_d;

// vector on intack: lowest pending slot * 2
reg [7:0] int_vector;
always @(*) begin
    int_vector = 8'h00;
    z_int_n = 1'b1;
    for (int i = 2; i >= 0; i--)
        if (snd_irq_input[i] & ~snd_irq_mask[i]) begin
            int_vector = {5'b0, i[1:0], 1'b0};
            z_int_n = 1'b0;
        end
end

// Merge an acknowledge with source changes before committing the pending
// bits.  An event arriving on the acknowledge cycle must remain pending; the
// previous sequence of nonblocking assignments allowed the ACK to overwrite
// a simultaneous YM/V60 event.
always @(*) begin
    snd_irq_next = snd_irq_input;
    if (z_io_wr && z_addr[7:4] == 4'hc && z_addr[0])
        snd_irq_next = snd_irq_next & z_dout[2:0];
    if (ym_irq & ~ym_irq_d)
        for (int i = 0; i < 3; i++)
            if (snd_irq_ctl[i] == SOUND_IRQ_YM3438[7:0])
                snd_irq_next[i] = 1'b1;
    if (~ym_irq & ym_irq_d)
        for (int i = 0; i < 3; i++)
            if (snd_irq_ctl[i] == SOUND_IRQ_YM3438[7:0])
                snd_irq_next[i] = 1'b0;
    if (v60_doorbell)
        for (int i = 0; i < 3; i++)
            if (snd_irq_ctl[i] == SOUND_IRQ_V60[7:0])
                snd_irq_next[i] = 1'b1;
end

always @(posedge clk) begin
    if (rst) begin
        snd_irq_input <= 0;
        snd_irq_ctl[0] <= 8'h00;
        snd_irq_ctl[1] <= 8'h00;
        snd_irq_ctl[2] <= 8'h00;
        snd_irq_mask  <= 8'h00;
        sound_dummy_value <= 8'h00;
        sound_bank    <= 0;
        mpcm_bank_lo  <= 3'd0;
        mpcm_bank_hi  <= 3'd0;
        irq_to_v60    <= 0;
        ym_irq_d      <= 0;
    end
    else begin
        irq_to_v60 <= 1'b0;
        ym_irq_d   <= ym_irq;
        snd_irq_input <= snd_irq_next;

        // Z80 IO writes
        if (z_io_wr) begin
            casez (z_addr[7:0])
                8'ha?: sound_bank[5:0] <= z_dout[5:0];
                8'hb?: begin
                    if (is_multi32) begin
                        // Stadium Cross drives both MultiPCM bank halves from
                        // the same three-bit latch (MAME scross_bank_w).
                        if (game_profile == MULTI32_STADIUM_CROSS) begin
                            mpcm_bank_hi <= z_dout[2:0];
                            mpcm_bank_lo <= z_dout[2:0];
                        end
                        else begin
                            mpcm_bank_hi <= z_dout[5:3];
                            mpcm_bank_lo <= z_dout[2:0];
                        end
                    end
                    else sound_bank[8:6] <= {z_dout[1:0], z_dout[2]};
                end
                8'hc?: begin
                    if (z_addr[2]) irq_to_v60 <= 1'b1;                // doorbell
                end
                8'hd?: begin
                    // MAME maps D0-D3 mirrored only at D4-D7.  D8-DF are
                    // genuinely unmapped and must not alias these registers.
                    if (!z_addr[3]) begin
                        if (z_addr[1:0] == 2'd3) snd_irq_mask <= z_dout;
                        else                    snd_irq_ctl[z_addr[1:0]] <= z_dout;
                    end
                end
                8'hf1: sound_dummy_value <= z_dout;
                default: ;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Z80 read mux
// ---------------------------------------------------------------------------
always @(*) begin
    if (z_intack)      z_din = int_vector;
    else if (z_io_rd) begin
        casez (z_addr[7:0])
            8'h8?: z_din = fm1_dout;
            8'h9?: z_din = 8'hff;  // unmapped: only one YM3438 on this board
            8'hf1: z_din = sound_dummy_value;
            default: z_din = 8'hff;
        endcase
    end
    else if (z_mem_rd) begin
        if (z_addr[15:13] == 3'b111)      z_din = shz_rd_r;
        // multipcm_device::read() always returns 0x00 in MAME -- the real
        // 315-5560 register window is write-only.
        else if (pcm_cs)                  z_din = 8'h00;
        else                              z_din = rom_byte_addr[0] ? rom_word[15:8] : rom_word[7:0];
    end
    else z_din = 8'hff;
end

// ---------------------------------------------------------------------------
// Output mixer. Widen before arithmetic and saturate after route scaling so
// full-scale legal samples cannot wrap around and reverse polarity.
// ---------------------------------------------------------------------------
s32_audio_mix output_mixer (
    .fm1_l(fm1_l), .fm1_r(fm1_r),
    .mp_l(mp_l),   .mp_r(mp_r),
    .audio_l(audio_l), .audio_r(audio_r)
);

endmodule
