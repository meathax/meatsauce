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
  // A/B files in MLAB (async-read LUT RAM) instead of 960 flip-flops + three 31:1 read mux trees:
  // one 16x32 MLAB RAM per file per read port (each has its own copy of the written data). No reset
  // on the RAM: while rst is high a 4-bit counter sweeps all 16 words with zero, so a reset of
  // >= 16 clk clears the files exactly like the flop version did.
  logic [DATA_WIDTH-1:0] sp_q;
  logic [3:0]            init_cnt;
  wire        a_we = rst | (wr_en && wr_idx != REG_SP_IDX && wr_file != REG_FILE_B);
  wire        b_we = rst | (wr_en && wr_idx != REG_SP_IDX && wr_file == REG_FILE_B);
  wire [3:0]  w_addr = rst ? init_cnt : wr_idx;
  wire [DATA_WIDTH-1:0] w_data = rst ? {DATA_WIDTH{1'b0}} : wr_data;
  wire [DATA_WIDTH-1:0] a_rd1, a_rd2, a_rd3, b_rd1, b_rd2, b_rd3;
  tms34010_mlab32 u_a1 (.clk(clk), .we(a_we), .waddr(w_addr), .wdata(w_data), .raddr(rs1_idx), .q(a_rd1));
  tms34010_mlab32 u_a2 (.clk(clk), .we(a_we), .waddr(w_addr), .wdata(w_data), .raddr(rs2_idx), .q(a_rd2));
  tms34010_mlab32 u_a3 (.clk(clk), .we(a_we), .waddr(w_addr), .wdata(w_data), .raddr(rs3_idx), .q(a_rd3));
  tms34010_mlab32 u_b1 (.clk(clk), .we(b_we), .waddr(w_addr), .wdata(w_data), .raddr(rs1_idx), .q(b_rd1));
  tms34010_mlab32 u_b2 (.clk(clk), .we(b_we), .waddr(w_addr), .wdata(w_data), .raddr(rs2_idx), .q(b_rd2));
  tms34010_mlab32 u_b3 (.clk(clk), .we(b_we), .waddr(w_addr), .wdata(w_data), .raddr(rs3_idx), .q(b_rd3));
  assign rs1_data = (rs1_idx == REG_SP_IDX) ? sp_q : (rs1_file == REG_FILE_B) ? b_rd1 : a_rd1;
  assign rs2_data = (rs2_idx == REG_SP_IDX) ? sp_q : (rs2_file == REG_FILE_B) ? b_rd2 : a_rd2;
  assign rs3_data = (rs3_idx == REG_SP_IDX) ? sp_q : (rs3_file == REG_FILE_B) ? b_rd3 : a_rd3;

  always_ff @(posedge clk) begin
    if (rst) begin
      init_cnt <= init_cnt + 4'd1;
      sp_q <= '0;
    end else begin
      init_cnt <= 4'd0;
      if (wr_en && wr_idx == REG_SP_IDX) sp_q <= wr_data;
    end
  end

  assign sp_o = sp_q;

endmodule : tms34010_regfile

// 16 x 32 LUT-RAM with asynchronous read, one write port (Cyclone V MLAB).
module tms34010_mlab32 (
  input  wire        clk,
  input  wire        we,
  input  wire [3:0]  waddr,
  input  wire [31:0] wdata,
  input  wire [3:0]  raddr,
  output wire [31:0] q
);
`ifdef VERILATOR
  reg [31:0] mem [0:15];
  always @(posedge clk) if (we) mem[waddr] <= wdata;
  assign q = mem[raddr];
`else
  altdpram #(
    .width(32), .widthad(4), .numwords(16),
    .indata_reg("INCLOCK"), .wraddress_reg("INCLOCK"), .wrcontrol_reg("INCLOCK"),
    .rdaddress_reg("UNREGISTERED"), .rdcontrol_reg("UNREGISTERED"), .outdata_reg("UNREGISTERED"),
    .ram_block_type("MLAB"), .intended_device_family("Cyclone V"),
    .read_during_write_mode_mixed_ports("DONT_CARE"),
    .lpm_type("altdpram")
  ) u_ram (
    .inclock(clk), .data(wdata), .wraddress(waddr), .wren(we), .rdaddress(raddr), .q(q),
    .aclr(1'b0), .byteena(1'b1), .inclocken(1'b1), .outclock(1'b1), .outclocken(1'b1), .rdaddressstall(1'b0),
    .rden(1'b1), .sclr(1'b0), .wraddressstall(1'b0)
  );
`endif
endmodule
`default_nettype wire
