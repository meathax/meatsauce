// Full 128KiB main work RAM backed by a private SDRAM region.
// CPU stores are posted in order; ordered score accesses fence the queue.
// A held request has one reply and must fall before a subsequent command.
module rf_workram #(
    parameter [25:0] BASE=26'h1e00000,
    parameter CLEAR_ON_INIT=0
)(
    input wire clk,clk_ram,init,abort,req,write,ordered,
    input wire [15:0] addr,wdata,input wire [1:0] be,
    output reg [15:0] q,output reg ready,output wire busy,
    output reg [26:1] ch_addr,output reg [15:0] ch_din,
    output reg [1:0] ch_be,output reg ch_req,ch_rnw,
    input wire ch_ready,input wire [63:0] ch_dout
);
    localparam [2:0] IDLE=0,LOOKUP=1,WAIT_READ=2,WAIT_WRITE=3,FINISH=4;
    localparam [1:0] STORE=0,FETCH=1,ORDERED_WRITE=2,CLEAR=3;
    reg [2:0] state;
    reg [15:0] client_addr,client_data;
    reg [1:0] client_be;
    reg client_write,client_ordered;
    reg [33:0] stores[0:7];
    reg [2:0] store_wp,store_rp;
    reg [3:0] store_count;
    wire [33:0] store_head=stores[store_rp];
    reg active,cancelled;
    reg clearing;
    reg [15:0] clear_addr;
    reg [1:0] kind,low_gap;
    reg [63:0] cache_valid;
    (* ramstyle="MLAB" *) reg [7:0] cache_tag[0:63];
    wire [5:0] cache_index=state==IDLE ? addr[7:2] : client_addr[7:2];
    wire [63:0] cache_q;
    reg cache_we;
    reg [5:0] cache_wa;
    reg [63:0] cache_wdata;
    rf_bram #(.WIDTH(64),.AW(6)) cache_data(
        .clk(clk),.waddr(cache_wa),.wdata(cache_wdata),.wren(cache_we),
        .raddr(cache_index),.q(cache_q));
    wire hit=cache_valid[client_addr[7:2]] && cache_tag[client_addr[7:2]]==client_addr[15:8];
    function automatic [63:0] merge_word(input [63:0] line_data,
        input [1:0] lane,input [15:0] value,input [1:0] mask);
        reg [63:0] value_out;
        begin
            value_out=line_data;
            if(mask[0])value_out[{lane,4'b0000}+:8]=value[7:0];
            if(mask[1])value_out[({lane,4'b0000}+6'd8)+:8]=value[15:8];
            merge_word=value_out;
        end
    endfunction
    // Completion control is synchronized; the complete burst is held until
    // a later transaction finishes, well after this reply is consumed.
    reg done_t;
    reg [63:0] ram_reply;
    always @(posedge clk_ram) begin
        if(init)begin done_t<=0;ram_reply<=0;end
        // ch_ready is already qualified by the RAM-domain arbiter's retained
        // WORK owner. Raw SYS ch_req is not a RAM-domain capture enable.
        else if(ch_ready)begin ram_reply<=ch_dout;done_t<=~done_t;end
    end
    (* preserve, dont_replicate, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name SYNCHRONIZATION_REGISTER_CHAIN_LENGTH 3" *) reg done_s,done_1,done_2;
    reg done_3;
    always @(posedge clk)begin
        if(init)begin done_s<=0;done_1<=0;done_2<=0;done_3<=0;end
        else begin done_s<=done_t;done_1<=done_s;done_2<=done_1;done_3<=done_2;end
    end
    wire done_edge=done_2^done_3;
    wire push=!clearing && state==LOOKUP && !abort && client_write && !client_ordered && store_count<8;
    wire pop=active && done_edge && kind==STORE;
    assign busy=clearing || active || store_count!=0 || state!=IDLE;
    always @(posedge clk)begin
        ready<=0;cache_we<=0;
        if(init)begin
            state<=IDLE;q<=0;store_wp<=0;store_rp<=0;store_count<=0;
            active<=0;cancelled<=0;kind<=STORE;low_gap<=0;
            clearing<=CLEAR_ON_INIT;clear_addr<=0;
            cache_valid<=0;cache_wa<=0;cache_wdata<=0;
            ch_req<=0;ch_addr<=0;ch_din<=0;ch_be<=0;ch_rnw<=1;
            client_addr<=0;client_data<=0;client_be<=0;client_write<=0;client_ordered<=0;
        end else begin
            store_count<=store_count+{3'd0,push}-{3'd0,pop};
            if(push)begin stores[store_wp]<={client_addr,client_data,client_be};store_wp<=store_wp+1'b1;end
            if(pop)store_rp<=store_rp+1'b1;
            if(low_gap!=0)low_gap<=low_gap-1'b1;
            if(active && done_edge)begin
                active<=0;ch_req<=0;low_gap<=2;
                if(kind==CLEAR)begin
                    if(clear_addr==16'hffff)clearing<=0;
                    else clear_addr<=clear_addr+1'b1;
                end
                if(!cancelled && !abort && kind==FETCH && state==WAIT_READ)begin
                    q<=ram_reply[{client_addr[1:0],4'b0000}+:16];
                    cache_wa<=client_addr[7:2];cache_wdata<=ram_reply;cache_we<=1;
                    cache_tag[client_addr[7:2]]<=client_addr[15:8];
                    cache_valid[client_addr[7:2]]<=1;
                    ready<=1;state<=FINISH;
                end else if(!cancelled && !abort && kind==ORDERED_WRITE && state==WAIT_WRITE)begin
                    ready<=1;state<=FINISH;
                end
                cancelled<=0;
            end
            // An accepted store survives logical reset. Outstanding reads and
            // ordered writes drain too, but their old reply is never reused.
            if(abort)begin
                cache_valid<=0;state<=IDLE;
                if(active && kind!=STORE && kind!=CLEAR)cancelled<=1;
            end else if(!clearing)case(state)
                IDLE:if(req)begin
                    client_addr<=addr;client_data<=wdata;client_be<=be;
                    client_write<=write;client_ordered<=ordered;state<=LOOKUP;
                end
                LOOKUP:begin
                    if(client_write)begin
                        if(client_ordered)begin cache_valid<=0;state<=WAIT_WRITE;end
                        else if(push)begin
                            if(hit)begin
                                cache_we<=1;cache_wa<=client_addr[7:2];
                                cache_wdata<=merge_word(cache_q,client_addr[1:0],client_data,client_be);
                            end
                            ready<=1;state<=FINISH;
                        end
                    end else if(!client_ordered && hit)begin
                        q<=cache_q[{client_addr[1:0],4'b0000}+:16];ready<=1;state<=FINISH;
                    end else state<=WAIT_READ;
                end
                FINISH:if(!req)state<=IDLE;
                default:;
            endcase
            // Payload is registered once and held throughout the native
            // controller request. Two low CPU clocks rearm its edge detector.
            if(!active && low_gap==0)begin
                if(clearing)begin
                    // Match the former native FPGA RAM's power-up zeros.
                    // Only PLL init starts this; logical reset cannot cancel
                    // an accepted clear or erase restored score contents.
                    ch_addr<=BASE+{10'd0,clear_addr};ch_din<=0;ch_be<=2'b11;
                    ch_rnw<=0;ch_req<=1;active<=1;kind<=CLEAR;cancelled<=0;
                end else if(store_count!=0)begin
                    ch_addr<=BASE+{10'd0,store_head[33:18]};
                    ch_din<=store_head[17:2];ch_be<=store_head[1:0];
                    ch_rnw<=0;ch_req<=1;active<=1;kind<=STORE;cancelled<=0;
                end else if(!abort && (state==WAIT_READ || state==WAIT_WRITE))begin
                    ch_addr<=BASE+(state==WAIT_READ ? {10'd0,client_addr[15:2],2'b00} : {10'd0,client_addr});
                    ch_din<=client_data;ch_be<=client_be;
                    ch_rnw<=state==WAIT_READ;ch_req<=1;active<=1;
                    kind<=state==WAIT_READ ? FETCH : ORDERED_WRITE;cancelled<=0;
                end
            end
        end
    end
endmodule
