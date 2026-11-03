/*  This file is part of JT51.

    JT51 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT51 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT51.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 27-10-2016
    */

/*  Darkmist derivative (r5-ymtimer): timers start and expire at the write instant, as in MAME.

    Original: jotego/jt51 commit 985a573dcfc1ff135553a39f7eae21d18ba57cbe hdl/jt51_timers.v
    (sha256 e885ffd11d62c2bf42aafb90eb30e681c3d98ae9c4fe6714b13d72f491347e70). GPL-3.0-or-later preserved.

    Change. The original loads a timer at the next sample boundary (zero), so the overflow flag lags the
    register write by 0..17.9 us. MAME 0.289 (ymfm_opm) arms timer A at the write instant for (1024-N)*64
    YM clocks and timer B for 16*(256-N)-(total_clocks&15) samples, where total_clocks is the number of
    sound-stream samples generated so far (floor(t*55930)+1: the stream rate is truncated to an integer).
    Here each timer has its own prescaler (32 cen_p1 per sample) that restarts on the load edge, the
    sub-cen_p1 write position is captured in clk units and added back at expiry, and timer B reads a
    private copy of MAME's sample counter. Ports are unchanged.

    Calibration. The native T5182 bus write is one cen_p1 (2 T-states, 0.56 us) later than the MAME tap
    that starts the timer, so timers expire one cen_p1 early and the sample grid starts one cen_p1 late.
    MAME also samples the YM status at the start of the Z80 I/O read step while the T80 samples the data bus
    at its end (26 clk, 0.53 us later), so the status copy of each flag rises 26 clk after the IRQ copy.
    This matches MAME-observed ordering; the real silicon phase is unmeasured. */

module jt51_timers(
    input         rst,
    input         clk,
    input         cen,
    input         zero,
    input [9:0]   value_A,
    input [7:0]   value_B,
    input         load_A,
    input         load_B,
    input         clr_flag_A,
    input         clr_flag_B,
    input         enable_irq_A,
    input         enable_irq_B,
    output        flag_A,
    output        flag_B,
    output        overflow_A,
    output        irq_n
);

wire irq_flag_A, irq_flag_B;   // undelayed flags drive the IRQ; flag_A/flag_B (status port) rise 26 clk later
assign irq_n = ~( (irq_flag_A&enable_irq_A) | (irq_flag_B&enable_irq_B) );

jt51_timer #(.CW(10)) timer_A(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .zero       ( zero      ),
    .start_value( value_A   ),
    .load       ( load_A    ),
    .clr_flag   ( clr_flag_A),
    .flag       ( irq_flag_A),
    .flag_vis   ( flag_A    ),
    .overflow   ( overflow_A)
);

jt51_timer #(.CW(8),.IS_B(1)) timer_B(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen           ),
    .zero       ( zero          ),
    .start_value( value_B       ),
    .load       ( load_B        ),
    .clr_flag   ( clr_flag_B    ),
    .flag       ( irq_flag_B    ),
    .flag_vis   ( flag_B        ),
    .overflow   (               )
);

endmodule

module jt51_timer #(parameter
    CW   = 8, // counter bit width. This is the counter that can be loaded
    IS_B = 0  // timer B ticks every 16 samples, phase-locked to the free-running sample counter
) (
    input   rst,
    input   clk,
    input   cen,
    input   zero,
    input   [CW-1:0] start_value,
    input   load,
    input   clr_flag,
    output reg flag,
    output reg flag_vis,
    output     overflow
);

localparam [22:0] STEP = 23'd111860;     // 2 YM clocks * 55930 per cen_p1
localparam [22:0] FULL = 23'd3579545;    // YM clocks per second

