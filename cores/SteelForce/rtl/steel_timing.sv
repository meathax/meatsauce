// One board clock. Reference IRQ/vblank and chip rates use rational enables.
module steel_timing #(
    parameter integer CLK_HZ=45600000
)(
    input logic clk, reset, pause_cpu, mortalr,
    // OSD CPU Turbo: 68000 phase rate = board clock (22.8 MHz CPU) instead of 30 MHz (15 MHz CPU, PCB speed).
    input logic turbo,
    output logic phi1, phi2, oki_cen, frame_tick, vblank,
    output logic [31:0] frame_number
);
`include "rtl/steel_raster_params.vh"
    // CPU frame interrupt and CPU-visible vblank are locked to the display raster: one frame is exactly
    // RASTER_FRAME_CLOCKS and the IRQ/vblank start coincides with the first clock of raster line
    // RASTER_V_ACTIVE (steel_raster resets to that line). MAME's explicit 2500 us vblank is converted with the
    // real line period: 2500 us = 38.0 lines of 65.79 us = 114,000 clocks, rounded to whole lines.
    localparam integer VBLANK_LINES=(CLK_HZ/400+RASTER_LINE_CLOCKS/2)/RASTER_LINE_CLOCKS;
    logic [31:0] cpu_acc, oki_acc, frame_cnt;
    logic next_phi2;
    logic [31:0] blank_left;
    wire [31:0] cpu_rate=turbo?CLK_HZ:32'd30000000;
    wire cpu_due=cpu_acc>=CLK_HZ-cpu_rate;
    wire [31:0] oki_rate=mortalr?32'd1006875:32'd1000000;
    assign phi1=cpu_due && !next_phi2 && !pause_cpu && !reset;
    assign phi2=cpu_due && next_phi2 && !pause_cpu && !reset;
    assign oki_cen=oki_acc>=CLK_HZ-oki_rate && !reset;
    assign frame_tick=frame_cnt==RASTER_FRAME_CLOCKS-1 && !reset;
    assign vblank=blank_left!=0;
    always_ff @(posedge clk) begin
        if(reset) begin
            cpu_acc<=0;oki_acc<=0;frame_cnt<=0;next_phi2<=1;
            blank_left<=0;frame_number<=0;
        end else begin
            if(!pause_cpu) begin
                if(cpu_due) begin cpu_acc<=cpu_acc+cpu_rate-CLK_HZ;next_phi2<=!next_phi2;end
                else cpu_acc<=cpu_acc+cpu_rate;
            end
            if(oki_cen) oki_acc<=oki_acc+oki_rate-CLK_HZ;
            else oki_acc<=oki_acc+oki_rate;
            if(frame_tick) begin
                frame_cnt<=0;
                frame_number<=frame_number+1;
                blank_left<=VBLANK_LINES*RASTER_LINE_CLOCKS; // MAME's explicit 2500us compatibility setting, in whole real lines.
            end else begin
                frame_cnt<=frame_cnt+1;
                if(blank_left!=0) blank_left<=blank_left-1;
            end
        end
    end
endmodule
