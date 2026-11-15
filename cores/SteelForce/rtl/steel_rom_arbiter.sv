// Three immutable-ROM clients. Ownership/address register before presentation.
// Round-robin advances after actual memory completions, independent of cache hits.
module steel_rom_arbiter(
    input wire clk,reset,
    input wire [2:0] request,
    input wire [24:0] address0,address1,address2,
    output reg [2:0] acknowledged,
    output wire [63:0] data,
    output reg memory_request,
    output reg [24:0] memory_address,
    input wire memory_ready,memory_acknowledged,
    input wire [63:0] memory_data
);
    localparam IDLE=0,WAIT_DONE=1,DROP=2;
    reg [1:0] state,owner,next_owner,chosen;
    reg found;
    assign data=memory_data;
    always @(*)begin
        found=0;chosen=next_owner;
        case(next_owner)
            0:if(request[0])begin chosen=0;found=1;end
              else if(request[1])begin chosen=1;found=1;end
              else if(request[2])begin chosen=2;found=1;end
            1:if(request[1])begin chosen=1;found=1;end
              else if(request[2])begin chosen=2;found=1;end
              else if(request[0])begin chosen=0;found=1;end
            default:if(request[2])begin chosen=2;found=1;end
              else if(request[0])begin chosen=0;found=1;end
              else if(request[1])begin chosen=1;found=1;end
        endcase
    end
    always @(posedge clk)begin
        if(reset)begin
            state<=IDLE;owner<=0;next_owner<=0;memory_request<=0;
            memory_address<=0;acknowledged<=0;
        end else begin
            acknowledged<=0;
            case(state)
                IDLE:if(found && memory_ready)begin
                    owner<=chosen;memory_request<=1;state<=WAIT_DONE;
                    case(chosen)
                        0:memory_address<=address0;
                        1:memory_address<=address1;
                        default:memory_address<=address2;
                    endcase
                end
                WAIT_DONE:if(memory_acknowledged)begin
                    acknowledged[owner]<=1;memory_request<=0;
                    next_owner<=owner==2 ? 2'd0 : owner+1'b1;state<=DROP;
                end
                DROP:if(memory_ready)state<=IDLE;
            endcase
        end
    end
endmodule
