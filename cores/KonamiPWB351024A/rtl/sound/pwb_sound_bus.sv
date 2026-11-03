// PWB351024A sound decode, MAME 0.289 mainevt.cpp sound_map and timers.
module pwb_sound_bus(
 input logic clk,reset,irq_reset,pause,profile_mainevt,cen,
 input logic [15:0] cpu_addr, input logic [7:0] cpu_dout,
 input logic mreq_n,iorq_n,m1_n,rd_n,wr_n,
 output logic [7:0] cpu_din,output wire wait_n,
 input logic [7:0] main_latch,input logic main_irq,line_start,
 input logic [8:0] scanline,output logic irq_n,nmi_n,
 output wire rom_req,output wire [14:0] rom_addr,
 input logic [7:0] rom_data,input logic rom_ok,
 input logic [7:0] ym_data,input logic upd_busyn,
 output wire ym_cs,ym_wr,pcm_cs,pcm_wr,
 output logic [7:0] banks,upd_command,irq_control,
 output wire debug_wr,debug_rd
);
 wire mem_rd=!mreq_n&&!rd_n;
 wire mem_wr=!mreq_n&&!wr_n;
 logic prev_wr,prev_rd,prev_irq;
 logic [1:0] nmi_count;
 logic [7:0] ram[0:1023];
 assign debug_wr=mem_wr&&!prev_wr&&!pause;
 assign debug_rd=mem_rd&&!prev_rd&&!pause;
 assign rom_req=mem_rd&&!cpu_addr[15];
 assign rom_addr=cpu_addr[14:0];
 assign wait_n=!(rom_req&&!rom_ok);
 assign ym_cs=!profile_mainevt&&!mreq_n&&(cpu_addr[15:1]==15'h6000);
 assign ym_wr=ym_cs&&!wr_n&&!pause;
 assign pcm_cs=!mreq_n&&(cpu_addr>=16'hb000)&&(cpu_addr<=16'hb00d)&&!pause;
 assign pcm_wr=pcm_cs&&debug_wr;
 always_comb begin
   cpu_din=8'hff;
   if(rom_req) cpu_din=rom_data;
   else if(cpu_addr>=16'h8000&&cpu_addr<=16'h83ff) cpu_din=ram[cpu_addr[9:0]];
   else if(cpu_addr==16'ha000) cpu_din=main_latch;
   else if(pcm_cs) cpu_din=0;
   else if(ym_cs) cpu_din=ym_data;
   else if(profile_mainevt&&cpu_addr==16'hd000) cpu_din={7'b0,upd_busyn};
 end
 always_ff @(posedge clk) begin
   if(reset) begin
     prev_wr<=0;prev_rd<=0;banks<=0;irq_control<=0;
     upd_command<=0;nmi_n<=1;nmi_count<=0;
   end else if(!pause) begin
     prev_wr<=mem_wr;prev_rd<=mem_rd;
     if(cen&&nmi_count!=0) begin
       nmi_count<=nmi_count-1'b1;
       if(nmi_count==1)nmi_n<=1;
     end
     if(line_start&&irq_control[2]) begin
       if(profile_mainevt&&scanline[4:0]==5'h10) begin nmi_n<=0;nmi_count<=2;end
     end
     if(debug_wr) begin
       if(cpu_addr>=16'h8000&&cpu_addr<=16'h83ff)ram[cpu_addr[9:0]]<=cpu_dout;
       if(cpu_addr==16'he000)irq_control<=cpu_dout;
       if(cpu_addr==16'hf000)banks<=cpu_dout;
       if(profile_mainevt&&cpu_addr==16'h9000)upd_command<=cpu_dout;
     end
   end
 end
 // The main CPU can command the board during the FM reset warmup. Preserve
 // that HOLD_LINE request until the Z80 eventually acknowledges it after EI.
 always_ff @(posedge clk) begin
   if(irq_reset)begin irq_n<=1;prev_irq<=0;end
   else if(!pause)begin
     prev_irq<=main_irq;
     if(!reset&&!iorq_n&&!m1_n)irq_n<=1;
     if(main_irq&&!prev_irq)irq_n<=0;
     if(!reset&&line_start&&irq_control[2]&&!profile_mainevt&&scanline[5:0]==6'h20)irq_n<=0;
   end
 end
endmodule
