// SPDX-License-Identifier: BSD-3-Clause
// Existing frontend 16-bit physical CPU interface + tagged pipelined GPU reads.
// Sprite/SCP/SCN normalized into 73728 snapshot words. GPU region IDs 0/1/2.
module gs_video_ram #(
    parameter CLIENTS=13,
    parameter OWNER_BITS=$clog2(CLIENTS)
)(
    input wire clk,reset,
    output wire initialized,
    input wire cut,cpu_bus_idle,
    output wire cut_ready,cut_ack,
    input wire cpu_req,cpu_write,
    input wire [24:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    output wire cpu_mapped,cpu_ack,
    output wire [15:0] cpu_rdata,
    input wire [CLIENTS-1:0] gpu_req,gpu_wide,
    input wire [CLIENTS*32-1:0] gpu_addr,
    output reg [CLIENTS-1:0] gpu_ack,
    output wire [CLIENTS*32-1:0] gpu_rdata
);
    reg cpu_issue_req,cpu_issue_write;
    reg [16:0] cpu_issue_address;
    reg [15:0] cpu_issue_data;
    reg [1:0] cpu_issue_bytes;
    reg [CLIENTS-1:0] issued;
    reg [OWNER_BITS-1:0] round_robin,pair_owner,stage0_owner,stage1_owner;
    reg issue_valid,issue_last,issue_wide;
    reg [16:0] issue_address;
    reg [OWNER_BITS-1:0] issue_owner;
    reg pair_pending,stage0_valid,stage1_valid,stage0_last,stage1_last,stage0_wide,stage1_wide;
    reg [16:0] pair_address;
    reg [15:0] upper_word[0:CLIENTS-1];
    reg found;
    reg [OWNER_BITS-1:0] selected;
    integer n,candidate;
    wire dispatch=initialized && (pair_pending || found);
    wire [OWNER_BITS-1:0] dispatch_owner=pair_pending ? pair_owner : selected;
    wire [17:0] selected_address=gpu_addr[selected*32 +: 18];
    wire [16:0] dispatch_address=pair_pending ? pair_address+17'd1 : normalized(selected_address);
    wire ram_cut_ready,ram_gpu_ack,ram_cpu_ack;
    wire [15:0] ram_gpu_data;
    wire [16:0] cpu_word_address=
        cpu_addr[24:16]==9'h142 ? {4'b0,cpu_addr[13:1]} :
        cpu_addr[24:16]==9'h143 ? 17'd8192+{2'b0,cpu_addr[15:1]} :
                                 17'd40960+{2'b0,cpu_addr[15:1]};
    function automatic [16:0] normalized(input [17:0] address);
        begin
            case(address[17:16])
            0: normalized={4'b0,address[13:1]};
            1: normalized=17'd8192+{2'b0,address[15:1]};
            2: normalized=17'd40960+{2'b0,address[15:1]};
            default: normalized=0; // Reserved region; board decoders never issue.
            endcase
        end
    endfunction
    assign cpu_mapped=(cpu_addr[24:16]==9'h142 && cpu_addr[15:14]==0) ||
        cpu_addr[24:16]==9'h143 || cpu_addr[24:16]==9'h144;
    assign cpu_ack=ram_cpu_ack && cpu_mapped && cpu_req;
    assign cut_ready=ram_cut_ready && cpu_bus_idle && !pair_pending &&
        !(|issued) && !(|gpu_req) && !cpu_req && !cpu_issue_req && !issue_valid && !stage0_valid && !stage1_valid;
    always @* begin
        selected=0;found=0;
        for(n=0;n<CLIENTS;n=n+1) begin
            candidate=round_robin+n;
            if(candidate>=CLIENTS) candidate=candidate-CLIENTS;
            if(!found && gpu_req[candidate] && !issued[candidate]) begin selected=candidate;found=1;end
        end
        gpu_ack=0;
        if(ram_gpu_ack && stage1_valid && stage1_last) gpu_ack[stage1_owner]=1;
    end
    genvar client;
    generate for(client=0;client<CLIENTS;client=client+1) begin: replies
        assign gpu_rdata[client*32 +: 32]=stage1_wide ? {upper_word[client],ram_gpu_data} : {16'b0,ram_gpu_data};
    end endgenerate
    // Explicit banks preserve the qualified synchronous read/reply timing.
    // Full-board M10K inference and fitted budgets qualify this implementation.
    gs_snapshot_ram #(.PIPELINED_GPU(1),.BANK_READS(0)) store(
        .clk(clk),.reset(reset),.initialized(initialized),
        .cut(cut && cpu_bus_idle && !pair_pending && !(|issued) && !(|gpu_req) && !cpu_req && !cpu_issue_req && !issue_valid && !stage0_valid && !stage1_valid),
        .cut_ready(ram_cut_ready),.cut_ack(cut_ack),
        .cpu_req(cpu_issue_req),.cpu_write(cpu_issue_write),.cpu_addr(cpu_issue_address),
        .cpu_wdata(cpu_issue_data),.cpu_bytes(cpu_issue_bytes),.cpu_ack(ram_cpu_ack),.cpu_rdata(cpu_rdata),
        .gpu_req(issue_valid),.gpu_addr(issue_address),.gpu_ack(ram_gpu_ack),.gpu_rdata(ram_gpu_data));
    always @(posedge clk) begin
        if(!cpu_issue_req && cpu_req && cpu_mapped && initialized) begin
            cpu_issue_req<=1;cpu_issue_write<=cpu_write;cpu_issue_address<=cpu_word_address;
            cpu_issue_data<=cpu_wdata;cpu_issue_bytes<=cpu_bytes;
        end else if(cpu_issue_req && !cpu_req) cpu_issue_req<=0;
        issued<=issued & gpu_req;
        issue_valid<=dispatch;
        stage0_valid<=issue_valid;stage1_valid<=stage0_valid;
        stage0_owner<=issue_owner;stage0_last<=issue_last;stage0_wide<=issue_wide;
        stage1_owner<=stage0_owner;stage1_last<=stage0_last;stage1_wide<=stage0_wide;
        if(dispatch) begin
            issue_owner<=dispatch_owner;issue_address<=dispatch_address;
            issue_last<=pair_pending || !gpu_wide[selected];
            issue_wide<=pair_pending || gpu_wide[selected];
            if(pair_pending) pair_pending<=0;
            else begin
                issued[selected]<=1;
                round_robin<=selected==CLIENTS-1 ? 0 : selected+1'b1;
                if(gpu_wide[selected]) begin
                    pair_pending<=1;pair_owner<=selected;pair_address<=dispatch_address;
                end
            end
        end
        if(ram_gpu_ack && stage1_valid) begin
            if(stage1_wide && !stage1_last) upper_word[stage1_owner]<=ram_gpu_data;

        end
        if(reset) begin
            cpu_issue_req<=0;cpu_issue_write<=0;cpu_issue_address<=0;cpu_issue_data<=0;cpu_issue_bytes<=0;
            issue_valid<=0;issue_last<=0;issue_wide<=0;issue_address<=0;issue_owner<=0;
            issued<=0;round_robin<=0;pair_owner<=0;pair_pending<=0;pair_address<=0;
            stage0_valid<=0;stage1_valid<=0;stage0_owner<=0;stage1_owner<=0;
            stage0_last<=0;stage1_last<=0;stage0_wide<=0;stage1_wide<=0;
            for(integer c=0;c<CLIENTS;c=c+1) upper_word[c]<=0;
        end
    end
endmodule