reg          last_load, load_q;
reg [CW-1:0] cnt;
reg [   4:0] presc;      // cen counts within one sample (wraps every 32 cen = 64 YM clocks)
reg [   3:0] free_cnt;   // MAME total_clocks (low bits) as of the last cen_p1
reg [  21:0] fph;        // sample-grid accumulator, units of 1/3579545 sample-seconds
reg          fseen;      // first cen_p1 after reset only starts the grid
reg [   3:0] bph;        // timer B: samples elapsed within the current 16-sample tick
reg [   4:0] since;      // clk cycles since the last cen_p1 (saturating)
reg [   4:0] a_reg;      // 'since' when the write took effect
reg [   3:0] f_reg;      // free_cnt at that instant, including a boundary passed since the last cen_p1
reg [   4:0] dly;        // clk cycles left before the flag rises
reg          dly_run;
reg [   4:0] vdly;       // status-copy delay counter

wire [  22:0] fnext = {1'b0,fph} + STEP;
wire          fwrap = fnext >= FULL;
wire [  22:0] fadv  = fwrap ? fnext - FULL : fnext;
// Sample-boundary crossing between the last cen_p1 and now: STEP per 27.46 clk = 4074 per clk.
// Three registered stages (60 ns of lag) keep the multiply/add/compare off one clock.
reg  [  16:0] fprod;
reg  [  22:0] fnow;
reg           fcross;
wire         sample_end = presc == 5'd31;
wire         tick = IS_B ? (sample_end && bph == 4'd15) : sample_end;
wire         start = load && !last_load;
wire         expire = tick && (&cnt);
assign overflow = &cnt;

always @(posedge clk) begin
    if( rst ) begin
        last_load <= 1'b0;
        load_q    <= 1'b0;
        cnt       <= {CW{1'b0}};
        presc     <= 5'd0;
        fph       <= 22'd0;
        fseen     <= 1'b0;
        free_cnt  <= 4'd1;   // MAME total_clocks = stream index + 1
        bph       <= 4'd0;
        since     <= 5'd0;
        a_reg     <= 5'd0;
        f_reg     <= 4'd1;
        fprod     <= 17'd0;
        fnow      <= 23'd0;
        fcross    <= 1'b0;
        flag_vis  <= 1'b0;
        vdly      <= 5'd0;
        dly       <= 5'd0;
        dly_run   <= 1'b0;
        flag      <= 1'b0;
    end else begin
        load_q <= load;
        fprod  <= {since,12'd0} - {8'd0,since,4'd0} - {10'd0,since,2'd0} - {11'd0,since,1'd0};   // since * 4074 = since * (4096-16-4-2)
        fnow   <= {1'b0,fph} + {6'd0,fprod};
        fcross <= fseen && (fnow >= FULL);
        // status copy of the flag: rises 26 clk after the IRQ copy, falls with it
        if( !flag ) begin flag_vis <= 1'b0; vdly <= 5'd0; end
        else if( !flag_vis ) begin
            if( vdly == 5'd26 ) flag_vis <= 1'b1; else vdly <= vdly + 5'd1;
        end
        if( cen ) since <= 5'd0; else if( since != 5'd31 ) since <= since + 5'd1;
        if( load && !load_q ) begin
            a_reg <= since;
            f_reg <= free_cnt + {3'd0,fcross};
        end
        if( dly_run ) begin
            dly <= dly - 5'd1;
            if( dly == 5'd1 ) begin dly_run <= 1'b0; if( !clr_flag ) flag <= 1'b1; end
        end
        if( clr_flag ) flag <= 1'b0;
        if( cen ) begin
            last_load <= load;
            fseen <= 1'b1;
            if( fseen ) begin
                fph <= fadv[21:0];
                if( fwrap ) free_cnt <= free_cnt + 4'd1;
            end
            if( start ) begin
                cnt   <= start_value;
                presc <= 5'd2;       // exact restart is 1 (first tick 32 cen_p1 after the cen_p1 that follows the write);
                                     // 2 adds the one-cen_p1 bus-offset calibration described in the header
                bph   <= f_reg;
            end else if( load ) begin
                presc <= presc + 5'd1;
                if( sample_end ) bph <= (bph == 4'd15) ? 4'd0 : bph + 4'd1;
                if( tick ) cnt <= expire ? start_value : cnt + 1'b1;
                if( expire && !clr_flag ) begin
                    if( a_reg == 5'd0 ) flag <= 1'b1;
                    else begin dly <= a_reg; dly_run <= 1'b1; end
                end
            end
        end
    end
end

endmodule
