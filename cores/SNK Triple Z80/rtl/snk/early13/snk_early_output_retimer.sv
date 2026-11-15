// SPDX-License-Identifier: GPL-3.0-or-later
// Constant-width output retimer for the HSJ / TNK3-class early boards (profiles 3..10).
// The pinned donor video chain runs on the 13.4 MHz-family time base (4 fast events per pixel,
// 14/15-clock pixel pattern). Its CE_PIXEL feeds sys scandoubler/HDMI/CRT chain, which re-measure
// pixel length (clock plan R2: pixel enable must be a plain even-N counter of clk_sys==CLK_VIDEO).
// Here the donor stream is re-emitted at a uniform N clk/pixel; the donor line grid is locked
// (snk_early_master_cen VIDEO_LOCK) so the donor line is exactly (HTOT_DONOR+fill)*N clocks and the
// fill extra blank pixels per line (inserted just before HSync) absorb the donor/output pixel-rate difference
// (93.8 MHz: HSJ/TNK3 414+2, ASO 416+0 -> 416 x 14 clk). fill is quasi-static (profile) and may be 0.
// Every output line is therefore HTOT_DONOR+fill pixels of exactly N clocks (HS/VS widths unchanged).
module snk_early_output_retimer #(parameter integer N=14,parameter integer MARGIN=3)(
 input wire clk,rst,
 input wire [5:0] fill,
 input wire in_ce,
 input wire [23:0] in_rgb,
 input wire in_hb,in_vb,in_hs,in_vs,
 output reg out_ce=0,
 output reg [23:0] out_rgb=0,
 output reg out_hb=1,out_vb=1,out_hs=0,out_vs=0,
 output reg locked=0
);
 // 32-entry FIFO in block RAM with a registered read (an array read combinationally became 950 registers).
 // The read side samples the head once per N clocks, long after rp changes; empty compares rp against the write pointer
 // delayed two clocks so q always reflects a completed write.
 (* ramstyle="M10K,no_rw_check" *) reg [27:0] fifo [0:31];
 reg [27:0] head=0;
 reg [4:0] wp=0,rp=0,wp_d1=0,wp_d2=0;
 wire empty=wp_d2==rp;
 wire full=(wp+5'd1)==rp;
 wire head_hs=head[26];
 always @(posedge clk) begin
  if(in_ce&&!full&&!rst) fifo[wp]<={in_hb,in_hs,in_vb,in_vs,in_rgb};
  head<=fifo[rp];
  wp_d1<=wp;wp_d2<=wp_d1;
 end
 reg [3:0] tcnt=0;
 wire tick=tcnt==N-1;
 reg [5:0] fill_cnt=0;
 reg fill_done=0,last_hs=0,fill_vs=0,fill_vb=0;
 always @(posedge clk)begin
  if(rst)begin
   wp<=0;rp<=0;tcnt<=0;fill_cnt<=0;fill_done<=0;last_hs<=0;locked<=0;out_ce<=0;
  end else begin
   out_ce<=0;
   tcnt<=tick?4'd0:tcnt+4'd1;
   // write side: donor pixel (registered with its CE)
   if(in_ce&&!full) wp<=wp+5'd1;
   // read side: one pixel per N clocks
   if(tick)begin
    out_ce<=1;
    if(fill_cnt!=0)begin
     out_rgb<=24'd0;out_hb<=1;out_hs<=0;out_vb<=fill_vb;out_vs<=fill_vs;
     fill_cnt<=fill_cnt-6'd1;
    end else if(empty)begin
     // underflow (reset, pause release or a lost donor line): hold the picture and relock with margin
     locked<=0;
    end else if(head_hs&&!last_hs&&!fill_done&&(!locked||fill!=6'd0))begin
     // front porch extension; the first line after (re)lock gets MARGIN extra pixels of FIFO headroom
     fill_cnt<=(locked?fill:fill+MARGIN[5:0])-6'd1;
     fill_done<=1;locked<=1;
     fill_vs<=head[24];fill_vb<=head[25];
     out_rgb<=24'd0;out_hb<=1;out_hs<=0;out_vb<=head[25];out_vs<=head[24];
    end else begin
     out_rgb<=head[23:0];out_hb<=head[27];out_hs<=head[26];out_vb<=head[25];out_vs<=head[24];
     last_hs<=head_hs;
     if(last_hs&&!head_hs)fill_done<=0;
     rp<=rp+5'd1;
    end
   end
  end
 end
endmodule
