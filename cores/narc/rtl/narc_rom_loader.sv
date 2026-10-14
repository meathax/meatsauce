// -----------------------------------------------------------------------------
// NARC (Williams Z-unit) MiSTer ROM stream loader.
//
// ioctl index 0:
//   0x000000..0x00000f  16-byte "NZ" header (not written)
//   0x000010..0x08000f  512 KB populated TMS34010 program image
//   0x080010..           linear 8bpp GFX bytes (MRA output="32")
//
// FROZEN one-stick SDRAM word layout (Wave 0 — matches rtl/mem/sdram.sv):
//   0x000000..0x03ffff  program                 512 KiB
//   0x400000..0x7fffff  GFX (two pixels/word)   8 MiB map
//   0x800000..0x80ffff  main RAM                128 KiB (CPU path, not ioctl0)
//   0x810000..0x813fff  CMOS/NVRAM              32 KiB (ioctl index 2)
//   0xc00000..0xc8ffff  sound ROMs              1.125 MiB
//
// ioctl index 1:
//   0x000000..0x08ffff  master 6809 region
//   0x090000..0x11ffff  slave 6809 region
// -----------------------------------------------------------------------------

`default_nettype none
module narc_rom_loader (
  input  wire        clk,
  input  wire        rst,
  input  wire        ioctl_download,
  input  wire [7:0]  ioctl_index,
  input  wire        ioctl_wr,
  input  wire [26:0] ioctl_addr,
  input  wire [7:0]  ioctl_dout,
  output reg         ioctl_wait,

  output reg         sdr_wr_req,
  output reg  [24:1] sdr_wr_addr,
  output reg  [15:0] sdr_wr_din,
  output reg  [1:0]  sdr_wr_be,
  input  wire        sdr_wr_ack,
  output reg         rom_loaded,
  output reg         sound_rom_loaded
);

  localparam logic [26:0] HDR_BYTES     = 27'h000010;
  localparam logic [26:0] PROG_BYTES    = 27'h080000;
  localparam logic [24:1] GFX_WORD_BASE = 24'h400000;
  localparam logic [24:1] SND_WORD_BASE = 24'hC00000;
  localparam logic [24:1] CMOS_WORD_BASE = 24'h810000;
  // The MRA's index-1 payload is two adjacent 0x90000-byte CPU images:
  // master first, slave second. Reject anything beyond that exact 0x120000
  // byte envelope so a malformed or mixed download cannot spill into the
  // following SDRAM bank.
  localparam logic [26:0] SOUND_BYTES   = 27'h120000;
  localparam logic [23:0] SOUND_WORDS   = 24'h090000;

  wire [26:0] payload_addr = ioctl_addr - HDR_BYTES;
  wire is_header = (ioctl_index == 8'd0) && (ioctl_addr < HDR_BYTES);
  wire is_prog   = (ioctl_index == 8'd0) && (ioctl_addr >= HDR_BYTES) &&
                   (payload_addr < PROG_BYTES);
  wire is_gfx    = (ioctl_index == 8'd0) && (ioctl_addr >= HDR_BYTES) &&
                   (payload_addr >= PROG_BYTES);
  wire is_sound  = (ioctl_index == 8'd1) && (ioctl_addr < SOUND_BYTES);
  wire is_nvram  = (ioctl_index == 8'd3) && (ioctl_addr < 27'd32768);
  // Each indexed MiSTer stream is independently byte-addressed. Do not let
  // an odd trailing byte from the previous stream become the low lane of the
  // first sound-ROM word.
  wire indexed_stream_start = (ioctl_addr == 0) && (ioctl_index != 8'd0);

  logic        pair_have_lo;
  logic [7:0]  pair_lo;
  logic [23:0] prog_wcnt;
  logic [23:0] gfx_wcnt;
  logic [23:0] snd_wcnt;
  logic [13:0] cmos_wcnt;
  logic        seen_download;
  logic        download_d;
  logic [7:0]  download_index_d;
  logic        sound_stream_seen;
  logic        sound_stream_full;
  logic        sound_stream_complete_pending;
  wire paired_write_pending = ioctl_download && ioctl_wr && pair_have_lo &&
                              (is_prog || is_gfx || is_sound || is_nvram);

  always_ff @(posedge clk) begin
    sdr_wr_req <= sdr_wr_req && !sdr_wr_ack;
    // Assert backpressure in the same cycle that the second byte launches a
    // paired SDRAM write. A one-clock-late wait lets the following byte enter
    // while sdr_wr_req is still outstanding and drops bytes in long streams.
    ioctl_wait <= sdr_wr_req || sdr_wr_ack || paired_write_pending;
    download_d <= ioctl_download;
    download_index_d <= ioctl_index;

    if (rst) begin
      pair_have_lo <= 1'b0;
      pair_lo      <= 8'd0;
      prog_wcnt    <= 24'd0;
      gfx_wcnt     <= 24'd0;
      snd_wcnt     <= 24'd0;
      cmos_wcnt    <= 14'd0;
      seen_download <= 1'b0;
      download_d   <= 1'b0;
      download_index_d <= 8'd0;
      rom_loaded   <= 1'b0;
      sound_rom_loaded <= 1'b0;
      sound_stream_seen <= 1'b0;
      sound_stream_full <= 1'b0;
      sound_stream_complete_pending <= 1'b0;
      sdr_wr_req   <= 1'b0;
      sdr_wr_addr  <= 24'd0;
      sdr_wr_din   <= 16'd0;
      sdr_wr_be    <= 2'b11;
      ioctl_wait   <= 1'b0;
    end else begin
      if (ioctl_download) seen_download <= 1'b1;
      if (download_d && !ioctl_download && seen_download)
        rom_loaded <= 1'b1;

      // The MRA may present all indexed regions under one download level, or
      // may start a fresh level for each region. Track the sound region itself
      // so the dual 6809 board cannot run against a partially populated ROM.
      if (ioctl_download && (ioctl_index == 8'd1) &&
          (!download_d || download_index_d != 8'd1)) begin
        sound_rom_loaded <= 1'b0;
        sound_stream_seen <= 1'b0;
        sound_stream_full <= 1'b0;
        sound_stream_complete_pending <= 1'b0;
      end else if (sound_stream_seen &&
                   (!ioctl_download || ioctl_index != 8'd1)) begin
        sound_stream_seen <= 1'b0;
        if (sound_stream_full && !pair_have_lo) begin
          if (!sdr_wr_req && !sdr_wr_ack)
            sound_rom_loaded <= 1'b1;
          else
            sound_stream_complete_pending <= 1'b1;
        end
      end
      if (sound_stream_complete_pending && sound_stream_full &&
          !pair_have_lo && !sdr_wr_req && !sdr_wr_ack) begin
        sound_rom_loaded <= 1'b1;
        sound_stream_complete_pending <= 1'b0;
      end
      if (ioctl_download && ioctl_wr && !ioctl_wait && is_sound)
        sound_stream_seen <= 1'b1;

      // Rearm every region counter at the START of each download. `rst` is only
      // ~pll_locked, so without this a second ioctl_download in one FPGA
      // configuration resumed the previous count: a re-loaded program image
      // would be written into the GFX region, and a second CMOS restore would
      // land at 0x454000+ (outside the CMOS window) and silently do nothing.
      // Clearing pair_have_lo here also stops an odd-length payload from
      // byte-shifting every following region. Placed before the write path so a
      // write in the same cycle as the download edge still takes effect.
      if (ioctl_download && !download_d) begin
        pair_have_lo <= 1'b0;
        prog_wcnt    <= 24'd0;
        gfx_wcnt     <= 24'd0;
        snd_wcnt     <= 24'd0;
        cmos_wcnt    <= 14'd0;
      end

      if (ioctl_download && ioctl_wr && !ioctl_wait) begin
        if (is_header || indexed_stream_start) begin
          // Header bytes are consumed only to keep the MRA format explicit.
          if (is_header)
            pair_have_lo <= 1'b0;
          else begin
            pair_lo      <= ioctl_dout;
            pair_have_lo <= 1'b1;
          end
        end else if (is_prog || is_gfx || is_sound || is_nvram) begin
          if (!pair_have_lo) begin
            pair_lo      <= ioctl_dout;
            pair_have_lo <= 1'b1;
          end else begin
            pair_have_lo <= 1'b0;
            sdr_wr_din   <= {ioctl_dout, pair_lo};
            sdr_wr_be    <= 2'b11;
            sdr_wr_req   <= 1'b1;
            if (is_prog) begin
              sdr_wr_addr <= prog_wcnt;
              prog_wcnt   <= prog_wcnt + 24'd1;
            end else if (is_gfx) begin
              sdr_wr_addr <= GFX_WORD_BASE + gfx_wcnt;
              gfx_wcnt    <= gfx_wcnt + 24'd1;
            end else if (is_sound) begin
              sdr_wr_addr <= SND_WORD_BASE + snd_wcnt;
              if (snd_wcnt == SOUND_WORDS - 1'b1)
                sound_stream_full <= 1'b1;
              snd_wcnt    <= snd_wcnt + 24'd1;
            end else begin
              sdr_wr_addr <= CMOS_WORD_BASE + {{10{1'b0}}, cmos_wcnt};
              cmos_wcnt   <= cmos_wcnt + 14'd1;
            end
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
