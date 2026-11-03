// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-array RAM idiom from Batman batman_vram.sv, pinned in donors/video.
// Target semantics: MAME0.289 thunderj.cpp map and atarivad.cpp latched writes.
// CPU/work VRAM 3f0000..3fffff. No donor slot schedule is copied.
// Eight separately addressed 4K-word banks permit PF writes and the paired
// attribute-bank write without adding a second write port to any RAM.
module thunderjaws_video_ram (
    input wire clk_sys,init_reset,
    input wire request_valid,
    output wire request_ready,
    input wire [14:0] word_address,
    input wire request_read,
    input wire [1:0] request_lanes,
    input wire [15:0] request_data,
    input wire attribute_enable,
    input wire [7:0] attribute_msb,attribute_lsb,
    output reg response_valid,
    output wire [15:0] response_data,
    // Serialized read-only port for EOF/diagnostics. Renderer allocation and
    // the physical board's access priorities remain a separate integration.
    input wire aux_valid,
    output wire aux_ready,
    input wire [14:0] aux_address,
    output reg aux_response_valid,
    output wire [15:0] aux_response_data,
    // The existing broadcast auxiliary read already accesses every bank at
    // this index. Expose its paired attribute without duplicating RAM/ports.
    output wire [15:0] aux_attribute_data
);
    wire accept=request_valid && request_ready;
    wire writing=accept && !request_read;
    assign request_ready=!init_reset;
    // No same-address mixed-port read/write ambiguity is exposed.
    assign aux_ready=!init_reset && !request_valid;
    wire aux_accept=aux_valid && aux_ready;
    reg [2:0] response_bank,aux_bank;
    wire [15:0] cpu_q[0:7],aux_q[0:7];
    assign response_data=cpu_q[response_bank];
    assign aux_response_data=aux_q[aux_bank];
    assign aux_attribute_data=aux_q[2];
    always @(posedge clk_sys) begin
        response_valid<=accept;
        aux_response_valid<=aux_accept;
        if(init_reset) begin response_bank<=0;aux_bank<=0;end
        else begin
            if(accept)response_bank<=word_address[14:12];
            if(aux_accept)aux_bank<=aux_address[14:12];
        end
    end
    genvar b;
    generate for(b=0;b<8;b=b+1)begin:bank
        reg [7:0] hi[0:4095],lo[0:4095];
        reg [7:0] cpu_hi,cpu_lo,aux_hi,aux_lo;
        integer i;
        initial for(i=0;i<4096;i=i+1)begin hi[i]=0;lo[i]=0;end
        wire direct_write=writing && word_address[14:12]==b;
        wire attr_hi=writing && attribute_enable && b==2 && word_address[14:12]==0;
        wire attr_lo=writing && attribute_enable && b==2 && word_address[14:12]==1;
        always @(posedge clk_sys) begin
            if(accept) begin
                cpu_hi<=hi[word_address[11:0]];
                cpu_lo<=lo[word_address[11:0]];
            end
            if(direct_write && request_lanes[1])hi[word_address[11:0]]<=request_data[15:8];
            else if(attr_hi)hi[word_address[11:0]]<=attribute_msb;
            if(direct_write && request_lanes[0])lo[word_address[11:0]]<=request_data[7:0];
            else if(attr_lo)lo[word_address[11:0]]<=attribute_lsb;
        end
        always @(posedge clk_sys) if(aux_accept)begin
            aux_hi<=hi[aux_address[11:0]];
            aux_lo<=lo[aux_address[11:0]];
        end
        assign cpu_q[b]={cpu_hi,cpu_lo};
        assign aux_q[b]={aux_hi,aux_lo};
    end endgenerate
endmodule
