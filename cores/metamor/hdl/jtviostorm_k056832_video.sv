/*
 * Violent Storm K056832 tile-layer renderer.
 *
 * The line producer/consumer structure is adapted from the GPL-3.0-or-later
 * GX173/Moo Mesa implementation `meathax/Bucky` commit
 * c7a9b82cac107d8dfea602e991c261923b9cd440 (source file listed in
 * .mister/source-lock.json). The private CPU/register/VRAM store from that
 * donor is intentionally not imported: this wrapper consumes the shared
 * JTFRAME dual-port VRAM and 32-bit tile-ROM ports.
 *
 * Hardware facts and remaining hypotheses are recorded in the evidence ledger.
 * Viostorm's K056832 is configured 5bpp (K056832_BPP_5, mystwarr.cpp) but only
 * planes 0-3 are populated in the tile ROM, so a tile row is one 32-bit word.
 */
module jtviostorm_k056832_video(
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
    input       [1:0] x0,x1,x2,x3, y0,y1,y2,y3, w0,w1,w2,w3, h0,h1,h2,h3,
    // Full 16-bit signed scroll registers -- see Fix 4, jtviostorm_k056832.sv.
    input signed [15:0] dx0, dx1, dx2, dx3,
    input signed [15:0] dy0, dy1, dy2, dy3,
    input       [1:0] flip0, flip1, flip2, flip3,
    // Global screen flip -- REG0 bits 5/4 -- and its associated correction
    // registers (0x3c/0x3a). Applies uniformly to all four layers (MAME
    // calls tilemap[i]->set_flip() in a loop over every K056832 tilemap,
    // k054156_k054157_k056832.cpp word_w() case 0x00/2), independently of
    // the per-layer REG1 override carried by flip0..3 above. See derivation
    // in the xbase_s/y_s comments below and the evidence ledger entry dated
    // 2026-08-18 (K056832 global screen flip).
    input             gflip_x, gflip_y,
    input       signed [12:0] corr_x,
    input       signed [11:0] corr_y,
    input       [8:0] rom_bank,

    // Shared K056832 physical VRAM port (17-bit word address).
    output reg [17:1] vram_addr,
    input      [15:0] vram_dout,

    // Shared 32-bit packed tile-ROM port.
    output            tile_cs,
    output     [21:2] tile_addr,
    input      [31:0] tile_data,
    input             tile_ok,

    // 9 bits: [8:5]=colnib (4-bit K055555 palette-nibble field), [4:0]=raw
    // 5bpp tile pen (0-31). Concatenation, not a sum -- the arithmetic
    // colnib*16+pen composition (matching K056832's forced granularity(16)
    // override, create_gfx(), k054156_k054157_k056832.cpp:358) is done in
    // jtviostorm_priority.sv, which also needs the raw pen bits intact for
    // its own transparency test. See Fix 1 in the evidence ledger.
    output     [8:0]  lyrf_pxl,
    output     [8:0]  lyra_pxl,
    output     [8:0]  lyrb_pxl,
    output     [8:0]  lyrc_pxl,
    output     [1:0]  lyrf_mix,
    output     [1:0]  lyra_mix,
    output     [1:0]  lyrb_mix,
    output     [1:0]  lyrc_mix
);

    // Metamorphic Force's VIDEO_START offsets are {+2,+4,+6,+7}; this is
    // taken directly from MAME mystwarr_v.cpp.
    function signed [9:0] layer_offx(input [1:0] layer);
        case (layer)
            // Metamorphic Force VIDEO_START offsets from MAME: +2,+4,+6,+7.
            2'd0: layer_offx =  10'sd2;
            2'd1: layer_offx =  10'sd4;
            2'd2: layer_offx =  10'sd6;
            default: layer_offx = 10'sd7;
        endcase
    endfunction

    function [3:0] layer_page(input [1:0] layer);
        case (layer)
            2'd0: layer_page = page0;
            2'd1: layer_page = page1;
            2'd2: layer_page = page2;
            default: layer_page = page3;
        endcase
    endfunction

    function [1:0] layer_x(input [1:0] layer); case(layer) 2'd0:layer_x=x0;2'd1:layer_x=x1;2'd2:layer_x=x2;default:layer_x=x3;endcase endfunction
    function [1:0] layer_y(input [1:0] layer); case(layer) 2'd0:layer_y=y0;2'd1:layer_y=y1;2'd2:layer_y=y2;default:layer_y=y3;endcase endfunction
    function [1:0] layer_w(input [1:0] layer); case(layer) 2'd0:layer_w=w0;2'd1:layer_w=w1;2'd2:layer_w=w2;default:layer_w=w3;endcase endfunction
    function [1:0] layer_h(input [1:0] layer); case(layer) 2'd0:layer_h=h0;2'd1:layer_h=h1;2'd2:layer_h=h2;default:layer_h=h3;endcase endfunction

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
               P_CODE=4'd4, P_CODE2=4'd5, P_XFER=4'd6;
    localparam R_IDLE=3'd0, R_ADDR=3'd1, R_REQ=3'd2, R_WAIT=3'd3, R_DEP=3'd4;
    localparam C_IDLE=1'b0, C_WRITE=1'b1;

    reg [3:0] pf_st;
    reg       cs_st;
    reg [1:0] flyr;
    reg [5:0] ftile;
    reg [8:0] fline;
    reg [15:0] attr_p, code_p;
    reg [31:0] romdata_p;
    reg [18:0] rom_addr;
    reg [2:0]  r_st;
    reg        r_busy;
    reg [15:0] r_attr, r_code;
    reg [1:0]  r_flip, r_lyr;
    reg [2:0]  r_sub, r_tyf;
    reg [5:0]  r_tile;
