// SPDX-License-Identifier: GPL-3.0-only
// Derived from pinned jlrh/snk-fpga; see PROVENANCE.md.
module snk_union_video #(parameter DISPLAY_FLIP_ENABLE=0)(
    input             is_psychos,is_sports,
    input             is_ik,
    input             is_chopper,
    input             big_sp16,   // gwar: 256 KiB sp16 needs the full 16-bit word address (bit 17 = sprite code bit 10)
    input             is_16m,     // 16 MHz video-crystal boards (bermudat/worldwar/psychos/gwar/tdfever/fsoccer): 420x236      // Ikari Warriors / Victory Road (288x224 raster on the early 13.4MHz-family pixel enable)
    input      [12:0] bg_tile_count,
    input             display_flip,
    input             rst,
    input             clk,
    input             pxl_cen,

    input      [ 8:0] bg_scrollx, bg_scrolly,
    input      [ 8:0] sp16_scrollx, sp16_scrolly,
    input      [ 8:0] sp32_scrollx, sp32_scrolly,
    input      [ 7:0] split,
    input      [ 7:0] txbank,
    input             flip,

    output     [10:0] vbg_addr,
    input      [ 7:0] vbg_data,
    output     [10:0] vtx_addr,
    input      [ 7:0] vtx_data,
    output     [ 6:0] vspr_addr,
    input      [31:0] vspr_data,

    output     [18:2] bgrom_addr,
    output            bgrom_cs,
    input      [31:0] bgrom_data,
    input             bgrom_ok,
    output     [17:2] s16rom_addr,
    output            s16rom_cs,
    input      [31:0] s16rom_data,
    input             s16rom_ok,
    output     [18:2] s32rom_addr,
    output            s32rom_cs,
    input      [31:0] s32rom_data,
    input             s32rom_ok,
    input             blank_en,
    output     [10:0] op16_addr,
    input             op16,
    output     [ 9:0] op32_addr,
    input             op32,
    output     [14:0] txrom_addr,
    input      [ 7:0] txrom_data,
    output     [ 9:0] pal_addr,
    input      [ 3:0] palr, palg, palb,

    output reg        LHBL,
    output reg        LVBL,
    output reg        HS,
    output reg        VS,
    output reg [ 7:0] red, green, blue,
    input      [ 3:0] gfx_en,
    output     [11:0] obj_cycles,
    output     [ 2:0] render_busy,
    output reg [ 2:0] line_overrun
);

// 96.768MHz master, pixel = clk/16 (6.048MHz). Synthetic blanking: 16 H blank pixels, 13 V blank lines
// (the 16MHz-family totals match Gwar PCB refresh within 0.05%).
localparam VBLANK=33;
localparam [8:0] VACT=9'd224, VS0=VACT+9'd2, VS1=VACT+9'd5;
// Ikari/Victory Road and the early-family retimer run on the 93.8MHz PLL setting: clk/14 = 6.7MHz, 416x262 -> 61.47Hz.
// The 2 retimer fill pixels (HSJ/TNK3 414-pixel donor line) sit in the front porch, preserving active-picture timing.
// MAME visible area 288x216 (lines 8..223 of the 224-line bitmap).
// Measured real-PCB refresh (2026-10-23): Gwar 61.01Hz and Chopper I 61.326Hz. At 8MHz, the
// late/sports raster is 512x256 (61.035Hz); Chopper I is 512x255 (61.275Hz).
wire [8:0] HTOTAL = is_ik ? 9'd415 : 9'd511;
wire [8:0] HACT   = is_ik ? 9'd288 : 9'd400;
wire [8:0] HS0    = is_ik ? 9'd308 : 9'd424;
wire [8:0] HS1    = is_ik ? 9'd316 : 9'd464;
wire [8:0] VTOTAL = is_ik ? 9'd261 : is_chopper ? 9'd254 : is_16m ? 9'd255 : (VACT+VBLANK-9'd1);

