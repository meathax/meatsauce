/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 4-10-2021 */

// The MXC-06 operates at 12MHz
// That gives an absolute maximum of 48 16-pxl tiles per line
// The actual number will be slightly below

module madmotor_mxc06_draw(
    input              rst,
    input              clk,
    input              chip_cen,
    input              pxl_cen,
    input              HS,
    input              LHBL,
    input              LVBL,
    input              flip,

    input      [ 8:0]  hdump,
    input      [ 8:0]  vrender,

    // Object engine
    output reg [ 9:0]  tbl_addr,
    input      [15:0]  tbl_dout,

    // ROM interface
    output reg         rom_cs,
    output reg [18:1]  rom_addr,
    input      [31:0]  rom_data,
    input              rom_ok,    

    output     [ 7:0]  pxl
);

reg  [7:0] buf_pxl;
reg  [8:0] buf_waddr;
reg  [12:0] id_eff;
wire [7:0] buf_wdata;
reg        buf_we;
reg        cen2;
reg  [2:0] nsize, ncnt;
reg  [1:0] msize; // n = horizontal tiles, m = vertical tiles, like in CPS1
reg        hflip, vflip;

wire [ 8:0] ypos;
reg  [ 8:0] xpos;
reg  [ 8:0] veff, vrf, top, bottom;
reg  [ 3:0] pal;
reg  [12:0] id;
reg  [ 5:0] line_cnt;   // number of drawn tiles in a line
reg         frame, parse_busy, inzone,
            draw, HSl, LVl,
            draw_busy, rom_good;
wire        blink;

assign ypos  = 9'd256-tbl_dout[8:0];
assign blink = tbl_dout[11];

always @* begin
    inzone = 1;
    bottom = ypos;
    case( tbl_dout[12:11] ) // msize
        0: top = ypos - 9'h10;
        1: top = ypos - 9'h20;
        2: top = ypos - 9'h40;
        3: top = ypos - 9'h80;
    endcase
    if( (vrf < top && !top[8]) || vrf >= bottom || bottom < 8 || (top[8] && bottom[8]) )
        inzone = 0;
end

always @* begin
    id_eff = tbl_dout[12:0];
    vrf    = flip ? 9'd256-vrender : vrender;
    case( msize )
        1: id_eff = { id_eff[12:1],     vflip^veff[4]    };
        2: id_eff = { id_eff[12:2], {2{vflip}}^veff[5:4] };
        3: id_eff = { id_eff[12:3], {3{vflip}}^veff[6:4] };
        default:;
    endcase
end

