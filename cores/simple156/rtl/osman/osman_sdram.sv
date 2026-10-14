// SPDX-License-Identifier: GPL-3.0-or-later
// One outstanding access over the actual JTFRAME SDRAM controller.
// Reads return a 64-bit group (four words, 8-byte aligned): rdata64 holds the
// whole group and rdata the word the request addressed. Writes stay single
// words. GROUP_BURST=1 fetches the group as one 4-word burst (mode register
// BL4, single-location writes); GROUP_BURST=0 fetches it as four sequential
// single-word reads (BL1), the access pattern of the hardware-proven builds.
module osman_sdram #(
    parameter integer HF = 0,
    parameter integer SHIFTED = 0,
    parameter integer EARLY_ISSUE = 0,
    parameter integer GROUP_BURST = 1,
    // Read every write back and rewrite it until it reads back intact.
    // Hardware lost random bits in ROM-image writes (persisting for the whole
    // session: tile pixels missing from every copy of a tile, a stray sprite
    // strip); reads proved reliable. Writes only occur during the image load.
    parameter integer VERIFY_WRITES = 0,
    parameter integer VERIFY_RETRIES = 7
)(
    input wire clk, reset, refresh,
    input wire req, we,
    input wire [24:0] byte_addr,
    input wire [15:0] wdata,
    input wire [1:0] be,
    output wire ready,
    output wire [15:0] rdata,
    output reg [63:0] rdata64,
    output wire initialized,
    // Writes that read back wrong at least once, and writes still wrong after
    // VERIFY_RETRIES rewrites (sticky until reset).
    output reg [15:0] verify_mismatches,
    output reg verify_failed,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml, sdram_dqmh,
    output wire sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke
);
    localparam [2:0] IDLE=0, ACCESS=1, WAIT_DATA=2, RESPONSE=3, GAP=4, CHECK=5;
    reg [2:0] state;
    reg [1:0] bank;
    // verifying: the ACCESS/WAIT_DATA pass is the read-back of the held write.
    reg verifying, rewritten;
    reg [2:0] retries;
    reg [1:0] word;   // GROUP_BURST=0: group word being read
    reg [24:0] held_addr;
    reg held_we;
    reg [15:0] held_data;
    reg [1:0] held_be;
    wire init;
    wire [3:0] ack, dst, dok, done;
    wire [15:0] dout;
    wire same_request = req && byte_addr == held_addr && we == held_we
        && be == held_be && (!we || wdata == held_data);
    // Optional IDLE request forwarding. Capture the same descriptor at this
    // edge; keep the existing ack withdrawal and RESPONSE hold contract.
    wire early_issue = (EARLY_ISSUE != 0) && state == IDLE && req && !init && !reset;
    wire [24:0] issue_addr = early_issue ? byte_addr : held_addr;
    wire [1:0] issue_bank = early_issue ? byte_addr[24:23] : bank;
    wire issue_we = early_issue ? we : held_we && !verifying;
    wire [15:0] issue_data = early_issue ? wdata : held_data;
    wire [1:0] issue_be = early_issue ? be : held_be;
    wire [3:0] request_bank = (state == ACCESS || early_issue) ? (4'b0001 << issue_bank) : 4'd0;
    // Reads start at the 8-byte aligned column so the sequential burst
    // delivers words 0..3 in address order. Writes use the exact word.
    // Without bursts each group word is its own read (word counts 0..3; an
    // early-issued request is always word 0), and a verify read-back reads
    // only the written word.
    wire single_reads = GROUP_BURST == 0;
    wire [21:0] issue_word = issue_we ? issue_addr[22:1] :
                             !single_reads ? {issue_addr[22:3], 2'b00} :
                             verifying ? held_addr[22:1] :
                             {issue_addr[22:3], early_issue ? 2'b00 : word};
    // More group words to read after the one completing now.
    wire more_words = single_reads && !held_we && word != 2'd3;
    assign initialized = !init && !reset;
    assign ready = state == RESPONSE && same_request && !verify_failed;
    assign rdata = held_addr[2:1] == 2'd0 ? rdata64[15:0] :
                   held_addr[2:1] == 2'd1 ? rdata64[31:16] :
                   held_addr[2:1] == 2'd2 ? rdata64[47:32] : rdata64[63:48];
    // A completed write goes on to its read-back; a completed read-back is checked.
    wire [2:0] closing_state = more_words ? GAP :
                               VERIFY_WRITES == 0 || !held_we ? RESPONSE : verifying ? CHECK : GAP;
    // A single-word read-back is the last word shifted in.
    wire [15:0] readback = single_reads ? rdata64[63:48] : rdata;
    wire readback_ok = (!held_be[0] || readback[7:0] == held_data[7:0]) &&
                       (!held_be[1] || readback[15:8] == held_data[15:8]);
    always @(posedge clk) begin
        if (reset || init) begin
            state <= IDLE; bank <= 0; held_addr <= 0;
            held_we <= 0; held_data <= 0; held_be <= 0; rdata64 <= 0;
            verifying <= 0; rewritten <= 0; retries <= 0; word <= 0;
            if (reset) begin verify_mismatches <= 0; verify_failed <= 0; end
        end else begin
            // JTFRAME aligns dout with dok, one word per clock for four
            // clocks; rdy closes the access on the last word's clock.
            // Shift so burst word 0 ends in bits 15:0.
            if ((state == ACCESS || state == WAIT_DATA) && dok[bank] && (!held_we || verifying))
                rdata64 <= {dout, rdata64[63:16]};
            case (state)
                IDLE: if (req) begin
                    bank <= byte_addr[24:23]; held_addr <= byte_addr;
                    held_we <= we; held_data <= wdata; held_be <= be;
                    verifying <= 0; rewritten <= 0; retries <= 0; word <= 0;
                    state <= ACCESS;
                end
                ACCESS: begin
                    // ack consumes the request before data completion. Holding
                    // rd/wr through rdy can enqueue the same operation twice.
                    if (done[bank]) begin
                        state <= closing_state;
                        if (more_words) word <= word + 1'b1;
                        else if (closing_state == GAP) verifying <= 1;
                    end else if (ack[bank]) state <= WAIT_DATA;
                end
                WAIT_DATA: if (done[bank]) begin
                    state <= closing_state;
                    if (more_words) word <= word + 1'b1;
                    else if (closing_state == GAP) verifying <= 1;
                end
                // One idle clock between back-to-back operations of one request,
                // as RESPONSE/IDLE provide between requests.
                GAP: state <= ACCESS;
                // rdy coincides with the last burst word, so the group is complete here.
                CHECK: begin
                    if (readback_ok) begin
                        verifying <= 0; state <= RESPONSE;
                    end else begin
                        if (!rewritten) verify_mismatches <= verify_mismatches + 1'b1;
                        rewritten <= 1;
                        if (retries == 3'(VERIFY_RETRIES)) begin
                            verify_failed <= 1; verifying <= 0; state <= RESPONSE;
                        end else begin
                            retries <= retries + 1'b1; verifying <= 0; state <= GAP;
                        end
                    end
                end
                RESPONSE: if (!same_request) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
    jtframe_sdram64 #(
        .AW(22), .HF(HF), .SHIFTED(SHIFTED), .MISTER(1),
        .BA0_LEN(GROUP_BURST ? 64 : 16), .BA1_LEN(GROUP_BURST ? 64 : 16),
        .BA2_LEN(GROUP_BURST ? 64 : 16), .BA3_LEN(GROUP_BURST ? 64 : 16), .PROG_LEN(16),
        .BA0_WEN(1), .BA1_WEN(1), .BA2_WEN(1), .BA3_WEN(1), .RFSHCNT(9)
    ) u_controller (
        .rst(reset), .clk(clk), .init(init),
        .ba0_addr(issue_word), .ba1_addr(issue_word),
        .ba2_addr(issue_word), .ba3_addr(issue_word),
        .rd(issue_we ? 4'd0 : request_bank), .wr(issue_we ? request_bank : 4'd0),
        .ba0_din(issue_data), .ba1_din(issue_data), .ba2_din(issue_data), .ba3_din(issue_data),
        .ba0_dsn(~issue_be), .ba1_dsn(~issue_be), .ba2_dsn(~issue_be), .ba3_dsn(~issue_be),
        .prog_en(1'b0), .prog_addr(22'd0), .prog_rd(1'b0), .prog_wr(1'b0),
        .prog_din(16'd0), .prog_dsn(2'b11), .prog_ba(2'd0),
        .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
        .rfsh(refresh), .ack(ack), .dst(dst), .dok(dok), .rdy(done), .dout(dout),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dqml(sdram_dqml), .sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe), .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras),
        .sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
    );
endmodule
