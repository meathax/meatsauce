//============================================================================
//  OutRunners cabinet panel overlay: each seat's 16x1 HD44780 LCD and its four
//  cabinet lamps, drawn as a 20-line strip BELOW the game picture.
//
//  Placement: the native raster is 262 lines with 224 active (s32_video.sv),
//  VSync on lines 233-235.  With the panel enabled the strip occupies the
//  first PANEL_LINES lines of vertical blanking (224-243), which become active
//  (DE high) lines, and VSync moves to vblank lines PANEL_LINES+3..+5
//  (247-249), leaving 12 back-porch lines.  Line/frame totals, CE_PIXEL,
//  HSync, HBlank and every game pixel are untouched, so no part of the game
//  image is covered.  With the panel disabled every output is the input,
//  combinationally: other titles and the "Off" setting keep the exact native
//  raster.  The enable is sampled at the start of vertical blanking so the
//  raster never changes shape mid-frame.
//
//  Lamps (decomp src/system/interrupts.c update_lamps/update_button_lamps):
//    port D bit 1 CHECK POINT, bit 3 RACE LEADER (per seat, I/O chip 0/1)
//    port G bit 0 DJ/MUSIC button, bit 1 << >> button
//
//  Layout of one seat (320 columns, centred in 416 mode), y = strip line:
//    x   6..14  LED  CHECK (y 1-9, amber) / LEADER (y 10-18, red)
//    x  18..53  labels "CHECK " / "LEADER" (lit in the lamp colour)
//    x  62..257 bezel, x 64..255 / y 2..17 backlit STN glass with the 16
//               characters at 2x2 pixels per dot (12-pixel pitch) and the
//               unlit dot matrix faintly visible
//    x 270..299 labels "MUSIC" / "<< >>", x 305..313 their cyan LEDs
//  Single-screen mode shows the selected screen's seat; Splitscreen shows
//  each seat under its own screen.
//
//  Resources: three M10K blocks (font ROM 2048x5, LCD RAM 512x8, line
//  buffer 2048x4) and a small renderer that builds the next strip line into
//  the idle line-buffer bank during the current line (< 1000 of the ~3070
//  clk_sys cycles available per line).
//============================================================================

module s32_lcd_panel (
    input             clk,             // clk_sys == CLK_VIDEO
    input             rst,             // game reset (LCD controllers)
    input             video_rst,       // raster-side reset

    input             enable,          // OutRunners profile && OSD on
    input             mode_416,
    input             splitscreen,
    input             screen_sel,      // single-screen mode: 0 = seat 1, 1 = seat 2

    input       [7:0] port_d_a, port_g_a,   // I/O chip 0 (seat 1)
    input       [7:0] port_d_b, port_g_b,   // I/O chip 1 (seat 2)

    input      [23:0] rgb_in,
    input             ce_in,
    input             hs_in,
    input             vs_in,
    input             hb_in,
    input             vb_in,

    output     [23:0] rgb_out,
    output            hs_out,
    output            vs_out,
    output            hb_out,
    output            vb_out,
    output            active           // panel lines present this frame
);

localparam [6:0] PANEL_LINES = 7'd20;
localparam [6:0] VS_FIRST    = PANEL_LINES + 7'd3;   // vblank line index
localparam [6:0] VS_LAST     = PANEL_LINES + 7'd5;

// ---------------------------------------------------------------------------
// LCD controllers and the shared LCD RAM (seat x {DDRAM 00-7F, CGRAM 80-BF})
// ---------------------------------------------------------------------------
wire       w0_req, w1_req;
wire [7:0] w0_addr, w1_addr, w0_data, w1_data;
wire       on0, on1, two0, two1;
wire [6:0] sh0, sh1;

