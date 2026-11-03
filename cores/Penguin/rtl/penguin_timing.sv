// SPDX-License-Identifier: GPL-3.0-or-later
// Integer-divider raster timing (clock plan: mister-clock-plan.md R1-R9).
// CE_PIXEL is a plain counter of the system clock: exactly one enable every PIXEL_DIV clocks,
// on every line, in blanking, pause and reset release, so pixel widths and line length never jitter.
// Raster totals are a synthetic evidence-fitted geometry (the real PCB H/V totals are unmeasured):
// 100 MHz / 16 = 6.25 MHz pixel, 400 x 258, 6400-clock lines = 60.5620 Hz against the
// 60.53 Hz PCB-video-measured refresh (docs/pcb-refresh-measurement.md); +0.05 %.
// The 400-pixel line keeps ~6400 clocks per line for the renderer (the previous accumulator
// gave 6453/6454); 512x269 /12 gave only 6144 and dropped rows (docs/clock-plan-20261022.md).
module penguin_timing #(
    parameter integer SYS_HZ=100000000,
    parameter integer PIXEL_DIV=16,
    parameter integer H_TOTAL=400,V_TOTAL=258,
    parameter integer ACTIVE_WIDTH=320,ACTIVE_HEIGHT=224,
    parameter integer H_SYNC_START=336,H_SYNC_END=368,
    parameter integer V_SYNC_START=232,V_SYNC_END=236
)(
    input logic clk,cold_reset,
    output wire ce_pix,
    output logic [8:0] h_count,v_count,
    output wire hblank,vblank,hsync,vsync,vblank_irq,
    (* preserve *) output logic scan_line_active, scan_next_line_active,
    output logic [31:0] frame_number
);
    localparam integer FRAME_CLOCKS=PIXEL_DIV*H_TOTAL*V_TOTAL;
    // Configured 2500us MAME IRQ duration differs from the synthetic blank interval.
    localparam integer IRQ_CLOCKS=SYS_HZ/400;
    localparam integer PIX_W=$clog2(PIXEL_DIV)+1;
    localparam integer FRAME_W=$clog2(FRAME_CLOCKS)+1;
    logic [PIX_W-1:0] pixel_count;
    logic [FRAME_W-1:0] frame_clock;
    assign ce_pix=!cold_reset && pixel_count==PIX_W'(PIXEL_DIV-1);
    assign vblank_irq=!cold_reset && frame_clock<FRAME_W'(IRQ_CLOCKS);
    assign hblank=h_count>=9'(ACTIVE_WIDTH);
    assign vblank=v_count>=9'(ACTIVE_HEIGHT);
    assign hsync=h_count>=9'(H_SYNC_START) && h_count<9'(H_SYNC_END);
    assign vsync=v_count>=9'(V_SYNC_START) && v_count<9'(V_SYNC_END);
    wire [8:0] next_v_count=v_count==9'(V_TOTAL-1)?9'd0:v_count+9'd1;
    function automatic logic next_line_active(input logic [8:0] line_number);
        next_line_active=(line_number==9'(V_TOTAL-1)?9'd0:line_number+9'd1)<ACTIVE_HEIGHT;
    endfunction
    // Decode at the counter update edge, preserving every output pixel cycle.
    always_ff @(posedge clk) begin
        if(cold_reset) begin
            scan_line_active <= 9'(ACTIVE_HEIGHT)<ACTIVE_HEIGHT;
            scan_next_line_active <= next_line_active(9'(ACTIVE_HEIGHT));
        end else if(ce_pix && h_count==9'(H_TOTAL-1)) begin
            scan_line_active <= next_v_count<ACTIVE_HEIGHT;
            scan_next_line_active <= next_line_active(next_v_count);
        end
    end
    // pixel_count and frame_clock both start at reset, so the IRQ window opens exactly at the
    // first vblank line and stays locked to the raster (FRAME_CLOCKS is the exact raster period).
    always_ff @(posedge clk) begin
        if(cold_reset) begin
            pixel_count<=0;frame_clock<=0;h_count<=0;
            v_count<=9'(ACTIVE_HEIGHT);frame_number<=0;
        end else begin
            pixel_count<=ce_pix?PIX_W'(0):pixel_count+PIX_W'(1);
            if(frame_clock==FRAME_W'(FRAME_CLOCKS-1)) begin
                frame_clock<=0;frame_number<=frame_number+32'd1;
            end else frame_clock<=frame_clock+FRAME_W'(1);
            if(ce_pix) begin
                if(h_count==9'(H_TOTAL-1)) begin
                    h_count<=0;
                    v_count<=v_count==9'(V_TOTAL-1)?9'd0:v_count+9'd1;
                end else h_count<=h_count+9'd1;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if(PIXEL_DIV<4 || PIXEL_DIV%2 || H_TOTAL>512 || V_TOTAL>512 || H_TOTAL<=ACTIVE_WIDTH || V_TOTAL<=ACTIVE_HEIGHT
           || H_SYNC_END>H_TOTAL || V_SYNC_END>V_TOTAL)
            $fatal(1,"Invalid reference timing dimensions/pixel divider (even PIXEL_DIV>=4 required)");
    end
`endif
endmodule
