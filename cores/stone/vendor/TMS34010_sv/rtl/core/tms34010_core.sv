// -----------------------------------------------------------------------------
// tms34010_core.sv
//
// Top-level multicycle TMS34010 CPU/graphics core, current through Task 0158.
//
// The core integrates instruction fetch/decode/execute, the A/B/SP register
// file, PC/ST, ALU/shifter/divider, field-aware memory sequencing, on-chip I/O
// register routing, trap/interrupt entry, and the implemented PIXT/FILL/
// PIXBLT/DRAV/LINE graphics engines. Unsupported opcodes raise the sticky
// `illegal_opcode_o` output.
//
// The external request/ack interface is an architectural bit-addressed
// interface, not the original physical 16-bit bus. REFCNT requests and the
// dedicated-VCLK internal video timing/screen scheduler are
// integrated. The synchronous four-register host engine, HINT, and HLT
// behavior are also integrated; the enclosing system/pin wrappers provide
// host/local arbitration and the original physical bus phases.
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
(
  input  logic                                clk,
  input  logic                                vclk_i,
  input  logic                                rst,
  input  logic                                vclk_rst_i,
  input  logic                                video_hsync_n_i,
  input  logic                                video_vsync_n_i,

  // Architectural bit-addressed memory request/ack interface.
  output logic                                mem_req,
  output logic                                mem_we,
  output logic [ADDR_WIDTH-1:0]               mem_addr,
  output logic [FIELD_SIZE_WIDTH-1:0]         mem_size,
  output logic [DATA_WIDTH-1:0]               mem_wdata,
  output logic                                mem_iaq,
  output logic                                mem_srt,
  output logic                                mem_is_io,
  output logic                                mem_io_we,
  output local_word_t                         mem_io_rdata,
  input  logic                                mem_io_grant,
  output logic                                mem_io_ready,
  input  logic [DATA_WIDTH-1:0]               mem_rdata,
  input  logic                                mem_ack,
  // CPU-owned physical I/O words from a field crossing the register window.
  input  logic                                mem_word_io_req,
  input  logic                                mem_word_io_we,
  input  logic [ADDR_WIDTH-1:0]               mem_word_io_addr,
  input  local_word_t                         mem_word_io_wdata,
  input  logic                                mem_word_io_ack,

  // Emulation boundary. RUN/EMU is high for RUN and low for EMU; EMUA is
  // active low. The physical HLDA/EMUA phase multiplexing belongs in the
  // future pin/bus wrapper.
  input  logic                                run_emu_n_i,
  output logic                                emua_n_o,

  // Synchronous four-register host boundary. The future pin-level wrapper
  // supplies bus timing/CDC and drives these request/ack transactions.
  input  logic                                hcs_n_i,
  input  logic                                host_req_i,
  input  logic                                host_we_i,
  input  host_reg_sel_t                       host_reg_i,
  input  logic [1:0]                          host_be_i,
  input  local_word_t                         host_wdata_i,
  output local_word_t                         host_rdata_o,
  output logic                                host_ack_o,
  output logic                                host_busy_o,
  output logic                                hint_n_o,

  // Held host-indirect local-word client for the future memory arbiter.
  output logic                                host_mem_req_o,
  output logic                                host_mem_we_o,
  output logic [ADDR_WIDTH-1:0]               host_mem_addr_o,
  output local_word_t                         host_mem_wdata_o,
  output logic                                host_mem_is_io_o,
  output local_word_t                         host_mem_io_rdata_o,
  input  local_word_t                         host_mem_rdata_i,
  input  logic                                host_mem_ack_i,

  // Interrupt-source boundary. LINT pins are raw asynchronous active-low
  // levels and are synchronized internally. The display set input remains a
  // core-clock pulse from its future integration wrapper.
  input  logic                                lint1_n_i,
  input  logic                                lint2_n_i,
  input  logic                                dpyint_set_i,

  // Refresh-client boundary. The request is a one-core-clock underflow event;
  // the row and mode remain stable for that cycle. The future memory fabric
  // arbitrates and emits the physical refresh cycle.
  output logic                                refresh_req_o,
  output logic [7:0]                          refresh_row_o,
  output logic                                refresh_cbr_o,

  // Functional video-timing boundary. These active-high interval signals are
  // generated in vclk_i; explicit CDC inside the I/O block returns live
  // register snapshots, DIP, and screen transactions to clk.
  output logic                                video_hsync_o,
  output logic                                video_vsync_o,
  output logic                                video_hblank_o,
  output logic                                video_vblank_o,
  output logic                                video_blank_o,
  output logic                                video_hsync_oe_o,
  output logic                                video_vsync_oe_o,

  // Screen-refresh client boundary. Request and payload remain stable until
  // the future memory/VRAM controller acknowledges the completed transfer.
  output logic                                screen_refresh_req_o,
  input  logic                                screen_refresh_ack_i,
  output logic [13:0]                         screen_refresh_srfaddr_o,
  output logic [15:0]                         screen_refresh_dpytap_o,
  output logic                                screen_refresh_org_o,

  // Observability for testbenches (Phase 0..3 — may move to an
  // sva/observability bundle later).
  output core_state_t                         state_o,
  output logic [ADDR_WIDTH-1:0]               pc_o,
  output instr_word_t                         instr_word_o,
  output logic                                illegal_opcode_o
);

  // ---------------------------------------------------------------------------
  // Pixel-processing operation (PPOP) — shared by the PIXT store engine and
  // the graphics fill/blt engines. Returns f(src, dest) per the CONTROL.PPOP
  // code (SPVU001A): 16 Boolean ops (bitwise) + 6 arithmetic ops (on the
  // unsigned PSIZE-bit pixels masked by `fmask`; ADDS/SUBS saturate). The low
  // `fmask` bits of the result are what the caller writes.
  // ---------------------------------------------------------------------------
  function automatic logic [DATA_WIDTH-1:0] ppop_apply(
      input logic [DATA_WIDTH-1:0] src,
      input logic [DATA_WIDTH-1:0] dest,
      input logic [4:0]            ppop,
      input logic [DATA_WIDTH-1:0] fmask);
    logic [DATA_WIDTH-1:0] sp, dp, addsum;
    sp     = src  & fmask;
    dp     = dest & fmask;
    addsum = dp + sp;
    unique case (ppop)
      5'h00:   ppop_apply = src;               // S (replace)
      5'h01:   ppop_apply = src &  dest;       // S AND D
      5'h02:   ppop_apply = src & ~dest;       // S AND ~D
      5'h03:   ppop_apply = '0;                // 0
      5'h04:   ppop_apply = src | ~dest;       // S OR ~D
      5'h05:   ppop_apply = ~(src ^ dest);     // S XNOR D
      5'h06:   ppop_apply = ~dest;             // ~D
      5'h07:   ppop_apply = ~(src | dest);     // S NOR D
      5'h08:   ppop_apply = src |  dest;       // S OR D
      5'h09:   ppop_apply = dest;              // D (no change)
      5'h0A:   ppop_apply = src ^  dest;       // S XOR D
      5'h0B:   ppop_apply = ~src & dest;       // ~S AND D
      5'h0C:   ppop_apply = '1;                // 1
      5'h0D:   ppop_apply = ~src | dest;       // ~S OR D
      5'h0E:   ppop_apply = ~(src & dest);     // S NAND D
      5'h0F:   ppop_apply = ~src;              // ~S
      5'h10:   ppop_apply = addsum;            // D + S (wrap)
      5'h11:   ppop_apply = (addsum > fmask) ? fmask : addsum;       // ADDS (sat all-1s)
      5'h12:   ppop_apply = dp - sp;           // D - S (wrap)
      5'h13:   ppop_apply = (dp >= sp) ? (dp - sp) : '0;             // SUBS (sat 0)
      5'h14:   ppop_apply = (dp >= sp) ? dp : sp;                    // MAX(D,S)
      5'h15:   ppop_apply = (dp <= sp) ? dp : sp;                    // MIN(D,S)
      default: ppop_apply = src;               // 0x16-0x1F reserved -> replace
    endcase
  endfunction

  // The graphics engines are mutually exclusive at instruction granularity.
  // Route their operands through one PPOP datapath instead of synthesizing a
  // complete Boolean/arithmetic processor for every engine.
  logic [DATA_WIDTH-1:0] pixel_ppop_src;
  logic [DATA_WIDTH-1:0] pixel_ppop_fmask;
  logic [DATA_WIDTH-1:0] pixel_ppop_raw_dest;
  logic [DATA_WIDTH-1:0] pixel_ppop_pmask;
  logic [DATA_WIDTH-1:0] pixel_ppop_src_q;
  logic [DATA_WIDTH-1:0] pixel_ppop_raw_dest_q;
  logic [DATA_WIDTH-1:0] pixel_ppop_pmask_q;
  logic [DATA_WIDTH-1:0] pixel_ppop_fmask_q;
  logic [DATA_WIDTH-1:0] pixel_ppop_result_q;
  logic [DATA_WIDTH-1:0] pixel_ppop_merged_q;
  logic                  pixel_ppop_inhibit_q;
  logic                  pixel_ppop_transp_en_q;
  logic [DATA_WIDTH-1:0] pixel_ppop_result_stage;
  logic [DATA_WIDTH-1:0] pixel_ppop_merged_stage;
  logic                  pixel_ppop_transp_stage;
  logic [DATA_WIDTH-1:0] pixel_size_mask_q;
  logic [15:0]           pixel_plane_mask_q;
  logic [4:0]            pixel_ppop_code_q;
  logic                  pixel_transp_en_q;
  logic                  pixel_ppop_inhibit;

  // COLOR0/COLOR1 contain four/sixteen/etc. independently selectable pixel
  // fields in their low 16 bits. The production guide requires the selected
  // source field to correspond to the destination pixel's position in its
  // 16-bit word, enabling non-replicated dithering patterns.
  function automatic logic [DATA_WIDTH-1:0] aligned_color(
      input logic [DATA_WIDTH-1:0] color,
      input logic [ADDR_WIDTH-1:0] destination_address,
      input logic [DATA_WIDTH-1:0] mask);
    aligned_color = (color >> destination_address[3:0]) & mask;
  endfunction

  // PMASK bits correspond to physical bit positions in each 16-bit memory
  // word. Pixel fields are right-justified inside the core, so select the
  // mask field at the actual source/destination address before processing.
  function automatic logic [DATA_WIDTH-1:0] aligned_pmask(
      input logic [15:0] plane_mask,
      input logic [ADDR_WIDTH-1:0] pixel_address,
      input logic [DATA_WIDTH-1:0] mask);
    aligned_pmask =
        ({{(DATA_WIDTH-16){1'b0}}, plane_mask} >> pixel_address[3:0])
        & mask;
  endfunction

  // ---------------------------------------------------------------------------
  // Program counter
  // ---------------------------------------------------------------------------
  logic                  pc_advance_en;
  logic                  pc_load_en;
  logic [ADDR_WIDTH-1:0] pc_load_value;
  logic [ADDR_WIDTH-1:0] pc_value;

  tms34010_pc u_pc (
    .clk            (clk),
    .rst            (rst),
    .load_en        (pc_load_en),
    .load_value     (pc_load_value),
    .advance_en     (pc_advance_en),
    .advance_amount (PC_ADVANCE_WIDTH'(INSTR_WORD_BITS)),
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
  // fetch. The decoder runs combinationally for two settle cycles; consumers
  // see its registered result from CORE_DISPATCH onward.
  // ---------------------------------------------------------------------------
  // Quartus 17 needs the intentionally multi-cycle decoder boundary to remain
  // visible after optimization so the matching SDC exception stays narrow.
  (* preserve *) instr_word_t instr_word_q;
  decoded_instr_t            decoded_comb;
  (* preserve *) decoded_instr_t decoded;
  logic                       is_mmtm_decode_q;
  // Registered class flags, captured with `decoded`. They replace the wide
  // iclass equality trees that fed the pixel-op, register-file and I/O cones.
  logic is_fill_q, fill_is_xy_q, is_pblt_q, is_drav_q, is_line_q, is_mv_store_q, is_mv_load_q;
  // Predecode the pixel-store conjunctions before the future-state/RF mux.
  logic pixt_store_decode_q, pixt_xy_store_decode_q;
  // Separate copies of the instruction class for the memory-request cone
  // (mem_req_int/addr/wdata/next-state in CORE_MEMORY) and the pixel/M2M cone, so
  // the class register does not fan out to every consumer at once.
  (* preserve, dont_merge *) instr_class_t iclass_mem_q;
  (* preserve, dont_merge *) instr_class_t iclass_pix_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      instr_word_q <= '0;
    end else if (state_q == CORE_FETCH && mem_ack_eff) begin
      instr_word_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
    end
  end

  tms34010_decode u_decode (
    .instr  (instr_word_q),
    .decoded(decoded_comb)
  );

  // The exhaustive decoder is deliberately given two complete core clocks.
  // The opcode is stable throughout CORE_DECODE and CORE_DECODE_WAIT, then
  // the packed result is captured once and used from CORE_DISPATCH until the
  // next acknowledged opcode fetch. Besides making the timing contract
  // explicit, this prevents decoder equality trees from being replicated
  // deep into every execute/writeback cone.
  always_ff @(posedge clk) begin
    if (rst) begin
      decoded <= '0;
      is_mmtm_decode_q <= 1'b0;
      iclass_mem_q <= INSTR_ILLEGAL; iclass_pix_q <= INSTR_ILLEGAL;
      // iclass 0 (INSTR_ILLEGAL, the reset value of `decoded`) is none of these classes.
      is_fill_q <= 1'b0; fill_is_xy_q <= 1'b0; is_pblt_q <= 1'b0; is_drav_q <= 1'b0;
      is_line_q <= 1'b0; is_mv_store_q <= 1'b0; is_mv_load_q <= 1'b0;
      pixt_store_decode_q <= 1'b0; pixt_xy_store_decode_q <= 1'b0;
    end else if (state_q == CORE_DECODE_WAIT) begin
      decoded <= decoded_comb;
      iclass_mem_q <= decoded_comb.iclass; iclass_pix_q <= decoded_comb.iclass;
      is_mmtm_decode_q <= (decoded_comb.iclass == INSTR_MMTM);
      is_fill_q     <= (decoded_comb.iclass == INSTR_FILL_L) || (decoded_comb.iclass == INSTR_FILL_XY);
      fill_is_xy_q  <= (decoded_comb.iclass == INSTR_FILL_XY);
      is_pblt_q     <= (decoded_comb.iclass == INSTR_PIXBLT_LL);
      is_drav_q     <= (decoded_comb.iclass == INSTR_DRAV);
      is_line_q     <= (decoded_comb.iclass == INSTR_LINE);
      is_mv_store_q <= (decoded_comb.iclass == INSTR_MOVE_FIELD_STORE);
      pixt_store_decode_q <= decoded_comb.force_pixel
                            && (decoded_comb.iclass == INSTR_MOVE_FIELD_STORE);
      pixt_xy_store_decode_q <= decoded_comb.force_pixel && decoded_comb.xy_addr
                               && (decoded_comb.iclass == INSTR_MOVE_FIELD_STORE);
      is_mv_load_q  <= (decoded_comb.iclass == INSTR_MOVE_FIELD_LOAD);
    end
  end

  // Sticky illegal-opcode diagnostic latch. Set when CORE_DECODE encounters
  // an unrecognized encoding and cleared only by reset. The §8.7-reserved
  // subset also enters the architectural trap-30 sequence below.
  logic illegal_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      illegal_q <= 1'b0;
    end else if (state_q == CORE_DISPATCH && decoded.illegal) begin
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
  logic signed [INSTR_WORD_WIDTH-1:0] disp_signed_short;
  // {disp8, 4'h0} = disp * 16. Explicitly extend its bit 11 sign through
  // the 16-bit intermediate before the address-width cast below.
  assign disp_signed_short = $signed({{4{instr_word_q[7]}},
                                      instr_word_q[7:0], 4'h0});
  assign branch_target_short = pc_value + ADDR_WIDTH'(disp_signed_short);

  // Immediate latches — declared up here (before their first use in
  // the branch_target_long / branch_target_jacc combinational
  // computations below) because Questa is strict about forward
  // references in `assign` statements, even though Verilator hoists
  // them. The matching `always_ff` that actually latches imm_lo_q /
  // imm_hi_q on memory acks lives further down (search for
  // CORE_FETCH_IMM_LO / CORE_FETCH_IMM_HI).
  instr_word_t imm_lo_q;
  instr_word_t imm_hi_q;
  instr_word_t imm_ext_lo_q;
  instr_word_t imm_ext_hi_q;

  // Long-form JRcc target: PC_after_both_fetches + sign_extend(disp16) × 16.
  // By the time the FSM hits CORE_WRITEBACK, pc_value already equals
  // (PC_original + 32 bits) — the opcode FETCH and the IMM_LO FETCH each
  // advanced the PC by 16. `imm_lo_q` holds the 16-bit displacement word.
  // {disp16, 4'h0} is a 20-bit value; sign bit at [19] equals imm_lo_q[15].
  logic [ADDR_WIDTH-1:0]   branch_target_long;
  logic signed [19:0]      disp_signed_20;
  assign disp_signed_20   = $signed({imm_lo_q, 4'h0});
  assign branch_target_long = pc_value + ADDR_WIDTH'(disp_signed_20);

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
  logic signed [9:0]     dsjs_disp_magnitude;
  // Build positive bit-offset = {1'b0, offset5, 4'h0} (signed 10-bit
  // value in [0, +496]), then negate when D=1.
  assign dsjs_disp_magnitude =
      $signed({1'b0, instr_word_q[9:5], 4'h0});
  assign dsjs_disp_bits = instr_word_q[10]
                        ? -dsjs_disp_magnitude
                        :  dsjs_disp_magnitude;
  assign branch_target_dsjs = pc_value + ADDR_WIDTH'(dsjs_disp_bits);

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
  logic [2:0]            mem_op_step;
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
  // Captured with `decoded` (same enable) instead of decoded from it: the class
  // compare sat at the head of the memory-address cone (timing closure).
  logic trap_skip_push;
  always_ff @(posedge clk) begin
    if (rst) trap_skip_push <= 1'b0;
    else if (state_q == CORE_DECODE_WAIT)
      trap_skip_push <= (decoded_comb.iclass == INSTR_TRAP) && (decoded_comb.k5 == 5'd0);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_op_step <= 3'd0;
      popped_st_q <= '0;
      popped_pc_q <= '0;
      move_data_q <= '0;
      pix_dest_q  <= '0;
    end else if (state_q == CORE_MEMORY && mem_ack_eff) begin
      // MOVE *Rs,*Rd: step 0 reads the source field; latch it so step 1
      // can write it to the destination.
      if (((decoded.iclass == INSTR_MOVE_FIELD_M2M)
        || (decoded.iclass == INSTR_MOVE_OFF_M2M_PI)
        || (decoded.iclass == INSTR_MOVE_ABS_M2M_PI)
        || (decoded.iclass == INSTR_MOVB_OFF_M2M)
        || (decoded.iclass == INSTR_MOVB_ABS_M2M)
        || (decoded.iclass == INSTR_MOVE_OFF_M2M)
        || (decoded.iclass == INSTR_MOVE_ABS_M2M))
       && mem_op_step == 3'd0) begin
        move_data_q <= mem_rdata_eff;
      end
      // A processing PIXT memory-to-memory transfer reads the raw destination
      // after its source. Keep the unmasked value for protected-plane merge;
      // PPOP sees the separately masked destination operand.
      if (pixt_m2m_rmw && mem_op_step == 3'd1)
        pix_dest_q <= mem_rdata_eff;
      // A processing/window PIXT store reads the destination at step 0; latch
      // it so step 1 can merge the result.
      if (decoded.iclass == INSTR_MOVE_FIELD_STORE && pixt_rmw && mem_op_step == 3'd0) begin
        pix_dest_q <= mem_rdata_eff;
      end
      // Latch popped values per-iclass per-step before moving on.
      if (decoded.iclass == INSTR_RETI) begin
        if (mem_op_step == 3'd0) popped_st_q <= mem_rdata_eff;
        if (mem_op_step == 3'd1) popped_pc_q <= mem_rdata_eff;
      end
      // TRAP vector fetch:
      //   - N>0: step 2 (after the two pushes).
      //   - N=0: step 0 (the only step).
      if (decoded.iclass == INSTR_TRAP) begin
        if (trap_skip_push) begin
          if (mem_op_step == 3'd0) popped_pc_q <= mem_rdata_eff;
        end else begin
          if (mem_op_step == 3'd2) popped_pc_q <= mem_rdata_eff;
        end
      end
      // Step counter: advance unless this is the final step for the
      // iclass, in which case reset to 0 for the next instruction.
      unique case (decoded.iclass)
        INSTR_RETI: mem_op_step <= (mem_op_step == 3'd1) ? 3'd0 : mem_op_step + 3'd1;
        INSTR_TRAP: mem_op_step <= (trap_skip_push || mem_op_step == 3'd2)
                                 ? 3'd0
                                 : mem_op_step + 3'd1;
        INSTR_MOVE_FIELD_M2M,
        INSTR_MOVE_OFF_M2M_PI,
        INSTR_MOVE_ABS_M2M_PI,
        INSTR_MOVB_OFF_M2M,
        INSTR_MOVB_ABS_M2M,
        INSTR_MOVE_OFF_M2M,
        INSTR_MOVE_ABS_M2M:
                    mem_op_step <=
                        (mem_op_step
                         == (pixt_m2m_rmw ? 3'd4 : 3'd1))
                          ? 3'd0 : mem_op_step + 3'd1;
        // Processing/window PIXT store: read -> write -> 0. Direct PIXT and
        // regular MOVE stores are single-step. RMW processing cycles advance
        // separately below before their final write.
        INSTR_MOVE_FIELD_STORE:
                    mem_op_step <= (pixt_rmw && mem_op_step == 3'd0) ? 3'd1 : 3'd0;
        default:    mem_op_step <= 3'd0;
      endcase
    end else if ((state_q == CORE_MEMORY)
                 && ((pixt_rmw
                      && (decoded.iclass == INSTR_MOVE_FIELD_STORE)
                      && ((mem_op_step == 3'd1) || (mem_op_step == 3'd2)))
                     || (pixt_m2m_rmw
                         && ((mem_op_step == 3'd2)
                             || (mem_op_step == 3'd3))))) begin
      // The PPOP and merge steps have no external memory transaction.
      mem_op_step <= mem_op_step + 3'd1;
    end else if (state_q == CORE_INT_VECTOR && mem_ack_eff) begin
      // Interrupt entry: latch the fetched trap vector (ISR entry address) so
      // CORE_INT_DONE can load it into the PC.
      popped_pc_q <= mem_rdata_eff;
      mem_op_step <= 3'd0;
    end else if (state_q != CORE_MEMORY) begin
      // Defensive reset between instructions.
      mem_op_step <= 3'd0;
    end
  end

  // ---------------------------------------------------------------------------
  // FILL L engine (Task 0087)
  //
  // FILL fills a DY×DX pixel array (DYDX=B7) with COLOR1 (B9), starting at
  // DADDR (B2), rows DPTCH (B3) bits apart. Each pixel is a PSIZE-bit field
  // write. Operands are latched at EXECUTE (DADDR/DPTCH/DYDX, read on the 3
  // ports) and CORE_FILL_SETUP (COLOR1); the pixel loop runs in CORE_FILL,
  // one write per ack. FILL XY additionally implements all window modes;
  // PPOP, transparency, and PMASK share the normal pixel merge. DADDR is
  // updated to the address following the last pixel.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] fill_dptch_q, fill_color_q, fill_daddr_raw_q;
  logic [15:0]           fill_dx_q, fill_dy_q;
  logic [DATA_WIDTH-1:0] fill_addr_q, fill_row_base_q, fill_result_q;
  logic [15:0]           fill_x_q, fill_y_q;
  logic [DATA_WIDTH-1:0] fill_psize_ext;
  logic [DATA_WIDTH-1:0] fill_next_addr;
  logic                  fill_empty, fill_row_end, fill_done;
  logic                  fill_checkpoint_due;
  logic                  array_resume;
  // The destination is not read for the documented fast path: replace
  // processing, transparency disabled, and no protected planes. Field
  // insertion still performs any alignment-required word RMW in the memory
  // fabric. Other pixel modes need the destination value explicitly.
  logic                  pixel_dest_read_required;
  assign fill_psize_ext = DATA_WIDTH'(io_psize[FIELD_SIZE_WIDTH-1:0]);
  assign fill_empty     = (fill_dx_q == 16'd0) || (fill_dy_q == 16'd0)
                       || fill_dx_q[15] || fill_dy_q[15];
  assign fill_row_end   = !fill_empty && (fill_x_q == fill_dx_q - 16'd1);
  assign fill_done      = fill_row_end
                       && (fill_y_q == fill_dy_q - 16'd1);
  assign fill_next_addr = fill_addr_q + fill_psize_ext;
  // The architectural interrupt points are destination word/row boundaries.
  // A checkpoint is never inserted after the final pixel; the following
  // fetch boundary handles that as an ordinary completed instruction.
  assign fill_checkpoint_due = !fill_done
                             && (fill_row_end
                                 || (fill_next_addr[3:0] == 4'd0));
  assign pixel_dest_read_required =
      (io_control[CTRL_PPOP_HI:CTRL_PPOP_LO] != 5'd0)
      || io_control[CTRL_T_BIT]
      || (io_pmask != 16'h0000);

  // FILL XY: convert the XY DADDR (latched raw at EXECUTE) to a linear start
  // address at SETUP, where OFFSET (B4) is on read port 3. Same shift form as
  // CVXYL: (Y<<(31-CONVDP)) + (X<<log2 PSIZE) + OFFSET.
  // The working address is linear; architectural DADDR stays XY and advances
  // its Y component by the original DY, as in pinned MAME fill_xy.
  logic [4:0]            fill_xy_yshift;
  logic [DATA_WIDTH-1:0] fill_xy_base, fill_xy_base_q, fill_offset_q;
  logic [DATA_WIDTH-1:0] fill_xy_linear;
  assign fill_xy_yshift = 5'd31 - io_convdp[4:0];
  assign fill_xy_base =
      ({{16{fill_daddr_raw_q[DATA_WIDTH-1]}}, fill_daddr_raw_q[DATA_WIDTH-1:16]} << fill_xy_yshift)
      + ({{16{fill_daddr_raw_q[15]}}, fill_daddr_raw_q[15:0]} << pix_xy_xsh);
  assign fill_xy_linear = fill_xy_base_q + fill_offset_q;

  // FILL pixel processing (Task 0093). Modes that consume the old pixel use
  // step 0 to read it into fill_dest_q, then step 1 writes PPOP(COLOR1,dest)
  // with plane masking and transparency. The default replace/no-mask/no-T
  // path starts directly at step 1.
  logic [2:0]            fill_substep_q;   // read, PPOP, merge, write (or direct)
  logic                  fill_dest_read_q;
  logic [DATA_WIDTH-1:0] fill_dest_q;      // destination pixel latched at read
  logic [DATA_WIDTH-1:0] fill_pixel_mask, fill_pmask_field;
  // Window handling (FILL XY only). WSTART/WEND are inclusive XY corners.
  // W=3 replaces the working geometry with the intersection before the first
  // request; the per-pixel predicate remains as a defensive backstop. W=1/W=2
  // implement hit/miss detection and WV.
  logic [DATA_WIDTH-1:0] fill_wstart_q, fill_wend_q;
  logic                  fill_win_en_q;    // W=3 preclipping active for this FILL
  logic                  fill_w2_q;        // W=2 (miss detection) active for this FILL
  logic                  fill_preclip_changed_q, fill_w3_empty_q;
  logic [15:0]           fill_px, fill_py; // current pixel absolute XY
  logic                  fill_in_window, fill_clip_out;
  assign fill_px = fill_daddr_raw_q[15:0]            + fill_x_q;
  assign fill_py = fill_daddr_raw_q[DATA_WIDTH-1:16] + fill_y_q;
  assign fill_in_window =
        ($signed(fill_px) >= $signed(fill_wstart_q[15:0])) && ($signed(fill_px) <= $signed(fill_wend_q[15:0]))
     && ($signed(fill_py) >= $signed(fill_wstart_q[DATA_WIDTH-1:16])) && ($signed(fill_py) <= $signed(fill_wend_q[DATA_WIDTH-1:16]));
  assign fill_clip_out = fill_win_en_q && !fill_in_window;
  // W=2 (miss detection): the whole array is drawn only if it lies entirely
  // within the registered window. W=1/W=2 and W=3 share the geometry stage.
  logic                  fill_array_inside;
  logic                  fill_array_inside_q;
  logic signed [15:0]    fill_arr_x0, fill_arr_y0;
  logic signed [16:0]    fill_arr_x1, fill_arr_y1;
  logic [15:0]           fill_dx_extent_q, fill_dy_extent_q;
  logic signed [16:0]    fill_arr_x1_q, fill_arr_y1_q;
  assign fill_arr_x0 = fill_daddr_raw_q[15:0];
  assign fill_arr_y0 = fill_daddr_raw_q[DATA_WIDTH-1:16];
  assign fill_arr_x1 = fill_arr_x1_q;
  assign fill_arr_y1 = fill_arr_y1_q;
  assign fill_array_inside = !fill_empty
     && (fill_arr_x0 >= $signed(fill_wstart_q[15:0]))
     && (fill_arr_x1 <= $signed({fill_wend_q[15],fill_wend_q[15:0]}))
     && (fill_arr_y0 >= $signed(fill_wstart_q[DATA_WIDTH-1:16]))
     && (fill_arr_y1 <= $signed({fill_wend_q[31],fill_wend_q[31:16]}));
  // W=3 preclipping uses three short stages, matching PIXBLT: evaluate the
  // 16-bit intersection, form its shifted address offset, then apply it.
  logic                  fill_clip_hit;
  logic [15:0]           fill_clip_x0, fill_clip_y0;
  logic [15:0]           fill_clip_x1, fill_clip_y1;
  logic                  fill_clip_hit_q;
  logic [15:0]           fill_clip_x0_q, fill_clip_y0_q;
  logic [15:0]           fill_clip_x1_q, fill_clip_y1_q;
  logic [15:0]           fill_clip_dx_q, fill_clip_dy_q;
  logic [15:0]           fill_clip_left_q, fill_clip_top_q;
  logic [DATA_WIDTH-1:0] fill_clip_left_bits, fill_clip_top_bits;
  logic [DATA_WIDTH-1:0] fill_clip_offset, fill_clip_offset_q;
  logic [DATA_WIDTH-1:0] fill_clip_start, fill_original_result;
  assign fill_clip_hit = !fill_empty
      && ($signed(fill_wstart_q[15:0]) <= $signed(fill_wend_q[15:0]))
      && ($signed(fill_wstart_q[DATA_WIDTH-1:16])
          <= $signed(fill_wend_q[DATA_WIDTH-1:16]))
      && !(
        (fill_arr_x1 < $signed({fill_wstart_q[15],fill_wstart_q[15:0]})) || (fill_arr_x0 > $signed(fill_wend_q[15:0]))
     || (fill_arr_y1 < $signed({fill_wstart_q[31],fill_wstart_q[31:16]}))
     || (fill_arr_y0 > $signed(fill_wend_q[DATA_WIDTH-1:16])));
  assign fill_clip_x0 = (fill_arr_x0 > $signed(fill_wstart_q[15:0]))
                      ? fill_arr_x0 : fill_wstart_q[15:0];
  assign fill_clip_y0 = (fill_arr_y0 > $signed(fill_wstart_q[DATA_WIDTH-1:16]))
                      ? fill_arr_y0 : fill_wstart_q[DATA_WIDTH-1:16];
  assign fill_clip_x1 = (fill_arr_x1 < $signed({fill_wend_q[15],fill_wend_q[15:0]}))
                      ? fill_arr_x1[15:0] : fill_wend_q[15:0];
  assign fill_clip_y1 = (fill_arr_y1 < $signed({fill_wend_q[31],fill_wend_q[31:16]}))
                      ? fill_arr_y1[15:0] : fill_wend_q[DATA_WIDTH-1:16];
  assign fill_clip_left_bits = {{16{1'b0}}, fill_clip_left_q} << pix_xy_xsh;
  assign fill_clip_top_bits =
      {{16{1'b0}}, fill_clip_top_q} << (5'd31 - io_convdp[4:0]);
  assign fill_clip_offset = fill_clip_left_bits + fill_clip_top_bits;
  assign fill_clip_start = fill_addr_q + fill_clip_offset_q;
  assign fill_original_result = {fill_daddr_raw_q[31:16] + fill_dy_q,
                                 fill_daddr_raw_q[15:0]};
  // W=1 (hit detection/common rectangle): no pixels are drawn. The array
  // "hits" the window if it overlaps at all; computed from the LATCHED
  // WSTART/WEND (valid after CORE_FILL_SETUP_WIN). Inclusive corners. On a
  // hit FILL returns the lowest-address corner and intersection dimensions.
  logic fill_w1_q, fill_array_hit;
  logic [DATA_WIDTH-1:0] fill_common_daddr, fill_common_dydx;
  assign fill_array_hit = fill_clip_hit_q;
  assign fill_common_daddr = {fill_clip_y0_q, fill_clip_x0_q};
  assign fill_common_dydx = {fill_clip_dy_q, fill_clip_dx_q};
  // Window-violation flag write (sets V; detection paths may also pulse
  // wvp_set):
  //   CORE_FILL_WIN_MISS — array outside the window → V=1, request WVP.
  //   CORE_FILL_WB with W=2 (array was inside) → V=0, no interrupt.
  //   CORE_FILL_WB with W=3 → V=1 iff any preclipping was required.
  // Shared window-violation flag write for FILL and PIXBLT. The PIXBLT signals
  // are assigned later; module-item ordering does not affect these continuous
  // assignments. win_flag_wb enables the V write; win_violation is its value.
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
                            || ((state_q == CORE_FILL_WB) && fill_win_en_q
                                && fill_preclip_changed_q)
                            || ((state_q == CORE_PBLT_WB2) && pblt_win_en_q
                                && pblt_preclip_changed_q)
                            || (drav_win_wb && !drav_inside_q)
                            || (line_win_wb && !line_last_inside_q)
                            || (pixt_win_wb && !pixt_inside_q);
  assign fill_win_flag_wb   = (state_q == CORE_FILL_WIN_MISS)
                            || ((state_q == CORE_FILL_WB)
                                && (fill_w2_q || fill_win_en_q))
                            || (state_q == CORE_PBLT_WIN_MISS)
                            || ((state_q == CORE_PBLT_WB2)
                                && (pblt_w2_q || pblt_win_en_q))
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
                 || (pixt_win_wb && (((pixt_w_q == 2'd1) && pixt_inside_q)
                                  || ((pixt_w_q == 2'd2) && !pixt_inside_q)));
  // PSIZE is sampled once at instruction EXECUTE. Reuse the registered mask
  // throughout the multi-cycle pixel operation instead of putting its live
  // I/O-register path in front of every destination write.
  assign fill_pixel_mask  = pixel_size_mask_q;
  assign fill_pmask_field = aligned_pmask(pixel_plane_mask_q, fill_addr_q,
                                          fill_pixel_mask);

  always_ff @(posedge clk) begin
    if (rst) begin
      fill_dptch_q     <= '0;
      fill_color_q     <= '0;
      fill_daddr_raw_q <= '0;
      fill_dx_q        <= '0;
      fill_dy_q        <= '0;
      fill_addr_q      <= '0;
      fill_row_base_q  <= '0;
      fill_result_q    <= '0;
      fill_xy_base_q   <= '0;
      fill_offset_q    <= '0;
      fill_x_q         <= '0;
      fill_y_q         <= '0;
      fill_substep_q   <= 3'd0;
      fill_dest_read_q <= 1'b0;
      fill_dest_q      <= '0;
      fill_wstart_q    <= '0;
      fill_wend_q      <= '0;
      fill_array_inside_q <= 1'b0;
      fill_dx_extent_q <= '0;
      fill_dy_extent_q <= '0;
      fill_arr_x1_q    <= '0;
      fill_arr_y1_q    <= '0;
      fill_clip_hit_q  <= 1'b0;
      fill_clip_x0_q   <= '0;
      fill_clip_y0_q   <= '0;
      fill_clip_x1_q   <= '0;
      fill_clip_y1_q   <= '0;
      fill_clip_dx_q   <= '0;
      fill_clip_dy_q   <= '0;
      fill_clip_left_q <= '0;
      fill_clip_top_q  <= '0;
      fill_clip_offset_q <= '0;
      fill_win_en_q    <= 1'b0;
      fill_w2_q        <= 1'b0;
      fill_w1_q        <= 1'b0;
      fill_preclip_changed_q <= 1'b0;
      fill_w3_empty_q  <= 1'b0;
    end else begin
      // EXECUTE: latch DADDR(port1)/DPTCH(port2)/DYDX(port3) for FILL. The
      // start address (possibly XY-converted) is finalized at SETUP. Window
      // clipping engages only for FILL XY with CONTROL.W = 3.
      if (state_q == CORE_EXECUTE && is_fill) begin
        if (array_resume) begin
          // PBX re-entry reads {B0,B2,B10}; FILL ignores B0. B2 is the next
          // actual pixel and B10 the next effective traversal cursor.
          fill_addr_q     <= dispatch_rs2_q;
          fill_row_base_q <= dispatch_rs2_q
                           - ({{16{1'b0}}, dispatch_rs3_q[15:0]}
                              << pix_xy_xsh);
          fill_x_q        <= dispatch_rs3_q[15:0];
          fill_y_q        <= dispatch_rs3_q[DATA_WIDTH-1:16];
        end else begin
          fill_daddr_raw_q <= dispatch_rs1_q;       // DADDR (linear, or XY)
          fill_dptch_q     <= dispatch_rs2_q;       // DPTCH
          fill_dx_q        <= dispatch_rs3_q[15:0]; // DX
          fill_dy_q        <= dispatch_rs3_q[DATA_WIDTH-1:16]; // DY
          fill_x_q         <= 16'd0;
          fill_y_q         <= 16'd0;
        end
        fill_win_en_q    <= fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd3);
        fill_w2_q        <= !array_resume && fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2);
        fill_w1_q        <= !array_resume && fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1);
        fill_dest_read_q <= pixel_dest_read_required;
        fill_preclip_changed_q <= 1'b0;
        fill_w3_empty_q  <= 1'b0;
      end
      if (state_q == CORE_ARRAY_RESUME1 && is_fill) begin
        // {B1,B3,B11}: only DPTCH and the effective dimensions apply.
        fill_dptch_q <= rf_rs2_data;
        fill_dx_q    <= rf_rs3_data[15:0];
        fill_dy_q    <= rf_rs3_data[DATA_WIDTH-1:16];
      end
      if (state_q == CORE_ARRAY_RESUME2 && is_fill) begin
        // {B12,B13,B14}: B12 is the saved final-result base/context and
        // B14 is the effective raw XY destination used by W=3 checks.
        fill_result_q    <= rf_rs1_data;
        fill_daddr_raw_q <= rf_rs3_data;
      end
      if (state_q == CORE_ARRAY_RESUME3 && is_fill) begin
        // {B5,B6,B7}: reload the preserved window and recover whether W=3
        // changed the original dimensions, which determines final V.
        fill_wstart_q <= rf_rs1_data;
        fill_wend_q   <= rf_rs2_data;
        fill_preclip_changed_q <= fill_win_en_q
                               && (rf_rs3_data != {fill_dy_q, fill_dx_q});
      end
      if (state_q == CORE_ARRAY_RESUME4 && is_fill) begin
        // {B8,B9}: FILL consumes COLOR1 and resumes at a clean pixel boundary.
        fill_color_q   <= rf_rs2_data;
        fill_substep_q <= fill_dest_read_q ? 3'd0 : 3'd1;
      end
      // CORE_FILL_SETUP_WIN: latch WSTART(port1=B5)/WEND(port2=B6) for clip.
      if (state_q == CORE_FILL_SETUP_WIN) begin
        fill_wstart_q <= rf_rs1_data;
        fill_wend_q   <= rf_rs2_data;
        // The non-empty array was established in CORE_FILL_SETUP. Capture
        // inclusive endpoints now so window evaluation does not serialize
        // the dimension decrement and endpoint addition with clipping.
        fill_arr_x1_q <= {fill_arr_x0[15],fill_arr_x0} + {1'b0,fill_dx_extent_q};
        fill_arr_y1_q <= {fill_arr_y0[15],fill_arr_y0} + {1'b0,fill_dy_extent_q};
        if (fill_win_en_q) begin
          fill_result_q <= fill_original_result;
        end
      end
      if (state_q == CORE_FILL_WIN_EVAL) begin
        // First stage: compare the registered window and capture the four
        // selected inclusive corners. Size and offset subtraction follow in
        // CORE_FILL_WIN_SIZE.
        fill_array_inside_q <= fill_array_inside;
        fill_clip_hit_q     <= fill_clip_hit;
        fill_clip_x0_q      <= fill_clip_x0;
        fill_clip_y0_q      <= fill_clip_y0;
        fill_clip_x1_q      <= fill_clip_x1;
        fill_clip_y1_q      <= fill_clip_y1;
      end
      if (state_q == CORE_FILL_WIN_SIZE) begin
        fill_clip_dx_q <= fill_clip_hit_q
                        ? fill_clip_x1_q - fill_clip_x0_q + 16'd1 : 16'd0;
        fill_clip_dy_q <= fill_clip_hit_q
                        ? fill_clip_y1_q - fill_clip_y0_q + 16'd1 : 16'd0;
        fill_clip_left_q <= fill_clip_hit_q
                          ? fill_clip_x0_q - fill_arr_x0 : 16'd0;
        fill_clip_top_q <= fill_clip_hit_q
                         ? fill_clip_y0_q - fill_arr_y0 : 16'd0;
      end
      if (state_q == CORE_FILL_WIN_OFFSETS) begin
        // Second stage: shift the clipped X/Y offsets and combine them.
        fill_clip_offset_q <= fill_clip_offset;
      end
      if (state_q == CORE_FILL_WIN_APPLY && fill_win_en_q) begin
        // Final stage: publish the clipped working rectangle before the
        // first memory request. Architectural DADDR remains fill_result_q.
        fill_preclip_changed_q <= !fill_array_inside_q;
        fill_w3_empty_q        <= !fill_clip_hit_q;
        if (fill_clip_hit_q) begin
          fill_daddr_raw_q <= {fill_clip_y0_q, fill_clip_x0_q};
          fill_dx_q        <= fill_clip_dx_q;
          fill_dy_q        <= fill_clip_dy_q;
          fill_addr_q      <= fill_clip_start;
          fill_row_base_q  <= fill_clip_start;
        end
      end
      // CORE_FILL_SETUP: latch COLOR1 (port1) and the linear start address
      // (port3 = OFFSET for the XY conversion); start at the read sub-step.
      if (state_q == CORE_FILL_SETUP) begin
        fill_color_q    <= rf_rs1_data;        // COLOR1
        fill_dx_extent_q <= fill_dx_q - 16'd1;
        fill_dy_extent_q <= fill_dy_q - 16'd1;
        if (fill_is_xy) begin
          // Shift and combine the XY coordinate separately from the OFFSET
          // addition, which completes in CORE_FILL_XY_ADDR.
          fill_xy_base_q <= fill_xy_base;
          fill_offset_q  <= rf_rs3_data;
        end else begin
          fill_addr_q     <= fill_daddr_raw_q;
          fill_row_base_q <= fill_daddr_raw_q;
          fill_result_q   <= fill_daddr_raw_q;
        end
        fill_substep_q  <= fill_dest_read_q ? 3'd0 : 3'd1;
      end
      if (state_q == CORE_FILL_XY_ADDR) begin
        fill_addr_q     <= fill_xy_linear;
        fill_row_base_q <= fill_xy_linear;
        fill_result_q   <= fill_daddr_raw_q;
      end
      // CORE_FILL: direct replace writes start/stay at sub-step 1; all other
      // modes read at sub-step 0 before writing at sub-step 1.
      if (state_q == CORE_FILL && mem_ack_eff) begin
        if (fill_substep_q == 3'd0) begin
          // Read ack: latch the destination pixel for processing.
          fill_dest_q <= mem_rdata_eff;
          fill_substep_q <= 3'd1;
        end else if ((fill_substep_q == 3'd3) || !fill_dest_read_q) begin
          fill_substep_q <= fill_dest_read_q ? 3'd0 : 3'd1;
          // Write ack: advance to the next pixel (or to the final DADDR).
          fill_addr_q <= fill_addr_q + fill_psize_ext;
          if(fill_row_end && !fill_win_en_q) begin
            fill_result_q <= fill_is_xy
                ? {fill_result_q[31:16] + 16'd1,fill_result_q[15:0]}
                : fill_result_q + fill_dptch_q;
          end
          if (fill_row_end && !fill_done) begin
            // Row complete (not the last): jump to the next row's base.
            fill_y_q        <= fill_y_q + 16'd1;
            fill_row_base_q <= fill_row_base_q + fill_dptch_q;
            fill_addr_q     <= fill_row_base_q + fill_dptch_q;
            fill_x_q        <= 16'd0;
          end else if (!fill_done) begin
            fill_x_q <= fill_x_q + 16'd1;
          end
          // Working traversal can end just past the last pixel. Completion
          // uses the separate row result, including the last row's pitch.
        end
      end
      if ((state_q == CORE_FILL) && fill_dest_read_q && !mem_ack_eff) begin
        if (fill_substep_q == 3'd1)
          fill_substep_q <= 3'd2;
        else if (fill_substep_q == 3'd2)
          fill_substep_q <= 3'd3;
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
  // and CORE_PBLT_SETUP (SPTCH/DPTCH). Each pixel reads its source, optionally
  // reads its destination when processing requires it, then writes; both
  // pointers advance by PSIZE per pixel and row-step by their pitch.
  // SADDR/DADDR are updated to the first pixels of the hypothetical next rows
  // (CORE_PBLT_WB → B0, CORE_PBLT_WB2 → B2). Internal traversal and
  // architectural completion pointers are separate so PBH/PBV and W=3
  // preclipping do not perturb final context.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] pblt_sptch_q, pblt_dptch_q;
  logic [15:0]           pblt_dx_q, pblt_dy_q;
  logic [15:0]           pblt_dx_extent_q, pblt_dy_extent_q;
  logic [DATA_WIDTH-1:0] pblt_src_addr_q, pblt_dst_addr_q;
  logic [DATA_WIDTH-1:0] pblt_src_row_q, pblt_dst_row_q;
  logic [DATA_WIDTH-1:0] pblt_src_result_q, pblt_dst_result_q;
  logic [DATA_WIDTH-1:0] pblt_src_result_next_q, pblt_dst_result_next_q;
  logic                  pblt_row_result_commit_q;
  logic [15:0]           pblt_x_q, pblt_y_q;
  logic [2:0]            pblt_substep_q;     // source, dest, PPOP, merge, write
  logic                  pblt_dest_read_q;
  logic                  pblt_hrev_q, pblt_vrev_q, pblt_auto_corner_q;
  logic [DATA_WIDTH-1:0] pblt_src_pix_q, pblt_dst_pix_q;
  logic [DATA_WIDTH-1:0] pblt_psize_ext, pblt_pixel_mask;
  logic [DATA_WIDTH-1:0] pblt_src_pmask_field, pblt_pmask_field;
  logic                  pblt_empty, pblt_row_end, pblt_done;
  logic signed [16:0]    pblt_arr_x1_q, pblt_arr_y1_q;
  // PIXBLT B (color expand): COLOR0/COLOR1 latched at SETUP2; the source read is
  // 1 bit (mem_size 1, src step 1) and expands to COLOR1 / COLOR0.
  logic [DATA_WIDTH-1:0] pblt_color0_q, pblt_color1_q;
  logic [DATA_WIDTH-1:0] pblt_src_eff, pblt_src_step;
  assign pblt_psize_ext   = DATA_WIDTH'(io_psize[FIELD_SIZE_WIDTH-1:0]);
  assign pblt_pixel_mask  = pixel_size_mask_q;
  assign pblt_src_pmask_field = aligned_pmask(
      pixel_plane_mask_q, pblt_src_access_addr, pblt_pixel_mask);
  assign pblt_pmask_field = aligned_pmask(
      pixel_plane_mask_q, pblt_dst_access_addr, pblt_pixel_mask);
  assign pblt_empty       = (pblt_dx_q == 16'd0) || (pblt_dy_q == 16'd0)
                         || pblt_dx_q[15] || pblt_dy_q[15];
  assign pblt_row_end     = !pblt_empty
                          && (pblt_x_q == pblt_dx_q - 16'd1);
  assign pblt_done        = pblt_row_end
                          && (pblt_y_q == pblt_dy_q - 16'd1);
  // Effective source pixel: a binary source bit selects COLOR1/COLOR0.
  // The effective source is formed from the read data on the source-read
  // acknowledge and registered, so the address-alignment and plane-mask cone
  // never shares a cycle with the write-data and PPOP operand muxes.
  logic [DATA_WIDTH-1:0] pblt_src_eff_next, pblt_src_eff_q;
  assign pblt_src_eff_next = decoded.blt_binary
                          ? (aligned_color(
                               mem_rdata_eff[0]
                                 ? pblt_color1_q : pblt_color0_q,
                               pblt_dst_access_addr, pblt_pixel_mask)
                             & ~pblt_pmask_field)
                          : (mem_rdata_eff & ~pblt_src_pmask_field);
  assign pblt_src_eff     = pblt_src_eff_q;
  // Source advances 1 bit/pixel for the binary form, PSIZE bits otherwise.
  assign pblt_src_step    = decoded.blt_binary ? 32'd1 : pblt_psize_ext;
  // Window handling for PIXBLTs with an XY destination. W=3 preclips both
  // arrays before traffic; the raw/effective XY destination remains available
  // for W=1/W=2 geometry and as a defensive in-window check in the pixel loop.
  logic [DATA_WIDTH-1:0] pblt_dst_xy_raw_q, pblt_wstart_q, pblt_wend_q;
  logic                  pblt_win_en_q;    // W=3 array preclip active
  logic                  pblt_w2_q;        // W=2 (miss detection) active
  logic                  pblt_preclip_changed_q, pblt_w3_empty_q;
  logic [15:0]           pblt_px, pblt_py;
  logic [15:0]           pblt_col_index, pblt_row_index;
  logic                  pblt_in_window, pblt_clip_out;
  assign pblt_col_index = pblt_empty ? 16'd0
                         : pblt_hrev_q ? (pblt_dx_q - 16'd1 - pblt_x_q)
                                       : pblt_x_q;
  assign pblt_row_index = pblt_empty ? 16'd0
                         : pblt_vrev_q ? (pblt_dy_q - 16'd1 - pblt_y_q)
                                       : pblt_y_q;
  assign pblt_px = pblt_dst_xy_raw_q[15:0]            + pblt_col_index;
  assign pblt_py = pblt_dst_xy_raw_q[DATA_WIDTH-1:16] + pblt_row_index;
  assign pblt_in_window =
        ($signed(pblt_px) >= $signed(pblt_wstart_q[15:0])) && ($signed(pblt_px) <= $signed(pblt_wend_q[15:0]))
     && ($signed(pblt_py) >= $signed(pblt_wstart_q[DATA_WIDTH-1:16])) && ($signed(pblt_py) <= $signed(pblt_wend_q[DATA_WIDTH-1:16]));
  assign pblt_clip_out = pblt_win_en_q && !pblt_in_window;
  // The pixel coordinates are stable for at least two cycles (source read,
  // then destination read) before the PPOP stage-1 capture, so the window test
  // is registered once and consumed from the register.
  logic pblt_clip_out_q;
  always_ff @(posedge clk) pblt_clip_out_q <= pblt_clip_out;
  // W=2 (miss detection): array containment test on the destination corners,
  // evaluated from WSTART/WEND after CORE_PBLT_SETUP_WIN registers both
  // operands. This keeps register-file selection out of the geometry path.
  logic        pblt_array_inside;
  logic signed [15:0] pblt_arr_x0, pblt_arr_y0;
  logic signed [16:0] pblt_arr_x1, pblt_arr_y1;
  assign pblt_arr_x0 = pblt_dst_xy_raw_q[15:0];
  assign pblt_arr_y0 = pblt_dst_xy_raw_q[DATA_WIDTH-1:16];
  assign pblt_arr_x1 = pblt_arr_x1_q;
  assign pblt_arr_y1 = pblt_arr_y1_q;
  // Window states are reachable only after setup has rejected a zero-size
  // PIXBLT, so the empty-array mux is unnecessary in this geometry cone.
  assign pblt_array_inside = (pblt_arr_x0 >= $signed(pblt_wstart_q[15:0]))
     && (pblt_arr_x1 <= $signed({pblt_wend_q[15],pblt_wend_q[15:0]}))
     && (pblt_arr_y0 >= $signed(pblt_wstart_q[DATA_WIDTH-1:16]))
     && (pblt_arr_y1 <= $signed({pblt_wend_q[31],pblt_wend_q[31:16]}));
  // W=3 effective geometry is evaluated in CORE_PBLT_WIN_EVAL from the
  // registered window. Source and destination receive identical pixel
  // offsets, then the effective rectangle receives normal PBH/PBV corner
  // adjustment. Result pointers remain tied to the original array context.
  logic                  pblt_clip_hit;
  logic [15:0]           pblt_clip_x0, pblt_clip_y0;
  logic [15:0]           pblt_clip_x1, pblt_clip_y1;
  logic [15:0]           pblt_clip_dx, pblt_clip_dy;
  logic [15:0]           pblt_clip_left, pblt_clip_top;
  logic                  pblt_array_inside_q, pblt_clip_hit_q;
  logic [15:0]           pblt_clip_x0_q, pblt_clip_y0_q;
  logic [15:0]           pblt_clip_x1_q, pblt_clip_y1_q;
  logic [15:0]           pblt_clip_dx_q, pblt_clip_dy_q;
  logic [15:0]           pblt_clip_left_q, pblt_clip_top_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_left_bits, pblt_clip_dst_left_bits;
  logic [DATA_WIDTH-1:0] pblt_clip_src_top_bits, pblt_clip_dst_top_bits;
  logic [DATA_WIDTH-1:0] pblt_clip_src_default, pblt_clip_dst_default;
  logic [DATA_WIDTH-1:0] pblt_clip_src_h_adjust, pblt_clip_dst_h_adjust;
  logic [DATA_WIDTH-1:0] pblt_clip_src_v_adjust, pblt_clip_dst_v_adjust;
  logic [DATA_WIDTH-1:0] pblt_clip_src_default_q, pblt_clip_dst_default_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_h_adjust_q, pblt_clip_dst_h_adjust_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_v_adjust_q, pblt_clip_dst_v_adjust_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_corner, pblt_clip_dst_corner;
  logic [DATA_WIDTH-1:0] pblt_original_src_result, pblt_original_dst_result;
  assign pblt_clip_hit = ($signed(pblt_wstart_q[15:0]) <= $signed(pblt_wend_q[15:0]))
      && ($signed(pblt_wstart_q[DATA_WIDTH-1:16])
          <= $signed(pblt_wend_q[DATA_WIDTH-1:16]))
      && !(
        (pblt_arr_x1 < $signed({pblt_wstart_q[15],pblt_wstart_q[15:0]}))
     || (pblt_arr_x0 > $signed(pblt_wend_q[15:0]))
     || (pblt_arr_y1 < $signed({pblt_wstart_q[31],pblt_wstart_q[31:16]}))
     || (pblt_arr_y0 > $signed(pblt_wend_q[DATA_WIDTH-1:16])));
  assign pblt_clip_x0 = (pblt_arr_x0 > $signed(pblt_wstart_q[15:0]))
                      ? pblt_arr_x0 : pblt_wstart_q[15:0];
  assign pblt_clip_y0 = (pblt_arr_y0 > $signed(pblt_wstart_q[DATA_WIDTH-1:16]))
                      ? pblt_arr_y0 : pblt_wstart_q[DATA_WIDTH-1:16];
  assign pblt_clip_x1 = (pblt_arr_x1 < $signed({pblt_wend_q[15],pblt_wend_q[15:0]}))
                      ? pblt_arr_x1[15:0] : pblt_wend_q[15:0];
  assign pblt_clip_y1 = (pblt_arr_y1 < $signed({pblt_wend_q[31],pblt_wend_q[31:16]}))
                      ? pblt_arr_y1[15:0] : pblt_wend_q[DATA_WIDTH-1:16];
  assign pblt_clip_dx = pblt_clip_hit
                      ? pblt_clip_x1 - pblt_clip_x0 + 16'd1 : 16'd0;
  assign pblt_clip_dy = pblt_clip_hit
                      ? pblt_clip_y1 - pblt_clip_y0 + 16'd1 : 16'd0;
  assign pblt_clip_left = pblt_clip_hit
                        ? pblt_clip_x0 - pblt_arr_x0 : 16'd0;
  assign pblt_clip_top = pblt_clip_hit
                       ? pblt_clip_y0 - pblt_arr_y0 : 16'd0;
  assign pblt_clip_src_left_bits =
      {{16{1'b0}}, pblt_clip_left_q}
      << (decoded.blt_binary ? 5'd0 : pix_xy_xsh);
  assign pblt_clip_dst_left_bits =
      {{16{1'b0}}, pblt_clip_left_q} << pix_xy_xsh;
  assign pblt_clip_src_top_bits =
      {{16{1'b0}}, pblt_clip_top_q} << (5'd31 - io_convsp[4:0]);
  assign pblt_clip_dst_top_bits =
      {{16{1'b0}}, pblt_clip_top_q} << (5'd31 - io_convdp[4:0]);
  assign pblt_clip_src_default = pblt_src_base_q
                                + pblt_clip_src_left_bits
                                + pblt_clip_src_top_bits;
  assign pblt_clip_dst_default = pblt_dst_base_q
                                + pblt_clip_dst_left_bits
                                + pblt_clip_dst_top_bits;
  assign pblt_clip_src_h_adjust =
      {{16{1'b0}}, pblt_clip_dx_q}
      << (decoded.blt_binary ? 5'd0 : pix_xy_xsh);
  assign pblt_clip_dst_h_adjust =
      {{16{1'b0}}, pblt_clip_dx_q} << pix_xy_xsh;
  assign pblt_clip_src_v_adjust =
      {{16{1'b0}}, (pblt_clip_hit_q ? pblt_clip_dy_q - 16'd1 : 16'd0)}
      << (5'd31 - io_convsp[4:0]);
  assign pblt_clip_dst_v_adjust =
      {{16{1'b0}}, (pblt_clip_hit_q ? pblt_clip_dy_q - 16'd1 : 16'd0)}
      << (5'd31 - io_convdp[4:0]);
  assign pblt_clip_src_corner = pblt_clip_src_default_q
      + (pblt_hrev_q ? pblt_clip_src_h_adjust_q : 32'd0)
      + (pblt_vrev_q ? pblt_clip_src_v_adjust_q : 32'd0);
  assign pblt_clip_dst_corner = pblt_clip_dst_default_q
      + (pblt_hrev_q ? pblt_clip_dst_h_adjust_q : 32'd0)
      + (pblt_vrev_q ? pblt_clip_dst_v_adjust_q : 32'd0);
  assign pblt_original_src_result = decoded.blt_src_xy
      ? {pblt_src_result_q[31:16] + pblt_dy_q,pblt_src_result_q[15:0]}
      : pblt_src_result_q + pblt_original_src_l_delta_q;
  assign pblt_original_dst_result = {pblt_dst_result_q[31:16] + pblt_dy_q,
                                    pblt_dst_result_q[15:0]};
  // WIN_EVAL precedes WIN_OFFSETS and keeps the original dimensions intact.
  // Window clipping must preserve the original completion context. A linear
  // source uses SPTCH, which need not equal the CONVSP conversion pitch.
  // Split the low-32-bit product across the two existing window setup stages.
  // This prevents cascaded DSPs from sharing one register-to-register path.
  logic [31:0]           pblt_original_src_l_lo_q;
  logic [15:0]           pblt_original_src_l_hi_q;
  logic [DATA_WIDTH-1:0] pblt_original_src_l_delta_q;
  // W=1 (hit detection/common rectangle): never draws; overlap and intersection
  // use the geometric top-left destination rectangle independently of PBH/PBV.
  // The returned DADDR then identifies the selected traversal corner for
  // full-color forms; binary-to-XY ignores PBH/PBV and returns top-left.
  logic pblt_w1_q, pblt_array_hit;
  logic [DATA_WIDTH-1:0] pblt_common_daddr, pblt_common_dydx;
  // The W=1 hit path uses the same intersection already calculated and
  // registered for W=3 preclipping. Reusing that geometry keeps the long
  // dimensions -> overlap -> common-rectangle -> writeback path out of the
  // register-file input mux.
  assign pblt_array_hit = pblt_clip_hit_q;
  assign pblt_common_daddr = {
      pblt_vrev_q ? pblt_clip_y1_q : pblt_clip_y0_q,
      pblt_hrev_q ? pblt_clip_x1_q : pblt_clip_x0_q
  };
  assign pblt_common_dydx = {pblt_clip_dy_q, pblt_clip_dx_q};

  // PIXBLT XY variants: convert the XY SADDR/DADDR (latched raw at EXECUTE) to a
  // linear address at SETUP (source via CONVSP, dest via CONVDP, + OFFSET on
  // read port 3, + log2 PSIZE = pix_xy_xsh). Same shift form as CVXYL/FILL XY.
  logic [DATA_WIDTH-1:0] pblt_src_conv, pblt_dst_conv;
  assign pblt_src_conv =
      (({{16{pblt_src_addr_q[DATA_WIDTH-1]}}, pblt_src_addr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convsp[4:0]))
       + ({{16{pblt_src_addr_q[15]}}, pblt_src_addr_q[15:0]} << pix_xy_xsh)) + rf_rs3_data;
  assign pblt_dst_conv =
      (({{16{pblt_dst_addr_q[DATA_WIDTH-1]}}, pblt_dst_addr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convdp[4:0]))
       + ({{16{pblt_dst_addr_q[15]}}, pblt_dst_addr_q[15:0]} << pix_xy_xsh)) + rf_rs3_data;

  // Full-color direction and corner adjustment (Task 0163).  Binary-source
  // PIXBLTs explicitly ignore PBH/PBV.  L,L consumes software-adjusted
  // starting corners; every full-color form containing an XY operand starts
  // from the default top-left address and receives automatic X/Y adjustment.
  // A reverse-X start points one pixel beyond the right edge because each
  // memory access predecrements by one pixel.
  logic [DATA_WIDTH-1:0] pblt_src_base, pblt_dst_base;
  logic [DATA_WIDTH-1:0] pblt_src_base_q, pblt_dst_base_q;
  logic [DATA_WIDTH-1:0] pblt_h_adjust;
  logic [DATA_WIDTH-1:0] pblt_src_v_adjust, pblt_dst_v_adjust;
  logic [DATA_WIDTH-1:0] pblt_src_adjust, pblt_dst_adjust;
  logic [DATA_WIDTH-1:0] pblt_src_adjust_q, pblt_dst_adjust_q;
  logic [DATA_WIDTH-1:0] pblt_src_corner, pblt_dst_corner;
  logic [DATA_WIDTH-1:0] pblt_src_row_step, pblt_dst_row_step;
  logic [DATA_WIDTH-1:0] pblt_src_access_addr, pblt_dst_access_addr;
  logic [DATA_WIDTH-1:0] pblt_dst_after_addr;
  // PBX resume rebuild is deliberately pipelined across the otherwise quiet
  // architectural-context read states.  Keeping these offsets registered
  // prevents a decode -> register-file -> variable-shift -> multi-adder path
  // from landing directly on the working row registers in CORE_EXECUTE.
  logic [DATA_WIDTH-1:0] pblt_resume_src_x_offset_q;
  logic [DATA_WIDTH-1:0] pblt_resume_dst_x_offset_q;
  logic                  pblt_checkpoint_due;
  assign pblt_src_base = decoded.blt_src_xy ? pblt_src_conv
                                            : pblt_src_addr_q;
  assign pblt_dst_base = decoded.blt_dst_xy ? pblt_dst_conv
                                            : pblt_dst_addr_q;
  assign pblt_h_adjust = {{16{1'b0}}, pblt_dx_q} << pix_xy_xsh;
  assign pblt_src_v_adjust =
      {{16{1'b0}}, (pblt_empty ? 16'd0 : pblt_dy_q - 16'd1)}
      << (5'd31 - io_convsp[4:0]);
  assign pblt_dst_v_adjust =
      {{16{1'b0}}, (pblt_empty ? 16'd0 : pblt_dy_q - 16'd1)}
      << (5'd31 - io_convdp[4:0]);
  assign pblt_src_adjust = ((pblt_auto_corner_q && pblt_hrev_q)
                            ? pblt_h_adjust : 32'd0)
                         + ((pblt_auto_corner_q && pblt_vrev_q)
                            ? pblt_src_v_adjust : 32'd0);
  assign pblt_dst_adjust = ((pblt_auto_corner_q && pblt_hrev_q)
                            ? pblt_h_adjust : 32'd0)
                         + ((pblt_auto_corner_q && pblt_vrev_q)
                            ? pblt_dst_v_adjust : 32'd0);
  assign pblt_src_corner = pblt_src_base_q + pblt_src_adjust_q;
  assign pblt_dst_corner = pblt_dst_base_q + pblt_dst_adjust_q;
  assign pblt_src_row_step = pblt_vrev_q
                           ? (32'd0 - pblt_sptch_q) : pblt_sptch_q;
  assign pblt_dst_row_step = pblt_vrev_q
                           ? (32'd0 - pblt_dptch_q) : pblt_dptch_q;
  assign pblt_src_access_addr = pblt_hrev_q
                              ? pblt_src_addr_q - pblt_src_step
                              : pblt_src_addr_q;
  assign pblt_dst_access_addr = pblt_hrev_q
                              ? pblt_dst_addr_q - pblt_psize_ext
                              : pblt_dst_addr_q;
  assign pblt_dst_after_addr = pblt_dst_access_addr + pblt_psize_ext;
  // Checkpoints follow completed destination writes at a 16-bit word edge or
  // nonfinal row edge. Reverse traversal crosses a word edge after writing
  // the aligned low-address field; forward traversal crosses when the next
  // address is aligned.
  assign pblt_checkpoint_due = !pblt_done
      && (pblt_row_end
          || (pblt_hrev_q ? (pblt_dst_access_addr[3:0] == 4'd0)
                           : (pblt_dst_after_addr[3:0] == 4'd0)));

  always_ff @(posedge clk) begin
    if (rst) begin
      pblt_sptch_q    <= '0;
      pblt_dptch_q    <= '0;
      pblt_dx_q       <= '0;
      pblt_dy_q       <= '0;
      pblt_src_base_q <= '0;
      pblt_dst_base_q <= '0;
      pblt_src_adjust_q <= '0;
      pblt_dst_adjust_q <= '0;
      pblt_dx_extent_q <= '0;
      pblt_dy_extent_q <= '0;
      pblt_src_addr_q <= '0;
      pblt_dst_addr_q <= '0;
      pblt_src_row_q  <= '0;
      pblt_dst_row_q  <= '0;
      pblt_src_result_q <= '0;
      pblt_dst_result_q <= '0;
      pblt_src_result_next_q <= '0;
      pblt_dst_result_next_q <= '0;
      pblt_row_result_commit_q <= 1'b0;
      pblt_original_src_l_lo_q <= '0;
      pblt_original_src_l_hi_q <= '0;
      pblt_original_src_l_delta_q <= '0;
      pblt_x_q        <= '0;
      pblt_y_q        <= '0;
      pblt_substep_q  <= 3'd0;
      pblt_dest_read_q <= 1'b0;
      pblt_hrev_q     <= 1'b0;
      pblt_vrev_q     <= 1'b0;
      pblt_auto_corner_q <= 1'b0;
      pblt_src_pix_q  <= '0;
      pblt_src_eff_q  <= '0;
      pblt_dst_pix_q  <= '0;
      pblt_color0_q   <= '0;
      pblt_color1_q   <= '0;
      pblt_dst_xy_raw_q <= '0;
      pblt_wstart_q   <= '0;
      pblt_wend_q     <= '0;
      pblt_arr_x1_q   <= '0;
      pblt_arr_y1_q   <= '0;
      pblt_win_en_q   <= 1'b0;
      pblt_w2_q       <= 1'b0;
      pblt_w1_q       <= 1'b0;
      pblt_preclip_changed_q <= 1'b0;
      pblt_w3_empty_q <= 1'b0;
      pblt_resume_src_x_offset_q <= '0;
      pblt_resume_dst_x_offset_q <= '0;
      pblt_array_inside_q <= 1'b0;
      pblt_clip_hit_q <= 1'b0;
      pblt_clip_x0_q <= '0;
      pblt_clip_y0_q <= '0;
      pblt_clip_x1_q <= '0;
      pblt_clip_y1_q <= '0;
      pblt_clip_dx_q <= '0;
      pblt_clip_dy_q <= '0;
      pblt_clip_left_q <= '0;
      pblt_clip_top_q <= '0;
      pblt_clip_src_default_q <= '0;
      pblt_clip_dst_default_q <= '0;
      pblt_clip_src_h_adjust_q <= '0;
      pblt_clip_dst_h_adjust_q <= '0;
      pblt_clip_src_v_adjust_q <= '0;
      pblt_clip_dst_v_adjust_q <= '0;
    end else begin
      // Prepare completion pointers and the row-write predicate before the
      // bus acknowledge. Source/destination reads give both registers time
      // to settle; the final write still retires on its original clock edge.
      pblt_src_result_next_q <= decoded.blt_src_xy
          ? {pblt_src_result_q[31:16] + 16'd1,pblt_src_result_q[15:0]}
          : pblt_src_result_q + pblt_sptch_q;
      pblt_dst_result_next_q <= decoded.blt_dst_xy
          ? {pblt_dst_result_q[31:16] + 16'd1,pblt_dst_result_q[15:0]}
          : pblt_dst_result_q + pblt_dptch_q;
      pblt_row_result_commit_q <= (state_q == CORE_PBLT)
          && (pblt_substep_q == (pblt_dest_read_q ? 3'd4 : 3'd2))
          && pblt_row_end && !pblt_win_en_q;

      // EXECUTE: latch SADDR(port1) / DADDR(port2) / DYDX(port3). Window
      // clipping engages only for an XY destination with CONTROL.W=3; keep the
      // raw XY DADDR (pblt_dst_addr_q is converted to linear at SETUP).
      if (state_q == CORE_EXECUTE && is_pblt) begin
        if (array_resume) begin
          // PBX re-entry reads {B0,B2,B10}. B0/B2 are the next actual
          // accesses and B10 is the next effective traversal cursor. Capture
          // those architectural values first; the four quiet resume states
          // below rebuild the engine's internal row/corner convention.
          pblt_src_addr_q <= dispatch_rs1_q;
          pblt_dst_addr_q <= dispatch_rs2_q;
          pblt_x_q <= dispatch_rs3_q[15:0];
          pblt_y_q <= dispatch_rs3_q[DATA_WIDTH-1:16];
        end else begin
          pblt_src_addr_q <= dispatch_rs1_q;          // SADDR
          pblt_src_row_q  <= dispatch_rs1_q;
          pblt_dst_addr_q <= dispatch_rs2_q;          // DADDR
          pblt_dst_row_q  <= dispatch_rs2_q;
          pblt_dst_xy_raw_q <= dispatch_rs2_q;        // raw XY DADDR (window)
          pblt_dx_q       <= dispatch_rs3_q[15:0];
          pblt_dy_q       <= dispatch_rs3_q[DATA_WIDTH-1:16];
          pblt_x_q        <= 16'd0;
          pblt_y_q        <= 16'd0;
        end
        pblt_substep_q  <= 3'd0;
        pblt_hrev_q     <= !decoded.blt_binary
                         && io_control[CTRL_PBH_BIT];
        pblt_vrev_q     <= !decoded.blt_binary
                         && io_control[CTRL_PBV_BIT];
        pblt_auto_corner_q <= !decoded.blt_binary
                           && (decoded.blt_src_xy || decoded.blt_dst_xy);
        pblt_win_en_q   <= decoded.blt_dst_xy &&
                           (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd3);
        pblt_w2_q       <= !array_resume && decoded.blt_dst_xy &&
                           (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2);
        pblt_w1_q       <= !array_resume && decoded.blt_dst_xy &&
                           (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1);
        pblt_dest_read_q <= pixel_dest_read_required;
        pblt_preclip_changed_q <= 1'b0;
        pblt_w3_empty_q <= 1'b0;
      end
      if (state_q == CORE_ARRAY_RESUME1 && is_pblt) begin
        // {B1,B3,B11}: pitches and effective dimensions. In parallel, turn
        // the saved next-access pointers into the reverse-X one-past form and
        // register the cursor-to-row offsets.
        pblt_sptch_q <= rf_rs1_data;
        pblt_dptch_q <= rf_rs2_data;
        pblt_dx_q    <= rf_rs3_data[15:0];
        pblt_dy_q    <= rf_rs3_data[DATA_WIDTH-1:16];
        if (pblt_hrev_q) begin
          pblt_src_addr_q <= pblt_src_addr_q + pblt_psize_ext;
          pblt_dst_addr_q <= pblt_dst_addr_q + pblt_psize_ext;
        end
        pblt_resume_src_x_offset_q <= decoded.blt_binary
            ? {{16{1'b0}}, pblt_x_q}
            : ({{16{1'b0}}, pblt_x_q} << pix_xy_xsh);
        pblt_resume_dst_x_offset_q <=
            {{16{1'b0}}, pblt_x_q} << pix_xy_xsh;
      end
      if (state_q == CORE_ARRAY_RESUME2 && is_pblt) begin
        // {B12,B13,B14}: architectural completion results and effective raw
        // destination geometry. Reconstruct the row bases from only
        // registered resume operands; reverse pointers are already one past
        // the next access after CORE_ARRAY_RESUME1.
        pblt_src_result_q  <= rf_rs1_data;
        pblt_dst_result_q  <= rf_rs2_data;
        pblt_dst_xy_raw_q  <= rf_rs3_data;
        pblt_src_row_q <= pblt_hrev_q
            ? pblt_src_addr_q + pblt_resume_src_x_offset_q
            : pblt_src_addr_q - pblt_resume_src_x_offset_q;
        pblt_dst_row_q <= pblt_hrev_q
            ? pblt_dst_addr_q + pblt_resume_dst_x_offset_q
            : pblt_dst_addr_q - pblt_resume_dst_x_offset_q;
      end
      if (state_q == CORE_ARRAY_RESUME3 && is_pblt) begin
        // {B5,B6,B7}: preserved window/original dimensions.
        pblt_wstart_q <= rf_rs1_data;
        pblt_wend_q   <= rf_rs2_data;
        pblt_preclip_changed_q <= pblt_win_en_q
                               && (rf_rs3_data != {pblt_dy_q, pblt_dx_q});
      end
      if (state_q == CORE_ARRAY_RESUME4 && is_pblt) begin
        // {B8,B9}: binary expansion colors (harmlessly latched for full color).
        pblt_color0_q <= rf_rs1_data;
        pblt_color1_q <= rf_rs2_data;
        pblt_substep_q <= 3'd0;
      end
      // CORE_PBLT_SETUP_WIN: latch WSTART(port1=B5)/WEND(port2=B6) for clip.
      if (state_q == CORE_PBLT_SETUP_WIN) begin
        pblt_wstart_q <= rf_rs1_data;
        pblt_wend_q   <= rf_rs2_data;
        pblt_original_src_l_lo_q <= pblt_sptch_q[15:0] * pblt_dy_q;
        pblt_original_src_l_hi_q <= 16'(pblt_sptch_q[31:16] * pblt_dy_q);
        pblt_arr_x1_q <= {pblt_arr_x0[15],pblt_arr_x0} + {1'b0,pblt_dx_extent_q};
        pblt_arr_y1_q <= {pblt_arr_y0[15],pblt_arr_y0} + {1'b0,pblt_dy_extent_q};
      end
      if (state_q == CORE_PBLT_WIN_EVAL) begin
        pblt_original_src_l_delta_q <= pblt_original_src_l_lo_q
                                    + {pblt_original_src_l_hi_q,16'd0};
        // First stage: comparisons and 16-bit intersection geometry.
        pblt_array_inside_q <= pblt_array_inside;
        pblt_clip_hit_q     <= pblt_clip_hit;
        pblt_clip_x0_q      <= pblt_clip_x0;
        pblt_clip_y0_q      <= pblt_clip_y0;
        pblt_clip_x1_q      <= pblt_clip_x1;
        pblt_clip_y1_q      <= pblt_clip_y1;
        pblt_clip_dx_q      <= pblt_clip_dx;
        pblt_clip_dy_q      <= pblt_clip_dy;
        pblt_clip_left_q    <= pblt_clip_left;
        pblt_clip_top_q     <= pblt_clip_top;
      end
      if (state_q == CORE_PBLT_WIN_OFFSETS) begin
        // Second stage: variable shifts and the first address-add layer.
        pblt_clip_src_default_q  <= pblt_clip_src_default;
        pblt_clip_dst_default_q  <= pblt_clip_dst_default;
        pblt_clip_src_h_adjust_q <= pblt_clip_src_h_adjust;
        pblt_clip_dst_h_adjust_q <= pblt_clip_dst_h_adjust;
        pblt_clip_src_v_adjust_q <= pblt_clip_src_v_adjust;
        pblt_clip_dst_v_adjust_q <= pblt_clip_dst_v_adjust;
        if (pblt_win_en_q) begin
          pblt_src_result_q <= pblt_original_src_result;
          pblt_dst_result_q <= pblt_original_dst_result;
        end
      end
      // Apply the registered geometry only after both calculation stages.
      // These are quiet core cycles with no externally visible bus phase.
      if (state_q == CORE_PBLT_WIN_APPLY) begin
        if (pblt_win_en_q) begin
          pblt_preclip_changed_q <= !pblt_array_inside_q;
          pblt_w3_empty_q        <= !pblt_clip_hit_q;
          if (pblt_clip_hit_q) begin
            pblt_dst_xy_raw_q <= {pblt_clip_y0_q, pblt_clip_x0_q};
            pblt_dx_q         <= pblt_clip_dx_q;
            pblt_dy_q         <= pblt_clip_dy_q;
            pblt_src_addr_q   <= pblt_clip_src_corner;
            pblt_src_row_q    <= pblt_clip_src_corner;
            pblt_dst_addr_q   <= pblt_clip_dst_corner;
            pblt_dst_row_q    <= pblt_clip_dst_corner;
          end
        end
      end
      // CORE_PBLT_SETUP: latch SPTCH(port1) / DPTCH(port2); for the XY variants
      // convert the XY SADDR/DADDR to linear (port3 = OFFSET here).
      if (state_q == CORE_PBLT_SETUP) begin
        pblt_sptch_q <= rf_rs1_data;
        pblt_dptch_q <= rf_rs2_data;
        pblt_dx_extent_q <= pblt_dx_q - 16'd1;
        pblt_dy_extent_q <= pblt_dy_q - 16'd1;
        pblt_src_base_q <= pblt_src_base;
        pblt_dst_base_q <= pblt_dst_base;
        pblt_src_adjust_q <= pblt_src_adjust;
        pblt_dst_adjust_q <= pblt_dst_adjust;
        // Architectural completion context is based on the supplied
        // top-left/default address (or the software-adjusted L,L corner), not
        // on the internal directional traversal address.
      end
      if (state_q == CORE_PBLT_CORNER) begin
        pblt_src_addr_q <= pblt_src_corner;
        pblt_src_row_q  <= pblt_src_corner;
        pblt_dst_addr_q <= pblt_dst_corner;
        pblt_dst_row_q  <= pblt_dst_corner;
        pblt_src_result_q <= decoded.blt_src_xy ? pblt_src_addr_q:pblt_src_base_q;
        pblt_dst_result_q <= decoded.blt_dst_xy ? pblt_dst_addr_q:pblt_dst_base_q;
      end
      // CORE_PBLT_SETUP2 (binary form): latch COLOR0(port1) / COLOR1(port2).
      if (state_q == CORE_PBLT_SETUP2) begin
        pblt_color0_q <= rf_rs1_data;
        pblt_color1_q <= rf_rs2_data;
      end
      // CORE_PBLT: per pixel, read src (0) / read dst (1) / write (2).
      if (state_q == CORE_PBLT && mem_ack_eff) begin
        if (pblt_substep_q == 3'd0) begin
          pblt_src_pix_q <= mem_rdata_eff;
          pblt_src_eff_q <= pblt_src_eff_next;
          pblt_substep_q <= pblt_dest_read_q ? 3'd1 : 3'd2;
        end else if (pblt_substep_q == 3'd1) begin
          pblt_dst_pix_q <= mem_rdata_eff;
          pblt_substep_q <= 3'd2;
        end else begin
          // Write ack: advance within a row or move the internal traversal
          // pointers by the selected signed row step.  Separate result
          // pointers advance geometrically by +pitch once per completed row,
          // which preserves the documented completion context for every
          // PBH/PBV selection.
          pblt_substep_q  <= 3'd0;
          if (pblt_row_end) begin
            pblt_src_row_q    <= pblt_src_row_q + pblt_src_row_step;
            pblt_dst_row_q    <= pblt_dst_row_q + pblt_dst_row_step;
            pblt_src_addr_q   <= pblt_src_row_q + pblt_src_row_step;
            pblt_dst_addr_q   <= pblt_dst_row_q + pblt_dst_row_step;
            if (!pblt_done) begin
              pblt_y_q <= pblt_y_q + 16'd1;
              pblt_x_q <= 16'd0;
            end
          end else if (!pblt_done) begin
            pblt_src_addr_q <= pblt_hrev_q
                             ? pblt_src_addr_q - pblt_src_step
                             : pblt_src_addr_q + pblt_src_step;
            pblt_dst_addr_q <= pblt_hrev_q
                             ? pblt_dst_addr_q - pblt_psize_ext
                             : pblt_dst_addr_q + pblt_psize_ext;
            pblt_x_q        <= pblt_x_q + 16'd1;
          end
        end
      end
      if ((state_q == CORE_PBLT) && mem_ack_eff && pblt_row_result_commit_q) begin
        pblt_src_result_q <= pblt_src_result_next_q;
        pblt_dst_result_q <= pblt_dst_result_next_q;
      end
      if ((state_q == CORE_PBLT) && pblt_dest_read_q && !mem_ack_eff) begin
        if (pblt_substep_q == 3'd2)
          pblt_substep_q <= 3'd3;
        else if (pblt_substep_q == 3'd3)
          pblt_substep_q <= 3'd4;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // DRAV (Draw and Advance) — SPVU001A page 12-67.
  //
  // A single-pixel COLOR1 draw at Rd's XY address, then Rd advances by Rs as an
  // XY add. At EXECUTE: Rd (port2) is XY-converted to a linear address with
  // OFFSET (port3) — pix_xy_dst_linear, the same form as PIXT XY / FILL XY —
  // and latched; Rs/Rd are latched for the advance. CORE_DRAV optionally
  // reads the destination when PPOP/transparency/PMASK requires it, then
  // writes COLOR1 through the shared FILL pixel merge. The advance is written back at
  // CORE_WRITEBACK. Task 0112 adds the per-pixel W=1/2/3 behavior below.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] drav_rd_q, drav_rs_q, drav_linear_q, drav_dest_q;
  logic [DATA_WIDTH-1:0] drav_color_q;
  logic [DATA_WIDTH-1:0] drav_wstart_q, drav_wend_q;
  logic [2:0]            drav_substep_q;    // read, PPOP, merge, write (or direct)
  logic                  drav_dest_read_q;
  // Per-pixel window check (CONTROL.W, Task 0112). Rd's XY is tested against the
  // inclusive [WSTART..WEND] rectangle (read at CORE_DRAV_SETUP_WIN). The pixel
  // is drawn only for W=0, or W=2/W=3 when inside. V (W!=0) = NOT inside; WVP is
  // requested for W=1 inside (hit) or W=2 outside (miss). The advance always
  // happens. Reuses the shared fill_win_flag_wb / wvp_set V-write path.
  logic [1:0]            drav_w_q;          // CONTROL.W latched at EXECUTE
  logic                  drav_inside_q;     // Rd's pixel lies inside the window
  logic                  drav_in_window;    // combinational test on registered window bounds
  assign drav_in_window =
        ($signed(drav_rd_q[15:0]) >= $signed(drav_wstart_q[15:0])) && ($signed(drav_rd_q[15:0]) <= $signed(drav_wend_q[15:0]))
     && ($signed(drav_rd_q[DATA_WIDTH-1:16]) >= $signed(drav_wstart_q[DATA_WIDTH-1:16]))
     && ($signed(drav_rd_q[DATA_WIDTH-1:16]) <= $signed(drav_wend_q[DATA_WIDTH-1:16]));
  logic [DATA_WIDTH-1:0] drav_pixel_mask, drav_pmask_field;
  logic [DATA_WIDTH-1:0] drav_advance;
  assign drav_pixel_mask  = pixel_size_mask_q;
  assign drav_pmask_field = aligned_pmask(pixel_plane_mask_q, drav_linear_q,
                                          drav_pixel_mask);
  // COLOR1 is captured through port3 in the quiet setup cycle so the draw
  // request never includes a decode -> register-file -> pixel-processing
  // path.
  // Rd advanced by Rs: independent 16-bit X and Y adds, no carry X->Y.
  assign drav_advance = {drav_rd_q[DATA_WIDTH-1:16] + drav_rs_q[DATA_WIDTH-1:16],
                         drav_rd_q[15:0]            + drav_rs_q[15:0]};

  always_ff @(posedge clk) begin
    if (rst) begin
      drav_rd_q      <= '0;
      drav_rs_q      <= '0;
      drav_linear_q  <= '0;
      drav_dest_q    <= '0;
      drav_color_q   <= '0;
      drav_wstart_q  <= '0;
      drav_wend_q    <= '0;
      drav_substep_q <= 3'd0;
      drav_dest_read_q <= 1'b0;
      drav_w_q       <= 2'd0;
      drav_inside_q  <= 1'b0;
    end else begin
      if (state_q == CORE_EXECUTE && is_drav) begin
        drav_rd_q      <= dispatch_rs2_q;     // Rd (XY dest)
        drav_rs_q      <= dispatch_rs1_q;     // Rs (XY increment)
        drav_linear_q  <= pix_xy_dst_linear;  // convert(Rd) + OFFSET (port3)
        drav_substep_q <= pixel_dest_read_required ? 3'd0 : 3'd1;
        drav_dest_read_q <= pixel_dest_read_required;
        drav_w_q       <= io_control[CTRL_W_HI:CTRL_W_LO];
      end
      // CORE_DRAV_SETUP_WIN captures WSTART/WEND and COLOR1. The following
      // evaluation state checks the registered rectangle, keeping RF selection
      // and XY comparisons out of the same timing path.
      if (state_q == CORE_DRAV_SETUP_WIN) begin
        drav_wstart_q <= rf_rs1_data;
        drav_wend_q   <= rf_rs2_data;
        drav_color_q  <= rf_rs3_data;
      end
      if (state_q == CORE_DRAV_WIN_EVAL)
        drav_inside_q <= drav_in_window;
      if (state_q == CORE_DRAV && mem_ack_eff) begin
        if (drav_substep_q == 3'd0) begin
          drav_dest_q    <= mem_rdata_eff;  // read ack
          drav_substep_q <= 3'd1;
        end else begin
          drav_substep_q <= drav_dest_read_q ? 3'd0 : 3'd1;
        end
      end
      if ((state_q == CORE_DRAV) && drav_dest_read_q && !mem_ack_eff) begin
        if (drav_substep_q == 3'd1)
          drav_substep_q <= 3'd2;
        else if (drav_substep_q == 3'd2)
          drav_substep_q <= 3'd3;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // LINE (Bresenham inner loop) — SPVU001A page 12-99.
  //
  // The implied B operands are read over 3 setup cycles (line_rd_b above), then
  // CORE_LINE_DRAW runs the per-pixel loop: draw COLOR1 at DADDR's XY
  // (optional destination read plus the FILL/DRAV pixel merge), then step d
  // and DADDR (+INC1 when d>0 i.e. the diagonal move, else +INC2) and decrement
  // COUNT. The Z bit (instr_word_q[7]) selects whether d=0 counts as ">0"
  // (Z=1 -> d>=0). At the end d/DADDR/COUNT are written back to B0/B2/B10.
  // Tasks 0115–0116 add W=3 clipping and W=1/W=2 abort behavior. DADDR/INC
  // adds are XY (independent 16-bit halves, no carry), matching ADDXY / DRAV.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] line_d_q, line_count_q, line_inc1_q, line_inc2_q;
  logic [DATA_WIDTH-1:0] line_offset_q, line_daddr_q, line_color_q, line_dest_q;
  logic [15:0]           line_b_q, line_a_q;
  logic [2:0]            line_substep_q;
  logic                  line_dest_read_q;
  // Form the signed XY contribution, then add OFFSET in a separate stage.
  // LINE already has three continuation/checkpoint cycles between pixels:
  // reuse them so the conversion adds no per-pixel latency.
  logic [DATA_WIDTH-1:0] line_xy_sum, line_xy_sum_q, line_linear_q;
  wire [DATA_WIDTH-1:0] line_linear = line_linear_q;
  assign line_xy_sum =
      (({{16{line_daddr_q[DATA_WIDTH-1]}}, line_daddr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convdp[4:0]))
       + ({{16{line_daddr_q[15]}}, line_daddr_q[15:0]} << pix_xy_xsh));
  // Pixel merge (PPOP / transparency / PMASK), COLOR1 = line_color_q.
  logic [DATA_WIDTH-1:0] line_pixel_mask, line_pmask_field;
  assign line_pixel_mask  = pixel_size_mask_q;
  assign line_pmask_field = aligned_pmask(pixel_plane_mask_q, line_linear,
                                          line_pixel_mask);
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
        ($signed(line_daddr_q[15:0]) >= $signed(line_wstart_q[15:0])) && ($signed(line_daddr_q[15:0]) <= $signed(line_wend_q[15:0]))
     && ($signed(line_daddr_q[DATA_WIDTH-1:16]) >= $signed(line_wstart_q[DATA_WIDTH-1:16]))
     && ($signed(line_daddr_q[DATA_WIDTH-1:16]) <= $signed(line_wend_q[DATA_WIDTH-1:16]));
  // Draw decision: W=1 (hit) draws the pixels OUTSIDE the window and aborts on
  // an inside pixel; W=2 (miss) and W=3 (clip) draw INSIDE pixels (W=2 aborts
  // on an outside pixel, W=3 just inhibits it). V at the end is NOT last-inside
  // for every windowed mode; WVP is set on a W=1/W=2 abort.
  assign line_draw_pixel = (line_w_mode == 2'd1) ? !line_in_window : line_in_window;
  assign line_clip_out   = line_win_en && !line_draw_pixel;
  assign line_abort      = (line_w_mode == 2'd1 &&  line_in_window)
                         || (line_w_mode == 2'd2 && !line_in_window);
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
      line_xy_sum_q  <= '0;
      line_linear_q  <= '0;
      line_daddr_q   <= '0;
      line_color_q   <= '0;
      line_dest_q    <= '0;
      line_b_q       <= '0;
      line_a_q       <= '0;
      line_substep_q <= 3'd0;
      line_dest_read_q <= 1'b0;
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
      if ((state_q == CORE_LINE_SETUP_WIN) || (state_q == CORE_LINE_CKPT_D))
        line_xy_sum_q <= line_xy_sum;
      if ((state_q == CORE_LINE_ADDR) || (state_q == CORE_LINE_CKPT_DADDR))
        line_linear_q <= line_xy_sum_q + line_offset_q;
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
        line_substep_q <= (pixel_dest_read_required || line_win_en) ? 3'd0 : 3'd1;
        line_dest_read_q <= pixel_dest_read_required || line_win_en;
      end
      if (state_q == CORE_LINE_DRAW && mem_ack_eff) begin
        if (line_substep_q == 3'd0) begin
          line_dest_q <= mem_rdata_eff;              // read ack
          line_substep_q <= 3'd1;
        end else begin
          line_substep_q <= line_dest_read_q ? 3'd0 : 3'd1;
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
      if ((state_q == CORE_LINE_DRAW) && line_dest_read_q && !mem_ack_eff) begin
        if (line_substep_q == 3'd1)
          line_substep_q <= 3'd2;
        else if (line_substep_q == 3'd2)
          line_substep_q <= 3'd3;
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
  //   is cleared after each mem_ack_eff.
  //   mm_rp_q (32-bit) is the working stack pointer / current transaction
  //   address.
  //   mm_mask_idx is the priority-encoded current mask bit and mm_iter_idx
  //   is the corresponding register. The two architected list encodings are
  //   intentionally asymmetric:
  //     - MMTM: mask[15-N] selects Rn. A highest mask-bit scan therefore
  //       saves the lowest-order selected register first.
  //     - MMFM: mask[N] selects Rn. The same highest mask-bit scan restores
  //       the highest-order selected register first.
  //   TI's assembler confirms both layouts: MMTM A2-A6,A10-A14 emits 0x3E3E,
  //   while MMFM A4,A8-A13 emits 0x3F10.
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
  // The focused tests use both the User's Guide worked example and exact
  // masks emitted by TI's original assembler, so a self-consistent but
  // reversed push/pop implementation cannot pass.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] mm_rp_q;
  logic [15:0]           mm_mask_q;
  logic [4:0]            mm_count_q;
  logic [3:0]            mm_mask_idx;
  logic [3:0]            mm_iter_idx;
  logic                  mm_mask_will_be_empty;
  logic                  is_mmtm, is_mmfm, is_mm;
  // MMTM push staging. The register-file read-port-1 index is shared by
  // every instruction, so it is always the registered selector. During an
  // MMTM push, stage 0 loads that selector from the registered mask (the
  // mask changes on entry and on each acknowledgement), stage 1 registers
  // the selected register's value, and stage 2 issues the memory write
  // from that flop.
  logic [3:0]            mm_push_idx;
  logic [1:0]            mm_push_stage_q;
  logic [DATA_WIDTH-1:0] mm_push_data_q;

  function automatic logic [4:0] mm_popcount16(input logic [15:0] value);
    logic [1:0] p0, p1, p2, p3, p4, p5, p6, p7;
    logic [2:0] q0, q1, q2, q3;
    logic [3:0] o0, o1;
    begin
      p0 = {1'b0, value[0]}  + {1'b0, value[1]};
      p1 = {1'b0, value[2]}  + {1'b0, value[3]};
      p2 = {1'b0, value[4]}  + {1'b0, value[5]};
      p3 = {1'b0, value[6]}  + {1'b0, value[7]};
      p4 = {1'b0, value[8]}  + {1'b0, value[9]};
      p5 = {1'b0, value[10]} + {1'b0, value[11]};
      p6 = {1'b0, value[12]} + {1'b0, value[13]};
      p7 = {1'b0, value[14]} + {1'b0, value[15]};
      q0 = {1'b0, p0} + {1'b0, p1};
      q1 = {1'b0, p2} + {1'b0, p3};
      q2 = {1'b0, p4} + {1'b0, p5};
      q3 = {1'b0, p6} + {1'b0, p7};
      o0 = {1'b0, q0} + {1'b0, q1};
      o1 = {1'b0, q2} + {1'b0, q3};
      mm_popcount16 = {1'b0, o0} + {1'b0, o1};
    end
  endfunction

  // Keep the hot MMTM register-file selector off the instruction-class
  // equality tree. This flag is captured alongside `decoded` at the existing
  // decode boundary, so it has the same architectural lifetime.
  assign is_mmtm = is_mmtm_decode_q;
  assign is_mmfm = (decoded.iclass == INSTR_MMFM);
  assign is_mm   = is_mmtm || is_mmfm;

  always_comb begin
    mm_mask_idx = 4'd0;
    // Both encodings select their architecturally first register via the
    // highest set mask bit. Iterate low-to-high so the last match wins.
    for (int i = 0; i < 16; i++) begin
      if (mm_mask_q[i]) mm_mask_idx = i[3:0];
    end
    mm_iter_idx = is_mmfm ? mm_mask_idx : (4'd15 - mm_mask_idx);
  end
  // MMTM stores mask[15-N] as RN. This form uses only the registered mask.
  assign mm_push_idx = 4'd15 - mm_mask_idx;
  // Count the remaining transfers separately so the final-ack decision does
  // not depend on a mask priority encoder, variable shift, and reduction.
  // A zero mask retains the existing single-ack completion behavior.
  assign mm_mask_will_be_empty = (mm_count_q <= 5'd1);

  always_ff @(posedge clk) begin
    if (rst) begin
      mm_rp_q   <= '0;
      mm_mask_q <= '0;
      mm_count_q <= '0;
    end else if (state_q == CORE_EXECUTE && is_mm) begin
      // First entry to CORE_MEMORY: capture the mask and seed the
      // working Rp. MMTM predecrements (first push at Rp-32); MMFM
      // starts at Rp (first read at Rp).
      // dispatch_rs2_q holds Rd from the preceding DISPATCH cycle. Reuse it
      // here instead of placing the register-file read mux on the iterator
      // initialization path.
      mm_rp_q   <= is_mmtm ? (dispatch_rs2_q - WORD_BIT_SIZE) : dispatch_rs2_q;
      mm_mask_q <= imm_lo_q;
      mm_count_q <= mm_popcount16(imm_lo_q);
    end else if (state_q == CORE_MEMORY
              && is_mm
              && mem_ack_eff) begin
      mm_mask_q[mm_mask_idx] <= 1'b0;
      if (mm_count_q != 5'd0) mm_count_q <= mm_count_q - 5'd1;
      if (is_mmfm) begin
        // Post-increment after every read, including the last.
        mm_rp_q <= mm_rp_q + WORD_BIT_SIZE;
      end else if (!mm_mask_will_be_empty) begin
        // Pre-decrement model: skip the step after the final push so the
        // last write address remains as the new Rp.
        mm_rp_q <= mm_rp_q - WORD_BIT_SIZE;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mm_push_stage_q <= '0;
      mm_push_data_q  <= '0;
    end else begin
      if (!((state_q == CORE_MEMORY) && is_mmtm) || mem_ack_eff) begin
        // Entry, or the mask changes at this edge: restart the staging.
        mm_push_stage_q <= 2'd0;
      end else if (mm_push_stage_q == 2'd0) begin
        mm_push_stage_q <= 2'd1;          // rf_rs1_idx_q now matches the mask
      end else if (mm_push_stage_q == 2'd1) begin
        mm_push_data_q  <= rf_rs1_data;   // R(mm_push_idx)
        mm_push_stage_q <= 2'd2;
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
      imm_ext_lo_q <= '0;
      imm_ext_hi_q <= '0;
    end else begin
      if (state_q == CORE_FETCH_IMM_LO && mem_ack_eff) begin
        imm_lo_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_HI && mem_ack_eff) begin
        imm_hi_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_EXT_LO && mem_ack_eff) begin
        imm_ext_lo_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_EXT_HI && mem_ack_eff) begin
        imm_ext_hi_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
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
  reg_file_t              rf_rs1_file_live, rf_rs1_file_q;
  reg_idx_t               rf_rs1_idx_live, rf_rs1_idx_q;
  logic [DATA_WIDTH-1:0]  rf_rs1_data;
  reg_file_t              rf_rs2_file;
  reg_idx_t               rf_rs2_idx;
  reg_file_t              rf_rs2_file_live, rf_rs2_file_q;
  reg_idx_t               rf_rs2_idx_live, rf_rs2_idx_q;
  logic [DATA_WIDTH-1:0]  rf_rs2_data;
  reg_file_t              rf_rs3_file;
  reg_idx_t               rf_rs3_idx;
  reg_file_t              rf_rs3_file_live, rf_rs3_file_q;
  reg_idx_t               rf_rs3_idx_live, rf_rs3_idx_q;
  logic [DATA_WIDTH-1:0]  rf_rs3_data;
  logic                   rf_wr_en;
  reg_file_t              rf_wr_file;
  reg_idx_t               rf_wr_idx;
  logic [DATA_WIDTH-1:0]  rf_wr_data;
  // Decode the regular writeback data source one cycle before it is needed.
  // This keeps the 7-bit instruction-class decoder out of the register-file
  // write-data mux, which otherwise fans out across every destination bit.
  typedef enum logic [3:0] {
    RF_WB_EXECUTE       = 4'd0,
    RF_WB_DRAV           = 4'd1,
    RF_WB_MPY            = 4'd2,
    RF_WB_DIV            = 4'd3,
    RF_WB_MOD            = 4'd4,
    RF_WB_MMTM           = 4'd5,
    RF_WB_MMFM           = 4'd6,
    RF_WB_MOVE_STORE     = 4'd7,
    RF_WB_MOVE_LOAD      = 4'd8,
    RF_WB_MOVE_M2M       = 4'd9,
    RF_WB_ABS_OFF_LOAD   = 4'd10,
    RF_WB_FILL            = 4'd11,
    RF_WB_PIXBLT          = 4'd12,
    RF_WB_LINE            = 4'd13
  } rf_wb_source_t;
  rf_wb_source_t rf_wb_source_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      rf_wb_source_q <= RF_WB_EXECUTE;
    end else if (state_q == CORE_DISPATCH) begin
      unique case (decoded.iclass)
        INSTR_DRAV: rf_wb_source_q <= RF_WB_DRAV;
        INSTR_MPYS, INSTR_MPYU: rf_wb_source_q <= RF_WB_MPY;
        INSTR_DIVU, INSTR_DIVS: rf_wb_source_q <= RF_WB_DIV;
        INSTR_MODU, INSTR_MODS: rf_wb_source_q <= RF_WB_MOD;
        INSTR_MMTM: rf_wb_source_q <= RF_WB_MMTM;
        INSTR_MMFM: rf_wb_source_q <= RF_WB_MMFM;
        INSTR_MOVE_FIELD_STORE: rf_wb_source_q <= RF_WB_MOVE_STORE;
        INSTR_MOVE_FIELD_LOAD: rf_wb_source_q <= RF_WB_MOVE_LOAD;
        INSTR_MOVE_FIELD_M2M,
        INSTR_MOVE_OFF_M2M_PI,
        INSTR_MOVE_ABS_M2M_PI: rf_wb_source_q <= RF_WB_MOVE_M2M;
        INSTR_MOVE_ABS_LOAD,
        INSTR_MOVE_OFF_LOAD: rf_wb_source_q <= RF_WB_ABS_OFF_LOAD;
        INSTR_FILL_L,
        INSTR_FILL_XY: rf_wb_source_q <= RF_WB_FILL;
        INSTR_PIXBLT_LL: rf_wb_source_q <= RF_WB_PIXBLT;
        INSTR_LINE: rf_wb_source_q <= RF_WB_LINE;
        default: rf_wb_source_q <= RF_WB_EXECUTE;
      endcase
    end
  end
  logic [DATA_WIDTH-1:0]  rf_sp;
  logic                   div_suppress_wb;

  // ALU ports.
  alu_op_t                alu_op;
  logic [DATA_WIDTH-1:0]  alu_a;
  logic [DATA_WIDTH-1:0]  alu_b;
  logic                   alu_cin;
  logic [DATA_WIDTH-1:0]  alu_result;
  alu_flags_t             alu_flags;
  alu_op_t                alu_op_q;
  logic [DATA_WIDTH-1:0]  alu_a_q;
  logic [DATA_WIDTH-1:0]  alu_b_q;
  logic                   alu_cin_q;
  logic [DATA_WIDTH-1:0]  alu_b_capture;
  logic [DATA_WIDTH-1:0]  alu_rs1_operand, alu_rs2_operand;

  // Status-register ports.
  logic                   st_flag_update_en;
  logic                   st_write_en;
  logic [DATA_WIDTH-1:0]  st_write_data;
  logic [DATA_WIDTH-1:0]  st_value;
  logic                   st_n, st_c, st_z, st_v;

  // Shifter ports.
  logic [DATA_WIDTH-1:0]  shifter_result;
  alu_flags_t             shifter_flags;
  logic [SHIFT_AMOUNT_WIDTH-1:0] shifter_amount_q;
  shift_op_t              shifter_op_q;
  alu_flags_t             shifter_flags_q;

  // ---- Operand assembly ----------------------------------------------------
  // Full 32-bit immediate composed from the latched 16-bit pieces. For
  // IW form: sign-extend (or zero-extend) imm_lo_q. For IL form (Task
  // 0013): concatenate {imm_hi_q, imm_lo_q}.
  logic [DATA_WIDTH-1:0] imm32;
  always_comb begin
    if (decoded.needs_imm32 || decoded.needs_imm64) begin
      imm32 = {imm_hi_q, imm_lo_q};
    end else if (decoded.imm_sign_extend) begin
      imm32 = {{(DATA_WIDTH-INSTR_WORD_WIDTH){imm_lo_q[INSTR_WORD_WIDTH-1]}}, imm_lo_q};
    end else begin
      imm32 = {{(DATA_WIDTH-INSTR_WORD_WIDTH){1'b0}}, imm_lo_q};
    end
  end

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
  assign is_fill    = is_fill_q;
  assign fill_is_xy = fill_is_xy_q;
  // PIXBLT reads its 5 implied B-file operands across two cycles: at EXECUTE —
  // SADDR(B0) on port1, DADDR(B2) on port2, DYDX(B7) on port3; at
  // CORE_PBLT_SETUP — SPTCH(B1) on port1, DPTCH(B3) on port2.
  assign is_pblt    = is_pblt_q;
  assign array_resume = (is_fill || is_pblt) && st_value[ST_PBX_BIT];
  // DRAV: at EXECUTE — Rs on port1, Rd on port2, OFFSET(B4) on port3 (for the
  // XY->linear conversion of Rd); in CORE_DRAV — COLOR1(B9) on port1.
  logic is_drav;
  assign is_drav    = is_drav_q;
  // LINE: 3 setup cycles read the implied B operands —
  //   SETUP1: d(B0)/DYDX(B7)/COUNT(B10);  SETUP2: INC1(B11)/INC2(B12)/OFFSET(B4);
  //   SETUP3: DADDR(B2)/COLOR1(B9).  All reads are from the B file.
  logic is_line;
  assign is_line    = is_line_q;
  logic is_emu;
  assign is_emu     = (decoded.iclass == INSTR_EMU);
  // Selectors are prepared for the state entered at the next clock edge.
  // Their registered values then drive the asynchronous register file for
  // that whole state, keeping decode/state muxing out of the data-read path.
  core_state_t rf_sel_state;
  assign rf_sel_state = state_d;
  logic line_rd_b;   // LINE is doing B-file setup reads this cycle
  assign line_rd_b  = is_line && ((rf_sel_state == CORE_LINE_SETUP1)
                               || (rf_sel_state == CORE_LINE_SETUP2)
                               || (rf_sel_state == CORE_LINE_SETUP3)
                               || (rf_sel_state == CORE_LINE_SETUP_WIN));

  assign rf_rs1_file_live = line_rd_b ? REG_FILE_B
                     : (rf_sel_state == CORE_PIXT_SETUP_WIN) ? REG_FILE_B
                     : (is_drav && ((rf_sel_state == CORE_DRAV) || (rf_sel_state == CORE_DRAV_SETUP_WIN))) ? REG_FILE_B
                     : (is_fill || is_pblt) ? REG_FILE_B
                     : (decoded.iclass == INSTR_MOVE_RR) ? decoded.rs_file
                     : decoded.rd_file;
  // Read-port 1 index is normally decoded.rs_idx. MMTM repurposes it
  // during CORE_MEMORY to scan the register list — rf_rs1_idx then
  // points at the current register being pushed, and rf_rs1_data
  // becomes the 32-bit value driven onto mem_wdata.
  assign rf_rs1_idx_live  = ((is_fill || is_pblt) && array_resume)
                     ? ((rf_sel_state == CORE_ARRAY_RESUME1) ? B_SPTCH_IDX
                      : (rf_sel_state == CORE_ARRAY_RESUME2) ? reg_idx_t'(12)
                      : (rf_sel_state == CORE_ARRAY_RESUME3) ? CPW_WSTART_IDX
                      : (rf_sel_state == CORE_ARRAY_RESUME4) ? B_COLOR0_IDX
                                                       : B_SADDR_IDX)
                     : is_fill ? ((rf_sel_state == CORE_FILL_SETUP_WIN) ? CPW_WSTART_IDX
                                : (rf_sel_state == CORE_FILL_SETUP) ? B_COLOR1_IDX : B_DADDR_IDX)
                     : is_pblt ? ((rf_sel_state == CORE_PBLT_SETUP_WIN) ? CPW_WSTART_IDX
                                : (rf_sel_state == CORE_PBLT_SETUP2) ? B_COLOR0_IDX
                                : (rf_sel_state == CORE_PBLT_SETUP)  ? B_SPTCH_IDX : B_SADDR_IDX)
                     : (rf_sel_state == CORE_MEMORY && is_mmtm) ? mm_push_idx
                     : (is_drav && (rf_sel_state == CORE_DRAV_SETUP_WIN)) ? CPW_WSTART_IDX // WSTART
                     : (is_drav && (rf_sel_state == CORE_DRAV)) ? B_COLOR1_IDX  // COLOR1 for the draw
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP1)) ? B_SADDR_IDX   // d (B0)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP2)) ? B_INC1_IDX    // INC1 (B11)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP3)) ? B_DADDR_IDX   // DADDR (B2)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP_WIN)) ? CPW_WSTART_IDX // WSTART (B5)
                     : (rf_sel_state == CORE_PIXT_SETUP_WIN) ? CPW_WSTART_IDX           // PIXT WSTART
                     : decoded.rs_idx;
  // Read port 2 normally reads Rd. CPW repurposes it (Rd is not a source
  // for CPW) to read the window-start register WSTART = B5; read port 3
  // reads the window-end register WEND = B6. Both are fixed B-file
  // registers per SPVU001A page 12-57. FILL: B3 (DPTCH) / B7 (DYDX).
  // PIXBLT: DADDR(B2) at EXECUTE, DPTCH(B3) at SETUP.
  assign rf_rs2_file_live = (line_rd_b || is_fill || is_pblt || (decoded.iclass == INSTR_CPW)
                        || (rf_sel_state == CORE_PIXT_SETUP_WIN)
                        || (is_drav && (rf_sel_state == CORE_DRAV_SETUP_WIN)))
                     ? REG_FILE_B : decoded.rd_file;
  assign rf_rs2_idx_live  = ((is_fill || is_pblt) && array_resume)
                     ? ((rf_sel_state == CORE_ARRAY_RESUME1) ? B_DPTCH_IDX
                      : (rf_sel_state == CORE_ARRAY_RESUME2) ? reg_idx_t'(13)
                      : (rf_sel_state == CORE_ARRAY_RESUME3) ? CPW_WEND_IDX
                      : (rf_sel_state == CORE_ARRAY_RESUME4) ? B_COLOR1_IDX
                                                       : B_DADDR_IDX)
                     : is_fill ? ((rf_sel_state == CORE_FILL_SETUP_WIN) ? CPW_WEND_IDX : B_DPTCH_IDX)
                     : is_pblt ? ((rf_sel_state == CORE_PBLT_SETUP_WIN) ? CPW_WEND_IDX
                                : (rf_sel_state == CORE_PBLT_SETUP2) ? B_COLOR1_IDX
                                : (rf_sel_state == CORE_PBLT_SETUP)  ? B_DPTCH_IDX : B_DADDR_IDX)
                     : (is_drav && (rf_sel_state == CORE_DRAV_SETUP_WIN)) ? CPW_WEND_IDX  // WEND
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP1)) ? B_DYDX_IDX    // DYDX (B7)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP2)) ? B_INC2_IDX    // INC2 (B12)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP3)) ? B_COLOR1_IDX  // COLOR1 (B9)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP_WIN)) ? CPW_WEND_IDX // WEND (B6)
                     : (rf_sel_state == CORE_PIXT_SETUP_WIN) ? CPW_WEND_IDX             // PIXT WEND
                     : (decoded.iclass == INSTR_CPW) ? CPW_WSTART_IDX : decoded.rd_idx;
  // Read port 3: CPW reads WEND (B6); DIVU/DIVS (even Rd) read the low half
  // of the 64-bit dividend, Rd+1; CVXYL/XY-PIXT read OFFSET (B4); FILL/PIXBLT
  // read DYDX (B7) at EXECUTE. Otherwise unused.
  assign rf_rs3_file_live = ((decoded.iclass == INSTR_DIVU) || (decoded.iclass == INSTR_DIVS))
                     ? decoded.rd_file : REG_FILE_B;
  assign rf_rs3_idx_live  = ((decoded.iclass == INSTR_DIVU) || (decoded.iclass == INSTR_DIVS))
                     ? (decoded.rd_idx + 4'd1)
                     : (is_drav && (rf_sel_state == CORE_DRAV_SETUP_WIN))
                     ? B_COLOR1_IDX
                     : ((is_fill || is_pblt) && array_resume)
                     ? ((rf_sel_state == CORE_ARRAY_RESUME1) ? reg_idx_t'(11)
                      : (rf_sel_state == CORE_ARRAY_RESUME2) ? reg_idx_t'(14)
                      : (rf_sel_state == CORE_ARRAY_RESUME3) ? B_DYDX_IDX
                                                       : B_COUNT_IDX)
                     : is_fill ? ((rf_sel_state == CORE_FILL_SETUP) ? B_OFFSET_IDX : B_DYDX_IDX)
                     : is_pblt ? ((rf_sel_state == CORE_PBLT_SETUP) ? B_OFFSET_IDX : B_DYDX_IDX)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP1)) ? B_COUNT_IDX   // COUNT (B10)
                     : (is_line && (rf_sel_state == CORE_LINE_SETUP2)) ? B_OFFSET_IDX  // OFFSET (B4)
                     : ((decoded.iclass == INSTR_CVXYL) || decoded.xy_addr || is_drav) ? B_OFFSET_IDX
                     : CPW_WEND_IDX;

  // Register selectors for the state the FSM is entering. Each state then
  // reads through stable addresses, including engine setup and resume stages.
  always_ff @(posedge clk) begin
    if (rst) begin
      rf_rs1_file_q <= REG_FILE_A;
      rf_rs1_idx_q  <= '0;
      rf_rs2_file_q <= REG_FILE_A;
      rf_rs2_idx_q  <= '0;
      rf_rs3_file_q <= REG_FILE_A;
      rf_rs3_idx_q  <= '0;
    end else begin
      rf_rs1_file_q <= rf_rs1_file_live;
      rf_rs1_idx_q  <= rf_rs1_idx_live;
      rf_rs2_file_q <= rf_rs2_file_live;
      rf_rs2_idx_q  <= rf_rs2_idx_live;
      rf_rs3_file_q <= rf_rs3_file_live;
      rf_rs3_idx_q  <= rf_rs3_idx_live;
    end
  end

  assign rf_rs1_file = rf_rs1_file_q;
  // MMTM loads its push index through rf_rs1_idx_q (see mm_push_stage_q), so
  // read port 1 has no live bypass mux in front of the register file.
  assign rf_rs1_idx  = rf_rs1_idx_q;
  assign rf_rs2_file = rf_rs2_file_q;
  assign rf_rs2_idx  = rf_rs2_idx_q;
  assign rf_rs3_file = rf_rs3_file_q;
  assign rf_rs3_idx  = rf_rs3_idx_q;

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

  // Capture the DSJ source during DISPATCH. These instructions may fetch a
  // displacement before WRITEBACK, so the operand is available a full cycle
  // before the branch decision. This cuts the async register-file read out of
  // the PC-load path.
  logic is_dsj_family;
  logic [DATA_WIDTH-1:0] dsj_rd_value_q;
  assign is_dsj_family = (decoded.iclass == INSTR_DSJ)
                      || (decoded.iclass == INSTR_DSJEQ)
                      || (decoded.iclass == INSTR_DSJNE)
                      || (decoded.iclass == INSTR_DSJS);
  always_ff @(posedge clk) begin
    if (rst) begin
      dsj_rd_value_q <= '0;
    end else if ((state_q == CORE_OPERAND_PREP) && is_dsj_family) begin
      dsj_rd_value_q <= rf_rs2_data;
    end
  end

  // "Will Rd be zero after the decrement?" DSJ-family instructions subtract
  // one, so the result is zero exactly when the captured old Rd equals one.
  logic dsj_rd_nonzero;
  assign dsj_rd_nonzero = (dsj_rd_value_q != DATA_WIDTH'(1));

  // Writeback enable is a one-cycle pulse, gated by the FSM state.
  // Writeback data and flag-input come from either the ALU or the
  // shifter depending on `decoded.use_shifter`. For DSJEQ/DSJNE the
  // dsj_precondition further gates the write: if Z doesn't match the
  // pre-condition the spec mandates Rd is left unchanged.
  // MMFM writes a popped register on every CORE_MEMORY ack (mem_rdata_eff is
  // valid in the same cycle mem_ack_eff asserts). This is a second user of
  // the single regfile write port, active in CORE_MEMORY rather than
  // CORE_WRITEBACK; the final-Rp write still happens at WRITEBACK below.
  // Rp is never in the list (spec: "unpredictable results"), so the two
  // writes never target the same index.
  logic mmfm_pop_wr;
  assign mmfm_pop_wr = (state_q == CORE_MEMORY) && is_mmfm && mem_ack_eff;

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
  logic [DATA_WIDTH-1:0] dispatch_rs1_q, dispatch_rs2_q, dispatch_rs3_q;
  logic [DATA_WIDTH-1:0] mv_ptr_operand_q, mv_ptr_execute;
  logic [DATA_WIDTH-1:0] mv_addr_q, mv_store_data_q;
  logic                  mv_load_ptr_wr;
  assign is_mv_store = is_mv_store_q;
  assign is_mv_load  = is_mv_load_q;
  assign mv_postinc  = (decoded.move_mode == MV_ADDR_POSTINC);
  assign mv_predec   = (decoded.move_mode == MV_ADDR_PREDEC);
  assign mv_incdec   = mv_postinc || mv_predec;
  assign mv_ptr      = is_mv_store ? rf_rs2_data : rf_rs1_data;
  assign mv_ptr_execute = mv_ptr_operand_q;
  assign mv_load_ptr_wr = (state_q == CORE_MEMORY) && is_mv_load
                       && mv_incdec && mem_ack_eff;

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
  logic [DATA_WIDTH-1:0] mv_read_data;
  logic [DATA_WIDTH-1:0] mv_load_data;      // field-extended load result
  logic [DATA_WIDTH-1:0] mv_load_data_q;    // extended word captured on read ack
  logic [4:0]            mv_sign_bit_idx;   // FS-1 for a 32-bit field source
  assign mv_fs_raw = instr_word_q[9] ? st_value[ST_FS1_HI:ST_FS1_LO]
                                     : st_value[ST_FS0_HI:ST_FS0_LO];
  // MOVB (decoded.force_byte) forces an 8-bit field and sign-extension on
  // load. PIXT (decoded.force_pixel) forces the field size to the PSIZE I/O
  // register value and zero-extension on load. Both override ST.FS/FE.
  assign mv_fs     = decoded.force_byte   ? FIELD_SIZE_WIDTH'(8)
                   : decoded.force_pixel  ? io_psize[FIELD_SIZE_WIDTH-1:0]
                   : (mv_fs_raw == 5'd0)  ? FIELD_SIZE_WIDTH'(DATA_WIDTH)
                                          : {1'b0, mv_fs_raw};
  assign mv_fe     = decoded.force_byte   ? 1'b1   // MOVB: sign-extend
                   : decoded.force_pixel  ? 1'b0   // PIXT: zero-extend
                   : (instr_word_q[9] ? st_value[ST_FE1_BIT] : st_value[ST_FE0_BIT]);
  assign mv_fs_ext = DATA_WIDTH'(mv_fs);
  assign mv_fmask  = (mv_fs >= FIELD_SIZE_WIDTH'(DATA_WIDTH))
                   ? '1 : ((32'd1 << mv_fs) - 32'd1);
  // The field parameters depend only on the decoded instruction, ST and PSIZE,
  // all of which are stable for several cycles before the read acknowledge
  // (decode, dispatch, operand prep and execute all precede CORE_MEMORY). They
  // are registered so the acknowledge-cycle path holds only the data select.
  logic [DATA_WIDTH-1:0] mv_fmask_q;
  logic                  mv_fs32_q, mv_fe_q;
  logic [4:0]            mv_sign_bit_idx_q;
  always_ff @(posedge clk) begin
    mv_fmask_q        <= mv_fmask;
    mv_fs32_q         <= (mv_fs >= FIELD_SIZE_WIDTH'(DATA_WIDTH));
    mv_fe_q           <= mv_fe;
    mv_sign_bit_idx_q <= mv_fs[4:0] - 5'd1;
  end
  assign mv_read_data = (decoded.force_pixel && is_mv_load)
                      ? (mem_rdata_eff
                         & ~aligned_pmask(io_pmask, mv_addr_q, mv_fmask_q))
                      : mem_rdata_eff;
  // The FS=32 arm below bypasses this index; for FS=1..31, five bits address
  // the selected sign bit without an implicit 6-to-5-bit truncation.
  assign mv_sign_bit_idx = mv_fs[4:0] - 5'd1;
  always_comb begin
    if (mv_fs32_q) begin
      mv_load_data = mv_read_data;                          // FS = 32: identity
    end else if (mv_fe_q && mv_read_data[mv_sign_bit_idx_q]) begin
      mv_load_data = mv_read_data | ~mv_fmask_q;            // sign-extend
    end else begin
      mv_load_data = mv_read_data & mv_fmask_q;             // zero-extend
    end
  end

  // Resolve MOVE field extraction and FE sign/zero extension with the memory
  // acknowledgement, then keep the extended result registered through
  // WRITEBACK. This takes FS decoding and the variable field mux out of the
  // register-file write-data path.
  always_ff @(posedge clk) begin
    if (rst) begin
      mv_load_data_q <= '0;
    end else if ((state_q == CORE_MEMORY) && mem_ack_eff
                 && ((rf_wb_source_q == RF_WB_MOVE_LOAD)
                     || (rf_wb_source_q == RF_WB_ABS_OFF_LOAD))) begin
      mv_load_data_q <= mv_load_data;
    end
  end

  // PIXT store pixel-write engine (Tasks 0089/0090/0091). A store reads
  // pix_dest_q first only when processing or an XY window needs it; otherwise
  // replace/no-mask/no-T is one direct write. The processed path combines
  // three CONTROL features, all confined to the PSIZE-bit pixel by mv_fmask:
  //   1. Pixel processing (PPOP, CONTROL[14:10]): processed = f(src, dest).
  //      All 16 Boolean and 6 arithmetic codes are implemented within the
  //      selected pixel width.
  //   2. Plane mask (PMASK): memory-source/destination protected bits enter
  //      PPOP as zero, then a 1 masks the corresponding processed-result bit.
  //   3. Transparency (CONTROL.T, bit 5): if the MASKED processed pixel is 0,
  //      the raw destination is left unchanged (the write still occurs).
  // Protected raw destination bits are then merged back for a visible result.
  // `pixt_rmw` selects this path; a regular MOVE store (no force_pixel) stays
  // a single write.
  logic                  pixt_rmw, pixt_m2m, pixt_m2m_rmw;
  logic [DATA_WIDTH-1:0] pixt_source_pixel;
  logic [DATA_WIDTH-1:0] pixt_source_pmask_field;
  logic [DATA_WIDTH-1:0] pixt_dest_address, pixt_pmask_field;
  logic [DATA_WIDTH-1:0] pix_dest_q;     // dest pixel latched at the read step
  // Arithmetic-PPOP operands: the PSIZE-bit pixels as unsigned values, and
  // the unsigned add. Arith ops are only defined for pixels of 4/8/16 bits
  // (SPVU001A); they are computed for all sizes (1/2-bit results are
  // spec-Undefined, so any value is acceptable).
  logic                  pixt_rmw_q;
  assign pixt_rmw         = pixt_rmw_q;
  assign pixt_m2m         = decoded.force_pixel
                          && (iclass_pix_q == INSTR_MOVE_FIELD_M2M);
  // Both destination-read predicates share the pixel configuration snapshot
  // at EXECUTE. A later host CONTROL/PMASK write applies to the next instruction.
  // Keep the class and live configuration off the memory-address/step cones.
  logic                  pixt_m2m_rmw_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      pixt_rmw_q <= 1'b0;
      pixt_m2m_rmw_q <= 1'b0;
    end else if (state_q == CORE_EXECUTE) begin
      pixt_rmw_q <= pixt_store_decode_q
                    && (pixel_dest_read_required || pixt_xy_win_dispatch);
      pixt_m2m_rmw_q <= pixt_m2m && pixel_dest_read_required;
    end
  end
  assign pixt_m2m_rmw     = pixt_m2m_rmw_q;
  assign pixt_dest_address = pixt_m2m ? m2m_dst_addr_q : mv_addr_q;
  assign pixt_source_pmask_field =
      aligned_pmask(pixel_plane_mask_q, m2m_src_addr_q, pixel_size_mask_q);
  assign pixt_pmask_field =
      aligned_pmask(pixel_plane_mask_q, pixt_dest_address, pixel_size_mask_q);
  assign pixt_source_pixel = pixt_m2m
                           ? (move_data_q & ~pixt_source_pmask_field)
                           : mv_store_data_q;
  always_comb begin
    pixel_ppop_src   = pixt_source_pixel;
    pixel_ppop_raw_dest = pix_dest_q;
    pixel_ppop_pmask = pixt_pmask_field;
    pixel_ppop_fmask = pixel_size_mask_q;
    pixel_ppop_inhibit = pixt_clip_out;
    if (is_fill) begin
      pixel_ppop_src = aligned_color(fill_color_q, fill_addr_q,
                                     pixel_size_mask_q);
      pixel_ppop_raw_dest = fill_dest_q;
      pixel_ppop_pmask = fill_pmask_field;
      pixel_ppop_inhibit = fill_clip_out;
    end else if (is_pblt) begin
      pixel_ppop_src   = pblt_src_eff;
      pixel_ppop_raw_dest = pblt_dst_pix_q;
      pixel_ppop_pmask = pblt_pmask_field;
      pixel_ppop_inhibit = pblt_clip_out_q;
    end else if (is_drav) begin
      pixel_ppop_src = aligned_color(drav_color_q, drav_linear_q,
                                     pixel_size_mask_q);
      pixel_ppop_raw_dest = drav_dest_q;
      pixel_ppop_pmask = drav_pmask_field;
      pixel_ppop_inhibit = 1'b0;
    end else if (is_line) begin
      pixel_ppop_src = aligned_color(line_color_q, line_linear,
                                     pixel_size_mask_q);
      pixel_ppop_raw_dest = line_dest_q;
      pixel_ppop_pmask = line_pmask_field;
      pixel_ppop_inhibit = line_clip_out;
    end
  end

  // The graphics array loops have natural cycles after a destination read.
  // Capture the aligned source/destination operands on the read ack, then
  // register the PPOP result and the final transparency/plane-mask merge on
  // successive cycles. This keeps the variable pixel alignment, arithmetic
  // PPOP and write-data selection out of one fabric-clock path.
  assign pixel_ppop_result_stage =
      ppop_apply(pixel_ppop_src_q,
                 pixel_ppop_raw_dest_q & ~pixel_ppop_pmask_q,
                 pixel_ppop_code_q, pixel_ppop_fmask_q);
  assign pixel_ppop_transp_stage = pixel_ppop_transp_en_q
      && ((pixel_ppop_result_q & ~pixel_ppop_pmask_q
           & pixel_ppop_fmask_q) == '0);
  assign pixel_ppop_merged_stage =
      (pixel_ppop_transp_stage || pixel_ppop_inhibit_q)
      ? pixel_ppop_raw_dest_q
      : ((pixel_ppop_result_q & ~pixel_ppop_pmask_q)
         | (pixel_ppop_raw_dest_q & pixel_ppop_pmask_q));

  always_ff @(posedge clk) begin
    if (rst) begin
      pixel_ppop_src_q       <= '0;
      pixel_ppop_raw_dest_q  <= '0;
      pixel_ppop_pmask_q     <= '0;
      pixel_ppop_fmask_q     <= '0;
      pixel_ppop_result_q    <= '0;
      pixel_ppop_merged_q    <= '0;
      pixel_ppop_inhibit_q   <= 1'b0;
      pixel_ppop_transp_en_q <= 1'b0;
    end else begin
      // Stage 1: destination-read acknowledgements. Use the returned raw word
      // directly because the engine's destination latch updates on this edge.
      if (((state_q == CORE_FILL) && mem_ack_eff && (fill_substep_q == 3'd0))
          || ((state_q == CORE_DRAV) && mem_ack_eff && (drav_substep_q == 3'd0))
          || ((state_q == CORE_LINE_DRAW) && mem_ack_eff
              && (line_substep_q == 3'd0))
          || ((state_q == CORE_PBLT) && mem_ack_eff
              && (pblt_substep_q == 3'd1) && pblt_dest_read_q)
          || ((state_q == CORE_MEMORY) && mem_ack_eff
              && (((iclass_pix_q == INSTR_MOVE_FIELD_STORE)
                   && pixt_rmw && (mem_op_step == 3'd0))
                  || (pixt_m2m_rmw && (mem_op_step == 3'd1))))) begin
        pixel_ppop_src_q       <= pixel_ppop_src;
        pixel_ppop_raw_dest_q  <= mem_rdata_eff;
        pixel_ppop_pmask_q     <= pixel_ppop_pmask;
        pixel_ppop_fmask_q     <= pixel_ppop_fmask;
        pixel_ppop_inhibit_q   <= pixel_ppop_inhibit;
        pixel_ppop_transp_en_q <= pixel_transp_en_q;
      end

      // Stage 2: PPOP arithmetic / boolean result.
      if (((state_q == CORE_FILL) && fill_dest_read_q
           && (fill_substep_q == 3'd1))
          || ((state_q == CORE_DRAV) && drav_dest_read_q
              && (drav_substep_q == 3'd1))
          || ((state_q == CORE_LINE_DRAW) && line_dest_read_q
              && (line_substep_q == 3'd1))
          || ((state_q == CORE_PBLT) && pblt_dest_read_q
              && (pblt_substep_q == 3'd2))
          || ((state_q == CORE_MEMORY)
              && ((pixt_rmw && (iclass_pix_q == INSTR_MOVE_FIELD_STORE)
                   && (mem_op_step == 3'd1))
                  || (pixt_m2m_rmw && (mem_op_step == 3'd2))))) begin
        pixel_ppop_result_q <= pixel_ppop_result_stage;
      end

      // Stage 3: plane-mask restoration and transparent/inhibited write data.
      if (((state_q == CORE_FILL) && fill_dest_read_q
           && (fill_substep_q == 3'd2))
          || ((state_q == CORE_DRAV) && drav_dest_read_q
              && (drav_substep_q == 3'd2))
          || ((state_q == CORE_LINE_DRAW) && line_dest_read_q
              && (line_substep_q == 3'd2))
          || ((state_q == CORE_PBLT) && pblt_dest_read_q
              && (pblt_substep_q == 3'd3))
          || ((state_q == CORE_MEMORY)
              && ((pixt_rmw && (iclass_pix_q == INSTR_MOVE_FIELD_STORE)
                   && (mem_op_step == 3'd2))
                  || (pixt_m2m_rmw && (mem_op_step == 3'd3))))) begin
        pixel_ppop_merged_q <= pixel_ppop_merged_stage;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pixel_size_mask_q  <= '0;
      pixel_plane_mask_q <= '0;
      pixel_ppop_code_q  <= '0;
      pixel_transp_en_q  <= 1'b0;
    end else if (state_q == CORE_EXECUTE) begin
      pixel_size_mask_q  <= (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0])
                          - 32'd1;
      pixel_plane_mask_q <= io_pmask;
      pixel_ppop_code_q  <= io_control[CTRL_PPOP_HI:CTRL_PPOP_LO];
      pixel_transp_en_q  <= io_control[CTRL_T_BIT];
    end
  end
  // Per-pixel window check for PIXT operations with an XY destination,
  // mirroring DRAV. This includes register-to-XY and XY-to-XY forms.
  // WSTART/WEND are read at CORE_PIXT_SETUP_WIN; the destination point is
  // latched before those read ports are repurposed. W=2/W=3 draw inside;
  // W=1 never draws. V (W!=0) = NOT inside; WVP on W=1 hit or W=2 miss.
  logic                  pixt_xy_win, pixt_xy_m2m, pixt_xy_win_dispatch;
  logic                  pixt_xy_win_q;
  logic [1:0]            pixt_w_q;
  logic [DATA_WIDTH-1:0] pixt_wstart_q, pixt_wend_q;
  logic [DATA_WIDTH-1:0] pixt_point_q;
  logic                  pixt_inside_q;     // latched at the pixel write step
  logic                  pixt_in_window, pixt_clip_out;
  assign pixt_xy_m2m = pixt_m2m && decoded.xy_addr;
  assign pixt_xy_win_dispatch = (pixt_xy_store_decode_q || pixt_xy_m2m)
                     && (io_control[CTRL_W_HI:CTRL_W_LO] != 2'd0);
  assign pixt_xy_win = (state_q == CORE_EXECUTE)
                    ? pixt_xy_win_dispatch : pixt_xy_win_q;
  assign pixt_in_window =
        ($signed(pixt_point_q[15:0]) >= $signed(pixt_wstart_q[15:0]))
     && ($signed(pixt_point_q[15:0]) <= $signed(pixt_wend_q[15:0]))
     && ($signed(pixt_point_q[DATA_WIDTH-1:16]) >= $signed(pixt_wstart_q[DATA_WIDTH-1:16]))
     && ($signed(pixt_point_q[DATA_WIDTH-1:16]) <= $signed(pixt_wend_q[DATA_WIDTH-1:16]));
  // W=1 never draws; W=2/W=3 draw inside.
  assign pixt_clip_out = pixt_xy_win &&
                         ((pixt_w_q == 2'd1) || !pixt_in_window);
  always_ff @(posedge clk) begin
    if (rst) begin
      pixt_wstart_q <= '0;
      pixt_wend_q   <= '0;
      pixt_point_q  <= '0;
      pixt_inside_q <= 1'b0;
      pixt_xy_win_q <= 1'b0;
      pixt_w_q     <= '0;
    end else begin
      if (state_q == CORE_EXECUTE) begin
        pixt_xy_win_q <= pixt_xy_win_dispatch;
        pixt_w_q <= io_control[CTRL_W_HI:CTRL_W_LO];
        if (pixt_xy_win_dispatch)
          pixt_point_q <= dispatch_rs2_q;
      end
      if (state_q == CORE_PIXT_SETUP_WIN) begin
        pixt_wstart_q <= rf_rs1_data;   // WSTART (B5)
        pixt_wend_q   <= rf_rs2_data;   // WEND (B6)
      end
      if (state_q == CORE_PIXT_WIN_EVAL)
        pixt_inside_q <= pixt_in_window;
      // Refresh the store form's result at its RMW write step. The M2M form
      // either proceeds or skips directly from SETUP_WIN using the live test.
      if ((state_q == CORE_MEMORY) && pixt_rmw && (mem_op_step == 3'd3) && mem_ack_eff)
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
  assign pix_xy_linear = (({{16{mv_ptr_execute[DATA_WIDTH-1]}}, mv_ptr_execute[DATA_WIDTH-1:16]} << pix_xy_yshift)
                          + ({{16{mv_ptr_execute[15]}}, mv_ptr_execute[15:0]} << pix_xy_xsh))
                          + dispatch_rs3_q; // + OFFSET (B4)

  assign mv_addr     = decoded.xy_addr ? pix_xy_linear
                     : mv_predec       ? (mv_ptr_execute - mv_fs_ext) : mv_ptr_execute;
  assign mv_ptr_new  = mv_predec ? (mv_ptr_execute - mv_fs_ext)
                                 : (mv_ptr_execute + mv_fs_ext);

  // Destination-pointer XY conversion (for the XY-to-XY PIXT M2M, Task 0086).
  // pix_xy_linear above converts the SOURCE pointer (mv_ptr = rf_rs1 for the
  // M2M) with CONVSP; the M2M destination (rf_rs2) converts with CONVDP.
  logic [4:0]            pix_xy_dst_yshift;
  logic [DATA_WIDTH-1:0] pix_xy_dst_linear;
  assign pix_xy_dst_yshift = 5'd31 - io_convdp[4:0];
  assign pix_xy_dst_linear =
      (({{16{dispatch_rs2_q[DATA_WIDTH-1]}}, dispatch_rs2_q[DATA_WIDTH-1:16]} << pix_xy_dst_yshift)
       + ({{16{dispatch_rs2_q[15]}}, dispatch_rs2_q[15:0]} << pix_xy_xsh))
      + dispatch_rs3_q; // + OFFSET (B4)

  // ---- Indirect-to-indirect MOVE auto inc/dec (Task 0062) -----------------
  // Two pointers (Rs=source, Rd=dest) both step by ±32. The source pointer
  // (Rs) is written during CORE_MEMORY at the step-0 (read) ack; the
  // destination pointer (Rd) is written at WRITEBACK. The step-1 (write)
  // address uses rf_rs2_data, which — when Rs==Rd — already reflects the
  // step-0 Rs update, so a postincrement Rs==Rd writes to the incremented
  // location (SPVU001A 12-138). To avoid double-stepping that one register,
  // the WRITEBACK Rd write is suppressed when Rs==Rd.
  logic                  is_mv_m2m, is_move_off_m2m_pi;
  logic                  is_move_abs_m2m_pi, is_m2m_dst_only_pi;
  logic                  is_movb_off_m2m, is_movb_abs_m2m;
  logic                  is_move_off_m2m, is_move_abs_m2m;
  logic                  m2m_same_reg, m2m_src_wr;
  logic [DATA_WIDTH-1:0] m2m_src_new, m2m_dst_new;
  logic [DATA_WIDTH-1:0] m2m_src_addr_q, m2m_dst_addr_q;
  logic [DATA_WIDTH-1:0] m2m_src_rf_q, m2m_dst_rf_q, m2m_offset_rf_q;
  logic [DATA_WIDTH-1:0] m2m_src_base_q, m2m_dst_base_q;
  logic [DATA_WIDTH-1:0] m2m_src_base, m2m_dst_base;
  logic [DATA_WIDTH-1:0] m2m_src_final, m2m_dst_final, m2m_dst_final_base;
  logic [DATA_WIDTH-1:0] m2m_src_rf, m2m_dst_rf;
  logic [DATA_WIDTH-1:0] m2m_src_offset, m2m_dst_offset;
  assign is_movb_off_m2m = (decoded.iclass == INSTR_MOVB_OFF_M2M);
  assign is_movb_abs_m2m = (decoded.iclass == INSTR_MOVB_ABS_M2M);
  assign is_move_off_m2m = (decoded.iclass == INSTR_MOVE_OFF_M2M);
  assign is_move_abs_m2m = (decoded.iclass == INSTR_MOVE_ABS_M2M);
  assign is_move_off_m2m_pi = (decoded.iclass == INSTR_MOVE_OFF_M2M_PI);
  assign is_move_abs_m2m_pi = (decoded.iclass == INSTR_MOVE_ABS_M2M_PI);
  assign is_m2m_dst_only_pi = is_move_off_m2m_pi || is_move_abs_m2m_pi;
  assign is_mv_m2m       = (decoded.iclass == INSTR_MOVE_FIELD_M2M)
                        || is_m2m_dst_only_pi
                        || is_movb_off_m2m || is_movb_abs_m2m
                        || is_move_off_m2m || is_move_abs_m2m;
  assign m2m_same_reg = (decoded.rs_idx == decoded.rd_idx);
  assign m2m_src_offset =
      {{(DATA_WIDTH-INSTR_WORD_WIDTH){imm_lo_q[INSTR_WORD_WIDTH-1]}}, imm_lo_q};
  assign m2m_dst_offset =
      {{(DATA_WIDTH-INSTR_WORD_WIDTH){imm_hi_q[INSTR_WORD_WIDTH-1]}}, imm_hi_q};
  // The M2M address path is staged to meet the 100 MHz fabric clock.  Stage 1
  // captures the asynchronous register-file operands, stage 2 performs the
  // XY/absolute base selection and shifts, and stage 3 applies OFFSET or a
  // signed field offset.  The architectural address is unchanged; only the
  // instruction's internal latency increases by three quiet cycles.
  // These address expressions are consumed only in CORE_M2M_CALC, after
  // CORE_EXECUTE has captured the dispatch operands. Keep the asynchronous
  // register-file outputs out of the staged base-address path.
  assign m2m_src_rf    = m2m_src_rf_q;
  assign m2m_dst_rf    = m2m_dst_rf_q;
  // Stage 2: form an absolute address or the shifted XY base.  OFFSET is
  // deliberately deferred to stage 3 so the barrel shifts do not share a
  // cycle with a 32-bit carry chain.
  assign m2m_src_base = (is_movb_abs_m2m || is_move_abs_m2m || is_move_abs_m2m_pi)
                      ? {imm_hi_q, imm_lo_q}
                      : decoded.xy_addr
                      ? (({{16{m2m_src_rf[DATA_WIDTH-1]}}, m2m_src_rf[DATA_WIDTH-1:16]} << pix_xy_yshift)
                         + ({{16{m2m_src_rf[15]}}, m2m_src_rf[15:0]} << pix_xy_xsh))
                      : m2m_src_rf;
  assign m2m_dst_base = (is_movb_abs_m2m || is_move_abs_m2m)
                      ? {imm_ext_hi_q, imm_ext_lo_q}
                      : decoded.xy_addr
                      ? (({{16{m2m_dst_rf[DATA_WIDTH-1]}}, m2m_dst_rf[DATA_WIDTH-1:16]} << pix_xy_dst_yshift)
                         + ({{16{m2m_dst_rf[15]}}, m2m_dst_rf[15:0]} << pix_xy_xsh))
                      : m2m_dst_rf;

  // Stage 3: finish the selected address form.
  assign m2m_src_final = (is_movb_abs_m2m || is_move_abs_m2m || is_move_abs_m2m_pi)
                       ? m2m_src_base_q
                       : decoded.xy_addr ? (m2m_src_base_q + m2m_offset_rf_q)
                       : (is_movb_off_m2m || is_move_off_m2m || is_move_off_m2m_pi)
                       ? (m2m_src_base_q + m2m_src_offset)
                       : mv_predec ? (m2m_src_base_q - mv_fs_ext) : m2m_src_base_q;
  assign m2m_dst_final_base = (is_movb_abs_m2m || is_move_abs_m2m)
                            ? m2m_dst_base_q
                            : decoded.xy_addr ? (m2m_dst_base_q + m2m_offset_rf_q)
                            : (is_movb_off_m2m || is_move_off_m2m)
                            ? (m2m_dst_base_q + m2m_dst_offset)
                            : mv_predec ? (m2m_dst_base_q - mv_fs_ext) : m2m_dst_base_q;
  assign m2m_dst_final = (m2m_same_reg && mv_incdec && !is_m2m_dst_only_pi)
                       ? (mv_predec ? (m2m_dst_final_base - mv_fs_ext)
                                    : (m2m_dst_final_base + mv_fs_ext))
                       : m2m_dst_final_base;
   assign m2m_src_new  = mv_predec ? (dispatch_rs1_q - mv_fs_ext) : (dispatch_rs1_q + mv_fs_ext);
   assign m2m_dst_new  = mv_predec ? (dispatch_rs2_q - mv_fs_ext) : (dispatch_rs2_q + mv_fs_ext);
  // Register every field-memory operand at EXECUTE. This keeps the memory
  // request and PIXT processing stages independent of the asynchronous
  // register-file/decode/address-conversion path. When an indirect M2M uses
  // the same register for both pointers, the source update happens after the
  // read; preserve the architecturally required updated destination address.
  always_ff @(posedge clk) begin
    if (rst) begin
      mv_addr_q        <= '0;
      mv_store_data_q  <= '0;
      m2m_src_addr_q   <= '0;
      m2m_dst_addr_q   <= '0;
      m2m_src_rf_q     <= '0;
      m2m_dst_rf_q     <= '0;
      m2m_offset_rf_q  <= '0;
      m2m_src_base_q   <= '0;
      m2m_dst_base_q   <= '0;
    end else if (state_q == CORE_EXECUTE && is_mv_m2m) begin
      m2m_src_rf_q    <= dispatch_rs1_q;
      m2m_dst_rf_q    <= dispatch_rs2_q;
      m2m_offset_rf_q <= dispatch_rs3_q;
    end else if (state_q == CORE_M2M_CALC) begin
      m2m_src_base_q <= m2m_src_base;
      m2m_dst_base_q <= m2m_dst_base;
    end else if (state_q == CORE_M2M_COMMIT) begin
      m2m_src_addr_q <= m2m_src_final;
      m2m_dst_addr_q <= m2m_dst_final;
    end else if (state_q == CORE_EXECUTE) begin
      mv_addr_q        <= mv_addr;
      mv_store_data_q  <= dispatch_rs1_q;
    end
  end
  // Update the source pointer Rs at the step-0 read ack (inc/dec M2M only).
  assign m2m_src_wr   = (state_q == CORE_MEMORY) && is_mv_m2m && mv_incdec
                     && !is_m2m_dst_only_pi
                     && (mem_op_step == 3'd0) && mem_ack_eff;

  // FILL writes the final DADDR back to B2 in CORE_FILL_WB; PIXBLT writes the
  // final SADDR (B0) in CORE_PBLT_WB and the final DADDR (B2) in CORE_PBLT_WB2.
  // W=1 hits instead write common-rectangle DADDR then DYDX in two cycles.
  logic fill_wb, pblt_wb_saddr, pblt_wb_daddr;
  logic fill_w1_daddr_wb, fill_w1_dydx_wb;
  logic pblt_w1_daddr_wb, pblt_w1_dydx_wb;
  logic common_daddr_wb, common_dydx_wb, graphics_wb;
  assign fill_wb       = (state_q == CORE_FILL_WB) && !fill_w3_empty_q;
  assign pblt_wb_saddr = (state_q == CORE_PBLT_WB);
  assign pblt_wb_daddr = (state_q == CORE_PBLT_WB2) && !pblt_w3_empty_q;
  assign fill_w1_daddr_wb = (state_q == CORE_FILL_WIN_HIT) && fill_array_hit;
  assign fill_w1_dydx_wb  = (state_q == CORE_FILL_W1_DYDX);
  assign pblt_w1_daddr_wb = (state_q == CORE_PBLT_WIN_HIT) && pblt_array_hit;
  assign pblt_w1_dydx_wb  = (state_q == CORE_PBLT_W1_DYDX);
  assign common_daddr_wb = fill_w1_daddr_wb || pblt_w1_daddr_wb;
  assign common_dydx_wb  = fill_w1_dydx_wb  || pblt_w1_dydx_wb;
  // Interruptible-array checkpoint image (Task 0166). The seven quiet states
  // serialize the architecturally visible B-file image through the single
  // write port. B0/B2 identify the next actual source/destination pixels;
  // B10-B14 retain the private cursor/geometry/results needed by PBX resume.
  // FILL does not alter B0 or B13. `array_checkpoint` marks the only cycle at
  // which the complete image is coherent and an array interrupt may be taken.
  logic array_ckpt_b0_wb, array_ckpt_b2_wb, array_ckpt_b10_wb;
  logic array_ckpt_b11_wb, array_ckpt_b12_wb, array_ckpt_b13_wb;
  logic array_ckpt_b14_wb, array_ckpt_wb, array_checkpoint;
  logic [DATA_WIDTH-1:0] array_ckpt_saddr, array_ckpt_daddr;
  logic [DATA_WIDTH-1:0] array_ckpt_cursor, array_ckpt_dims;
  logic [DATA_WIDTH-1:0] array_ckpt_b12_data, array_ckpt_b13_data;
  logic [DATA_WIDTH-1:0] array_ckpt_b14_data;
  assign array_checkpoint   = (state_q == CORE_ARRAY_CKPT_B14);
  assign array_ckpt_b0_wb   = (state_q == CORE_ARRAY_CKPT_B0) && is_pblt;
  assign array_ckpt_b2_wb   = (state_q == CORE_ARRAY_CKPT_B2);
  assign array_ckpt_b10_wb  = (state_q == CORE_ARRAY_CKPT_B10);
  assign array_ckpt_b11_wb  = (state_q == CORE_ARRAY_CKPT_B11);
  assign array_ckpt_b12_wb  = (state_q == CORE_ARRAY_CKPT_B12);
  assign array_ckpt_b13_wb  = (state_q == CORE_ARRAY_CKPT_B13) && is_pblt;
  // FILL L resumes from B2/B10-B12 and never consumes the raw XY cursor.
  // Preserve its program-owned B14 (Ultimate Tennis keeps the zoom port here).
  assign array_ckpt_b14_wb  = array_checkpoint && (!is_fill || fill_is_xy);
  assign array_ckpt_wb = array_ckpt_b0_wb || array_ckpt_b2_wb
                       || array_ckpt_b10_wb || array_ckpt_b11_wb
                       || array_ckpt_b12_wb || array_ckpt_b13_wb
                       || array_ckpt_b14_wb;
  assign array_ckpt_saddr = pblt_hrev_q
                          ? pblt_src_addr_q - pblt_src_step
                          : pblt_src_addr_q;
  assign array_ckpt_daddr = is_fill ? fill_addr_q
                          : pblt_hrev_q
                          ? pblt_dst_addr_q - pblt_psize_ext
                          : pblt_dst_addr_q;
  assign array_ckpt_cursor = is_fill ? {fill_y_q, fill_x_q}
                                     : {pblt_y_q, pblt_x_q};
  assign array_ckpt_dims = is_fill ? {fill_dy_q, fill_dx_q}
                                   : {pblt_dy_q, pblt_dx_q};
  assign array_ckpt_b12_data = is_fill ? fill_result_q : pblt_src_result_q;
  assign array_ckpt_b13_data = pblt_dst_result_q;
  assign array_ckpt_b14_data = is_fill ? fill_daddr_raw_q
                                       : pblt_dst_xy_raw_q;
  // LINE final/checkpoint writebacks: d -> B0, DADDR -> B2, COUNT -> B10,
  // one per cycle. The checkpoint form publishes the next-pixel continuation
  // image before interrupt sampling; final/abort writeback retains the
  // original completion path and status behavior.
  logic line_wb_d, line_wb_daddr, line_wb_count, line_wb;
  logic line_checkpoint;
  assign line_wb_d     = (state_q == CORE_LINE_WB_D)
                      || (state_q == CORE_LINE_CKPT_D);
  assign line_wb_daddr = (state_q == CORE_LINE_WB_DADDR)
                      || (state_q == CORE_LINE_CKPT_DADDR);
  assign line_wb_count = (state_q == CORE_LINE_WB_COUNT)
                      || (state_q == CORE_LINE_CKPT_COUNT);
  assign line_checkpoint = (state_q == CORE_LINE_CKPT_COUNT);
  assign line_wb       = line_wb_d || line_wb_daddr || line_wb_count;
  assign graphics_wb   = fill_wb || pblt_wb_saddr || pblt_wb_daddr
                       || common_daddr_wb || common_dydx_wb || array_ckpt_wb
                       || line_wb;
  // Interrupt-entry SP writeback: at CORE_INT_DONE, SP <- SP-64 (two 32-bit
  // pushes done). Only when context was actually pushed (an NMI with NMIM=1
  // saves nothing, so SP is unchanged). Highest-priority regfile write.
  logic int_sp_wb;
  assign int_sp_wb = (state_q == CORE_INT_DONE) && int_push_q;
  assign rf_wr_en   = ((state_q == CORE_WRITEBACK)
                       && decoded.wb_reg_en
                       && dsj_precondition
                       // Dual-inc/dec Rs==Rd was already written at step 0.
                       // Destination-only postincrement forms never write Rs.
                       && !(is_mv_m2m && !is_m2m_dst_only_pi && m2m_same_reg)
                       && !div_suppress_wb)
                   || mmfm_pop_wr
                   || mv_load_ptr_wr
                   || m2m_src_wr
                   || graphics_wb
                   || int_sp_wb;
  assign rf_wr_file = int_sp_wb ? REG_FILE_A
                    : graphics_wb ? REG_FILE_B : decoded.rd_file;
  assign rf_wr_idx  = int_sp_wb ? REG_SP_IDX
                    : line_wb_count              ? B_COUNT_IDX
                    : array_ckpt_b14_wb           ? reg_idx_t'(14)
                    : array_ckpt_b13_wb           ? reg_idx_t'(13)
                    : array_ckpt_b12_wb           ? reg_idx_t'(12)
                    : array_ckpt_b11_wb           ? reg_idx_t'(11)
                    : array_ckpt_b10_wb           ? reg_idx_t'(10)
                    : common_dydx_wb              ? B_DYDX_IDX
                    : (fill_wb || pblt_wb_daddr || line_wb_daddr
                       || array_ckpt_b2_wb)        ? B_DADDR_IDX
                    : common_daddr_wb             ? B_DADDR_IDX
                    : (pblt_wb_saddr || line_wb_d || array_ckpt_b0_wb)
                                                  ? B_SADDR_IDX  // LINE d -> B0
                    : mmfm_pop_wr                ? mm_iter_idx
                    : (mv_load_ptr_wr || m2m_src_wr) ? decoded.rs_idx  // update pointer Rs
                    : ((is_mpy || is_div) && pair_wb_step) ? (decoded.rd_idx + 4'd1)  // pair low/rem -> Rd+1
                                                     : decoded.rd_idx;
  // EXGF (Exchange Field Definition) datapath. Per SPVU001A page 12-77:
  // Rd's low 6 bits swap with the F-selected FE:FS pair (1 + 5 bits)
  // in ST. Rd's upper 26 bits are cleared after the swap.
  //
  // Preserve the old Rd value captured at OPERAND_PREP so the exchange is
  // atomic even after the read selectors return to their live state.
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
      exgf_new_st[ST_FS1_HI:ST_FS1_LO] = dispatch_rs2_q[4:0];
      exgf_new_st[ST_FE1_BIT]          = dispatch_rs2_q[5];
    end else begin
      exgf_new_st[ST_FS0_HI:ST_FS0_LO] = dispatch_rs2_q[4:0];
      exgf_new_st[ST_FE0_BIT]          = dispatch_rs2_q[5];
    end
  end

  // ---- ADDXY / SUBXY datapath (XY-coordinate arithmetic) ------------------
  // Treat each register as two 16-bit halves: X = low 16, Y = high 16.
  // ADDXY/SUBXY operate on the halves independently, with NO carry/borrow
  // propagating between them. Rd is both a source and the destination;
  // rf_rs2_data delivers the old Rd, rf_rs1_data the Rs operand.
  //   ADDXY (SPVU001A 12-41):  N=(Xres==0), V=Xres[15], Z=(Yres==0), C=Yres[15].
  //   SUBXY (User's Guide 4-11/12-252): compare-style flags —
  //     N=(RsX==RdX), V=(RsX>RdX), Z=(RsY==RdY), C=(RsY>RdY), with
  //     signed 16-bit comparisons because X/Y are signed coordinates.
  logic [15:0] xy_rs_x, xy_rs_y, xy_rd_x, xy_rd_y;
  logic [15:0] xy_x_add, xy_y_add, xy_x_sub, xy_y_sub;
  logic [DATA_WIDTH-1:0] addxy_result, subxy_result;
  alu_flags_t            addxy_flags, subxy_flags;
  assign xy_rs_x = dispatch_rs1_q[15:0];
  assign xy_rs_y = dispatch_rs1_q[DATA_WIDTH-1:16];
  assign xy_rd_x = dispatch_rs2_q[15:0];
  assign xy_rd_y = dispatch_rs2_q[DATA_WIDTH-1:16];
  assign xy_x_add = xy_rd_x + xy_rs_x;     // 16-bit, carry dropped
  assign xy_y_add = xy_rd_y + xy_rs_y;
  assign xy_x_sub = xy_rd_x - xy_rs_x;     // Rd - Rs per spec
  assign xy_y_sub = xy_rd_y - xy_rs_y;
  assign addxy_result = {xy_y_add, xy_x_add};
  assign subxy_result = {xy_y_sub, xy_x_sub};
  assign addxy_flags = '{n: (xy_x_add == 16'd0), c: xy_y_add[15],
                          z: (xy_y_add == 16'd0), v: xy_x_add[15]};
  assign subxy_flags = '{
      n: (xy_x_sub == 16'd0),
      c: ($signed(xy_rs_y) > $signed(xy_rd_y)),
      z: (xy_y_sub == 16'd0),
      v: ($signed(xy_rs_x) > $signed(xy_rd_x))
  };
  // CMPXY (SPVU001A 12-55): nondestructive; flags use the sign bits of the
  // per-half subtract results, distinct from SUBXY's signed greater-than flags.
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
  assign cpw_pt_x = dispatch_rs1_q[15:0];
  assign cpw_pt_y = dispatch_rs1_q[DATA_WIDTH-1:16];
  assign cpw_ws_x = dispatch_rs2_q[15:0];     // WSTART.X (B5)
  assign cpw_ws_y = dispatch_rs2_q[DATA_WIDTH-1:16];
  assign cpw_we_x = dispatch_rs3_q[15:0];     // WEND.X (B6)
  assign cpw_we_y = dispatch_rs3_q[DATA_WIDTH-1:16];
  assign cpw_b5 = ($signed(cpw_ws_x) > $signed(cpw_pt_x));  // WSTART.X > Rs.X
  assign cpw_b6 = ($signed(cpw_pt_x) > $signed(cpw_we_x));  // Rs.X > WEND.X
  assign cpw_b7 = ($signed(cpw_ws_y) > $signed(cpw_pt_y));  // WSTART.Y > Rs.Y
  assign cpw_b8 = ($signed(cpw_pt_y) > $signed(cpw_we_y));  // Rs.Y > WEND.Y
  assign cpw_result = {{(DATA_WIDTH-9){1'b0}}, cpw_b8, cpw_b7, cpw_b6, cpw_b5, 5'b0};
  assign cpw_flags  = '{n: 1'b0, c: 1'b0, z: 1'b0,
                         v: (cpw_b5 | cpw_b6 | cpw_b7 | cpw_b8)};

  // ---- CVXYL (convert XY address to linear) datapath -----------------------
  // Pinned MAME CVXYL/DXYTOL: linear = (Y << ydp_shift) + (X << xsh) + OFFSET.
  // X = Rs[15:0] and Y = Rs[31:16] are signed. The screen pitch and
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
  // Sign-extend both coordinates before scaling. The contributions add:
  // their set bits can overlap (including every negative X coordinate).
  assign cvxyl_ypart  = {{16{dispatch_rs1_q[DATA_WIDTH-1]}}, dispatch_rs1_q[DATA_WIDTH-1:16]}
                        << cvxyl_ydp_shift;
  assign cvxyl_xpart  = {{16{dispatch_rs1_q[15]}}, dispatch_rs1_q[15:0]} << cvxyl_xsh;
  assign cvxyl_result = (cvxyl_ypart + cvxyl_xpart) + dispatch_rs3_q; // + OFFSET (B4)

  // ---- MPYS / MPYU multiply datapath (SPVU001A 12-164/12-166) -------------
  // Stage the register-file operands at DISPATCH, form the FS1 field at
  // EXECUTE, then let the DSP multiply settle in CORE_MPY before writeback.
  // This preserves the architectural result and pair-writeback ordering while
  // keeping RF selection and variable sign extension out of the multiplier
  // timing path. FS1=0 means the whole Rs register.
  logic                  is_mpy, mpy_signed, mpy_rd_even;
  logic signed [65:0]    mpy_shared_product;
  logic        [63:0]    mpy_product, mpy_product_q;
  logic [DATA_WIDTH-1:0] mpy_rs_raw_q, mpy_rd_raw_q;
  logic signed [DATA_WIDTH:0] mpy_operand_a_q, mpy_operand_b_q;
  logic [4:0]            mpy_fs1_q;
  logic                  mpy_signed_q;
  assign is_mpy      = (decoded.iclass == INSTR_MPYS) || (decoded.iclass == INSTR_MPYU);
  assign mpy_signed  = (decoded.iclass == INSTR_MPYS);
  assign mpy_rd_even = (decoded.rd_idx[0] == 1'b0);
  // Variable multiplier width: extract the low FS1 bits of Rs and
  // sign-extend (MPYS) or zero-extend (MPYU) to 32 bits before the multiply;
  // Rd (the multiplicand) stays full 32-bit.
  logic [4:0]            mpy_fs1;
  logic [DATA_WIDTH-1:0] mpy_fmask;
  logic [DATA_WIDTH-1:0] mpy_rs_field;
  assign mpy_fs1   = mpy_fs1_q;
  assign mpy_fmask = (32'd1 << mpy_fs1) - 32'd1;   // FS1 1..31; FS1=0 uses full Rs below
  always_comb begin
    if (mpy_fs1 == 5'd0) begin
      mpy_rs_field = mpy_rs_raw_q;                                   // FS1 = 32
    end else if (mpy_signed_q && mpy_rs_raw_q[mpy_fs1 - 5'd1]) begin
      mpy_rs_field = (mpy_rs_raw_q & mpy_fmask) | ~mpy_fmask;        // MPYS sign-extend
    end else begin
      mpy_rs_field = mpy_rs_raw_q & mpy_fmask;                       // zero-extend / positive
    end
  end
  // A single signed 33x33 multiplier supports both operations. The extra bit
  // is captured with each operand: sign extension for MPYS, zero for MPYU.
  assign mpy_shared_product = mpy_operand_a_q * mpy_operand_b_q;
  assign mpy_product = mpy_shared_product[63:0];

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
  logic [2*DATA_WIDTH-1:0] div_dividend, div_dividend_q;
  logic [DATA_WIDTH-1:0]   div_divisor, div_divisor_q;
  logic [DATA_WIDTH-1:0]   div_quotient, div_remainder;
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
  assign div_dvd_sign = is_signed_div && dispatch_rs2_q[DATA_WIDTH-1]; // Rd MSB
  assign div_dvs_sign = is_signed_div && dispatch_rs1_q[DATA_WIDTH-1]; // Rs MSB
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
  assign rd_abs = dispatch_rs2_q[DATA_WIDTH-1]
                ? (~dispatch_rs2_q + 1'b1) : dispatch_rs2_q;
  assign raw64  = {dispatch_rs2_q, dispatch_rs3_q};
  assign abs64  = dispatch_rs2_q[DATA_WIDTH-1] ? (~raw64 + 1'b1) : raw64;
  always_comb begin
    if (!is_signed_div)
      div_dividend = div_use_pair ? raw64 : {{DATA_WIDTH{1'b0}}, dispatch_rs2_q};
    else if (div_use_pair)
      div_dividend = abs64;                                // |{Rd, Rd+1}|
    else
      div_dividend = {{DATA_WIDTH{1'b0}}, rd_abs};         // {0, |Rd|}
  end
  assign div_divisor = div_dvs_sign ? (~dispatch_rs1_q + 1'b1) : dispatch_rs1_q;

  // Divide magnitudes and signs are prepared from the DISPATCH snapshots at
  // EXECUTE. Starting the iterative unit one state later keeps its overflow
  // comparison off the decoder/register-file/arithmetic path.
  always_ff @(posedge clk) begin
    if (rst) begin
      div_dividend_q <= '0;
      div_divisor_q  <= '0;
    end else if ((state_q == CORE_EXECUTE) && is_div) begin
      div_dividend_q <= div_dividend;
      div_divisor_q  <= div_divisor;
    end
  end

  // The core stages operands in EXECUTE, then starts from stable registers.
  assign div_start = (state_q == CORE_DIV_PREP);

  tms34010_divider u_divider (
    .clk       (clk),
    .rst       (rst),
    .start     (div_start),
    .dividend  (div_dividend_q),
    .divisor   (div_divisor_q),
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
  // DIV leaves its destination unchanged on overflow. MODU can overflow only
  // on divide-by-zero and is likewise suppressed. MODS is different: page
  // 12-112 says Rd is always overwritten, and a nonzero-divisor signed
  // quotient overflow still leaves a valid remainder. Only its divide-by-zero
  // case (reported by the divider's raw overflow) suppresses writeback.
  assign div_suppress_wb = is_div && div_v
                         && !(is_mods && !div_overflow);

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
      mpy_rs_raw_q  <= '0;
      mpy_rd_raw_q  <= '0;
      mpy_operand_a_q <= '0;
      mpy_operand_b_q <= '0;
      mpy_fs1_q     <= '0;
      mpy_signed_q  <= 1'b0;
      pair_wb_step  <= 1'b0;
    end else begin
      if (state_q == CORE_OPERAND_PREP && is_mpy) begin
        mpy_rs_raw_q <= rf_rs1_data;
        mpy_rd_raw_q <= rf_rs2_data;
        mpy_fs1_q    <= st_value[ST_FS1_HI:ST_FS1_LO];
        mpy_signed_q <= mpy_signed;
      end
      if (state_q == CORE_EXECUTE && is_mpy) begin
        mpy_operand_a_q <= {mpy_signed_q && mpy_rd_raw_q[DATA_WIDTH-1], mpy_rd_raw_q};
        mpy_operand_b_q <= {mpy_signed_q && mpy_rs_field[DATA_WIDTH-1], mpy_rs_field};
      end
      if (state_q == CORE_MPY) begin
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
  // A thermometer mask avoids the one-hot barrel shift followed by a
  // 32-bit subtract carry chain. FS=0 represents all 32 bits.
  genvar field_bit;
  generate
    for (field_bit=0; field_bit<DATA_WIDTH; field_bit=field_bit+1) begin : field_mask_bits
      if (field_bit == 0) begin : lowest
        assign field_mask[field_bit] = 1'b1;
      end else if (field_bit == DATA_WIDTH-1) begin : highest
        assign field_mask[field_bit] = (fs_selected == 5'd0);
      end else begin : middle
        assign field_mask[field_bit] = (fs_selected == 5'd0)
                                    || (fs_selected > 5'(field_bit));
      end
    end
  endgenerate
  always_comb begin
    if (fs_selected == 5'd0) begin
      // Field-size = 32: identity.
      field_msb   = dispatch_rs2_q[DATA_WIDTH-1];
      sext_result = dispatch_rs2_q;
      zext_result = dispatch_rs2_q;
    end else begin
      field_msb   = dispatch_rs2_q[fs_selected - 5'd1];
      sext_result = field_msb ? ((dispatch_rs2_q & field_mask) | ~field_mask)
                              :  (dispatch_rs2_q & field_mask);
      zext_result = dispatch_rs2_q & field_mask;
    end
  end

  // Capture the selected register-file operands after the registered read
  // selectors have had a full cycle to settle.
  always_ff @(posedge clk) begin
    if (rst) begin
      dispatch_rs1_q <= '0;
      dispatch_rs2_q <= '0;
      dispatch_rs3_q <= '0;
      mv_ptr_operand_q <= '0;
    end else if (state_q == CORE_OPERAND_PREP) begin
      dispatch_rs1_q <= rf_rs1_data;
      dispatch_rs2_q <= rf_rs2_data;
      dispatch_rs3_q <= rf_rs3_data;
      if (is_mv_store || (decoded.iclass == INSTR_MOVE_OFF_STORE))
        mv_ptr_operand_q <= rf_rs2_data;
      else if (is_mv_load || (decoded.iclass == INSTR_MOVE_OFF_LOAD))
        mv_ptr_operand_q <= mv_ptr;
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
    if (dispatch_rs1_q[i]) lmo_bit_pos = i[4:0];
    end
    if (dispatch_rs1_q == '0)
      lmo_result = '0;
    else
      lmo_result = {{(DATA_WIDTH-5){1'b0}}, ~lmo_bit_pos};
  end

  // Regfile write-data mux. Several "Rd ← something" instructions
  // bypass the ALU/shifter and route a different source:
  //   GETST  → ST value
  //   GETPC  → current PC value
  //   EXGPC  → current PC value (the other half of the swap)
  //   REV    → chip-revision constant (page 12-233)
  //   LMO_RR → priority-encoder result
  // Ordinary results are captured while the FSM is in CORE_EXECUTE. This
  // explicit boundary matches the multi-cycle contract: CORE_WRITEBACK
  // consumes a stable registered value instead of rebuilding a live
  // asynchronous-regfile/ALU path after the state and special read selectors
  // have moved on.
  logic [DATA_WIDTH-1:0] execute_wb_data;
  logic [DATA_WIDTH-1:0] execute_wb_data_q;
  logic [DATA_WIDTH-1:0] m2m_dst_new_q;

  always_comb begin
    unique case (decoded.iclass)
      INSTR_MOVX:   execute_wb_data =
          {dispatch_rs2_q[DATA_WIDTH-1:16], dispatch_rs1_q[15:0]};
      INSTR_MOVY:   execute_wb_data =
          {dispatch_rs1_q[DATA_WIDTH-1:16], dispatch_rs2_q[15:0]};
      INSTR_ADDXY:  execute_wb_data = addxy_result;
      INSTR_SUBXY:  execute_wb_data = subxy_result;
      INSTR_CPW:    execute_wb_data = cpw_result;
      INSTR_GETST:  execute_wb_data = st_value;
      INSTR_MOVE_FIELD_STORE,
      INSTR_MOVE_FIELD_LOAD:
                    execute_wb_data = mv_ptr_new;
      INSTR_MOVE_FIELD_M2M,
      INSTR_MOVE_OFF_M2M_PI,
      INSTR_MOVE_ABS_M2M_PI:
                    execute_wb_data = m2m_src_new;
      INSTR_CVXYL:  execute_wb_data = cvxyl_result;
      INSTR_GETPC,
      INSTR_EXGPC:  execute_wb_data = pc_value;
      INSTR_REV:    execute_wb_data = REV_VALUE;
      INSTR_LMO_RR: execute_wb_data = lmo_result;
      INSTR_SEXT:   execute_wb_data = sext_result;
      INSTR_ZEXT:   execute_wb_data = zext_result;
      INSTR_EXGF:   execute_wb_data = exgf_new_rd;
      default:      execute_wb_data =
          decoded.use_shifter ? shifter_result : alu_result;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      execute_wb_data_q <= '0;
      m2m_dst_new_q     <= '0;
    end else if (state_q == CORE_EXECUTE) begin
      execute_wb_data_q <= execute_wb_data;
      m2m_dst_new_q     <= m2m_dst_new;
    end
  end

  // Later multi-cycle engines override the registered ordinary result with
  // their own registered/memory response. The default is the execution-stage
  // result above.
  always_comb begin
    if (int_sp_wb) begin
      // Interrupt entry: SP <- SP - 64 (two 32-bit pushes complete).
      rf_wr_data = rf_sp - WORD_BIT_SIZE_2;
    end else if (array_ckpt_b0_wb) begin
      rf_wr_data = array_ckpt_saddr;
    end else if (array_ckpt_b2_wb) begin
      rf_wr_data = array_ckpt_daddr;
    end else if (array_ckpt_b10_wb) begin
      rf_wr_data = array_ckpt_cursor;
    end else if (array_ckpt_b11_wb) begin
      rf_wr_data = array_ckpt_dims;
    end else if (array_ckpt_b12_wb) begin
      rf_wr_data = array_ckpt_b12_data;
    end else if (array_ckpt_b13_wb) begin
      rf_wr_data = array_ckpt_b13_data;
    end else if (array_ckpt_b14_wb) begin
      rf_wr_data = array_ckpt_b14_data;
    end else if (fill_w1_daddr_wb) begin
      rf_wr_data = fill_common_daddr;
    end else if (fill_w1_dydx_wb) begin
      rf_wr_data = fill_common_dydx;
    end else if (pblt_w1_daddr_wb) begin
      rf_wr_data = pblt_common_daddr;
    end else if (pblt_w1_dydx_wb) begin
      rf_wr_data = pblt_common_dydx;
    end else
    unique case (rf_wb_source_q)
      RF_WB_DRAV: rf_wr_data = drav_advance;   // Rd advanced by Rs (XY add)
      // MPYS/MPYU: even Rd -> hi32 then (Rd+1) lo32; odd Rd -> lo32.
      RF_WB_MPY:   rf_wr_data = mpy_rd_even
                               ? (pair_wb_step ? mpy_product_q[31:0] : mpy_product_q[63:32])
                               : mpy_product_q[31:0];
      // DIVU: even Rd -> quotient (pass 0), remainder -> Rd+1 (pass 1);
      // odd Rd -> quotient. (Skipped entirely on overflow via rf_wr_en.)
      // DIVU/DIVS: even Rd -> quotient (pass 0), remainder -> Rd+1 (pass 1);
      // odd Rd -> quotient. div_quot_out/div_rem_out are sign-conditioned
      // (identity for the unsigned variants).
      RF_WB_DIV:   rf_wr_data = (div_rd_even && pair_wb_step) ? div_rem_out
                                                              : div_quot_out;
      // MODU/MODS: the remainder of Rd mod Rs -> Rd (single writeback).
      RF_WB_MOD:   rf_wr_data = div_rem_out;
      RF_WB_MMTM:  rf_wr_data = mm_rp_q;       // final Rp = address of last push
      // MMFM: per-iteration pop writes mem_rdata_eff to the popped register;
      // the WRITEBACK pass writes final Rp (= initial + 32*count).
      RF_WB_MMFM:  rf_wr_data = mmfm_pop_wr ? mem_rdata_eff : mm_rp_q;
      // MOVE *Rs,Rd: Rd <- the 32 bits read from mem[Rs]. mem_rdata_eff still
      // holds the value at WRITEBACK (no new transaction is issued there).
      // Store inc/dec writes the auto-updated pointer back to Rd at
      // WRITEBACK (plain store has wb_reg_en=0, so this is unused there).
      RF_WB_MOVE_STORE: rf_wr_data = execute_wb_data_q;
      // Load: at WRITEBACK -> the field-extended data to Rd; during
      // CORE_MEMORY (inc/dec) -> the updated pointer to Rs.
      RF_WB_MOVE_LOAD:
          rf_wr_data = mv_load_ptr_wr ? execute_wb_data_q : mv_load_data_q;
      // Indirect-to-indirect inc/dec: source pointer Rs (step-0 ack) or
      // destination pointer Rd (WRITEBACK).
      RF_WB_MOVE_M2M:
          rf_wr_data = m2m_src_wr ? execute_wb_data_q : m2m_dst_new_q;
      // MOVE @SAddr,Rd: Rd <- the field-extended value read from the
      // absolute address. MOVE *Rs(off),Rd: same, from the offset address.
      RF_WB_ABS_OFF_LOAD: rf_wr_data = mv_load_data_q;
      RF_WB_FILL: rf_wr_data = fill_result_q;
      RF_WB_PIXBLT: rf_wr_data = pblt_wb_saddr ? pblt_src_result_q   // SADDR -> B0
                                                  : pblt_dst_result_q;  // DADDR -> B2
      RF_WB_LINE:   rf_wr_data = line_wb_d     ? line_d_q      // d -> B0
                               : line_wb_daddr  ? line_daddr_q  // DADDR -> B2
                                                : line_count_q; // COUNT -> B10
      default:      rf_wr_data = execute_wb_data_q;
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
  // OPERAND_PREP reads the registered selectors; all other states use the
  // snapshots captured at the end of that preparation cycle.
  // ALU operands always come from the snapshots captured at the end of
  // OPERAND_PREP; CORE_BTST_PREP is the cycle that forms them into alu_a/alu_b,
  // so the register-file read never shares a cycle with the ALU operand mux.
  assign alu_rs1_operand = dispatch_rs1_q;
  assign alu_rs2_operand = dispatch_rs2_q;
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
      INSTR_BTST_RR: alu_a = alu_rs2_operand; // Rd is the operand
      INSTR_NEGB:    alu_a = '0;            // NEGB: 0 - Rd - C via SUBB
      INSTR_PUSHST,
      INSTR_POPST,
      INSTR_CALL_RS,
      INSTR_CALLA,
      INSTR_CALLR,
      INSTR_RETS,
      INSTR_RETI,
      INSTR_TRAP:    alu_a = alu_rs2_operand; // SP via rs2 (rd_idx=15)
      default:       alu_a = alu_rs1_operand; // Rs (or unused for MOVI/MOVK)
    endcase
  end
  always_comb begin
    unique case (decoded.iclass)
      INSTR_MOVI_IW,
      INSTR_MOVI_IL,
      INSTR_ADDI_IW,
      INSTR_ADDI_IL,
      INSTR_ANDI_IL,
      INSTR_ORI_IL,
      INSTR_XORI_IL: alu_b = imm32;
      // SUBI and CMPI carry the one's complement of the source-level
      // immediate. TI's assembler, disassembler, and shipped C workloads
      // all use this object-code encoding for both IW and IL forms.
      INSTR_SUBI_IW,
      INSTR_SUBI_IL,
      INSTR_CMPI_IW,
      INSTR_CMPI_IL: alu_b = ~imm32;
      INSTR_MOVK,
      INSTR_ADDK,
      INSTR_SUBK:   alu_b = (decoded.k5 == 5'd0)
                          ? K_ZERO_VALUE
                          : {{(DATA_WIDTH-5){1'b0}}, decoded.k5};
      INSTR_DSJ,
      INSTR_DSJEQ,
      INSTR_DSJNE,
      INSTR_DSJS:    alu_b = {{(DATA_WIDTH-5){1'b0}}, decoded.k5};
      INSTR_BTST_K:  alu_b = 32'd1 << decoded.k5;
      INSTR_BTST_RR: alu_b = 32'd1 << alu_rs1_operand[4:0];
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
      INSTR_CMP_RR:  alu_b = alu_rs1_operand; // Rs is the "second" operand
      default:       alu_b = alu_rs2_operand;
    endcase
  end
  assign alu_cin = st_c;

  // The alu_b selector already carries the one's complement for SUBI/CMPI
  // (MAME subi/cmpi: Rd - ~word); capture it unchanged.
  assign alu_b_capture = alu_b;

  // Register ALU operands on the edge leaving OPERAND_PREP via BTST_PREP.
  // This keeps instruction decode and register-file selection out of the
  // execute-stage ALU carry/result cone.
  always_ff @(posedge clk) begin
    if (rst) begin
      alu_op_q  <= ALU_OP_ADD;
      alu_a_q   <= '0;
      alu_b_q   <= '0;
      alu_cin_q <= 1'b0;
    end else if ((state_q != CORE_EXECUTE) && (state_d == CORE_EXECUTE)) begin
      alu_op_q  <= alu_op;
      alu_a_q   <= alu_a;
      alu_b_q   <= alu_b_capture;
      alu_cin_q <= alu_cin;
    end
  end

  // Status-register inputs. Flag-update is gated by FSM state, like the
  // regfile write. Full ST write port is unused until POPST lands.
  assign st_flag_update_en = ((state_q == CORE_WRITEBACK) && decoded.wb_flags_en)
                           || fill_win_flag_wb;
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
  logic                  array_pbx_complete;
  assign array_pbx_complete = st_value[ST_PBX_BIT]
                           && (((state_q == CORE_FILL_WB) && is_fill)
                               || ((state_q == CORE_PBLT_WB2) && is_pblt));
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

  assign st_write_en = ((state_q == CORE_WRITEBACK)
                    && ((decoded.iclass == INSTR_PUTST) ||
                        (decoded.iclass == INSTR_SETF)  ||
                        (decoded.iclass == INSTR_EXGF)  ||
                        (decoded.iclass == INSTR_DINT)  ||
                        (decoded.iclass == INSTR_EINT)  ||
                        (decoded.iclass == INSTR_POPST) ||
                        (decoded.iclass == INSTR_RETI)  ||
                        (decoded.iclass == INSTR_TRAP)))
                    || (state_q == CORE_INT_DONE)
                    || array_pbx_complete;
  always_comb begin
    if (state_q == CORE_INT_DONE) begin
      // 1988 User's Guide §8.5 page 8-6, step 3: every interrupt installs
      // the fresh service-context value (IE=0, FS0=16, FS1=32, FE/flags=0).
      // NMIM controls stacking only; NMIM=1 still receives this live ST.
      st_write_data = ST_RESET_VALUE;
    end else if (array_pbx_complete) begin
      // PBX remains live while a resumed operation is again interruptible,
      // then clears atomically at successful completion. A resumed W=3
      // operation also publishes its reconstructed V result on this edge;
      // the full write has priority over the parallel flag-only port.
      st_write_data = st_value;
      st_write_data[ST_PBX_BIT] = 1'b0;
      if ((is_fill && fill_win_en_q) || (is_pblt && pblt_win_en_q))
        st_write_data[ST_V_BIT] = fill_win_violation;
    end else
    unique case (decoded.iclass)
      INSTR_PUTST: st_write_data = dispatch_rs1_q;
      INSTR_SETF:  st_write_data = setf_new_st;
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
      CC_P:    branch_taken = !st_n & !st_z;           // positive
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
          pc_load_value = {dispatch_rs1_q[ADDR_WIDTH-1:4], 4'h0};
        end
        INSTR_EXGPC: begin
          // Atomic swap PC ↔ Rd: PC ← old Rd with its bottom 4 bits forced
          // to 0 per page 12-79, Rd ← next PC via the mux above.
          // dispatch_rs2_q is the old Rd value captured before execution.
          pc_load_en    = 1'b1;
          pc_load_value = {dispatch_rs2_q[ADDR_WIDTH-1:4], 4'h0};
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
          pc_load_value = {dispatch_rs1_q[ADDR_WIDTH-1:4], 4'h0};
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
          // Return from subroutine: PC <- popped value (= mem_rdata_eff,
          // which the memory model still holds after the ack since it
          // doesn't clear on IDLE). The popped value is already
          // word-aligned (since it was pushed by a CALL/CALLA/CALLR
          // or TRAP), so no bottom-nibble mask is needed.
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
    end else if (state_q == CORE_RESET && !rst && mem_ack_eff) begin
      // Load the level-0 vector on the same acknowledged transaction that
      // retires CORE_RESET. The first CORE_FETCH therefore observes the
      // architectural reset-service-routine address.
      pc_load_en    = 1'b1;
      pc_load_value = mem_rdata_eff;
    end else if (state_q == CORE_INT_DONE) begin
      // Interrupt entry: load PC with the trap vector (ISR entry address),
      // latched into popped_pc_q on the CORE_INT_VECTOR ack. Already word-
      // aligned (it is a vector word), so no bottom-nibble mask.
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
  // 16-bit; a legal field may span three adjacent register words.
  logic                  io_is_io;
  logic                  io_fast_field;
  logic                  io_full_field;
  logic [ADDR_WIDTH-1:0] io_decode_addr;
  logic                  io_decode_is_io;
  logic                  pblt_reverse_src_io, pblt_reverse_dst_io;
  logic [6:0]            io_field_remaining;
  logic [6:0]            io_psize_remaining_q;
  logic [6:0]            mv_io_field_remaining;
  // Only wholly internal fields use the parallel register window. Mixed
  // fields retain normal field sequencing and classify each physical word.
  // A six-bit field size cannot cross the end of the 512-bit page unless
  // its address is in the final 64 bits. Select 64-size with the request
  // size below, keeping a second carry chain out of the address/decode cone.
  assign mv_io_field_remaining = decoded.force_byte ? 7'd56
      : decoded.force_pixel ? io_psize_remaining_q
      : (mv_fs_raw == 5'd0) ? 7'd32
      : 7'd64 - {2'b0, mv_fs_raw};
  // The narrow parallel payload is valid only for MOVE-family writers.
  // Stack, multiple-register and graphics stores use the word sequencer's
  // full architectural payload. Decode eligibility before request capture,
  // and require CORE_MEMORY so an interrupt cannot reuse a stale MOVE class.
  logic io_narrow_writer_q;
  always_ff @(posedge clk) begin
    if (rst) io_narrow_writer_q <= 1'b0;
    else if (state_q == CORE_DECODE_WAIT) begin
      unique case (decoded_comb.iclass)
        INSTR_MOVE_FIELD_STORE, INSTR_MOVE_OFF_STORE, INSTR_MOVE_ABS_STORE,
        INSTR_MOVE_FIELD_M2M, INSTR_MOVE_OFF_M2M_PI, INSTR_MOVE_ABS_M2M_PI,
        INSTR_MOVB_OFF_M2M, INSTR_MOVB_ABS_M2M,
        INSTR_MOVE_OFF_M2M, INSTR_MOVE_ABS_M2M: io_narrow_writer_q <= 1'b1;
        default: io_narrow_writer_q <= 1'b0;
      endcase
    end
  end
  // Reverse pixels address end-width. Classify that interval directly from
  // its registered end so the full address subtractor is not before decode.
  // The next page contributes only an end exactly at the I/O page boundary.
  function automatic logic reverse_pixel_io_field(
      input logic [ADDR_WIDTH-1:0] end_addr,
      input logic [FIELD_SIZE_WIDTH-1:0] width);
    reverse_pixel_io_field =
        ((end_addr[ADDR_WIDTH-1:9] == 23'h600000)
          && (end_addr[8:0] >= {{(9-FIELD_SIZE_WIDTH){1'b0}}, width}))
        || ((end_addr[ADDR_WIDTH-1:9] == 23'h600001)
          && (end_addr[8:0] == 9'd0) && (width != '0));
  endfunction
  assign pblt_reverse_src_io = reverse_pixel_io_field(pblt_src_addr_q,
      decoded.blt_binary ? FIELD_SIZE_WIDTH'(1)
                         : io_psize[FIELD_SIZE_WIDTH-1:0]);
  assign pblt_reverse_dst_io = reverse_pixel_io_field(pblt_dst_addr_q,
      io_psize[FIELD_SIZE_WIDTH-1:0]);
  // This address mux uses registered PBLT ends in both directions.
  // Keep the reverse subtractor outside every I/O classification arm.
  assign io_decode_is_io = io_decode_addr[ADDR_WIDTH-1:9] == 23'h600000;
  assign io_full_field = ((state_q == CORE_PBLT) && pblt_hrev_q)
      ? ((pblt_substep_q == 3'd0) ? pblt_reverse_src_io : pblt_reverse_dst_io)
      : (io_decode_is_io && ((io_decode_addr[8:6] != 3'b111)
                     || ({1'b0, io_decode_addr[5:0]} <= io_field_remaining)));
  assign io_fast_field = io_full_field && (!mem_we_int
                           || ((state_q == CORE_MEMORY) && io_narrow_writer_q));
  logic [15:0]           io_rdata16;
  logic [DATA_WIDTH+LOCAL_WORD_WIDTH-1:0] io_fast_rdata_words;
  logic [15:0]           io_psize;     // PSIZE register (pixel size, for PIXT/CVXYL)
  logic [15:0]           io_convdp;    // CONVDP register (XY->linear dest pitch)
  logic [15:0]           io_convsp;    // CONVSP register (XY->linear source pitch)
  logic [15:0]           io_control;   // CONTROL register (PPOP, T, window mode, ...)
  logic [15:0]           io_pmask;     // PMASK register (plane mask)
  // The pixel-configuration registers are consumed by the pixel engines through
  // registered shadows, so no I/O-register flop drives the request/decode
  // cones directly. The shadows lag the I/O register by one clock; a pixel
  // operation cannot start until a fetch acknowledge, CORE_DECODE and
  // CORE_DECODE_WAIT have passed after the write that changed them.
  logic [15:0]           io_psize_live, io_convdp_live, io_convsp_live;
  logic [15:0]           io_control_live, io_pmask_live;
  always_ff @(posedge clk) begin
    if (rst) begin
      io_psize <= '0; io_convdp <= '0; io_convsp <= '0;
      io_control <= '0; io_pmask <= '0;
      io_psize_remaining_q <= 7'd64;
    end else begin
      io_psize <= io_psize_live; io_convdp <= io_convdp_live;
      io_convsp <= io_convsp_live; io_control <= io_control_live;
      io_pmask <= io_pmask_live;
      io_psize_remaining_q <= 7'd64
                           - {1'b0, io_psize_live[FIELD_SIZE_WIDTH-1:0]};
    end
  end
  logic                  io_pixel_srt; // DPYCTL.SRT program-controlled VRAM transfer
  logic [15:0]           io_intenb;    // INTENB register (maskable-interrupt enables)
  logic [15:0]           io_intpend;   // INTPEND register (maskable-interrupt pending)
  logic [15:0]           io_hstctlh;   // HSTCTLH register (host control; NMI/NMIM bits)
  logic                  io_hlt;       // HSTCTLH.HLT, sampled at instruction boundaries
  logic                  nmi_clear;    // pulse to clear HSTCTLH.NMI on taking the NMI
  logic                  wvp_set;      // pulse to set INTPEND.WV on a window violation
  logic [DATA_WIDTH-1:0] mem_rdata_eff;
  logic                  mem_we_int;   // the FSM's write intent (pre-I/O gating)
  // Write intent held with the request, like io_access_addr_q. The fabric
  // cannot acknowledge in the cycle a request first appears, so at the
  // acknowledge this equals the live intent; it keeps the FSM's write-intent
  // mux out of the I/O register write enables.
  logic                  io_request_we_q;
  tms34010_io_regs u_io_regs (
    .clk      (clk),
    .vclk_i   (vclk_i),
    .rst      (rst),
    .vclk_rst_i(vclk_rst_i),
    .video_hsync_n_i(video_hsync_n_i),
    .video_vsync_n_i(video_vsync_n_i),
    .hcs_n_i  (hcs_n_i),
    .host_req_i(host_req_i),
    .host_we_i(host_we_i),
    .host_reg_i(host_reg_i),
    .host_be_i(host_be_i),
    .host_wdata_i(host_wdata_i),
    .host_rdata_o(host_rdata_o),
    .host_ack_o(host_ack_o),
    .host_busy_o(host_busy_o),
    .hint_n_o (hint_n_o),
    .hlt_o    (io_hlt),
    .host_mem_req_o(host_mem_req_o),
    .host_mem_we_o(host_mem_we_o),
    .host_mem_addr_o(host_mem_addr_o),
    .host_mem_wdata_o(host_mem_wdata_o),
    .host_mem_is_io_o(host_mem_is_io_o),
    .host_mem_io_rdata_o(host_mem_io_rdata_o),
    .host_mem_rdata_i(host_mem_rdata_i),
    .host_mem_ack_i(host_mem_ack_i),
    // An acknowledge only ever answers the core's outstanding request, and
    // the write intent/address the I/O block uses are the registered copies
    // of that request, so the live mem_req_int mux is not needed here.
    .req      ((mem_ack_eff && io_is_io_q) || mem_word_io_ack),
    .we       (mem_word_io_req ? mem_word_io_we : io_request_we_q),
    .addr     (io_fast_addr),
    .req_addr_i(mem_word_io_req ? mem_word_io_addr : io_fast_addr),
    .wdata    (mem_word_io_req ? mem_word_io_wdata : io_write_data_q),
    .req_next_i(io_write_next_q && !mem_word_io_req),
    .req_next_addr_i(io_next_addr_q),
    .wdata_next_i(io_write_data_next_q),
    .req_third_i(io_write_third_q && !mem_word_io_req),
    .req_third_addr_i(io_third_addr_q),
    .wdata_third_i(io_write_data_third_q),
    .rdata    (io_rdata16),
    .rdata_next(),
    .rdata_third(),
    .field_rdata_o(io_fast_rdata_words),
    .is_io    (io_is_io),
    .psize_o  (io_psize_live),
    .convdp_o (io_convdp_live),
    .convsp_o (io_convsp_live),
    .control_o(io_control_live),
    .pmask_o  (io_pmask_live),
    .pixel_srt_o(io_pixel_srt),
    .intenb_o (io_intenb),
    .intpend_o(io_intpend),
    .hstctlh_o(io_hstctlh),
    .refcnt_o (),
    .refresh_req_o(refresh_req_o),
    .refresh_row_o(refresh_row_o),
    .refresh_cbr_o(refresh_cbr_o),
    .hcount_o (),
    .vcount_o (),
    .video_hsync_o(video_hsync_o),
    .video_vsync_o(video_vsync_o),
    .video_hblank_o(video_hblank_o),
    .video_vblank_o(video_vblank_o),
    .video_blank_o(video_blank_o),
    .video_hsync_oe_o(video_hsync_oe_o),
    .video_vsync_oe_o(video_vsync_oe_o),
    .dpyadr_o (),
    .screen_refresh_req_o(screen_refresh_req_o),
    .screen_refresh_ack_i(screen_refresh_ack_i),
    .screen_refresh_srfaddr_o(screen_refresh_srfaddr_o),
    .screen_refresh_dpytap_o(screen_refresh_dpytap_o),
    .screen_refresh_org_o(screen_refresh_org_o),
    .nmi_clear(nmi_clear),
    .wvp_set  (wvp_set),
    .dpyint_set(dpyint_set_i),
    .lint1_n_i(lint1_n_i),
    .lint2_n_i(lint2_n_i)
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
  // Any interrupt is taken at the fetch boundary when NMI is pending or a
  // maskable request is asserted.
  logic int_take;
  assign int_take = nmi_req || int_req;

  // Latched state for the entry sequence (captured at a legal boundary):
  //   int_vec_q    — the trap-vector address to fetch.
  //   int_is_nmi_q  — this entry is an NMI (drives the auto-clear).
  //   int_push_q    — context is pushed (always for maskable/illegal;
  //                   NMIM=0 for NMI).
  //   int_rewind_q — push the current single-word instruction address.
  //   int_pbx_q    — set PBX in the stacked ST copy (FILL/PIXBLT only).
  // nmi_clear pulses in CORE_INT_DONE when the latched entry was an NMI.
  logic [ADDR_WIDTH-1:0] int_vec_q;
  logic                  int_is_nmi_q;
  logic                  int_push_q;
  logic                  int_rewind_q;
  logic                  int_pbx_q;
  logic [ADDR_WIDTH-1:0] int_stack_pc;
  logic [DATA_WIDTH-1:0] int_stack_st;
  assign int_stack_pc = int_rewind_q
                      ? pc_value - ADDR_WIDTH'(INSTR_WORD_BITS) : pc_value;
  always_comb begin
    int_stack_st = st_value;
    if (int_pbx_q) int_stack_st[ST_PBX_BIT] = 1'b1;
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      int_vec_q    <= '0;
      int_is_nmi_q <= 1'b0;
      int_push_q   <= 1'b0;
      int_rewind_q <= 1'b0;
      int_pbx_q    <= 1'b0;
    end else if (array_checkpoint && int_take) begin
      // The checkpoint image and this capture commit on the same edge.
      // Re-enter the one-word array opcode after RETI and mark only its
      // stacked ST copy as a PixBlt-executing context.
      int_vec_q    <= nmi_req ? INT_VEC_NMI : int_vector;
      int_is_nmi_q <= nmi_req;
      int_push_q   <= nmi_req ? !nmi_nmim : 1'b1;
      int_rewind_q <= 1'b1;
      int_pbx_q    <= 1'b1;
    end else if (line_checkpoint && int_take) begin
      // LINE's three-word B checkpoint is directly consumable by the normal
      // setup sequence after RETI refetches the one-word opcode. PBX remains
      // reserved for FILL/PIXBLT.
      int_vec_q    <= nmi_req ? INT_VEC_NMI : int_vector;
      int_is_nmi_q <= nmi_req;
      int_push_q   <= nmi_req ? !nmi_nmim : 1'b1;
      int_rewind_q <= 1'b1;
      int_pbx_q    <= 1'b0;
    end else if (state_q == CORE_FETCH && int_take) begin
      int_vec_q    <= nmi_req ? INT_VEC_NMI : int_vector;
      int_is_nmi_q <= nmi_req;
      int_push_q   <= nmi_req ? !nmi_nmim : 1'b1;   // NMIM=1 ⇒ no push
      int_rewind_q <= 1'b0;
      int_pbx_q    <= 1'b0;
    end else if (state_q == CORE_DISPATCH && decoded.illegal_trap) begin
      // 1988 User's Guide §8.7: an illegal opcode is an unmaskable
      // TRAP-30-equivalent event. PC already points past the illegal word.
      int_vec_q    <= INT_VEC_ILLOP;
      int_is_nmi_q <= 1'b0;
      int_push_q   <= 1'b1;
      int_rewind_q <= 1'b0;
      int_pbx_q    <= 1'b0;
    end
  end
  assign nmi_clear = (state_q == CORE_INT_DONE) && int_is_nmi_q;
  // Gate the ordinary external-memory write for I/O-space accesses: an I/O
  // write commits into u_io_regs and must not also write RAM. The original
  // write intent, on-chip read data, and decode sideband instead let the
  // memory fabric issue the special RAS/LAL-only I/O cycle. u_io_regs receives
  // a one-clock completion-qualified request, so held memory waits cannot
  // repeat a processor write or live-register load.
  assign mem_we = mem_we_int && !io_fast_field;
  // DPYCTL.SRT converts only graphics pixel accesses. Instruction fetches,
  // stack/data moves, host traffic, and on-chip I/O retain their ordinary
  // cycle types. The registered memory-fabric ingress captures this sideband
  // with the complete architectural request before arbitration.
  assign mem_srt = mem_req_int && io_pixel_srt && !io_fast_field
                && ((state_q == CORE_DRAV)
                    || (state_q == CORE_LINE_DRAW)
                    || (state_q == CORE_FILL)
                    || (state_q == CORE_PBLT)
                    || ((state_q == CORE_MEMORY) && decoded.force_pixel));
  assign mem_is_io    = io_fast_field;
  assign mem_io_we    = mem_we_int;
  assign mem_io_rdata = io_rdata16;

  // Effective read data. The external memory path holds mem_rdata through
  // WRITEBACK, but the asynchronous I/O read follows the live address. The
  // integrated fabric cannot acknowledge before its registered ingress has
  // accepted a request, so snapshot I/O classification, read data, completion
  // address, and write data on the held request. Completion and WRITEBACK then
  // consume only these stable values rather than rebuilding a long live
  // core/register/I/O mux path.
  logic mem_req_int, mem_ack_eff;
  logic io_window_valid_q, io_data_valid_q;
  logic io_ack_pending_q;

  // Snapshot the native words when this request wins the local bus, after any
  // earlier host-indirect write. Alignment consumes that snapshot on the next
  // edge. Readiness remains asserted until completion, and the fabric retains
  // CPU ownership until ready so the register commit precedes any host grant.
  // Retaining an early completion here also supports a direct core responder.
  assign mem_req = mem_req_int && !io_ack_pending_q;
  assign mem_io_ready = io_data_valid_q;
  assign mem_ack_eff = (mem_ack || io_ack_pending_q)
                    && (!io_is_io_q || io_data_valid_q);
  always_ff @(posedge clk) begin
    if (rst || mem_ack_eff) begin
      io_window_valid_q <= 1'b0;
      io_data_valid_q <= 1'b0;
      io_ack_pending_q <= 1'b0;
    end else begin
      if (mem_io_grant && io_is_io_q) io_window_valid_q <= 1'b1;
      if (io_window_valid_q) io_data_valid_q <= 1'b1;
      if (mem_ack && io_is_io_q && !io_data_valid_q)
        io_ack_pending_q <= 1'b1;
    end
  end

  logic [DATA_WIDTH-1:0] io_rdata_q;
  logic        io_is_io_q;
  // Private copy of io_is_io_q for the mem_rdata_eff select only; the original
  // fans out to 30+ loads and sat at the head of the register write-back cone
  // (timing closure at the slow corner).
  (* preserve, dont_merge *) logic io_is_io_rd_q;
  // A qualified parallel field is wholly inside the 512-bit I/O page.
  // Hold its offset and a private page qualifier instead of carrying a
  // full address through the next/third-word adders and page comparators.
  // The sequenced-word port above retains its full architectural address.
  (* preserve, dont_merge *) logic io_page_view_q;
  logic [8:0] io_access_addr_q;
  logic [ADDR_WIDTH-1:0] io_fast_addr;
  logic [9:0] io_next_word_offset, io_third_word_offset;
  logic [15:0] io_write_data_q;
  logic        io_write_next_q;
  logic        io_write_third_q;
  logic [ADDR_WIDTH-1:0] io_next_addr_q;
  logic [ADDR_WIDTH-1:0] io_third_addr_q;
  logic [DATA_WIDTH-1:0] move_off_addr_q;
  logic [15:0] io_write_data_next_q;
  logic [15:0] io_write_data_third_q;
  logic [FIELD_SIZE_WIDTH-1:0] io_request_size_q;
  logic [DATA_WIDTH-1:0] io_request_wdata_q;
  // The parallel I/O path accepts only MOVE-class stores. io_wdata is a narrow
  // subset of mem_wdata (stack/PC pushes and the pixel engines are excluded), so
  // the I/O payload flops do not sit behind the full write-data mux.
  logic [DATA_WIDTH-1:0] io_wdata;
  logic [DATA_WIDTH+LOCAL_WORD_WIDTH-1:0] io_rdata_words_q;
  logic [5:0]  io_field_width;
  logic [DATA_WIDTH-1:0] io_field_mask;
  logic [DATA_WIDTH-1:0] io_field_rdata;
  logic [DATA_WIDTH+LOCAL_WORD_WIDTH-1:0] io_field_wdata;
  logic [DATA_WIDTH+LOCAL_WORD_WIDTH-1:0] io_rdata_words;
  assign io_fast_addr = {io_page_view_q ? 23'h600000 : 23'h000000,
                         io_access_addr_q};
  // Keep bit 9 of each narrow sum: a following word beyond C00001FF must
  // still decode outside I/O, rather than wrapping onto register zero.
  assign io_next_word_offset = {1'b0, io_access_addr_q[8:4], 4'b0000}
                             + 10'd16;
  assign io_third_word_offset = {1'b0, io_access_addr_q[8:4], 4'b0000}
                              + 10'd32;
  assign io_next_addr_q = {io_page_view_q ? 22'h300000 : 22'h000000,
                          io_next_word_offset};
  assign io_third_addr_q = {io_page_view_q ? 22'h300000 : 22'h000000,
                           io_third_word_offset};
  always_comb begin
    // On-chip registers are 16-bit words in the processor's bit-addressed
    // space. A MOVE may address a subfield (for example CONTROL+5 with
    // FS=10), so present a right-justified read field and merge writes into
    // the addressed bits exactly as the external field sequencer would.
    io_rdata_words = io_rdata_words_q;
    io_field_width = io_request_size_q;
    io_field_mask = (io_field_width >= 6'd32)
                  ? 32'hFFFF_FFFF
                  : (32'h0000_0001 << io_field_width) - 32'h0000_0001;
    io_field_rdata =
        DATA_WIDTH'(io_rdata_words >> io_access_addr_q[3:0]) & io_field_mask;
    io_field_wdata =
        (io_rdata_words & ~({{LOCAL_WORD_WIDTH{1'b0}}, io_field_mask}
                            << io_access_addr_q[3:0]))
      | ({{LOCAL_WORD_WIDTH{1'b0}}, (io_request_wdata_q & io_field_mask)}
          << io_access_addr_q[3:0]);
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      io_rdata_q       <= '0;
      io_is_io_q       <= 1'b0;
      io_is_io_rd_q    <= 1'b0;
      io_page_view_q   <= 1'b0;
      io_access_addr_q <= '0;
      io_write_data_q  <= '0;
      io_write_next_q  <= 1'b0;
      io_write_third_q <= 1'b0;
      io_write_data_next_q <= '0;
      io_write_data_third_q <= '0;
      io_request_size_q <= '0;
      io_request_we_q  <= 1'b0;
      io_request_wdata_q <= '0;
      io_rdata_words_q <= '0;
    end else begin
      // The integrated memory fabric registers every request before it can
      // acknowledge it. First hold the raw processor request at the core
      // boundary. The I/O read view below is sampled from this registered
      // address on the following cycle.
      if (mem_req_int) begin
        io_is_io_q       <= io_fast_field;
        io_is_io_rd_q    <= io_fast_field;
        io_page_view_q   <= io_fast_field;
        io_access_addr_q <= mem_addr[8:0];
        io_request_size_q <= mem_size;
        io_request_we_q  <= mem_we_int;
        io_request_wdata_q <= io_wdata;
      end
      if (mem_io_grant && io_is_io_q)
      io_rdata_words_q <= io_fast_rdata_words;
      // Align/merge the granted snapshot using only registered operands. The
      // snapshot stays fixed until the next grant, including across wait
      // states, so an internal producer cannot refresh preserved RMW bits.
      // Completion readiness brackets this pipeline without restoring the
      // decode/register-file/address-mux path into the write payload flops.
      if (io_is_io_q) begin
        io_rdata_q       <= io_field_rdata;
        io_write_data_q  <= io_field_wdata[15:0];
        io_write_next_q  <=
            ({2'b0, io_access_addr_q[3:0]} + io_request_size_q)
            > FIELD_SIZE_WIDTH'(16);
        io_write_data_next_q <= io_field_wdata[31:16];
        io_write_third_q <=
            ({2'b0, io_access_addr_q[3:0]} + io_request_size_q)
            > FIELD_SIZE_WIDTH'(32);
        io_write_data_third_q <= io_field_wdata[47:32];
      end
    end
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      move_off_addr_q <= '0;
    end else if (state_q == CORE_EXECUTE) begin
      // Both operands are flops here: the pointer is captured at OPERAND_PREP,
      // after the offset fetch, and imm32 is the registered sign-extended word.
      move_off_addr_q <= mv_ptr_operand_q + imm32;
    end
  end
  assign mem_rdata_eff =
      io_is_io_rd_q ? io_rdata_q : mem_rdata;

  tms34010_alu u_alu (
    .op    (alu_op_q),
    .a     (alu_a_q),
    .b     (alu_b_q),
    .cin   (alu_cin_q),
    .result(alu_result),
    .flags (alu_flags)
  );

  // Shifter datapath. Operand is the Rd register value captured from the
  // selected read port, which reads decoded.rd_idx in the same file as the
  // destination). Shift amount comes from one of two sources:
  //   - K-form shifts: decoded.k5 (left/rotate direct; right forms already
  //     converted from their two's-complement opcode field by decode)
  //   - Rs-form left/rotate shifts (SLA/SLL/RL Rs, Rd):  Rs[4:0] directly
  //   - Rs-form right shifts (SRA/SRL Rs, Rd):  2's complement of Rs[4:0]
  //     (per spec pages 12-244/12-246; "use the 2s complement value of the
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
      default:      shifter_amount = decoded.k5;
    endcase
  end

  tms34010_shifter u_shifter (
    .op    (shifter_op_q),
    .a     (dispatch_rs2_q),
    .amount(shifter_amount_q),
    .result(shifter_result),
    .flags (shifter_flags)
  );

  // Shift instructions use the ordinary operand-prep/execute/writeback
  // boundary: dispatch_rs2_q captures the shifted operand during PREP, the barrel
  // shifter evaluates it in EXECUTE, and the flags are retained for WRITEBACK.
  always_ff @(posedge clk) begin
    if (rst) begin
      shifter_amount_q <= '0;
      shifter_op_q     <= SHIFT_OP_SLL;
      shifter_flags_q  <= '0;
    end else begin
      if (state_q == CORE_OPERAND_PREP && decoded.use_shifter) begin
        shifter_amount_q <= shifter_amount;
        shifter_op_q     <= decoded.shift_op;
      end
      if (state_q == CORE_EXECUTE && decoded.use_shifter)
        shifter_flags_q <= shifter_flags;
    end
  end

  // Flag-input mux: status register samples either ALU flags or shifter
  // flags depending on the source of the result.
  // Flag-input mux: SET/CLR-C inject a constant C value (paired with
  // the wb_flag_mask = c-only in their decoder arms); other
  // flag-affecting instructions get their flags from the ALU or shifter
  // per `decoded.use_shifter`.
  alu_flags_t  flag_input;
  always_comb begin
    if (fill_win_flag_wb) begin
      // Window result: only V is written (mask below is V-only).
      flag_input = '{n: 1'b0, c: 1'b0, z: 1'b0, v: fill_win_violation};
    end else
    unique case (decoded.iclass)
      INSTR_SETC:   flag_input = '{n: 1'b0, c: 1'b1, z: 1'b0, v: 1'b0};
      INSTR_CLRC:   flag_input = '{n: 1'b0, c: 1'b0, z: 1'b0, v: 1'b0};
      // LMO uses the DISPATCH operand snapshot, matching lmo_result and
      // keeping its status path independent of later special RF selectors.
      INSTR_LMO_RR: flag_input = '{n: 1'b0, c: 1'b0,
                                    z: (dispatch_rs1_q == '0), v: 1'b0};
      INSTR_SEXT:   flag_input = '{n: sext_result[DATA_WIDTH-1], c: 1'b0,
                                    z: (sext_result == '0), v: 1'b0};
      INSTR_ZEXT:   flag_input = '{n: 1'b0, c: 1'b0,
                                    z: (zext_result == '0), v: 1'b0};
      // MMTM (SPVU001A page 12-111): N = sign of (0 - original Rp) with
      // exceptions Rp=0 -> 1 and Rp=0x80000000 -> 0; the closed form is
      // N = ~Rp[31]. Use the original Rp captured at DISPATCH, before the
      // final-Rp writeback changes the register-file value. C/Z/V are masked
      // off (Unaffected) via wb_flag_mask, so only the N field matters.
      INSTR_MMTM:   flag_input = '{n: ~dispatch_rs2_q[DATA_WIDTH-1],
                                    c: 1'b0, z: 1'b0, v: 1'b0};
      // MOVE load (indirect / offset / absolute): implicit compare-to-0 of
      // the loaded field AFTER FE sign/zero extension (mv_load_data_q). N =
      // result sign, Z = result==0, V=0; C masked off by wb_flag_mask. For a
      // PIXT load (force_pixel) the only defined status bit is V = (pixel !=
      // 0); the PIXT-load decode masks N/C/Z off (they are spec-Undefined).
      INSTR_MOVE_FIELD_LOAD,
      INSTR_MOVE_ABS_LOAD,
      INSTR_MOVE_OFF_LOAD:  flag_input = '{n: mv_load_data_q[DATA_WIDTH-1],
                                    c: 1'b0, z: (mv_load_data_q == '0),
                                    v: (decoded.force_pixel && (mv_load_data_q != '0))};
      INSTR_ADDXY:  flag_input = addxy_flags;
      INSTR_SUBXY:  flag_input = subxy_flags;
      INSTR_CMPXY:  flag_input = cmpxy_flags;
      INSTR_CPW:    flag_input = cpw_flags;
      // Multiply status follows the architecturally stored result. Even Rd
      // stores all 64 bits, while odd Rd discards the upper 32 bits; therefore
      // odd-form N/Z must use product[31:0], not the untruncated product.
      // MPYU masks N off and uses the same even/odd Z selection.
      INSTR_MPYS,
      INSTR_MPYU:   flag_input = '{
          n: mpy_rd_even ? mpy_product_q[63] : mpy_product_q[DATA_WIDTH-1],
          c: 1'b0,
          z: mpy_rd_even ? (mpy_product_q == 64'd0)
                         : (mpy_product_q[DATA_WIDTH-1:0] == '0),
          v: 1'b0
      };
      // Divide family: V reports quotient overflow. DIVS N follows a negative
      // quotient except for the divider's early-overflow cases (Rs=0 or an
      // even-Rd high half >= divisor), exactly as page 12-63 specifies. MODS
      // leaves N unaffected. Z follows the stored quotient/remainder; DIV
      // forces it low on overflow, while MOD masks it only for Rs=0.
      INSTR_DIVU,
      INSTR_DIVS,
      INSTR_MODU,
      INSTR_MODS:   flag_input = '{
          n: is_divs && !div_overflow
             && ((div_quot_out == 32'h8000_0000)
                 || (div_result_neg && (div_quotient != '0))),
          c: 1'b0,
          z: (div_result_main == '0)
             && (is_div_mod ? !div_overflow : !div_v),
          v: div_v
      };
      default:      flag_input = decoded.use_shifter ? shifter_flags_q : alu_flags;
    endcase
  end

  // Effective per-flag update mask. MODU/MODS leave Z Unaffected only when
  // Rs=0. `div_overflow` is the divider's raw early-overflow indication and
  // distinguishes that case from MODS signed-quotient overflow, where Z is
  // still defined from the valid remainder.
  alu_flags_t effective_flag_mask;
  always_comb begin
    effective_flag_mask = decoded.wb_flag_mask;
    if (is_div_mod && div_overflow) effective_flag_mask.z = 1'b0;
    if (fill_win_flag_wb)
      effective_flag_mask = '{n: 1'b0, c: 1'b0, z: 1'b0, v: 1'b1};
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
    mem_req_int       = 1'b0;
    mem_we_int        = 1'b0;
    mem_addr      = '0;
    io_decode_addr = mem_addr;
    mem_size      = '0;
    io_field_remaining = 7'd64;
    mem_wdata     = '0;
    io_wdata      = '0;
    mem_iaq       = 1'b0;
    pc_advance_en = 1'b0;

    unique case (state_q)
      CORE_RESET: begin
        // Architectural reset (1988 UG 8-10 through 8-13): HCS high at reset
        // selects host-present mode and defers the level-0 vector fetch until
        // the host clears HLT. Otherwise fetch the 32-bit vector through the
        // normal memory interface. Reset does not push PC/ST or touch SP.
        if (!rst) begin
          if (io_hlt) begin
            state_d = CORE_RESET_HALT;
          end else begin
            mem_req_int    = 1'b1;
            mem_we_int = 1'b0;
            mem_addr   = RESET_VECTOR_ADDR;
            io_decode_addr = mem_addr;
            mem_size   = MEM_SIZE_32;
            io_field_remaining = 7'd32;
            if (mem_ack_eff) state_d = CORE_FETCH;
          end
        end
      end

      CORE_FETCH: begin
        // Recognise a pending interrupt at the instruction boundary. NMI
        // (non-maskable) takes priority over a maskable request (ST.IE=1 and an
        // enabled INTPEND bit). When taken, do NOT fetch — pc_value stays at the
        // resume address. An NMI with NMIM=1 saves no context and jumps
        // straight to the vector; everything else pushes PC+ST first.
        // A newly asserted NMI is serviced before a simultaneous halt, which
        // lets HLT stop the core at the NMI service routine's first boundary.
        // Keep an outstanding fetch asserted until its acknowledgement.  An
        // interrupt may become pending while the request is in flight; if we
        // drop mem_req_int here, the old fetch acknowledgement can be consumed as
        // the first interrupt stack-write acknowledgement.
        mem_req_int  = 1'b1;
        mem_we_int   = 1'b0;
        mem_addr = pc_value;
        io_decode_addr = mem_addr;
        mem_size = INSTR_WORD_BITS;
        io_field_remaining = 7'd48;
        mem_iaq  = 1'b1;
        if (mem_ack_eff) begin
          if (int_take) begin
            // Leave PC at the requested word so RETI resumes by refetching it.
            state_d = (nmi_req && nmi_nmim) ? CORE_INT_VECTOR : CORE_INT_PUSH_PC;
          end else if (io_hlt) begin
            state_d = CORE_HOST_HALT;
          end else begin
            state_d       = CORE_DECODE;
            pc_advance_en = 1'b1;       // advance PC by INSTR_WORD_BITS
          end
        end
      end

      CORE_INT_PUSH_PC: begin
        // Push the resume PC to mem[SP-32] (32-bit). SP is not updated until
        // CORE_INT_DONE; the second push uses SP-64. Order matches RETI's pop
        // (ST at the lower address, PC at the higher) and the TRAP push.
        mem_req_int   = 1'b1;
        mem_we_int = 1'b1;
        mem_addr  = rf_sp - WORD_BIT_SIZE;
        // Interrupt pushes always use the word sequencer. Their fast-field
        // classifier is unused and must not depend on forwarded SP arithmetic.
        io_decode_addr = '0;
        mem_size  = MEM_SIZE_32;
        io_field_remaining = 7'd32;
        mem_wdata = int_stack_pc;
        if (mem_ack_eff) state_d = CORE_INT_PUSH_ST;
      end

      CORE_INT_PUSH_ST: begin
        // Push ST to mem[SP-64] (32-bit).
        mem_req_int   = 1'b1;
        mem_we_int = 1'b1;
        mem_addr  = rf_sp - WORD_BIT_SIZE_2;
        io_decode_addr = '0;
        mem_size  = MEM_SIZE_32;
        io_field_remaining = 7'd32;
        mem_wdata = int_stack_st;
        if (mem_ack_eff) state_d = CORE_INT_VECTOR;
      end

      CORE_INT_VECTOR: begin
        // Read the 32-bit trap vector (the ISR entry address) at the latched
        // vector address; latch it into popped_pc_q for the PC load below.
        mem_req_int   = 1'b1;
        mem_we_int = 1'b0;
        mem_addr  = int_vec_q;
        io_decode_addr = mem_addr;
        mem_size  = MEM_SIZE_32;
        io_field_remaining = 7'd32;
        if (mem_ack_eff) state_d = CORE_INT_DONE;
      end

      CORE_INT_DONE: begin
        // One cycle to retire the entry: SP <- SP-64 (regfile), PC <- vector,
        // and ST <- ST_RESET_VALUE. NMIM=1 suppresses only the SP update.
        // Then fetch the ISR.
        state_d = CORE_FETCH;
      end

      CORE_DECODE: begin
        // instr_word_q has just changed. Hold it for a second complete cycle
        // before the wide combinational decode record is captured.
        state_d = CORE_DECODE_WAIT;
      end

      CORE_DECODE_WAIT: begin
        // decoded is captured at the edge leaving this state.
        state_d = CORE_DISPATCH;
      end

      CORE_DISPATCH: begin
        // Reserved encodings trap immediately to vector 30. PC was advanced
        // by the opcode fetch, so the pushed PC matches TRAP 30's PC'.
        if (decoded.illegal_trap) begin
          state_d = CORE_INT_PUSH_PC;
        end else if (decoded.needs_imm64) begin
          state_d = CORE_FETCH_IMM_LO;
        end else if (decoded.needs_imm32) begin
          state_d = CORE_FETCH_IMM_LO;
        end else if (decoded.needs_imm16) begin
          state_d = CORE_FETCH_IMM_LO;
        end else begin
          state_d = CORE_OPERAND_PREP;
        end
      end

      CORE_OPERAND_PREP: begin
        // Registered read addresses have driven the asynchronous RF ports for
        // one full cycle. Capture their data, then give BTST_RR its existing
        // separate one-hot-mask preparation cycle.
        state_d = CORE_BTST_PREP;
      end

      CORE_BTST_PREP: begin
        // alu_b_capture uses dispatch_rs1_q here; the one-hot mask settles
        // before the edge that captures ALU operands and enters EXECUTE.
        state_d = CORE_EXECUTE;
      end

      CORE_FETCH_IMM_LO: begin
        // Fetch the 16-bit low-immediate word from PC. Same protocol as
        // CORE_FETCH; PC advances by INSTR_WORD_BITS on ack.
        mem_req_int  = 1'b1;
        mem_we_int   = 1'b0;
        mem_addr = pc_value;
        io_decode_addr = mem_addr;
        mem_size = INSTR_WORD_BITS;
        io_field_remaining = 7'd48;
        if (mem_ack_eff) begin
          pc_advance_en = 1'b1;
          state_d = (decoded.needs_imm32 || decoded.needs_imm64)
                  ? CORE_FETCH_IMM_HI : CORE_OPERAND_PREP;
        end
      end

      CORE_FETCH_IMM_HI: begin
        mem_req_int  = 1'b1;
        mem_we_int   = 1'b0;
        mem_addr = pc_value;
        io_decode_addr = mem_addr;
        mem_size = INSTR_WORD_BITS;
        io_field_remaining = 7'd48;
        if (mem_ack_eff) begin
          pc_advance_en = 1'b1;
          state_d = decoded.needs_imm64 ? CORE_FETCH_IMM_EXT_LO : CORE_OPERAND_PREP;
        end
      end

      CORE_FETCH_IMM_EXT_LO: begin
        mem_req_int  = 1'b1;
        mem_we_int = 1'b0;
        mem_addr = pc_value;
        io_decode_addr = mem_addr;
        mem_size = INSTR_WORD_BITS;
        io_field_remaining = 7'd48;
        if (mem_ack_eff) begin
          pc_advance_en = 1'b1;
          state_d = CORE_FETCH_IMM_EXT_HI;
        end
      end

      CORE_FETCH_IMM_EXT_HI: begin
        mem_req_int  = 1'b1;
        mem_we_int = 1'b0;
        mem_addr = pc_value;
        io_decode_addr = mem_addr;
        mem_size = INSTR_WORD_BITS;
        io_field_remaining = 7'd48;
        if (mem_ack_eff) begin
          pc_advance_en = 1'b1;
          state_d = CORE_OPERAND_PREP;
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
        if (is_mpy)
          state_d = CORE_MPY;
        else if (is_mv_m2m)
          state_d = CORE_M2M_CAPTURE;
        else if (is_emu)
          state_d = run_emu_n_i ? CORE_WRITEBACK : CORE_EMU_HALT;
        else if (is_div)
          state_d = CORE_DIV_PREP;
        else if (is_fill)
          state_d = array_resume ? CORE_ARRAY_RESUME1 : CORE_FILL_SETUP;
        else if (is_pblt)
          state_d = array_resume ? CORE_ARRAY_RESUME1 : CORE_PBLT_SETUP;
        else if (is_drav)
          // DRAV: latched Rd/Rs/linear here. The setup cycle captures COLOR1
          // and, when W!=0, WSTART/WEND before any pixel request.
          state_d = CORE_DRAV_SETUP_WIN;
        else if (is_line)
          state_d = CORE_LINE_SETUP1;  // LINE: read the implied B operands
        else if (pixt_xy_win)
          state_d = CORE_PIXT_SETUP_WIN; // windowed XY PIXT: read WSTART/WEND
        else
          state_d = decoded.needs_memory_op ? CORE_MEMORY : CORE_WRITEBACK;
      end

      CORE_M2M_CAPTURE: begin
        // Stage 1 has captured both register-file operands.  Keep this state
        // quiet so the next cycle contains only the XY/absolute base logic.
        state_d = CORE_M2M_CALC;
      end

      CORE_M2M_CALC: begin
        // Stage 2 registers the shifted/selected base address.  A windowed
        // XY PIXT still performs its existing WSTART/WEND setup after the
        // final address commit; all other M2M forms proceed to memory.
        state_d = CORE_M2M_COMMIT;
      end

      CORE_M2M_COMMIT: begin
        state_d = pixt_xy_win ? CORE_PIXT_SETUP_WIN : CORE_MEMORY;
      end

      CORE_DIV_PREP: begin
        // The divider accepts the registered magnitude operands on this edge.
        state_d = CORE_DIVIDE;
      end

      CORE_DIVIDE: begin
        // Hold while the divider runs; proceed to writeback when it signals
        // done (results, incl. the overflow flag, are then stable).
        state_d = div_done ? CORE_WRITEBACK : CORE_DIVIDE;
      end

      CORE_MPY: begin
        // The staged operands have had a full cycle through the inferred DSP
        // multiplier. The product register is written at this edge.
        state_d = CORE_WRITEBACK;
      end

      CORE_FILL_SETUP: begin
        // One cycle to latch COLOR1 (and the counters were seeded at EXECUTE).
        // A zero dimension is an empty array: no access, flag update, or
        // implied-register writeback is performed.
        // XY conversion has its own address stage. Once the linear origin is
        // ready, a windowed operation can read WSTART/WEND.
        state_d = fill_empty                                  ? CORE_FETCH
                : fill_is_xy                                  ? CORE_FILL_XY_ADDR
                : (fill_win_en_q || fill_w2_q || fill_w1_q)   ? CORE_FILL_SETUP_WIN
                                                              : CORE_FILL;
      end

      CORE_FILL_XY_ADDR: begin
        state_d = (fill_win_en_q || fill_w2_q || fill_w1_q)
                ? CORE_FILL_SETUP_WIN : CORE_FILL;
      end

      CORE_FILL_SETUP_WIN: begin
        // Latch WSTART/WEND before evaluating any window geometry.
        state_d = CORE_FILL_WIN_EVAL;
      end

      CORE_FILL_WIN_EVAL: begin
        // W=2 can decide from the registered endpoints. W=1 needs the
        // intersection dimensions; W=3 also needs those dimensions before
        // shifting and applying its start-address offset.
        state_d = (fill_w2_q && !fill_array_inside) ? CORE_FILL_WIN_MISS
                : (fill_w1_q || fill_win_en_q) ? CORE_FILL_WIN_SIZE
                : CORE_FILL;
      end

      CORE_FILL_WIN_SIZE: begin
        state_d = fill_w1_q ? CORE_FILL_WIN_HIT
                : fill_win_en_q ? CORE_FILL_WIN_OFFSETS
                                : CORE_FILL;
      end

      CORE_FILL_WIN_OFFSETS: begin
        state_d = CORE_FILL_WIN_APPLY;
      end

      CORE_FILL_WIN_APPLY: begin
        state_d = fill_clip_hit_q ? CORE_FILL : CORE_FILL_WB;
      end

      CORE_FILL_WIN_MISS: begin
        // W=2 window miss: no pixels drawn; V=1 and WVP set (combinationally),
        // then fetch the next instruction.
        state_d = CORE_FETCH;
      end

      CORE_FILL_WIN_HIT: begin
        // W=1 hit detection: no pixels drawn. V and WVP are driven
        // combinationally from fill_array_hit. A hit also writes common DADDR
        // in this cycle, followed by common DYDX in its own write-port cycle.
        state_d = fill_array_hit ? CORE_FILL_W1_DYDX : CORE_FETCH;
      end

      CORE_FILL_W1_DYDX: begin
        state_d = CORE_FETCH;
      end

      CORE_DRAV_SETUP_WIN: begin
        // Capture WSTART/WEND and COLOR1. Window comparisons happen in the
        // next state from registered bounds, separated from the RF read mux.
        state_d = (drav_w_q == 2'd0) ? CORE_DRAV : CORE_DRAV_WIN_EVAL;
      end

      CORE_DRAV_WIN_EVAL: begin
        // Only W=2/3 inside proceeds to the pixel access; otherwise advance
        // Rd and write V/WVP without pixel traffic.
        state_d = (((drav_w_q == 2'd2) || (drav_w_q == 2'd3))
                   && drav_in_window) ? CORE_DRAV : CORE_WRITEBACK;
      end

      CORE_PIXT_SETUP_WIN: begin
        // Capture WSTART/WEND; the registered rectangle is evaluated next.
        state_d = CORE_PIXT_WIN_EVAL;
      end

      CORE_PIXT_WIN_EVAL: begin
        // A register-to-XY store runs its pixel access and inhibits the write
        // there. Suppressed XY-to-XY transfers skip directly to writeback.
        state_d = (pixt_xy_m2m
                   && ((pixt_w_q == 2'd1)
                       || !pixt_in_window))
                ? CORE_WRITEBACK : CORE_MEMORY;
      end

      CORE_DRAV: begin
        // A destination read is followed by registered PPOP and merge steps;
        // direct replace writes in its original second cycle.
        mem_size = io_psize[FIELD_SIZE_WIDTH-1:0];
        io_field_remaining = io_psize_remaining_q;
        if (drav_substep_q == 3'd0) begin
          mem_req_int  = 1'b1;
          mem_addr = drav_linear_q;
          io_decode_addr = mem_addr;
          mem_we_int = 1'b0;            // read the destination pixel
        end else if (drav_substep_q == (drav_dest_read_q ? 3'd3 : 3'd1)) begin
          mem_req_int  = 1'b1;
          mem_addr = drav_linear_q;
          io_decode_addr = mem_addr;
          mem_we_int = 1'b1;           // write the merged pixel
          mem_wdata = drav_dest_read_q
                    ? pixel_ppop_merged_q
                    : aligned_color(drav_color_q, drav_linear_q,
                                    pixel_size_mask_q);
        end
        if (mem_ack_eff
            && (drav_substep_q == (drav_dest_read_q ? 3'd3 : 3'd1)))
          state_d = CORE_WRITEBACK;
        else
          state_d = CORE_DRAV;
      end

      CORE_LINE_SETUP1: state_d = CORE_LINE_SETUP2;
      CORE_LINE_SETUP2: state_d = CORE_LINE_SETUP3;
      CORE_LINE_SETUP3:
        // Stage the first address through SETUP_WIN/ADDR even without a
        // window. Subsequent pixels reuse the existing checkpoint stages.
        // If COUNT is 0 there is nothing to draw; go straight to writeback.
        state_d = (line_count_q == '0) ? CORE_LINE_WB_D
                : CORE_LINE_SETUP_WIN;
      CORE_LINE_SETUP_WIN: state_d = CORE_LINE_ADDR;
      CORE_LINE_ADDR: state_d = CORE_LINE_DRAW;

      CORE_LINE_DRAW: begin
        // A destination read is followed by registered PPOP and merge steps;
        // direct replace writes in its original second cycle.
        mem_size = io_psize[FIELD_SIZE_WIDTH-1:0];
        io_field_remaining = io_psize_remaining_q;
        if (line_substep_q == 3'd0) begin
          mem_req_int  = 1'b1;
          mem_addr = line_linear;
          io_decode_addr = mem_addr;
          mem_we_int = 1'b0;            // read the destination pixel
        end else if (line_substep_q == (line_dest_read_q ? 3'd3 : 3'd1)) begin
          mem_req_int  = 1'b1;
          mem_addr = line_linear;
          io_decode_addr = mem_addr;
          mem_we_int = 1'b1;           // write the merged pixel
          mem_wdata = line_dest_read_q
                    ? pixel_ppop_merged_q
                    : aligned_color(line_color_q, line_linear,
                                    pixel_size_mask_q);
        end
        if (mem_ack_eff
            && (line_substep_q == (line_dest_read_q ? 3'd3 : 3'd1))) begin
          // Final pixels and W=1/W=2 aborts complete normally. Every other
          // completed pixel first publishes its continuation state.
          state_d = ((line_count_q == 32'd1) || line_abort)
                  ? CORE_LINE_WB_D : CORE_LINE_CKPT_D;
        end else begin
          state_d = CORE_LINE_DRAW;
        end
      end

      CORE_LINE_WB_D:     state_d = CORE_LINE_WB_DADDR; // write d  -> B0
      CORE_LINE_WB_DADDR: state_d = CORE_LINE_WB_COUNT; // write DADDR -> B2
      CORE_LINE_WB_COUNT: state_d = CORE_FETCH;         // write COUNT -> B10, then fetch
      CORE_LINE_CKPT_D:     state_d = CORE_LINE_CKPT_DADDR;
      CORE_LINE_CKPT_DADDR: state_d = CORE_LINE_CKPT_COUNT;
      CORE_LINE_CKPT_COUNT: begin
        state_d = int_take
                ? ((nmi_req && nmi_nmim) ? CORE_INT_VECTOR
                                         : CORE_INT_PUSH_PC)
                : CORE_LINE_DRAW;
      end

      CORE_FILL: begin
        // Per pixel, optionally read the destination at sub-step 0, then write
        // the merged/direct value at sub-step 1. The field sequencer handles sub-word /
        // straddling pixels. Stay until the array's last write completes.
        mem_req_int   = 1'b1;
        mem_addr  = fill_addr_q;
        io_decode_addr = mem_addr;
        mem_size  = io_psize[FIELD_SIZE_WIDTH-1:0];
        io_field_remaining = io_psize_remaining_q;
        if (fill_substep_q == 3'd0) begin
          mem_we_int = 1'b0;            // read the destination pixel
        end else if (fill_substep_q == (fill_dest_read_q ? 3'd3 : 3'd1)) begin
          mem_we_int = 1'b1;            // write the processed pixel
          mem_wdata  = fill_dest_read_q ? pixel_ppop_merged_q
                                        : aligned_color(fill_color_q, fill_addr_q,
                                                        pixel_size_mask_q);
        end else begin
          mem_req_int = 1'b0;               // registered PPOP / merge stage
        end
        if (mem_ack_eff
            && (fill_substep_q == (fill_dest_read_q ? 3'd3 : 3'd1))) begin
          state_d = fill_done            ? CORE_FILL_WB
                  : fill_checkpoint_due  ? CORE_ARRAY_CKPT_B0
                                         : CORE_FILL;
        end else begin
          state_d = CORE_FILL;
        end
      end

      CORE_FILL_WB: begin
        // Write the final DADDR back to B2, then fetch the next instruction.
        state_d = CORE_FETCH;
      end

      CORE_PBLT_SETUP: begin
        // Capture pitches, converted bases, and corner offsets in parallel.
        state_d = CORE_PBLT_CORNER;
      end

      CORE_PBLT_CORNER: begin
        // Finish the traversal addresses before color/window setup or pixel
        // traffic. Empty arrays still exit without a request or writeback.
        state_d = pblt_empty                                  ? CORE_FETCH
                : decoded.blt_binary                          ? CORE_PBLT_SETUP2
                : (pblt_win_en_q || pblt_w2_q || pblt_w1_q)   ? CORE_PBLT_SETUP_WIN
                                                              : CORE_PBLT;
      end

      CORE_PBLT_SETUP2: begin
        // Latch COLOR0/COLOR1 for the color-expand source.
        state_d = (pblt_win_en_q || pblt_w2_q || pblt_w1_q) ? CORE_PBLT_SETUP_WIN
                                                            : CORE_PBLT;
      end

      CORE_PBLT_SETUP_WIN: begin
        // Latch WSTART(B5)/WEND(B6) before evaluating any window geometry.
        state_d = CORE_PBLT_WIN_EVAL;
      end

      CORE_PBLT_WIN_EVAL: begin
        state_d = CORE_PBLT_WIN_OFFSETS;
      end

      CORE_PBLT_WIN_OFFSETS: begin
        state_d = CORE_PBLT_WIN_APPLY;
      end

      CORE_PBLT_WIN_APPLY: begin
        // W=3 preclips both working arrays before any request; a fully
        // excluded rectangle goes to status-only WB2. W=2 checks containment.
        // W=1 never draws.
        state_d = pblt_w1_q                         ? CORE_PBLT_WIN_HIT
                : (pblt_w2_q && !pblt_array_inside_q) ? CORE_PBLT_WIN_MISS
                : (pblt_win_en_q && !pblt_clip_hit_q) ? CORE_PBLT_WB2
                                                    : CORE_PBLT;
      end

      CORE_PBLT_WIN_MISS: begin
        // W=2 window miss: no pixels drawn; V=1 and WVP set, then fetch.
        state_d = CORE_FETCH;
      end

      CORE_PBLT_WIN_HIT: begin
        // W=1 hit detection: no pixels drawn. Write the selected common-
        // rectangle corner now and its dimensions in the following cycle.
        state_d = pblt_array_hit ? CORE_PBLT_W1_DYDX : CORE_FETCH;
      end

      CORE_PBLT_W1_DYDX: begin
        state_d = CORE_FETCH;
      end

      CORE_PBLT: begin
        // Per pixel: read source (sub-step 0), optionally read destination
        // (1), then write the processed/direct pixel (2).
        // The binary source is read 1 bit at a time; otherwise PSIZE bits.
        mem_size  = io_psize[FIELD_SIZE_WIDTH-1:0];
        io_field_remaining = io_psize_remaining_q;
        unique case (pblt_substep_q)
          3'd0: begin
            mem_req_int   = 1'b1;
            mem_we_int = 1'b0;             // read source pixel (1 bit if binary)
            mem_addr   = pblt_src_access_addr;
            io_decode_addr = pblt_src_addr_q;
            if (decoded.blt_binary) begin
              mem_size = FIELD_SIZE_WIDTH'(1);
              io_field_remaining = 7'd63;
            end
          end
          3'd1: if (pblt_dest_read_q) begin
            mem_req_int   = 1'b1;
            mem_we_int = 1'b0;             // read destination pixel
            mem_addr   = pblt_dst_access_addr;
            io_decode_addr = pblt_dst_addr_q;
          end
          3'd2: if (!pblt_dest_read_q) begin
            mem_req_int   = 1'b1;
            mem_we_int = 1'b1;
            mem_addr   = pblt_dst_access_addr;
            io_decode_addr = pblt_dst_addr_q;
            mem_wdata  = pblt_src_eff;
          end
          default: if (pblt_dest_read_q && (pblt_substep_q == 3'd4)) begin
            mem_req_int   = 1'b1;
            mem_we_int = 1'b1;             // write the processed pixel
            mem_addr   = pblt_dst_access_addr;
            io_decode_addr = pblt_dst_addr_q;
            mem_wdata  = pixel_ppop_merged_q;
          end
        endcase
        if (mem_ack_eff
            && (pblt_substep_q == (pblt_dest_read_q ? 3'd4 : 3'd2))) begin
          state_d = pblt_done            ? CORE_PBLT_WB
                  : pblt_checkpoint_due  ? CORE_ARRAY_CKPT_B0
                                         : CORE_PBLT;
        end else begin
          state_d = CORE_PBLT;
        end
      end

      CORE_PBLT_WB: begin
        // Write the final SADDR back to B0.
        state_d = CORE_PBLT_WB2;
      end

      CORE_PBLT_WB2: begin
        // Write the final DADDR back to B2, then fetch the next instruction.
        state_d = CORE_FETCH;
      end

      // Serialize one coherent, restart-sufficient array context after a
      // completed destination word/row. No memory request is active anywhere
      // in this chain. Interrupts are sampled only in the final state, after
      // B14 and every preceding context word are committed.
      CORE_ARRAY_CKPT_B0:  state_d = CORE_ARRAY_CKPT_B2;
      CORE_ARRAY_CKPT_B2:  state_d = CORE_ARRAY_CKPT_B10;
      CORE_ARRAY_CKPT_B10: state_d = CORE_ARRAY_CKPT_B11;
      CORE_ARRAY_CKPT_B11: state_d = CORE_ARRAY_CKPT_B12;
      CORE_ARRAY_CKPT_B12: state_d = CORE_ARRAY_CKPT_B13;
      CORE_ARRAY_CKPT_B13: state_d = CORE_ARRAY_CKPT_B14;
      CORE_ARRAY_CKPT_B14: begin
        state_d = int_take
                ? ((nmi_req && nmi_nmim) ? CORE_INT_VECTOR
                                         : CORE_INT_PUSH_PC)
                : is_fill ? CORE_FILL : CORE_PBLT;
      end

      // A PBX-marked RETI refetches the interrupted one-word array opcode.
      // These quiet reads rebuild all private engine state strictly from the
      // handler-preserved architectural B image before the next pixel.
      CORE_ARRAY_RESUME1: state_d = CORE_ARRAY_RESUME2;
      CORE_ARRAY_RESUME2: state_d = CORE_ARRAY_RESUME3;
      CORE_ARRAY_RESUME3: state_d = CORE_ARRAY_RESUME4;
      CORE_ARRAY_RESUME4: state_d = is_fill ? CORE_FILL : CORE_PBLT;

      CORE_MEMORY: begin
        // Memory transaction state for instructions that set
        // decoded.needs_memory_op. The IF signals (mem_req_int, mem_we_int,
        // mem_addr, mem_size, mem_wdata) are driven per iclass.
        unique case (iclass_mem_q)
          INSTR_PUSHST: begin
            // Write ST to mem[new SP] as a 32-bit transfer.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = execute_wb_data_q; // registered ALU result = SP - 32
            io_decode_addr = mem_addr;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
            mem_wdata = st_value;          // ST
          end
          INSTR_POPST: begin
            // Read 32-bit ST from mem[OLD SP]. The increment-by-32
            // happens via the ALU; we don't want alu_result here,
            // we want the pre-increment SP value. POPST has
            // rd_idx=15 (SP) on rs2 — so rs2 gives OLD SP.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = dispatch_rs2_q;    // = current SP, captured at DISPATCH
            io_decode_addr = mem_addr;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
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
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = execute_wb_data_q; // registered ALU result = SP - 32
            io_decode_addr = mem_addr;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
            mem_wdata = pc_value;          // PC' (return address)
          end
          INSTR_RETS: begin
            // Pop PC from mem[OLD SP]. mem_addr = current SP value
            // (rf_rs2_data) — NOT alu_result, which is SP + 32 + 16*N.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = dispatch_rs2_q;    // = current SP, captured at DISPATCH
            io_decode_addr = mem_addr;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
          end
          INSTR_RETI: begin
            // Two-step pop: step 0 reads ST from mem[SP]; step 1 reads
            // PC from mem[SP+32]. Both 32-bit reads. The latched
            // popped_st_q / popped_pc_q values flow to the WRITEBACK
            // ST-write and PC-load paths below.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
            mem_addr  = (mem_op_step == 3'd0)
                      ? dispatch_rs2_q               // = SP
                      : (dispatch_rs2_q + WORD_BIT_SIZE); // = SP + 32
            io_decode_addr = mem_addr;
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
            mem_req_int   = 1'b1;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
            if (trap_skip_push) begin
              mem_we_int    = 1'b0;
              mem_addr  = TRAP_VECTOR_BASE;        // N=0 ⇒ vector @ 0xFFFFFFE0
              io_decode_addr = mem_addr;
            end else begin
              unique case (mem_op_step)
                3'd0: begin
                  mem_we_int    = 1'b1;
                  mem_addr  = dispatch_rs2_q - WORD_BIT_SIZE;
                  io_decode_addr = mem_addr;
                  mem_wdata = pc_value;             // PC'
                end
                3'd1: begin
                  mem_we_int    = 1'b1;
                  mem_addr  = dispatch_rs2_q - WORD_BIT_SIZE_2;
                  io_decode_addr = mem_addr;
                  mem_wdata = st_value;             // ST as it stood
                end
                default: begin                       // step 2
                  mem_we_int    = 1'b0;
                  // Trap-vector address = TRAP_VECTOR_BASE - N*32.
                  // N is decoded.k5 (5 bits); N*32 = N << 5.
                  mem_addr  = TRAP_VECTOR_BASE
                            - ({{(ADDR_WIDTH-5){1'b0}}, decoded.k5} << 5);
                  io_decode_addr = mem_addr;
                end
              endcase
            end
          end
          INSTR_MMTM: begin
            // Push the register currently selected by mm_iter_idx to
            // mem[mm_rp_q]. Each iteration of CORE_MEMORY is one 32-bit
            // write; mm_mask_q and mm_rp_q advance on the ack. We stay
            // in CORE_MEMORY until the mask is empty.
            // The request waits for the staged register value so the write
            // payload is a flop rather than a live register-file read.
            mem_req_int   = (mm_push_stage_q == 2'd2);
            mem_we_int    = 1'b1;
            mem_addr  = mm_rp_q;
            io_decode_addr = mem_addr;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
            mem_wdata = mm_push_data_q;    // = value of register R(mm_push_idx)
          end
          INSTR_MMFM: begin
            // Pop: read 32 bits from mem[mm_rp_q] into the register
            // selected by mm_iter_idx (highest-order first). The regfile
            // write happens via the mmfm_pop_wr path; here we just drive
            // the read. mm_mask_q clears the bit and mm_rp_q advances
            // (+32) on the ack. Stay in CORE_MEMORY until mask empty.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = mm_rp_q;
            io_decode_addr = mem_addr;
            mem_size  = MEM_SIZE_32;
            io_field_remaining = 7'd32;
          end
          INSTR_MOVE_FIELD_STORE: begin
            // MOVE Rs,*Rd[+|-]: write the low FS bits of Rs (rf_rs1_data) to
            // mem[mv_addr]. mv_addr = pointer Rd (postinc/none) or Rd-FS
            // (predec); the pointer auto-update (Rd±FS) is written back at
            // WRITEBACK for the inc/dec forms. FS from the F-selected ST pair.
            // A processing/window PIXT store reads the destination at step 0
            // and writes the merged value at step 1. A regular MOVE or direct
            // replace PIXT store is a single write.
            mem_addr  = mv_addr_q;         // = Rd or Rd-FS (predec)
            io_decode_addr = mem_addr;
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
            if (pixt_rmw && mem_op_step == 3'd0) begin
              mem_req_int   = 1'b1;
              mem_we_int = 1'b0;           // step 0: read the destination pixel
            end else if (pixt_rmw && mem_op_step != 3'd3) begin
              mem_req_int = 1'b0;               // registered PPOP / merge stage
            end else begin
              mem_req_int   = 1'b1;
              mem_we_int = 1'b1;           // write (single, or step 1 of RMW)
              mem_wdata  = pixt_rmw ? pixel_ppop_merged_q : mv_store_data_q;
              io_wdata   = pixt_rmw ? pixel_ppop_merged_q : mv_store_data_q;
            end
          end
          INSTR_MOVE_FIELD_LOAD: begin
            // MOVE [-]*Rs[+],Rd: read an FS-bit field from mem[mv_addr].
            // mv_addr = pointer Rs (postinc/none) or Rs-FS (predec). The
            // field-extended data (mv_load_data) goes to Rd at WRITEBACK;
            // for inc/dec the updated pointer Rs±FS is written via the
            // mv_load_ptr_wr path on this ack.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = mv_addr_q;         // = Rs or Rs-FS (predec)
            io_decode_addr = mem_addr;
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
          end
          INSTR_MOVE_OFF_STORE: begin
            // MOVE Rs,*Rd(off): write the low FS bits of Rs (rf_rs1_data) to
            // mem[Rd + off]. imm32 = sign-extended 16-bit offset; Rd =
            // rf_rs2_data. Field-size aware (Task 0078); no pointer step.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = move_off_addr_q;
            io_decode_addr = mem_addr;
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
            mem_wdata = dispatch_rs1_q;    // = Rs (low FS bits used)
            io_wdata  = dispatch_rs1_q;    // = Rs (low FS bits used)
          end
          INSTR_MOVE_OFF_LOAD: begin
            // MOVE *Rs(off),Rd: read an FS-bit field at mem[Rs + off];
            // field-extended result -> Rd at WRITEBACK. Rs = rf_rs1_data
            // (pointer); imm32 = sext(off16). Field-size aware (Task 0078).
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = move_off_addr_q;
            io_decode_addr = mem_addr;
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
          end
          INSTR_MOVE_ABS_STORE: begin
            // MOVE Rs,@DAddr: write the low FS bits of Rs (rf_rs1_data) to the
            // absolute bit address imm32 = {imm_hi_q, imm_lo_q}. Field-size
            // aware (Task 0078).
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b1;
            mem_addr  = imm32;
            io_decode_addr = mem_addr;
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
            mem_wdata = dispatch_rs1_q;    // = Rs (low FS bits used)
            io_wdata  = dispatch_rs1_q;    // = Rs (low FS bits used)
          end
          INSTR_MOVE_ABS_LOAD: begin
            // MOVE @SAddr,Rd: read an FS-bit field from the absolute address
            // imm32; the field-extended result goes to Rd at WRITEBACK
            // (rf_wr_data mux), flags from the extended value. Task 0078.
            mem_req_int   = 1'b1;
            mem_we_int    = 1'b0;
            mem_addr  = imm32;
            io_decode_addr = mem_addr;
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
          end
          INSTR_MOVE_FIELD_M2M,
          INSTR_MOVE_OFF_M2M_PI,
          INSTR_MOVE_ABS_M2M_PI,
          INSTR_MOVB_OFF_M2M,
          INSTR_MOVB_ABS_M2M,
          INSTR_MOVE_OFF_M2M,
          INSTR_MOVE_ABS_M2M: begin
            // Ordinary indirect-to-indirect MOVE is read then write. PIXT
            // uses the same direct two-step path only for replace/T=0/
            // PMASK=0; otherwise it inserts a destination read and writes the
            // PPOP/transparency/plane-mask result on step 2.
            mem_size  = mv_fs;             // field size (1..32)
            io_field_remaining = mv_io_field_remaining;
            if (mem_op_step == 3'd0) begin
              mem_req_int   = 1'b1;
              mem_we_int   = 1'b0;
              mem_addr = m2m_src_addr_q;   // = Rs (or Rs-FS predec)
              io_decode_addr = mem_addr;
            end else if (pixt_m2m_rmw && mem_op_step == 3'd1) begin
              mem_req_int = 1'b1;
              mem_we_int = 1'b0;
              mem_addr = m2m_dst_addr_q;
              io_decode_addr = mem_addr;
            end else if (pixt_m2m_rmw && mem_op_step != 3'd4) begin
              mem_req_int = 1'b0;               // registered PPOP / merge stage
            end else begin
              mem_req_int   = 1'b1;
              mem_we_int   = 1'b1;
              mem_addr = m2m_dst_addr_q;   // = Rd (or Rd-FS predec; updated Rs if Rs==Rd)
              io_decode_addr = mem_addr;
              mem_wdata = pixt_m2m_rmw ? pixel_ppop_merged_q : move_data_q;
              io_wdata  = pixt_m2m_rmw ? pixel_ppop_merged_q : move_data_q;
            end
          end
          default: ;  // no transaction (shouldn't reach with needs_memory_op=0)
        endcase
        if (mem_ack_eff) begin
          // Multi-step instructions stay in CORE_MEMORY until their
          // final step's ack; everything else transitions on every ack.
          unique case (iclass_mem_q)
            INSTR_RETI: if (mem_op_step == 3'd1) state_d = CORE_WRITEBACK;
            INSTR_TRAP: if (trap_skip_push || mem_op_step == 3'd2)
                          state_d = CORE_WRITEBACK;
            INSTR_MMTM,
            INSTR_MMFM: if (mm_mask_will_be_empty) state_d = CORE_WRITEBACK;
            INSTR_MOVE_FIELD_M2M,
            INSTR_MOVE_OFF_M2M_PI,
            INSTR_MOVE_ABS_M2M_PI,
            INSTR_MOVB_OFF_M2M,
            INSTR_MOVB_ABS_M2M,
            INSTR_MOVE_OFF_M2M,
            INSTR_MOVE_ABS_M2M:
                        if (mem_op_step
                            == (pixt_m2m_rmw ? 3'd4 : 3'd1))
                          state_d = CORE_WRITEBACK;
            // A destination-reading PIXT stays for its write; direct store exits.
            INSTR_MOVE_FIELD_STORE:
                        if (!pixt_rmw || mem_op_step == 3'd3) state_d = CORE_WRITEBACK;
            default:    state_d = CORE_WRITEBACK;
          endcase
        end
      end

      CORE_WRITEBACK: begin
        // An even-Rd multiply/divide needs a second writeback cycle to
        // store the low half (product LSBs / divide remainder) into Rd+1.
        state_d = pair_second_pass ? CORE_WRITEBACK : CORE_FETCH;
      end

      CORE_EMU_HALT: begin
        // PC already points at the instruction after EMU. No memory or
        // architectural write occurs while halted. Raising RUN resumes at
        // the next instruction boundary.
        state_d = run_emu_n_i ? CORE_FETCH : CORE_EMU_HALT;
      end

      CORE_RESET_HALT: begin
        // Host-present reset performs no vector fetch until HLT is cleared.
        state_d = io_hlt ? CORE_RESET_HALT : CORE_RESET;
      end

      CORE_HOST_HALT: begin
        // No instruction, memory, or interrupt work occurs while halted.
        // Refresh/video/display blocks continue clocking independently.
        state_d = io_hlt ? CORE_HOST_HALT : CORE_FETCH;
      end

      default: begin
        // Defensive: any out-of-range encoding goes back to reset.
        state_d = CORE_RESET;
      end
    endcase
  end

  assign state_o          = state_q;
  assign pc_o             = pc_value;
  assign instr_word_o     = instr_word_q;
  assign illegal_opcode_o = illegal_q;
  assign emua_n_o         = !((state_q == CORE_EXECUTE && is_emu)
                           || (state_q == CORE_EMU_HALT));

endmodule : tms34010_core
`default_nettype wire
