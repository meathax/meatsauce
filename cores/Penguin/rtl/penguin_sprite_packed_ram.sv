// Full 256 KiB: six 10-bit lanes in 32 banks plus one 4-bit tail in 16 banks.
// CPU partial writes merge with that bank's prepared read, without a global
// RAM-to-RAM feedback mux. List copies can only write the two packed banks.
// SPDX-License-Identifier: GPL-3.0-or-later
module penguin_sprite_packed_ram (
    input logic clk,
    input logic [14:0] address,
    input logic [63:0] data,
    input logic [7:0] write_mask,
    input logic [15:0] cpu_data,
    input logic copy_mode,
    input logic write,
    output wire [63:0] q,
    output wire [63:0] header_q,
    input logic video_clk,
    input logic [14:0] video_address,
    output wire [63:0] video_q
);
`ifdef SYNTHESIS
    // Decode on the existing address-sampling edge: no extra read cycle.
    logic [31:0] cpu_bank_select=32'd1,video_bank_select=32'd1;
    always_ff @(posedge clk) cpu_bank_select<=32'd1 << address[14:10];
    // Coarse bank metadata is captured with the existing one-hot selector.
    logic [1:0] cpu_group_select=2'd0;
    always_ff @(posedge clk)cpu_group_select<=address[14:13];

    always_ff @(posedge video_clk) video_bank_select<=32'd1 << video_address[14:10];
    genvar lane,bank,bit_index;
    generate for(lane=0;lane<6;lane=lane+1)begin: lanes
        wire [9:0] cpu_words[0:31],video_words[0:31];
        assign header_q[lane*10 +:10]=cpu_words[1];
        // Same capture edge as the RAM address; place one selector per lane.
        (* preserve, dont_merge *) logic [31:0] video_lane_select=32'd1;
        always_ff @(posedge video_clk)video_lane_select<=32'd1 << video_address[14:10];

        // Same-edge local decode avoids a shared 62-load selector route.
        // Preserve each lane's copy; no additional RAM read/write cycle.
        (* preserve, dont_merge *) logic [31:0] cpu_lane_select=32'd1;
        always_ff @(posedge clk)cpu_lane_select<=32'd1 << address[14:10];

        for(bank=0;bank<32;bank=bank+1)begin: banks
            wire [9:0] merged;
            for(bit_index=0;bit_index<10;bit_index=bit_index+1)begin: bits
                localparam integer POSITION=lane*10+bit_index;
                if(bank<2) assign merged[bit_index]=write_mask[POSITION/8]?data[POSITION]:cpu_words[bank][bit_index];
                else assign merged[bit_index]=write_mask[POSITION/8]?cpu_data[POSITION%16]:cpu_words[bank][bit_index];
            end
            wire touched=(|write_mask[(lane*10)/8 +: ((lane*10+9)/8-(lane*10)/8+1)]);
            wire bank_write=write && address[14:10]==bank && touched && ((bank<2)||!copy_mode);
            altsyncram #(
                .operation_mode("BIDIR_DUAL_PORT"),
                .width_a(10),.widthad_a(10),.numwords_a(1024),
                .width_b(10),.widthad_b(10),.numwords_b(1024),
                .width_byteena_a(1),.width_byteena_b(1),.byte_size(10),.maximum_depth(1024),
                .address_reg_b("CLOCK1"),.outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
                .power_up_uninitialized("FALSE"),.read_during_write_mode_mixed_ports("OLD_DATA"),
                .intended_device_family("Cyclone V"),.ram_block_type("M10K")
            ) ram(.clock0(clk),.clock1(video_clk),.address_a(address[9:0]),.address_b(video_address[9:0]),
                .data_a(merged),.data_b(10'd0),.byteena_a(1'b1),.byteena_b(1'b1),
                .rden_a(address[14:10]==bank),.rden_b(video_address[14:10]==bank),
                .wren_a(bank_write),.wren_b(1'b0),.q_a(cpu_words[bank]),.q_b(video_words[bank]));
        end
        logic [9:0] selected_cpu_word,selected_video_word;


        always_comb begin
            selected_cpu_word=10'bx;
            selected_video_word=10'bx;
            unique case(1'b1)
    cpu_lane_select[0]: selected_cpu_word=cpu_words[0];
    cpu_lane_select[1]: selected_cpu_word=cpu_words[1];
    cpu_lane_select[2]: selected_cpu_word=cpu_words[2];
    cpu_lane_select[3]: selected_cpu_word=cpu_words[3];
    cpu_lane_select[4]: selected_cpu_word=cpu_words[4];
    cpu_lane_select[5]: selected_cpu_word=cpu_words[5];
    cpu_lane_select[6]: selected_cpu_word=cpu_words[6];
    cpu_lane_select[7]: selected_cpu_word=cpu_words[7];
    cpu_lane_select[8]: selected_cpu_word=cpu_words[8];
    cpu_lane_select[9]: selected_cpu_word=cpu_words[9];
    cpu_lane_select[10]: selected_cpu_word=cpu_words[10];
    cpu_lane_select[11]: selected_cpu_word=cpu_words[11];
    cpu_lane_select[12]: selected_cpu_word=cpu_words[12];
    cpu_lane_select[13]: selected_cpu_word=cpu_words[13];
    cpu_lane_select[14]: selected_cpu_word=cpu_words[14];
    cpu_lane_select[15]: selected_cpu_word=cpu_words[15];
    cpu_lane_select[16]: selected_cpu_word=cpu_words[16];
    cpu_lane_select[17]: selected_cpu_word=cpu_words[17];
    cpu_lane_select[18]: selected_cpu_word=cpu_words[18];
    cpu_lane_select[19]: selected_cpu_word=cpu_words[19];
    cpu_lane_select[20]: selected_cpu_word=cpu_words[20];
    cpu_lane_select[21]: selected_cpu_word=cpu_words[21];
    cpu_lane_select[22]: selected_cpu_word=cpu_words[22];
    cpu_lane_select[23]: selected_cpu_word=cpu_words[23];
    cpu_lane_select[24]: selected_cpu_word=cpu_words[24];
    cpu_lane_select[25]: selected_cpu_word=cpu_words[25];
    cpu_lane_select[26]: selected_cpu_word=cpu_words[26];
    cpu_lane_select[27]: selected_cpu_word=cpu_words[27];
    cpu_lane_select[28]: selected_cpu_word=cpu_words[28];
    cpu_lane_select[29]: selected_cpu_word=cpu_words[29];
    cpu_lane_select[30]: selected_cpu_word=cpu_words[30];
    cpu_lane_select[31]: selected_cpu_word=cpu_words[31];
    default: selected_cpu_word=10'bx;
endcase
            unique case(1'b1)
                video_lane_select[0]: selected_video_word=video_words[0];
                video_lane_select[1]: selected_video_word=video_words[1];
                video_lane_select[2]: selected_video_word=video_words[2];
                video_lane_select[3]: selected_video_word=video_words[3];
                video_lane_select[4]: selected_video_word=video_words[4];
                video_lane_select[5]: selected_video_word=video_words[5];
                video_lane_select[6]: selected_video_word=video_words[6];
                video_lane_select[7]: selected_video_word=video_words[7];
                video_lane_select[8]: selected_video_word=video_words[8];
                video_lane_select[9]: selected_video_word=video_words[9];
                video_lane_select[10]: selected_video_word=video_words[10];
                video_lane_select[11]: selected_video_word=video_words[11];
                video_lane_select[12]: selected_video_word=video_words[12];
                video_lane_select[13]: selected_video_word=video_words[13];
                video_lane_select[14]: selected_video_word=video_words[14];
                video_lane_select[15]: selected_video_word=video_words[15];
                video_lane_select[16]: selected_video_word=video_words[16];
                video_lane_select[17]: selected_video_word=video_words[17];
                video_lane_select[18]: selected_video_word=video_words[18];
                video_lane_select[19]: selected_video_word=video_words[19];
                video_lane_select[20]: selected_video_word=video_words[20];
                video_lane_select[21]: selected_video_word=video_words[21];
                video_lane_select[22]: selected_video_word=video_words[22];
                video_lane_select[23]: selected_video_word=video_words[23];
                video_lane_select[24]: selected_video_word=video_words[24];
                video_lane_select[25]: selected_video_word=video_words[25];
                video_lane_select[26]: selected_video_word=video_words[26];
                video_lane_select[27]: selected_video_word=video_words[27];
                video_lane_select[28]: selected_video_word=video_words[28];
                video_lane_select[29]: selected_video_word=video_words[29];
                video_lane_select[30]: selected_video_word=video_words[30];
                video_lane_select[31]: selected_video_word=video_words[31];
                default: selected_video_word=10'bx;
            endcase
        end
        assign q[lane*10+:10]=selected_cpu_word;
        assign video_q[lane*10+:10]=selected_video_word;
    end
    endgenerate
    // Tail bits all belong to byte seven, so a CPU write never needs a merge.
    // Retain 2048-word packing: 192 full M10Ks and 16 tail M10Ks, as before.
    wire [3:0] cpu_tail[0:15],video_tail[0:15];
    assign header_q[63:60]=cpu_tail[0];
    generate for(bank=0;bank<16;bank=bank+1)begin: tail_banks
        wire [3:0] tail_data;
        if(bank==0)assign tail_data=copy_mode?data[63:60]:cpu_data[15:12];
        else assign tail_data=cpu_data[15:12];
        altsyncram #(
            .operation_mode("BIDIR_DUAL_PORT"),
            .width_a(4),.widthad_a(11),.numwords_a(2048),
            .width_b(4),.widthad_b(11),.numwords_b(2048),
            .width_byteena_a(1),.width_byteena_b(1),.byte_size(8),.maximum_depth(2048),
            .address_reg_b("CLOCK1"),.outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
            .power_up_uninitialized("FALSE"),.read_during_write_mode_mixed_ports("OLD_DATA"),
            .intended_device_family("Cyclone V"),.ram_block_type("M10K")
        ) ram(.clock0(clk),.clock1(video_clk),.address_a(address[10:0]),.address_b(video_address[10:0]),
            .data_a(tail_data),.data_b(4'd0),.byteena_a(1'b1),.byteena_b(1'b1),
            .rden_a(address[14:11]==bank),.rden_b(video_address[14:11]==bank),
            .wren_a(write && write_mask[7] && address[14:11]==bank && (!copy_mode || bank==0)),.wren_b(1'b0),
            .q_a(cpu_tail[bank]),.q_b(video_tail[bank]));
    end endgenerate
    logic [3:0] selected_cpu_tail,selected_video_tail;
// BEGIN GROUP_selected_cpu_tail
(* keep *) logic [3:0] selected_cpu_tail_group0,selected_cpu_tail_group1,selected_cpu_tail_group2,selected_cpu_tail_group3;
always_comb begin
    selected_cpu_tail_group0=4'bx;
    unique case(1'b1)
        cpu_bank_select[0]: selected_cpu_tail_group0=cpu_tail[0];
        cpu_bank_select[1]: selected_cpu_tail_group0=cpu_tail[0];
        cpu_bank_select[2]: selected_cpu_tail_group0=cpu_tail[1];
        cpu_bank_select[3]: selected_cpu_tail_group0=cpu_tail[1];
        cpu_bank_select[4]: selected_cpu_tail_group0=cpu_tail[2];
        cpu_bank_select[5]: selected_cpu_tail_group0=cpu_tail[2];
        cpu_bank_select[6]: selected_cpu_tail_group0=cpu_tail[3];
        cpu_bank_select[7]: selected_cpu_tail_group0=cpu_tail[3];
        default: selected_cpu_tail_group0=4'bx;
    endcase
    selected_cpu_tail_group1=4'bx;
    unique case(1'b1)
        cpu_bank_select[8]: selected_cpu_tail_group1=cpu_tail[4];
        cpu_bank_select[9]: selected_cpu_tail_group1=cpu_tail[4];
        cpu_bank_select[10]: selected_cpu_tail_group1=cpu_tail[5];
        cpu_bank_select[11]: selected_cpu_tail_group1=cpu_tail[5];
        cpu_bank_select[12]: selected_cpu_tail_group1=cpu_tail[6];
        cpu_bank_select[13]: selected_cpu_tail_group1=cpu_tail[6];
        cpu_bank_select[14]: selected_cpu_tail_group1=cpu_tail[7];
        cpu_bank_select[15]: selected_cpu_tail_group1=cpu_tail[7];
        default: selected_cpu_tail_group1=4'bx;
    endcase
    selected_cpu_tail_group2=4'bx;
    unique case(1'b1)
        cpu_bank_select[16]: selected_cpu_tail_group2=cpu_tail[8];
        cpu_bank_select[17]: selected_cpu_tail_group2=cpu_tail[8];
        cpu_bank_select[18]: selected_cpu_tail_group2=cpu_tail[9];
        cpu_bank_select[19]: selected_cpu_tail_group2=cpu_tail[9];
        cpu_bank_select[20]: selected_cpu_tail_group2=cpu_tail[10];
        cpu_bank_select[21]: selected_cpu_tail_group2=cpu_tail[10];
        cpu_bank_select[22]: selected_cpu_tail_group2=cpu_tail[11];
        cpu_bank_select[23]: selected_cpu_tail_group2=cpu_tail[11];
        default: selected_cpu_tail_group2=4'bx;
    endcase
    selected_cpu_tail_group3=4'bx;
    unique case(1'b1)
        cpu_bank_select[24]: selected_cpu_tail_group3=cpu_tail[12];
        cpu_bank_select[25]: selected_cpu_tail_group3=cpu_tail[12];
        cpu_bank_select[26]: selected_cpu_tail_group3=cpu_tail[13];
        cpu_bank_select[27]: selected_cpu_tail_group3=cpu_tail[13];
        cpu_bank_select[28]: selected_cpu_tail_group3=cpu_tail[14];
        cpu_bank_select[29]: selected_cpu_tail_group3=cpu_tail[14];
        cpu_bank_select[30]: selected_cpu_tail_group3=cpu_tail[15];
        cpu_bank_select[31]: selected_cpu_tail_group3=cpu_tail[15];
        default: selected_cpu_tail_group3=4'bx;
    endcase
end
// END GROUP_selected_cpu_tail

    always_comb begin
        selected_cpu_tail=4'bx;
        selected_video_tail=4'bx;
        unique case(cpu_group_select)
    2'd0: selected_cpu_tail=selected_cpu_tail_group0;
    2'd1: selected_cpu_tail=selected_cpu_tail_group1;
    2'd2: selected_cpu_tail=selected_cpu_tail_group2;
    2'd3: selected_cpu_tail=selected_cpu_tail_group3;
    default: selected_cpu_tail=4'bx;
endcase
        unique case(1'b1)
            video_bank_select[0]: selected_video_tail=video_tail[0];
            video_bank_select[1]: selected_video_tail=video_tail[0];
            video_bank_select[2]: selected_video_tail=video_tail[1];
            video_bank_select[3]: selected_video_tail=video_tail[1];
            video_bank_select[4]: selected_video_tail=video_tail[2];
            video_bank_select[5]: selected_video_tail=video_tail[2];
            video_bank_select[6]: selected_video_tail=video_tail[3];
            video_bank_select[7]: selected_video_tail=video_tail[3];
            video_bank_select[8]: selected_video_tail=video_tail[4];
            video_bank_select[9]: selected_video_tail=video_tail[4];
            video_bank_select[10]: selected_video_tail=video_tail[5];
            video_bank_select[11]: selected_video_tail=video_tail[5];
            video_bank_select[12]: selected_video_tail=video_tail[6];
            video_bank_select[13]: selected_video_tail=video_tail[6];
            video_bank_select[14]: selected_video_tail=video_tail[7];
            video_bank_select[15]: selected_video_tail=video_tail[7];
            video_bank_select[16]: selected_video_tail=video_tail[8];
            video_bank_select[17]: selected_video_tail=video_tail[8];
            video_bank_select[18]: selected_video_tail=video_tail[9];
            video_bank_select[19]: selected_video_tail=video_tail[9];
            video_bank_select[20]: selected_video_tail=video_tail[10];
            video_bank_select[21]: selected_video_tail=video_tail[10];
            video_bank_select[22]: selected_video_tail=video_tail[11];
            video_bank_select[23]: selected_video_tail=video_tail[11];
            video_bank_select[24]: selected_video_tail=video_tail[12];
            video_bank_select[25]: selected_video_tail=video_tail[12];
            video_bank_select[26]: selected_video_tail=video_tail[13];
            video_bank_select[27]: selected_video_tail=video_tail[13];
            video_bank_select[28]: selected_video_tail=video_tail[14];
            video_bank_select[29]: selected_video_tail=video_tail[14];
            video_bank_select[30]: selected_video_tail=video_tail[15];
            video_bank_select[31]: selected_video_tail=video_tail[15];
            default: selected_video_tail=4'bx;
        endcase
    end
    assign q[63:60]=selected_cpu_tail;
    assign video_q[63:60]=selected_video_tail;
`else
    assign header_q=q;
    logic [63:0] records [0:32767];
    logic [63:0] cpu_read,video_read;
    always_ff @(posedge clk) begin
        cpu_read<=records[address];
        if(write) for(integer b=0;b<8;b=b+1)if(write_mask[b])records[address][b*8+:8]<=data[b*8+:8];
    end
    always_ff @(posedge video_clk) video_read<=records[video_address];
    assign q=cpu_read;assign video_q=video_read;
`endif
endmodule
