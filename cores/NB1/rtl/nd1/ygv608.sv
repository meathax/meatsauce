//------------------------------------------------------------------------------
// Yamaha YGV608 pattern VDP for the Namco ND-1 core: the 68000 port/register
// interface, the built-in tables, the raster timing and the palette output,
// around the line renderer in ygv608_render.sv. Semantics follow MAME's
// ygv608.cpp as documented in docs/ygv608.md; ROZ, mosaic and ROM DMA are not
// implemented and raise `unsupported` when enabled.
//
// Raster (docs/core-design.md section 4): 414 dots x 258 lines at cen_pix,
// visible 288 x 224 from dot 54, line 26. Line y is rendered during raster
// line 25 + y and scanned out on line 26 + y. FV (vblank) is set at dot 0
// of line 250; FP (raster) where R#15/16 point.
//------------------------------------------------------------------------------
`default_nettype none

module ygv608 (
    input  logic        clk,            // 96 MHz
    input  logic        reset,
    input  logic        cen_pix,        // 6.4 MHz dot clock enable (96/15)
    // 68000 side: the 8 ports at 0x800000-0x80000F, one byte each
    input  logic  [2:0] port_sel,
    input  logic        port_wr,
    input  logic        port_rd,
    input  logic  [7:0] port_wdata,
    output logic  [7:0] port_q,
    // gfx bank from the cuskey
    input  logic  [1:0] gfxbank,
    // MiSTer (not in the donor): rotate the whole raster 180 degrees - line 223-y is
    // rendered for display line y and the line buffer is read right to left.
    // Sampled at vblank start so a frame never changes orientation half way.
    input  logic        screen_flip,
    // pattern ROM port: 32-bit fetch of 4 consecutive bytes of the 8 MB pattern space
    output logic        pat_req,
    output logic [20:0] pat_addr,
    output logic  [6:0] pat_len,        // units in the request (1, or a whole tile for ROZ)
    input  logic        pat_wr,         // one unit delivered (pat_q, pat_idx)
    input  logic  [5:0] pat_idx,
    input  logic        pat_ack,        // after the last unit
    input  logic [31:0] pat_q,
    // video out
    output logic        hsync, vsync, hblank, vblank, de,
    output logic  [7:0] r, g, b,
    // interrupts
    output logic        irq_vblank,
    output logic        irq_raster,
    output logic        unsupported,
    output logic  [3:0] unsup_src       // {ROM DMA, ROZ case not as MAME, mosaic, render overrun}
);
    // ------------------------------------------------------------ registers
    logic  [5:0] ytile_ptr, xtile_ptr;
    logic        ytile_autoinc, xtile_autoinc, plane_select_access;
    logic        saar, saaw, scar, scaw, ba_plane_scroll_select, cpar, cpaw;
    logic  [7:0] sprite_address, scroll_address, palette_address, sprite_bank;
    logic        dckm, flip, zron, dspe;
    logic  [1:0] md;
    logic  [1:0] h_display_size, v_display_size;
    logic        roz_wrap_disable, scroll_wrap_disable, page_size;
    logic  [1:0] pattern_size;
    logic  [2:0] h_div_size, v_div_size;
    logic  [1:0] sprite_aux_reg;
    logic        sprite_aux_mode, sprite_disable;
    logic  [1:0] mosaic_a, mosaic_b;
    logic  [1:0] scm;
    logic        yse, cbdr;
    logic  [1:0] priority_mode;
    logic        planeB_trans, planeA_trans;
    logic  [1:0] sprite_color_fetch;
    logic  [2:0] planeB_color_fetch, planeA_color_fetch;
    logic  [7:0] border_color;
    logic        vblank_irq_mask, raster_irq_mask;
    logic  [8:0] raster_irq_vpos;
    logic  [4:0] raster_irq_hpos;      // x32
    logic        raster_irq_mode;
    logic [47:0] base_addr;            // plane*24 + entry*3
    logic  [7:0] crtc [8];             // R#39..46 raw
    logic  [7:0] roz_raw [14];         // R#25..38 raw
    // MAME roz_convert_raw24/16: 21 or 13 significant bits, << 7, sign-extended from bit 27 or 19
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [31:0] roz24(input logic [7:0] b0, input logic [7:0] b1, input logic [7:0] b2);
        roz24 = {{4{b2[4]}}, b2[4:0], b1, b0, 7'd0};
    endfunction
    function automatic logic [31:0] roz16(input logic [7:0] b0, input logic [7:0] b1);
        roz16 = {{12{b1[4]}}, b1[4:0], b0, 7'd0};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] roz_ax  = roz24(roz_raw[0], roz_raw[1], roz_raw[2]);
    wire [31:0] roz_dx  = roz16(roz_raw[3], roz_raw[4]);
    wire [31:0] roz_dxy = roz16(roz_raw[5], roz_raw[6]);
    wire [31:0] roz_ay  = roz24(roz_raw[7], roz_raw[8], roz_raw[9]);
    wire [31:0] roz_dy  = roz16(roz_raw[10], roz_raw[11]);
    wire [31:0] roz_dyx = roz16(roz_raw[12], roz_raw[13]);
    logic       roz_unsup;
    logic  [5:0] register_address;
    logic        register_autoinc_r, register_autoinc_w;
    logic  [7:0] screen_status;        // bits 4:2 = FP FV FC
    logic  [7:0] dma_status;
    logic  [1:0] p0_state;
    logic        pn_base_r_b, pn_base_w_b;   // "read/write pattern name base is plane B"
    logic  [1:0] color_state_r, color_state_w;
    logic        unsupported_sticky;

    // derived
    wire  [6:0] page_x = (md == 2'd1) ? 7'd32 : (page_size ? 7'd32 : 7'd64);
    wire  [6:0] page_y = (md == 2'd1) ? 7'd32 : (page_size ? 7'd64 : 7'd32);
    wire  [2:0] pny_shift = (page_x == 7'd32) ? 3'd5 : 3'd6;
    wire        bits16 = (md != 2'd0);
    wire        one_plane = md[1];
    logic [3:0] col_shift;
    always_comb begin
        // MAME screen_ctrl_9_w: shift in the scroll table column index
        logic [3:0] cs;
        if (v_div_size == 3'd0) cs = 4'd8;
        else begin
            cs = (pattern_size == 2'd0) ? ({1'b0, v_div_size} - 4'd4) : ({1'b0, v_div_size} - 4'd5);
            if (cs[3]) cs = 4'd8;          // negative: "unhandled slv condition" -> 8
        end
        col_shift = cs;
    end

    // ------------------------------------------------------------ raster
    logic  [8:0] dot;        // 0..413
    logic  [8:0] line;       // 0..257
    wire         visible_h = (dot >= 9'd54) && (dot < 9'd342);
    wire         visible_v = (line >= 9'd26) && (line < 9'd250);
    logic        render_start;
    logic        flip_f = 1'b0;     // screen_flip for the current frame
    logic  [7:0] render_y;

    // ------------------------------------------------------------ tables
    // pattern name table: 2048 x 16 (even byte in [15:8]), byte-enabled writes
    (* ramstyle = "no_rw_check" *) logic [1:0][7:0] pnt [2048];
    logic [10:0] pnt_waddr, pnt_cpu_raddr, pnt_rend_raddr;
    logic  [1:0] pnt_be;
    logic  [7:0] pnt_wbyte;
    logic [15:0] pnt_cpu_q, pnt_rend_q;
    // sprite attribute table: 64 x 32, byte lanes
    (* ramstyle = "no_rw_check" *) logic [3:0][7:0] sat [64];
    logic  [5:0] sat_waddr, sat_cpu_raddr, sat_rend_raddr;
    logic  [3:0] sat_be;
    logic  [7:0] sat_wbyte;
    logic [31:0] sat_cpu_q, sat_rend_q;
    // scroll tables: 512 x 8
    (* ramstyle = "no_rw_check" *) logic [7:0] sdt [512];
    logic  [8:0] sdt_waddr, sdt_cpu_raddr, sdt_rend_raddr;
    logic        sdt_we;
    logic  [7:0] sdt_wbyte, sdt_cpu_q, sdt_rend_q;
    // palette: 256 x 3 bytes, byte lanes
    (* ramstyle = "no_rw_check" *) logic [2:0][7:0] pal [256];
    logic  [7:0] pal_waddr, pal_cpu_raddr, pal_out_raddr;
    logic  [2:0] pal_be;
    logic  [7:0] pal_wbyte;
    logic [23:0] pal_cpu_q, pal_out_q;

    // the table writer: CPU port writes, or the reset sweep
    logic        clearing;
    logic [10:0] clear_addr;

    always_ff @(posedge clk) begin
        if (pnt_be[0]) pnt[pnt_waddr][0] <= pnt_wbyte;
        if (pnt_be[1]) pnt[pnt_waddr][1] <= pnt_wbyte;
        pnt_cpu_q  <= pnt[pnt_cpu_raddr];
    end
    always_ff @(posedge clk) pnt_rend_q <= pnt[pnt_rend_raddr];
    always_ff @(posedge clk) begin
        for (int i = 0; i < 4; i++) if (sat_be[i]) sat[sat_waddr][i] <= sat_wbyte;
        sat_cpu_q <= sat[sat_cpu_raddr];
    end
    always_ff @(posedge clk) sat_rend_q <= sat[sat_rend_raddr];
    always_ff @(posedge clk) begin
        if (sdt_we) sdt[sdt_waddr] <= sdt_wbyte;
        sdt_cpu_q <= sdt[sdt_cpu_raddr];
    end
    always_ff @(posedge clk) sdt_rend_q <= sdt[sdt_rend_raddr];
    always_ff @(posedge clk) begin
        for (int i = 0; i < 3; i++) if (pal_be[i]) pal[pal_waddr][i] <= pal_wbyte;
        pal_cpu_q <= pal[pal_cpu_raddr];
    end
    always_ff @(posedge clk) pal_out_q <= pal[pal_out_raddr];

    // ------------------------------------------------------------ pattern name pointer helpers
    // byte index of the cell the P#0 pointers select (MAME pattern_name_table_r/w)
    function automatic logic [12:0] p0_index(input logic use_b);
        logic [12:0] i;
        i = ({7'd0, ytile_ptr} << pny_shift) + {7'd0, xtile_ptr};
        if (bits16) i = {i[11:0], 1'b0};
        if (use_b) i = i + (({6'd0, page_y} << pny_shift) << (bits16 ? 1 : 0));
        p0_index = i;
    endfunction

    // register read-back (R#0..16 live, others 0)
    function automatic logic [7:0] reg_read(input logic [5:0] rn);
        case (rn)
        6'd0:  reg_read = {ytile_autoinc, plane_select_access, ytile_ptr};
        6'd1:  reg_read = {xtile_autoinc, 1'b0, xtile_ptr};
        6'd2:  reg_read = {cpaw, cpar, 1'b0, ba_plane_scroll_select, scaw, scar, saaw, saar};
        6'd3:  reg_read = sprite_address;
        6'd4:  reg_read = scroll_address;
        6'd5:  reg_read = palette_address;
        6'd6:  reg_read = sprite_bank;
        6'd7:  reg_read = {dckm, flip, 2'b00, zron, md, dspe};
        6'd8:  reg_read = {h_display_size, v_display_size, roz_wrap_disable, scroll_wrap_disable, 1'b0, page_size};
        6'd9:  reg_read = {pattern_size, h_div_size, v_div_size};
        6'd10: reg_read = {sprite_aux_reg, sprite_aux_mode, sprite_disable, mosaic_b, mosaic_a};
        6'd11: reg_read = {scm, yse, cbdr, priority_mode, planeB_trans, planeA_trans};
        6'd12: reg_read = {sprite_color_fetch, planeB_color_fetch, planeA_color_fetch};
        6'd14: reg_read = {6'd0, raster_irq_mask, vblank_irq_mask};
        6'd15: reg_read = raster_irq_vpos[7:0];
        6'd16: reg_read = {raster_irq_mode, raster_irq_vpos[8], 1'b0, raster_irq_hpos};
        default: reg_read = 8'd0;
        endcase
    endfunction

    // ------------------------------------------------------------ CPU port access
    // read: capture the table address on port_rd; port_q is valid from the next clock
    logic  [2:0] rd_sel;
    logic  [1:0] rd_color_state;
    logic        rd_pnt_lane;
    logic  [5:0] rd_sat_lane;   // one-hot-ish: byte lane index
    logic  [7:0] rd_reg_value;
    logic  [7:0] status_value;
    always_comb begin
        case (rd_sel)
        3'd0: port_q = rd_pnt_lane ? pnt_cpu_q[7:0] : pnt_cpu_q[15:8];
        3'd1: port_q = sat_cpu_q[{rd_sat_lane[1:0], 3'b000} +: 8];
        3'd2: port_q = sdt_cpu_q;
        3'd3: port_q = pal_cpu_q[{rd_color_state, 3'b000} +: 8];
        3'd4: port_q = rd_reg_value;
        3'd6: port_q = status_value;
        3'd7: port_q = dma_status;
        default: port_q = 8'd0;
        endcase
    end

    // status: FP FV FC flags | HB | VB (live)
    assign status_value = {3'b000, screen_status[4:2], ~visible_h, ~visible_v};

    // register write side effects are applied in the main process below
    always_ff @(posedge clk) begin
        // default: no table writes
        pnt_be <= 2'b00; sat_be <= 4'b0000; sdt_we <= 1'b0; pal_be <= 3'b000;
        render_start <= 1'b0;
        if (reset) begin
            ytile_ptr <= 6'd0; xtile_ptr <= 6'd0; ytile_autoinc <= 1'b0; xtile_autoinc <= 1'b0; plane_select_access <= 1'b0;
            saar <= 1'b0; saaw <= 1'b0; scar <= 1'b0; scaw <= 1'b0; ba_plane_scroll_select <= 1'b0; cpar <= 1'b0; cpaw <= 1'b0;
            sprite_address <= 8'd0; scroll_address <= 8'd0; palette_address <= 8'd0; sprite_bank <= 8'd0;
            dckm <= 1'b0; flip <= 1'b0; zron <= 1'b0; dspe <= 1'b0; md <= 2'd0;
            h_display_size <= 2'd0; v_display_size <= 2'd0; roz_wrap_disable <= 1'b0; scroll_wrap_disable <= 1'b0; page_size <= 1'b0;
            pattern_size <= 2'd0; h_div_size <= 3'd0; v_div_size <= 3'd0;
            sprite_aux_reg <= 2'd0; sprite_aux_mode <= 1'b0; sprite_disable <= 1'b0; mosaic_a <= 2'd0; mosaic_b <= 2'd0;
            scm <= 2'd0; yse <= 1'b0; cbdr <= 1'b0; priority_mode <= 2'd0; planeB_trans <= 1'b0; planeA_trans <= 1'b0;
            sprite_color_fetch <= 2'd0; planeB_color_fetch <= 3'd0; planeA_color_fetch <= 3'd0; border_color <= 8'd0;
            vblank_irq_mask <= 1'b0; raster_irq_mask <= 1'b0; raster_irq_vpos <= 9'd0; raster_irq_hpos <= 5'd0; raster_irq_mode <= 1'b0;
            base_addr <= 48'd0;
            for (int i = 0; i < 8; i++) crtc[i] <= 8'd0;
            for (int i = 0; i < 14; i++) roz_raw[i] <= 8'd0;
            register_address <= 6'd0; register_autoinc_r <= 1'b0; register_autoinc_w <= 1'b0;
            screen_status <= 8'd0; dma_status <= 8'd0; p0_state <= 2'd0; pn_base_r_b <= 1'b0; pn_base_w_b <= 1'b0;
            color_state_r <= 2'd0; color_state_w <= 2'd0; unsupported_sticky <= 1'b0;
            irq_vblank <= 1'b0; irq_raster <= 1'b0;
            clearing <= 1'b0; clear_addr <= 11'd0;
            rd_sel <= 3'd5; rd_color_state <= 2'd0; rd_pnt_lane <= 1'b0; rd_sat_lane <= 6'd0; rd_reg_value <= 8'd0;
            pnt_waddr <= 11'd0; pnt_wbyte <= 8'd0; sat_waddr <= 6'd0; sat_wbyte <= 8'd0; sdt_waddr <= 9'd0; sdt_wbyte <= 8'd0;
            pal_waddr <= 8'd0; pal_wbyte <= 8'd0;
            pnt_cpu_raddr <= 11'd0; sat_cpu_raddr <= 6'd0; sdt_cpu_raddr <= 9'd0; pal_cpu_raddr <= 8'd0;
            dot <= 9'd0; line <= 9'd0; render_y <= 8'd0;
        end else begin
            // ---- raster counters, IRQ flags, render kick
            if (cen_pix) begin
                if (dot == 9'd413) begin
                    dot <= 9'd0;
                    line <= (line == 9'd257) ? 9'd0 : line + 9'd1;
                end else dot <= dot + 9'd1;
                // events at the *next* position
                if (dot == 9'd413) begin
                    logic [8:0] nline;
                    nline = (line == 9'd257) ? 9'd0 : line + 9'd1;
                    if (nline >= 9'd25 && nline <= 9'd248) begin
                        render_start <= 1'b1;
                        render_y <= flip_f ? 8'd223 - (nline[7:0] - 8'd25) : nline[7:0] - 8'd25;
                    end
                    if (nline == 9'd250) flip_f <= screen_flip;
                    if (nline == 9'd250) begin
                        screen_status[3] <= 1'b1;                          // FV
                        if (vblank_irq_mask) irq_vblank <= 1'b1;
                    end
                end
                // raster position: MAME screen coordinates (visible origin) -> our dot/line
                if (!raster_irq_mode && raster_irq_vpos <= 9'd261 && {raster_irq_hpos, 5'd0} <= 10'd804 &&
                    {1'b0, line} == 10'd26 + {1'b0, raster_irq_vpos} && {1'b0, dot} == 10'd54 + {raster_irq_hpos, 5'd0}) begin
                    screen_status[4] <= 1'b1;                              // FP
                    if (raster_irq_mask) irq_raster <= 1'b1;
                end
            end

            // ---- the reset sweep clears every table (P#7 bit 0)
            if (clearing) begin
                clear_addr <= clear_addr + 11'd1;
                if (clear_addr == 11'd2047) clearing <= 1'b0;
                pnt_waddr <= clear_addr; pnt_wbyte <= 8'd0; pnt_be <= 2'b11;
                if (clear_addr < 11'd64)  begin sat_waddr <= clear_addr[5:0]; sat_wbyte <= 8'd0; sat_be <= 4'b1111; end
                if (clear_addr < 11'd512) begin sdt_waddr <= clear_addr[8:0]; sdt_wbyte <= 8'd0; sdt_we <= 1'b1; end
                if (clear_addr < 11'd256) begin pal_waddr <= clear_addr[7:0]; pal_wbyte <= 8'd0; pal_be <= 3'b111; end
            end

            // ---- port writes
            if (port_wr) begin
                case (port_sel)
                3'd0: begin // pattern name table data
                    logic use_b; logic [12:0] pn;
                    use_b = pn_base_w_b;
                    if (p0_state == 2'd0) use_b = (!one_plane && plane_select_access);
                    pn = p0_index(use_b) + {12'd0, p0_state[0]};
                    if (pn > 13'd4095) pn = 13'd0;
                    pnt_waddr <= pn[11:1]; pnt_wbyte <= port_wdata; pnt_be <= pn[0] ? 2'b01 : 2'b10;
                    if (p0_state == 2'd0) pn_base_w_b <= use_b;
                    // state advance: 8-bit mode uses one byte per cell
                    if (p0_state == 2'd0 && md != 2'd0) p0_state <= 2'd1;
                    else begin
                        p0_state <= 2'd0; pn_base_w_b <= 1'b0;
                        // auto-increment
                        if (ytile_autoinc) begin
                            if (ytile_ptr == page_y[5:0] - 6'd1) begin
                                ytile_ptr <= 6'd0;
                                if (xtile_ptr == page_x[5:0] - 6'd1) begin xtile_ptr <= 6'd0; plane_select_access <= ~plane_select_access; end
                                else xtile_ptr <= xtile_ptr + 6'd1;
                            end else ytile_ptr <= ytile_ptr + 6'd1;
                        end else if (xtile_autoinc) begin
                            if (xtile_ptr == page_x[5:0] - 6'd1) begin
                                xtile_ptr <= 6'd0;
                                if (ytile_ptr == page_y[5:0] - 6'd1) begin ytile_ptr <= 6'd0; plane_select_access <= ~plane_select_access; end
                                else ytile_ptr <= ytile_ptr + 6'd1;
                            end else xtile_ptr <= xtile_ptr + 6'd1;
                        end
                    end
                end
                3'd1: begin
                    sat_waddr <= sprite_address[7:2]; sat_wbyte <= port_wdata; sat_be <= 4'b0001 << sprite_address[1:0];
                    if (saaw) sprite_address <= sprite_address + 8'd1;
                end
                3'd2: begin
                    sdt_waddr <= {ba_plane_scroll_select, scroll_address}; sdt_wbyte <= port_wdata; sdt_we <= 1'b1;
                    if (scaw) begin
                        scroll_address <= scroll_address + 8'd1;
                        if (scroll_address == 8'hff) ba_plane_scroll_select <= ~ba_plane_scroll_select;
                    end
                end
                3'd3: begin
                    pal_waddr <= palette_address; pal_wbyte <= port_wdata; pal_be <= 3'b001 << color_state_w;
                    if (color_state_w == 2'd2) begin
                        color_state_w <= 2'd0;
                        if (cpaw) palette_address <= palette_address + 8'd1;
                    end else color_state_w <= color_state_w + 2'd1;
                end
                3'd4: begin // register data
                    if (register_autoinc_w) register_address <= register_address + 6'd1;
                    case (register_address)
                    6'd0: begin ytile_ptr <= port_wdata[5:0] & (page_y[5:0] - 6'd1); ytile_autoinc <= port_wdata[7]; plane_select_access <= port_wdata[6]; end
                    6'd1: begin xtile_ptr <= port_wdata[5:0] & (page_x[5:0] - 6'd1); xtile_autoinc <= port_wdata[7]; end
                    6'd2: begin saar <= port_wdata[0]; saaw <= port_wdata[1]; scar <= port_wdata[2]; scaw <= port_wdata[3];
                                ba_plane_scroll_select <= port_wdata[4]; cpar <= port_wdata[6]; cpaw <= port_wdata[7]; end
                    6'd3: sprite_address <= port_wdata;
                    6'd4: scroll_address <= port_wdata;
                    6'd5: palette_address <= port_wdata;
                    6'd6: sprite_bank <= port_wdata;
                    6'd7: begin dckm <= port_wdata[7]; flip <= port_wdata[6]; zron <= port_wdata[3]; md <= port_wdata[2:1]; dspe <= port_wdata[0];
                                p0_state <= 2'd0; end
                    6'd8: begin h_display_size <= port_wdata[7:6]; v_display_size <= port_wdata[5:4]; roz_wrap_disable <= port_wdata[3];
                                scroll_wrap_disable <= port_wdata[2]; page_size <= port_wdata[0]; end
                    6'd9: begin pattern_size <= port_wdata[7:6]; h_div_size <= port_wdata[5:3]; v_div_size <= port_wdata[2:0]; end
                    6'd10: begin sprite_aux_reg <= port_wdata[7:6]; sprite_aux_mode <= port_wdata[5]; sprite_disable <= port_wdata[4];
                                 mosaic_b <= port_wdata[3:2]; mosaic_a <= port_wdata[1:0]; end
                    6'd11: begin scm <= port_wdata[7:6]; yse <= port_wdata[5]; cbdr <= port_wdata[4]; priority_mode <= port_wdata[3:2];
                                 planeB_trans <= port_wdata[1]; planeA_trans <= port_wdata[0]; end
                    6'd12: begin sprite_color_fetch <= port_wdata[7:6]; planeB_color_fetch <= port_wdata[5:3]; planeA_color_fetch <= port_wdata[2:0]; end
                    6'd13: border_color <= port_wdata;
                    6'd14: begin
                        vblank_irq_mask <= port_wdata[0]; raster_irq_mask <= port_wdata[1];
                        if (port_wdata[0] && screen_status[3]) irq_vblank <= 1'b1;
                        if (port_wdata[1] && screen_status[4]) irq_raster <= 1'b1;
                    end
                    6'd15: raster_irq_vpos[7:0] <= port_wdata;
                    6'd16: begin raster_irq_mode <= port_wdata[7]; raster_irq_vpos[8] <= port_wdata[6]; raster_irq_hpos <= port_wdata[4:0]; end
                    6'd17, 6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23, 6'd24: begin
                        // two 3-bit entries per register; plane B from R#21
                        logic [5:0] off;
                        off = 6'd6 * (register_address - 6'd17);   // entries 2k, 2k+1 at bit 6k; plane B (R#21+) lands at 24
                        base_addr[off +: 3] <= port_wdata[2:0];
                        base_addr[off + 6'd3 +: 3] <= port_wdata[6:4];
                    end
                    6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd30, 6'd31, 6'd32, 6'd33, 6'd34, 6'd35, 6'd36, 6'd37, 6'd38: begin
                        logic [3:0] ri;
                        ri = register_address[3:0] - 4'd9;      // 25..38 -> 0..13
                        roz_raw[ri] <= port_wdata;
                    end
                    6'd39, 6'd40, 6'd41, 6'd42, 6'd43, 6'd44, 6'd45, 6'd46: begin
                        logic [2:0] ci;
                        ci = register_address[2:0] - 3'd7;      // 39..46 -> 0..7
                        crtc[ci] <= port_wdata;
                    end
                    default: ;
                    endcase
                end
                3'd5: begin register_address <= port_wdata[5:0]; register_autoinc_r <= port_wdata[6]; register_autoinc_w <= port_wdata[7]; end
                3'd6: begin
                    screen_status <= screen_status & ~port_wdata;
                    if (port_wdata[3]) irq_vblank <= 1'b0;
                    if (port_wdata[4]) irq_raster <= 1'b0;
                end
                3'd7: begin
                    dma_status <= port_wdata;
                    if (port_wdata[5:1] != 5'd0) unsupported_sticky <= 1'b1;      // ROM DMA
                    if (port_wdata[0]) begin
                        // HandleReset: ports/registers 0-38 and 47-49 cleared, tables cleared
                        pn_base_w_b <= 1'b0; pn_base_r_b <= 1'b0; register_address <= 6'd0;
                        register_autoinc_r <= 1'b0; register_autoinc_w <= 1'b0;
                        ytile_ptr <= 6'd0; xtile_ptr <= 6'd0; ytile_autoinc <= 1'b0; xtile_autoinc <= 1'b0; plane_select_access <= 1'b0;
                        saar <= 1'b0; saaw <= 1'b0; scar <= 1'b0; scaw <= 1'b0; ba_plane_scroll_select <= 1'b0; cpar <= 1'b0; cpaw <= 1'b0;
                        sprite_address <= 8'd0; scroll_address <= 8'd0; palette_address <= 8'd0; sprite_bank <= 8'd0;
                        dckm <= 1'b0; flip <= 1'b0; zron <= 1'b0; dspe <= 1'b0; md <= 2'd0; p0_state <= 2'd0;
                        h_display_size <= 2'd0; v_display_size <= 2'd0; roz_wrap_disable <= 1'b0; scroll_wrap_disable <= 1'b0; page_size <= 1'b0;
                        pattern_size <= 2'd0; h_div_size <= 3'd0; v_div_size <= 3'd0;
                        sprite_aux_reg <= 2'd0; sprite_aux_mode <= 1'b0; sprite_disable <= 1'b0; mosaic_a <= 2'd0; mosaic_b <= 2'd0;
                        scm <= 2'd0; yse <= 1'b0; cbdr <= 1'b0; priority_mode <= 2'd0; planeB_trans <= 1'b0; planeA_trans <= 1'b0;
                        sprite_color_fetch <= 2'd0; planeB_color_fetch <= 3'd0; planeA_color_fetch <= 3'd0; border_color <= 8'd0;
                        vblank_irq_mask <= 1'b0; raster_irq_mask <= 1'b0; raster_irq_vpos <= 9'd0; raster_irq_hpos <= 5'd0; raster_irq_mode <= 1'b0;
                        base_addr <= 48'd0;
                        for (int i = 0; i < 14; i++) roz_raw[i] <= 8'd0;
                        clearing <= 1'b1; clear_addr <= 11'd0;
                    end
                end
                endcase
            end

            // ---- port reads (side effects) and read address capture
            if (port_rd) begin
                rd_sel <= port_sel;
                case (port_sel)
                3'd0: begin
                    logic use_b; logic [12:0] pn;
                    use_b = pn_base_r_b;
                    if (p0_state == 2'd0) use_b = (!one_plane && plane_select_access);
                    pn = p0_index(use_b) + {12'd0, p0_state[0]};
                    if (pn > 13'd4095) pn = 13'd0;
                    pnt_cpu_raddr <= pn[11:1]; rd_pnt_lane <= pn[0];
                    if (p0_state == 2'd0) pn_base_r_b <= use_b;
                    if (p0_state == 2'd0 && md != 2'd0) p0_state <= 2'd1;
                    else begin
                        p0_state <= 2'd0; pn_base_r_b <= 1'b0;
                        if (ytile_autoinc) begin
                            if (ytile_ptr == page_y[5:0] - 6'd1) begin
                                ytile_ptr <= 6'd0;
                                if (xtile_ptr == page_x[5:0] - 6'd1) begin xtile_ptr <= 6'd0; plane_select_access <= ~plane_select_access; end
                                else xtile_ptr <= xtile_ptr + 6'd1;
                            end else ytile_ptr <= ytile_ptr + 6'd1;
                        end else if (xtile_autoinc) begin
                            if (xtile_ptr == page_x[5:0] - 6'd1) begin
                                xtile_ptr <= 6'd0;
                                if (ytile_ptr == page_y[5:0] - 6'd1) begin ytile_ptr <= 6'd0; plane_select_access <= ~plane_select_access; end
                                else ytile_ptr <= ytile_ptr + 6'd1;
                            end else xtile_ptr <= xtile_ptr + 6'd1;
                        end
                    end
                end
                3'd1: begin
                    sat_cpu_raddr <= sprite_address[7:2]; rd_sat_lane <= {4'd0, sprite_address[1:0]};
                    if (saar) sprite_address <= sprite_address + 8'd1;
                end
                3'd2: begin
                    sdt_cpu_raddr <= {ba_plane_scroll_select, scroll_address};
                    if (scar) begin
                        scroll_address <= scroll_address + 8'd1;
                        if (scroll_address == 8'hff) ba_plane_scroll_select <= ~ba_plane_scroll_select;
                    end
                end
                3'd3: begin
                    pal_cpu_raddr <= palette_address; rd_color_state <= color_state_r;
                    if (color_state_r == 2'd2) begin
                        color_state_r <= 2'd0;
                        if (cpar) palette_address <= palette_address + 8'd1;
                    end else color_state_r <= color_state_r + 2'd1;
                end
                3'd4: begin
                    rd_reg_value <= reg_read(register_address);
                    if (register_autoinc_r) register_address <= register_address + 6'd1;
                end
                default: ;
                endcase
            end
        end
    end

    // ------------------------------------------------------------ renderer
    logic        rend_busy, rend_overrun;
    assign unsupported = unsupported_sticky | roz_unsup | (mosaic_a != 2'd0) | (mosaic_b != 2'd0) | rend_overrun;
    assign unsup_src = {unsupported_sticky, roz_unsup, (mosaic_a != 2'd0) | (mosaic_b != 2'd0), rend_overrun};
    logic [15:0] rend_line_clocks, rend_max_clocks;
    logic  [9:0] lb_raddr;
    logic  [7:0] lb_q;
    ygv608_render u_render (
        .clk(clk), .reset(reset),
        .start(render_start), .line_y(render_y), .busy(rend_busy), .overrun(rend_overrun),
        .line_clocks(rend_line_clocks), .max_clocks(rend_max_clocks),
        .md(md), .page_size(page_size), .pts16(pattern_size != 2'd0), .slh(h_div_size), .slv(v_div_size),
        .col_shift(col_shift), .flip(flip), .dspe(dspe), .spas(sprite_aux_mode), .spa(sprite_aux_reg),
        .sprd(sprite_disable), .prm(priority_mode), .ctpb(planeB_trans), .ctpa(planeA_trans),
        .apf(planeA_color_fetch), .bpf(planeB_color_fetch), .spf(sprite_color_fetch),
        .border(border_color), .sprite_bank(sprite_bank), .gfxbank(gfxbank), .base_addr(base_addr),
        .zron(zron), .roz_wrap(~roz_wrap_disable),
        .roz_ax(roz_ax), .roz_ay(roz_ay), .roz_dx(roz_dx), .roz_dy(roz_dy), .roz_dxy(roz_dxy), .roz_dyx(roz_dyx),
        .roz_unsupported(roz_unsup),
        .pnt_addr(pnt_rend_raddr), .pnt_q(pnt_rend_q),
        .sdt_addr(sdt_rend_raddr), .sdt_q(sdt_rend_q),
        .sat_addr(sat_rend_raddr), .sat_q(sat_rend_q),
        .pat_req(pat_req), .pat_addr(pat_addr), .pat_len(pat_len), .pat_wr(pat_wr), .pat_idx(pat_idx),
        .pat_ack(pat_ack), .pat_q(pat_q),
        .lb_raddr(lb_raddr), .lb_q(lb_q)
    );

    // ------------------------------------------------------------ output stage
    // at each cen_pix the current dot's pixel is read from the line buffer (bank
    // = displayed line & 1), looked up in the palette, and presented at the
    // next cen_pix together with its syncs.
    logic        de_p, hs_p, vs_p, hb_p, vb_p;
    logic        de_q, hs_q, vs_q, hb_q, vb_q;
    wire   [8:0] disp_line = line - 9'd26;
    always_ff @(posedge clk) begin
        if (reset) begin
            lb_raddr <= 10'd0; pal_out_raddr <= 8'd0;
            de_p <= 1'b0; hs_p <= 1'b0; vs_p <= 1'b0; hb_p <= 1'b1; vb_p <= 1'b1;
            de_q <= 1'b0; hs_q <= 1'b0; vs_q <= 1'b0; hb_q <= 1'b1; vb_q <= 1'b1;
            de <= 1'b0; hsync <= 1'b0; vsync <= 1'b0; hblank <= 1'b1; vblank <= 1'b1; r <= 8'd0; g <= 8'd0; b <= 8'd0;
        end else begin
            if (cen_pix) begin
                lb_raddr <= {disp_line[0] ^ flip_f, flip_f ? 9'd341 - dot : dot - 9'd54};   // 341 = 54 + 287
                de_p <= visible_h && visible_v;
                hb_p <= ~visible_h; vb_p <= ~visible_v;
                hs_p <= (dot >= 9'd360) && (dot < 9'd392);
                vs_p <= (line >= 9'd252) && (line < 9'd255);
                // outputs for the dot processed at the previous cen_pix
                de <= de_q; hsync <= hs_q; vsync <= vs_q; hblank <= hb_q; vblank <= vb_q;
                r <= {pal_out_q[5:0], pal_out_q[5:4]};
                g <= {pal_out_q[13:8], pal_out_q[13:12]};
                b <= {pal_out_q[21:16], pal_out_q[21:20]};
            end
            // pipeline: lb read (1) -> palette read (1); the syncs follow one stage behind
            pal_out_raddr <= lb_q;
            de_q <= de_p; hs_q <= hs_p; vs_q <= vs_p; hb_q <= hb_p; vb_q <= vb_p;
        end
    end

    wire _unused_ok = &{1'b0, rend_busy, rend_line_clocks, rend_max_clocks, crtc[0], crtc[1], crtc[2], crtc[3],
                        crtc[4], crtc[5], crtc[6], crtc[7], dckm, h_display_size, v_display_size,
                        scroll_wrap_disable, scm, yse, cbdr, rd_sat_lane[5:2], dma_status,
                        pal_out_q[23:22], pal_out_q[15:14], pal_out_q[7:6], disp_line[8:1]};
endmodule
