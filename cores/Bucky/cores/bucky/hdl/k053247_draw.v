// ─────────────────────────────────────────────────────────────────────────────────────────────
// FORK COWBOYS del dibujante de sprites (rol del 053247). Origen: modules/jtframe/hdl/video/jtframe_draw.v
// Clonado 2026-07-20 (ses.27).
//
// PASO 3 (ses.28): PREFETCH PIPELINE para OCULTAR LA LATENCIA de la SDRAM de MiSTer. El corte del vagón en
// PLACA NO era write-rate (el 2px/clk lo arregló solo con BW infinita) sino LATENCIA de las 2 lecturas de
// 32-bit por tile (bus lyro single-outstanding). Medido: 14198@CLKDIV6 OBJ_LAT=4 -> 120 líneas cortadas.
// Ver memoria cowboys-sprites-cuello-latencia-no-writerate.
//
// Estructura: DOS etapas concurrentes.
//   FETCH: al recibir un tile del scan, lee word0+word1 de ROM y los pre-ensambla en un reg de 64 bits
//          (16 px). `busy` (al scan) = etapa FETCH ocupada -> el scan adelanta el tile N+1 mientras DRAW
//          pinta el N => la latencia de leer N+1 se solapa con dibujar N.
//   DRAW:  dibuja desde el reg pre-ensamblado (SIN esperar rom_ok). Lógica de píxel IDÉNTICA al 2px/clk
//          previo (pixel bajo por puerto A, alto por B a buf_addr+1 cuando no_zoom) => bit-exacto,
//          movimiento sigue 0.2604%. La placa original no prefetchea (mask ROM paralelas, latencia ~0);
//          esto es compensación de la SDRAM de MiSTer.
//
// jtframe NO se toca. Validar SIEMPRE con OBJ_LAT>0 (14198) + movimiento (run_vseq 4000 16).
// ─────────────────────────────────────────────────────────────────────────────────────────────
/*  This file is part of JTFRAME.
    JTFRAME program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTFRAME program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTFRAME.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate */

// Draws one line of a 16x16 tile
module k053247_draw#( parameter
    AW       =  9,
    CW       = 12,
    PW       =  8,
    ZW       =  6,
    ZI       =  ZW-1,
    ZENLARGE =  0,
    SWAPH    =  0,
    KEEP_OLD =  0
)(
    input               rst,
    input               clk,

    input               draw,
    output              busy,
    output              draw_busy,
    input    [CW-1:0]   code,
    input    [AW-1:0]   xpos,
    input      [ 3:0]   ysub,
    input      [ 1:0]   trunc, // cowboys: siempre 0 (16 px)

    input    [ZW-1:0]   hzoom,
    input               hz_keep,
    input               hflip,
    input               vflip,
    input      [PW-5:0] pal,

    output reg [CW+6:2] rom_addr, // HVVVV format
    output reg          rom_cs,
    input               rom_ok,
    input      [31:0]   rom_data, // (ya viene "sorted" desde cowboys_obj)

    output reg [AW-1:0] buf_addr,
    output              buf_we,
    output     [PW-1:0] buf_din,
    output     [AW-1:0] buf_addr2,
    output              buf_we2,
    output     [PW-1:0] buf_din2,
    // ── 4 px/clk (ses.30): puertos C y D. Con zoom o !FOURPX caen a we3/we4=0. ──
    output     [AW-1:0] buf_addr3,
    output              buf_we3,
    output     [PW-1:0] buf_din3,
    output     [AW-1:0] buf_addr4,
    output              buf_we4,
    output     [PW-1:0] buf_din4
);

