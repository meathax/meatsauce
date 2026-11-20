// SPDX-License-Identifier: BSD-3-Clause
// Current-frame TC0110PCR palette snapshot. Copy during native blanking while
// main CPU execution is frozen; later CPU palette writes cannot recolor scanout.
// Eight independent banks copy eight entries on each CPU edge. Live and display
// memories remain separate, preserving the original mixed-clock ownership.
module gs_palette_snapshot #(parameter BANKED=0)(
    input wire cpu_clk,video_clk,reset,
    input wire write_strobe,cpu_reg,
    input wire [1:0] cpu_bytes,
    input wire [15:0] cpu_data,
    input wire cut,
    input wire copy_bank,pixel_page,
    output reg cut_ack,
    output wire copy_busy,
    input wire pixel_ce,
    input wire [11:0] pixel_index,
    output wire [23:0] pixel_rgb
);
    localparam IDLE=0,PRIME=1,COPY=2;
    reg [1:0] state;
    reg cut_seen;
    reg [11:0] index=0;
    reg [8:0] cursor;
    reg captured_bank;
    reg [2:0] pixel_bank=0;
    wire [15:0] pixel_words[0:7];
    wire [15:0] pixel_word=pixel_words[pixel_bank];
    wire [15:0] masked_data={cpu_bytes[1]?cpu_data[15:8]:8'b0,cpu_bytes[0]?cpu_data[7:0]:8'b0};
    wire [8:0] read_address=state==COPY ? cursor+1'b1 : cursor;
    assign copy_busy=state!=IDLE;
    genvar bank;
    generate for(bank=0;bank<8;bank=bank+1) begin: banks
        (* ramstyle="M10K, no_rw_check" *) reg [15:0] live[0:511],display[0:(BANKED?1023:511)];
        reg [15:0] copy_word,pixel_value=0;
        integer entry;
        initial begin
            for(entry=0;entry<512;entry=entry+1) live[entry]=0;
            for(entry=0;entry<(BANKED?1024:512);entry=entry+1) display[entry]=0;
        end
        always @(posedge cpu_clk) begin
            copy_word<=live[read_address];
            if(write_strobe && |cpu_bytes && cpu_reg && index[2:0]==3'(bank))
                live[index[11:3]]<=masked_data;
            if(state==COPY) display[BANKED ? {captured_bank,cursor} : {1'b0,cursor}]<=copy_word;
        end
        always @(posedge video_clk) if(pixel_ce)
            pixel_value<=display[BANKED ? {pixel_page,pixel_index[11:3]} : {1'b0,pixel_index[11:3]}];
        assign pixel_words[bank]=pixel_value;
    end endgenerate
    always @(posedge video_clk) if(pixel_ce) pixel_bank<=pixel_index[2:0];
    always @(posedge cpu_clk) begin
        cut_ack<=0;
        if(!cut) cut_seen<=0;
        if(write_strobe && |cpu_bytes && !cpu_reg) index<=masked_data[11:0];
        case(state)
        IDLE: if(cut && !cut_seen) begin cut_seen<=1;cursor<=0;captured_bank<=copy_bank;state<=PRIME;end
        PRIME: state<=COPY;
        COPY: if(cursor==511) begin state<=IDLE;cut_ack<=1;end else cursor<=cursor+1'b1;
        endcase
        // Native PCR index/palette persist across CPU reset; only copy aborts.
        if(reset) begin state<=IDLE;cut_seen<=0;cursor<=0;captured_bank<=0;cut_ack<=0;end
    end
    assign pixel_rgb={pixel_word[14:10],pixel_word[14:12],pixel_word[9:5],pixel_word[9:7],pixel_word[4:0],pixel_word[4:2]};
endmodule
