// Fixed integer component enables from the single 48 MHz system clock.
// Phase is intentionally free-running through reset and pause.
//
// cpu_speed selects the main Z80 enable rate (OSD "Main CPU Speed"):
//   0 = 12 MHz (period 4), 1 = Original 6 MHz (period 8, exact PCB rate),
//   2 = 16 MHz (period 3), 3 = Original. The selection is sampled only on
// the original 6 MHz boundary and the first faster enable follows one full
// new period later, so enable spacing is never shorter than the active period
// (3 clk_sys) across any switch. Original keeps the qualified phase exactly.
module daikaiju_clock_enables (
    input  logic       clk_sys,
    input  logic [1:0] cpu_speed,
    output logic       ce_main_6mhz,
    output logic       ce_osc_3mhz
);
    logic [3:0] phase = 4'd0;
    always_ff @(posedge clk_sys) phase <= phase + 1'b1;

    wire boundary = &phase[2:0];
    // Internal mode: 0 = 12 MHz, 1 = Original, 2 = 16 MHz.
    logic [1:0] mode_q = 2'd1;
    logic [1:0] fast_cnt = 2'd0;
    wire fast_mode = (mode_q != 2'd1);
    wire [1:0] fast_last = (mode_q == 2'd2) ? 2'd2 : 2'd3;
    wire fast_ce = fast_mode && (fast_cnt == fast_last);

    always_ff @(posedge clk_sys) begin
        if (boundary) mode_q <= (cpu_speed == 2'd3) ? 2'd1 : cpu_speed;
        if (!fast_mode || fast_ce) fast_cnt <= 2'd0;
        else                       fast_cnt <= fast_cnt + 2'd1;
    end

    assign ce_main_6mhz = fast_mode ? fast_ce : boundary;
    assign ce_osc_3mhz = &phase;
endmodule
