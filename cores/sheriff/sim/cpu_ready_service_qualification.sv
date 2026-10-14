// SPDX-License-Identifier: GPL-2.0-or-later
// Conditional synthetic shared clock projection; no physical DRAM timing claim.
module cpu_ready_service_qualification(
 input wire clk,reset,
 input wire [7:0] bus_data,
 output wire [15:0] address,
 output wire [7:0] dout,status,captured_data,
 output wire sync,dbin,wr_n,waiting,ready,ramstb_n,ststb,hread_n,rdy_in,first_capture,
 output wire phi1_ttl,phi3_ttl,
 output wire [4:0] phase,
 output wire [3:0] phase_4i
);
 wire read_start,write_start,ack,inte;
 n8080_cpu_ready cpu(.clk(clk),.reset(reset),.pause(1'b0),.ready(ready),
  .din(address[14] ? captured_data : bus_data),.irq(1'b0),
  .address(address),.dout(dout),.status(status),.inte(inte),.sync(sync),.dbin(dbin),.wr_n(wr_n),
  .read_start(read_start),.write_start(write_start),.interrupt_ack(ack),.wait_debug(waiting),.phase_debug(phase));
 assign phi1_ttl=!(phase<5);
 assign phi3_ttl=(phase<8 || phase>=13);
 assign ststb=sync && !phi1_ttl;
 assign ramstb_n=!(address[14] && ststb);
 // Rising crystal edges land at post-edge CPU phases3,5,8,10,13,15,18,20,23,0.
 wire ce_xtal=(phase==2 || phase==4 || phase==7 || phase==9 || phase==12 ||
               phase==14 || phase==17 || phase==19 || phase==22 || phase==24);
 n8080_memory_phases slots(.clk(clk),.reset(reset),.ce_xtal(ce_xtal),
  .raw_cas_n(),.raw_ras_n(),.comadr_n(),.hread_n(hread_n),.phase_4i(phase_4i),.delay_4a());
 n8080_ram_readback service(.clk(clk),.reset(reset),.ramstb_n(ramstb_n),
  .hread_n(hread_n),.phi1_ttl(phi1_ttl),.phi3_ttl(phi3_ttl),.rd(bus_data),
  .captured_data(captured_data),.first_capture(first_capture),.rdy_in(rdy_in),.ready(ready));
endmodule
