// SPDX-License-Identifier: BSD-3-Clause
// 128 fully associative indexed 8x8 tiles, addressed by a complete tile directory.
// The capacity and global round-robin replacement order are unchanged.
// One synchronous 2048x64 RAM port per direction; four texels per memory beat.
module gs_tc0610_cache #(parameter STREAM_FILL=0,parameter PIPELINED_PIXELS=0)(
    input wire clk,reset,invalidate,
    output wire idle,
    input wire pixel_req,stream_pixels,
    input wire [17:0] pixel_addr,
    output wire pixel_ack,
    output wire [15:0] pixel_rdata,
    output wire mem_req,
    output wire [15:0] mem_addr,
    input wire mem_ack,
    input wire [63:0] mem_rdata,
    input wire mem_line_valid,
    input wire [2:0] mem_line_word,
    input wire [63:0] mem_line_data
);
    localparam IDLE=0,CHECK=1,SELECT=2,FILL=3,GAP=4,REPLY=5,WAIT_RAM=6,CLEAR=7;
    reg [2:0] state;
    reg [17:0] saved_address;
    reg [11:0] saved_key;
    reg [3:0] fill_beat;
    reg [6:0] victim,replacement;
    reg [127:0] tag_valid;
    // One entry per possible source tile removes the serial associative search.
    // Reverse tags invalidate the evicted tile before its slot is overwritten.
    (* ramstyle="M10K, no_rw_check" *) reg [7:0] directory[0:4095];
    (* ramstyle="MLAB, no_rw_check" *) reg [11:0] reverse_tags[0:127];
    reg [7:0] directory_data;
    reg [11:0] clear_key;
    reg found_valid;
    reg [6:0] found_slot;
    (* ramstyle="M10K, no_rw_check" *) reg [63:0] pixels[0:2047];
    reg [63:0] ram_data;
    wire [11:0] request_key={pixel_addr[17:12],pixel_addr[8:3]};
    wire previous_tile=found_valid && saved_key==request_key;
    wire [10:0] ram_read_address=state==IDLE && pixel_req && previous_tile ?
        {found_slot,pixel_addr[11:9],pixel_addr[2]} :
        {found_slot,saved_address[11:9],saved_address[2]};
    wire [10:0] ram_write_address=STREAM_FILL ? {victim,fill_beat[3],mem_line_word} : {victim,fill_beat};
    wire [17:0] tile_base={saved_address[17:12],3'b0,saved_address[8:3],3'b0};
    assign idle=state==IDLE;
    // The already registered four-texel word needs no new RAM read. REPLY
    // keeps legacy held requests stable; the PCB streaming client advances on ACK.
    wire streaming=PIPELINED_PIXELS && stream_pixels;
    wire word_hit=state==IDLE && found_valid && saved_address[17:2]==pixel_addr[17:2];
    assign pixel_ack=(state==REPLY || word_hit) && pixel_req && !invalidate && !reset;
    wire [1:0] read_lane=word_hit ? pixel_addr[1:0] : saved_address[1:0];
    assign pixel_rdata=ram_data[read_lane*16 +: 16];
    assign mem_req=state==FILL;
    assign mem_addr=tile_base[17:2]+{6'b0,fill_beat[3:1],7'b0}+fill_beat[0];
    always @(posedge clk) begin
        directory_data<=directory[request_key];
        if(state==CLEAR) directory[clear_key]<=0;
        else if(state==SELECT && !found_valid && tag_valid[replacement])
            directory[reverse_tags[replacement]]<=0;
        else if(state==FILL && mem_ack && (STREAM_FILL ? fill_beat[3] : fill_beat==15)) begin
            directory[saved_key]<={1'b1,victim};
            reverse_tags[victim]<=saved_key;
        end
    end
    always @(posedge clk) begin
        ram_data<=pixels[ram_read_address];
        if(state==FILL && (STREAM_FILL ? mem_line_valid : mem_ack))
            pixels[ram_write_address]<=STREAM_FILL ? mem_line_data : mem_rdata;
    end
    always @(posedge clk) begin
        case(state)
        CLEAR: begin
            clear_key<=clear_key+1'b1;
            if(&clear_key) state<=IDLE;
        end
        IDLE: if(pixel_req) begin
            saved_address<=pixel_addr;saved_key<=request_key;
            // The previous registered hit remains valid until a miss replaces
            // a tile or a frame invalidates the cache. Reuse it within a tile.
            // The same four-texel word already resides in ram_data; a different
            // word still needs a synchronous RAM read before acknowledging.
            if(found_valid && saved_key==request_key)
                state<=saved_address[17:2]==pixel_addr[17:2] ? (streaming ? IDLE:REPLY) : REPLY;
            else state<=CHECK;
        end
        WAIT_RAM: state<=REPLY;
        CHECK: begin
            found_valid<=directory_data[7];found_slot<=directory_data[6:0];state<=SELECT;
        end
        SELECT: begin
            if(found_valid) state<=REPLY;
            else begin
                victim<=replacement;replacement<=replacement+1'b1;
                tag_valid[replacement]<=0;fill_beat<=0;state<=FILL;
            end
        end
        FILL: if(mem_ack) begin
            // Tile packing maps rows0..3 and4..7 to two aligned DDR lines.
            // The stream adapter acknowledges only after all eight beats.
            if(STREAM_FILL ? fill_beat[3] : fill_beat==15) begin
                // The completed fill already identifies the exact resident slot.
                tag_valid[victim]<=1;found_valid<=1;found_slot<=victim;state<=SELECT;
            end else begin fill_beat<=STREAM_FILL ? 4'd8 : fill_beat+1'b1;state<=GAP;end
        end
        GAP: state<=FILL;
        REPLY: if(streaming ? pixel_req:!pixel_req) state<=IDLE;
        endcase
        if(reset || invalidate) begin
            state<=CLEAR;clear_key<=0;tag_valid<=0;saved_address<=0;saved_key<=0;fill_beat<=0;victim<=0;
            replacement<=0;found_valid<=0;found_slot<=0;
        end
    end
endmodule
