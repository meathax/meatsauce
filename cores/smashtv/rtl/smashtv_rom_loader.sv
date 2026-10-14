// -----------------------------------------------------------------------------
// smashtv_rom_loader.sv
//
// Routes the MiSTer ioctl download (index 0 = the MRA-assembled ROM image) into
// the core's memories, for the whole Midway Y-Unit (CVSD) family. The image is
// prefixed with a small CONFIG HEADER so one core/loader serves multiple games
// (Smash TV 6bpp, Trog 4bpp, ...). SDRAM layout below the header is UNCHANGED,
// so Smash TV's proven memory map is untouched.
//
// ioctl index 0 layout:
//   0x000000 .. 0x00000F   CONFIG HEADER (16 bytes) -- see below, NOT written to SDRAM
//   +0x000000 .. +0x03FFFF program ROM, 256 KB, interleaved (u105/u89)
//                          -> SDRAM word address 0x00000 .. 0x1FFFF
//   +0x040000 ..           GFX ROM, N MB, de-interleaved per bpp
//                          -> SDRAM word address 0x20000 ..
// ioctl index 1            sound ROM (CVSD 6809) -> SDRAM word base 0x500000
//
// CONFIG HEADER (16 bytes):
//   [0]='Y' [1]='U'   magic
//   [2]=game_id       0=smashtv 1=trog 2=hiimpact 3=shimpact 4=strkforc
//   [3..15]           reserved
// game_id drives bpp / protection / control scheme (decoded below + in the core).
//
// GFX FORMAT:
//   6bpp (Smash TV): MRA output="32" delivers 4-byte groups b0=u1xx(planes0,1)
//     b1=u9x(2,3) b2=u10x(4,5) b3=dup(discarded). pixel_k = {2'b0, b2[hi], b0[hi],
//     b1[hi]} for bit-pair k -- 6-bit pixel.  (LSB-first, MAME init_gfxrom(6).)
//   4bpp (Trog):     MRA output="16" delivers 2-byte groups b0=plane0 b1=plane1.
//     pixel_k = {4'b0, (b1>>2k)&3, (b0>>2k)&3} -- 4-bit pixel.
//     (MAME init_gfxrom(4); validated bit-exact vs the real romset.)
//   Either way: 4 decoded pixel-bytes per group -> 2 SDRAM words {p1,p0},{p3,p2};
//   the blitter reads one byte per pixel at GFX_WORD_BASE + pix/2, byte pix[0].
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_rom_loader #(
  // When 1, load Total Carnage: NO 16-byte config header, 512 KB program,
  // GFX at SDRAM word 0x40000, plus an OKI sample ROM on ioctl index 2. When 0
  // (default), the multi-game CVSD path (Smash TV / Trog / ...) is byte-identical.
  parameter bit TOTCARN = 1'b0
) (
  input  wire        clk,
  input  wire        rst,

  input  wire        ioctl_download,
  input  wire [7:0]  ioctl_index,
  input  wire        ioctl_wr,
  input  wire [26:0] ioctl_addr,
  input  wire [7:0]  ioctl_dout,
  output reg         ioctl_wait,

  // SDRAM write channel (program ROM + GFX ROM + sound ROM)
  output reg         sdr_wr_req,
  output reg  [24:1] sdr_wr_addr,     // word address
  output reg  [15:0] sdr_wr_din,
  output reg  [1:0]  sdr_wr_be,
  input  wire        sdr_wr_ack,

  // Per-game configuration, latched from the header (valid once rom_loaded).
  output reg  [7:0]  game_id,
  output wire        cfg_4bpp,        // 1 = 4bpp GFX (Trog/Strike Force)
  output wire        cfg_has_prot,    // 1 = Y-Unit protection chip present
  output wire        cfg_ctrl_trog,   // 1 = Trog control scheme (4-way + punch)

  output reg         rom_loaded
);

  // Total Carnage has no config header (dedicated TOTCARN=1 build) and a 512 KB
  // program; its GFX sits above the 512 KB program image in SDRAM (word 0x40000).
  localparam [26:0] HDR_BYTES      = TOTCARN ? 27'h000000 : 27'h000010;
  localparam [26:0] PROG_BYTES     = TOTCARN ? 27'h080000 : 27'h040000;  // 512/256 KB program
  localparam [26:0] GFX_BASE       = TOTCARN ? 27'h080000 : 27'h040000;  // payload offset of GFX
  localparam [24:1] GFX_WORD_BASE  = TOTCARN ? 24'h40000  : 24'h20000;   // SDRAM word base for GFX
  localparam [24:1] SND_WORD_BASE  = 24'h500000;   // SDRAM word base for the sound-CPU ROM
  localparam [24:1] OKI_WORD_BASE  = 24'h540000;   // SDRAM word base for the OKI ROM (totcarn)

  // ---- per-game config decode (from latched game_id) ----------------------
  // GID: 0 smashtv, 1 trog, 2 hiimpact, 3 shimpact, 4 strkforc
  assign cfg_4bpp      = (game_id == 8'd1) || (game_id == 8'd4);          // trog, strkforc
  assign cfg_has_prot  = (game_id != 8'd0);                               // all but smashtv
  assign cfg_ctrl_trog = (game_id == 8'd1);                               // trog

  // payload address (below the header)
  wire [26:0] payload_addr = ioctl_addr - HDR_BYTES;
  wire is_cfg  = (ioctl_index == 8'd0) && (ioctl_addr < HDR_BYTES);
  wire is_prog = (ioctl_index == 8'd0) && (ioctl_addr >= HDR_BYTES) && (payload_addr <  PROG_BYTES);
  wire is_gfx  = (ioctl_index == 8'd0) && (ioctl_addr >= HDR_BYTES) && (payload_addr >= GFX_BASE);
  wire is_snd  = (ioctl_index == 8'd1);
  wire is_oki  = TOTCARN && (ioctl_index == 8'd2);   // OKI sample ROM (totcarn only)

  // --- sound ROM state (2-byte pairing, separate .mra index 1) ---
  reg        snd_have_lo;
  reg [7:0]  snd_lo;
  reg [23:0] snd_wcnt;

  // --- OKI ROM state (2-byte pairing, .mra index 2) ---
  reg        oki_have_lo;
  reg [7:0]  oki_lo;
  reg [23:0] oki_wcnt;

  // --- program ROM state (2-byte pairing) ---
  reg        have_lo;
  reg [7:0]  lo_byte;
  reg [23:0] prog_wcnt;

  // --- GFX ROM state (byte-group accumulator: 4 bytes @6bpp, 2 bytes @4bpp) ---
  reg [1:0]  gfx_bidx;       // byte index within a group
  reg [7:0]  gfx_b0;         // plane0 byte
  reg [7:0]  gfx_b1;         // plane1 byte
  reg [7:0]  gfx_b2;         // plane2 byte (6bpp only; b3=dup discarded)
  reg        gfx_second;     // second SDRAM word (pixels 2/3) pending
  reg [23:0] gfx_wcnt;       // GFX SDRAM word counter (2 words per group)

  wire [1:0] gfx_last_idx = cfg_4bpp ? 2'd1 : 2'd3;

  // At the emit cycle the LAST meaningful plane byte is:
  //   6bpp: plane2 = gfx_b2 (latched @idx2; the incoming idx3 byte is the dup)
  //   4bpp: plane1 = ioctl_dout (the incoming idx1 byte, not yet registered)
  // So the FIRST word (pixels 0,1) uses the incoming byte via b1_eff; the SECOND
  // word (pixels 2,3) fires a cycle later and uses the REGISTERED gfx_b1 (which
  // we latch to that same incoming byte at emit for 4bpp). gfx_b0/gfx_b2 are
  // always already registered. This mirrors the proven 6bpp same-cycle emit.
  wire [7:0] b1_eff = cfg_4bpp ? ioctl_dout : gfx_b1;
  // first-word pixels 0,1  (b1 from b1_eff)
  wire [7:0] gfx_p0 = cfg_4bpp ? {4'b0000, b1_eff[1:0], gfx_b0[1:0]}
                               : {2'b00, gfx_b2[1:0], b1_eff[1:0], gfx_b0[1:0]};
  wire [7:0] gfx_p1 = cfg_4bpp ? {4'b0000, b1_eff[3:2], gfx_b0[3:2]}
                               : {2'b00, gfx_b2[3:2], b1_eff[3:2], gfx_b0[3:2]};
  // second-word pixels 2,3  (b1 from registered gfx_b1)
  wire [7:0] gfx_p2 = cfg_4bpp ? {4'b0000, gfx_b1[5:4], gfx_b0[5:4]}
                               : {2'b00, gfx_b2[5:4], gfx_b1[5:4], gfx_b0[5:4]};
  wire [7:0] gfx_p3 = cfg_4bpp ? {4'b0000, gfx_b1[7:6], gfx_b0[7:6]}
                               : {2'b00, gfx_b2[7:6], gfx_b1[7:6], gfx_b0[7:6]};

  always_ff @(posedge clk) begin
    // Default: hold write request until acknowledged; stall download while busy.
    // The controller stretches each ack for ACK_HOLD SDRAM clocks so this
    // (slower) domain can see it -- a new request raised while the stale ack
    // is still high gets cleared instantly and the write is LOST. So: stall
    // ioctl until the ack has fully fallen, and never re-arm before then.
    sdr_wr_req <= sdr_wr_req & ~sdr_wr_ack;
    ioctl_wait <= sdr_wr_req | sdr_wr_ack | gfx_second;

    if (rst) begin
      have_lo    <= 1'b0;
      lo_byte    <= 8'd0;
      prog_wcnt  <= 24'd0;
      gfx_bidx   <= 2'd0;
      gfx_b0     <= 8'd0;
      gfx_b1     <= 8'd0;
      gfx_b2     <= 8'd0;
      gfx_second <= 1'b0;
      gfx_wcnt   <= 24'd0;
      snd_have_lo <= 1'b0;
      snd_lo      <= 8'd0;
      snd_wcnt    <= 24'd0;
      oki_have_lo <= 1'b0;
      oki_lo      <= 8'd0;
      oki_wcnt    <= 24'd0;
      game_id    <= 8'd0;
      rom_loaded <= 1'b0;
      sdr_wr_req <= 1'b0;
      ioctl_wait <= 1'b0;

    end else begin

      // -----------------------------------------------------------------------
      // GFX second word: fires as soon as the first write request clears.
      // gfx_b0/b1/b2 are still valid (ioctl_wait prevents new bytes arriving).
      // -----------------------------------------------------------------------
      if (gfx_second && !sdr_wr_req && !sdr_wr_ack) begin
        gfx_second  <= 1'b0;
        sdr_wr_din  <= {gfx_p3, gfx_p2};
        sdr_wr_addr <= GFX_WORD_BASE + gfx_wcnt;
        sdr_wr_be   <= 2'b11;
        sdr_wr_req  <= 1'b1;
        gfx_wcnt    <= gfx_wcnt + 24'd1;
      end

      // -----------------------------------------------------------------------
      // Byte from ioctl (ioctl_wait prevents new bytes while busy)
      // -----------------------------------------------------------------------
      if (ioctl_download && ioctl_wr) begin

        // Config header: latch game_id (byte offset 2). Not written to SDRAM.
        if (is_cfg) begin
          if (ioctl_addr[3:0] == 4'd2) game_id <= ioctl_dout;
        end

        else if (is_prog) begin
          // Program ROM: pair bytes into 16-bit SDRAM words (lo byte first)
          if (!have_lo) begin
            lo_byte  <= ioctl_dout;
            have_lo  <= 1'b1;
          end else begin
            have_lo     <= 1'b0;
            sdr_wr_din  <= {ioctl_dout, lo_byte};
            sdr_wr_be   <= 2'b11;
            sdr_wr_req  <= 1'b1;
            sdr_wr_addr <= prog_wcnt;
            prog_wcnt   <= prog_wcnt + 24'd1;
          end

        end else if (is_snd) begin
          // Sound ROM: pair bytes into 16-bit SDRAM words at SND_WORD_BASE
          // (byte 2W = low, 2W+1 = high; matches williams_cvsd's byte select).
          if (!snd_have_lo) begin
            snd_lo      <= ioctl_dout;
            snd_have_lo <= 1'b1;
          end else begin
            snd_have_lo <= 1'b0;
            sdr_wr_din  <= {ioctl_dout, snd_lo};
            sdr_wr_be   <= 2'b11;
            sdr_wr_req  <= 1'b1;
            sdr_wr_addr <= SND_WORD_BASE + snd_wcnt;
            snd_wcnt    <= snd_wcnt + 24'd1;
          end

        end else if (is_oki) begin
          // OKI sample ROM: pair bytes into 16-bit SDRAM words at OKI_WORD_BASE.
          if (!oki_have_lo) begin
            oki_lo      <= ioctl_dout;
            oki_have_lo <= 1'b1;
          end else begin
            oki_have_lo <= 1'b0;
            sdr_wr_din  <= {ioctl_dout, oki_lo};
            sdr_wr_be   <= 2'b11;
            sdr_wr_req  <= 1'b1;
            sdr_wr_addr <= OKI_WORD_BASE + oki_wcnt;
            oki_wcnt    <= oki_wcnt + 24'd1;
          end

        end else if (is_gfx) begin
          // GFX ROM: accumulate a group (4 bytes @6bpp / 2 bytes @4bpp),
          // de-interleave, write 2 SDRAM words. Emit on the LAST group byte
          // (same-cycle, like the proven 6bpp path): the first word uses the
          // incoming byte via b1_eff; the second word (gfx_second) uses the
          // registered gfx_b1, which we latch to this incoming byte for 4bpp.
          if (gfx_bidx == gfx_last_idx) begin
            gfx_bidx    <= 2'd0;
            if (cfg_4bpp) gfx_b1 <= ioctl_dout;   // plane1 for the 2nd-word decode
            sdr_wr_din  <= {gfx_p1, gfx_p0};       // first word: pixels 1, 0
            sdr_wr_addr <= GFX_WORD_BASE + gfx_wcnt;
            sdr_wr_be   <= 2'b11;
            sdr_wr_req  <= 1'b1;
            gfx_wcnt    <= gfx_wcnt + 24'd1;
            gfx_second  <= 1'b1;                    // second word: pixels 3, 2
          end else begin
            case (gfx_bidx)
              2'd0: gfx_b0 <= ioctl_dout;
              2'd1: gfx_b1 <= ioctl_dout;
              2'd2: gfx_b2 <= ioctl_dout;
              default: ;
            endcase
            gfx_bidx <= gfx_bidx + 2'd1;
          end
        end
      end

      // Download finished
      if (!ioctl_download) rom_loaded <= 1'b1;
    end
  end
endmodule
`default_nettype wire
