// SPDX-License-Identifier: BSD-3-Clause
// TC0100SCN text tile-row sampler, Galactic Storm offsets (-48,-56).
// MAME 0.289 tc0100scn.cpp (Nicola Salmoria, David Graves).
// Normal-width/unflipped mode only at this milestone; unsupported flags
// remain visible. Row output supports a subsequent streamed line buffer.
module gs_scn_text #(parameter CACHE_FONT=0)(
    input logic invalidate,
    input logic clk,reset,query,
    input logic [8:0] x,y,
    input logic [127:0] controls,
    output logic valid,opaque,supported,
    output logic [11:0] pixel_index,
    output logic [95:0] row_indices,
    output logic [7:0] row_opaque,
    output logic mem_req,output logic [15:0] mem_addr,
    input logic mem_ack,input logic [15:0] mem_rdata
);
    typedef enum logic [2:0] {IDLE,ATTR,GAP,FONT,DONE,CACHED,ATTR_CHECK} state_t;
    state_t state;
    wire [8:0] source_x=x-controls[32 +: 9]-9'd32;
    wire [8:0] source_y=y-controls[80 +: 9]-9'd64;
    logic [2:0] px,py;
    logic [5:0] color;
    logic flip_x,disabled;
    logic [2:0] bit_x;
    logic [1:0] pen;
    // Column-indexed attribute rows are immutable within the caller's snapshot.
    (* ramstyle="MLAB, no_rw_check" *) logic [21:0] attr_cache[0:63];
    logic [21:0] attr_read;
    logic [63:0] attr_valid;
    logic [5:0] attr_column,attr_y;
    wire attr_hit=attr_valid[attr_column] && attr_read[21:16]==attr_y;
    wire [15:0] attr_value=state==ATTR_CHECK ? attr_read[15:0] : mem_rdata;
    always_ff @(posedge clk) begin
        attr_read<=attr_cache[source_x[8:3]];
        if(CACHE_FONT && state==ATTR && mem_ack) attr_cache[attr_column]<={attr_y,mem_rdata};
        if(reset || invalidate) attr_valid<=0;
        else if(CACHE_FONT && state==ATTR && mem_ack) attr_valid[attr_column]<=1;
        if(query && state==IDLE) begin attr_column<=source_x[8:3];attr_y<=source_y[8:3];end
    end
    logic cache_valid;
    logic [10:0] cache_tag;
    logic [15:0] cache_row;
    wire [10:0] requested_font={attr_value[7:0],(py ^ (attr_value[15] ? 3'd7 : 3'd0))};
    wire [15:0] font_row=state==CACHED ? cache_row : mem_rdata;
    always_ff @(posedge clk) begin
        if(reset || invalidate) cache_valid<=0;
        else if(CACHE_FONT && state==FONT && mem_ack) begin
            cache_valid<=1;cache_tag<=mem_addr[11:1];cache_row<=mem_rdata;
        end
    end
    integer p;
    assign mem_req=state==ATTR || state==FONT;
    always_comb begin
        bit_x=px ^ (flip_x ? 3'd7 : 3'd0);
        pen={font_row[15-bit_x],font_row[7-bit_x]};
    end
    always_ff @(posedge clk) begin
        valid<=0;
        if(reset) begin
            state<=IDLE;px<=0;py<=0;color<=0;flip_x<=0;disabled<=0;
            mem_addr<=0;pixel_index<=0;opaque<=0;supported<=1;
            row_indices<=0;row_opaque<=0;
        end else case(state)
            IDLE: if(query) begin
                px<=source_x[2:0];py<=source_y[2:0];
                disabled<=controls[98];
                supported<=!controls[100] && !controls[112];
                mem_addr<=16'h4000+{3'd0,source_y[8:3],source_x[8:3],1'b0};
                state<=CACHE_FONT ? ATTR_CHECK : ATTR;
            end
            ATTR,ATTR_CHECK: if(state==ATTR_CHECK && !attr_hit) state<=ATTR;
            else if(state==ATTR_CHECK || mem_ack) begin
                color<=attr_value[13:8];flip_x<=attr_value[14];
                mem_addr<=16'h6000+{4'd0,attr_value[7:0],(py ^ (attr_value[15] ? 3'd7 : 3'd0)),1'b0};
                state<=CACHE_FONT && cache_valid && cache_tag==requested_font ? CACHED : GAP;
            end
            GAP: state<=FONT;
            FONT,CACHED: if(state==CACHED || mem_ack) begin
                // TC0100SCN text inherits background granularity (16), even
                // though its glyphs contain only two bitplanes.
                pixel_index<={2'd0,color,2'b0,pen};opaque<=pen!=0 && !disabled && supported;
                for(p=0;p<8;p=p+1) begin
                    row_indices[12*p +: 12]<={2'd0,color,2'b0,
                        font_row[15-(p ^ (flip_x ? 7 : 0))],
                        font_row[7-(p ^ (flip_x ? 7 : 0))]};
                    row_opaque[p]<=!disabled && supported &&
                        (font_row[15-(p ^ (flip_x ? 7 : 0))] || font_row[7-(p ^ (flip_x ? 7 : 0))]);
                end
                valid<=1;state<=DONE;
            end
            DONE: state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
