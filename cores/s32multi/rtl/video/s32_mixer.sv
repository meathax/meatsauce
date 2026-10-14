//============================================================================
//  System 32 mixer / priority-color stage — 315-5388
//  (DESIGN.md §6.6, Appendix C.8)
//  Per-pixel priority resolution across TEXT/NBG0-3/BITMAP/SPRITE/BACKGROUND
//  with sprite grouping, palette lookup, blending, color offsets and shadow.
//  One instance per screen (Multi 32 = two).
//
//  Line-buffer inputs are written by s32_tilemap; the sprite line comes from
//  the framebuffer line fetcher. This module implements MAME mix_all_layers'
//  effective-priority scheme evaluated directly per pixel:
//    - first  = topmost non-transparent layer (the winner)
//    - second = the scan continued below the winner (blend partner)
//    - blend  = (first*(7-f) + second*(f+1)) >> 3 per 5-bit channel, gated
//               by the winner's blendmask (reg 0x30+2*lay bits 13:6) and,
//               for a sprite partner, sprblendmask over the sprite group
//    - shadow = sprite shadow sources halve final RGB after blending
//  Two palette lookups per pixel are time-multiplexed on the single mixer
//  palette port (a pixel period is ~15 clk_ram; each lookup needs ~5).
//
//  315-5242/M71064 cross-check (Furrtek SiliconRE, silicon-traced): the DAC
//  stays 5-bit end to end (ROUT/GOUT/BOUT, no on-chip expansion), confirming
//  expand5() below is correctly a transport-only conversion for MiSTer/HDMI,
//  not a hardware behaviour to model. Shadow/blank on real silicon is
//  output-enable gating into an analog resistor network (BEXU/BUBU signals),
//  not a digital halving; MAME's `>>1` shadow model is a software
//  abstraction of that already validated against real hardware over decades,
//  and is kept here rather than guessing at undocumented resistor values.
//  OPEN: SiliconRE issue #14 raises a physical-trace concern that the R/G
//  DAC output pins may be swapped relative to the schematic's labels. That
//  is a board-to-connector question the M71064 Verilog itself cannot answer
//  (its internal R/G naming is self-consistent either way) and MAME's
//  channel order -- which this mixer follows -- is the higher-confidence
//  source absent a real-hardware bring-up test. Left as a flagged risk for
//  hardware verification, not changed speculatively.
//============================================================================

module s32_mixer (
    input             clk,          // clk_ram
    input             rst,

    // mixer register file (0x610000/0x690000): 64 words
    input             reg_we,
    input       [5:0] reg_addr,
    input      [15:0] reg_wdata,
    input       [1:0] reg_be,
    output     [15:0] reg_rdata,
    input       [5:0] reg_raddr,
    output     [15:0] reg_r4e,        // 0x4E: palette write-both control (B6)

    // display timing
    input       [8:0] disp_x,
    input       [8:0] disp_y,
    input             disp_active,
    input             frame_latch,   // pulse at vblank start: snapshot color regs
    input             display_en,    // 315-5296 CNT1
    input             flip_y,        // cabinet ORIENTATION_FLIP_Y (backdrop line)
    input       [5:0] layer_off,     // per-layer disable (TEXT,NBG0-3,BITMAP)
    input      [15:0] bg_ctrl,       // VRAM $1FF5E backdrop/line-color select

    // registered pixels from the shared tile/bitmap line buffer
    input      [13:0] px_text,
    input      [13:0] px_nbg0,
    input      [13:0] px_nbg1,
    input      [13:0] px_nbg2,
    input      [13:0] px_nbg3,
    input      [13:0] px_bmp,

    // sprite line pixel (from framebuffer line buffer, already fetched)
    input      [15:0] spr_pix,

    // palette read port (time-multiplexed: first then second lookup)
    output     [13:0] pal_addr,
    input      [15:0] pal_data,

    // final pixel out
    output reg [23:0] rgb
);

