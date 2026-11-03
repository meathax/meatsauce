// -----------------------------------------------------------------------------
// sdram.sv  -- Exterminator SDRAM controller (single generic client port)
//
// Derived from the NARC/Smash TV controller (which derives from the proven Sega
// System 32 MiSTer controller): init/refresh/command engine, CL2 timing, the
// centred DQ-capture pipeline and the open-page row policy are kept. The five
// NARC clients (prog/gfx/main/wr/snd) are replaced by ONE client port with
// word address, 1..4 word read burst and single-word byte-masked writes; the
// arbiter in exterm_sdram_arb.sv multiplexes the two GSPs and the ROM loader.
//
// Clocking: `clk` is the SDRAM clock (clk_ram = 80 MHz = 4 x clk_sys, phase
// aligned). The client (clk_sys side) holds sd_req until it sees sd_ack, then
// drops it and must wait for sd_ack to fall before issuing the next request.
// sd_ack is held ACK_HOLD clk_ram cycles (8 = two clk_sys periods) so clk_sys
// can never miss it (the NARC 4:1 CDC contract).
//
// Word address map is chosen by the client; bank = sd_addr[23:22] (open-page
// policy keeps one row open per bank):
//   bank 0  0x000000..0x0FFFFF  EPROM 2 MB (read after download)
//   bank 1  0x400000..0x43FFFF  master DRAM 512 KB
//   bank 2  0x800000..0x87FFFF  slave DRAM 1 MB
// -----------------------------------------------------------------------------

