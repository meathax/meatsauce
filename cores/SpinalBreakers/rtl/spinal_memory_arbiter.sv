// SPDX-License-Identifier: GPL-3.0-or-later
// Same-clock, two-client, one-outstanding granule arbiter. Each client holds
// request/address until ready and drops request between transactions. Backend
// samples requests synchronously, returns no earlier than a later edge and
// holds ready only until request is removed; ready must not depend on request
// combinationally. In-flight backend work is drained rather than reset away.
module spinal_memory_arbiter (
    input logic clk,reset,
    input logic request0,request1,
    input logic [24:0] address0,address1,
    input logic write0,write1,input logic [15:0] write_data0,write_data1,
    output wire ready0,ready1,
    output wire [63:0] data0,data1,
    output wire backend_request,output wire idle,
    output wire [24:0] backend_address,
    output wire backend_write,output wire [15:0] backend_write_data,
    input logic backend_ready,
    input logic [63:0] backend_data
);
    typedef enum logic [1:0] {IDLE,WAIT_REPLY,RESPONSE,DRAIN} state_t;
    state_t state=IDLE;
    assign idle=state==IDLE && !backend_ready;
    logic owner,last_owner=1'b1,discard,released;
    logic [24:0] held_address;
    logic held_write;logic [15:0] held_write_data;
    logic [63:0] response_data;
    wire selected=request0 && request1 ? !last_owner : request1;
    wire any_request=request0 || request1;
    wire selected_request=owner ? request1 : request0;
    wire fresh=state==IDLE && !reset && any_request && !backend_ready;
    wire reply=state==WAIT_REPLY && backend_ready && !discard && selected_request;
    // Arbitration and stale-ack checks affect edge admission only.
    assign backend_request=state==WAIT_REPLY;
    assign backend_address=state==IDLE ? (selected ? address1 : address0) : held_address;
    assign backend_write=state==IDLE ? (selected ? write1 : write0) : held_write;
    assign backend_write_data=state==IDLE ? (selected ? write_data1 : write_data0) : held_write_data;
    assign ready0=(reply && !owner) || (state==RESPONSE && !owner && request0);
    assign ready1=(reply && owner) || (state==RESPONSE && owner && request1);
    assign data0=reply ? backend_data : response_data;
    assign data1=reply ? backend_data : response_data;
    always_ff @(posedge clk) begin
        case(state)
            IDLE: if(fresh) begin
                owner<=selected;last_owner<=selected;
                held_address<=selected ? address1 : address0;
                held_write<=selected ? write1 : write0;held_write_data<=selected ? write_data1 : write_data0;
                discard<=0;released<=0;state<=WAIT_REPLY;
            end
            WAIT_REPLY: begin
                if(!selected_request) begin discard<=1;released<=1;end
                if(backend_ready) begin
                    if(discard || !selected_request) state<=DRAIN;
                    else begin response_data<=backend_data;state<=RESPONSE;end
                end
            end
            RESPONSE: if(!selected_request) begin
                released<=1;
                if(!reset && !backend_ready) state<=IDLE;
                else state<=DRAIN;
            end
            DRAIN: begin
                if(!selected_request) released<=1;
                if(!reset && !backend_ready && (released || !selected_request)) state<=IDLE;
            end
            default:state<=IDLE;
        endcase
    end
endmodule