localparam [ZW-1:0] HZONE = { {ZW-1{1'b0}},1'b1} << ZI;

// ── ETAPA FETCH: pre-ensambla los 64 bits (2 lecturas) de un tile ──────────────────────────────
localparam [1:0] F_IDLE=0, F_RD0=1, F_RD1=2, F_HOLD=3;
reg  [1:0]  f_st;
reg  [63:0] pre_data;
reg         f_lsb;
// parametros del tile en fetch (se acarrean a draw en el handoff)
reg [CW-1:0] fc_code;
reg [ 3:0]   fc_ysub;
reg [AW-1:0] fc_xpos;
reg [ZW-1:0] fc_hzoom;
reg [PW-5:0] fc_pal;
reg          fc_hflip, fc_vflip, fc_hzkeep, fc_nozoom;

wire [3:0] fc_ysubf = fc_ysub ^ {4{fc_vflip}};
wire       fc_nz    = hzoom==HZONE || hzoom==0;

assign busy = f_st!=F_IDLE;   // al scan: FETCH ocupado (draw puede seguir pintando el tile anterior)
assign draw_busy = d_busy;     // ownership guard: actual line-buffer writer is active

// ── ETAPA DRAW: dibuja desde pre_data (sin esperar ROM) ────────────────────────────────────────
reg  [63:0] d_data;
reg [AW-1:0] d_xpos;
reg [ZW-1:0] d_hzoom;
reg [PW-5:0] d_pal;
reg          d_hflip, d_hzkeep, d_nozoom;
reg          d_go;
reg          d_busy;
reg  [31:0]  pxl_data;    // ventana de 8 px en curso
reg  [ 3:0]  cnt;
reg          dw_sel;      // 0=word0, 1=word1  (proxima recarga)
reg          second;      // dibujando el 2o word (=ultimo)
reg [ZW-1:0] hz_cnt, nx_hz;
reg          moveon, readon;
wire [ZW-1:ZI] hzint = hz_cnt[ZW-1:ZI];
wire         four_px = d_nozoom;    // no_zoom -> 4 px/clk (ses.30); con zoom cae a 1 px/clk
wire [3:0]   pxl, pxl_hi, pxl_c, pxl_d;

// pixel i del tile = bits [i, 8+i, 16+i, 24+i] de pxl_data (4 planos intercalados). hflip -> desde arriba.
assign pxl    = d_hflip ? {pxl_data[31],pxl_data[23],pxl_data[15],pxl_data[ 7]}
                        : {pxl_data[24],pxl_data[16],pxl_data[ 8],pxl_data[ 0]};
assign pxl_hi = d_hflip ? {pxl_data[30],pxl_data[22],pxl_data[14],pxl_data[ 6]}
                        : {pxl_data[25],pxl_data[17],pxl_data[ 9],pxl_data[ 1]};
assign pxl_c  = d_hflip ? {pxl_data[29],pxl_data[21],pxl_data[13],pxl_data[ 5]}
                        : {pxl_data[26],pxl_data[18],pxl_data[10],pxl_data[ 2]};
assign pxl_d  = d_hflip ? {pxl_data[28],pxl_data[20],pxl_data[12],pxl_data[ 4]}
                        : {pxl_data[27],pxl_data[19],pxl_data[11],pxl_data[ 3]};
assign buf_din   = { d_pal, pxl };
assign buf_din2  = { d_pal, pxl_hi };
assign buf_din3  = { d_pal, pxl_c };
assign buf_din4  = { d_pal, pxl_d };
assign buf_we    = d_busy & ~cnt[3];
assign buf_we2   = d_busy & ~cnt[3] & four_px & readon;   // 2o px: en 4px SIEMPRE, como el 2px antiguo
assign buf_we3   = d_busy & ~cnt[3] & four_px & readon;
assign buf_we4   = d_busy & ~cnt[3] & four_px & readon;
assign buf_addr2 = buf_addr + 10'd1;
assign buf_addr3 = buf_addr + 10'd2;
assign buf_addr4 = buf_addr + 10'd3;

always @* begin
    if( ZENLARGE==1 ) begin
        readon = hzint >= 1;
        moveon = hzint <= 1;
        nx_hz  = readon ? hz_cnt - HZONE : hz_cnt;
        if( moveon   ) nx_hz = nx_hz + d_hzoom;
        if( d_nozoom ) {moveon, readon} = 2'b11;
    end else begin
        readon = 1;
        { moveon, nx_hz } = {1'b1, hz_cnt}-{1'b0,d_hzoom};
    end
end

wire handoff = f_st==F_HOLD && !d_busy;

always @(posedge clk) begin
    if( rst ) begin
        f_st<=F_IDLE; rom_cs<=0; f_lsb<=0; pre_data<=0;
        d_go<=0; d_busy<=0; cnt<=0; buf_addr<=0; pxl_data<=0; hz_cnt<=0;
        dw_sel<=0; second<=0;
    end else begin
        d_go <= 0;
        // ── FETCH FSM ──
        case( f_st )
            F_IDLE: if( draw ) begin
                fc_code<=code; fc_ysub<=ysub; fc_vflip<=vflip; fc_hflip<=hflip;
                fc_xpos<=xpos; fc_hzoom<=hzoom; fc_hzkeep<=hz_keep; fc_pal<=pal; fc_nozoom<=fc_nz;
                f_lsb  <= hflip;
                rom_cs <= 1;
                f_st   <= F_RD0;
            end
            F_RD0: if( rom_ok ) begin
                pre_data[31:0] <= rom_data;
                f_lsb          <= ~fc_hflip;   // segunda lectura
                f_st           <= F_RD1;
            end
            F_RD1: if( rom_ok ) begin
                pre_data[63:32] <= rom_data;
                rom_cs          <= 0;
                f_st            <= F_HOLD;
            end
            F_HOLD: if( !d_busy ) begin       // handoff cuando DRAW esta libre
                f_st <= F_IDLE;
            end
        endcase

        // ── handoff FETCH -> DRAW (arranca el dibujo del tile pre-ensamblado) ──
        if( handoff ) begin
            d_data   <= pre_data;
            d_xpos   <= fc_xpos; d_hzoom<=fc_hzoom; d_pal<=fc_pal;
            d_hflip  <= fc_hflip; d_hzkeep<=fc_hzkeep; d_nozoom<=fc_nozoom;
            d_go     <= 1'b1;
        end

        // ── DRAW FSM ──
        if( !d_busy ) begin
            if( d_go ) begin
                d_busy <= 1; cnt <= 8; dw_sel <= 0; second <= 0;
                if( !d_hzkeep ) begin hz_cnt <= HZONE>>1; buf_addr <= d_xpos; end
            end
        end else begin
            if( cnt[3] ) begin                 // recarga la ventana de 8 px (sin espera de ROM)
                pxl_data <= dw_sel ? d_data[63:32] : d_data[31:0];
                cnt[3]   <= 0;
                second   <= dw_sel;            // dw_sel=0 -> word0 (no ultimo); =1 -> word1 (ultimo)
                dw_sel   <= 1;
            end
            if( !cnt[3] ) begin
                hz_cnt <= nx_hz;
                if( readon ) begin
                    cnt      <= cnt + (four_px ? 4'd4 : 4'd1);
                    pxl_data <= d_hflip ? (four_px ? pxl_data<<4 : pxl_data<<1)
                                        : (four_px ? pxl_data>>4 : pxl_data>>1);
                end
                if( moveon ) buf_addr <= buf_addr + (four_px ? 10'd4 : 10'd1);
                if( readon && second &&
                    ( four_px ? cnt[2:0]==4 : cnt[2:0]==7 ) ) begin
                    d_busy <= 0; // 16 px dibujados
                end
            end
        end
    end
end

// direccion de ROM (etapa fetch)
always @* rom_addr = { fc_code, f_lsb^SWAPH[0], fc_ysubf };

endmodule
