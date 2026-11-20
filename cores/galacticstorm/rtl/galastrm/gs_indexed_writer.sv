// SPDX-License-Identifier: BSD-3-Clause
// Coalesce indexed pixels into masked 64-bit writes, with a small burst queue.
// Output is a streaming transaction port: ACK accepts the current held record.
module gs_indexed_writer #(parameter FIFO_BITS=5)(
    input wire clk,reset,flush,
    input wire pixel_valid,
    output wire pixel_ready,
    input wire [8:0] pixel_x,pixel_y,
    input wire [15:0] pixel_index,
    input wire [24:0] base_address,
    output wire idle,
    output wire mem_req,
    output wire [24:0] mem_addr,
    output wire [63:0] mem_data,
    output wire [7:0] mem_bytes,
    input wire mem_ack
);
    localparam DEPTH=1<<FIFO_BITS;
    reg pack_valid;
    reg [24:0] pack_address;
    reg [63:0] pack_data;
    reg [7:0] pack_bytes;
    reg [FIFO_BITS-1:0] read_pointer,write_pointer;
    reg [FIFO_BITS:0] count;
    (* ramstyle="MLAB, no_rw_check" *) reg [96:0] records[0:DEPTH-1];
    reg [96:0] ram_data,output_records[0:1];
    reg pending,output_read,output_write;
    reg [1:0] output_count;
    wire [24:0] pixel_address=base_address+{6'b0,pixel_y,pixel_x,1'b0};
    wire [24:0] word_address={pixel_address[24:3],3'b0};
    wire [1:0] lane=pixel_address[2:1];
    wire same_word=!pack_valid || word_address==pack_address;
    wire space=count<DEPTH; // Avoid simultaneous full-queue overwrite/read.
    assign pixel_ready=same_word && (lane!=3 || space);
    wire fire=pixel_valid && pixel_ready;
    wire flush_partial=pack_valid && ((pixel_valid && !same_word) || (flush && !pixel_valid));
    wire finish_word=fire && lane==3;
    wire push=space && (finish_word || flush_partial);
    reg [63:0] next_data;
    wire [7:0] next_bytes=(pack_valid ? pack_bytes : 8'b0) | (8'h03<<(lane*2));
    wire [96:0] push_record=finish_word ? {word_address,next_data,next_bytes} : {pack_address,pack_data,pack_bytes};
    assign mem_req=output_count!=0;
    assign {mem_addr,mem_data,mem_bytes}=output_records[output_read];
    wire pop=mem_req && mem_ack;
    wire [2:0] projected={1'b0,output_count}+{2'b0,pending}-{2'b0,pop};
    wire issue=count!=0 && projected<2;
    assign idle=!pack_valid && count==0 && !pending && output_count==0;
    always @* begin
        next_data=pack_valid ? pack_data : 64'b0;
        next_data[lane*16 +: 16]=pixel_index;
    end
    always @(posedge clk) begin
        ram_data<=records[read_pointer];
        if(push) records[write_pointer]<=push_record;
    end
    always @(posedge clk) begin
        pending<=issue;
        if(issue) read_pointer<=read_pointer+1'b1;
        if(push) write_pointer<=write_pointer+1'b1;
        count<=count+push-issue;
        if(pending) begin output_records[output_write]<=ram_data;output_write<=!output_write;end
        if(pop) output_read<=!output_read;
        output_count<=output_count+pending-pop;
        if(fire) begin
            pack_valid<=lane!=3;pack_address<=word_address;pack_data<=next_data;pack_bytes<=next_bytes;
        end else if(push && flush_partial) pack_valid<=0;
        if(reset) begin
            pack_valid<=0;pack_address<=0;pack_data<=0;pack_bytes<=0;
            read_pointer<=0;write_pointer<=0;count<=0;pending<=0;
            output_read<=0;output_write<=0;output_count<=0;output_records[0]<=0;output_records[1]<=0;
        end
    end
endmodule
