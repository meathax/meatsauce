// Per-title digital/49-way input wrapper for the MCR-68k core.
/* verilator lint_off IMPORTSTAR */
import mcr68_game_pkg::*;
/* verilator lint_on IMPORTSTAR */
`default_nettype none

module mcr68_input_frontend (
    input  wire              clk,
    input  wire              rst,
    input  wire  [2:0]       game,
    input  wire  [2:0]       coin,
    input  wire  [1:0]       start_btn,
    input  wire              tilt,
    input  wire              service1,
    input  wire              service_dip,
    input  wire  [3:0]       joy1,
    input  wire  [3:0]       joy2,
    input  wire  [3:0]       joy3,
    input  wire  [7:1]       btn1,
    input  wire  [7:1]       btn2,
    input  wire  [7:1]       btn3,
    input  wire signed [7:0] an_x1,
    input  wire signed [7:0] an_y1,
    input  wire signed [7:0] an_x2,
    input  wire signed [7:0] an_y2,
    input  wire  [7:0]       dsw_in,
    output wire  [15:0]      in0_word,
    output wire  [15:0]      in1_word,
    output wire  [15:0]      dsw_word
);
    // 49-way position outputs are diagnostic-only; the frontend contract
    // exposes the assembled CPU-visible port words, not telemetry.
    /* verilator lint_off PINCONNECTEMPTY */
    mcr68_input_map #(.RUNTIME_GAME_SEL(1'b1)) u_input_map (
        .clk         (clk),
        .rst         (rst),
        .game        (mcr68_game_e'(game)),
        .coin        (coin),
        .start_btn   (start_btn),
        .tilt        (tilt),
        .service1    (service1),
        .service_dip (service_dip),
        .joy1        (joy1),
        .joy2        (joy2),
        .joy3        (joy3),
        .btn1        (btn1),
        .btn2        (btn2),
        .btn3        (btn3),
        .an_x1       (an_x1),
        .an_y1       (an_y1),
        .an_x2       (an_x2),
        .an_y2       (an_y2),
        .dsw_in      (dsw_in),
        .in0_word    (in0_word),
        .in1_word    (in1_word),
        .dsw_word    (dsw_word),
        .dbg_pos_x1  (),
        .dbg_pos_y1  (),
        .dbg_pos_x2  (),
        .dbg_pos_y2  ()
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule

`default_nettype wire
