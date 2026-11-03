// -----------------------------------------------------------------------------
// exterm_video.sv -- Exterminator video: timing from the master GSP registers, two
// display-address units (master/slave), BG/FG VRAM, CLUT and the exterm
// `scanline_update` mix.  See docs/lane2_video.md.
//
// Output pipeline (per ce_pix, clk-domain, fixed latency):
//   c0  edge where ce_pix is sampled high: address regs for pixel (hc,vc) loaded
//   c1  VRAM latches addresses                        (bg_q/fg_q valid after c1)
//   c2  mix -> CLUT address (comb.), CLUT latches     (clut_q valid after c2)
//   c3  r/g/b/hs/vs/hblank/vblank/de/ce_pix_o registered
// => RGB/sync/blank for pixel (hc,vc) are visible 3 clk after the ce_pix edge that
// consumed it, ce_pix_o is high for exactly 1 clk, in the cycle where the new pixel
// first appears.  hs/vs/hblank/vblank are delayed by the same 3 clk (aligned to RGB).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
`default_nettype none
module exterm_video (
  input  wire        clk,
  input  wire        rst,
  input  wire        ce_pix,
  input  wire [15:0] m_vreg [0:15],
  input  wire [15:0] s_vreg [0:15],
  output wire [15:0] hcount,
  output wire [15:0] vcount,
  output wire        m_dint,
  output wire        s_dint,
  output wire [15:0] m_dpyadr_live,
  output wire [15:0] s_dpyadr_live,

  // BG (master) VRAM CPU port
  input  wire        mv_req, mv_we,
  input  wire [15:0] mv_addr, mv_wdata,
  input  wire [1:0]  mv_be,
  input  wire        mv_srt_rd, mv_srt_wr,
  output wire [15:0] mv_rdata,
  output wire        mv_ack,
  // FG (slave) VRAM CPU port
  input  wire        sv_req, sv_we,
  input  wire [15:0] sv_addr, sv_wdata,
  input  wire [1:0]  sv_be,
  input  wire        sv_srt_rd, sv_srt_wr,
  output wire [15:0] sv_rdata,
  output wire        sv_ack,
  // CLUT CPU port
  input  wire        pal_we,
  input  wire [10:0] pal_addr,
  input  wire [15:0] pal_wdata,
  input  wire [1:0]  pal_be,
  output wire [15:0] pal_rdata,

  // video out
  output reg  [4:0]  r, g, b,
  output reg         hs, vs, hblank, vblank,
  output reg         de,
  output reg         ce_pix_o
);
  // ---- register unpack (contract index map) ----
  wire [15:0] m_hesync = m_vreg[0],  m_heblnk = m_vreg[1],  m_hsblnk = m_vreg[2],  m_htotal = m_vreg[3];
  wire [15:0] m_vesync = m_vreg[4],  m_veblnk = m_vreg[5],  m_vsblnk = m_vreg[6],  m_vtotal = m_vreg[7];
  wire [15:0] m_dpyctl = m_vreg[8],  m_dpystrt = m_vreg[9], m_dpyint = m_vreg[10], m_dpytap = m_vreg[11];
  wire [15:0] s_heblnk = s_vreg[1],  s_hsblnk = s_vreg[2];
  wire [15:0] s_veblnk = s_vreg[5],  s_vsblnk = s_vreg[6];
  wire [15:0] s_dpyctl = s_vreg[8],  s_dpystrt = s_vreg[9], s_dpyint = s_vreg[10], s_dpytap = s_vreg[11];

  // MAME keeps the previous screen size until HTOTAL and VTOTAL are both programmed (>0): 318x264 at boot.
  wire [15:0] m_htotal_e = (m_htotal == 16'd0 || m_vtotal == 16'd0) ? 16'd317 : m_htotal;
  wire [15:0] m_vtotal_e = (m_htotal == 16'd0 || m_vtotal == 16'd0) ? 16'd263 : m_vtotal;

  // ---- timing ----
  wire [15:0] hc, vc, vn;
  wire        line_start, t_hs, t_vs, t_hb, t_vb;
  exterm_timing u_tim (
    .clk(clk), .rst(rst), .ce_pix(ce_pix),
    .hesync(m_hesync), .heblnk(m_heblnk), .hsblnk(m_hsblnk), .htotal(m_htotal_e),
    .vesync(m_vesync), .veblnk(m_veblnk), .vsblnk(m_vsblnk), .vtotal(m_vtotal_e),
    .hc(hc), .vc(vc), .line_start(line_start), .vn(vn),
    .hcount_o(hcount), .vcount_o(vcount),
    .hs(t_hs), .vs(t_vs), .hblank(t_hb), .vblank(t_vb)
  );

  // ---- display-address units ----
  wire [11:0] m_row, s_row;
  wire [13:0] m_col, s_col;
  wire [1:0]  m_yoff, s_yoff;
  wire        m_en, s_en;
  tms_display u_mdisp (
    .clk(clk), .rst(rst), .strobe(line_start), .vn(vn),
    .dpyctl(m_dpyctl), .dpystrt(m_dpystrt), .dpytap(m_dpytap), .dpyint(m_dpyint),
    .veblnk(m_veblnk), .vsblnk(m_vsblnk), .vtotal(m_vtotal), .scr_vtotal(m_vtotal_e),
    .dpyadr_live(m_dpyadr_live), .dint(m_dint),
    .rowaddr(m_row), .coladdr(m_col), .yoffset(m_yoff), .enabled(m_en)
  );
  tms_display u_sdisp (
    .clk(clk), .rst(rst), .strobe(line_start), .vn(vn),
    .dpyctl(s_dpyctl), .dpystrt(s_dpystrt), .dpytap(s_dpytap), .dpyint(s_dpyint),
    .veblnk(s_veblnk), .vsblnk(s_vsblnk), .vtotal(s_vreg[7]), .scr_vtotal(m_vtotal_e),
    .dpyadr_live(s_dpyadr_live), .dint(s_dint),
    .rowaddr(s_row), .coladdr(s_col), .yoffset(s_yoff), .enabled(s_en)
  );

  // FG line enable: slave enabled && veblnk <= line < vsblnk && heblnk < hsblnk  (evaluated at line start)
  reg fg_line_en;
  always_ff @(posedge clk) begin
    if (rst) fg_line_en <= 1'b0;
    else if (line_start)
      fg_line_en <= s_dpyctl[15] && (vn >= s_veblnk) && (vn < s_vsblnk) && (s_heblnk < s_hsblnk);
  end

  // per-line derived addresses (stable from the cycle after line_start)
  wire [15:0] fg_rowbase = {s_row[7:0], 8'h00} + {7'd0, s_yoff, 7'd0};   // ((rowaddr<<8)+(yoffset<<7)) & 0xff80
  wire [6:0]  fg_col0    = s_col[7:1];                                    // (coladdr>>1) & 0x7f
  wire [7:0]  bg_col0    = m_col[7:0];                                    // coladdr & 0xff

  // ---- stage 0 (c0) ----
  wire [15:0] ix   = hc - m_heblnk;                       // visible pixel index
  wire        vis0 = !t_hb && !t_vb && m_en;
  reg  [15:0] bg_a, fg_a;
  reg         s0_sel, s0_fgen, s0_vis, s0_hs, s0_vs, s0_hb, s0_vb;
  always_ff @(posedge clk) begin
    if (rst) begin
      bg_a <= 16'd0; fg_a <= 16'd0;
      s0_sel <= 1'b0; s0_fgen <= 1'b0; s0_vis <= 1'b0;
      s0_hs <= 1'b0; s0_vs <= 1'b0; s0_hb <= 1'b1; s0_vb <= 1'b1;
    end else if (ce_pix) begin
      bg_a   <= {m_row[7:0], bg_col0 + ix[7:0]};
      fg_a   <= {fg_rowbase[15:7], fg_col0 + ix[7:1]};
      s0_sel <= ix[0];
      s0_fgen <= fg_line_en;
      s0_vis <= vis0;
      s0_hs <= t_hs; s0_vs <= t_vs; s0_hb <= t_hb; s0_vb <= t_vb;
    end
  end

  // ---- VRAMs (scan side) ----
  wire [15:0] bg_q, fg_q;
  exterm_vram u_bg (
    .clk(clk), .rst(rst),
    .req(mv_req), .we(mv_we), .addr(mv_addr), .wdata(mv_wdata), .be(mv_be),
    .srt_rd(mv_srt_rd), .srt_wr(mv_srt_wr), .rdata(mv_rdata), .ack(mv_ack),
    .scan_addr(bg_a), .scan_data(bg_q)
  );
  exterm_vram u_fg (
    .clk(clk), .rst(rst),
    .req(sv_req), .we(sv_we), .addr(sv_addr), .wdata(sv_wdata), .be(sv_be),
    .srt_rd(sv_srt_rd), .srt_wr(sv_srt_wr), .rdata(sv_rdata), .ack(sv_ack),
    .scan_addr(fg_a), .scan_data(fg_q)
  );

  // ---- stage 1 flags (c1) ----
  reg s1_sel, s1_fgen, s1_vis, s1_hs, s1_vs, s1_hb, s1_vb;
  always_ff @(posedge clk) begin
    s1_sel <= s0_sel; s1_fgen <= s0_fgen; s1_vis <= s0_vis;
    s1_hs <= s0_hs; s1_vs <= s0_vs; s1_hb <= s0_hb; s1_vb <= s0_vb;
  end

  // ---- mix (combinational between c1 and c2) = exterm_state::scanline_update ----
  wire [7:0]  fgbyte   = !s1_fgen ? 8'd0 : (s1_sel ? fg_q[15:8] : fg_q[7:0]);
  wire        bg_force = (bg_q[15:13] == 3'b111);
  wire        use_fg   = !bg_force && (fgbyte != 8'd0);
  wire        use_bgc  = bg_force || (!use_fg && bg_q[15]);
  wire [10:0] clut_idx = use_fg ? {3'b000, fgbyte} : bg_q[10:0];
  wire        use_clut = use_fg || use_bgc;

  wire [15:0] clut_q;
  exterm_clut u_clut (
    .clk(clk),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_wdata(pal_wdata), .pal_be(pal_be), .pal_rdata(pal_rdata),
    .scan_addr(clut_idx), .scan_data(clut_q)
  );

  // ---- stage 2 (c2) ----
  reg [14:0] s2_direct;
  reg        s2_use_clut, s2_vis, s2_hs, s2_vs, s2_hb, s2_vb;
  always_ff @(posedge clk) begin
    s2_direct <= bg_q[14:0]; s2_use_clut <= use_clut; s2_vis <= s1_vis;
    s2_hs <= s1_hs; s2_vs <= s1_vs; s2_hb <= s1_hb; s2_vb <= s1_vb;
  end

  // ---- stage 3 (c3): outputs ----
  reg ced1, ced2, ced3;
  wire [14:0] pix = s2_use_clut ? clut_q[14:0] : s2_direct;
  always_ff @(posedge clk) begin
    ced1 <= ce_pix; ced2 <= ced1; ced3 <= ced2;
    if (rst) begin
      r <= 5'd0; g <= 5'd0; b <= 5'd0;
      hs <= 1'b0; vs <= 1'b0; hblank <= 1'b1; vblank <= 1'b1; de <= 1'b0; ce_pix_o <= 1'b0;
      ced1 <= 1'b0; ced2 <= 1'b0; ced3 <= 1'b0;
    end else begin
      r <= s2_vis ? pix[14:10] : 5'd0;
      g <= s2_vis ? pix[9:5]   : 5'd0;
      b <= s2_vis ? pix[4:0]   : 5'd0;
      hs <= s2_hs; vs <= s2_vs; hblank <= s2_hb; vblank <= s2_vb;
      de <= !s2_hb && !s2_vb;
      ce_pix_o <= ced3;
    end
  end

`ifdef VERILATOR
  // ---- simulation-only debug dump (plusargs: +vdump=<prefix> +vdump_frame=<n>) ----
  // At line 0 of frame n writes <prefix>_{mvram,svram,clut}.hex, <prefix>_regs.txt and a per-line
  // FG-parameter log for that frame; <prefix>_svw.txt = count of slave-VRAM CPU writes per 256-word row.
  string     vd_prefix, vd_tag;
  integer    vd_frame, vd_n, vd_f, vd_i;
  integer    vd_svw [0:255];
  integer    vd_srtw, vd_srtr;
  integer    vd_fp;
  reg        vd_on;
  initial begin
    vd_on = $value$plusargs("vdump=%s", vd_prefix);
    if (!$value$plusargs("vdump_frame=%d", vd_frame)) vd_frame = 1500;
    vd_n = 0; vd_srtw = 0; vd_srtr = 0;
    for (vd_i = 0; vd_i < 256; vd_i = vd_i + 1) vd_svw[vd_i] = 0;
  end
  integer vd_lf, vd_lc;
  initial begin vd_lc = 0; vd_lf = 0; if ($value$plusargs("vdump=%s", vd_prefix)) vd_lf = $fopen({vd_prefix, "_svlog.txt"}, "w"); end
  always @(posedge clk) if (vd_lf != 0 && sv_ack && (sv_we && !sv_srt_wr && !sv_srt_rd && sv_wdata != 16'd0) && vd_lc < 20000) begin
    vd_lc <= vd_lc + 1;
    $fwrite(vd_lf, "f%0d vcount=%0d addr=%04x we=%0d be=%0d data=%04x srt_rd=%0d srt_wr=%0d\n", vd_n, vcount, sv_addr, sv_we, sv_be, sv_wdata, sv_srt_rd, sv_srt_wr);
    if (vd_lc == 19999) $fflush(vd_lf);
  end
  integer vd_mf, vd_mc, vd_stall;
  initial begin vd_mc = 0; vd_stall = 0; vd_mf = 0; if ($value$plusargs("vdump=%s", vd_prefix)) vd_mf = $fopen({vd_prefix, "_mvlog.txt"}, "w"); end
  always @(posedge clk) if (vd_mf != 0) begin
    vd_stall <= (mv_req | mv_srt_rd | mv_srt_wr) && !mv_ack ? vd_stall + 1 : 0;
    if (vd_stall == 70000) $fwrite(vd_mf, "STALL f%0d vc=%0d req=%0d we=%0d srt_rd=%0d srt_wr=%0d addr=%04x qcnt=%0d eng=%0d st=%0d\n", vd_n, vcount, mv_req, mv_we, mv_srt_rd, mv_srt_wr, mv_addr, u_bg.qcnt, u_bg.eng, u_bg.st);
    if (mv_ack && vd_mc < 300) begin vd_mc <= vd_mc + 1; $fwrite(vd_mf, "f%0d vc=%0d ACK we=%0d srt_rd=%0d srt_wr=%0d addr=%04x data=%04x be=%0d\n", vd_n, vcount, mv_we, mv_srt_rd, mv_srt_wr, mv_addr, mv_wdata, mv_be); end
  end
  reg [15:0] vd_pc, vd_ps, vd_p7;
  integer    vd_rf;
  initial begin vd_rf = 0; if ($value$plusargs("vdump=%s", vd_prefix)) vd_rf = $fopen({vd_prefix, "_reglog.txt"}, "w"); end
  always @(posedge clk) if (vd_rf != 0) begin
    vd_pc <= s_vreg[8]; vd_ps <= s_vreg[9]; vd_p7 <= s_vreg[7];
    if (s_vreg[8] != vd_pc || s_vreg[9] != vd_ps || s_vreg[7] != vd_p7)
      $fwrite(vd_rf, "f%0d vc=%0d slave DPYCTL=%04x DPYSTRT=%04x VTOTAL=%04x\n", vd_n, vcount, s_vreg[8], s_vreg[9], s_vreg[7]);
  end
  always @(posedge clk) if (vd_on && !rst) begin
    if (sv_ack && !sv_srt_rd && !sv_srt_wr && sv_we) vd_svw[sv_addr[15:8]] <= vd_svw[sv_addr[15:8]] + 1;
    if (sv_ack && sv_srt_wr) vd_srtw <= vd_srtw + 1;
    if (sv_ack && sv_srt_rd) vd_srtr <= vd_srtr + 1;
    if (line_start && vn == 16'd0) begin
      vd_n <= vd_n + 1;
      if (vd_n + 1 == vd_frame || vd_n + 1 == 1300) begin
        vd_tag = $sformatf("%0d", vd_n + 1);
        $writememh({vd_prefix, vd_tag, "_mvram.hex"}, u_bg.u_ram.mem);
        $writememh({vd_prefix, vd_tag, "_svram.hex"}, u_fg.u_ram.mem);
        $writememh({vd_prefix, vd_tag, "_clut.hex"}, u_clut.u_ram.mem);
        vd_fp = $fopen({vd_prefix, vd_tag, "_regs.txt"}, "w");
        for (vd_i = 0; vd_i < 14; vd_i = vd_i + 1) $fwrite(vd_fp, "reg%02d master %04x slave %04x\n", vd_i, m_vreg[vd_i], s_vreg[vd_i]);
        $fwrite(vd_fp, "svram CPU word-writes per row (row:count) srt_wr=%0d srt_rd=%0d\n", vd_srtw, vd_srtr);
        for (vd_i = 0; vd_i < 256; vd_i = vd_i + 1) if (vd_svw[vd_i] != 0) $fwrite(vd_fp, "%02x:%0d ", vd_i, vd_svw[vd_i]);
        $fwrite(vd_fp, "\n");
        $fclose(vd_fp);
        $display("VDUMP frame %0d written", vd_frame);
      end
      if (vd_n + 1 == vd_frame + 1) vd_f = 0;
    end
    // per-line FG parameters (from the line_start strobe) for the dump frame
    if (line_start && (vd_n + 1 == vd_frame || vd_n + 1 == 1300)) begin
      vd_tag = $sformatf("%0d", vd_n + 1);
      vd_fp = $fopen({vd_prefix, vd_tag, "_lines.txt"}, (vn == 16'd0) ? "w" : "a");
      $fwrite(vd_fp, "line %0d m_adr=%04x s_adr=%04x s_en=%0d s_ctl=%04x s_strt=%04x s_tap=%04x\n", vn, m_dpyadr_live, s_dpyadr_live, s_dpyctl[15], s_dpyctl, s_dpystrt, s_dpytap);
      $fclose(vd_fp);
    end
  end
`ifdef EXTERM_SLAVE_TRACE
  // ---- slave write/operation trace (simulation only; build with -DEXTERM_SLAVE_TRACE):
  // +tr0=<f> +tr1=<f> window in frame-counter units (vd_n); +vdump=<prefix> selects the output file <prefix>_trace.txt.
  `define SCPU $root.exterm_sim_top.u_core.u_cpu.u_scpu
  integer tr_f0, tr_f1, tr_fh;
  reg [31:0] tr_psrc, tr_pdst, tr_fdst;
  reg        tr_newp, tr_newf;
  reg [31:0] tr_lastpc, tr_pc;
  initial begin
    tr_fh = 0; tr_f0 = 0; tr_f1 = 0; tr_newp = 1; tr_newf = 1; tr_lastpc = 0;
    tr_psrc = 0; tr_pdst = 0; tr_fdst = 0;
    if (!$value$plusargs("tr0=%d", tr_f0)) tr_f0 = 0;
    if (!$value$plusargs("tr1=%d", tr_f1)) tr_f1 = 0;
    if ($value$plusargs("vdump=%s", vd_prefix)) tr_fh = $fopen({vd_prefix, "_trace.txt"}, "w");
  end
  wire tr_win = (tr_fh != 0) && (vd_n >= tr_f0) && (vd_n <= tr_f1);
  always @(posedge clk) if (tr_win) begin
    if ($root.exterm_sim_top.dbg_s_retire) tr_lastpc <= $root.exterm_sim_top.dbg_s_pc;
    if (`SCPU.pblt_src_xy_raw_q !== tr_psrc || `SCPU.pblt_dst_xy_raw_q !== tr_pdst) begin
      tr_psrc <= `SCPU.pblt_src_xy_raw_q; tr_pdst <= `SCPU.pblt_dst_xy_raw_q; tr_newp <= 1'b1;
    end
    if (`SCPU.fill_daddr_raw_q !== tr_fdst) begin tr_fdst <= `SCPU.fill_daddr_raw_q; tr_newf <= 1'b1; end
    if (tr_win && sv_ack && (sv_we || sv_srt_wr || sv_srt_rd)) begin
      if (tr_newp) begin
        tr_newp <= 1'b0;
        $fwrite(tr_fh, "OP-PIXBLT f%0d pc_prev=%08x SADDR=%08x DADDR=%08x DYDX=%04x_%04x SPTCH=%08x DPTCH=%08x CTRL=%04x PSIZE=%0d PMASK=%04x C0=%08x C1=%08x\n", vd_n, tr_lastpc,
          `SCPU.pblt_src_xy_raw_q, `SCPU.pblt_dst_xy_raw_q, `SCPU.pblt_dy_q, `SCPU.pblt_dx_q, `SCPU.pblt_sptch_q, `SCPU.pblt_dptch_q,
          `SCPU.io_control, `SCPU.io_psize, `SCPU.io_pmask, `SCPU.pblt_color0_q, `SCPU.pblt_color1_q);
      end
      if (tr_newf) begin
        tr_newf <= 1'b0;
        $fwrite(tr_fh, "OP-FILL f%0d pc_prev=%08x DADDR=%08x DYDX=%04x_%04x DPTCH=%08x COLOR1=%08x CTRL=%04x PSIZE=%0d\n", vd_n, tr_lastpc,
          `SCPU.fill_daddr_raw_q, `SCPU.fill_dy_q, `SCPU.fill_dx_q, `SCPU.fill_dptch_q, `SCPU.fill_color_q, `SCPU.io_control, `SCPU.io_psize);
      end
      $fwrite(tr_fh, "f%0d vc=%0d W addr=%04x row=%02x col=%02x data=%04x be=%0d srt_wr=%0d srt_rd=%0d pc_cur=%08x\n", vd_n, vcount, sv_addr, sv_addr[15:8], sv_addr[7:0], sv_wdata, sv_be, sv_srt_wr, sv_srt_rd, $root.exterm_sim_top.dbg_s_pc);
    end
  end
`endif
`endif
endmodule
`default_nettype wire
