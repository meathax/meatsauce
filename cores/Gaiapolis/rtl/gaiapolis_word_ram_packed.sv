// SPDX-License-Identifier: GPL-3.0-or-later
// Local derivative of read-only METAMORPHIC native20 packing proof.
// Donor SHA256 2d21b40641e35fd31a2d4c99d023036bae844995762bc5144eed7bf31ae968ae
// QIP flags also reach full-core Verilator. Its default backend must remain
// behavioral; native Quartus/QIS and explicit Intel-model tests use primitives.
`ifdef GAIAPOLIS_PACKED_RAM_INTEL_MODEL_TEST
    `define GAIAPOLIS_WORD_RAM_NATIVE_BACKEND
`elsif VERILATOR
    // Behavioral backend, including full-QIP simulations.
`elsif ALTERA_RESERVED_QIS
    `define GAIAPOLIS_WORD_RAM_NATIVE_BACKEND
`elsif GAIAPOLIS_PACKED_RAM_PRIMITIVES
    `define GAIAPOLIS_WORD_RAM_NATIVE_BACKEND
`endif
// Three5-bit planes plus five packed bit15s per row retain all AW-bit words.
// Direct byte-local planes use native OLD_DATA. Cross-byte/packed planes use
// one delayed commit and forwarding, preserving that same OLD_DATA edge.
module gaiapolis_word_ram_packed #(
    parameter AW=15,
    parameter SPLIT_GEOMETRY=0
)(
    input clk,
    input [15:0] data,
    input [AW:1] addr,
    input [1:0] we,
    output [15:0] q,
    input [AW:1] cpu_addr,
    input [$clog2(((1<<AW)+4)/5)-1:0] restore_row,
    input [2:0] restore_lane,
    input restore_select
);
    localparam WORDS=1<<AW;
    localparam ROWS=(WORDS+4)/5;
    localparam ROW_AW=$clog2(ROWS);
    // Exact unsigned /5: rounding error <1/5 for every AW-bit input.
    localparam [AW-1:0] RECIPROCAL=((64'd1<<(AW+2))+4)/5;
    // Quartus 17 multstyle supports constant non-power-of-two DSP products.
    // Combinational only: preserve the existing OLD_DATA capture edge.
    (* multstyle = "dsp" *) wire [2*AW-1:0] reciprocal_product;
    // Keep the restore grant out of the CPU reciprocal product.
    wire [AW-1:0] decode_addr = SPLIT_GEOMETRY ? cpu_addr : addr;
    assign reciprocal_product=decode_addr*RECIPROCAL;
    wire [AW-1:0] quotient=reciprocal_product>>(AW+2);
    wire [AW-1:0] five_quotient=quotient+(quotient<<2);
    wire [2:0] cpu_lane=3'(decode_addr-five_quotient);
    wire [2:0] lane=SPLIT_GEOMETRY && restore_select ? restore_lane : cpu_lane;
    wire [ROW_AW-1:0] row=SPLIT_GEOMETRY && restore_select ? restore_row : quotient[ROW_AW-1:0];
    reg [AW-1:0] addr_q;
    reg [ROW_AW-1:0] row_q;
    reg [2:0] lane_q;
    reg [15:0] data_q;
    reg [1:0] we_q=2'b00;
    wire [14:0] fields_q;
    wire [4:0] parity_q;
    reg mid_valid=1'b0,parity_valid=1'b0;
    reg [AW-1:0] last_mid_addr;
    reg [ROW_AW-1:0] last_parity_row;
    reg [4:0] last_mid_data,last_parity_data;
    wire [4:0] visible_mid=mid_valid && last_mid_addr==addr_q ? last_mid_data : fields_q[9:5];
    wire [4:0] visible_parity=parity_valid && last_parity_row==row_q ? last_parity_data : parity_q;
    reg [4:0] merged_mid,merged_parity;
    always @* begin
        merged_mid=visible_mid;
        if(we_q[0])merged_mid[2:0]=data_q[7:5];
        if(we_q[1])merged_mid[4:3]=data_q[9:8];
        merged_parity=visible_parity;
        if(we_q[1])merged_parity[lane_q]=data_q[15];
    end
    assign q={visible_parity[lane_q],fields_q[14:10],visible_mid,fields_q[4:0]};
    always @(posedge clk)begin
        addr_q<=addr;row_q<=row;lane_q<=lane;data_q<=data;we_q<=we;
        if(|we_q)begin
            mid_valid<=1'b1;last_mid_addr<=addr_q;last_mid_data<=merged_mid;
        end
        if(we_q[1])begin
            parity_valid<=1'b1;last_parity_row<=row_q;last_parity_data<=merged_parity;
        end
    end
    genvar field;
    generate for(field=0;field<3;field=field+1)begin:fields
        wire [AW-1:0] write_addr=field==1 ? addr_q : addr;
        wire [4:0] write_data=field==0 ? data[4:0] : field==1 ? merged_mid : data[14:10];
        wire write_en=field==0 ? we[0] : field==1 ? |we_q : we[1];
`ifdef GAIAPOLIS_WORD_RAM_NATIVE_BACKEND
        altsyncram #(.intended_device_family("Cyclone V"),
            .operation_mode("DUAL_PORT"),.ram_block_type("M10K"),
            .width_a(5),.width_b(5),.widthad_a(AW),.widthad_b(AW),
            .numwords_a(WORDS),.numwords_b(WORDS),.maximum_depth(2048),
            .address_reg_b("CLOCK0"),.outdata_reg_b("UNREGISTERED"),
            .read_during_write_mode_mixed_ports("OLD_DATA"),
            .power_up_uninitialized("FALSE"),
            .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),
            .clock_enable_output_b("BYPASS")) storage(
            .clock0(clk),.address_a(write_addr),.address_b(addr),
            .data_a(write_data),.wren_a(write_en),.q_b(fields_q[field*5+:5]));
`else
        reg [4:0] mem[0:WORDS-1];reg [4:0] read_q;integer i;
        initial for(i=0;i<WORDS;i=i+1)mem[i]=5'd0;
        always @(posedge clk)begin
            read_q<=mem[addr];if(write_en)mem[write_addr]<=write_data;
        end
        assign fields_q[field*5+:5]=read_q;
`endif
    end endgenerate
`ifdef GAIAPOLIS_WORD_RAM_NATIVE_BACKEND
    altsyncram #(.intended_device_family("Cyclone V"),
        .operation_mode("DUAL_PORT"),.ram_block_type("M10K"),
        .width_a(5),.width_b(5),.widthad_a(ROW_AW),.widthad_b(ROW_AW),
        .numwords_a(ROWS),.numwords_b(ROWS),.maximum_depth(2048),
        .address_reg_b("CLOCK0"),.outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .power_up_uninitialized("FALSE"),
        .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),
        .clock_enable_output_b("BYPASS")) parity_storage(
        .clock0(clk),.address_a(row_q),.address_b(row),
        .data_a(merged_parity),.wren_a(we_q[1]),.q_b(parity_q));
`else
    reg [4:0] parity_mem[0:ROWS-1];reg [4:0] parity_read_q;integer p;
    initial for(p=0;p<ROWS;p=p+1)parity_mem[p]=5'd0;
    always @(posedge clk)begin
        parity_read_q<=parity_mem[row];if(we_q[1])parity_mem[row_q]<=merged_parity;
    end
    assign parity_q=parity_read_q;
`endif
endmodule
`undef GAIAPOLIS_WORD_RAM_NATIVE_BACKEND
