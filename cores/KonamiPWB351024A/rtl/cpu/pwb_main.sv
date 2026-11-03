// Explicit compatibility adapter. This is not an HD6309 implementation.
// ce_e/ce_q have the donor mc6809i phase-strobe semantics. The integrating
// phase generator must also stop while cpu_ok=0 so strobes are not discarded.
module pwb_main #(
 parameter ALLOW_6809_COMPAT=0
)(
 input wire clk,reset,ce_e,ce_q,pause,cpu_ok,
 input wire irq,nmi,input wire [7:0] din,
 output wire [15:0] addr,output wire [7:0] dout,
 output wire rnw,avma,bs,ba,lic,opcode,
 output wire [111:0] debug_regs,
 output wire hd6309_supported,execution_enabled
);
 assign hd6309_supported=1'b0;
 assign execution_enabled=ALLOW_6809_COMPAT != 0;
 generate if(ALLOW_6809_COMPAT) begin:compatibility
  mc6809i #(.ILLEGAL_INSTRUCTIONS("STOP")) cpu(
   .clk(clk),.nRESET(!reset),.cen_E(ce_e && !pause && cpu_ok),
   .cen_Q(ce_q && !pause && cpu_ok),.D(din),.DOut(dout),.ADDR(addr),
   .RnW(rnw),.nIRQ(!irq),.nFIRQ(1'b1),.nNMI(!nmi),
   .AVMA(avma),.BUSY(),.BS(bs),.BA(ba),.LIC(lic),
   .nHALT(1'b1),.nDMABREQ(1'b1),.OP(opcode),.RegData(debug_regs));
 end else begin:unavailable
  assign addr=16'hffff;assign dout=0;assign rnw=1;
  assign avma=0;assign bs=0;assign ba=0;assign lic=0;assign opcode=0;
  assign debug_regs=0;
 end endgenerate
endmodule
