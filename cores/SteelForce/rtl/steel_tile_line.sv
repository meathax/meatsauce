// Four-layer scanline fetcher. One board clock, synchronous main-RAM reads.
// Graphics rows use the byte-preserving linear layout from stage_graphics.py.
// Produces palette/priority writes; line compositor must OR tile priorities.
module steel_tile_line(
    input wire clk, reset, mortalr, start,
    input wire [7:0] line_y,
    output wire busy,
    output reg done,
    output wire ram_en,
    output reg [16:0] ram_addr,
    input wire [15:0] ram_data,
    output wire gfx_req,
    output reg [22:0] gfx_addr,
    input wire gfx_ready,
    input wire [63:0] gfx_data,
    output wire [1:0] pixel_valid,
    output wire [8:0] pixel_x,
    output wire [10:0] pixel_index0, pixel_index1,
    output wire sprites_enabled,
    output wire [4:0] pixel_priority
);
    localparam IDLE=0, ATTR_REQ=1, ATTR_WAIT=2, LAYER=3, SCROLL_REQ=4,
        SCROLL_WAIT=5, TILE_REQ=6, TILE_WAIT=7, GFX_WAIT=8, DRAW=9, ADVANCE=10, NEXT_TILE=11;
    // Next-tile prefetch runs beside DRAW so tile-word RAM reads and graphics latency are hidden behind drawing.
    localparam PF_IDLE=0, PF_RAM=1, PF_RAMW=2, PF_GFX=3, PF_DONE=4;
    reg [3:0] state;
    reg [2:0] attr_index;
    reg [15:0] attr[0:7];
    reg [1:0] layer;
    reg [7:0] y, world_y;
    reg [9:0] world_x;
    reg [8:0] x;
    reg [15:0] tile_word;
    reg [63:0] row;
    reg [2:0] pf;
    reg [9:0] pf_x;
    reg [15:0] pf_word;
    reg [63:0] pf_row;
    wire text_layer=layer==3;
    wire [3:0] offset=text_layer ? {1'b0,world_x[2:0]} : world_x[3:0];
    wire [63:0] shifted_row=row >> {offset,2'b00};
    wire [3:0] pen0=shifted_row[3:0],pen1=shifted_row[7:4];
    wire [1:0] count=(x==365 || offset==(text_layer ? 4'd7 : 4'd15)) ? 2'd1 : 2'd2;
    wire [12:0] code=tile_word[12:0] & ((mortalr || text_layer) ? 13'h1fff : 13'h0fff);
    assign busy=state!=IDLE;
    assign sprites_enabled=attr[5][4];
    wire [12:0] pf_code=pf_word[12:0] & ((mortalr || text_layer) ? 13'h1fff : 13'h0fff);
    wire [4:0] tile_len=text_layer ? 5'd8 : 5'd16;
    wire [9:0] pf_next_x=world_x+{5'b0,tile_len-{1'b0,offset}};
    // The tile after this one starts at x_next; it exists (and will be consumed) only if that is still on screen.
    wire [9:0] x_next=x+{5'b0,tile_len-{1'b0,offset}};
    wire pf_wanted=x_next<366;
    assign ram_en=state==ATTR_REQ || state==SCROLL_REQ || state==TILE_REQ || pf==PF_RAM;
    assign gfx_req=state==GFX_WAIT || pf==PF_GFX;
    assign pixel_valid[0]=state==DRAW && (pen0!=0 || layer==0);
    assign pixel_valid[1]=state==DRAW && count==2 && (pen1!=0 || layer==0);
    assign pixel_x=x;
    assign pixel_index0={2'b00,layer,7'b0}+{4'b0,tile_word[15:13],pen0};
    assign pixel_index1={2'b00,layer,7'b0}+{4'b0,tile_word[15:13],pen1};
    assign pixel_priority=text_layer ? 5'h10 : (5'b1 << layer);
    always_comb begin
        ram_addr=0;
        if(state==ATTR_REQ) ram_addr=17'h01e00+{14'b0,attr_index};
        if(state==SCROLL_REQ)
            ram_addr=17'h01800+{6'b0,layer,9'b0}+
                (attr[6][{1'b0,layer,1'b0}] ? {9'b0,world_y} : 17'b0);
        if(state==TILE_REQ || pf==PF_RAM) begin
            if(text_layer) ram_addr=17'h00c00+{6'b0,world_y[7:3],6'b0}+{11'b0,(state==TILE_REQ ? world_x[8:3] : pf_x[8:3])};
            else ram_addr={5'b0,layer,10'b0}+{7'b0,(state==TILE_REQ ? world_x[9:4] : pf_x[9:4]),4'b0}+{13'b0,world_y[7:4]};
        end
        if(text_layer)
            gfx_addr=23'h280000+{5'b0,pf==PF_GFX ? pf_code : code,5'b0}+{18'b0,world_y[2:0],2'b0};
        else
            gfx_addr=23'h100000+(mortalr ? {1'b0,layer,20'b0} : {2'b0,layer,19'b0})+
                {3'b0,pf==PF_GFX ? pf_code : code,7'b0}+{16'b0,world_y[3:0],3'b0};
    end
    always_ff @(posedge clk) begin
        done<=0;
        if(reset) begin pf<=PF_IDLE;pf_x<=0;pf_word<=0;pf_row<=0;state<=IDLE;layer<=0;x<=0;attr_index<=0;y<=0;world_y<=0;world_x<=0;tile_word<=0;row<=0;end
        else case(state)
            IDLE: if(start) begin y<=line_y;attr_index<=0;state<=ATTR_REQ;end
            ATTR_REQ: state<=ATTR_WAIT;
            ATTR_WAIT: begin
                attr[attr_index]<=ram_data;
                if(attr_index==7) begin layer<=0;state<=LAYER;end
                else begin attr_index<=attr_index+1'b1;state<=ATTR_REQ;end
            end
            LAYER: begin
                if(!attr[5][{2'b0,layer}] || (mortalr && text_layer)) state<=ADVANCE;
                else begin
                    x<=0;world_y<=y+attr[{1'b0,layer}+3'd1][7:0]+8'b1;
                    if(text_layer) begin world_x<={1'b0,attr[0][8:0]}+10'd23;state<=TILE_REQ;end
                    else state<=SCROLL_REQ;
                end
            end
            SCROLL_REQ: state<=SCROLL_WAIT;
            SCROLL_WAIT: begin world_x<=ram_data[9:0]+10'd26-{8'b0,layer};state<=TILE_REQ;end
            TILE_REQ: state<=TILE_WAIT;
            TILE_WAIT: begin tile_word<=ram_data;state<=GFX_WAIT;end
            GFX_WAIT: if(gfx_ready) begin
                row<=gfx_data;state<=DRAW;
                if(pf_wanted) begin pf_x<=pf_next_x;pf<=PF_RAM;end
            end
            DRAW: begin
                if(x+{7'b0,count}>=366) state<=ADVANCE;
                else begin
                    x<=x+{7'b0,count};
                    if(text_layer) world_x<={1'b0,world_x[8:0]+{7'b0,count}};
                    else world_x<=world_x+{8'b0,count};
                    if(offset>=(text_layer ? 4'd6 : 4'd14)) state<=NEXT_TILE;
                end
            end
            NEXT_TILE: if(pf==PF_DONE) begin
                tile_word<=pf_word;row<=pf_row;state<=DRAW;
                if(pf_wanted) begin pf_x<=pf_next_x;pf<=PF_RAM;end
                else pf<=PF_IDLE;
            end
            ADVANCE: begin
                if(layer==3) begin done<=1;state<=IDLE;end
                else begin layer<=layer+1'b1;state<=LAYER;end
            end
            default: state<=IDLE;
        endcase
        if(!reset) case(pf)
            PF_RAM: pf<=PF_RAMW;
            PF_RAMW: begin pf_word<=ram_data;pf<=PF_GFX;end
            PF_GFX: if(gfx_ready) begin pf_row<=gfx_data;pf<=PF_DONE;end
            default: ;
        endcase
    end
endmodule
