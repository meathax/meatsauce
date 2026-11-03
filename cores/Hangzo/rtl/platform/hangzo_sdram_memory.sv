// SPDX-License-Identifier: GPL-3.0-only
// Logical 32MiB JTFRAME memory integration. Clock/phase parameters are explicit
// test/configuration inputs; no electrical timing qualification is implied.
module hangzo_sdram_memory #(
    parameter integer HF_CONFIG=-1,
    parameter integer SHIFTED_CONFIG=-1,
    parameter integer REFRESH_COMMANDS_CONFIG=-1
)(
    input wire clk,controller_reset,programmer_mode,read_invalidate,refresh,
    output wire initialized,
    input wire download_request,
    input wire [23:0] download_storage_word,
    input wire [15:0] download_data,
    output wire download_ack,
    input wire read_request,
    output wire read_accept,
    input wire [25:0] read_byte_address,
    output wire read_response,
    input wire read_response_ready,
    output wire [63:0] read_data,
    output wire read_fault,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    // No donor/default clock profile silently becomes the board profile.
    generate if((HF_CONFIG!=0 && HF_CONFIG!=1) ||
                (SHIFTED_CONFIG!=0 && SHIFTED_CONFIG!=1) || REFRESH_COMMANDS_CONFIG<1)begin: invalid_profile
        hangzo_sdram_memory_requires_explicit_clock_and_refresh_profile configuration_error();
    end endgenerate
    wire initializing;
    wire [3:0] bank_read,bank_ack,bank_dst,bank_rdy;
    wire [21:0] bank_address,programmer_address;
    wire [1:0] programmer_bank;
    wire [15:0] programmer_data,controller_data;
    wire programmer_write,programmer_ack,programmer_rdy;
    // The donor resets ordinary bank FSMs during programming and resets its
    // programmer outside programming, using the opposite edge internally.
    // Bridges quarantine registered stale returns for two post-flush edges.
    wire read_flush=controller_reset || initializing || programmer_mode;
    wire program_flush=controller_reset || initializing || !programmer_mode;
    assign initialized=!controller_reset && !initializing;
    hangzo_sdram_read_bridge reads(
        .clk(clk),.bank_flush(read_flush),.invalidate(read_invalidate),
        .request_valid(read_request),.request_ready(read_accept),
        .request_byte_address(read_byte_address),.response_valid(read_response),
        .response_ready(read_response_ready),.response_data(read_data),
        .bank_read(bank_read),.bank_word_address(bank_address),
        .bank_ack(bank_ack),.bank_dst(bank_dst),.bank_rdy(bank_rdy),
        .bank_data(controller_data),.fault(read_fault));
    hangzo_sdram_write_bridge writes(
        .clk(clk),.programmer_flush(program_flush),.request(download_request),
        .storage_word_address(download_storage_word),.write_data(download_data),
        .acknowledged(download_ack),.programmer_write(programmer_write),
        .programmer_word_address(programmer_address),.programmer_bank(programmer_bank),
        .programmer_data(programmer_data),.programmer_ack(programmer_ack),.programmer_rdy(programmer_rdy));
    jtframe_sdram64 #(.AW(22),.HF(HF_CONFIG),.SHIFTED(SHIFTED_CONFIG),.PAD_DQM(1),
        .BA0_LEN(64),.BA1_LEN(64),.BA2_LEN(64),.BA3_LEN(64),.PROG_LEN(16),
        .BA0_WEN(0),.BA1_WEN(0),.BA2_WEN(0),.BA3_WEN(0),.RFSHCNT(REFRESH_COMMANDS_CONFIG)) controller(
        .rst(controller_reset),.clk(clk),.init(initializing),.dqm_inhibit(controller_reset || initializing),
        .ba0_addr(bank_address),.ba1_addr(bank_address),.ba2_addr(bank_address),.ba3_addr(bank_address),
        .rd(bank_read),.wr(4'd0),
        .ba0_din(16'd0),.ba1_din(16'd0),.ba2_din(16'd0),.ba3_din(16'd0),
        .ba0_dsn(2'b11),.ba1_dsn(2'b11),.ba2_dsn(2'b11),.ba3_dsn(2'b11),
        .prog_en(programmer_mode),.prog_addr(programmer_address),.prog_rd(1'b0),
        .prog_wr(programmer_write),.prog_din(programmer_data),.prog_dsn(2'b00),
        .prog_ba(programmer_bank),.prog_dst(),.prog_dok(),.prog_rdy(programmer_rdy),.prog_ack(programmer_ack),
        .rfsh(refresh),.ack(bank_ack),.dst(bank_dst),.dok(),.rdy(bank_rdy),.dout(controller_data),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),.sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke));
endmodule
