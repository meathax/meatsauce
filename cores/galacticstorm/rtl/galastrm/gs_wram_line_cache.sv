// SPDX-License-Identifier: GPL-3.0-or-later
// Main 68020 private work-RAM (0x200000-0x21ffff) line store for
// gs_wram_write_buffer: 2**IW direct-mapped lines of four words in eight
// byte-lane M10K arrays plus a {valid,tag} array.
//
// The owner (write buffer) keeps coherence:
//  * fill  - aligned line read back after all queued writes drained;
//  * write - a posted CPU write updates its bytes when the line is resident,
//            or invalidates the indexed entry when residency is unproven.
// The RAM is read every edge at rd_addr (the held request, or the CPU's next
// address while idle), so the lookup for a newly issued request is on the RAM
// output in that request's first cycle. Any RAM write marks the output stale.
// Reset sweeps all tags invalid; lookups report no residency until done.
module gs_wram_line_cache #(
    parameter integer IW=10
)(
    input wire clk,reset,
    input wire [23:0] rd_addr,          // address read this edge
    input wire [23:0] req_addr,         // held request being decided
    output wire known,                  // output is current for req_addr's line index
    output wire resident,               // known && req_addr's line is present
    output wire [15:0] word,            // req_addr's word (valid when resident)
    input wire write_hit,               // posted write to a resident line
    input wire write_invalidate,        // posted write with unproven residency
    input wire [23:0] write_addr,
    input wire [1:0] write_be,
    input wire [15:0] write_data,
    input wire fill,
    input wire [23:0] fill_addr,        // line aligned
    input wire [63:0] fill_line
);
    localparam integer TW=14-IW;        // line address [16:3] minus index
    localparam integer N=1<<IW;
    (* ramstyle="M10K, no_rw_check" *) reg [TW:0] tags [0:N-1];
    reg [TW:0] q_tag;
    wire [63:0] q_line;
    reg [23:0] q_addr;
    reg [IW-1:0] sweep;
    reg sweeping,swept;
    wire [IW-1:0] rd_index=rd_addr[IW+2:3];
    wire [IW-1:0] req_index=req_addr[IW+2:3];
    wire [IW-1:0] write_index=write_addr[IW+2:3];
    wire [IW-1:0] fill_index=fill_addr[IW+2:3];
    wire byte_write=write_hit || fill;
    wire [IW-1:0] byte_index=fill ? fill_index : write_index;
    wire tag_we=fill || write_invalidate || sweeping;
    wire [IW-1:0] tag_index=fill ? fill_index : write_invalidate ? write_index : sweep;
    wire [TW:0] tag_data=fill ? {1'b1,fill_addr[16:IW+3]} : '0;
    wire any_write=byte_write || tag_we;
    assign known=swept && q_addr[IW+2:3]==req_index;
    assign resident=known && q_tag=={1'b1,req_addr[16:IW+3]};
    assign word=q_line[16*req_addr[2:1] +: 16];
    genvar b;
    generate for(b=0;b<8;b=b+1) begin : lane
        // Byte b of the line is byte (b&1) of word b>>1 (bit 8*(b&1)).
        // Module-scope RAM wrapper: Quartus 17 can expand generate-local arrays.
        wire write_lane=write_hit && write_addr[2:1]==b/2 && write_be[b%2];
        gs_wram_line_byte_ram #(.IW(IW)) ram(.clk(clk),.rd_index(rd_index),.q(q_line[8*b +: 8]),
            .we(fill || write_lane),.wr_index(byte_index),
            .data(fill ? fill_line[8*b +: 8] : write_data[8*(b%2) +: 8]));
    end endgenerate
    always @(posedge clk) begin
        q_tag<=tags[rd_index];
        if(tag_we) tags[tag_index]<=tag_data;
        // An output read on a write edge may be stale or undefined.
        q_addr<=any_write ? ~rd_addr : rd_addr;
        if(reset) begin sweep<=0;sweeping<=1;swept<=0;end
        else begin
            swept<=!sweeping;
            if(sweeping && !fill && !write_invalidate) begin
                sweep<=sweep+1'b1;
                if(&sweep) sweeping<=0;
            end
        end
    end
endmodule

// One byte lane: 2**IW x 8 simple dual-port M10K, registered read, no
// read-during-write guarantee (the owner marks such outputs stale).
module gs_wram_line_byte_ram #(parameter integer IW=10)(
    input wire clk,
    input wire [IW-1:0] rd_index,
    output reg [7:0] q,
    input wire we,
    input wire [IW-1:0] wr_index,
    input wire [7:0] data
);
    (* ramstyle="M10K, no_rw_check" *) reg [7:0] mem [0:(1<<IW)-1];
    always @(posedge clk) begin
        q<=mem[rd_index];
        if(we) mem[wr_index]<=data;
    end
endmodule
