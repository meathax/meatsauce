// SPDX-License-Identifier: GPL-3.0-or-later
// Conditional shared-clock connection; CPU_WR_RD is explicit external stimulus.
module cpu_dram_service_qualification (
 input wire clk, reset, cpu_wr_rd_level,
 input wire [7:0] rom_data,
 input wire [4:0] physical_h_byte,
 input wire [7:0] physical_v,
 output wire [15:0] address,
 output wire [7:0] dout, status, captured_data, do_data,
 output wire sync, dbin, wr_n, waiting, ready, ramstb_n, ststb,
 output wire hread_n, rdy_in, first_capture, phi1_ttl, phi3_ttl,
 output wire [4:0] phase,
 output wire [3:0] phase_4i,
 output wire raw_ras_n, raw_cas_n, comadr_n, ras_n, cas_n, we_n,
 output wire [1:0] mux_selector,
 output wire [6:0] mux_address,
 output wire do_valid, read_event, write_event, ignored_cas_event, unsupported_event,
 output reg [13:0] committed_address, requested_read_address,
 output reg [15:0] committed_cpu_address,
 output reg [7:0] committed_data,
 output reg committed_cpu_wr_n
);
 wire read_start, write_start, ack, inte;
 wire [7:0] delay_4a;
 n8080_cpu_ready cpu(.clk(clk),.reset(reset),.pause(1'b0),.ready(ready),
  .din(address[14] ? captured_data : rom_data),.irq(1'b0),
  .address(address),.dout(dout),.status(status),.inte(inte),.sync(sync),
  .dbin(dbin),.wr_n(wr_n),.read_start(read_start),.write_start(write_start),
  .interrupt_ack(ack),.wait_debug(waiting),.phase_debug(phase));
 assign phi1_ttl=!(phase<5);
 assign phi3_ttl=(phase<8 || phase>=13);
 // Retain the previous service fixture's named, rounded crystal projection.
 wire ce_xtal=(phase==2 || phase==4 || phase==7 || phase==9 || phase==12 ||
               phase==14 || phase==17 || phase==19 || phase==22 || phase==24);
 n8080_memory_phases slots(.clk(clk),.reset(reset),.ce_xtal(ce_xtal),
  .raw_ras_n(raw_ras_n),.raw_cas_n(raw_cas_n),.comadr_n(comadr_n),
  .hread_n(hread_n),.phase_4i(phase_4i),.delay_4a(delay_4a));
 wire unused_disable, unused_predicate;
 n8080_dram_control control(.cpu_wr_rd_level(cpu_wr_rd_level),
  .cpu_address(address),.cpu_wr_n(wr_n),.cpu_sync(sync),.phi1_ttl(phi1_ttl),
  .physical_h_byte(physical_h_byte),.physical_v(physical_v),
  .raw_cas_n(raw_cas_n),.raw_ras_n(raw_ras_n),.comadr_n(comadr_n),.hread_n(hread_n),
  .mux_selector(mux_selector),.mux_address(mux_address),
  .dram_cas_n(cas_n),.dram_ras_n(ras_n),.dram_we_n(we_n),
  .ststb(ststb),.ramstb_n(ramstb_n),.disable_level(unused_disable),
  .write_predicate(unused_predicate));
 n8080_dram_storage storage(.clk(clk),.reset(reset),.ras_n(ras_n),.cas_n(cas_n),
  .we_n(we_n),.mux_address(mux_address),.di(dout),.do_data(do_data),.do_valid(do_valid),
  .read_event(read_event),.write_event(write_event),
  .ignored_cas_event(ignored_cas_event),.unsupported_event(unsupported_event));
 n8080_ram_readback service(.clk(clk),.reset(reset),.ramstb_n(ramstb_n),
  .hread_n(hread_n),.phi1_ttl(phi1_ttl),.phi3_ttl(phi3_ttl),.rd(do_data),
  .captured_data(captured_data),.first_capture(first_capture),.rdy_in(rdy_in),.ready(ready));
 // Diagnostic observation only: never force or bypass a storage transaction.
 always @(posedge clk) begin
  if(reset) begin
   committed_address<=0;requested_read_address<=0;committed_data<=0;
   committed_cpu_address<=0;committed_cpu_wr_n<=1;
  end else begin
   if(storage.memory_write) begin
    committed_address<=storage.memory_address;committed_data<=dout;
    committed_cpu_address<=address;committed_cpu_wr_n<=wr_n;
   end
   if(storage.memory_read) requested_read_address<=storage.memory_address;
  end
 end
endmodule
