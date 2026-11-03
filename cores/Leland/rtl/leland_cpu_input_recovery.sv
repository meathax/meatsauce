// SPDX-License-Identifier: GPL-3.0-or-later
// Preserve nominal-clock input history while replaying deferred CPU clocks.
// Uses the existing Jamie Iles GPLv3+ s80x86 FIFO, without changing its RAM.
// This is a same-root transfer, not a synchronizer for asynchronous inputs.
`timescale 1ns/1ps
module leland_cpu_input_recovery #(
    parameter integer INPUT_WIDTH=2,
    parameter integer CREDIT_WIDTH=8,
    parameter integer MIN_GAP=4
)(
    input wire clk,
    input wire reset,
    input wire pause,
    input wire nominal_ce,
    input wire artificial_wait,
    input wire [INPUT_WIDTH-1:0] input_now,
    output wire [INPUT_WIDTH-1:0] input_at_cpu,
    output wire cpu_ce,
    output wire [CREDIT_WIDTH-1:0] pending,
    output wire fault
);
wire overflow,empty,full;
reg queue_fault=0;
assign fault=overflow || queue_fault;
leland_cpu_recovery #(.MIN_GAP(MIN_GAP),.CREDIT_WIDTH(CREDIT_WIDTH)) clock_credit(
    .clk(clk),.reset(reset),.pause(pause || fault),.nominal_ce(nominal_ce),
    .artificial_wait(artificial_wait),.cpu_ce(cpu_ce),.pending(pending),.overflow(overflow));
wire earn=nominal_ce && !pause && !reset && !fault;
wire bypass=(pending==0) && cpu_ce && earn;
// The credit counter faults instead of accepting an over-capacity sample.
wire push=earn && !bypass && (!(&pending) || cpu_ce);
wire pop=cpu_ce && pending!=0;
wire [INPUT_WIDTH-1:0] history;
wire [INPUT_WIDTH-1:0] aligned=(pending==0) ? input_now : history;
assign input_at_cpu = aligned;
Fifo #(.data_width(INPUT_WIDTH),.depth(1<<CREDIT_WIDTH),.full_threshold(2)) history_queue(
    .clk(clk),.reset(1'b0),.flush(reset),.wr_en(push),.wr_data(input_now),
    .rd_en(pop),.rd_data(history),.empty(empty),.nearly_full(),.full(full));
always @(posedge clk) begin
    if(reset)queue_fault<=0;
    else if(full || empty!=(pending==0))queue_fault<=1;
end
endmodule
