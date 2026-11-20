// SPDX-License-Identifier: BSD-3-Clause
// Registered held-packet arbiter. Each client drops REQ after ACK; a held
// acknowledged packet cannot retire twice. Scanout may override round-robin.
module gs_memory_arb2 #(parameter STREAM_LINES=0,LINE_WRITES=0,DIRECT_GRANT=0,COMBINATIONAL_GRANT=0)(
    input wire clk,reset,
    input wire [1:0] req,write,
    input wire [1:0] line_read,line_write,
    input wire urgent0,
    input wire [49:0] addr,
    input wire [127:0] wdata,
    input wire [15:0] bytes,
    output wire [1:0] ack,
    output wire [63:0] rdata,
    output reg mem_req,mem_write,
    output reg mem_line_read,mem_line_write,
    output reg [24:0] mem_addr,
    output reg [63:0] mem_wdata,
    output reg [7:0] mem_bytes,
    input wire mem_ack,mem_busy,
    input wire [63:0] mem_rdata
);
    reg owner,next_owner;
    reg [1:0] issued,pending;
    reg [1:0] packet_line,packet_write_line;
    reg [97:0] packets[0:1];
    reg urgent_saved;
    wire [97:0] packet0={write[0],addr[24:0],wdata[63:0],bytes[7:0]};
    wire [97:0] packet1={write[1],addr[49:25],wdata[127:64],bytes[15:8]};
    wire selected=urgent_saved && pending[0] ? 1'b0 : (pending[next_owner]?next_owner:!next_owner);
    wire ack_owner;
    assign ack={2{mem_req && mem_ack}} & (ack_owner?2'b10:2'b01);
    assign rdata=mem_rdata;
    generate if(COMBINATIONAL_GRANT) begin: direct_packets
        // For native clients which retire/advance on ACK, and a backend
        // returning to IDLE on that same edge. Retain ownership while stalled;
        // the client itself retains the packet, including during backend BUSY.
        reg locked;
        wire grant=urgent0 && req[0] ? 1'b0 : (req[next_owner] ? next_owner : !next_owner);
        assign ack_owner=locked ? owner:grant;
        always @* begin
            mem_req=!reset && (locked || |req);
            mem_line_read=STREAM_LINES && line_read[ack_owner];
            mem_line_write=LINE_WRITES && line_write[ack_owner] && write[ack_owner];
            {mem_write,mem_addr,mem_wdata,mem_bytes}=ack_owner ? packet1:packet0;
        end
        always @(posedge clk) begin
            if(!locked && |req) begin owner<=grant;locked<=1;end
            if(mem_req && mem_ack) begin locked<=0;next_owner<=!ack_owner;end
            if(reset) begin locked<=0;owner<=0;next_owner<=0;end
        end
`ifndef SYNTHESIS
        reg stalled;
        reg [99:0] retained;
        always @(posedge clk) begin
            if(reset) stalled<=0;
            else begin
                if(stalled)
                    assert(mem_req && {mem_line_read,mem_line_write,mem_write,mem_addr,mem_wdata,mem_bytes}==retained)
                        else $fatal(1,"Direct memory packet changed before ACK");
                stalled<=mem_req && !mem_ack;
                retained<={mem_line_read,mem_line_write,mem_write,mem_addr,mem_wdata,mem_bytes};
            end
        end
`endif
    end else if(DIRECT_GRANT) begin: held_clients
        assign ack_owner=owner;
        // These clients already hold a registered packet through ACK. Capture
        // that packet when granting, without first making a second queued copy.
        // The registered grant/data remain unchanged throughout backend BUSY.
        wire [1:0] eligible=req & ~issued;
        wire grant=urgent0 && eligible[0] ? 1'b0 : (eligible[next_owner] ? next_owner : !next_owner);
        always @(posedge clk) begin
            if(!req[0]) issued[0]<=0;
            if(!req[1]) issued[1]<=0;
            if(mem_req) begin
                if(mem_ack) begin mem_req<=0;next_owner<=!owner;end
            end else if(!mem_busy && |eligible) begin
                owner<=grant;issued[grant]<=1;mem_req<=1;
                mem_line_read<=STREAM_LINES && line_read[grant];
                mem_line_write<=LINE_WRITES && line_write[grant] && write[grant];
                {mem_write,mem_addr,mem_wdata,mem_bytes}<=grant ? packet1 : packet0;
            end
            if(reset) begin
                mem_req<=0;mem_write<=0;mem_addr<=0;mem_wdata<=0;mem_bytes<=0;
                mem_line_read<=0;mem_line_write<=0;owner<=0;next_owner<=0;issued<=0;
            end
        end
    end else begin: queued_clients
    assign ack_owner=owner;
    integer i;
    always @(posedge clk) begin
        // Both actual clients drop REQ after ACK. Capture once per held request,
        // then arbitrate registered packets, outside the producer address path.
        for(i=0;i<2;i=i+1) begin
            if(!req[i]) issued[i]<=0;
            if(req[i] && !issued[i] && !pending[i]) begin
                issued[i]<=1;pending[i]<=1;packets[i]<=i ? packet1 : packet0;
                packet_line[i]<=STREAM_LINES && line_read[i];
                packet_write_line[i]<=LINE_WRITES && line_write[i] && write[i];
                if(i==0) urgent_saved<=urgent0;
            end
        end
        if(mem_req) begin
            if(mem_ack) begin mem_req<=0;pending[owner]<=0;next_owner<=!owner;end
        end else if(!mem_busy && |pending) begin
            owner<=selected;mem_req<=1;
            mem_line_read<=packet_line[selected];
            mem_line_write<=packet_write_line[selected];
            {mem_write,mem_addr,mem_wdata,mem_bytes}<=packets[selected];
        end
        if(reset) begin
            mem_req<=0;mem_write<=0;mem_addr<=0;mem_wdata<=0;mem_bytes<=0;
            mem_line_read<=0;packet_line<=0;mem_line_write<=0;packet_write_line<=0;
            owner<=0;next_owner<=0;issued<=0;pending<=0;packets[0]<=0;packets[1]<=0;urgent_saved<=0;
        end
    end
    end endgenerate
endmodule
