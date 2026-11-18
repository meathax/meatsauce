// Real Intel 8748 execution; one 48MHz master clock and oscillator enables.
module alpha68kn_mcu (
 input wire clk,reset,pause_game,
 output wire [11:0] program_addr,input wire [7:0] program_data,
 input wire command_valid,command_read,input wire [7:0] command_addr,command_data,
 input wire [1:0] coins_n,
 output reg main_halt=0,output reg irq2=0,shared_write=0,
 output reg [7:0] shared_addr=0,shared_data=0,output reg flip=0,
 output reg [7:0] bus_data=0,control=0,
 output reg bus_event=0,control_event=0,
 output reg [31:0] oscillator_ticks=0,core_ticks=0
);
 reg [25:0] oscillator_fraction=0;
 wire [26:0] oscillator_sum={1'b0,oscillator_fraction}+27'd9263750;
 wire oscillator_ce=!reset && !pause_game && oscillator_sum>=27'd48000000;
 wire core_ce;
 wire [7:0] ram_addr,ram_out,db_out,p2_out;
 wire ram_we,bus_we,p2_we,psen_n;
 reg [7:0] ram[0:63]; reg [5:0] ram_read_addr=0;
 integer n;
 initial for(n=0;n<64;n=n+1) ram[n]=0;
 // Matches the donor 8048 RAM: six-bit address, registered read address.
 always @(posedge clk) begin
   ram_read_addr<=ram_addr[5:0];
   if(ram_we && !reset && !pause_game) ram[ram_addr[5:0]]<=ram_out;
 end
 reg interrupt_pending=0,read_mode=0;
 reg [7:0] address_latch=0;
 reg bus_pending=0,p2_pending=0;
 wire [7:0] p2_latched;
  wire [7:0] effective_control=p2_pending ? p2_latched : control;
 always @(posedge clk) begin
   irq2<=0;shared_write<=0;bus_event<=0;control_event<=0;
   if(reset) begin
     oscillator_fraction<=0;oscillator_ticks<=0;core_ticks<=0;
     interrupt_pending<=0;main_halt<=0;read_mode<=0;address_latch<=0;
     bus_data<=0;control<=0;flip<=0;bus_pending<=0;p2_pending<=0;
   end else if(!pause_game) begin
     if(oscillator_ce) oscillator_fraction<=oscillator_sum-27'd48000000;
     else oscillator_fraction<=oscillator_sum[25:0];
     if(oscillator_ce) oscillator_ticks<=oscillator_ticks+1'b1;
     if(core_ce) core_ticks<=core_ticks+1'b1;
     // Observe BUS pins and the committed P2 latch one master tick after the real decoder write.
     bus_pending<=bus_we;p2_pending<=p2_we;
     if(bus_pending) begin bus_data<=db_out;bus_event<=1;end
     if(p2_pending) begin
       control<=p2_latched;control_event<=1;
       if(!p2_latched[4]) begin interrupt_pending<=0;main_halt<=0;end
       if(p2_latched[5]) irq2<=1;
       if(!p2_latched[6]) begin shared_write<=1;shared_addr<=address_latch;shared_data<=bus_data;end
       flip<=!p2_latched[7];
     end
     if(command_valid) begin
       address_latch<=command_addr;read_mode<=command_read;
       bus_data<=command_read ? 8'hff : command_data;
       if(effective_control[4]) begin interrupt_pending<=1;main_halt<=1;end
     end
   end
 end
 t48_core cpu(
   .xtal_i(clk),.xtal_en_i(oscillator_ce),.reset_i(!reset),
   .clk_i(clk),.en_clk_i(core_ce),.xtal3_o(core_ce),
   .int_n_i(!interrupt_pending),.t0_i(coins_n[0]),.t1_i(coins_n[1]),
   .ea_i(|program_addr[11:10]),.db_i(psen_n ? bus_data : 8'hff),
   .p1_i(address_latch),.p2_i(read_mode ? 8'hff : 8'hf7),
   .dmem_addr_o(ram_addr),.dmem_we_o(ram_we),.dmem_data_o(ram_out),
   .dmem_data_i(ram[ram_read_addr]),.pmem_addr_o(program_addr),.pmem_data_i(program_data),
   .db_o(db_out),.p2_o(p2_out),.psen_n_o(psen_n),
   .alpha_bus_write_o(bus_we),.alpha_p2_write_o(p2_we),.alpha_p2_latch_o(p2_latched),
   .t0_o(),.t0_dir_o(),.rd_n_o(),.wr_n_o(),.ale_o(),.db_dir_o(),
   .p2l_low_imp_o(),.p2h_low_imp_o(),.p1_o(),.p1_low_imp_o(),.prog_n_o()
 );
endmodule
