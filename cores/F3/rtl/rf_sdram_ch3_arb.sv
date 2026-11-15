// Retained-transaction ownership for the existing SDRAM channel3.
// Producers hold payload/request until their qualified completion. Native
// request stays low for two full RAM clocks before another rising edge.
module rf_sdram_ch3_arb(
    input wire clk_ram,init,
    input wire [26:1] l_addr,p_addr,w_addr,
    input wire [15:0] l_din,p_din,w_din,
    input wire [1:0] l_be,p_be,w_be,
    input wire l_req,p_req,w_req,l_rnw,p_rnw,w_rnw,
    output wire l_ready,p_ready,w_ready,
    output reg [26:1] ch_addr,output reg [15:0] ch_din,
    output reg [1:0] ch_be,output wire ch_req,
    output reg ch_rnw,input wire ch_ready
);
    localparam [1:0] IDLE=0,ACTIVE=1,DROP=2,GAP=3;
    reg [1:0] state,owner;
    reg [1:0] gap;
    (* dont_replicate, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name SYNCHRONIZATION_REGISTER_CHAIN_LENGTH 2" *) reg [2:0] req_s,req_sync;
    always @(posedge clk_ram)begin
        if(init)begin req_s<=0;req_sync<=0;end
        else begin req_s<={p_req,w_req,l_req};req_sync<=req_s;end
    end
    assign ch_req=state==ACTIVE;
    assign l_ready=state==ACTIVE && owner==0 && ch_ready;
    assign w_ready=state==ACTIVE && owner==1 && ch_ready;
    assign p_ready=state==ACTIVE && owner==2 && ch_ready;
    always @(posedge clk_ram)begin
        if(init)begin state<=IDLE;owner<=0;gap<=0;ch_addr<=0;ch_din<=0;ch_be<=0;ch_rnw<=1;end
        else case(state)
            IDLE:begin
                if(req_sync[0])begin
                    owner<=0;ch_addr<=l_addr;ch_din<=l_din;ch_be<=l_be;ch_rnw<=l_rnw;state<=ACTIVE;
                end else if(req_sync[1])begin
                    owner<=1;ch_addr<=w_addr;ch_din<=w_din;ch_be<=w_be;ch_rnw<=w_rnw;state<=ACTIVE;
                end else if(req_sync[2])begin
                    owner<=2;ch_addr<=p_addr;ch_din<=p_din;ch_be<=p_be;ch_rnw<=p_rnw;state<=ACTIVE;
                end
            end
            ACTIVE:if(ch_ready)state<=DROP;
            DROP:if(!req_sync[owner])begin gap<=2;state<=GAP;end
            GAP:if(gap==0)state<=IDLE;else gap<=gap-1'b1;
        endcase
    end
endmodule
