// SPDX-License-Identifier: GPL-3.0-or-later
// Byte-array RAM idiom from Batman batman_vram.sv, pinned in donors/video.
// Target semantics: MAME0.289 thunderj.cpp map and atarivad.cpp latched writes.
// Packed four-column bank3 retains identical bits and CPU byte semantics.
// Dedicated MO reads use otherwise unused bank3/4 B cycles; CPU writes and
// conflicting EOF/alpha reads retain priority. Optional coherent rendering keeps
// CPU and EOF reads live while the display uses a frame-boundary view.
// CPU/work VRAM 3f0000..3fffff. No donor slot schedule is copied.
// Eight separately addressed 4K-word banks permit PF writes and the paired
// attribute-bank write without adding a second write port to any RAM.
module thunderjaws_video_ram_packed #(parameter integer SNAPSHOT_ENABLE=0) (
    input wire clk_sys,init_reset,
    input wire snapshot_start,aux_snapshot,
    output wire snapshot_initialized,snapshot_fault,
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
    output wire [15:0] aux_attribute_data,
    input wire mo_valid,
    output wire mo_ready,
    input wire [14:0] mo_address,
    output reg mo_response_valid,
    output wire [63:0] mo_response_data
);
    wire accept=request_valid && request_ready;
    wire writing=accept && !request_read;
    wire [7:0] bank_initialized,bank_ready,bank_fault;
    assign snapshot_initialized=!init_reset && &bank_initialized;
    assign snapshot_fault=|bank_fault;
    assign request_ready=!init_reset && &bank_ready;
    // No same-address mixed-port read/write ambiguity is exposed.
    assign aux_ready=snapshot_initialized && !request_valid;
    wire aux_accept=aux_valid && aux_ready;
    reg [2:0] response_bank,aux_bank;
    wire [15:0] cpu_q[0:7],aux_q[0:7];
    wire mo_accept=mo_valid && mo_ready;
    wire aux_mo_conflict=aux_valid && aux_ready && aux_address[14:12]==mo_address[14:12];
    assign mo_ready=snapshot_initialized && !(writing && word_address[14:12]==mo_address[14:12]) && !aux_mo_conflict;
    reg mo_packed;
    wire [63:0] descriptor_data;
    assign mo_response_data=mo_packed ? descriptor_data : {48'd0,aux_q[4]};
    always @(posedge clk_sys)begin
        mo_response_valid<=mo_accept;
        if(mo_accept)mo_packed<=mo_address[14:12]==3;
    end
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
    genvar b,c;
    generate for(b=0;b<8;b=b+1)begin:bank
        if(b==3)begin:packed_mo
            wire [15:0] cpu_column[0:3],aux_column[0:3];
            wire [3:0] column_initialized,column_ready,column_fault;
            assign bank_initialized[b]=&column_initialized;
            assign bank_ready[b]=&column_ready;
            assign bank_fault[b]=|column_fault;
            reg [1:0] cpu_select,aux_select;
            always @(posedge clk_sys)begin
                if(accept)cpu_select<=word_address[1:0];
                if(aux_accept)aux_select<=aux_address[1:0];
            end
            wire mo_b_read=mo_accept && mo_address[14:12]==3;
            wire b_read_enable=mo_b_read || aux_accept;
            wire [9:0] b_read_address=mo_b_read ? mo_address[11:2] : aux_address[11:2];
            for(c=0;c<4;c=c+1)begin:column
                wire [7:0] ch,cl,ah,al;
                wire column_write=writing && word_address[14:12]==3 && word_address[1:0]==c;
                thunderjaws_vram_column_byte hi(.clk(clk_sys),.a_enable(accept && SNAPSHOT_ENABLE==0),.a_address(word_address[11:2]),
                    .write_enable(column_write && request_lanes[1] && SNAPSHOT_ENABLE==0),.write_data(request_data[15:8]),.a_data(ch),
                    .b_enable(b_read_enable),.b_address(b_read_address),.b_data(ah));
                thunderjaws_vram_column_byte lo(.clk(clk_sys),.a_enable(accept && SNAPSHOT_ENABLE==0),.a_address(word_address[11:2]),
                    .write_enable(column_write && request_lanes[0] && SNAPSHOT_ENABLE==0),.write_data(request_data[7:0]),.a_data(cl),
                    .b_enable(b_read_enable),.b_address(b_read_address),.b_data(al));
                if(SNAPSHOT_ENABLE!=0)begin:snapshot
                    wire initialized,ready,fault;wire [15:0] a_data,b_data;
                    assign column_initialized[c]=initialized;assign column_ready[c]=ready;assign column_fault[c]=fault;
                    assign cpu_column[c]=a_data;assign aux_column[c]=b_data;
                    thunderjaws_snapshot_ram #(.ADDRESS_BITS(10)) storage(.clk(clk_sys),.init_reset(init_reset),.snapshot_start(snapshot_start),
                        .initialized(initialized),.a_ready(ready),.fault(fault),
                        .a_enable(accept),.a_write(column_write),.a_address(word_address[11:2]),.a_lanes(request_lanes),.a_write_data(request_data),.a_data(a_data),
                        .b_enable(b_read_enable),.b_snapshot(mo_b_read || aux_snapshot),.b_address(b_read_address),.b_data(b_data));
                end else begin:live
                    assign column_initialized[c]=1;assign column_ready[c]=1;assign column_fault[c]=0;
                    assign cpu_column[c]={ch,cl};assign aux_column[c]={ah,al};
                end
                assign descriptor_data[c*16+:16]=aux_column[c];
            end
            assign cpu_q[b]=cpu_column[cpu_select];assign aux_q[b]=aux_column[aux_select];
        end else begin:word_bank
        reg [7:0] hi[0:4095],lo[0:4095];
        reg [7:0] cpu_hi,cpu_lo,aux_hi,aux_lo;
        integer i;
        initial for(i=0;i<4096;i=i+1)begin hi[i]=0;lo[i]=0;end
        wire direct_write=writing && word_address[14:12]==b;
        wire attr_hi=writing && attribute_enable && b==2 && word_address[14:12]==0;
        wire attr_lo=writing && attribute_enable && b==2 && word_address[14:12]==1;
        wire direct_hi=direct_write && request_lanes[1];
        wire direct_lo=direct_write && request_lanes[0];
        wire hi_write=direct_hi || attr_hi;
        wire lo_write=direct_lo || attr_lo;
        wire [7:0] hi_data=direct_hi ? request_data[15:8] : attribute_msb;
        wire [7:0] lo_data=direct_lo ? request_data[7:0] : attribute_lsb;
        wire mo_b_read=mo_accept && mo_address[14:12]==b;
        wire b_read_enable=mo_b_read || aux_accept;
        wire [11:0] b_read_address=mo_b_read ? mo_address[11:0] : aux_address[11:0];
        if(SNAPSHOT_ENABLE!=0 && b<5)begin:snapshot
            wire initialized,ready,fault;wire [15:0] a_data,b_data;
            assign bank_initialized[b]=initialized;assign bank_ready[b]=ready;assign bank_fault[b]=fault;
            assign cpu_q[b]=a_data;assign aux_q[b]=b_data;
            thunderjaws_snapshot_ram #(.ADDRESS_BITS(12)) storage(.clk(clk_sys),.init_reset(init_reset),.snapshot_start(snapshot_start),
                .initialized(initialized),.a_ready(ready),.fault(fault),
                .a_enable(accept),.a_write(hi_write || lo_write),.a_address(word_address[11:0]),.a_lanes({hi_write,lo_write}),.a_write_data({hi_data,lo_data}),.a_data(a_data),
                .b_enable(b_read_enable),.b_snapshot(mo_b_read || aux_snapshot),.b_address(b_read_address),.b_data(b_data));
        end else begin:live
        assign bank_initialized[b]=1;assign bank_ready[b]=1;assign bank_fault[b]=0;
        always @(posedge clk_sys) begin
            if(accept) begin
                cpu_hi<=hi[word_address[11:0]];
                cpu_lo<=lo[word_address[11:0]];
            end
            if(hi_write)hi[word_address[11:0]]<=hi_data;
            if(lo_write)lo[word_address[11:0]]<=lo_data;
        end
        always @(posedge clk_sys)begin
            if(b_read_enable)begin aux_hi<=hi[b_read_address];aux_lo<=lo[b_read_address];end
        end
        assign cpu_q[b]={cpu_hi,cpu_lo};
        assign aux_q[b]={aux_hi,aux_lo};
        end
        end
    end endgenerate
endmodule

// Single-write, two registered read ports; explicit byte column boundary.
module thunderjaws_vram_column_byte(
    input wire clk,a_enable,write_enable,b_enable,
    input wire [9:0] a_address,b_address,
    input wire [7:0] write_data,
    output reg [7:0] a_data,b_data
);
    reg [7:0] mem[0:1023];
    integer i;initial for(i=0;i<1024;i=i+1)mem[i]=0;
    always @(posedge clk)begin
        if(a_enable)a_data<=mem[a_address];
        if(write_enable)mem[a_address]<=write_data;
    end
    always @(posedge clk)if(b_enable)b_data<=mem[b_address];
endmodule
