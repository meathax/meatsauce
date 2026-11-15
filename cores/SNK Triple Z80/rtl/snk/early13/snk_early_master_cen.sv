// SPDX-License-Identifier: GPL-3.0-or-later
// Positive-master-edge adaptation of the pinned RndMnkIII source phases.
// Runs only on the 93.8 MHz early PLL setting (= 7 x 13.4 MHz board crystal): 13.4 MHz = clk/7 (3/4 event pattern),
// 6.7 MHz = clk/14 and 3.35 MHz = clk/28 exactly; 4/3.36/2/8 MHz are n/m accumulators.
module snk_early_master_cen #(parameter integer CLK_HZ=93800000,parameter integer VIDEO_LOCK=0)(
 input wire i_clk,
 input wire aso_grid, // VIDEO_LOCK only: ASO 416-pixel donor line instead of the HSJ/TNK3 414-pixel line
 output reg clk_13p4_cen=0,clk_13p4=0,clk_13p4b_cen=0,clk_13p4b=0,
 output reg clk_6p7_cen=0,clk_6p7b_cen=0,clk_3p35_cen=0,clk_3p35b_cen=0,
 output reg clk_4_cen=0,clk_4b_cen=0,
 output reg clk_3p36_cen=0,clk_3p36b_cen=0,clk_2_cen=0,clk_8_cen=0,
 output reg group_b_pixel_cen=0
);
 // The residue modulo gcd is constant; quotient carries are identical.
 function integer clock_gcd(input integer a,input integer b);
  integer rem; begin
   while(b!=0)begin rem=a%b;a=b;b=rem;end
   clock_gcd=a;
  end
 endfunction
  // Real-PCB frame rate (Jumping Cross footage, 2026-10-21): the in-game TIME
  // counts 6 vblanks per 0.1 s (MAME RAM D8E3), and the PCB stream advances it
  // at 1.02358 timer-s per real s -> 61.416 Hz (two segments, 61.407/61.422).
  // MAME's 60 Hz is a guess. Group-B (wave family) pixel is the 13.4 MHz-family
  // clk/14 (6.7 MHz at 93.8 MHz); with the 416x262 raster in
  // snk_early_group_b_raster that is 61.472 Hz. CE on i_clk, not a clock.
  localparam integer PIXEL_DIV=14;
  reg [$clog2(PIXEL_DIV)-1:0] pixel_cnt=0;
  // 13.4 MHz-family time base (2 x 13.4 MHz board crystal, exact on the 93.8 MHz PLL setting).
  localparam integer FAST_HZ=26800000;
 localparam integer SOUND_P=(CLK_HZ/67)*65+((CLK_HZ%67)*65)/67;
 localparam integer SOUND_N=(CLK_HZ/67)*31+((CLK_HZ%67)*31)/67;
 reg [2:0] fast_phase=0;reg wave_cpu_phase=0;
 localparam integer FAST_G=clock_gcd(CLK_HZ,FAST_HZ);
 localparam integer FAST_D=CLK_HZ/FAST_G;
 localparam integer FAST_W_FREE=$clog2(FAST_D)>0?$clog2(FAST_D):1;
 localparam integer FAST_W=VIDEO_LOCK ? 10 : FAST_W_FREE;
 localparam [FAST_W:0] FAST_LIMIT_FREE=FAST_D;
 localparam [FAST_W:0] FAST_STEP_FREE=FAST_HZ/FAST_G;
 // VIDEO_LOCK: video time base on an exact 416-pixel output line (416 x 14 = 5824 clk at 93.8 MHz, 61.47 Hz at 262
 // lines) so the constant-width output retimer re-emits each line at 14 clk/pixel. 4 fast events per pixel.
 // ASO donor line = 416 px = 1664 events in 5824 clk = 2/7: exactly the free 26.8 MHz grid (retimer fill 0).
 // HSJ/TNK3-class donor line = 414 px = 1656 events in 5824 clk = 207/728 (identical pattern every line; retimer fill 2).
 wire [FAST_W:0] FAST_LIMIT=VIDEO_LOCK ? (aso_grid ? 7 : 728) : FAST_LIMIT_FREE;
 wire [FAST_W:0] FAST_STEP=VIDEO_LOCK ? (aso_grid ? 2 : 207) : FAST_STEP_FREE;
 reg [FAST_W-1:0] fast_acc=VIDEO_LOCK ? 0 : (CLK_HZ-FAST_HZ)/FAST_G;
 wire [FAST_W:0] fast_sum={1'b0,fast_acc}+FAST_STEP;
 wire [FAST_W:0] fast_residue=fast_sum-FAST_LIMIT;
 localparam integer SOUND_P_G=clock_gcd(CLK_HZ,4000000);
 localparam integer SOUND_P_D=CLK_HZ/SOUND_P_G;
 localparam integer SOUND_P_W=$clog2(SOUND_P_D)>0?$clog2(SOUND_P_D):1;
 localparam [SOUND_P_W:0] SOUND_P_LIMIT=SOUND_P_D;
 localparam [SOUND_P_W:0] SOUND_P_STEP=4000000/SOUND_P_G;
 reg [SOUND_P_W-1:0] sound_p_acc=(SOUND_P)/SOUND_P_G;
 wire [SOUND_P_W:0] sound_p_sum={1'b0,sound_p_acc}+SOUND_P_STEP;
 wire [SOUND_P_W:0] sound_p_residue=sound_p_sum-SOUND_P_LIMIT;
 localparam integer SOUND_N_G=clock_gcd(CLK_HZ,4000000);
 localparam integer SOUND_N_D=CLK_HZ/SOUND_N_G;
 localparam integer SOUND_N_W=$clog2(SOUND_N_D)>0?$clog2(SOUND_N_D):1;
 localparam [SOUND_N_W:0] SOUND_N_LIMIT=SOUND_N_D;
 localparam [SOUND_N_W:0] SOUND_N_STEP=4000000/SOUND_N_G;
 reg [SOUND_N_W-1:0] sound_n_acc=(SOUND_N)/SOUND_N_G;
 wire [SOUND_N_W:0] sound_n_sum={1'b0,sound_n_acc}+SOUND_N_STEP;
 wire [SOUND_N_W:0] sound_n_residue=sound_n_sum-SOUND_N_LIMIT;
 localparam integer WAVE_CPU_G=clock_gcd(CLK_HZ,6720000);
 localparam integer WAVE_CPU_D=CLK_HZ/WAVE_CPU_G;
 localparam integer WAVE_CPU_W=$clog2(WAVE_CPU_D)>0?$clog2(WAVE_CPU_D):1;
 localparam [WAVE_CPU_W:0] WAVE_CPU_LIMIT=WAVE_CPU_D;
 localparam [WAVE_CPU_W:0] WAVE_CPU_STEP=6720000/WAVE_CPU_G;
 reg [WAVE_CPU_W-1:0] wave_cpu_acc=(CLK_HZ-6720000)/WAVE_CPU_G;
 wire [WAVE_CPU_W:0] wave_cpu_sum={1'b0,wave_cpu_acc}+WAVE_CPU_STEP;
 wire [WAVE_CPU_W:0] wave_cpu_residue=wave_cpu_sum-WAVE_CPU_LIMIT;
 localparam integer AY_G=clock_gcd(CLK_HZ,2000000);
 localparam integer AY_D=CLK_HZ/AY_G;
 localparam integer AY_W=$clog2(AY_D)>0?$clog2(AY_D):1;
 localparam [AY_W:0] AY_LIMIT=AY_D;
 localparam [AY_W:0] AY_STEP=2000000/AY_G;
 reg [AY_W-1:0] ay_acc=(0)/AY_G;
 wire [AY_W:0] ay_sum={1'b0,ay_acc}+AY_STEP;
 wire [AY_W:0] ay_residue=ay_sum-AY_LIMIT;
 localparam integer WAVE_G=clock_gcd(CLK_HZ,8000000);
 localparam integer WAVE_D=CLK_HZ/WAVE_G;
 localparam integer WAVE_W=$clog2(WAVE_D)>0?$clog2(WAVE_D):1;
 localparam [WAVE_W:0] WAVE_LIMIT=WAVE_D;
 localparam [WAVE_W:0] WAVE_STEP=8000000/WAVE_G;
 reg [WAVE_W-1:0] wave_acc=(0)/WAVE_G;
 wire [WAVE_W:0] wave_sum={1'b0,wave_acc}+WAVE_STEP;
 wire [WAVE_W:0] wave_residue=wave_sum-WAVE_LIMIT;
 always @(posedge i_clk)begin
   group_b_pixel_cen<=pixel_cnt==PIXEL_DIV-1;
   pixel_cnt<=pixel_cnt==PIXEL_DIV-1?0:pixel_cnt+1'b1;
  clk_13p4_cen<=0;clk_13p4b_cen<=0;clk_6p7_cen<=0;clk_6p7b_cen<=0;clk_3p35_cen<=0;clk_3p35b_cen<=0;
  if(fast_sum>=FAST_LIMIT)begin
   fast_acc<=fast_residue[FAST_W-1:0];fast_phase<=fast_phase+1'b1;
   clk_13p4b_cen<=!fast_phase[0];clk_13p4_cen<=fast_phase[0];
   clk_6p7_cen<=fast_phase[1:0]==0;clk_6p7b_cen<=fast_phase[1:0]==2;
   clk_3p35_cen<=fast_phase==0;clk_3p35b_cen<=fast_phase==4;
  end else fast_acc<=fast_sum[FAST_W-1:0];
  // Preserve the accepted source's two identical phase-level outputs.
  if(clk_13p4_cen||clk_13p4b_cen)begin clk_13p4<=~clk_13p4;clk_13p4b<=~clk_13p4b;end
  clk_4_cen<=sound_p_sum>=SOUND_P_LIMIT;sound_p_acc<=sound_p_sum>=SOUND_P_LIMIT?sound_p_residue[SOUND_P_W-1:0]:sound_p_sum[SOUND_P_W-1:0];
  clk_4b_cen<=sound_n_sum>=SOUND_N_LIMIT;sound_n_acc<=sound_n_sum>=SOUND_N_LIMIT?sound_n_residue[SOUND_N_W-1:0]:sound_n_sum[SOUND_N_W-1:0];
  clk_3p36_cen<=0;clk_3p36b_cen<=0;
  if(wave_cpu_sum>=WAVE_CPU_LIMIT)begin
   wave_cpu_acc<=wave_cpu_residue[WAVE_CPU_W-1:0];wave_cpu_phase<=~wave_cpu_phase;
   clk_3p36_cen<=!wave_cpu_phase;clk_3p36b_cen<=wave_cpu_phase;
  end else wave_cpu_acc<=wave_cpu_sum[WAVE_CPU_W-1:0];
  clk_2_cen<=ay_sum>=AY_LIMIT;ay_acc<=ay_sum>=AY_LIMIT?ay_residue[AY_W-1:0]:ay_sum[AY_W-1:0];
  clk_8_cen<=wave_sum>=WAVE_LIMIT;wave_acc<=wave_sum>=WAVE_LIMIT?wave_residue[WAVE_W-1:0]:wave_sum[WAVE_W-1:0];
 end
endmodule

// Gate a synchronous CE without allowing a pause/resume edge to shorten its
// legal spacing. Cooldown intentionally survives core reset and counts during
// pause; missed events are dropped because the downstream CPU/chip is held.
module snk_early_cen_guard #(parameter integer MIN_SPACING=1)(
 input wire clk,
 input wire run_enable,
 input wire raw_ce,
 output reg ce=0
);
 localparam integer COUNT_W=$clog2(MIN_SPACING+1)>0?$clog2(MIN_SPACING+1):1;
 localparam [COUNT_W-1:0] RELOAD=MIN_SPACING-1;
 reg [COUNT_W-1:0] cooldown=0;
 always @(posedge clk)begin
  ce<=0;
  if(cooldown!=0)cooldown<=cooldown-1'b1;
  if(run_enable && raw_ce && cooldown==0)begin
   ce<=1;
   cooldown<=RELOAD;
  end
 end
endmodule
