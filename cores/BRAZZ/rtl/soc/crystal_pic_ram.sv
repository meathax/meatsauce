// PIC program/EEPROM block RAMs for rtl/soc/crystal_pic16.sv, copied unchanged from
// BrezzaSoft_Crystal_System_MiSTer rtl/memory/crystal_ram.sv (Kyle Lester, GPL-3.0-or-later).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later

// Simple dual port: one write port, one registered read port. Read-during-write to the same address returns
// the old data (the users never depend on it).
module crystal_sdpram #(
    parameter integer AW = 9,
    parameter integer DW = 16
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
    (* ramstyle = "no_rw_check, M10K" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// True dual port: two independent read/write ports (registered reads).
module crystal_tdpram #(
    parameter integer AW = 14,
    parameter integer DW = 8
) (
    input  wire          clk,
    input  wire          a_we,
    input  wire [AW-1:0] a_addr,
    input  wire [DW-1:0] a_wdata,
    output reg  [DW-1:0] a_rdata,
    input  wire          b_we,
    input  wire [AW-1:0] b_addr,
    input  wire [DW-1:0] b_wdata,
    output reg  [DW-1:0] b_rdata
);
    (* ramstyle = "no_rw_check, M10K" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_rdata <= mem[a_addr];
    end
    always @(posedge clk) begin
        if (b_we) mem[b_addr] <= b_wdata;
        b_rdata <= mem[b_addr];
    end
endmodule
