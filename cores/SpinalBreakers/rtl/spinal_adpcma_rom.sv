// SPDX-License-Identifier: GPL-3.0-or-later
// Two-entry ordered JT10 ADPCM-A sample request queue. JT10 cannot stall for
// memory; sticky overflow/late flags make missed sample deadlines observable.
// ym_ce is the existing JT10 enable, not a generated or modified clock.
module spinal_adpcma_rom (
    input logic clk,reset,ym_ce,invalidate,
    input logic roe_n,input logic [19:0] sample_address,input logic [4:0] sample_bank,
    output logic [7:0] sample_data,
    output wire backend_request,output wire [24:0] backend_address,
    input logic backend_ready,input logic [63:0] backend_data,
    output logic fault_overflow,fault_late,output wire idle
);
    logic roe_q=1,rd=0,wr=0,gap=0;
    logic [1:0] count=0;
    logic [19:0] address_q[0:1];logic invalid_bank_q[0:1];logic [3:0] age_q[0:1];
    wire event_request=roe_q && !roe_n;
    wire request=count!=0 && !gap && !invalid_bank_q[rd];
    wire ready,error,cache_idle;wire [63:0] mapped;
    assign idle=count==0 && !gap && !event_request && cache_idle;
    wire pop=count!=0 && !gap && (invalid_bank_q[rd] || ready);
    wire push=event_request && (count<2 || pop);
    spinal_rom_bridge #(.CACHE_ENABLE(1),.CACHE_LINES(64)) cache(.clk(clk),.reset(reset),.invalidate(invalidate),
        .request(request),.region(4'd9),.offset({2'b0,address_q[rd]}),.ready(ready),.error(error),.data(mapped),
        .backend_request(backend_request),.backend_address(backend_address),.backend_ready(backend_ready),.backend_data(backend_data),.idle(cache_idle));
    always_ff @(posedge clk) begin
        if(reset) begin
            roe_q<=1;rd<=0;wr<=0;gap<=0;count<=0;sample_data<=0;fault_overflow<=0;fault_late<=0;
        end else begin
            roe_q<=roe_n;
            if(gap)gap<=0;
            if(event_request && !push)fault_overflow<=1;
            if(ym_ce && count!=0)begin
                if(age_q[rd]>=10)fault_late<=1;else age_q[rd]<=age_q[rd]+1'b1;
                if(count==2)begin
                    if(age_q[~rd]>=10)fault_late<=1;else age_q[~rd]<=age_q[~rd]+1'b1;
                end
            end
            if(push)begin address_q[wr]<=sample_address;invalid_bank_q[wr]<=sample_bank!=0;age_q[wr]<=0;wr<=~wr;end
            if(pop)begin
                sample_data<=invalid_bank_q[rd] ? 8'hff : mapped[7:0];
                if(!invalid_bank_q[rd] && error)fault_late<=1;
                rd<=~rd;gap<=1;
            end
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
        end
    end
endmodule
