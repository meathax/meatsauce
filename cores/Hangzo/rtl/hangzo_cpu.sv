// SPDX-License-Identifier: GPL-3.0-or-later
// Hangzo bus adapter around the unmodified FX68K execution/microcode donor.
`timescale 1ns/1ns
module hangzo_cpu (
    input wire clk, reset, pause,
    input wire irq6,
    output wire request,
    output wire [23:0] address,
    output wire write,
    output wire [1:0] byte_enable,
    output wire [15:0] write_data,
    input wire acknowledge,
    input wire [15:0] read_data,
    output wire [2:0] function_code,
    output wire phase1, phase2,
    output wire halted, pause_ack
`ifdef VERILATOR
    ,output wire [11:0] debug_credit,
    output wire [63:0] debug_ticks, debug_pairs, debug_dropped
`endif
);
    wire as_n, uds_n, lds_n, rw_n;
    wire [23:1] word_address;
    wire active = !as_n && !(uds_n && lds_n) && function_code != 3'd7;
    reg completed;
    reg [15:0] reply;
    wire [11:0] credit;
    hangzo_cpu_ce u_ce (
        .clk(clk), .reset(reset), .pause(pause),
        .block_phi2(active && !completed), .phi1(phase1), .phi2(phase2),
        .credit(credit)
`ifdef VERILATOR
        ,.debug_ticks(debug_ticks), .debug_pairs(debug_pairs), .debug_dropped(debug_dropped)
`endif
    );
`ifdef VERILATOR
    assign debug_credit = credit;
`endif
    // Complete exactly one transport request per bus cycle. Registered reply
    // precedes DTACK; the CPU sees coherent data even with back-to-back reads.
    always @(posedge clk) begin
        if (reset || !active) completed <= 0;
        else if (request && acknowledge) begin
            reply <= read_data;
            completed <= 1;
        end
    end
    assign request = active && !completed && !reset;
    // Pausing inhibits both CPU phases immediately, while transport completion
    // continues above. Grant the independent RAM port only after the last
    // reply has been captured and two quiet root edges have elapsed. AS may
    // remain asserted on a completed frozen cycle; halted is unrelated.
    reg [1:0] pause_quiet;
    always @(posedge clk) begin
        if(reset || !pause || request) pause_quiet<=0;
        else pause_quiet<={pause_quiet[0],1'b1};
    end
    assign pause_ack = pause && !reset && !request && pause_quiet[1];
    assign address = {word_address, 1'b0};
    assign write = !rw_n;
    assign byte_enable = {~uds_n, ~lds_n};
    wire vpa_n = !(!as_n && function_code == 3'd7);
    wire [2:0] ipl_n = irq6 ? 3'b001 : 3'b111;
    wire halted_n;
    assign halted = !halted_n;
    fx68k u_cpu (
        .clk(clk), .extReset(reset), .pwrUp(reset),
        .enPhi1(phase1), .enPhi2(phase2), .HALTn(1'b1),
        .ASn(as_n), .UDSn(uds_n), .LDSn(lds_n), .eRWn(rw_n),
        .eab(word_address), .iEdb(reply), .oEdb(write_data),
        .FC0(function_code[0]), .FC1(function_code[1]), .FC2(function_code[2]),
        .DTACKn(!completed), .VPAn(vpa_n), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1), .IPL0n(ipl_n[0]),
        .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
        .E(), .VMAn(), .BGn(), .oRESETn(), .oHALTEDn(halted_n)
    );
endmodule