s32_hd44780 lcd0 (
    .clk(clk), .rst(rst), .port_g(port_g_a),
    .wr_req(w0_req), .wr_addr(w0_addr), .wr_data(w0_data),
    .disp_on(on0), .two_line(two0), .disp_shift(sh0)
);
s32_hd44780 lcd1 (
    .clk(clk), .rst(rst), .port_g(port_g_b),
    .wr_req(w1_req), .wr_addr(w1_addr), .wr_data(w1_data),
    .disp_on(on1), .two_line(two1), .disp_shift(sh1)
);

// One write port, served to the seats on alternate cycles through a one-deep
// hold per seat (a controller issues at most one write every other cycle).
reg       hv0, hv1, wsel;
reg [7:0] ha0, ha1, hd0, hd1;
reg       lw_en;
reg [8:0] lw_addr;
reg [7:0] lw_data;
always @(posedge clk) begin
    lw_en <= 1'b0;
    wsel  <= ~wsel;
    if (rst) begin
        hv0 <= 1'b0;
        hv1 <= 1'b0;
    end
    else begin
        if (!wsel && hv0) begin
            lw_en   <= 1'b1;
            lw_addr <= {1'b0, ha0};
            lw_data <= hd0;
        end
        else if (wsel && hv1) begin
            lw_en   <= 1'b1;
            lw_addr <= {1'b1, ha1};
            lw_data <= hd1;
        end
        if (w0_req) begin
            hv0 <= 1'b1;
            ha0 <= w0_addr;
            hd0 <= w0_data;
        end
        else if (!wsel) hv0 <= 1'b0;
        if (w1_req) begin
            hv1 <= 1'b1;
            ha1 <= w1_addr;
            hd1 <= w1_data;
        end
        else if (wsel) hv1 <= 1'b0;
    end
end

reg [7:0] lcd_ram [0:511];
reg [8:0] lr_addr;
reg [7:0] lr_q;
integer   ii;
initial begin
    for (ii = 0; ii < 512; ii = ii + 1)
        lcd_ram[ii] = ii[7] ? 8'h00 : 8'h20;
end
always @(posedge clk) begin
    if (lw_en) lcd_ram[lw_addr] <= lw_data;
    lr_q <= lcd_ram[lr_addr];
end

// HD44780 ROM code A00 character generator, 256 x 8 rows of 5 dots.
reg [4:0] font_rom [0:2047];
reg [10:0] fr_addr;
reg [4:0]  fr_q;
initial $readmemh("rtl/video/s32_hd44780_font.hex", font_rom);
always @(posedge clk) fr_q <= font_rom[fr_addr];

// ---------------------------------------------------------------------------
// Line renderer
// ---------------------------------------------------------------------------
localparam [3:0] C_BG = 4'd0,  C_HILITE = 4'd1, C_SHADOW = 4'd2, C_BEZEL = 4'd3,
                 C_GLASS = 4'd4, C_GHOST = 4'd5, C_INK = 4'd6, C_LABOFF = 4'd7,
                 C_AMBER = 4'd8, C_AMBHALO = 4'd9, C_RED = 4'd10, C_REDHALO = 4'd11,
                 C_CYAN = 4'd12, C_CYNHALO = 4'd13, C_LEDOFF = 4'd14, C_SPEC = 4'd15;

function automatic [7:0] label_char(input row2, input [3:0] i);
    // 0-5: left label, 6-10: right label
    case ({row2, i})
        5'h00: label_char = "C"; 5'h01: label_char = "H"; 5'h02: label_char = "E";
        5'h03: label_char = "C"; 5'h04: label_char = "K"; 5'h05: label_char = " ";
        5'h06: label_char = "M"; 5'h07: label_char = "U"; 5'h08: label_char = "S";
        5'h09: label_char = "I"; 5'h0a: label_char = "C";
        5'h10: label_char = "L"; 5'h11: label_char = "E"; 5'h12: label_char = "A";
        5'h13: label_char = "D"; 5'h14: label_char = "E"; 5'h15: label_char = "R";
        5'h16: label_char = "<"; 5'h17: label_char = "<"; 5'h18: label_char = " ";
        5'h19: label_char = ">"; 5'h1a: label_char = ">";
        default: label_char = " ";
    endcase
endfunction

// LED disc on a 9x9 box: 1 = disc, 2 = halo ring, 3 = specular, 0 = outside.
function automatic [1:0] led_shape(input signed [4:0] dx, input signed [4:0] dy);
    reg [2:0] ax, ay;
    reg [4:0] d2;
    begin
        ax = dx[4] ? -dx[2:0] : dx[2:0];
        ay = dy[4] ? -dy[2:0] : dy[2:0];
        d2 = ax * ax + ay * ay;
        if ((dx == -5'sd1 && dy == -5'sd2) || (dx == -5'sd2 && dy == -5'sd1))
            led_shape = 2'd3;
        else if (d2 <= 5'd11) led_shape = 2'd1;
        else if (d2 <= 5'd20) led_shape = 2'd2;
        else                  led_shape = 2'd0;
    end
endfunction

wire [9:0] W   = mode_416 ? 10'd416 : 10'd320;
wire [9:0] OFF = mode_416 ? 10'd48  : 10'd0;

localparam [1:0] R_IDLE = 2'd0, R_FETCH = 2'd1, R_PIX = 2'd2;
reg  [1:0] rs;
reg  [4:0] ty;           // strip line being rendered
reg        wbank;
reg  [5:0] fi;           // fetch item: 0-31 seat chars, 32-42 labels
reg  [2:0] fstep;
reg  [7:0] fcode;
reg  [4:0] rows [0:31];
reg  [4:0] lab  [0:10];
reg  [1:0] lamp_chk, lamp_ldr, lamp_mus, lamp_arr;
reg  [1:0] lcd_on;
reg  [6:0] lshift0, lshift1;
reg        ltwo0, ltwo1;

reg  [9:0] px;           // linear write x: seat 0 cols then seat 1 cols
reg        pseat;
reg  [9:0] pcol;
// incremental geometry counters
reg        gsub;
reg  [2:0] gdot;
reg  [3:0] gci;
reg  [2:0] tcol;
reg  [3:0] tch;

reg        lb_we;
reg [10:0] lb_waddr;
reg  [3:0] lb_wdata;

wire       glass_line = (ty >= 5'd2) && (ty <= 5'd17);
wire [2:0] dot_row    = ty[3:1] - 3'd1;            // (ty-2)>>1
wire       lab_row1   = (ty >= 5'd2)  && (ty <= 5'd9);
wire       lab_row2   = (ty >= 5'd11) && (ty <= 5'd18);
wire [2:0] lab_r      = lab_row2 ? ty[2:0] - 3'd3 : ty[2:0] - 3'd2;  // ty-11 / ty-2

// DDRAM address of character c on line 0 for the fetching seat
wire       fseat   = fi[4];
wire [3:0] fchr    = fi[3:0];
wire [6:0] fshift  = fseat ? lshift1 : lshift0;
wire       ftwo    = fseat ? ltwo1 : ltwo0;
wire [7:0] fsum    = {1'b0, fshift} + {4'd0, fchr};
wire [6:0] fpos    = ftwo ? ((fsum >= 8'd40) ? fsum[6:0] - 7'd40 : fsum[6:0])
                          : ((fsum >= 8'd80) ? fsum[6:0] - 7'd80 : fsum[6:0]);

// Pixel classification for the current sweep position
wire signed [10:0] lx = $signed({1'b0, pcol}) - $signed({1'b0, OFF});
wire       in_seat  = (lx >= 0) && (lx < 11'sd320);
wire       row1     = (ty >= 5'd1)  && (ty <= 5'd9);
wire       row2     = (ty >= 5'd10) && (ty <= 5'd18);
wire [4:0] led_cy   = row2 ? 5'd14 : 5'd5;
wire signed [4:0] led_dy = $signed(ty - led_cy);
wire       led_l    = (lx >= 11'sd6)   && (lx <= 11'sd14);
wire       led_r    = (lx >= 11'sd305) && (lx <= 11'sd313);
wire signed [10:0] led_ddx = led_l ? lx - 11'sd10 : lx - 11'sd309;
wire [1:0] shape    = led_shape(led_ddx[4:0], led_dy);
wire       text_l   = (lx >= 11'sd18)  && (lx <= (row2 ? 11'sd53 : 11'sd47));
wire       text_r   = (lx >= 11'sd270) && (lx <= 11'sd299);
wire       bezel    = (lx >= 11'sd62)  && (lx <= 11'sd257) && (ty >= 5'd1) && (ty <= 5'd18);
wire       corner   = (lx == 11'sd62 || lx == 11'sd257) && (ty == 5'd1 || ty == 5'd18);
wire       glass    = (lx >= 11'sd64)  && (lx <= 11'sd255) && glass_line;
wire       glyph_x  = (lx >= 11'sd65)  && (lx <= 11'sd254) && (gdot != 3'd5);
wire [4:0] grow     = rows[{pseat, gci}];
wire       gbit     = grow[3'd4 - gdot];
wire       sc_on    = pseat ? lcd_on[1] : lcd_on[0];
// Splitscreen: continue the composer's 2-pixel A|B divider through the strip
wire       seam     = splitscreen && (pseat ? (pcol == 10'd0) : (pcol == W - 10'd1));
wire [4:0] trow     = lab[text_r ? 4'd6 + tch : tch];
wire       tbit     = (tcol != 3'd5) && trow[3'd4 - tcol];

reg  [3:0] pix_c;
always @(*) begin
    reg lit;
    reg [3:0] on_c, halo_c;
    pix_c = (ty == 5'd0) ? C_HILITE : (ty == 5'd19) ? C_SHADOW : C_BG;
    if (seam) pix_c = C_BEZEL;
    else if (in_seat) begin
        if ((led_l || led_r) && (row1 || row2)) begin
            if (led_l) begin
                lit    = row2 ? lamp_ldr[pseat] : lamp_chk[pseat];
                on_c   = row2 ? C_RED : C_AMBER;
                halo_c = row2 ? C_REDHALO : C_AMBHALO;
            end
            else begin
                lit    = row2 ? lamp_arr[pseat] : lamp_mus[pseat];
                on_c   = C_CYAN;
                halo_c = C_CYNHALO;
            end
            case (shape)
                2'd1: pix_c = lit ? on_c : C_LEDOFF;
                2'd2: if (lit) pix_c = halo_c;
                2'd3: pix_c = lit ? C_SPEC : C_LABOFF;
                default: ;
            endcase
        end
        else if ((text_l || text_r) && (lab_row1 || lab_row2)) begin
            if (text_l) begin
                lit  = lab_row2 ? lamp_ldr[pseat] : lamp_chk[pseat];
                on_c = lab_row2 ? C_RED : C_AMBER;
            end
            else begin
                lit  = lab_row2 ? lamp_arr[pseat] : lamp_mus[pseat];
                on_c = C_CYAN;
            end
            if (tbit) pix_c = lit ? on_c : C_LABOFF;
        end
        else if (bezel && !corner) begin
            if (!glass)             pix_c = C_BEZEL;
            else if (!glyph_x)      pix_c = C_GLASS;
            else if (!sc_on)        pix_c = C_GLASS;
            // lit dots are solid 2x2; unlit dots leave a faint pixel so the
            // dot matrix reads as a grid, like an unpowered STN segment
            else if (gbit)          pix_c = C_INK;
            else                    pix_c = (!gsub && !ty[0]) ? C_GHOST : C_GLASS;
        end
    end
end

// render request from the raster side (same clock)
reg        rq;
reg  [4:0] rq_ty;

always @(posedge clk) begin
    lb_we <= 1'b0;
    if (video_rst) begin
        rs <= R_IDLE;
    end
    else begin
        case (rs)
        R_IDLE: ;
        R_FETCH: begin
            // each read: address registered, one cycle in the RAM, then
            // capture.  Seat characters take two reads (code, then the glyph
            // row from CGRAM or the character ROM); labels one.
            fstep <= fstep + 3'd1;
            if (fi < 6'd32) begin
                case (fstep)
                    3'd0: lr_addr <= {fseat, 1'b0, fpos};
                    3'd2: begin
                        fcode   <= lr_q;
                        lr_addr <= {fseat, 2'b10, lr_q[2:0], dot_row};
                        fr_addr <= {lr_q, dot_row};
                    end
                    3'd4: begin
                        rows[fi[4:0]] <= (glass_line && (fseat ? lcd_on[1] : lcd_on[0]))
                                       ? ((fcode < 8'h10) ? lr_q[4:0] : fr_q) : 5'd0;
                        fi    <= fi + 6'd1;
                        fstep <= 3'd0;
                    end
                    default: ;
                endcase
            end
            else begin
                case (fstep)
                    3'd0: fr_addr <= {label_char(lab_row2, fi[3:0]), lab_r};
                    3'd2: begin
                        lab[fi[3:0]] <= (lab_row1 || lab_row2) ? fr_q : 5'd0;
                        fstep <= 3'd0;
                        if (fi == 6'd42) begin
                            rs    <= R_PIX;
                            px    <= 10'd0;
                            pseat <= 1'b0;
                            pcol  <= 10'd0;
                        end
                        else fi <= fi + 6'd1;
                    end
                    default: ;
                endcase
            end
        end
        R_PIX: begin
            lb_we    <= 1'b1;
            lb_waddr <= {wbank, px};
            lb_wdata <= pix_c;
            px       <= px + 10'd1;
            // glyph counters: reset entering x=65, 2 px per dot, 6 dots/char
            if (lx == 11'sd64) begin
                gsub <= 1'b0; gdot <= 3'd0; gci <= 4'd0;
            end
            else begin
                gsub <= ~gsub;
                if (gsub) begin
                    if (gdot == 3'd5) begin
                        gdot <= 3'd0;
                        gci  <= gci + 4'd1;
                    end
                    else gdot <= gdot + 3'd1;
                end
            end
            // label counters: reset entering x=18 / x=270, 6 px per char
            if (lx == 11'sd17 || lx == 11'sd269) begin
                tcol <= 3'd0; tch <= 4'd0;
            end
            else if (tcol == 3'd5) begin
                tcol <= 3'd0;
                tch  <= tch + 4'd1;
            end
            else tcol <= tcol + 3'd1;
            if (pcol == W - 10'd1) begin
                pcol  <= 10'd0;
                pseat <= 1'b1;
                if (pseat) rs <= R_IDLE;
            end
            else pcol <= pcol + 10'd1;
        end
        default: rs <= R_IDLE;
        endcase

        if (rq) begin
            rs       <= R_FETCH;
            ty       <= rq_ty;
            wbank    <= rq_ty[0];
            fi       <= 6'd0;
            fstep    <= 3'd0;
            lamp_chk <= {port_d_b[1], port_d_a[1]};
            lamp_ldr <= {port_d_b[3], port_d_a[3]};
            lamp_mus <= {port_g_b[0], port_g_a[0]};
            lamp_arr <= {port_g_b[1], port_g_a[1]};
            lcd_on   <= {on1, on0};
            lshift0  <= sh0;
            lshift1  <= sh1;
            ltwo0    <= two0;
            ltwo1    <= two1;
        end
    end
end

reg  [3:0] line_buf [0:2047];
reg [10:0] lb_raddr;
reg  [3:0] lb_q;
always @(posedge clk) begin
    if (lb_we) line_buf[lb_waddr] <= lb_wdata;
    lb_q <= line_buf[lb_raddr];
end

// ---------------------------------------------------------------------------
// Raster side: everything advances on the incoming pixel enable
// ---------------------------------------------------------------------------
reg        en_frame;
reg        vb_q, hb_q;
reg  [6:0] vbl;          // vblank line index, 7F outside vblank
reg  [9:0] rpx;
reg [23:0] rgb_r;
reg        hs_r, vs_r, hb_r, vb_r;

wire       hb_fall = hb_q & ~hb_in;
wire [6:0] cur_vbl = !vb_in ? 7'h7f : (hb_fall ? vbl + 7'd1 : vbl);
wire       strip   = en_frame && vb_in && (cur_vbl < PANEL_LINES);
wire [6:0] nxt_vbl = vb_in ? cur_vbl + 7'd1 : 7'd0;
wire [9:0] rbase   = splitscreen ? 10'd0 : (screen_sel ? W : 10'd0);

function automatic [23:0] pal(input [3:0] c);
    case (c)
        C_BG:      pal = 24'h1a1c22;
        C_HILITE:  pal = 24'h4a505c;
        C_SHADOW:  pal = 24'h07080a;
        C_BEZEL:   pal = 24'h030304;
        C_GLASS:   pal = 24'hb4d043;
        C_GHOST:   pal = 24'ha2bd38;
        C_INK:     pal = 24'h1a2608;
        C_LABOFF:  pal = 24'h50555f;
        C_AMBER:   pal = 24'hffa424;
        C_AMBHALO: pal = 24'h6e3f0a;
        C_RED:     pal = 24'hff3b30;
        C_REDHALO: pal = 24'h6a1410;
        C_CYAN:    pal = 24'h4fe0ff;
        C_CYNHALO: pal = 24'h0f5468;
        C_LEDOFF:  pal = 24'h2c2f36;
        default:   pal = 24'hfffbe8;   // C_SPEC
    endcase
endfunction

always @(posedge clk) begin
    rq <= 1'b0;
    if (video_rst) begin
        en_frame <= 1'b0;
        vb_q     <= 1'b0;
        hb_q     <= 1'b0;
        vbl      <= 7'h7f;
        rpx      <= 10'd0;
        lb_raddr <= 11'd0;
    end
    else if (ce_in) begin
        vb_q <= vb_in;
        hb_q <= hb_in;
        if (vb_in && !vb_q) en_frame <= enable;
        if (!vb_in)       vbl <= 7'h7f;
        else if (hb_fall) vbl <= vbl + 7'd1;

        // line start: build the next strip line into the other bank (also
        // while disabled, so the first enabled frame already has line 0)
        if (hb_fall && (nxt_vbl < PANEL_LINES)) begin
            rq    <= 1'b1;
            rq_ty <= nxt_vbl[4:0];
        end

        // line-buffer read address for the pixel at the next enable
        if (hb_in) begin
            rpx      <= 10'd0;
            lb_raddr <= {nxt_vbl[0], rbase};
        end
        else begin
            rpx      <= rpx + 10'd1;
            lb_raddr <= {cur_vbl[0], rbase + rpx + 10'd1};
        end

        rgb_r <= strip ? pal(lb_q) : rgb_in;
        hs_r  <= hs_in;
        vs_r  <= en_frame ? (vb_in && cur_vbl >= VS_FIRST && cur_vbl <= VS_LAST) : vs_in;
        hb_r  <= hb_in;
        vb_r  <= vb_in & ~strip;
    end
end

assign active  = en_frame;
assign rgb_out = en_frame ? rgb_r : rgb_in;
assign hs_out  = en_frame ? hs_r  : hs_in;
assign vs_out  = en_frame ? vs_r  : vs_in;
assign hb_out  = en_frame ? hb_r  : hb_in;
assign vb_out  = en_frame ? vb_r  : vb_in;

endmodule
