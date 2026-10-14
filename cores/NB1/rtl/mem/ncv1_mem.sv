//------------------------------------------------------------------------------
// Pocket memory subsystem for the ND-1 core: the 7.5 MB ROM image in SDRAM
// behind the core's request/ack ports (docs/core-design.md §2).
//
//   image offset   size     SDRAM word address   client
//   0x000000       1 MB     0x000000             68000 program  (random, client 1)
//   0x100000       512 KB   0x080000             H8 program     (random, client 2)
//   0x180000       2 MB     0x0C0000             pattern ROM chip 0  (bursts of 1-64 32-bit units; pattern
//                                                space 0x000000-0x3FFFFF, the chip mirrored twice)
//   0x380000       2 MB     0x1C0000             C352 samples   (random, client 3, one byte used)
//   0x580000       2 MB     0x2C0000             pattern ROM chip 1  (pattern space 0x400000-0x7FFFFF; Vol.1's
//                                                image repeats chip 0 here)
//
// Big-endian words: image byte 2k is the high byte of word k. Client 0 is the
// loader's word writer (busy only while the image downloads).
//------------------------------------------------------------------------------
`default_nettype none

module ncv1_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz phase-shifted for the chip clock pin
    input  logic        init,
    output logic        ready,
    input  logic        rd_late,
    input  logic        burst_slow,

    // ROM image download: a byte at an image offset
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_busy,        // bytes still queued for SDRAM

    // core ports
    input  logic [19:1] prog_addr, input logic prog_req, output logic prog_ack, output logic [15:0] prog_q,
    input  logic [18:1] sub_addr,  input logic sub_req,  output logic sub_ack,  output logic [15:0] sub_q,
    input  logic [20:0] pat_addr,  input logic pat_req,  output logic pat_ack,  output logic [31:0] pat_q,
    input  logic  [6:0] pat_len,   output logic pat_wr,  output logic  [5:0] pat_idx,
    input  logic [23:0] pcm_addr,  input logic pcm_req,  output logic pcm_ack,  output logic  [7:0] pcm_q,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic  [1:0] dram_dqm,
    output logic        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n
);
    localparam [24:1] SD_PROG = 24'h000000, SD_SUB = 24'h080000, SD_PAT = 24'h0C0000, SD_PCM = 24'h1C0000, SD_PAT1 = 24'h2C0000;

    // ------------------------------------------------------------ download: pair bytes into words
    // The loader delivers at most a byte per 8 clocks; consecutive even/odd bytes
    // become one word write. A lone even byte waits for its partner and is
    // flushed alone after 255 clocks.
    logic        dl_we_d, pend_v;
    logic [24:0] pend_a;
    logic  [7:0] pend_d, pend_age;
    wire         nb = dl_we && !dl_we_d;
    logic        wf_push;
    logic [41:0] wf_in;                                 // {word addr[24:1], be[1:0], data[15:0]}
    always_comb begin
        wf_push = 1'b0; wf_in = '0;
        if (nb && pend_v && dl_addr == {pend_a[24:1], 1'b1}) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], 2'b11, pend_d, dl_data};
        end else if (pend_v && (nb || pend_age == 8'hff)) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], pend_a[0] ? 2'b01 : 2'b10, pend_d, pend_d};
        end
    end
    (* ramstyle = "no_rw_check" *) logic [41:0] wfifo [64];
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    logic [41:0] wf_head;
    always_ff @(posedge clk) begin
        if (init) begin dl_we_d <= 1'b0; pend_v <= 1'b0; pend_a <= '0; pend_d <= '0; pend_age <= '0; wf_wp <= '0; end
        else begin
            dl_we_d <= dl_we;
            if (wf_push) begin wfifo[wf_wp[5:0]] <= wf_in; wf_wp <= wf_wp + 7'd1; end
            if (nb) begin
                if (pend_v && dl_addr == {pend_a[24:1], 1'b1}) pend_v <= 1'b0;
                else begin pend_v <= 1'b1; pend_a <= dl_addr; pend_d <= dl_data; pend_age <= 8'd0; end
            end else if (pend_v) begin
                if (pend_age == 8'hff) pend_v <= 1'b0; else pend_age <= pend_age + 8'd1;
            end
        end
    end
    always_ff @(posedge clk) wf_head <= wfifo[wf_rp[5:0]];
    assign dl_busy = pend_v | ~wf_empty;

    // ------------------------------------------------------------ SDRAM clients
    localparam NCLI = 4;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] sd_rdata;

    // client 0: loader writes from the FIFO head (one at a time; the head is registered a clock late)
    typedef enum logic [1:0] {W_IDLE, W_HEAD, W_REQ} wst_t;
    wst_t wst;
    always_ff @(posedge clk) begin
        if (init) begin wst <= W_IDLE; c_req[0] <= 1'b0; wf_rp <= '0; c_addr[0] <= '0; c_wdata[0] <= '0; c_be[0] <= '0; end
        else case (wst)
            W_IDLE: if (!wf_empty) wst <= W_HEAD;                   // wf_head valid next clock
            W_HEAD: begin c_addr[0] <= wf_head[41:18]; c_be[0] <= wf_head[17:16]; c_wdata[0] <= wf_head[15:0]; c_req[0] <= 1'b1; wst <= W_REQ; end
            W_REQ:  if (c_ack[0]) begin c_req[0] <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
            default: wst <= W_IDLE;
        endcase
    end
    assign c_we[0] = 1'b1;

    // clients 1-3: pass-through reads; the ack carries the shared read data
    assign c_addr[1] = SD_PROG + {5'd0, prog_addr};  assign c_req[1] = prog_req; assign prog_ack = c_ack[1]; assign prog_q = sd_rdata;
    assign c_addr[2] = SD_SUB  + {6'd0, sub_addr};   assign c_req[2] = sub_req;  assign sub_ack  = c_ack[2]; assign sub_q  = sd_rdata;
    assign c_addr[3] = SD_PCM  + {4'd0, pcm_addr[20:1]}; assign c_req[3] = pcm_req; assign pcm_ack = c_ack[3];
    assign pcm_q = pcm_addr[0] ? sd_rdata[7:0] : sd_rdata[15:8];
    genvar gi;
    generate for (gi = 1; gi < NCLI; gi++) begin : g_ro
        assign c_we[gi] = 1'b0; assign c_wdata[gi] = '0; assign c_be[gi] = 2'b00;
    end endgenerate

    // burst client: the pattern ROM, pat_len 32-bit units (two SDRAM words each) per request;
    // each unit goes out with pat_wr as its second word arrives, pat_ack after b_done.
    // A burst past the end of a 2 MB chip reads on into the next region instead of
    // wrapping (tiles within their size of the end of the chip only).
    logic [24:1] b_addr; logic [9:0] b_idx; logic b_req, b_wr, b_done, b_abort; logic [15:0] b_data; logic [9:0] b_widx;
    logic [15:0] bw0;
    logic  [9:0] b_len_r;
    typedef enum logic [1:0] {B_IDLE, B_RUN, B_ACK} bst_t;
    bst_t bst;
    always_ff @(posedge clk) begin
        if (init) begin
            bst <= B_IDLE; b_req <= 1'b0; pat_ack <= 1'b0; pat_wr <= 1'b0; pat_idx <= 6'd0; pat_q <= 32'd0;
            b_addr <= '0; bw0 <= '0; b_len_r <= 10'd2;
        end else begin
            pat_ack <= 1'b0; pat_wr <= 1'b0;
            case (bst)
            B_IDLE: if (pat_req && !pat_ack) begin
                b_addr <= (pat_addr[20] ? SD_PAT1 : SD_PAT) + {4'd0, pat_addr[18:0], 1'b0};   // chip pat_addr[20], each 2 MB mirrored across its 4 MB
                b_len_r <= {2'b00, pat_len, 1'b0};
                b_req <= 1'b1; bst <= B_RUN;
            end
            B_RUN: begin
                if (b_wr) begin
                    if (!b_idx[0]) bw0 <= b_data;
                    else begin pat_q <= {bw0, b_data}; pat_idx <= b_idx[6:1]; pat_wr <= 1'b1; end
                end
                if (b_done) begin b_req <= 1'b0; bst <= B_ACK; end
            end
            B_ACK: begin pat_ack <= 1'b1; bst <= B_IDLE; end
            default: bst <= B_IDLE;
            endcase
        end
    end
    assign b_abort = 1'b0;

    logic dram_cs_n_unused;
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(dram_cs_n_unused), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len_r), .b_req(b_req), .b_abort(b_abort), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx(b_widx)
    );
    wire _unused = &{1'b0, dram_cs_n_unused, b_widx, b_idx[9:7], pat_addr[19], pcm_addr[23:21], wf_head[41:18]};
endmodule
