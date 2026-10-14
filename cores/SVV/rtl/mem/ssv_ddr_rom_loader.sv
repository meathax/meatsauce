// ssv_ddr_rom_loader.sv
//
// DDR3 fast-load adaptor for the index-0 ROM stream.
//
// Background: an MRA <rom index="0" address="0x...."> element tells MiSTer
// Main to memcpy the assembled ROM blob straight into DDR3 at that address
// instead of streaming it over the ioctl link byte-by-byte. Main still runs
// the ordinary ioctl_download handshake around the transfer (so ioctl_addr
// ends up holding the final byte count), but emits zero ioctl_wr strobes.
// This is the same convention MiSTer-devel/Arcade-IGSPGM_MiSTer's
// ddr_rom_loader_adaptor uses (rtl/rom_loader.sv, module
// ddr_rom_loader_adaptor) -- ported here rather than copied verbatim because
// this core's ssv_rom_loader keys off ioctl_addr directly for byte-pair
// parity and mapping-table comparisons.
//
// This module sits alongside ssv_rom_loader, not inside it: it watches the
// real HPS ioctl bus for index-0 traffic and classifies which of the two
// download shapes actually happened once ioctl_download for that index
// falls:
//   - at least one ioctl_wr was observed  -> legacy MRA (no address=), the
//     bytes already reached ssv_rom_loader over the real bus. This module
//     stays idle for that entire session; behaviour is byte-for-byte
//     identical to before this module existed.
//   - no ioctl_wr was observed and ioctl_addr != 0 -> address-mode MRA. The
//     blob is sitting in DDR3; ioctl_addr is the byte count. This module
//     reads it back over the DDRAM_* port and replays it as a synthetic
//     ioctl byte stream (replay_wr/replay_addr/replay_dout) with the same
//     one-strobe-per-byte, wait-gated shape hps_io itself uses, so the
//     caller can mux it straight into ssv_rom_loader's ioctl_wr/ioctl_addr/
//     ioctl_dout inputs with no changes to ssv_rom_loader itself.
//
// DDR3 port ownership: ddr_acquire is only ever asserted while the caller's
// core_cold_reset is also asserted (AND'd in here, not left to the caller to
// remember). screen_rotate is the only other DDRAM_* consumer in this core,
// and its write traffic is driven entirely by the DE/sync stream out of
// ssv_core's video timing, which core_cold_reset holds in reset -- so while
// the gate is high, rotate cannot start a transaction and acquiring the port
// cannot contend with one. core_cold_reset is the right gate (an earlier
// revision used video_reset, which ssv_host_guard only asserts for PLL loss
// or an explicit host reset -- it is LOW during a normal MRA load, so the
// adaptor could never acquire the port and the load hung with rom_loaded
// low). core_cold_reset is guaranteed high for the whole replay because the
// guard folds ~rom_loaded into it, and rom_loaded stays low until
// ssv_rom_loader has consumed the final replayed byte. If the gate ever
// dropped mid-load anyway, this module releases the port and stalls
// (LED_USER stays lit) rather than silently corrupting rotate traffic.
module ssv_ddr_rom_loader #(
    parameter [31:0] DDR_BASE_BYTES = 32'h3000_0000  // must match the MRA's address=
)(
    input                clk,
    input                reset,
    input                core_cold_reset, // DDR3 port may only be acquired while this is high

    // Real HPS ioctl bus (only the index-0 window is acted on).
    input                ioctl_download,
    input          [7:0] ioctl_index,
    input                ioctl_wr,
    input         [26:0] ioctl_addr,

    // ssv_rom_loader's own ioctl_wait output (the value it would drive back
    // to hps_io on the real bus). This is fed back in so the replay stream
    // honours the exact same back-pressure contract hps_io does -- without
    // it, replay could push a byte into the loader mid-SDRAM-write.
    input                loader_wait,

    // Synthetic ioctl view for ssv_rom_loader's index-0 path. When
    // replay_active is low every one of these is inert; the caller ORs/
    // muxes them with the real bus and gets the real bus back unchanged.
    output logic         replay_active,
    output logic         replay_wr,
    output logic  [26:0] replay_addr,
    output logic   [7:0] replay_dout,
    // The index the caller must hand ssv_rom_loader. Held at 0 for the whole
    // replay: the loader only accepts a byte while the index it sees is 0, and
    // in address mode Main is long gone by the time we are replaying (see
    // replay_hold), so passing its live index through would drop the rest of
    // the ROM on the floor.
    output logic   [7:0] replay_index,
    // Fold into the core's ioctl_wait. Address mode gives Main no reason to
    // wait: rom_finish() does a shmem_put and drops ioctl_download in
    // milliseconds, then moves to the next MRA element -- every shipped SSV MRA
    // has a trailing <nvram index="4"> -- while we are still replaying
    // megabytes. Without this, that next transfer's bytes are lost, because the
    // caller has muxed the loader's ioctl_wr over to the replay stream.
    output logic         replay_hold,

    // DDRAM_* port (arbitrated by the caller against screen_rotate using
    // ddr_acquire as the select).
    output logic         ddr_acquire,
    output logic   [7:0] ddr_burstcnt,
    output logic  [28:0] ddr_addr,
    output logic         ddr_rd,
    input                ddr_busy,
    input         [63:0] ddr_dout,
    input                ddr_dout_ready
);

localparam [7:0] ROM_INDEX = 8'd0;

typedef enum logic [1:0] {
    S_IDLE,
    S_ISSUE,
    S_WAIT,
    S_DRAIN
} state_t;

state_t      state;
logic        prev_download;
logic        wr_seen;
logic [26:0] length;
logic [26:0] offset;
logic [63:0] buffer;

