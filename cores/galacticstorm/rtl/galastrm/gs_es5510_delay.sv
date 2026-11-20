// SPDX-License-Identifier: BSD-3-Clause
// Native 1M x 16 ES5510 delay store over the shared held 64-bit word service.
// Reserve logical DDR bytes 0x1600000..0x17fffff (2 MiB); no register-array RAM.
// Native reset/host RAM clear writes every physical byte before acknowledging.
module gs_es5510_delay #(
    parameter [24:0] BASE=25'h1600000
)(
    input wire clk,reset,
    input wire req,write,input wire [19:0] addr,input wire [15:0] wdata,
    output wire ack,output reg [15:0] rdata,
    input wire clear_req,output wire clear_ack,
    output wire mem_req,mem_write,output wire [24:0] mem_addr,
    output wire [63:0] mem_wdata,output wire [7:0] mem_bytes,
    input wire mem_ack,input wire [63:0] mem_rdata,
    output wire busy
);
    localparam [2:0] IDLE=0,COMMAND=1,REPLY=2,RETIRE=3,CLEAR=4,CLEAR_ACK=5,CLEAR_RETIRE=6,CLEAR_GAP=7;
    reg [2:0] state=IDLE;
    reg saved_write;
    reg [19:0] saved_addr;
    reg [15:0] saved_data;
    reg [17:0] clear_word;
    assign ack=state==REPLY && req;
    assign clear_ack=state==CLEAR_ACK;
    assign mem_req=state==COMMAND || state==CLEAR;
    assign mem_write=state==CLEAR || saved_write;
    assign mem_addr=BASE+(state==CLEAR ? {4'b0,clear_word,3'b0}:{4'b0,saved_addr[19:2],3'b0});
    assign mem_wdata=state==CLEAR ? 64'b0:{4{saved_data}};
    assign mem_bytes=state==CLEAR ? 8'hff:(8'h03 << {saved_addr[1:0],1'b0});
    assign busy=state!=IDLE;
    always @(posedge clk)begin
        case(state)
            IDLE:begin
                if(clear_req)begin clear_word<=0;state<=CLEAR;end
                else if(req)begin saved_write<=write;saved_addr<=addr;saved_data<=wdata;state<=COMMAND;end
            end
            COMMAND:if(mem_ack)begin rdata<=mem_rdata >> {saved_addr[1:0],4'b0};state<=REPLY;end
            REPLY:state<=RETIRE;
            RETIRE:if(!req)state<=IDLE;
            CLEAR:if(mem_ack)begin
                if(clear_word==18'h3ffff)state<=CLEAR_ACK;
                else begin clear_word<=clear_word+1'b1;state<=CLEAR_GAP;end
            end
            CLEAR_ACK:state<=CLEAR_RETIRE;
            CLEAR_RETIRE:if(!clear_req)state<=IDLE;
            // Drop the shared request between consecutive physical clears.
            CLEAR_GAP:state<=CLEAR;
            default:state<=IDLE;
        endcase
        if(reset)begin state<=IDLE;saved_write<=0;saved_addr<=0;saved_data<=0;clear_word<=0;rdata<=0;end
    end
endmodule
