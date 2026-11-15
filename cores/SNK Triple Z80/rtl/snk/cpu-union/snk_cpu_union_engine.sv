// Three native T80pa instances; board-specific decode, watchdog and arbitration
// stay outside this engine. Lane 0=A, 1=B, 2=sound. One master clock only.
module snk_cpu_union_engine(
 input wire clk,
 input wire [2:0] reset_n,cen_p,cen_n,wait_n,irq_n,nmi_n,
 input wire [23:0] din,
 output wire [47:0] addr,
 output wire [23:0] dout,
 output wire [2:0] m1_n,mreq_n,iorq_n,rd_n,wr_n,rfsh_n,halt_n,busack_n
);
 genvar lane;
 generate for(lane=0;lane<3;lane=lane+1) begin:cpu
  T80pa processor(
   .CLK(clk),.RESET_n(reset_n[lane]),
   .CEN_p(cen_p[lane]),.CEN_n(cen_n[lane]),
   .WAIT_n(wait_n[lane]),.INT_n(irq_n[lane]),.NMI_n(nmi_n[lane]),
   .R800_mode(1'b0),.REG(),.DIRSet(1'b0),.DIR(212'b0),
   .BUSRQ_n(1'b1),.OUT0(1'b0),.DI(din[lane*8+:8]),
   .A(addr[lane*16+:16]),.DO(dout[lane*8+:8]),
   .M1_n(m1_n[lane]),.MREQ_n(mreq_n[lane]),.IORQ_n(iorq_n[lane]),
   .RD_n(rd_n[lane]),.WR_n(wr_n[lane]),.RFSH_n(rfsh_n[lane]),
   .HALT_n(halt_n[lane]),.BUSAK_n(busack_n[lane])
  );
 end endgenerate
endmodule
