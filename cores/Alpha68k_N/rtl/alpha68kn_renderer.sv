// Alpha68k N strip engine, pinned MAME 0.289 formulas.
// One master clock, synchronous metadata ROM/RAM ports and live per-line fetches.
module alpha68kn_renderer (
    input wire clk,reset,line_start,flip,stingray,
    input wire rotate180,
    input wire [8:0] line_y,video_y,
    input wire [7:0] video_x,
    output reg [8:0] video_pen,
    output wire [11:0] strip_addr,
    input wire [15:0] strip_data,
    output wire [12:0] color_addr,
    input wire [7:0] color_data,
    output wire gfx_req,
    output wire [18:0] gfx_addr,
    input wire gfx_ack,gfx_ready,
    input wire [15:0] gfx_data,
    output reg [11:0] worst_line_cycles,
    output reg [31:0] completed_lines,deadline_misses,row_overflows
);
    localparam DONE=0,CLEAR=1,POS_RD=2,POS_LAT=3,TILE_RD=4,TILE_LAT=5,
               COLOR_RD=6,COLOR_LAT=7,G0=8,GAP=9,G1=10;
    reg [3:0] state;
    reg [7:0] clear_x;
    reg render_bank;
    reg [8:0] target_y;
    reg [1:0] group_index;
    reg [4:0] strip_index,selected_tile;
    reg [2:0] selected_row;
    reg signed [9:0] mx;
    reg [15:0] tile_word,plane0;
    reg [2:0] bank;
    reg [10:0] tile_code;
    reg [2:0] source_row;
    reg [4:0] tile_color;
    reg acked,line_active;
    reg [11:0] elapsed;
    reg row_valid,draw_busy;
    reg [23:0] row_pixels,draw_pixels;
    reg [4:0] row_color,draw_color;
    reg signed [9:0] row_x,draw_x;
    reg row_flip,draw_flip;
    reg [2:0] draw_column;
    wire row_taken=row_valid && !draw_busy;
    wire finished=state==DONE && !row_valid && !draw_busy;
    wire [1:0] group_c=group_index==0 ? 2'd2 : group_index==1 ? 2'd3 : 2'd1;
    wire [11:0] group_d=group_index==0 ? 12'h800 : group_index==1 ? 12'hc00 : 12'h400;
    wire [7:0] normal_y=-strip_data[15:8];
    wire [7:0] origin_y=flip ? 8'd249-normal_y : normal_y;
    wire [7:0] relative_y=target_y[7:0]-origin_y;
    wire [4:0] tile_at_line=flip ? -relative_y[7:3] : relative_y[7:3];
    wire [18:0] kyros_base=bank[2:1]==0 ? 19'h00000 :
        bank[2:1]==1 ? 19'h18000 : bank[2:1]==2 ? 19'h30000 : 19'h48000;
    wire [18:0] base=stingray ? (bank[1] ? 19'h10000 : 19'd0) : kyros_base;
    wire [18:0] plane_offset=stingray ?
        (bank==1 ? 19'h28000 : bank==3 ? 19'h10000 : 19'h08000) :
        (bank[0] ? 19'h10000 : 19'h08000);
    wire [18:0] row_address=base+{4'd0,tile_code,4'd0}+{16'd0,source_row};
    assign strip_addr=(state==POS_RD || state==POS_LAT) ?
        {2'd0,strip_index,5'd0}+{10'd0,group_c} :
        group_d+{2'd0,strip_index,5'd0}+{7'd0,selected_tile};
    assign color_addr={tile_word[13],tile_word[11:2],tile_word[15:14]};
    assign gfx_addr=row_address+(state==G1 ? plane_offset : 19'd0);
    assign gfx_req=(state==G0 || state==G1) && !acked;

    // MAME readbit is MSB first. Layout offset 4 therefore selects the low
    // nibble. Plane 0 contributes pixel bit 2; planes 1/2 share another word.
    function automatic [23:0] decode_row(input [15:0] p0,p12,input high0);
        reg [23:0] result;
        integer bitpos;
        begin
            for(integer column=0;column<8;column=column+1) begin
                bitpos=(column<4 ? 8 : 0)+(column%4);
                result[column*3+:3]={p0[bitpos+(high0?4:0)],p12[bitpos+4],p12[bitpos]};
            end
            decode_row=result;
        end
    endfunction
    task automatic advance_strip;
        begin
            if(strip_index==31) begin
                strip_index<=0;
                if(group_index==2) state<=DONE;
                else begin group_index<=group_index+1'b1;state<=POS_RD;end
            end else begin strip_index<=strip_index+1'b1;state<=POS_RD;end
        end
    endtask

    reg [8:0] linebuf[0:511];
    initial for(integer i=0;i<512;i=i+1) linebuf[i]=9'h100;
    wire [2:0] pixel_column=draw_flip ? 3'd7-draw_column : draw_column;
    wire [2:0] pixel=draw_pixels[pixel_column*3+:3];
    wire signed [9:0] screen_x=draw_x+$signed({7'd0,draw_column});
    wire draw_write=draw_busy && pixel!=0 && screen_x>=0 && screen_x<256;
    wire write_en=!reset && !line_start && (state==CLEAR || draw_write);
    wire [8:0] write_addr={render_bank,state==CLEAR ? clear_x : screen_x[7:0]};
    wire [8:0] write_pen=state==CLEAR ? 9'h100 : {1'b0,draw_color,pixel};
    // One write port shared by clearing and drawing; independent display read.
    always @(posedge clk) begin
        if(write_en) linebuf[write_addr]<=write_pen;
        video_pen<=linebuf[{video_y[0],rotate180 ? ~video_x : video_x}];
    end

    always @(posedge clk) begin
        if(reset || line_start) begin
            draw_busy<=0;draw_column<=0;
        end else if(row_taken) begin
            draw_busy<=1;draw_column<=0;draw_pixels<=row_pixels;
            draw_x<=row_x;draw_color<=row_color;draw_flip<=row_flip;
        end else if(draw_busy) begin
            if(draw_column==7) draw_busy<=0;
            else draw_column<=draw_column+1'b1;
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            state<=DONE;row_valid<=0;acked<=0;line_active<=0;elapsed<=0;
            worst_line_cycles<=0;completed_lines<=0;deadline_misses<=0;row_overflows<=0;
            clear_x<=0;render_bank<=0;target_y<=0;group_index<=0;strip_index<=0;
            selected_tile<=0;selected_row<=0;mx<=0;tile_word<=0;plane0<=0;
            bank<=0;tile_code<=0;source_row<=0;tile_color<=0;
            row_pixels<=0;row_color<=0;row_x<=0;row_flip<=0;
        end else begin
            if(row_taken) row_valid<=0;
            if(line_active) begin
                elapsed<=elapsed+1'b1;
                if(finished) begin
                    line_active<=0;completed_lines<=completed_lines+1'b1;
                    if(elapsed>worst_line_cycles) worst_line_cycles<=elapsed;
                end
            end
            if(line_start) begin
                if(line_active && !finished) deadline_misses<=deadline_misses+1'b1;
                state<=CLEAR;clear_x<=0;render_bank<=!line_y[0];
                target_y<=rotate180 ? 9'd255-(line_y==263 ? 9'd0 : line_y+1'b1) :
                    (line_y==263 ? 9'd0 : line_y+1'b1);
                group_index<=0;strip_index<=0;row_valid<=0;acked<=0;
                line_active<=1;elapsed<=0;
            end else case(state)
                CLEAR:begin
                    if(clear_x==255) state<=target_y<16 || target_y>=240 ? DONE : POS_RD;
                    else clear_x<=clear_x+1'b1;
                end
                POS_RD:state<=POS_LAT;
                POS_LAT:begin
                    selected_tile<=tile_at_line;selected_row<=relative_y[2:0];
                    mx<=stingray && strip_data[7:0]>248 ?
                        $signed({2'b00,strip_data[7:0]})-10'sd256 :
                        $signed({2'b00,strip_data[7:0]});
                    state<=TILE_RD;
                end
                TILE_RD:state<=TILE_LAT;
                TILE_LAT:begin
                    tile_word<=strip_data;
                    bank<=stingray ? {1'b0,strip_data[11:10]} : {strip_data[15],strip_data[11:10]};
                    tile_code<=stingray ? {1'b0,strip_data[9:0]} : {strip_data[13],strip_data[9:0]};
                    source_row<=(strip_data[12]^flip) ? ~selected_row : selected_row;
                    if(strip_data==(stingray ? 16'h0040 : 16'h0020)) advance_strip();
                    else if(stingray) begin
                        tile_color<={strip_data[11:10],strip_data[15:13]};
                        acked<=0;state<=G0;
                    end else state<=COLOR_RD;
                end
                COLOR_RD:state<=COLOR_LAT;
                COLOR_LAT:begin
                    // 0xff is a valid Kyros color, reduced modulo 32.
                    tile_color<=color_data[4:0];acked<=0;state<=G0;
                end
                G0:begin
                    if(gfx_ack) acked<=1;
                    if(gfx_ready) begin plane0<=gfx_data;acked<=0;state<=GAP;end
                end
                GAP:state<=G1;
                G1:begin
                    if(gfx_ack) acked<=1;
                    if(gfx_ready) begin
                        row_pixels<=decode_row(plane0,gfx_data,bank[0]);
                        row_color<=tile_color;row_x<=mx;row_flip<=flip;row_valid<=1;acked<=0;
                        if(row_valid && !row_taken) row_overflows<=row_overflows+1'b1;
                        advance_strip();
                    end
                end
                default:;
            endcase
        end
    end
endmodule
