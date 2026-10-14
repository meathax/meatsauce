// SPDX-License-Identifier: GPL-2.0-or-later
// Diagnostic fixture for the pristine donor's phase and interrupt aperture.
// The product CPU and its pins are not changed by this fixture.
module vm80a_phase (
    input wire clk, reset, irq, level_mode,
    input wire [7:0] din,
    output wire [15:0] address,
    output wire [7:0] dout,
    output reg [7:0] status=0,
    output wire inte, sync, dbin, wr_n,
    output wire read_start, write_start, interrupt_ack,
    output wire [4:0] phase_debug,
    output wire [4:0] tstate, mcycle,
    output wire intr_debug, inta_debug, mstart_debug
);
    reg [4:0] phase=0;
    always @(posedge clk) phase<=phase==24?0:phase+1'b1;
    assign phase_debug=phase;
    wire f1=level_mode?(phase<12):(phase==0);
    wire f2=level_mode?(phase>=12):(phase==12);
    wire aena, dena, hlda, waiting;
    vm80a_core cpu (
        .pin_clk(clk),.pin_f1(f1),.pin_f2(f2),.pin_reset(reset),
        .pin_a(address),.pin_dout(dout),.pin_din(din),
        .pin_aena(aena),.pin_dena(dena),.pin_hold(1'b0),
        .pin_hlda(hlda),.pin_ready(1'b1),.pin_wait(waiting),
        .pin_int(irq),.pin_inte(inte),.pin_sync(sync),
        .pin_dbin(dbin),.pin_wr_n(wr_n)
    );
    reg previous_sync=0, previous_dbin=0, previous_wr_n=1;
    assign read_start=dbin&&!previous_dbin;
    assign write_start=!wr_n&&previous_wr_n;
    assign interrupt_ack=sync&&!previous_sync&&dout[0];
    always @(posedge clk) begin
        previous_sync<=sync;previous_dbin<=dbin;previous_wr_n<=wr_n;
        if(sync&&!previous_sync) status<=dout;
        if(reset)status<=0;
    end
    assign tstate={cpu.t5,cpu.t4,cpu.t3,cpu.t2,cpu.t1};
    assign mcycle={cpu.m5,cpu.m4,cpu.m3,cpu.m2,cpu.m1};
    assign intr_debug=cpu.intr;
    assign inta_debug=cpu.inta;
    assign mstart_debug=cpu.mstart;
endmodule
