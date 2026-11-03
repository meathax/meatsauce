// SPDX-License-Identifier: GPL-3.0-or-later
// All three use the pinned generated T80s.v in synthesis and simulation.
module airbustr_cpus (
 input logic clk,reset,sub_reset,cpu_cen,pause,
 input logic [2:0] cpu_rom_pending,
 output logic [2:0] cpu_rom_quiesce,cpu_bus_idle, cpu_bus_loan_safe,
 input logic main_irq,sub_irq,sub_nmi,sound_irq,sound_nmi,
 input logic [7:0] main_vector, output logic main_irq_ack, sub_irq_ack,
 output logic [2:0] cpu_req_valid, input logic [2:0] cpu_req_ready,
 output logic [2:0] cpu_req_io,cpu_req_write,
 output logic [47:0] cpu_req_addr, output logic [23:0] cpu_req_data,
 input logic [2:0] cpu_rsp_valid, input logic [23:0] cpu_rsp_data,
 output logic [47:0] cpu_addr, output logic [23:0] cpu_data,
 output logic [2:0] m1_n,mreq_n,iorq_n,rd_n,wr_n,rfsh_n,halt_n,wait_n
);
 wire [2:0] interrupt_n = ~{sound_irq,sub_irq,main_irq};
 wire [2:0] nmi_n = ~{sound_nmi,sub_nmi,1'b0};
 wire [2:0] requested_reset = {reset,(reset || sub_reset),reset};
 logic [2:0] drain_hold;
 wire [2:0] local_reset = requested_reset | drain_hold;
 // Pause lets an already physical SEND finish; only a truly idle lane closes admission.
 assign cpu_rom_quiesce = requested_reset | ({3{pause}} & cpu_bus_idle);
 wire [23:0] vectors = {8'hff,8'hfd,main_vector}; // sub IM2 vector FD (sub_interrupt)
 wire [23:0] data_in;
 wire [2:0] irq_ack;
 assign main_irq_ack=irq_ack[0];
 assign sub_irq_ack=irq_ack[1];
 // Cycle recovery (jtframe_z80_romwait RECOVERY=1 style). The 48 MHz clock is
 // 8x each 6 MHz Z80, so a CPU whose memory access stalls a clock enable (WAIT_n
 // low) is repaid with an extra enable half-way through a later window in which
 // it is not waiting. The PCB Z80 never waits for ROM, so average speed stays
 // exactly 6 MHz (debt is the number of lost enables) while SDRAM/arbiter latency
 // no longer slows the game. Peripherals stay on the fixed base enable.
 logic [2:0] since_cen;
 logic [2:0][3:0] debt;
 wire [2:0] extra_cen, cen_eff;
 always_ff @(posedge clk) since_cen <= cpu_cen ? 3'd0 : since_cen + 3'd1;
 assign cen_eff = {3{cpu_cen}} | extra_cen;
 genvar n;
 generate for(n=0;n<3;n=n+1) begin: cpu
  assign extra_cen[n] = debt[n]!=0 && since_cen==3'd3 && wait_n[n] && !local_reset[n] && !pause;
  always_ff @(posedge clk) begin
   if(local_reset[n]) debt[n]<=4'd0;
   else if(extra_cen[n]) debt[n]<=debt[n]-4'd1;
   else if(cpu_cen && !pause && !wait_n[n] && debt[n]!=4'd15) debt[n]<=debt[n]+4'd1;
  end
  // Keep RESET asserted until an accepted old response and adapter DONE retire.
  always_ff @(posedge clk) begin
   if(requested_reset[n]) drain_hold[n]<=1'b1;
   else if(!cpu_rom_pending[n] && !cpu_rsp_valid[n] && cpu_bus_idle[n]) drain_hold[n]<=1'b0;
  end
  T80s core (.RESET_n(!local_reset[n]),.CLK(clk),.CEN(cen_eff[n] && !pause),
   .WAIT_n(wait_n[n]),.INT_n(interrupt_n[n]),.NMI_n(nmi_n[n]),
   .BUSRQ_n(1'b1),.OUT0(1'b0),.DI(data_in[8*n+:8]),
   .M1_n(m1_n[n]),.MREQ_n(mreq_n[n]),.IORQ_n(iorq_n[n]),
   .RD_n(rd_n[n]),.WR_n(wr_n[n]),.RFSH_n(rfsh_n[n]),
   .HALT_n(halt_n[n]),.BUSAK_n(),.A(cpu_addr[16*n+:16]),.DOUT(cpu_data[8*n+:8]));
  airbustr_z80_bus bus (.clk,.reset,.cpu_reset(requested_reset[n]),
   .transaction_idle(cpu_bus_idle[n]), .loan_safe(cpu_bus_loan_safe[n]),
   .m1_n(m1_n[n]),.mreq_n(mreq_n[n]),.iorq_n(iorq_n[n]),.rd_n(rd_n[n]),
   .wr_n(wr_n[n]),.rfsh_n(rfsh_n[n]),.addr(cpu_addr[16*n+:16]),
   .data_out(cpu_data[8*n+:8]),.irq_vector(vectors[8*n+:8]),
   .data_in(data_in[8*n+:8]),.wait_n(wait_n[n]),.irq_ack(irq_ack[n]),
   .req_valid(cpu_req_valid[n]),.req_ready(cpu_req_ready[n]),
   .req_io(cpu_req_io[n]),.req_write(cpu_req_write[n]),.req_addr(cpu_req_addr[16*n+:16]),
   .req_data(cpu_req_data[8*n+:8]),.rsp_valid(cpu_rsp_valid[n]),.rsp_data(cpu_rsp_data[8*n+:8]));
 end endgenerate
endmodule
