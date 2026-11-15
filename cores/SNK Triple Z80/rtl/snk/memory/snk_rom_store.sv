// Shared SNK ROM store: byte download and two toggle/ack word readers.
// Download convention follows the Ikari donor: even byte = high lane.
// Address inputs are logical 16-bit word indices; capacity is 32MB.
module snk_rom_store #(parameter integer CLK_HZ=53600000,parameter integer READ_BURST2=0,parameter integer FAST_READS=0,parameter integer CLK_MIN_HZ=CLK_HZ)(
    input wire clk,clk_shifted,init,
    output wire initialized,
    input wire dl_valid,
    input wire [23:0] dl_word_addr,
    input wire [7:0] dl_data,
    input wire dl_low_byte,
    output wire dl_wait,load_idle,
    input wire [23:0] read_addr1,read_addr2,
    input wire read_req1,read_req2,
    output wire read_ack1,read_ack2,
    output wire [15:0] read_data1,read_data2,
    output wire [31:0] read_pair1,read_pair2,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,
    output wire SDRAM_nRAS,SDRAM_nCAS,SDRAM_CLK,SDRAM_CKE
);
    reg write_req=0;
    wire write_ack;
    reg [23:0] write_addr=0,addr1=0,addr2=0;
    reg [7:0] write_data=0;
    reg write_low=0;
    reg req1=0,req2=0;
    wire ack1,ack2;
    wire [15:0] data1,data2;
    wire [15:0] data_next;
    reg saved_ack1=0,saved_ack2=0;
    reg [15:0] saved_data1=0,saved_data2=0;
    reg [31:0] saved_pair1=0,saved_pair2=0;
    wire new_reply1=FAST_READS && initialized && ack1!=saved_ack1;
    wire new_reply2=FAST_READS && initialized && ack2!=saved_ack2;
    // Forward a newly completed owned reply, then retain it before another
    // client can change the controller's shared data bus.
    assign read_ack1=FAST_READS ? ack1 : saved_ack1;
    assign read_ack2=FAST_READS ? ack2 : saved_ack2;
    assign read_data1=new_reply1 ? data1 : saved_data1;
    assign read_data2=new_reply2 ? data2 : saved_data2;
    assign read_pair1=new_reply1 ? {data1,data_next} : saved_pair1;
    assign read_pair2=new_reply2 ? {data2,data_next} : saved_pair2;
    wire accept1=FAST_READS && initialized && read_req1!=req1 && ack1==req1;
    wire accept2=FAST_READS && initialized && read_req2!=req2 && ack2==req2;
    assign load_idle=initialized && (write_req==write_ack);
    assign dl_wait=!load_idle;
    always @(posedge clk) begin
        if(init)begin
            write_req<=0;req1<=0;req2<=0;
            saved_ack1<=0;saved_ack2<=0;saved_data1<=0;saved_data2<=0;
            saved_pair1<=0;saved_pair2<=0;
        end else if(initialized)begin
            if(dl_valid && !dl_wait)begin
                write_addr<=dl_word_addr;write_data<=dl_data;
                write_low<=dl_low_byte;write_req<=~write_req;
            end
            // Latch each accepted address until the controller acknowledges it.
            if(read_req1!=req1 && read_ack1==req1)begin
                addr1<=read_addr1;req1<=read_req1;
            end
            if(read_req2!=req2 && read_ack2==req2)begin
                addr2<=read_addr2;req2<=read_req2;
            end
            // Data and external ACK change together. Idle clients retain their
            // response while the shared controller serves another client.
            if(ack1!=saved_ack1)begin saved_data1<=data1;saved_pair1<={data1,data_next};saved_ack1<=ack1;end
            if(ack2!=saved_ack2)begin saved_data2<=data2;saved_pair2<={data2,data_next};saved_ack2<=ack2;end
        end
    end
    snk_sdram #(.CLK_HZ(CLK_HZ),.READ_BURST2(READ_BURST2),.CLK_MIN_HZ(CLK_MIN_HZ)) controller(
        .clk(clk),.clk_shifted(clk_shifted),.init(init),.initialized(initialized),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CLK(SDRAM_CLK),.SDRAM_CKE(SDRAM_CKE),
        .addr0(write_addr),.wrl0(write_low),.wrh0(!write_low),
        .din0({write_data,write_data}),.dout0(),.req0(write_req),.ack0(write_ack),
        .addr1(accept1?read_addr1:addr1),.wrl1(1'b0),.wrh1(1'b0),.din1(16'b0),.dout1(data1),.req1(accept1?read_req1:req1),.ack1(ack1),
        .addr2(accept2?read_addr2:addr2),.wrl2(1'b0),.wrh2(1'b0),.din2(16'b0),.dout2(data2),.req2(accept2?read_req2:req2),.ack2(ack2),.dout_next(data_next));
endmodule
