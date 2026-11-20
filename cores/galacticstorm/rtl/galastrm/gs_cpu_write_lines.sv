// SPDX-License-Identifier: BSD-3-Clause
// Split an aligned four-word posted store at a word-only shadow RAM boundary.
// Retire only after all four held transactions, including request-drop gaps.
module gs_cpu_write_lines #(parameter ENABLE=0)(
    input wire clk,reset,
    input wire up_req,up_write,input wire [24:0] up_addr,
    input wire [15:0] up_wdata,input wire [1:0] up_bytes,
    input wire up_write_line,input wire [63:0] up_wline,
    output wire up_ack,idle,output wire [15:0] up_rdata,
    output wire down_req,down_write,output wire [24:0] down_addr,
    output wire [15:0] down_wdata,output wire [1:0] down_bytes,
    input wire down_ack,input wire [15:0] down_rdata
);
    generate if(!ENABLE)begin: direct_word
        assign down_req=up_req;assign down_write=up_write;assign down_addr=up_addr;
        assign down_wdata=up_wdata;assign down_bytes=up_bytes;
        assign up_ack=down_ack;assign up_rdata=down_rdata;assign idle=1;
    end else begin: split_line
        localparam IDLE=0,SEND=1,DROP=2,REPLY=3;
        reg [1:0] state,word;
        reg [24:0] address;reg [63:0] data;
        reg [15:0] selected_data;
        always @* case(word)
            0:selected_data=data[15:0];
            1:selected_data=data[31:16];
            2:selected_data=data[47:32];
            default:selected_data=data[63:48];
        endcase
        wire active=state!=IDLE;
        assign idle=!active && !(up_req && up_write_line);
        assign down_req=active ? state==SEND : up_req && !up_write_line;
        assign down_write=active ? 1'b1 : up_write;
        assign down_addr=active ? address+{22'b0,word,1'b0} : up_addr;
        assign down_wdata=active ? selected_data : up_wdata;
        assign down_bytes=active ? 2'b11 : up_bytes;
        assign up_ack=up_req && (active ? state==REPLY : !up_write_line && down_ack);
        assign up_rdata=down_rdata;
        always @(posedge clk)begin
            case(state)
                IDLE:if(up_req && up_write_line)begin
                    address<=up_addr;data<=up_wline;word<=0;state<=SEND;
                end
                SEND:if(down_ack)begin
                    if(word==3)state<=REPLY;else state<=DROP;
                end
                DROP:begin word<=word+1'b1;state<=SEND;end
                REPLY:if(!up_req)state<=IDLE;
            endcase
            if(reset)begin state<=IDLE;word<=0;address<=0;data<=0;end
        end
`ifndef SYNTHESIS
        always @(posedge clk)if(!reset && state==IDLE && up_req && up_write_line)
            assert(up_write && up_bytes==3 && up_addr[2:0]==0 && up_wdata==up_wline[15:0])
                else $fatal(1,"Invalid shadow four-word write");
`endif
    end endgenerate
endmodule
