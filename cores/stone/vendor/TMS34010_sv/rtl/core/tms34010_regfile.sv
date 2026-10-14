// -----------------------------------------------------------------------------
// tms34010_regfile.sv
//
// General-purpose register file for the TMS34010 core.
//
// Architectural contract (per bibliography/hdl-reimplementation/03-registers.md):
//   - File A: A0..A14 (15 entries, 32 bits each).
//   - File B: B0..B14 (15 entries, 32 bits each).
//   - SP    : 1 entry, 32 bits, accessible from BOTH files at index 4'hF
//             (i.e., A15 and B15 are aliases for the same SP).
//
// Port shape:
//   - Two combinational read ports. Async read is FPGA-friendly for this
//     size (~1 Kb total) — fits in distributed/LUT RAM on Cyclone V or
//     plain flip-flops without inflating the LUT count.
//   - One synchronous write port. Write-after-read on the SAME port within
//     a cycle: a read on `rs1`/`rs2` issued in the same cycle as a write
//     to the matching index returns the OLD value (the new value lands at
//     the next clock edge). This matches the multi-cycle execute model.
//
// Reset:
//   Synchronous active-high `rst`. All entries clear to '0. The loop in
//   the reset arm is bounded and fully unrollable (15 iterations × 2 files
//   + 1 SP = 31 sequential element updates), so synthesis treats it as
//   plain parallel resets.
//
// Notes:
//   - SP aliasing is implemented in one place (the read/write decode
//     functions). Code that touches the regfile never has to know about
//     the alias.
//   - No `/`, no `%`, no `initial` (rst handles all init), no unbounded
//     loops, no latches (all combinational outputs assigned on every
//     path through `always_comb`).
//
// Spec source:
//   third_party/TMS34010_Info/bibliography/hdl-reimplementation/03-registers.md
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_regfile
  import tms34010_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,

  // Read port 1.
  input  reg_file_t             rs1_file,
  input  reg_idx_t              rs1_idx,
  output logic [DATA_WIDTH-1:0] rs1_data,

  // Read port 2.
  input  reg_file_t             rs2_file,
  input  reg_idx_t              rs2_idx,
  output logic [DATA_WIDTH-1:0] rs2_data,

  // Read port 3. Added for instructions that need a third simultaneous
  // source — currently CPW (reads the point plus WSTART and WEND). Async
  // read like the others; a third read mux on this flop-based file is
  // cheap (no extra memory blocks).
  input  reg_file_t             rs3_file,
  input  reg_idx_t              rs3_idx,
  output logic [DATA_WIDTH-1:0] rs3_data,

  // Write port.
  input  logic                  wr_en,
  input  reg_file_t             wr_file,
  input  reg_idx_t              wr_idx,
  input  logic [DATA_WIDTH-1:0] wr_data,

  // Observability: SP value, used by testbenches and (eventually) host
  // interface debug paths.
  output logic [DATA_WIDTH-1:0] sp_o
);

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------
  // One 32-entry array per read port, all written identically. Address is
  // {file_is_b, idx[3:0]}; index 15 (SP) is never stored here. Each copy has
  // an unregistered read, which Cyclone V maps to MLAB LUT RAM: one cell of
  // read delay instead of a 31:1 flop mux fanning out from the index register.
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] mem1 [0:31] /*verilator public_flat_rd*/;
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] mem2 [0:31];
  (* ramstyle = "MLAB, no_rw_check" *) logic [DATA_WIDTH-1:0] mem3 [0:31];
  logic [DATA_WIDTH-1:0] sp_q;
  // synthesis translate_off
  initial begin
    for (int unsigned i = 0; i < 32; i++) begin
      mem1[i] = '0; mem2[i] = '0; mem3[i] = '0;
    end
  end
  // synthesis translate_on

  // ---------------------------------------------------------------------------
  // Read multiplex (combinational / async read)
  //
  // Index 4'hF on either file returns SP. Other indices return the matching
  // file entry. Implemented inline rather than via a function to keep the
  // synthesizable form trivial for Quartus.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Registered write port. A write is held for one cycle before it commits to
  // the array, so the core's write-data/enable cone ends at one 32-bit
  // register instead of fanning out to every register-file flop. Every read
  // port and sp_o bypass the pending write, so reads observe exactly the value
  // they would have seen with an immediate write.
  // ---------------------------------------------------------------------------
  logic                  wr_pend_q;
  reg_file_t             wr_file_q;
  reg_idx_t              wr_idx_q;
  logic [DATA_WIDTH-1:0] wr_data_q;

  function automatic logic pend_hit(input reg_file_t file, input reg_idx_t idx);
    pend_hit = wr_pend_q && (idx == wr_idx_q)
            && ((idx == REG_SP_IDX) || (file == wr_file_q));
  endfunction

  always_comb begin
    if (pend_hit(rs1_file, rs1_idx)) begin
      rs1_data = wr_data_q;
    end else if (rs1_idx == REG_SP_IDX) begin
      rs1_data = sp_q;
    end else begin
      rs1_data = mem1[{rs1_file == REG_FILE_B, rs1_idx[3:0]}];
    end
  end

  always_comb begin
    if (pend_hit(rs2_file, rs2_idx)) begin
      rs2_data = wr_data_q;
    end else if (rs2_idx == REG_SP_IDX) begin
      rs2_data = sp_q;
    end else begin
      rs2_data = mem2[{rs2_file == REG_FILE_B, rs2_idx[3:0]}];
    end
  end

  always_comb begin
    if (pend_hit(rs3_file, rs3_idx)) begin
      rs3_data = wr_data_q;
    end else if (rs3_idx == REG_SP_IDX) begin
      rs3_data = sp_q;
    end else begin
      rs3_data = mem3[{rs3_file == REG_FILE_B, rs3_idx[3:0]}];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_pend_q <= 1'b0;
      wr_file_q <= REG_FILE_A;
      wr_idx_q  <= '0;
      wr_data_q <= '0;
    end else begin
      wr_pend_q <= wr_en;
      if (wr_en) begin
        wr_file_q <= wr_file;
        wr_idx_q  <= wr_idx;
        wr_data_q <= wr_data;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      // Only SP resets; the MLAB arrays power up to zero and carry no reset.
      sp_q <= '0;
    end else if (wr_pend_q && (wr_idx_q == REG_SP_IDX)) begin
      sp_q <= wr_data_q;
    end
  end

  // Per-file views of the array for testbenches. Hidden from synthesis: the
  // 30 constant-address reads would otherwise become extra RAM read ports.
  // synthesis translate_off
  logic [DATA_WIDTH-1:0] a_regs [0:14];
  logic [DATA_WIDTH-1:0] b_regs [0:14];
  genvar gi;
  generate
    for (gi = 0; gi < 15; gi++) begin : g_views
      assign a_regs[gi] = mem1[gi];
      assign b_regs[gi] = mem1[16 + gi];
    end
  endgenerate
  // synthesis translate_on

  // RAM write port: no reset, so the arrays infer as LUT RAM.
  always_ff @(posedge clk) begin
    if (wr_pend_q && (wr_idx_q != REG_SP_IDX)) begin
      mem1[{wr_file_q == REG_FILE_B, wr_idx_q[3:0]}] <= wr_data_q;
      mem2[{wr_file_q == REG_FILE_B, wr_idx_q[3:0]}] <= wr_data_q;
      mem3[{wr_file_q == REG_FILE_B, wr_idx_q[3:0]}] <= wr_data_q;
    end
  end

  assign sp_o = (wr_pend_q && (wr_idx_q == REG_SP_IDX)) ? wr_data_q : sp_q;

endmodule : tms34010_regfile
`default_nettype wire
