// SPDX-License-Identifier: GPL-3.0-or-later
// SPY uses an ordinary MC6809E, without Konami opcode scrambling.
module spy_cpu #(parameter integer CLOCK_DIVIDER = 16) (
    input logic clk, reset, pause,
    input logic [7:0] din,
    input logic ready, irq_n, firq_n,
    output wire [15:0] addr,
    output wire [7:0] dout,
    output wire rnw,
    output wire transfer, opcode,
    output wire [111:0] registers
);
    localparam integer PHASE_BITS = $clog2(CLOCK_DIVIDER);
    logic [PHASE_BITS-1:0] phase;
    // Memory DI is consumed at E. Keep the intervening E/Q phases at their
    // nominal cadence and stretch E only when its selected byte is still late.
    wire advance = !pause && (phase != 0 || ready);
    wire ce_e = advance && phase == 0;
    wire ce_q = advance && phase == CLOCK_DIVIDER/2;
    // Writes are committed once, at the Q phase, as in the donor wrapper.
    assign transfer = ce_q && !reset;
    always_ff @(posedge clk) begin
        if (reset) phase <= 0;
        else if (advance) phase <= phase + 1'b1;
    end
    mc6809i u_cpu (
        .clk(clk), .cen_E(ce_e), .cen_Q(ce_q), .nRESET(!reset),
        .D(din), .DOut(dout), .ADDR(addr), .RnW(rnw),
        .nIRQ(irq_n), .nFIRQ(firq_n), .nNMI(1'b1),
        .nHALT(1'b1), .nDMABREQ(1'b1), .BS(), .BA(),
        .AVMA(), .BUSY(), .LIC(), .OP(opcode), .RegData(registers)
    );
endmodule

/*
Original MC6809 Standard BSD notice
Applies to rtl/vendor/mc6809/mc6809i.v; this project elects this grant.

Copyright (c) 2016, Greg Miller
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
        * Redistributions of source code must retain the above copyright
          notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above copyright
          notice, this list of conditions and the following disclaimer in the
          documentation and/or other materials provided with the distribution.
        * The name of the author may not be used to endorse or promote products
          derived from this software without specific prior written permission.
    
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
    WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL GREG MILLER BE LIABLE FOR ANY
    DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
    (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
    ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