localparam H_TOTAL  = 512;
localparam H_ACTIVE = 400;
localparam V_TOTAL  = 256;
localparam V_ACTIVE = 224;

reg  [8:0] H, V, hd1, vd1, rline;
reg        start;
reg display_flip_latched=0;
always @(posedge clk)begin
 if(rst)display_flip_latched<=0;
 else if(pxl_cen && H==HTOTAL && V==VTOTAL-9'd1)
  display_flip_latched<=DISPLAY_FLIP_ENABLE && display_flip;
end
// Reverse the visible coordinates, preserving physical line-buffer bank parity.
wire [8:0] draw_line=display_flip_latched ? (is_ik ? 9'd231 : 9'd223)-rline : rline;
always @(posedge clk) begin
    start <= 0;
    if( rst ) begin
        H <= 0; V <= 0; hd1 <= 0; vd1 <= 0; rline <= 1;
    end else if( pxl_cen ) begin
        hd1 <= H;   vd1 <= V;
        if( H == HTOTAL ) begin
            H <= 0;
            V <= V == VTOTAL ? 9'd0 : V + 9'd1;

            rline <= V == VTOTAL ? 9'd1 : (V == VTOTAL-9'd1 ? 9'd0 : V + 9'd2);

            start <= V >= VTOTAL-9'd1 || V < VACT-9'd2;
        end else H <= H + 9'd1;
    end
end

always @(posedge clk) if (rst) begin
    LHBL <= 0; LVBL <= 0; HS <= 0; VS <= 0;