// ---------------------------------------------------------------------------
// register file
// ---------------------------------------------------------------------------
reg [15:0] mreg [0:63];
integer __mri;
// MAME video_start memsets mixer_control to 0xFF: unwritten registers read
// 0xFFFF, giving priority 0xF. holo only programs sprite group 0 and relies
// on group 1 (the r4c=0 default group) reading as all-ones — a zero init
// left every sprite at priority 0 and the screen black (real-ROM boot).
initial for(__mri=0;__mri<64;__mri=__mri+1) mreg[__mri]=16'hFFFF;
assign reg_rdata = mreg[reg_raddr];
assign reg_r4e   = mreg[6'h27];   // 0x4E/2
always @(posedge clk) if (reg_we) begin
    if (reg_be[0]) mreg[reg_addr][7:0]  <= reg_wdata[7:0];
    if (reg_be[1]) mreg[reg_addr][15:8] <= reg_wdata[15:8];
end

// ---------------------------------------------------------------------------
// sprite group extraction (reg 0x4C low nibble -> shift/mask/or)
// ---------------------------------------------------------------------------
wire [15:0] r4c = mreg[6'h26];  // 0x4C/2
wire [15:0] r4e = mreg[6'h27];
wire [15:0] r3e = mreg[6'h1f];  // 0x3E/2: color-offset select
reg  [3:0] sprgroup_shift;
reg  [3:0] sprgroup_mask;
reg  [3:0] sprgroup_or;
reg        r4c_use_own_palbase;
reg        r4c_shadow_rmw_en;
initial begin
    sprgroup_shift = 4'd10;
    sprgroup_mask = 4'hf;
    sprgroup_or = 4'h0;
    r4c_use_own_palbase = 1'b1;
    r4c_shadow_rmw_en = 1'b1;
end
always @(posedge clk) if (reg_we && reg_addr == 6'h26 && reg_be[0]) begin
    r4c_use_own_palbase <= (reg_wdata[1:0] == 2'b11);
    r4c_shadow_rmw_en <= reg_wdata[2];
    case (reg_wdata[3:0])
        4'h0: begin sprgroup_shift<=14; sprgroup_mask<=4'h0; sprgroup_or<=4'h1; end
        4'h1: begin sprgroup_shift<=14; sprgroup_mask<=4'h1; sprgroup_or<=4'h2; end
        4'h2: begin sprgroup_shift<=13; sprgroup_mask<=4'h3; sprgroup_or<=4'h4; end
        4'h3: begin sprgroup_shift<=12; sprgroup_mask<=4'h7; sprgroup_or<=4'h8; end
        4'h4: begin sprgroup_shift<=14; sprgroup_mask<=4'h1; sprgroup_or<=4'h0; end
        4'h5: begin sprgroup_shift<=13; sprgroup_mask<=4'h3; sprgroup_or<=4'h0; end
        4'h6: begin sprgroup_shift<=12; sprgroup_mask<=4'h7; sprgroup_or<=4'h0; end
        4'h7: begin sprgroup_shift<=11; sprgroup_mask<=4'hf; sprgroup_or<=4'h0; end
        4'h8: begin sprgroup_shift<=14; sprgroup_mask<=4'h1; sprgroup_or<=4'h0; end
        4'h9: begin sprgroup_shift<=13; sprgroup_mask<=4'h3; sprgroup_or<=4'h0; end
        4'ha: begin sprgroup_shift<=12; sprgroup_mask<=4'h7; sprgroup_or<=4'h0; end
        4'hb: begin sprgroup_shift<=11; sprgroup_mask<=4'hf; sprgroup_or<=4'h0; end
        4'hc: begin sprgroup_shift<=13; sprgroup_mask<=4'h1; sprgroup_or<=4'h0; end
        4'hd: begin sprgroup_shift<=12; sprgroup_mask<=4'h3; sprgroup_or<=4'h0; end
        4'he: begin sprgroup_shift<=11; sprgroup_mask<=4'h7; sprgroup_or<=4'h0; end
        4'hf: begin sprgroup_shift<=10; sprgroup_mask<=4'hf; sprgroup_or<=4'h0; end
    endcase
end

// sprite pixel semantics (MAME mix loop, exactly):
//   transparent when (pix & 0x7fff) == 0x7fff (covers 0xFFFF erase + 0x7FFF)
//   shadow source a: bit15 CLEAR when reg 0x4C bit2 set (RMW shadow sprites)
//   shadow source b: masked pen == sprshadow (0x7ffe & sprpixmask) — the
//     shadow pen: itself transparent, shadows whatever wins beneath
reg  [3:0]  spr_group_raw;
reg  [15:0] sprpixmask;
always @(*) begin
    case (sprgroup_shift)
        4'd14: begin spr_group_raw = {3'b0, spr_pix[14]} & sprgroup_mask; sprpixmask = 16'h3fff; end
        4'd13: begin spr_group_raw = {2'b0, spr_pix[14:13]} & sprgroup_mask; sprpixmask = 16'h1fff; end
        4'd12: begin spr_group_raw = {1'b0, spr_pix[14:12]} & sprgroup_mask; sprpixmask = 16'h0fff; end
        4'd11: begin spr_group_raw = spr_pix[14:11] & sprgroup_mask; sprpixmask = 16'h07ff; end
        default: begin spr_group_raw = spr_pix[13:10] & sprgroup_mask; sprpixmask = 16'h03ff; end
    endcase
end
wire [3:0]  spr_group = sprgroup_or | spr_group_raw;
wire        spr_transp = (spr_pix & 16'h7fff) == 16'h7fff;
wire [15:0] sprshadowpen = 16'h7ffe & sprpixmask;
wire        spr_shadow_pen = !spr_transp &&
                             ((spr_pix & sprpixmask & 16'h7ffe) == sprshadowpen);
wire        spr_shadow_rmw = r4c_shadow_rmw_en && !spr_pix[15];
wire        spr_shadow_src = spr_shadow_pen | spr_shadow_rmw;
wire        spr_opaque = !spr_transp && !spr_shadow_pen;   // can win the scan

// ---------------------------------------------------------------------------
// effective priority per layer:  {prio[3:0], rank[2:0]}
//   ordinary rank: sprites=7, text=6, nbg0=5 ... bitmap=1
//   special low key: backdrop=1
//   layer regs: 0x20+2*lay (TEXT..BITMAP), 0x2C background, 0x00+2*grp sprites
//
// A layer pixel is a mix candidate only when drawn (bit13, "opaque") and its
// layer's programmed priority is nonzero — plain MAME mix_all_layers
// semantics.  $1FF8E[8+bg] no longer reaches the mixer: s32_tilemap now
// resolves that per-NBG pen-0 enable at the tile source, so a masked pen 0
// is never marked drawn here (see titlef-floor-backdrop-root-cause).
// ---------------------------------------------------------------------------
reg [15:0] sprreg;
reg [6:0] ep_spr, ep_text, ep_nbg0, ep_nbg1, ep_nbg2, ep_nbg3, ep_bmp;
reg [6:0] ep_spr_nom;   // sprite order slot regardless of pixel content
// Only relative ordering is consumed.  Keep the backdrop key below every
// ordinary non-zero-priority layer (which is always >= 7'd9).
wire [6:0] ep_bg = 7'd1;
reg [15:0] lr_t, lr_0, lr_1, lr_2, lr_3, lr_b;
always @(*) begin
    sprreg = mreg[{2'b00, spr_group}];
    lr_t = mreg[6'h10]; lr_0 = mreg[6'h11]; lr_1 = mreg[6'h12];
    lr_2 = mreg[6'h13]; lr_3 = mreg[6'h14]; lr_b = mreg[6'h15];
    ep_spr_nom = (sprreg[3:0] != 0) ? {sprreg[3:0], 3'd7} : 7'd0;
    ep_spr  = spr_opaque ? ep_spr_nom : 7'd0;
    // bit13 = drawn/opaque, set for real pixels only.
    // disabled layers never mix (MAME enablemask) — a disabled layer's
    // line buffer keeps stale pixels, so it must be gated here
    ep_text = (!layer_off[0] && px_text[13] && lr_t[3:0] != 0) ? {lr_t[3:0], 3'd6} : 7'd0;
    ep_nbg0 = (!layer_off[1] && px_nbg0[13] && lr_0[3:0] != 0) ? {lr_0[3:0], 3'd5} : 7'd0;
    ep_nbg1 = (!layer_off[2] && px_nbg1[13] && lr_1[3:0] != 0) ? {lr_1[3:0], 3'd4} : 7'd0;
    ep_nbg2 = (!layer_off[3] && px_nbg2[13] && lr_2[3:0] != 0) ? {lr_2[3:0], 3'd3} : 7'd0;
    ep_nbg3 = (!layer_off[4] && px_nbg3[13] && lr_3[3:0] != 0) ? {lr_3[3:0], 3'd2} : 7'd0;
    ep_bmp  = (!layer_off[5] && px_bmp[13]  && lr_b[3:0] != 0) ? {lr_b[3:0], 3'd1} : 7'd0;
end

// The source pixels arrive from registered line/frame buffers, but the full
// two-winner scan plus palette-index arithmetic is much too deep for 96 MHz.
// Snapshot the per-pixel candidates first, then resolve winner, runner-up and
// palette indices on separate clocks.  The 416-wide mode still provides 12
// clk_ram clocks per pixel, so this leaves two clocks of margin.
reg [6:0] ep_spr_s, ep_text_s, ep_nbg0_s, ep_nbg1_s;
reg [6:0] ep_nbg2_s, ep_nbg3_s, ep_bmp_s, ep_spr_nom_s;

// Winner select (8-way max), evaluated from the candidate snapshot. Keep the
// priority key and layer selector together through a balanced tournament. In
// addition to the winner, retain the three opponents it defeated. The largest
// of those opponents is the runner-up, so the following pipeline stage needs
// only two comparisons instead of masking the winner and repeating all seven.
// Rank makes every non-zero key unique.
function automatic [10:0] max_candidate(input [10:0] a, input [10:0] b);
    max_candidate = (a[10:4] > b[10:4]) ? a : b;
endfunction

wire [10:0] cand_spr  = {ep_spr_s,  4'd6};
wire [10:0] cand_text = {ep_text_s, 4'd0};
wire [10:0] cand_nbg0 = {ep_nbg0_s, 4'd1};
wire [10:0] cand_nbg1 = {ep_nbg1_s, 4'd2};
wire [10:0] cand_nbg2 = {ep_nbg2_s, 4'd3};
wire [10:0] cand_nbg3 = {ep_nbg3_s, 4'd4};
wire [10:0] cand_bmp  = {ep_bmp_s,  4'd5};
wire [10:0] cand_bg   = {ep_bg,     4'd7};

wire p0_left_wins = ep_spr_s  > ep_text_s;
wire p1_left_wins = ep_nbg0_s > ep_nbg1_s;
wire p2_left_wins = ep_nbg2_s > ep_nbg3_s;
wire p3_left_wins = ep_bmp_s  > ep_bg;
wire [10:0] win_p0  = p0_left_wins ? cand_spr  : cand_text;
wire [10:0] lose_p0 = p0_left_wins ? cand_text : cand_spr;
wire [10:0] win_p1  = p1_left_wins ? cand_nbg0 : cand_nbg1;
wire [10:0] lose_p1 = p1_left_wins ? cand_nbg1 : cand_nbg0;
wire [10:0] win_p2  = p2_left_wins ? cand_nbg2 : cand_nbg3;
wire [10:0] lose_p2 = p2_left_wins ? cand_nbg3 : cand_nbg2;
wire [10:0] win_p3  = p3_left_wins ? cand_bmp  : cand_bg;
wire [10:0] lose_p3 = p3_left_wins ? cand_bg   : cand_bmp;

wire q0_left_wins = win_p0[10:4] > win_p1[10:4];
wire q1_left_wins = win_p2[10:4] > win_p3[10:4];
wire [10:0] win_q0 = q0_left_wins ? win_p0 : win_p1;
wire [10:0] win_q1 = q1_left_wins ? win_p2 : win_p3;
wire [10:0] lose_q0_first = q0_left_wins ? lose_p0 : lose_p1;
wire [10:0] lose_q1_first = q1_left_wins ? lose_p2 : lose_p3;
wire [10:0] lose_q0_second = q0_left_wins ? win_p1 : win_p0;
wire [10:0] lose_q1_second = q1_left_wins ? win_p3 : win_p2;

wire final_left_wins = win_q0[10:4] > win_q1[10:4];
wire [10:0] win_max = final_left_wins ? win_q0 : win_q1;
wire [10:0] win_loser_first = final_left_wins ? lose_q0_first : lose_q1_first;
wire [10:0] win_loser_second = final_left_wins ? lose_q0_second : lose_q1_second;
wire [10:0] win_loser_final = final_left_wins ? win_q1 : win_q0;
wire [6:0] best = win_max[10:4];
wire [3:0] bestsel = win_max[3:0]; // 0=text 1..4 nbg 5 bmp 6 spr 7 bg

reg [6:0] best_hold, best2_hold;
reg [3:0] bestsel_hold, best2sel_hold;
reg [10:0] runner_first_hold, runner_second_hold, runner_final_hold;

// The only possible runner-up is one of the three candidates that lost
// directly to the winner. Resolve those registered opponents here. When all
// three keys are zero, background was the winner and there is no opaque blend
// partner; retain the old tree's background selector sentinel in that case.
wire [10:0] run_pair = max_candidate(runner_first_hold, runner_second_hold);
wire [10:0] run_opponent_max = max_candidate(run_pair, runner_final_hold);
wire [10:0] run_max = (run_opponent_max[10:4] == 7'd0)
                    ? {7'd0, 4'd7} : run_opponent_max;
wire [6:0] best2 = run_max[10:4];
wire [3:0] best2sel = run_max[3:0];

// ---------------------------------------------------------------------------
// backdrop pixel (MAME update_background): per line.  This control belongs
// to video RAM at $1FF5E, not to the mixer's unrelated $5E register.
//   bit15 ? (bg_ctrl & 0x1e00) + ((bg_ctrl + y) & 0x1ff)
//         : (bg_ctrl & 0x1e00)
// ---------------------------------------------------------------------------
// Under the cabinet ORIENTATION_FLIP_Y adapter the backdrop line-color gradient
// must index the CRAM table in game coordinates (223 - y), like the tile and
// sprite source lines; the constant-backdrop mode (bit15=0) is unaffected
// (audit R20 TM-2 / SP-4).
wire [8:0] bg_line = (flip_y && disp_y < 9'd224) ? (9'd223 - disp_y) : disp_y;
wire [13:0] bg_pen = {1'b0, bg_ctrl[12:9], 9'b0}
                   + (bg_ctrl[15] ? {5'b0, (bg_ctrl[8:0] + bg_line) & 9'h1ff} : 14'd0);

// ---------------------------------------------------------------------------
// per-layer palette info: palbase nibble, mixshift, 14-bit pen
//   index = palbase + ((pen >> shift) & 0x3ff0) + (pen & 0xf)   (wraps 14 bit)
//   sprite: palbase from group reg unless (0x4C & 3) == 3 (then from 0x4C);
//           mixshift always from the group reg
// NOTE: the layer mux must be an explicit always@(*) reading the signals
// directly — hiding them inside a function called from a continuous assign
// leaves them out of the sensitivity list (iverilog) and the index goes stale.
// ---------------------------------------------------------------------------
wire [15:0] lr_bg = mreg[6'h16];
wire [19:0] li_text = {lr_t[7:4], lr_t[9:8], 1'b0, px_text[12:0]};
wire [19:0] li_nbg0 = {lr_0[7:4], lr_0[9:8], 1'b0, px_nbg0[12:0]};
wire [19:0] li_nbg1 = {lr_1[7:4], lr_1[9:8], 1'b0, px_nbg1[12:0]};
wire [19:0] li_nbg2 = {lr_2[7:4], lr_2[9:8], 1'b0, px_nbg2[12:0]};
wire [19:0] li_nbg3 = {lr_3[7:4], lr_3[9:8], 1'b0, px_nbg3[12:0]};
wire [19:0] li_bmp  = {lr_b[7:4], lr_b[9:8], 1'b0, px_bmp[12:0]};
wire [19:0] li_spr  = {r4c_use_own_palbase ? r4c[7:4] : sprreg[7:4],
                       sprreg[9:8], spr_pix[13:0] & sprpixmask[13:0]};
wire [19:0] li_bg   = {lr_bg[7:4], lr_bg[9:8], bg_pen};

function automatic [13:0] mk_palidx(input [19:0] li);
    reg [13:0] shifted_pen;
    begin
        case (li[15:14])
            2'd0: shifted_pen = {li[13:4], 4'b0};
            2'd1: shifted_pen = {1'b0, li[13:5], 4'b0};
            2'd2: shifted_pen = {2'b0, li[13:6], 4'b0};
            default: shifted_pen = {3'b0, li[13:7], 4'b0};
        endcase
        // shifted_pen has a zero low nibble, so inserting the original low
        // nibble before the palette-base addition is equivalent to two adds.
        mk_palidx = {li[19:16], 10'b0}
                  + (shifted_pen | {10'b0, li[3:0]});
    end
endfunction

// Do the variable shift and palette-base addition before the candidate
// snapshot. The priority tree then drives only a shallow 8:1 index mux.
reg [13:0] idx_text_s, idx_nbg0_s, idx_nbg1_s, idx_nbg2_s;
reg [13:0] idx_nbg3_s, idx_bmp_s, idx_spr_s, idx_bg_s;
reg [19:0] li_spr_s;
reg [13:0] idx_winner, idx_runner;
always @(*) begin
    case (bestsel_hold)
        4'd0: idx_winner = idx_text_s; 4'd1: idx_winner = idx_nbg0_s;
        4'd2: idx_winner = idx_nbg1_s; 4'd3: idx_winner = idx_nbg2_s;
        4'd4: idx_winner = idx_nbg3_s; 4'd5: idx_winner = idx_bmp_s;
        4'd6: idx_winner = idx_spr_s; default: idx_winner = idx_bg_s;
    endcase
    case (best2sel_hold)
        4'd0: idx_runner = idx_text_s; 4'd1: idx_runner = idx_nbg0_s;
        4'd2: idx_runner = idx_nbg1_s; 4'd3: idx_runner = idx_nbg2_s;
        4'd4: idx_runner = idx_nbg3_s; 4'd5: idx_runner = idx_bmp_s;
        4'd6: idx_runner = idx_spr_s; default: idx_runner = idx_bg_s;
    endcase
end

// ---------------------------------------------------------------------------
// blend controls (reg 0x4E: bit11 enable, bits 10:8 factor;
//   winner's reg 0x30+2*lay: bits 13:6 blendmask, bits 5:0 sprite-group code)
// ---------------------------------------------------------------------------
reg         blendenable_s;
reg  [2:0]  blendfactor_s;
reg  [15:0] wblendreg_hold;
wire        winner_blends = (bestsel_hold <= 4'd5);
wire [7:0]  blendmask   = (blendenable_s && winner_blends) ? wblendreg_hold[13:6] : 8'h00;

// compute_sprite_blend: mm=(enc>>4)&3, v=enc&0xf
reg [15:0] sprblendmask;
always @(*) begin
    case (wblendreg_hold[5:4])
        2'b00: sprblendmask = 16'h1 << wblendreg_hold[3:0];
        2'b01: sprblendmask = (16'h1 << wblendreg_hold[3:0]) | ((16'h1 << wblendreg_hold[3:0]) - 16'h1);
        2'b10: sprblendmask = ~((16'h1 << wblendreg_hold[3:0]) - 16'h1);
        2'b11: sprblendmask = 16'hffff;
    endcase
end

reg [3:0] spr_group_raw_s;
// MAME uses the raw pixel-derived group for the per-layer sprite blend
// mask. sprgroup_or selects the effective priority/palette register only.
wire do_blend_resolved = blendmask[best2sel_hold[2:0]] &&
                         (best2sel_hold != 4'd6 || sprblendmask[spr_group_raw_s]);

// shadow applies when the scan passes the sprite layer's order slot:
//   scan 1 (always): sprite at/above the winner
//   scan 2 (only when the winner has blends): sprite below winner, at/above
//   the partner — MAME's second loop re-evaluates shadow identically
reg spr_shadow_src_s;
wire shadow_resolved = spr_shadow_src_s && (ep_spr_nom_s != 0) &&
                       ( ep_spr_nom_s >= best_hold ||
                         (blendmask != 8'h00 && bestsel_hold != 4'd6 && ep_spr_nom_s >= best2_hold) );

// ---------------------------------------------------------------------------
// color offsets: rgboffs bank0 = regs 0x40-0x44, bank1 = 0x46-0x4A, bank2 = 0
//   mode = {r3e[15], r3e[laybit]}  (laybit = laynum, bg uses bit 8)
//   layerflag: text..bitmap = reg(0x30+2*lay) bit14; sprites = 0x4C bit15;
//              background = 0x3E bit14
//   mode 0/3 -> bank !layerflag; mode 1 -> bank 2; mode 2 -> !flag ? 2 : 0
// ---------------------------------------------------------------------------
wire [5:0] layer_color_flags = {mreg[6'h1d][14], mreg[6'h1c][14],
                                mreg[6'h1b][14], mreg[6'h1a][14],
                                mreg[6'h19][14], mreg[6'h18][14]};
reg [15:0] r3e_s;
reg        r4c15_s;
reg  [5:0] layer_color_flags_s;
wire [17:0] coloroffs_bank0_live = {mreg[6'h22][5:0], mreg[6'h21][5:0],
                                    mreg[6'h20][5:0]};
wire [17:0] coloroffs_bank1_live = {mreg[6'h25][5:0], mreg[6'h24][5:0],
                                    mreg[6'h23][5:0]};

// Color offset select ($3E), the per-layer offset flags and both offset banks
// are whole-frame quantities.  Reading them live let a mid-frame CPU write
// change the offset applied partway down the screen, splitting the picture
// into horizontal bands of differently-tinted output; games toggle the $3E
// bank select every frame to dither between two shades on a CRT, so the split
// was visible constantly (arabfgt ocean, cutscene sky).  MAME reads mixer
// control once per frame, after the frame is complete.  Snapshot at vblank.
reg [15:0] r3e_f;
reg        r4c15_f;
reg  [5:0] layer_color_flags_f;
reg [17:0] coloroffs_bank0;
reg [17:0] coloroffs_bank1;
initial begin
    r3e_f = 16'hFFFF;
    r4c15_f = 1'b1;
    layer_color_flags_f = 6'h3F;
    coloroffs_bank0 = 18'h3FFFF;
    coloroffs_bank1 = 18'h3FFFF;
end
always @(posedge clk) if (frame_latch) begin
    r3e_f               <= r3e;
    r4c15_f             <= r4c[15];
    layer_color_flags_f <= layer_color_flags;
    coloroffs_bank0     <= coloroffs_bank0_live;
    coloroffs_bank1     <= coloroffs_bank1_live;
end

// All dependencies are explicit function arguments.  Quartus 17 can omit
// global signals referenced only from inside an automatic function (it
// previously reported r3e as assigned-but-never-read), silently removing the
// color-offset mode logic from hardware.
function automatic [1:0] coloroffs_of(
    input [3:0]  sel,
    input [15:0] ctl3e,
    input        sprite_flag,
    input [5:0]  layer_flags
);
    logic laybit, lflag;
    case (sel)
        4'd0: begin laybit = ctl3e[0]; lflag = layer_flags[0]; end
        4'd1: begin laybit = ctl3e[1]; lflag = layer_flags[1]; end
        4'd2: begin laybit = ctl3e[2]; lflag = layer_flags[2]; end
        4'd3: begin laybit = ctl3e[3]; lflag = layer_flags[3]; end
        4'd4: begin laybit = ctl3e[4]; lflag = layer_flags[4]; end
        4'd5: begin laybit = ctl3e[5]; lflag = layer_flags[5]; end
        4'd6: begin laybit = ctl3e[6]; lflag = sprite_flag;   end
        default: begin laybit = ctl3e[8]; lflag = ctl3e[14]; end
    endcase
    case ({ctl3e[15], laybit})
        2'b00, 2'b11: coloroffs_of = {1'b0, ~lflag};
        2'b01:        coloroffs_of = 2'd2;
        default:      coloroffs_of = lflag ? 2'd0 : 2'd2;
    endcase
endfunction

function automatic signed [5:0] off_chan(
    input [1:0]  bank,
    input [1:0]  ch,
    input [17:0] bank0,
    input [17:0] bank1
);
    case (bank)
        2'd0: case (ch)
            2'd0:    off_chan = $signed(bank0[5:0]);
            2'd1:    off_chan = $signed(bank0[11:6]);
            default: off_chan = $signed(bank0[17:12]);
        endcase
        2'd1: case (ch)
            2'd0:    off_chan = $signed(bank1[5:0]);
            2'd1:    off_chan = $signed(bank1[11:6]);
            default: off_chan = $signed(bank1[17:12]);
        endcase
        default: off_chan = 6'sd0;
    endcase
endfunction

// ---------------------------------------------------------------------------
// pixel pipeline: two palette lookups per pixel, then MAME's 5-bit-domain
// arithmetic. Palette port is registered directly on clk_ram; the existing
// schedule retains ample margin around its one-clock registered address.
// Pixel period is 12 clk_ram in 416 mode and >= 14 in 320 mode.
//   T0 (disp_x changes): synchronous line-RAM read is issued
//   T1: snapshot candidates from the RAM outputs
//   T2: resolve/register winner and finish the sprite palette index
//   T3: resolve/register blend partner and issue the winner palette lookup
//   T4: latch the runner palette index and final context
//   P0: present the second palette index; the first address has already been
//       registered for a full clk_ram edge, so its data is in flight
//   P2: capture the first pixel before the earliest second result can replace it
//   P4: apply both color-offset banks (entered directly from P2; the former P3
//       bubble cost the 416-mode picture one pixel of horizontal alignment)
//   P5: blend and apply shadow
//   P6: clamp and register rgb
// ---------------------------------------------------------------------------
reg [8:0]  dx_d;
reg [3:0]  ph;
reg        pixel_changed;
reg        winner_pending;
reg        second_pending;
reg        context_pending;
reg [13:0] pal_addr_r;
reg [15:0] pal_data_r;
reg [15:0] first_pal;
reg [13:0] idx2_hold;
reg        blend_hold, shadow_hold, act_hold;
reg [1:0]  co1_hold, co2_hold;
reg signed [7:0] r1_pipe, g1_pipe, b1_pipe;
reg signed [7:0] r2_pipe, g2_pipe, b2_pipe;
reg signed [11:0] rr_pipe, gg_pipe, bb_pipe;
assign pal_addr = pal_addr_r;

function automatic [4:0] clamp5(input signed [11:0] v);
    if (v > 12'sd31)     clamp5 = 5'd31;
    else if (v < 12'sd0) clamp5 = 5'd0;
    else                 clamp5 = v[4:0];
endfunction

// 315-5242 presents each clamped 5-bit DAC component as a full-scale 8-bit
// HDMI component.  This is the standard pal5bit expansion used by MAME:
// replicate the upper three bits into the low three bits so 5'b11111 becomes
// 8'hff (not 8'hf8).  Keep the expansion after all mixer arithmetic and
// clamping; it is a transport-boundary conversion, not a palette change.
function automatic [7:0] expand5(input [4:0] v);
    expand5 = {v, v[4:2]};
endfunction

// MAME applies signed color offsets before blending and clamps only after the
// weighted sum.  An offset channel can therefore be -32..62.  Letting the
// expression inherit the eight-bit width of r1/r2 truncates products above
// 127 (the simple no-offset directed case never exposed this).  Widen both
// samples and coefficients before multiplication so the complete pre-clamp
// range survives exactly.
function automatic signed [11:0] blend_chan(
    input signed [7:0] first,
    input signed [7:0] second,
    input        [2:0] factor
);
    logic signed [15:0] first_w, second_w;
    logic signed [15:0] first_coeff, second_coeff;
    logic signed [15:0] weighted;
    begin
        first_w = {{8{first[7]}}, first};
        second_w = {{8{second[7]}}, second};
        first_coeff = 16'sd7 - $signed({1'b0, factor});
        second_coeff = $signed({1'b0, factor}) + 16'sd1;
        weighted = first_w * first_coeff + second_w * second_coeff;
        blend_chan = weighted >>> 3;
    end
endfunction

// Keep the palette-address launch mux independent of the pixel-start
// qualifier below.  When pal_addr_r lived in the main priority chain,
// Quartus folded (disp_x != dx_d) and every intervening state test into the
// register's enable/data cone.  Both launch points are already identified by
// registered state, so this small dedicated block preserves the exact lookup
// edges while removing display X from the palette-address timing path.
always @(posedge clk) begin
    if (rst)
        pal_addr_r <= 14'd0;
    else if (second_pending)
        pal_addr_r <= idx_winner;
    else if (ph == 4'd0)
        pal_addr_r <= idx2_hold;
end

always @(posedge clk) begin
    logic signed [11:0] rr, gg, bb;

    dx_d <= disp_x;
    // mix_disp_x_cdc is updated on the opposite clk_ram edge.  Register the
    // change indication here before it fans into the wide candidate snapshot
    // bank.  This preserves the existing T1 snapshot edge while replacing a
    // half-cycle disp_x comparator/enable path with one full-cycle strobe.
    pixel_changed <= (disp_x != dx_d);
    // Register the palette output before the offset/blend DSP chain.
    pal_data_r <= pal_data;
    if (rst) begin
        ph <= 4'hF;
        pixel_changed <= 1'b0;
        winner_pending <= 1'b0;
        second_pending <= 1'b0;
        context_pending <= 1'b0;
        rgb <= 24'h000000;
    end
    else if (pixel_changed) begin
        // The line memories sampled disp_x on the preceding edge. Their
        // registered outputs are now stable, so snapshot all candidates.
        ep_spr_s     <= ep_spr;
        ep_text_s    <= ep_text;
        ep_nbg0_s    <= ep_nbg0;
        ep_nbg1_s    <= ep_nbg1;
        ep_nbg2_s    <= ep_nbg2;
        ep_nbg3_s    <= ep_nbg3;
        ep_bmp_s     <= ep_bmp;
        ep_spr_nom_s <= ep_spr_nom;
        idx_text_s   <= mk_palidx(li_text);
        idx_nbg0_s   <= mk_palidx(li_nbg0);
        idx_nbg1_s   <= mk_palidx(li_nbg1);
        idx_nbg2_s   <= mk_palidx(li_nbg2);
        idx_nbg3_s   <= mk_palidx(li_nbg3);
        idx_bmp_s    <= mk_palidx(li_bmp);
        // The sprite line comes directly from the framebuffer M10K.  Retain
        // its compact palette-info word here, then perform the shift/add on
        // the following edge.  This uses the existing winner stage and keeps
        // the M10K output out of the palette-index arithmetic timing cone.
        li_spr_s     <= li_spr;
        idx_bg_s     <= mk_palidx(li_bg);
        spr_group_raw_s <= spr_group_raw;
        spr_shadow_src_s <= spr_shadow_src;
        blendenable_s <= r4e[11];
        blendfactor_s <= r4e[10:8];
        r3e_s <= r3e_f;
        r4c15_s <= r4c15_f;
        layer_color_flags_s <= layer_color_flags_f;
        act_hold <= disp_active & display_en;
        winner_pending <= 1'b1;
        second_pending <= 1'b0;
        context_pending <= 1'b0;
        ph <= 4'hF;
    end
    else if (winner_pending) begin
        idx_spr_s <= mk_palidx(li_spr_s);
        best_hold <= best;
        bestsel_hold <= bestsel;
        runner_first_hold <= win_loser_first;
        runner_second_hold <= win_loser_second;
        runner_final_hold <= win_loser_final;
        winner_pending <= 1'b0;
        second_pending <= 1'b1;
    end
    else if (second_pending) begin
        // bestsel_hold was registered on the preceding edge. Keeping the
        // dynamic mixer-register lookup here prevents the balanced winner
        // tree and 64:1 register mux from becoming one 96 MHz timing path.
        wblendreg_hold <= mreg[6'h18 + {2'b0, bestsel_hold}];
        // Register the three-opponent runner result before the palette-index
        // and blend-control muxes. This removes the winner-mask cone and five
        // redundant 7-bit comparisons from the path toward idx2_hold.
        best2_hold    <= best2;
        best2sel_hold <= best2sel;
        // bestsel_hold and every palette index are now registered.  Issue the
        // first lookup here so the priority tournament no longer feeds the
        // palette-address register in the same cycle.  The existing P2 sample
        // remains four clocks later, preserving the output-pixel schedule.
        second_pending <= 1'b0;
        context_pending <= 1'b1;
    end
    else if (context_pending) begin
        idx2_hold   <= idx_runner;
        blend_hold  <= do_blend_resolved;
        shadow_hold <= shadow_resolved;
        co1_hold    <= coloroffs_of(bestsel_hold,  r3e_s, r4c15_s, layer_color_flags_s);
        co2_hold    <= coloroffs_of(best2sel_hold, r3e_s, r4c15_s, layer_color_flags_s);
        context_pending <= 1'b0;
        ph <= 4'd0;
    end
    else if (ph != 4'hF) begin
        ph <= ph + 1'd1;
        if (ph == 4'd0) begin
            // The first address was issued in the partner stage. Switch now so
            // the second registered lookup is available well before P4.
        end
        else if (ph == 4'd2) begin
            first_pal <= pal_data_r;
            // Skip the former P3 bubble.  pal_data_r already holds the second
            // lookup on the next edge, and first_pal is captured here, so P4
            // has every input it needs one clock earlier.  With the bubble a
            // pixel took 13 clk_ram edges from the display-X change — one more
            // than the 12-edge 416-wide pixel period — so the display sampled
            // the previous pixel and the whole 416-wide picture came out one
            // column right of MAME.  320-wide mode (15 edges) had slack and
            // never showed it.  No combinational path grows; only this phase
            // decode moves.  tb_mixer_pixel_latency pins the 12-edge budget.
            ph <= 4'd4;
        end
        else if (ph == 4'd4) begin
            // Keep the offset-bank muxes out of the DSP/clamp path.
            r1_pipe <= $signed({3'b0, first_pal[4:0]})
                     + off_chan(co1_hold, 2'd0, coloroffs_bank0, coloroffs_bank1);
            g1_pipe <= $signed({3'b0, first_pal[9:5]})
                     + off_chan(co1_hold, 2'd1, coloroffs_bank0, coloroffs_bank1);
            b1_pipe <= $signed({3'b0, first_pal[14:10]})
                     + off_chan(co1_hold, 2'd2, coloroffs_bank0, coloroffs_bank1);
            r2_pipe <= $signed({3'b0, pal_data_r[4:0]})
                     + off_chan(co2_hold, 2'd0, coloroffs_bank0, coloroffs_bank1);
            g2_pipe <= $signed({3'b0, pal_data_r[9:5]})
                     + off_chan(co2_hold, 2'd1, coloroffs_bank0, coloroffs_bank1);
            b2_pipe <= $signed({3'b0, pal_data_r[14:10]})
                     + off_chan(co2_hold, 2'd2, coloroffs_bank0, coloroffs_bank1);
        end
        else if (ph == 4'd5) begin
            // Preserve MAME's order: offset, blend, then shadow.
            if (blend_hold) begin
                rr = blend_chan(r1_pipe, r2_pipe, blendfactor_s);
                gg = blend_chan(g1_pipe, g2_pipe, blendfactor_s);
                bb = blend_chan(b1_pipe, b2_pipe, blendfactor_s);
            end
            else begin
                rr = r1_pipe; gg = g1_pipe; bb = b1_pipe;
            end
            if (shadow_hold) begin
                rr = rr >>> 1; gg = gg >>> 1; bb = bb >>> 1;
            end
            rr_pipe <= rr;
            gg_pipe <= gg;
            bb_pipe <= bb;
        end
        else if (ph == 4'd6) begin
            rgb <= !act_hold ? 24'h000000
                 : {expand5(clamp5(rr_pipe)),
                    expand5(clamp5(gg_pipe)),
                    expand5(clamp5(bb_pipe))};
            ph <= 4'hF;
        end
    end
end

endmodule
