/*  This file is part of JTOPL.

    JTOPL is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTOPL is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTOPL.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 17-6-2020

    */

module psychos_jtopl_eg_step(
    input             attack,
    input      [ 4:0] base_rate,
    input      [ 3:0] keycode,
    input      [14:0] eg_cnt,
    input             cnt_in,
    input             ksr,
    output            cnt_lsb,
    output reg        step,
    output reg [ 5:0] rate,
    output reg        sum_up
);

reg  [6:0]   pre_rate;
wire [1:0]   shby;

// MAME0.289 OPL keycode scaling: KSR enabled uses full code; disabled uses /4.
assign shby = ksr ? 2'd0 : 2'd2;

always @(*) begin : pre_rate_calc
    if( base_rate == 5'd0 )
        pre_rate = 7'd0;
    else
        pre_rate = { 1'b0, base_rate, 1'b0 } +  // base_rate LSB is always zero except for RR
            ({ 3'b0, keycode } >> shby);
end

always @(*)
    // MAME0.289 retains finite attack at rates60/61; saturate only above63.
    rate = pre_rate>7'd63 ? 6'd63 : pre_rate[5:0];

reg [2:0] cnt;

reg [4:0] mux_sel;
always @(*) begin
    mux_sel = {1'b0,rate[5:2]}; // pinned OPL attack and decay share counter epochs
end

always @(*) 
    case( mux_sel )
        5'h0:    cnt = eg_cnt[13:11];
        5'h1:    cnt = eg_cnt[12:10];
        5'h2:    cnt = eg_cnt[11: 9];
        5'h3:    cnt = eg_cnt[10: 8];
        5'h4:    cnt = eg_cnt[ 9: 7];
        5'h5:    cnt = eg_cnt[ 8: 6];
        5'h6:    cnt = eg_cnt[ 7: 5];
        5'h7:    cnt = eg_cnt[ 6: 4];
        5'h8:    cnt = eg_cnt[ 5: 3];
        5'h9:    cnt = eg_cnt[ 4: 2];
        5'ha:    cnt = eg_cnt[ 3: 1];
        default: cnt = eg_cnt[ 2: 0];
    endcase

////////////////////////////////
reg [7:0] step_idx;

always @(*) begin : rate_step
    if( rate[5:4]==2'b11 ) begin // 0 means 1x, 1 means 2x
        if( rate[5:2]==4'hf && attack)
            step_idx = 8'b11111111; // Maximum attack speed, rates 60&61
        else
        case( rate[1:0] )
            2'd0: step_idx = 8'b00000000;
            2'd1: step_idx = 8'b10001000; // 2
            2'd2: step_idx = 8'b10101010; // 4
            2'd3: step_idx = 8'b11101110; // 6
        endcase
    end
    else begin
        if( rate[5:3]==3'd0 )
            step_idx = rate[2:1]==2'b11 ? 8'b11101110 : 8'b10101010; // official nonattack rates2..7
        else
        case( rate[1:0] )
            2'd0: step_idx = 8'b10101010; // 4
            2'd1: step_idx = 8'b10111010; // preserve attack path; official nonattack pattern
            2'd2: step_idx = 8'b11101110; // 6
            2'd3: step_idx = 8'b11111110; // 7
        endcase
    end
    // a rate of zero keeps the level still
    step = rate[5:1]==5'd0 ? 1'b0 : step_idx[ cnt ];
end

assign cnt_lsb = cnt[0];
always @(*) begin
    // A cached counter bit belongs to the previous rate and is invalid when
    // attack/decay or register writes select a new rate. Pinned OPL clocks
    // the envelope only when the current counter has zero fractional bits.
    case( rate[5:2] )
        4'h0: sum_up = ~|eg_cnt[10:0];
        4'h1: sum_up = ~|eg_cnt[9:0];
        4'h2: sum_up = ~|eg_cnt[8:0];
        4'h3: sum_up = ~|eg_cnt[7:0];
        4'h4: sum_up = ~|eg_cnt[6:0];
        4'h5: sum_up = ~|eg_cnt[5:0];
        4'h6: sum_up = ~|eg_cnt[4:0];
        4'h7: sum_up = ~|eg_cnt[3:0];
        4'h8: sum_up = ~|eg_cnt[2:0];
        4'h9: sum_up = ~|eg_cnt[1:0];
        4'ha: sum_up = ~eg_cnt[0];
        default: sum_up = 1'b1;
    endcase

end

endmodule // eg_step