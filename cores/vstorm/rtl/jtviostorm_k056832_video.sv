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
 * Viostorm's K056832 is configured 5bpp (K056832_BPP_5, mystwarr.cpp); the
 * tilepen() 5-byte-row ROM fetch below decodes all 5 bit-planes, but only
 * pen[3:0] currently reaches the 8-bit line-buffer/pixel ports -- see the
 * finding-3 note at tilepen()'s call site and the evidence ledger.
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

    input       [3:0] page0, page1, page2, page3,
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

    // Violent Storm's VIDEO_START offsets are {-1,+1,+3,+4}; this is taken
    // directly from mystwarr_v.cpp, not from the donor's Moo Mesa offsets.
    function signed [9:0] layer_offx(input [1:0] layer);
        case (layer)
            2'd0: layer_offx = -10'sd1;
            2'd1: layer_offx =  10'sd1;
            2'd2: layer_offx =  10'sd3;
            default: layer_offx = 10'sd4;
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

    // P_ROM3B is a one-cycle gap with tile_cs deasserted between the two
    // word requests: the request/ack contract (jtframe_romrq.v: "works with
    // addr_ok permanently high as long as addr is not changed until data_ok
    // is produced") requires tile_addr to stay stable for the whole cycle
    // tile_cs is high. word_addr0 (word 0) is stable across P_ROM2/P_ROM3;
    // tile_cs is deasserted in P_ROM3B while tile_addr switches to
    // word_addr1; tile_cs reasserts only in P_ROM4 with word_addr1 stable.
    // See Fix 2 in the evidence ledger.
    localparam P_IDLE=4'd0, P_SETUP=4'd1, P_ATTR=4'd2, P_ATTR2=4'd3,
               P_CODE=4'd4, P_CODE2=4'd5, P_ROM=4'd6, P_ROM2=4'd7,
               P_ROM3=4'd8, P_ROM3B=4'd9, P_ROM4=4'd10, P_DEP=4'd11;
    localparam C_IDLE=1'b0, C_WRITE=1'b1;

    reg [3:0] pf_st;
    reg       cs_st;
    reg [1:0] flyr;
    reg [5:0] ftile;
    reg [8:0] fline;
    reg [15:0] attr_p, code_p;
    reg [31:0] romword0;
    reg [63:0] romdata_p;
    reg [1:0]  fbyteoff_p;
    reg [18:0] rom_addr;
    reg [2:0]  fpx8;
    reg [1:0]  wlyr;
    reg [5:0]  wtile;
    reg [15:0] attr_c;
    reg [63:0] romdata_c;
    reg [1:0]  byteoff_c;
    reg [1:0]  flip_c;
    reg [2:0]  subc;
    reg        hs_valid;
    reg [15:0] h_attr;
    reg [63:0] h_rom;
    reg [1:0]  h_byteoff;
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
        (18'sd424 + {{2{dx_val[15]}},dx_val} - {{8{offx_val[9]}},offx_val} +
                     {{5{corr_x[12]}},corr_x}) :
        (18'sd40 + {{2{dx_val[15]}},dx_val} -
                    {{8{offx_val[9]}},offx_val});
    wire [8:0] base_x = xbase_s[8:0];
    wire [2:0] first_sub = gflip_x ? ~base_x[2:0] : base_x[2:0];
    wire [5:0] first_col = base_x[8:3];
    wire [5:0] cur_col = gflip_x ? (first_col - ftile) : (first_col + ftile);
    wire signed [17:0] y_s = gflip_y ?
        (18'sd223 - {9'b0,fline} + {{2{dy_val[15]}},dy_val} +
                     {{6{corr_y[11]}},corr_y}) :
        ({9'b0,fline} + {{2{dy_val[15]}},dy_val});
    wire [7:0] y_tm = y_s[7:0];
    wire [4:0] frow = y_tm[7:3];
    wire [2:0] fty = y_tm[2:0];
    wire [11:0] tile_index = {frow,cur_col,1'b0};
    wire [16:0] attr_addr = {1'b0,layer_page(flyr),tile_index};
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
    wire [2:0] tyf = tile_flip_p[1] ? ~fty : fty;

    wire flipx_c = flip_c[0];
    // k056832_device::get_tile_info() forms the six-bit fbits=2 colour field
    // as (attr&0x03)|((attr>>2)&0x3c); viostorm_tile_callback then selects
    // color>>2 & 0xf as the four-bit palette nibble.  Working through the
    // algebra that final nibble is attr[7:4] (not attr[5:2], which reuses
    // the flip-override bits at attr[3:2] and drops attr[7:6] entirely).
    // attr[1:0] remains the independent two-bit tile-mix code.
    wire [3:0] colnib_c = attr_c[7:4];
    wire [2:0] pxf = flipx_c ? ~fpx8 : fpx8;
    // Konami "Pre-GX" 5bpp ROM format (mystwarr.cpp decode_tiles(), MAME
    // 0.289): raw ROM data is packed 5 bytes/row (8 rows/tile) -- 4 "chunky"
    // bytes (s0..s3) holding bit-planes 0-3 nibble-interleaved per the GX173
    // donor's byte_sel order, plus one planar 5th-plane byte (s4) where
    // s4.bit(7-x) is plane 4 for pixel column x directly. `d` carries two
    // back-to-back 32-bit ROM words {word1,word0}; `boff` is the byte offset
    // of s0 within that 8-byte window (rows are 5 bytes apart, so this shifts
    // by one byte every row, hence the two-word fetch).
    function [4:0] tilepen(input [2:0] tx, input [63:0] d, input [1:0] boff);
        reg [2:0] o;
        reg [7:0] s0,s1,s2,s3,s4;
        reg [1:0] byte_sel;
        reg [7:0] b;
        begin
            o = {1'b0,boff};
            s0 = d[(o+3'd0)*8 +: 8];
            s1 = d[(o+3'd1)*8 +: 8];
            s2 = d[(o+3'd2)*8 +: 8];
            s3 = d[(o+3'd3)*8 +: 8];
            s4 = d[(o+3'd4)*8 +: 8];
            case (tx)
                3'd0,3'd1: byte_sel = 2'd1;
                3'd2,3'd3: byte_sel = 2'd0;
                3'd4,3'd5: byte_sel = 2'd3;
                default:   byte_sel = 2'd2;
            endcase
            case (byte_sel)
                2'd0: b = s0;
                2'd1: b = s1;
                2'd2: b = s2;
                default: b = s3;
            endcase
            tilepen = {s4[3'd7-tx], tx[0] ? b[3:0] : b[7:4]};
        end
    endfunction
    // pen5 is the full 5-bit raw tile pen (all 32 palette entries per tile
    // color group are now reachable -- Fix 1). It is carried whole through
    // lb_wd/lb_q/lyrf_pxl into jtviostorm_priority.sv, which performs the
    // colnib*16+pen composition against the K055555 layer palette base.
    wire [4:0] pen5 = tilepen(pxf,romdata_c,byteoff_c);
    wire signed [11:0] outpx_s = $signed({3'b0,wtile,3'b0}) -
                                  $signed({9'b0,subc}) +
                                  $signed({9'b0,fpx8});
    wire [8:0] outpx = outpx_s[8:0];
    wire outpx_ok = (outpx_s >= 0) && (outpx_s < 384);

    // k056832_device::get_tile_info() indexes the flat decoded gfx array
    // directly by `code` with no runtime bank offset (create_gfx() decodes
    // the whole ROM region once at device_start()); rom_bank/REG1A-1B only
    // steers the CPU ROM-checksum readback window (mw_rom_word_r in
    // jtviostorm_k056832.sv), so it must not appear in this render address.
    // ROM rows are 5 bytes apart (see tilepen() above), so the byte address
    // for row `rom_addr` is rom_addr*5; that byte address is rarely 4-byte
    // aligned, so two consecutive 32-bit tile-ROM words are fetched and the
    // 5-byte row window is extracted starting at the low 2 bits of the byte
    // address (byte_off/fbyteoff_p/byteoff_c/h_byteoff below).
    wire [21:0] byte_addr  = {3'b0,rom_addr} * 22'd5;
    wire [19:0] word_addr0 = byte_addr[21:2];
    wire [1:0]  byte_off   = byte_addr[1:0];
    wire [19:0] word_addr1 = word_addr0 + 20'd1;

    assign tile_cs = (pf_st == P_ROM2) || (pf_st == P_ROM3) || (pf_st == P_ROM4);
    assign tile_addr = (pf_st == P_ROM3B || pf_st == P_ROM4) ? word_addr1 : word_addr0;

    always @(posedge clk or posedge rst) begin : render_fsm
        integer ci;
        if (rst) begin
            pf_st <= P_IDLE;
            cs_st <= C_IDLE;
            flyr <= 2'd0;
            ftile <= 6'd0;
            fline <= 9'd0;
            attr_p <= 16'd0;
            code_p <= 16'd0;
            romword0 <= 32'd0;
            romdata_p <= 64'd0;
            fbyteoff_p <= 2'd0;
            rom_addr <= 19'd0;
            fpx8 <= 3'd0;
            wlyr <= 2'd0;
            wtile <= 6'd0;
            attr_c <= 16'd0;
            romdata_c <= 64'd0;
            byteoff_c <= 2'd0;
            flip_c <= 2'd0;
            subc <= 3'd0;
            hs_valid <= 1'b0;
            h_attr <= 16'd0;
            h_rom <= 64'd0;
            h_byteoff <= 2'd0;
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
                fline <= vpos + 9'd1;
                pf_st <= P_SETUP;
                cs_st <= C_IDLE;
                hs_valid <= 1'b0;
                for (ci=0; ci<4; ci=ci+1) begin
                    disp_cov[ci] <= fill_cov[ci];
                    fill_cov[ci] <= 9'd0;
                end
            end

            if (cs_st == C_WRITE && outpx_ok && (outpx + 9'd1) > fill_cov[wlyr])
                fill_cov[wlyr] <= outpx + 9'd1;

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
                    pf_st <= P_ROM;
                end
                P_ROM: begin
                    rom_addr <= {code_p,3'b000} + {{16{1'b0}},tyf};
                    pf_st <= P_ROM2;
                end
                P_ROM2: pf_st <= P_ROM3;
                P_ROM3: if (tile_ok) begin
                    romword0 <= tile_data;
                    fbyteoff_p <= byte_off;
                    pf_st <= P_ROM3B;
                end
                P_ROM3B: pf_st <= P_ROM4;
                P_ROM4: if (tile_ok) begin
                    romdata_p <= {tile_data,romword0};
                    pf_st <= P_DEP;
                end
                P_DEP: if (!hs_valid) begin
                    h_attr <= attr_p;
                    h_rom <= romdata_p;
                    h_byteoff <= fbyteoff_p;
                    h_tile <= ftile;
                    h_lyr <= flyr;
                    h_sub <= first_sub;
                    h_flip <= tile_flip_p;
                    hs_valid <= 1'b1;
                    if (ftile == 6'd48) begin
                        ftile <= 6'd0;
                        if (flyr == 2'd3)
                            pf_st <= P_IDLE;
                        else begin
                            flyr <= flyr + 2'd1;
                            pf_st <= P_SETUP;
                        end
                    end else begin
                        ftile <= ftile + 6'd1;
                        pf_st <= P_SETUP;
                    end
                end
                default: pf_st <= P_IDLE;
            endcase

            case (cs_st)
                C_IDLE: if (hs_valid) begin
                    attr_c <= h_attr;
                    romdata_c <= h_rom;
                    byteoff_c <= h_byteoff;
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
    wire [8:0] dpx = hpos - 9'd40;
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

endmodule
