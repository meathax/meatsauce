// SPDX-License-Identifier: BSD-3-Clause
// Bundled held-request transfer between the CPU and RAM clock domains.
// Reset assertion is shared; each clock domain releases through its own pair.
// Payload stays stable through the reply handshake.
// SAME_CLOCK=1 is only legal when cpu_clk and ram_clk are the same clock net:
// the toggles are then compared directly (no synchronizer latency). The held
// packet/reply are registered on the toggle edge, so they are stable when seen.
module gs_bus_cdc #(parameter LINE_REPLY=0,LINE_WRITES=0,SAME_CLOCK=0)(
    input wire cpu_clk,ram_clk,reset,
    input wire cpu_req,cpu_write,
    input wire [24:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    input wire cpu_write_line,input wire [63:0] cpu_wline,
    output wire cpu_ack,cpu_idle,
    output reg [15:0] cpu_rdata,
    output reg [63:0] cpu_rline,
    output wire ram_req,output reg ram_write,
    output reg [24:0] ram_addr,
    output reg [15:0] ram_wdata,
    output reg [1:0] ram_bytes,
    output reg ram_write_line,output reg [63:0] ram_wline,
    input wire ram_ack,
    input wire [15:0] ram_rdata,
    input wire [63:0] ram_rline
);
    localparam IDLE=0,WAIT=1,REPLY=2;
    reg [1:0] cpu_state;
    reg request_toggle,response_toggle;
    localparam PACKET_BITS=44+(LINE_WRITES ? 65 : 0);
    reg [PACKET_BITS-1:0] packet;
    reg [63:0] reply;
    (* preserve, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] cpu_reset_s=2'b11,ram_reset_s=2'b11;
    always @(posedge cpu_clk or posedge reset)
        if(reset)cpu_reset_s<=2'b11;else cpu_reset_s<={cpu_reset_s[0],1'b0};
    always @(posedge ram_clk or posedge reset)
        if(reset)ram_reset_s<=2'b11;else ram_reset_s<={ram_reset_s[0],1'b0};
    wire cpu_reset=cpu_reset_s[1],ram_reset=ram_reset_s[1];
    reg ram_pending;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg response_s1,response_s2,request_s1,request_s2;
    wire request_seen=SAME_CLOCK ? request_toggle : request_s2;
    wire response_seen=SAME_CLOCK ? response_toggle : response_s2;
    assign cpu_ack=cpu_state==REPLY && cpu_req && !cpu_reset;
    assign cpu_idle=cpu_state==IDLE && !cpu_req;
    assign ram_req=ram_pending && !ram_reset;
`ifndef SYNTHESIS
    reg [PACKET_BITS-1:0] observed_packet;
    reg [63:0] observed_reply;
    reg [3:0] packet_settle,reply_settle;
    always @(posedge ram_clk)begin
        observed_packet<=packet;
        if(packet!=observed_packet)packet_settle<=1;
        else if(packet_settle!=15)packet_settle<=packet_settle+1'b1;
        if(!SAME_CLOCK && !ram_reset && !ram_pending && request_s2!=response_toggle)
            assert(packet_settle>=2) else $fatal(1,"Held CDC packet did not settle for two receiver intervals");
        if(ram_reset)begin observed_packet<=0;packet_settle<=0;end
    end
    always @(posedge cpu_clk)begin
        observed_reply<=reply;
        if(reply!=observed_reply)reply_settle<=1;
        else if(reply_settle!=15)reply_settle<=reply_settle+1'b1;
        if(!SAME_CLOCK && !cpu_reset && cpu_state==WAIT && response_s2==request_toggle)
            assert(reply_settle>=2) else $fatal(1,"Held CDC reply did not settle for two receiver intervals");
        if(cpu_reset)begin observed_reply<=0;reply_settle<=0;end
    end
`endif
    always @(posedge cpu_clk) begin
        response_s1<=response_toggle;response_s2<=response_s1;
        case(cpu_state)
        IDLE: if(cpu_req) begin
            if(LINE_WRITES) packet<={cpu_write_line,cpu_wline,cpu_write,cpu_addr,cpu_wdata,cpu_bytes};
            else packet<={cpu_write,cpu_addr,cpu_wdata,cpu_bytes};
            request_toggle<=!request_toggle;cpu_state<=WAIT;
        end
        WAIT: if(response_seen==request_toggle) begin
            cpu_rdata<=reply[15:0];cpu_rline<=reply;cpu_state<=REPLY;
        end
        REPLY: if(!cpu_req) cpu_state<=IDLE;
        endcase
        if(cpu_reset) begin cpu_state<=IDLE;request_toggle<=0;packet<=0;cpu_rdata<=0;cpu_rline<=0;response_s1<=0;response_s2<=0;end
    end
    always @(posedge ram_clk) begin
        request_s1<=request_toggle;request_s2<=request_s1;
        if(ram_pending) begin
            if(ram_ack) begin
                reply<=LINE_REPLY ? ram_rline : {48'b0,ram_rdata};
                response_toggle<=request_seen;ram_pending<=0;
            end
        end else if(request_seen!=response_toggle) begin
            if(LINE_WRITES) {ram_write_line,ram_wline,ram_write,ram_addr,ram_wdata,ram_bytes}<=packet;
            else begin {ram_write,ram_addr,ram_wdata,ram_bytes}<=packet;ram_write_line<=0;ram_wline<=0;end
            ram_pending<=1;
        end
        if(ram_reset) begin
            request_s1<=0;request_s2<=0;response_toggle<=0;reply<=0;
            ram_pending<=0;ram_write<=0;ram_addr<=0;ram_wdata<=0;ram_bytes<=0;ram_write_line<=0;ram_wline<=0;
        end
    end
endmodule
