// SPDX-License-Identifier: GPL-3.0-only
// Derived from pinned jlrh/snk-fpga; see PROVENANCE.md.
module snk_psychos_video #(parameter DISPLAY_FLIP_ENABLE=0)(
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

    output     [17:2] bgrom_addr,
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

localparam [8:0] HTOTAL=9'd511, HACT=9'd400, HS0=9'd440, HS1=9'd480;
localparam [8:0] VTOTAL=9'd263, VACT=9'd224, VS0=9'd236, VS1=9'd239;

localparam H_TOTAL  = 512;
localparam H_ACTIVE = 400;
localparam V_TOTAL  = 264;
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
wire [8:0] draw_line=display_flip_latched ? 9'd223-rline : rline;
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
    LVBL <= vd1 < VACT;
    HS   <= hd1 >= HS0 && hd1 < HS1;
    if( hd1 == HS0 ) VS <= vd1 >= VS0 && vd1 < VS1;
end

wire [8:0] bg_baddr, tx_baddr, ob_baddr;
wire [7:0] bg_bdata;
wire [3:0] tx_bdata;
wire [9:0] ob_bdata;
wire       bg_bwe, tx_bwe, ob_bwe;

snk_psychos_bg u_bg(
    .rst      ( rst        ), .clk( clk ), .start( start ), .line( draw_line ), .flip( flip ),
    .scrollx  ( bg_scrollx ), .scrolly( bg_scrolly ), .busy(render_busy[0]),
    .vram_addr( vbg_addr   ), .vram_data( vbg_data ),
    .rom_addr ( bgrom_addr ), .rom_cs( bgrom_cs ), .rom_data( bgrom_data ), .rom_ok( bgrom_ok ),
    .buf_addr ( bg_baddr   ), .buf_data( bg_bdata ), .buf_we( bg_bwe )
);

snk_psychos_tx u_tx(
    .ik(1'b0),
    .rst      ( rst        ), .clk( clk ), .start( start ), .line( draw_line ), .flip( flip ),
    .bank     ( txbank[5:4] ), .busy(render_busy[1]),
    .vram_addr( vtx_addr   ), .vram_data( vtx_data ),
    .rom_addr ( txrom_addr ), .rom_data( txrom_data ),
    .buf_addr ( tx_baddr   ), .buf_data( tx_bdata ), .buf_we( tx_bwe )
);

wire [17:2] s16rom_raw_addr;
assign s16rom_addr = {1'b0, s16rom_raw_addr[16:2]};
always @(posedge clk) begin
    if (rst) line_overrun <= 3'b000;
    else if (start) line_overrun <= line_overrun | render_busy;
end

snk_psychos_obj u_obj(
    .rst      ( rst        ), .clk( clk ), .start( start ), .line( draw_line ), .flip( flip ),
    .sp16_scrollx( sp16_scrollx ), .sp16_scrolly( sp16_scrolly ),
    .sp32_scrollx( sp32_scrollx ), .sp32_scrolly( sp32_scrolly ),
    .split    ( split      ), .busy(render_busy[2]),
    .ram_addr ( vspr_addr  ), .ram_data( vspr_data ),
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

snk_psychos_dual_ram #(.DW(10), .AW(10)) u_objbuf(
    .clk0( clk ), .data0( ob_bdata ), .addr0( { wh, ob_baddr } ), .we0( ob_bwe ), .q0(),
    .clk1( clk ), .data1( 10'd0 ), .addr1( rd_addr ), .we1( ob_clr ), .q1( ob_q ) );

reg  [9:0] idx;
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
        rd_addr <= { V[0], (display_flip_latched && H<HACT) ? 9'd399-H : H };
        txpal   <= txbank[3:0];
        red <= rn; green <= gn; blue <= bn;
    end else if( ph != 0 ) begin
        ph <= ph == 3'd5 ? 3'd0 : ph + 3'd1;
        case( ph )
            3'd2: begin
                if( tx_q != 4'hF && gfx_en[2] )      idx <= { 2'b00, txpal, tx_q };
                else if( ob_q[9] && gfx_en[1] )      idx <= { ob_q[8] ? 2'b10 : 2'b01, ob_q[7:0] };
                else if( gfx_en[0] )                 idx <= { 2'b11, txbank[7], bg_q[6:0] };
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
