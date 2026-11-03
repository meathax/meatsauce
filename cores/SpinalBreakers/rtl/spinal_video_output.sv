// SPDX-License-Identifier: GPL-3.0-or-later
// Adapter from the registered game pixel tuple to MiSTer's arcade video chain.
// raw_x/raw_y, RGB, sync and raw_ce must describe the same sampled pixel.
module spinal_video_output #(parameter bit WITH_CRT=0) (
    input logic clk,reset,raw_ce,raw_hs,raw_vs,
    input logic [8:0] raw_x,raw_y,
    input logic [4:0] raw_r,raw_g,raw_b,
    input logic [2:0] effects,input logic forced_scandoubler,
    input logic crt_enable,input logic [2:0] crt_size,input logic signed [4:0] crt_hpos,crt_vpos,
    inout wire [21:0] gamma_bus,
    output wire clk_video,ce_pixel,output wire [7:0] red,green,blue,
    output wire hs,vs,de,output wire [1:0] scanlines,output wire hq2x_unavailable
);
    wire [23:0] rgb={{raw_r,raw_r[4:2]},{raw_g,raw_g[4:2]},{raw_b,raw_b[4:2]}};
    wire hblank=raw_x>=9'd352;
    wire vblank=raw_y>=9'd240;
    wire chain_ce,chain_hs,chain_vs,chain_hblank,chain_vblank;wire [23:0] chain_rgb;
    generate if(WITH_CRT)begin:gen_crt
        spinal_crt crt(.clk(clk),.reset(reset),.ce_in(raw_ce),.enable(crt_enable),
            .hsize_option(crt_size),.hpos_option(crt_hpos),.vpos_option(crt_vpos),
            .rgb_in(rgb),.hs_in(raw_hs),.vs_in(raw_vs),.hb_in(hblank),.vb_in(vblank),
            .ce_out(chain_ce),.active(),.rgb_out(chain_rgb),.hs_out(chain_hs),.vs_out(chain_vs),
            .hb_out(chain_hblank),.vb_out(chain_vblank));
    end else begin:gen_no_crt
        assign chain_ce=raw_ce;assign chain_rgb=rgb;assign chain_hs=raw_hs;assign chain_vs=raw_vs;
        assign chain_hblank=hblank;assign chain_vblank=vblank;
    end endgenerate
    // HQ2x would require /2 at this clock and is excluded by clock-plan R2.
    // Settings change only at vblank so the enabled divider never jitters.
    logic [2:0] fx_latched=0;logic forced_latched=0,hq_blocked=0;
    logic [2:0] phase=0;logic phase_ready=0;
    wire doubled=forced_latched || fx_latched!=0;
    wire mixer_ce,mixer_hs,mixer_vs,mixer_de;wire [7:0] mixer_r,mixer_g,mixer_b;
    logic doubled_hs,doubled_vs,doubled_de;logic [7:0] doubled_r,doubled_g,doubled_b;
    assign hq2x_unavailable=hq_blocked;
    // The fixed counter is anchored to the integer /8 input pixel cadence.
    // The doubled tuple is delayed one clk so both modes share raw+2 phase;
    // transitions can then preserve intervals of exactly 4 or 8 clocks.
    assign ce_pixel=phase_ready && (doubled ? phase[1:0]==1 : phase==1);
    assign {red,green,blue,hs,vs,de}=doubled ? {doubled_r,doubled_g,doubled_b,doubled_hs,doubled_vs,doubled_de} :
                                                      {mixer_r,mixer_g,mixer_b,mixer_hs,mixer_vs,mixer_de};
    always_ff @(posedge clk) begin
        if(reset)begin phase<=0;phase_ready<=0;fx_latched<=0;forced_latched<=0;hq_blocked<=0;
            doubled_r<=0;doubled_g<=0;doubled_b<=0;doubled_hs<=0;doubled_vs<=0;doubled_de<=0;end
        else begin
            if(mixer_ce)begin doubled_r<=mixer_r;doubled_g<=mixer_g;doubled_b<=mixer_b;
                doubled_hs<=mixer_hs;doubled_vs<=mixer_vs;doubled_de<=mixer_de;end
            if(!phase_ready)begin
                if(chain_ce)begin phase<=0;phase_ready<=1;end
            end else phase<=phase+1'b1;
            if(raw_ce && raw_x==0 && raw_y==240)begin
                fx_latched<=(effects==1 || effects>4) ? 0 : effects;
                forced_latched<=forced_scandoubler;
                hq_blocked<=effects==1 || effects>4;
            end
        end
    end
    spinal_arcade_video #(.WIDTH(WITH_CRT ? 384 : 352),.DW(24),.GAMMA(1)) video(
        .clk_video(clk),.ce_pix(chain_ce),.RGB_in(chain_rgb),.HBlank(chain_hblank),.VBlank(chain_vblank),.HSync(chain_hs),.VSync(chain_vs),
        .CLK_VIDEO(clk_video),.CE_PIXEL(mixer_ce),.VGA_R(mixer_r),.VGA_G(mixer_g),.VGA_B(mixer_b),
        .VGA_HS(mixer_hs),.VGA_VS(mixer_vs),.VGA_DE(mixer_de),.VGA_SL(scanlines),.fx(fx_latched),
        .forced_scandoubler(forced_latched),.gamma_bus(gamma_bus));
endmodule
