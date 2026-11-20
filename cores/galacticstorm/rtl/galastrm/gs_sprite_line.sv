// SPDX-License-Identifier: BSD-3-Clause
// Galastrm's front-to-back prio_zoom_transpen ownership, MAME 0.289.
// Background masking is applied AFTER ownership: a masked first opaque sprite
// still hides later sprites. Feed reversed chunk order within ascending records.
module gs_sprite_line #(parameter PAIRED=0)(
    input wire clk,reset,
    input wire clear_start,
    output reg clear_busy,
    input wire pixel_valid,
    output wire pixel_ready,
    input wire signed [11:0] pixel_x,
    input wire [11:0] pixel_index,
    input wire [1:0] pixel_priority,
    input wire pixel_opaque,
    input wire pixel2_valid,
    input wire signed [11:0] pixel2_x,
    input wire [11:0] pixel2_index,
    input wire [1:0] pixel2_priority,
    input wire pixel2_opaque,
    output wire write_pending,
    input wire lookup_mode,lookup_req,
    input wire [8:0] lookup_x,
    output wire lookup_ready,
    output reg lookup_valid,
    output wire owner_present,
    output wire [11:0] owner_index,
    output wire [1:0] owner_priority,
    output reg [31:0] covered_groups,
    input wire [8:0] coverage_first,coverage_last,
    output wire range_covered
);
    // Pack adjacent 16-bit owners into one 256x32 M10K word. This preserves
    // one synchronous read and one write per cycle while allowing a pixel pair.
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] owners [0:255];
    reg [31:0] ram_read_data,forward_data;
    reg forward_valid;
    reg read_lane;
    reg [8:0] clear_x,stage_x,stage_x2;
    reg [15:0] stage_pixel,stage_pixel2;
    reg stage_valid,stage_valid2;
    // Each replica has one asynchronous read and one synchronous write,
    // matching a legal MLAB port pair. Three reads from one array expand to
    // flip-flops in Quartus 17. Narrow words also bound endpoint-mask logic.
    (* ramstyle="MLAB, no_rw_check" *) reg [15:0] coverage_first_words[0:31];
    (* ramstyle="MLAB, no_rw_check" *) reg [15:0] coverage_last_words[0:31];
    (* ramstyle="MLAB, no_rw_check" *) reg [15:0] coverage_update_words[0:31];
    wire [4:0] first_group=coverage_first[8:4],last_group=coverage_last[8:4];
    wire [4:0] group_distance=last_group-first_group;
    wire [15:0] first_mask=16'hffff<<coverage_first[3:0];
    wire [15:0] last_mask=16'hffff>>(4'd15-coverage_last[3:0]);
    wire same_group=first_group==last_group;
    wire [15:0] mask_a=same_group ? first_mask & last_mask : first_mask;
    wire [15:0] first_word=coverage_first_words[first_group];
    wire [15:0] last_word=coverage_last_words[last_group];
    // A <=64-pixel row crosses at most three complete interior groups.
    wire interior_covered=(group_distance<=1 || covered_groups[first_group+5'd1]) &&
        (group_distance<=2 || covered_groups[first_group+5'd2]) &&
        (group_distance<=3 || covered_groups[first_group+5'd3]);
    assign range_covered=!reset && !clear_start && !clear_busy &&
        coverage_last>=coverage_first && ({1'b0,coverage_last}-{1'b0,coverage_first})<64 &&
        (first_word & mask_a)==mask_a &&
        (same_group || (last_word & last_mask)==last_mask) && interior_covered;

    wire [8:0] read_x=lookup_mode ? lookup_x : pixel_x[8:0];
    wire [7:0] read_word=lookup_mode ? lookup_x[8:1] : pixel_x[8:1];
    wire [31:0] read_word_data=forward_valid ? forward_data : ram_read_data;
    wire [15:0] lookup_owner=read_lane ? read_word_data[31:16] : read_word_data[15:0];
    wire [15:0] stage_owner=stage_x[0] ? read_word_data[31:16] : read_word_data[15:0];
    wire [15:0] stage_owner2=stage_x2[0] ? read_word_data[31:16] : read_word_data[15:0];
    wire pair_contract=!PAIRED || (pixel2_x==pixel_x+12'sd1 && !pixel_x[0] &&
        pixel2_x[8:1]==pixel_x[8:1] && pixel2_x[8:4]==pixel_x[8:4]);
    wire pair_take=PAIRED && pixel2_valid;
    wire take=pixel_valid && pixel_ready && pixel_opaque && pixel_x>=0 && pixel_x<512;
    wire take2=pair_take && pixel_ready && pixel2_opaque && pixel2_x>=0 && pixel2_x<512;
    wire write_owner=stage_valid && !stage_owner[15] && !clear_busy;
    wire write_owner2=stage_valid2 && !stage_owner2[15] && !clear_busy;
    wire low_write=(write_owner && !stage_x[0]) || (write_owner2 && !stage_x2[0]);
    wire high_write=(write_owner && stage_x[0]) || (write_owner2 && stage_x2[0]);
    wire [15:0] low_data=(write_owner && !stage_x[0]) ? stage_pixel :
                         ((write_owner2 && !stage_x2[0]) ? stage_pixel2 : read_word_data[15:0]);
    wire [15:0] high_data=(write_owner && stage_x[0]) ? stage_pixel :
                          ((write_owner2 && stage_x2[0]) ? stage_pixel2 : read_word_data[31:16]);
    wire [31:0] write_data=clear_busy ? 32'b0 :
        {high_write ? high_data : read_word_data[31:16],low_write ? low_data : read_word_data[15:0]};
    wire [7:0] write_word=clear_busy ? clear_x[8:1] : stage_x[8:1];
    wire ram_write=clear_busy || write_owner || write_owner2;
    wire [4:0] coverage_write_address=clear_busy ? clear_x[8:4] : stage_x[8:4];
    wire [15:0] coverage_mask=(write_owner ? (16'b1<<stage_x[3:0]) : 16'b0) |
        (write_owner2 ? (16'b1<<stage_x2[3:0]) : 16'b0);
    wire [15:0] covered_next=coverage_update_words[coverage_write_address] | coverage_mask;
    wire coverage_write=(clear_busy && clear_x[3:0]==0) || (write_owner || write_owner2);
    wire [15:0] coverage_write_data=clear_busy ? 16'b0 : covered_next;
    always @(posedge clk) begin
        if(coverage_write) begin
            coverage_first_words[coverage_write_address]<=coverage_write_data;
            coverage_last_words[coverage_write_address]<=coverage_write_data;
            coverage_update_words[coverage_write_address]<=coverage_write_data;
        end
    end

    assign pixel_ready=!clear_busy && !clear_start && !lookup_mode && !reset &&
                       (!PAIRED || !pixel2_valid || pair_contract);
    assign write_pending=stage_valid || stage_valid2;
    assign lookup_ready=lookup_mode && !clear_busy && !clear_start && !write_pending && !reset;
    assign owner_present=lookup_owner[15];
    assign owner_priority=lookup_owner[13:12];
    assign owner_index=lookup_owner[11:0];
    always @(posedge clk) begin
        ram_read_data<=owners[read_word];
        if(ram_write) owners[write_word]<=write_data;
    end
    always @(posedge clk) begin
        read_lane<=read_x[0];
        if((write_owner || write_owner2) && !clear_busy) begin
            covered_groups[coverage_write_address]<=&covered_next;
        end
        // Forward the complete packed word on a same-word read/write collision.
        forward_valid<=ram_write && write_word==read_word && !clear_busy;
        forward_data<=write_data;
        stage_x<=pixel_x[8:0];
        stage_x2<=pixel2_x[8:0];
        stage_pixel<={1'b1,1'b0,pixel_priority,pixel_index};
        stage_pixel2<={1'b1,1'b0,pixel2_priority,pixel2_index};
        stage_valid<=take;
        stage_valid2<=take2;
        lookup_valid<=lookup_req && lookup_ready;
        if(clear_start && !clear_busy) begin
            clear_busy<=1;clear_x<=0;stage_valid<=0;stage_valid2<=0;lookup_valid<=0;
            covered_groups<=0;
        end else if(clear_busy) begin
            clear_x<=clear_x+9'd2;
            if(clear_x==510) clear_busy<=0;
        end
        if(reset) begin
            clear_busy<=0;clear_x<=0;stage_valid<=0;stage_valid2<=0;lookup_valid<=0;read_lane<=0;
            covered_groups<=0;
        end
    end
endmodule