`ifdef VS_ALLLAYERS
    wire [3:0] len = 4'hf;   // worst-case timing test: fetch all four layers
`else
    wire [3:0] len = layer_en;
`endif
    reg        hs_valid;
    wire       fetch_busy = (pf_st != P_IDLE) || r_busy || hs_valid;
    reg [2:0]  fpx8;
    reg [1:0]  wlyr;
    reg [5:0]  wtile;
    reg [15:0] attr_c;
    reg [31:0] romdata_c;
    reg [1:0]  flip_c;
    reg [2:0]  subc;
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

    wire signed [15:0] dx_val = layer_dx(flyr);
    wire signed [15:0] dy_val = layer_dy(flyr);
    wire signed [9:0]  offx_val = layer_offx(flyr);
    // Widened to hold the full 16-bit signed register value; base_x/y_tm
    // below still truncate to the per-page pixel window (9/8 bits), which is
    // the correct 2's-complement modulo wrap of the *unclipped* scroll value
    // -- unlike the previous 10-bit register slice, which corrupted the sign
    // of any register value outside +-511 before this arithmetic ever ran.
    //
    // Global-flip world-address derivation -- CORRECTED 2026-08-18 (evidence
    // ledger entry "K056832 global-flip: empirical rendered-frame
    // measurement refutes source-only derivation"). The prior source-only
    // algebraic derivation (both the original and its "confirmation" pass)
    // assumed the flipped branch has the SAME sign/slope as the unflipped
    // branch (world increasing with screen_x), differing only by an
    // additive constant. A live MAME pixel-exact measurement (viostorm
    // service-mode "RAM ROM CHECK" screen, K056832-only static text,
    // REG0 bits4/5 poked live while paused, corr_x/corr_y independently
    // poked to known values, screen:pixel() cross-correlated against the
    // unflipped baseline at 1px resolution) proves the real transform
    // MIRRORS the screen (world DECREASES as screen_x/y increases), not
    // merely a shifted-but-same-direction window. Measured, exact
    // (100% pixel match, full 384x224 active area, at every tested
    // corr_x/corr_y value 0/32/64):
    //   world_x_flip(x_f) = 424 - x_f + corr_x + dx_val - offx_val
    //   world_y_flip(y_f) = 223 - y_f + corr_y + dy_val
    // (x_f/y_f = 0-based active screen column/row, i.e. RTL's outpx/fline).
    // These reduce, at x_f=0/y_f=0, to the anchors below; the "424"/"223"
    // replace the previous (wrong-slope) "88"/"0" constants, and dx_val/
    // offx_val/corr_x now carry the SAME sign as the unflipped branch
    // (dx_val added, offx_val subtracted, corr_x added) -- the previous
    // branch had all three signs backwards in addition to the wrong slope.
    //
    // The X mirror additionally requires reversing the per-scanline tile
    // FETCH order: unlike Y (whose world row address is recomputed by pure
    // formula every scanline), X fills the line buffer via an incremental
    // fetch loop (`ftile` 0..47) that must count DOWN through VRAM columns
    // under flip, not up, for the decreasing world-x slope to hold across
    // tile boundaries (verified algebraically: a per-tile-only mirror
    // without reversing `cur_col` produces a sawtooth, not a continuous
    // mirror). The intra-tile pixel-phase register (`first_sub`) must also
    // become the 3-bit complement of the standard low bits under flip, so
    // that the existing subc/fpx8 skip-count pipeline (unchanged) still
    // emits exactly the pixels in [0,384) once cur_col's direction flips
    // (derived by requiring first_col*8+7-first_sub == world_x_flip(0) mod
    // 512, which resolves to first_sub = ~base_x[2:0] for any base_x).
    wire signed [17:0] xbase_s = gflip_x ?
        (18'sd312 + {{2{dx_val[15]}},dx_val} - {{8{offx_val[9]}},offx_val} +
                     {{5{corr_x[12]}},corr_x}) :
        (18'sd24 + {{2{dx_val[15]}},dx_val} -
                    {{8{offx_val[9]}},offx_val});
    wire [8:0] base_x = xbase_s[8:0];
    wire [2:0] first_sub = gflip_x ? ~base_x[2:0] : base_x[2:0];
    wire [5:0] first_col = base_x[8:3];
    wire [5:0] cur_col = gflip_x ? (first_col - ftile) : (first_col + ftile);
    // K056832 layers are rectangles of 512x256 pages. Page selection must
    // use the unwrapped scroll coordinate; base_x alone has already discarded
    // every bit above the 512-pixel page width.
    // Global X flip reverses the tile walk. Page selection must follow the
    // same direction as cur_col; otherwise crossing column 0/63 fetches the
    // correct local column from the wrong 512-pixel VRAM page.
    wire signed [18:0] tile_x_abs = gflip_x ?
        ((xbase_s >>> 3) - $signed({13'd0,ftile})) :
        ((xbase_s >>> 3) + $signed({13'd0,ftile}));
    // Scroll wraps within the layer's configured page rectangle, not the
    // complete 4x4 VRAM grid. A one-page layer must keep its selected page
    // even when a signed scroll/flip coordinate crosses zero.
    `include "hdl/jtmetamrph_page_wrap.vh"
    wire [1:0] page_col_rel = wrap_page(tile_x_abs >>> 6, layer_w(flyr));
    // K053252 vpos is the raw 9-bit counter, not a 0-based visible-line
    // coordinate. MAME 0.289 uses visible scanlines 16..239 (yextent=256).
    // The line producer runs during the preceding horizontal blank; its
    // origin must include that pipeline boundary rather than treating raw
    // vpos as the first pixel of the line being displayed. Native POST
    // replay validates the flipped origin below without image alignment.
    // Global flip reverses the full source coordinate; attribute row flip
    // is applied once at the ROM fetch below.
    wire signed [17:0] y_s = gflip_y ?
        (18'sd253 - $signed({9'b0,fline}) +
         {{2{dy_val[15]}},dy_val} + {{6{corr_y[11]}},corr_y}) :
        ($signed({9'b0,fline}) + {{2{dy_val[15]}},dy_val});
    wire [7:0] y_tm = y_s[7:0];
    wire [4:0] frow = y_tm[7:3];
    wire [2:0] fty = y_tm[2:0];
    // MAME clips globally Y-flipped pages at the 256-line page boundary,
    // independently of tilemap.cpp's visible-area mirror origin (254).
    // The CCU's displayed 15..238 coordinates arrive here as 271..494;
    // fline[7:0] is the page-clipping screen coordinate.  Keep y_s for the
    // pixel row, but select the page from (adjusted_scroll-1-screen_y).
    // This selects the preceding page across a flip boundary rather than
    // fetching the current page's final two rows. See graphics/CAUSAL_NOTES.
    wire signed [17:0] flip_scroll_y = {{2{dy_val[15]}},dy_val} +
                                      {{6{corr_y[11]}},corr_y};
    wire signed [18:0] flip_clip_y = {flip_scroll_y[17],flip_scroll_y} -
                                    19'sd1 - $signed({11'd0,fline[7:0]});
    // MAME casts adjusted DY to unsigned before reducing modulo height.
    // 2^32 modulo a three-page height is256; heights1/2/4 divide2^32.
    wire signed [18:0] flip_page_y = (flip_clip_y >>> 8) +
        ((layer_h(flyr)==2'd2 && flip_scroll_y[17]) ? 19'sd1 : 19'sd0);
    wire [1:0] page_row_rel = gflip_y ? wrap_page(flip_page_y,layer_h(flyr)) :
                                         wrap_page({y_s[17],y_s} >>> 8,layer_h(flyr));
    wire [1:0] page_x = (layer_x(flyr) + page_col_rel) & 2'b11;
    wire [1:0] page_y = (layer_y(flyr) + page_row_rel) & 2'b11;
    wire [3:0] grid_page = {page_y,page_x};
    wire [11:0] tile_index = {frow,cur_col,1'b0};
    wire [16:0] attr_addr = {1'b0,grid_page,tile_index};
    wire [16:0] code_addr = attr_addr | 17'd1;
    wire [1:0] flip_val = layer_flip(flyr);
    // Viostorm's K056832 is 5bpp for pixel data (K056832_BPP_5) but the
    // attribute-word shift/mask table is selected by REG3's fbits field
    // (MAME fbits=2 here regardless of pixel bpp): attr[3:2] carries the
    // tile's Y/X flip bits and REG1 supplies the per-layer override mask.
    // The effective flip must be resolved before fetching the row; using
    // attr[0] here would instead consume the mix-code field.
    wire [1:0] tile_flip_local = flip_val & attr_p[3:2];
    // Global flip composes with the per-layer/attr flip by XOR, matching
    // tilemap.cpp tile_update(): "flags = m_tileinfo.flags ^ (m_attributes
    // & 0x03)" -- m_tileinfo.flags there is exactly tile_flip_local (set
    // from k056832's own get_tile_info() TILE_FLIPYX(flip), which reads
    // REG1 & attr[3:2], k054156_k054157_k056832.cpp:618-628); m_attributes'
    // low two bits are the TILEMAP_FLIPY/FLIPX bits driven by REG0[5:4]. No
    // VRAM tile-selection reorder is involved -- tilemap.cpp's m_mapper
    // (logical column/row -> VRAM index) is fixed at tilemap creation and
    // is untouched by set_flip(); only this per-tile pixel/row mirror and
    // the xbase_s/y_s scroll-origin change above are affected.
    wire [1:0] tile_flip_p = tile_flip_local ^ {gflip_y, gflip_x};
    // y_s already reverses the complete source coordinate under global
    // flip, including its three row bits. Apply only the attribute flip
    // here; applying global flip again reverses glyph rows twice.
    wire [2:0] tyf = tile_flip_local[1] ? ~fty : fty;

    wire flipx_c = flip_c[0];
    // k056832_device::get_tile_info() forms the six-bit fbits=2 colour field
    // as (attr&0x03)|((attr>>2)&0x3c); viostorm_tile_callback then selects
    // color>>2 & 0xf as the four-bit palette nibble.  Working through the
    // algebra that final nibble is attr[7:4] (not attr[5:2], which reuses
    // the flip-override bits at attr[3:2] and drops attr[7:6] entirely).
    // attr[1:0] remains the independent two-bit tile-mix code.
    wire [3:0] colnib_c = attr_c[7:4];
    wire [2:0] pxf = flipx_c ? ~fpx8 : fpx8;
    // Viostorm populates only the 4bpp planes of the 5bpp tile ROM region
    // (168a09/168a08 via ROM_LOADTILE_WORD, plane 4 erased): each tile row is
    // one 32-bit word, four "chunky" bytes s0..s3 holding bit-planes 0-3
    // nibble-interleaved in the GX173 byte_sel order. Plane 4 reads as zero.
    // MAME K056832_BPP_5 charlayout5 plane offsets are {32,24,8,16,0}.
    // Metamorphic's fifth byte/plane (offset 32) is ERASE00, while our private
    // SDRAM stream stores logical bytes 0..3. Decode the remaining four
    // planes bit-by-bit exactly like MAME instead of using Viostorm's old
    // chunky-nibble permutation.
    function [4:0] tilepen(input [2:0] tx, input [31:0] d);
        reg [7:0] s0,s1,s2,s3;
        reg [7:0] d0,d1,d2,d3;
        reg [2:0] sh;
        begin
            // mystwarr_v.cpp::decode_tiles() first converts the raw pre-GX
            // four chunky bytes into GX planar order.  CPU ROM readback must
            // still see the raw bytes, so perform this only in the renderer.
            s0 = d[7:0]; s1 = d[15:8]; s2 = d[23:16]; s3 = d[31:24];
            d0 = {s0[7],s0[3],s1[7],s1[3],s2[7],s2[3],s3[7],s3[3]};
            d1 = {s0[6],s0[2],s1[6],s1[2],s2[6],s2[2],s3[6],s3[2]};
            d2 = {s0[5],s0[1],s1[5],s1[1],s2[5],s2[1],s3[5],s3[1]};
            d3 = {s0[4],s0[0],s1[4],s1[0],s2[4],s2[0],s3[4],s3[0]};
            sh = 3'd7 - tx;
            // MAME writes transformed bytes as {d3,d1,d2,d0,p5}; charlayout5
            // plane offsets {32,24,8,16,0}.  p5 is ERASE00 for this set.
            // gfx_element::decode gives the first layout plane the MSB.
            // Offsets {32,24,8,16,0} therefore select {p5,d0,d1,d2,d3}.
            tilepen = { 1'b0, d0[sh], d1[sh], d2[sh], d3[sh] };
        end
    endfunction
    // pen5 is the full 5-bit raw tile pen (all 32 palette entries per tile
    // color group are now reachable -- Fix 1). It is carried whole through
    // lb_wd/lb_q/lyrf_pxl into jtviostorm_priority.sv, which performs the
    // colnib*16+pen composition against the K055555 layer palette base.
    wire [4:0] pen5 = tilepen(pxf,romdata_c);
    wire signed [11:0] outpx_s = $signed({3'b0,wtile,3'b0}) -
                                  $signed({9'b0,subc}) +
                                  $signed({9'b0,fpx8});
    wire [8:0] outpx = outpx_s[8:0];
    wire outpx_ok = (outpx_s >= 0) && (outpx_s < 288);

    // k056832_device::get_tile_info() indexes the flat decoded gfx array
    // directly by `code` with no runtime bank offset (create_gfx() decodes
    // the whole ROM region once at device_start()); rom_bank/REG1A-1B only
    // steers the CPU ROM-checksum readback window (mw_rom_word_r in
    // jtviostorm_k056832.sv), so it must not appear in this render address.
    // One 32-bit ROM word per tile row: the row index is the word address.
    assign tile_cs = (r_st == R_REQ) || (r_st == R_WAIT);
    assign tile_addr = {1'b0, rom_addr};

    always @(posedge clk or posedge rst) begin : render_fsm
        integer ci;
        if (rst) begin
            pf_st <= P_IDLE;
            r_st <= R_IDLE;
            r_busy <= 1'b0;
            cs_st <= C_IDLE;
            flyr <= 2'd0;
            ftile <= 6'd0;
            fline <= 9'd0;
            attr_p <= 16'd0;
            code_p <= 16'd0;
            romdata_p <= 32'd0;
            rom_addr <= 19'd0;
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
            vram_addr <= 17'd0;
            for (ci=0; ci<4; ci=ci+1) begin
                fill_cov[ci] <= 9'd0;
                disp_cov[ci] <= 9'd0;
            end
        end else begin
            prev_lhbl <= lhbl;
            if (prev_lhbl && !lhbl) begin
                dispbank <= fbank;
                fbank <= ~fbank;
                flyr <= 2'd0;
                ftile <= 6'd0;
                fpx8 <= 3'd0;
                fline <= vpos;
                pf_st <= len[0] ? P_SETUP : P_XFER;
                r_st <= R_IDLE;
                r_busy <= 1'b0;
                cs_st <= C_IDLE;
                hs_valid <= 1'b0;
                for (ci=0; ci<4; ci=ci+1) begin
                    disp_cov[ci] <= fill_cov[ci];
                    fill_cov[ci] <= 9'd0;
                end
            end

            if (cs_st == C_WRITE && outpx_ok && (outpx + 9'd1) > fill_cov[wlyr])
                fill_cov[wlyr] <= outpx + 9'd1;

            // V stage: VRAM attribute/code read of the next tile
            case (pf_st)
                P_IDLE: begin end
                P_SETUP: begin
                    vram_addr <= attr_addr;
                    pf_st <= P_ATTR;
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
                    pf_st <= P_XFER;
                end
                P_XFER: if (!len[flyr] || !r_busy) begin
                    if (len[flyr]) begin
                        r_attr <= attr_p;
                        r_code <= code_p;
                        r_flip <= tile_flip_p;
                        r_sub  <= first_sub;
                        r_tile <= ftile;
                        r_lyr  <= flyr;
                        r_tyf  <= tyf;
                        r_busy <= 1'b1;
                        r_st   <= R_ADDR;
                    end
                if (!len[flyr] || ftile == 6'd48) begin
                        ftile <= 6'd0;
                        if (flyr == 2'd3)
                            pf_st <= P_IDLE;
                        else begin
                            flyr <= flyr + 2'd1;
                            pf_st <= len[flyr + 2'd1] ? P_SETUP : P_XFER;
                        end
                    end else begin
                        ftile <= ftile + 6'd1;
                        pf_st <= P_SETUP;
                    end
                end
                default: pf_st <= P_IDLE;
            endcase

            // R stage: tile ROM row fetch and hand-off to the pixel writer
            case (r_st)
                R_IDLE: begin end
                R_ADDR: begin
                    rom_addr <= {r_code,3'b000} + {16'd0,r_tyf};
                    r_st <= R_REQ;
                end
                R_REQ: r_st <= R_WAIT;
                R_WAIT: if (tile_ok) begin
                    romdata_p <= tile_data;
                    r_st <= R_DEP;
                end
                R_DEP: if (!hs_valid) begin
                    h_attr <= r_attr;
                    h_rom <= romdata_p;
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
                    flip_c <= h_flip;
                    wtile <= h_tile;
                    wlyr <= h_lyr;
                    subc <= h_sub;
                    fpx8 <= 3'd0;
                    hs_valid <= 1'b0;
                    cs_st <= C_WRITE;
                end
                C_WRITE: if (fpx8 == 3'd7)
                    cs_st <= C_IDLE;
                else
                    fpx8 <= fpx8 + 3'd1;
                default: cs_st <= C_IDLE;
            endcase
        end
    end

    wire [9:0] lb_wa = {fbank,outpx};
    // The Violent Storm callback uses attr[1:0] as a two-bit mix code. The
    // line-buffer word now carries those two mix bits, the four colour
    // (colnib) bits, and the full 5-bit raw pen (Fix 1) -- 11 bits total.
    wire [10:0] lb_wd = {attr_c[1:0],colnib_c,pen5};
    wire lb_we = (cs_st == C_WRITE) && outpx_ok;
    // Visible pixel column: counts CCU pixel enables while LHBL is high, so it
    // does not depend on the counter value the CCU happens to start blanking at.
    reg [8:0] vis_x;
    always @(posedge clk or posedge rst) begin
        if (rst)
            vis_x <= 9'd0;
        else if (pxl_cen)
            vis_x <= lhbl ? vis_x + 9'd1 : 9'd0;
    end
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

    // jtframe_rpwp_ram has a synchronous read port: lb*_q is the data for
    // the address sampled on the preceding clk edge. Pipeline the display
    // qualification by the same edge so current blank/coverage state is not
    // combined with the previous RAM word.
    reg [3:0] cov_ok;
    reg       visible_q;
    always @(posedge clk) begin
        cov_ok[0] <= dpx < disp_cov[0];
        cov_ok[1] <= dpx < disp_cov[1];
        cov_ok[2] <= dpx < disp_cov[2];
        cov_ok[3] <= dpx < disp_cov[3];
        visible_q <= lhbl && lvbl;
    end

    assign lyrf_pxl = (visible_q && gfx_en[0] && cov_ok[0]) ? lb0_q[8:0] : 9'd0;
    assign lyra_pxl = (visible_q && gfx_en[1] && cov_ok[1]) ? lb1_q[8:0] : 9'd0;
    assign lyrb_pxl = (visible_q && gfx_en[2] && cov_ok[2]) ? lb2_q[8:0] : 9'd0;
    assign lyrc_pxl = (visible_q && gfx_en[3] && cov_ok[3]) ? lb3_q[8:0] : 9'd0;
    assign lyrf_mix = (visible_q && gfx_en[0] && cov_ok[0]) ? lb0_q[10:9] : 2'b00;
    assign lyra_mix = (visible_q && gfx_en[1] && cov_ok[1]) ? lb1_q[10:9] : 2'b00;
    assign lyrb_mix = (visible_q && gfx_en[2] && cov_ok[2]) ? lb2_q[10:9] : 2'b00;
    assign lyrc_mix = (visible_q && gfx_en[3] && cov_ok[3]) ? lb3_q[10:9] : 2'b00;

endmodule
