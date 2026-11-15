// SPDX-License-Identifier: GPL-3.0-or-later
// Gaiapolis adaptation: raw chip ROM interface, title offsets and callback.
// Line producer/consumer adapted from the primary Violent Storm donor,
// whose GPL-3.0-or-later GX173/Moo Mesa lineage is meathax/Bucky commit
// c7a9b82cac107d8dfea602e991c261923b9cd440. Shared VRAM stays external.
// Raw ROM words are little endian by byte address; each row has four chunky
// bytes followed by the erased fifth plane. No decoded copy is required.
module gaiapolis_k056832_video #(
    // Native measured CCU active origin and MAME's visible bitmap origin.
    parameter integer VACTIVE_FIRST=271,
    parameter integer BITMAP_TOP=16,
    parameter integer PREFETCH_LINES=1
)(
    input wire monster,
    input             rst,
    input             clk,
    input             pxl_cen,
    input       [8:0] hpos,
    input       [8:0] vpos,
    input             lhbl,
    input             lvbl,
    input             hs,
    input             vs,
    input       [3:0] gfx_en,
    input       [3:0] layer_en,     // K055555 input enables A-D

    input       [3:0] page0, page1, page2, page3,
    // Full 16-bit signed scroll registers -- see Fix 4, jtviostorm_k056832.sv.
    input signed [15:0] dx0, dx1, dx2, dx3,
    input signed [15:0] dy0, dy1, dy2, dy3,
    input       [1:0] flip0, flip1, flip2, flip3,
    // REG0 global flips and signed REG1D/REG1E corrections.
    input             gflip_x, gflip_y,
    input       signed [12:0] corr_x,
    input       signed [11:0] corr_y,
    input       [8:0] rom_bank,
    input       [511:0] config_regs, // Raw REG0..REG1F, word i at16*i +:16.

    // Gaiapolis uses internal scroll RAM. REG0 bit1 affects the CPU page16
    // window; it does not enable MAME's separate external scroll configuration.
    output reg [16:1] vram_addr,
    input      [15:0] vram_dout,

    // Shared aligned RAW 32-bit tile-ROM port, little endian by byte address.
    output            tile_cs,
    output     [22:2] tile_addr,
    input      [31:0] tile_data,
    input             tile_ok,

    // Palette nibble[8:5], retained pen[4:0] with stored fifth plane zero.
    output     [8:0]  lyrf_pxl,
    output     [8:0]  lyra_pxl,
    output     [8:0]  lyrb_pxl,
    output     [8:0]  lyrc_pxl,
    output     [1:0]  lyrf_mix,
    output     [1:0]  lyra_mix,
    output     [1:0]  lyrb_mix,
    output     [1:0]  lyrc_mix
);

    // Gaiapolis VIDEO_START offsets: X {-1,+2,+4,+5}, Y {-1,0,0,0}.
    function signed [9:0] layer_offx(input [1:0] layer);
        case(layer)
            2'd0: layer_offx=monster ? 10'sd2 : -10'sd1;
            2'd1: layer_offx=monster ? 10'sd4 : 10'sd2;
            2'd2: layer_offx=monster ? 10'sd6 : 10'sd4;
            default: layer_offx=monster ? 10'sd7 : 10'sd5;
        endcase
    endfunction

    function signed [9:0] layer_offy(input [1:0] layer);
        layer_offy=(!monster && layer==2'd0) ? -10'sd1 : 10'sd0;
    endfunction

    function [3:0] layer_page(input [1:0] layer);
        case (layer)
            2'd0: layer_page = page0;
            2'd1: layer_page = page1;
            2'd2: layer_page = page2;
            default: layer_page = page3;
        endcase
    endfunction

    function signed [15:0] layer_dx(input [1:0] layer);
        case (layer)
            2'd0: layer_dx = dx0;
            2'd1: layer_dx = dx1;
            2'd2: layer_dx = dx2;
            default: layer_dx = dx3;
        endcase
    endfunction

    function signed [15:0] layer_dy(input [1:0] layer);
        case (layer)
            2'd0: layer_dy = dy0;
            2'd1: layer_dy = dy1;
            2'd2: layer_dy = dy2;
            default: layer_dy = dy3;
        endcase
    endfunction

    function [1:0] layer_flip(input [1:0] layer);
        case (layer)
            2'd0: layer_flip = flip0;
            2'd1: layer_flip = flip1;
            2'd2: layer_flip = flip2;
            default: layer_flip = flip3;
        endcase
    endfunction

    // Producer = two overlapped stages: V reads the attribute/code words of
    // the next tile from VRAM while R fetches the current tile's ROM row.
    localparam P_IDLE=4'd0, P_SETUP=4'd1, P_ATTR=4'd2, P_ATTR2=4'd3,
               P_CODE=4'd4, P_CODE2=4'd5, P_XFER=4'd6,
               P_LAYER=4'd7,P_LSHI=4'd8,P_LSHI2=4'd9,
               P_LSLO=4'd10,P_LSLO2=4'd11;
    // XFER resolves blank/cached rows straight to R_DEP and presents misses
    // with a ready address in R_REQ; a ROM response hands off without R_DEP
    // whenever the writer slot is free.
    localparam R_IDLE=3'd0, R_REQ=3'd2, R_WAIT=3'd3, R_DEP=3'd4,
               R_REQ2=3'd5, R_WAIT2=3'd6;
    localparam C_IDLE=1'b0, C_WRITE=1'b1;

    reg [3:0] pf_st;
    reg       cs_st;
    reg [1:0] flyr;
    reg [5:0] ftile;
    reg signed [11:0] fline;
    reg [15:0] attr_p, code_p;
    reg [7:0] plane_p, h_plane, plane_c;
    reg signed [31:0] line_dx;
    reg [15:0] ls_high;
    reg [3:0] tile_modes,previous_reg4;
    reg [31:0] romdata_p;
    reg [22:0] rom_addr;
    reg [2:0]  r_st;
    reg        r_busy;
    reg        r_discard;
    reg [15:0] r_attr, r_code;
    reg [1:0]  r_flip, r_lyr;
    reg [2:0]  r_sub, r_tyf;
    reg [5:0]  r_tile;
`ifdef VS_ALLLAYERS
    wire [3:0] len = 4'hf;   // worst-case timing test: fetch all four layers
`else
    wire [3:0] len = layer_en;
`endif
    reg [2:0]  fpx8;
    reg [1:0]  wlyr;
    reg [5:0]  wtile;
    reg [15:0] attr_c;
    reg [31:0] romdata_c;
    reg [1:0]  flip_c;
    reg [2:0]  subc;
    reg        hs_valid;
    wire       fetch_busy = (pf_st != P_IDLE) || r_busy || hs_valid;
    reg [15:0] h_attr;
    reg [31:0] h_rom;
    reg [5:0]  h_tile;
    reg [1:0]  h_lyr;
    reg [2:0]  h_sub;
    reg [1:0]  h_flip;
    reg        prev_lhbl;
    reg        dispbank;
    reg        fbank;
    reg [8:0]  fill_cov [0:3];
    reg [8:0]  disp_cov [0:3];

    // Tile-row cache. A ROM row is identified exactly by {code,tyf}; ROM is
    // read-only, so a matching entry is always correct and needs no epoch.
    // Text/HUD layers repeat a few codes per line, so most rows skip SDRAM.
    // Index = code[5:0]; tag = {code[15:6],tyf}; data = {plane,word}.
    // The lookup reads every clock at the VRAM code word. A hit additionally
    // requires the registered read index to equal code_p[5:0] (a CPU VRAM
    // write during an XFER stall can move the read) and no same-edge write.
    // Producer-side fill request, then one pipeline stage before the MLAB write
    // port: gives the write address/data a dedicated low-fanout launch register.
    reg        cwe_p;
    reg [5:0]  cw_idx_p;
    reg [12:0] cw_tag_p;
    reg [39:0] cw_data_p;
    (* preserve *) reg        cwe;
    (* preserve *) reg [5:0]  cw_idx;
    (* preserve *) reg [12:0] cw_tag;
    (* preserve *) reg [39:0] cw_data;
    always @(posedge clk) begin
        cwe <= cwe_p; cw_idx <= cw_idx_p; cw_tag <= cw_tag_p; cw_data <= cw_data_p;
    end
    reg [63:0] cache_valid;
    reg        cache_valid_q,cache_collide_q;
    reg [5:0]  cache_ridx_q;
    reg [52:0] cache_q;
    (* ramstyle = "MLAB, no_rw_check" *) reg [52:0] row_cache [0:63];
    // Index from the registered code (not the VRAM output): a combinational
    // M10K-q to MLAB-address path makes Quartus refuse to infer the VRAM RAM.
    reg        xfer_w;
    wire [5:0] cache_ridx = code_p[5:0];
    always @(posedge clk) begin
        if(cwe) row_cache[cw_idx] <= {cw_tag,cw_data};
        cache_q <= row_cache[cache_ridx];
        cache_ridx_q <= cache_ridx;
        cache_collide_q <= cwe && cw_idx==cache_ridx;
    end
    always @(posedge clk or posedge rst)
        if(rst) begin cache_valid<=64'd0; cache_valid_q<=1'b0; end
        else begin
            if(cwe) cache_valid[cw_idx]<=1'b1;
            cache_valid_q<=cache_valid[cache_ridx];
        end


    function [15:0] reg_word(input [4:0] idx);
        reg_word=config_regs[{idx,4'b0} +:16];
    endfunction
    function [1:0] map_height(input [1:0] layer);
        map_height=2'(reg_word(5'd8+{3'b0,layer}));
    endfunction
    function [1:0] map_width(input [1:0] layer);
        map_width=2'(reg_word(5'd12+{3'b0,layer}));
    endfunction
    function [31:0] height_pixels(input [1:0] size);
        height_pixels=32'd256 * (32'd1+{30'b0,size});
    endfunction
    function [31:0] width_mask(input [1:0] size);
        width_mask=(32'd512 * (32'd1+{30'b0,size})) - 32'd1;
    endfunction
    // 4**n == 1 (mod 3): reduce twelve base-four digits in a balanced tree.
    // This preserves all 32-bit scroll values without a general divider.
    function automatic [1:0] add_mod3(input [1:0] a,b);
        reg [2:0] sum;
        begin
            sum={1'b0,a}+{1'b0,b};
            add_mod3=2'(sum>=3'd3 ? sum-3'd3 : sum);
        end
    endfunction
    function automatic [1:0] mod3_24(input [23:0] value);
        reg [1:0] digit[0:15],pair[0:7],quad[0:3],octet[0:1];
        integer n;
        begin
            for(n=0;n<16;n=n+1)
                if(n<12) digit[n]=value[n*2 +:2]==3 ? 2'd0 : value[n*2 +:2];
                else digit[n]=0;
            for(n=0;n<8;n=n+1) pair[n]=add_mod3(digit[2*n],digit[2*n+1]);
            for(n=0;n<4;n=n+1) quad[n]=add_mod3(pair[2*n],pair[2*n+1]);
            for(n=0;n<2;n=n+1) octet[n]=add_mod3(quad[2*n],quad[2*n+1]);
            mod3_24=add_mod3(octet[0],octet[1]);
        end
    endfunction
    function [10:0] wrap_x(input signed [31:0] value,input [1:0] size);
        reg [10:0] tmp;
        begin
            case(size)
                2'd0: tmp={2'b0,value[8:0]};
                2'd1: tmp={1'b0,value[9:0]};
                // Signed V=U-sign*2^32; 2^23 mod3=2, so subtracting
                // the sign extension adds1 to the upper quotient modulo3.
                2'd2: tmp={add_mod3(mod3_24({1'b0,value[31:9]}),
                                   value[31] ? 2'd1 : 2'd0),value[8:0]};
                default: tmp=value[10:0];
            endcase
            wrap_x=tmp[10:0];
        end
    endfunction
    function [9:0] wrap_y(input signed [31:0] value,input [1:0] size);
        reg [9:0] tmp;
        begin
            case(size)
                2'd0: tmp={2'b0,value[7:0]};
                2'd1: tmp={1'b0,value[8:0]};
                // Here2^24 mod3=1: the signed correction adds2.
                2'd2: tmp={add_mod3(mod3_24(value[31:8]),
                                   value[31] ? 2'd2 : 2'd0),value[7:0]};
                default: tmp=value[9:0];
            endcase
            wrap_y=tmp[9:0];
        end
    endfunction
    function [2:0] page_owner(input [3:0] page);
        integer layer,row,col;
        reg [3:0] origin;
        reg [1:0] physical_row,physical_col;
        begin
            page_owner=3'd4;
            for(layer=0;layer<4;layer=layer+1) begin
                origin=layer_page(2'(layer));
                for(row=0;row<4;row=row+1) for(col=0;col<4;col=col+1) begin
                    physical_row=origin[3:2]+2'(row);
                    physical_col=origin[1:0]+2'(col);
                    if(row<=int'(map_height(2'(layer))) &&
                       col<=int'(map_width(2'(layer))) &&
                       page=={physical_row,physical_col}) page_owner=3'(layer);
                end
            end
        end
    endfunction
    function association_enabled();
        integer layer;
        begin
            association_enabled=1'b1;
            for(layer=0;layer<4;layer=layer+1)
                if(layer_page(2'(layer))==4'd0 &&
                   map_height(2'(layer))==2'd3 && map_width(2'(layer))==2'd3)
                    association_enabled=1'b0;
        end
    endfunction

    // MAME resets cached tile modes to1 and raw REG4 to0; unchanged raw writes
    // preserve the cache. Transition tracking matches word_w's changed-bit test.
    wire [3:0] reg4_word=4'(reg_word(5'd4));
    always @(posedge clk or posedge rst)
        if(rst) begin tile_modes<=4'hf; previous_reg4<=4'h0; end
        else begin
            tile_modes<=(tile_modes & ~(previous_reg4 ^ reg4_word[3:0])) |
                        (reg4_word[3:0] & (previous_reg4 ^ reg4_word[3:0]));
            previous_reg4<=reg4_word[3:0];
        end

    wire [1:0] map_h=map_height(flyr),map_w=map_width(flyr);
    wire signed [15:0] dx_val=layer_dx(flyr),dy_val=layer_dy(flyr);
    wire signed [9:0] offx_val=layer_offx(flyr),offy_val=layer_offy(flyr);
    wire signed [31:0] bitmap_y={{20{fline[11]}},fline};
    wire signed [31:0] dy_corr={{16{dy_val[15]}},dy_val} +
         (gflip_y ? {{20{corr_y[11]}},corr_y} : 32'sd0);
    wire signed [31:0] ay_value=dy_corr-{{22{offy_val[9]}},offy_val};
    // Explicit unsigned modulo is observable at negative scroll on height768.
    wire [31:0] ay=map_h==2'd0 ? {24'd0,ay_value[7:0]} :
                       map_h==2'd1 ? {23'd0,ay_value[8:0]} :
                       map_h==2'd2 ? {22'd0,mod3_24(ay_value[31:8]),ay_value[7:0]} :
                                       {22'd0,ay_value[9:0]};
    wire signed [31:0] y_unwrapped=gflip_y ?
         $signed(ay)-bitmap_y-32'sd1 : $signed(ay)+bitmap_y;
    wire [9:0] source_y=wrap_y(y_unwrapped,map_h);
    wire [15:0] reg5_word=reg_word(5'd5);
    wire [1:0] scroll_mode=reg5_word[{1'b0,flyr,1'b0} +:2];
    wire signed [31:0] ls_index_full=(map_h!=2'd0) ?
         $signed({22'b0,source_y}) :
         (gflip_y ? 32'sd255-bitmap_y-
             (scroll_mode==2'd2 ? (dy_corr & 32'sd7) : 32'sd0) :
             dy_corr+bitmap_y);
    wire [8:0] ls_index=scroll_mode==2'd2 ?
         {ls_index_full[8:3],3'b0} : ls_index_full[8:0];
    wire [4:0] reg24_word=5'(reg_word(5'd24));
    wire [3:0] scroll_page={reg24_word[4:3],reg24_word[1:0]};
    wire [15:0] ls_address={scroll_page,flyr,ls_index,1'b0};
    wire signed [31:0] dx_effective=line_dx-{{22{offx_val[9]}},offx_val} +
         (gflip_x ? {{19{corr_x[12]}},corr_x} : 32'sd0);
    // MAME uses &width-1, including its three-page non-power-of-two mask.
    wire [31:0] sx=$unsigned(dx_effective) & width_mask(map_w);
    wire signed [31:0] x_first=gflip_x ? $signed(sx)-(monster ? 32'sd25 : 32'sd41) : $signed(sx)+(monster ? 32'sd24 : 32'sd40);
    wire [10:0] base_x=wrap_x(x_first,map_w);
    wire [2:0] first_sub=gflip_x ? ~base_x[2:0] : base_x[2:0];
    wire signed [31:0] tile_x_unwrapped=$signed({21'b0,base_x[10:3],3'b0}) +
         (gflip_x ? -$signed({23'b0,ftile,3'b0}) : $signed({23'b0,ftile,3'b0}));
    wire [10:0] tile_x=wrap_x(tile_x_unwrapped,map_w);
    wire [3:0] origin_page=layer_page(flyr);
    wire [1:0] physical_row=origin_page[3:2]+source_y[9:8];
    wire [1:0] physical_col=origin_page[1:0]+tile_x[10:9];
    wire [3:0] physical_page={physical_row,physical_col};
    wire [2:0] owner=page_owner(physical_page);
    wire association=association_enabled();
    // Gaiapolis leaves MAME linemap disabled; a zero cached tile mode is blank.
    wire page_visible=(!association || owner=={1'b0,flyr}) &&
                      tile_modes[association ? owner[1:0] : flyr];
    wire [11:0] tile_index={source_y[7:3],tile_x[8:3],1'b0};
    wire [15:0] attr_addr={physical_page,tile_index};
    wire [15:0] code_addr=attr_addr | 16'd1;
    function [1:0] attribute_flip(input [7:0] attr);
        reg [1:0] fbits;
        begin
            fbits=2'(reg_word(5'd3)>>6);
            case(fbits)
                2'd0: attribute_flip=attr[7:6];
                2'd1: attribute_flip=attr[5:4];
                2'd2: attribute_flip=attr[3:2];
                default: attribute_flip=attr[1:0];
            endcase
        end
    endfunction
    wire [1:0] tile_flip_local=layer_flip(flyr) & attribute_flip(attr_p[7:0]);
    // Global reversal already selected raw page/tile/row. XOR global X only
    // because the donor writer emits each raw tile in increasing pixel order.
    wire [1:0] tile_flip_p={tile_flip_local[1],tile_flip_local[0] ^ gflip_x};
    wire [2:0] tyf=tile_flip_local[1] ? ~source_y[2:0] : source_y[2:0];
    wire cache_hit=cache_valid_q && !cache_collide_q && cache_ridx_q==code_p[5:0] &&
                   cache_q[52:40]=={code_p[15:6],tyf};
    // Tile t covers outpx 8t-sub..8t-sub+7; the last tile with any pixel
    // below the viewport width is (W-1+sub)/8. Later tiles are never visible.
    wire [5:0] last_tile=monster ? (first_sub==3'd0 ? 6'd35 : 6'd36) :
                                   (first_sub==3'd0 ? 6'd46 : 6'd47);
    wire [22:0] miss_rom_addr=({4'd0,code_p,3'b000} + {20'd0,tyf}) * (monster ? 23'd5 : 23'd4);
    // Completed row from the shared ROM: one aligned word (Gaiapolis), or a
    // Monster 5-byte row assembled across two words in R_WAIT2.
    wire fetch_done = r_st==R_WAIT2 || (!monster && rom_addr[1:0]==2'd0);
    reg [31:0] fetch_word;
    always @* begin
        if(r_st!=R_WAIT2) fetch_word=tile_data;
        else case (rom_addr[1:0])
            2'd1: fetch_word={tile_data[7:0],romdata_p[31:8]};
            2'd2: fetch_word={tile_data[15:0],romdata_p[31:16]};
            2'd3: fetch_word={tile_data[23:0],romdata_p[31:24]};
            default: fetch_word=romdata_p;
        endcase
    end
    wire [7:0] fetch_plane = r_st==R_WAIT2 ? tile_data[{rom_addr[1:0],3'b0} +:8] : 8'd0;

    wire flipx_c = flip_c[0];
    // Exact SHIFTMASKS normalization then Gaiapolis color>>2&15 callback.
    function [3:0] palette_nibble(input [15:0] attr);
        reg [15:0] r;
        reg [5:0] color;
        reg unused_callback_bits;
        begin
            r=reg_word(5'd3);
            case(r[7:6])
                2'd0: color=attr[5:0];
                2'd1: color={attr[7:6],attr[3:0]};
                2'd2: color={attr[7:4],attr[1:0]};
                default: color=attr[7:2];
            endcase
            palette_nibble=color[5:2];
            unused_callback_bits=&{1'b0,attr[15:8],attr[1:0],r[15:8],r[5:0],color[1:0]};
        end
    endfunction
    wire [3:0] colnib_c = palette_nibble(attr_c);
    wire [2:0] pxf = flipx_c ? ~fpx8 : fpx8;
    // Raw tiles are packed nibbles plus a fifth plane. MAME decode_tiles()
    // converts the first four bytes before its charlayout5 decode.
    function [4:0] tilepen(input [2:0] tx, input [31:0] d, input [7:0] fifth);
        reg [7:0] s0,s1,s2,s3;
        reg [1:0] byte_sel;
        reg [7:0] b;
        begin
            s0 = d[7:0];
            s1 = d[15:8];
            s2 = d[23:16];
            s3 = d[31:24];
            // Raw MAME region already applies ROM_LOADTILE_WORD word reversal.
            // decode_tiles()+charlayout5 yields each raw byte's high/low nibble.
            byte_sel = tx[2:1];
            case (byte_sel)
                2'd0: b = s0;
                2'd1: b = s1;
                2'd2: b = s2;
                default: b = s3;
            endcase
            tilepen = {monster && fifth[3'd7-tx],tx[0] ? b[3:0] : b[7:4]};
        end
    endfunction
    // Retain the donor's 5-bit pen interface for priority/transparency.
    wire [4:0] pen5 = tilepen(pxf,romdata_c,plane_c);
    wire signed [11:0] outpx_s = $signed({3'b0,wtile,3'b0}) -
                                  $signed({9'b0,subc}) +
                                  $signed({9'b0,fpx8});
    wire [8:0] outpx = outpx_s[8:0];
    wire outpx_ok = (outpx_s >= 0) && (outpx_s < (monster ? 288 : 376));

    // k056832_device::get_tile_info() indexes the flat decoded gfx array
    // directly by `code` with no runtime bank offset (create_gfx() decodes
    // the whole ROM region once at device_start()); rom_bank/REG1A-1B only
    // steers the CPU ROM-checksum readback window (mw_rom_word_r in
    // gaiapolis_k056832.sv), so it must not appear in this render address.
    // Five raw bytes per row: fetch four loaded bytes across aligned words.
    // The fifth plane is zero in Gaiapolis; no decoded duplicate is stored.
    // gaiapolis_rom_arb holds a completed response while CS stays high and
    // only latches a new address after a CS gap. R_REQ2 drops CS for that gap;
    // otherwise the second read of a 5-byte row returned the first word again
    // (wrong fifth plane and unaligned pixel bytes).
    assign tile_cs = (r_st == R_REQ) || (r_st == R_WAIT) || (r_st == R_WAIT2);
    assign tile_addr = rom_addr[22:2] +
                       ((r_st == R_REQ2 || r_st == R_WAIT2) ? 21'd1 : 21'd0);

    always @(posedge clk or posedge rst) begin : render_fsm
        integer ci;
        if (rst) begin
            pf_st <= P_IDLE;
            r_st <= R_IDLE;
            r_busy <= 1'b0;
            r_discard <= 1'b0;
            cs_st <= C_IDLE;
            flyr <= 2'd0;
            ftile <= 6'd0;
            fline <= 12'sd0;
            line_dx <= 32'sd0;
            ls_high <= 16'd0;
            cwe_p <= 1'b0;
            xfer_w <= 1'b0;
            cw_idx_p <= 6'd0;
            cw_tag_p <= 13'd0;
            cw_data_p <= 40'd0;
            attr_p <= 16'd0;
            plane_p<=0;h_plane<=0;plane_c<=0;
            code_p <= 16'd0;
            romdata_p <= 32'd0;
            rom_addr <= 23'd0;
            fpx8 <= 3'd0;
            wlyr <= 2'd0;
            wtile <= 6'd0;
            attr_c <= 16'd0;
            romdata_c <= 32'd0;
            flip_c <= 2'd0;
            subc <= 3'd0;
            hs_valid <= 1'b0;
            h_attr <= 16'd0;
            h_rom <= 32'd0;
            h_tile <= 6'd0;
            h_lyr <= 2'd0;
            h_sub <= 3'd0;
            h_flip <= 2'd0;
            prev_lhbl <= 1'b0;
            dispbank <= 1'b0;
            fbank <= 1'b1;
            vram_addr <= 16'd0;
            for (ci=0; ci<4; ci=ci+1) begin
                fill_cov[ci] <= 9'd0;
                disp_cov[ci] <= 9'd0;
            end
        end else begin
            prev_lhbl <= lhbl;
            cwe_p <= 1'b0;
            if (prev_lhbl && !lhbl) begin
                dispbank <= fbank;
                fbank <= ~fbank;
                flyr <= 2'd0;
                ftile <= 6'd0;
                fpx8 <= 3'd0;
                // CCU vpos still names the line just displayed at LHBL falling.
                fline <= $signed({3'b0,vpos}) +
                         12'((monster ? 17 : BITMAP_TOP)-(monster ? 272 : VACTIVE_FIRST)+PREFETCH_LINES);
                xfer_w <= 1'b0;
                pf_st <= len[0] ? P_LAYER : P_XFER;
                // A line deadline does not cancel a shared-ROM transaction.
                // Keep its address/CS until ACK, then discard the old row.
                r_st <= tile_cs && !tile_ok ? r_st : R_IDLE;
                r_busy <= tile_cs && !tile_ok;
                r_discard <= tile_cs && !tile_ok;
                cs_st <= C_IDLE;
                hs_valid <= 1'b0;
                for (ci=0; ci<4; ci=ci+1) begin
                    disp_cov[ci] <= fill_cov[ci];
                    fill_cov[ci] <= 9'd0;
                end
            end else begin
            if (cs_st == C_WRITE && outpx_ok && (outpx + 9'd1) > fill_cov[wlyr])
                fill_cov[wlyr] <= outpx + 9'd1;

            // V stage: VRAM attribute/code read of the next tile
            case (pf_st)
                P_IDLE: begin end
                P_LAYER: begin
                    line_dx<={{16{dx_val[15]}},dx_val};
                    if(scroll_mode==2'd0 || scroll_mode==2'd2) begin
                        vram_addr<=ls_address; pf_st<=P_LSHI;
                    end else pf_st<=P_SETUP;
                end
                P_LSHI: pf_st<=P_LSHI2;
                P_LSHI2: begin
                    ls_high<=vram_dout; vram_addr<=ls_address | 16'd1; pf_st<=P_LSLO;
                end
                P_LSLO: pf_st<=P_LSLO2;
                P_LSLO2: begin line_dx<=$signed({ls_high,vram_dout}); pf_st<=P_SETUP; end
                P_SETUP: begin
                    if(page_visible) begin vram_addr<=attr_addr; pf_st<=P_ATTR; end
                    else begin attr_p<=16'd0; code_p<=16'd0; pf_st<=P_XFER; end
                end
                P_ATTR: pf_st <= P_ATTR2;
                P_ATTR2: begin
                    attr_p <= vram_dout;
                    vram_addr <= code_addr;
                    pf_st <= P_CODE;
                end
                P_CODE: pf_st <= P_CODE2;
                P_CODE2: begin
                    code_p <= vram_dout;
                    xfer_w <= 1'b1;
                    pf_st <= P_XFER;
                end
                P_XFER: if (xfer_w) xfer_w <= 1'b0;
                else if (!len[flyr] || !r_busy) begin
                    if (len[flyr]) begin
                        r_attr <= attr_p;
                        r_code <= code_p;
                        r_flip <= tile_flip_p;
                        r_sub  <= first_sub;
                        r_tile <= ftile;
                        r_lyr  <= flyr;
                        r_tyf  <= tyf;
                        r_busy <= 1'b1;
                        if(!page_visible) begin
                            romdata_p<=32'd0; plane_p<=8'd0; r_st<=R_DEP;
                        end else if(cache_hit) begin
                            romdata_p<=cache_q[31:0]; plane_p<=cache_q[39:32]; r_st<=R_DEP;
                        end else begin
                            // Monster Maulers rows are 5 bytes (fifth plane);
                            // Gaiapolis rows are packed 4 bytes: one aligned word.
                            rom_addr <= miss_rom_addr;
                            r_st <= R_REQ;
                        end
                    end
                    if (!len[flyr] || ftile == last_tile) begin
                        ftile <= 6'd0;
                        if (flyr == 2'd3)
                            pf_st <= P_IDLE;
                        else begin
                            flyr <= flyr + 2'd1;
                            pf_st <= len[flyr + 2'd1] ? P_LAYER : P_XFER;
                        end
                    end else begin
                        ftile <= ftile + 6'd1;
                        pf_st <= P_SETUP;
                    end
                end
                default: pf_st <= P_IDLE;
            endcase

            // R stage: tile ROM row fetch and hand-off to the pixel writer
            if(r_discard) begin
                if(tile_ok) begin
                    r_st <= R_IDLE;
                    r_busy <= 1'b0;
                    r_discard <= 1'b0;
                end
            end else case (r_st)
                R_IDLE: begin end
                R_REQ: r_st <= R_WAIT;
                R_WAIT: if (tile_ok) begin
                    if(fetch_done) begin
                        cwe_p <= 1'b1; cw_idx_p <= r_code[5:0];
                        cw_tag_p <= {r_code[15:6],r_tyf}; cw_data_p <= {fetch_plane,fetch_word};
                        if(!hs_valid) begin
                            h_attr <= r_attr; h_rom <= fetch_word; h_plane <= fetch_plane;
                            h_tile <= r_tile; h_lyr <= r_lyr; h_sub <= r_sub; h_flip <= r_flip;
                            hs_valid <= 1'b1; r_busy <= 1'b0; r_st <= R_IDLE;
                        end else begin
                            romdata_p <= fetch_word; plane_p <= fetch_plane; r_st <= R_DEP;
                        end
                    end else begin
                        romdata_p <= tile_data;
                        r_st <= R_REQ2;
                    end
                end
                R_REQ2: r_st <= R_WAIT2;
                R_WAIT2: if (tile_ok) begin
                    cwe_p <= 1'b1; cw_idx_p <= r_code[5:0];
                    cw_tag_p <= {r_code[15:6],r_tyf}; cw_data_p <= {fetch_plane,fetch_word};
                    if(!hs_valid) begin
                        h_attr <= r_attr; h_rom <= fetch_word; h_plane <= fetch_plane;
                        h_tile <= r_tile; h_lyr <= r_lyr; h_sub <= r_sub; h_flip <= r_flip;
                        hs_valid <= 1'b1; r_busy <= 1'b0; r_st <= R_IDLE;
                    end else begin
                        romdata_p <= fetch_word; plane_p <= fetch_plane; r_st <= R_DEP;
                    end
                end
                R_DEP: if (!hs_valid) begin
                    h_attr <= r_attr;
                    h_rom <= romdata_p;
                    h_plane <= plane_p;
                    h_tile <= r_tile;
                    h_lyr <= r_lyr;
                    h_sub <= r_sub;
                    h_flip <= r_flip;
                    hs_valid <= 1'b1;
                    r_busy <= 1'b0;
                    r_st <= R_IDLE;
                end
                default: r_st <= R_IDLE;
            endcase

            case (cs_st)
                C_IDLE: if (hs_valid) begin
                    attr_c <= h_attr;
                    romdata_c <= h_rom;
                    plane_c <= h_plane;
                    flip_c <= h_flip;
                    wtile <= h_tile;
                    wlyr <= h_lyr;
                    subc <= h_sub;
                    fpx8 <= 3'd0;
                    hs_valid <= 1'b0;
                    cs_st <= C_WRITE;
                end
                // Back-to-back: the last pixel clock loads the next tile.
                C_WRITE: if (fpx8 == 3'd7) begin
                    if (hs_valid) begin
                        attr_c <= h_attr;
                        romdata_c <= h_rom;
                        plane_c <= h_plane;
                        flip_c <= h_flip;
                        wtile <= h_tile;
                        wlyr <= h_lyr;
                        subc <= h_sub;
                        fpx8 <= 3'd0;
                        hs_valid <= 1'b0;
                    end else
                        cs_st <= C_IDLE;
                end else
                    fpx8 <= fpx8 + 3'd1;
                default: cs_st <= C_IDLE;
            endcase
            end
        end
    end

    wire [9:0] lb_wa = {fbank,outpx};
    // game4bpp_tile_callback leaves priority/mix zero; attr[1:0] is not a mix code.
    wire [10:0] lb_wd = {2'b00,colnib_c,pen5};
    wire lb_we = (cs_st == C_WRITE) && outpx_ok;
    // Visible pixel column: counts CCU pixel enables while LHBL is high, so it
    // does not depend on the counter value the CCU happens to start blanking at.
    reg [8:0] vis_x;
    always @(posedge clk)
        if (pxl_cen) vis_x <= lhbl ? vis_x + 9'd1 : 9'd0;
    wire [8:0] dpx = vis_x;
    wire [9:0] rdaddr = {dispbank,dpx};
    wire [10:0] lb0_q, lb1_q, lb2_q, lb3_q;

    jtframe_rpwp_ram #(.DW(11),.AW(10)) u_lbuf0(
        .clk(clk), .rd_addr(rdaddr), .dout(lb0_q), .wr_addr(lb_wa),
        .din(lb_wd), .we(lb_we && wlyr==2'd0));
    jtframe_rpwp_ram #(.DW(11),.AW(10)) u_lbuf1(
        .clk(clk), .rd_addr(rdaddr), .dout(lb1_q), .wr_addr(lb_wa),
        .din(lb_wd), .we(lb_we && wlyr==2'd1));
    jtframe_rpwp_ram #(.DW(11),.AW(10)) u_lbuf2(
        .clk(clk), .rd_addr(rdaddr), .dout(lb2_q), .wr_addr(lb_wa),
        .din(lb_wd), .we(lb_we && wlyr==2'd2));
    jtframe_rpwp_ram #(.DW(11),.AW(10)) u_lbuf3(
        .clk(clk), .rd_addr(rdaddr), .dout(lb3_q), .wr_addr(lb_wa),
        .din(lb_wd), .we(lb_we && wlyr==2'd3));

    reg [3:0] cov_ok;
    always @(posedge clk) begin
        cov_ok[0] <= dpx < disp_cov[0];
        cov_ok[1] <= dpx < disp_cov[1];
        cov_ok[2] <= dpx < disp_cov[2];
        cov_ok[3] <= dpx < disp_cov[3];
    end

    wire visible = lhbl && lvbl;
    assign lyrf_pxl = (visible && gfx_en[0] && cov_ok[0]) ? lb0_q[8:0] : 9'd0;
    assign lyra_pxl = (visible && gfx_en[1] && cov_ok[1]) ? lb1_q[8:0] : 9'd0;
    assign lyrb_pxl = (visible && gfx_en[2] && cov_ok[2]) ? lb2_q[8:0] : 9'd0;
    assign lyrc_pxl = (visible && gfx_en[3] && cov_ok[3]) ? lb3_q[8:0] : 9'd0;
    assign lyrf_mix = (visible && gfx_en[0] && cov_ok[0]) ? lb0_q[10:9] : 2'b00;
    assign lyra_mix = (visible && gfx_en[1] && cov_ok[1]) ? lb1_q[10:9] : 2'b00;
    assign lyrb_mix = (visible && gfx_en[2] && cov_ok[2]) ? lb2_q[10:9] : 2'b00;
    assign lyrc_mix = (visible && gfx_en[3] && cov_ok[3]) ? lb3_q[10:9] : 2'b00;

    // Kept for donor port compatibility; coordinate high bits are modulo wrap.
    wire unused_compat = &{1'b0,hpos,hs,vs,rom_bank,config_regs,ls_index_full[31:9],tile_x[2:0],reg24_word[2],flip_c[1],fetch_busy};
endmodule