wire sel = (ioctl_index == ROM_INDEX);

assign ddr_burstcnt  = 8'd1;
// replay_active anticipates the S_IDLE->S_ISSUE transition combinationally
// instead of waiting for the state register. The caller ORs this into the
// loader's ioctl_download view AND (via ssv_host_guard) into core_cold_reset;
// if it only rose a cycle after the real ioctl_download fell, a game switch
// (rom_loaded still high from the previous game, no ioctl_wr in address mode
// to clear it) would see core_cold_reset drop for that one cycle, release the
// core, and -- because this module's port gate is core_cold_reset -- deadlock
// with the replay pending and the gate permanently low. Anticipating the
// transition keeps the download view and the reset hold seamless.
assign replay_active = (state != S_IDLE) ||
                       (sel && prev_download && !ioctl_download &&
                        !wr_seen && ioctl_addr != 27'd0);
assign replay_index  = replay_active ? ROM_INDEX : ioctl_index;
assign replay_hold   = replay_active;
// AND with core_cold_reset every cycle, not just at the moment of
// acquisition: if the gate were ever to drop mid-load this releases the port
// immediately rather than trusting a stale decision from load-start.
assign ddr_acquire   = (state != S_IDLE) && core_cold_reset;

always_ff @(posedge clk) begin
    if (reset) begin
        state          <= S_IDLE;
        prev_download  <= 1'b0;
        wr_seen        <= 1'b0;
        ddr_rd         <= 1'b0;
        replay_wr      <= 1'b0;
    end else begin
        prev_download <= ioctl_download;
        replay_wr     <= 1'b0;

        if (sel && ioctl_download && ioctl_wr)
            wr_seen <= 1'b1;

        case (state)
            S_IDLE: begin
                if (sel && prev_download && !ioctl_download) begin
                    if (wr_seen) begin
                        // Legacy MRA: bytes already streamed over the real
                        // ioctl bus. Nothing to replay.
                        wr_seen <= 1'b0;
                    end
                    else if (ioctl_addr != 27'd0) begin
                        // Address-mode MRA: ioctl_addr is the byte count Main
                        // left behind (user_io_set_download's second argument
                        // is the length in this mode, despite being named
                        // addr), and the blob itself is in DDR3 at
                        // DDR_BASE_BYTES. Subtract the one hps_io adds in its
                        // end-of-download branch: that increment exists to turn
                        // the last-written address into a total in streaming
                        // mode, but nothing was streamed here, so it is pure
                        // overshoot and would replay one byte past the blob.
                        length <= ioctl_addr - 27'd1;
                        offset <= 27'd0;
                        state  <= S_ISSUE;
                    end
                    // ioctl_addr == 0 && !wr_seen: an empty index-0
                    // download. Nothing to load either way.
                end
            end

            S_ISSUE: begin
                // Only issue once the port is actually granted
                // (core_cold_reset asserted) and the previous transaction
                // has drained.
                if (core_cold_reset && !ddr_busy) begin
                    // 8-byte-aligned word address for the current byte
                    // offset, expressed the same way the top-level's other
                    // DDRAM_ADDR producer (screen_rotate) does: a byte
                    // address shifted right by 3.
                    ddr_addr <= DDR_BASE_BYTES[31:3] + {5'b00000, offset[26:3]};
                    ddr_rd   <= 1'b1;
                    state    <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (!ddr_busy)
                    ddr_rd <= 1'b0;
                if (ddr_dout_ready) begin
                    buffer      <= ddr_dout;
                    // Present the first byte of the word straight away; the
                    // strobe for it is raised on the next cycle in S_DRAIN.
                    replay_addr <= offset;
                    replay_dout <= ddr_dout[7:0];
                    state       <= S_DRAIN;
                end
            end

            S_DRAIN: begin
                // One byte per cycle, LSB-first out of the 64-bit word.
                // Stream byte N of the blob Main placed in DDR3 sits at
                // ddr_dout[8*(N%8) +: 8]: the DDR3 port is little-endian, as
                // this core's only other DDRAM_* client shows directly --
                // sys/arcade_video.v's screen_rotate drives
                //   DDRAM_BE = ram_addr[2] ? 8'hF0 : 8'h0F;
                // so byte offsets 0-3 of a word are DIN/DOUT[31:0]. The
                // adaptor this was ported from indexes the same way
                // (buffer[(offset[2:0]*8) +: 8] over an unswapped copy of the
                // read data). Draining from the top of the word instead
                // reversed every group of eight bytes.
                //
                // The strobe is held until ssv_rom_loader actually takes the
                // byte, rather than being raised one cycle after a loader_wait
                // sample. The loader has no input buffer -- it accepts on
                // (ioctl_wr && !busy) and drives ioctl_wait from busy -- so a
                // strobe landing on a stale sample is dropped outright, and
                // because the loader pairs bytes by ioctl_addr[0] a single
                // lost byte mis-pairs the whole rest of the stream.
                // replay_wr is the registered output, so testing it here means
                // testing whether the byte was visible on the bus this cycle.
                replay_wr <= 1'b1;
                if (replay_wr && !loader_wait) begin
                    buffer      <= {8'h00, buffer[63:8]};
                    offset      <= offset + 27'd1;
                    replay_addr <= offset + 27'd1;
                    replay_dout <= buffer[15:8];
                    if (offset + 27'd1 == length) begin
                        state     <= S_IDLE;
                        replay_wr <= 1'b0;
                    end
                    else if (offset[2:0] == 3'd7) begin
                        state     <= S_ISSUE;
                        replay_wr <= 1'b0;
                    end
                    // else: stay in S_DRAIN, next byte comes from the
                    // buffer already latched -- no new DDR read needed.
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
