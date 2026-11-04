`timescale 1ns/1ps
module pxl_spacing_tb;
reg clk=0; always #9.93 clk=~clk;
wire pxl, pxl2;
jtframe_pxlcen u(.clk(clk),.pxl_cen(pxl),.pxl2_cen(pxl2));
integer i, last=-1, gap, n=0, other=0, mn=999, mx=0, n2=0, last2=-1, other2=0;
initial begin
  for(i=0;i<400*280*8*2;i=i+1) begin   // two full 400x280 frames at N=8
    @(posedge clk); #0.1;
    if(pxl) begin if(last>=0) begin gap=i-last; n=n+1; if(gap<mn) mn=gap; if(gap>mx) mx=gap; if(gap!=8) other=other+1; end last=i; end
    if(pxl2) begin if(last2>=0) begin if(i-last2!=4) other2=other2+1; n2=n2+1; end last2=i; end
  end
  $display("pxl_cen gaps=%0d min=%0d max=%0d non8=%0d | pxl2_cen gaps=%0d non4=%0d", n, mn, mx, other, n2, other2);
  $display("%s", (other==0 && mn==8 && mx==8 && other2==0) ? "PASS spacing={8}" : "FAIL");
  $finish;
end
endmodule