`default_nettype none
// Donor style: power-up initial values on cmd/init_cnt/state are intentional.
/* verilator lint_off PROCASSINIT */
module sdram #(
    // Column-address width of the fitted SDRAM part (9 = 512-column module).
    parameter int COLBITS = 9,
    // Refresh interval in clk cycles (8192 rows / 64 ms = 7.8 us -> 625 @ 80 MHz).
    parameter int REF_INTERVAL = 560
) (
    input wire        clk,          // SDRAM clock (80 MHz)
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
    // SDRAM_CLK is driven at the top level by a dedicated 180deg PLL output.

    // Generic client port (clk_sys side; see exterm_sdram_arb.sv)
    input wire        sd_req,
    input wire        sd_we,
    input wire [23:0] sd_addr,       // 16-bit word address
    input wire [15:0] sd_din,
    input wire  [1:0] sd_be,
    input wire  [2:0] sd_burst,      // read burst length 1..4 (0 treated as 1)
    output reg [63:0] sd_dout,       // {w3,w2,w1,w0}
    output reg        sd_ack
);

    reg [15:0] dq_out; reg dq_oe; reg [1:0] dqm;
    assign SDRAM_CKE  = 1'b1;
    assign SDRAM_DQML = dqm[0];
    assign SDRAM_DQMH = dqm[1];
    assign SDRAM_DQ   = dq_oe ? dq_out : 16'hZZZZ;

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

    reg [3:0]  rd_total, rd_issued, rd_captured;
    reg [24:1] xfer_addr; reg is_write;
    reg [15:0] din_r; reg [1:0] be_r;
    reg [2:0]  wrrc_cnt, refw_cnt, react_cnt;
    reg        read_straddle;   // window crosses a row boundary
    reg [2:0]  prew_cnt;        // tRP wait after a single-bank PRECHARGE

    // OPEN-PAGE row tracking, one entry per bank.
    reg        row_open [0:3];
    reg [12:0] row_addr [0:3];

    // Ack is held for ACK_HOLD clk cycles (clk_sys = clk/4: 8 cycles = 2 clk_sys).
    localparam [3:0] ACK_HOLD = 4'd8;
    reg [3:0]  ah;

    // Request latch. pend arms on req but NOT while ack is still asserted (the
    // client withdraws req on ack; this guards a still-high req).
    reg pend, we_r;
    reg [24:1] addr_r; reg [2:0] burst_r; reg [15:0] wdat_r; reg [1:0] wbe_r;
    always @(posedge clk) begin
        if (sd_req && !sd_ack && !pend) begin
            pend    <= 1'b1;
            we_r    <= sd_we;
            addr_r  <= sd_addr;
            burst_r <= sd_burst;
            wdat_r  <= sd_din;
            wbe_r   <= sd_be;
        end
        if (init) pend <= 1'b0;
        if (sd_ack) pend <= 1'b0;
    end

    // CL2 starts driving after the first chip edge following READ (valid by
    // the second), not after the second edge. dq_in samples that word at E3;
    // cl_pipe[3] consumes the registered sample at E4. BL1 has already released
    // DQ by the E4 sample, so selecting cl_pipe[4] consumes an invalid bus value.
    reg [15:0] dq_in; reg [3:0] cl_pipe;
    (* ramstyle = "logic" *) reg [15:0] cap_buf [0:3];
    always @(posedge clk) dq_in <= SDRAM_DQ;

    function automatic [63:0] build_dout(input [3:0] total, input [15:0] last);
        reg [63:0] r;
        begin
            r = {cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]};
            case (total)
                4'd1: r[15:0]  = last;
                4'd2: r[31:16] = last;
                4'd3: r[47:32] = last;
                default: r[63:48] = last;
            endcase
            build_dout = r;
        end
    endfunction

    always @(posedge clk) begin
        cmd   <= CMD_NOP;
        dq_oe <= 1'b0;

        if (ah != 0) ah <= ah - 1'd1; else sd_ack <= 1'b0;

        if (init) begin
            init_cnt <= 16'hffff; ready <= 1'b0; state <= ST_IDLE;
            ref_pend <= 1'b0; ref_cnt <= 10'd0; dqm <= 2'b11;
            cl_pipe <= 4'b0;
            ah <= 0; sd_ack <= 1'b0;
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
            if (ref_cnt == REF_INTERVAL[9:0]) begin ref_cnt <= 0; ref_pend <= 1'b1; end

            cl_pipe <= {cl_pipe[2:0], 1'b0};
            if (cl_pipe[3]) begin
                cap_buf[rd_captured[1:0]] <= dq_in;
                rd_captured <= rd_captured + 1'd1;
                if (rd_captured + 1'd1 == rd_total) begin
                    sd_dout <= build_dout(rd_total, dq_in);
                    sd_ack  <= 1'b1; ah <= ACK_HOLD;
                end
            end

            case (state)
            ST_IDLE: begin
                if (ref_pend && cl_pipe == 0) begin
                    cmd <= CMD_PRE; SDRAM_A[10] <= 1'b1;   // precharge ALL banks
                    for (int b = 0; b < 4; b++) row_open[b] <= 1'b0;
                    refw_cnt <= 3'd1; state <= ST_PRE_REF;
                end
                else if (pend && !sd_ack) begin
                    logic [24:1] a2; logic [3:0] nwords;
                    nwords = we_r ? 4'd1 : ((burst_r == 3'd0) ? 4'd1 : {1'b0, burst_r});
                    if (nwords > 4'd4) nwords = 4'd4;
                    a2 = addr_r + {20'd0, (nwords - 4'd1)};
                    din_r <= wdat_r; be_r <= wbe_r;
                    is_write <= we_r;
                    rd_total <= nwords;
                    // A multi-word window straddles when first and last word are
                    // in different rows; the burst then re-ACTs per word.
                    read_straddle <= !we_r && (nwords > 4'd1) &&
                                     (addr_r[22:COLBITS+1] != a2[22:COLBITS+1]);
                    react_cnt <= 3'd0;
                    xfer_addr <= addr_r;
                    rd_issued <= 0; rd_captured <= 0;
                    state <= ST_DEC;   // decide next cycle, off this path
                end
            end
            // Row-hit decision, all inputs clk-registered.
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
                if (wrrc_cnt == 3'd4) begin sd_ack <= 1'b1; ah <= ACK_HOLD; end
                if (wrrc_cnt == 0) state <= ST_IDLE; else wrrc_cnt <= wrrc_cnt - 1'd1;
            end

            // Read issue: single-ACT column burst (back-to-back READs on one open
            // row, incrementing only the column) or, when the window straddles a
            // row boundary, one READ per ACT.
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
                    react_cnt <= 3'd0;
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
            // Straddle re-activate: close the previous row of this bank first.
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
