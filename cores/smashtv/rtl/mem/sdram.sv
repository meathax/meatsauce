// -----------------------------------------------------------------------------
// sdram.sv  -- Smash T.V. SDRAM controller
//
// Adapted from the proven Sega System 32 MiSTer controller (rtl/mem/sdram_s32.sv,
// which runs on real DE10-Nano SDRAM). The init/refresh/command engine, the CL2
// timing, and the centred DQ-capture pipeline are kept verbatim; only the client
// ports are changed to what Smash T.V. needs:
//
//   wr   : ROM download (16-bit word writes from ioctl)
//   prog : TMS34010 program-ROM read -- a 3-word burst (the field window
//          w0,w1,w2 that smashtv_mem's EXTERNAL_PROG path expects)
//
// Main RAM and GFX ROM stay in block RAM for the first bring-up, so only these
// two channels exist. Clock is the SDRAM clock (~96-100 MHz); refresh counts are
// sized for that. Timing only fully validates on hardware.
// -----------------------------------------------------------------------------

`default_nettype none
module sdram (
    input             clk,          // SDRAM clock (~96-100 MHz)
    input             init,         // reset/init request
    output reg        ready,

    inout      [15:0] SDRAM_DQ,
    output reg [12:0] SDRAM_A,
    output reg  [1:0] SDRAM_BA,
    output            SDRAM_DQML,
    output            SDRAM_DQMH,
    output reg        SDRAM_nCS,
    output reg        SDRAM_nCAS,
    output reg        SDRAM_nRAS,
    output reg        SDRAM_nWE,
    output            SDRAM_CKE,
    // SDRAM_CLK is NOT a port here: it's driven directly at the top level by a
    // dedicated 180deg-phase PLL output (the s32 method), so the SDC can
    // reference a clean generated clock instead of an internally-forwarded one.

    // ROM download (write)
    input             wr_req,
    input      [24:1] wr_addr,
    input      [15:0] wr_din,
    input       [1:0] wr_be,
    output reg        wr_ack,

    // program-ROM read: 3-word window starting at prog_addr
    input             prog_req,
    input      [24:1] prog_addr,
    output reg [47:0] prog_dout,     // {w2, w1, w0}
    output reg        prog_ack,

    // GFX read: single 16-bit word (2 packed gfx bytes) at gfx_addr
    input             gfx_req,
    input      [24:1] gfx_addr,
    output reg [95:0] gfx_dout,      // {w5..w0} -- 6-word burst (12 packed gfx bytes)
    output reg        gfx_ack,

    // Main RAM: read = 3-word window (like prog); write = single word.
    input             main_req,
    input             main_we,
    input      [24:1] main_addr,
    input      [15:0] main_din,
    input       [1:0] main_be,
    output reg [47:0] main_dout,     // {w2, w1, w0} on reads
    output reg        main_ack,

    // Sound-ROM read: single 16-bit word (2 packed sound bytes) at snd_addr.
    input             snd_req,
    input      [24:1] snd_addr,
    output reg [15:0] snd_dout,
    output reg        snd_ack
);

    reg [15:0] dq_out; reg dq_oe; reg [1:0] dqm;
    assign SDRAM_CKE  = 1'b1;
    assign SDRAM_DQML = dqm[0];
    assign SDRAM_DQMH = dqm[1];
    assign SDRAM_DQ   = dq_oe ? dq_out : 16'hZZZZ;

    localparam CL = 3'd2;
    localparam CMD_NOP=4'b0111, CMD_ACT=4'b0011, CMD_READ=4'b0101,
               CMD_WRITE=4'b0100, CMD_PRE=4'b0010, CMD_REF=4'b0001, CMD_MRS=4'b0000;
    reg [3:0] cmd = CMD_NOP;
    assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

    reg [15:0] init_cnt = 16'hffff;
    wire       init_done = (init_cnt == 0);
    reg [9:0]  ref_cnt; reg ref_pend;

    typedef enum logic [3:0] {
        ST_IDLE, ST_ACT, ST_RCD1, ST_RCD2, ST_RD, ST_RDW, ST_WR, ST_WRRC,
        ST_PRE_REF, ST_REF, ST_REFW
    } state_t;
    state_t state = ST_IDLE;

    reg [2:0]  grant;             // 0=prog 1=gfx 2=main 3=wr 4=snd
    reg [3:0]  rd_total, rd_issued, rd_captured;
    reg [24:1] xfer_addr; reg is_write;
    reg [15:0] din_r; reg [1:0] be_r;
    reg [2:0]  wrrc_cnt, refw_cnt, react_cnt;
    reg        read_straddle;   // 3-word window crosses a row boundary
    // Ack is held for ACK_HOLD SDRAM-clock cycles. clk (SDRAM/clk_ram) is 96 MHz
    // and the core samples ack on clk_sys = 24 MHz (4:1), so a short 2-cycle ack
    // pulse can fall entirely between two clk_sys edges and be missed -> the core
    // deadlocks waiting for prog/main/gfx data (black screen). Hold it >= 2 clk_sys
    // periods (8 SDRAM cycles) so clk_sys always catches it.
    //
    // PER-CHANNEL stretch (latent-correctness fix): a SINGLE shared ack_stretch
    // counter -- re-armed by EVERY channel's completion and clearing ALL acks
    // together only when it drained -- can let one channel hold another's ack high
    // under sustained back-to-back completions (each new completion re-arms the
    // shared counter before it drains, so an earlier main_ack never clears and
    // smashtv_mem's S_IDLE waits on !main_ext_ack). Each channel now stretches
    // independently, armed only by its own completion, so no channel can pin
    // another's ack. NOTE: this was originally believed to fix the Total Carnage
    // tank-collision grey-out; HARDWARE TESTING DISPROVED THAT -- that grey is a
    // SEPARATE, still-open video/render bug (the game stops drawing the playfield
    // after a specific large sprite is drawn; it is NOT a memory stall). This
    // remains a valid correctness fix but does not address the tank grey.
    localparam [3:0] ACK_HOLD = 4'd8;
    reg [3:0]  ackst_prog, ackst_wr, ackst_gfx, ackst_main, ackst_snd;

    // pend arms on req but NOT while its ack is still asserted (handshake in
    // flight), so a still-high held req (prog/wr/main) does not re-issue during
    // the long ack window.
    reg prog_pend, wr_pend, gfx_pend, main_pend, snd_pend, main_we_r;
    always @(posedge clk) begin
        if (prog_req && !prog_ack) prog_pend <= 1'b1;
        if (wr_req   && !wr_ack)   wr_pend   <= 1'b1;
        if (gfx_req  && !gfx_ack)  gfx_pend  <= 1'b1;
        if (main_req && !main_ack) begin main_pend <= 1'b1; main_we_r <= main_we; end
        if (snd_req  && !snd_ack)  snd_pend  <= 1'b1;
        if (init) {prog_pend, wr_pend, gfx_pend, main_pend, snd_pend} <= '0;
        if (prog_ack) prog_pend <= 1'b0;
        if (wr_ack)   wr_pend   <= 1'b0;
        if (gfx_ack)  gfx_pend  <= 1'b0;
        if (main_ack) main_pend <= 1'b0;
        if (snd_ack)  snd_pend  <= 1'b0;
    end

    // DQ capture -- the proven MiSTer approach (as in wickerwaka's IremM92 /
    // Sorgelig's canonical sdram.sv): a single posedge sample of SDRAM_DQ. This
    // works because SDRAM_CLK is forwarded 180 deg via an altddio_out DDR
    // register (below), so read data returned on the chip's clock is stable
    // around our posedge. No explicit SDRAM SDC constraints (they fight the DDR
    // forwarding and skew the capture eye).
    reg [15:0] dq_in; reg [3:0] cl_pipe;
    reg [15:0] cap_buf [0:5];   // up to 6 captured words (GFX 6-word burst)
    always @(posedge clk) dq_in <= SDRAM_DQ;

    task automatic deliver(input [15:0] final_word);
        case (grant)
            3'd0: begin prog_dout <= {final_word, cap_buf[1], cap_buf[0]}; prog_ack <= 1'b1; ackst_prog <= ACK_HOLD; end
            // GFX: 6-word burst -> 12 packed pixels per transaction (2x the old
            // 3-word bandwidth), so sprite blits stall far less on the shared
            // SDRAM GFX channel under contention.
            3'd1: begin gfx_dout  <= {final_word, cap_buf[4], cap_buf[3],
                                      cap_buf[2], cap_buf[1], cap_buf[0]}; gfx_ack <= 1'b1; ackst_gfx <= ACK_HOLD; end
            3'd2: begin main_dout <= {final_word, cap_buf[1], cap_buf[0]}; main_ack <= 1'b1; ackst_main <= ACK_HOLD; end
            3'd4: begin snd_dout  <= final_word;                          snd_ack <= 1'b1; ackst_snd <= ACK_HOLD; end
            default: ;
        endcase
    endtask

    always @(posedge clk) begin
        cmd   <= CMD_NOP;
        dq_oe <= 1'b0;

        // Per-channel stretch: each ack holds for ACK_HOLD cycles after its own
        // completion, then clears -- independently, so no channel pins another's ack.
        if (ackst_prog != 0) ackst_prog <= ackst_prog - 1'd1; else prog_ack <= 1'b0;
        if (ackst_wr   != 0) ackst_wr   <= ackst_wr   - 1'd1; else wr_ack   <= 1'b0;
        if (ackst_gfx  != 0) ackst_gfx  <= ackst_gfx  - 1'd1; else gfx_ack  <= 1'b0;
        if (ackst_main != 0) ackst_main <= ackst_main - 1'd1; else main_ack <= 1'b0;
        if (ackst_snd  != 0) ackst_snd  <= ackst_snd  - 1'd1; else snd_ack  <= 1'b0;

        if (init) begin
            init_cnt <= 16'hffff; ready <= 1'b0; state <= ST_IDLE;
            ref_pend <= 1'b0; ref_cnt <= 10'd0; dqm <= 2'b11;
            cl_pipe <= 4'b0;
            ackst_prog <= 0; ackst_wr <= 0; ackst_gfx <= 0; ackst_main <= 0; ackst_snd <= 0;
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
                    deliver(dq_in);   // arms this channel's own stretch counter
                end
            end

            case (state)
            ST_IDLE: begin
                if (ref_pend && cl_pipe == 0) begin
                    cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;
                    refw_cnt <= 3'd1; state <= ST_PRE_REF;
                end
                else if (wr_pend | main_pend | prog_pend | gfx_pend | snd_pend) begin
                    logic [24:1] a, a2; logic three; logic [3:0] nwords;
                    din_r <= wr_din; be_r <= wr_be; three = 1'b0; nwords = 4'd1;
                    if (wr_pend) begin
                        grant <= 3'd3; a = wr_addr; rd_total <= 4'd1; is_write <= 1'b1;
                    end else if (snd_pend) begin
                        // Sound ROM: HIGHEST read priority. The 6809's E clock
                        // freezes until this single word arrives; as the LOWEST
                        // priority it starved under the fast blitter's dense GFX
                        // bursts and the sound board froze after the boot beep.
                        // Requests are rare single words (64-entry cache, 2 MHz
                        // CPU), so promoting them costs the other channels at
                        // most ~one word-slot occasionally.
                        grant <= 3'd4; a = snd_addr; rd_total <= 4'd1; is_write <= 1'b0;
                    end else if (main_pend) begin
                        grant <= 3'd2; a = main_addr;
                        if (main_we_r) begin rd_total <= 4'd1; is_write <= 1'b1; din_r <= main_din; be_r <= main_be; end
                        else           begin rd_total <= 4'd3; is_write <= 1'b0; three = 1'b1; nwords = 4'd3; end
                    end else if (prog_pend) begin
                        grant <= 3'd0; a = prog_addr; rd_total <= 4'd3; is_write <= 1'b0; three = 1'b1; nwords = 4'd3;
                    end else begin
                        // GFX: 6-word column burst = 12 packed pixels per transaction
                        // (2x the old 3-word bandwidth). Reuses the proven single-ACT
                        // column-burst + per-word straddle path.
                        grant <= 3'd1; a = gfx_addr; rd_total <= 4'd6; is_write <= 1'b0; three = 1'b1; nwords = 4'd6;
                    end
                    // A multi-word column window straddles when its first and last
                    // word are in different rows (a[22:10]); then the burst re-ACTs
                    // per word instead of column-incrementing on one open row.
                    a2 = a + {20'd0, (nwords - 4'd1)};
                    read_straddle <= three && (a[22:10] != a2[22:10]);
                    react_cnt <= 3'd0;
                    xfer_addr <= a;
                    cmd <= CMD_ACT; SDRAM_BA <= a[24:23]; SDRAM_A <= a[22:10];
                    rd_issued <= 0; rd_captured <= 0; state <= ST_RCD1;
                end
            end
            ST_RCD1: state <= ST_RCD2;
            ST_RCD2: state <= is_write ? ST_WR : ST_RD;

            ST_WR: begin
                cmd <= CMD_WRITE; SDRAM_BA <= xfer_addr[24:23];
                SDRAM_A <= {2'b00, 1'b1, xfer_addr[10:1]};  // A10 = auto-precharge
                dq_out <= din_r; dq_oe <= 1'b1; dqm <= ~be_r;
                wrrc_cnt <= 3'd4; state <= ST_WRRC;
            end
            ST_WRRC: begin
                if (wrrc_cnt == 3'd4) begin
                    if (grant == 3'd2) begin main_ack <= 1'b1; ackst_main <= ACK_HOLD; end
                    else               begin wr_ack   <= 1'b1; ackst_wr   <= ACK_HOLD; end
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
                    SDRAM_A <= {2'b00, (rd_issued + 1'd1 == rd_total) ? 1'b1 : 1'b0,
                                xfer_addr[10:1]};
                    xfer_addr[10:1] <= xfer_addr[10:1] + 1'd1;
                    if (rd_issued + 1'd1 == rd_total) state <= ST_RDW;  // else stay: next READ
                end else begin
                    SDRAM_A   <= {2'b00, 1'b1, xfer_addr[10:1]};   // A10=1: auto-precharge
                    react_cnt <= 3'd4;                             // tRP/tRC margin
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
            ST_ACT: begin
                cmd <= CMD_ACT; SDRAM_BA <= xfer_addr[24:23]; SDRAM_A <= xfer_addr[22:10];
                state <= ST_RCD1;
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
