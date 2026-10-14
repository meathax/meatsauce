module t48_probe_top(
 input wire clk,reset,load_we,input wire [9:0] load_addr,input wire [7:0] load_data,
 input wire command_valid,command_read,input wire [7:0] command_addr,command_data,
 input wire [1:0] coins_n,
 output wire main_halt,irq2,shared_write,flip,bus_event,control_event,
 output wire [7:0] shared_addr,shared_data,bus_data,control,
 output wire [11:0] program_addr,output wire [31:0] oscillator_ticks,core_ticks
);
 reg [7:0] firmware[0:1023];reg [7:0] program_data=0;
 always @(posedge clk) begin
   if(load_we) firmware[load_addr]<=load_data;
   program_data<=firmware[program_addr[9:0]];
 end
 alpha68kn_mcu mcu(.clk(clk),.reset(reset),.pause_game(1'b0),.*);
endmodule
