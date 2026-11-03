// SPDX-License-Identifier: GPL-3.0-or-later
// User-approved provisional 7MHz / 448x272 raster (57.4458 Hz), user-approved 27 October 2026 from PCB footage audio timing; replaces the 22 October 442x276.
// clk is the shared 56MHz system/video clock. Cold reset only: game reset,
// pause, OSD, ROM loading and memory stalls must not stop video cadence.
// Sync/active placement and 529us IRQ duration retain the diagnostic profile;
// they remain provisional, not measured PCB sync/IRQ waveforms.
module hangzo_raster (
    input wire clk,cold_reset,
    output wire pixel_ce,hs,vs,hblank,video_vblank,irq_vblank,
    output wire frame_boundary,
    output reg frame_odd,
    output reg [8:0] hpos,vpos
);
    reg [2:0] pixel_phase;
    reg [14:0] irq_remaining;
    assign pixel_ce=!cold_reset && pixel_phase==3'd7;
    assign frame_boundary=pixel_ce && hpos==0 && vpos==248;
    assign hs=!(hpos>=350 && hpos<384);
    assign vs=!(vpos>=256 && vpos<260);
    assign hblank=hpos>=320;
    assign video_vblank=vpos<8 || vpos>=248;
    assign irq_vblank=!cold_reset && (frame_boundary || irq_remaining!=0);
    always @(posedge clk) begin
        if(cold_reset) begin
            pixel_phase<=0; hpos<=0; vpos<=248;
            irq_remaining<=0; frame_odd<=0;
        end else begin
            pixel_phase<=pixel_phase+3'd1;
            if(frame_boundary) irq_remaining<=15'd29623;
            else if(irq_remaining!=0) irq_remaining<=irq_remaining-15'd1;
            if(pixel_ce) begin
                if(hpos==447) begin
                    hpos<=0;
                    if(vpos==271) vpos<=0; else vpos<=vpos+9'd1;
                    if(vpos==247) frame_odd<=!frame_odd;
                end else hpos<=hpos+9'd1;
            end
        end
    end
endmodule
