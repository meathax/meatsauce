// -----------------------------------------------------------------------------
// tms34010_core.sv
//
// Top-level TMS34010 core wrapper. Phase 3 — decode skeleton integrated.
//
// What this module IS, today:
//   - A clocked top-level entity with explicit synchronous active-high reset.
//   - A typed-enum core FSM that fully cycles: CORE_RESET → CORE_FETCH →
//     CORE_DECODE → CORE_EXECUTE → CORE_WRITEBACK → CORE_FETCH (no
//     instruction touches memory in Phase 3, so CORE_MEMORY is unused).
//   - Memory IF that drives `mem_addr` from the PC register and asserts a
//     16-bit fetch in CORE_FETCH. On mem_ack the fetched word is latched
//     into `instr_word_q` and the PC advances by INSTR_WORD_BITS.
//   - A tms34010_decode instance evaluates `instr_word_q` combinationally.
//     Phase 3 skeleton: every encoding is flagged ILLEGAL.
//   - Sticky `illegal_opcode_o` observability output.
//   - Register file, ALU, and status register instantiated and connected
//     into the datapath: ALU result → regfile write-data port, ALU flags
//     → status-register flag-update port. All "go" signals (rf_wr_en,
//     st_flag_update_en, st_write_en) are currently tied to 0 — no
//     instruction is yet decoded into a real datapath action. Task 0012
//     replaces these tie-offs with decoded-instruction-driven values for
//     the first real instruction (MOVI).
//
// What this module IS NOT, yet:
//   - No real instruction decoded. EXECUTE / WRITEBACK are pass-through
//     states; the datapath stays at quiescent values.
//   - No branches / jumps yet, so the PC `load_en` port is tied 0.
//   - The PC starts at `RESET_PC` from the package, currently a placeholder
//     '0 — see docs/assumptions.md A0008 for the architectural reset-vector
//     fetch sequence that is Phase 8 work.
//
// Synthesis notes:
//   - One sequential `always_ff` for the state register.
//   - One `always_comb` for next-state and combinational outputs, with safe
//     defaults at the top to prevent latch inference.
//   - No `/`, `%`, runtime loops, or `initial` blocks.
//   - Reset is synchronous active-high (project convention A0003).
//
// Spec source: third_party/TMS34010_Info/docs/ti-official/
//              1988_TI_TMS34010_Users_Guide.pdf
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_core
  import tms34010_pkg::*;
