// -----------------------------------------------------------------------------
// sdram.sv  -- Smash T.V. SDRAM controller
//
// Adapted from the proven Sega System 32 MiSTer controller (rtl/mem/sdram_s32.sv,
// which runs on real DE10-Nano SDRAM). The init/refresh/command engine, the CL2
// timing, and the centred DQ-capture pipeline are kept verbatim; only the client
// ports are changed for NARC's single-module memory plan:
//
// One-stick word map. BANK-SEPARATED as of 2026-07-30: the bank field is
// a[24:23], so banks are 0x400000-word quarters. Each client now owns a bank,
// which combined with the open-page policy below lets a client's row stay
// active across other clients' traffic.
//   Word map:                                              bank
//     0x000000..0x03ffff  program ROM          512 KiB      0
//     0x400000..0x7fffff  GFX address space     8 MiB       1   (fills bank 1)
//     0x800000..0x80ffff  main RAM              128 KiB     2
//     0x810000..0x813fff  CMOS/NVRAM            32 KiB      2
//     0xc00000..0xc8ffff  sound ROM images      1.125 MiB   3
//
//   Measured (sim/sdram_check/tb_sdram_occupancy.sv, gameplay mix):
//     closed-page, interleaved banks   68.1% occupancy   49.4 MB/s
//     open-page,   interleaved banks   69.1% occupancy   51.4 MB/s
//     open-page,   bank-separated      63.3% occupancy   55.9 MB/s
//   Bank separation ALONE measured byte-identical to the old map -- it is
//   worthless without the open-page policy, and vice versa is only +4%.
//   Priority (highest→lowest): wr(loader/NVRAM) > snd > main/CMOS > prog > gfx
//   VRAM stays FPGA BRAM; sound work RAMs stay MLAB; no second stick / no
//   third palette port.
//
//   wr   : ROM/NVRAM download writes from ioctl
//   snd  : dual-sound-board ROM reads
//   main : TMS34010 main RAM and CMOS reads/writes
//   prog : TMS34010 program-ROM three-word field windows
//   gfx  : blitter six-word graphics bursts
//
// All five clients arbitrate one physical SDRAM module. Clock is the SDRAM
// clock (~96-100 MHz); refresh counts are sized for that. Pin-level timing still
// requires post-fit and real-hardware validation. Gate: sim/sdram_check/tb_sdram.
// -----------------------------------------------------------------------------

