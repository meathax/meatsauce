// SPDX-License-Identifier: BSD-3-Clause
// Fair two-client MiSTer DDRAM command service. An accepted read owns all its
// burst replies; a write releases after its single accepted beat. The selected
// command stays held while the backend is busy. Both clients retain their own
// coherent cache, and logical surface/delay address ranges remain disjoint.
module gs_ddr_arb2 #(
    // Aggregated clients may already carry ordered reads from several owners.
    // Their replies still use this arbiter's two-entry ownership FIFO.
    parameter [1:0] PIPELINED_CLIENTS=2'b00,
    // Child arbiters must see retirement beats while they drain their own
    // reset epoch. Leaf clients retain the default discarded-reply contract.
    parameter [1:0] FORWARD_DRAIN=2'b00
)(
    input wire clk,reset,
    input wire [1:0] rd,we,input wire [15:0] burstcnt,input wire [57:0] addr,
    input wire [127:0] din,input wire [15:0] be,
    output wire [1:0] busy,dout_ready,output wire [63:0] dout,
    input wire DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,output wire [28:0] DDRAM_ADDR,
    input wire [63:0] DDRAM_DOUT,input wire DDRAM_DOUT_READY,output wire DDRAM_RD,
    output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE
);
    // Default: one read per client; aggregated clients share two reply slots.
    // Command admission is independent of return-data service (Avalon-MM).
    reg grant=0,owner=0,next_owner=0;
    reg head=0,tail=0,flush_pending=0;
    reg [1:0] count=0,inflight=0;
    reg reply_owner[0:1];
    reg [7:0] remaining[0:1];
    wire [1:0] requesting=(we | (rd & {2{count<2}})) & (PIPELINED_CLIENTS | ~inflight);
    wire selected=requesting[next_owner] ? next_owner:!next_owner;
    wire enabled=grant && !reset && !flush_pending;
    wire accepted=enabled && !DDRAM_BUSY && (rd[owner] || we[owner]);
    wire push=accepted && rd[owner];
    wire beat=count!=0 && DDRAM_DOUT_READY;
    wire pop=beat && remaining[head]==1;
    assign busy={2{DDRAM_BUSY || !enabled}} | (owner ? 2'b01:2'b10);
    assign DDRAM_RD=enabled && rd[owner];
    assign DDRAM_WE=enabled && we[owner];
    assign DDRAM_BURSTCNT=burstcnt[8*owner +:8];
    assign DDRAM_ADDR=addr[29*owner +:29];
    assign DDRAM_DIN=din[64*owner +:64];
    assign DDRAM_BE=be[8*owner +:8];
    assign dout=DDRAM_DOUT;
    assign dout_ready=beat && ((!reset && !flush_pending) || FORWARD_DRAIN[reply_owner[head]]) ?
        (reply_owner[head] ? 2'b10:2'b01):2'b00;
    always @(posedge clk)begin
        if(!grant && !reset && !flush_pending && |requesting)begin owner<=selected;grant<=1;end
        if(enabled && !DDRAM_BUSY)begin grant<=0;next_owner<=!owner;end
        count<=count+{1'b0,push}-{1'b0,pop};
        if(beat)begin
            remaining[head]<=remaining[head]-1'b1;
            if(pop)begin inflight[reply_owner[head]]<=0;head<=!head;end
        end
        if(push)begin
            reply_owner[tail]<=owner;remaining[tail]<=burstcnt[8*owner +:8];
            inflight[owner]<=1;tail<=!tail;
        end
        // Accepted replies retain ownership through reset. Drain and discard
        // them before admitting a new command epoch; never relabel old data.
        if(reset)begin
            grant<=0;next_owner<=0;flush_pending<=1;
            if(count==0)begin head<=0;tail<=0;inflight<=0;end
        end else if(flush_pending && count==0)flush_pending<=0;
    end
`ifndef SYNTHESIS
    always @(posedge clk)if(!reset)begin
        if(count>2)$fatal(1,"DDR reply ownership overflow");
        if(push && ((!PIPELINED_CLIENTS[owner] && inflight[owner]) || burstcnt[8*owner +:8]==0))
            $fatal(1,"DDR duplicate client read or empty burst");
        if(DDRAM_DOUT_READY && count==0)$fatal(1,"DDR unowned reply");
    end
`endif
endmodule
