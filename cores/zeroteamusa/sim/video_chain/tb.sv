module tb;
    reg clk=0; always #5 clk=~clk; reg reset=1;
    wire [31:0] f0,l0,v0,p0,f1,l1,v1,p1,f2,l2,v2,p2,f3,l3,v3,p3;
    vbench #(.NEWHB(0),.SD(0)) a(clk,reset,f0,l0,v0,p0);
    vbench #(.NEWHB(1),.SD(0)) b(clk,reset,f1,l1,v1,p1);
    vbench #(.NEWHB(0),.SD(1)) c(clk,reset,f2,l2,v2,p2);
    vbench #(.NEWHB(1),.SD(1)) d(clk,reset,f3,l3,v3,p3);
    initial begin
        repeat(50) @(posedge clk); reset=0;
        repeat(96000000/55*8) @(posedge clk);
        $display("OLD 15k: frames=%0d de_lines=%0d maxpix=%0d",f0,l0,p0);
        $display("NEW 15k: frames=%0d de_lines=%0d maxpix=%0d",f1,l1,p1);
        $display("OLD SD : frames=%0d de_lines=%0d maxpix=%0d",f2,l2,p2);
        $display("NEW SD : frames=%0d de_lines=%0d maxpix=%0d",f3,l3,p3);
        $finish;
    end
endmodule
