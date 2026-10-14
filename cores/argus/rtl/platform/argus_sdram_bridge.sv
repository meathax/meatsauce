// SPDX-License-Identifier: GPL-3.0-or-later
// Frequency selects the conservative donor profile and real-time delays.
// Keep CPU/audio below 256 KiB in banks 0/1 and graphics in banks 2/3.
// The private physical mapping is lossless; clients retain byte addresses.
// Aligned 8-byte reads populate a cache, invalidated on writes/storage reset.
module argus_sdram_bridge #(
    parameter int unsigned SYS_HZ = 54_000_000,
    parameter int unsigned REFRESH_PERIOD = int'((64'(SYS_HZ) * 75) / 10_000_000)
)(
    input  logic clk_sys, reset,
    input  logic req, we, read_wide,
    input  logic [23:0] addr,
    input  logic [7:0] wdata,
    output logic ready,
    output logic [7:0] rdata,
    output logic [63:0] rdata64,
    output logic mem_init_ready,
    inout  wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML, SDRAM_DQMH,
    output wire SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE
`ifdef VERILATOR
    , output wire [15:0] sim_sdram_dout
`endif
);
    typedef enum logic [2:0] {IDLE, WRITE_START, WRITE_WAIT, READ_WAIT, RETURN_DATA} state_t;
    state_t state;
    logic init, prog_en, prog_wr, prog_ack, prog_rdy;
    logic [3:0] rd, ack, dok, rdy;
    logic [15:0] dout, prog_din;
    logic [21:0] bank_addr, prog_addr;
    logic [1:0] bank_id, prog_dsn;
    logic [2:0] byte_sel;
    logic [1:0] word_count;
    logic [63:0] cache_data;
    logic [20:0] cache_tag, pending_tag;
    logic cache_valid, request_acked;
    logic [$clog2(REFRESH_PERIOD)-1:0] refresh_count;
    logic rfsh;
    logic [63:0] completed_burst;
    wire [3:0] controller_command;
    wire [1:0] physical_bank = {(|addr[23:18]), addr[17]};
    wire [21:0] physical_word = {addr[23:18], addr[16:1]};
    logic command_live;
    // The donor command flop has no reset priority and can capture an old,
    // uninitialized mux value on the first reset edge. Inhibit physical
    // commands immediately while reset is asserted, then wait for the first
    // registered initialization command after release. CKE stays high so the
    // donor's full 200us wait and subsequent initialization remain clocked.
    always_ff @(posedge clk_sys) command_live <= !reset;
    assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} =
        reset || !command_live ? 4'b1111 : controller_command;
    // One LF cycle is insufficient for tRCD/tRP20ns above 50MHz.
    localparam int HF_PROFILE = SYS_HZ > 50_000_000 ? 1 : 0;
    localparam int INIT_CYCLES = (SYS_HZ + 4_999) / 5_000 + 16;
    always_comb begin
        completed_burst = cache_data;
        if (dok[bank_id]) completed_burst[{word_count,4'b0000} +: 16] = dout;
    end

    assign mem_init_ready = !init && !reset;
    assign prog_en = state == WRITE_START || state == WRITE_WAIT;
    // Give the controller's negedge mode reset a full edge before requesting.
    assign prog_wr = state == WRITE_WAIT && !request_acked && !prog_ack;
    assign rd = state == READ_WAIT && !request_acked && !ack[bank_id] ? (4'b0001 << bank_id) : 4'b0000;

    always_ff @(posedge clk_sys) begin
        rfsh <= 1'b0;
        if (reset || init) refresh_count <= '0;
        else if (refresh_count == $clog2(REFRESH_PERIOD)'(REFRESH_PERIOD-1)) begin
            refresh_count <= '0;
            rfsh <= 1'b1;
        end else refresh_count <= refresh_count + 1'b1;
    end

    always_ff @(posedge clk_sys) begin
        ready <= 1'b0;
        if (reset || init) begin
            state <= IDLE;
            rdata <= 8'hff;
            rdata64 <= 64'hffffffffffffffff;
            bank_addr <= 22'd0;
            prog_addr <= 22'd0;
            bank_id <= 2'd0;
            prog_din <= 16'd0;
            prog_dsn <= 2'b11;
            byte_sel <= 3'd0;
            word_count <= 2'd0;
            cache_data <= 64'd0;
            cache_tag <= 21'd0;
            pending_tag <= 21'd0;
            cache_valid <= 1'b0;
            request_acked <= 1'b0;
        end else case (state)
            IDLE: if (req) begin
                request_acked <= 1'b0;
                byte_sel <= addr[2:0];
                if (!we && read_wide && addr[2:0] != 3'd0) begin
                    rdata <= 8'hff;
                    rdata64 <= 64'hffffffffffffffff;
                    ready <= 1'b1;
                    state <= RETURN_DATA;
                end else if (we) begin
                    bank_id <= physical_bank;
                    prog_addr <= physical_word;
                    prog_din <= {wdata, wdata};
                    prog_dsn <= addr[0] ? 2'b01 : 2'b10;
                    cache_valid <= 1'b0;
                    state <= WRITE_START;
                end else if (cache_valid && cache_tag == addr[23:3]) begin
                    rdata <= cache_data[{addr[2:0], 3'b000} +: 8];
                    rdata64 <= cache_data;
                    ready <= 1'b1;
                    state <= RETURN_DATA;
                end else begin
                    bank_id <= physical_bank;
                    bank_addr <= {physical_word[21:2], 2'b00};
                    pending_tag <= addr[23:3];
                    word_count <= 2'd0;
                    state <= READ_WAIT;
                end
            end
            WRITE_START: state <= WRITE_WAIT;
            WRITE_WAIT: begin
                if (prog_ack) request_acked <= 1'b1;
                if (prog_rdy) begin
                    ready <= 1'b1;
                    state <= RETURN_DATA;
                end
            end
            READ_WAIT: begin
                if (ack[bank_id]) request_acked <= 1'b1;
                if (dok[bank_id]) begin
                    cache_data[{word_count, 4'b0000} +: 16] <= dout;
                    word_count <= word_count + 2'd1;
                end
                if (rdy[bank_id]) begin
                    cache_tag <= pending_tag;
                    cache_valid <= 1'b1;
                    rdata <= byte_sel[2:1] == word_count ?
                        (byte_sel[0] ? dout[15:8] : dout[7:0]) :
                        cache_data[{byte_sel, 3'b000} +: 8];
                    rdata64 <= completed_burst;
                    ready <= 1'b1;
                    state <= RETURN_DATA;
                end
            end
            RETURN_DATA: state <= IDLE;
            default: state <= IDLE;
        endcase
    end

    // A17 chooses the bank within each pair. Removing it from the word address
    // retains every logical bit; graphics use the upper pair of the 32 MiB
    // module so CPU/audio cannot replace their open rows. Burst lanes stay
    // contiguous and the cache tags remain logical byte addresses.
    jtframe_sdram64 #(
        .HF(HF_PROFILE), .INIT_CYCLES(14'(INIT_CYCLES)), .SHIFTED(0), .CAPTURE_NEGEDGE(1),
        .MISTER(1), .RFSHCNT(1), .BAPRIO(1),
        .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64), .PROG_LEN(16),
        .BA0_WEN(0), .BA1_WEN(0), .BA2_WEN(0), .BA3_WEN(0)
    ) controller (
        .rst(reset), .clk(clk_sys), .init(init),
        .ba0_addr(bank_addr), .ba1_addr(bank_addr), .ba2_addr(bank_addr), .ba3_addr(bank_addr),
        .rd(rd), .wr(4'd0), .ba0_din(16'd0), .ba1_din(16'd0), .ba2_din(16'd0), .ba3_din(16'd0),
        .ba0_dsn(2'b11), .ba1_dsn(2'b11), .ba2_dsn(2'b11), .ba3_dsn(2'b11),
        .prog_en(prog_en), .prog_addr(prog_addr), .prog_rd(1'b0), .prog_wr(prog_wr),
        .prog_din(prog_din), .prog_dsn(prog_dsn), .prog_ba(bank_id),
        .prog_dst(), .prog_dok(), .prog_rdy(prog_rdy), .prog_ack(prog_ack),
        .rfsh(rfsh), .ack(ack), .dst(), .dok(dok), .rdy(rdy), .dout(dout),
        .sdram_dq(SDRAM_DQ), .sdram_a(SDRAM_A), .sdram_ba(SDRAM_BA),
        .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
        .sdram_nwe(controller_command[0]), .sdram_ncas(controller_command[1]), .sdram_nras(controller_command[2]),
        .sdram_ncs(controller_command[3]), .sdram_cke(SDRAM_CKE)
`ifdef VERILATOR
        , .sdram_din(sim_sdram_dout)
`endif
    );
endmodule
