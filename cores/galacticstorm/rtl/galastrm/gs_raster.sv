// SPDX-License-Identifier: BSD-3-Clause
// Presentation timing is distinct from the renderer's512x400 drawing surface.
module gs_raster #(parameter [8:0] RESET_Y=0,parameter PRESENT_15K=0)(
    input wire clk,reset,output wire pixel_ce,
    output wire [8:0] x,y,output wire visible,frame_cut,frame_start);
    generate if(PRESENT_15K)begin: provisional_15k
        gs_raster64 raster(.clk_sys(clk),.reset(reset),.ce_pixel(pixel_ce),
            .x(x),.y(y),.hs(),.vs(),.hb(),.vb());
        assign visible=x>=96 && x<416 && y>=16 && y<248;
        assign frame_cut=pixel_ce && x==0 && y==248;
        assign frame_start=pixel_ce && x==0 && y==0;
    end else begin: legacy_reference
        gs_raster_legacy #(.RESET_Y(RESET_Y)) raster(
            .clk(clk),.reset(reset),.pixel_ce(pixel_ce),.x(x),.y(y),
            .visible(visible),.frame_cut(frame_cut),.frame_start(frame_start));
    end endgenerate
endmodule
// SPDX-License-Identifier: BSD-3-Clause
// Approved provisional presentation raster; these are not measured PCB porches.
// Standalone redesign candidate, not yet connected to the production core.
module gs_raster64(
    input wire clk_sys, reset,
    output wire ce_pixel, hs, vs, hb, vb,
    output reg [8:0] x = 0,
    output reg [8:0] y = 0
);
    // Never gate or restart the pixel divider on pause or game reset.
    // FPGA power-up initialization establishes the initial phase only.
    reg [2:0] pixel_count = 0;
    reg restart = 1;
    always @(posedge clk_sys) begin
        pixel_count <= pixel_count + 1'b1;
        // Remember even a one-root-clock reset until a pixel boundary.
        if (reset) restart <= 1;
        if (ce_pixel) begin
            restart <= reset;
            if (reset || restart) begin x <= 0; y <= 0; end
            else if (x == 511) begin
                x <= 0;
                y <= y == 259 ? 9'd0 : y + 1'b1;
            end else x <= x + 1'b1;
        end
    end
    assign ce_pixel = pixel_count == 3'd7;
    assign hs = x < 32;
    assign vs = y < 4;
    assign hb = x < 96 || x >= 416;
    assign vb = y < 16 || y >= 248;
endmodule

// SPDX-License-Identifier: BSD-3-Clause
// MAME 0.289 Galastrm native raster: 512x400 at 60 Hz, visible
// x=96..415/y=84..315, update/snapshot before IRQ5 on line 316.
// At the qualified 64 MHz GPU clock, native pixel enable is exactly 24/125.
module gs_raster_legacy #(parameter [8:0] RESET_Y=0)(
    input wire clk,reset,
    output reg pixel_ce,
    output reg [8:0] x,y,
    output wire visible,frame_cut,frame_start
);
    reg [6:0] phase;
    assign visible=x>=96 && x<416 && y>=84 && y<316;
    assign frame_cut=pixel_ce && x==0 && y==316;
    assign frame_start=pixel_ce && x==0 && y==0;
    always @(posedge clk) begin
        pixel_ce<=0;
        if(phase>=101) begin phase<=phase-101;pixel_ce<=1;end
        else phase<=phase+24;
        if(pixel_ce) begin
            x<=x+1'b1;
            if(x==511) begin x<=0;y<=y==399?0:y+1'b1;end
        end
        if(reset) begin phase<=0;pixel_ce<=0;x<=0;y<=RESET_Y;end
    end
endmodule
