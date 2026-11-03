// -----------------------------------------------------------------------------
// tms34010_status_reg.sv
//
// 32-bit status register (ST) for the TMS34010 core.
//
// ST holds, per bibliography/hdl-reimplementation/03-registers.md:
//   - Condition flags N, C, Z, V (from ALU and shifter).
//   - Field-size mode bits FE0/FE1 + extension bits  (Phase 4-5 work).
//   - Interrupt enable bits (E, IE)                  (Phase 8 work).
//   - Other privilege / mode bits                    (deferred).
//
// In Phase 2, only the four condition flags are populated by name. Non-flag
// bits hold whatever was last written via the full ST write port (POPST in
// Phase 4) — they default to 0 at reset.
//
// Bit positions are package parameters (`ST_N_BIT` etc., placeholders per
// docs/assumptions.md A0010 pending SPVU001A Ch. 2 read). Consumers in the
// rest of the design reference the named flag outputs (`n_o`, `c_o`,
// `z_o`, `v_o`), so the bit positions matter only to PUSHST / POPST /
// MMTM ST / MMFM ST instructions and to debug observability.
//
// Update priority on a given clock edge:
//   1. Reset → ST = 0.
//   2. `st_write_en` → ST takes `st_write_data` (full 32 bits).
//   3. `flag_update_en` → only the four condition-flag bits change to
//      `flags_in`; all other bits hold.
//   4. Otherwise → ST holds.
//
// If `st_write_en` and `flag_update_en` are both asserted in the same
// cycle, the full write wins (documented).
//
// Synthesis notes:
//   - One always_ff with explicit if/else if precedence — synthesizes as
//     32 D-flip-flops with a 4-input mux per flag bit.
//   - No latches, no `/`, no `%`, no `initial`, no loops.
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_status_reg
  import tms34010_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,

  // Selective flag update from ALU/shifter.
  input  logic                  flag_update_en,
  input  alu_flags_t            flags_in,
  // Per-flag mask: which of N, C, Z, V should actually update when
  // `flag_update_en` is high. All-ones is the standard case (full
  // arithmetic flag update). BTST sets only `z`. ABS sets all but `c`.
  input  alu_flags_t            flag_update_mask,

  // Full ST write (POPST, MMFM-of-ST, debug load, etc.).
  input  logic                  st_write_en,
  input  logic [DATA_WIDTH-1:0] st_write_data,

  // Outputs.
  output logic [DATA_WIDTH-1:0] st_o,
  output logic                  n_o,
  output logic                  c_o,
  output logic                  z_o,
  output logic                  v_o
);

  logic [DATA_WIDTH-1:0] st_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      st_q <= ST_RESET_VALUE;
    end else if (st_write_en) begin
      st_q <= st_write_data;
    end else if (flag_update_en) begin
      if (flag_update_mask.n) st_q[ST_N_BIT] <= flags_in.n;
      if (flag_update_mask.c) st_q[ST_C_BIT] <= flags_in.c;
      if (flag_update_mask.z) st_q[ST_Z_BIT] <= flags_in.z;
      if (flag_update_mask.v) st_q[ST_V_BIT] <= flags_in.v;
    end
  end

  assign st_o = st_q;
  assign n_o  = st_q[ST_N_BIT];
  assign c_o  = st_q[ST_C_BIT];
  assign z_o  = st_q[ST_Z_BIT];
  assign v_o  = st_q[ST_V_BIT];

endmodule : tms34010_status_reg
`default_nettype wire
