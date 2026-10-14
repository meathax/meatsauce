// SPDX-License-Identifier: GPL-2.0-or-later
// Component fixture; synthetic instructions exercise the actual CPU bus.
module cpu_ready_qualification (
    input wire clk, reset, pause, ready, irq,
    output wire [15:0] address,
    output wire [7:0] dout, status,
    output wire inte, sync, dbin, wr_n, read_start, write_start, interrupt_ack,
    output wire wait_debug,
    output wire [4:0] phase_debug,
    output reg [7:0] ram0=0, ram1=0,
    output reg [7:0] writes0=0, writes1=0,
    output wire facade_equal
);
    reg [7:0] din;
    always @* begin
        din=8'h76;
        case(address)
            16'h0000:din=8'h3e; 16'h0001:din=8'ha5;
            16'h0002:din=8'h32; 16'h0003:din=8'h00;
            16'h0004:din=8'h60; 16'h0005:din=8'hfb;
            16'h0006:din=8'h3a; 16'h0007:din=8'h00;
            16'h0008:din=8'h60; 16'h0009:din=8'hc6;
            16'h000a:din=8'h5a; 16'h000b:din=8'h32;
            16'h000c:din=8'h01; 16'h000d:din=8'h60;
            16'h000e:din=8'h76;
            16'h6000:din=ram0; 16'h6001:din=ram1;
            default:din=8'h76;
        endcase
        if(status[0])din=8'hff;
    end
    n8080_cpu_ready actual(.*);
    always @(posedge clk) if(!pause) begin
        if(reset)begin ram0<=0;ram1<=0;writes0<=0;writes1<=0;end
        else if(write_start&&!status[4])begin
            if(address==16'h6000)begin ram0<=dout;writes0<=writes0+1'b1;end
            if(address==16'h6001)begin ram1<=dout;writes1<=writes1+1'b1;end
        end
    end
    wire [15:0] fa, ra;
    wire [7:0] fd, fs, rd, rs;
    wire fi,fy,fb,fw,fr,fx,fk,ri,ry,rb,rw,rr,rx,rk;
    wire [4:0] fp,rp;
    n8080_cpu legacy(.clk(clk),.reset(reset),.pause(pause),.din(din),.irq(irq),
        .address(fa),.dout(fd),.status(fs),.inte(fi),.sync(fy),.dbin(fb),
        .wr_n(fw),.read_start(fr),.write_start(fx),.interrupt_ack(fk),.phase_debug(fp));
    n8080_cpu_ready tied_high(.clk(clk),.reset(reset),.pause(pause),.ready(1'b1),
        .din(din),.irq(irq),.address(ra),.dout(rd),.status(rs),.inte(ri),.sync(ry),
        .dbin(rb),.wr_n(rw),.read_start(rr),.write_start(rx),.interrupt_ack(rk),
        .phase_debug(rp),.wait_debug());
    assign facade_equal={fa,fd,fs,fi,fy,fb,fw,fr,fx,fk,fp}=={ra,rd,rs,ri,ry,rb,rw,rr,rx,rk,rp};
endmodule