wire [3:0] nsize_aux = (4'd1 << tbl_dout[10:9])-4'd1;

// Mad Motor multi-column descriptor parser, adapted from jtcop_obj_draw.
// Each column owns its code word; only the parent owns X/Y/flip/color/flash.
reg [2:0] columns_left;
reg first_column, parent_draw;
wire [10:0] parent_next = {1'b0,tbl_addr} +
    (tbl_dout[15] ? (11'd4 << tbl_dout[10:9]) : 11'd4);
wire [10:0] column_next = {1'b0,tbl_addr} +
    (columns_left==1 ? 11'd3 : 11'd4);

always @(posedge clk, posedge rst) begin
    if(rst) begin
        tbl_addr<=0; cen2<=0; parse_busy<=0; draw<=0; frame<=0;
        nsize<=0; msize<=0; HSl<=0; LVl<=0;
        columns_left<=0; first_column<=1; parent_draw<=0;
        hflip<=0; vflip<=0; veff<=0; xpos<=0; pal<=0; id<=0;
    end else if(chip_cen) begin
        HSl<=HS; LVl<=LVBL; cen2<=~cen2; draw<=0;
        if(!LVBL && LVl) frame<=~frame;
        if(HSl && !HS) begin
            tbl_addr<=0; parse_busy<=1; cen2<=0;
            first_column<=1; columns_left<=0;
        end
        if(parse_busy && !draw_busy && !draw && cen2) begin
            case(tbl_addr[1:0])
                0: begin
                    {vflip,hflip}<=tbl_dout[14:13];
                    msize<=tbl_dout[12:11];
                    veff<=vrf-ypos;
                    nsize<=0; // One column per draw transaction.
                    columns_left<=nsize_aux[2:0];
                    first_column<=1;
                    if(!inzone || !tbl_dout[15]) begin
                        // Invisible enabled parents still consume all columns.
                        tbl_addr<=parent_next[9:0];
                        if(parent_next[10]) parse_busy<=0;
                    end else tbl_addr<=tbl_addr+10'd1;
                end
                1: begin
                    id<=id_eff;
                    if(first_column) tbl_addr<=tbl_addr+10'd1;
                    else begin
                        xpos<=xpos-9'd16;
                        draw<=parent_draw;
                        columns_left<=columns_left-1'b1;
                        tbl_addr<=column_next[9:0];
                        if(column_next[10]) parse_busy<=0;
                    end
                end
                2: begin
                    xpos<=9'd240-tbl_dout[8:0];
                    pal<=tbl_dout[15:12];
                    parent_draw<=~tbl_dout[11] | frame;
                    draw<=~tbl_dout[11] | frame;
                    first_column<=0;
                    if(columns_left==0) begin
                        tbl_addr<=tbl_addr+10'd2;
                        if(&tbl_addr[9:2]) parse_busy<=0;
                    end else tbl_addr<=tbl_addr+10'd3;
                end
                default: parse_busy<=0;
            endcase
            if(line_cnt>=48) parse_busy<=0;
        end
    end
end

// Draw the sprite
reg  [31:0] draw_data;
wire [ 3:0] draw_pxl;
reg  [ 3:0] draw_cnt;
reg         half;
wire [ 8:0] buf_waflip;

assign draw_pxl  = hflip ? { draw_data[ 8], draw_data[24], draw_data[0], draw_data[16] } :
                           { draw_data[15], draw_data[31], draw_data[7], draw_data[23] };
assign buf_wdata = { pal, draw_pxl };
assign buf_waflip= !flip ? buf_waddr : 9'h100-buf_waddr;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        draw_busy <= 0;
        draw_cnt  <= 0;
        buf_waddr <= 0;
        rom_good  <= 0;
        buf_we    <= 0;
        rom_cs    <= 0;
        half      <= 0;
        ncnt      <= 0;
        line_cnt  <= 0;
    end else if (chip_cen) begin
        rom_good <= rom_ok;
        if( !parse_busy ) line_cnt <= 0;
        if( draw ) begin
            draw_busy <= 1;
            half      <= 0;
            rom_addr <= { id, ~hflip, veff[3:0]^{4{vflip}} }; // 16 bits
            draw_cnt <= 0;
            ncnt     <= nsize;
            rom_cs   <= 1;
            rom_good <= 0;
            buf_waddr<= xpos;
        end
        if( !buf_we && rom_cs && rom_good && rom_ok && draw_cnt==0 ) begin
            draw_data <= rom_data;
            rom_cs    <= 0;
            buf_we    <= 1;
            draw_cnt  <= 7;
        end
        if( buf_we ) begin
            draw_data <= hflip ? draw_data>>1 : draw_data<<1;
            draw_cnt <= draw_cnt-1'd1;
            buf_waddr<= buf_waddr+9'd1;
            if( draw_cnt==0 ) begin
                buf_we    <= 0;
                if( half ) begin
                    line_cnt <= line_cnt + 1'd1;
                    if( ncnt==0 ) begin
                        draw_busy <= 0;
                        rom_cs    <= 0;
                    end else begin // next tile in the sequence
                        rom_addr[5] <= ~hflip;
                        rom_addr[18:6] <= rom_addr[18:6]+(13'd1<<msize);
                        rom_cs   <= 1;
                        rom_good <= 0;
                        half     <= 0;
                        draw_cnt <= 0;
                        ncnt     <= ncnt-1'd1;
                    end
                end else begin // second half of 16-pxl tile
                    rom_addr[5] <= ~rom_addr[5];
                    rom_cs      <= 1;
                    rom_good    <= 0;
                    half        <= 1;
                    draw_cnt    <= 0;
                end
            end
        end
    end
end

jtframe_obj_buffer #(.ALPHA  ( 8'H0  ))
u_buffer (
    .clk        ( clk       ),
    .LHBL       ( LHBL      ),
    .flip       ( 1'b0      ),
    // New data writes
    .wr_data    ( buf_wdata ),
    .wr_addr    ( buf_waflip),
    .we         ( buf_we & chip_cen    ),
    // Old data reads (and erases)
    .rd_addr    ( hdump     ),
    .rd         ( pxl_cen   ),
    .rd_data    ( pxl       )
);

endmodule 