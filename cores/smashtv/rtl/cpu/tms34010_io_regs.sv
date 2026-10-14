// -----------------------------------------------------------------------------
// tms34010_io_regs.sv
//
// On-chip memory-mapped I/O register file for the TMS34010.
//
// Per the 1988 User's Guide Figure 6-1 (page 6-3), the GSP has 32 internal
// 16-bit registers occupying the bit-address range 0xC0000000-0xC00001FF.
// Each register sits at a 0x10-bit-aligned address (16 bits apart). The CPU
// (and, on real silicon, the host) reaches them through the ordinary
// bit-addressed memory interface; an address decodes to I/O space when its
// two MSBs are 11 and bits[29:9] are 0. The register index is addr[8:4].
//
// "All I/O registers ... are cleared to 0 at reset" (UG §6, Reset). The one
// documented exception concerns the HLT bit's dependence on the HCS pin of
// the host interface, which this FPGA reimplementation does not yet model;
// resetting every register to 0 is therefore correct here.
//
// Scope (Task 0081 — foundation):
//   - Plain read/write storage for all 32 registers. This is exactly correct
//     for the control/graphics registers that the instruction set reads
//     (PSIZE, PMASK, CONVSP, CONVDP, CONTROL, DPYCTL, ...).
//   - Registers whose real silicon behavior is read-only or has write side
//     effects (HCOUNT/VCOUNT/REFCNT/DPYADR are driven by video timing;
//     INTPEND bits are write-to-clear) are MODELLED AS PLAIN STORAGE for now.
//     Those side effects arrive with the video-timing and interrupt blocks
//     (see docs/memory_map.md). No instruction implemented so far depends on
//     them.
//
// Port shape:
//   - Synchronous active-high reset (assumption A0003), all registers -> 0.
//   - One synchronous write port (req & we & is_io).
//   - One combinational (async) read port. The 32x16 array is tiny (512
//     bits) and async read keeps this composable with the core's existing
//     register-style reads; FPGA maps it to flops + a 32:1 mux.
//   - `is_io` tells the caller whether `addr` decoded as I/O space, so the
//     surrounding memory fabric can route reads/writes here vs. external RAM.
//
// Spec source:
//   third_party/TMS34010_Info/docs/ti-official/1988_TI_TMS34010_Users_Guide.pdf
//   Figure 6-1 (I/O Register Memory Map), §6 "I/O Registers".
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_io_regs
  import tms34010_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,

  input  logic                  req,      // access strobe
  input  logic                  we,       // 1 = write, 0 = read
  input  logic [ADDR_WIDTH-1:0] addr,     // full 32-bit bit-address
  input  logic [15:0]           wdata,

  output logic [15:0]           rdata,    // selected register (0 if not I/O)
  output logic                  is_io,    // addr decodes to I/O space

  // Dedicated taps for the graphics datapath (combinational views of the
  // stored registers). More can be added (PMASK/CONTROL) as the graphics ops
  // that need them land.
  output logic [15:0]           psize_o,  // PSIZE: pixel size in bits (1..16)
  output logic [15:0]           convdp_o, // CONVDP: XY->linear dest pitch shift
  output logic [15:0]           convsp_o, // CONVSP: XY->linear source pitch shift
  output logic [15:0]           control_o,// CONTROL: PPOP[14:10], PBV/PBH, W, T(bit5)
  output logic [15:0]           pmask_o,  // PMASK: plane mask (1 bit = plane masked)
  output logic [15:0]           intenb_o, // INTENB: maskable-interrupt enables
  output logic [15:0]           intpend_o,// INTPEND: maskable-interrupt pending bits
  output logic [15:0]           hstctlh_o,// HSTCTLH: host control (NMI/NMIM in bits 8/9)
  output logic [15:0]           dpyint_o, // DPYINT scanline register (for ext video timing)
  output logic [15:0]           dpystrt_o,// DPYSTRT: display start addr (screen scroll)
  output logic [15:0]           dpyctl_o, // DPYCTL: display control (DUDATE = bits[9:2])
  input  logic                  nmi_clear,// 1-cycle: clear HSTCTLH.NMI (device took NMI)
  input  logic                  wvp_set,  // 1-cycle: set INTPEND.WV (window violation)
  // Interrupt sources. DI is device-INTERNAL (edge-set, software-cleared). INT1/
  // INT2 are the EXTERNAL request lines whose INTPEND bits FOLLOW the line level
  // (MAME execute_set_input), so they are passed as levels, not pulses.
  input  logic                  di_set,   // 1-cycle: set INTPEND.DI (display interrupt)
  input  logic                  int1_line,// INT1 external line level (blitter DMA-done)
  input  logic                  int2_line,// INT2 external line level (unused on Y-unit)
  // Live video-timing counter inputs: override the stored HCOUNT/VCOUNT register
  // reads so code that polls these gets the real pixel-clock position, not 0.
  input  logic [15:0]           hcount_i, // live HCOUNT from smashtv_video
  input  logic [15:0]           vcount_i  // live VCOUNT from smashtv_video
);

  // I/O-space decode: two MSBs = 11 and bits[29:9] = 0 (range C0000000-
  // C00001FF). The register index is addr[8:4].
  logic [IO_REG_IDX_W-1:0] idx;
  assign is_io = (addr[ADDR_WIDTH-1:ADDR_WIDTH-2] == 2'b11)
              && (addr[ADDR_WIDTH-3:IO_REG_IDX_W+4] == '0);
  assign idx   = addr[IO_REG_IDX_W+3 : 4];

  // Register storage.
  logic [15:0] io_reg [0:IO_REG_COUNT-1];

  // Async read: the selected register, or 0 when the address is not in I/O
  // space. HCOUNT and VCOUNT override the stored value with the live video
  // counter so polling code sees the real pixel-clock position.
  assign rdata = is_io ? (
      (idx == IO_IDX_HCOUNT) ? hcount_i :
      (idx == IO_IDX_VCOUNT) ? vcount_i :
      io_reg[idx]) : 16'h0;

  // Dedicated graphics taps.
  assign psize_o   = io_reg[IO_IDX_PSIZE];
  assign convdp_o  = io_reg[IO_IDX_CONVDP];
  assign convsp_o  = io_reg[IO_IDX_CONVSP];
  assign control_o = io_reg[IO_IDX_CONTROL];
  assign pmask_o   = io_reg[IO_IDX_PMASK];
  assign intenb_o  = io_reg[IO_IDX_INTENB];
  assign intpend_o = io_reg[IO_IDX_INTPEND];
  assign hstctlh_o = io_reg[IO_IDX_HSTCTLH];
  assign dpyint_o  = io_reg[IO_IDX_DPYINT];
  assign dpystrt_o = io_reg[IO_IDX_DPYSTRT];
  assign dpyctl_o  = io_reg[IO_IDX_DPYCTL];

  // Next INTPEND value, built to match MAME's TMS34010 exactly:
  //   * INT1/INT2 pending bits FOLLOW their external line level every cycle
  //     (execute_set_input: |=INT on assert, &=~INT on clear).
  //   * A program/host write to INTPEND can ONLY clear DI and WV -- and only by
  //     writing a 0 to that bit. It never sets any bit and never touches INT1/
  //     INT2/HI (REG_INTPEND write handler: "if(!(data&DI)) INTPEND&=~DI;
  //     if(!(data&WV)) INTPEND&=~WV;"). This is why the OLD full-overwrite was
  //     wrong: it let the ISR set/clear arbitrary pending bits.
  //   * Device-internal sources (DI, WV) set their bit (edge). Applied LAST so a
  //     set coincident with the ISR's clear-write is not lost -- the new
  //     interrupt stays pending (matches MAME's callback-then-write ordering).
  logic [15:0] intpend_next;
  always_comb begin
    intpend_next = io_reg[IO_IDX_INTPEND];
    intpend_next[INT_X1_BIT] = int1_line;   // INT1 follows external line level
    intpend_next[INT_X2_BIT] = int2_line;   // INT2 follows external line level
    if (req && we && is_io && idx == IO_IDX_INTPEND) begin
      if (!wdata[INT_DI_BIT]) intpend_next[INT_DI_BIT] = 1'b0;  // clear DI on write-0
      if (!wdata[INT_WV_BIT]) intpend_next[INT_WV_BIT] = 1'b0;  // clear WV on write-0
    end
    if (wvp_set) intpend_next[INT_WV_BIT] = 1'b1;   // window violation (internal)
    if (di_set)  intpend_next[INT_DI_BIT] = 1'b1;   // display interrupt (internal)
  end

  // Synchronous write + reset. The reset loop is bounded (32 iterations) and
  // fully unrollable, so synthesis treats it as parallel resets.
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < IO_REG_COUNT; i++) begin
        io_reg[i] <= 16'h0;
      end
    end else begin
      // Non-INTPEND register writes (INTPEND is handled via intpend_next).
      if (req && we && is_io && idx != IO_IDX_INTPEND) begin
        io_reg[idx] <= wdata;
      end else if (nmi_clear) begin
        // The device auto-clears HSTCTLH.NMI when it takes the NMI (1988 UG §8).
        // A normal I/O write takes precedence.
        io_reg[IO_IDX_HSTCTLH][HSTCTL_NMI_BIT] <= 1'b0;
      end
      io_reg[IO_IDX_INTPEND] <= intpend_next;
    end
  end

endmodule : tms34010_io_regs

`default_nettype wire
