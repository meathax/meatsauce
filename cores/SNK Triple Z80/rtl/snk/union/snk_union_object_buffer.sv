// Sports pen14 is a shadow instruction, not a palette14 source pixel.
// Later shadow preserves any earlier ordinary sprite: only background pens
// are affected by MAME's shadow table. Normal later sprite overwrites earlier.
//
// Block-RAM structure (Quartus 17 inference). The original single array had two write ports and two read
// ports, with the sports write address (waddr) different from the read address (addr0): that cannot map to
// M10K and was kept in 10,240 flip-flops. Here the 1024 entries are split by address bit 9 into two 512-entry
// halves (the renderer and the scanner always work on opposite halves: addr0[9]=wh, addr1[9]=V[0]), and each
// half exists twice (copy 0 read by port 0, copy 1 read by port 1). Every copy has ONE write port and ONE
// registered read address; all copies of a half take the same merged write (port 1 clear has priority over the
// port 0 write if both ever hit the same half in one clock, which the line-buffer protocol forbids and the
// simulation check below flags). No reset and no parallel clear. clk1 is assumed to be the same net as clk0 (it
// is in snk_union_video); the logic runs on clk0.
module snk_union_object_buffer(
 input sports_mode,
 input clk0,input [9:0] data0,input [9:0] addr0,input we0,output [9:0] q0,
 input clk1,input [9:0] data1,input [9:0] addr1,input we1,output [9:0] q1
);
reg pending=0;reg [9:0] waddr=0,wdata=0;
reg sel0=0,sel1=0;
wire [9:0] r00,r01,r10,r11;
assign q0=sel0?r01:r00;
assign q1=sel1?r11:r10;
// port 0 write request (sports: delayed read-modify-write; otherwise direct)
wire w0_en=sports_mode ? (pending&&(wdata[3:0]!=4'he||!q0[9]||q0[3:0]==4'he)) : we0;
wire [9:0] w0_addr=sports_mode ? waddr : addr0;
wire [9:0] w0_data=sports_mode ? wdata : data0;
// merged writes per half (port 1 clear wins a same-half collision)
wire w1_h0=we1&&!addr1[9],w1_h1=we1&&addr1[9];
wire w0_h0=w0_en&&!w0_addr[9]&&!w1_h0,w0_h1=w0_en&&w0_addr[9]&&!w1_h1;
wire h0_we=w1_h0||w0_h0,h1_we=w1_h1||w0_h1;
wire [8:0] h0_wa=w1_h0?addr1[8:0]:w0_addr[8:0],h1_wa=w1_h1?addr1[8:0]:w0_addr[8:0];
wire [9:0] h0_wd=w1_h0?data1:w0_data,h1_wd=w1_h1?data1:w0_data;
(* ramstyle="M10K" *) reg [9:0] m0a[0:511],m0b[0:511],m1a[0:511],m1b[0:511];
reg [9:0] q0a,q0b,q1a,q1b;
always @(posedge clk0)begin q0a<=m0a[addr0[8:0]];if(h0_we)m0a[h0_wa]<=h0_wd;end   // half0, read by port 0
always @(posedge clk0)begin q0b<=m0b[addr0[8:0]];if(h1_we)m0b[h1_wa]<=h1_wd;end   // half1, read by port 0
always @(posedge clk0)begin q1a<=m1a[addr1[8:0]];if(h0_we)m1a[h0_wa]<=h0_wd;end   // half0, read by port 1
always @(posedge clk0)begin q1b<=m1b[addr1[8:0]];if(h1_we)m1b[h1_wa]<=h1_wd;end   // half1, read by port 1
assign r00=q0a,r01=q0b,r10=q1a,r11=q1b;
always @(posedge clk0)begin
 sel0<=addr0[9];sel1<=addr1[9];
 pending<=sports_mode&&we0;waddr<=addr0;wdata<=data0;
end
`ifdef VERILATOR
// Line-buffer protocol check: renderer and scanner never write the same half in the same clock.
always @(posedge clk0)if(w0_en&&we1&&w0_addr[9]==addr1[9])$display("snk_union_object_buffer: same-half write collision (line-buffer protocol violated)");
`endif
endmodule