#(
  // smashtv: when 1, reset fetches the 32-bit PC from the architectural reset
  // vector at 0xFFFFFFE0 (the real TMS34010 boot sequence). When 0 (upstream
  // default) reset jumps straight to RESET_PC — the contract the upstream unit
  // testbenches rely on (program at word 0). Set 1 for the Smash TV core.
  parameter bit RESET_VECTOR_FETCH = 1'b0,
  // Instruction pacing: minimum clk cycles between instruction fetches
  // (0 = unpaced). This is a floor around the core's existing multi-cycle
  // execution, not a direct crystal-clock divider, so hardware tops calibrate
  // it against reference CPU/video markers. NARC Z-unit uses 4.
  parameter int unsigned PACE_CLKS = 0
)(
  input  logic                                clk,
  input  logic                                rst,

  // smashtv external interrupt sources. DI is a 1-cycle pulse (device-internal
  // display interrupt). INT1/INT2 are the external request-line LEVELS whose
  // INTPEND bits follow them (default 0 => unchanged behaviour for the upstream
  // unit tests that leave them unconnected).
  input  logic                                ext_dint_set,   // display interrupt (pulse)
  input  logic                                ext_int1_line,  // external int 1 line level (blitter)
  input  logic                                ext_int2_line,  // external int 2 line level (unused)
  input  logic                                ext_halt,       // freeze at instr boundary (pause)

  // Live video-timing counters from smashtv_video (threaded to io_regs so
  // code that polls HCOUNT/VCOUNT sees the real pixel-clock position).
  input  logic [15:0]                         hcount_i,       // live HCOUNT
  input  logic [15:0]                         vcount_i,       // live VCOUNT
  // DPYINT scanline register forwarded to the external video module so it can
  // fire the display interrupt at the correct line, not just vblank.
  output logic [15:0]                         dpyint_o,
  output logic [15:0]                         dpyctl_o,
  output logic [15:0]                         dpystart_o,
  output logic [15:0]                         dpytap_o,
  output logic [15:0]                         dpyadr_o,

  // Memory request/valid interface (stub in Phase 0 skeleton).
  output logic                                mem_req,
  output logic                                mem_we,
  output logic [ADDR_WIDTH-1:0]               mem_addr,
  output logic [FIELD_SIZE_WIDTH-1:0]         mem_size,
  output logic [DATA_WIDTH-1:0]               mem_wdata,
  input  logic [DATA_WIDTH-1:0]               mem_rdata,
  input  logic                                mem_ack,

  // Observability for testbenches (Phase 0..3 — may move to an
  // sva/observability bundle later).
  output core_state_t                         state_o,
  output logic [ADDR_WIDTH-1:0]               pc_o,
  // Architectural PC of the instruction currently held in instr_word_o.
  // pc_o is the live next-fetch PC and is therefore one instruction ahead
  // during accepted data-bus cycles; instr_pc_o is for trace attribution only.
  output logic [ADDR_WIDTH-1:0]               instr_pc_o,
  output instr_word_t                         instr_word_o,
  output logic                                illegal_opcode_o
);

  // Pixel-processing operation (PPOP) — f(src,dest) per CONTROL.PPOP — now lives
  // in tms34010_pkg (imported above) so the core and unit tests share one
  // MAME-exact definition. Called by all five graphics engines below.

  // ---------------------------------------------------------------------------
  // Program counter
  // ---------------------------------------------------------------------------
  logic                  pc_advance_en;
  logic                  pc_load_en;
  logic [ADDR_WIDTH-1:0] pc_load_value;
  logic [ADDR_WIDTH-1:0] pc_value;
  logic [ADDR_WIDTH-1:0] instr_pc_q;

  tms34010_pc u_pc (
    .clk            (clk),
    .rst            (rst),
    .load_en        (pc_load_en),
    .load_value     (pc_load_value),
    .advance_en     (pc_advance_en),
    .advance_amount ({{(PC_ADVANCE_WIDTH-FIELD_SIZE_WIDTH){1'b0}}, INSTR_WORD_BITS}),
    .pc_o           (pc_value)
  );

  // ---------------------------------------------------------------------------
  // State register
  // ---------------------------------------------------------------------------
  core_state_t state_q;
  core_state_t state_d;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= CORE_RESET;
    end else begin
      state_q <= state_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Instruction word latch + decoder
  //
  // instr_word_q is latched the cycle the memory acks an instruction
  // fetch. The decoder runs combinationally; consumers see the decoded
  // result from CORE_DECODE onward.
  // ---------------------------------------------------------------------------
  instr_word_t    instr_word_q;
  decoded_instr_t decoded;

  always_ff @(posedge clk) begin
    if (rst) begin
      instr_word_q <= '0;
    end else if (state_q == CORE_FETCH && ic_fetch_done) begin
      instr_word_q <= ic_fetch_word;   // word from the instruction cache
    end
  end

  tms34010_decode u_decode (
    .instr  (instr_word_q),
    .decoded(decoded)
  );

  // Sticky illegal-opcode latch. Set on the cycle we are in CORE_DECODE
  // with an illegal `decoded`. Cleared only by reset.
  logic illegal_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      illegal_q <= 1'b0;
    end else if (state_q == CORE_DECODE && decoded.illegal) begin
      illegal_q <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Branch-target computation (PC-relative, short form)
  //
  // For JRUC short and (future) JRcc short: the displacement in
  // instr_word_q[7:0] is a signed 8-bit count of 16-bit words. The new PC
  // is `current_pc + disp * 16` (in bits). `current_pc` is the value AFTER
  // the opcode fetch already advanced the PC by 16, which matches what
  // hand-decoding `JRGT L5 = 0xC70B` at PC=0x3B0 → target 0x470 produces
  // (target = (0x3B0+16) + 11*16 = 0x470).
  //
  // The full target is computed combinationally and only consumed when
  // the FSM is in CORE_WRITEBACK with a taken-branch decoded class.
  // ---------------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] branch_target_short;
  logic signed [INSTR_WORD_WIDTH-1:0] disp_signed_12;
  // {disp8, 4'h0} = disp * 16 expressed in 12 bits, sign-bit at [11].
  assign disp_signed_12   = $signed({{4{instr_word_q[7]}}, instr_word_q[7:0], 4'h0});
  assign branch_target_short = pc_value +
         {{(ADDR_WIDTH-INSTR_WORD_WIDTH){disp_signed_12[INSTR_WORD_WIDTH-1]}}, disp_signed_12};

  // Immediate latches — declared up here (before their first use in
  // the branch_target_long / branch_target_jacc combinational
  // computations below) because Questa is strict about forward
  // references in `assign` statements, even though Verilator hoists
  // them. The matching `always_ff` that actually latches imm_lo_q /
  // imm_hi_q on memory acks lives further down (search for
  // CORE_FETCH_IMM_LO / CORE_FETCH_IMM_HI).
  instr_word_t imm_lo_q;
  instr_word_t imm_hi_q;
  instr_word_t abs2_lo_q;
  instr_word_t abs2_hi_q;

  // Long-form JRcc target: PC_after_both_fetches + sign_extend(disp16) × 16.
  // By the time the FSM hits CORE_WRITEBACK, pc_value already equals
  // (PC_original + 32 bits) — the opcode FETCH and the IMM_LO FETCH each
  // advanced the PC by 16. `imm_lo_q` holds the 16-bit displacement word.
  // {disp16, 4'h0} is a 20-bit value; sign bit at [19] equals imm_lo_q[15].
  logic [ADDR_WIDTH-1:0]   branch_target_long;
  logic signed [19:0]      disp_signed_20;
  assign disp_signed_20   = $signed({imm_lo_q, 4'h0});
  assign branch_target_long = pc_value +
         {{(ADDR_WIDTH-20){disp_signed_20[19]}}, disp_signed_20};

  // JAcc absolute target: PC ← address with the bottom 4 bits forced to 0
  // (spec page 12-91 explicitly: "lower four bits of the program counter
  // are set to 0"). Address is assembled from the two 16-bit imm words
  // already fetched via needs_imm32, same as MOVI IL.
  logic [ADDR_WIDTH-1:0] branch_target_jacc;
  assign branch_target_jacc = {imm_hi_q, imm_lo_q[INSTR_WORD_WIDTH-1:4], 4'h0};

  // DSJS short-form target: PC' ± offset×16 bits.
  // pc_value at CORE_WRITEBACK already equals PC' (= PC_original + 16
  // after the single-word opcode fetch). instr_word_q[10] is the
  // direction bit; instr_word_q[9:5] is the 5-bit unsigned offset.
  logic [ADDR_WIDTH-1:0] branch_target_dsjs;
  logic signed [9:0]     dsjs_disp_bits;
  // Build positive bit-offset = {1'b0, offset5, 4'h0} (signed 10-bit
  // value in [0, +496]), then negate when D=1.
  assign dsjs_disp_bits = instr_word_q[10]
                        ? -$signed({1'b0, instr_word_q[9:5], 4'h0})
                        :  $signed({1'b0, instr_word_q[9:5], 4'h0});
  assign branch_target_dsjs = pc_value +
         {{(ADDR_WIDTH-10){dsjs_disp_bits[9]}}, dsjs_disp_bits};

  // ---------------------------------------------------------------------------
  // Multi-step memory transaction support
  //
  // Some instructions (RETI, TRAP, MMTM, MMFM) chain multiple memory
  // transactions within a single CORE_MEMORY stay. `mem_op_step` ticks
  // through 0, 1, ... as each ack arrives; the FSM only exits to
  // CORE_WRITEBACK on the final step. The `popped_st_q` / `popped_pc_q`
  // / `mem_data_q` latches capture mem_rdata_eff between transactions
  // since `mem_rdata_eff` itself is overwritten by the next read.
  // ---------------------------------------------------------------------------
  logic [1:0]            mem_op_step;
  logic [DATA_WIDTH-1:0] popped_st_q;
  logic [DATA_WIDTH-1:0] popped_pc_q;
  // MOVE *Rs,*Rd (indirect-to-indirect): holds the field read at *Rs in
  // step 0 so it can be written to *Rd in step 1 (mem_rdata_eff is overwritten
  // by the next transaction).
  logic [DATA_WIDTH-1:0] move_data_q;

  // TRAP 0 is special per SPVU001A page 12-253: it does NOT push PC' or
  // ST onto the stack — it just sets ST <- 0x10 and fetches the vector
  // at 0xFFFFFFE0. Intended for the SP-corrupt / SP-uninitialised case.
  // We collapse the three-step TRAP sequence to a single vector-fetch
  // step when k5 == 0 (and suppress the SP -64 update via the alu_b mux).
  logic trap_skip_push;
  assign trap_skip_push = (decoded.iclass == INSTR_TRAP) && (decoded.k5 == 5'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_op_step <= 2'd0;
      popped_st_q <= '0;
      popped_pc_q <= '0;
      move_data_q <= '0;
      pix_dest_q  <= '0;
    end else if (state_q == CORE_MEMORY && mem_ack) begin
      // MOVE *Rs,*Rd: step 0 reads the source field; latch it so step 1
      // can write it to the destination.
      if ((decoded.iclass == INSTR_MOVE_FIELD_M2M ||
           decoded.iclass == INSTR_MOVE_ABS_M2M ||
           decoded.iclass == INSTR_MOVE_OFF_M2M ||
           decoded.iclass == INSTR_MOVE_OFF_NI ||
           decoded.iclass == INSTR_MOVE_ABS_NI) && mem_op_step == 2'd0) begin
        move_data_q <= mem_rdata_eff;
      end
      // PIXT store plane-mask RMW: step 0 reads the destination pixel; latch
      // it so step 1 can merge it under the plane mask.
      if (decoded.iclass == INSTR_MOVE_FIELD_STORE && pixt_rmw && mem_op_step == 2'd0) begin
        pix_dest_q <= mem_rdata_eff;
      end
      // Latch popped values per-iclass per-step before moving on.
      if (decoded.iclass == INSTR_RETI) begin
        if (mem_op_step == 2'd0) popped_st_q <= mem_rdata_eff;
        if (mem_op_step == 2'd1) popped_pc_q <= mem_rdata_eff;
      end
      // TRAP vector fetch:
      //   - N>0: step 2 (after the two pushes).
      //   - N=0: step 0 (the only step).
      if (decoded.iclass == INSTR_TRAP) begin
        if (trap_skip_push) begin
          if (mem_op_step == 2'd0) popped_pc_q <= mem_rdata_eff;
        end else begin
          if (mem_op_step == 2'd2) popped_pc_q <= mem_rdata_eff;
        end
      end
      // Step counter: advance unless this is the final step for the
      // iclass, in which case reset to 0 for the next instruction.
      unique case (decoded.iclass)
        INSTR_RETI: mem_op_step <= (mem_op_step == 2'd1) ? 2'd0 : mem_op_step + 2'd1;
        INSTR_TRAP: mem_op_step <= (trap_skip_push || mem_op_step == 2'd2)
                                 ? 2'd0
                                 : mem_op_step + 2'd1;
        INSTR_MOVE_FIELD_M2M,
        INSTR_MOVE_ABS_M2M,
        INSTR_MOVE_OFF_M2M,
        INSTR_MOVE_OFF_NI,
        INSTR_MOVE_ABS_NI:
                    mem_op_step <= (mem_op_step == 2'd1) ? 2'd0 : mem_op_step + 2'd1;
        // PIXT store RMW: step 0 (read) -> step 1 (write) -> 0. Regular MOVE
        // store (no force_pixel) is single-step and falls through to default.
        INSTR_MOVE_FIELD_STORE:
                    mem_op_step <= (pixt_rmw && mem_op_step == 2'd0) ? 2'd1 : 2'd0;
        default:    mem_op_step <= 2'd0;
      endcase
    end else if (state_q == CORE_INT_VECTOR && mem_ack) begin
      // Interrupt entry: latch the fetched trap vector (ISR entry address) so
      // CORE_INT_DONE can load it into the PC.
      popped_pc_q <= mem_rdata_eff;
      mem_op_step <= 2'd0;
    end else if (state_q == CORE_RVEC && mem_ack) begin
      // smashtv reset: latch the fetched reset vector so CORE_RVEC_DONE can
      // load it into the PC.
      popped_pc_q <= mem_rdata_eff;
      mem_op_step <= 2'd0;
    end else if (state_q != CORE_MEMORY) begin
      // Defensive reset between instructions.
      mem_op_step <= 2'd0;
    end
  end

  // ---------------------------------------------------------------------------
  // FILL L engine (Task 0087)
  //
  // FILL fills a DY×DX pixel array (DYDX=B7) with COLOR1 (B9), starting at
  // DADDR (B2), rows DPTCH (B3) bits apart. Each pixel is a PSIZE-bit field
  // write. Operands are latched at EXECUTE (DADDR/DPTCH/DYDX, read on the 3
  // ports) and CORE_FILL_SETUP (COLOR1); the pixel loop runs in CORE_FILL,
  // one write per ack. Replace mode only (window checking is never used for
  // FILL; PMASK/transparency/PPOP default to no-op at reset and are not yet
  // applied). DADDR is updated to the address following the last pixel.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] fill_dptch_q, fill_color_q, fill_daddr_raw_q;
  logic [15:0]           fill_dx_q, fill_dy_q;
  logic [DATA_WIDTH-1:0] fill_addr_q, fill_row_base_q;
  logic [15:0]           fill_x_q, fill_y_q;
  logic [DATA_WIDTH-1:0] fill_psize_ext;
  logic                  fill_row_end, fill_done;
  assign fill_psize_ext = {{(DATA_WIDTH-FIELD_SIZE_WIDTH){1'b0}}, io_psize[FIELD_SIZE_WIDTH-1:0]};
  assign fill_row_end   = (fill_x_q == fill_dx_q - 16'd1);
  assign fill_done      = fill_row_end && (fill_y_q == fill_dy_q - 16'd1);

  // FILL XY: convert the XY DADDR (latched raw at EXECUTE) to a linear start
  // address at SETUP, where OFFSET (B4) is on read port 3. Same shift form as
  // CVXYL: ((Y<<(31-CONVDP)) | (X<<log2 PSIZE)) + OFFSET.
  logic [4:0]            fill_xy_yshift;
  logic [DATA_WIDTH-1:0] fill_xy_linear, fill_start;
  assign fill_xy_yshift = 5'd31 - io_convdp[4:0];
  assign fill_xy_linear =
      (({{16{fill_daddr_raw_q[DATA_WIDTH-1]}}, fill_daddr_raw_q[DATA_WIDTH-1:16]} << fill_xy_yshift)
       | ({16'b0, fill_daddr_raw_q[15:0]} << pix_xy_xsh))
      + rf_rs3_data;   // OFFSET (B4) at SETUP
  assign fill_start = fill_is_xy ? fill_xy_linear : fill_daddr_raw_q;

  // FILL pixel processing (Task 0093). Each pixel is a read-modify-write: step
  // 0 (fill_substep_q=0) reads the destination pixel into fill_dest_q, step 1
  // writes fill_merged = PPOP(COLOR1, dest) plane-masked and transparency-
  // checked. At reset defaults (PPOP=0/PMASK=0/T=0) merged = COLOR1, so a plain
  // fill is unchanged (it just also reads first).
  logic                  fill_substep_q;   // 0 = read dest, 1 = write merged
  logic [DATA_WIDTH-1:0] fill_dest_q;      // destination pixel latched at read
  logic [DATA_WIDTH-1:0] fill_pixel_mask, fill_pmask_field;
  logic [DATA_WIDTH-1:0] fill_processed, fill_merged;
  logic                  fill_transp;
  // Window clipping (CONTROL.W = 3, FILL XY only — Task 0105). WSTART/WEND are
  // XY (X in [15:0], Y in [31:16]). A pixel outside the inclusive window
  // rectangle is left unchanged (write-back of the read dest, the same skip
  // mechanism as transparency). W=1/W=2 (hit/miss detection, WV interrupt,
  // abort) are NOT implemented yet (A0031) — only W=3 clips.
  logic [DATA_WIDTH-1:0] fill_wstart_q, fill_wend_q;
  logic                  fill_win_en_q;    // W=3 clipping active for this FILL
  logic                  fill_w2_q;        // W=2 (miss detection) active for this FILL
  logic [15:0]           fill_px, fill_py; // current pixel absolute XY
  logic                  fill_in_window, fill_clip_out;
  assign fill_px = fill_daddr_raw_q[15:0]            + fill_x_q;
  assign fill_py = fill_daddr_raw_q[DATA_WIDTH-1:16] + fill_y_q;
  assign fill_in_window =
        (fill_px >= fill_wstart_q[15:0]) && (fill_px <= fill_wend_q[15:0])
     && (fill_py >= fill_wstart_q[DATA_WIDTH-1:16]) && (fill_py <= fill_wend_q[DATA_WIDTH-1:16]);
  assign fill_clip_out = fill_win_en_q && !fill_in_window;
  // W=2 (miss detection): the whole array is drawn only if it lies entirely
  // within the window. Containment is a single rectangle test on the array's
  // corners, evaluated combinationally at CORE_FILL_SETUP_WIN from the live
  // WSTART(port1)/WEND(port2) reads (X=[15:0], Y=[31:16]).
  logic                  fill_array_inside;
  logic [15:0]           fill_arr_x0, fill_arr_y0, fill_arr_x1, fill_arr_y1;
  assign fill_arr_x0 = fill_daddr_raw_q[15:0];
  assign fill_arr_y0 = fill_daddr_raw_q[DATA_WIDTH-1:16];
  assign fill_arr_x1 = fill_arr_x0 + fill_dx_q - 16'd1;   // last column
  assign fill_arr_y1 = fill_arr_y0 + fill_dy_q - 16'd1;   // last row
  assign fill_array_inside =
        (fill_arr_x0 >= rf_rs1_data[15:0]) && (fill_arr_x1 <= rf_rs2_data[15:0])
     && (fill_arr_y0 >= rf_rs1_data[DATA_WIDTH-1:16]) && (fill_arr_y1 <= rf_rs2_data[DATA_WIDTH-1:16]);
  // W=1 (hit detection): no pixels are drawn. The array "hits" the window if it
  // overlaps at all; computed from the LATCHED WSTART/WEND (valid in
  // CORE_FILL_WIN_HIT, after the SETUP_WIN latch). Overlap = NOT fully to one
  // side. Inclusive corners.
  logic fill_w1_q, fill_array_hit;
  assign fill_array_hit = !(
        (fill_arr_x1 < fill_wstart_q[15:0]) || (fill_arr_x0 > fill_wend_q[15:0])
     || (fill_arr_y1 < fill_wstart_q[DATA_WIDTH-1:16]) || (fill_arr_y0 > fill_wend_q[DATA_WIDTH-1:16]));
  // Window-violation flag write (sets V; the miss path also pulses wvp_set):
  //   CORE_FILL_WIN_MISS — array outside the window → V=1, request WVP.
  //   CORE_FILL_WB with W=2 (array was inside) → V=0, no interrupt.
  // Shared window-violation flag write for FILL and PIXBLT W=2 (declared here;
  // pblt_w2_q is assigned later — order-independent for these continuous
  // assigns). win_flag_wb enables the V write; win_violation is the V value
  // (1 = a miss); wvp_set pulses INTPEND.WV on a miss.
  logic fill_win_flag_wb, fill_win_violation;
  // V value written: W=2 miss → 1; W=2 inside (at WB) → 0; W=1 hit → V = NOT
  // overlapped (1 if the array is entirely outside the window, else 0).
  // DRAV per-pixel window write-back (CORE_WRITEBACK, W!=0): V = NOT inside.
  logic drav_win_wb;
  assign drav_win_wb = (state_q == CORE_WRITEBACK) && is_drav && (drav_w_q != 2'd0);
  // LINE W=3 writes V at the d-writeback (V = NOT last-pixel-inside; no WVP).
  logic line_win_wb;
  assign line_win_wb = (state_q == CORE_LINE_WB_D) && line_win_en;
  // Windowed XY PIXT writes V (and maybe WVP) at CORE_WRITEBACK, like DRAV.
  logic pixt_win_wb;
  assign pixt_win_wb = (state_q == CORE_WRITEBACK) && pixt_xy_win;
  assign fill_win_violation = (state_q == CORE_FILL_WIN_MISS)
                            || (state_q == CORE_PBLT_WIN_MISS)
                            || ((state_q == CORE_FILL_WIN_HIT) && !fill_array_hit)
                            || ((state_q == CORE_PBLT_WIN_HIT) && !pblt_array_hit)
                            || (drav_win_wb && !drav_inside_q)
                            || (line_win_wb && !line_last_inside_q)
                            || (pixt_win_wb && !pixt_inside_q);
  assign fill_win_flag_wb   = (state_q == CORE_FILL_WIN_MISS)
                            || ((state_q == CORE_FILL_WB) && fill_w2_q)
                            || (state_q == CORE_PBLT_WIN_MISS)
                            || ((state_q == CORE_PBLT_WB2) && pblt_w2_q)
                            || (state_q == CORE_FILL_WIN_HIT)
                            || (state_q == CORE_PBLT_WIN_HIT)
                            || drav_win_wb
                            || line_win_wb
                            || pixt_win_wb;
  // WVP requested on a W=2 miss / W=1 hit for the array engines; for DRAV (per
  // pixel) on a W=1 hit (pixel inside) or a W=2 miss (pixel outside).
  assign wvp_set = (state_q == CORE_FILL_WIN_MISS)
                 || (state_q == CORE_PBLT_WIN_MISS)
                 || ((state_q == CORE_FILL_WIN_HIT) && fill_array_hit)
                 || ((state_q == CORE_PBLT_WIN_HIT) && pblt_array_hit)
                 || (drav_win_wb && (((drav_w_q == 2'd1) && drav_inside_q)
                                  || ((drav_w_q == 2'd2) && !drav_inside_q)))
                 || (line_win_wb && line_aborted_q)   // LINE W=1/W=2 abort
                 || (pixt_win_wb && (((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1) && pixt_inside_q)
                                  || ((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2) && !pixt_inside_q)));
  assign fill_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
  assign fill_pmask_field = {{(DATA_WIDTH-16){1'b0}}, io_pmask} & fill_pixel_mask;
  // COLOR1 is a 32-bit register and NARC's rectangle helper deliberately
  // duplicates an 8-bit color into adjacent lanes (for example green=0x0202).
  // The raster operation consumes one PSIZE-bit source pixel, not the complete
  // register. Without this mask P_MAX compares 0x0202 against an 8-bit
  // destination and paints over the diagnostic's black (index 5) chip labels.
  assign fill_processed   = ppop_apply(fill_color_q & fill_pixel_mask, fill_dest_q,
                                       io_control[CTRL_PPOP_HI:CTRL_PPOP_LO], fill_pixel_mask);
  assign fill_transp      = io_control[CTRL_T_BIT] && ((fill_processed & fill_pixel_mask) == '0);
  assign fill_merged      = (fill_transp || fill_clip_out)
                          ? fill_dest_q
                          : ((fill_processed & ~fill_pmask_field) | (fill_dest_q & fill_pmask_field));

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_dptch_q     <= '0;
      fill_color_q     <= '0;
      fill_daddr_raw_q <= '0;
      fill_dx_q        <= '0;
      fill_dy_q        <= '0;
      fill_addr_q      <= '0;
      fill_row_base_q  <= '0;
      fill_x_q         <= '0;
      fill_y_q         <= '0;
      fill_substep_q   <= 1'b0;
      fill_dest_q      <= '0;
      fill_wstart_q    <= '0;
      fill_wend_q      <= '0;
      fill_win_en_q    <= 1'b0;
      fill_w2_q        <= 1'b0;
      fill_w1_q        <= 1'b0;
    end else begin
      // EXECUTE: latch DADDR(port1)/DPTCH(port2)/DYDX(port3) for FILL. The
      // start address (possibly XY-converted) is finalized at SETUP. Window
      // clipping engages only for FILL XY with CONTROL.W = 3.
      if (state_q == CORE_EXECUTE && is_fill) begin
        fill_daddr_raw_q <= rf_rs1_data;       // DADDR (linear, or XY for FILL XY)
        fill_dptch_q     <= rf_rs2_data;       // DPTCH
        fill_dx_q        <= rf_rs3_data[15:0]; // DX
        fill_dy_q        <= rf_rs3_data[DATA_WIDTH-1:16]; // DY
        fill_x_q         <= 16'd0;
        fill_y_q         <= 16'd0;
        fill_win_en_q    <= fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd3);
        fill_w2_q        <= fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2);
        fill_w1_q        <= fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1);
      end
      // CORE_FILL_SETUP_WIN: latch WSTART(port1=B5)/WEND(port2=B6) for clip.
      if (state_q == CORE_FILL_SETUP_WIN) begin
        fill_wstart_q <= rf_rs1_data;
        fill_wend_q   <= rf_rs2_data;
      end
      // CORE_FILL_SETUP: latch COLOR1 (port1) and the linear start address
      // (port3 = OFFSET for the XY conversion); start at the read sub-step.
      if (state_q == CORE_FILL_SETUP) begin
        fill_color_q    <= rf_rs1_data;        // COLOR1
        fill_addr_q     <= fill_start;
        fill_row_base_q <= fill_start;
        fill_substep_q  <= 1'b0;
      end
      // CORE_FILL: per pixel, read (sub-step 0) then write (sub-step 1).
      if (state_q == CORE_FILL && mem_ack) begin
        fill_substep_q <= ~fill_substep_q;
        if (!fill_substep_q) begin
          // Read ack: latch the destination pixel for processing.
          fill_dest_q <= mem_rdata_eff;
        end else begin
          // Write ack: advance to the next pixel (or to the final DADDR).
          fill_addr_q <= fill_addr_q + fill_psize_ext;
          if (fill_row_end && !fill_done) begin
            // Row complete (not the last): jump to the next row's base.
            fill_y_q        <= fill_y_q + 16'd1;
            fill_row_base_q <= fill_row_base_q + fill_dptch_q;
            fill_addr_q     <= fill_row_base_q + fill_dptch_q;
            fill_x_q        <= 16'd0;
          end else if (!fill_done) begin
            fill_x_q <= fill_x_q + 16'd1;
          end
          // On fill_done the write ack leaves fill_addr_q at the pixel
          // following the last (the final DADDR); the FSM moves to CORE_FILL_WB.
          //
          // KNOWN MAME DIVERGENCE (open item, doc/UPSTREAM_TB_FINDINGS.md).
          // MAME 34010gfx.hxx never touches DADDR() inside the fill loop and runs
          // this tail block once after it:
          //     if (dst_is_linear) DADDR() += DYDX_Y() * DPTCH();
          //     else               DADDR_Y() += DYDX_Y();
          // i.e. the final DADDR is base + DY*DPTCH (the row PAST the array), the
          // same rule the PIXBLT engine below now implements via its
          // pblt_src_wb_q / pblt_dst_wb_q accumulators.
          // The `!fill_done` gate here instead leaves fill_addr_q at
          // last-row-start + DX*PSIZE ("the pixel following the last").
          // FILL is deliberately left on the old behaviour: tb_fill_l,
          // tb_fill_xy and tb_fill_window all encode the last-pixel+1 expectation
          // and currently PASS, and testbench expectations are never edited to
          // accommodate an RTL change. Fixing FILL is a separate decision that
          // must retire those three expectations first.
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // PIXBLT L,L engine (Task 0094)
  //
  // Transfer a DY×DX pixel array from the SOURCE array (SADDR=B0, rows SPTCH=B1
  // apart) to the DESTINATION array (DADDR=B2, rows DPTCH=B3 apart), processing
  // each pixel: written = PPOP(source pixel, destination pixel), plane-masked
  // and transparency-checked. Operands are read at EXECUTE (SADDR/DADDR/DYDX)
  // and CORE_PBLT_SETUP (SPTCH/DPTCH). Each pixel is a 3-step sequence
  // (substep 0 read source, 1 read destination, 2 write); both pointers advance
  // by PSIZE per pixel and row-step by their pitch.
  //
  // SADDR/DADDR writeback (P0009/P0010). MAME 34010gfx.hxx never touches
  // SADDR()/DADDR() inside the pixel loop; it runs this tail block once, after
  // the loop, unconditionally:
  //     if (src_is_linear) SADDR() += DYDX_Y() * SPTCH(); else SADDR_Y() += DYDX_Y();
  //     if (dst_is_linear) DADDR() += DYDX_Y() * DPTCH(); else DADDR_Y() += DYDX_Y();
  // So the linear result is base + DY*pitch (the row PAST the array), not
  // last-pixel+1, and the XY result advances only the Y half by DY. The working
  // pointers (pblt_src_addr_q / pblt_dst_addr_q / *_row_q) cannot supply that:
  // they stop at last-row-start + width, and under PBV they walk BACKWARD from a
  // pre-advanced base. pblt_src_wb_q / pblt_dst_wb_q are therefore separate
  // accumulators, seeded with the RAW register operands at EXECUTE and stepped
  // by their pitch once per completed row INCLUDING the last. That needs no
  // multiplier and is PBV-independent. Writeback: CORE_PBLT_WB → B0,
  // CORE_PBLT_WB2 → B2.
  //
  // No corner adjust (top-left → bottom-right).
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] pblt_sptch_q, pblt_dptch_q;
  logic [15:0]           pblt_dx_q, pblt_dy_q;
  logic [DATA_WIDTH-1:0] pblt_src_addr_q, pblt_dst_addr_q;
  logic [DATA_WIDTH-1:0] pblt_src_row_q, pblt_dst_row_q;
  // MAME tail-block accumulators (see the header note): raw operand at EXECUTE
  // plus one pitch per completed row, so after DY rows they hold base+DY*pitch.
  logic [DATA_WIDTH-1:0] pblt_src_wb_q, pblt_dst_wb_q;
  // Raw (unconverted) SADDR latched at EXECUTE, for the XY-source writeback
  // form SADDR_Y() += DYDX_Y(). The dest equivalent is pblt_dst_xy_raw_q.
  logic [DATA_WIDTH-1:0] pblt_src_xy_raw_q;
  logic [15:0]           pblt_x_q, pblt_y_q;
  logic [1:0]            pblt_substep_q;     // 0 read src, 1 read dst, 2 write
  logic [DATA_WIDTH-1:0] pblt_src_pix_q, pblt_dst_pix_q;
  logic [DATA_WIDTH-1:0] pblt_psize_ext, pblt_pixel_mask, pblt_pmask_field;
  logic [DATA_WIDTH-1:0] pblt_processed, pblt_merged;
  logic                  pblt_row_end, pblt_done, pblt_transp;
  // PIXBLT B (color expand): COLOR0/COLOR1 latched at SETUP2; the source read is
  // 1 bit (mem_size 1, src step 1) and expands to COLOR1 / COLOR0.
  logic [DATA_WIDTH-1:0] pblt_color0_q, pblt_color1_q;
  logic [DATA_WIDTH-1:0] pblt_src_eff, pblt_src_step;
  // PBV (CONTROL bit 9): PixBlt vertical direction. MAME 34010gfx.hxx: with
  // PBV set and any XY operand, BOTH start addresses pre-advance to the last
  // row ((dy-1) * conv pitch) and rows then step BACKWARD (-SPTCH/-DPTCH).
  // Ignoring it corrupted every overlapping VRAM-to-VRAM scroll copy (the
  // intro/credits text scrollers) into horizontal glyph-streaks. PBH (bit 8)
  // is not implemented by MAME either; rows always run left-to-right.
  logic                  pblt_yrev_q;
  assign pblt_psize_ext   = {{(DATA_WIDTH-FIELD_SIZE_WIDTH){1'b0}}, io_psize[FIELD_SIZE_WIDTH-1:0]};
  assign pblt_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
  assign pblt_pmask_field = {{(DATA_WIDTH-16){1'b0}}, io_pmask} & pblt_pixel_mask;
  assign pblt_row_end     = (pblt_x_q == pblt_dx_q - 16'd1);
  assign pblt_done        = pblt_row_end && (pblt_y_q == pblt_dy_q - 16'd1);
  // Effective source pixel: a binary source bit selects COLOR1/COLOR0.
  assign pblt_src_eff     = decoded.blt_binary
                          ? (pblt_src_pix_q[0] ? pblt_color1_q : pblt_color0_q)
                          : pblt_src_pix_q;
  // Source advances 1 bit/pixel for the binary form, PSIZE bits otherwise.
  assign pblt_src_step    = decoded.blt_binary ? 32'd1 : pblt_psize_ext;
  assign pblt_processed   = ppop_apply(pblt_src_eff & pblt_pixel_mask, pblt_dst_pix_q,
                                       io_control[CTRL_PPOP_HI:CTRL_PPOP_LO], pblt_pixel_mask);
  assign pblt_transp      = io_control[CTRL_T_BIT] && ((pblt_processed & pblt_pixel_mask) == '0);
  // Window clipping (CONTROL.W=3, PIXBLT with XY dest — Task 0106). The raw XY
  // DADDR is preserved (pblt_dst_xy_raw_q) because pblt_dst_addr_q is converted
  // to linear at SETUP; each pixel's absolute XY = (rawX+col, rawY+row) is
  // tested against the inclusive [WSTART..WEND] rectangle and out-of-window
  // pixels are left unchanged (same skip path as transparency). W=1/W=2 and the
  // WV interrupt are not implemented (A0031).
  logic [DATA_WIDTH-1:0] pblt_dst_xy_raw_q, pblt_wstart_q, pblt_wend_q;
  logic                  pblt_win_en_q;    // W=3 per-pixel clip active
  logic                  pblt_w2_q;        // W=2 (miss detection) active
  logic [15:0]           pblt_px, pblt_py;
  logic                  pblt_in_window, pblt_clip_out;
  assign pblt_px = pblt_dst_xy_raw_q[15:0]            + pblt_x_q;
  assign pblt_py = pblt_dst_xy_raw_q[DATA_WIDTH-1:16] + pblt_y_q;
  assign pblt_in_window =
        (pblt_px >= pblt_wstart_q[15:0]) && (pblt_px <= pblt_wend_q[15:0])
     && (pblt_py >= pblt_wstart_q[DATA_WIDTH-1:16]) && (pblt_py <= pblt_wend_q[DATA_WIDTH-1:16]);
  assign pblt_clip_out = pblt_win_en_q && !pblt_in_window;
  // W=2 (miss detection): array containment test on the dest corners, evaluated
  // combinationally at CORE_PBLT_SETUP_WIN from the live WSTART(port1)/WEND
  // (port2) reads (mirrors the FILL W=2 path).
  logic        pblt_array_inside;
  logic [15:0] pblt_arr_x0, pblt_arr_y0, pblt_arr_x1, pblt_arr_y1;
  assign pblt_arr_x0 = pblt_dst_xy_raw_q[15:0];
  assign pblt_arr_y0 = pblt_dst_xy_raw_q[DATA_WIDTH-1:16];
  assign pblt_arr_x1 = pblt_arr_x0 + pblt_dx_q - 16'd1;
  assign pblt_arr_y1 = pblt_arr_y0 + pblt_dy_q - 16'd1;
  assign pblt_array_inside =
        (pblt_arr_x0 >= rf_rs1_data[15:0]) && (pblt_arr_x1 <= rf_rs2_data[15:0])
     && (pblt_arr_y0 >= rf_rs1_data[DATA_WIDTH-1:16]) && (pblt_arr_y1 <= rf_rs2_data[DATA_WIDTH-1:16]);
  // W=1 (hit detection): never draws; overlap test from the LATCHED WSTART/WEND
  // (valid in CORE_PBLT_WIN_HIT). Mirrors the FILL W=1 path.
  logic pblt_w1_q, pblt_array_hit;
  assign pblt_array_hit = !(
        (pblt_arr_x1 < pblt_wstart_q[15:0]) || (pblt_arr_x0 > pblt_wend_q[15:0])
     || (pblt_arr_y1 < pblt_wstart_q[DATA_WIDTH-1:16]) || (pblt_arr_y0 > pblt_wend_q[DATA_WIDTH-1:16]));
  assign pblt_merged      = (pblt_transp || pblt_clip_out)
                          ? pblt_dst_pix_q
                          : ((pblt_processed & ~pblt_pmask_field) | (pblt_dst_pix_q & pblt_pmask_field));

  // PIXBLT XY variants: convert the XY SADDR/DADDR (latched raw at EXECUTE) to a
  // linear address at SETUP (source via CONVSP, dest via CONVDP, + OFFSET on
  // read port 3, + log2 PSIZE = pix_xy_xsh). Same shift form as CVXYL/FILL XY.
  logic [DATA_WIDTH-1:0] pblt_src_conv, pblt_dst_conv;
  assign pblt_src_conv =
      (({{16{pblt_src_addr_q[DATA_WIDTH-1]}}, pblt_src_addr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convsp[4:0]))
       | ({16'b0, pblt_src_addr_q[15:0]} << pix_xy_xsh)) + rf_rs3_data;
  assign pblt_dst_conv =
      (({{16{pblt_dst_addr_q[DATA_WIDTH-1]}}, pblt_dst_addr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convdp[4:0]))
       | ({16'b0, pblt_dst_addr_q[15:0]} << pix_xy_xsh)) + rf_rs3_data;

  always_ff @(posedge clk) begin
    if (rst) begin
      pblt_sptch_q    <= '0;
      pblt_dptch_q    <= '0;
      pblt_dx_q       <= '0;
      pblt_dy_q       <= '0;
      pblt_src_addr_q <= '0;
      pblt_dst_addr_q <= '0;
      pblt_src_row_q  <= '0;
      pblt_dst_row_q  <= '0;
      pblt_src_wb_q   <= '0;
      pblt_dst_wb_q   <= '0;
      pblt_src_xy_raw_q <= '0;
      pblt_x_q        <= '0;
      pblt_y_q        <= '0;
      pblt_substep_q  <= 2'd0;
      pblt_yrev_q     <= 1'b0;
      pblt_src_pix_q  <= '0;
      pblt_dst_pix_q  <= '0;
      pblt_color0_q   <= '0;
      pblt_color1_q   <= '0;
      pblt_dst_xy_raw_q <= '0;
      pblt_wstart_q   <= '0;
      pblt_wend_q     <= '0;
      pblt_win_en_q   <= 1'b0;
      pblt_w2_q       <= 1'b0;
      pblt_w1_q       <= 1'b0;
    end else begin
      // EXECUTE: latch SADDR(port1) / DADDR(port2) / DYDX(port3). Window
      // clipping engages only for an XY destination with CONTROL.W=3; keep the
      // raw XY DADDR (pblt_dst_addr_q is converted to linear at SETUP).
      if (state_q == CORE_EXECUTE && is_pblt) begin
        pblt_src_addr_q <= rf_rs1_data;          // SADDR
        pblt_src_row_q  <= rf_rs1_data;
        pblt_dst_addr_q <= rf_rs2_data;          // DADDR
        pblt_dst_row_q  <= rf_rs2_data;
        pblt_src_xy_raw_q <= rf_rs1_data;        // raw XY SADDR (for writeback)
        pblt_dst_xy_raw_q <= rf_rs2_data;        // raw XY DADDR (window + wb)
        // Seed the MAME tail accumulators with the RAW operands: the tail block
        // is base + DY*pitch, computed from the register value the instruction
        // started with, not from the XY-converted / PBV-pre-advanced base.
        pblt_src_wb_q   <= rf_rs1_data;
        pblt_dst_wb_q   <= rf_rs2_data;
        pblt_dx_q       <= rf_rs3_data[15:0];
        pblt_dy_q       <= rf_rs3_data[DATA_WIDTH-1:16];
        pblt_x_q        <= 16'd0;
        pblt_y_q        <= 16'd0;
        pblt_substep_q  <= 2'd0;
        pblt_yrev_q     <= io_control[CTRL_PBV_BIT];
        pblt_win_en_q   <= decoded.blt_dst_xy &&
                           (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd3);
        pblt_w2_q       <= decoded.blt_dst_xy &&
                           (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2);
        pblt_w1_q       <= decoded.blt_dst_xy &&
                           (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1);
      end
      // CORE_PBLT_SETUP_WIN: latch WSTART(port1=B5)/WEND(port2=B6) for clip.
      if (state_q == CORE_PBLT_SETUP_WIN) begin
        pblt_wstart_q <= rf_rs1_data;
        pblt_wend_q   <= rf_rs2_data;
      end
      // CORE_PBLT_SETUP: latch SPTCH(port1) / DPTCH(port2); for the XY variants
      // convert the XY SADDR/DADDR to linear (port3 = OFFSET here). With PBV
      // and any XY operand, pre-advance BOTH starts to the last row using the
      // CONV pitches (1 << (31-CONVSP/DP)) exactly as MAME 34010gfx.hxx does.
      if (state_q == CORE_PBLT_SETUP) begin
        logic [DATA_WIDTH-1:0] sadj, dadj, sbase, dbase;
        logic pbv_adj;
        pbv_adj = pblt_yrev_q && (decoded.blt_src_xy || decoded.blt_dst_xy);
        sadj = pbv_adj ? ({16'd0, (pblt_dy_q - 16'd1)} << (5'd31 - io_convsp[4:0])) : '0;
        dadj = pbv_adj ? ({16'd0, (pblt_dy_q - 16'd1)} << (5'd31 - io_convdp[4:0])) : '0;
        sbase = (decoded.blt_src_xy ? pblt_src_conv : pblt_src_addr_q) + sadj;
        dbase = (decoded.blt_dst_xy ? pblt_dst_conv : pblt_dst_addr_q) + dadj;
        pblt_sptch_q    <= rf_rs1_data;
        pblt_dptch_q    <= rf_rs2_data;
        pblt_src_addr_q <= sbase;
        pblt_src_row_q  <= sbase;
        pblt_dst_addr_q <= dbase;
        pblt_dst_row_q  <= dbase;
      end
      // CORE_PBLT_SETUP2 (binary form): latch COLOR0(port1) / COLOR1(port2).
      if (state_q == CORE_PBLT_SETUP2) begin
        pblt_color0_q <= rf_rs1_data;
        pblt_color1_q <= rf_rs2_data;
      end
      // CORE_PBLT: per pixel, read src (0) / read dst (1) / write (2).
      if (state_q == CORE_PBLT && mem_ack) begin
        if (pblt_substep_q == 2'd0) begin
          pblt_src_pix_q <= mem_rdata_eff;
          pblt_substep_q <= 2'd1;
        end else if (pblt_substep_q == 2'd1) begin
          pblt_dst_pix_q <= mem_rdata_eff;
          pblt_substep_q <= 2'd2;
        end else begin
          // Write ack: advance both pointers to the next pixel (source by 1
          // bit for the binary form, PSIZE otherwise; dest always by PSIZE).
          pblt_substep_q  <= 2'd0;
          pblt_src_addr_q <= pblt_src_addr_q + pblt_src_step;
          pblt_dst_addr_q <= pblt_dst_addr_q + pblt_psize_ext;
          // MAME tail block: one pitch per COMPLETED row, the last row included
          // (unlike the working pointers below, which stop at pblt_done). After
          // DY rows these hold raw base + DY*pitch. Always +pitch, never -pitch:
          // MAME's tail adds regardless of PBV.
          if (pblt_row_end) begin
            pblt_src_wb_q <= pblt_src_wb_q + pblt_sptch_q;
            pblt_dst_wb_q <= pblt_dst_wb_q + pblt_dptch_q;
          end
          if (pblt_row_end && !pblt_done) begin
            // PBV: rows step backward (-SPTCH/-DPTCH), matching MAME.
            logic [DATA_WIDTH-1:0] snext, dnext;
            snext = pblt_yrev_q ? (pblt_src_row_q - pblt_sptch_q)
                                : (pblt_src_row_q + pblt_sptch_q);
            dnext = pblt_yrev_q ? (pblt_dst_row_q - pblt_dptch_q)
                                : (pblt_dst_row_q + pblt_dptch_q);
            pblt_y_q        <= pblt_y_q + 16'd1;
            pblt_src_row_q  <= snext;
            pblt_dst_row_q  <= dnext;
            pblt_src_addr_q <= snext;
            pblt_dst_addr_q <= dnext;
            pblt_x_q        <= 16'd0;
          end else if (!pblt_done) begin
            pblt_x_q <= pblt_x_q + 16'd1;
          end
        end
      end
    end
  end

  // Final SADDR (B0, CORE_PBLT_WB) / DADDR (B2, CORE_PBLT_WB2), MAME's tail
  // block: a LINEAR operand becomes base + DY*pitch (the accumulator above); an
  // XY operand advances only its Y half by DY, X untouched.
  logic [DATA_WIDTH-1:0] pblt_wb_src_val, pblt_wb_dst_val;
  assign pblt_wb_src_val = decoded.blt_src_xy
      ? {pblt_src_xy_raw_q[DATA_WIDTH-1:16] + pblt_dy_q, pblt_src_xy_raw_q[15:0]}
      : pblt_src_wb_q;
  assign pblt_wb_dst_val = decoded.blt_dst_xy
      ? {pblt_dst_xy_raw_q[DATA_WIDTH-1:16] + pblt_dy_q, pblt_dst_xy_raw_q[15:0]}
      : pblt_dst_wb_q;

  // ---------------------------------------------------------------------------
  // DRAV (Draw and Advance) — SPVU001A page 12-67.
  //
  // A single-pixel COLOR1 draw at Rd's XY address, then Rd advances by Rs as an
  // XY add. At EXECUTE: Rd (port2) is XY-converted to a linear address with
  // OFFSET (port3) — pix_xy_dst_linear, the same form as PIXT XY / FILL XY —
  // and latched; Rs/Rd are latched for the advance. CORE_DRAV then runs a
  // 2-step read-dest / write-merged RMW (COLOR1 on port1), reusing the FILL
  // pixel-merge (PPOP / transparency / PMASK). The advance is written back at
  // CORE_WRITEBACK. Window modes (W=1/2/3) are not yet applied (A0031, W=0).
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] drav_rd_q, drav_rs_q, drav_linear_q, drav_dest_q;
  logic                  drav_substep_q;    // 0 = read dest, 1 = write merged
  // Per-pixel window check (CONTROL.W, Task 0112). Rd's XY is tested against the
  // inclusive [WSTART..WEND] rectangle (read at CORE_DRAV_SETUP_WIN). The pixel
  // is drawn only for W=0, or W=2/W=3 when inside. V (W!=0) = NOT inside; WVP is
  // requested for W=1 inside (hit) or W=2 outside (miss). The advance always
  // happens. Reuses the shared fill_win_flag_wb / wvp_set V-write path.
  logic [1:0]            drav_w_q;          // CONTROL.W latched at EXECUTE
  logic                  drav_inside_q;     // Rd's pixel lies inside the window
  logic                  drav_in_window;    // combinational test at SETUP_WIN
  assign drav_in_window =
        (drav_rd_q[15:0] >= rf_rs1_data[15:0]) && (drav_rd_q[15:0] <= rf_rs2_data[15:0])
     && (drav_rd_q[DATA_WIDTH-1:16] >= rf_rs1_data[DATA_WIDTH-1:16])
     && (drav_rd_q[DATA_WIDTH-1:16] <= rf_rs2_data[DATA_WIDTH-1:16]);
  // Drawn for W=0 always; for W=2/W=3 only when inside; W=1 never draws.
  logic [DATA_WIDTH-1:0] drav_pixel_mask, drav_pmask_field, drav_processed, drav_merged;
  logic                  drav_transp;
  logic [DATA_WIDTH-1:0] drav_advance;
  assign drav_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
  assign drav_pmask_field = {{(DATA_WIDTH-16){1'b0}}, io_pmask} & drav_pixel_mask;
  // COLOR1 is rf_rs1_data in CORE_DRAV (port1 reads B9 there).
  assign drav_processed   = ppop_apply(rf_rs1_data & drav_pixel_mask, drav_dest_q,
                                       io_control[CTRL_PPOP_HI:CTRL_PPOP_LO], drav_pixel_mask);
  assign drav_transp      = io_control[CTRL_T_BIT] && ((drav_processed & drav_pixel_mask) == '0);
  assign drav_merged      = drav_transp
                          ? drav_dest_q
                          : ((drav_processed & ~drav_pmask_field) | (drav_dest_q & drav_pmask_field));
  // Rd advanced by Rs: independent 16-bit X and Y adds, no carry X->Y.
  assign drav_advance = {drav_rd_q[DATA_WIDTH-1:16] + drav_rs_q[DATA_WIDTH-1:16],
                         drav_rd_q[15:0]            + drav_rs_q[15:0]};

  always_ff @(posedge clk) begin
    if (rst) begin
      drav_rd_q      <= '0;
      drav_rs_q      <= '0;
      drav_linear_q  <= '0;
      drav_dest_q    <= '0;
      drav_substep_q <= 1'b0;
      drav_w_q       <= 2'd0;
      drav_inside_q  <= 1'b0;
    end else begin
      if (state_q == CORE_EXECUTE && is_drav) begin
        drav_rd_q      <= rf_rs2_data;        // Rd (XY dest)
        drav_rs_q      <= rf_rs1_data;        // Rs (XY increment)
        drav_linear_q  <= pix_xy_dst_linear;  // convert(Rd) + OFFSET (port3)
        drav_substep_q <= 1'b0;
        drav_w_q       <= io_control[CTRL_W_HI:CTRL_W_LO];
      end
      // CORE_DRAV_SETUP_WIN: latch the window test (WSTART=port1, WEND=port2).
      if (state_q == CORE_DRAV_SETUP_WIN) drav_inside_q <= drav_in_window;
      if (state_q == CORE_DRAV && mem_ack) begin
        drav_substep_q <= ~drav_substep_q;
        if (!drav_substep_q) drav_dest_q <= mem_rdata_eff;  // read ack
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LINE (Bresenham inner loop) — SPVU001A page 12-99.
  //
  // The implied B operands are read over 3 setup cycles (line_rd_b above), then
  // CORE_LINE_DRAW runs the per-pixel loop: draw COLOR1 at DADDR's XY (2-step
  // RMW, reusing the FILL/DRAV pixel merge), then step the decision variable d
  // and DADDR (+INC1 when d>0 i.e. the diagonal move, else +INC2) and decrement
  // COUNT. The Z bit (instr_word_q[7]) selects whether d=0 counts as ">0"
  // (Z=1 -> d>=0). At the end d/DADDR/COUNT are written back to B0/B2/B10.
  // Window modes are not yet applied (W=0; A0031). DADDR/INC adds are XY
  // (independent 16-bit halves, no carry), matching ADDXY / DRAV.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] line_d_q, line_count_q, line_inc1_q, line_inc2_q;
  logic [DATA_WIDTH-1:0] line_offset_q, line_daddr_q, line_color_q, line_dest_q;
  logic [15:0]           line_b_q, line_a_q;
  logic                  line_substep_q;
  // Per-pixel linear address from DADDR's XY (same conversion form as FILL XY).
  logic [DATA_WIDTH-1:0] line_linear;
  assign line_linear =
      (({{16{line_daddr_q[DATA_WIDTH-1]}}, line_daddr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convdp[4:0]))
       | ({16'b0, line_daddr_q[15:0]} << pix_xy_xsh)) + line_offset_q;
  // Pixel merge (PPOP / transparency / PMASK), COLOR1 = line_color_q.
  logic [DATA_WIDTH-1:0] line_pixel_mask, line_pmask_field, line_processed, line_merged;
  logic                  line_transp;
  assign line_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
  assign line_pmask_field = {{(DATA_WIDTH-16){1'b0}}, io_pmask} & line_pixel_mask;
  assign line_processed   = ppop_apply(line_color_q & line_pixel_mask, line_dest_q,
                                       io_control[CTRL_PPOP_HI:CTRL_PPOP_LO], line_pixel_mask);
  assign line_transp      = io_control[CTRL_T_BIT] && ((line_processed & line_pixel_mask) == '0);
  // Per-pixel window clip (CONTROL.W=3, Task 0115). LINE inhibits writes to
  // pixels outside the window (no preclip — tested at draw time); the V bit at
  // the end reflects whether the last pixel calculated was inside. W=1/W=2
  // (abort modes) are deferred (A0031). WSTART/WEND read at CORE_LINE_SETUP_WIN.
  logic [DATA_WIDTH-1:0] line_wstart_q, line_wend_q;
  logic                  line_last_inside_q;  // inside status of the last pixel
  logic                  line_aborted_q;      // W=1/W=2 aborted on a violation
  logic [1:0]            line_w_mode;
  logic                  line_win_en;         // any window mode active (W!=0)
  logic                  line_in_window, line_draw_pixel, line_clip_out, line_abort;
  assign line_w_mode    = io_control[CTRL_W_HI:CTRL_W_LO];
  assign line_win_en    = (line_w_mode != 2'd0);
  assign line_in_window =
        (line_daddr_q[15:0] >= line_wstart_q[15:0]) && (line_daddr_q[15:0] <= line_wend_q[15:0])
     && (line_daddr_q[DATA_WIDTH-1:16] >= line_wstart_q[DATA_WIDTH-1:16])
     && (line_daddr_q[DATA_WIDTH-1:16] <= line_wend_q[DATA_WIDTH-1:16]);
  // Draw decision: W=1 (hit) draws the pixels OUTSIDE the window and aborts on
  // an inside pixel; W=2 (miss) and W=3 (clip) draw INSIDE pixels (W=2 aborts
  // on an outside pixel, W=3 just inhibits it). V at the end is NOT last-inside
  // for every windowed mode; WVP is set on a W=1/W=2 abort.
  assign line_draw_pixel = (line_w_mode == 2'd1) ? !line_in_window : line_in_window;
  assign line_clip_out   = line_win_en && !line_draw_pixel;
  assign line_abort      = (line_w_mode == 2'd1 &&  line_in_window)
                         || (line_w_mode == 2'd2 && !line_in_window);
  assign line_merged      = (line_transp || line_clip_out)
                          ? line_dest_q
                          : ((line_processed & ~line_pmask_field) | (line_dest_q & line_pmask_field));
  // Bresenham decision: branch (diagonal, +INC1) when d>0 (Z=0) or d>=0 (Z=1).
  logic        line_branch;
  logic [DATA_WIDTH-1:0] line_2b, line_2a, line_d_next, line_daddr_next, line_count_next;
  assign line_branch = instr_word_q[7] ? !line_d_q[DATA_WIDTH-1]              // Z=1: d >= 0
                                       : (!line_d_q[DATA_WIDTH-1] && (line_d_q != '0)); // Z=0: d > 0
  assign line_2b = {16'b0, line_b_q} << 1;
  assign line_2a = {16'b0, line_a_q} << 1;
  assign line_d_next = line_branch ? (line_d_q + line_2b - line_2a)
                                   : (line_d_q + line_2b);
  assign line_daddr_next = line_branch
      ? {line_daddr_q[DATA_WIDTH-1:16] + line_inc1_q[DATA_WIDTH-1:16],
         line_daddr_q[15:0]            + line_inc1_q[15:0]}
      : {line_daddr_q[DATA_WIDTH-1:16] + line_inc2_q[DATA_WIDTH-1:16],
         line_daddr_q[15:0]            + line_inc2_q[15:0]};
  assign line_count_next = line_count_q - 32'd1;

  always_ff @(posedge clk) begin
    if (rst) begin
      line_d_q       <= '0;
      line_count_q   <= '0;
      line_inc1_q    <= '0;
      line_inc2_q    <= '0;
      line_offset_q  <= '0;
      line_daddr_q   <= '0;
      line_color_q   <= '0;
      line_dest_q    <= '0;
      line_b_q       <= '0;
      line_a_q       <= '0;
      line_substep_q <= 1'b0;
      line_wstart_q  <= '0;
      line_wend_q    <= '0;
      line_last_inside_q <= 1'b0;
      line_aborted_q <= 1'b0;
    end else begin
      // Clear the abort flag when a new LINE starts (at EXECUTE).
      if (state_q == CORE_EXECUTE && is_line) line_aborted_q <= 1'b0;
      if (state_q == CORE_LINE_SETUP_WIN) begin
        line_wstart_q <= rf_rs1_data;          // WSTART (B5)
        line_wend_q   <= rf_rs2_data;          // WEND (B6)
      end
      if (state_q == CORE_LINE_SETUP1) begin
        line_d_q     <= rf_rs1_data;                 // d (B0)
        line_b_q     <= rf_rs2_data[DATA_WIDTH-1:16]; // b = DYDX minor
        line_a_q     <= rf_rs2_data[15:0];            // a = DYDX major
        line_count_q <= rf_rs3_data;                 // COUNT (B10)
      end
      if (state_q == CORE_LINE_SETUP2) begin
        line_inc1_q   <= rf_rs1_data;                // INC1 (B11)
        line_inc2_q   <= rf_rs2_data;                // INC2 (B12)
        line_offset_q <= rf_rs3_data;                // OFFSET (B4)
      end
      if (state_q == CORE_LINE_SETUP3) begin
        line_daddr_q   <= rf_rs1_data;               // DADDR (B2)
        line_color_q   <= rf_rs2_data;               // COLOR1 (B9)
        line_substep_q <= 1'b0;
      end
      if (state_q == CORE_LINE_DRAW && mem_ack) begin
        line_substep_q <= ~line_substep_q;
        if (!line_substep_q) begin
          line_dest_q <= mem_rdata_eff;              // read ack
        end else begin
          // Write ack: record this pixel's window status (for the final V) and
          // whether it triggered a W=1/W=2 abort, then advance the Bresenham
          // state for the next pixel.
          line_last_inside_q <= line_in_window;
          if (line_abort) line_aborted_q <= 1'b1;
          line_d_q     <= line_d_next;
          line_daddr_q <= line_daddr_next;
          line_count_q <= line_count_next;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // MMTM / MMFM iterator (shared)
  //
  // MMTM (push, INSTR_MMTM) and MMFM (pop, INSTR_MMFM) walk the same
  // 16-bit register-list mask one set bit at a time, one 32-bit memory
  // transaction per bit. They share this iterator state and differ only
  // in scan direction, the +/-32 address step, and read-vs-write:
  //
  //   mm_mask_q (16-bit) shadows the original mask; the just-handled bit
  //   is cleared after each mem_ack.
  //   mm_rp_q (32-bit) is the working stack pointer / current transaction
  //   address.
  //   mm_iter_idx is the priority-encoded current bit:
  //     - MMTM: LOWEST set bit  (lowest-order register saved first).
  //     - MMFM: HIGHEST set bit (highest-order register restored first).
  //   It indexes both the register file and the bit to clear after ack.
  //
  // Address sequencing (predecrement vs postincrement, per SPVU001A
  // pages 12-111 / 12-109):
  //   - MMTM: mm_rp_q seeds to (initial Rp - 32) so the first push lands
  //     at Rp-32; it decrements by 32 after each ack EXCEPT the last, so
  //     the final value (= initial - 32*count) is the lowest written
  //     address, written back as the new Rp.
  //   - MMFM: mm_rp_q seeds to (initial Rp) so the first read is at Rp;
  //     it increments by 32 after EVERY ack including the last, so the
  //     final value (= initial + 32*count) points one word past the data,
  //     written back as the new Rp.
  //
  // Assumption A0026: bit N of the mask = register R(N) for both
  // instructions. The spec's chart was a graphical figure unrecoverable
  // from pdftotext; the MMTM→MMFM round-trip test is the real check, and
  // it only depends on MMTM/MMFM agreeing on the mapping, not its
  // absolute value.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] mm_rp_q;
  logic [15:0]           mm_mask_q;
  logic [3:0]            mm_iter_idx;
  logic                  mm_mask_will_be_empty;
  logic                  is_mmtm, is_mmfm, is_mm;

  assign is_mmtm = (decoded.iclass == INSTR_MMTM);
  assign is_mmfm = (decoded.iclass == INSTR_MMFM);
  assign is_mm   = is_mmtm || is_mmfm;

  always_comb begin
    mm_iter_idx = 4'd0;
    if (is_mmfm) begin
      // MMFM: highest set bit. Iterate low→high so the LAST overwrite
      // (the largest i with mm_mask_q[i]=1) wins.
      for (int i = 0; i < 16; i++) begin
        if (mm_mask_q[i]) mm_iter_idx = i[3:0];
      end
    end else begin
      // MMTM: lowest set bit. Iterate high→low so the loop terminates
      // on the smallest i with mm_mask_q[i]=1.
      for (int i = 15; i >= 0; i--) begin
        if (mm_mask_q[i]) mm_iter_idx = i[3:0];
      end
    end
  end
  // After we clear the bit at mm_iter_idx, will the mask be empty? Gates
  // the FSM transition (last transaction → WRITEBACK) and, for MMTM,
  // suppresses the final Rp-decrement.
  assign mm_mask_will_be_empty = ((mm_mask_q & ~(16'd1 << mm_iter_idx)) == 16'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      mm_rp_q   <= '0;
      mm_mask_q <= '0;
    end else if (state_q == CORE_EXECUTE && is_mm && (imm_lo_q == 16'd0)) begin
      // Empty register list: no memory traffic; Rp unchanged (MAME no-ops the
      // loop). Seed mm_rp_q so WRITEBACK rewrites the original pointer.
      mm_rp_q   <= rf_rs2_data;
      mm_mask_q <= 16'd0;
    end else if (state_q == CORE_EXECUTE
              && state_d == CORE_MEMORY
              && is_mm) begin
      // First entry to CORE_MEMORY: capture the mask and seed the
      // working Rp. MMTM predecrements (first push at Rp-32); MMFM
      // starts at Rp (first read at Rp).
      //
      // MASK ENCODING (MAME 34010ops.hxx, corrects assumption A0026): the two
      // instructions use OPPOSITE mask conventions. MMTM's mask is BIT-REVERSED
      // (ROM bit 15-r = register r: MAME scans l&0x8000 with i=0..15), while
      // MMFM's is normal (bit r = register r: i=15..0). E.g. `MMTM SP,A0,A7`
      // assembles mask 0x8100 but `MMFM SP,A0,A7` assembles 0x0081. Reversing
      // MMTM's mask here makes bit N = register N uniform for the iterator.
      // (Found via the game-entry trace diff: the boot never executes MMTM, so
      // no earlier MAME diff could catch it; a same-wrong-mapping round-trip
      // test also cannot. The first game-code MMFM restored A8/A9/A11/SP's
      // pushed values into A0/A4/A6/A7 and the CMOS library crashed.)
      mm_rp_q   <= is_mmtm ? (rf_rs2_data - WORD_BIT_SIZE) : rf_rs2_data;
      // explicit bit-reverse (Quartus 17.1 lacks the {<<{}} streaming operator)
      mm_mask_q <= is_mmtm ? {imm_lo_q[0],  imm_lo_q[1],  imm_lo_q[2],  imm_lo_q[3],
                              imm_lo_q[4],  imm_lo_q[5],  imm_lo_q[6],  imm_lo_q[7],
                              imm_lo_q[8],  imm_lo_q[9],  imm_lo_q[10], imm_lo_q[11],
                              imm_lo_q[12], imm_lo_q[13], imm_lo_q[14], imm_lo_q[15]}
                           : imm_lo_q;
    end else if (state_q == CORE_MEMORY
              && is_mm
              && mem_ack) begin
      mm_mask_q[mm_iter_idx] <= 1'b0;
      if (is_mmfm) begin
        // MAME updates Rp live: REG(i)=RLONG(Rp); Rp+=32. When i==Rd the
        // restored stack image becomes the next base (loaded_Rp+32).
        if (mm_iter_idx == decoded.rd_idx)
          mm_rp_q <= mem_rdata_eff + WORD_BIT_SIZE;
        else
          mm_rp_q <= mm_rp_q + WORD_BIT_SIZE;
      end else if (!mm_mask_will_be_empty) begin
        // Pre-decrement model: skip the step after the final push so the
        // last write address remains as the new Rp.
        mm_rp_q <= mm_rp_q - WORD_BIT_SIZE;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Immediate latch
  //
  // Long-immediate-form instructions (MOVI IW/IL, ADDI IW/IL, ...) fetch
  // one or two additional 16-bit words after the opcode word. The
  // imm_lo_q / imm_hi_q registers are DECLARED earlier (just before
  // the branch_target_long block) so the assigns above can reference
  // them under strict simulators like Questa; the always_ff that
  // updates them sits here.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      imm_lo_q <= '0;
      imm_hi_q <= '0;
      abs2_lo_q <= '0;
      abs2_hi_q <= '0;
    end else begin
      if (state_q == CORE_FETCH_IMM_LO && mem_ack) begin
        imm_lo_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_HI && mem_ack) begin
        imm_hi_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_ABS2_LO && mem_ack) begin
        abs2_lo_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_ABS2_HI && mem_ack) begin
        abs2_hi_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Datapath modules
  //
  // Control signals are now driven by `decoded.*` plus the FSM state:
  // writes only happen in CORE_WRITEBACK, and only for instructions whose
  // decoded record requests a writeback (decoded.wb_reg_en /
  // decoded.wb_flags_en).
  // ---------------------------------------------------------------------------

  // Register-file ports.
  reg_file_t              rf_rs1_file;
  reg_idx_t               rf_rs1_idx;
  logic [DATA_WIDTH-1:0]  rf_rs1_data;
  reg_file_t              rf_rs2_file;
  reg_idx_t               rf_rs2_idx;
  logic [DATA_WIDTH-1:0]  rf_rs2_data;
  reg_file_t              rf_rs3_file;
  reg_idx_t               rf_rs3_idx;
  logic [DATA_WIDTH-1:0]  rf_rs3_data;
  logic                   rf_wr_en;
  reg_file_t              rf_wr_file;
  reg_idx_t               rf_wr_idx;
  logic [DATA_WIDTH-1:0]  rf_wr_data;
  logic [DATA_WIDTH-1:0]  rf_sp;

  // ALU ports.
  alu_op_t                alu_op;
  logic [DATA_WIDTH-1:0]  alu_a;
  logic [DATA_WIDTH-1:0]  alu_b;
  logic                   alu_cin;
  logic [DATA_WIDTH-1:0]  alu_result;
  logic [DATA_WIDTH-1:0]  alu_result_q;     // settled in CORE_EXECUTE
  alu_flags_t             alu_flags;
  alu_flags_t             alu_flags_q;

  // Status-register ports.
  logic                   st_flag_update_en;
  logic                   st_write_en;
  logic [DATA_WIDTH-1:0]  st_write_data;
  logic [DATA_WIDTH-1:0]  st_value;
  logic                   st_n, st_c, st_z, st_v;

  // Shifter ports.
  logic [DATA_WIDTH-1:0]  shifter_result;
  logic [DATA_WIDTH-1:0]  shifter_result_q; // settled in CORE_EXECUTE
  alu_flags_t             shifter_flags;
  alu_flags_t             shifter_flags_q;
  logic [DATA_WIDTH-1:0]  setf_new_st_q;    // settled in CORE_EXECUTE
  // XY / MOVX family also settled in EXECUTE (same timing cut as ALU/shifter).
  logic [DATA_WIDTH-1:0]  movx_result_q, movy_result_q;
  logic [DATA_WIDTH-1:0]  addxy_result_q, subxy_result_q;
  logic [DATA_WIDTH-1:0]  cpw_result_q, sext_result_q, zext_result_q, lmo_result_q;
  alu_flags_t             addxy_flags_q, subxy_flags_q, cmpxy_flags_q, cpw_flags_q;

  // ---- Operand assembly ----------------------------------------------------
  // Full 32-bit immediate composed from the latched 16-bit pieces. For
  // IW form: sign-extend (or zero-extend) imm_lo_q. For IL form (Task
  // 0013): concatenate {imm_hi_q, imm_lo_q}.
  logic [DATA_WIDTH-1:0] imm32;
  always_comb begin
    if (decoded.needs_imm32) begin
      imm32 = {imm_hi_q, imm_lo_q};
    end else if (decoded.imm_sign_extend) begin
      imm32 = {{(DATA_WIDTH-INSTR_WORD_WIDTH){imm_lo_q[INSTR_WORD_WIDTH-1]}}, imm_lo_q};
    end else begin
      imm32 = {{(DATA_WIDTH-INSTR_WORD_WIDTH){1'b0}}, imm_lo_q};
    end
  end

  logic [DATA_WIDTH-1:0] abs2;
  assign abs2 = {abs2_hi_q, abs2_lo_q};

  // ---- Register-file selectors driven by decode ----------------------------
  // rs1 reads Rs (used as ALU `a` for reg-reg ops). rs2 reads Rd (used as
  // ALU `b` for reg-reg ops where Rd is also a source, e.g. ADD Rs,Rd).
  // For MOVI / MOVK, the rs1/rs2 reads still occur but their values are
  // not routed to alu_a/b (the alu_b mux picks imm32 or zero-extended k5
  // instead).
  //
  // TMS34010 reg-reg encoding constrains Rs and Rd to the same file, so
  // a single `decoded.rd_file` drives both reads.
  // Read-port 1 normally reads from the destination file (reg-reg ops
  // are same-file). MOVE Rs,Rd is the one cross-file exception: Rs may
  // live in the opposite file from Rd, so it uses decoded.rs_file.
  // FILL reads its implied B-file operands across two cycles via the three
  // read ports: at EXECUTE — DADDR(B2) on port1, DPTCH(B3) on port2,
  // DYDX(B7) on port3; at CORE_FILL_SETUP — COLOR1(B9) on port1.
  logic is_fill, fill_is_xy, is_pblt;
  assign is_fill    = (decoded.iclass == INSTR_FILL_L) || (decoded.iclass == INSTR_FILL_XY);
  assign fill_is_xy = (decoded.iclass == INSTR_FILL_XY);
  // PIXBLT reads its 5 implied B-file operands across two cycles: at EXECUTE —
  // SADDR(B0) on port1, DADDR(B2) on port2, DYDX(B7) on port3; at
  // CORE_PBLT_SETUP — SPTCH(B1) on port1, DPTCH(B3) on port2.
  assign is_pblt    = (decoded.iclass == INSTR_PIXBLT_LL);
  // DRAV: at EXECUTE — Rs on port1, Rd on port2, OFFSET(B4) on port3 (for the
  // XY->linear conversion of Rd); in CORE_DRAV — COLOR1(B9) on port1.
  logic is_drav;
  assign is_drav    = (decoded.iclass == INSTR_DRAV);
  // LINE: 3 setup cycles read the implied B operands —
  //   SETUP1: d(B0)/DYDX(B7)/COUNT(B10);  SETUP2: INC1(B11)/INC2(B12)/OFFSET(B4);
  //   SETUP3: DADDR(B2)/COLOR1(B9).  All reads are from the B file.
  logic is_line;
  assign is_line    = (decoded.iclass == INSTR_LINE);
  logic line_rd_b;   // LINE is doing B-file setup reads this cycle
  assign line_rd_b  = is_line && ((state_q == CORE_LINE_SETUP1)
                               || (state_q == CORE_LINE_SETUP2)
                               || (state_q == CORE_LINE_SETUP3)
                               || (state_q == CORE_LINE_SETUP_WIN));

  assign rf_rs1_file = line_rd_b ? REG_FILE_B
                     : (state_q == CORE_PIXT_SETUP_WIN) ? REG_FILE_B
                     : (is_drav && ((state_q == CORE_DRAV) || (state_q == CORE_DRAV_SETUP_WIN))) ? REG_FILE_B
                     : (is_fill || is_pblt) ? REG_FILE_B
                     : (decoded.iclass == INSTR_MOVE_RR) ? decoded.rs_file
                     : decoded.rd_file;
  // Read-port 1 index is normally decoded.rs_idx. MMTM repurposes it
  // during CORE_MEMORY to scan the register list — rf_rs1_idx then
  // points at the current register being pushed, and rf_rs1_data
  // becomes the 32-bit value driven onto mem_wdata.
  assign rf_rs1_idx  = is_fill ? ((state_q == CORE_FILL_SETUP_WIN) ? CPW_WSTART_IDX
                                : (state_q == CORE_FILL_SETUP) ? B_COLOR1_IDX : B_DADDR_IDX)
                     : is_pblt ? ((state_q == CORE_PBLT_SETUP_WIN) ? CPW_WSTART_IDX
                                : (state_q == CORE_PBLT_SETUP2) ? B_COLOR0_IDX
                                : (state_q == CORE_PBLT_SETUP)  ? B_SPTCH_IDX : B_SADDR_IDX)
                     : (state_q == CORE_MEMORY && is_mmtm) ? mm_iter_idx
                     : (is_drav && (state_q == CORE_DRAV_SETUP_WIN)) ? CPW_WSTART_IDX // WSTART
                     : (is_drav && (state_q == CORE_DRAV)) ? B_COLOR1_IDX  // COLOR1 for the draw
                     : (is_line && (state_q == CORE_LINE_SETUP1)) ? B_SADDR_IDX   // d (B0)
                     : (is_line && (state_q == CORE_LINE_SETUP2)) ? B_INC1_IDX    // INC1 (B11)
                     : (is_line && (state_q == CORE_LINE_SETUP3)) ? B_DADDR_IDX   // DADDR (B2)
                     : (is_line && (state_q == CORE_LINE_SETUP_WIN)) ? CPW_WSTART_IDX // WSTART (B5)
                     : (state_q == CORE_PIXT_SETUP_WIN) ? CPW_WSTART_IDX           // PIXT WSTART
                     : decoded.rs_idx;
  // Read port 2 normally reads Rd. CPW repurposes it (Rd is not a source
  // for CPW) to read the window-start register WSTART = B5; read port 3
  // reads the window-end register WEND = B6. Both are fixed B-file
  // registers per SPVU001A page 12-57. FILL: B3 (DPTCH) / B7 (DYDX).
  // PIXBLT: DADDR(B2) at EXECUTE, DPTCH(B3) at SETUP.
  assign rf_rs2_file = (line_rd_b || is_fill || is_pblt || (decoded.iclass == INSTR_CPW)
                        || (state_q == CORE_PIXT_SETUP_WIN)
                        || (is_drav && (state_q == CORE_DRAV_SETUP_WIN)))
                     ? REG_FILE_B : decoded.rd_file;
  assign rf_rs2_idx  = is_fill ? ((state_q == CORE_FILL_SETUP_WIN) ? CPW_WEND_IDX : B_DPTCH_IDX)
                     : is_pblt ? ((state_q == CORE_PBLT_SETUP_WIN) ? CPW_WEND_IDX
                                : (state_q == CORE_PBLT_SETUP2) ? B_COLOR1_IDX
                                : (state_q == CORE_PBLT_SETUP)  ? B_DPTCH_IDX : B_DADDR_IDX)
                     : (is_drav && (state_q == CORE_DRAV_SETUP_WIN)) ? CPW_WEND_IDX  // WEND
                     : (is_line && (state_q == CORE_LINE_SETUP1)) ? B_DYDX_IDX    // DYDX (B7)
                     : (is_line && (state_q == CORE_LINE_SETUP2)) ? B_INC2_IDX    // INC2 (B12)
                     : (is_line && (state_q == CORE_LINE_SETUP3)) ? B_COLOR1_IDX  // COLOR1 (B9)
                     : (is_line && (state_q == CORE_LINE_SETUP_WIN)) ? CPW_WEND_IDX // WEND (B6)
                     : (state_q == CORE_PIXT_SETUP_WIN) ? CPW_WEND_IDX             // PIXT WEND
                     : (decoded.iclass == INSTR_CPW) ? CPW_WSTART_IDX : decoded.rd_idx;
  // Read port 3: CPW reads WEND (B6); DIVU/DIVS (even Rd) read the low half
  // of the 64-bit dividend, Rd+1; CVXYL/XY-PIXT read OFFSET (B4); FILL/PIXBLT
  // read DYDX (B7) at EXECUTE. Otherwise unused.
  assign rf_rs3_file = ((decoded.iclass == INSTR_DIVU) || (decoded.iclass == INSTR_DIVS))
                     ? decoded.rd_file : REG_FILE_B;
  assign rf_rs3_idx  = ((decoded.iclass == INSTR_DIVU) || (decoded.iclass == INSTR_DIVS))
                     ? (decoded.rd_idx + 4'd1)
                     : is_fill ? ((state_q == CORE_FILL_SETUP) ? B_OFFSET_IDX : B_DYDX_IDX)
                     : is_pblt ? ((state_q == CORE_PBLT_SETUP) ? B_OFFSET_IDX : B_DYDX_IDX)
                     : (is_line && (state_q == CORE_LINE_SETUP1)) ? B_COUNT_IDX   // COUNT (B10)
                     : (is_line && (state_q == CORE_LINE_SETUP2)) ? B_OFFSET_IDX  // OFFSET (B4)
                     : ((decoded.iclass == INSTR_CVXYL) || decoded.xy_addr || is_drav) ? B_OFFSET_IDX
                     : CPW_WEND_IDX;

  // DSJ-family runtime gate. For DSJEQ/DSJNE, the decrement (and any
  // subsequent jump) happens only if the Z bit pre-condition holds:
  //   - DSJ:   unconditional   → gate = 1
  //   - DSJEQ: gated on Z=1    → gate = st_z
  //   - DSJNE: gated on Z=0    → gate = !st_z
  // For non-DSJ instructions this signal is irrelevant; we default
  // it to 1 so it doesn't interfere with their writebacks.
  logic dsj_precondition;
  always_comb begin
    unique case (decoded.iclass)
      INSTR_DSJ,
      INSTR_DSJS:   dsj_precondition = 1'b1;
      INSTR_DSJEQ:  dsj_precondition = st_z;
      INSTR_DSJNE:  dsj_precondition = !st_z;
      default:      dsj_precondition = 1'b1;
    endcase
  end

  // "Will Rd be zero after the decrement?" — needed for the DSJ
  // branch decision. alu_result_q (latched in CORE_EXECUTE) is the
  // decremented Rd at WRITEBACK for the DSJ family.
  logic dsj_rd_nonzero;
  assign dsj_rd_nonzero = (alu_result_q != '0);

  // Writeback enable is a one-cycle pulse, gated by the FSM state.
  // Writeback data and flag-input come from either the ALU or the
  // shifter depending on `decoded.use_shifter`. For DSJEQ/DSJNE the
  // dsj_precondition further gates the write: if Z doesn't match the
  // pre-condition the spec mandates Rd is left unchanged.
  // MMFM writes a popped register on every CORE_MEMORY ack (mem_rdata_eff is
  // valid in the same cycle mem_ack asserts). This is a second user of
  // the single regfile write port, active in CORE_MEMORY rather than
  // CORE_WRITEBACK; the final-Rp write still happens at WRITEBACK below.
  // Rp is never in the list (spec: "unpredictable results"), so the two
  // writes never target the same index.
  logic mmfm_pop_wr;
  assign mmfm_pop_wr = (state_q == CORE_MEMORY) && is_mmfm && mem_ack;

  // ---- Indirect MOVE addressing + auto inc/dec (Task 0059/0060) -----------
  // Pointer register: Rd for stores (rf_rs2), Rs for loads (rf_rs1). The
  // memory address is the pointer (postinc/none) or pointer-32 (predec);
  // the post-update pointer value is pointer±32 (FS=32). For LOAD inc/dec
  // the updated pointer is written to Rs during CORE_MEMORY (a second
  // regfile-write user, like mmfm_pop_wr); the data write to Rd happens at
  // WRITEBACK, so when Rs==Rd the data wins (SPVU001A 12-143).
  logic                  is_mv_store, is_mv_load;
  logic                  mv_postinc, mv_predec, mv_incdec;
  logic [DATA_WIDTH-1:0] mv_ptr, mv_addr, mv_ptr_new;
  logic                  mv_load_ptr_wr;
  assign is_mv_store = (decoded.iclass == INSTR_MOVE_FIELD_STORE);
  assign is_mv_load  = (decoded.iclass == INSTR_MOVE_FIELD_LOAD);
  assign mv_postinc  = (decoded.move_mode == MV_ADDR_POSTINC);
  assign mv_predec   = (decoded.move_mode == MV_ADDR_PREDEC);
  assign mv_incdec   = mv_postinc || mv_predec;
  assign mv_ptr      = is_mv_store ? rf_rs2_data : rf_rs1_data;
  assign mv_load_ptr_wr = (state_q == CORE_MEMORY) && is_mv_load
                       && mv_incdec && mem_ack;

  // ---- MOVE field-size machinery (Task 0077) ------------------------------
  // The F bit (instr_word_q[9]) selects the FS0/FE0 (0) or FS1/FE1 (1) pair
  // in ST. FS=0 encodes a 32-bit field. Field stores write the low FS bits
  // (the memory model does the read-modify-write); field loads extend the
  // FS-bit field to 32 bits per FE (1 = sign-extend, 0 = zero-extend).
  // Indirect pointers auto-step by ±FS, not the old hardcoded ±32.
  logic [4:0]            mv_fs_raw;
  logic [FIELD_SIZE_WIDTH-1:0] mv_fs;       // actual field size 1..32
  logic                  mv_fe;             // 1 = sign-extend on load
  logic [DATA_WIDTH-1:0] mv_fs_ext;         // FS zero-extended to the pointer width
  logic [DATA_WIDTH-1:0] mv_fmask;
  logic [DATA_WIDTH-1:0] mv_load_data;      // field-extended load result
  assign mv_fs_raw = instr_word_q[9] ? st_value[ST_FS1_HI:ST_FS1_LO]
                                     : st_value[ST_FS0_HI:ST_FS0_LO];
  // MOVB (decoded.force_byte) forces an 8-bit field and sign-extension on
  // load. PIXT (decoded.force_pixel) forces the field size to the PSIZE I/O
  // register value and zero-extension on load. Both override ST.FS/FE.
  // PIXT: PSIZE==0 means 32 (same encoding as ST.FS), not a zero-width field
  // that would postinc by 0 while the memory path treats size 0 as 32.
  assign mv_fs     = decoded.force_byte   ? 6'd8   // width == FIELD_SIZE_WIDTH
                   : decoded.force_pixel  ? ((io_psize[FIELD_SIZE_WIDTH-1:0] == '0)
                                            ? MEM_SIZE_32
                                            : io_psize[FIELD_SIZE_WIDTH-1:0])
                   : (mv_fs_raw == 5'd0)  ? MEM_SIZE_32
                                          : {1'b0, mv_fs_raw};
  assign mv_fe     = decoded.force_byte   ? 1'b1   // MOVB: sign-extend
                   : decoded.force_pixel  ? 1'b0   // PIXT: zero-extend
                   : (instr_word_q[9] ? st_value[ST_FE1_BIT] : st_value[ST_FE0_BIT]);
  assign mv_fs_ext = {{(DATA_WIDTH-FIELD_SIZE_WIDTH){1'b0}}, mv_fs};
  assign mv_fmask  = (mv_fs >= MEM_SIZE_32)
                   ? '1 : ((32'd1 << mv_fs) - 32'd1);
  always_comb begin
    if (mv_fs >= MEM_SIZE_32) begin
      mv_load_data = mem_rdata_eff;                         // FS = 32: identity
    end else if (mv_fe && mem_rdata_eff[5'(mv_fs - 6'd1)]) begin
      mv_load_data = mem_rdata_eff | ~mv_fmask;             // sign-extend
    end else begin
      mv_load_data = mem_rdata_eff & mv_fmask;              // zero-extend
    end
  end

  // PIXT store pixel-write engine (Tasks 0089/0090/0091). A PIXT store is a
  // 2-step CORE_MEMORY read-modify-write: step 0 reads the destination pixel
  // (pix_dest_q), step 1 writes the result. The result combines three CONTROL
  // features, all confined to the PSIZE-bit pixel by mv_fmask:
  //   1. Pixel processing (PPOP, CONTROL[14:10]): processed = f(src, dest) via
  //      ppop_apply -- all 22 codes (16 Boolean + 6 arithmetic ADD/ADDS/SUB/
  //      SUBS/MAX/MIN, 0x10-0x15) are implemented, MAME-exact.
  //   2. Transparency (CONTROL.T, bit 5): if enabled and the PROCESSED pixel
  //      is 0, the destination is left unchanged (write the old value back —
  //      memory cycles still occur, per the spec).
  //   3. Plane mask (PMASK): a 1 bit protects that plane:
  //      merged = (processed & ~pmask) | (dest & pmask).
  // `pixt_rmw` selects this path; a regular MOVE store (no force_pixel) stays
  // a single write.
  logic                  pixt_rmw;
  logic [DATA_WIDTH-1:0] pixt_pmask_field;
  logic [DATA_WIDTH-1:0] pix_dest_q;     // dest pixel latched at the read step
  logic [DATA_WIDTH-1:0] pixt_processed; // PPOP(src, dest)
  logic                  pixt_transp;    // transparency inhibits this write
  logic [DATA_WIDTH-1:0] pixt_merged;    // value written at step 1
  // Arithmetic-PPOP operands: the PSIZE-bit pixels as unsigned values, and
  // the unsigned add. Arith ops are only defined for pixels of 4/8/16 bits
  // (SPVU001A); they are computed for all sizes (1/2-bit results are
  // spec-Undefined, so any value is acceptable).
  // DPYCTL.SRT converts PIXT into a hardware shift-register transfer.  Its
  // store form is a single write cycle (the data operand is ignored), not the
  // normal pixel plane-mask read/modify/write.  Performing the preliminary
  // read here would replace the source shift-register image with destination
  // data immediately before the store, making NARC's score-table scroll inert.
  assign pixt_rmw         = decoded.force_pixel && is_mv_store && !dpyctl_o[11];
  assign pixt_pmask_field = {{(DATA_WIDTH-16){1'b0}}, io_pmask} & mv_fmask;
  assign pixt_processed   = ppop_apply(rf_rs1_data & mv_fmask, pix_dest_q,
                                       io_control[CTRL_PPOP_HI:CTRL_PPOP_LO], mv_fmask);
  assign pixt_transp  = io_control[CTRL_T_BIT] && ((pixt_processed & mv_fmask) == '0);
  // Per-pixel window check for an XY PIXT store (Task 0117), mirroring DRAV.
  // WSTART/WEND are read at CORE_PIXT_SETUP_WIN; the pointer's XY (mv_ptr) is
  // tested. Drawn for W=0, or W=2/W=3 when inside; W=1 never draws. V (W!=0) =
  // NOT inside; WVP on a W=1 hit (inside) or W=2 miss (outside). Gated by
  // pixt_xy_win so a regular MOVE / non-XY PIXT / W=0 PIXT is unaffected.
  logic                  pixt_xy_win;
  logic [DATA_WIDTH-1:0] pixt_wstart_q, pixt_wend_q;
  logic                  pixt_inside_q;     // latched at the RMW write step
  logic                  pixt_in_window, pixt_clip_out;
  assign pixt_xy_win  = pixt_rmw && decoded.xy_addr
                     && (io_control[CTRL_W_HI:CTRL_W_LO] != 2'd0);
  assign pixt_in_window =
        (mv_ptr[15:0] >= pixt_wstart_q[15:0]) && (mv_ptr[15:0] <= pixt_wend_q[15:0])
     && (mv_ptr[DATA_WIDTH-1:16] >= pixt_wstart_q[DATA_WIDTH-1:16])
     && (mv_ptr[DATA_WIDTH-1:16] <= pixt_wend_q[DATA_WIDTH-1:16]);
  // W=1 never draws; W=2/W=3 draw inside.
  assign pixt_clip_out = pixt_xy_win &&
                         ((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1) || !pixt_in_window);
  assign pixt_merged  = (pixt_transp || pixt_clip_out)
                      ? pix_dest_q
                      : ((pixt_processed & ~pixt_pmask_field) | (pix_dest_q & pixt_pmask_field));
  always_ff @(posedge clk) begin
    if (rst) begin
      pixt_wstart_q <= '0;
      pixt_wend_q   <= '0;
      pixt_inside_q <= 1'b0;
    end else begin
      if (state_q == CORE_PIXT_SETUP_WIN) begin
        pixt_wstart_q <= rf_rs1_data;   // WSTART (B5)
        pixt_wend_q   <= rf_rs2_data;   // WEND (B6)
      end
      // Latch the pointer's window status at the RMW write step (for the
      // final V / WVP written at CORE_WRITEBACK).
      if ((state_q == CORE_MEMORY) && pixt_rmw && (mem_op_step == 2'd1) && mem_ack)
        pixt_inside_q <= pixt_in_window;
    end
  end

  // XY-addressed PIXT: the pointer holds an XY value; convert it to a linear
  // bit address (same shift form as CVXYL). CONVDP for a destination pointer
  // (store), CONVSP for a source pointer (load). OFFSET = B4 (read port 3).
  logic [15:0]           pix_xy_conv;
  logic [4:0]            pix_xy_yshift;
  logic [4:0]            pix_xy_xsh;
  logic [DATA_WIDTH-1:0] pix_xy_linear;
  assign pix_xy_conv   = is_mv_store ? io_convdp : io_convsp;
  assign pix_xy_yshift = 5'd31 - pix_xy_conv[4:0];
  always_comb begin
    unique case (io_psize[4:0])
      5'd1:    pix_xy_xsh = 5'd0;
      5'd2:    pix_xy_xsh = 5'd1;
      5'd4:    pix_xy_xsh = 5'd2;
      5'd8:    pix_xy_xsh = 5'd3;
      5'd16:   pix_xy_xsh = 5'd4;
      default: pix_xy_xsh = 5'd0;
    endcase
  end
  assign pix_xy_linear = (({{16{mv_ptr[DATA_WIDTH-1]}}, mv_ptr[DATA_WIDTH-1:16]} << pix_xy_yshift)
                          | ({16'b0, mv_ptr[15:0]} << pix_xy_xsh))
                         + rf_rs3_data;   // + OFFSET (B4)

  assign mv_addr     = decoded.xy_addr ? pix_xy_linear
                     : mv_predec       ? (mv_ptr - mv_fs_ext) : mv_ptr;
  assign mv_ptr_new  = mv_predec ? (mv_ptr - mv_fs_ext) : (mv_ptr + mv_fs_ext);

  // Destination-pointer XY conversion (for the XY-to-XY PIXT M2M, Task 0086).
  // pix_xy_linear above converts the SOURCE pointer (mv_ptr = rf_rs1 for the
  // M2M) with CONVSP; the M2M destination (rf_rs2) converts with CONVDP.
  logic [4:0]            pix_xy_dst_yshift;
  logic [DATA_WIDTH-1:0] pix_xy_dst_linear;
  assign pix_xy_dst_yshift = 5'd31 - io_convdp[4:0];
  assign pix_xy_dst_linear =
      (({{16{rf_rs2_data[DATA_WIDTH-1]}}, rf_rs2_data[DATA_WIDTH-1:16]} << pix_xy_dst_yshift)
       | ({16'b0, rf_rs2_data[15:0]} << pix_xy_xsh))
      + rf_rs3_data;   // + OFFSET (B4)

  // ---- Indirect-to-indirect MOVE auto inc/dec (Task 0062) -----------------
  // Two pointers (Rs=source, Rd=dest) both step by ±32. The source pointer
  // (Rs) is written during CORE_MEMORY at the step-0 (read) ack; the
  // destination pointer (Rd) is written at WRITEBACK. The step-1 (write)
  // address uses rf_rs2_data, which — when Rs==Rd — already reflects the
  // step-0 Rs update, so a postincrement Rs==Rd writes to the incremented
  // location (SPVU001A 12-138). To avoid double-stepping that one register,
  // the WRITEBACK Rd write is suppressed when Rs==Rd.
  logic                  is_mv_m2m, m2m_same_reg, m2m_src_wr;
  logic [DATA_WIDTH-1:0] m2m_src_addr, m2m_dst_addr, m2m_src_new, m2m_dst_new;
  assign is_mv_m2m    = (decoded.iclass == INSTR_MOVE_FIELD_M2M);
  assign m2m_same_reg = (decoded.rs_idx == decoded.rd_idx);
  // Field-size aware (Task 0079): both pointers step by ±FS, not ±32. XY PIXT
  // M2M (Task 0086): the pointers hold XY values — convert the source with
  // CONVSP (pix_xy_linear) and the destination with CONVDP (pix_xy_dst_linear).
  assign m2m_src_addr = decoded.xy_addr ? pix_xy_linear
                      : mv_predec       ? (rf_rs1_data - mv_fs_ext) : rf_rs1_data;
  assign m2m_dst_addr = decoded.xy_addr ? pix_xy_dst_linear
                      : mv_predec       ? (rf_rs2_data - mv_fs_ext) : rf_rs2_data;
  assign m2m_src_new  = mv_predec ? (rf_rs1_data - mv_fs_ext) : (rf_rs1_data + mv_fs_ext);
  assign m2m_dst_new  = mv_predec ? (rf_rs2_data - mv_fs_ext) : (rf_rs2_data + mv_fs_ext);
  // Update the source pointer Rs at the step-0 read ack (inc/dec M2M only).
  assign m2m_src_wr   = (state_q == CORE_MEMORY) && is_mv_m2m && mv_incdec
                     && (mem_op_step == 2'd0) && mem_ack;

  // FILL writes the final DADDR back to B2 in CORE_FILL_WB; PIXBLT writes the
  // final SADDR (B0) in CORE_PBLT_WB and the final DADDR (B2) in CORE_PBLT_WB2.
  logic fill_wb, pblt_wb_saddr, pblt_wb_daddr, graphics_wb;
  assign fill_wb       = (state_q == CORE_FILL_WB);
  assign pblt_wb_saddr = (state_q == CORE_PBLT_WB);
  assign pblt_wb_daddr = (state_q == CORE_PBLT_WB2);
  // LINE writebacks: d -> B0, DADDR -> B2, COUNT -> B10, one per cycle.
  logic line_wb_d, line_wb_daddr, line_wb_count, line_wb;
  assign line_wb_d     = (state_q == CORE_LINE_WB_D);
  assign line_wb_daddr = (state_q == CORE_LINE_WB_DADDR);
  assign line_wb_count = (state_q == CORE_LINE_WB_COUNT);
  assign line_wb       = line_wb_d || line_wb_daddr || line_wb_count;
  assign graphics_wb   = fill_wb || pblt_wb_saddr || pblt_wb_daddr || line_wb;
  // Interrupt-entry SP writeback: at CORE_INT_DONE, SP <- SP-64 (two 32-bit
  // pushes done). Only when context was actually pushed (an NMI with NMIM=1
  // saves nothing, so SP is unchanged). Highest-priority regfile write.
  logic int_sp_wb;
  assign int_sp_wb = (state_q == CORE_INT_DONE) && int_push_q;
  assign rf_wr_en   = ((state_q == CORE_WRITEBACK)
                       && decoded.wb_reg_en
                       && dsj_precondition
                       && !(is_mv_m2m && m2m_same_reg)   // Rs==Rd: Rs write already covered it
                       && !(is_div && div_v))            // divide overflow: leave Rd unchanged
                   || mmfm_pop_wr
                   || mv_load_ptr_wr
                   || m2m_src_wr
                   || graphics_wb
                   || int_sp_wb;
  assign rf_wr_file = int_sp_wb ? REG_FILE_A
                    : graphics_wb ? REG_FILE_B : decoded.rd_file;
  assign rf_wr_idx  = int_sp_wb ? REG_SP_IDX
                    : line_wb_count              ? B_COUNT_IDX
                    : (fill_wb || pblt_wb_daddr || line_wb_daddr) ? B_DADDR_IDX
                    : (pblt_wb_saddr || line_wb_d) ? B_SADDR_IDX  // LINE d -> B0
                    : mmfm_pop_wr                ? mm_iter_idx
                    : (mv_load_ptr_wr || m2m_src_wr) ? decoded.rs_idx  // update pointer Rs
                    : ((is_mpy || is_div) && pair_wb_step) ? (decoded.rd_idx + 4'd1)  // pair low/rem -> Rd+1
                                                     : decoded.rd_idx;
  // EXGF (Exchange Field Definition) datapath. Per SPVU001A page 12-77:
  // Rd's low 6 bits swap with the F-selected FE:FS pair (1 + 5 bits)
  // in ST. Rd's upper 26 bits are cleared after the swap.
  //
  // Because the regfile is async-read, rf_rs2_data delivers the OLD
  // Rd value during the same CORE_WRITEBACK cycle that writes the
  // new value — so a single-cycle atomic swap is straightforward.
  logic [4:0]            exgf_cur_fs;
  logic                  exgf_cur_fe;
  logic [DATA_WIDTH-1:0] exgf_new_rd;
  logic [DATA_WIDTH-1:0] exgf_new_st;
  assign exgf_cur_fs = instr_word_q[9] ? st_value[ST_FS1_HI:ST_FS1_LO]
                                       : st_value[ST_FS0_HI:ST_FS0_LO];
  assign exgf_cur_fe = instr_word_q[9] ? st_value[ST_FE1_BIT]
                                       : st_value[ST_FE0_BIT];
  assign exgf_new_rd = {{(DATA_WIDTH-6){1'b0}}, exgf_cur_fe, exgf_cur_fs};
  always_comb begin
    exgf_new_st = st_value;
    if (instr_word_q[9]) begin
      exgf_new_st[ST_FS1_HI:ST_FS1_LO] = rf_rs2_data[4:0];
      exgf_new_st[ST_FE1_BIT]          = rf_rs2_data[5];
    end else begin
      exgf_new_st[ST_FS0_HI:ST_FS0_LO] = rf_rs2_data[4:0];
      exgf_new_st[ST_FE0_BIT]          = rf_rs2_data[5];
    end
  end

  // ---- ADDXY / SUBXY datapath (XY-coordinate arithmetic) ------------------
  // Treat each register as two 16-bit halves: X = low 16, Y = high 16.
  // ADDXY/SUBXY operate on the halves independently, with NO carry/borrow
  // propagating between them. Rd is both a source and the destination;
  // rf_rs2_data delivers the old Rd, rf_rs1_data the Rs operand.
  //   ADDXY (SPVU001A 12-41):  N=(Xres==0), V=Xres[15], Z=(Yres==0), C=Yres[15].
  //   SUBXY (SPVU001A 12-252): compare-style flags — N=(RsX==RdX),
  //     V=(RsX>RdX), Z=(RsY==RdY), C=(RsY>RdY) (unsigned, = subtract borrow).
  logic [15:0] xy_rs_x, xy_rs_y, xy_rd_x, xy_rd_y;
  logic [15:0] xy_x_add, xy_y_add, xy_x_sub, xy_y_sub;
  logic [DATA_WIDTH-1:0] addxy_result, subxy_result;
  alu_flags_t            addxy_flags, subxy_flags;
  assign xy_rs_x = rf_rs1_data[15:0];
  assign xy_rs_y = rf_rs1_data[DATA_WIDTH-1:16];
  assign xy_rd_x = rf_rs2_data[15:0];
  assign xy_rd_y = rf_rs2_data[DATA_WIDTH-1:16];
  assign xy_x_add = xy_rd_x + xy_rs_x;     // 16-bit, carry dropped
  assign xy_y_add = xy_rd_y + xy_rs_y;
  assign xy_x_sub = xy_rd_x - xy_rs_x;     // Rd - Rs per spec
  assign xy_y_sub = xy_rd_y - xy_rs_y;
  assign addxy_result = {xy_y_add, xy_x_add};
  assign subxy_result = {xy_y_sub, xy_x_sub};
  assign addxy_flags = '{n: (xy_x_add == 16'd0), c: xy_y_add[15],
                          z: (xy_y_add == 16'd0), v: xy_x_add[15]};
  // SUBXY's C and V are SIGNED compares. MAME 34010ops.hxx SUB_XY does
  // SET_C_LOG(a.y > b->y) / SET_V_LOG(a.x > b->x), and tms34010.h declares
  // XY as { int16_t x; int16_t y; } -- the halves are signed. Screen
  // coordinates legitimately go negative, and an unsigned compare returns
  // the opposite answer for them.
  assign subxy_flags = '{n: (xy_x_sub == 16'd0),
                          c: ($signed(xy_rs_y) > $signed(xy_rd_y)),
                          z: (xy_y_sub == 16'd0),
                          v: ($signed(xy_rs_x) > $signed(xy_rd_x))};
  // CMPXY (SPVU001A 12-55): nondestructive; flags use the SIGN bits of the
  // per-half subtract results (NOT the unsigned borrow SUBXY uses).
  alu_flags_t cmpxy_flags;
  assign cmpxy_flags = '{n: (xy_x_sub == 16'd0), c: xy_y_sub[15],
                          z: (xy_y_sub == 16'd0), v: xy_x_sub[15]};

  // ---- CPW (Compare Point to Window) datapath (SPVU001A 12-57) ------------
  // Compare the XY point in Rs (rf_rs1) against the window corners
  // WSTART = B5 (rf_rs2, overridden above) and WEND = B6 (rf_rs3). X = low
  // 16 signed, Y = high 16 signed. The 4-bit out-of-window code lands in
  // Rd[8:5]; all other bits 0. V = 1 iff the point is outside the window
  // (any code bit set); N/C/Z Unaffected (masked off by wb_flag_mask).
  logic [15:0] cpw_pt_x, cpw_pt_y, cpw_ws_x, cpw_ws_y, cpw_we_x, cpw_we_y;
  logic        cpw_b5, cpw_b6, cpw_b7, cpw_b8;
  logic [DATA_WIDTH-1:0] cpw_result;
  alu_flags_t  cpw_flags;
  assign cpw_pt_x = rf_rs1_data[15:0];
  assign cpw_pt_y = rf_rs1_data[DATA_WIDTH-1:16];
  assign cpw_ws_x = rf_rs2_data[15:0];        // WSTART.X (B5)
  assign cpw_ws_y = rf_rs2_data[DATA_WIDTH-1:16];
  assign cpw_we_x = rf_rs3_data[15:0];        // WEND.X   (B6)
  assign cpw_we_y = rf_rs3_data[DATA_WIDTH-1:16];
  assign cpw_b5 = ($signed(cpw_ws_x) > $signed(cpw_pt_x));  // WSTART.X > Rs.X
  assign cpw_b6 = ($signed(cpw_pt_x) > $signed(cpw_we_x));  // Rs.X > WEND.X
  assign cpw_b7 = ($signed(cpw_ws_y) > $signed(cpw_pt_y));  // WSTART.Y > Rs.Y
  assign cpw_b8 = ($signed(cpw_pt_y) > $signed(cpw_we_y));  // Rs.Y > WEND.Y
  assign cpw_result = {{(DATA_WIDTH-9){1'b0}}, cpw_b8, cpw_b7, cpw_b6, cpw_b5, 5'b0};
  assign cpw_flags  = '{n: 1'b0, c: 1'b0, z: 1'b0,
                         v: (cpw_b5 | cpw_b6 | cpw_b7 | cpw_b8)};

  // ---- CVXYL (convert XY address to linear) datapath -----------------------
  // SPVU001A page 12-59: linear = [(Y << ydp_shift) OR (X << xsh)] + OFFSET.
  // X = Rs[15:0] (positive), Y = Rs[31:16] (signed). The screen pitch and
  // pixel size are powers of two, so the multiplies are shifts: the Y shift
  // is 31 - CONVDP[4:0] (CONVDP encodes the destination pitch as a shift; e.g.
  // CONVDP=0x14 -> shift 11 -> pitch 2^11), and the X shift is log2(PSIZE).
  // OFFSET (B-file B4, on read port 3) is the linear address of XY origin.
  logic [4:0]            cvxyl_ydp_shift;
  logic [4:0]            cvxyl_xsh;
  logic [DATA_WIDTH-1:0] cvxyl_ypart, cvxyl_xpart, cvxyl_result;
  assign cvxyl_ydp_shift = 5'd31 - io_convdp[4:0];
  always_comb begin
    unique case (io_psize[4:0])
      5'd1:    cvxyl_xsh = 5'd0;
      5'd2:    cvxyl_xsh = 5'd1;
      5'd4:    cvxyl_xsh = 5'd2;
      5'd8:    cvxyl_xsh = 5'd3;
      5'd16:   cvxyl_xsh = 5'd4;
      default: cvxyl_xsh = 5'd0;   // PSIZE not a power of two in 1..16: undefined
    endcase
  end
  // Sign-extend Y (signed) to 32 bits before the shift; X is positive.
  assign cvxyl_ypart  = {{16{rf_rs1_data[DATA_WIDTH-1]}}, rf_rs1_data[DATA_WIDTH-1:16]}
                        << cvxyl_ydp_shift;
  assign cvxyl_xpart  = {16'b0, rf_rs1_data[15:0]} << cvxyl_xsh;
  assign cvxyl_result = (cvxyl_ypart | cvxyl_xpart) + rf_rs3_data;   // + OFFSET (B4)

  // ---- MPYS / MPYU multiply datapath (SPVU001A 12-164/12-166) -------------
  // Rd (rf_rs2) is the 32-bit multiplicand, Rs (rf_rs1) the multiplier — an
  // FS1-bit field (FS1=0 means 32, the whole Rs). The 64-bit product is
  // latched in CORE_EXECUTE (mpy_product_q — the registered output for DSP
  // inference) and written back over 1 cycle (odd Rd: low 32 to Rd) or 2
  // cycles (even Rd: hi 32 to Rd, then lo 32 to Rd+1). pair_wb_step (shared
  // with DIVU) selects the second pass.
  logic                  is_mpy, mpy_signed, mpy_rd_even;
  logic signed [63:0]    mpy_sprod;
  logic        [63:0]    mpy_uprod, mpy_product, mpy_product_q;
  assign is_mpy      = (decoded.iclass == INSTR_MPYS) || (decoded.iclass == INSTR_MPYU);
  assign mpy_signed  = (decoded.iclass == INSTR_MPYS);
  assign mpy_rd_even = (decoded.rd_idx[0] == 1'b0);
  // Variable multiplier width: extract the low FS1 bits of Rs and
  // sign-extend (MPYS) or zero-extend (MPYU) to 32 bits before the multiply;
  // Rd (the multiplicand) stays full 32-bit.
  logic [4:0]            mpy_fs1;
  logic [DATA_WIDTH-1:0] mpy_fmask;
  logic [DATA_WIDTH-1:0] mpy_rs_field;
  assign mpy_fs1   = st_value[ST_FS1_HI:ST_FS1_LO];
  assign mpy_fmask = (32'd1 << mpy_fs1) - 32'd1;   // FS1 1..31; FS1=0 uses full Rs below
  always_comb begin
    if (mpy_fs1 == 5'd0) begin
      mpy_rs_field = rf_rs1_data;                                    // FS1 = 32
    end else if (mpy_signed && rf_rs1_data[mpy_fs1 - 5'd1]) begin
      mpy_rs_field = (rf_rs1_data & mpy_fmask) | ~mpy_fmask;         // MPYS sign-extend
    end else begin
      mpy_rs_field = rf_rs1_data & mpy_fmask;                        // zero-extend / positive
    end
  end
  // 64-bit-context products: operands sign/zero-extend to 64 then multiply.
  assign mpy_sprod   = $signed(rf_rs2_data) * $signed(mpy_rs_field);
  assign mpy_uprod   = rf_rs2_data * mpy_rs_field;
  assign mpy_product = mpy_signed ? $unsigned(mpy_sprod) : mpy_uprod;

  // ---- DIVU divide datapath (SPVU001A 12-69) -----------------------------
  // Multi-cycle restoring divider runs in CORE_DIVIDE. Even Rd: 64-bit
  // dividend {Rd, Rd+1} (Rd+1 read via port 3) -> quotient in Rd, remainder
  // in Rd+1. Odd Rd: 32-bit dividend Rd -> quotient in Rd. On overflow
  // (divisor 0 or quotient > 32 bits) the result is NOT written; only V is
  // set. The product/quotient pair-writeback to {Rd, Rd+1} is shared with
  // MPY via pair_wb_step.
  // is_div = the whole divide family (DIVU/MODU/DIVS/MODS) — anything that
  // runs the multi-cycle divider via CORE_DIVIDE. The divider itself is
  // unsigned; for the signed variants the core feeds |operands| and
  // sign-conditions the results.
  logic                  is_div, is_divu, is_modu, is_divs, is_mods;
  logic                  is_signed_div, is_div_mod, div_rd_even, div_use_pair;
  logic [2*DATA_WIDTH-1:0] div_dividend;
  logic [DATA_WIDTH-1:0]   div_divisor, div_quotient, div_remainder;
  logic                    div_start, div_busy, div_done, div_overflow;
  assign is_divu       = (decoded.iclass == INSTR_DIVU);
  assign is_modu       = (decoded.iclass == INSTR_MODU);
  assign is_divs       = (decoded.iclass == INSTR_DIVS);
  assign is_mods       = (decoded.iclass == INSTR_MODS);
  assign is_div        = is_divu || is_modu || is_divs || is_mods;
  assign is_signed_div = is_divs || is_mods;
  assign is_div_mod    = is_modu || is_mods;        // remainder result (vs quotient)
  assign div_rd_even   = (decoded.rd_idx[0] == 1'b0);
  // Only DIVU/DIVS with an even Rd use the 64-bit {Rd, Rd+1} dividend; the
  // MOD ops and odd-Rd divides use the 32-bit {0/sext, Rd} dividend.
  assign div_use_pair  = (is_divu || is_divs) && div_rd_even;

  // Operand signs (signed variants only) and magnitudes fed to the divider.
  // The combinational signs drive the divider-input abs at CORE_EXECUTE;
  // the LATCHED signs (_q, captured at the divide start) drive the result
  // sign-conditioning at WRITEBACK — by then Rd may already hold the
  // quotient (even-Rd pass 0), so its live MSB is no longer the dividend's.
  logic div_dvd_sign, div_dvs_sign, div_result_neg;
  logic div_dvd_sign_q, div_dvs_sign_q;
  assign div_dvd_sign = is_signed_div && rf_rs2_data[DATA_WIDTH-1];   // Rd MSB
  assign div_dvs_sign = is_signed_div && rf_rs1_data[DATA_WIDTH-1];   // Rs MSB
  assign div_result_neg = div_dvd_sign_q ^ div_dvs_sign_q;            // quotient sign

  always_ff @(posedge clk) begin
    if (rst) begin
      div_dvd_sign_q <= 1'b0;
      div_dvs_sign_q <= 1'b0;
    end else if (state_q == CORE_EXECUTE && is_div) begin
      div_dvd_sign_q <= div_dvd_sign;
      div_dvs_sign_q <= div_dvs_sign;
    end
  end

  logic [DATA_WIDTH-1:0]   rd_abs;
  logic [2*DATA_WIDTH-1:0] raw64, abs64;
  assign rd_abs = rf_rs2_data[DATA_WIDTH-1] ? (~rf_rs2_data + 1'b1) : rf_rs2_data;
  assign raw64  = {rf_rs2_data, rf_rs3_data};
  assign abs64  = rf_rs2_data[DATA_WIDTH-1] ? (~raw64 + 1'b1) : raw64;
  always_comb begin
    if (!is_signed_div)
      div_dividend = div_use_pair ? raw64 : {{DATA_WIDTH{1'b0}}, rf_rs2_data};
    else if (div_use_pair)
      div_dividend = abs64;                                // |{Rd, Rd+1}|
    else
      div_dividend = {{DATA_WIDTH{1'b0}}, rd_abs};         // {0, |Rd|}
  end
  assign div_divisor = div_dvs_sign ? (~rf_rs1_data + 1'b1) : rf_rs1_data;

  // One-cycle start pulse as we leave CORE_EXECUTE for CORE_DIVIDE; the
  // divider latches the operands on that edge.
  assign div_start = (state_q == CORE_EXECUTE) && is_div;

  tms34010_divider u_divider (
    .clk       (clk),
    .rst       (rst),
    .start     (div_start),
    .dividend  (div_dividend),
    .divisor   (div_divisor),
    .busy      (div_busy),
    .done      (div_done),
    .quotient  (div_quotient),
    .remainder (div_remainder),
    .overflow  (div_overflow)
  );

  // Sign-condition the magnitude results, and compute the divide-family
  // result/flags. div_quot_out/div_rem_out are the (possibly negated)
  // values; div_result_main is what the flags/Z reflect.
  logic [DATA_WIDTH-1:0] div_quot_out, div_rem_out, div_result_main;
  assign div_quot_out = div_result_neg  ? (~div_quotient  + 1'b1) : div_quotient;
  assign div_rem_out  = div_dvd_sign_q  ? (~div_remainder + 1'b1) : div_remainder;
  assign div_result_main = is_div_mod ? div_rem_out : div_quot_out;
  // Signed overflow: the magnitude quotient must fit a signed 32-bit value.
  //   positive result: |q| >= 2^31  -> overflow
  //   negative result: |q| >  2^31  -> overflow (|q|==2^31 is -2^31, valid)
  // (div_overflow already covers Rs=0 and |q| >= 2^32.)
  logic div_signed_ovf, div_v;
  assign div_signed_ovf = div_overflow
    || (is_signed_div &&
        (div_result_neg ? (div_quotient[DATA_WIDTH-1] && (div_quotient[DATA_WIDTH-2:0] != '0))
                        :  div_quotient[DATA_WIDTH-1]));
  assign div_v = is_signed_div ? div_signed_ovf : div_overflow;

  // ---- Pair writeback step (shared MPY-even / DIVU-even) ------------------
  // Ops that write the {Rd, Rd+1} register pair over two WRITEBACK cycles.
  // pair_wb_step selects the second pass (Rd+1). DIVU on overflow writes
  // nothing, so it is not a pair-writeback op then.
  logic is_pair_wb, pair_second_pass, pair_wb_step;
  assign is_pair_wb = (is_mpy && mpy_rd_even)
                   || (div_use_pair && !div_v);   // DIVU/DIVS even (not MOD; not on overflow)
  assign pair_second_pass = is_pair_wb && (pair_wb_step == 1'b0);

  always_ff @(posedge clk) begin
    if (rst) begin
      mpy_product_q <= '0;
      pair_wb_step  <= 1'b0;
    end else begin
      if (state_q == CORE_EXECUTE && is_mpy) begin
        mpy_product_q <= mpy_product;
      end
      // Step 0 -> 1 only while we hold in WRITEBACK for the second pass.
      if (state_q == CORE_WRITEBACK) begin
        pair_wb_step <= pair_second_pass ? 1'b1 : 1'b0;
      end else begin
        pair_wb_step <= 1'b0;
      end
    end
  end

  // SEXT / ZEXT field-extension datapath. Per SPVU001A pages 12-238
  // (SEXT) and 12-256 (ZEXT): take the low `FS` bits of Rd, then
  // either sign-extend (copy the field MSB into bits[31:FS]) or
  // zero-extend (clear bits[31:FS]). FS is read from the F-selected
  // pair in ST (FS0 if instr_word_q[9]=0, FS1 if =1). FS=5'b00000
  // encodes a field-size of 32 per Table 5-3, so the data is the
  // full 32-bit register and no extension is needed.
  logic [4:0]            fs_selected;
  logic [DATA_WIDTH-1:0] field_mask;
  logic                  field_msb;
  logic [DATA_WIDTH-1:0] sext_result;
  logic [DATA_WIDTH-1:0] zext_result;
  assign fs_selected = instr_word_q[9]
                     ? st_value[ST_FS1_HI:ST_FS1_LO]
                     : st_value[ST_FS0_HI:ST_FS0_LO];
  always_comb begin
    if (fs_selected == 5'd0) begin
      // Field-size = 32: identity.
      field_mask  = '1;
      field_msb   = rf_rs2_data[DATA_WIDTH-1];
      sext_result = rf_rs2_data;
      zext_result = rf_rs2_data;
    end else begin
      field_mask  = (32'd1 << fs_selected) - 32'd1;
      field_msb   = rf_rs2_data[fs_selected - 5'd1];
      sext_result = field_msb ? ((rf_rs2_data & field_mask) | ~field_mask)
                              :  (rf_rs2_data & field_mask);
      zext_result = rf_rs2_data & field_mask;
    end
  end

  // LMO (Leftmost-One) datapath. Pure combinational — finds the
  // highest-set bit of rf_rs1_data and computes Rd = 31 - bit_pos
  // (i.e., one's-complement of the bit position in 5 bits). The
  // upper 27 bits of Rd are zero. If rf_rs1_data == 0, Rd = 0 and
  // the Z flag (gated by wb_flag_mask) is set.
  logic [4:0]            lmo_bit_pos;
  logic [DATA_WIDTH-1:0] lmo_result;
  always_comb begin
    // Iterate low-to-high so the LAST overwrite (highest set bit)
    // wins. Synthesizable — no `break`, no run-time loop.
    lmo_bit_pos = 5'd0;
    for (int i = 0; i < DATA_WIDTH; i++) begin
      if (rf_rs1_data[i]) lmo_bit_pos = i[4:0];
    end
    if (rf_rs1_data == '0)
      lmo_result = '0;
    else
      lmo_result = {{(DATA_WIDTH-5){1'b0}}, ~lmo_bit_pos};
  end

  // Regfile write-data mux. Several "Rd ← something" instructions
  // bypass the ALU/shifter and route a different source:
  //   GETST  → ST value
  //   GETPC  → current PC value
  //   EXGPC  → current PC value (the other half of the swap)
  //   REV    → chip-revision constant (A0025)
  //   LMO_RR → priority-encoder result
  // The default routes the shifter or ALU result per decoded.use_shifter.
  always_comb begin
    if (int_sp_wb) begin
      // Interrupt entry: SP <- SP - 64 (two 32-bit pushes complete).
      rf_wr_data = rf_sp - WORD_BIT_SIZE_2;
    end else
    unique case (decoded.iclass)
      // MOVX/MOVY/ADDXY/SUBXY/CPW: latched in CORE_EXECUTE (see below).
      INSTR_MOVX:   rf_wr_data = movx_result_q;
      INSTR_MOVY:   rf_wr_data = movy_result_q;
      INSTR_ADDXY:  rf_wr_data = addxy_result_q;
      INSTR_SUBXY:  rf_wr_data = subxy_result_q;
      INSTR_DRAV:   rf_wr_data = drav_advance;   // Rd advanced by Rs (XY add)
      INSTR_CPW:    rf_wr_data = cpw_result_q;
      // MPYS/MPYU: even Rd -> hi32 then (Rd+1) lo32; odd Rd -> lo32.
      INSTR_MPYS,
      INSTR_MPYU:   rf_wr_data = mpy_rd_even
                               ? (pair_wb_step ? mpy_product_q[31:0] : mpy_product_q[63:32])
                               : mpy_product_q[31:0];
      // DIVU: even Rd -> quotient (pass 0), remainder -> Rd+1 (pass 1);
      // odd Rd -> quotient. (Skipped entirely on overflow via rf_wr_en.)
      // DIVU/DIVS: even Rd -> quotient (pass 0), remainder -> Rd+1 (pass 1);
      // odd Rd -> quotient. div_quot_out/div_rem_out are sign-conditioned
      // (identity for the unsigned variants).
      INSTR_DIVU,
      INSTR_DIVS:   rf_wr_data = (div_rd_even && pair_wb_step) ? div_rem_out
                                                              : div_quot_out;
      // MODU/MODS: the remainder of Rd mod Rs -> Rd (single writeback).
      INSTR_MODU,
      INSTR_MODS:   rf_wr_data = div_rem_out;
      INSTR_GETST:  rf_wr_data = st_value;
      INSTR_MMTM:   rf_wr_data = mm_rp_q;       // final Rp = address of last push
      // MMFM: per-iteration pop writes mem_rdata_eff to the popped register;
      // the WRITEBACK pass writes final Rp (= initial + 32*count).
      INSTR_MMFM:   rf_wr_data = mmfm_pop_wr ? mem_rdata_eff : mm_rp_q;
      // MOVE *Rs,Rd: Rd <- the 32 bits read from mem[Rs]. At WRITEBACK
      // mem_rdata_eff resolves to mem_rdata_q, the copy latched at the
      // load's ack, so the value cannot be disturbed by later bus traffic.
      // Store inc/dec writes the auto-updated pointer back to Rd at
      // WRITEBACK (plain store has wb_reg_en=0, so this is unused there).
      INSTR_MOVE_FIELD_STORE: rf_wr_data = mv_ptr_new;
      // Load: at WRITEBACK -> the field-extended data to Rd; during
      // CORE_MEMORY (inc/dec) -> the updated pointer to Rs.
      INSTR_MOVE_FIELD_LOAD: rf_wr_data = mv_load_ptr_wr ? mv_ptr_new : mv_load_data;
      // Indirect-to-indirect inc/dec: source pointer Rs (step-0 ack) or
      // destination pointer Rd (WRITEBACK).
      INSTR_MOVE_FIELD_M2M: rf_wr_data = m2m_src_wr ? m2m_src_new : m2m_dst_new;
      // MOVE *Rs(SOff),*Rd+ / MOVE @SAddr,*Rd+: only dest pointer postincrements.
      INSTR_MOVE_OFF_NI,
      INSTR_MOVE_ABS_NI:    rf_wr_data = m2m_dst_new;
      // MOVE @SAddr,Rd: Rd <- the field-extended value read from the
      // absolute address. MOVE *Rs(off),Rd: same, from the offset address.
      INSTR_MOVE_ABS_LOAD,
      INSTR_MOVE_OFF_LOAD:  rf_wr_data = mv_load_data;
      INSTR_CVXYL:  rf_wr_data = cvxyl_result;
      INSTR_FILL_L,
      INSTR_FILL_XY: rf_wr_data = fill_addr_q;  // final (linear) DADDR -> B2 (CORE_FILL_WB)
      INSTR_PIXBLT_LL: rf_wr_data = pblt_wb_saddr ? pblt_wb_src_val   // SADDR -> B0
                                                  : pblt_wb_dst_val;  // DADDR -> B2
      INSTR_LINE:    rf_wr_data = line_wb_d     ? line_d_q      // d -> B0
                               : line_wb_daddr  ? line_daddr_q  // DADDR -> B2
                                                : line_count_q; // COUNT -> B10
      INSTR_GETPC,
      INSTR_EXGPC:  rf_wr_data = pc_value;
      INSTR_REV:    rf_wr_data = REV_VALUE;
      INSTR_LMO_RR: rf_wr_data = lmo_result_q;
      INSTR_SEXT:   rf_wr_data = sext_result_q;
      INSTR_ZEXT:   rf_wr_data = zext_result_q;
      INSTR_EXGF:   rf_wr_data = exgf_new_rd;
      // ALU/shifter results were registered in CORE_EXECUTE so WRITEBACK does
      // not re-close the full decode→ALU→regfile path in one clk_sys cycle
      // (Quartus critical path was instr_word_q → A-file).
      default:      rf_wr_data = decoded.use_shifter ? shifter_result_q : alu_result_q;
    endcase
  end

  // ALU operand selection.
  //
  // Default routing puts Rs on `alu_a` and Rd on `alu_b`, which works for
  // commutative reg-reg ops (ADD, AND, OR, XOR, ...) and for the move
  // family (`alu_b` is overridden to the immediate / K).
  //
  // For SUB (Rd - Rs → Rd) the order matters: we need `alu_a = Rd` and
  // `alu_b = Rs` because the ALU computes `a - b`. The two muxes below
  // swap routing for `INSTR_SUB_RR`.
  assign alu_op  = decoded.alu_op;
  always_comb begin
    unique case (decoded.iclass)
      INSTR_SUB_RR,
      INSTR_SUBB_RR,
      INSTR_ANDN_RR,
      INSTR_CMP_RR,
      INSTR_ADDK,
      INSTR_SUBK,
      INSTR_NEG,
      INSTR_NOT,
      INSTR_ABS,
      INSTR_ADDI_IW,
      INSTR_SUBI_IW,
      INSTR_CMPI_IW,
      INSTR_ADDI_IL,
      INSTR_SUBI_IL,
      INSTR_CMPI_IL,
      INSTR_ANDI_IL,
      INSTR_ORI_IL,
      INSTR_XORI_IL,
      INSTR_DSJ,
      INSTR_DSJEQ,
      INSTR_DSJNE,
      INSTR_DSJS,
      INSTR_BTST_K,
      INSTR_BTST_RR: alu_a = rf_rs2_data;   // Rd is the operand
      INSTR_NEGB:    alu_a = '0;            // NEGB: 0 - Rd - C via SUBB
      INSTR_PUSHST,
      INSTR_POPST,
      INSTR_CALL_RS,
      INSTR_CALLA,
      INSTR_CALLR,
      INSTR_RETS,
      INSTR_RETI,
      INSTR_TRAP:    alu_a = rf_rs2_data;   // SP via rs2 (rd_idx=15)
      default:       alu_a = rf_rs1_data;   // Rs (or unused for MOVI/MOVK)
    endcase
  end
  always_comb begin
    unique case (decoded.iclass)
      INSTR_MOVI_IW,
      INSTR_MOVI_IL,
      INSTR_ADDI_IW,
      INSTR_ADDI_IL,
      INSTR_ORI_IL,
      INSTR_XORI_IL: alu_b = imm32;
      // ANDI, SUBI (IW+IL) and CMPI (IW+IL) store the ONE'S-COMPLEMENT of the
      // operand in the instruction stream (MAME 34010ops.hxx: ANDI `&= ~PARAM`,
      // SUBI_W/L `t = ~PARAM`, CMPI_W/L `t = (int16_t)~PARAM` / `~PARAM_LONG`);
      // ADDI/ORI/XORI/MOVI are stored raw. PARAM_WORD() is int16_t (sign-
      // extended), so for the IW forms ~imm32 == sign_extend(~imm16) exactly.
      // The missing CMPI complement was THE black-screen bug: the boot's final
      // `CMPI 10FFFF0h,SP` (stored 0xFEF0000F) never matched, so it re-ran its
      // ~24s warm-up delay loop forever and never jumped to game code.
      INSTR_SUBI_IW,
      INSTR_SUBI_IL,
      INSTR_CMPI_IW,
      INSTR_CMPI_IL,
      INSTR_ANDI_IL: alu_b = ~imm32;
      // MOVK/ADDK/SUBK: K-field 0 encodes 32 (MAME fw_inc[0]=32). Without this
      // `MOVK 20h,A3` loaded 0 and the game's 32-entry process-table scan
      // (DSJS on the count) wrapped to ~4G iterations -- the attract sequencer
      // crawled ~17x slow scanning forever (found via the tb_attract scan probe).
      INSTR_MOVK,
      INSTR_ADDK,
      INSTR_SUBK:    alu_b = (decoded.k5 == 5'd0)
                           ? 32'd32
                           : {{(DATA_WIDTH-5){1'b0}}, decoded.k5};
      INSTR_DSJ,
      INSTR_DSJEQ,
      INSTR_DSJNE,
      INSTR_DSJS:    alu_b = {{(DATA_WIDTH-5){1'b0}}, decoded.k5};
      // BTST K: the K-field is stored as 31-bit (MAME: bit = 31 - PARAM_K).
      // The register form (BTST_RR) is RAW (bit = Rs & 0x1f) -- do not "fix" it.
      INSTR_BTST_K:  alu_b = 32'd1 << (5'd31 - decoded.k5);
      INSTR_BTST_RR: alu_b = 32'd1 << rf_rs1_data[4:0];
      INSTR_PUSHST,
      INSTR_POPST,
      INSTR_CALL_RS,
      INSTR_CALLA,
      INSTR_CALLR:   alu_b = WORD_BIT_SIZE;
      INSTR_RETS:    alu_b = WORD_BIT_SIZE + ({{(DATA_WIDTH-5){1'b0}}, decoded.k5} << 4);
      INSTR_RETI:    alu_b = WORD_BIT_SIZE_2;     // SP += 32 (ST pop) + 32 (PC pop) = 64
      INSTR_TRAP:    alu_b = trap_skip_push ? 32'd0 : WORD_BIT_SIZE_2;
                                          // N>0: SP -= 64 (PC push + ST push).
                                          // N=0: SP unchanged (TRAP 0 skips pushes).
      INSTR_SUB_RR,
      INSTR_SUBB_RR,
      INSTR_ANDN_RR,
      INSTR_CMP_RR:  alu_b = rf_rs1_data;   // Rs is the "second" operand
      default:       alu_b = rf_rs2_data;
    endcase
  end
  assign alu_cin = st_c;

  // Status-register inputs. Flag-update is gated by FSM state, like the
  // regfile write. Full ST write port is unused until POPST lands.
  assign st_flag_update_en = ((state_q == CORE_WRITEBACK) && decoded.wb_flags_en)
                           || fill_win_flag_wb;   // FILL W=2 writes V
  // ST-write data + enable. Two instructions drive the full ST-write
  // path:
  //   PUTST Rs: ST ← Rs (full copy).
  //   SETF FS, FE, F: read current ST, splice the F-selected FS/FE
  //                   pair with the new values from the instruction
  //                   word, write back.
  //
  // SETF operand extraction (from instr_word_q):
  //   F  = instr_word_q[9]
  //   FE = instr_word_q[5]
  //   FS = instr_word_q[4:0]
  logic [DATA_WIDTH-1:0] setf_new_st;
  always_comb begin
    setf_new_st = st_value;  // start from current
    if (instr_word_q[9]) begin
      // F=1: update FS1 (bits[10:6]) and FE1 (bit[11]).
      setf_new_st[ST_FS1_HI:ST_FS1_LO] = instr_word_q[4:0];
      setf_new_st[ST_FE1_BIT]          = instr_word_q[5];
    end else begin
      // F=0: update FS0 (bits[4:0]) and FE0 (bit[5]).
      setf_new_st[ST_FS0_HI:ST_FS0_LO] = instr_word_q[4:0];
      setf_new_st[ST_FE0_BIT]          = instr_word_q[5];
    end
  end

  // Interrupt entry always reloads ST (even NMI with NMIM=1 / no push),
  // matching MAME tms34010.cpp check_interrupt() → RESET_ST() after the
  // optional PC/ST push. Preserving only IE-clear left FS1 intact; NARC's
  // DIRQ then ran PALTRANS with FS1=2 inherited from UnpackRLC.
  assign st_write_en = ((state_q == CORE_WRITEBACK)
                    && ((decoded.iclass == INSTR_PUTST) ||
                        (decoded.iclass == INSTR_SETF)  ||
                        (decoded.iclass == INSTR_EXGF)  ||
                        (decoded.iclass == INSTR_DINT)  ||
                        (decoded.iclass == INSTR_EINT)  ||
                        (decoded.iclass == INSTR_POPST) ||
                        (decoded.iclass == INSTR_RETI)  ||
                        (decoded.iclass == INSTR_TRAP)))
                    || (state_q == CORE_INT_DONE);
  always_comb begin
    if (state_q == CORE_INT_DONE) begin
      // Interrupt entry: ST <- reset value (IE=0, flags=0, FS0=16, FS1=0).
      // Full ST was pushed when int_push_q; RETI restores it. Same as TRAP.
      st_write_data = ST_RESET_VALUE;
    end else
    unique case (decoded.iclass)
      INSTR_PUTST: st_write_data = rf_rs1_data;
      INSTR_SETF:  st_write_data = setf_new_st_q;  // latched in CORE_EXECUTE
      INSTR_EXGF:  st_write_data = exgf_new_st;
      INSTR_DINT:  st_write_data = st_value & ~(32'd1 << ST_IE_BIT);
      INSTR_EINT:  st_write_data = st_value |  (32'd1 << ST_IE_BIT);
      INSTR_POPST: st_write_data = mem_rdata_eff;        // popped 32-bit ST value
      INSTR_RETI:  st_write_data = popped_st_q;      // ST captured in step 0
      INSTR_TRAP:  st_write_data = ST_RESET_VALUE;   // 0x10: IE=0, flags=0, FS0=16, FS1=0 (= reset ST).
      default:     st_write_data = '0;
    endcase
  end

  // ---- Branch-condition evaluator -----------------------------------------
  // Combinational decode of decoded.branch_cc against the current ST
  // flags. Returns 1 if the branch should be taken. Codes not in the
  // verified set (A0017) return 0 (no branch); the decoder is responsible
  // for routing unverified codes to ILLEGAL so this default isn't reached
  // by a recognized JRCC.
  logic branch_taken;
  always_comb begin
    unique case (decoded.branch_cc)
      CC_UC:   branch_taken = 1'b1;
      CC_P:    branch_taken = !st_n & !st_z;          // positive (result > 0)
      CC_LS:   branch_taken = st_c | st_z;             // unsigned <=
      CC_HI:   branch_taken = !st_c & !st_z;           // unsigned >
      CC_LT:   branch_taken = st_n ^ st_v;             // signed   <
      CC_LE:   branch_taken = (st_n ^ st_v) | st_z;    // signed   <=
      CC_GT:   branch_taken = !(st_n ^ st_v) & !st_z;  // signed   >
      CC_GE:   branch_taken = !(st_n ^ st_v);          // signed   >=
      CC_EQ:   branch_taken = st_z;                    // =
      CC_NE:   branch_taken = !st_z;                   // !=
      CC_HS:   branch_taken = !st_c;                   // unsigned >=  (== NC)
      CC_C:    branch_taken = st_c;                     // carry set (== B)
      CC_V:    branch_taken = st_v;                     // overflow
      CC_NV:   branch_taken = !st_v;                    // no overflow
      CC_N:    branch_taken = st_n;                     // negative
      CC_NN:   branch_taken = !st_n;                    // nonnegative
      default: branch_taken = 1'b0;
    endcase
  end

  // ---- PC-load (branches) -------------------------------------------------
  // Gated by FSM state. For JRcc short, load the relative target in
  // CORE_WRITEBACK only when the condition is met.
  always_comb begin
    pc_load_en    = 1'b0;
    pc_load_value = '0;
    if (state_q == CORE_WRITEBACK) begin
      unique case (decoded.iclass)
        INSTR_JRCC_SHORT: begin
          if (branch_taken) begin
            pc_load_en    = 1'b1;
            pc_load_value = branch_target_short;
          end
        end
        INSTR_JRCC_LONG: begin
          if (branch_taken) begin
            pc_load_en    = 1'b1;
            pc_load_value = branch_target_long;
          end
        end
        INSTR_JUMP_RS: begin
          // Unconditional indirect jump: load PC from Rs (read via rs1
          // port) with the bottom 4 bits forced to 0 to enforce
          // word alignment per SPVU001A page 12-98.
          pc_load_en    = 1'b1;
          pc_load_value = {rf_rs1_data[ADDR_WIDTH-1:4], 4'h0};
        end
        INSTR_EXGPC: begin
          // Atomic swap PC ↔ Rd: PC ← old Rd (with bottom 4 bits forced
          // to 0 per A0025), Rd ← PC (via the rf_wr_data mux above).
          // rf_rs2_data is the async-read value of decoded.rd_idx in
          // the same file as the destination — i.e., the OLD Rd value.
          pc_load_en    = 1'b1;
          pc_load_value = {rf_rs2_data[ADDR_WIDTH-1:4], 4'h0};
        end
        INSTR_DSJ,
        INSTR_DSJEQ,
        INSTR_DSJNE: begin
          // Decrement-and-skip-jump family. Branch taken iff the
          // runtime pre-condition (always for DSJ; Z gate for
          // DSJEQ/DSJNE) holds AND the post-decrement Rd is nonzero.
          // Target shape matches the long-form JRcc:
          //   target = PC' + sign_extend(offset16) * 16
          // where PC' is pc_value at WRITEBACK (already advanced
          // through the opcode + offset-word fetches).
          if (dsj_precondition && dsj_rd_nonzero) begin
            pc_load_en    = 1'b1;
            pc_load_value = branch_target_long;
          end
        end
        INSTR_JACC: begin
          // Absolute conditional jump: PC ← {imm_hi_q, imm_lo_q} with
          // the bottom 4 bits forced to 0 (word alignment per spec
          // page 12-91). Re-uses the JRcc condition evaluator.
          if (branch_taken) begin
            pc_load_en    = 1'b1;
            pc_load_value = branch_target_jacc;
          end
        end
        INSTR_DSJS: begin
          // Short-form decrement-and-skip-jump. Branch taken iff the
          // post-decrement Rd is non-zero (dsj_precondition = 1 for
          // DSJS just like DSJ). Target = PC' ± offset×16 per
          // instr_word_q[10] direction bit.
          if (dsj_rd_nonzero) begin
            pc_load_en    = 1'b1;
            pc_load_value = branch_target_dsjs;
          end
        end
        INSTR_CALL_RS: begin
          // Subroutine call indirect: PC <- Rs (with bottom 4 bits
          // forced to 0 per SPVU001A page 12-47 "always sets the four
          // LSBs of the program counter to 0"). The return address
          // PC' has already been pushed to mem[new SP] in
          // CORE_MEMORY by the time we reach this WRITEBACK arm.
          pc_load_en    = 1'b1;
          pc_load_value = {rf_rs1_data[ADDR_WIDTH-1:4], 4'h0};
        end
        INSTR_CALLA: begin
          // Absolute call: PC <- {imm_hi_q, imm_lo_q} with bottom 4
          // bits cleared. Same target as JAcc (branch_target_jacc).
          pc_load_en    = 1'b1;
          pc_load_value = branch_target_jacc;
        end
        INSTR_CALLR: begin
          // Relative call: PC <- PC' + sign_ext(disp16) * 16. Same
          // target as JRcc long-form (branch_target_long).
          pc_load_en    = 1'b1;
          pc_load_value = branch_target_long;
        end
        INSTR_RETS: begin
          // Return from subroutine: PC <- popped value. mem_rdata_eff is
          // the copy latched at the pop's ack (see the mem_rdata_q latch
          // near the io_regs instantiation), so a bus change during this
          // WRITEBACK cycle cannot redirect the return -- this used to
          // rely on the memory holding mem_rdata after the ack, which is
          // not something a shared bus guarantees. The popped value is
          // already word-aligned (since it was pushed by a CALL/CALLA/
          // CALLR or TRAP), so no bottom-nibble mask is needed.
          pc_load_en    = 1'b1;
          pc_load_value = mem_rdata_eff;
        end
        INSTR_RETI: begin
          // Return from interrupt: PC <- popped_pc_q (latched in
          // step 1 of CORE_MEMORY). The matching popped ST is delivered
          // via the st_write_en path above.
          pc_load_en    = 1'b1;
          pc_load_value = popped_pc_q;
        end
        INSTR_TRAP: begin
          // Software interrupt: PC <- trap-vector value (latched into
          // popped_pc_q on step 2 of CORE_MEMORY). New ST is delivered
          // via the st_write_en path; SP -64 lands via alu_result/regfile.
          pc_load_en    = 1'b1;
          pc_load_value = popped_pc_q;
        end
        default: ; // no branch
      endcase
    end else if (state_q == CORE_INT_DONE) begin
      // Interrupt entry: load PC with the trap vector (ISR entry address),
      // latched into popped_pc_q on the CORE_INT_VECTOR ack. Already word-
      // aligned (it is a vector word), so no bottom-nibble mask.
      pc_load_en    = 1'b1;
      pc_load_value = popped_pc_q;
    end else if (state_q == CORE_RVEC_DONE) begin
      // smashtv reset: load PC with the fetched reset vector.
      pc_load_en    = 1'b1;
      pc_load_value = popped_pc_q;
    end
  end

  tms34010_regfile u_regfile (
    .clk      (clk),
    .rst      (rst),
    .rs1_file (rf_rs1_file),
    .rs1_idx  (rf_rs1_idx),
    .rs1_data (rf_rs1_data),
    .rs2_file (rf_rs2_file),
    .rs2_idx  (rf_rs2_idx),
    .rs2_data (rf_rs2_data),
    .rs3_file (rf_rs3_file),
    .rs3_idx  (rf_rs3_idx),
    .rs3_data (rf_rs3_data),
    .wr_en    (rf_wr_en),
    .wr_file  (rf_wr_file),
    .wr_idx   (rf_wr_idx),
    .wr_data  (rf_wr_data),
    .sp_o     (rf_sp)
  );

  // ---- On-chip I/O register file (Task 0082) ------------------------------
  // Accesses whose bit-address is in I/O space (0xC0000000-0xC00001FF) are
  // serviced on-chip. The register file's async read is muxed into
  // `mem_rdata_eff`, so MOVE/MOVB loads from I/O space observe the register
  // value; writes commit into the register file from the same req/we/addr
  // the external bus sees. The external memory ignores the I/O address range
  // (it is out of range for the simulation memory model), so the external
  // cycle is harmless. Faithful external-cycle gating (RAS-only) and an
  // on-chip ack belong with a later memory-fabric module. I/O registers are
  // 16-bit; the core accesses them with 16-bit fields (set FS=16).
  logic                  io_is_io;
  logic [15:0]           io_rdata16;
  logic [15:0]           io_psize;     // PSIZE register (pixel size, for PIXT/CVXYL)
  logic [15:0]           io_convdp;    // CONVDP register (XY->linear dest pitch)
  logic [15:0]           io_convsp;    // CONVSP register (XY->linear source pitch)
  logic [15:0]           io_control;   // CONTROL register (PPOP, T, window mode, ...)
  logic [15:0]           io_pmask;     // PMASK register (plane mask)
  logic [15:0]           io_intenb;    // INTENB register (maskable-interrupt enables)
  logic [15:0]           io_intpend;   // INTPEND register (maskable-interrupt pending)
  logic [15:0]           io_hstctlh;   // HSTCTLH register (host control; NMI/NMIM bits)
  logic                  nmi_clear;    // pulse to clear HSTCTLH.NMI on taking the NMI
  logic                  wvp_set;      // pulse to set INTPEND.WV on a window violation
  logic [DATA_WIDTH-1:0] mem_rdata_eff;
  logic                  mem_we_int;   // the FSM's write intent (pre-I/O gating)

  tms34010_io_regs u_io_regs (
    .clk      (clk),
    .rst      (rst),
    .req      (mem_req),
    .we       (mem_we_int),    // the access's write intent
    .addr     (mem_addr),
    .wdata    (mem_wdata[15:0]),
    .rdata    (io_rdata16),
    .is_io    (io_is_io),
    .psize_o  (io_psize),
    .convdp_o (io_convdp),
    .convsp_o (io_convsp),
    .control_o(io_control),
    .pmask_o  (io_pmask),
    .intenb_o (io_intenb),
    .intpend_o(io_intpend),
    .hstctlh_o(io_hstctlh),
    .nmi_clear(nmi_clear),
    .wvp_set  (wvp_set),
    .di_set   (ext_dint_set),
    .int1_line(ext_int1_line),
    .int2_line(ext_int2_line),
    .hcount_i (hcount_i),
    .vcount_i (vcount_i),
    .dpyint_o (dpyint_o),
    .dpyctl_o (dpyctl_o),
    .dpystart_o(dpystart_o),
    .dpytap_o (dpytap_o),
    .dpyadr_o (dpyadr_o)
  );

  // ---- Maskable-interrupt priority encoder (Task 0100) --------------------
  // Combinational: int_req asserts when ST.IE=1 and an enabled INTPEND bit is
  // set; int_vector is the winning source's trap-vector address. The core
  // recognises the request at the CORE_FETCH boundary and runs the entry
  // sequence below. NMI (host, via HSTCTL) is separate and not handled here.
  logic                  int_req;
  logic [ADDR_WIDTH-1:0] int_vector;
  tms34010_int_ctrl u_int_ctrl (
    .intpend   (io_intpend),
    .intenb    (io_intenb),
    .ie        (st_value[ST_IE_BIT]),
    .int_req   (int_req),
    .int_vector(int_vector)
  );
  // Nonmaskable interrupt (NMI): host sets HSTCTLH.NMI. It is non-maskable
  // (ignores ST.IE) and takes priority over maskable interrupts. NMIM selects
  // whether context (PC/ST) is pushed. The device auto-clears the NMI bit on
  // taking it (nmi_clear pulse below), else — being non-maskable — it would
  // re-trigger forever.
  logic nmi_req, nmi_nmim;
  assign nmi_req  = io_hstctlh[HSTCTL_NMI_BIT];
  assign nmi_nmim = io_hstctlh[HSTCTL_NMIM_BIT];
  // HALT (HSTCTLH bit 15): when set, the CPU stops at the instruction boundary —
  // no fetch, and NO interrupts (MAME tms34010.cpp execute_run: "Absolutely no
  // interrupts must be taken!!!"). It resumes only when the bit is cleared (on
  // real silicon, by the host; Smash TV never sets it). Gated in CORE_FETCH.
  logic cpu_halted;
  assign cpu_halted = io_hstctlh[HSTCTL_HLT_BIT] || ext_halt;

  // Instruction pacing (PACE_CLKS): a free-running down-counter reloaded at
  // each fetch; the next fetch is held until it hits 0. Interrupt entry is NOT
  // delayed (real interrupt latency is what it is). Zero-parameter = no logic.
  logic pace_ok;
  generate if (PACE_CLKS == 0) begin : g_nopace
    assign pace_ok = 1'b1;
  end else begin : g_pace
    logic [$clog2(PACE_CLKS+1)-1:0] pace_q;
    always_ff @(posedge clk) begin
      if (rst)                    pace_q <= '0;
      else if (state_q == CORE_FETCH && pc_advance_en)
                                  pace_q <= PACE_CLKS[$clog2(PACE_CLKS+1)-1:0];
      else if (pace_q != '0)      pace_q <= pace_q - 1'b1;
    end
    assign pace_ok = (pace_q == '0);
  end endgenerate
  // Any interrupt is taken at the fetch boundary when NMI is pending or a
  // maskable request is asserted.
  logic int_take;
  assign int_take = nmi_req || int_req;

  // ---------------------------------------------------------------------------
  // P0013: a fetch request the memory system has ALREADY LATCHED must run to
  // completion before we honour an interrupt. If int_take rises after mem_req
  // was asserted (e.g. the display interrupt firing mid-fetch — DPYINT is async
  // to the CPU), the core would abort the fetch and jump to CORE_INT_PUSH_PC;
  // the memsys's ack for the aborted read then gets misattributed to the
  // interrupt's PC push, so that 32-bit write is silently dropped and RETI later
  // returns to a corrupt (0) address -> derail into VRAM. Once a fetch is in
  // flight, ignore int_take until mem_ack; the interrupt is taken at the next
  // fetch boundary — HW-correct (the in-flight instruction completes).
  //
  // Coverage note for THIS core (which routes CORE_FETCH through the icache):
  //   * cache ENABLED  — icache_mem_req is only asserted while ic_state==IC_FILL,
  //     and ic_busy is high for the whole of that, so the existing !ic_busy gate
  //     already blocks the divert. fetch_inflight_q is redundant but harmless.
  //   * cache DISABLED (CONTROL.CD=1, bypass) — icache_mem_req mirrors fetch_req
  //     directly and ic_state never leaves IC_IDLE, so ic_busy is permanently 0
  //     and the !ic_busy gate does NOT protect the bypass fetch. That is the hole
  //     fetch_inflight_q closes.
  // ---------------------------------------------------------------------------
  logic fetch_inflight_q;
  always_ff @(posedge clk) begin
    if (rst)
      fetch_inflight_q <= 1'b0;
    else if (state_q == CORE_FETCH && mem_req && !mem_ack)
      fetch_inflight_q <= 1'b1;
    else if (mem_ack || state_q != CORE_FETCH)
      fetch_inflight_q <= 1'b0;
  end

  // Combined "an interrupt may be taken right now" gate for CORE_FETCH: only at
  // a clean boundary (no cache fill running, no bypass fetch outstanding).
  logic int_divert_ok;
  assign int_divert_ok = int_take && !ic_busy && !fetch_inflight_q;

  // ---------------------------------------------------------------------------
  // Instruction cache (256-byte, 4-segment). CORE_FETCH is routed through it:
  // on a hit the word is returned with no memory cycle; on a miss the icache
  // drives the shared memory bus to fill a 4-word subsegment. `ic_busy` is high
  // during a fill so an interrupt is not taken mid-fill (which would orphan it);
  // the interrupt is instead taken at the next clean fetch boundary. CD
  // (CONTROL bit 15) bypasses the cache; Smash TV runs with the cache enabled.
  // Functionally transparent — verified by the boot differential.
  // ---------------------------------------------------------------------------
  logic                  ic_fetch_req, ic_fetch_done, ic_busy;
  logic [15:0]           ic_fetch_word;
  logic                  ic_mem_req;
  logic [ADDR_WIDTH-1:0] ic_mem_addr;
  // P0013: hold fetch_req asserted while a bypass fetch is in flight, otherwise
  // dropping it would strand the icache's `fetch_done = fetch_req & mem_ack`
  // handshake for a read the memsys is already committed to completing.
  assign ic_fetch_req = (state_q == CORE_FETCH) && !cpu_halted && pace_ok
                     && !int_divert_ok;
  tms34010_icache u_icache (
    .clk(clk), .rst(rst),
    .cache_disable(io_control[15]),        // CONTROL.CD
    .flush(1'b0),                          // no runtime flush (no SMC; reset clears)
    .fetch_req(ic_fetch_req), .fetch_pc(pc_value),
    .fetch_done(ic_fetch_done), .fetch_word(ic_fetch_word), .busy(ic_busy),
    .icache_mem_req(ic_mem_req), .icache_mem_addr(ic_mem_addr),
    .mem_rdata(mem_rdata), .mem_ack(mem_ack)
  );

  // Capture the PC that named the instruction when its fetch completes.
  // The live pc_value advances on that same boundary, so using pc_o for a
  // later data transaction attributes the transaction to the following word.
  always_ff @(posedge clk) begin
    if (rst)
      instr_pc_q <= '0;
    else if (state_q == CORE_FETCH && ic_fetch_done)
      instr_pc_q <= pc_value;
  end

  // Latched state for the entry sequence (captured when leaving CORE_FETCH):
  //   int_vec_q    — the trap-vector address to fetch.
  //   int_is_nmi_q — this entry is an NMI (drives the auto-clear).
  //   int_push_q   — context is pushed (always for maskable; NMIM=0 for NMI).
  // nmi_clear pulses in CORE_INT_DONE when the latched entry was an NMI.
  logic [ADDR_WIDTH-1:0] int_vec_q;
  logic                  int_is_nmi_q;
  logic                  int_push_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      int_vec_q    <= '0;
      int_is_nmi_q <= 1'b0;
      int_push_q   <= 1'b0;
    end else if (state_q == CORE_FETCH && int_take) begin
      int_vec_q    <= nmi_req ? INT_VEC_NMI : int_vector;
      int_is_nmi_q <= nmi_req;
      int_push_q   <= nmi_req ? !nmi_nmim : 1'b1;   // NMIM=1 ⇒ no push
    end
  end
  assign nmi_clear = (state_q == CORE_INT_DONE) && int_is_nmi_q;
  // Gate the EXTERNAL write for I/O-space accesses: an I/O write commits into
  // u_io_regs and must NOT also write external memory (otherwise it would
  // corrupt RAM — a small external model that only decodes low address bits
  // would alias 0xC00001xx onto a low word). The external cycle is still
  // requested (so external memory provides the ack, RAS-style), but with
  // write disabled for I/O addresses; the read data is muxed below.
  assign mem_we = mem_we_int && !io_is_io;

  // Effective read data. A read's data is sampled ONCE, on the cycle the
  // access is acknowledged, and held from there through WRITEBACK.
  //
  // Both sources are latched at the ack:
  //   - The I/O register's async read follows mem_addr and would change as
  //     soon as the address moves on.
  //   - The external bus is NOT guaranteed to hold mem_rdata after the ack
  //     either. This code previously assumed it was ("the external memory
  //     model holds mem_rdata stable from the ack cycle through WRITEBACK")
  //     and fed combinational mem_rdata straight into the retired arm. That
  //     let any post-ack bus change overwrite an already-acknowledged read
  //     during WRITEBACK: RETS loaded its return PC from the later bus value
  //     rather than the popped one and jumped wild (tb_rets), POPST restored
  //     a corrupted ST (tb_popst), and MOVE @Addr,Rd wrote the mutated word
  //     (tb_move_abs_wb_race). On real hardware the bus is shared, so this
  //     was never a harness-only concern.
  //
  // During an active transaction (mem_req high, i.e. the ack cycle itself)
  // use the combinational value — that is the cycle the data arrives, and
  // per-ack consumers such as MMFM's pop writeback read it there. Once the
  // transaction has retired (WRITEBACK, mem_req low) use the latched copy.
  logic [15:0]           io_rdata_q;
  logic                  io_is_io_q;
  logic [DATA_WIDTH-1:0] mem_rdata_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      io_rdata_q  <= '0;
      io_is_io_q  <= 1'b0;
      mem_rdata_q <= '0;
    end else if (mem_req && mem_ack) begin
      io_rdata_q  <= io_rdata16;
      io_is_io_q  <= io_is_io;
      mem_rdata_q <= mem_rdata;
    end
  end
  assign mem_rdata_eff =
      mem_req ? (io_is_io   ? {{(DATA_WIDTH-16){1'b0}}, io_rdata16} : mem_rdata)
              : (io_is_io_q ? {{(DATA_WIDTH-16){1'b0}}, io_rdata_q} : mem_rdata_q);

  tms34010_alu u_alu (
    .op    (alu_op),
    .a     (alu_a),
    .b     (alu_b),
    .cin   (alu_cin),
    .result(alu_result),
    .flags (alu_flags)
  );

  // Capture ALU/shifter/SETF results during the intentional CORE_EXECUTE
  // settle cycle so WRITEBACK only pays a short register-to-register path.
  // MEMORY-state uses of alu_result (stack push address, etc.) keep the live
  // combinational value.
  always_ff @(posedge clk) begin
    if (rst) begin
      alu_result_q     <= '0;
      shifter_result_q <= '0;
      alu_flags_q      <= '0;
      shifter_flags_q  <= '0;
      setf_new_st_q    <= '0;
      movx_result_q    <= '0;
      movy_result_q    <= '0;
      addxy_result_q   <= '0;
      subxy_result_q   <= '0;
      cpw_result_q     <= '0;
      sext_result_q    <= '0;
      zext_result_q    <= '0;
      lmo_result_q     <= '0;
      addxy_flags_q    <= '0;
      subxy_flags_q    <= '0;
      cmpxy_flags_q    <= '0;
      cpw_flags_q      <= '0;
    end else if (state_q == CORE_EXECUTE) begin
      alu_result_q     <= alu_result;
      shifter_result_q <= shifter_result;
      alu_flags_q      <= alu_flags;
      shifter_flags_q  <= shifter_flags;
      setf_new_st_q    <= setf_new_st;
      movx_result_q    <= {rf_rs2_data[DATA_WIDTH-1:16], rf_rs1_data[15:0]};
      movy_result_q    <= {rf_rs1_data[DATA_WIDTH-1:16], rf_rs2_data[15:0]};
      addxy_result_q   <= addxy_result;
      subxy_result_q   <= subxy_result;
      cpw_result_q     <= cpw_result;
      sext_result_q    <= sext_result;
      zext_result_q    <= zext_result;
      lmo_result_q     <= lmo_result;
      addxy_flags_q    <= addxy_flags;
      subxy_flags_q    <= subxy_flags;
      cmpxy_flags_q    <= cmpxy_flags;
      cpw_flags_q      <= cpw_flags;
    end
  end

  // Shifter datapath. Operand is the Rd register value (via rf_rs2_data,
  // which already reads decoded.rd_idx in the same file as the
  // destination). Shift amount comes from one of two sources:
  //   - K-form shifts (SLA/SLL/SRA/SRL/RL K, Rd):  decoded.k5 (literal K)
  //   - Rs-form left/rotate shifts (SLA/SLL/RL Rs, Rd):  Rs[4:0] directly
  //   - Rs-form right shifts (SRA/SRL Rs, Rd):  2's complement of Rs[4:0]
  //     (per spec page 12-219; "use the 2s complement value of the
  //     5 LSBs in Rs"). The negation is done here in the amount mux.
  logic [SHIFT_AMOUNT_WIDTH-1:0] shifter_amount;
  always_comb begin
    unique case (decoded.iclass)
      INSTR_SLA_RR,
      INSTR_SLL_RR,
      INSTR_RL_RR:  shifter_amount = rf_rs1_data[SHIFT_AMOUNT_WIDTH-1:0];
      INSTR_SRA_RR,
      INSTR_SRL_RR: shifter_amount = (~rf_rs1_data[SHIFT_AMOUNT_WIDTH-1:0])
                                     + {{(SHIFT_AMOUNT_WIDTH-1){1'b0}}, 1'b1};
      // K-form right shifts ALSO store the count two's-complemented (the
      // assembler encodes 32-count; MAME SRA/SRL: k = (-(K)) & 0x1f, shared by
      // the K and Rs forms). E.g. `SRL 4,A8` assembles K=28; shifting by the
      // raw field (28) instead of 4 corrupted the game's error-screen pointer
      // alignment (found via the attract-sim wander at instr 56.8M).
      INSTR_SRA_K,
      INSTR_SRL_K:  shifter_amount = (~decoded.k5)
                                     + {{(SHIFT_AMOUNT_WIDTH-1){1'b0}}, 1'b1};
      default:      shifter_amount = decoded.k5;
    endcase
  end

  tms34010_shifter u_shifter (
    .op    (decoded.shift_op),
    .a     (rf_rs2_data),
    .amount(shifter_amount),
    .result(shifter_result),
    .flags (shifter_flags)
  );

  // Flag-input mux: status register samples either ALU flags or shifter
  // flags depending on the source of the result.
  // Flag-input mux: SET/CLR-C inject a constant C value (paired with
  // the wb_flag_mask = c-only in their decoder arms); other
  // flag-affecting instructions get their flags from the ALU or shifter
  // per `decoded.use_shifter`.
  alu_flags_t  flag_input;
  always_comb begin
    if (fill_win_flag_wb) begin
      // FILL W=2 window result: only V is written (mask below is V-only).
      flag_input = '{n: 1'b0, c: 1'b0, z: 1'b0, v: fill_win_violation};
    end else
    unique case (decoded.iclass)
      INSTR_SETC:   flag_input = '{n: 1'b0, c: 1'b1, z: 1'b0, v: 1'b0};
      INSTR_CLRC:   flag_input = '{n: 1'b0, c: 1'b0, z: 1'b0, v: 1'b0};
      INSTR_LMO_RR: flag_input = '{n: 1'b0, c: 1'b0,
                                    z: (rf_rs1_data == '0), v: 1'b0};
      INSTR_SEXT:   flag_input = '{n: sext_result_q[DATA_WIDTH-1], c: 1'b0,
                                    z: (sext_result_q == '0), v: 1'b0};
      INSTR_ZEXT:   flag_input = '{n: 1'b0, c: 1'b0,
                                    z: (zext_result_q == '0), v: 1'b0};
      // MMTM (SPVU001A page 12-111): N = sign of (0 - original Rp) with
      // exceptions Rp=0 -> 1 and Rp=0x80000000 -> 0; the closed form is
      // N = ~Rp[31]. rf_rs2_data still reads the ORIGINAL Rp during
      // WRITEBACK (the final-Rp write is in flight on the same edge, and
      // the regfile read returns the pre-write value). C/Z/V are masked
      // off (Unaffected) via wb_flag_mask, so only the N field matters.
      INSTR_MMTM:   flag_input = '{n: ~rf_rs2_data[DATA_WIDTH-1],
                                    c: 1'b0, z: 1'b0, v: 1'b0};
      // MOVE load (indirect / offset / absolute): implicit compare-to-0 of
      // the loaded field AFTER FE sign/zero extension (mv_load_data). N =
      // result sign, Z = result==0, V=0; C masked off by wb_flag_mask. For a
      // PIXT load (force_pixel) the only defined status bit is V = (pixel !=
      // 0); the PIXT-load decode masks N/C/Z off (they are spec-Undefined).
      INSTR_MOVE_FIELD_LOAD,
      INSTR_MOVE_ABS_LOAD,
      INSTR_MOVE_OFF_LOAD:  flag_input = '{n: mv_load_data[DATA_WIDTH-1],
                                    c: 1'b0, z: (mv_load_data == '0),
                                    v: (decoded.force_pixel && (mv_load_data != '0))};
      INSTR_ADDXY:  flag_input = addxy_flags_q;
      INSTR_SUBXY:  flag_input = subxy_flags_q;
      INSTR_CMPXY:  flag_input = cmpxy_flags_q;
      INSTR_CPW:    flag_input = cpw_flags_q;
      // MPYS: N/Z from the 64-bit product. MPYU: Z only (N masked off).
      INSTR_MPYS,
      INSTR_MPYU:   flag_input = '{n: mpy_product_q[63], c: 1'b0,
                                    z: (mpy_product_q == 64'd0), v: 1'b0};
      // Divide family (DIVU/DIVS/MODU/MODS): V = overflow; Z = (result==0);
      // N = result sign (signed variants only — masked off for unsigned by
      // wb_flag_mask). The result is the quotient (DIV) or remainder (MOD),
      // already sign-conditioned. On overflow N/Z read 0; for the MOD ops
      // the Z mask is cleared on overflow (effective_flag_mask) so Z stays
      // Unaffected when Rs=0.
      INSTR_DIVU,
      INSTR_DIVS,
      INSTR_MODU,
      INSTR_MODS:   flag_input = '{n: (is_signed_div && !div_v && div_result_main[DATA_WIDTH-1]),
                                    c: 1'b0,
                                    z: (!div_v && (div_result_main == '0)),
                                    v: div_v};
      default:      flag_input = decoded.use_shifter ? shifter_flags_q : alu_flags_q;
    endcase
  end

  // Effective per-flag update mask. Normally the decoded mask, but MODU
  // (and the future MODS) leave Z "Unaffected" when Rs=0 (overflow), which
  // is a runtime condition the static decode mask can't express.
  alu_flags_t effective_flag_mask;
  always_comb begin
    effective_flag_mask = decoded.wb_flag_mask;
    if (is_div_mod && div_v) effective_flag_mask.z = 1'b0;  // MODU/MODS: Z unaffected on Rs=0
    if (fill_win_flag_wb)
      effective_flag_mask = '{n: 1'b0, c: 1'b0, z: 1'b0, v: 1'b1};  // FILL W=2: V only
  end

  tms34010_status_reg u_status_reg (
    .clk             (clk),
    .rst             (rst),
    .flag_update_en  (st_flag_update_en),
    .flags_in        (flag_input),
    .flag_update_mask(effective_flag_mask),
    .st_write_en     (st_write_en),
    .st_write_data   (st_write_data),
    .st_o            (st_value),
    .n_o             (st_n),
    .c_o             (st_c),
    .z_o             (st_z),
    .v_o             (st_v)
  );

  // ---------------------------------------------------------------------------
  // Next-state + combinational outputs
  //
  // Safe defaults at the top — none of the output muxes can infer a latch.
  // ---------------------------------------------------------------------------
  always_comb begin
    // Defaults.
    state_d       = state_q;
    mem_req       = 1'b0;
    mem_we_int        = 1'b0;
    mem_addr      = '0;
    mem_size      = '0;
    mem_wdata     = '0;
    pc_advance_en = 1'b0;

    unique case (state_q)
      CORE_RESET: begin
        // smashtv: the TMS34010 boots by fetching a 32-bit PC from the reset
        // vector at bit address 0xFFFFFFE0 (SPVU001A Ch.13; upstream deferred
        // this as A0008). Gated by RESET_VECTOR_FETCH so upstream tests, which
        // expect PC=RESET_PC and a program at word 0, keep their contract.
        state_d = RESET_VECTOR_FETCH ? CORE_RVEC : CORE_FETCH;
      end

      CORE_RVEC: begin
        // smashtv: fetch the 32-bit reset vector at TRAP_VECTOR_BASE
        // (0xFFFFFFE0). Latched into popped_pc_q on ack (see the popped_pc_q
        // register block). This case item carries both the mem drive and the
        // next-state, matching the CORE_INT_VECTOR idiom in this combined block.
        mem_req    = 1'b1;
        mem_we_int = 1'b0;
        mem_addr   = TRAP_VECTOR_BASE;
        mem_size   = MEM_SIZE_32;
        if (mem_ack) state_d = CORE_RVEC_DONE;
      end

      CORE_RVEC_DONE: begin
        // One cycle to load PC <- vector (pc_load in the PC-load block), then
        // begin normal execution.
        state_d = CORE_FETCH;
      end

      CORE_FETCH: begin
        // HALT (HSTCTLH.HLT, or ext_halt for NARC's menu/save pause) freezes the
        // CPU at the instruction boundary: issue no fetch and take no interrupts,
        // holding pc_value, until released. Checked before int_take so a halted
        // CPU cannot take interrupts (MAME semantics). Smash TV never sets the
        // HLT bit, but NARC actively drives ext_halt for pause -- so this must
        // not fire mid-fetch. Same hazard int_divert_ok already guards against
        // for interrupts: only freeze at a CLEAN boundary (!ic_busy, no cache
        // fill running) and with no bypass fetch already latched by the memsys
        // (!fetch_inflight_q, P0013). Halting mid-fill instead would drop
        // mem_req for the still-incomplete fill's remaining words while the
        // icache's own ic_state/fill_word keep believing one is owed, which
        // upstream pause_ack logic misreads as a quiescent bus boundary and can
        // hand the shared SDRAM to another client mid-fill.
        if (cpu_halted && !ic_busy && !fetch_inflight_q) begin
          state_d = CORE_FETCH;
        end else
        // Recognise a pending interrupt at the instruction boundary. NMI
        // (non-maskable) takes priority over a maskable request (ST.IE=1 and an
        // enabled INTPEND bit). When taken, do NOT fetch — pc_value stays at the
        // resume address. An NMI with NMIM=1 saves no context and jumps
        // straight to the vector; everything else pushes PC+ST first. Only divert
        // at a clean boundary — no cache fill running (!ic_busy) so a fill in
        // progress is not lost, and no bypass fetch already latched by the memsys
        // (!fetch_inflight_q, P0013) so its ack cannot be misattributed to the
        // interrupt's PC push. Both are folded into int_divert_ok.
        if (int_divert_ok) begin
          state_d = (nmi_req && nmi_nmim) ? CORE_INT_VECTOR : CORE_INT_PUSH_PC;
        end else begin
          // Fetch through the instruction cache. On a hit ic_mem_req is 0 (no
          // bus cycle) and ic_fetch_done is immediate; on a miss the icache
          // drives the bus (ic_mem_req/ic_mem_addr) to fill a subsegment.
          mem_req    = ic_mem_req;
          mem_we_int = 1'b0;
          mem_addr   = ic_mem_addr;
          mem_size   = INSTR_WORD_BITS;
          if (ic_fetch_done) begin
            state_d       = CORE_DECODE;
            pc_advance_en = 1'b1;       // advance PC by INSTR_WORD_BITS
          end
        end
      end

      CORE_INT_PUSH_PC: begin
        // Push the resume PC to mem[SP-32] (32-bit). SP is not updated until
        // CORE_INT_DONE; the second push uses SP-64. Order matches RETI's pop
        // (ST at the lower address, PC at the higher) and the TRAP push.
        mem_req   = 1'b1;
        mem_we_int = 1'b1;
        mem_addr  = rf_sp - WORD_BIT_SIZE;
        mem_size  = MEM_SIZE_32;
        mem_wdata = pc_value;
        if (mem_ack) state_d = CORE_INT_PUSH_ST;
      end

      CORE_INT_PUSH_ST: begin
        // Push ST to mem[SP-64] (32-bit).
        mem_req   = 1'b1;
        mem_we_int = 1'b1;
        mem_addr  = rf_sp - WORD_BIT_SIZE_2;
        mem_size  = MEM_SIZE_32;
        mem_wdata = st_value;
        if (mem_ack) state_d = CORE_INT_VECTOR;
      end

      CORE_INT_VECTOR: begin
        // Read the 32-bit trap vector (the ISR entry address) at the latched
        // vector address; latch it into popped_pc_q for the PC load below.
        mem_req   = 1'b1;
        mem_we_int = 1'b0;
        mem_addr  = int_vec_q;
        mem_size  = MEM_SIZE_32;
        if (mem_ack) state_d = CORE_INT_DONE;
      end

      CORE_INT_DONE: begin
        // One cycle to retire the entry: SP <- SP-64 (regfile), PC <- vector,
        // ST <- ST_RESET_VALUE (IE=0, FS0=16, FS1=0; MAME RESET_ST). Then fetch.
        state_d = CORE_FETCH;
      end

      CORE_DECODE: begin
        // Branch based on how many immediate words the decoded
        // instruction needs.
        if (decoded.needs_imm32) begin
          state_d = CORE_FETCH_IMM_LO;
        end else if (decoded.needs_imm16) begin
          state_d = CORE_FETCH_IMM_LO;
        end else begin
          state_d = CORE_EXECUTE;
        end
      end

      CORE_FETCH_IMM_LO: begin
        // Fetch the 16-bit low-immediate word from PC. Same protocol as
        // CORE_FETCH; PC advances by INSTR_WORD_BITS on ack.
        mem_req  = 1'b1;
        mem_we_int   = 1'b0;
        mem_addr = pc_value;
        mem_size = INSTR_WORD_BITS;
        if (mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = decoded.needs_imm32 ? CORE_FETCH_IMM_HI : CORE_EXECUTE;
        end
      end

      CORE_FETCH_IMM_HI: begin
        mem_req  = 1'b1;
        mem_we_int   = 1'b0;
        mem_addr = pc_value;
        mem_size = INSTR_WORD_BITS;
        if (mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = (decoded.iclass == INSTR_MOVE_ABS_M2M)
                  ? CORE_FETCH_ABS2_LO : CORE_EXECUTE;
        end
      end

      CORE_FETCH_ABS2_LO: begin
        mem_req  = 1'b1;
        mem_we_int = 1'b0;
        mem_addr = pc_value;
        mem_size = INSTR_WORD_BITS;
        if (mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = CORE_FETCH_ABS2_HI;
        end
      end

      CORE_FETCH_ABS2_HI: begin
        mem_req  = 1'b1;
        mem_we_int = 1'b0;
        mem_addr = pc_value;
        mem_size = INSTR_WORD_BITS;
        if (mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = CORE_EXECUTE;
        end
      end

      CORE_EXECUTE: begin
        // ALU output and flags are combinational from decoded.alu_op,
        // alu_a, alu_b, and st_c. CORE_EXECUTE lets that result settle
        // for one cycle. For instructions that need a memory
        // transaction (PUSHST and the rest of the stack/CALL family),
        // route through CORE_MEMORY first; otherwise go straight to
        // CORE_WRITEBACK.
        // Divide instructions hand off to the multi-cycle divider; others
        // go to memory (if any) then writeback.
        if (is_div)
          state_d = CORE_DIVIDE;
        else if (is_fill)
          state_d = CORE_FILL_SETUP;   // FILL: latched DADDR/DPTCH/DYDX here
        else if (is_pblt)
          state_d = CORE_PBLT_SETUP;   // PIXBLT: latched SADDR/DADDR/DYDX here
        else if (is_drav)
          // DRAV: latched Rd/Rs/linear here. A windowed DRAV (W!=0) first reads
          // WSTART/WEND to test Rd's pixel; W=0 goes straight to the draw.
          state_d = (io_control[CTRL_W_HI:CTRL_W_LO] != 2'd0) ? CORE_DRAV_SETUP_WIN
                                                              : CORE_DRAV;
        else if (is_line)
          state_d = CORE_LINE_SETUP1;  // LINE: read the implied B operands
        else if (pixt_xy_win)
          state_d = CORE_PIXT_SETUP_WIN; // windowed XY PIXT: read WSTART/WEND
        else if (is_mm && (imm_lo_q == 16'd0))
          // Empty MMTM/MMFM list: skip CORE_MEMORY (would otherwise push/pop R0).
          state_d = CORE_WRITEBACK;
        else
          state_d = decoded.needs_memory_op ? CORE_MEMORY : CORE_WRITEBACK;
      end

      CORE_DIVIDE: begin
        // Hold while the divider runs; proceed to writeback when it signals
        // done (results, incl. the overflow flag, are then stable).
        state_d = div_done ? CORE_WRITEBACK : CORE_DIVIDE;
      end

      CORE_FILL_SETUP: begin
        // One cycle to latch COLOR1 (and the counters were seeded at EXECUTE).
        // FILL XY with a window (W=2 or W=3) takes one more cycle to read
        // WSTART/WEND.
        //
        // Same MAME early-bail as PIXBLT (34010gfx.hxx fill(): "if (dx <= 0 ||
        // dy <= 0) return;") -- skip the whole instruction, no writeback. See
        // the CORE_PBLT_SETUP comment for the full underflow explanation.
        if ($signed(fill_dx_q) <= 0 || $signed(fill_dy_q) <= 0)
          state_d = CORE_FETCH;
        else
          state_d = (fill_win_en_q || fill_w2_q || fill_w1_q) ? CORE_FILL_SETUP_WIN
                                                              : CORE_FILL;
      end

      CORE_FILL_SETUP_WIN: begin
        // Latch WSTART(B5)/WEND(B6). W=3 proceeds to the (per-pixel-clipped)
        // fill. W=2 (miss detection) checks array containment now: draw only if
        // the whole array is inside, else skip to CORE_FILL_WIN_MISS (no draw).
        // W=1 (hit detection) never draws — go straight to CORE_FILL_WIN_HIT.
        state_d = fill_w1_q                          ? CORE_FILL_WIN_HIT
                : (fill_w2_q && !fill_array_inside)  ? CORE_FILL_WIN_MISS
                                                     : CORE_FILL;
      end

      CORE_FILL_WIN_MISS: begin
        // W=2 window miss: no pixels drawn; V=1 and WVP set (combinationally),
        // then fetch the next instruction.
        state_d = CORE_FETCH;
      end

      CORE_FILL_WIN_HIT: begin
        // W=1 hit detection: no pixels drawn. V and WVP are driven
        // combinationally from fill_array_hit (overlap), then fetch.
        state_d = CORE_FETCH;
      end

      CORE_DRAV_SETUP_WIN: begin
        // One cycle to read WSTART(B5)/WEND(B6) and test Rd's pixel. If the
        // pixel is drawn (W=2/3 inside) go to the RMW; otherwise skip straight
        // to CORE_WRITEBACK, which still advances Rd and writes V/WVP.
        state_d = (((drav_w_q == 2'd2) || (drav_w_q == 2'd3)) && drav_in_window)
                ? CORE_DRAV : CORE_WRITEBACK;
      end

      CORE_PIXT_SETUP_WIN: begin
        // One cycle to read WSTART(B5)/WEND(B6); then the normal PIXT-store RMW
        // runs in CORE_MEMORY (the window inhibits the write per pixel).
        state_d = CORE_MEMORY;
      end

      CORE_DRAV: begin
        // Single-pixel RMW at Rd's linear address: read the destination pixel
        // (sub-step 0), then write the merged COLOR1 (sub-step 1). On the write
        // ack proceed to CORE_WRITEBACK, which advances Rd by Rs.
        mem_req  = 1'b1;
        mem_addr = drav_linear_q;
        mem_size = io_psize[FIELD_SIZE_WIDTH-1:0];
        if (!drav_substep_q) begin
          mem_we_int = 1'b0;            // read the destination pixel
        end else begin
          mem_we_int = 1'b1;           // write the merged pixel
          mem_wdata  = drav_merged;
        end
        if (mem_ack && drav_substep_q)
          state_d = CORE_WRITEBACK;
        else
          state_d = CORE_DRAV;
      end

      CORE_LINE_SETUP1: state_d = CORE_LINE_SETUP2;
      CORE_LINE_SETUP2: state_d = CORE_LINE_SETUP3;
      CORE_LINE_SETUP3:
        // A windowed (W=3) LINE reads WSTART/WEND first. If COUNT is 0 there is
        // nothing to draw; go straight to writeback.
        state_d = (line_count_q == '0) ? CORE_LINE_WB_D
                : line_win_en           ? CORE_LINE_SETUP_WIN : CORE_LINE_DRAW;
      CORE_LINE_SETUP_WIN: state_d = CORE_LINE_DRAW;

      CORE_LINE_DRAW: begin
        // Per-pixel RMW at DADDR's linear address: read dest (sub-step 0), write
        // the merged COLOR1 (sub-step 1). On the write ack of the last pixel
        // (COUNT about to reach 0) go to writeback; else draw the next pixel.
        mem_req  = 1'b1;
        mem_addr = line_linear;
        mem_size = io_psize[FIELD_SIZE_WIDTH-1:0];
        if (!line_substep_q) begin
          mem_we_int = 1'b0;            // read the destination pixel
        end else begin
          mem_we_int = 1'b1;           // write the merged pixel
          mem_wdata  = line_merged;
        end
        // Stop on the last pixel OR a W=1/W=2 window-violation abort.
        if (mem_ack && line_substep_q && ((line_count_q == 32'd1) || line_abort))
          state_d = CORE_LINE_WB_D;
        else
          state_d = CORE_LINE_DRAW;
      end

      CORE_LINE_WB_D:     state_d = CORE_LINE_WB_DADDR; // write d  -> B0
      CORE_LINE_WB_DADDR: state_d = CORE_LINE_WB_COUNT; // write DADDR -> B2
      CORE_LINE_WB_COUNT: state_d = CORE_FETCH;         // write COUNT -> B10, then fetch

      CORE_FILL: begin
        // Per pixel, read the destination (sub-step 0) then write the merged
        // value (sub-step 1): merged = PPOP(COLOR1, dest) plane-masked and
        // transparency-checked. The memory model RMW handles sub-word /
        // straddling pixels. Stay until the array's last write completes.
        mem_req   = 1'b1;
        mem_addr  = fill_addr_q;
        mem_size  = io_psize[FIELD_SIZE_WIDTH-1:0];
        if (!fill_substep_q) begin
          mem_we_int = 1'b0;            // read the destination pixel
        end else begin
          mem_we_int = 1'b1;            // write the processed pixel
          mem_wdata  = fill_merged;
        end
        if (mem_ack && fill_substep_q && fill_done)
          state_d = CORE_FILL_WB;
        else
          state_d = CORE_FILL;
      end

      CORE_FILL_WB: begin
        // Write the final DADDR back to B2, then fetch the next instruction.
        state_d = CORE_FETCH;
      end

      CORE_PBLT_SETUP: begin
        // One cycle to latch SPTCH/DPTCH (counters seeded at EXECUTE). The
        // binary form reads COLOR0/COLOR1 in a second setup cycle; a windowed
        // (W=3) XY blt reads WSTART/WEND in CORE_PBLT_SETUP_WIN.
        //
        // MAME bails the WHOLE instruction -- no memory access, no SADDR/DADDR
        // writeback -- when either dimension is <= 0, treating DYDX as SIGNED
        // 16-bit (34010gfx.hxx pixblt(): "dx=(int16_t)DYDX_X(); dy=(int16_t)
        // DYDX_Y(); ... if (dx <= 0 || dy <= 0) return;"). Our per-pixel end
        // tests (x==dx-1, y==dy-1) UNDERFLOW to 0xFFFF when dx/dy==0, turning a
        // no-op into a 65536-iteration loop (confirmed: this hung Smash TV's
        // boot indefinitely). wb_reg_en=0 for PIXBLT (decode.sv), so skipping
        // straight to CORE_FETCH here correctly touches no registers, matching
        // MAME's early return before any writes occur.
        if ($signed(pblt_dx_q) <= 0 || $signed(pblt_dy_q) <= 0)
          state_d = CORE_FETCH;
        else
          state_d = decoded.blt_binary                          ? CORE_PBLT_SETUP2
                  : (pblt_win_en_q || pblt_w2_q || pblt_w1_q)   ? CORE_PBLT_SETUP_WIN
                                                                : CORE_PBLT;
      end

      CORE_PBLT_SETUP2: begin
        // Latch COLOR0/COLOR1 for the color-expand source.
        state_d = (pblt_win_en_q || pblt_w2_q || pblt_w1_q) ? CORE_PBLT_SETUP_WIN
                                                            : CORE_PBLT;
      end

      CORE_PBLT_SETUP_WIN: begin
        // Latch WSTART(B5)/WEND(B6). W=3 proceeds to the per-pixel-clipped blt;
        // W=2 (miss detection) checks array containment now — draw only if the
        // whole array is inside, else skip to CORE_PBLT_WIN_MISS (no draw).
        // W=1 (hit detection) never draws — go straight to CORE_PBLT_WIN_HIT.
        state_d = pblt_w1_q                         ? CORE_PBLT_WIN_HIT
                : (pblt_w2_q && !pblt_array_inside) ? CORE_PBLT_WIN_MISS
                                                    : CORE_PBLT;
      end

      CORE_PBLT_WIN_MISS: begin
        // W=2 window miss: no pixels drawn; V=1 and WVP set, then fetch.
        state_d = CORE_FETCH;
      end

      CORE_PBLT_WIN_HIT: begin
        // W=1 hit detection: no pixels drawn; V/WVP from pblt_array_hit, fetch.
        state_d = CORE_FETCH;
      end

      CORE_PBLT: begin
        // Per pixel: read source (sub-step 0), read destination (1), write the
        // processed pixel (2). Stay until the array's last write completes.
        // The binary source is read 1 bit at a time; otherwise PSIZE bits.
        mem_req   = 1'b1;
        mem_size  = io_psize[FIELD_SIZE_WIDTH-1:0];
        unique case (pblt_substep_q)
          2'd0: begin
            mem_we_int = 1'b0;             // read source pixel (1 bit if binary)
            mem_addr   = pblt_src_addr_q;
            if (decoded.blt_binary) mem_size = 6'd1;  // width == FIELD_SIZE_WIDTH
          end
          2'd1: begin
            mem_we_int = 1'b0;             // read destination pixel
            mem_addr   = pblt_dst_addr_q;
          end
          default: begin
            mem_we_int = 1'b1;             // write the processed pixel
            mem_addr   = pblt_dst_addr_q;
            mem_wdata  = pblt_merged;
          end
        endcase
        if (mem_ack && pblt_substep_q == 2'd2 && pblt_done)
          state_d = CORE_PBLT_WB;
        else
          state_d = CORE_PBLT;
      end

      CORE_PBLT_WB: begin
        // Write the final SADDR back to B0.
        state_d = CORE_PBLT_WB2;
      end

      CORE_PBLT_WB2: begin
        // Write the final DADDR back to B2, then fetch the next instruction.
        state_d = CORE_FETCH;
      end

      CORE_MEMORY: begin
        // Memory transaction state for instructions that set
        // decoded.needs_memory_op. The IF signals (mem_req, mem_we_int,
        // mem_addr, mem_size, mem_wdata) are driven per iclass.
        unique case (decoded.iclass)
          INSTR_PUSHST: begin
            // Write ST to mem[new SP] as a 32-bit transfer.
            mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = alu_result;        // = SP - 32
            mem_size  = MEM_SIZE_32;
            mem_wdata = st_value;          // ST
          end
          INSTR_POPST: begin
            // Read 32-bit ST from mem[OLD SP]. The increment-by-32
            // happens via the ALU; we don't want alu_result here,
            // we want the pre-increment SP value. POPST has
            // rd_idx=15 (SP) on rs2 — so rs2 gives OLD SP.
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = rf_rs2_data;       // = current SP
            mem_size  = MEM_SIZE_32;
          end
          INSTR_CALL_RS,
          INSTR_CALLA,
          INSTR_CALLR: begin
            // Push PC' to mem[new SP]. new SP = alu_result = SP - 32.
            // pc_value at this point is PC' — the address of the
            // first instruction AFTER the CALL's full encoding:
            //   CALL Rs:  PC + 16 bits  (single-word opcode)
            //   CALLR:    PC + 32 bits  (opcode + 16-bit disp)
            //   CALLA:    PC + 48 bits  (opcode + 16-bit LO + 16-bit HI)
            // All three increments have already happened by the time
            // we enter CORE_MEMORY (via the FETCH / FETCH_IMM_LO /
            // FETCH_IMM_HI advances).
            mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = alu_result;        // = SP - 32
            mem_size  = MEM_SIZE_32;
            mem_wdata = pc_value;          // PC' (return address)
          end
          INSTR_RETS: begin
            // Pop PC from mem[OLD SP]. mem_addr = current SP value
            // (rf_rs2_data) — NOT alu_result, which is SP + 32 + 16*N.
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = rf_rs2_data;       // = current SP
            mem_size  = MEM_SIZE_32;
          end
          INSTR_RETI: begin
            // Two-step pop: step 0 reads ST from mem[SP]; step 1 reads
            // PC from mem[SP+32]. Both 32-bit reads. The latched
            // popped_st_q / popped_pc_q values flow to the WRITEBACK
            // ST-write and PC-load paths below.
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_size  = MEM_SIZE_32;
            mem_addr  = (mem_op_step == 2'd0)
                      ? rf_rs2_data                  // = SP
                      : (rf_rs2_data + WORD_BIT_SIZE);      // = SP + 32
          end
          INSTR_TRAP: begin
            // Three-step sequence for N>0 — see SPVU001A page 12-252:
            //   step 0: write PC' at SP-32       (push return address)
            //   step 1: write ST  at SP-64       (push status reg)
            //   step 2: read trap vector @ V_N   (= 0xFFFFFFE0 - N*32)
            // SP itself is updated via alu_result (= SP - 64) at
            // WRITEBACK; ST is replaced with 0x00000010; PC is loaded
            // from popped_pc_q (latched on step 2).
            //
            // For TRAP 0 (`trap_skip_push`): collapse to a single step
            // that is the vector fetch — no pushes (per spec note 1
            // page 12-253). SP stays unchanged (alu_b=0 above).
            mem_req   = 1'b1;
            mem_size  = MEM_SIZE_32;
            if (trap_skip_push) begin
              mem_we_int    = 1'b0;
              mem_addr  = TRAP_VECTOR_BASE;        // N=0 ⇒ vector @ 0xFFFFFFE0
            end else begin
              unique case (mem_op_step)
                2'd0: begin
                  mem_we_int    = 1'b1;
                  mem_addr  = rf_rs2_data - WORD_BIT_SIZE;
                  mem_wdata = pc_value;             // PC'
                end
                2'd1: begin
                  mem_we_int    = 1'b1;
                  mem_addr  = rf_rs2_data - WORD_BIT_SIZE_2;
                  mem_wdata = st_value;             // ST as it stood
                end
                default: begin                       // step 2
                  mem_we_int    = 1'b0;
                  // Trap-vector address = TRAP_VECTOR_BASE - N*32.
                  // N is decoded.k5 (5 bits); N*32 = N << 5.
                  mem_addr  = TRAP_VECTOR_BASE
                            - ({{(ADDR_WIDTH-5){1'b0}}, decoded.k5} << 5);
                end
              endcase
            end
          end
          INSTR_MMTM: begin
            // Push the register currently selected by mm_iter_idx to
            // mem[mm_rp_q]. Each iteration of CORE_MEMORY is one 32-bit
            // write; mm_mask_q and mm_rp_q advance on the ack. We stay
            // in CORE_MEMORY until the mask is empty.
            // MAME: Rp -= 32; WLONG(Rp, REG(i)). When i==Rd, REG(i) is the
            // already-decremented pointer — write mm_rp_q, not the pre-update
            // rf_rs1_data.
            mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = mm_rp_q;
            mem_size  = MEM_SIZE_32;
            mem_wdata = (mm_iter_idx == decoded.rd_idx) ? mm_rp_q : rf_rs1_data;
          end
          INSTR_MMFM: begin
            // Pop: read 32 bits from mem[mm_rp_q] into the register
            // selected by mm_iter_idx (highest-order first). The regfile
            // write happens via the mmfm_pop_wr path; here we just drive
            // the read. mm_mask_q clears the bit and mm_rp_q advances
            // (+32) on the ack. Stay in CORE_MEMORY until mask empty.
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = mm_rp_q;
            mem_size  = MEM_SIZE_32;
          end
          INSTR_MOVE_FIELD_STORE: begin
            // MOVE Rs,*Rd[+|-]: write the low FS bits of Rs (rf_rs1_data) to
            // mem[mv_addr]. mv_addr = pointer Rd (postinc/none) or Rd-FS
            // (predec); the pointer auto-update (Rd±FS) is written back at
            // WRITEBACK for the inc/dec forms. FS from the F-selected ST pair.
            // A PIXT store (pixt_rmw) is a 2-step plane-mask read-modify-write:
            // step 0 reads the destination pixel, step 1 writes the merged
            // value. A regular MOVE store (and PMASK=0 PIXT) is a single write.
            mem_req   = 1'b1;
            mem_addr  = mv_addr;           // = Rd or Rd-FS (predec)
            mem_size  = mv_fs;             // field size (1..32)
            if (pixt_rmw && mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;           // step 0: read the destination pixel
            end else begin
              mem_we_int = 1'b1;           // write (single, or step 1 of RMW)
              mem_wdata  = pixt_rmw ? pixt_merged : rf_rs1_data;
            end
          end
          INSTR_MOVE_FIELD_LOAD: begin
            // MOVE [-]*Rs[+],Rd: read an FS-bit field from mem[mv_addr].
            // mv_addr = pointer Rs (postinc/none) or Rs-FS (predec). The
            // field-extended data (mv_load_data) goes to Rd at WRITEBACK;
            // for inc/dec the updated pointer Rs±FS is written via the
            // mv_load_ptr_wr path on this ack.
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = mv_addr;           // = Rs or Rs-FS (predec)
            mem_size  = mv_fs;             // field size (1..32)
          end
          INSTR_MOVE_OFF_STORE: begin
            // MOVE Rs,*Rd(off): write the low FS bits of Rs (rf_rs1_data) to
            // mem[Rd + off]. imm32 = sign-extended 16-bit offset; Rd =
            // rf_rs2_data. Field-size aware (Task 0078); no pointer step.
            mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = rf_rs2_data + imm32;
            mem_size  = mv_fs;             // field size (1..32)
            mem_wdata = rf_rs1_data;       // = Rs (low FS bits used)
          end
          INSTR_MOVE_OFF_LOAD: begin
            // MOVE *Rs(off),Rd: read an FS-bit field at mem[Rs + off];
            // field-extended result -> Rd at WRITEBACK. Rs = rf_rs1_data
            // (pointer); imm32 = sext(off16). Field-size aware (Task 0078).
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = rf_rs1_data + imm32;
            mem_size  = mv_fs;             // field size (1..32)
          end
          INSTR_MOVE_ABS_STORE: begin
            // MOVE Rs,@DAddr: write the low FS bits of Rs (rf_rs1_data) to the
            // absolute bit address imm32 = {imm_hi_q, imm_lo_q}. Field-size
            // aware (Task 0078).
            mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = imm32;
            mem_size  = mv_fs;             // field size (1..32)
            mem_wdata = rf_rs1_data;       // = Rs (low FS bits used)
          end
          INSTR_MOVE_ABS_LOAD: begin
            // MOVE @SAddr,Rd: read an FS-bit field from the absolute address
            // imm32; the field-extended result goes to Rd at WRITEBACK
            // (rf_wr_data mux), flags from the extended value. Task 0078.
            mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = imm32;
            mem_size  = mv_fs;             // field size (1..32)
          end
          INSTR_MOVE_ABS_M2M: begin
            // MOVE @SAddr,@DAddr,F: two-step absolute field copy. imm32 is
            // the first (source) long parameter; abs2 is the second (dest).
            mem_req  = 1'b1;
            mem_size = mv_fs;
            if (mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;
              mem_addr = imm32;
            end else begin
              mem_we_int = 1'b1;
              mem_addr = abs2;
              mem_wdata = move_data_q;
            end
          end
          INSTR_MOVE_OFF_M2M: begin
            // MOVE *Rs(SOff),*Rd(DOff): two signed 16-bit BIT offsets follow
            // the opcode in source/destination order (imm_lo_q/imm_hi_q).
            mem_req  = 1'b1;
            mem_size = mv_fs;
            if (mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;
              mem_addr = rf_rs1_data +
                         {{(DATA_WIDTH-16){imm_lo_q[15]}}, imm_lo_q};
            end else begin
              mem_we_int = 1'b1;
              mem_addr = rf_rs2_data +
                         {{(DATA_WIDTH-16){imm_hi_q[15]}}, imm_hi_q};
              mem_wdata = move_data_q;
            end
          end
          INSTR_MOVE_OFF_NI: begin
            // MOVE *Rs(SOff),*Rd+: read FS bits at Rs+sext(off16), write to
            // *Rd, then Rd += FS at WRITEBACK. Source pointer unchanged.
            mem_req  = 1'b1;
            mem_size = mv_fs;
            if (mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;
              mem_addr = rf_rs1_data + imm32;
            end else begin
              mem_we_int = 1'b1;
              mem_addr = rf_rs2_data;
              mem_wdata = move_data_q;
            end
          end
          INSTR_MOVE_ABS_NI: begin
            // MOVE @SAddr,*Rd+: read FS bits at absolute imm32, write to *Rd,
            // then Rd += FS at WRITEBACK. Flags Unaffected (MAME move*_a_ni).
            mem_req  = 1'b1;
            mem_size = mv_fs;
            if (mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;
              mem_addr = imm32;
            end else begin
              mem_we_int = 1'b1;
              mem_addr = rf_rs2_data;
              mem_wdata = move_data_q;
            end
          end
          INSTR_MOVE_FIELD_M2M: begin
            // Two-step indirect-to-indirect: read *Rs, then write *Rd.
            mem_req   = 1'b1;
            mem_size  = mv_fs;
            if (mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;
              mem_addr = m2m_src_addr;
            end else begin
              mem_we_int = 1'b1;
              mem_addr = m2m_dst_addr;
              mem_wdata = move_data_q;
            end
          end
          default: ;  // no transaction (shouldn't reach with needs_memory_op=0)
        endcase
        if (mem_ack) begin
          // Multi-step instructions stay in CORE_MEMORY until their
          // final step's ack; everything else transitions on every ack.
          unique case (decoded.iclass)
            INSTR_RETI: if (mem_op_step == 2'd1) state_d = CORE_WRITEBACK;
            INSTR_TRAP: if (trap_skip_push || mem_op_step == 2'd2)
                          state_d = CORE_WRITEBACK;
            INSTR_MMTM,
            INSTR_MMFM: if (mm_mask_will_be_empty) state_d = CORE_WRITEBACK;
            INSTR_MOVE_FIELD_M2M,
            INSTR_MOVE_ABS_M2M,
            INSTR_MOVE_OFF_M2M,
            INSTR_MOVE_OFF_NI,
            INSTR_MOVE_ABS_NI: if (mem_op_step == 2'd1) state_d = CORE_WRITEBACK;
            // PIXT store RMW stays for its write step; single-step store exits.
            INSTR_MOVE_FIELD_STORE:
                        if (!pixt_rmw || mem_op_step == 2'd1) state_d = CORE_WRITEBACK;
            default:    state_d = CORE_WRITEBACK;
          endcase
        end
      end

      CORE_WRITEBACK: begin
        // An even-Rd multiply/divide needs a second writeback cycle to
        // store the low half (product LSBs / divide remainder) into Rd+1.
        state_d = pair_second_pass ? CORE_WRITEBACK : CORE_FETCH;
      end

      default: begin
        // Defensive: any out-of-range encoding goes back to reset.
        state_d = CORE_RESET;
      end
    endcase
  end

  assign state_o          = state_q;
  assign pc_o             = pc_value;
  assign instr_pc_o       = instr_pc_q;
  assign instr_word_o     = instr_word_q;
  assign illegal_opcode_o = illegal_q;

endmodule : tms34010_core
`default_nettype wire
