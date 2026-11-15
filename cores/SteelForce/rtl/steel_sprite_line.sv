// Reverse-order sprite scan with one-cycle descriptor prefetch.
// Next descriptor stays queued during row fetch/draw: disabled entries cost one clock.
// Up to two pixels/clock. Nontransparent blocked pixels must still set priority31.
module steel_sprite_line(
    input wire clk,reset,mortalr,start,enabled,
    input wire [7:0] line_y,
    input wire [7:0] first_index,last_index,
    output wire busy,
    output reg done,
    output wire sprite_en,
    output wire [7:0] sprite_index,
    input wire [63:0] sprite_data,
    output wire gfx_req,
    output wire [22:0] gfx_addr,
    input wire gfx_ready,
    input wire [63:0] gfx_data,
    output wire [1:0] pixel_valid,
    output wire [8:0] pixel_x,
    output wire [10:0] pixel_index0,pixel_index1,
    output wire [4:0] pixel_threshold
);
    localparam IDLE=0,FIRST=1,SCAN=2,GFX=3,DRAW=4;
    reg [2:0] state;
    reg [7:0] index,y,end_index;
    reg signed [10:0] x;
    reg [3:0] offset,color;
    reg [13:0] code;
    reg [3:0] row_y;
    reg flip;
    reg [4:0] threshold;
    reg [63:0] row;
    wire [8:0] candidate_y={1'b0,y}+sprite_data[8:0]+9'd1;
    wire [8:0] candidate_height={1'b0,sprite_data[15:12],4'b0}+9'd16;
    wire signed [10:0] candidate_x=$signed({1'b0,sprite_data[57:48]})-11'sd7;
    wire signed [10:0] screen_x=x+$signed({7'b0,offset});
    wire [1:0] count=(offset==15 || screen_x==373) ? 2'd1 : 2'd2;
    wire [63:0] shifted=row >> {offset,2'b00};
    wire [3:0] pen0=shifted[3:0],pen1=shifted[7:4];
    wire [63:0] adjusted,decoded;
    genvar n;
    generate for(n=0;n<16;n=n+1) begin: flip_row
        // Four planes, each left/right byte, interleaved in one 8-byte row.
        assign decoded[n*4+0]=gfx_data[(0*2+(n<8?0:1))*8+(n%8)];
        assign decoded[n*4+1]=gfx_data[(1*2+(n<8?0:1))*8+(n%8)];
        assign decoded[n*4+2]=gfx_data[(2*2+(n<8?0:1))*8+(n%8)];
        assign decoded[n*4+3]=gfx_data[(3*2+(n<8?0:1))*8+(n%8)];
        assign adjusted[n*4+:4]=flip ? decoded[(15-n)*4+:4] : decoded[n*4+:4];
    end endgenerate
    assign busy=state!=IDLE;
    assign sprite_en=state==FIRST || (state==SCAN && index!=end_index);
    assign sprite_index=state==FIRST ? index : index-8'd1;
    assign gfx_req=state==GFX;
    assign gfx_addr=23'h400000+{2'b0,code,7'b0}+{16'b0,row_y,3'b0};
    assign pixel_valid[0]=state==DRAW && pen0!=0;
    assign pixel_valid[1]=state==DRAW && count==2 && pen1!=0;
    assign pixel_x=screen_x[8:0]-9'd8;
    assign pixel_index0=11'h400+{3'b0,color,pen0};
    assign pixel_index1=11'h400+{3'b0,color,pen1};
    assign pixel_threshold=threshold;
    always_ff @(posedge clk) begin
        done<=0;
        if(reset) begin state<=IDLE;index<=0;y<=0;end_index<=0;x<=0;offset<=0;color<=0;code<=0;row_y<=0;flip<=0;threshold<=0;row<=0;end
        else case(state)
            IDLE: if(start) begin
                y<=line_y;index<=first_index;end_index<=last_index;
                if(enabled) state<=FIRST;else done<=1;
            end
            FIRST: state<=SCAN;
            SCAN: begin
                // Horizontal wrapped copies end at x7 or earlier, outside x8..373.
                // Vertical wrapping is candidate_y's modulo512 arithmetic.
                if(sprite_data[11] && candidate_y<candidate_height &&
                   candidate_x<=373 && candidate_x+11'sd15>=8) begin
                    x<=candidate_x;
                    offset<=candidate_x<8 ? (4'd8-candidate_x[3:0]) : 4'b0;
                    color<=sprite_data[19:16];flip<=sprite_data[25];
                    code<=(sprite_data[45:32]+{10'b0,candidate_y[7:4]}) &
                          (mortalr ? 14'h3fff : 14'h1fff);
                    row_y<=candidate_y[3:0];
                    case(sprite_data[21:20])
                        0:threshold<=2;
                        1:threshold<=4;
                        2:threshold<=12;
                        3:threshold<=14;
                    endcase
                    state<=GFX;
                end else if(index==end_index) begin done<=1;state<=IDLE;end
                else index<=index-1'b1;
            end
            GFX: if(gfx_ready) begin row<=adjusted;state<=DRAW;end
            DRAW: begin
                if({1'b0,offset}+{3'b0,count}>=16 || screen_x+$signed({9'b0,count})>=374) begin
                    if(index==end_index) begin done<=1;state<=IDLE;end
                    else begin index<=index-1'b1;state<=SCAN;end
                end else offset<=offset+{2'b0,count};
            end
            default:state<=IDLE;
        endcase
    end
endmodule
