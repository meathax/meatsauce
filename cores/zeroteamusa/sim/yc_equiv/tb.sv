// Equivalence check: stock yc_out vs the pre-registered-sine-lookup version.
module tb;
    reg clk=0; always #5 clk=~clk;
    reg [39:0] inc=40'h0922222222;  // arbitrary carrier
    reg pal=0, cvbs=0; reg [16:0] cb={7'd40,10'd240};
    reg hs=0,vs=0,cs=0,de=0; reg [23:0] din=0;
    wire [23:0] d0,d1; wire h0,v0,c0,e0,h1,v1,c1,e1;
    yc_out_orig a(.clk(clk),.PHASE_INC(inc),.PAL_EN(pal),.CVBS(cvbs),.COLORBURST_RANGE(cb),.hsync(hs),.vsync(vs),.csync(cs),.de(de),.din(din),.dout(d0),.hsync_o(h0),.vsync_o(v0),.csync_o(c0),.de_o(e0));
    yc_out      b(.clk(clk),.PHASE_INC(inc),.PAL_EN(pal),.CVBS(cvbs),.COLORBURST_RANGE(cb),.hsync(hs),.vsync(vs),.csync(cs),.de(de),.din(din),.dout(d1),.hsync_o(h1),.vsync_o(v1),.csync_o(c1),.de_o(e1));
    integer n=0, bad=0, x=0, y=0;
    always @(posedge clk) begin
        x<=(x==799)?0:x+1; if(x==799) y<=(y==524)?0:y+1;
        hs<=(x>=656&&x<752); vs<=(y>=490&&y<492); cs<=!(hs^vs); de<=(x<640&&y<480);
        din<=$random;
        if(n==200000) begin pal<=1; end
        if(n==400000) begin cvbs<=1; end
        n<=n+1;
        if({d0,h0,v0,c0,e0}!=={d1,h1,v1,c1,e1}) bad<=bad+1;
        if(n==600000) begin $display("cycles=%0d mismatches=%0d %s",n,bad,bad==0?"YC_EQUIV_PASS":"YC_EQUIV_FAIL"); $finish; end
    end
endmodule
