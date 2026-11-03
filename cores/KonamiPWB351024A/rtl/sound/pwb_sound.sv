// 48 MHz master, asynchronous ROM request/ready transports. All inputs synchronous.
module pwb_sound(
 input logic clk,reset,pause,profile_mainevt,
 input logic [7:0] main_latch,input logic main_irq,line_start,
 input logic [8:0] scanline,
 output wire rom_req,output wire [14:0] rom_addr,
 input logic [7:0] rom_data,input logic rom_ok,
 output wire pcm_req,output wire [18:0] pcm_addr,
 input logic [7:0] pcm_data,input logic pcm_ok,
 output wire upd_req,output wire [18:0] upd_addr,
 input logic [7:0] upd_data,input logic upd_ok,
 output logic signed [15:0] audio,audio_l,audio_r,
 output logic sample_valid,
 output wire debug_wr,debug_rd,output wire [15:0] debug_addr,
 output wire [7:0] debug_data,debug_banks,
 output wire debug_irq_n,debug_nmi_n,output logic debug_clip,output wire debug_cen
);
 logic [25:0] fraction;
 wire [26:0] next_fraction={1'b0,fraction}+27'd3579545;
 wire [26:0] wrapped_fraction=next_fraction-27'd48000000;
 wire ce=next_fraction>=27'd48000000&&!pause;
 logic half_phase;
 logic [12:0] reset_count;
 wire sound_reset=reset||(reset_count!=0);
 logic [6:0] upd_div;
 wire upd_ce=upd_div==74&&!pause;
 assign debug_cen=ce;
 always_ff @(posedge clk) begin
   if(reset)begin fraction<=0;half_phase<=0;upd_div<=0;reset_count<=4096;end
   else if(!pause)begin
     if(reset_count!=0)reset_count<=reset_count-1'b1;
     fraction<=ce?wrapped_fraction[25:0]:next_fraction[25:0];
     if(ce)half_phase<=!half_phase;
     upd_div<=upd_ce?7'd0:upd_div+1'b1;
   end
 end
 wire [15:0] cpu_addr;
 wire [7:0] cpu_din,cpu_dout,ym_data,upd_command,irq_control;
 wire mreq_n,iorq_n,m1_n,rd_n,wr_n,wait_n;
 wire ym_cs,ym_wr,pcm_cs,pcm_wr,ym_sample,upd_busyn;
 wire signed [15:0] ym_l,ym_r;
 wire signed [10:0] pcm_a,pcm_b;
 wire signed [8:0] upd_audio;
 wire [16:0] upd_local_addr;
 assign debug_addr=cpu_addr;
 assign debug_data=cpu_dout;
 T80s u_cpu(.RESET_n(!sound_reset),.CLK(clk),.CEN(ce),.WAIT_n(wait_n),
   .INT_n(debug_irq_n),.NMI_n(debug_nmi_n),.BUSRQ_n(1'b1),.OUT0(1'b0),
   .DI(cpu_din),.M1_n(m1_n),.MREQ_n(mreq_n),.IORQ_n(iorq_n),
   .RD_n(rd_n),.WR_n(wr_n),.RFSH_n(),.HALT_n(),.BUSAK_n(),.A(cpu_addr),.DOUT(cpu_dout));
 pwb_sound_bus u_bus(.clk(clk),.reset(sound_reset),.irq_reset(reset),.pause(pause),.profile_mainevt(profile_mainevt),.cen(ce),
   .cpu_addr(cpu_addr),.cpu_dout(cpu_dout),.mreq_n(mreq_n),.iorq_n(iorq_n),.m1_n(m1_n),
   .rd_n(rd_n),.wr_n(wr_n),.cpu_din(cpu_din),.wait_n(wait_n),
   .main_latch(main_latch),.main_irq(main_irq),.line_start(line_start),.scanline(scanline),
   .irq_n(debug_irq_n),.nmi_n(debug_nmi_n),.rom_req(rom_req),.rom_addr(rom_addr),
   .rom_data(rom_data),.rom_ok(rom_ok),.ym_data(ym_data),.upd_busyn(upd_busyn),
   .ym_cs(ym_cs),.ym_wr(ym_wr),.pcm_cs(pcm_cs),.pcm_wr(pcm_wr),.banks(debug_banks),
   .upd_command(upd_command),.irq_control(irq_control),.debug_wr(debug_wr),.debug_rd(debug_rd));
 jt51 u_ym(.rst(sound_reset||profile_mainevt),.clk(clk),.cen(ce),.cen_p1(ce&&half_phase),
   .cs_n(!ym_cs),.wr_n(!ym_wr),.a0(cpu_addr[0]),.din(cpu_dout),.dout(ym_data),
   .ct1(),.ct2(),.irq_n(),.sample(ym_sample),.left(ym_l),.right(ym_r),.xleft(),.xright());
 spy_pcm #(.BLOCK_ROM(0)) u_pcm(.clk(clk),.reset(sound_reset),.pause(pause),.cen(ce),
   .cs(pcm_cs&&(debug_rd||debug_wr)),.wr(pcm_wr),.addr(cpu_addr[3:0]),.din(cpu_dout),
   .bank_a(debug_banks[1:0]),.bank_b(debug_banks[3:2]),.rom_req(pcm_req),.rom_addr(pcm_addr),
   .rom_data(pcm_data),.rom_block(32'd0),.rom_ok(pcm_ok),.snda(pcm_a),.sndb(pcm_b));
 pwb_upd7759 u_upd(.rst(sound_reset||!profile_mainevt||!irq_control[1]),.clk(clk),.cen(upd_ce),
   .stn(!irq_control[0]),.cs(1'b1),.mdn(1'b1),.busyn(upd_busyn),.wrn(1'b1),
   .din(upd_command),.drqn(),.rom_cs(upd_req),.rom_addr(upd_local_addr),
   .rom_data(upd_data),.rom_ok(upd_ok),.sound(upd_audio));
 assign upd_addr={debug_banks[5:4],upd_local_addr};
  pwb_sound_mixer u_mixer(.clk(clk),.reset(reset),.pause(pause),.profile_mainevt(profile_mainevt),
    .pcm_a(pcm_a),.pcm_b(pcm_b),.ym_l(ym_l),.ym_r(ym_r),.upd_audio(upd_audio),
    .audio(audio),.audio_l(audio_l),.audio_r(audio_r),.sample_valid(sample_valid),.debug_clip(debug_clip));
endmodule

// The board audio stream is sampled once per 1000 master clocks.  Snapshot
// every source at that edge, then carry it through a full-rate mixer pipeline.
// The pipeline changes only output latency; it does not feed any sound bus,
// IRQ, CPU, or video state.
module pwb_sound_mixer(
  input  logic clk,reset,pause,profile_mainevt,
  input  logic signed [10:0] pcm_a,pcm_b,
  input  logic signed [15:0] ym_l,ym_r,
  input  logic signed [8:0] upd_audio,
  output logic signed [15:0] audio,audio_l,audio_r,
  output logic sample_valid,debug_clip
);
  logic [9:0] sample_div;
  wire sample_tick=!pause&&(sample_div==10'd999);

  logic valid0,valid1,valid2,valid3,valid4,valid5,valid6,valid7,valid8,valid9;
  logic signed [10:0] pcm_a0,pcm_b0;
  logic signed [15:0] ym_l0,ym_r0;
  logic signed [8:0] upd0,upd1,upd2,upd3,upd4,upd5,upd6,upd7,upd8;
  logic profile0,profile1,profile2,profile3,profile4,profile5,profile6,profile7,profile8;

  logic signed [18:0] pcm_num1,ym_num1;
  logic [18:0] pcm_mag2,ym_mag2;
  logic pcm_sign2,ym_sign2;

  logic [14:0] pcm_low3,ym_low3;
  logic [3:0] pcm_rem3,ym_rem3;
  logic [3:0] pcm_q3,ym_q3;
  logic pcm_sign3,ym_sign3;

  logic [10:0] pcm_low4,ym_low4;
  logic [3:0] pcm_rem4,ym_rem4;
  logic [7:0] pcm_q4,ym_q4;
  logic pcm_sign4,ym_sign4;

  logic [6:0] pcm_low5,ym_low5;
  logic [3:0] pcm_rem5,ym_rem5;
  logic [11:0] pcm_q5,ym_q5;
  logic pcm_sign5,ym_sign5;

  logic [2:0] pcm_low6,ym_low6;
  logic [3:0] pcm_rem6,ym_rem6,pcm_rem7,ym_rem7;
  logic [15:0] pcm_q6,ym_q6;
  logic pcm_sign6,ym_sign6;

  logic [18:0] pcm_q7,ym_q7;
  logic pcm_sign7,ym_sign7;
  logic signed [19:0] pcm_scaled8,ym_scaled8;
  logic signed [20:0] mixed9;

  function automatic [7:0] div10_digit;
    input [3:0] remainder_in;
    input [3:0] bits_in;
    reg [3:0] remainder;
    reg [3:0] quotient;
    reg [4:0] shifted;
    integer i;
    begin
      remainder=remainder_in;
      quotient=4'd0;
      shifted=5'd0;
      for(i=3;i>=0;i=i-1)begin
        shifted={remainder,bits_in[i]};
        if(shifted>=5'd10)begin
          remainder=shifted-5'd10;
          quotient[i]=1'b1;
        end else begin
          remainder=shifted[3:0];
        end
      end
      div10_digit={remainder,quotient};
    end
  endfunction

  function automatic [6:0] div10_last3;
    input [3:0] remainder_in;
    input [2:0] bits_in;
    reg [3:0] remainder;
    reg [2:0] quotient;
    reg [4:0] shifted;
    integer i;
    begin
      remainder=remainder_in;
      quotient=3'd0;
      shifted=5'd0;
      for(i=2;i>=0;i=i-1)begin
        shifted={remainder,bits_in[i]};
        if(shifted>=5'd10)begin
          remainder=shifted-5'd10;
          quotient[i]=1'b1;
        end else begin
          remainder=shifted[3:0];
        end
      end
      div10_last3={remainder,quotient};
    end
  endfunction

  wire [7:0] pcm_div3=div10_digit(4'd0,pcm_mag2[18:15]);
  wire [7:0] ym_div3 =div10_digit(4'd0,ym_mag2[18:15]);
  wire [7:0] pcm_div4=div10_digit(pcm_rem3,pcm_low3[14:11]);
  wire [7:0] ym_div4 =div10_digit(ym_rem3,ym_low3[14:11]);
  wire [7:0] pcm_div5=div10_digit(pcm_rem4,pcm_low4[10:7]);
  wire [7:0] ym_div5 =div10_digit(ym_rem4,ym_low4[10:7]);
  wire [7:0] pcm_div6=div10_digit(pcm_rem5,pcm_low5[6:3]);
  wire [7:0] ym_div6 =div10_digit(ym_rem5,ym_low5[6:3]);
  wire [6:0] pcm_div7=div10_last3(pcm_rem6,pcm_low6);
  wire [6:0] ym_div7 =div10_last3(ym_rem6,ym_low6);

  always_ff @(posedge clk)begin
    if(reset)begin
      sample_div<=10'd0;
      valid0<=0;valid1<=0;valid2<=0;valid3<=0;valid4<=0;
      valid5<=0;valid6<=0;valid7<=0;valid8<=0;valid9<=0;
      sample_valid<=0;audio<=0;audio_l<=0;audio_r<=0;debug_clip<=0;
    end else begin
      if(!pause)sample_div<=sample_div==10'd999 ? 10'd0 : sample_div+1'b1;
      valid0<=sample_tick;
      valid1<=valid0;valid2<=valid1;valid3<=valid2;valid4<=valid3;
      valid5<=valid4;valid6<=valid5;valid7<=valid6;valid8<=valid7;valid9<=valid8;
      sample_valid<=valid9;

      if(sample_tick)begin
        pcm_a0<=pcm_a;pcm_b0<=pcm_b;ym_l0<=ym_l;ym_r0<=ym_r;
        upd0<=upd_audio;profile0<=profile_mainevt;
      end
      if(valid0)begin
        // Preserve the board's producer-unit gains and exact numerator order.
        pcm_num1<=$signed(pcm_a0)*19'sd68+$signed(pcm_b0)*19'sd68;
        ym_num1<=$signed(ym_l0)*19'sd3+$signed(ym_r0)*19'sd3;
        upd1<=upd0;profile1<=profile0;
      end
      if(valid1)begin
        pcm_mag2<=pcm_num1[18]?-pcm_num1:pcm_num1;
        ym_mag2<=ym_num1[18]?-ym_num1:ym_num1;
        pcm_sign2<=pcm_num1[18];ym_sign2<=ym_num1[18];
        upd2<=upd1;profile2<=profile1;
      end
      if(valid2)begin
        pcm_rem3<=pcm_div3[7:4];ym_rem3<=ym_div3[7:4];
        pcm_low3<=pcm_mag2[14:0];ym_low3<=ym_mag2[14:0];
        pcm_q3<=pcm_div3[3:0];ym_q3<=ym_div3[3:0];
        pcm_sign3<=pcm_sign2;ym_sign3<=ym_sign2;
        upd3<=upd2;profile3<=profile2;
      end
      if(valid3)begin
        pcm_rem4<=pcm_div4[7:4];ym_rem4<=ym_div4[7:4];
        pcm_low4<=pcm_low3[10:0];ym_low4<=ym_low3[10:0];
        pcm_q4<={pcm_q3,pcm_div4[3:0]};ym_q4<={ym_q3,ym_div4[3:0]};
        pcm_sign4<=pcm_sign3;ym_sign4<=ym_sign3;
        upd4<=upd3;profile4<=profile3;
      end
      if(valid4)begin
        pcm_rem5<=pcm_div5[7:4];ym_rem5<=ym_div5[7:4];
        pcm_low5<=pcm_low4[6:0];ym_low5<=ym_low4[6:0];
        pcm_q5<={pcm_q4,pcm_div5[3:0]};ym_q5<={ym_q4,ym_div5[3:0]};
        pcm_sign5<=pcm_sign4;ym_sign5<=ym_sign4;
        upd5<=upd4;profile5<=profile4;
      end
      if(valid5)begin
        pcm_rem6<=pcm_div6[7:4];ym_rem6<=ym_div6[7:4];
        pcm_low6<=pcm_low5[2:0];ym_low6<=ym_low5[2:0];
        pcm_q6<={pcm_q5,pcm_div6[3:0]};ym_q6<={ym_q5,ym_div6[3:0]};
        pcm_sign6<=pcm_sign5;ym_sign6<=ym_sign5;
        upd6<=upd5;profile6<=profile5;
      end
      if(valid6)begin
        pcm_rem7<=pcm_div7[6:3];ym_rem7<=ym_div7[6:3];
        pcm_q7<={pcm_q6,pcm_div7[2:0]};ym_q7<={ym_q6,ym_div7[2:0]};
        pcm_sign7<=pcm_sign6;ym_sign7<=ym_sign6;
        upd7<=upd6;profile7<=profile6;
      end
      if(valid7)begin
        pcm_scaled8<=pcm_sign7?-$signed({1'b0,pcm_q7}):$signed({1'b0,pcm_q7});
        ym_scaled8<=ym_sign7?-$signed({1'b0,ym_q7}):$signed({1'b0,ym_q7});
        upd8<=upd7;profile8<=profile7;
      end
      if(valid8)begin
        mixed9<=$signed(pcm_scaled8)+(profile8?($signed({{12{upd8[8]}},upd8})<<<6):$signed(ym_scaled8));
      end
      if(valid9)begin
        if(mixed9>21'sd32767)begin audio<=16'sd32767;audio_l<=16'sd32767;audio_r<=16'sd32767;debug_clip<=1;end
        else if(mixed9< -21'sd32768)begin audio<=16'sh8000;audio_l<=16'sh8000;audio_r<=16'sh8000;debug_clip<=1;end
        else begin audio<=mixed9[15:0];audio_l<=mixed9[15:0];audio_r<=mixed9[15:0];debug_clip<=0;end
      end
    end
  end
endmodule
