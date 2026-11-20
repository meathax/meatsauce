// SPDX-License-Identifier: BSD-3-Clause
// Frame candidate arena: 16384 indexed 64-bit descriptors, then up to 147456
// candidates packed into 128-byte pages (60 ordered 16-bit IDs + next page).
// Each of 50 eight-line bands retains native input order.
// Relative byte addresses occupy 0x00000..0xaffff in external memory.
// Memory replies put an ID pair/page link in rdata[31:0]; wide=1 transfers 64 bits.
// SPLIT_PLANES keeps separate direct (priority 0) and rotated lists per band,
// each in native input order; a query then walks only its own plane.
module gs_sprite_bins #(parameter SPLIT_PLANES=0)(
    input wire clk,reset,start,seal,
    output wire start_ready,
    output wire build_ready,
    output reg sealed,overflow,
    input wire descriptor_valid,
    output wire descriptor_ready,
    input wire [63:0] descriptor,
    output reg [14:0] descriptor_count,
    output reg [17:0] node_count,
    input wire query,
    input wire [5:0] query_band,
    input wire query_direct,
    output wire query_ready,
    output reg query_done,
    output wire output_valid,
    input wire output_ready,
    output reg [63:0] output_descriptor,
    output wire mem_req,
    output reg mem_write,mem_wide,
    output reg [19:0] mem_addr,
    output reg [63:0] mem_wdata,
    input wire mem_ack,
    input wire [63:0] mem_rdata
);
    localparam NIL=18'h3ffff;
    localparam IDLE=0,CLEAR=1,WRITE_DESC=2,GAP_NODE=3,WRITE_NODE=4,
               NEXT_BAND=7,
               READ_NODE=8,GAP_DESC=9,READ_DESC=10,OUTPUT=11,GAP_READ=12,
               FLUSH_CHECK=13,FLUSH_WRITE=14,FLUSH_NEXT=15;
    reg [3:0] state;
    (* ramstyle="MLAB, no_rw_check" *) reg [17:0] heads[0:127];
    (* ramstyle="MLAB, no_rw_check" *) reg [31:0] tail_records[0:127];
    reg [6:0] clear_band;
    reg [5:0] band,last_band;
    reg saved_plane;
    reg [13:0] saved_id,read_id;
    reg [11:0] read_page,page_count;
    reg [4:0] read_word;
    reg [15:0] second_id;
    reg second_pending;
    reg [63:0] saved_descriptor;
    // Adjacent bands revisit immutable descriptors from this sealed frame.
    reg [511:0] descriptor_cached;
    (* ramstyle="MLAB, no_rw_check" *) reg [4:0] descriptor_tags[0:511];
    (* ramstyle="M10K, no_rw_check" *) reg [63:0] descriptor_data[0:511];
    reg [63:0] cached_descriptor;
    wire [8:0] descriptor_read_slot=state==READ_NODE ? mem_rdata[8:0] :
        (state==OUTPUT && second_pending ? second_id[8:0] : read_id[8:0]);
    always @(posedge clk) begin
        cached_descriptor<=descriptor_data[descriptor_read_slot];
        if(state==READ_DESC && mem_ack) begin
            descriptor_data[read_id[8:0]]<=mem_rdata;
            descriptor_tags[read_id[8:0]]<=read_id[13:9];
        end
    end
    wire signed [10:0] y=$signed(descriptor[46:37]);
    wire signed [10:0] bottom=y+$signed({4'b0,descriptor[60:54]});
    wire direct=descriptor[24:23]==0;
    wire [6:0] head_address=state==IDLE ? {SPLIT_PLANES!=0 && query_direct,query_band} : {saved_plane,band};
    wire [17:0] head=heads[head_address];
    wire flushing=state==FLUSH_CHECK || state==FLUSH_WRITE || state==FLUSH_NEXT;
    // Tail record = {page[11:0], used IDs[5:0], pending odd ID[13:0]}.
    wire [31:0] tail_record=tail_records[flushing ? clear_band : {saved_plane,band}];
    wire [11:0] tail_page=tail_record[31:20];
    wire [5:0] tail_used=tail_record[19:14];
    wire new_page=head==NIL || tail_used==60;
    wire [19:0] tail_base=20'h20000+{1'b0,tail_page,7'b0};
    wire head_write=state==CLEAR || (state==NEXT_BAND && head==NIL);
    wire tail_write=state==CLEAR || state==NEXT_BAND;
    wire [6:0] bin_write_address=state==CLEAR ? clear_band : {saved_plane,band};
    always @(posedge clk) begin
        if(head_write) heads[bin_write_address]<=state==CLEAR ? NIL : {6'b0,page_count};
        if(tail_write) tail_records[bin_write_address]<=state==CLEAR ? 32'b0 :
            {new_page ? page_count : tail_page,new_page ? 6'd1 : tail_used+6'd1,saved_id};
    end
    wire signed [10:0] lo=direct && y<84 ? 11'sd84 : (y<0 ? 11'sd0 : y);
    wire signed [10:0] hi=direct && bottom>316 ? 11'sd316 :
                                (bottom>400 ? 11'sd400 : bottom);
    assign build_ready=state==IDLE && !sealed && !reset && !start;
    assign start_ready=state==IDLE && !reset;
    assign descriptor_ready=build_ready && descriptor_count<16384 && !seal;
    assign query_ready=state==IDLE && sealed && !reset && !start;
    assign output_valid=state==OUTPUT;
    assign mem_req=state==WRITE_DESC || state==WRITE_NODE ||
                   state==READ_NODE || state==READ_DESC || state==FLUSH_WRITE;
    always @* begin
        mem_write=0;mem_wide=0;mem_addr=0;mem_wdata=0;
        case(state)
        WRITE_DESC: begin
            mem_write=1;mem_wide=1;mem_addr={3'b0,saved_id,3'b0};mem_wdata=saved_descriptor;
        end
        WRITE_NODE: begin
            mem_write=1;
            if(tail_used==60) begin
                mem_addr=tail_base+20'd120;mem_wdata={52'b0,page_count};
            end else begin
                mem_addr=tail_base+{13'b0,tail_used[5:1],2'b0};
                mem_wdata={32'b0,2'b0,saved_id,2'b0,tail_record[13:0]};
            end
        end
        FLUSH_WRITE: begin
            mem_write=1;
            mem_addr=tail_base+{13'b0,tail_used[5:1],2'b0};
            mem_wdata=tail_used[0] ? {32'b0,16'hffff,2'b0,tail_record[13:0]} : 64'h00000000ffffffff;
        end
        READ_NODE: mem_addr=20'h20000+{1'b0,read_page,7'b0}+{13'b0,read_word,2'b0};
        READ_DESC: begin mem_wide=1;mem_addr={3'b0,read_id,3'b0};end
        endcase
    end
    always @(posedge clk) begin
        query_done<=0;
        case(state)
        IDLE: begin
            if(seal && !sealed) begin clear_band<=0;state<=FLUSH_CHECK;end
            if(descriptor_valid && descriptor_ready) begin
                if(lo>=hi || descriptor[53:47]==0 || descriptor[60:54]==0) begin
                    overflow<=1;sealed<=1;
                end else begin
                    saved_descriptor<=descriptor;saved_id<=descriptor_count[13:0];saved_plane<=SPLIT_PLANES!=0 && direct;
                    descriptor_count<=descriptor_count+1'b1;
                    band<=lo[8:3];last_band<=(hi-1'b1)>>3;state<=WRITE_DESC;
                end
            end
            if(query && query_ready) begin
                if(query_band>=50) begin overflow<=1;query_done<=1;end
                else if(head==NIL) query_done<=1;
                else begin read_page<=head[11:0];read_word<=0;state<=READ_NODE;end
            end
        end
        CLEAR: begin
            if(clear_band==(SPLIT_PLANES!=0 ? 7'd113 : 7'd49)) state<=IDLE;
            else clear_band<=clear_band+1'b1;
        end
        WRITE_DESC: if(mem_ack) state<=GAP_NODE;
        GAP_NODE: if(node_count>=147456) begin overflow<=1;sealed<=1;state<=IDLE;end
                  else state<=head==NIL || (tail_used!=60 && !tail_used[0]) ? NEXT_BAND : WRITE_NODE;
        WRITE_NODE: if(mem_ack) begin
            state<=NEXT_BAND;
        end
        NEXT_BAND: begin
            node_count<=node_count+1'b1;
            if(new_page) page_count<=page_count+1'b1;
            if(band==last_band) state<=IDLE;
            else begin band<=band+1'b1;state<=GAP_NODE;end
        end
        READ_NODE: if(mem_ack) begin
            if(read_word==30) begin
                if(mem_rdata[31:0]==32'hffffffff) begin query_done<=1;state<=IDLE;end
                else begin read_page<=mem_rdata[11:0];read_word<=0;state<=GAP_READ;end
            end else if(mem_rdata[15:0]==16'hffff) begin query_done<=1;state<=IDLE;end
            else begin
                read_id<=mem_rdata[13:0];second_id<=mem_rdata[31:16];second_pending<=1;state<=GAP_DESC;
            end
        end
        GAP_DESC: if(descriptor_cached[read_id[8:0]] && descriptor_tags[read_id[8:0]]==read_id[13:9]) begin
            output_descriptor<=cached_descriptor;state<=OUTPUT;
        end else state<=READ_DESC;
        READ_DESC: if(mem_ack) begin
            descriptor_cached[read_id[8:0]]<=1;
            output_descriptor<=mem_rdata;state<=OUTPUT;
        end
        OUTPUT: if(output_ready) begin
            if(second_pending) begin
                second_pending<=0;
                if(second_id==16'hffff) begin query_done<=1;state<=IDLE;end
                else begin read_id<=second_id[13:0];state<=GAP_DESC;end
            end else begin read_word<=read_word+1'b1;state<=GAP_READ;end
        end
        GAP_READ: state<=READ_NODE;
        FLUSH_CHECK: state<=tail_used==0 ? FLUSH_NEXT : FLUSH_WRITE;
        FLUSH_WRITE: if(mem_ack) state<=FLUSH_NEXT;
        FLUSH_NEXT: begin
            if(clear_band==(SPLIT_PLANES!=0 ? 7'd113 : 7'd49)) begin sealed<=1;state<=IDLE;end
            else begin clear_band<=clear_band+1'b1;state<=FLUSH_CHECK;end
        end
        endcase
        if(start && state==IDLE) begin
            descriptor_cached<=0;
            state<=CLEAR;clear_band<=0;sealed<=0;overflow<=0;descriptor_count<=0;node_count<=0;page_count<=0;
        end
        if(reset) begin
            descriptor_cached<=0;
            state<=IDLE;sealed<=1;overflow<=0;descriptor_count<=0;node_count<=0;page_count<=0;
            query_done<=0;clear_band<=0;band<=0;last_band<=0;saved_plane<=0;
            saved_id<=0;read_id<=0;read_page<=0;read_word<=0;second_id<=0;second_pending<=0;saved_descriptor<=0;output_descriptor<=0;
        end
    end
endmodule
