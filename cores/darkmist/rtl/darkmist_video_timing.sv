// SPDX-License-Identifier: GPL-3.0-or-later
// Steady prototype raster through CPU reset/download. Physical PCB sync windows
// remain unqualified: these totals/windows are the MAME comparison fixture.
module darkmist_video_timing (
    input wire clk,power_reset,soft_reset,run_ready,
    output reg hold_game,ce_pixel,
    output reg [8:0] pixel_x,
    output reg [7:0] pixel_y,
    output wire hblank,vblank,hsync,vsync,frame_tick
);
    reg [2:0] div;
    reg [8:0] x;
    reg [7:0] y;
    wire advance=div==7;
    assign frame_tick=advance && x==399 && y==239;
    assign hblank=pixel_x>=256;
    assign vblank=pixel_y<16 || pixel_y>=240;
    assign hsync=pixel_x>=304 && pixel_x<336;
    assign vsync=pixel_y>=244 && pixel_y<248;
    always @(posedge clk) begin
        if(power_reset) begin
            div<=0;x<=0;y<=240;hold_game<=1;ce_pixel<=0;pixel_x<=0;pixel_y<=240;
        end else begin
            div<=div+3'd1;ce_pixel<=advance;pixel_x<=x;pixel_y<=y;
            if(advance) begin
                if(x==399) begin x<=0;y<=y+8'd1;end else x<=x+9'd1;
            end
            if(soft_reset || !run_ready) hold_game<=1;
            else if(frame_tick) hold_game<=0;
        end
    end
endmodule
