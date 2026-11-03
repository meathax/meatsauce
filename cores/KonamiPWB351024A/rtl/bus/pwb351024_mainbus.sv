// PWB351024A main map, following MAME 0.289 mainevt.cpp.
// ce_bus marks a completed Q bus cycle. Deassert while cpu_ok is low.
module pwb351024_mainbus(
 input wire clk,reset,profile_devstors,ce_bus,ce_12m,
 input wire [15:0] cpu_addr,input wire [7:0] cpu_dout,
 input wire cpu_rnw,cpu_valid,output reg [7:0] cpu_din,
 output wire cpu_ok,
 output wire [15:0] rom_addr,input wire [7:0] rom_data,input wire rom_ok,
 output wire vid_cs,vid_wr,output wire [13:0] vid_addr,
 output wire [7:0] vid_dout,input wire [7:0] vid_din,input wire vid_ok,
 output wire rmrd,output wire pal_wr,output wire [8:0] pal_addr,
 output wire [7:0] pal_data,input wire [7:0] pal_din,
 input wire [7:0] in_system,in_p1,in_p2,in_p3,in_p4,dsw1,dsw2,dsw3,
 input wire tile_irq,vblank,output wire irq,nmi,
 output reg [7:0] sound_latch,output reg sound_irq,
 output reg [7:0] coin_lamps,output wire watchdog_access,
 input wire state_req,state_we,state_pause_ack,input wire [15:0] state_addr,input wire [7:0] state_din,
 output wire [7:0] state_dout,output wire state_grant
);
 wire [7:0] ram_dout;
 // Borrow only the real work RAM, after an acknowledged and observed quiet bus.
 reg [1:0] state_quiet=0;
 wire state_valid=state_addr>=16'h4000 && state_addr<16'h5e00;
 always @(posedge clk)begin
  if(reset||!state_pause_ack||ce_bus)state_quiet<=0;
  else state_quiet<={state_quiet[0],1'b1};
 end
 assign state_grant=state_req && state_pause_ack && (&state_quiet) && !ce_bus && !reset && state_valid;
 reg [7:0] bank_reg;
 wire rd=cpu_rnw,wr=!cpu_rnw;
 wire [15:0] a=cpu_addr;
 wire io_bank=(a==16'h1f80),io_latch=(a==16'h1f84),io_irq=(a==16'h1f88);
 wire io_wdog=(a==16'h1f8c),io_coin=(a==16'h1f90);
 wire io_inputs=(a>=16'h1f94 && a<=16'h1f98) || a==16'h1f9b ||
                (!profile_devstors && (a==16'h1f99 || a==16'h1f9a));
 wire math_cs=profile_devstors && a>=16'h1fa0 && a<=16'h1fbf;
 // Read and write decode independently: write-only registers retain video reads,
 // and read-only input ports retain video writes in the MAME address map.
 wire vid_read=a<16'h4000 && !io_wdog && !io_inputs && !math_cs;
 wire vid_write=a<16'h4000 && !io_bank && !io_latch && !io_irq && !io_wdog && !io_coin && !math_cs;
 wire rom_cs=a>=16'h6000;
 wire ram_cs=a>=16'h4000 && a<16'h5e00;
 wire pal_cs=a>=16'h5e00 && a<16'h6000;
 assign vid_cs=cpu_valid && (rd?vid_read:vid_write);
 assign cpu_ok=!cpu_valid ? 1'b1:vid_cs ? vid_ok:(rom_cs && rd) ? rom_ok:1'b1;
 wire accept=ce_bus && cpu_valid && cpu_ok;
 // Unchanged SPY/JTFRAME synchronous true-dual-port donor, also used by video.
 // Only 7680 bytes are decoded; physical depth rounds to 8192 bytes.
 // The CPU holds each address for 8+ sys clocks before its consuming E edge.
 jtframe_dual_ram_cen #(.AW(13)) u_work(
  .clk0(clk),.cen0(1'b1),.addr0(a[12:0]),.data0(cpu_dout),
  .we0(accept && wr && ram_cs && !reset),.q0(ram_dout),
  .clk1(clk),.cen1(state_grant),.addr1(state_addr[12:0]),.data1(state_din),
  .we1(state_we),.q1(state_dout));
 assign vid_wr=accept && wr && vid_write;
 assign vid_addr=a[13:0]; assign vid_dout=cpu_dout;
 assign rom_addr=a[15] ? a:{1'b0,bank_reg[1:0],a[12:0]};
 assign rmrd=bank_reg[6];
 assign pal_wr=accept && wr && pal_cs;
 assign pal_addr=a[8:0]; assign pal_data=cpu_dout;
 assign irq=tile_irq;
 assign watchdog_access=accept && io_wdog;
 wire [7:0] math_data; wire math_nmi;
 (* dont_retime *) reg [7:0] math_read_data;
 // K051733 reads clock its LFSR. Capture the returned pre-access byte at Q
 // before that side effect, and hold this transaction's value until CPU E.
 always @(posedge clk) begin
  if(reset) math_read_data<=0;
  else if(accept && math_cs && rd) math_read_data<=math_data;
 end
 pwb_k051733 math(.clk(clk),.reset(reset),.ce_12m(ce_12m),.vblank(vblank),
  .access(accept && math_cs),.wr(wr),.addr(a[4:0]),.din(cpu_dout),
  .dout(math_data),.nmi(math_nmi));
 assign nmi=profile_devstors && math_nmi;
 always @(posedge clk) begin
  sound_irq<=0;
  if(reset) begin bank_reg<=0;sound_latch<=0;coin_lamps<=0;end
  else if(accept && wr) begin
   if(io_bank) bank_reg<=cpu_dout;
   if(io_latch) sound_latch<=cpu_dout;
   if(io_irq) sound_irq<=1;
   if(io_coin) coin_lamps<=cpu_dout;
  end
 end
 always @* begin
  cpu_din=8'hff;
  if(rom_cs) cpu_din=rom_data;
  else if(ram_cs) cpu_din=ram_dout;
  else if(pal_cs) cpu_din=pal_din;
  else if(math_cs) cpu_din=math_read_data;
  else if(io_wdog) cpu_din=8'hff;
  else if(io_inputs) case(a[3:0])
   4:cpu_din=in_system;5:cpu_din=in_p1;6:cpu_din=in_p2;7:cpu_din=dsw1;
   8:cpu_din=dsw3;9:cpu_din=in_p3;10:cpu_din=in_p4;11:cpu_din=dsw2;
   default:cpu_din=8'hff;
  endcase
  else if(vid_read) cpu_din=vid_din;
 end
endmodule
