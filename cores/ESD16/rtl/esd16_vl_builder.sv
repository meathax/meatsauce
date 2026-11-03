// ESD16 line builder engine. Two instances run in parallel inside esd16_video_line:
//   SPR=0 : tile layers. Layer 0 (opaque, colour bank) then layer 1 (pen 0 transparent) for line `bline`.
//           Every pixel 0..319 is written by layer 0; layer 1 pixels overwrite it with l1=1.
//   SPR=1 : sprites. Scans the 256 sprite entries in order (later wins) and emits hit rows, including the
//           decospr 'wing' tile. Writes only opaque in-range pixels, with pri = x[15] and the draw-order tag
//           {entry, wing}. With NLANES=2, two instances scan the same list and take alternate tile rows
//           (LANE 0: rows 0,2,4..; LANE 1: rows 1,3,5..); the parent merges them by order tag.
// Each engine owns its own ROM channel (pipelined req/ready, in-order valid, see esd16_video_line),
// so the 'bgs' and 'spr' SDRAM banks are fetched concurrently. The emitter turns one fetched tile
// row into 16 (or 8) pixel writes, one per clock, and overlaps the next row's ROM fetch.
// The parent owns the line buffers and the priority merge; this module never reads them back.
module esd16_vl_builder #(parameter SPR = 0, NLANES = 1, LANE = 0) (
    input              clk,
    input              rst,
    input              start,             // one-clock pulse: build line `start_line` into buffer `start_buf`
    input        [7:0] start_line,
    input              start_buf,
    output             busy,              // build (including emitter drain) in progress
    output reg  [13:0] busy_clks,

    input              cbank0,
    input              frame_odd,
    input        [1:0] layer_16x16,
    input              flip_screen,
    input       [10:0] scroll0x,
    input       [10:0] scroll0y,
    input       [10:0] scroll1x,
    input       [10:0] scroll1y,

    output reg  [12:0] vram0_addr,
    input       [15:0] vram0_q,
    output reg  [12:0] vram1_addr,
    input       [15:0] vram1_q,
    output reg   [9:0] sram_addr,
    input       [15:0] sram_q,

    output reg         rom_req,
    output reg  [20:0] rom_addr,
    input              rom_ready,
    input              rom_valid,
    input       [31:0] rom_data,

    output reg         wr_en,
    output reg         wr_buf,
    output reg   [8:0] wr_addr,
    output reg  [10:0] wr_data,
    output reg         wr_flag,           // SPR=0: pixel is a layer 1 pixel; SPR=1: sprite has priority bit set
    output reg   [8:0] wr_order           // SPR=1: draw order {entry, wing} (later entries / wing tiles win)
);
    localparam [4:0]
        S_IDLE  = 5'd0,  S_T_A   = 5'd1,  S_T_B   = 5'd2,  S_T_C   = 5'd3,
        S_RD_RQ = 5'd4,  S_RD_W  = 5'd5,  S_HAND  = 5'd6,  S_SP_A  = 5'd7,
        S_SP_B  = 5'd8,  S_SP_C  = 5'd9,  S_SP_R1 = 5'd11,
        S_SP_R2 = 5'd12, S_SP_R3 = 5'd13, S_SP_SCAN = 5'd14, S_SP_P  = 5'd15, S_DONE  = 5'd16;

    reg  [4:0]  st;
    reg  [7:0]  bline;           // line being built
    reg         bbuf;            // buffer being built
    reg  [1:0]  lay;             // 0 L0, 1 L1 (tile engine only)
    reg  [5:0]  tcnt;            // tile index 0..40 for 8x8, 0..20 for 16x16
    reg  [7:0]  spr_i;
    reg  [7:0]  spr_scan_i;      // index belonging to the registered SRAM Y-data token
    reg  [10:0] s0x, s0y, s1x, s1y;
    reg         size0_16, size1_16;
    reg         flip_latched;
    reg         cb0;
    reg  [15:0] code;
    reg  [3:0]  prow;            // row within tile (post flip)
    reg  [3:0]  nprow;           // row of the prefetched next tile
    reg         j_16, em_16;
    reg  [2:0]  rcnt;            // responses received
    reg  [2:0]  icnt;            // next request index to present
    reg  [31:0] rd [0:5];
    reg  signed [10:0] j_x;
    reg  [10:0] j_pbase;
    reg         j_transp, j_flip, j_flag;
    reg   [8:0] j_order;
    reg         item;            // parity of the sprite tile rows seen so far on this line
    reg  [15:0] y_raw, code_raw, x_raw;
    reg         s1_v, s1_buf, s1_flag;
    reg   [8:0] s1_order;
    reg   [8:0] s1_addr;
    reg  [10:0] s1_data;
    reg         wing_pass;       // second (x-16) tile of the current sprite row

    assign busy = (st != S_IDLE);

    // Layer maps are row-major: 128x64 entries for 8x8 and 64x64 for 16x16.
    wire [10:0] sx  = lay[0] ? s1x : s0x;
    wire [10:0] sy  = lay[0] ? s1y : s0y;
    wire        current_16 = lay[0] ? size1_16 : size0_16;
    wire  [9:0] wy16 = {2'b0, bline} + sy[9:0];
    wire  [8:0] wy8  = {1'b0, bline} + sy[8:0];
    wire  [5:0] tcol16 = sx[9:4] + tcnt[4:0];
    wire  [6:0] tcol8  = sx[9:3] + tcnt;
    wire [12:0] vram_addr_cur = current_16 ? {1'b0, wy16[9:4], tcol16}
                                           : {wy8[8:3], tcol8};
    wire  [3:0] prow_cur = current_16 ? wy16[3:0] : {1'b0, wy8[2:0]};
    // The flipped tilemap is still emitted left-to-right. Its source columns run backward.
    wire  [9:0] flip_ux = sx[9:0] + (lay[0] ? 10'd317 : 10'd321);
    wire  [9:0] flip_v16 = sy[9:0] + 10'd239 - {2'b0, bline};
    wire  [8:0] flip_v8  = sy[8:0] + 9'd239 - {1'b0, bline};
    wire  [5:0] flip_tcol16 = flip_ux[9:4] - tcnt[4:0];
    wire  [6:0] flip_tcol8  = flip_ux[9:3] - tcnt;
    wire [12:0] flip_vram_addr_cur = current_16 ? {1'b0, flip_v16[9:4], flip_tcol16}
                                                : {flip_v8[8:3], flip_tcol8};
    wire  [3:0] flip_prow_cur = current_16 ? flip_v16[3:0] : {1'b0, flip_v8[2:0]};
    wire [12:0] vram_addr_cur_sel = flip_latched ? flip_vram_addr_cur : vram_addr_cur;
    wire  [3:0] prow_cur_sel = flip_latched ? flip_prow_cur : prow_cur;
    wire  [5:0] tile_last = current_16 ? 6'd20 : 6'd40;
    wire        tile_last_hit = (tcnt == tile_last);

    // sprite helpers (combinational from y_raw)
    wire  signed [8:0] yi   = {~y_raw[8], y_raw[7:0]};
    wire         [2:0] mm   = (y_raw[10:9] == 2'd0) ? 3'd0 : (y_raw[10:9] == 2'd1) ? 3'd1 :
                              (y_raw[10:9] == 2'd2) ? 3'd3 : 3'd7;
    wire  signed [11:0] dd  = $signed({4'b0, bline}) - 12'sd232 + $signed({{3{yi[8]}}, yi}) +
                              $signed({5'b0, mm, 4'b0});
    wire signed [10:0] d_flip = $signed({3'b0, bline}) + 11'sd8 - $signed({{2{yi[8]}}, yi});
    // Streaming scan decision: sram_q is consumed with its explicit next-index token.
    wire signed [8:0] scan_yi = {~sram_q[8], sram_q[7:0]};
    wire        [2:0] scan_mm = (sram_q[10:9] == 2'd0) ? 3'd0 : (sram_q[10:9] == 2'd1) ? 3'd1 :
                                (sram_q[10:9] == 2'd2) ? 3'd3 : 3'd7;
    wire signed [11:0] scan_dd = $signed({4'b0, bline}) - 12'sd232 +
                                 $signed({{3{scan_yi[8]}}, scan_yi}) +
                                 $signed({5'b0, scan_mm, 4'b0});
    wire signed [10:0] scan_d_flip = $signed({3'b0, bline}) + 11'sd8 - $signed({{2{scan_yi[8]}}, scan_yi});
    wire        [10:0] scan_d_flip_limit = ({8'd0, scan_mm} + 11'd1) << 4;
    wire               scan_hit_normal = !scan_dd[11] && (scan_dd[10:4] <= {4'b0, scan_mm});
    wire               scan_hit_flipped = !scan_d_flip[10] && (scan_d_flip[10:0] < scan_d_flip_limit);
    wire               scan_sp_hit = (flip_latched ? scan_hit_flipped : scan_hit_normal) &&
                                     !(sram_q[12] && frame_odd);
    wire         [2:0] kk   = flip_latched ? d_flip[6:4] : dd[6:4];
    wire         [3:0] ry   = flip_latched ? d_flip[3:0] : dd[3:0];
    wire               sprite_fy = y_raw[14] ^ flip_latched;
    wire               sprite_fx = ~y_raw[13] ^ flip_latched;
    wire         [3:0] sprite_row = sprite_fy ? (4'd15 - ry) : ry;
    wire [15:0]  tc_main    = code_raw + (sprite_fy ? {13'd0, mm - kk} : {13'd0, kk});
    wire [15:0]  tc_full    = wing_pass ? (tc_main - {13'd0, mm} - 16'd1) : tc_main;
    wire  [8:0]  xu         = x_raw[8:0] - 9'd24;
    wire  [8:0]  xu_plus24  = x_raw[8:0] + 9'd24;
    wire signed [10:0] xnorm_minus24 = (xu >= 9'd320) ? ($signed({2'b0, xu}) - 11'sd512) : $signed({2'b0, xu});
    wire signed [10:0] xnorm_plus24  = (xu_plus24 >= 9'd320) ? ($signed({2'b0, xu_plus24}) - 11'sd512) : $signed({2'b0, xu_plus24});
    wire signed [10:0] xi = flip_latched ? (11'sd304 - xnorm_plus24) : xnorm_minus24;
    wire signed [10:0] sprite_jx = wing_pass ? (xi + (flip_latched ? 11'sd16 : -11'sd16)) : xi;

    // ROM read address generation
    reg  [20:0] ra;
    reg  [1:0]  rg;
    always @* begin
        rg = 2'd0; ra = 21'd0;
        if (SPR == 0) begin
            if (current_16) begin
                // 16x16 layout stores four 8x8 quadrants in separate 64-byte blocks.
                ra = {code[13:0], 6'd0} + {15'd0, prow[3], icnt[1], 4'd0} + {17'd0, prow[2:0], icnt[0]};
            end else begin
                // Raw 8x8 graphics: 64-byte tile stride, 8 bytes per row.
                ra = {1'd0, code, 4'd0} + {17'd0, prow[2:0], icnt[0]};
            end
        end else begin
            case (icnt)
                3'd0, 3'd3: rg = 2'd0;
                3'd1, 3'd4: rg = 2'd1;
                default:    rg = 2'd2;
            endcase
            // Plane groups are 2 MB apart (Head Panic: 32768 tiles per group; SWAT Police data is mirrored
            // twice in each group by its MRA so code mod 16384 matches MAME's gfx element wrap). Code is 15 bit.
            ra = ((rg == 2'd0) ? 21'h000000 : (rg == 2'd1) ? 21'h080000 : 21'h100000)
                 + {2'd0, code[14:0], 4'd0} + {18'd0, prow[3:1]} + ((icnt < 3'd3) ? 21'd8 : 21'd0);
        end
    end

    // pixel vector (128 bit: pixel i at [8i+:8]) from the 4 / 6 dwords
    wire [127:0] pv_bg = {rd[3], rd[2], rd[1], rd[0]};
    wire  [63:0] pv_h [0:1];
    genvar gh, gp;
    generate
        for (gh = 0; gh < 2; gh = gh + 1) begin : g_half
            wire [31:0] d0 = rd[3*gh + 0];
            wire [31:0] d1 = rd[3*gh + 1];
            wire [31:0] d2 = rd[3*gh + 2];
            wire [7:0] b1 = prow[0] ? d0[23:16] : d0[7:0];     // plane 1
            wire [7:0] b2 = prow[0] ? d0[31:24] : d0[15:8];    // plane 2
            wire [7:0] b3 = prow[0] ? d1[23:16] : d1[7:0];     // plane 3
            wire [7:0] b4 = prow[0] ? d1[31:24] : d1[15:8];    // plane 4
            wire [7:0] b0 = prow[0] ? d2[23:16] : d2[7:0];     // plane 0 (MSB)
            for (gp = 0; gp < 8; gp = gp + 1) begin : g_px
                assign pv_h[gh][8*gp +: 8] = {3'b000, b0[7-gp], b1[7-gp], b2[7-gp], b3[7-gp], b4[7-gp]};
            end
        end
    endgenerate
    wire [127:0] pv_j = (SPR != 0) ? {pv_h[1], pv_h[0]} : pv_bg;

    // emitter
    reg         em_busy;
    reg   [4:0] em_i;
    reg [127:0] em_pv;
    reg signed [10:0] em_x;
    reg  [10:0] em_pbase;
    reg         em_transp, em_flip, em_buf, em_flag;
    reg   [8:0] em_order;
    wire  [3:0] em_src = em_flip ? (em_16 ? ~em_i[3:0] : {1'b0, ~em_i[2:0]}) : em_i[3:0];
    wire  [7:0] em_pix = em_pv[8*em_src +: 8];
    wire signed [10:0] em_xx = em_x + $signed({6'b0, em_i});

    // next tile after the current one (tile index n -> n+1, layer 0 tiles 0..20 then layer 1)
    wire  [1:0] nl   = tile_last_hit ? lay + 2'd1 : lay;
    wire  [5:0] nt   = tile_last_hit ? 6'd0 : tcnt + 6'd1;
    wire [10:0] nsx  = nl[0] ? s1x : s0x;
    wire [10:0] nsy  = nl[0] ? s1y : s0y;
    wire        next_16 = nl[0] ? size1_16 : size0_16;
    wire  [9:0] nwy16 = {2'b0, bline} + nsy[9:0];
    wire  [8:0] nwy8  = {1'b0, bline} + nsy[8:0];
    wire  [5:0] ntcol16 = nsx[9:4] + nt[4:0];
    wire  [6:0] ntcol8  = nsx[9:3] + nt;
    wire [12:0] vram_addr_next = next_16 ? {1'b0, nwy16[9:4], ntcol16}
                                         : {nwy8[8:3], ntcol8};
    wire  [3:0] prow_next = next_16 ? nwy16[3:0] : {1'b0, nwy8[2:0]};
    wire  [9:0] nflip_ux = nsx[9:0] + (nl[0] ? 10'd317 : 10'd321);
    wire  [9:0] nflip_v16 = nsy[9:0] + 10'd239 - {2'b0, bline};
    wire  [8:0] nflip_v8 = nsy[8:0] + 9'd239 - {1'b0, bline};
    wire  [5:0] nflip_tcol16 = nflip_ux[9:4] - nt[4:0];
    wire  [6:0] nflip_tcol8 = nflip_ux[9:3] - nt;
    wire [12:0] flip_vram_addr_next = next_16 ? {1'b0, nflip_v16[9:4], nflip_tcol16}
                                              : {nflip_v8[8:3], nflip_tcol8};
    wire  [3:0] flip_prow_next = next_16 ? nflip_v16[3:0] : {1'b0, nflip_v8[2:0]};
    wire [15:0] vq = lay[0] ? vram1_q : vram0_q;
    wire  [2:0] nrd = (SPR != 0) ? 3'd6 : (current_16 ? 3'd4 : 3'd2);
    wire        last_rd = (rcnt == nrd - 3'd1);

    always @(posedge clk) begin
        // ---- emitter stage 1
        s1_v <= 1'b0;
        if (em_busy) begin
            s1_v    <= (!em_xx[10] && (em_xx[9:0] < 10'd320)) && (!em_transp || (em_pix != 8'd0));
            s1_addr <= em_xx[8:0];
            s1_data <= em_pbase + {3'b0, em_pix};
            s1_buf  <= em_buf;
            s1_flag <= em_flag;
            s1_order <= em_order;
            em_i    <= em_i + 5'd1;
            if (em_i == (em_16 ? 5'd15 : 5'd7)) em_busy <= 1'b0;
        end
        // ---- stage 2: line buffer write
        wr_en   <= s1_v;
        wr_addr <= s1_addr;
        wr_data <= s1_data;
        wr_buf  <= s1_buf;
        wr_flag <= s1_flag;
        wr_order <= s1_order;

        if (busy_clks != 14'h3fff) busy_clks <= busy_clks + 14'd1;

        if (rst) begin
            st <= S_IDLE; em_busy <= 1'b0; rom_req <= 1'b0;
            busy_clks <= 14'd0; wr_en <= 1'b0; s1_v <= 1'b0;
        end else if (start) begin
            rom_req <= 1'b0;
            em_busy <= 1'b0;
            bline <= start_line;
            bbuf  <= start_buf;
            s0x <= scroll0x; s0y <= scroll0y; s1x <= scroll1x; s1y <= scroll1y;
            size0_16 <= layer_16x16[0]; size1_16 <= layer_16x16[1];
            flip_latched <= flip_screen;
            cb0 <= cbank0;
            lay <= 2'd0; tcnt <= 6'd0; spr_i <= 8'd0; item <= 1'b0;
            busy_clks <= 14'd0;
            st <= (SPR != 0) ? S_SP_A : S_T_A;
        end else begin
            case (st)
            S_IDLE: ;
            // ---------------- tile layers
            S_T_A: begin
                if (lay[0]) vram1_addr <= vram_addr_cur_sel;
                else        vram0_addr <= vram_addr_cur_sel;
                prow <= prow_cur_sel;
                st <= S_T_B;
            end
            S_T_B: st <= S_T_C;
            S_T_C: begin
                code     <= current_16 ? {2'b0, vq[13:0]} : vq;   // 8x8: full 16-bit code (64 KB tiles); 16x16: code mod 16384
                if (tcnt != 6'd0 || lay[0]) prow <= nprow;
                rcnt     <= 3'd0;
                icnt     <= 3'd0;
                j_x      <= current_16
                          ? (flip_latched
                             ? ($signed({2'b0, tcnt[4:0], 4'b0}) + $signed({7'b0, flip_ux[3:0]}) - 11'sd15)
                             : ($signed({2'b0, tcnt[4:0], 4'b0}) - $signed({7'b0, sx[3:0]})))
                          : (flip_latched
                             ? ($signed({2'b0, tcnt, 3'b0}) + $signed({8'b0, flip_ux[2:0]}) - 11'sd7)
                             : ($signed({2'b0, tcnt, 3'b0}) - $signed({8'b0, sx[2:0]})));
                j_16     <= current_16;
                j_pbase  <= lay[0] ? 11'd0 : {2'b0, cb0, 8'd0};
                j_transp <= lay[0];
                j_flip   <= flip_latched;
                j_flag   <= lay[0];
                // prefetch the tile code of the next tile (same or next layer)
                if (nl[0]) vram1_addr <= flip_latched ? flip_vram_addr_next : vram_addr_next;
                else       vram0_addr <= flip_latched ? flip_vram_addr_next : vram_addr_next;
                nprow <= flip_latched ? flip_prow_next : prow_next;
                st <= S_RD_RQ;
            end
            S_RD_RQ: begin
                rom_addr <= ra;
                rom_req  <= 1'b1;
                icnt     <= 3'd1;
                st <= S_RD_W;
            end
            S_RD_W: begin
                if (rom_req && rom_ready) begin
                    if (icnt == nrd) rom_req <= 1'b0;
                    else begin
                        rom_addr <= ra;
                        icnt     <= icnt + 3'd1;
                    end
                end
                if (rom_valid) begin
                    rd[rcnt] <= rom_data;
                    rcnt     <= rcnt + 3'd1;
                    if (last_rd) st <= S_HAND;
                end
            end
            S_HAND: if (!em_busy) begin
                em_busy   <= 1'b1;
                em_i      <= 5'd0;
                em_pv     <= pv_j;
                em_x      <= j_x;
                em_16     <= j_16;
                em_pbase  <= j_pbase;
                em_transp <= j_transp;
                em_flip   <= j_flip;
                em_flag   <= j_flag;
                em_order  <= j_order;
                em_buf    <= bbuf;
                if (SPR != 0) begin
                    if (y_raw[11] && !wing_pass) begin wing_pass <= 1'b1; st <= S_SP_P; end
                    else if (spr_i == 8'd255) st <= S_DONE;
                    else begin spr_i <= spr_i + 8'd1; st <= S_SP_A; end
                end else begin
                    if (tile_last_hit) begin
                        tcnt <= 6'd0;
                        lay  <= lay + 2'd1;
                        st   <= lay[0] ? S_DONE : S_T_C;
                    end else begin
                        tcnt <= tcnt + 6'd1;
                        st <= S_T_C;
                    end
                end
            end
            // ---------------- sprites
            S_SP_A:  begin sram_addr <= {spr_i, 2'd0}; wing_pass <= 1'b0; st <= S_SP_B; end
            S_SP_B:  begin sram_addr <= {spr_i + 8'd1, 2'd0}; st <= S_SP_C; end
            // Prime one following Y record in S_SP_B. At this edge SRAM samples
            // that following address while this state consumes the current token.
            S_SP_C: begin
                y_raw <= sram_q;
                if (scan_sp_hit) begin sram_addr <= {spr_i, 2'd1}; st <= S_SP_R1; end
                else if (spr_i == 8'd255) st <= S_DONE;
                else begin
                    spr_scan_i <= spr_i + 8'd1;
                    sram_addr <= {spr_i + 8'd2, 2'd0};
                    st <= S_SP_SCAN;
                end
            end
            // Every miss consumes the registered Y token and launches the
            // following-but-one Y address. Hits leave this path for attributes.
            S_SP_SCAN: begin
                y_raw <= sram_q;
                if (scan_sp_hit) begin
                    spr_i <= spr_scan_i;
                    sram_addr <= {spr_scan_i, 2'd1};
                    st <= S_SP_R1;
                end else if (spr_scan_i == 8'd255) st <= S_DONE;
                else begin
                    spr_scan_i <= spr_scan_i + 8'd1;
                    sram_addr <= {spr_scan_i + 8'd2, 2'd0};
                end
            end
            S_SP_R1: begin sram_addr <= {spr_i, 2'd2}; st <= S_SP_R2; end
            S_SP_R2: begin code_raw <= sram_q; st <= S_SP_R3; end
            S_SP_R3: begin x_raw <= sram_q; st <= S_SP_P; end
            S_SP_P: begin
                code     <= {1'b0, tc_full[14:0]};
                prow     <= sprite_row;
                j_x      <= sprite_jx;
                j_16     <= 1'b1;
                j_pbase  <= 11'h200 + {3'b0, x_raw[11:9], 5'd0};
                j_flag   <= x_raw[15];
                j_order  <= {spr_i, wing_pass};
                j_flip   <= sprite_fx;
                j_transp <= 1'b1;
                rcnt     <= 3'd0;
                icnt     <= 3'd0;
                item     <= ~item;
                if (NLANES == 1 || item == LANE[0]) st <= S_RD_RQ;
                // Row owned by the other lane: continue the scan exactly as after an emitted row.
                else if (y_raw[11] && !wing_pass) begin wing_pass <= 1'b1; st <= S_SP_P; end
                else if (spr_i == 8'd255) st <= S_DONE;
                else begin spr_i <= spr_i + 8'd1; st <= S_SP_A; end
            end
            S_DONE: if (!em_busy && !s1_v && !wr_en) st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
