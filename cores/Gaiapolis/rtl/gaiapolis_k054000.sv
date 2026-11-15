// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from JTCORES simson/hdl/jtk054000.v (Jose Tejada Gomez).
// Register map/arithmetic reference: MAME 0.289 konami/k054000.cpp.
// The staged JT pipeline is retained; active arithmetic corrects 24-bit wrap,
// the -1024 endpoint, and abs(full_difference)&511 rather than abs(low9).
// Semiaxes reset to one and written values are used WITHOUT adding one.
// clk is the system clock; rst is synchronous and active high. cs is already
// lower-byte-lane qualified; addr is the register number (CPU byte A[5:1]).
// A cs/we write commits once per rising clock; repeated identical bus writes
// are harmless. din/dout are the LOWER byte. Undefined reads return zero.
// Status 0x18 returns 0 for collision and 1 for no collision; other addresses
// return zero even if they were written. ready is false for four clocks after
// a parameter write/reset, and true on other reads. The bus wrapper must wait
// on a status read until ready, rather than sampling stale pipeline state.
// state_addr/state_dout provide non-destructive raw register visibility.
module gaiapolis_k054000 (
    input  logic        clk,
    input  logic        rst,
    input  logic        cs,
    input  logic [4:0]  addr,
    input  logic        we,
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    output logic        ready,
    input  logic [4:0]  state_addr,
    output logic [7:0]  state_dout
);
    logic [23:0] a_center_x, a_center_y, b_center_x, b_center_y;
    logic [7:0] a_delta_x, a_delta_y;
    logic [7:0] a_half_x, a_half_y, b_half_x, b_half_y;
    logic signed [25:0] adjusted_x, adjusted_y, difference_x, difference_y;
    logic [8:0] sum_x, sum_y;
    logic outside_x, outside_y, no_collision;
    logic [2:0] settling;
    logic parameter_write;
    logic [8:0] magnitude_x, magnitude_y;

    always_comb begin
        parameter_write = cs && we && (
            (addr >= 5'h01 && addr <= 5'h04) || addr == 5'h06 || addr == 5'h07 ||
            (addr >= 5'h09 && addr <= 5'h0c) || addr == 5'h0e || addr == 5'h0f ||
            (addr >= 5'h11 && addr <= 5'h13) || (addr >= 5'h15 && addr <= 5'h17));
        // abs(full difference)&511 depends on the FULL sign, not bit 8.
        magnitude_x = difference_x[25] ? -difference_x[8:0] : difference_x[8:0];
        magnitude_y = difference_y[25] ? -difference_y[8:0] : difference_y[8:0];
        dout = cs && !we && addr == 5'h18 ? {7'd0,no_collision} : 8'd0;
        ready = !(cs && !we && addr == 5'h18) || settling == 3'd0;
        state_dout = 8'd0;
        case (state_addr)
            5'h01: state_dout = a_center_x[23:16];
            5'h02: state_dout = a_center_x[15:8];
            5'h03: state_dout = a_center_x[7:0];
            5'h04: state_dout = a_delta_x;
            5'h06: state_dout = a_half_x;
            5'h07: state_dout = a_half_y;
            5'h09: state_dout = a_center_y[23:16];
            5'h0a: state_dout = a_center_y[15:8];
            5'h0b: state_dout = a_center_y[7:0];
            5'h0c: state_dout = a_delta_y;
            5'h0e: state_dout = b_half_x;
            5'h0f: state_dout = b_half_y;
            5'h11: state_dout = b_center_y[23:16];
            5'h12: state_dout = b_center_y[15:8];
            5'h13: state_dout = b_center_y[7:0];
            5'h15: state_dout = b_center_x[23:16];
            5'h16: state_dout = b_center_x[15:8];
            5'h17: state_dout = b_center_x[7:0];
            default: state_dout = 8'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            a_center_x <= 24'd0;
            a_center_y <= 24'd0;
            b_center_x <= 24'd0;
            b_center_y <= 24'd0;
            a_delta_x <= 8'd0;
            a_delta_y <= 8'd0;
            a_half_x <= 8'd1;
            a_half_y <= 8'd1;
            b_half_x <= 8'd1;
            b_half_y <= 8'd1;
            adjusted_x <= 26'sd0;
            adjusted_y <= 26'sd0;
            difference_x <= 26'sd0;
            difference_y <= 26'sd0;
            sum_x <= 9'd2;
            sum_y <= 9'd2;
            outside_x <= 1'b0;
            outside_y <= 1'b0;
            no_collision <= 1'b0;
            settling <= 3'd4;
        end else begin
            if (parameter_write) begin
                settling <= 3'd4;
                case (addr)
                    5'h01: a_center_x[23:16] <= din;
                    5'h02: a_center_x[15:8] <= din;
                    5'h03: a_center_x[7:0] <= din;
                    5'h04: a_delta_x <= din;
                    5'h06: a_half_x <= din;
                    5'h07: a_half_y <= din;
                    5'h09: a_center_y[23:16] <= din;
                    5'h0a: a_center_y[15:8] <= din;
                    5'h0b: a_center_y[7:0] <= din;
                    5'h0c: a_delta_y <= din;
                    5'h0e: b_half_x <= din;
                    5'h0f: b_half_y <= din;
                    5'h11: b_center_y[23:16] <= din;
                    5'h12: b_center_y[15:8] <= din;
                    5'h13: b_center_y[7:0] <= din;
                    5'h15: b_center_x[23:16] <= din;
                    5'h16: b_center_x[15:8] <= din;
                    5'h17: b_center_x[7:0] <= din;
                    default: ;
                endcase
            end else if (settling != 3'd0) begin
                settling <= settling - 3'd1;
            end
            adjusted_x <= $signed({2'b00,a_center_x}) + $signed({{18{a_delta_x[7]}},a_delta_x});
            adjusted_y <= $signed({2'b00,a_center_y}) + $signed({{18{a_delta_y[7]}},a_delta_y});
            difference_x <= adjusted_x - $signed({2'b00,b_center_x});
            difference_y <= adjusted_y - $signed({2'b00,b_center_y});
            sum_x <= {1'b0,a_half_x} + {1'b0,b_half_x};
            sum_y <= {1'b0,a_half_y} + {1'b0,b_half_y};
            outside_x <= difference_x > 26'sd511 || difference_x <= -26'sd1024 ||
                         magnitude_x > sum_x;
            outside_y <= difference_y > 26'sd511 || difference_y <= -26'sd1024 ||
                         magnitude_y > sum_y;
            no_collision <= outside_x || outside_y;
        end
    end
endmodule
