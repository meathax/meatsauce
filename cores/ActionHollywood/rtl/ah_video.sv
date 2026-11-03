// Action Hollywood (TCH/Proyesel, MAME actionhw) video: CPU RAM slice A00000-C007FF, timing, 3 tilemaps + sprites, palette.
// One clock domain: clk = 47.95395 MHz, pixel clock enable = clk/6 (7.99233 MHz -> 60.038 Hz, PCB-measured), HTOTAL 512, VTOTAL 260, active 352x240 at raster x 82..433, y 0..239.
// Line-buffer renderer: line L+1 is built (tile slots + sprite line buffer) while line L is displayed.
// Scroll registers are latched once per frame at the start of vblank (MAME renders the frame at vblank start).
module ah_video (
	input  wire         clk,
	input  wire         rst,
	// 68000 slice
	input  wire         vid_cs,
	input  wire [23:1]  cpu_addr,
	input  wire [15:0]  cpu_din,
	input  wire         cpu_uds_n,
	input  wire         cpu_lds_n,
	input  wire         cpu_rw,           // 1 = read
	output wire [15:0]  vid_dout,
	output wire         vid_ack,
	// GFX ROM client port (word index in the 8 MB image space, GFX base 0x200000 included)
	output wire         gfx_req,
	output wire [22:2]  gfx_addr,
	input  wire         gfx_ack,
	input  wire [31:0]  gfx_data,
	output reg          vint,
	// video
	output reg          ce_pix,
	output reg          hs,
	output reg          vs,
	output reg          hblank,
	output reg          vblank,
	output reg  [7:0]   r,
	output reg  [7:0]   g,
	output reg  [7:0]   b,
	output wire [9:0]   dbg_x,
	output wire [9:0]   dbg_y,
	input  wire         flip              // 180-degree presentation flip (OSD Rotation 180), latched at the start of vblank
);
	// =========================================================================== timing
	reg [2:0] ph;
	reg [8:0] hc, vc;
	initial begin ph = 3'd0; hc = 9'd0; vc = 9'd0; ce_pix = 1'b0; hs = 1'b0; vs = 1'b0; hblank = 1'b1; vblank = 1'b1; end   // power-up raster state
	wire      tick = (ph == 3'd5);
	wire [8:0] hn = (hc == 9'd511) ? 9'd0 : hc + 1'b1;
	wire [8:0] vn = (hc == 9'd511) ? ((vc == 9'd259) ? 9'd0 : vc + 1'b1) : vc;
	assign dbg_x = {1'b0, hc};
	assign dbg_y = {1'b0, vc};

	wire act_h_n = (hn >= 9'd82) && (hn <= 9'd433);
	wire act_v_n = (vn < 9'd240);

	// =========================================================================== CPU slice
	wire [23:0] a = {cpu_addr, 1'b0};
	wire sel_fg    = vid_cs && (a[23:14] == 10'h280);
	wire sel_bg    = vid_cs && (a[23:14] == 10'h281);
	wire sel_bg2   = vid_cs && (a[23:14] == 10'h282);
	wire sel_spare = vid_cs && (a[23:14] == 10'h283);
	wire sel_scr   = vid_cs && (a[23:4]  == 20'hA1000);
	wire sel_spr   = vid_cs && (a[23:11] == 13'h1600);
	wire sel_pal   = vid_cs && (a[23:11] == 13'h1800);

	reg ack_r;
	always @(posedge clk) ack_r <= rst ? 1'b0 : vid_cs;
	assign vid_ack = vid_cs & ack_r;
	wire wr   = vid_cs & ack_r & ~cpu_rw;
	wire we_h = wr & ~cpu_uds_n;
	wire we_l = wr & ~cpu_lds_n;

	reg [2:0] rsel;   // registered read select (aligned with the RAM read registers)
	always @(posedge clk)
		rsel <= sel_fg ? 3'd0 : sel_bg ? 3'd1 : sel_bg2 ? 3'd2 : sel_spare ? 3'd3 : sel_pal ? 3'd4 : 3'd7;

	// scroll regs (write only) + vblank shadow
	reg [95:0] scr_live;
	reg [95:0] scr_sh;
	always @(posedge clk) begin
		if (sel_scr && wr && a[3:1] < 3'd6) begin
			if (we_h) scr_live[{a[3:1], 4'd8} +: 8] <= cpu_din[15:8];
			if (we_l) scr_live[{a[3:1], 4'd0} +: 8] <= cpu_din[7:0];
		end
		if (tick && hn == 9'd0 && vn == 9'd240)
			scr_sh <= scr_live;
	end

	// ------------------------------------------------------------------ RAMs (CPU port A, render port B)
	wire [12:0] tram_addr;      // render read address (shared by the three tile RAMs)
	wire [15:0] fg_a, bg_a, bg2_a, sp_a, pal_a;
	wire [15:0] fg_b, bg_b, bg2_b, pal_b, spr_b;
	wire [9:0]  spr_raddr;
	wire [9:0]  pal_raddr;
	wire [15:0] spare_b_unused, spr_a_unused;

	ah_vid_cpuram #(13) u_fg    (.clk(clk), .a_addr(a[13:1]), .a_din(cpu_din), .a_we_h(we_h & sel_fg),    .a_we_l(we_l & sel_fg),    .a_dout(fg_a),  .b_addr(tram_addr), .b_dout(fg_b));
	ah_vid_cpuram #(13) u_bg    (.clk(clk), .a_addr(a[13:1]), .a_din(cpu_din), .a_we_h(we_h & sel_bg),    .a_we_l(we_l & sel_bg),    .a_dout(bg_a),  .b_addr(tram_addr), .b_dout(bg_b));
	ah_vid_cpuram #(13) u_bg2   (.clk(clk), .a_addr(a[13:1]), .a_din(cpu_din), .a_we_h(we_h & sel_bg2),   .a_we_l(we_l & sel_bg2),   .a_dout(bg2_a), .b_addr(tram_addr), .b_dout(bg2_b));
	ah_vid_cpuram #(13) u_spare (.clk(clk), .a_addr(a[13:1]), .a_din(cpu_din), .a_we_h(we_h & sel_spare), .a_we_l(we_l & sel_spare), .a_dout(sp_a),  .b_addr(13'd0),     .b_dout(spare_b_unused));
	ah_vid_cpuram #(10) u_sprr  (.clk(clk), .a_addr(a[10:1]), .a_din(cpu_din), .a_we_h(we_h & sel_spr),   .a_we_l(we_l & sel_spr),   .a_dout(spr_a_unused), .b_addr(spr_raddr), .b_dout(spr_b));
	ah_vid_cpuram #(10) u_pal   (.clk(clk), .a_addr(a[10:1]), .a_din(cpu_din), .a_we_h(we_h & sel_pal),   .a_we_l(we_l & sel_pal),   .a_dout(pal_a), .b_addr(pal_raddr), .b_dout(pal_b));

	assign vid_dout = (rsel == 3'd0) ? fg_a : (rsel == 3'd1) ? bg_a : (rsel == 3'd2) ? bg2_a :
	                  (rsel == 3'd3) ? sp_a : (rsel == 3'd4) ? pal_a : 16'h0000;

	// =========================================================================== line fill control
	reg        init_done;
	reg [8:0]  init_cnt;
	reg        pend;
	reg [7:0]  pend_l;
	reg        eng_start;
	reg [7:0]  eng_line;
	reg        eng_bank;
	wire       tdone, sdone;
	reg [15:0] busy_cnt, busy_max;     // statistics (read hierarchically by the testbench)
	reg [15:0] overrun_cnt;
	wire       arb_idle;

	wire [8:0] l_next = (vn == 9'd259) ? 9'd0 : vn + 1'b1;
	// 180-degree flip in game addressing: display line L shows source line 239-L read right-to-left.  The engines
	// render the source line; the line-buffer bank still follows the DISPLAY line parity.  Latched once per frame.
	reg        flip_r = 1'b0;
	always @(posedge clk) if (tick && hn == 9'd0 && vn == 9'd240) flip_r <= flip;
	wire [8:0] l_src = flip_r ? (9'd239 - l_next) : l_next;
	reg        pend_b;

	always @(posedge clk) begin
		eng_start <= 1'b0;
		if (rst) begin
			init_done <= 0; init_cnt <= 0; pend <= 0; busy_cnt <= 0; busy_max <= 0; overrun_cnt <= 0;
		end else begin
			if (!init_done) begin
				init_cnt <= init_cnt + 1'b1;
				if (init_cnt == 9'd511) init_done <= 1;
			end
			if (tick && hn == 9'd0 && l_next < 9'd240 && init_done) begin
				pend <= 1; pend_l <= l_src[7:0]; pend_b <= l_next[0];
				if (!(tdone && sdone)) overrun_cnt <= overrun_cnt + 1'b1;
			end
			if (pend && arb_idle) begin
				pend <= 0; eng_start <= 1; eng_line <= pend_l; eng_bank <= pend_b;
				busy_cnt <= 0;
			end else if (!(tdone && sdone)) busy_cnt <= busy_cnt + 1'b1;
			if (tdone && sdone && busy_cnt > busy_max) busy_max <= busy_cnt;
		end
	end

	// =========================================================================== engines + GFX arbiter
	wire        t_req, s_req;
	wire [19:0] t_b, s_b;
	wire [9:0]  spr_addr_e;
	wire [2:0]  slot_we;
	wire [6:0]  slot_wa;
	wire [67:0] slot_wd;
	wire        sb_we;
	wire [8:0]  sb_wa;
	wire [9:0]  sb_wd;
	wire        ack_t, ack_s;

	ah_vid_tiles u_tiles (
		.clk(clk), .rst(rst), .start(eng_start), .line(eng_line), .fbank(eng_bank), .scr(scr_sh),
		.ram_addr(tram_addr), .ram_q_bg2(bg2_b), .ram_q_bg(bg_b), .ram_q_fg(fg_b),
		.gfx_req(t_req), .gfx_b(t_b), .gfx_ack(ack_t), .gfx_data(gfx_data),
		.slot_we(slot_we), .slot_wa(slot_wa), .slot_wd(slot_wd), .done(tdone));

	ah_vid_spr u_spr_e (
		.clk(clk), .rst(rst), .start(eng_start), .line(eng_line), .gate(tdone),
		.spr_addr(spr_addr_e), .spr_q(spr_b),
		.gfx_req(s_req), .gfx_b(s_b), .gfx_ack(ack_s), .gfx_data(gfx_data),
		.buf_we(sb_we), .buf_wa(sb_wa), .buf_wd(sb_wd), .done(sdone));

	// arbiter: combinational request, owner latched while a transfer is outstanding. Tiles beat sprites.
	reg own_v, own;                      // own: 0 tile, 1 sprite
	wire cur = own_v ? own : ~t_req;
	assign gfx_req  = own_v | t_req | s_req;
	wire [19:0] cur_b = cur ? s_b : t_b;
	assign gfx_addr = 21'h80000 + {1'b0, cur_b};
	assign ack_t = gfx_ack & ~cur;
	assign ack_s = gfx_ack & cur;
	assign arb_idle = ~own_v & ~t_req & ~s_req;
	always @(posedge clk) begin
		if (rst) own_v <= 0;
		else if (gfx_ack) own_v <= 0;
		else if (gfx_req) begin own_v <= 1; own <= cur; end
	end

	// =========================================================================== line buffers / output addressing
	wire        dbank = vc[0];            // bank being displayed; fill bank is ~dbank
	wire [95:0] sc = scr_sh;
	wire [8:0]  nx = hn;                  // pixel position the output pipeline is preparing
	wire [8:0]  nf = flip_r ? (9'd515 - hn) : hn;   // source raster x (82..433 mirrored) under flip
	wire        act_n = (nx >= 9'd82) && (nx <= 9'd433) && (vc < 9'd240) && (hc != 9'd511);
	wire [8:0]  kx = nf - 9'd82;

	wire [9:0] tx0 = {1'b0, nf} + sc[73:64];
	wire [9:0] tx1 = {1'b0, nf} + sc[41:32];
	wire [8:0] tx2 = nf + sc[8:0];
	wire [6:0] ra0 = {dbank, tx0[9:4]};
	wire [6:0] ra1 = {dbank, tx1[9:4]};
	wire [6:0] ra2 = {dbank, tx2[8:3]};
	wire [3:0] px0 = tx0[3:0];
	wire [3:0] px1 = tx1[3:0];
	wire [3:0] px2 = {1'b0, tx2[2:0]};
	wire [67:0] sq0, sq1, sq2;
	ah_vid_sdp #(7, 68) u_slot0 (.clk(clk), .we(slot_we[0]), .wa(slot_wa), .wd(slot_wd), .ra(ra0), .rq(sq0));
	ah_vid_sdp #(7, 68) u_slot1 (.clk(clk), .we(slot_we[1]), .wa(slot_wa), .wd(slot_wd), .ra(ra1), .rq(sq1));
	ah_vid_sdp #(7, 68) u_slot2 (.clk(clk), .we(slot_we[2]), .wa(slot_wa), .wd(slot_wd), .ra(ra2), .rq(sq2));

	// sprite line buffers: a bank is either being filled (engine) or displayed (read, then cleared)
	assign spr_raddr = spr_addr_e;
	wire       clr_we    = act_n && (ph == 3'd1);
	wire       fill_bank = ~dbank;
	wire [9:0] sbq0, sbq1;
	wire       sb0_we = init_done ? (fill_bank == 1'b0 ? sb_we : clr_we) : 1'b1;
	wire [8:0] sb0_wa = init_done ? (fill_bank == 1'b0 ? sb_wa : kx)     : init_cnt;
	wire [9:0] sb0_wd = init_done ? (fill_bank == 1'b0 ? sb_wd : 10'h00F) : 10'h00F;
	wire       sb1_we = init_done ? (fill_bank == 1'b1 ? sb_we : clr_we) : 1'b1;
	wire [8:0] sb1_wa = init_done ? (fill_bank == 1'b1 ? sb_wa : kx)     : init_cnt;
	wire [9:0] sb1_wd = init_done ? (fill_bank == 1'b1 ? sb_wd : 10'h00F) : 10'h00F;
	ah_vid_sdp #(9, 10) u_sb0 (.clk(clk), .we(sb0_we), .wa(sb0_wa), .wd(sb0_wd), .ra(kx), .rq(sbq0));
	ah_vid_sdp #(9, 10) u_sb1 (.clk(clk), .we(sb1_we), .wa(sb1_wa), .wd(sb1_wd), .ra(kx), .rq(sbq1));

	// =========================================================================== pixel pipeline (6 clk per pixel)
	// ph0: addresses valid, RAM read; ph1: layer mux -> idx_r; ph2: palette read; ph3: rgb_n; tick: outputs
	wire [3:0] pen0 = sq0[{1'b0, px0, 2'b00} +: 4];
	wire [3:0] pen1 = sq1[{1'b0, px1, 2'b00} +: 4];
	wire [3:0] pen2 = sq2[{1'b0, px2, 2'b00} +: 4];
	wire [9:0] sprv = dbank ? sbq1 : sbq0;
	reg  [9:0] idx_r;
	reg        act_r;
	assign pal_raddr = idx_r;
	always @(posedge clk) begin
		if (ph == 3'd1) begin
			act_r <= act_n;
			if (pen2 != 4'hF)           idx_r <= {2'b00, sq2[67:64], pen2};   // FG
			else if (sprv[3:0] != 4'hF) idx_r <= sprv;                        // sprites (group 0x30)
			else if (pen1 != 4'hF)      idx_r <= {2'b01, sq1[67:64], pen1};   // BG
			else                        idx_r <= {2'b10, sq0[67:64], pen0};   // BG2 (opaque)
		end
	end
	reg [23:0] rgb_n;    // {B,G,R}
	always @(posedge clk)
		if (ph == 3'd3)
			rgb_n <= act_r ? {{pal_b[11:8], pal_b[11:8]}, {pal_b[7:4], pal_b[7:4]}, {pal_b[3:0], pal_b[3:0]}} : 24'h000000;

	always @(posedge clk) begin
		// The raster (pixel CE, counters, sync, blanking) free-runs from configuration and is NOT reset by the game
		// reset: CE_PIXEL spacing stays exactly 6 and HS/VS never stop during ROM download or OSD reset
		// (mister-clock-plan R2/R8, video rule "keep raster running through game reset").  Only RGB and vint are gated.
		vint <= 1'b0;
		ph <= tick ? 3'd0 : ph + 1'b1;
		ce_pix <= tick;
		if (tick) begin
			hc <= hn; vc <= vn;
			hblank <= !act_h_n;
			vblank <= !act_v_n;
			hs <= (hn >= 9'd450) && (hn < 9'd490);
			vs <= (vn >= 9'd246) && (vn < 9'd249);
			if (rst) begin r <= 0; g <= 0; b <= 0; end
			else begin r <= rgb_n[7:0]; g <= rgb_n[15:8]; b <= rgb_n[23:16]; end
			if (!rst && hn == 9'd0 && vn == 9'd240) vint <= 1'b1;
		end
	end
endmodule