end else if( pxl_cen ) begin

    LHBL <= hd1 < HACT;
    LVBL <= vd1 < VACT && (!is_ik || vd1 >= 9'd8);
    HS   <= hd1 >= HS0 && hd1 < HS1;
    if( hd1 == HS0 ) VS <= vd1 >= VS0 && vd1 < VS1;
end

wire [8:0] bg_baddr, tx_baddr, ob_baddr;
wire [7:0] bg_bdata;
wire [3:0] tx_bdata;
wire [9:0] ob_bdata;
wire       bg_bwe, tx_bwe, ob_bwe;

// Capture the completed software update before the vblank IRQ starts the
// next one. Gwar rewrites sprites in lines 224..255 and scroll in lines 0..2;
// a snapshot at the end of blanking mixes those epochs. Copy during line 223,
// after its render completed, then activate at first visible-line preparation.
// The live
// synchronous video port remains available to CPUs/front-check through their
// independent ports; only this renderer reads the frame copy. Register and
// sprite writes during scanout become visible together on the next frame.
wire context_start = pxl_cen && H == HTOTAL &&
                     V == VACT-9'd2;
wire frame_start = start && rline == (is_ik ? 9'd8 : 9'd0);
reg [8:0] bg_pending_x, bg_pending_y;
reg [8:0] sp16_pending_x, sp16_pending_y, sp32_pending_x, sp32_pending_y;
reg [7:0] split_pending, txbank_pending;
reg flip_pending;
reg [8:0] bg_frame_x, bg_frame_y;
reg [8:0] sp16_frame_x, sp16_frame_y, sp32_frame_x, sp32_frame_y;
reg [7:0] split_frame, txbank_frame;
reg flip_frame;
reg snapshot_busy, snapshot_valid;
reg [6:0] snapshot_addr;
reg [1:0] snapshot_phase;
wire [6:0] obj_ram_addr;
reg [31:0] obj_ram_data;
(* ramstyle = "M10K" *) reg [31:0] sprite_frame[0:127];
assign vspr_addr = snapshot_addr;
always @(posedge clk) begin
    obj_ram_data <= sprite_frame[obj_ram_addr];
    if (snapshot_busy && snapshot_phase == 2'd2)
        sprite_frame[snapshot_addr] <= vspr_data;
end
always @(posedge clk) begin
    if (rst) begin
        bg_pending_x <= 0; bg_pending_y <= 0;
        sp16_pending_x <= 0; sp16_pending_y <= 0;
        sp32_pending_x <= 0; sp32_pending_y <= 0;
        split_pending <= 0; txbank_pending <= 0; flip_pending <= 0;
        snapshot_busy <= 0; snapshot_valid <= 0;
        snapshot_addr <= 0; snapshot_phase <= 0;
    end else if (context_start) begin
        bg_pending_x <= bg_scrollx; bg_pending_y <= bg_scrolly;
        sp16_pending_x <= sp16_scrollx; sp16_pending_y <= sp16_scrolly;
        sp32_pending_x <= sp32_scrollx; sp32_pending_y <= sp32_scrolly;
        split_pending <= split; txbank_pending <= txbank; flip_pending <= flip;
        snapshot_busy <= 1; snapshot_valid <= 0;
        snapshot_addr <= 0; snapshot_phase <= 0;
    end else if (snapshot_busy) begin
        if (snapshot_phase == 2'd2) begin
            snapshot_phase <= 0;
            if (snapshot_addr == 7'd127) begin
                snapshot_busy <= 0; snapshot_valid <= 1;
            end else snapshot_addr <= snapshot_addr + 7'd1;
        end else snapshot_phase <= snapshot_phase + 2'd1;
    end
end
always @(posedge clk) begin
    if (rst) begin
        bg_frame_x <= 0; bg_frame_y <= 0;
        sp16_frame_x <= 0; sp16_frame_y <= 0;
        sp32_frame_x <= 0; sp32_frame_y <= 0;
        split_frame <= 0; txbank_frame <= 0; flip_frame <= 0;
    end else if (frame_start) begin
        bg_frame_x <= bg_pending_x; bg_frame_y <= bg_pending_y;
        sp16_frame_x <= sp16_pending_x; sp16_frame_y <= sp16_pending_y;
        sp32_frame_x <= sp32_pending_x; sp32_frame_y <= sp32_pending_y;
        split_frame <= split_pending; txbank_frame <= txbank_pending; flip_frame <= flip_pending;
    end
end
wire [8:0] bg_draw_x = frame_start ? bg_pending_x : bg_frame_x;
wire [8:0] bg_draw_y = frame_start ? bg_pending_y : bg_frame_y;
wire [8:0] sp16_draw_x = frame_start ? sp16_pending_x : sp16_frame_x;
wire [8:0] sp16_draw_y = frame_start ? sp16_pending_y : sp16_frame_y;
wire [8:0] sp32_draw_x = frame_start ? sp32_pending_x : sp32_frame_x;
wire [8:0] sp32_draw_y = frame_start ? sp32_pending_y : sp32_frame_y;
wire [7:0] split_draw = frame_start ? split_pending : split_frame;
wire [7:0] txbank_draw = frame_start ? txbank_pending : txbank_frame;
wire flip_draw = frame_start ? flip_pending : flip_frame;

snk_union_bg u_bg(
    .tile_count(bg_tile_count), .ik(is_ik),
    .rst      ( rst        ), .clk( clk ), .start( start ), .line( draw_line ), .flip( flip_draw ),
    .scrollx  ( bg_draw_x ), .scrolly( bg_draw_y ), .busy(render_busy[0]),
    .vram_addr( vbg_addr   ), .vram_data( vbg_data ),
    .rom_addr ( bgrom_addr ), .rom_cs( bgrom_cs ), .rom_data( bgrom_data ), .rom_ok( bgrom_ok ),
    .buf_addr ( bg_baddr   ), .buf_data( bg_bdata ), .buf_we( bg_bwe )
);

// big_sp16 identifies the Guerrilla War profile in the shared board. Its
// sub CPU clears and redraws the HUD in separate writes. Read one completed
// text map for the frame, alongside the matching text bank and sprite context.
wire text_snapshot = big_sp16 && !is_ik && !is_sports;
wire [10:0] tx_render_addr;
reg [7:0] tx_frame_data;
(* ramstyle = "M10K" *) reg [7:0] text_frame[0:2047];
reg tx_copy_active, tx_copy_valid, tx_frame_valid;
reg [10:0] tx_copy_addr, tx_copy_return;
assign vtx_addr = text_snapshot && tx_copy_active ? tx_copy_addr : tx_render_addr;
always @(posedge clk) begin
    tx_frame_data <= text_frame[tx_render_addr];
    // The shared video port returns the address sampled on the preceding
    // rising edge. Carry that address/valid with the response, including drain.
    if (tx_copy_valid) text_frame[tx_copy_return] <= vtx_data;
    if (rst) begin
        tx_copy_active <= 0; tx_copy_valid <= 0; tx_frame_valid <= 0;
        tx_copy_addr <= 0; tx_copy_return <= 0;
    end else begin
        tx_copy_valid <= tx_copy_active;
        tx_copy_return <= tx_copy_addr;
        if (context_start && text_snapshot) begin
            tx_copy_active <= 1; tx_copy_addr <= 0; tx_frame_valid <= 0;
        end else if (tx_copy_active) begin
            if (tx_copy_addr == 11'd2047) tx_copy_active <= 0;
            else tx_copy_addr <= tx_copy_addr + 11'd1;
        end
        if (tx_copy_valid && tx_copy_return == 11'd2047) tx_frame_valid <= 1;
    end
end
wire [7:0] tx_render_data = text_snapshot ?
    (tx_frame_valid ? tx_frame_data : 8'h20) : vtx_data;

snk_psychos_tx u_tx(
    .ik(is_ik),
    .rst      ( rst        ), .clk( clk ), .start( start ), .line( draw_line ), .flip( flip_draw ),
    .bank     ( txbank_draw[5:4] ), .busy(render_busy[1]),
    .vram_addr( tx_render_addr ), .vram_data( tx_render_data ),
    .rom_addr ( txrom_addr ), .rom_data( txrom_data ),
    .buf_addr ( tx_baddr   ), .buf_data( tx_bdata ), .buf_we( tx_bwe )
);

wire [17:2] s16rom_raw_addr;
assign s16rom_addr = big_sp16 ? s16rom_raw_addr : {1'b0, s16rom_raw_addr[16:2]};
always @(posedge clk) begin
    if (rst) line_overrun <= 3'b000;
    else if (start) line_overrun <= line_overrun | render_busy;
end

snk_union_obj u_obj(
    .sports_mode(is_sports), .ik(is_ik),
    .rst      ( rst        ), .clk( clk ), .start( start && snapshot_valid && !snapshot_busy ), .line( draw_line ), .flip( flip_draw ),
    .sp16_scrollx( sp16_draw_x ), .sp16_scrolly( sp16_draw_y ),
    .sp32_scrollx( sp32_draw_x ), .sp32_scrolly( sp32_draw_y ),
    .split    ( split_draw ), .busy(render_busy[2]),
    .ram_addr ( obj_ram_addr ), .ram_data( obj_ram_data ),
    .s16_addr ( s16rom_raw_addr), .s16_cs( s16rom_cs ), .s16_data( s16rom_data ), .s16_ok( s16rom_ok ),
    .s32_addr ( s32rom_addr), .s32_cs( s32rom_cs ), .s32_data( s32rom_data ), .s32_ok( s32rom_ok ),
    .blank_en ( blank_en   ), .op16_addr( op16_addr ), .op16( op16 ), .op32_addr( op32_addr ), .op32( op32 ),
    .buf_addr ( ob_baddr   ), .buf_data( ob_bdata ), .buf_we( ob_bwe ),
    .cycles   ( obj_cycles )
);

reg  [2:0] ph;
reg  [9:0] rd_addr;
reg        ob_clr;
wire [7:0] bg_q;
wire [3:0] tx_q;
wire [9:0] ob_q;
wire       wh = rline[0];

snk_psychos_dual_ram #(.DW(8), .AW(10)) u_bgbuf(
    .clk0( clk ), .data0( bg_bdata ), .addr0( { wh, bg_baddr } ), .we0( bg_bwe ), .q0(),
    .clk1( clk ), .data1( 8'd0 ), .addr1( rd_addr ), .we1( 1'b0 ), .q1( bg_q ) );

snk_psychos_dual_ram #(.DW(4), .AW(10)) u_txbuf(
    .clk0( clk ), .data0( tx_bdata ), .addr0( { wh, tx_baddr } ), .we0( tx_bwe ), .q0(),
    .clk1( clk ), .data1( 4'd0 ), .addr1( rd_addr ), .we1( 1'b0 ), .q1( tx_q ) );

snk_union_object_buffer u_objbuf(
    .sports_mode(is_sports),
    .clk0( clk ), .data0( ob_bdata ), .addr0( { wh, ob_baddr } ), .we0( ob_bwe ), .q0(),
    .clk1( clk ), .data1( 10'd0 ), .addr1( rd_addr ), .we1( ob_clr ), .q1( ob_q ) );

reg  [9:0] idx;
wire       tx_opaque = is_ik && (rd_addr[8:0] < 9'd16 || rd_addr[8:0] >= 9'd272);
reg  [3:0] txpal;
assign pal_addr = idx;

function [7:0] lut( input [3:0] v );
    lut = (v[0] ? 8'h0e : 8'h00) + (v[1] ? 8'h1f : 8'h00) + (v[2] ? 8'h43 : 8'h00) + (v[3] ? 8'h8f : 8'h00);
endfunction

reg [7:0] rn, gn, bn;
always @(posedge clk) begin
    ob_clr <= 0;
    if (rst) begin
        ph <= 0; rd_addr <= 0; txpal <= 0; idx <= 0;
        rn <= 0; gn <= 0; bn <= 0;
        red <= 0; green <= 0; blue <= 0;
    end else if( pxl_cen ) begin
        ph      <= 3'd1;
        rd_addr <= { V[0], (display_flip_latched && H<HACT) ? (HACT-9'd1)-H : H };
        txpal   <= txbank_frame[3:0];
        red <= rn; green <= gn; blue <= bn;
    end else if( ph != 0 ) begin
        ph <= ph == 3'd5 ? 3'd0 : ph + 3'd1;
        case( ph )
            3'd2: begin
                // ikari palette (snk.cpp gfx_ikari): sp16 0x000+c*8+p, sp32 0x080+c*8+p, bg 0x100+c*16+p, tx 0x180(+16)+p, shadow = idx|0x200
                // ikari tx: tile_index>=0x400 (outer columns 0,1 / 34,35) carries TILE_FORCE_LAYER0 = opaque, pen 15 is drawn
                if( (tx_q != 4'hF || tx_opaque) && gfx_en[2] )      idx <= is_ik ? { 2'b01, 3'b100, txpal[0], tx_q } : { 2'b00, txpal, tx_q };
                else if( ob_q[9] && gfx_en[1] && (!(is_sports||is_ik)||ob_q[3:0]!=4'he) ) idx <= is_ik ? { 2'b00, ob_q[8], ob_q[7:4], ob_q[2:0] } : is_sports ? {2'b01,ob_q[7:0]} : { ob_q[8] ? 2'b10 : 2'b01, ob_q[7:0] };
                else if( gfx_en[0] ) idx <= is_ik ? { (ob_q[9]&&gfx_en[1]&&ob_q[3:0]==4'he) ? 2'b11:2'b01, 1'b0, bg_q[6:0] } : is_sports ? { (ob_q[9]&&gfx_en[1]&&ob_q[3:0]==4'he) ? 2'b11:2'b10, bg_q } : (is_psychos ? { 2'b11, txbank_frame[7], bg_q[6:0] } : { 2'b11, bg_q });
                else                                 idx <= 10'h3FF;
                ob_clr <= 1;
            end
            3'd4: begin
                rn <= lut( palr ); gn <= lut( palg ); bn <= lut( palb );
            end
            default:;
        endcase
    end
end

endmodule
