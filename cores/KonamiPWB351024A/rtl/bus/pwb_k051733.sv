// SPDX-License-Identifier: BSD-3-Clause
// MAME 0.289 k051733.cpp, BSD-3-Clause: Fabio Priuli, Acho A. Tang,
// R. Belmont. RTL translation of its documented arithmetic/register model.
// Full notice: donors/cpu/K051733_LICENSE.txt.
module pwb_k051733(
 input wire clk,reset,ce_12m,vblank,access,wr,
 input wire [4:0] addr,input wire [7:0] din,
 output reg [7:0] dout,output wire nmi
);
 (* dont_retime *) reg [7:0] ram[0:31];
 reg [15:0] lfsr,timer;
 reg vb_old;
 reg [2:0] pulse;
 wire signed [15:0] op1={ram[0],ram[1]},op2={ram[2],ram[3]};
 wire [15:0] op3={ram[4],ram[5]},rad={ram[6],ram[7]};
 wire signed [16:0] dx=$signed({1'b0,ram[14],ram[15]})-$signed({1'b0,ram[10],ram[11]});
 wire signed [16:0] dy=$signed({1'b0,ram[12],ram[13]})-$signed({1'b0,ram[8],ram[9]});
 wire [16:0] absdx=dx<0 ? -dx:dx,absdy=dy<0 ? -dy:dy;
 wire signed [15:0] quotient=op2==0 ? 16'sd0:op1/op2;
 wire signed [15:0] remainder=op2==0 ? op1:op1%op2;
 function automatic [15:0] isqrt(input [31:0] value);
  reg [33:0] remainder,root,bitpair; integer k;
  begin
   remainder={2'b0,value};root=0;bitpair=34'h040000000;
   // Restoring square root: no inferred multipliers in the dependency chain.
   for(k=0;k<16;k=k+1) begin
    if(remainder>=root+bitpair) begin
     remainder=remainder-root-bitpair;
     root=(root>>1)+bitpair;
    end else root=root>>1;
    bitpair=bitpair>>2;
   end
   isqrt=root[15:0] & 16'hfffe;
  end
 endfunction
 wire [15:0] root=isqrt({op3,16'b0});
 assign nmi=|pulse;
 integer i;
 always @(posedge clk) begin
  if(reset) begin
   for(i=0;i<32;i=i+1) ram[i]<=0;
   lfsr<=16'h00ff; timer<=0; vb_old<=0; pulse<=0;
  end else begin
   vb_old<=vblank;
   if(ce_12m && pulse!=0) pulse<=pulse-1'b1;
   if(vblank && !vb_old) begin
    if(timer==0) begin
     timer<={ram[16],ram[17]};
     if(ram[18][0]) pulse<=4;
    end else timer<=timer-1'b1;
   end
   if(access) begin
    lfsr<={lfsr[14:0],lfsr[1]^lfsr[8]^lfsr[12]};
    if(wr) ram[addr]<=din;
   end
  end
 end
 always @* begin
  case(addr[2:0])
   0:dout=quotient[15:8]; 1:dout=quotient[7:0];
   2:dout=remainder[15:8]; 3:dout=remainder[7:0];
   4:dout=root[15:8]; 5:dout=root[7:0]; 6:dout=lfsr[7:0];
   default: begin
    if(absdx>{1'b0,rad} || absdy>{1'b0,rad}) dout=8'hff;
    else if(dy<=0) begin
     if(dx<=0) dout=(dy>=dx)?0:6;
     else dout=(dy>=-dx)?4:7;
    end else begin
     if(dx<=0) dout=(dy>-dx)?2:1;
     else dout=(dy>dx)?3:5;
    end
   end
  endcase
 end
endmodule
