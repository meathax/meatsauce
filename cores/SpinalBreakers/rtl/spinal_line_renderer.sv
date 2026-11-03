// SPDX-License-Identifier: GPL-3.0-or-later
// Component renderer. One clock; held request/reply interface, no timing cuts.
// Static draw-state qualification comes before live frame publication/SDRAM fit.
module spinal_line_renderer #(parameter bit QUEUED=0, parameter integer LINE_BANKS=2)(
    input logic clk,reset,start,publish,flip_line,
    input logic [1:0] draw_bank,show_bank,
    input logic [7:0] line_y,gfxbank,
    input logic [15:0] scrollx1,
    output wire busy,
    output logic done,
    output logic line_ready,
    output logic [7:0] ready_y,
    output logic mem_req,
    output logic [3:0] mem_space,
    output logic [21:0] mem_address,
    input logic mem_ready,
    input logic [63:0] mem_data,
    input logic [8:0] read_x,
    output logic [9:0] read_color
);
    // Spaces:0/1 VRAM word,2 four-word sprite descriptor,3 row-scroll word,
    // 4/5 packed tile row(32b),6/7 packed sprite row(64b),8 sprite lookup word.
    // Addresses are byte offsets. Packed graphics pixel0 occupies bits3:0;
    // descriptor word0 is bits15:0. All replies belong to the held tuple.
    typedef enum logic [4:0] {IDLE,ROW_SEND,ROW_WAIT,BG,VC_WAIT,
        TC_SEND,TC_WAIT,CTRL_SEND,CTRL_WAIT,DESC_SEND,DESC_WAIT,TY_PRE,TY,TX,
        LOOK_SEND,LOOK_WAIT,SPR_SEND,SPR_WAIT,SPR_PIXEL,NEXT_TILE,NEXT_DESC,PREFETCH_WAIT} state_t;
    state_t state;
    logic discarded;
    logic [7:0] y,bank;
    logic flip;
    logic [15:0] scroll,row_scroll;
    logic [8:0] x;
    logic layer,cache_valid;
    logic [10:0] cache_cell;
    logic [15:0] tile_word;
    logic [15:0] cached_tile_code;
    logic [31:0] tile_pixels;
    logic prefetch_ready;
    logic [10:0] fetch_cell;
    logic [15:0] fetch_word,fetch_code;
    logic [31:0] fetch_pixels;
    // Independent synchronous ports keep bank selection outside each RAM.
    logic [1:0] front_bank,render_bank;
    wire [9:0] color_even_q[0:LINE_BANKS-1],color_odd_q[0:LINE_BANKS-1];
    // {background, tile_priority, occupied, sprite_rank}. Background passes
    // initialize every location; no reset loop or asynchronous read is needed.
    (* ramstyle="M10K" *) logic [20:0] metadata_even[0:175],metadata_odd[0:175];
    logic [1:0] read_bank_q;
    logic read_odd_q,read_valid_q;
    logic [20:0] metadata_q_even,metadata_q_odd,forward_data_even,forward_data_odd;
    logic forward_valid_even,forward_valid_odd;
    logic pixel_pending_even,pixel_pending_odd;
    logic [7:0] pending_x_even,pending_x_odd;
    logic [8:0] pending_rank;
    logic [9:0] pending_color_even,pending_color_odd;
    logic pending_priority;
    logic write_even,write_odd;
    logic [7:0] write_x_even,write_x_odd;
    logic [9:0] write_color_even,write_color_odd;
    logic [20:0] write_metadata_even,write_metadata_odd;
    wire [20:0] pixel_metadata_even=forward_valid_even ? forward_data_even : metadata_q_even;
    wire [20:0] pixel_metadata_odd=forward_valid_odd ? forward_data_odd : metadata_q_odd;
    wire [8:0] source_x=layer ? (x+scroll[8:0]+9'd4) : (x+row_scroll[8:0]);
    wire [10:0] tile_cell={y[7:3],source_x[8:3]};
    wire [4:0] nibble_shift={source_x[2:0],2'b00};
    wire [3:0] tile_pen=tile_pixels[nibble_shift+:4];
    wire [15:0] tile_code=layer ? {bank[5:3],tile_word[12:0]} : {1'b0,bank[2:0],tile_word[11:0]};
    wire [15:0] incoming_tile_code=layer ? {bank[5:3],mem_data[12:0]} : {1'b0,bank[2:0],mem_data[11:0]};
    wire background_state=state==BG || state==VC_WAIT || state==TC_SEND || state==TC_WAIT;
    wire draw_background=background_state && cache_valid && tile_cell==cache_cell;
    wire [8:0] next_tile_x=x+9'd8-{6'd0,source_x[2:0]};
    wire [10:0] next_tile_cell={y[7:3],(source_x[8:3]+6'd1)};
    logic chip,priority_pass;
    logic [6:0] first_desc,descriptor;
    logic [8:0] ox,oy;
    logic [5:0] zx,zy;
    logic [2:0] xs,ys,tx,ty;
    logic fx,fy;
    logic [3:0] color,px;
    logic [15:0] map_base;
    logic [16:0] sprite_code;
    logic [63:0] sprite_pixels;
    typedef enum logic [2:0] {PF_IDLE,PF_LOOK_WAIT,PF_SPR_SEND,PF_SPR_WAIT,PF_READY} prefetch_t;
    prefetch_t sprite_prefetch;
    logic [16:0] prefetch_code;
    logic [63:0] prefetch_pixels;
    logic [3:0] sprite_row;
    logic [3:0] row_index_q;
    logic row_hit_q;
    wire [4:0] width=zx[5:1]+{4'd0,zx[0]};
    wire [4:0] height=zy[5:1]+{4'd0,zy[0]};
    wire [2:0] cx=fx ? xs-tx : tx;
    wire [2:0] cy=fy ? ys-ty : ty;
    wire [8:0] sx9=ox+((zx*cx)>>1)+9'd16;
    wire [8:0] sy9=oy+((zy*cy)>>1)+9'd16;
    // For flip, draw sprites into the pre-mirrored line buffer using the
    // SPR2 chip's 308/208 origins and its per-tile zoom. The final scanout
    // reversal then presents the same coordinates as the flipped chip.
    wire [8:0] flipped_sx9=9'd324-ox-((zx*cx)>>1);
    wire [8:0] flipped_sy9=9'd224-oy-((zy*cy)>>1);
    wire signed [10:0] sx=flip ? 11'sd384-$signed({6'd0,width})-$signed({2'b00,flipped_sx9}) : $signed({2'b00,sx9})-11'sd16;
    wire signed [10:0] sy=flip ? 11'sd256-$signed({6'd0,height})-$signed({2'b00,flipped_sy9}) : $signed({2'b00,sy9})-11'sd16;
    wire signed [10:0] dest_x=sx+$signed({7'd0,px})-11'sd8;
    wire signed [10:0] local_y=$signed({3'd0,y})-sy;
    wire [10:0] row_index_ext=fy ? {6'd0,height}-11'd1-$unsigned(local_y) : $unsigned(local_y);
    wire [3:0] row_index=row_index_ext[3:0];
    wire [3:0] last_column=width[3:0]-4'd1;
    wire [3:0] column_index=fx ? last_column-px : px;
    function automatic [16:0] step(input [4:0] n);
        case(n)
            9:step=116508;10:step=104857;11:step=95325;12:step=87381;
            13:step=80659;14:step=74898;15:step=69905;default:step=65536;
        endcase
    endfunction
    wire [20:0] source_y_fixed=row_index_q*step(height);
    wire [20:0] source_x_fixed=column_index*step(width);
    wire [3:0] source_pixel_x=source_x_fixed[19:16];
    wire [3:0] sprite_pen=sprite_pixels[{source_pixel_x,2'b00}+:4];
    // Adjacent destination pixels always occupy different parity banks. Scale
    // each source coordinate independently, preserving odd-width zoom rounding.
    wire [3:0] next_px=px+4'd1;
    wire [3:0] next_column=fx ? last_column-next_px : next_px;
    wire [20:0] next_source_x_fixed=next_column*step(width);
    wire [3:0] next_sprite_pen=sprite_pixels[{next_source_x_fixed[19:16],2'b00}+:4];
    wire signed [10:0] next_dest_x=dest_x+11'sd1;
    wire [7:0] read_meta_even=dest_x[0] ? next_dest_x[8:1] : dest_x[8:1];
    wire [7:0] read_meta_odd=dest_x[0] ? dest_x[8:1] : next_dest_x[8:1];
    wire issue_first=state==SPR_PIXEL && dest_x>=0 && dest_x<352 && sprite_pen!=15;
    wire issue_second=state==SPR_PIXEL && px!=last_column &&
        next_dest_x>=0 && next_dest_x<352 && next_sprite_pen!=15;
    wire [9:0] background_color=layer ? {2'b01,1'b0,tile_word[15:13],tile_pen} : {2'b00,tile_word[15:12],tile_pen};
    wire [3:0] stride=xs<2 ? {1'b0,xs}+1'b1 : xs<4 ? 4'd4 : 4'd8;
    wire [16:0] map_index={1'b0,map_base}+ty*stride+{14'd0,tx};
    wire [16:0] following_map=map_index+17'd1;
    wire [2:0] following_tx=tx+3'd1;
    wire [2:0] following_cx=fx ? xs-following_tx : following_tx;
    wire [8:0] following_sx9=ox+((zx*following_cx)>>1)+9'd16;
    wire [8:0] following_flipped_sx9=9'd324-ox-((zx*following_cx)>>1);
    wire signed [10:0] following_sx=flip ?
        11'sd384-$signed({6'd0,width})-$signed({2'b00,following_flipped_sx9}) :
        $signed({2'b00,following_sx9})-11'sd16;
    wire following_visible=following_sx+$signed({6'd0,width})>8 && following_sx<360;
    // MAME draws chip0/priority0,chip0/priority1,chip1/priority0,chip1/priority1
    // front to back. An explicit rank permits one descriptor read per chip.
    // Even a sprite hidden behind a tile claims its priority position.
    wire [8:0] candidate_rank={chip,priority_pass,(7'd126-descriptor)};
    assign busy=state!=IDLE || mem_req;
    assign read_color=read_valid_q ? (read_odd_q ? color_odd_q[read_bank_q] : color_even_q[read_bank_q]) : 10'd0;
    genvar line_bank;
    generate for(line_bank=0;line_bank<LINE_BANKS;line_bank=line_bank+1)begin: line_storage
        spinal_line_color_ram even_pixels(
            .clk(clk),.read_address(read_x[8:1]),.q(color_even_q[line_bank]),
            .write_enable(write_even && render_bank==line_bank),
            .write_address(write_x_even),.data(write_color_even));
        spinal_line_color_ram odd_pixels(
            .clk(clk),.read_address(read_x[8:1]),.q(color_odd_q[line_bank]),
            .write_enable(write_odd && render_bank==line_bank),
            .write_address(write_x_odd),.data(write_color_odd));
    end endgenerate

    // Each parity bank has one read and one write port. The preceding pair
    // retires while the next pair reads metadata. Forward both collision paths;
    // no mixed-port read-during-write value or extra timing exception is used.
    always_comb begin
        write_even=0;write_odd=0;
        write_x_even=pending_x_even;write_x_odd=pending_x_odd;
        write_color_even=0;write_color_odd=0;
        write_metadata_even=0;write_metadata_odd=0;
        if(!reset && !discarded)begin
            if(draw_background && (!layer || tile_pen!=15))begin
                if(x[0])begin
                    write_odd=1;write_x_odd=x[8:1];write_color_odd=background_color;
                    write_metadata_odd={background_color,layer,1'b0,9'd0};
                end else begin
                    write_even=1;write_x_even=x[8:1];write_color_even=background_color;
                    write_metadata_even={background_color,layer,1'b0,9'd0};
                end
            end else begin
                if(pixel_pending_even && (!pixel_metadata_even[9] || pending_rank<pixel_metadata_even[8:0]))begin
                    write_even=1;
                    write_color_even=pending_priority && pixel_metadata_even[10] ? pixel_metadata_even[20:11] : pending_color_even;
                    write_metadata_even={pixel_metadata_even[20:10],1'b1,pending_rank};
                end
                if(pixel_pending_odd && (!pixel_metadata_odd[9] || pending_rank<pixel_metadata_odd[8:0]))begin
                    write_odd=1;
                    write_color_odd=pending_priority && pixel_metadata_odd[10] ? pixel_metadata_odd[20:11] : pending_color_odd;
                    write_metadata_odd={pixel_metadata_odd[20:10],1'b1,pending_rank};
                end
            end
        end
    end
    always_ff @(posedge clk)begin
        read_bank_q<=QUEUED ? show_bank : front_bank;read_odd_q<=read_x[0];read_valid_q<=read_x<352;
        metadata_q_even<=metadata_even[read_meta_even];metadata_q_odd<=metadata_odd[read_meta_odd];
        if(write_even)metadata_even[write_x_even]<=write_metadata_even;
        if(write_odd)metadata_odd[write_x_odd]<=write_metadata_odd;
        forward_valid_even<=write_even && write_x_even==read_meta_even;
        forward_valid_odd<=write_odd && write_x_odd==read_meta_odd;
        forward_data_even<=write_metadata_even;forward_data_odd<=write_metadata_odd;
        pixel_pending_even<=!reset && !discarded && (dest_x[0] ? issue_second : issue_first);
        pixel_pending_odd<=!reset && !discarded && (dest_x[0] ? issue_first : issue_second);
        pending_x_even<=read_meta_even;pending_x_odd<=read_meta_odd;pending_rank<=candidate_rank;
        pending_color_even<={1'b1,chip,color,(dest_x[0] ? next_sprite_pen : sprite_pen)};
        pending_color_odd<={1'b1,chip,color,(dest_x[0] ? sprite_pen : next_sprite_pen)};
        pending_priority<=priority_pass;
    end
    always_ff @(posedge clk) begin
        done<=0;
        if(reset) begin
            state<=IDLE;
            sprite_prefetch<=PF_IDLE;
            prefetch_ready<=0;cache_valid<=0;
            front_bank<=0;render_bank<=1;line_ready<=0;ready_y<=0;
            // Reset abandons the drawing epoch but drains an outstanding reply.
            // A new start cannot reuse ownership before that tuple retires.
            if(mem_req && !mem_ready)discarded<=1;
            else begin mem_req<=0;discarded<=0;end
        end else if(discarded) begin
            if(mem_ready)begin mem_req<=0;discarded<=0;end
        end else begin
            if(!QUEUED && publish && line_ready)begin front_bank<=render_bank;line_ready<=0;end
            case(state)
            IDLE:if(start && !mem_req && (QUEUED || !line_ready || publish))begin
                y<=line_y;bank<=gfxbank;scroll<=scrollx1;flip<=flip_line;
                // A publish/start coincidence must draw into the old front,
                // never the bank that has just become visible.
                render_bank<=QUEUED ? draw_bank : (publish && line_ready ? front_bank : (front_bank^2'd1));
                if(QUEUED)line_ready<=0;
                state<=ROW_SEND;
            end
            ROW_SEND:begin mem_req<=1;mem_space<=3;mem_address<={13'd0,y,1'b0};state<=ROW_WAIT;end
            ROW_WAIT:if(mem_ready)begin
                mem_req<=0;row_scroll<=mem_data[15:0];x<=0;layer<=0;cache_valid<=0;prefetch_ready<=0;state<=BG;
            end
            BG:begin
                if(!draw_background && prefetch_ready)begin
                    tile_pixels<=fetch_pixels;tile_word<=fetch_word;
                    cached_tile_code<=fetch_code;cache_cell<=fetch_cell;
                    cache_valid<=1;prefetch_ready<=0;
                end else if(!prefetch_ready && (!draw_background || next_tile_x<352))begin
                    // Draw the current tile while fetching the next one. Keep
                    // palette/code/pixels together until that tile is consumed.
                    mem_req<=1;mem_space<=layer ? 1 : 0;
                    fetch_cell<=draw_background ? next_tile_cell : tile_cell;
                    mem_address<={10'd0,(draw_background ? next_tile_cell : tile_cell),1'b0};
                    state<=VC_WAIT;
                end
            end
            VC_WAIT:if(mem_ready)begin
                mem_req<=0;fetch_word<=mem_data[15:0];fetch_code<=incoming_tile_code;
                // Repeated map cells may use the same graphics with a different
                // palette. The row cache is keyed by graphics code, not color.
                if(cache_valid && incoming_tile_code==cached_tile_code)begin
                    fetch_pixels<=tile_pixels;prefetch_ready<=1;state<=BG;
                end else state<=TC_SEND;
            end
            TC_SEND:begin
                mem_req<=1;mem_space<=layer ? 5 : 4;
                // gfx1 has32768 tiles; gfx2 has65536. Address wraps in region.
                mem_address<={1'b0,fetch_code,y[2:0],2'b00};state<=TC_WAIT;
            end
            TC_WAIT:if(mem_ready)begin mem_req<=0;fetch_pixels<=mem_data[31:0];prefetch_ready<=1;state<=BG;end
            CTRL_SEND:begin mem_req<=1;mem_space<=2;mem_address<={11'd0,chip,10'h3f8};state<=CTRL_WAIT;end
            CTRL_WAIT:if(mem_ready)begin
                mem_req<=0;
                first_desc<=mem_data[38:32];
                descriptor<=126;state<=DESC_SEND;
            end
            DESC_SEND:if(descriptor<first_desc)begin
                if(!chip)begin chip<=1;state<=CTRL_SEND;end
                else begin state<=IDLE;done<=1;line_ready<=1;ready_y<=y;end
            end else begin
                mem_req<=1;mem_space<=2;mem_address<={11'd0,chip,descriptor,3'b000};state<=DESC_WAIT;
            end
            DESC_WAIT:if(mem_ready)begin
                mem_req<=0;
                if(!mem_data[39])state<=NEXT_DESC;
                else begin
                    priority_pass<=mem_data[36];
                    oy<=mem_data[8:0];ox<=mem_data[24:16];
                    zy<=6'd32-{2'd0,mem_data[15:12]};zx<=6'd32-{2'd0,mem_data[31:28]};
                    xs<=mem_data[42:40];ys<=mem_data[46:44];fx<=mem_data[43];fy<=mem_data[47];
                    color<=mem_data[35:32];map_base<=mem_data[63:48];ty<=0;tx<=0;state<=TY_PRE;
                end
            end
            // Split sprite position/flip arithmetic from reciprocal row scaling.
            // Every new tile row enters here before either hit or row is used.
            TY_PRE:begin
                row_index_q<=row_index;
                row_hit_q<=local_y>=0 && local_y<$signed({6'd0,height});
                state<=TY;
            end
            TY:if(row_hit_q)begin
                sprite_row<=source_y_fixed[19:16];tx<=0;state<=TX;
            end else if(ty==ys)state<=NEXT_DESC;
                else begin ty<=ty+1'b1;state<=TY_PRE;end
            TX:if(sx+$signed({6'd0,width})<=8 || sx>=360)state<=NEXT_TILE;
                else if(chip)state<=LOOK_SEND;
                else begin sprite_code<=map_index;state<=SPR_SEND;end
            LOOK_SEND:begin mem_req<=1;mem_space<=8;mem_address<={4'd0,map_index,1'b0};state<=LOOK_WAIT;end
            LOOK_WAIT:if(mem_ready)begin mem_req<=0;sprite_code<={1'b0,mem_data[15:0]};state<=SPR_SEND;end
            SPR_SEND:begin
                mem_req<=1;mem_space<=chip ? 7 : 6;
                mem_address<=chip ? {1'b0,sprite_code[13:0],sprite_row,3'b000} : {2'b00,sprite_code[12:0],sprite_row,3'b000};
                state<=SPR_WAIT;
            end
            // Transparent pens neither write color nor claim sprite priority.
            SPR_WAIT:if(mem_ready)begin mem_req<=0;sprite_pixels<=mem_data;px<=0;state<=(&mem_data) ? NEXT_TILE : SPR_PIXEL;end
            SPR_PIXEL:begin
                if(px==last_column || next_px==last_column)state<=NEXT_TILE;
                else px<=px+4'd2;
            end
            NEXT_TILE:if(sprite_prefetch!=PF_IDLE)begin
                state<=PREFETCH_WAIT;
            end else if(tx==xs)begin
                if(ty==ys)state<=NEXT_DESC;
                else begin ty<=ty+1'b1;state<=TY_PRE;end
            end else begin tx<=tx+1'b1;state<=TX;end
            PREFETCH_WAIT:if(sprite_prefetch==PF_READY)begin
                tx<=tx+1'b1;sprite_pixels<=prefetch_pixels;px<=0;
                sprite_prefetch<=PF_IDLE;
                state<=(&prefetch_pixels) ? NEXT_TILE : SPR_PIXEL;
            end
            NEXT_DESC:if(descriptor==0 || descriptor==first_desc)begin
                if(!chip)begin chip<=1;state<=CTRL_SEND;end
                else begin state<=IDLE;done<=1;line_ready<=1;ready_y<=y;end
            end else begin
                descriptor<=descriptor-1'b1;mem_req<=1;mem_space<=2;
                mem_address<={11'd0,chip,(descriptor-7'd1),3'b000};state<=DESC_WAIT;
            end
            default:state<=IDLE;
            endcase
            // ROM contents are immutable during drawing. Fetch only the next
            // visible tile of this same row while its predecessor emits pixels.
            // The request still drops between transactions and retains ownership
            // through an arbitrarily stalled reply, including deadline recovery.
            if(state==SPR_PIXEL || state==NEXT_TILE || state==PREFETCH_WAIT)begin
                case(sprite_prefetch)
                PF_IDLE:if(state==SPR_PIXEL && tx!=xs && following_visible)begin
                    mem_req<=1;
                    if(chip)begin
                        mem_space<=8;mem_address<={4'd0,following_map,1'b0};
                        sprite_prefetch<=PF_LOOK_WAIT;
                    end else begin
                        mem_space<=6;mem_address<={2'b00,following_map[12:0],sprite_row,3'b000};
                        sprite_prefetch<=PF_SPR_WAIT;
                    end
                end
                PF_LOOK_WAIT:if(mem_ready)begin
                    mem_req<=0;prefetch_code<={1'b0,mem_data[15:0]};sprite_prefetch<=PF_SPR_SEND;
                end
                PF_SPR_SEND:begin
                    mem_req<=1;mem_space<=7;
                    mem_address<={1'b0,prefetch_code[13:0],sprite_row,3'b000};sprite_prefetch<=PF_SPR_WAIT;
                end
                PF_SPR_WAIT:if(mem_ready)begin
                    mem_req<=0;prefetch_pixels<=mem_data;sprite_prefetch<=PF_READY;
                end
                default:begin end
                endcase
            end
            if(draw_background)begin
                if(x==351)begin
                    x<=0;cache_valid<=0;prefetch_ready<=0;
                    if(!layer)begin layer<=1;state<=BG;end
                    else begin chip<=0;priority_pass<=0;state<=CTRL_SEND;end
                end else x<=x+1'b1;
            end
        end
    end
endmodule

// Quartus 17 does not infer these arrays when declared inside a generate loop.
// Keep the same registered old-data read and synchronous write in module scope.
module spinal_line_color_ram(
    input logic clk,
    input logic [7:0] read_address,write_address,
    input logic write_enable,
    input logic [9:0] data,
    output logic [9:0] q
);
    (* ramstyle="M10K" *) logic [9:0] pixels[0:175];
    always_ff @(posedge clk)begin
        q<=pixels[read_address];
        if(write_enable)pixels[write_address]<=data;
    end
endmodule