`default_nettype none
module sdram #(
    // Column-address width of the fitted SDRAM part.
    //   9  = 512-column, 4M x16 x4banks (32 MB module)  -- the original target
    //   11 = 2048-column, 64M x16      (128 MB module)  -- the current target
    //
    // Only the internal row/column split changes; the client address buses stay
    // [24:1] (32 MB of word space), which is ~3x what the frozen map uses. What
    // a wider column buys is a WIDER ROW: 512 words -> 2048 words. With the
    // open-page policy below that directly converts row misses into row hits,
    // so it compounds with the bank separation rather than duplicating it.
    //
    // Column bits map to A[9:0] and then A[11], skipping A[10] because A[10] is
    // the auto-precharge flag on a column command. That is the standard SDRAM
    // column mapping for parts with more than 10 column bits.
    parameter int COLBITS = 9
) (
    input wire        clk,          // SDRAM clock (~96-100 MHz)
    input wire        init,         // reset/init request
    output reg        ready,

    inout wire [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output wire       SDRAM_DQML,
    output wire       SDRAM_DQMH,
    output reg        SDRAM_nCS,
    output reg        SDRAM_nCAS,
    output reg        SDRAM_nRAS,
    output reg        SDRAM_nWE,
    output wire       SDRAM_CKE,
    // SDRAM_CLK is NOT a port here: it's driven directly at the top level by a
    // dedicated 180deg-phase PLL output (the s32 method), so the SDC can
    // reference a clean generated clock instead of an internally-forwarded one.

    // ROM download (write)
    input wire        wr_req,
    input wire [24:1] wr_addr,
    input wire [15:0] wr_din,
    input wire  [1:0] wr_be,
    output reg        wr_ack,

    // program-ROM read: 3-word window starting at prog_addr
    input wire        prog_req,
    input wire [24:1] prog_addr,
    output reg [47:0] prog_dout,     // {w2, w1, w0}
    output reg        prog_ack,

    // GFX read: six 16-bit words (12 packed graphics bytes).
    input wire        gfx_req,
    input wire [24:1] gfx_addr,
    output reg [95:0] gfx_dout,      // {w5..w0} -- 6-word burst (12 packed gfx bytes)
    output reg        gfx_ack,

    // Main RAM: read = 3-word window (like prog); write = single word.
    input wire        main_req,
    input wire        main_we,
    input wire [24:1] main_addr,
    input wire [15:0] main_din,
    input wire  [1:0] main_be,
    output reg [47:0] main_dout,     // {w2, w1, w0} on reads
    output reg        main_ack,

    // Sound-ROM read: single 16-bit word (2 packed sound bytes) at snd_addr.
    input wire        snd_req,
    input wire [24:1] snd_addr,
    output reg [15:0] snd_dout,
    output reg        snd_ack
);

    reg [15:0] dq_out; reg dq_oe; reg [1:0] dqm;
    assign SDRAM_CKE  = 1'b1;
    assign SDRAM_DQML = dqm[0];
    assign SDRAM_DQMH = dqm[1];
    assign SDRAM_DQ   = dq_oe ? dq_out : 16'hZZZZ;

    localparam CL = 3'd2;
    // Deselect between commands. All actual SDRAM commands below still drive
    // nCS low; this keeps the idle output from becoming a falsely constant
    // chip-select pin in the fitted design.
    localparam CMD_NOP=4'b1111, CMD_ACT=4'b0011, CMD_READ=4'b0101,
               CMD_WRITE=4'b0100, CMD_PRE=4'b0010, CMD_REF=4'b0001, CMD_MRS=4'b0000;
    reg [3:0] cmd = CMD_NOP;
    assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

    reg [15:0] init_cnt = 16'hffff;
    wire       init_done = (init_cnt == 0);
    reg [9:0]  ref_cnt; reg ref_pend;

    typedef enum logic [3:0] {
        ST_IDLE, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW, ST_WR, ST_WRRC,
        ST_PRE_REF, ST_REF, ST_REFW, ST_PREB, ST_DEC
    } state_t;
    state_t state = ST_IDLE;

    reg [2:0]  grant;             // 0=prog 1=gfx 2=main 3=wr 4=snd
    reg [3:0]  rd_total, rd_issued, rd_captured;
    reg [24:1] xfer_addr; reg is_write;
    reg [15:0] din_r; reg [1:0] be_r;
    reg [2:0]  wrrc_cnt, refw_cnt, react_cnt;
    reg        read_straddle;   // 3-word window crosses a row boundary
    reg [2:0]  prew_cnt;         // tRP wait after a single-bank PRECHARGE

    // OPEN-PAGE row tracking, one entry per bank.
    //
    // The controller used to auto-precharge (A10=1) on the last word of every
    // transaction, so no row was ever left open and every access paid
    // ACT + tRCD + CAS + tRP. Measured cost of that policy, from
    // sim/sdram_check/tb_sdram_occupancy.sv: 91.7% bus occupancy delivering
    // only 47.2 MB/s of a 193.3 MB/s bus -- about a quarter of the bus doing
    // useful work. It also made per-bank region placement worthless: giving
    // each client its own bank measured byte-identical throughput.
    //
    // Now a row stays open after the burst. A following access to the same
    // bank+row skips ACT and both tRCD cycles entirely; a different row in
    // that bank costs one PRECHARGE + tRP first. Refresh precharges all banks
    // and invalidates every entry.
    reg        row_open [0:3];
    reg [12:0] row_addr [0:3];
    // Ack is held for ACK_HOLD SDRAM-clock cycles. clk (SDRAM/clk_ram) is 96 MHz
    // and the core samples ack on clk_sys = 24 MHz (4:1), so a short 2-cycle ack
    // pulse can fall entirely between two clk_sys edges and be missed -> the core
    // deadlocks waiting for prog/main/gfx data (black screen). Hold it >= 2 clk_sys
    // periods (8 SDRAM cycles) so clk_sys always catches it.
    localparam [3:0] ACK_HOLD = 4'd8;
    // PER-CLIENT hold counters. This was a single shared, restartable counter,
    // which had two bad properties under load:
    //   1. every deliver() reloaded it to ACK_HOLD, so client A's ack was
    //      extended by unrelated traffic from B/C/D finishing inside A's
    //      window;
    //   2. all five acks were cleared together when it hit zero, so a client
    //      whose ack was set late still had it dropped on the shared deadline.
    // Because `pend` cannot re-arm while a client's own ack is high (see
    // below), (1) throttled each channel's re-issue rate non-deterministically
    // as bus load rose, and (2) is a correctness hazard, not just a speed one.
    // Independent counters give every client exactly ACK_HOLD cycles from ITS
    // OWN delivery. The CDC margin is unchanged -- this is not a margin cut.
    reg [3:0]  ah_prog, ah_gfx, ah_main, ah_wr, ah_snd;

    // OPEN-PAGE DECISION IS TAKEN IN ITS OWN STATE (ST_DEC), NOT IN ST_IDLE.
    //
    // History, because this cost a failed fit. The decision was first written
    // inline in ST_IDLE, then "optimised" by precomputing a row-hit bit per
    // client. BOTH forms make the command outputs depend on a client ADDRESS
    // rather than only on its *_pend bit, and main_addr arrives through the
    // NVRAM arbiter mux in the clk_sys domain. The 2026-07-30 fit failed at
    //     narc_nvram_arbiter|nvram_grant (clk_sys) -> sdram|cmd[0] (clk_ram)
    // setup -1.671 ns, TNS -9.095, on a 10.348 ns single-cycle relationship.
    // Before the change, ST_IDLE issued CMD_ACT unconditionally and no address
    // ever reached cmd[], which is why this path did not exist.
    //
    // So ST_IDLE now only ARBITRATES and latches; it issues no command. ST_DEC
    // evaluates the row hit one cycle later, entirely from clk_ram-registered
    // state (xfer_addr, row_open, row_addr). Costs 1 clk_ram per transaction
    // against a 9-13 cycle transaction; a row hit still saves the 2 tRCD cycles
    // plus the precharge, so open-page stays a net win.
    // pend arms on req but NOT while its ack is still asserted (handshake in
    // flight), so a still-high held req (prog/wr/main) does not re-issue during
    // the long ack window.
    reg prog_pend, wr_pend, gfx_pend, main_pend, snd_pend, main_we_r;
    reg [24:1] snd_addr_r;
    always @(posedge clk) begin
        if (prog_req && !prog_ack) prog_pend <= 1'b1;
        if (wr_req   && !wr_ack)   wr_pend   <= 1'b1;
        if (gfx_req  && !gfx_ack)  gfx_pend  <= 1'b1;
        if (main_req && !main_ack) begin main_pend <= 1'b1; main_we_r <= main_we; end
        if (snd_req  && !snd_ack) begin
            snd_pend  <= 1'b1;
            snd_addr_r <= snd_addr;
        end
        if (init) begin
            {prog_pend, wr_pend, gfx_pend, main_pend, snd_pend} <= '0;
            snd_addr_r <= '0;
        end
        if (prog_ack) prog_pend <= 1'b0;
        if (wr_ack)   wr_pend   <= 1'b0;
        if (gfx_ack)  gfx_pend  <= 1'b0;
        if (main_ack) main_pend <= 1'b0;
        if (snd_ack)  snd_pend  <= 1'b0;
    end

    // DQ capture -- the proven MiSTer approach (as in wickerwaka's IremM92 /
    // Sorgelig's canonical sdram.sv): a single posedge sample of SDRAM_DQ. This
    // works because the SDRAM chip is clocked 180 deg out of phase with this
    // controller: SDRAM_CLK is a dedicated PLL phase tap driven straight to the
    // pin at the top level (Arcade-NARC.sv:155, .outclk2_clk(SDRAM_CLK), 5174ps
    // = 180deg of the 10348ps/96.648MHz period), not an internally-forwarded
    // clock -- see the port-list note above and Arcade-NARC.sv:255-257. Read
    // data returned on the chip's edge is therefore centred on our posedge.
    // The capture eye is held by explicit SDC constraints, not left to chance:
    // Arcade-NARC.sdc:50-51 creates the SDRAM_CLK generated clock from that
    // outclk2 PLL pin, :54-55 set the DQ input delays (6.4 max / 3.2 min),
    // :56-61 the command/data output delays, and :62-65 the setup/hold
    // multicycles from SDRAM_CLK back into this controller's clock domain.
    reg [15:0] dq_in; reg [3:0] cl_pipe;
    (* ramstyle = "logic" *) reg [15:0] cap_buf [0:5];   // GFX 6-word burst
    always @(posedge clk) dq_in <= SDRAM_DQ;

    task automatic deliver(input [15:0] final_word);
        case (grant)
            3'd0: begin prog_dout <= {final_word, cap_buf[1], cap_buf[0]};
                        prog_ack <= 1'b1; ah_prog <= ACK_HOLD; end
            // GFX: 6-word burst -> 12 packed pixels per transaction (2x the old
            // 3-word bandwidth), so sprite blits stall far less on the shared
            // SDRAM GFX channel under contention.
            3'd1: begin gfx_dout  <= {final_word, cap_buf[4], cap_buf[3],
                                      cap_buf[2], cap_buf[1], cap_buf[0]};
                        gfx_ack <= 1'b1; ah_gfx <= ACK_HOLD; end
            3'd2: begin main_dout <= {final_word, cap_buf[1], cap_buf[0]};
                        main_ack <= 1'b1; ah_main <= ACK_HOLD; end
            3'd4: begin snd_dout  <= final_word;
                        snd_ack <= 1'b1; ah_snd <= ACK_HOLD; end
            default: ;
        endcase
    endtask

    always @(posedge clk) begin
        cmd   <= CMD_NOP;
        dq_oe <= 1'b0;

        if (ah_prog != 0) ah_prog <= ah_prog - 1'd1; else prog_ack <= 1'b0;
        if (ah_gfx  != 0) ah_gfx  <= ah_gfx  - 1'd1; else gfx_ack  <= 1'b0;
        if (ah_main != 0) ah_main <= ah_main - 1'd1; else main_ack <= 1'b0;
        if (ah_wr   != 0) ah_wr   <= ah_wr   - 1'd1; else wr_ack   <= 1'b0;
        if (ah_snd  != 0) ah_snd  <= ah_snd  - 1'd1; else snd_ack  <= 1'b0;

        if (init) begin
            init_cnt <= 16'hffff; ready <= 1'b0; state <= ST_IDLE;
            ref_pend <= 1'b0; ref_cnt <= 10'd0; dqm <= 2'b11;
            cl_pipe <= 4'b0;
            ah_prog <= 0; ah_gfx <= 0; ah_main <= 0; ah_wr <= 0; ah_snd <= 0;
            for (int b = 0; b < 4; b++) row_open[b] <= 1'b0;
        end
        else if (!init_done) begin
            init_cnt <= init_cnt - 1'd1; dqm <= 2'b11;
            case (init_cnt)
                16'h0400: begin cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1; end
                16'h03c0,16'h0380,16'h0340,16'h0300,
                16'h02c0,16'h0280,16'h0240,16'h0200: cmd <= CMD_REF;
                16'h00a0: begin
                    cmd <= CMD_MRS; SDRAM_BA <= 2'b00;
                    SDRAM_A <= 13'b000_0_00_010_0_000;   // CL2, sequential, burst 1
                end
                16'h0001: ready <= 1'b1;
                default: ;
            endcase
        end
        else begin
            dqm <= 2'b00;
            ref_cnt <= ref_cnt + 1'd1;
            if (ref_cnt == 10'd700) begin ref_cnt <= 0; ref_pend <= 1'b1; end

            cl_pipe <= {cl_pipe[2:0], 1'b0};
            if (cl_pipe[3]) begin
                cap_buf[rd_captured[2:0]] <= dq_in;
                rd_captured <= rd_captured + 1'd1;
                if (rd_captured + 1'd1 == rd_total) begin
                    deliver(dq_in);   // sets this client's own hold counter
                end
            end

            case (state)
            ST_IDLE: begin
                if (ref_pend && cl_pipe == 0) begin
                    cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;   // precharge ALL banks
                    for (int b = 0; b < 4; b++) row_open[b] <= 1'b0;
                    refw_cnt <= 3'd1; state <= ST_PRE_REF;
                end
                else if (wr_pend | main_pend | prog_pend | gfx_pend | snd_pend) begin
                    logic [24:1] a, a2; logic three; logic [3:0] nwords; logic iw;
                    din_r <= wr_din; be_r <= wr_be; three = 1'b0; nwords = 4'd1; iw = 1'b0;
                    if (wr_pend) begin
                        grant <= 3'd3; a = wr_addr; rd_total <= 4'd1; iw = 1'b1;
                    end else if (snd_pend) begin
                        // Sound ROM: HIGHEST read priority. The 6809's E clock
                        // freezes until this single word arrives; as the LOWEST
                        // priority it starved under the fast blitter's dense GFX
                        // bursts and the sound board froze after the boot beep.
                        // Requests are rare single words (64-entry cache, 2 MHz
                        // CPU), so promoting them costs the other channels at
                        // most ~one word-slot occasionally.
                        grant <= 3'd4; a = snd_addr_r; rd_total <= 4'd1; iw = 1'b0;
                    end else if (main_pend) begin
                        grant <= 3'd2; a = main_addr;
                        if (main_we_r) begin rd_total <= 4'd1; iw = 1'b1; din_r <= main_din; be_r <= main_be; end
                        else           begin rd_total <= 4'd3; iw = 1'b0; three = 1'b1; nwords = 4'd3; end
                    end else if (prog_pend) begin
                        grant <= 3'd0; a = prog_addr; rd_total <= 4'd3; iw = 1'b0; three = 1'b1; nwords = 4'd3;
                    end else begin
                        // GFX: 6-word column burst = 12 packed pixels per transaction
                        // (2x the old 3-word bandwidth). Reuses the proven single-ACT
                        // column-burst + per-word straddle path.
                        grant <= 3'd1; a = gfx_addr; rd_total <= 4'd6; iw = 1'b0; three = 1'b1; nwords = 4'd6;
                    end
                    // A multi-word column window straddles when its first and last
                    // word are in different rows (a[22:10]); then the burst re-ACTs
                    // per word instead of column-incrementing on one open row.
                    a2 = a + {20'd0, (nwords - 4'd1)};
                    read_straddle <= three && (a[22:COLBITS+1] != a2[22:COLBITS+1]);
                    react_cnt <= 3'd0;
                    xfer_addr <= a; is_write <= iw;
                    rd_issued <= 0; rd_captured <= 0;
                    state <= ST_DEC;   // decide next cycle, off this path
                end
            end
            // Row-hit decision, all inputs clk_ram-registered.
            ST_DEC: begin
                logic [1:0]  bk; logic [12:0] rw;
                bk = xfer_addr[24:23]; rw = 13'(xfer_addr[22:COLBITS+1]);
                if (row_open[bk] && (row_addr[bk] == rw)) begin
                    state <= is_write ? ST_WR : ST_RD;   // skip ACT + both tRCD
                end else if (row_open[bk]) begin
                    cmd <= CMD_PRE; SDRAM_BA <= bk; SDRAM_A[10] <= 1'b0;
                    row_open[bk] <= 1'b0;
                    prew_cnt <= 3'd2; state <= ST_PREB;
                end else begin
                    cmd <= CMD_ACT; SDRAM_BA <= bk; SDRAM_A <= rw;
                    row_open[bk] <= 1'b1; row_addr[bk] <= rw;
                    state <= ST_RCD1;
                end
            end
            ST_RCD1: state <= ST_RCD2;
            ST_RCD2: state <= is_write ? ST_WR : ST_RD;

            ST_WR: begin
                cmd <= CMD_WRITE; SDRAM_BA <= xfer_addr[24:23];
                SDRAM_A <= {1'b0, (COLBITS > 10) ? xfer_addr[11] : 1'b0,
                            1'b0, xfer_addr[10:1]};   // A10=0: leave row open
                dq_out <= din_r; dq_oe <= 1'b1; dqm <= ~be_r;
                wrrc_cnt <= 3'd4; state <= ST_WRRC;
            end
            ST_WRRC: begin
                if (wrrc_cnt == 3'd4) begin
                    if (grant == 3'd2) begin main_ack <= 1'b1; ah_main <= ACK_HOLD; end
                    else                begin wr_ack   <= 1'b1; ah_wr   <= ACK_HOLD; end
                end
                if (wrrc_cnt == 0) state <= ST_IDLE; else wrrc_cnt <= wrrc_cnt - 1'd1;
            end

            // Read issue. COMMON case (no straddle): s32's PROVEN single-ACT
            // column burst -- back-to-back READs on one open row, auto-precharge
            // on the last, incrementing only the column. This is byte-identical to
            // the Sega System 32 controller that runs on this exact board.
            // STRADDLE case (rare, window crosses a row boundary): one READ per
            // ACT, re-ACTing the correct row for each word (a column-increment
            // burst would wrap the column within the open row -> wrong words).
            ST_RD: begin
                cmd <= CMD_READ; SDRAM_BA <= xfer_addr[24:23];
                cl_pipe[0] <= 1'b1;
                rd_issued <= rd_issued + 1'd1;
                if (!read_straddle) begin
                    SDRAM_A <= {1'b0, (COLBITS > 10) ? xfer_addr[11] : 1'b0,
                                1'b0, xfer_addr[10:1]};  // row stays open
                    xfer_addr[COLBITS:1] <= xfer_addr[COLBITS:1] + 1'd1;
                    if (rd_issued + 1'd1 == rd_total) state <= ST_RDW;  // else stay: next READ
                end else begin
                    SDRAM_A   <= {1'b0, (COLBITS > 10) ? xfer_addr[11] : 1'b0,
                                  1'b0, xfer_addr[10:1]};  // row stays open
                    react_cnt <= 3'd0;   // ST_ACT issues PRE + tRP before the ACT
                    state     <= ST_RDW;
                end
            end
            ST_RDW: if (cl_pipe == 0) begin
                if (react_cnt != 3'd0) react_cnt <= react_cnt - 1'd1;   // straddle margin
                else if (rd_issued == rd_total) state <= ST_IDLE;       // all words done
                else begin
                    xfer_addr[24:1] <= xfer_addr[24:1] + 1'd1;  // straddle: re-ACT next row
                    state <= ST_ACT;
                end
            end
            // Straddle re-activate. With open-page the previous row in this
            // bank is still active, so it must be closed before the next ACT.
            ST_ACT: begin
                cmd <= CMD_PRE; SDRAM_BA <= xfer_addr[24:23]; SDRAM_A[10] <= 1'b0;
                row_open[xfer_addr[24:23]] <= 1'b0;
                prew_cnt <= 3'd2; state <= ST_PREB;
            end

            // tRP wait after a single-bank PRECHARGE, then activate the row we
            // actually want and record it as open.
            ST_PREB: begin
                if (prew_cnt == 0) begin
                    cmd <= CMD_ACT;
                    SDRAM_BA <= xfer_addr[24:23]; SDRAM_A <= 13'(xfer_addr[22:COLBITS+1]);
                    row_open[xfer_addr[24:23]] <= 1'b1;
                    row_addr[xfer_addr[24:23]] <= 13'(xfer_addr[22:COLBITS+1]);
                    state <= ST_RCD1;
                end else prew_cnt <= prew_cnt - 1'd1;
            end

            ST_PRE_REF: begin
                if (refw_cnt == 0) begin
                    cmd <= CMD_REF; ref_pend <= 1'b0; refw_cnt <= 3'd6; state <= ST_REFW;
                end else refw_cnt <= refw_cnt - 1'd1;
            end
            ST_REF: state <= ST_REFW;
            ST_REFW: if (refw_cnt == 0) state <= ST_IDLE; else refw_cnt <= refw_cnt - 1'd1;
            default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
