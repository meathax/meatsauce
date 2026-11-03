// SPDX-License-Identifier: GPL-3.0-or-later
// SPY's default MAME watchdog: first write arms a three-second timer.
// The timer measures unpaused 48 MHz master clocks, independently of CPU ready.
module spy_watchdog #(
    parameter integer TIMEOUT_CYCLES = 144000000,
    parameter integer RESET_PULSE_CYCLES = 64
)(
    input logic clk, reset, pause, kick,
    output logic expired,
    output wire debug_armed,
    output wire [31:0] debug_count
);
    localparam integer CW = TIMEOUT_CYCLES > 1 ? $clog2(TIMEOUT_CYCLES) : 1;
    localparam integer PW = RESET_PULSE_CYCLES > 1 ? $clog2(RESET_PULSE_CYCLES) : 1;
    localparam logic [CW-1:0] LAST_COUNT = CW'(TIMEOUT_CYCLES-1);
    localparam logic [PW-1:0] PULSE_LAST = PW'(RESET_PULSE_CYCLES-1);
    logic [CW-1:0] count;
    logic [PW-1:0] pulse_left;
    logic armed;
    assign debug_armed = armed;
    assign debug_count = {{(32-CW){1'b0}},count};
`ifndef SYNTHESIS
    initial begin
        if (TIMEOUT_CYCLES < 1 || RESET_PULSE_CYCLES < 1)
            $fatal(1,"Watchdog timeout and pulse width must be positive");
    end
`endif
    always_ff @(posedge clk) begin
        if (reset) begin
            count <= 0;
            pulse_left <= 0;
            expired <= 0;
            armed <= 0;
        end else if (expired) begin
            // Once issued, the reset request completes even if pause or kick
            // changes. An external reset has priority over this pulse.
            if (pulse_left == 0) expired <= 0;
            else pulse_left <= pulse_left - 1'b1;
        end else if (kick) begin
            count <= 0;
            armed <= 1;
        end else if (armed && !pause) begin
            if (count == LAST_COUNT) begin
                count <= 0;
                armed <= 0;
                expired <= 1;
                pulse_left <= PULSE_LAST;
            end else count <= count + 1'b1;
        end
    end
endmodule
