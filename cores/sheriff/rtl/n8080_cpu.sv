// SPDX-License-Identifier: GPL-2.0-or-later
// Nintendo 8080 bus adapter. vm80a retains its own CC-BY-3.0 notice.
module n8080_cpu_ready (
    input wire clk, reset, pause, ready,
    input wire [7:0] din,
    input wire irq,
    output wire [15:0] address,
    output wire [7:0] dout,
    output reg [7:0] status = 0,
    output wire inte, sync, dbin, wr_n,
    output wire read_start, write_start, interrupt_ack,
    output wire wait_debug,
    output wire [4:0] phase_debug
);
    // Keep phases running while reset is asserted: the donor samples reset
    // through both phase gates. Reset must span at least three T states.
    reg [4:0] phase = 0;
    always @(posedge clk) if (!pause) phase <= phase == 24 ? 0 : phase + 1'b1;
    assign phase_debug = phase;
    // Related Bandido 2A/3A/3B/5A network: phi1 occupies crystal intervals
    // 0..1, phi2 3..7, with gaps. Keep level enables, not one-clock strobes.
    // At 50.4 MHz the ideal phi2 rise is phase 7.5; sampling at phase 8
    // rounds it 9.920635 ns late. No PLL or raster/IRQ offset is changed.
    // Primary derivation/remaining physical limits: sheriff_clock_network.json.
    wire f1 = phase < 5;
    wire f2 = phase >= 8 && phase < 20;
    wire aena, dena, hlda, waiting;
    assign wait_debug = waiting;
    // Phase gates alone do not freeze the donor's DBIN/extended-data latches.
    // The generated adaptation enables every sequential block together.
    vm80a_core_ce cpu (
        .pin_clk(clk), .pin_ce(!pause), .pin_f1(f1), .pin_f2(f2), .pin_reset(reset),
        .pin_a(address), .pin_dout(dout), .pin_din(din),
        .pin_aena(aena), .pin_dena(dena), .pin_hold(1'b0),
        .pin_hlda(hlda), .pin_ready(ready), .pin_wait(waiting),
        .pin_int(irq), .pin_inte(inte), .pin_sync(sync),
        .pin_dbin(dbin), .pin_wr_n(wr_n)
    );
    reg previous_sync = 0, previous_dbin = 0, previous_wr_n = 1;
    assign read_start = dbin && !previous_dbin;
    assign write_start = !wr_n && previous_wr_n;
    assign interrupt_ack = sync && !previous_sync && dout[0];
    always @(posedge clk) if (!pause) begin
        previous_sync <= sync;
        previous_dbin <= dbin;
        previous_wr_n <= wr_n;
        if (sync && !previous_sync) status <= dout;
        if (reset) status <= 0;
    end
endmodule

// Compatibility interface for the currently qualified logical-memory board.
// Physical memory integration must use n8080_cpu_ready and a qualified READY net.
module n8080_cpu (
    input wire clk, reset, pause,
    input wire [7:0] din,
    input wire irq,
    output wire [15:0] address,
    output wire [7:0] dout, status,
    output wire inte, sync, dbin, wr_n,
    output wire read_start, write_start, interrupt_ack,
    output wire [4:0] phase_debug
);
    n8080_cpu_ready cpu (
        .clk(clk), .reset(reset), .pause(pause), .ready(1'b1), .din(din),
        .irq(irq), .address(address), .dout(dout), .status(status),
        .inte(inte), .sync(sync), .dbin(dbin), .wr_n(wr_n),
        .read_start(read_start), .write_start(write_start),
        .interrupt_ack(interrupt_ack), .phase_debug(phase_debug), .wait_debug()
    );
endmodule
