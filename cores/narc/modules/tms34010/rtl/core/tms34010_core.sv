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
#(
  // Core clocks per local clock (machine state). 1 = every core clock is a
  // local clock.
  parameter int unsigned CLKS_PER_STATE = 8,
  // 1 (default): cycle-accurate timing (docs/cycle_accuracy.md); needs
  // CLKS_PER_STATE >= 8, i.e. the core clock is the board's INCLK. 0: the
  // original TMS34010_sv behaviour, kept as the test reference.
  parameter bit          CYCLE_ACCURATE = 1'b1,
  // vclk_i is a clock enable on clk instead of a clock (tms34010_system)
  parameter bit          VCLK_CEN       = 1'b0
)
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
  // Bits of a write's field the memory controller keeps (plane mask,
  // transparency), and whether it reads and merges every word of the write
  // (plane masking or transparency enabled); 0 with CYCLE_ACCURATE=0.
  output logic [DATA_WIDTH-1:0]               mem_keep,
  output logic                                mem_rmw,
  // CYCLE_ACCURATE: this write's data and keep mask follow one clock after
  // the memory takes the request (mem_late_wdata/keep, valid that clock).
  output logic                                mem_late,
  output logic [DATA_WIDTH-1:0]               mem_late_wdata,
  output logic [DATA_WIDTH-1:0]               mem_late_keep,
  output logic                                mem_iaq,
  output logic                                mem_srt,
  output logic                                mem_is_io,
  output logic                                mem_io_we,
  output local_word_t                         mem_io_rdata,
  input  logic [DATA_WIDTH-1:0]               mem_rdata,
  input  logic                                mem_ack,
  // The memory controller is still busy with a CPU request (a posted write
  // in progress). Used only with CYCLE_ACCURATE.
  input  logic                                mem_busy,

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

  // The same operations on every pixel of a field of up to 16 bits at once
  // (the word FILL engine, CYCLE_ACCURATE). Boolean operations are bitwise;
  // the arithmetic ones work on each PSIZE-bit pixel.
  function automatic logic [15:0] ppop_word(
      input logic [15:0] src,
      input logic [15:0] dest,
      input logic [4:0]  ppop,
      input logic [FIELD_SIZE_WIDTH-1:0] psize);
    logic [DATA_WIDTH-1:0] r;
    ppop_word = 16'(ppop_apply({16'd0, src}, {16'd0, dest}, ppop, 32'h0000_FFFF));
    if ((ppop >= 5'h10) && (ppop <= 5'h15)) begin
      unique case (psize)
        6'd16: ppop_word = 16'(ppop_apply({16'd0, src}, {16'd0, dest}, ppop,
                                          32'h0000_FFFF));
        6'd8: for (int i = 0; i < 2; i++) begin
          r = ppop_apply({24'd0, src[i*8 +: 8]}, {24'd0, dest[i*8 +: 8]}, ppop, 32'hFF);
          ppop_word[i*8 +: 8] = r[7:0];
        end
        6'd4: for (int i = 0; i < 4; i++) begin
          r = ppop_apply({28'd0, src[i*4 +: 4]}, {28'd0, dest[i*4 +: 4]}, ppop, 32'hF);
          ppop_word[i*4 +: 4] = r[3:0];
        end
        6'd2: for (int i = 0; i < 8; i++) begin
          r = ppop_apply({30'd0, src[i*2 +: 2]}, {30'd0, dest[i*2 +: 2]}, ppop, 32'h3);
          ppop_word[i*2 +: 2] = r[1:0];
        end
        default: for (int i = 0; i < 16; i++) begin
          r = ppop_apply({31'd0, src[i]}, {31'd0, dest[i]}, ppop, 32'h1);
          ppop_word[i] = r[0];
        end
      endcase
    end
  endfunction

  // One PSIZE-bit lane of all ones for every 1 bit of a binary source (the
  // PIXBLT expand forms): bit i selects pixel i of the destination field.
  function automatic logic [15:0] expand_bits(
      input logic [15:0] bits,
      input logic [FIELD_SIZE_WIDTH-1:0] psize);
    expand_bits = '0;
    unique case (psize)
      6'd16: expand_bits = {16{bits[0]}};
      6'd8: for (int i = 0; i < 2; i++) expand_bits[i*8 +: 8] = {8{bits[i]}};
      6'd4: for (int i = 0; i < 4; i++) expand_bits[i*4 +: 4] = {4{bits[i]}};
      6'd2: for (int i = 0; i < 8; i++) expand_bits[i*2 +: 2] = {2{bits[i]}};
      default: expand_bits = bits;
    endcase
  endfunction

  // The pixels of a 16-bit word field that are 0 (transparent).
  function automatic logic [15:0] zero_pixels(
      input logic [15:0] value,
      input logic [FIELD_SIZE_WIDTH-1:0] psize);
    zero_pixels = '0;
    unique case (psize)
      6'd16: zero_pixels = (value == 16'd0) ? 16'hFFFF : 16'h0000;
      6'd8: for (int i = 0; i < 2; i++)
        zero_pixels[i*8 +: 8] = (value[i*8 +: 8] == 8'd0) ? 8'hFF : 8'h00;
      6'd4: for (int i = 0; i < 4; i++)
        zero_pixels[i*4 +: 4] = (value[i*4 +: 4] == 4'd0) ? 4'hF : 4'h0;
      6'd2: for (int i = 0; i < 8; i++)
        zero_pixels[i*2 +: 2] = (value[i*2 +: 2] == 2'd0) ? 2'h3 : 2'h0;
      default: zero_pixels = ~value;
    endcase
  endfunction

  // The graphics engines are mutually exclusive at instruction granularity.
  // Route their operands through one PPOP datapath instead of synthesizing a
  // complete Boolean/arithmetic processor for every engine.
  logic [DATA_WIDTH-1:0] pixel_ppop_src;
  logic [DATA_WIDTH-1:0] pixel_ppop_dest;
  logic [DATA_WIDTH-1:0] pixel_ppop_fmask;
  logic [DATA_WIDTH-1:0] pixel_ppop_result;
  logic [DATA_WIDTH-1:0] pixel_ppop_raw_dest;
  logic [DATA_WIDTH-1:0] pixel_ppop_pmask;
  logic [DATA_WIDTH-1:0] pixel_ppop_merged;
  logic [DATA_WIDTH-1:0] pixel_size_mask_q;
  logic [15:0]           pixel_plane_mask_q;
  logic [4:0]            pixel_ppop_code_q;
  logic                  pixel_transp_en_q;
  logic                  pixel_ppop_inhibit;
  logic                  pixel_ppop_transp;

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

  // FSM side of the memory interface. tms34010_icache (5.4) sits between
  // these and the mem_* ports; with CYCLE_ACCURATE=0 it is a wire.
  logic                          fsm_mem_req;
  logic                          fsm_mem_we;
  logic [ADDR_WIDTH-1:0]         fsm_mem_addr;
  logic [FIELD_SIZE_WIDTH-1:0]   fsm_mem_size;
  logic [DATA_WIDTH-1:0]         fsm_mem_wdata;
  logic [DATA_WIDTH-1:0]         fsm_mem_keep;
  logic                          fsm_mem_rmw;
  logic                          fsm_mem_iaq;
  logic                          fsm_mem_srt;
  logic                          fsm_mem_is_io;
  logic                          fsm_mem_io_we;
  local_word_t                   fsm_mem_io_rdata;
  logic [DATA_WIDTH-1:0]         fsm_mem_rdata;
  logic                          fsm_mem_ack;
  logic                          fsm_mem_ifetch;
  logic                          io_post_d1_q, io_post_d2_q, io_post_d3_q; // posted I/O write commit
  logic                          io_rd_late_q;      // CYCLE_ACCURATE: I/O read view a clock late
  logic                          io_req, io_we;               // I/O register access strobe
  logic                          fsm_mem_from_mem;  // word came from memory, not the cache
  logic                          pace_hold;         // CYCLE_ACCURATE: next fetch not yet due
  logic                          pace_write_hold;   // CYCLE_ACCURATE: write not yet due
  logic                          pace_fill_hold;    // CYCLE_ACCURATE: FILL access not yet due

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

  always_ff @(posedge clk) begin
    if (rst) begin
      instr_word_q <= '0;
    end else if (state_q == CORE_FETCH && fsm_mem_ack) begin
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
    end else if (state_q == CORE_DECODE_WAIT) begin
      decoded <= decoded_comb;
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
    end else if (state_q == CORE_MEMORY && fsm_mem_ack) begin
      // MOVE *Rs,*Rd: step 0 reads the source field; latch it so step 1
      // can write it to the destination.
      if (((decoded.iclass == INSTR_MOVE_FIELD_M2M)
        || (decoded.iclass == INSTR_MOVE_OFF_M2M_PI)
        || (decoded.iclass == INSTR_MOVE_ABS_M2M_PI)
        || (decoded.iclass == INSTR_MOVB_OFF_M2M)
        || (decoded.iclass == INSTR_MOVB_ABS_M2M)
        || (decoded.iclass == INSTR_MOVE_OFF_M2M)
        || (decoded.iclass == INSTR_MOVE_ABS_M2M))
       && mem_op_step == 2'd0) begin
        move_data_q <= mem_rdata_eff;
      end
      // A processing PIXT memory-to-memory transfer reads the raw destination
      // after its source. Keep the unmasked value for protected-plane merge;
      // PPOP sees the separately masked destination operand.
      if (pixt_m2m_rmw && mem_op_step == 2'd1)
        pix_dest_q <= mem_rdata_eff;
      // A processing/window PIXT store reads the destination at step 0; latch
      // it so step 1 can merge the result.
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
        INSTR_MOVE_OFF_M2M_PI,
        INSTR_MOVE_ABS_M2M_PI,
        INSTR_MOVB_OFF_M2M,
        INSTR_MOVB_ABS_M2M,
        INSTR_MOVE_OFF_M2M,
        INSTR_MOVE_ABS_M2M:
                    mem_op_step <=
                        (mem_op_step
                         == (pixt_m2m_rmw ? 2'd2 : 2'd1))
                          ? 2'd0 : mem_op_step + 2'd1;
        // Processing/window PIXT store: read -> write -> 0. Direct PIXT and
        // regular MOVE stores are single-step and fall through to default.
        INSTR_MOVE_FIELD_STORE:
                    mem_op_step <= (pixt_rmw && mem_op_step == 2'd0) ? 2'd1 : 2'd0;
        default:    mem_op_step <= 2'd0;
      endcase
    end else if (state_q == CORE_INT_VECTOR && fsm_mem_ack) begin
      // Interrupt entry: latch the fetched trap vector (ISR entry address) so
      // CORE_INT_DONE can load it into the PC.
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
  assign fill_empty     = (fill_dx_q == 16'd0) || (fill_dy_q == 16'd0);
  // With CYCLE_ACCURATE the FILL works a word at a time (13.3.2.2): each
  // step writes the pixels from the current address to the next word
  // boundary or the end of the row. Otherwise one pixel per step.
  logic [15:0]           fill_step_px;
  logic [FIELD_SIZE_WIDTH-1:0] fill_step_bits;
  logic [15:0]           fill_word_px;
  // Pixels from the address to the next word boundary, registered the same
  // way as fill_rem_q (off the W=3 clip -> start address path): a step's
  // write acknowledge loads it from the next address, otherwise it follows
  // fill_addr_q a clock late.
  logic [15:0]           fill_word_px_q;
  logic [3:0]            fill_next_nib;
  assign fill_next_nib  = (fill_row_end && !fill_done)
                        ? (fill_row_base_q[3:0] + fill_dptch_q[3:0])
                        : fill_next_addr[3:0];
  always_ff @(posedge clk)
    if (state_q == CORE_FILL && fsm_mem_ack && fill_substep_q)
      fill_word_px_q <= {11'd0, 5'd16 - {1'b0, fill_next_nib}} >> pix_xy_xsh;
    else
      fill_word_px_q <= {11'd0, 5'd16 - {1'b0, fill_addr_q[3:0]}} >> pix_xy_xsh;
  assign fill_word_px   = fill_word_px_q;
  // Pixels left in the row, registered (off the W=3 clip -> DX path). A step's
  // write acknowledge updates it with fill_x_q, so it is current in the next
  // clock; otherwise it follows DX - X a clock late. The one late case is
  // W=3 preclipping (DX written in CORE_FILL_SETUP_WIN, CORE_FILL next):
  // the first access is held for the setup states then, so the stale value
  // never reaches a request.
  logic [15:0]           fill_rem_q;
  always_ff @(posedge clk)
    if (state_q == CORE_FILL && fsm_mem_ack && fill_substep_q)
      fill_rem_q <= fill_row_end ? fill_dx_q : fill_rem_q - fill_step_px;
    else
      fill_rem_q <= fill_dx_q - fill_x_q;
  // The step size itself is registered too (off the register-to-datapath
  // path): it is used no sooner than two clocks after its inputs change
  // (each step is followed by the checkpoint states; the first waits for the
  // setup states).
  logic [15:0]           fill_step_px_q;
  always_ff @(posedge clk)
    fill_step_px_q <= (fill_rem_q < fill_word_px) ? fill_rem_q : fill_word_px;
  assign fill_step_px   = !CYCLE_ACCURATE ? 16'd1 : fill_step_px_q;
  assign fill_step_bits = FIELD_SIZE_WIDTH'(fill_step_px << pix_xy_xsh);
  assign fill_row_end   = !fill_empty && (fill_x_q + fill_step_px == fill_dx_q);
  assign fill_done      = fill_row_end
                       && (fill_y_q == fill_dy_q - 16'd1);
  assign fill_next_addr = fill_addr_q + DATA_WIDTH'(fill_step_bits);
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
  // With CYCLE_ACCURATE, plane masking and transparency are applied by the
  // memory controller inside the write, a read-modify-write of each word
  // (13.3.2.5, Table 13-7); the CPU reads the destination only for a pixel
  // processing operation. PIXT, DRAV and LINE; FILL and PIXBLT still read it.
  logic                  pixel_cpu_dest_read;
  assign pixel_cpu_dest_read = CYCLE_ACCURATE
      ? (io_control[CTRL_PPOP_HI:CTRL_PPOP_LO] != 5'd0)
      : pixel_dest_read_required;

  // FILL XY: convert the XY DADDR (latched raw at EXECUTE) to a linear start
  // address at SETUP, where OFFSET (B4) is on read port 3. Same shift form as
  // CVXYL: ((Y<<(31-CONVDP)) | (X<<log2 PSIZE)) + OFFSET. Per the User's
  // Guide page 12-85, final DADDR remains the next linear address.
  logic [4:0]            fill_xy_yshift;
  logic [DATA_WIDTH-1:0] fill_xy_linear, fill_start;
  assign fill_xy_yshift = 5'd31 - io_convdp[4:0];
  assign fill_xy_linear =
      (({{16{fill_daddr_raw_q[DATA_WIDTH-1]}}, fill_daddr_raw_q[DATA_WIDTH-1:16]} << fill_xy_yshift)
       | ({16'b0, fill_daddr_raw_q[15:0]} << pix_xy_xsh))
      + rf_rs3_data;   // OFFSET (B4) at SETUP
  assign fill_start = fill_is_xy ? fill_xy_linear : fill_daddr_raw_q;
  // W=3 moves the start to the clipped corner, whose address the chip forms
  // with the same conversion; that corner lies in the window, so X >= 0
  // there (4.3: "the clipping window ... is restricted to positive X and Y").
  // The clipped start is this array's start plus the clip offsets, which
  // needs the start as a sum: with X sign-extended and added, the same value
  // as the OR form for any X the conversion can take (0 <= X*PSIZE < pitch),
  // and the clipped corner's address when the array starts left of X = 0.
  logic [DATA_WIDTH-1:0] fill_xy_sum, fill_sum_start, fill_sum_q;
  assign fill_xy_sum =
      (({{16{fill_daddr_raw_q[DATA_WIDTH-1]}}, fill_daddr_raw_q[DATA_WIDTH-1:16]} << fill_xy_yshift)
       + ({{16{fill_daddr_raw_q[15]}}, fill_daddr_raw_q[15:0]} << pix_xy_xsh))
      + rf_rs3_data;   // OFFSET (B4) at SETUP
  assign fill_sum_start = fill_is_xy ? fill_xy_sum : fill_daddr_raw_q;

  // FILL pixel processing (Task 0093). Modes that consume the old pixel use
  // step 0 to read it into fill_dest_q, then step 1 writes PPOP(COLOR1,dest)
  // with plane masking and transparency. The default replace/no-mask/no-T
  // path starts directly at step 1.
  logic                  fill_substep_q;   // 0 = read dest, 1 = write merged/direct
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
  // within the window. Containment is a single rectangle test on the array's
  // corners, evaluated combinationally at CORE_FILL_SETUP_WIN from the live
  // WSTART(port1)/WEND(port2) reads (X=[15:0], Y=[31:16]).
  logic                  fill_array_inside;
  // The window corners the clip is computed from: the live WSTART/WEND reads,
  // or with CYCLE_ACCURATE the registered ones, a clock later (the FSM stays
  // a second clock in CORE_FILL_SETUP_WIN; the setup states hold the first
  // access anyway). This keeps the register file out of the clip -> DX /
  // start-address path.
  logic [DATA_WIDTH-1:0] fill_win_s, fill_win_e;
  logic                  fill_win_eval_q;
  assign fill_win_s = CYCLE_ACCURATE ? fill_wstart_q : rf_rs1_data;
  assign fill_win_e = CYCLE_ACCURATE ? fill_wend_q   : rf_rs2_data;
  always_ff @(posedge clk)
    fill_win_eval_q <= !rst && CYCLE_ACCURATE && (state_q == CORE_FILL_SETUP_WIN)
                       && !fill_win_eval_q;
  logic [15:0]           fill_arr_x0, fill_arr_y0, fill_arr_x1, fill_arr_y1;
  assign fill_arr_x0 = fill_daddr_raw_q[15:0];
  assign fill_arr_y0 = fill_daddr_raw_q[DATA_WIDTH-1:16];
  assign fill_arr_x1 = fill_empty ? fill_arr_x0
                                  : fill_arr_x0 + fill_dx_q - 16'd1;
  assign fill_arr_y1 = fill_empty ? fill_arr_y0
                                  : fill_arr_y0 + fill_dy_q - 16'd1;
  assign fill_array_inside = !fill_empty
     &&
        ($signed(fill_arr_x0) >= $signed(fill_win_s[15:0])) && ($signed(fill_arr_x1) <= $signed(fill_win_e[15:0]))
     && ($signed(fill_arr_y0) >= $signed(fill_win_s[DATA_WIDTH-1:16])) && ($signed(fill_arr_y1) <= $signed(fill_win_e[DATA_WIDTH-1:16]));
  // W=3 preclipping is calculated from the live window read in
  // CORE_FILL_SETUP_WIN, before the first pixel request. The working start
  // becomes the top-left intersection and the working dimensions shrink to
  // the intersection. DADDR's architectural completion value is kept
  // separately from these internal working operands.
  logic                  fill_clip_hit;
  logic [15:0]           fill_clip_x0, fill_clip_y0;
  logic [15:0]           fill_clip_x1, fill_clip_y1;
  logic [15:0]           fill_clip_dx, fill_clip_dy;
  logic [15:0]           fill_clip_left, fill_clip_top;
  logic [DATA_WIDTH-1:0] fill_clip_left_bits, fill_clip_top_bits;
  logic [DATA_WIDTH-1:0] fill_clip_start, fill_original_result;
  assign fill_clip_hit = !fill_empty
      && ($signed(fill_win_s[15:0]) <= $signed(fill_win_e[15:0]))
      && ($signed(fill_win_s[DATA_WIDTH-1:16]) <= $signed(fill_win_e[DATA_WIDTH-1:16]))
      && !(
        ($signed(fill_arr_x1) < $signed(fill_win_s[15:0])) || ($signed(fill_arr_x0) > $signed(fill_win_e[15:0]))
     || ($signed(fill_arr_y1) < $signed(fill_win_s[DATA_WIDTH-1:16]))
     || ($signed(fill_arr_y0) > $signed(fill_win_e[DATA_WIDTH-1:16])));
  assign fill_clip_x0 = ($signed(fill_arr_x0) > $signed(fill_win_s[15:0]))
                      ? fill_arr_x0 : fill_win_s[15:0];
  assign fill_clip_y0 = ($signed(fill_arr_y0) > $signed(fill_win_s[DATA_WIDTH-1:16]))
                      ? fill_arr_y0 : fill_win_s[DATA_WIDTH-1:16];
  assign fill_clip_x1 = ($signed(fill_arr_x1) < $signed(fill_win_e[15:0]))
                      ? fill_arr_x1 : fill_win_e[15:0];
  assign fill_clip_y1 = ($signed(fill_arr_y1) < $signed(fill_win_e[DATA_WIDTH-1:16]))
                      ? fill_arr_y1 : fill_win_e[DATA_WIDTH-1:16];
  assign fill_clip_dx = fill_clip_hit
                      ? fill_clip_x1 - fill_clip_x0 + 16'd1 : 16'd0;
  assign fill_clip_dy = fill_clip_hit
                      ? fill_clip_y1 - fill_clip_y0 + 16'd1 : 16'd0;
  assign fill_clip_left = fill_clip_hit
                        ? fill_clip_x0 - fill_arr_x0 : 16'd0;
  assign fill_clip_top = fill_clip_hit
                       ? fill_clip_y0 - fill_arr_y0 : 16'd0;
  assign fill_clip_left_bits = {{16{1'b0}}, fill_clip_left} << pix_xy_xsh;
  assign fill_clip_top_bits =
      {{16{1'b0}}, fill_clip_top} << (5'd31 - io_convdp[4:0]);
  assign fill_clip_start = fill_sum_q
                         + fill_clip_left_bits + fill_clip_top_bits;
  assign fill_original_result = fill_addr_q
      + ({{16{1'b0}}, fill_dy_q - 16'd1} << (5'd31 - io_convdp[4:0]))
      + ({{16{1'b0}}, fill_dx_q} << pix_xy_xsh);
  // W=1 (hit detection/common rectangle): no pixels are drawn. The array
  // "hits" the window if it overlaps at all; computed from the LATCHED
  // WSTART/WEND (valid after CORE_FILL_SETUP_WIN). Inclusive corners. On a
  // hit FILL returns the lowest-address corner and intersection dimensions.
  logic fill_w1_q, fill_array_hit;
  logic [15:0] fill_common_x0, fill_common_y0;
  logic [15:0] fill_common_x1, fill_common_y1;
  logic [DATA_WIDTH-1:0] fill_common_daddr, fill_common_dydx;
  assign fill_array_hit = !fill_empty
      && ($signed(fill_wstart_q[15:0]) <= $signed(fill_wend_q[15:0]))
      && ($signed(fill_wstart_q[DATA_WIDTH-1:16]) <= $signed(fill_wend_q[DATA_WIDTH-1:16]))
      && !(
        ($signed(fill_arr_x1) < $signed(fill_wstart_q[15:0])) || ($signed(fill_arr_x0) > $signed(fill_wend_q[15:0]))
     || ($signed(fill_arr_y1) < $signed(fill_wstart_q[DATA_WIDTH-1:16])) || ($signed(fill_arr_y0) > $signed(fill_wend_q[DATA_WIDTH-1:16])));
  assign fill_common_x0 = ($signed(fill_arr_x0) > $signed(fill_wstart_q[15:0]))
                        ? fill_arr_x0 : fill_wstart_q[15:0];
  assign fill_common_y0 = ($signed(fill_arr_y0) > $signed(fill_wstart_q[DATA_WIDTH-1:16]))
                        ? fill_arr_y0 : fill_wstart_q[DATA_WIDTH-1:16];
  assign fill_common_x1 = ($signed(fill_arr_x1) < $signed(fill_wend_q[15:0]))
                        ? fill_arr_x1 : fill_wend_q[15:0];
  assign fill_common_y1 = ($signed(fill_arr_y1) < $signed(fill_wend_q[DATA_WIDTH-1:16]))
                        ? fill_arr_y1 : fill_wend_q[DATA_WIDTH-1:16];
  assign fill_common_daddr = {fill_common_y0, fill_common_x0};
  assign fill_common_dydx = {
      fill_common_y1 - fill_common_y0 + 16'd1,
      fill_common_x1 - fill_common_x0 + 16'd1
  };
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
                 || (pixt_win_wb && (((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1) && pixt_inside_q)
                                  || ((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2) && !pixt_inside_q)));
  // Word FILL datapath (CYCLE_ACCURATE): COLOR1, the destination read and
  // the plane mask at the step's position in its word; transparent pixels and
  // plane-masked bits are kept by the memory controller (13.3.2.5).
  logic [15:0] fill_step_mask, fill_word_color, fill_word_dest, fill_word_pmask;
  logic [15:0] fill_word_result, fill_word_keep;
  assign fill_step_mask   = 16'((32'd1 << fill_step_bits) - 32'd1);
  assign fill_word_color  = 16'(fill_color_q >> fill_addr_q[3:0]) & fill_step_mask;
  assign fill_word_dest   = fill_dest_q[15:0] & fill_step_mask;
  assign fill_word_pmask  = 16'({16'd0, pixel_plane_mask_q} >> fill_addr_q[3:0]) & fill_step_mask;
  assign fill_word_result = ppop_word(fill_word_color, fill_word_dest & ~fill_word_pmask,
                                      pixel_ppop_code_q, io_psize[FIELD_SIZE_WIDTH-1:0])
                          & fill_step_mask;
  assign fill_word_keep   = (fill_word_pmask
                             | (pixel_transp_en_q
                                ? zero_pixels(fill_word_result & ~fill_word_pmask,
                                              io_psize[FIELD_SIZE_WIDTH-1:0])
                                : 16'd0))
                          & fill_step_mask;
  assign fill_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
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
      fill_sum_q       <= '0;
      fill_row_base_q  <= '0;
      fill_result_q    <= '0;
      fill_x_q         <= '0;
      fill_y_q         <= '0;
      fill_substep_q   <= 1'b0;
      fill_dest_read_q <= 1'b0;
      fill_dest_q      <= '0;
      fill_wstart_q    <= '0;
      fill_wend_q      <= '0;
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
          fill_addr_q     <= rf_rs2_data;
          fill_row_base_q <= rf_rs2_data
                           - ({{16{1'b0}}, rf_rs3_data[15:0]}
                              << pix_xy_xsh);
          fill_x_q        <= rf_rs3_data[15:0];
          fill_y_q        <= rf_rs3_data[DATA_WIDTH-1:16];
        end else begin
          fill_daddr_raw_q <= rf_rs1_data;       // DADDR (linear, or XY)
          fill_dptch_q     <= rf_rs2_data;       // DPTCH
          fill_dx_q        <= rf_rs3_data[15:0]; // DX
          fill_dy_q        <= rf_rs3_data[DATA_WIDTH-1:16]; // DY
          fill_x_q         <= 16'd0;
          fill_y_q         <= 16'd0;
        end
        fill_win_en_q    <= fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd3);
        fill_w2_q        <= !array_resume && fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd2);
        fill_w1_q        <= !array_resume && fill_is_xy &&
                            (io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1);
        fill_dest_read_q <= pixel_cpu_dest_read;
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
        fill_substep_q <= !fill_dest_read_q;
      end
      // CORE_FILL_SETUP_WIN: latch WSTART(port1=B5)/WEND(port2=B6) for clip.
      if (state_q == CORE_FILL_SETUP_WIN) begin
        fill_wstart_q <= rf_rs1_data;
        fill_wend_q   <= rf_rs2_data;
        if (fill_win_en_q && (!CYCLE_ACCURATE || fill_win_eval_q)) begin
          fill_preclip_changed_q <= !fill_array_inside;
          fill_w3_empty_q        <= !fill_clip_hit;
          if (fill_clip_hit) begin
            fill_daddr_raw_q <= {fill_clip_y0, fill_clip_x0};
            fill_dx_q        <= fill_clip_dx;
            fill_dy_q        <= fill_clip_dy;
            fill_addr_q      <= fill_clip_start;
            fill_row_base_q  <= fill_clip_start;
          end
          fill_result_q <= fill_original_result;
        end
      end
      // CORE_FILL_SETUP: latch COLOR1 (port1) and the linear start address
      // (port3 = OFFSET for the XY conversion); start at the read sub-step.
      if (state_q == CORE_FILL_SETUP) begin
        fill_color_q    <= rf_rs1_data;        // COLOR1
        fill_addr_q     <= fill_start;
        fill_sum_q      <= fill_sum_start;
        fill_row_base_q <= fill_start;
        fill_result_q   <= fill_start;
        fill_substep_q  <= !fill_dest_read_q;
      end
      // CORE_FILL: direct replace writes start/stay at sub-step 1; all other
      // modes read at sub-step 0 before writing at sub-step 1.
      if (state_q == CORE_FILL && fsm_mem_ack) begin
        if (!fill_substep_q) begin
          // Read ack: latch the destination pixel for processing.
          fill_dest_q <= mem_rdata_eff;
          fill_substep_q <= 1'b1;
        end else begin
          fill_substep_q <= !fill_dest_read_q;
          // Write ack: advance to the next pixel (or to the final DADDR).
          fill_addr_q <= fill_next_addr;
          if (fill_row_end && !fill_done) begin
            // Row complete (not the last): jump to the next row's base.
            fill_y_q        <= fill_y_q + 16'd1;
            fill_row_base_q <= fill_row_base_q + fill_dptch_q;
            fill_addr_q     <= fill_row_base_q + fill_dptch_q;
            fill_x_q        <= 16'd0;
          end else if (!fill_done) begin
            fill_x_q <= fill_x_q + fill_step_px;
          end
          // On fill_done the write ack leaves fill_addr_q at the pixel
          // following the last (the final DADDR); the FSM moves to CORE_FILL_WB.
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
  logic [DATA_WIDTH-1:0] pblt_src_addr_q, pblt_dst_addr_q;
  logic [DATA_WIDTH-1:0] pblt_src_row_q, pblt_dst_row_q;
  logic [DATA_WIDTH-1:0] pblt_src_result_q, pblt_dst_result_q;
  logic [15:0]           pblt_x_q, pblt_y_q;
  logic [1:0]            pblt_substep_q;     // 0 read src, 1 read dst, 2 write
  logic                  pblt_dest_read_q;
  logic                  pblt_hrev_q, pblt_vrev_q, pblt_auto_corner_q;
  logic [DATA_WIDTH-1:0] pblt_src_pix_q, pblt_dst_pix_q;
  logic [DATA_WIDTH-1:0] pblt_psize_ext, pblt_pixel_mask;
  logic [DATA_WIDTH-1:0] pblt_src_pmask_field, pblt_pmask_field;
  logic                  pblt_empty, pblt_row_end, pblt_done;
  // PIXBLT B (color expand): COLOR0/COLOR1 latched at SETUP2; the source read is
  // 1 bit (fsm_mem_size 1, src step 1) and expands to COLOR1 / COLOR0.
  logic [DATA_WIDTH-1:0] pblt_color0_q, pblt_color1_q;
  logic [DATA_WIDTH-1:0] pblt_src_eff, pblt_src_step;
  assign pblt_psize_ext   = DATA_WIDTH'(io_psize[FIELD_SIZE_WIDTH-1:0]);
  assign pblt_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
  assign pblt_src_pmask_field = aligned_pmask(
      pixel_plane_mask_q, pblt_src_access_addr, pblt_pixel_mask);
  assign pblt_pmask_field = aligned_pmask(
      pixel_plane_mask_q, pblt_dst_access_addr, pblt_pixel_mask);
  assign pblt_empty       = (pblt_dx_q == 16'd0) || (pblt_dy_q == 16'd0);
  // With CYCLE_ACCURATE the full-color PIXBLTs work a destination word at a
  // time (13.4.2.2): each step moves the pixels up to the next destination
  // word boundary (in the PBH direction) or the end of the row. The source
  // words are read once each into a two-word buffer (13.4.2.4: the first
  // destination word needs one or two of them). Binary PIXBLTs and
  // CYCLE_ACCURATE=0 move a pixel per step.
  logic                  pbw_on;    // full-color word mode (source buffer)
  logic                  pbx_on;    // binary (expand) word mode
  logic                  pbw_word;  // either
  logic [15:0]           pbw_room_px, pbw_step_px;
  logic [FIELD_SIZE_WIDTH-1:0] pbw_step_bits;
  logic [DATA_WIDTH-1:0] pbw_dst_start, pbw_src_start;
  assign pbw_on        = CYCLE_ACCURATE && !decoded.blt_binary;
  assign pbx_on        = CYCLE_ACCURATE && decoded.blt_binary;
  assign pbw_word      = CYCLE_ACCURATE;
  // Pixels from the destination address to the next word boundary in the
  // PBH direction, registered as fill_word_px_q.
  function automatic logic [15:0] pbw_room(input logic [3:0] nib, input logic hrev,
                                           input logic [4:0] xsh);
    pbw_room = {11'd0, (hrev ? ((nib == 4'd0) ? 5'd16 : {1'b0, nib})
                             : (5'd16 - {1'b0, nib}))} >> xsh;
  endfunction
  logic [15:0]           pbw_room_q;
  logic [3:0]            pbw_next_nib;
  assign pbw_next_nib  = pblt_row_end
                       ? (pblt_dst_row_q[3:0] + pblt_dst_row_step[3:0])
                       : (pblt_hrev_q ? pblt_dst_addr_q[3:0] - 4'(pbw_step_bits)
                                      : pblt_dst_addr_q[3:0] + 4'(pbw_step_bits));
  always_ff @(posedge clk)
    if (state_q == CORE_PBLT && fsm_mem_ack && pblt_substep_q == 2'd2)
      pbw_room_q <= pbw_room(pbw_next_nib, pblt_hrev_q, pix_xy_xsh);
    else
      pbw_room_q <= pbw_room(pblt_dst_addr_q[3:0], pblt_hrev_q, pix_xy_xsh);
  assign pbw_room_px   = pbw_room_q;
  logic [15:0]           pblt_rem_q;      // pixels left in the row (as fill_rem_q;
                                          // W=3: CORE_PBLT_WIN_APPLY writes DX)
  always_ff @(posedge clk)
    if (state_q == CORE_PBLT && fsm_mem_ack && pblt_substep_q == 2'd2)
      pblt_rem_q <= pblt_row_end ? pblt_dx_q : pblt_rem_q - pbw_step_px;
    else
      pblt_rem_q <= pblt_dx_q - pblt_x_q;
  // Expand forms (13.5.2.3): the source is read in segments of up to 32
  // bits; a step also ends with its segment.
  logic [31:0]           pbx_bits_q;
  logic [5:0]            pbx_seg_q, pbx_pos_q;
  logic                  pbx_valid_q;
  logic [15:0]           pbx_seg_left, pbw_lim_px;
  assign pbx_seg_left  = {10'd0, pbx_seg_q - pbx_pos_q};
  assign pbw_lim_px    = (pblt_rem_q < pbw_room_px) ? pblt_rem_q : pbw_room_px;
  // Registered like fill_step_px_q: a full-color step is followed by the
  // checkpoint states, an expand step that ends mid-word by a segment read,
  // and the first step waits for the setup states.
  logic [15:0]           pbw_step_px_q;
  always_ff @(posedge clk)
    pbw_step_px_q <= (pbx_on && pbx_valid_q && (pbx_seg_left < pbw_lim_px)) ? pbx_seg_left
                   : pbw_lim_px;
  assign pbw_step_px   = !pbw_word ? 16'd1 : pbw_step_px_q;
  assign pbw_step_bits = FIELD_SIZE_WIDTH'(pbw_step_px << pix_xy_xsh);
  // Source bits a step uses: PSIZE per pixel, 1 for the expand forms.
  logic [FIELD_SIZE_WIDTH-1:0] pbw_src_bits;
  assign pbw_src_bits  = pbx_on ? FIELD_SIZE_WIDTH'(pbw_step_px) : pbw_step_bits;
  assign pbw_dst_start = pblt_hrev_q ? pblt_dst_addr_q - DATA_WIDTH'(pbw_step_bits)
                                     : pblt_dst_addr_q;
  assign pbw_src_start = pblt_hrev_q ? pblt_src_addr_q - DATA_WIDTH'(pbw_src_bits)
                                     : pblt_src_addr_q;
  assign pblt_row_end     = !pblt_empty
                          && (pblt_x_q + pbw_step_px == pblt_dx_q);

  // Source word buffer: the last two source words read, pbw_win_q (word
  // address) and pbw_win_q + 1. The source is read in sequence, one word per
  // destination word, and one more for a row's first destination word when
  // it needs two (13.4.2.4, D < S); Table 13-9 times every row that way.
  logic [ADDR_WIDTH-5:0] pbw_win_q, pbw_next_q, pbw_need_lo, pbw_need_hi, pbw_miss;
  logic [15:0]           pbw_lo_q, pbw_hi_q;
  logic [1:0]            pbw_reads_q;
  logic                  pbw_first_q, pbw_spans2, pbw_src_ready;
  logic [DATA_WIDTH-1:0] pbw_src_end;
  logic [5:0]            pbw_src_off;
  logic [15:0]           pbw_step_mask, pbw_src_chunk, pbw_src_pm, pbw_dst_pm;
  logic [15:0]           pbw_result, pbw_keep;
  assign pbw_src_end   = pbw_src_start + DATA_WIDTH'(pbw_step_bits) - 32'd1;
  assign pbw_need_lo   = pbw_src_start[ADDR_WIDTH-1:4];
  assign pbw_need_hi   = pbw_src_end[ADDR_WIDTH-1:4];
  // Whether the step's source bits cross a word boundary, from the 4 low
  // address bits instead of the two word addresses (timing: the word compare
  // after a 32-bit add was the worst path). The start is the source address
  // less the step's source bits when going backwards; the end is the start
  // plus the step's bits less one. Two addresses a few bits apart lie in the
  // same word exactly when their offsets from the word holding the source
  // address do, so this equals need_lo != need_hi for any address.
  logic signed [7:0] pbw_s_off, pbw_e_off;
  assign pbw_s_off  = $signed({4'd0, pblt_src_addr_q[3:0]})
                    - (pblt_hrev_q ? $signed({2'd0, pbw_src_bits}) : 8'sd0);
  assign pbw_e_off  = pbw_s_off + $signed({2'd0, pbw_step_bits}) - 8'sd1;
  assign pbw_spans2 = (pbw_s_off[7:4] != pbw_e_off[7:4]);
`ifdef VERILATOR
  // The simulation guards below check only after a reset has been seen (a
  // bench may run clocks before it asserts reset, with state not yet set).
  logic g_armed_q = 1'b0;
  always_ff @(posedge clk)
    if (rst) g_armed_q <= 1'b1;
  // Simulation guard: the same answer as the word addresses, every clock.
  always_ff @(posedge clk)
    if (g_armed_q && !rst && pbw_spans2 != (pbw_need_lo != pbw_need_hi)) begin
      $display("SPANS2 MISMATCH t=%0t addr %h bits %0d/%0d hrev %0d", $time,
               pblt_src_addr_q, pbw_src_bits, pbw_step_bits, pblt_hrev_q);
      $fatal(1);
    end
`endif
  assign pbw_src_ready = (pbw_reads_q == ((pbw_first_q && pbw_spans2) ? 2'd2 : 2'd1));
  // The word to read next: a row starts at its first word in the direction
  // of travel, then goes on in sequence.
  assign pbw_miss      = (pbw_first_q && pbw_reads_q == 2'd0)
                       ? (pblt_hrev_q ? pbw_need_hi : pbw_need_lo)
                       : pbw_next_q;
  assign pbw_src_off   = 6'({pbw_need_lo - pbw_win_q, 4'd0}) + {2'd0, pbw_src_start[3:0]};
  assign pbw_step_mask = 16'((32'd1 << pbw_step_bits) - 32'd1);
  assign pbw_src_chunk = 16'({pbw_hi_q, pbw_lo_q} >> pbw_src_off) & pbw_step_mask;
  // Plane mask at the source and destination positions (PMASK repeats every
  // word), as upstream applies it per pixel.
  assign pbw_src_pm    = 16'({pixel_plane_mask_q, pixel_plane_mask_q} >> pbw_src_start[3:0])
                       & pbw_step_mask;
  assign pbw_dst_pm    = 16'({16'd0, pixel_plane_mask_q} >> pbw_dst_start[3:0]) & pbw_step_mask;
  // Expand: COLOR1 where the source bit is 1, COLOR0 where it is 0, each at
  // the destination position (upstream's aligned_color), plane-masked with
  // the destination mask.
  logic [15:0] pbx_lanes, pbx_src;
  assign pbx_lanes = expand_bits(16'(pbx_bits_q >> pbx_pos_q), io_psize[FIELD_SIZE_WIDTH-1:0]);
  assign pbx_src   = ((16'(pblt_color1_q >> pbw_dst_start[3:0]) & pbx_lanes)
                    | (16'(pblt_color0_q >> pbw_dst_start[3:0]) & ~pbx_lanes))
                   & pbw_step_mask & ~pbw_dst_pm;
  assign pbw_result    = ppop_word(pbx_on ? pbx_src : (pbw_src_chunk & ~pbw_src_pm),
                                   pblt_dst_pix_q[15:0] & ~pbw_dst_pm,
                                   pixel_ppop_code_q, io_psize[FIELD_SIZE_WIDTH-1:0])
                       & pbw_step_mask;
  // With CYCLE_ACCURATE the write of a word step is raised on the first clock
  // of sub-step 2, as the guide's state timing has it, but its data and keep
  // mask come from registers: the first clock of the sub-step registers the
  // result and the masks, and the memory fabric takes the data and keep mask
  // one clock after it takes the request (mem_late), before the field
  // sequencer has started any word of the write. So the bus timer sees the
  // request at the same clock as with live data (no clocks taken out of the
  // memory's share of the cycle). Everything the result depends on (the
  // destination word read in sub-step 1, the buffered source words, the step,
  // PSIZE, CONTROL, PMASK) holds through sub-step 2, so the registers are
  // loaded in every clock of it and hold, in the clock after the write is
  // taken, what they held in that clock. Justification: timing only
  // (docs/dropin_measure.md).
  logic [15:0] pbw_result_q, pbw_dpm_q, pbw_smask_q;
  logic        pbw_late_q;      // the late write taken last clock was a word write
  logic        late_taken_q;    // a late write (mem_late) was taken last clock
  always_ff @(posedge clk) begin
    pbw_late_q   <= pbw_wr_step;
    late_taken_q <= !rst && mem_late && fsm_mem_req && fsm_mem_ack;
  end
  logic        pbw_wr_step;     // this clock is a word step's write sub-step
  assign pbw_wr_step = CYCLE_ACCURATE && pbw_word && (state_q == CORE_PBLT)
                    && (pblt_substep_q == 2'd2);
  // CONTROL.T and PSIZE are registered with the result too, so the late keep
  // mask uses the values of the clock the write was taken (a host write to
  // CONTROL or PSIZE can land in the clock after).
  logic                        pbw_transp_q;
  logic [FIELD_SIZE_WIDTH-1:0] pbw_psize_q;
  always_ff @(posedge clk) begin
    if (pbw_wr_step) begin
      pbw_result_q <= pbw_result;
      pbw_dpm_q    <= pbw_dst_pm;
      pbw_smask_q  <= pbw_step_mask;
      pbw_transp_q <= pixel_transp_en_q;
      pbw_psize_q  <= io_psize[FIELD_SIZE_WIDTH-1:0];
    end
  end
  assign pbw_keep      = (pbw_dpm_q
                          | (pbw_transp_q
                             ? zero_pixels(pbw_result_q & ~pbw_dpm_q, pbw_psize_q)
                             : 16'd0))
                       & pbw_smask_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      pbx_bits_q  <= '0;
      pbx_seg_q   <= '0;
      pbx_pos_q   <= '0;
      pbx_valid_q <= 1'b0;
    end else if ((state_q == CORE_EXECUTE && is_pblt)
                 || (state_q == CORE_PBLT && fsm_mem_ack && pblt_substep_q == 2'd2
                     && pblt_row_end)) begin
      pbx_valid_q <= 1'b0;
    end else if (pbx_on && state_q == CORE_PBLT && pblt_substep_q == 2'd0
                 && fsm_mem_req && fsm_mem_ack) begin
      pbx_bits_q  <= mem_rdata_eff;
      pbx_seg_q   <= 6'(fsm_mem_size);
      pbx_pos_q   <= '0;
      pbx_valid_q <= 1'b1;
    end else if (pbx_on && state_q == CORE_PBLT && fsm_mem_ack && pblt_substep_q == 2'd2) begin
      pbx_pos_q   <= pbx_pos_q + 6'(pbw_step_px);
      if (pbx_pos_q + 6'(pbw_step_px) == pbx_seg_q) pbx_valid_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pbw_win_q   <= '0;
      pbw_next_q  <= '0;
      pbw_lo_q    <= '0;
      pbw_hi_q    <= '0;
      pbw_reads_q <= '0;
      pbw_first_q <= 1'b0;
    end else if ((state_q == CORE_EXECUTE && is_pblt)
                 || (state_q == CORE_PBLT && fsm_mem_ack && pblt_substep_q == 2'd2
                     && pblt_row_end)) begin
      // A new PIXBLT, a resumed one, or a new row.
      pbw_reads_q <= '0;
      pbw_first_q <= 1'b1;
    end else if (state_q == CORE_PBLT && fsm_mem_ack && pblt_substep_q == 2'd2) begin
      pbw_reads_q <= '0;
      pbw_first_q <= 1'b0;
    end else if (pbw_on && state_q == CORE_PBLT && pblt_substep_q == 2'd0
                 && fsm_mem_req && fsm_mem_ack) begin
      pbw_reads_q <= pbw_reads_q + 2'd1;
      if (pblt_hrev_q) begin
        pbw_win_q  <= pbw_miss;
        pbw_hi_q   <= pbw_lo_q;
        pbw_lo_q   <= mem_rdata_eff[15:0];
        pbw_next_q <= pbw_miss - 1'b1;
      end else begin
        pbw_win_q  <= pbw_miss - 1'b1;
        pbw_lo_q   <= pbw_hi_q;
        pbw_hi_q   <= mem_rdata_eff[15:0];
        pbw_next_q <= pbw_miss + 1'b1;
      end
    end
  end
  assign pblt_done        = pblt_row_end
                          && (pblt_y_q == pblt_dy_q - 16'd1);
  // Effective source pixel: a binary source bit selects COLOR1/COLOR0.
  assign pblt_src_eff     = decoded.blt_binary
                          ? (aligned_color(
                               pblt_src_pix_q[0]
                                 ? pblt_color1_q : pblt_color0_q,
                               pblt_dst_access_addr, pblt_pixel_mask)
                             & ~pblt_pmask_field)
                          : (pblt_src_pix_q & ~pblt_src_pmask_field);
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
  // W=2 (miss detection): array containment test on the destination corners,
  // evaluated from WSTART/WEND after CORE_PBLT_SETUP_WIN registers both
  // operands. This keeps register-file selection out of the geometry path.
  logic        pblt_array_inside;
  logic [15:0] pblt_arr_x0, pblt_arr_y0, pblt_arr_x1, pblt_arr_y1;
  assign pblt_arr_x0 = pblt_dst_xy_raw_q[15:0];
  assign pblt_arr_y0 = pblt_dst_xy_raw_q[DATA_WIDTH-1:16];
  assign pblt_arr_x1 = pblt_empty ? pblt_arr_x0
                                  : pblt_arr_x0 + pblt_dx_q - 16'd1;
  assign pblt_arr_y1 = pblt_empty ? pblt_arr_y0
                                  : pblt_arr_y0 + pblt_dy_q - 16'd1;
  assign pblt_array_inside = !pblt_empty
     &&
        ($signed(pblt_arr_x0) >= $signed(pblt_wstart_q[15:0]))
     && ($signed(pblt_arr_x1) <= $signed(pblt_wend_q[15:0]))
     && ($signed(pblt_arr_y0) >= $signed(pblt_wstart_q[DATA_WIDTH-1:16]))
     && ($signed(pblt_arr_y1) <= $signed(pblt_wend_q[DATA_WIDTH-1:16]));
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
  logic [15:0]           pblt_clip_dx_q, pblt_clip_dy_q;
  logic [15:0]           pblt_clip_left_q, pblt_clip_top_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_left_bits, pblt_clip_dst_left_bits;
  logic [DATA_WIDTH-1:0] pblt_clip_src_top_bits, pblt_clip_dst_top_bits;
  logic [DATA_WIDTH-1:0] pblt_clip_src_default, pblt_clip_dst_default;
  logic [DATA_WIDTH-1:0] pblt_src_sum_q, pblt_dst_sum_q;  // the start as a sum (pblt_src_sum)
  logic [DATA_WIDTH-1:0] pblt_clip_src_h_adjust, pblt_clip_dst_h_adjust;
  logic [DATA_WIDTH-1:0] pblt_clip_src_v_adjust, pblt_clip_dst_v_adjust;
  logic [DATA_WIDTH-1:0] pblt_clip_src_default_q, pblt_clip_dst_default_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_h_adjust_q, pblt_clip_dst_h_adjust_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_v_adjust_q, pblt_clip_dst_v_adjust_q;
  logic [DATA_WIDTH-1:0] pblt_clip_src_corner, pblt_clip_dst_corner;
  logic [DATA_WIDTH-1:0] pblt_original_src_result, pblt_original_dst_result;
  assign pblt_clip_hit = !pblt_empty
      && ($signed(pblt_wstart_q[15:0]) <= $signed(pblt_wend_q[15:0]))
      && ($signed(pblt_wstart_q[DATA_WIDTH-1:16]) <= $signed(pblt_wend_q[DATA_WIDTH-1:16]))
      && !(
        ($signed(pblt_arr_x1) < $signed(pblt_wstart_q[15:0]))
     || ($signed(pblt_arr_x0) > $signed(pblt_wend_q[15:0]))
     || ($signed(pblt_arr_y1) < $signed(pblt_wstart_q[DATA_WIDTH-1:16]))
     || ($signed(pblt_arr_y0) > $signed(pblt_wend_q[DATA_WIDTH-1:16])));
  assign pblt_clip_x0 = ($signed(pblt_arr_x0) > $signed(pblt_wstart_q[15:0]))
                      ? pblt_arr_x0 : pblt_wstart_q[15:0];
  assign pblt_clip_y0 = ($signed(pblt_arr_y0) > $signed(pblt_wstart_q[DATA_WIDTH-1:16]))
                      ? pblt_arr_y0 : pblt_wstart_q[DATA_WIDTH-1:16];
  assign pblt_clip_x1 = ($signed(pblt_arr_x1) < $signed(pblt_wend_q[15:0]))
                      ? pblt_arr_x1 : pblt_wend_q[15:0];
  assign pblt_clip_y1 = ($signed(pblt_arr_y1) < $signed(pblt_wend_q[DATA_WIDTH-1:16]))
                      ? pblt_arr_y1 : pblt_wend_q[DATA_WIDTH-1:16];
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
  assign pblt_clip_src_default = pblt_src_sum_q
                                + pblt_clip_src_left_bits
                                + pblt_clip_src_top_bits;
  assign pblt_clip_dst_default = pblt_dst_sum_q
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
  assign pblt_original_src_result = pblt_src_result_q
      + ({{16{1'b0}}, pblt_dy_q} << (5'd31 - io_convsp[4:0]));
  assign pblt_original_dst_result = pblt_dst_result_q
      + ({{16{1'b0}}, pblt_dy_q} << (5'd31 - io_convdp[4:0]));
  // W=1 (hit detection/common rectangle): never draws; overlap and intersection
  // use the geometric top-left destination rectangle independently of PBH/PBV.
  // The returned DADDR then identifies the selected traversal corner for
  // full-color forms; binary-to-XY ignores PBH/PBV and returns top-left.
  logic pblt_w1_q, pblt_array_hit;
  logic [15:0] pblt_common_x0, pblt_common_y0;
  logic [15:0] pblt_common_x1, pblt_common_y1;
  logic [DATA_WIDTH-1:0] pblt_common_daddr, pblt_common_dydx;
  assign pblt_array_hit = !pblt_empty
      && ($signed(pblt_wstart_q[15:0]) <= $signed(pblt_wend_q[15:0]))
      && ($signed(pblt_wstart_q[DATA_WIDTH-1:16]) <= $signed(pblt_wend_q[DATA_WIDTH-1:16]))
      && !(
        ($signed(pblt_arr_x1) < $signed(pblt_wstart_q[15:0])) || ($signed(pblt_arr_x0) > $signed(pblt_wend_q[15:0]))
     || ($signed(pblt_arr_y1) < $signed(pblt_wstart_q[DATA_WIDTH-1:16])) || ($signed(pblt_arr_y0) > $signed(pblt_wend_q[DATA_WIDTH-1:16])));
  assign pblt_common_x0 = ($signed(pblt_arr_x0) > $signed(pblt_wstart_q[15:0]))
                        ? pblt_arr_x0 : pblt_wstart_q[15:0];
  assign pblt_common_y0 = ($signed(pblt_arr_y0) > $signed(pblt_wstart_q[DATA_WIDTH-1:16]))
                        ? pblt_arr_y0 : pblt_wstart_q[DATA_WIDTH-1:16];
  assign pblt_common_x1 = ($signed(pblt_arr_x1) < $signed(pblt_wend_q[15:0]))
                        ? pblt_arr_x1 : pblt_wend_q[15:0];
  assign pblt_common_y1 = ($signed(pblt_arr_y1) < $signed(pblt_wend_q[DATA_WIDTH-1:16]))
                        ? pblt_arr_y1 : pblt_wend_q[DATA_WIDTH-1:16];
  assign pblt_common_daddr = {
      pblt_vrev_q ? pblt_common_y1 : pblt_common_y0,
      pblt_hrev_q ? pblt_common_x1 : pblt_common_x0
  };
  assign pblt_common_dydx = {
      pblt_common_y1 - pblt_common_y0 + 16'd1,
      pblt_common_x1 - pblt_common_x0 + 16'd1
  };

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
  // The same conversions as sums (X sign-extended and added), for the W=3
  // clipped start: see fill_xy_sum.
  logic [DATA_WIDTH-1:0] pblt_src_sum, pblt_dst_sum;
  assign pblt_src_sum = decoded.blt_src_xy
      ? (({{16{pblt_src_addr_q[DATA_WIDTH-1]}}, pblt_src_addr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convsp[4:0]))
         + ({{16{pblt_src_addr_q[15]}}, pblt_src_addr_q[15:0]} << pix_xy_xsh)) + rf_rs3_data
      : pblt_src_addr_q;
  assign pblt_dst_sum = decoded.blt_dst_xy
      ? (({{16{pblt_dst_addr_q[DATA_WIDTH-1]}}, pblt_dst_addr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convdp[4:0]))
         + ({{16{pblt_dst_addr_q[15]}}, pblt_dst_addr_q[15:0]} << pix_xy_xsh)) + rf_rs3_data
      : pblt_dst_addr_q;

  // Full-color direction and corner adjustment (Task 0163).  Binary-source
  // PIXBLTs explicitly ignore PBH/PBV.  L,L consumes software-adjusted
  // starting corners; every full-color form containing an XY operand starts
  // from the default top-left address and receives automatic X/Y adjustment.
  // A reverse-X start points one pixel beyond the right edge because each
  // memory access predecrements by one pixel.
  logic [DATA_WIDTH-1:0] pblt_src_base, pblt_dst_base;
  logic [DATA_WIDTH-1:0] pblt_h_adjust;
  logic [DATA_WIDTH-1:0] pblt_src_v_adjust, pblt_dst_v_adjust;
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
  assign pblt_src_corner = pblt_src_base
                         + ((pblt_auto_corner_q && pblt_hrev_q)
                            ? pblt_h_adjust : 32'd0)
                         + ((pblt_auto_corner_q && pblt_vrev_q)
                            ? pblt_src_v_adjust : 32'd0);
  assign pblt_dst_corner = pblt_dst_base
                         + ((pblt_auto_corner_q && pblt_hrev_q)
                            ? pblt_h_adjust : 32'd0)
                         + ((pblt_auto_corner_q && pblt_vrev_q)
                            ? pblt_dst_v_adjust : 32'd0);
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
  // Word mode: the interrupt points are the destination word boundaries and
  // row ends (13.4.4); an expand step can end mid-word with its source
  // segment, and is not one.
  logic pbw_word_edge;
  assign pbw_word_edge = pblt_hrev_q ? (pbw_dst_start[3:0] == 4'd0)
                                     : ((pbw_dst_start[3:0] + 4'(pbw_step_bits)) == 4'd0);
  assign pblt_checkpoint_due = !pblt_done
      && (pblt_row_end
          || (pbw_word ? pbw_word_edge
                       : (pblt_hrev_q ? (pblt_dst_access_addr[3:0] == 4'd0)
                                      : (pblt_dst_after_addr[3:0] == 4'd0))));

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
      pblt_src_result_q <= '0;
      pblt_src_sum_q    <= '0;
      pblt_dst_sum_q    <= '0;
      pblt_dst_result_q <= '0;
      pblt_x_q        <= '0;
      pblt_y_q        <= '0;
      pblt_substep_q  <= 2'd0;
      pblt_dest_read_q <= 1'b0;
      pblt_hrev_q     <= 1'b0;
      pblt_vrev_q     <= 1'b0;
      pblt_auto_corner_q <= 1'b0;
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
      pblt_preclip_changed_q <= 1'b0;
      pblt_w3_empty_q <= 1'b0;
      pblt_resume_src_x_offset_q <= '0;
      pblt_resume_dst_x_offset_q <= '0;
      pblt_array_inside_q <= 1'b0;
      pblt_clip_hit_q <= 1'b0;
      pblt_clip_x0_q <= '0;
      pblt_clip_y0_q <= '0;
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
      // EXECUTE: latch SADDR(port1) / DADDR(port2) / DYDX(port3). Window
      // clipping engages only for an XY destination with CONTROL.W=3; keep the
      // raw XY DADDR (pblt_dst_addr_q is converted to linear at SETUP).
      if (state_q == CORE_EXECUTE && is_pblt) begin
        if (array_resume) begin
          // PBX re-entry reads {B0,B2,B10}. B0/B2 are the next actual
          // accesses and B10 is the next effective traversal cursor. Capture
          // those architectural values first; the four quiet resume states
          // below rebuild the engine's internal row/corner convention.
          pblt_src_addr_q <= rf_rs1_data;
          pblt_dst_addr_q <= rf_rs2_data;
          pblt_x_q <= rf_rs3_data[15:0];
          pblt_y_q <= rf_rs3_data[DATA_WIDTH-1:16];
        end else begin
          pblt_src_addr_q <= rf_rs1_data;          // SADDR
          pblt_src_row_q  <= rf_rs1_data;
          pblt_dst_addr_q <= rf_rs2_data;          // DADDR
          pblt_dst_row_q  <= rf_rs2_data;
          pblt_dst_xy_raw_q <= rf_rs2_data;        // raw XY DADDR (window)
          pblt_dx_q       <= rf_rs3_data[15:0];
          pblt_dy_q       <= rf_rs3_data[DATA_WIDTH-1:16];
          pblt_x_q        <= 16'd0;
          pblt_y_q        <= 16'd0;
        end
        pblt_substep_q  <= 2'd0;
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
        pblt_dest_read_q <= CYCLE_ACCURATE ? pixel_cpu_dest_read : pixel_dest_read_required;
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
        pblt_substep_q <= 2'd0;
      end
      // CORE_PBLT_SETUP_WIN: latch WSTART(port1=B5)/WEND(port2=B6) for clip.
      if (state_q == CORE_PBLT_SETUP_WIN) begin
        pblt_wstart_q <= rf_rs1_data;
        pblt_wend_q   <= rf_rs2_data;
      end
      if (state_q == CORE_PBLT_WIN_EVAL) begin
        // First stage: comparisons and 16-bit intersection geometry.
        pblt_array_inside_q <= pblt_array_inside;
        pblt_clip_hit_q     <= pblt_clip_hit;
        pblt_clip_x0_q      <= pblt_clip_x0;
        pblt_clip_y0_q      <= pblt_clip_y0;
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
        pblt_src_addr_q   <= pblt_src_corner;
        pblt_src_row_q    <= pblt_src_corner;
        pblt_dst_addr_q   <= pblt_dst_corner;
        pblt_dst_row_q    <= pblt_dst_corner;
        // Architectural completion context is based on the supplied
        // top-left/default address (or the software-adjusted L,L corner), not
        // on the internal directional traversal address.
        pblt_src_result_q <= pblt_src_base;
        pblt_dst_result_q <= pblt_dst_base;
        pblt_src_sum_q    <= pblt_src_sum;
        pblt_dst_sum_q    <= pblt_dst_sum;
      end
      // CORE_PBLT_SETUP2 (binary form): latch COLOR0(port1) / COLOR1(port2).
      if (state_q == CORE_PBLT_SETUP2) begin
        pblt_color0_q <= rf_rs1_data;
        pblt_color1_q <= rf_rs2_data;
      end
      // CORE_PBLT: per pixel, read src (0) / read dst (1) / write (2).
      if (pbw_on && state_q == CORE_PBLT && pblt_substep_q == 2'd0) begin
        // Word mode: read source words until the step's are buffered.
        if (pbw_src_ready)
          pblt_substep_q <= pblt_dest_read_q ? 2'd1 : 2'd2;
      end else if (pbx_on && state_q == CORE_PBLT && pblt_substep_q == 2'd0) begin
        // Expand word mode: read a source segment when none is loaded.
        if (pbx_valid_q)
          pblt_substep_q <= pblt_dest_read_q ? 2'd1 : 2'd2;
      end else if (state_q == CORE_PBLT && fsm_mem_ack) begin
        if (pblt_substep_q == 2'd0) begin
          pblt_src_pix_q <= mem_rdata_eff;
          pblt_substep_q <= pblt_dest_read_q ? 2'd1 : 2'd2;
        end else if (pblt_substep_q == 2'd1) begin
          pblt_dst_pix_q <= mem_rdata_eff;
          pblt_substep_q <= 2'd2;
        end else begin
          // Write ack: advance within a row or move the internal traversal
          // pointers by the selected signed row step.  Separate result
          // pointers advance geometrically by +pitch once per completed row,
          // which preserves the documented completion context for every
          // PBH/PBV selection.
          pblt_substep_q  <= 2'd0;
          if (pblt_row_end) begin
            pblt_src_row_q    <= pblt_src_row_q + pblt_src_row_step;
            pblt_dst_row_q    <= pblt_dst_row_q + pblt_dst_row_step;
            pblt_src_addr_q   <= pblt_src_row_q + pblt_src_row_step;
            pblt_dst_addr_q   <= pblt_dst_row_q + pblt_dst_row_step;
            if (!pblt_win_en_q) begin
              pblt_src_result_q <= pblt_src_result_q + pblt_sptch_q;
              pblt_dst_result_q <= pblt_dst_result_q + pblt_dptch_q;
            end
            if (!pblt_done) begin
              pblt_y_q <= pblt_y_q + 16'd1;
              pblt_x_q <= 16'd0;
            end
          end else if (!pblt_done) begin
            pblt_src_addr_q <= pblt_hrev_q
                             ? pblt_src_addr_q - (pbw_word ? DATA_WIDTH'(pbw_src_bits) : pblt_src_step)
                             : pblt_src_addr_q + (pbw_word ? DATA_WIDTH'(pbw_src_bits) : pblt_src_step);
            pblt_dst_addr_q <= pblt_hrev_q
                             ? pblt_dst_addr_q - (pbw_word ? DATA_WIDTH'(pbw_step_bits) : pblt_psize_ext)
                             : pblt_dst_addr_q + (pbw_word ? DATA_WIDTH'(pbw_step_bits) : pblt_psize_ext);
            pblt_x_q        <= pblt_x_q + pbw_step_px;
          end
        end
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
  logic                  drav_substep_q;    // 0 = read dest, 1 = write merged
  logic                  drav_dest_read_q;
  // Per-pixel window check (CONTROL.W, Task 0112). Rd's XY is tested against the
  // inclusive [WSTART..WEND] rectangle (read at CORE_DRAV_SETUP_WIN). The pixel
  // is drawn only for W=0, or W=2/W=3 when inside. V (W!=0) = NOT inside; WVP is
  // requested for W=1 inside (hit) or W=2 outside (miss). The advance always
  // happens. Reuses the shared fill_win_flag_wb / wvp_set V-write path.
  logic [1:0]            drav_w_q;          // CONTROL.W latched at EXECUTE
  logic                  drav_inside_q;     // Rd's pixel lies inside the window
  logic                  drav_in_window;    // combinational test at SETUP_WIN
  assign drav_in_window =
        ($signed(drav_rd_q[15:0]) >= $signed(rf_rs1_data[15:0])) && ($signed(drav_rd_q[15:0]) <= $signed(rf_rs2_data[15:0]))
     && ($signed(drav_rd_q[DATA_WIDTH-1:16]) >= $signed(rf_rs1_data[DATA_WIDTH-1:16]))
     && ($signed(drav_rd_q[DATA_WIDTH-1:16]) <= $signed(rf_rs2_data[DATA_WIDTH-1:16]));
  logic [DATA_WIDTH-1:0] drav_pixel_mask, drav_pmask_field;
  logic [DATA_WIDTH-1:0] drav_advance;
  assign drav_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
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
      drav_substep_q <= 1'b0;
      drav_dest_read_q <= 1'b0;
      drav_w_q       <= 2'd0;
      drav_inside_q  <= 1'b0;
    end else begin
      if (state_q == CORE_EXECUTE && is_drav) begin
        drav_rd_q      <= rf_rs2_data;        // Rd (XY dest)
        drav_rs_q      <= rf_rs1_data;        // Rs (XY increment)
        drav_linear_q  <= pix_xy_dst_linear;  // convert(Rd) + OFFSET (port3)
        drav_substep_q <= !pixel_cpu_dest_read;
        drav_dest_read_q <= pixel_cpu_dest_read;
        drav_w_q       <= io_control[CTRL_W_HI:CTRL_W_LO];
      end
      // CORE_DRAV_SETUP_WIN is also the unconditional COLOR1 capture cycle:
      // ports 1/2 read WSTART/WEND and port 3 reads B9.
      if (state_q == CORE_DRAV_SETUP_WIN) begin
        drav_inside_q <= drav_in_window;
        drav_color_q  <= rf_rs3_data;
      end
      if (state_q == CORE_DRAV && fsm_mem_ack) begin
        if (!drav_substep_q) begin
          drav_dest_q    <= mem_rdata_eff;  // read ack
          drav_substep_q <= 1'b1;
        end else begin
          drav_substep_q <= !drav_dest_read_q;
        end
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
  logic                  line_substep_q;
  logic                  line_dest_read_q;
  // Per-pixel linear address from DADDR's XY (same conversion form as FILL XY).
  logic [DATA_WIDTH-1:0] line_linear;
  assign line_linear =
      (({{16{line_daddr_q[DATA_WIDTH-1]}}, line_daddr_q[DATA_WIDTH-1:16]} << (5'd31 - io_convdp[4:0]))
       | ({16'b0, line_daddr_q[15:0]} << pix_xy_xsh)) + line_offset_q;
  // Pixel merge (PPOP / transparency / PMASK), COLOR1 = line_color_q.
  logic [DATA_WIDTH-1:0] line_pixel_mask, line_pmask_field;
  assign line_pixel_mask  = (32'd1 << io_psize[FIELD_SIZE_WIDTH-1:0]) - 32'd1;
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
  // Draw decision: W=1 (hit) draws no pixels and aborts on an inside pixel
  // ("calculates points but no pixels are actually drawn", SPVU001A 12-101,
  // 7.10.1); W=2 (miss) and W=3 (clip) draw INSIDE pixels (W=2 aborts on an
  // outside pixel, W=3 just inhibits it). V at the end is NOT last-inside for
  // every windowed mode; WVP is set on a W=1/W=2 abort.
  assign line_draw_pixel = (line_w_mode == 2'd1) ? 1'b0 : line_in_window;
  assign line_clip_out   = line_win_en && !line_draw_pixel;
  assign line_abort      = (line_w_mode == 2'd1 &&  line_in_window)
                         || (line_w_mode == 2'd2 && !line_in_window);
  // With CYCLE_ACCURATE a pixel the window leaves undrawn makes no access:
  // the chip only calculates it (Table 12-10, q). Upstream reads and writes
  // back every pixel of a windowed line.
  logic        line_skip;
  assign line_skip = CYCLE_ACCURATE && line_win_en && !line_draw_pixel;
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
        line_substep_q <= !(pixel_cpu_dest_read || (line_win_en && !CYCLE_ACCURATE));
        line_dest_read_q <= pixel_cpu_dest_read || (line_win_en && !CYCLE_ACCURATE);
      end
      if (state_q == CORE_LINE_DRAW && line_skip) begin
        // A pixel the window leaves undrawn: no access, same bookkeeping as
        // a drawn pixel's write acknowledge.
        line_substep_q     <= !line_dest_read_q;
        line_last_inside_q <= line_in_window;
        if (line_abort) line_aborted_q <= 1'b1;
        line_d_q     <= line_d_next;
        line_daddr_q <= line_daddr_next;
        line_count_q <= line_count_next;
      end else if (state_q == CORE_LINE_DRAW && fsm_mem_ack) begin
        if (!line_substep_q) begin
          line_dest_q <= mem_rdata_eff;              // read ack
          line_substep_q <= 1'b1;
        end else begin
          line_substep_q <= !line_dest_read_q;
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
  //   is cleared after each fsm_mem_ack.
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
  logic [3:0]            mm_mask_idx;
  logic [3:0]            mm_iter_idx;
  logic                  mm_mask_will_be_empty;
  logic                  is_mmtm, is_mmfm, is_mm;

  assign is_mmtm = (decoded.iclass == INSTR_MMTM);
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
  // After we clear the bit at mm_iter_idx, will the mask be empty? Gates
  // the FSM transition (last transaction → WRITEBACK) and, for MMTM,
  // suppresses the final Rp-decrement.
  // Next value of mm_mask_q (the register below loads it), also used by the
  // registered read-port addresses.
  logic [15:0] mm_mask_d;
  always_comb begin
    mm_mask_d = mm_mask_q;
    if (state_q == CORE_EXECUTE && state_d == CORE_MEMORY && is_mm)
      mm_mask_d = imm_lo_q;
    else if (state_q == CORE_MEMORY && is_mm && fsm_mem_ack)
      mm_mask_d[mm_mask_idx] = 1'b0;
  end
  assign mm_mask_will_be_empty =
      ((mm_mask_q & ~(16'd1 << mm_mask_idx)) == 16'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      mm_rp_q   <= '0;
      mm_mask_q <= '0;
    end else if (state_q == CORE_EXECUTE
              && state_d == CORE_MEMORY
              && is_mm) begin
      // First entry to CORE_MEMORY: capture the mask and seed the
      // working Rp. MMTM predecrements (first push at Rp-32); MMFM
      // starts at Rp (first read at Rp).
      mm_rp_q   <= is_mmtm ? (rf_rs2_data - WORD_BIT_SIZE) : rf_rs2_data;
      mm_mask_q <= mm_mask_d;
    end else if (state_q == CORE_MEMORY
              && is_mm
              && fsm_mem_ack) begin
      mm_mask_q <= mm_mask_d;
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
      if (state_q == CORE_FETCH_IMM_LO && fsm_mem_ack) begin
        imm_lo_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_HI && fsm_mem_ack) begin
        imm_hi_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_EXT_LO && fsm_mem_ack) begin
        imm_ext_lo_q <= mem_rdata_eff[INSTR_WORD_WIDTH-1:0];
      end
      if (state_q == CORE_FETCH_IMM_EXT_HI && fsm_mem_ack) begin
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
  logic                   div_suppress_wb;

  // ALU ports.
  alu_op_t                alu_op;
  logic [DATA_WIDTH-1:0]  alu_a;
  logic [DATA_WIDTH-1:0]  alu_b;
  logic                   alu_cin;
  logic [DATA_WIDTH-1:0]  alu_result;
  alu_flags_t             alu_flags;

  // Status-register ports.
  logic                   st_flag_update_en;
  logic                   st_write_en;
  logic [DATA_WIDTH-1:0]  st_write_data;
  logic [DATA_WIDTH-1:0]  st_value;
  logic                   st_n, st_c, st_z, st_v;

  // Shifter ports.
  logic [DATA_WIDTH-1:0]  shifter_result;
  alu_flags_t             shifter_flags;

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
  assign is_fill    = (decoded.iclass == INSTR_FILL_L) || (decoded.iclass == INSTR_FILL_XY);
  assign fill_is_xy = (decoded.iclass == INSTR_FILL_XY);
  // PIXBLT reads its 5 implied B-file operands across two cycles: at EXECUTE —
  // SADDR(B0) on port1, DADDR(B2) on port2, DYDX(B7) on port3; at
  // CORE_PBLT_SETUP — SPTCH(B1) on port1, DPTCH(B3) on port2.
  assign is_pblt    = (decoded.iclass == INSTR_PIXBLT_LL);
  assign array_resume = (is_fill || is_pblt) && st_value[ST_PBX_BIT];
  // DRAV: at EXECUTE — Rs on port1, Rd on port2, OFFSET(B4) on port3 (for the
  // XY->linear conversion of Rd); in CORE_DRAV — COLOR1(B9) on port1.
  logic is_drav;
  assign is_drav    = (decoded.iclass == INSTR_DRAV);
  // LINE: 3 setup cycles read the implied B operands —
  //   SETUP1: d(B0)/DYDX(B7)/COUNT(B10);  SETUP2: INC1(B11)/INC2(B12)/OFFSET(B4);
  //   SETUP3: DADDR(B2)/COLOR1(B9).  All reads are from the B file.
  logic is_line;
  assign is_line    = (decoded.iclass == INSTR_LINE);
  logic is_emu;
  assign is_emu     = (decoded.iclass == INSTR_EMU);
  logic line_rd_b;   // LINE is doing B-file setup reads this cycle
  assign line_rd_b  = is_line && ((state_q == CORE_LINE_SETUP1)
                               || (state_q == CORE_LINE_SETUP2)
                               || (state_q == CORE_LINE_SETUP3)
                               || (state_q == CORE_LINE_SETUP_WIN));

  // Register-file read-port addresses. They are a function of the state, the
  // decoded instruction, the MMTM/MMFM mask and ST.PBX only, so they are
  // registered from the next values of those (state_d, the decode capture,
  // mm_mask_d, the ST write) and equal the same function of the current
  // values on every clock; the read ports then start at a register instead of
  // at the decode/state logic. The function body is the earlier port logic
  // unchanged. Justification: timing only (docs/dropin_measure.md).
  typedef struct packed {
    reg_file_t f1; reg_idx_t i1;
    reg_file_t f2; reg_idx_t i2;
    reg_file_t f3; reg_idx_t i3;
  } rf_addr_t;
  function automatic rf_addr_t rf_addr_fn(input core_state_t st, input decoded_instr_t dc,
                                          input logic [15:0] mmask, input logic pbx);
    rf_addr_t r;
    logic f_fill, f_pblt, f_ar, f_drav, f_line, f_lrb, f_mmtm, f_mmfm;
    logic [3:0] f_mmidx, f_mmiter;
    f_fill = (dc.iclass == INSTR_FILL_L) || (dc.iclass == INSTR_FILL_XY);
    f_pblt = (dc.iclass == INSTR_PIXBLT_LL);
    f_ar   = (f_fill || f_pblt) && pbx;
    f_drav = (dc.iclass == INSTR_DRAV);
    f_line = (dc.iclass == INSTR_LINE);
    f_lrb  = f_line && ((st == CORE_LINE_SETUP1) || (st == CORE_LINE_SETUP2)
                     || (st == CORE_LINE_SETUP3) || (st == CORE_LINE_SETUP_WIN));
    f_mmtm = (dc.iclass == INSTR_MMTM);
    f_mmfm = (dc.iclass == INSTR_MMFM);
    f_mmidx = 4'd0;
    for (int i = 0; i < 16; i++) if (mmask[i]) f_mmidx = i[3:0];
    f_mmiter = f_mmfm ? f_mmidx : (4'd15 - f_mmidx);
    r.f1 = f_lrb ? REG_FILE_B
                       : (st == CORE_PIXT_SETUP_WIN) ? REG_FILE_B
                       : (f_drav && ((st == CORE_DRAV) || (st == CORE_DRAV_SETUP_WIN))) ? REG_FILE_B
                       : (f_fill || f_pblt) ? REG_FILE_B
                       : (dc.iclass == INSTR_MOVE_RR) ? dc.rs_file
                       : dc.rd_file;
    // Read-port 1 index is normally dc.rs_idx. MMTM repurposes it
    // during CORE_MEMORY to scan the register list — rf_rs1_idx then
    // points at the current register being pushed, and rf_rs1_data
    // becomes the 32-bit value driven onto fsm_mem_wdata.
    r.i1 = ((f_fill || f_pblt) && f_ar)
                       ? ((st == CORE_ARRAY_RESUME1) ? B_SPTCH_IDX
                        : (st == CORE_ARRAY_RESUME2) ? reg_idx_t'(12)
                        : (st == CORE_ARRAY_RESUME3) ? CPW_WSTART_IDX
                        : (st == CORE_ARRAY_RESUME4) ? B_COLOR0_IDX
                                                         : B_SADDR_IDX)
                       : f_fill ? ((st == CORE_FILL_SETUP_WIN) ? CPW_WSTART_IDX
                                  : (st == CORE_FILL_SETUP) ? B_COLOR1_IDX : B_DADDR_IDX)
                       : f_pblt ? ((st == CORE_PBLT_SETUP_WIN) ? CPW_WSTART_IDX
                                  : (st == CORE_PBLT_SETUP2) ? B_COLOR0_IDX
                                  : (st == CORE_PBLT_SETUP)  ? B_SPTCH_IDX : B_SADDR_IDX)
                       : (st == CORE_MEMORY && f_mmtm) ? f_mmiter
                       : (f_drav && (st == CORE_DRAV_SETUP_WIN)) ? CPW_WSTART_IDX // WSTART
                       : (f_drav && (st == CORE_DRAV)) ? B_COLOR1_IDX  // COLOR1 for the draw
                       : (f_line && (st == CORE_LINE_SETUP1)) ? B_SADDR_IDX   // d (B0)
                       : (f_line && (st == CORE_LINE_SETUP2)) ? B_INC1_IDX    // INC1 (B11)
                       : (f_line && (st == CORE_LINE_SETUP3)) ? B_DADDR_IDX   // DADDR (B2)
                       : (f_line && (st == CORE_LINE_SETUP_WIN)) ? CPW_WSTART_IDX // WSTART (B5)
                       : (st == CORE_PIXT_SETUP_WIN) ? CPW_WSTART_IDX           // PIXT WSTART
                       : dc.rs_idx;
    // Read port 2 normally reads Rd. CPW repurposes it (Rd is not a source
    // for CPW) to read the window-start register WSTART = B5; read port 3
    // reads the window-end register WEND = B6. Both are fixed B-file
    // registers per SPVU001A page 12-57. FILL: B3 (DPTCH) / B7 (DYDX).
    // PIXBLT: DADDR(B2) at EXECUTE, DPTCH(B3) at SETUP.
    r.f2 = (f_lrb || f_fill || f_pblt || (dc.iclass == INSTR_CPW)
                          || (st == CORE_PIXT_SETUP_WIN)
                          || (f_drav && (st == CORE_DRAV_SETUP_WIN)))
                       ? REG_FILE_B : dc.rd_file;
    r.i2 = ((f_fill || f_pblt) && f_ar)
                       ? ((st == CORE_ARRAY_RESUME1) ? B_DPTCH_IDX
                        : (st == CORE_ARRAY_RESUME2) ? reg_idx_t'(13)
                        : (st == CORE_ARRAY_RESUME3) ? CPW_WEND_IDX
                        : (st == CORE_ARRAY_RESUME4) ? B_COLOR1_IDX
                                                         : B_DADDR_IDX)
                       : f_fill ? ((st == CORE_FILL_SETUP_WIN) ? CPW_WEND_IDX : B_DPTCH_IDX)
                       : f_pblt ? ((st == CORE_PBLT_SETUP_WIN) ? CPW_WEND_IDX
                                  : (st == CORE_PBLT_SETUP2) ? B_COLOR1_IDX
                                  : (st == CORE_PBLT_SETUP)  ? B_DPTCH_IDX : B_DADDR_IDX)
                       : (f_drav && (st == CORE_DRAV_SETUP_WIN)) ? CPW_WEND_IDX  // WEND
                       : (f_line && (st == CORE_LINE_SETUP1)) ? B_DYDX_IDX    // DYDX (B7)
                       : (f_line && (st == CORE_LINE_SETUP2)) ? B_INC2_IDX    // INC2 (B12)
                       : (f_line && (st == CORE_LINE_SETUP3)) ? B_COLOR1_IDX  // COLOR1 (B9)
                       : (f_line && (st == CORE_LINE_SETUP_WIN)) ? CPW_WEND_IDX // WEND (B6)
                       : (st == CORE_PIXT_SETUP_WIN) ? CPW_WEND_IDX             // PIXT WEND
                       : (dc.iclass == INSTR_CPW) ? CPW_WSTART_IDX : dc.rd_idx;
    // Read port 3: CPW reads WEND (B6); DIVU/DIVS (even Rd) read the low half
    // of the 64-bit dividend, Rd+1; CVXYL/XY-PIXT read OFFSET (B4); FILL/PIXBLT
    // read DYDX (B7) at EXECUTE. Otherwise unused.
    r.f3 = ((dc.iclass == INSTR_DIVU) || (dc.iclass == INSTR_DIVS))
                       ? dc.rd_file : REG_FILE_B;
    r.i3 = ((dc.iclass == INSTR_DIVU) || (dc.iclass == INSTR_DIVS))
                       ? (dc.rd_idx + 4'd1)
                       : (f_drav && (st == CORE_DRAV_SETUP_WIN))
                       ? B_COLOR1_IDX
                       : ((f_fill || f_pblt) && f_ar)
                       ? ((st == CORE_ARRAY_RESUME1) ? reg_idx_t'(11)
                        : (st == CORE_ARRAY_RESUME2) ? reg_idx_t'(14)
                        : (st == CORE_ARRAY_RESUME3) ? B_DYDX_IDX
                                                         : B_COUNT_IDX)
                       : f_fill ? ((st == CORE_FILL_SETUP) ? B_OFFSET_IDX : B_DYDX_IDX)
                       : f_pblt ? ((st == CORE_PBLT_SETUP) ? B_OFFSET_IDX : B_DYDX_IDX)
                       : (f_line && (st == CORE_LINE_SETUP1)) ? B_COUNT_IDX   // COUNT (B10)
                       : (f_line && (st == CORE_LINE_SETUP2)) ? B_OFFSET_IDX  // OFFSET (B4)
                       : ((dc.iclass == INSTR_CVXYL) || dc.xy_addr || f_drav) ? B_OFFSET_IDX
                       : CPW_WEND_IDX;
    return r;
  endfunction

  rf_addr_t       rf_addr_q;
  decoded_instr_t decoded_next;
  logic           st_pbx_next;
  assign decoded_next = (state_q == CORE_DECODE_WAIT) ? decoded_comb : decoded;
  assign st_pbx_next  = st_write_en ? st_write_data[ST_PBX_BIT] : st_value[ST_PBX_BIT];
  always_ff @(posedge clk) begin
    if (rst) rf_addr_q <= rf_addr_fn(CORE_RESET, '0, 16'd0, ST_RESET_VALUE[ST_PBX_BIT]);
    else     rf_addr_q <= rf_addr_fn(state_d, decoded_next, mm_mask_d, st_pbx_next);
  end
  assign rf_rs1_file = rf_addr_q.f1;
  assign rf_rs1_idx  = rf_addr_q.i1;
  assign rf_rs2_file = rf_addr_q.f2;
  assign rf_rs2_idx  = rf_addr_q.i2;
  assign rf_rs3_file = rf_addr_q.f3;
  assign rf_rs3_idx  = rf_addr_q.i3;
`ifdef VERILATOR
  // Simulation guard: the registered addresses must equal the function of
  // the current state on every clock.
  always_ff @(posedge clk)
    if (g_armed_q && !rst && rf_addr_q != rf_addr_fn(state_q, decoded, mm_mask_q, st_value[ST_PBX_BIT])) begin
      $display("RFADDR MISMATCH t=%0t state=%0d q=%h now=%h", $time, state_q, rf_addr_q,
               rf_addr_fn(state_q, decoded, mm_mask_q, st_value[ST_PBX_BIT]));
      $fatal(1);
    end
`endif

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
  // branch decision. alu_result at WRITEBACK is the decremented Rd
  // (when iclass is one of the DSJ family).
  logic dsj_rd_nonzero;
  assign dsj_rd_nonzero = (alu_result != '0);

  // Writeback enable is a one-cycle pulse, gated by the FSM state.
  // Writeback data and flag-input come from either the ALU or the
  // shifter depending on `decoded.use_shifter`. For DSJEQ/DSJNE the
  // dsj_precondition further gates the write: if Z doesn't match the
  // pre-condition the spec mandates Rd is left unchanged.
  // MMFM writes a popped register on every CORE_MEMORY ack (mem_rdata_eff is
  // valid in the same cycle fsm_mem_ack asserts). This is a second user of
  // the single regfile write port, active in CORE_MEMORY rather than
  // CORE_WRITEBACK; the final-Rp write still happens at WRITEBACK below.
  // Rp is never in the list (spec: "unpredictable results"), so the two
  // writes never target the same index.
  logic mmfm_pop_wr;
  assign mmfm_pop_wr = (state_q == CORE_MEMORY) && is_mmfm && fsm_mem_ack;

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
  logic [DATA_WIDTH-1:0] mv_addr_q, mv_store_data_q;
  logic                  mv_load_ptr_wr;
  assign is_mv_store = (decoded.iclass == INSTR_MOVE_FIELD_STORE);
  assign is_mv_load  = (decoded.iclass == INSTR_MOVE_FIELD_LOAD);
  assign mv_postinc  = (decoded.move_mode == MV_ADDR_POSTINC);
  assign mv_predec   = (decoded.move_mode == MV_ADDR_PREDEC);
  assign mv_incdec   = mv_postinc || mv_predec;
  assign mv_ptr      = is_mv_store ? rf_rs2_data : rf_rs1_data;
  assign mv_load_ptr_wr = (state_q == CORE_MEMORY) && is_mv_load
                       && mv_incdec && fsm_mem_ack;

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
  assign mv_read_data = (decoded.force_pixel && is_mv_load)
                      ? (mem_rdata_eff
                         & ~aligned_pmask(io_pmask, mv_addr_q, mv_fmask))
                      : mem_rdata_eff;
  // The FS=32 arm below bypasses this index; for FS=1..31, five bits address
  // the selected sign bit without an implicit 6-to-5-bit truncation.
  assign mv_sign_bit_idx = mv_fs[4:0] - 5'd1;
  always_comb begin
    if (mv_fs >= FIELD_SIZE_WIDTH'(DATA_WIDTH)) begin
      mv_load_data = mv_read_data;                          // FS = 32: identity
    end else if (mv_fe && mv_read_data[mv_sign_bit_idx]) begin
      mv_load_data = mv_read_data | ~mv_fmask;              // sign-extend
    end else begin
      mv_load_data = mv_read_data & mv_fmask;               // zero-extend
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
  // With CYCLE_ACCURATE a windowed XY store decides at CORE_PIXT_SETUP_WIN
  // and, when it draws, is a plain store: the chip reads nothing for the
  // window and writes nothing when the pixel is not drawn (12-194).
  assign pixt_rmw         = decoded.force_pixel && is_mv_store
                          && (pixel_cpu_dest_read
                              || (pixt_xy_win && !CYCLE_ACCURATE));
  assign pixt_m2m         = decoded.force_pixel
                          && (decoded.iclass == INSTR_MOVE_FIELD_M2M);
  assign pixt_m2m_rmw     = pixt_m2m && pixel_cpu_dest_read;
  assign pixt_dest_address = pixt_m2m ? m2m_dst_addr_q : mv_addr_q;
  assign pixt_source_pmask_field =
      aligned_pmask(pixel_plane_mask_q, m2m_src_addr_q, mv_fmask);
  assign pixt_pmask_field =
      aligned_pmask(pixel_plane_mask_q, pixt_dest_address, mv_fmask);
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
      pixel_ppop_inhibit = pblt_clip_out;
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
    pixel_ppop_dest = pixel_ppop_raw_dest & ~pixel_ppop_pmask;
  end
  assign pixel_ppop_result =
      ppop_apply(pixel_ppop_src, pixel_ppop_dest,
                 pixel_ppop_code_q, pixel_ppop_fmask);
  // Architectural ordering is source/destination plane mask, PPOP, result
  // mask, then transparency. A protected-only result is transparent.
  assign pixel_ppop_transp = pixel_transp_en_q
      && ((pixel_ppop_result & ~pixel_ppop_pmask
           & pixel_ppop_fmask) == '0);
  assign pixel_ppop_merged = (pixel_ppop_transp || pixel_ppop_inhibit)
      ? pixel_ppop_raw_dest
      : ((pixel_ppop_result & ~pixel_ppop_pmask)
         | (pixel_ppop_raw_dest & pixel_ppop_pmask));
  // The same merge done by the memory controller: the pixel bits it keeps.
  // Outside them the merged value is the result, so the CPU need not have
  // read the destination.
  // Table 13-7 times the write as a read-modify-write whenever plane
  // masking or transparency is enabled, whatever the pixel values.
  logic [DATA_WIDTH-1:0] pixel_keep;
  logic                  pixel_rmw;
  assign pixel_keep = (pixel_ppop_transp || pixel_ppop_inhibit)
                    ? pixel_ppop_fmask
                    : (pixel_ppop_pmask & pixel_ppop_fmask);
  assign pixel_rmw  = pixel_transp_en_q || (pixel_plane_mask_q != 16'h0000);

  // With CYCLE_ACCURATE a single-pixel write (PIXT store, DRAV, LINE) is
  // raised on the first clock of its write step, as before, but its data and
  // keep mask come from registers: the first clock registers the pixel
  // operation's result and the operands of the merge, and the memory fabric
  // takes the merged data and keep mask one clock after it takes the request
  // (mem_late), before the field sequencer starts the write. Their inputs hold
  // through the write step (the destination was read in the step before; the
  // source, address and pixel configuration are registers), so the registers
  // are loaded in every clock of the step. Justification: timing only
  // (docs/dropin_measure.md).
  logic                  pix_wr_step;      // FSM: this clock is a pixel write step
  logic                  pix_wr_plain_sel; // FSM: the write data is pix_wr_plain
  logic [DATA_WIDTH-1:0] pix_wr_plain;     // FSM: data of a direct PIXT store
  logic                  pix_plain_sel_q;
  logic [DATA_WIDTH-1:0] pix_plain_q;
  logic [DATA_WIDTH-1:0] pix_res_q, pix_dest_raw_q, pix_pmask_q, pix_fmask_q;
  logic                  pix_inhibit_q, pix_transp_en_q, pix_wr_transp;
  logic [DATA_WIDTH-1:0] pixel_wr_data, pixel_wr_keep;
  always_ff @(posedge clk) begin
    if (pix_wr_step) begin
      pix_res_q      <= pixel_ppop_result;
      pix_dest_raw_q <= pixel_ppop_raw_dest;
      pix_pmask_q    <= pixel_ppop_pmask;
      pix_fmask_q    <= pixel_ppop_fmask;
      pix_inhibit_q  <= pixel_ppop_inhibit;
      pix_transp_en_q <= pixel_transp_en_q;   // CONTROL.T of the take clock
      pix_plain_sel_q <= pix_wr_plain_sel;
      pix_plain_q    <= pix_wr_plain;
    end
  end
  assign pix_wr_transp = pix_transp_en_q
      && ((pix_res_q & ~pix_pmask_q & pix_fmask_q) == '0);
  assign pixel_wr_data = !CYCLE_ACCURATE ? pixel_ppop_merged
                       : (pix_wr_transp || pix_inhibit_q) ? pix_dest_raw_q
                       : ((pix_res_q & ~pix_pmask_q) | (pix_dest_raw_q & pix_pmask_q));
  assign pixel_wr_keep = !CYCLE_ACCURATE ? pixel_keep
                       : (pix_wr_transp || pix_inhibit_q) ? pix_fmask_q
                       : (pix_pmask_q & pix_fmask_q);

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
  logic                  pixt_xy_win, pixt_xy_m2m;
  logic [DATA_WIDTH-1:0] pixt_wstart_q, pixt_wend_q;
  logic [DATA_WIDTH-1:0] pixt_point_q;
  logic                  pixt_inside_q;     // latched at the pixel write step
  logic                  pixt_in_window, pixt_in_window_live, pixt_clip_out;
  assign pixt_xy_m2m = pixt_m2m && decoded.xy_addr;
  assign pixt_xy_win  = decoded.xy_addr
                     && ((decoded.force_pixel && is_mv_store) || pixt_xy_m2m)
                     && (io_control[CTRL_W_HI:CTRL_W_LO] != 2'd0);
  assign pixt_in_window =
        ($signed(pixt_point_q[15:0]) >= $signed(pixt_wstart_q[15:0]))
     && ($signed(pixt_point_q[15:0]) <= $signed(pixt_wend_q[15:0]))
     && ($signed(pixt_point_q[DATA_WIDTH-1:16]) >= $signed(pixt_wstart_q[DATA_WIDTH-1:16]))
     && ($signed(pixt_point_q[DATA_WIDTH-1:16]) <= $signed(pixt_wend_q[DATA_WIDTH-1:16]));
  assign pixt_in_window_live =
        ($signed(pixt_point_q[15:0]) >= $signed(rf_rs1_data[15:0]))
     && ($signed(pixt_point_q[15:0]) <= $signed(rf_rs2_data[15:0]))
     && ($signed(pixt_point_q[DATA_WIDTH-1:16]) >= $signed(rf_rs1_data[DATA_WIDTH-1:16]))
     && ($signed(pixt_point_q[DATA_WIDTH-1:16]) <= $signed(rf_rs2_data[DATA_WIDTH-1:16]));
  // W=1 never draws; W=2/W=3 draw inside.
  assign pixt_clip_out = pixt_xy_win &&
                         ((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1) || !pixt_in_window);
  always_ff @(posedge clk) begin
    if (rst) begin
      pixt_wstart_q <= '0;
      pixt_wend_q   <= '0;
      pixt_point_q  <= '0;
      pixt_inside_q <= 1'b0;
    end else begin
      if ((state_q == CORE_EXECUTE) && pixt_xy_win)
        pixt_point_q <= rf_rs2_data;
      if (state_q == CORE_PIXT_SETUP_WIN) begin
        pixt_wstart_q <= rf_rs1_data;   // WSTART (B5)
        pixt_wend_q   <= rf_rs2_data;   // WEND (B6)
        pixt_inside_q <= pixt_in_window_live;
      end
      // Refresh the store form's result at its RMW write step. The M2M form
      // either proceeds or skips directly from SETUP_WIN using the live test.
      if ((state_q == CORE_MEMORY) && pixt_rmw && (mem_op_step == 2'd1) && fsm_mem_ack)
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
  logic                  is_mv_m2m, is_move_off_m2m_pi;
  logic                  is_move_abs_m2m_pi, is_m2m_dst_only_pi;
  logic                  is_movb_off_m2m, is_movb_abs_m2m;
  logic                  is_move_off_m2m, is_move_abs_m2m;
  logic                  m2m_same_reg, m2m_src_wr;
  logic [DATA_WIDTH-1:0] m2m_src_addr, m2m_dst_addr, m2m_src_new, m2m_dst_new;
  logic [DATA_WIDTH-1:0] m2m_src_addr_q, m2m_dst_addr_q;
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
  // Field-size aware (Task 0079): both pointers step by ±FS, not ±32. XY PIXT
  // M2M (Task 0086): the pointers hold XY values — convert the source with
  // CONVSP (pix_xy_linear) and the destination with CONVDP (pix_xy_dst_linear).
  assign m2m_src_addr = (is_movb_abs_m2m || is_move_abs_m2m)
                      ? {imm_hi_q, imm_lo_q}
                      : is_move_abs_m2m_pi ? {imm_hi_q, imm_lo_q}
                      : (is_movb_off_m2m || is_move_off_m2m)
                      ? (rf_rs1_data + m2m_src_offset)
                      : is_move_off_m2m_pi ? (rf_rs1_data + m2m_src_offset)
                      : decoded.xy_addr ? pix_xy_linear
                      : mv_predec       ? (rf_rs1_data - mv_fs_ext) : rf_rs1_data;
  assign m2m_dst_addr = (is_movb_abs_m2m || is_move_abs_m2m)
                      ? {imm_ext_hi_q, imm_ext_lo_q}
                      : (is_movb_off_m2m || is_move_off_m2m)
                      ? (rf_rs2_data + m2m_dst_offset)
                      : decoded.xy_addr ? pix_xy_dst_linear
                      : mv_predec       ? (rf_rs2_data - mv_fs_ext) : rf_rs2_data;
  assign m2m_src_new  = mv_predec ? (rf_rs1_data - mv_fs_ext) : (rf_rs1_data + mv_fs_ext);
  assign m2m_dst_new  = mv_predec ? (rf_rs2_data - mv_fs_ext) : (rf_rs2_data + mv_fs_ext);
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
    end else if (state_q == CORE_EXECUTE) begin
      mv_addr_q        <= mv_addr;
      mv_store_data_q  <= rf_rs1_data;
      m2m_src_addr_q   <= m2m_src_addr;
      m2m_dst_addr_q   <= (m2m_same_reg && mv_incdec
                           && !is_m2m_dst_only_pi)
                        ? (mv_predec ? (m2m_dst_addr - mv_fs_ext)
                                     : (m2m_dst_addr + mv_fs_ext))
                        : m2m_dst_addr;
    end
  end
  // Update the source pointer Rs at the step-0 read ack (inc/dec M2M only).
  assign m2m_src_wr   = (state_q == CORE_MEMORY) && is_mv_m2m && mv_incdec
                     && !is_m2m_dst_only_pi
                     && (mem_op_step == 2'd0) && fsm_mem_ack;

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
  assign array_ckpt_b14_wb  = array_checkpoint;
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
  //   SUBXY (User's Guide 4-11/12-252): compare-style flags —
  //     N=(RsX==RdX), V=(RsX>RdX), Z=(RsY==RdY), C=(RsY>RdY), with
  //     signed 16-bit comparisons because X/Y are signed coordinates.
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
  // The operands are registered at the end of CORE_DISPATCH, which an MPY
  // always leaves for CORE_EXECUTE (it has no immediate). Nothing writes the
  // register file or ST in CORE_DISPATCH (every writer is qualified to
  // WRITEBACK, MEMORY, INT_DONE or a graphics write-back state), so these
  // equal what the read ports give in CORE_EXECUTE, and the multiplier starts
  // at a register rather than at the read-port index logic.
  // Justification: timing only (docs/dropin_measure.md); no behaviour change.
  logic [DATA_WIDTH-1:0] mpy_rd_op_q, mpy_rs_op_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      mpy_rd_op_q <= '0;
      mpy_rs_op_q <= '0;
    end else if (state_q == CORE_DISPATCH) begin
      mpy_rd_op_q <= rf_rs2_data;
      mpy_rs_op_q <= mpy_rs_field;
    end
  end
  // 64-bit-context products: operands sign/zero-extend to 64 then multiply.
  assign mpy_sprod   = $signed(mpy_rd_op_q) * $signed(mpy_rs_op_q);
  assign mpy_uprod   = mpy_rd_op_q * mpy_rs_op_q;
  assign mpy_product = mpy_signed ? unsigned'(mpy_sprod) : mpy_uprod;

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
          {rf_rs2_data[DATA_WIDTH-1:16], rf_rs1_data[15:0]};
      INSTR_MOVY:   execute_wb_data =
          {rf_rs1_data[DATA_WIDTH-1:16], rf_rs2_data[15:0]};
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
    unique case (decoded.iclass)
      INSTR_DRAV:   rf_wr_data = drav_advance;   // Rd advanced by Rs (XY add)
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
      INSTR_MMTM:   rf_wr_data = mm_rp_q;       // final Rp = address of last push
      // MMFM: per-iteration pop writes mem_rdata_eff to the popped register;
      // the WRITEBACK pass writes final Rp (= initial + 32*count).
      INSTR_MMFM:   rf_wr_data = mmfm_pop_wr ? mem_rdata_eff : mm_rp_q;
      // MOVE *Rs,Rd: Rd <- the 32 bits read from mem[Rs]. mem_rdata_eff still
      // holds the value at WRITEBACK (no new transaction is issued there).
      // Store inc/dec writes the auto-updated pointer back to Rd at
      // WRITEBACK (plain store has wb_reg_en=0, so this is unused there).
      INSTR_MOVE_FIELD_STORE: rf_wr_data = execute_wb_data_q;
      // Load: at WRITEBACK -> the field-extended data to Rd; during
      // CORE_MEMORY (inc/dec) -> the updated pointer to Rs.
      INSTR_MOVE_FIELD_LOAD:
          rf_wr_data = mv_load_ptr_wr ? execute_wb_data_q : mv_load_data;
      // Indirect-to-indirect inc/dec: source pointer Rs (step-0 ack) or
      // destination pointer Rd (WRITEBACK).
      INSTR_MOVE_FIELD_M2M,
      INSTR_MOVE_OFF_M2M_PI,
      INSTR_MOVE_ABS_M2M_PI:
          rf_wr_data = m2m_src_wr ? execute_wb_data_q : m2m_dst_new_q;
      // MOVE @SAddr,Rd: Rd <- the field-extended value read from the
      // absolute address. MOVE *Rs(off),Rd: same, from the offset address.
      INSTR_MOVE_ABS_LOAD,
      INSTR_MOVE_OFF_LOAD:  rf_wr_data = mv_load_data;
      INSTR_FILL_L,
      INSTR_FILL_XY: rf_wr_data = fill_win_en_q ? fill_result_q
                                               : fill_addr_q;  // final linear DADDR -> B2
      INSTR_PIXBLT_LL: rf_wr_data = pblt_wb_saddr ? pblt_src_result_q   // SADDR -> B0
                                                  : pblt_dst_result_q;  // DADDR -> B2
      INSTR_LINE:    rf_wr_data = line_wb_d     ? line_d_q      // d -> B0
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
      INSTR_PUTST: st_write_data = rf_rs1_data;
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
      CC_P:    branch_taken = !st_n & !st_z;          // positive
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
          // Atomic swap PC ↔ Rd: PC ← old Rd with its bottom 4 bits forced
          // to 0 per page 12-79, Rd ← next PC via the mux above.
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
    end else if (state_q == CORE_RESET && !rst && fsm_mem_ack) begin
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
  // 16-bit; the core accesses them with 16-bit fields (set FS=16).
  logic                  io_is_io, io_is_io_regs, io_is_io_live;
  logic [ADDR_WIDTH-1:0] io_rd_addr;
  logic [15:0]           io_rdata16;
  logic [15:0]           io_rdata_next16;
  logic [15:0]           io_psize;     // PSIZE register (pixel size, for PIXT/CVXYL)
  logic [15:0]           io_convdp;    // CONVDP register (XY->linear dest pitch)
  logic [15:0]           io_convsp;    // CONVSP register (XY->linear source pitch)
  logic [15:0]           io_control;   // CONTROL register (PPOP, T, window mode, ...)
  logic [15:0]           io_pmask;     // PMASK register (plane mask)
  logic                  io_pixel_srt; // DPYCTL.SRT program-controlled VRAM transfer
  logic [15:0]           io_intenb;    // INTENB register (maskable-interrupt enables)
  logic [15:0]           io_intpend;   // INTPEND register (maskable-interrupt pending)
  logic [15:0]           io_hstctlh;   // HSTCTLH register (host control; NMI/NMIM bits)
  logic                  io_hlt;       // HSTCTLH.HLT, sampled at instruction boundaries
  logic                  nmi_clear;    // pulse to clear HSTCTLH.NMI on taking the NMI
  logic                  wvp_set;      // pulse to set INTPEND.WV on a window violation
  logic [DATA_WIDTH-1:0] mem_rdata_eff;
  logic                  mem_we_int;   // the FSM's write intent (pre-I/O gating)
  tms34010_io_regs #(
    .CLKS_PER_STATE (CLKS_PER_STATE),
    .CYCLE_ACCURATE (CYCLE_ACCURATE),
    .VCLK_CEN       (VCLK_CEN)
  ) u_io_regs (
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
    .req      (io_req),
    .we       (io_we),         // the access's write intent
    .addr     (io_rd_addr),
    .req_addr_i(io_access_addr_q),
    .wdata    (io_write_data_q),
    .req_next_i(io_write_next_q),
    .req_next_addr_i(io_next_addr_q),
    .wdata_next_i(io_write_data_next_q),
    .rdata    (io_rdata16),
    .rdata_next(io_rdata_next16),
    .is_io    (io_is_io_regs),
    .psize_o  (io_psize),
    .convdp_o (io_convdp),
    .convsp_o (io_convsp),
    .control_o(io_control),
    .pmask_o  (io_pmask),
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
  // An opcode fetch, once issued, must complete: the memory fabric has latched
  // it, and its acknowledge would otherwise retire the next state's request.
  logic fetch_open_q;
  always_ff @(posedge clk) begin
    if (rst) fetch_open_q <= 1'b0;
    else     fetch_open_q <= (state_q == CORE_FETCH) && fsm_mem_req && !fsm_mem_ack;
  end
  logic fetch_int_take;
  assign fetch_int_take = int_take && !fetch_open_q;

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
    end else if (state_q == CORE_FETCH && fetch_int_take) begin
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
  assign fsm_mem_we = mem_we_int && !io_is_io;
  // DPYCTL.SRT converts only graphics pixel accesses. Instruction fetches,
  // stack/data moves, host traffic, and on-chip I/O retain their ordinary
  // cycle types. The registered memory-fabric ingress captures this sideband
  // with the complete architectural request before arbitration.
  assign fsm_mem_srt = fsm_mem_req && io_pixel_srt && !io_is_io
                && ((state_q == CORE_DRAV)
                    || (state_q == CORE_LINE_DRAW)
                    || (state_q == CORE_FILL)
                    || (state_q == CORE_PBLT)
                    || ((state_q == CORE_MEMORY) && decoded.force_pixel));
  assign fsm_mem_is_io    = io_is_io;
  assign fsm_mem_io_we    = mem_we_int;
  assign fsm_mem_io_rdata = io_rdata16;
  // With CYCLE_ACCURATE the I/O registers are read through the registered
  // request address (the data is needed two states later at the earliest),
  // which keeps the decode -> register file -> address path out of the I/O
  // read mux; the I/O decode for the request itself stays on the live
  // address (the same compare as tms34010_io_regs).
  assign io_rd_addr     = CYCLE_ACCURATE ? io_access_addr_q : fsm_mem_addr;
  assign io_is_io_live  = (fsm_mem_addr[ADDR_WIDTH-1:ADDR_WIDTH-2] == 2'b11)
                       && (fsm_mem_addr[ADDR_WIDTH-3:IO_REG_IDX_W+4] == '0);
  assign io_is_io       = CYCLE_ACCURATE ? io_is_io_live : io_is_io_regs;

  // Effective read data. The external memory path holds fsm_mem_rdata through
  // WRITEBACK, but the asynchronous I/O read follows the live address. The
  // integrated fabric cannot acknowledge before its registered ingress has
  // accepted a request, so snapshot I/O classification, read data, completion
  // address, and write data on the held request. Completion and WRITEBACK then
  // consume only these stable values rather than rebuilding a long live
  // core/register/I/O mux path.
  logic [DATA_WIDTH-1:0] io_rdata_q;
  logic        io_is_io_q;
  logic [ADDR_WIDTH-1:0] io_access_addr_q;
  logic [15:0] io_write_data_q;
  logic        io_write_next_q;
  logic [ADDR_WIDTH-1:0] io_next_addr_q;
  logic [15:0] io_write_data_next_q;
  logic [FIELD_SIZE_WIDTH-1:0] io_request_size_q;
  logic [DATA_WIDTH-1:0] io_request_wdata_q;
  logic [DATA_WIDTH-1:0] io_request_keep_q;   // bits the write keeps (mem_keep)
  logic [DATA_WIDTH-1:0] io_request_kept;     // the write data with them kept
  logic [DATA_WIDTH-1:0] io_rdata_words_q;
  logic [5:0]  io_field_width;
  logic [DATA_WIDTH-1:0] io_field_mask;
  logic [DATA_WIDTH-1:0] io_field_rdata;
  logic [DATA_WIDTH-1:0] io_field_wdata;
  logic [DATA_WIDTH-1:0] io_rdata_words;
  always_comb begin
    // On-chip registers are 16-bit words in the processor's bit-addressed
    // space. A MOVE may address a subfield (for example CONTROL+5 with
    // FS=10), so present a right-justified read field and merge writes into
    // the addressed bits exactly as the external field sequencer would.
    io_rdata_words = io_rdata_words_q;
    if (io_request_size_q
        >= FIELD_SIZE_WIDTH'(6'd32 - {2'b0, io_access_addr_q[3:0]}))
      io_field_width = 6'd32 - {2'b0, io_access_addr_q[3:0]};
    else
      io_field_width = io_request_size_q;
    io_field_mask = (io_field_width >= 6'd32)
                  ? 32'hFFFF_FFFF
                  : (32'h0000_0001 << io_field_width) - 32'h0000_0001;
    io_field_rdata =
        (io_rdata_words >> io_access_addr_q[3:0]) & io_field_mask;
    // A write's keep mask (plane mask, transparency; only set with
    // CYCLE_ACCURATE, where the memory controller applies them) keeps those
    // bits of the register, as the field sequencer does for memory.
    io_request_kept =
        (io_request_wdata_q & ~io_request_keep_q)
      | ((io_rdata_words >> io_access_addr_q[3:0]) & io_request_keep_q);
    io_field_wdata =
        (io_rdata_words & ~(io_field_mask << io_access_addr_q[3:0]))
      | ((io_request_kept & io_field_mask)
          << io_access_addr_q[3:0]);
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      io_rdata_q       <= '0;
      io_is_io_q       <= 1'b0;
      io_access_addr_q <= '0;
      io_write_data_q  <= '0;
      io_write_next_q  <= 1'b0;
      io_next_addr_q   <= '0;
      io_write_data_next_q <= '0;
      io_request_size_q <= '0;
      io_request_wdata_q <= '0;
      io_request_keep_q  <= '0;
      io_rdata_words_q <= '0;
      io_rd_late_q     <= 1'b0;
    end else begin
      // The integrated memory fabric registers every request before it can
      // acknowledge it. First hold the raw processor request and two-word
      // I/O read view at the core boundary. With CYCLE_ACCURATE a posted
      // write is accepted at once and committed three clocks later (io_req
      // below), so this stage holds for the clock in between.
      if (fsm_mem_req)
        io_is_io_q       <= io_is_io;
      io_rd_late_q <= CYCLE_ACCURATE && fsm_mem_req && !io_post_d1_q && !io_post_d2_q;
      if (io_rd_late_q)
        io_rdata_words_q <= {io_rdata_next16, io_rdata16};
      if (fsm_mem_req && !io_post_d1_q && !io_post_d2_q) begin
        io_access_addr_q <= fsm_mem_addr;
        io_request_size_q <= fsm_mem_size;
        io_request_wdata_q <= fsm_mem_wdata;
        io_request_keep_q  <= fsm_mem_keep;
        if (!CYCLE_ACCURATE)
          io_rdata_words_q <= {io_rdata_next16, io_rdata16};
        io_next_addr_q   <= {fsm_mem_addr[ADDR_WIDTH-1:4], 4'b0000}
                          + ADDR_WIDTH'(16);
      end
      // A late write's data (mem_late) arrives the clock after it is taken,
      // while io_post_d1_q holds this snapshot's other fields.
      if (late_taken_q) begin
        io_request_wdata_q <= mem_late_wdata;
        io_request_keep_q  <= mem_late_keep;
      end
      // Then align/merge only registered operands. The physical I/O cycle
      // cannot acknowledge before the fabric's registered ingress and local
      // bus phases, so this stage is complete before the completion pulse.
      // Separating it removes a decode/register-file/address-mux path from
      // the I/O write payload flops.
      if (io_is_io_q)
        io_rdata_q       <= io_field_rdata;
      // A posted I/O write's payload keeps following its held snapshot until
      // it commits, whatever the next request is (the I/O registers ignore
      // the commit of a write that wasn't to I/O space).
      if (io_is_io_q || io_post_d1_q || io_post_d2_q) begin
        io_write_data_q  <= io_field_wdata[15:0];
        io_write_next_q  <=
            ({2'b0, io_access_addr_q[3:0]} + io_request_size_q)
            > FIELD_SIZE_WIDTH'(16);
        io_write_data_next_q <= io_field_wdata[31:16];
      end
    end
  end
  // I/O register access strobe. Upstream: the acknowledged access. With
  // CYCLE_ACCURATE a write is posted (1988 UG 6.2) and acknowledged in the
  // clock it is accepted, before the snapshot above is ready, so an
  // accepted write commits three clocks later from the snapshot (the read
  // view it merges into is taken a clock after the request).
  always_ff @(posedge clk) begin
    if (rst) begin
      io_post_d1_q <= 1'b0;
      io_post_d2_q <= 1'b0;
      io_post_d3_q <= 1'b0;
    end else begin
      io_post_d1_q <= CYCLE_ACCURATE && fsm_mem_req && fsm_mem_ack && mem_we_int;
      io_post_d2_q <= io_post_d1_q;
      io_post_d3_q <= io_post_d2_q;
    end
  end
  assign io_req = CYCLE_ACCURATE
                ? ((fsm_mem_req && fsm_mem_ack && !mem_we_int) || io_post_d3_q)
                : (fsm_mem_req && fsm_mem_ack);
  assign io_we  = CYCLE_ACCURATE ? io_post_d3_q : mem_we_int;

  assign mem_rdata_eff =
      io_is_io_q ? io_rdata_q : fsm_mem_rdata;

  tms34010_alu u_alu (
    .op    (alu_op),
    .a     (alu_a),
    .b     (alu_b),
    .cin   (alu_cin),
    .result(alu_result),
    .flags (alu_flags)
  );

  // Shifter datapath. Operand is the Rd register value (via rf_rs2_data,
  // which already reads decoded.rd_idx in the same file as the
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
      // Window result: only V is written (mask below is V-only).
      flag_input = '{n: 1'b0, c: 1'b0, z: 1'b0, v: fill_win_violation};
    end else
    unique case (decoded.iclass)
      INSTR_SETC:   flag_input = '{n: 1'b0, c: 1'b1, z: 1'b0, v: 1'b0};
      INSTR_CLRC:   flag_input = '{n: 1'b0, c: 1'b0, z: 1'b0, v: 1'b0};
      INSTR_LMO_RR: flag_input = '{n: 1'b0, c: 1'b0,
                                    z: (rf_rs1_data == '0), v: 1'b0};
      INSTR_SEXT:   flag_input = '{n: sext_result[DATA_WIDTH-1], c: 1'b0,
                                    z: (sext_result == '0), v: 1'b0};
      INSTR_ZEXT:   flag_input = '{n: 1'b0, c: 1'b0,
                                    z: (zext_result == '0), v: 1'b0};
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
      default:      flag_input = decoded.use_shifter ? shifter_flags : alu_flags;
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
    fsm_mem_req       = 1'b0;
    pix_wr_step       = 1'b0;
    pix_wr_plain_sel  = 1'b0;
    pix_wr_plain      = '0;
    mem_we_int        = 1'b0;
    fsm_mem_addr      = '0;
    fsm_mem_size      = '0;
    fsm_mem_wdata     = '0;
    fsm_mem_keep      = '0;
    fsm_mem_rmw       = 1'b0;
    fsm_mem_iaq       = 1'b0;
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
            fsm_mem_req    = 1'b1;
            mem_we_int = 1'b0;
            fsm_mem_addr   = RESET_VECTOR_ADDR;
            fsm_mem_size   = MEM_SIZE_32;
            if (fsm_mem_ack) state_d = CORE_FETCH;
          end
        end
      end

      CORE_FETCH: begin
        // CYCLE_ACCURATE: the previous instruction has not used up its
        // machine states yet (docs/cycle_accuracy.md). Nothing starts.
        if (pace_hold) begin
          state_d = CORE_FETCH;
        end else
        // Recognise a pending interrupt at the instruction boundary. NMI
        // (non-maskable) takes priority over a maskable request (ST.IE=1 and an
        // enabled INTPEND bit). When taken, do NOT fetch — pc_value stays at the
        // resume address. An NMI with NMIM=1 saves no context and jumps
        // straight to the vector; everything else pushes PC+ST first.
        // A newly asserted NMI is serviced before a simultaneous halt, which
        // lets HLT stop the core at the NMI service routine's first boundary.
        if (fetch_int_take) begin
          state_d = (nmi_req && nmi_nmim) ? CORE_INT_VECTOR : CORE_INT_PUSH_PC;
        end else if (io_hlt && !fetch_open_q) begin
          state_d = CORE_HOST_HALT;
        end else begin
          fsm_mem_req  = 1'b1;
          mem_we_int   = 1'b0;
          fsm_mem_addr = pc_value;
          fsm_mem_size = INSTR_WORD_BITS;
          fsm_mem_iaq  = 1'b1;
          if (fsm_mem_ack) begin
            state_d       = CORE_DECODE;
            pc_advance_en = 1'b1;       // advance PC by INSTR_WORD_BITS
          end
        end
      end

      CORE_INT_PUSH_PC: begin
        // Push the resume PC to mem[SP-32] (32-bit). SP is not updated until
        // CORE_INT_DONE; the second push uses SP-64. Order matches RETI's pop
        // (ST at the lower address, PC at the higher) and the TRAP push.
        fsm_mem_req   = 1'b1;
        mem_we_int = 1'b1;
        fsm_mem_addr  = rf_sp - WORD_BIT_SIZE;
        fsm_mem_size  = MEM_SIZE_32;
        fsm_mem_wdata = int_stack_pc;
        if (fsm_mem_ack) state_d = CORE_INT_PUSH_ST;
      end

      CORE_INT_PUSH_ST: begin
        // Push ST to mem[SP-64] (32-bit).
        fsm_mem_req   = 1'b1;
        mem_we_int = 1'b1;
        fsm_mem_addr  = rf_sp - WORD_BIT_SIZE_2;
        fsm_mem_size  = MEM_SIZE_32;
        fsm_mem_wdata = int_stack_st;
        if (fsm_mem_ack) state_d = CORE_INT_VECTOR;
      end

      CORE_INT_VECTOR: begin
        // Read the 32-bit trap vector (the ISR entry address) at the latched
        // vector address; latch it into popped_pc_q for the PC load below.
        fsm_mem_req   = 1'b1;
        mem_we_int = 1'b0;
        fsm_mem_addr  = int_vec_q;
        fsm_mem_size  = MEM_SIZE_32;
        if (fsm_mem_ack) state_d = CORE_INT_DONE;
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
          state_d = CORE_EXECUTE;
        end
      end

      CORE_FETCH_IMM_LO: begin
        // Fetch the 16-bit low-immediate word from PC. Same protocol as
        // CORE_FETCH; PC advances by INSTR_WORD_BITS on ack.
        fsm_mem_req  = 1'b1;
        mem_we_int   = 1'b0;
        fsm_mem_addr = pc_value;
        fsm_mem_size = INSTR_WORD_BITS;
        if (fsm_mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = (decoded.needs_imm32 || decoded.needs_imm64)
                  ? CORE_FETCH_IMM_HI : CORE_EXECUTE;
        end
      end

      CORE_FETCH_IMM_HI: begin
        fsm_mem_req  = 1'b1;
        mem_we_int   = 1'b0;
        fsm_mem_addr = pc_value;
        fsm_mem_size = INSTR_WORD_BITS;
        if (fsm_mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = decoded.needs_imm64 ? CORE_FETCH_IMM_EXT_LO : CORE_EXECUTE;
        end
      end

      CORE_FETCH_IMM_EXT_LO: begin
        fsm_mem_req  = 1'b1;
        mem_we_int = 1'b0;
        fsm_mem_addr = pc_value;
        fsm_mem_size = INSTR_WORD_BITS;
        if (fsm_mem_ack) begin
          pc_advance_en = 1'b1;
          state_d = CORE_FETCH_IMM_EXT_HI;
        end
      end

      CORE_FETCH_IMM_EXT_HI: begin
        fsm_mem_req  = 1'b1;
        mem_we_int = 1'b0;
        fsm_mem_addr = pc_value;
        fsm_mem_size = INSTR_WORD_BITS;
        if (fsm_mem_ack) begin
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
        if (is_emu)
          state_d = run_emu_n_i ? CORE_WRITEBACK : CORE_EMU_HALT;
        else if (is_div)
          state_d = CORE_DIVIDE;
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

      CORE_DIVIDE: begin
        // Hold while the divider runs; proceed to writeback when it signals
        // done (results, incl. the overflow flag, are then stable).
        state_d = div_done ? CORE_WRITEBACK : CORE_DIVIDE;
      end

      CORE_FILL_SETUP: begin
        // One cycle to latch COLOR1 (and the counters were seeded at EXECUTE).
        // A zero dimension is an empty array: no access, flag update, or
        // implied-register writeback is performed.
        // FILL XY with a window (W=2 or W=3) takes one more cycle to read
        // WSTART/WEND.
        state_d = fill_empty                                  ? CORE_FETCH
                : (fill_win_en_q || fill_w2_q || fill_w1_q)   ? CORE_FILL_SETUP_WIN
                                                              : CORE_FILL;
      end

      CORE_FILL_SETUP_WIN: begin
        // Latch WSTART(B5)/WEND(B6). W=3 preclips the working rectangle now,
        // before any pixel request; a fully excluded rectangle goes to the
        // status-only WB cycle. W=2 checks containment. W=1 never draws.
        state_d = (CYCLE_ACCURATE && !fill_win_eval_q) ? CORE_FILL_SETUP_WIN
                : fill_w1_q                          ? CORE_FILL_WIN_HIT
                : (fill_w2_q && !fill_array_inside)  ? CORE_FILL_WIN_MISS
                : (fill_win_en_q && !fill_clip_hit)  ? CORE_FILL_WB
                                                     : CORE_FILL;
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
        // Read WSTART(B5)/WEND(B6), COLOR1(B9), and test Rd's pixel. W=0
        // always draws. For a window, only W=2/3 inside proceeds to the
        // access; otherwise advance Rd and write V/WVP without pixel traffic.
        state_d = (drav_w_q == 2'd0)
                ? CORE_DRAV
                : (((drav_w_q == 2'd2) || (drav_w_q == 2'd3))
                   && drav_in_window)
                ? CORE_DRAV : CORE_WRITEBACK;
      end

      CORE_PIXT_SETUP_WIN: begin
        // Read WSTART/WEND. A register-to-XY store runs its pixel access and
        // inhibits the write there. Suppressed XY-to-XY transfers skip
        // directly to writeback; an admitted transfer may use either the
        // direct source-read/write path or the processing destination-read
        // path selected by pixt_m2m_rmw. With CYCLE_ACCURATE a suppressed
        // store skips its access too.
        state_d = ((pixt_xy_m2m || CYCLE_ACCURATE)
                   && ((io_control[CTRL_W_HI:CTRL_W_LO] == 2'd1)
                       || !pixt_in_window_live))
                ? CORE_WRITEBACK : CORE_MEMORY;
      end

      CORE_DRAV: begin
        // Draw at Rd's linear address: optionally read the destination at
        // sub-step 0, then write merged/direct COLOR1 at sub-step 1. On the
        // write ack proceed to CORE_WRITEBACK, which advances Rd by Rs.
        fsm_mem_req  = 1'b1;
        fsm_mem_addr = drav_linear_q;
        fsm_mem_size = io_psize[FIELD_SIZE_WIDTH-1:0];
        if (!drav_substep_q) begin
          mem_we_int = 1'b0;            // read the destination pixel
        end else begin
          mem_we_int = 1'b1;           // write the merged pixel
          pix_wr_step    = fsm_mem_req;
          fsm_mem_wdata  = pixel_wr_data;
          if (CYCLE_ACCURATE) begin
            fsm_mem_keep = pixel_wr_keep;
            fsm_mem_rmw  = pixel_rmw;
          end
        end
        if (fsm_mem_ack && drav_substep_q)
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
        // Per pixel, optionally read dest at sub-step 0, then write merged or
        // direct COLOR1 at sub-step 1. On the write ack of the last pixel
        // (COUNT about to reach 0) go to writeback; else draw the next pixel.
        fsm_mem_req  = !line_skip;
        fsm_mem_addr = line_linear;
        fsm_mem_size = io_psize[FIELD_SIZE_WIDTH-1:0];
        if (!line_substep_q) begin
          mem_we_int = 1'b0;            // read the destination pixel
        end else begin
          mem_we_int = 1'b1;           // write the merged pixel
          pix_wr_step    = fsm_mem_req;
          fsm_mem_wdata  = pixel_wr_data;
          if (CYCLE_ACCURATE) begin
            fsm_mem_keep = pixel_wr_keep;
            fsm_mem_rmw  = pixel_rmw;
          end
        end
        if ((fsm_mem_ack && line_substep_q) || line_skip) begin
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
        fsm_mem_req   = 1'b1;
        fsm_mem_addr  = fill_addr_q;
        fsm_mem_size  = CYCLE_ACCURATE ? fill_step_bits : io_psize[FIELD_SIZE_WIDTH-1:0];
        if (!fill_substep_q) begin
          mem_we_int = 1'b0;            // read the destination pixel(s)
        end else begin
          mem_we_int = 1'b1;            // write the processed pixel(s)
          fsm_mem_wdata  = pixel_ppop_merged;
          if (CYCLE_ACCURATE) begin
            fsm_mem_wdata = {16'd0, fill_word_result};
            fsm_mem_keep  = {16'd0, fill_word_keep};
            fsm_mem_rmw   = pixel_rmw;
          end
        end
        if (fsm_mem_ack && fill_substep_q) begin
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
        // One cycle to latch SPTCH/DPTCH (counters seeded at EXECUTE). The
        // zero-dimension case is an empty array and exits before color/window
        // setup, memory traffic, or implied-register writeback.
        // binary form reads COLOR0/COLOR1 in a second setup cycle; a windowed
        // (W=3) XY blt reads WSTART/WEND in CORE_PBLT_SETUP_WIN.
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
        fsm_mem_req   = 1'b1;
        fsm_mem_size  = io_psize[FIELD_SIZE_WIDTH-1:0];
        unique case (pblt_substep_q)
          2'd0: begin
            mem_we_int = 1'b0;             // read source pixel (1 bit if binary)
            fsm_mem_addr   = pblt_src_access_addr;
            if (decoded.blt_binary) fsm_mem_size = FIELD_SIZE_WIDTH'(1);
            if (pbw_on) begin              // word mode: the next source word
              fsm_mem_req  = !pbw_src_ready;
              fsm_mem_addr = {pbw_miss, 4'd0};
              fsm_mem_size = FIELD_SIZE_WIDTH'(16);
            end
            if (pbx_on) begin              // expand: a segment of up to 32 bits
              fsm_mem_req  = !pbx_valid_q;
              fsm_mem_addr = pblt_src_addr_q;
              fsm_mem_size = (pblt_rem_q < 16'd32) ? FIELD_SIZE_WIDTH'(pblt_rem_q)
                                                   : FIELD_SIZE_WIDTH'(32);
            end
          end
          2'd1: begin
            mem_we_int = 1'b0;             // read destination pixel
            fsm_mem_addr   = pblt_dst_access_addr;
            if (pbw_word) begin
              fsm_mem_addr = pbw_dst_start;
              fsm_mem_size = pbw_step_bits;
            end
          end
          default: begin
            mem_we_int = 1'b1;             // write the processed pixel
            fsm_mem_addr   = pblt_dst_access_addr;
            fsm_mem_wdata  = pixel_ppop_merged;
            if (pbw_word) begin
              fsm_mem_addr  = pbw_dst_start;
              fsm_mem_size  = pbw_step_bits;
              fsm_mem_wdata = {16'd0, pbw_result_q};
              fsm_mem_keep  = {16'd0, pbw_keep};
              fsm_mem_rmw   = pixel_rmw;
            end
          end
        endcase
        if (fsm_mem_ack && pblt_substep_q == 2'd2) begin
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
        // decoded.needs_memory_op. The IF signals (fsm_mem_req, mem_we_int,
        // fsm_mem_addr, fsm_mem_size, fsm_mem_wdata) are driven per iclass.
        unique case (decoded.iclass)
          INSTR_PUSHST: begin
            // Write ST to mem[new SP] as a 32-bit transfer.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            fsm_mem_addr  = alu_result;        // = SP - 32
            fsm_mem_size  = MEM_SIZE_32;
            fsm_mem_wdata = st_value;          // ST
          end
          INSTR_POPST: begin
            // Read 32-bit ST from mem[OLD SP]. The increment-by-32
            // happens via the ALU; we don't want alu_result here,
            // we want the pre-increment SP value. POPST has
            // rd_idx=15 (SP) on rs2 — so rs2 gives OLD SP.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_addr  = rf_rs2_data;       // = current SP
            fsm_mem_size  = MEM_SIZE_32;
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
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            fsm_mem_addr  = alu_result;        // = SP - 32
            fsm_mem_size  = MEM_SIZE_32;
            fsm_mem_wdata = pc_value;          // PC' (return address)
          end
          INSTR_RETS: begin
            // Pop PC from mem[OLD SP]. fsm_mem_addr = current SP value
            // (rf_rs2_data) — NOT alu_result, which is SP + 32 + 16*N.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_addr  = rf_rs2_data;       // = current SP
            fsm_mem_size  = MEM_SIZE_32;
          end
          INSTR_RETI: begin
            // Two-step pop: step 0 reads ST from mem[SP]; step 1 reads
            // PC from mem[SP+32]. Both 32-bit reads. The latched
            // popped_st_q / popped_pc_q values flow to the WRITEBACK
            // ST-write and PC-load paths below.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_size  = MEM_SIZE_32;
            fsm_mem_addr  = (mem_op_step == 2'd0)
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
            fsm_mem_req   = 1'b1;
            fsm_mem_size  = MEM_SIZE_32;
            if (trap_skip_push) begin
              mem_we_int    = 1'b0;
              fsm_mem_addr  = TRAP_VECTOR_BASE;        // N=0 ⇒ vector @ 0xFFFFFFE0
            end else begin
              unique case (mem_op_step)
                2'd0: begin
                  mem_we_int    = 1'b1;
                  fsm_mem_addr  = rf_rs2_data - WORD_BIT_SIZE;
                  fsm_mem_wdata = pc_value;             // PC'
                end
                2'd1: begin
                  mem_we_int    = 1'b1;
                  fsm_mem_addr  = rf_rs2_data - WORD_BIT_SIZE_2;
                  fsm_mem_wdata = st_value;             // ST as it stood
                end
                default: begin                       // step 2
                  mem_we_int    = 1'b0;
                  // Trap-vector address = TRAP_VECTOR_BASE - N*32.
                  // N is decoded.k5 (5 bits); N*32 = N << 5.
                  fsm_mem_addr  = TRAP_VECTOR_BASE
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
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            fsm_mem_addr  = mm_rp_q;
            fsm_mem_size  = MEM_SIZE_32;
            fsm_mem_wdata = rf_rs1_data;       // = value of register R(mm_iter_idx)
          end
          INSTR_MMFM: begin
            // Pop: read 32 bits from mem[mm_rp_q] into the register
            // selected by mm_iter_idx (highest-order first). The regfile
            // write happens via the mmfm_pop_wr path; here we just drive
            // the read. mm_mask_q clears the bit and mm_rp_q advances
            // (+32) on the ack. Stay in CORE_MEMORY until mask empty.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_addr  = mm_rp_q;
            fsm_mem_size  = MEM_SIZE_32;
          end
          INSTR_MOVE_FIELD_STORE: begin
            // MOVE Rs,*Rd[+|-]: write the low FS bits of Rs (rf_rs1_data) to
            // mem[mv_addr]. mv_addr = pointer Rd (postinc/none) or Rd-FS
            // (predec); the pointer auto-update (Rd±FS) is written back at
            // WRITEBACK for the inc/dec forms. FS from the F-selected ST pair.
            // A processing/window PIXT store reads the destination at step 0
            // and writes the merged value at step 1. A regular MOVE or direct
            // replace PIXT store is a single write.
            fsm_mem_req   = 1'b1;
            fsm_mem_addr  = mv_addr_q;         // = Rd or Rd-FS (predec)
            fsm_mem_size  = mv_fs;             // field size (1..32)
            if (pixt_rmw && mem_op_step == 2'd0) begin
              mem_we_int = 1'b0;           // step 0: read the destination pixel
            end else begin
              mem_we_int = 1'b1;           // write (single, or step 1 of RMW)
              pix_wr_step    = decoded.force_pixel;
              pix_wr_plain_sel = !pixt_rmw;
              pix_wr_plain   = mv_store_data_q;
              fsm_mem_wdata  = pixt_rmw ? pixel_wr_data : mv_store_data_q;
              if (CYCLE_ACCURATE && decoded.force_pixel) begin
                fsm_mem_keep = pixel_wr_keep;
                fsm_mem_rmw  = pixel_rmw;
              end
            end
          end
          INSTR_MOVE_FIELD_LOAD: begin
            // MOVE [-]*Rs[+],Rd: read an FS-bit field from mem[mv_addr].
            // mv_addr = pointer Rs (postinc/none) or Rs-FS (predec). The
            // field-extended data (mv_load_data) goes to Rd at WRITEBACK;
            // for inc/dec the updated pointer Rs±FS is written via the
            // mv_load_ptr_wr path on this ack.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_addr  = mv_addr_q;         // = Rs or Rs-FS (predec)
            fsm_mem_size  = mv_fs;             // field size (1..32)
          end
          INSTR_MOVE_OFF_STORE: begin
            // MOVE Rs,*Rd(off): write the low FS bits of Rs (rf_rs1_data) to
            // mem[Rd + off]. imm32 = sign-extended 16-bit offset; Rd =
            // rf_rs2_data. Field-size aware (Task 0078); no pointer step.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            fsm_mem_addr  = rf_rs2_data + imm32;
            fsm_mem_size  = mv_fs;             // field size (1..32)
            fsm_mem_wdata = rf_rs1_data;       // = Rs (low FS bits used)
          end
          INSTR_MOVE_OFF_LOAD: begin
            // MOVE *Rs(off),Rd: read an FS-bit field at mem[Rs + off];
            // field-extended result -> Rd at WRITEBACK. Rs = rf_rs1_data
            // (pointer); imm32 = sext(off16). Field-size aware (Task 0078).
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_addr  = rf_rs1_data + imm32;
            fsm_mem_size  = mv_fs;             // field size (1..32)
          end
          INSTR_MOVE_ABS_STORE: begin
            // MOVE Rs,@DAddr: write the low FS bits of Rs (rf_rs1_data) to the
            // absolute bit address imm32 = {imm_hi_q, imm_lo_q}. Field-size
            // aware (Task 0078).
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b1;
            fsm_mem_addr  = imm32;
            fsm_mem_size  = mv_fs;             // field size (1..32)
            fsm_mem_wdata = rf_rs1_data;       // = Rs (low FS bits used)
          end
          INSTR_MOVE_ABS_LOAD: begin
            // MOVE @SAddr,Rd: read an FS-bit field from the absolute address
            // imm32; the field-extended result goes to Rd at WRITEBACK
            // (rf_wr_data mux), flags from the extended value. Task 0078.
            fsm_mem_req   = 1'b1;
            mem_we_int    = 1'b0;
            fsm_mem_addr  = imm32;
            fsm_mem_size  = mv_fs;             // field size (1..32)
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
            fsm_mem_req   = 1'b1;
            fsm_mem_size  = mv_fs;             // field size (1..32)
            if (mem_op_step == 2'd0) begin
              mem_we_int   = 1'b0;
              fsm_mem_addr = m2m_src_addr_q;   // = Rs (or Rs-FS predec)
            end else if (pixt_m2m_rmw && mem_op_step == 2'd1) begin
              mem_we_int = 1'b0;
              fsm_mem_addr = m2m_dst_addr_q;
            end else begin
              mem_we_int   = 1'b1;
              fsm_mem_addr = m2m_dst_addr_q;   // = Rd (or Rd-FS predec; updated Rs if Rs==Rd)
              pix_wr_step   = pixt_m2m;
              fsm_mem_wdata = pixt_m2m ? pixel_wr_data : move_data_q;
              if (CYCLE_ACCURATE && pixt_m2m) begin
                fsm_mem_keep = pixel_wr_keep;
                fsm_mem_rmw  = pixel_rmw;
              end
            end
          end
          default: ;  // no transaction (shouldn't reach with needs_memory_op=0)
        endcase
        if (fsm_mem_ack) begin
          // Multi-step instructions stay in CORE_MEMORY until their
          // final step's ack; everything else transitions on every ack.
          unique case (decoded.iclass)
            INSTR_RETI: if (mem_op_step == 2'd1) state_d = CORE_WRITEBACK;
            INSTR_TRAP: if (trap_skip_push || mem_op_step == 2'd2)
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
                            == (pixt_m2m_rmw ? 2'd2 : 2'd1))
                          state_d = CORE_WRITEBACK;
            // A destination-reading PIXT stays for its write; direct store exits.
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
  // Every word read through the PC: opcodes, immediates, displacements and
  // absolute addresses (5.4).
  assign fsm_mem_ifetch = (state_q == CORE_FETCH)
                       || (state_q == CORE_FETCH_IMM_LO)
                       || (state_q == CORE_FETCH_IMM_HI)
                       || (state_q == CORE_FETCH_IMM_EXT_LO)
                       || (state_q == CORE_FETCH_IMM_EXT_HI);

  tms34010_icache #(
    .ENABLE (CYCLE_ACCURATE)
  ) u_icache (
    .clk      (clk),
    .rst      (rst),
    .cd_i     (io_control[CTRL_CD_BIT]),
    .cf_i     (io_hstctlh[HSTCTL_CF_BIT]),
    .c_req    (fsm_mem_req && !(((mem_we_int || (state_q == CORE_LINE_DRAW)
                                      || (state_q == CORE_FILL)
                                      || ((state_q == CORE_PBLT) && pbw_word))
                                     && pace_write_hold)
                                    || (((state_q == CORE_FILL)
                                         || ((state_q == CORE_PBLT) && pbw_word))
                                        && pace_fill_hold))),
    .c_we     (fsm_mem_we),
    .c_addr   (fsm_mem_addr),
    .c_size   (fsm_mem_size),
    .c_wdata  (fsm_mem_wdata),
    .c_iaq    (fsm_mem_iaq),
    .c_ifetch (fsm_mem_ifetch),
    .c_pc     (pc_value),
    .c_srt    (fsm_mem_srt),
    .c_is_io  (fsm_mem_is_io),
    .c_io_we  (fsm_mem_io_we),
    .c_ack    (fsm_mem_ack),
    .c_rdata  (fsm_mem_rdata),
    .c_from_mem (fsm_mem_from_mem),
    .m_req    (mem_req),
    .m_we     (mem_we),
    .m_addr   (mem_addr),
    .m_size   (mem_size),
    .m_wdata  (mem_wdata),
    .m_iaq    (mem_iaq),
    .m_srt    (mem_srt),
    .m_is_io  (mem_is_io),
    .m_io_we  (mem_io_we),
    .m_ack    (mem_ack),
    .m_rdata  (mem_rdata)
  );
  assign mem_io_rdata = fsm_mem_io_rdata;
  // Data writes pass the cache unchanged (it only answers instruction reads).
  assign mem_keep     = fsm_mem_keep;
  assign mem_rmw      = fsm_mem_rmw;

  // Late write data (CYCLE_ACCURATE, see pbw_result_q and pix_res_q): a
  // PIXBLT word write or single-pixel write is raised with mem_late, and its
  // data and keep mask are given here one clock later.
  assign mem_late       = CYCLE_ACCURATE && (pix_wr_step || pbw_wr_step);
  assign mem_late_wdata = pbw_late_q      ? {16'd0, pbw_result_q}
                        : pix_plain_sel_q ? pix_plain_q
                        :                   pixel_wr_data;
  assign mem_late_keep  = pbw_late_q ? {16'd0, pbw_keep} : pixel_wr_keep;
`ifdef VERILATOR
  // Simulation guard: the late data of every pixel or word write the memory
  // takes is what the live path gives in the clock it is taken.
  logic [15:0]           g_pbw_keep;
  logic [DATA_WIDTH-1:0] g_wdata, g_keep, g_wdata_q, g_keep_q;
  logic                  g_late_q = 1'b0, g_late_d2_q = 1'b0;
  assign g_pbw_keep = (pbw_dst_pm
                       | (pixel_transp_en_q
                          ? zero_pixels(pbw_result & ~pbw_dst_pm,
                                        io_psize[FIELD_SIZE_WIDTH-1:0])
                          : 16'd0))
                    & pbw_step_mask;
  assign g_wdata = pbw_wr_step      ? {16'd0, pbw_result}
                 : pix_wr_plain_sel ? pix_wr_plain
                 :                    pixel_ppop_merged;
  assign g_keep  = pbw_wr_step ? {16'd0, g_pbw_keep} : pixel_keep;
  always_ff @(posedge clk) begin
    g_late_q <= 1'b0;
    if (CYCLE_ACCURATE && g_armed_q && !rst && fsm_mem_req && fsm_mem_ack
        && (pix_wr_step || pbw_wr_step)) begin
      g_late_q  <= 1'b1;
      g_wdata_q <= g_wdata;
      g_keep_q  <= g_keep;
    end
    if (g_late_q && (mem_late_wdata != g_wdata_q || mem_late_keep != g_keep_q)) begin
      $display("LATE WR MISMATCH t=%0t data %h/%h keep %h/%h", $time,
               mem_late_wdata, g_wdata_q, mem_late_keep, g_keep_q);
      $fatal(1);
    end
    // and the I/O write snapshot holds it from the next clock (it commits
    // from there for a write into the I/O page).
    g_late_d2_q <= g_late_q;
    if (g_late_d2_q && (io_request_wdata_q != g_wdata_q || io_request_keep_q != g_keep_q)) begin
      $display("LATE IO MISMATCH t=%0t data %h/%h keep %h/%h", $time,
               io_request_wdata_q, g_wdata_q, io_request_keep_q, g_keep_q);
      $fatal(1);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // CYCLE_ACCURATE instruction pacing (docs/cycle_accuracy.md).
  //
  // Each instruction gets its CPU states: its microcode length, worked out
  // from the 1988 UG Section 12 "Machine States" cache-hit figures and the
  // Section 13 tables, less the two states of every data word it reads.
  // States in which the CPU waits for memory don't count, so bus cycles,
  // cache fills and hidden writes add their own time. Each instruction word
  // that had to come from memory adds one state (13.1: cache-disabled =
  // cache-hit + 3 per word; 5.4.7: a miss costs 8 + 1). The next opcode
  // fetch starts on the first clock of the state after the count is met.
  // ---------------------------------------------------------------------------
  generate
    if (CYCLE_ACCURATE) begin : g_pace
      localparam int unsigned PW = (CLKS_PER_STATE > 1) ? $clog2(CLKS_PER_STATE) : 1;
      // The core's fixed per-instruction work (decode, the fabric's request
      // register) has to fit inside one state, so the guide's state counts
      // hold only from 8 core clocks per state (docs/cycle_accuracy.md).
      // synthesis translate_off
      initial if (CLKS_PER_STATE < 8)
        $error("tms34010_core: CYCLE_ACCURATE needs CLKS_PER_STATE >= 8 (got %0d)",
               CLKS_PER_STATE);
      // synthesis translate_on

      // Justification (a): position in the machine state, this
      // instruction's counted CPU states and memory-sourced words, the
      // in-state wait flag, the latched branch outcome, and the release.
      logic [PW-1:0] phase_q;
      logic [19:0]    cpu_cnt_q;
      logic [3:0]    mem_words_q;
      logic          waited_q;
      logic          taken_q;
      logic          released_q;
      logic          int_entry_q;  // an interrupt or illegal-opcode entry is running
      logic          read3_q;      // this instruction read a three-word field
      logic          write3_q;     // ... and wrote one (Table 13-4 index 13)
      logic          span3;
      logic          span3_q;      // span3 one clock ago

      logic          last_clk;
      logic          waiting;
      logic          state_counts;
      logic [19:0]    cpu_cnt_next;
      logic [19:0]    cpu_states;
      logic [19:0]    need;
      logic          due;

      assign last_clk = (CLKS_PER_STATE <= 1) || (phase_q == PW'(CLKS_PER_STATE - 1));
      assign waiting  = mem_req && !mem_ack;
      assign state_counts = !(waited_q || waiting);
      assign cpu_cnt_next = cpu_cnt_q + (state_counts ? 20'd1 : 20'd0);

      // Extra CPU states for the pixel processing operation, beyond reading
      // the destination (12-214..12-225, 12-68): Replace, Booleans and ADD
      // none; ADDS, SUB, MAX and MIN one; SUBS two.
      logic [4:0] ppop;
      logic [19:0] ppop_states;
      assign ppop = io_control[CTRL_PPOP_HI:CTRL_PPOP_LO];
      always_comb begin
        unique case (ppop)
          5'b10001, 5'b10010, 5'b10100, 5'b10101: ppop_states = 20'd1;
          5'b10011:                               ppop_states = 20'd2;
          default:                                ppop_states = 20'd0;
        endcase
      end

      // LINE (13.6): 4 setup states, then 3 + P per pixel drawn, P = 2 for
      // Replace (Table 12-11). The other operations' P adds the destination
      // read (two bus states, counted by the bus model) and the same extra
      // states as PIXT. A pixel's memory accesses start after its first three
      // CPU states; its write is posted and overlaps the next pixel's first
      // states. This is the order that gives the guide's figures at every
      // PSIZE (a PSIZE < 16 write is a read-modify-write of 4 bus states).
      logic [15:0] pix_cnt_q;      // pixels this instruction has written
      // FILL (13.3, Tables 13-5/13-6). The engine posts one word (or edge
      // field) per step; the bus model times the words. After a row's last
      // write has finished the CPU spends a few states on the row, and after
      // the last row a few more; the numbers depend on the row class (N = 1,
      // 2, 3+ words) and which row edges are word aligned (Table 13-6 less
      // the edge read-modify-writes, which the bus times). Pixel processing
      // reads each word and spends ADDS/SUB/MAX/MIN one, SUBS two states on
      // it before the write (Table 13-7).
      logic [5:0]  fill_setup_q;   // Table 13-5
      logic        fill_win_q, fill_clip_q, fill_start_q, fill_dim_q;
      logic [3:0]  fill_wait_q;    // row / end states still to come
      logic [1:0]  fill_ppw_q;     // pixel processing states before a write
      logic [20:0] fill_row_end_off;
      logic        fill_lead_al, fill_trail_al;
      logic [3:0]  fill_row_states, fill_end_states;
      assign fill_row_end_off = {17'd0, fill_row_base_q[3:0]}
                              + ({5'd0, fill_dx_q} << pix_xy_xsh);
      assign fill_lead_al  = (fill_row_base_q[3:0] == 4'd0);
      assign fill_trail_al = (fill_row_end_off[3:0] == 4'd0);
      always_comb begin
        if (fill_row_end_off <= 21'd16) begin            // short
          fill_row_states = (fill_lead_al && fill_trail_al) ? 4'd1 : 4'd0;
          fill_end_states = fill_lead_al ? 4'd2 : 4'd1;
        end else if (fill_row_end_off <= 21'd32) begin   // medium
          fill_row_states = {3'd0, fill_lead_al} + {3'd0, fill_trail_al};
          fill_end_states = (fill_lead_al || fill_trail_al) ? 4'd2 : 4'd1;
        end else begin                                   // long
          fill_row_states = {3'd0, fill_trail_al};
          fill_end_states = !fill_lead_al ? (fill_trail_al ? 4'd2 : 4'd1)
                          : (fill_trail_al ? 4'd2 : 4'd5);
        end
      end
      // Full-color PIXBLT (13.4, Tables 13-8/13-9), the same way: setup, the
      // bus model for the source reads and destination words, then row and
      // end states after each row's last write, from Table 13-9 less the
      // source reads and edge read-modify-writes the bus times (docs).
      logic [5:0]  pblt_setup_q;
      logic [DATA_WIDTH-1:0] pbt_dst_lo, pbt_bits;
      logic [20:0] pbt_end_off;
      logic [4:0]  pbt_first_bits;
      logic [DATA_WIDTH-1:0] pbt_src_first;
      logic        pbt_lead_al, pbt_trail_al, pbt_two_src;
      logic [3:0]  pblt_row_states, pblt_end_states;
      assign pbt_bits     = {16'd0, pblt_dx_q} << pix_xy_xsh;
      assign pbt_dst_lo   = pblt_hrev_q ? pblt_dst_row_q - pbt_bits : pblt_dst_row_q;
      assign pbt_end_off  = {17'd0, pbt_dst_lo[3:0]} + pbt_bits[20:0];
      assign pbt_lead_al  = (pbt_dst_lo[3:0] == 4'd0);
      assign pbt_trail_al = (pbt_end_off[3:0] == 4'd0);
      // The row's first destination word and whether it needs two source
      // words (D < S, 13.4.2.4).
      always_comb begin
        if (pblt_hrev_q) begin
          pbt_first_bits = (pblt_dst_row_q[3:0] == 4'd0) ? 5'd16 : {1'b0, pblt_dst_row_q[3:0]};
          if (pbt_bits < DATA_WIDTH'(pbt_first_bits)) pbt_first_bits = 5'(pbt_bits);
          pbt_src_first  = pblt_src_row_q - DATA_WIDTH'(pbt_first_bits);
        end else begin
          pbt_first_bits = 5'd16 - {1'b0, pblt_dst_row_q[3:0]};
          if (pbt_bits < DATA_WIDTH'(pbt_first_bits)) pbt_first_bits = 5'(pbt_bits);
          pbt_src_first  = pblt_src_row_q;
        end
        pbt_two_src = ({1'b0, pbt_src_first[3:0]} + pbt_first_bits) > 5'd16;
      end
      always_comb begin
        if (!pblt_hrev_q) begin
          if (pbt_end_off <= 21'd16) begin
            pblt_row_states = pbt_two_src ? 4'd0 : 4'd2;
            pblt_end_states = (pbt_lead_al && pbt_trail_al) ? 4'd5 : 4'd3;
          end else begin
            pblt_row_states = (pbt_end_off <= 21'd32) ? 4'd2 : 4'd0;
            pblt_end_states = (pbt_trail_al ? 4'd5 : 4'd3) - {3'd0, pbt_two_src};
          end
        end else begin
          if (pbt_end_off <= 21'd16) begin
            pblt_row_states = (pbt_lead_al && pbt_trail_al && !pbt_two_src) ? 4'd1 : 4'd0;
            pblt_end_states = (pbt_lead_al && pbt_trail_al) ? 4'd8 : 4'd7;
          end else begin
            pblt_row_states = ((pbt_end_off <= 21'd32) ? 4'd2 : 4'd1)
                            - {3'd0, pbt_two_src && !pbt_trail_al};
            pblt_end_states = (pbt_trail_al ? 4'd4 : 4'd3) + {3'd0, pbt_two_src};
          end
        end
      end
      // Expand (13.5.2.3, Table 13-12): after each source segment is read
      // the CPU spends 3 states before writing, 1 when the segment's first
      // destination write is not a whole word (its read-modify-write is
      // timed by the bus).
      logic [1:0]  pbx_wait_q;
      logic [15:0] pbx_first_px;
      logic        pbx_first_full;
      assign pbx_first_px   = (pblt_rem_q < pbw_room_px) ? pblt_rem_q : pbw_room_px;
      assign pbx_first_full = (pblt_dst_addr_q[3:0] == 4'd0)
                           && ((pbx_first_px << pix_xy_xsh) == 16'd16)
                           && ({10'd0, 6'(fsm_mem_size)} >= pbx_first_px);
      assign pace_fill_hold = (fill_wait_q != 4'd0) || (fill_ppw_q != 2'd0)
                           || (pbx_wait_q != 2'd0);
      logic [15:0] skip_cnt_q;     // LINE pixels calculated, not written, no violation
      logic [5:0]  mpy_half_q;     // FS1/2, rounded up (FS1 = 0 is 32)
      logic        mpy_neg_q;      // MPYU: Rs's FS1-bit field has its MSB set
      // Window checking (7.10): a pixel that W=1 or a window miss/clip leaves
      // undrawn. The PIXT XY,XY page gives no W=1 figure; taken as W=2's
      // (docs C9).
      logic [1:0]  win_w;
      logic        pixt_nodraw, drav_nodraw;
      assign win_w       = io_control[CTRL_W_HI:CTRL_W_LO];
      assign pixt_nodraw = pixt_xy_win && ((win_w == 2'd1) || !pixt_inside_q);
      assign drav_nodraw = (drav_w_q == 2'd1)
                        || ((drav_w_q != 2'd0) && !drav_inside_q);
      // A divide whose quotient magnitude is 2^31 (12-63, 12-113).
      logic        div_min;
      assign div_min = (decoded.iclass == INSTR_DIVS || decoded.iclass == INSTR_MODS)
                    && (div_quotient == 32'h8000_0000);
      logic [19:0] line_px;        // pixel states so far: pix_cnt x (5 + extra)
      // Table 12-10: a pixel calculated but not written takes 5 states, and
      // so does a window violation (W=1, W=2) or, with W=1, the end of the
      // line (5q + 5; docs C10).
      logic [19:0] line_win_px;
      assign line_win_px = ({4'd0, skip_cnt_q} << 2) + {4'd0, skip_cnt_q}
                         + (((line_w_mode == 2'd1) || line_aborted_q) ? 20'd5 : 20'd0);
      always_comb begin
        line_px = ({4'd0, pix_cnt_q} << 2) + {4'd0, pix_cnt_q} + line_win_px;
        if (ppop_states == 20'd1)      line_px = line_px + {4'd0, pix_cnt_q};
        else if (ppop_states == 20'd2) line_px = line_px + ({4'd0, pix_cnt_q} << 1);
      end

      always_comb begin
        cpu_states = 20'd1;
        unique case (decoded.iclass)
          // Section 12 pages: two states.
          INSTR_MOVI_IW, INSTR_ADDI_IW, INSTR_SUBI_IW, INSTR_CMPI_IW,
          INSTR_BTST_RR, INSTR_JUMP_RS, INSTR_EXGPC:
            cpu_states = 20'd2;
          // Three states.
          INSTR_MOVI_IL, INSTR_ADDI_IL, INSTR_SUBI_IL, INSTR_CMPI_IL,
          INSTR_ANDI_IL, INSTR_ORI_IL, INSTR_XORI_IL, INSTR_SLA_K,
          INSTR_SLA_RR, INSTR_SEXT, INSTR_DINT, INSTR_EINT, INSTR_PUTST,
          INSTR_CVXYL:
            cpu_states = 20'd3;
          // 12-237: SETF 1 state for F=0, 2 for F=1.
          INSTR_SETF:       cpu_states = instr_word_q[9] ? 20'd2 : 20'd1;
          // 12-95, 12-97, 12-93, 12-75, 12-70..12-73: taken / not taken.
          INSTR_JRCC_SHORT: cpu_states = taken_q ? 20'd2 : 20'd1;
          // 12-97: long JRcc not taken 4 (the 1986 first edition says 2).
          INSTR_JRCC_LONG:  cpu_states = taken_q ? 20'd3 : 20'd4;
          INSTR_JACC:       cpu_states = taken_q ? 20'd3 : 20'd4;
          INSTR_DSJS:       cpu_states = taken_q ? 20'd2 : 20'd3;
          INSTR_DSJ, INSTR_DSJEQ, INSTR_DSJNE:
                            cpu_states = taken_q ? 20'd3 : 20'd2;
          // 12-165, 12-167: 5 + FS1/2; MPYU one more if Rs is
          // negative (taken as the MSB of its FS1-bit field, docs C11).
          INSTR_MPYS:       cpu_states = 20'd5 + {14'd0, mpy_half_q};
          INSTR_MPYU:       cpu_states = 20'd5 + {14'd0, mpy_half_q}
                                       + (mpy_neg_q ? 20'd1 : 20'd0);
          // 12-63, 12-65, 12-113, 12-114: early end on overflow / Rs = 0;
          // DIVS and MODS take one more state when the result is >80000000
          // (taken as a quotient magnitude of 2^31, docs C8).
          INSTR_DIVS:       cpu_states = div_overflow ? 20'd7
                                       : (decoded.rd_idx[0] ? 20'd39 : 20'd40)
                                         + (div_min ? 20'd1 : 20'd0);
          INSTR_DIVU:       cpu_states = div_overflow ? 20'd5 : 20'd37;
          INSTR_MODS:       cpu_states = div_overflow ? 20'd3
                                       : 20'd40 + (div_min ? 20'd1 : 20'd0);
          INSTR_MODU:       cpu_states = div_overflow ? 20'd3 : 20'd35;
          // 12-77.
          INSTR_EMU:        cpu_states = 20'd8;
          // Stack: cache-hit figure less the words read (12-227..12-232).
          INSTR_PUSHST:     cpu_states = 20'd2;
          INSTR_POPST:      cpu_states = 20'd4;
          INSTR_CALL_RS:    cpu_states = 20'd3;
          INSTR_CALLA:      cpu_states = 20'd4;
          INSTR_CALLR:      cpu_states = 20'd3;
          INSTR_RETS:       cpu_states = 20'd3;
          INSTR_RETI:       cpu_states = 20'd3;
          // 12-254: 16 states with SP aligned, 30 without; the pushes and the
          // vector read come out of the bus model, and the guide's non-aligned
          // figure has two more CPU states.
          INSTR_TRAP:       cpu_states = (rf_sp[3:0] != 4'd0) ? 20'd6 : 20'd4;
          // Tables 13-1 and 13-2: the forms' cache-hit figures less the
          // words read; MOVE loads add one for sign extension (13-1 note 1).
          // PIXT (12-214..12-225): the forms' Replace figures less the words
          // read; XY forms add the conversion.
          // A windowed XY pixel that is not drawn (W=1, or outside the
          // window): the "Window Violation" columns of 12-216 and 12-225.
          INSTR_MOVE_FIELD_STORE:
            cpu_states = pixt_nodraw ? ((win_w == 2'd3) ? 20'd4 : 20'd6)
                       : decoded.force_pixel
                       ? ((decoded.xy_addr ? 20'd4 : 20'd2) + ppop_states)
                       : (decoded.move_mode == MV_ADDR_PREDEC) ? 20'd2 : 20'd1;
          INSTR_MOVE_FIELD_LOAD:
            cpu_states = decoded.force_pixel ? (decoded.xy_addr ? 20'd4 : 20'd2)
                       : ((decoded.move_mode == MV_ADDR_PREDEC) ? 20'd2 : 20'd1)
                       + ((mv_fe && !decoded.force_byte && !decoded.force_pixel
                           && (mv_fs != FIELD_SIZE_WIDTH'(DATA_WIDTH))) ? 20'd1 : 20'd0);
          INSTR_MOVE_OFF_STORE, INSTR_MOVE_ABS_STORE:
            cpu_states = 20'd3;
          INSTR_MOVE_OFF_LOAD, INSTR_MOVE_ABS_LOAD:
            cpu_states = 20'd3
                       + ((mv_fe && !decoded.force_byte
                           && (mv_fs != FIELD_SIZE_WIDTH'(DATA_WIDTH))) ? 20'd1 : 20'd0);
          // Table 13-4.
          INSTR_MOVE_FIELD_M2M:
            cpu_states = pixt_nodraw ? ((win_w == 2'd3) ? 20'd6 : 20'd8)
                       : decoded.force_pixel
                       ? ((decoded.xy_addr ? 20'd5 : 20'd2) + ppop_states)
                       : (decoded.move_mode == MV_ADDR_NONE) ? 20'd1 : 20'd2;
          // 12-68 DRAV; its "Window Violation" columns when the pixel is not drawn.
          INSTR_DRAV:       cpu_states = drav_nodraw ? ((drav_w_q == 2'd2) ? 20'd3 : 20'd5)
                                       : 20'd4 + ppop_states;
          INSTR_LINE:       cpu_states = 20'd4 + line_px;
          // 13.3.1, Table 13-5: FILL setup; the transfer is timed by the
          // engine (fill_wait_q).
          INSTR_FILL_L, INSTR_FILL_XY: cpu_states = {14'd0, fill_setup_q};
          INSTR_PIXBLT_LL:
                            cpu_states = {14'd0, pblt_setup_q};
          INSTR_MOVE_OFF_M2M_PI, INSTR_MOVE_ABS_M2M_PI,
          INSTR_MOVE_OFF_M2M, INSTR_MOVB_OFF_M2M:
            cpu_states = 20'd3;
          INSTR_MOVE_ABS_M2M, INSTR_MOVB_ABS_M2M:
            cpu_states = 20'd5;
          // 12-110 MMFM 3 + 4n (Rp aligned), 3 + 6n (not): the n
          // 32-bit reads of two or three words.
          INSTR_MMFM:       cpu_states = 20'd3;
          // 12-112 MMTM aligned 2 + 4n + (2): four CPU states, then the n
          // 32-bit writes back to back through the one-deep controller
          // (the CPU waits while each is in progress), and two more states
          // after the last write is taken: 2 + 4n, with 2 hidden.
          INSTR_MMTM:       cpu_states = 20'd6;
          default:          cpu_states = 20'd1;
        endcase
      end

      // The CPU state in which an instruction's write starts. From the
      // guide's hidden states: hidden = start + bus states - 1 - CPU states
      // (Table 13-2 for MOVE/MOVB stores; 12-48..12-50 CALL; 12-228 PUSHST).
      logic [19:0] write_state;
      always_comb begin
        write_state = 20'd1;
        unique case (decoded.iclass)
          INSTR_MOVE_FIELD_STORE:
            write_state = decoded.force_pixel
                        ? ((decoded.xy_addr ? 20'd4 : 20'd2) + ppop_states)
                        : (decoded.move_mode == MV_ADDR_PREDEC) ? 20'd2 : 20'd1;
          INSTR_DRAV:       write_state = 20'd4 + ppop_states;
          INSTR_LINE:       write_state = 20'd8 + line_px;
          INSTR_FILL_L, INSTR_FILL_XY: write_state = {14'd0, fill_setup_q} + 20'd1;
          INSTR_PIXBLT_LL:
                            write_state = {14'd0, pblt_setup_q} + 20'd1;
          // Table 13-4: the write starts in the last CPU state for the
          // predecrement, offset and absolute forms, the first otherwise.
          INSTR_MOVE_FIELD_M2M:
            write_state = decoded.force_pixel
                        ? ((decoded.xy_addr ? 20'd5 : 20'd2) + ppop_states)
                        : (decoded.move_mode == MV_ADDR_PREDEC) ? 20'd2 : 20'd1;
          INSTR_MOVE_OFF_M2M_PI, INSTR_MOVE_ABS_M2M_PI,
          INSTR_MOVE_OFF_M2M, INSTR_MOVB_OFF_M2M:
            write_state = 20'd3;
          INSTR_MOVE_ABS_M2M, INSTR_MOVB_ABS_M2M:
            write_state = 20'd5;
          INSTR_MOVE_OFF_STORE, INSTR_MOVE_ABS_STORE:
            write_state = 20'd3;
          // 12-228 PUSHST: 2+(3) aligned, 2+(8) not: with SP not aligned the
          // five-cycle write starts a state earlier.
          INSTR_PUSHST:     write_state = (rf_sp[3:0] != 4'd0) ? 20'd1 : 20'd2;
          INSTR_CALLR:      write_state = 20'd2;
          INSTR_CALL_RS, INSTR_CALLA: write_state = 20'd3;
          INSTR_MMTM:                 write_state = 20'd5;
          default:          write_state = 20'd1;
        endcase
      end
      // The extra state of each memory-sourced instruction word comes
      // before the instruction's own CPU states.

      // A data field that touches three words (alignment G, Figure 13-1).
      assign span3 = (({2'b00, fsm_mem_addr[3:0]} + fsm_mem_size) > 6'd32);

      // Table 13-4: a memory-to-memory move whose source and destination are
      // both alignment G takes two more states than the other columns give,
      // in every form.
      logic       m2m;
      logic [19:0] gg_states;
      assign m2m = (decoded.iclass == INSTR_MOVE_FIELD_M2M && !decoded.force_pixel)
                || (decoded.iclass == INSTR_MOVE_OFF_M2M_PI)
                || (decoded.iclass == INSTR_MOVE_ABS_M2M_PI)
                || (decoded.iclass == INSTR_MOVE_OFF_M2M)
                || (decoded.iclass == INSTR_MOVE_ABS_M2M);
      assign gg_states = (m2m && read3_q && write3_q) ? 20'd2 : 20'd0;

      // Interrupt and illegal-opcode entry push PC and ST and read the vector,
      // as TRAP does (12-254, 8.4). Table 8-4 note 3: 16 states with SP
      // aligned, 28 without; four CPU states either way (TRAP's non-aligned
      // figure, 30, has two more).
      assign need = (int_entry_q ? 20'd4
                                 : (cpu_states + gg_states))
                  + {16'd0, mem_words_q};
      // The next fetch is released in the first clock of a state, once the
      // states completed so far cover the instruction (docs/cycle_accuracy.md).
      logic first_clk;
      assign first_clk = (CLKS_PER_STATE <= 1) || (phase_q == '0);

      // The two extra G-to-G states come before the write (its hidden
      // states match the other columns').
      logic [19:0] gg_write;
      assign gg_write = (m2m && read3_q && span3_q) ? 20'd2 : 20'd0;
      assign pace_write_hold = (state_q != CORE_FETCH)
                            && ((cpu_cnt_q + 20'd1) < wthresh_q);
      // need and the write threshold are registered: they depend on the
      // decoded instruction (fixed from CORE_DISPATCH), the latched branch
      // outcome and counters, all settled at least a clock before use, and
      // registering them keeps the decode tables out of the request path.
      logic [19:0] need_q;
      logic [19:0] wthresh_q;
      always_ff @(posedge clk) begin
        if (rst) begin
          need_q    <= 20'd1;
          wthresh_q <= 20'd1;
          span3_q   <= 1'b0;
        end else begin
          need_q    <= need;
          wthresh_q <= write_state + gg_write + {16'd0, mem_words_q};
          span3_q   <= span3;
        end
      end
      assign due  = first_clk && (state_q == CORE_FETCH) && !released_q
                 && (cpu_cnt_q >= need_q) && (fill_wait_q == 4'd0);
      assign pace_hold = !(released_q || due);

      always_ff @(posedge clk) begin
        if (rst) begin
          phase_q     <= '0;
          cpu_cnt_q   <= '0;
          mem_words_q <= '0;
          waited_q    <= 1'b0;
          taken_q     <= 1'b0;
          released_q  <= 1'b0;
          read3_q     <= 1'b0;
          write3_q    <= 1'b0;
          int_entry_q <= 1'b0;
          pix_cnt_q   <= '0;
          skip_cnt_q  <= '0;
          fill_setup_q <= 6'd4;
          fill_win_q   <= 1'b0;
          fill_clip_q  <= 1'b0;
          fill_start_q <= 1'b0;
          fill_dim_q   <= 1'b0;
          pblt_setup_q <= 6'd7;
          fill_wait_q <= '0;
          fill_ppw_q  <= '0;
          pbx_wait_q  <= '0;
          mpy_half_q  <= '0;
          mpy_neg_q   <= 1'b0;
        end else begin
          if (last_clk) phase_q <= '0;
          else          phase_q <= phase_q + 1'b1;

          waited_q <= last_clk ? 1'b0 : (waited_q || waiting);

          if (state_q == CORE_WRITEBACK)
            taken_q <= pc_load_en;

          if (due) begin
            // The next instruction starts with the coming state.
            released_q  <= 1'b1;
            cpu_cnt_q   <= '0;
            mem_words_q <= '0;
            read3_q     <= 1'b0;
            write3_q    <= 1'b0;
            int_entry_q <= 1'b0;
            pix_cnt_q   <= '0;
            skip_cnt_q  <= '0;
          end else begin
            if (state_q == CORE_LINE_DRAW && fsm_mem_req && mem_we_int && fsm_mem_ack
                && pix_cnt_q != 16'hFFFF)
              pix_cnt_q <= pix_cnt_q + 1'b1;
            // FILL setup (Table 13-5): FILL L 4, FILL XY 6; with W=3
            // preclipping 9 if the array fits, 16 if the start corner moves,
            // 12 if only the far corner moves, 20 for both. W=1/W=2 and an
            // array wholly outside the window: no figure (docs C12).
            if (state_q == CORE_EXECUTE && is_fill)
              fill_setup_q <= fill_is_xy ? 6'd6 : 6'd4;
            // (The preclip outcome is registered at CORE_FILL_SETUP_WIN and
            // the figure chosen a clock later, off the window-read path; the
            // first access waits for the setup states anyway.)
            if (state_q == CORE_FILL_SETUP_WIN && fill_win_eval_q) begin
              fill_win_q   <= 1'b1;
              fill_clip_q  <= fill_win_en_q && fill_clip_hit;
              fill_start_q <= (fill_clip_x0 != fill_arr_x0) || (fill_clip_y0 != fill_arr_y0);
              fill_dim_q   <= (fill_clip_x1 != fill_arr_x1) || (fill_clip_y1 != fill_arr_y1);
            end else
              fill_win_q   <= 1'b0;
            if (fill_win_q)
              fill_setup_q <= !fill_clip_q ? 6'd9
                            : fill_start_q ? (fill_dim_q ? 6'd20 : 6'd16)
                            : (fill_dim_q ? 6'd12 : 6'd9);
            // PIXBLT setup (Table 13-8): L,L 7, XY,L and L,XY 9, XY,XY 12;
            // with an XY destination and W=3 preclipping 3 more if the array
            // fits, 10 if the start corner moves, 6 if the far corner moves,
            // 14 for both; corner adjust for the XY forms +1 (PBH), +2 (PBV),
            // +4 (both).
            // Expand (Table 13-11): B,L 4, B,XY 6; W=3 9/17/12/21.
            if (state_q == CORE_EXECUTE && is_pblt)
              pblt_setup_q <= decoded.blt_binary ? (decoded.blt_dst_xy ? 6'd6 : 6'd4)
                            : (decoded.blt_src_xy && decoded.blt_dst_xy) ? 6'd12
                            : (decoded.blt_src_xy || decoded.blt_dst_xy) ? 6'd9 : 6'd7;
            if (state_q == CORE_PBLT_SETUP && pblt_auto_corner_q)
              pblt_setup_q <= pblt_setup_q
                            + ((pblt_hrev_q && pblt_vrev_q) ? 6'd4
                               : pblt_vrev_q ? 6'd2 : pblt_hrev_q ? 6'd1 : 6'd0);
            if (state_q == CORE_PBLT_WIN_EVAL && pblt_win_en_q)
              pblt_setup_q <= pblt_setup_q
                + (!pblt_clip_hit ? 6'd3
                   : ((pblt_clip_x0 != pblt_arr_x0) || (pblt_clip_y0 != pblt_arr_y0))
                     ? (((pblt_clip_x1 != pblt_arr_x1) || (pblt_clip_y1 != pblt_arr_y1))
                        ? (decoded.blt_binary ? 6'd15 : 6'd14)
                        : (decoded.blt_binary ? 6'd11 : 6'd10))
                   : (((pblt_clip_x1 != pblt_arr_x1) || (pblt_clip_y1 != pblt_arr_y1))
                      ? 6'd6 : 6'd3));
            // A row's last write: its row states, and after the last row the
            // end states too, counted once the controller has finished.
            if (state_q == CORE_FILL && fsm_mem_req && fsm_mem_ack && mem_we_int
                && fill_row_end)
              fill_wait_q <= fill_done ? (fill_row_states + fill_end_states)
                                       : fill_row_states;
            else if (state_q == CORE_PBLT && pbw_word && fsm_mem_req && fsm_mem_ack
                     && mem_we_int && pblt_row_end)
              // Expand (Table 13-12): no row states (each source segment has
              // its own), 3 at the end.
              fill_wait_q <= pbx_on ? (pblt_done ? 4'd3 : 4'd0)
                           : pblt_done ? (pblt_row_states + pblt_end_states)
                                       : pblt_row_states;
            else if (last_clk && (fill_wait_q != 4'd0) && !mem_busy)
              fill_wait_q <= fill_wait_q - 4'd1;
            if (state_q == CORE_PBLT && pbx_on && pblt_substep_q == 2'd0
                && fsm_mem_req && fsm_mem_ack)
              pbx_wait_q <= pbx_first_full ? 2'd3 : 2'd1;
            else if (last_clk && (pbx_wait_q != 2'd0))
              pbx_wait_q <= pbx_wait_q - 2'd1;
            if ((state_q == CORE_FILL && fsm_mem_req && fsm_mem_ack && !mem_we_int)
                || (state_q == CORE_PBLT && pbw_word && pblt_substep_q == 2'd1
                    && fsm_mem_req && fsm_mem_ack))
              fill_ppw_q <= 2'(ppop_states);
            else if (last_clk && (fill_ppw_q != 2'd0))
              fill_ppw_q <= fill_ppw_q - 2'd1;
            if (state_q == CORE_LINE_DRAW && line_skip && !line_abort
                && skip_cnt_q != 16'hFFFF)
              skip_cnt_q <= skip_cnt_q + 1'b1;
            if (state_q == CORE_EXECUTE && is_mpy) begin
              mpy_half_q <= (mpy_fs1 == 5'd0) ? 6'd16 : ({1'b0, mpy_fs1} + 6'd1) >> 1;
              mpy_neg_q  <= (mpy_fs1 == 5'd0) ? rf_rs1_data[DATA_WIDTH-1]
                                              : rf_rs1_data[mpy_fs1 - 5'd1];
            end
            if (state_q == CORE_INT_PUSH_PC || state_q == CORE_INT_VECTOR)
              int_entry_q <= 1'b1;
            if (fsm_mem_req && !fsm_mem_ifetch && !fsm_mem_is_io && span3) begin
              if (fsm_mem_we) write3_q <= 1'b1;
              else            read3_q  <= 1'b1;
            end
            if (last_clk && cpu_cnt_q != 20'hFFFFF) cpu_cnt_q <= cpu_cnt_next;
            if (fsm_mem_from_mem && fsm_mem_ifetch && mem_words_q != 4'hF)
              mem_words_q <= mem_words_q + 1'b1;
            if (state_q != CORE_FETCH && state_q != CORE_RESET)
              released_q <= 1'b0;
          end
        end
      end
    end else begin : g_no_pace
      assign pace_hold       = 1'b0;
      assign pace_write_hold = 1'b0;
      assign pace_fill_hold  = 1'b0;
    end
  endgenerate

  assign pc_o             = pc_value;
  assign instr_word_o     = instr_word_q;
  assign illegal_opcode_o = illegal_q;
  assign emua_n_o         = !((state_q == CORE_EXECUTE && is_emu)
                           || (state_q == CORE_EMU_HALT));

endmodule : tms34010_core
`default_nettype wire
