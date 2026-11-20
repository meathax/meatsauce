// SPDX-License-Identifier: BSD-3-Clause
// screen_rotate emits write pulses without observing DDRAM_BUSY. Queue those
// commands before the shared DDR arbiter; never silently corrupt a frame.
module gs_ddr_write_queue #(parameter BITS=10)(
    input wire clk,reset,push,input wire [28:0] address,
    input wire [63:0] data,input wire [7:0] bytes,
    output wire we,output wire [28:0] out_address,
    output wire [63:0] out_data,output wire [7:0] out_bytes,
    input wire busy,output reg overflow
);
    localparam DEPTH=1<<BITS;
    (* ramstyle="M10K, no_rw_check" *) reg [100:0] entries[0:DEPTH-1];
    reg [BITS-1:0] wp,rp;
    reg [BITS:0] count;
    // Synchronous read, with a separate held output command.
    reg [100:0] ram_data,head;
    reg fetching,valid;
    wire pop=valid && !busy;
    wire enqueue=push && count<DEPTH;
    assign we=valid;
    assign {out_address,out_data,out_bytes}=head;
    always @(posedge clk)begin
        ram_data<=entries[rp];
        if(enqueue)entries[wp]<={address,data,bytes};
        if(push && !enqueue)overflow<=1;
        count<=count+enqueue-fetching;
        if(enqueue)wp<=wp+1'b1;
        fetching<=0;
        if(!valid && !fetching && count!=0)begin fetching<=1;rp<=rp+1'b1;end
        if(fetching)begin head<=ram_data;valid<=1;end
        if(pop)valid<=0;
        if(reset)begin wp<=0;rp<=0;count<=0;fetching<=0;valid<=0;head<=0;overflow<=0;end
    end
endmodule
