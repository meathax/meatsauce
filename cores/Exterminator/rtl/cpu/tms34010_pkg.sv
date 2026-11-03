// -----------------------------------------------------------------------------
// tms34010_pkg.sv
//
// Architectural constants, widths, and shared typedefs for the TMS34010 core.
//
// This file is the single source of truth for project-wide widths and enum
// types. Other RTL files must not introduce parallel "magic number" widths.
// As more of the spec is implemented, this package grows with concrete
// register-bit layouts and instruction-class typedefs.
//
// Spec source: third_party/TMS34010_Info/docs/ti-official/
//              1988_TI_TMS34010_Users_Guide.pdf
//
// Phase 0: skeleton — only the typedefs/widths needed by the core FSM
// scaffold are defined here. Concrete architectural details (status register
// layout, register file indices, instruction word fields) land in Phase 1+.
// -----------------------------------------------------------------------------

`default_nettype none
package tms34010_pkg;

  // ---------------------------------------------------------------------------
  // Architectural widths
  // ---------------------------------------------------------------------------

  // TMS34010 is a 32-bit architecture with a bit-addressed memory model.
  // The external bus on the original device is 16 bits, but the RTL exposes
  // an internal-style request/valid interface at full architectural width;
  // an external glue module (Phase 6) handles the bus multiplexing.
  parameter int unsigned ADDR_WIDTH       = 32;
  parameter int unsigned DATA_WIDTH       = 32;

  // Field-size operands are 1..32 bits, encoded in 6 bits.
  // Spec: 1988 User's Guide, field-move/field-addressing chapter.
  parameter int unsigned FIELD_SIZE_WIDTH = 6;

  // ---------------------------------------------------------------------------
  // Instruction-stream constants
  //
  // Spec: bibliography/hdl-reimplementation/01-architecture.md
  // ("Instructions are 16-bit-aligned half-words in memory. PC is a
  //   bit-address but increments by 16 per fetch.")
  // ---------------------------------------------------------------------------
  parameter logic [FIELD_SIZE_WIDTH-1:0] INSTR_WORD_BITS = 6'd16;

  // Width of the PC's per-advance amount (in bits). 8 bits covers 1- to
  // 15-word instructions with headroom; the longest documented form is
  // 3 words (48 bits) for instructions with a 32-bit immediate.
  parameter int unsigned PC_ADVANCE_WIDTH = 8;

  // Reset PC value. Placeholder — the architectural reset sequence fetches
  // PC from the trap table near the top of address space (see
  // docs/assumptions.md entry A0008). Until Phase 8 implements the
  // reset-fetch sequence, the core boots at this constant.
  parameter logic [ADDR_WIDTH-1:0] RESET_PC = '0;

  // ---------------------------------------------------------------------------
  // Core top-level FSM states
  //
  // Added in Phase 3:
  //   CORE_FETCH_IMM_LO/HI — fetch the 16- or 32-bit immediate that follows
  //   long-immediate-form instructions (MOVI IW/IL, ADDI IW/IL, CMPI, etc.).
  // ---------------------------------------------------------------------------
  typedef enum logic [5:0] {
    CORE_RESET        = 6'd0,
    CORE_FETCH        = 6'd1,
    CORE_DECODE       = 6'd2,
    CORE_FETCH_IMM_LO = 6'd3,
    CORE_FETCH_IMM_HI = 6'd4,
    CORE_EXECUTE      = 6'd5,
    CORE_MEMORY       = 6'd6,
    CORE_WRITEBACK    = 6'd7,
    CORE_DIVIDE       = 6'd8,  // multi-cycle wait for the divider (DIVU/MODU/...)
    CORE_FILL_SETUP   = 6'd9,  // FILL: latch COLOR1 + init counters (operands B2/B3/B7
                               //       latched at EXECUTE); the pixel loop follows
    CORE_FILL         = 6'd10, // FILL: per-pixel read-modify-write until the array is done
    CORE_FILL_WB      = 6'd11, // FILL: write the final DADDR back to B2
    CORE_PBLT_SETUP   = 6'd12, // PIXBLT: latch SPTCH/DPTCH (SADDR/DADDR/DYDX at EXECUTE)
    CORE_PBLT         = 6'd13, // PIXBLT: per-pixel read-src / read-dst / write loop
    CORE_PBLT_WB      = 6'd14, // PIXBLT: write the final SADDR back to B0
    CORE_PBLT_WB2     = 6'd15, // PIXBLT: write the final DADDR back to B2
    CORE_PBLT_SETUP2  = 6'd16, // PIXBLT B (color expand): latch COLOR0/COLOR1
    CORE_INT_PUSH_ST  = 6'd17, // interrupt entry: push ST onto the stack
    CORE_INT_PUSH_PC  = 6'd18, // interrupt entry: push PC onto the stack
    CORE_INT_VECTOR   = 6'd19, // interrupt entry: read the vector -> PC
    CORE_INT_DONE     = 6'd20, // interrupt entry: write back SP, ST <- reset
    CORE_FILL_SETUP_WIN = 6'd21, // FILL XY (W=2/3): read WSTART/WEND for window
    CORE_PBLT_SETUP_WIN = 6'd22, // PIXBLT XY (W=3): read WSTART/WEND for clipping
    CORE_FILL_WIN_MISS  = 6'd23, // FILL XY (W=2): array outside window — no draw, V=1, WVP
    CORE_PBLT_WIN_MISS  = 6'd24, // PIXBLT XY (W=2): array outside window — no draw, V=1, WVP
    CORE_FILL_WIN_HIT   = 6'd25, // FILL XY (W=1): hit detection — no draw, V/WVP on overlap
    CORE_PBLT_WIN_HIT   = 6'd26, // PIXBLT XY (W=1): hit detection — no draw, V/WVP on overlap
    CORE_DRAV           = 6'd27, // DRAV: 2-step RMW pixel draw at Rd's XY (advance at WRITEBACK)
    CORE_DRAV_SETUP_WIN = 6'd28, // DRAV (W!=0): read WSTART/WEND, test Rd's XY against window
    CORE_LINE_SETUP1    = 6'd29, // LINE: read d(B0)/DYDX(B7)/COUNT(B10)
    CORE_LINE_SETUP2    = 6'd30, // LINE: read INC1(B11)/INC2(B12)/OFFSET(B4)
    CORE_LINE_SETUP3    = 6'd31, // LINE: read DADDR(B2)/COLOR1(B9)
    CORE_LINE_DRAW      = 6'd32, // LINE: per-pixel RMW draw + Bresenham step (d/DADDR/COUNT)
    CORE_LINE_WB_D      = 6'd33, // LINE: write back d -> B0
    CORE_LINE_WB_DADDR  = 6'd34, // LINE: write back DADDR -> B2
    CORE_LINE_WB_COUNT  = 6'd35, // LINE: write back COUNT (=0) -> B10
    CORE_LINE_SETUP_WIN = 6'd36, // LINE (W=3): read WSTART/WEND for per-pixel clip
    CORE_PIXT_SETUP_WIN = 6'd37, // PIXT XY (W!=0): read WSTART/WEND before the RMW
    // --- smashtv local addition: architectural reset-vector fetch (A0008) ---
    CORE_RVEC           = 6'd38, // reset: read the 32-bit reset vector @ 0xFFFFFFE0
    CORE_RVEC_DONE      = 6'd39, // reset: load PC with the fetched vector, then fetch
    CORE_FETCH_ABS2_LO = 6'd40, // absolute-to-absolute MOVE: destination address low word
    CORE_FETCH_ABS2_HI = 6'd41  // absolute-to-absolute MOVE: destination address high word
  } core_state_t;

  // ---------------------------------------------------------------------------
  // Register file types
  //
  // Spec: bibliography/hdl-reimplementation/03-registers.md
  //   - Two 15-entry general-purpose register banks (A and B).
  //   - One shared stack pointer accessible from both banks as A15/B15.
  //   - All 32 bits.
  // ---------------------------------------------------------------------------
  typedef enum logic {
    REG_FILE_A = 1'b0,
    REG_FILE_B = 1'b1
  } reg_file_t;

  // 4-bit register index inside a file. Index 4'hF is the shared SP alias.
  typedef logic [3:0] reg_idx_t;

  parameter reg_idx_t REG_SP_IDX = 4'hF;

  // CPW's implied window operands are fixed B-file registers (SPVU001A
  // page 12-57): WSTART = B5 (inclusive lesser corner), WEND = B6.
  parameter reg_idx_t CPW_WSTART_IDX = 4'd5;
  parameter reg_idx_t CPW_WEND_IDX   = 4'd6;

  // Graphics B-file registers with fixed implied roles (SPVU001A §"Implied
  // Operands"). B2 = DADDR (destination address), B3 = DPTCH (destination
  // pitch), B4 = OFFSET (linear address of XY origin 0,0), B7 = DYDX (array
  // dimensions rows:cols), B9 = COLOR1 (fill / source color).
  parameter reg_idx_t B_SADDR_IDX  = 4'd0;
  parameter reg_idx_t B_SPTCH_IDX  = 4'd1;
  parameter reg_idx_t B_DADDR_IDX  = 4'd2;
  parameter reg_idx_t B_DPTCH_IDX  = 4'd3;
  parameter reg_idx_t B_OFFSET_IDX = 4'd4;
  parameter reg_idx_t B_DYDX_IDX   = 4'd7;
  parameter reg_idx_t B_COLOR0_IDX = 4'd8;
  parameter reg_idx_t B_COLOR1_IDX = 4'd9;
  // LINE (and other incremental-draw) implied B registers.
  parameter reg_idx_t B_COUNT_IDX  = 4'd10; // COUNT (loop count) / SADDR-d alias
  parameter reg_idx_t B_INC1_IDX   = 4'd11; // INC1 (minor/diagonal XY increment)
  parameter reg_idx_t B_INC2_IDX   = 4'd12; // INC2 (major/dominant XY increment)

  // ---------------------------------------------------------------------------
  // ALU operation enum
  //
  // Spec sources:
  //   - bibliography/hdl-reimplementation/02-instruction-set.md
  //     §"Arithmetic / Logical": "N, C, Z, V plus the field-size mode bits
  //     ... all live in the ST register".
  //   - bibliography/hdl-reimplementation/03-registers.md §"Status register".
  //
  // Concrete per-instruction flag semantics (TI's exact carry-vs-borrow
  // convention, V on NEG / ABS minimum-negative, etc.) are captured in
  // docs/assumptions.md as A0009 until SPVU001A Appendix A is read in
  // detail. The ALU implements the "obvious" two's-complement /
  // carry-out-of-MSB convention and matches the standard:
  //   C = unsigned overflow (carry from MSB on ADD; "borrow" output on SUB,
  //       which here equals NOT carry-out-of-(a + ~b + 1)).
  //   V = signed overflow.
  //   N = result[31].
  //   Z = result == 0.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_OP_ADD    = 4'd0,
    ALU_OP_ADDC   = 4'd1,
    ALU_OP_SUB    = 4'd2,
    ALU_OP_SUBB   = 4'd3,
    ALU_OP_CMP    = 4'd4,
    ALU_OP_AND    = 4'd5,
    ALU_OP_ANDN   = 4'd6,
    ALU_OP_OR     = 4'd7,
    ALU_OP_XOR    = 4'd8,
    ALU_OP_NOT    = 4'd9,
    ALU_OP_NEG    = 4'd10,
    ALU_OP_PASS_A = 4'd11,
    ALU_OP_PASS_B = 4'd12,
    ALU_OP_ABS    = 4'd13   // |a|; result mux'd between a and (0-a) based on
                            // sign bit. V on MIN_INT. See A0024.
  } alu_op_t;

  typedef struct packed {
    logic n;
    logic c;
    logic z;
    logic v;
  } alu_flags_t;

  // ---------------------------------------------------------------------------
  // Shifter operation enum
  //
  // Spec source: bibliography/hdl-reimplementation/01-architecture.md
  //   §"Top-level blocks" — "32-bit barrel shifter; the shifter is critical
  //   for field operations and pixel shifts"; 02-instruction-set.md lists
  //   SLA, SLL, SRA, SRL, RL as the shift/rotate primitives.
  //
  // SLA vs SLL is per-spec: same shifted output, may differ on V flag (V on
  // sign-change during left shift). Tracked in docs/assumptions.md A0009;
  // both treated identically here until SPVU001A Appendix A is read.
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    SHIFT_OP_SLL = 3'd0,  // shift left, logical (fill 0)
    SHIFT_OP_SLA = 3'd1,  // shift left, arithmetic (alias of SLL; V flag TBD)
    SHIFT_OP_SRL = 3'd2,  // shift right, logical (fill 0)
    SHIFT_OP_SRA = 3'd3,  // shift right, arithmetic (sign-extend)
    SHIFT_OP_RL  = 3'd4,  // rotate left
    SHIFT_OP_RR  = 3'd5   // rotate right
  } shift_op_t;

  parameter int unsigned SHIFT_AMOUNT_WIDTH = 5;  // 32-bit shifter, 0..31

  // ---------------------------------------------------------------------------
  // Status register layout — VERIFIED against SPVU001A §5.2 (Table 5-2,
  // page 5-18). The original A0010 placeholder for N/C/Z/V at bits
  // 31..28 happened to be correct; the field-size bits and IE/PBX are
  // now pinned to their authoritative positions.
  //
  //   Bits[4:0]   FS0     Field Size 0  (5-bit; 00000 → field-size 32)
  //   Bit[5]      FE0     Field Extend 0 (0 = zero-ext, 1 = sign-ext)
  //   Bits[10:6]  FS1     Field Size 1
  //   Bit[11]     FE1     Field Extend 1
  //   Bits[20:12] reserved (preserved as written; reset = 0)
  //   Bit[21]     IE      Interrupt Enable (DINT clears, EINT sets)
  //   Bits[24:22] reserved
  //   Bit[25]     PBX     PixBlt Executing
  //   Bits[27:26] reserved
  //   Bit[28]     V       Overflow
  //   Bit[29]     Z       Zero
  //   Bit[30]     C       Carry
  //   Bit[31]     N       Negative
  //
  // ST resets to 0x0000_0010 per spec page 5-18 → FS0 = 16 at reset.
  // ---------------------------------------------------------------------------
  parameter int unsigned ST_FS0_LO  = 0;
  parameter int unsigned ST_FS0_HI  = 4;
  parameter int unsigned ST_FE0_BIT = 5;
  parameter int unsigned ST_FS1_LO  = 6;
  parameter int unsigned ST_FS1_HI  = 10;
  parameter int unsigned ST_FE1_BIT = 11;
  parameter int unsigned ST_IE_BIT  = 21;
  parameter int unsigned ST_PBX_BIT = 25;
  parameter int unsigned ST_V_BIT   = 28;
  parameter int unsigned ST_Z_BIT   = 29;
  parameter int unsigned ST_C_BIT   = 30;
  parameter int unsigned ST_N_BIT   = 31;
  parameter logic [DATA_WIDTH-1:0] ST_RESET_VALUE = 32'h0000_0010;

  // ---------------------------------------------------------------------------
  // Misc architectural constants (kept here so RTL has no magic numbers).
  // ---------------------------------------------------------------------------
  // REV Rd result — chip-revision constant. The spec calls the value
  // "undefined", but the worked example shows REV → 0x00000008 (A0025).
  parameter logic [DATA_WIDTH-1:0] REV_VALUE = 32'h0000_0008;
  // Trap-vector table top. Vector for TRAP N is TRAP_VECTOR_BASE - N*32.
  // Per SPVU001A page 12-252; TRAP 0's vector lives at the base itself.
  parameter logic [DATA_WIDTH-1:0] TRAP_VECTOR_BASE = 32'hFFFF_FFE0;

  // One architectural word is DATA_WIDTH bits. Stack push/pop and the
  // field-move pointers (at field-size 32) step the bit-address SP /
  // pointer by one word per 32-bit transfer; the multi-push sequences
  // (TRAP, RETI) step by two words.
  parameter logic [ADDR_WIDTH-1:0] WORD_BIT_SIZE   = DATA_WIDTH;     // 32
  parameter logic [ADDR_WIDTH-1:0] WORD_BIT_SIZE_2 = 2 * DATA_WIDTH; // 64
  // Memory-transfer size (in bits) of a full 32-bit word access, as it
  // appears on the mem_size port (FIELD_SIZE_WIDTH bits wide).
  parameter logic [FIELD_SIZE_WIDTH-1:0] MEM_SIZE_32 = FIELD_SIZE_WIDTH'(DATA_WIDTH); // 6'd32

  // ---------------------------------------------------------------------------
  // On-chip I/O register file (1988 User's Guide Figure 6-1, page 6-3).
  //
  // 32 memory-mapped 16-bit registers occupy the bit-address range
  // 0xC0000000-0xC00001FF. Each register sits at a 0x10-bit-aligned address
  // (16 bits apart). An address is in I/O space when its two MSBs are 11 and
  // bits[29:9] are 0; the register index is addr[8:4]. All registers reset to
  // 0 (UG page 6-?: "All I/O registers ... are cleared to 0 at reset").
  // ---------------------------------------------------------------------------
  parameter logic [ADDR_WIDTH-1:0] IO_BASE_ADDR  = 32'hC000_0000;
  parameter int unsigned           IO_REG_COUNT  = 32;
  parameter int unsigned           IO_REG_IDX_W  = 5;     // addr[8:4]
  // Register indices (= address[8:4] = (addr - IO_BASE) >> 4).
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HESYNC  = 5'h00; // Horizontal End Sync
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HEBLNK  = 5'h01; // Horizontal End Blank
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HSBLNK  = 5'h02; // Horizontal Start Blank
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HTOTAL  = 5'h03; // Horizontal Total
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_VESYNC  = 5'h04; // Vertical End Sync
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_VEBLNK  = 5'h05; // Vertical End Blank
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_VSBLNK  = 5'h06; // Vertical Start Blank
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_VTOTAL  = 5'h07; // Vertical Total
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_DPYCTL  = 5'h08; // Display Control
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_DPYSTRT = 5'h09; // Display Start
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_DPYINT  = 5'h0A; // Display Interrupt
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_CONTROL = 5'h0B; // Control
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HSTDATA = 5'h0C; // Host Data
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HSTADRL = 5'h0D; // Host Address (LSBs)
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HSTADRH = 5'h0E; // Host Address (MSBs)
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HSTCTLL = 5'h0F; // Host Control (LSBs)
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HSTCTLH = 5'h10; // Host Control (MSBs)
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_INTENB  = 5'h11; // Interrupt Enable
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_INTPEND = 5'h12; // Interrupt Pending
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_CONVSP  = 5'h13; // Source Conversion Pitch
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_CONVDP  = 5'h14; // Destination Conversion Pitch
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_PSIZE   = 5'h15; // Pixel Size
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_PMASK   = 5'h16; // Plane Mask
  // 0x17-0x1A reserved
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_DPYTAP  = 5'h1B; // Display Tap Point
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_HCOUNT  = 5'h1C; // Horizontal Count
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_VCOUNT  = 5'h1D; // Vertical Count
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_DPYADR  = 5'h1E; // Display Address
  parameter logic [IO_REG_IDX_W-1:0] IO_IDX_REFCNT  = 5'h1F; // DRAM Refresh Count

  // Interrupt enable/pending (INTENB/INTPEND) bit positions and the trap vector
  // address of each maskable interrupt (1988 UG §8.3/8.4, Tables 8-2/8-3).
  // Priority (high→low): HI > DI > WV > INT1 > INT2 (internal before external).
  parameter int unsigned INT_X1_BIT = 1;   // external interrupt 1
  parameter int unsigned INT_X2_BIT = 2;   // external interrupt 2
  parameter int unsigned INT_HI_BIT = 9;   // host interrupt
  parameter int unsigned INT_DI_BIT = 10;  // display interrupt
  parameter int unsigned INT_WV_BIT = 11;  // window violation
  parameter logic [ADDR_WIDTH-1:0] INT_VEC_X1 = 32'hFFFF_FFC0; // trap 1
  parameter logic [ADDR_WIDTH-1:0] INT_VEC_X2 = 32'hFFFF_FFA0; // trap 2
  parameter logic [ADDR_WIDTH-1:0] INT_VEC_HI = 32'hFFFF_FEC0; // trap 9
  parameter logic [ADDR_WIDTH-1:0] INT_VEC_DI = 32'hFFFF_FEA0; // trap 10
  parameter logic [ADDR_WIDTH-1:0] INT_VEC_WV = 32'hFFFF_FE80; // trap 11

  // Nonmaskable interrupt (NMI): host sets HSTCTLH.NMI; the device vectors
  // through trap 8 and (if NMIM=0) pushes PC+ST. 1988 UG §8 (Table 8-2,
  // page 8-? "NMI ... 8 ... FFFFFEE0h") and HSTCTLH (page 5507/4322).
  parameter logic [ADDR_WIDTH-1:0] INT_VEC_NMI   = 32'hFFFF_FEE0; // trap 8
  parameter int unsigned           HSTCTL_NMI_BIT  = 8;  // HSTCTLH: NMI request
  parameter int unsigned           HSTCTL_NMIM_BIT = 9;  // HSTCTLH: NMI mode (1=no push)
  parameter int unsigned           HSTCTL_HLT_BIT  = 15; // HSTCTLH: HALT (1 = stop the CPU)

  // CONTROL register bit fields (1988 UG page 4-? CONTROL register).
  parameter int unsigned CTRL_T_BIT    = 5;   // pixel transparency enable
  parameter int unsigned CTRL_W_LO     = 6;   // window violation detection mode
  parameter int unsigned CTRL_W_HI     = 7;
  parameter int unsigned CTRL_PBH_BIT  = 8;   // PixBlt horizontal direction
  parameter int unsigned CTRL_PBV_BIT  = 9;   // PixBlt vertical direction
  parameter int unsigned CTRL_PPOP_LO  = 10;  // pixel-processing operation select
  parameter int unsigned CTRL_PPOP_HI  = 14;

  // ---------------------------------------------------------------------------
  // Instruction word + decoded-instruction skeleton
  //
  // Spec: bibliography/hdl-reimplementation/02-instruction-set.md
  //   §"Encoding shape": "16-bit-aligned half-words ... The decode space is
  //   dense — there is no easy 'top-bits-give-class' partition. Use the
  //   SPVU004 opcode chart ... rather than hand-rolling the decoder."
  //
  // Phase 3 skeleton: the only field populated by decode is `illegal`. The
  // rest of `decoded_instr_t` is intentionally absent until specific
  // instructions are added in Task 0011 onwards (one per task, each citing
  // the SPVU004 opcode-chart row that defines its encoding).
  // ---------------------------------------------------------------------------
  parameter int unsigned INSTR_WORD_WIDTH = 16;
  typedef logic [INSTR_WORD_WIDTH-1:0] instr_word_t;

  // Instruction class — used by the core control FSM to pick the
  // decode/execute/memory/writeback path. Widened to 6 bits in Task
  // 0029 when ADDC/SUBB pushed the count past 32.
  typedef enum logic [6:0] {
    INSTR_ILLEGAL    = 7'd0,
    INSTR_MOVI_IW    = 7'd1,  // MOVI IW K, Rd    — 16-bit sign-extended immediate
    INSTR_MOVI_IL    = 7'd2,  // MOVI IL K, Rd    — 32-bit immediate
    INSTR_MOVK       = 7'd3,  // MOVK K, Rd       — 5-bit zero-extended constant
    INSTR_ADD_RR     = 7'd4,  // ADD Rs, Rd       — Rs + Rd → Rd; both same file
    INSTR_SUB_RR     = 7'd5,  // SUB Rs, Rd       — Rd - Rs → Rd; both same file
    INSTR_AND_RR     = 7'd6,  // AND Rs, Rd       — Rd & Rs  → Rd
    INSTR_ANDN_RR    = 7'd7,  // ANDN Rs, Rd      — Rd & ~Rs → Rd
    INSTR_OR_RR      = 7'd8,  // OR Rs, Rd        — Rd | Rs  → Rd
    INSTR_XOR_RR     = 7'd9,  // XOR Rs, Rd       — Rd ^ Rs  → Rd
    INSTR_CMP_RR     = 7'd10, // CMP Rs, Rd       — flags from (Rd - Rs); Rd unchanged
    INSTR_JRCC_SHORT = 7'd11, // JRcc short       — conditional relative jump
                              //                    (cc=0 = UC = unconditional)
    INSTR_ADDK       = 7'd12, // ADDK K, Rd       — K + Rd → Rd  (K = 5-bit, zext)
    INSTR_SUBK       = 7'd13, // SUBK K, Rd       — Rd - K → Rd  (K = 5-bit, zext)
    INSTR_NEG        = 7'd14, // NEG Rd           — 0 - Rd → Rd
    INSTR_NOT        = 7'd15, // NOT Rd           — ~Rd → Rd     (C, V cleared)
    INSTR_ADDI_IW    = 7'd16, // ADDI IW K, Rd    — Rd + sext(K16) → Rd
    INSTR_SUBI_IW    = 7'd17, // SUBI IW K, Rd    — Rd - sext(K16) → Rd
    INSTR_CMPI_IW    = 7'd18, // CMPI IW K, Rd    — flags from Rd - sext(K16); Rd unchanged
    INSTR_SLA_K      = 7'd19, // SLA K, Rd        — Rd << K (arithmetic, may set V)
    INSTR_SLL_K      = 7'd20, // SLL K, Rd        — Rd << K (logical)
    INSTR_SRA_K      = 7'd21, // SRA K, Rd        — Rd >>> K (arithmetic / sign-extend)
    INSTR_SRL_K      = 7'd22, // SRL K, Rd        — Rd >> K  (logical, MSB ← 0)
    INSTR_RL_K       = 7'd23, // RL K, Rd         — Rd ROL K (rotate left)
    INSTR_ADDI_IL    = 7'd24, // ADDI IL K, Rd    — Rd + K32 → Rd
    INSTR_SUBI_IL    = 7'd25, // SUBI IL K, Rd    — Rd - K32 → Rd
    INSTR_CMPI_IL    = 7'd26, // CMPI IL K, Rd    — flags from Rd - K32; Rd unchanged
    INSTR_ANDI_IL    = 7'd27, // ANDI IL K, Rd    — Rd & K32 → Rd
    INSTR_ORI_IL     = 7'd28, // ORI  IL K, Rd    — Rd | K32 → Rd
    INSTR_XORI_IL    = 7'd29, // XORI IL K, Rd    — Rd ^ K32 → Rd
    INSTR_MOVE_RR    = 7'd30, // MOVE Rs, Rd      — Rs → Rd (same-file reg-reg)
    INSTR_NOP        = 7'd31, // NOP              — no operation, PC advances only
    INSTR_ADDC_RR    = 7'd32, // ADDC Rs, Rd      — Rs + Rd + C → Rd (carry-in)
    INSTR_SUBB_RR    = 7'd33, // SUBB Rs, Rd      — Rd - Rs - C → Rd (borrow-in)
    INSTR_JRCC_LONG  = 7'd34, // JRcc Address     — long form: 16-bit signed disp
                              //                    in the following word; target =
                              //                    PC_after_both_fetches + disp*16
    INSTR_JUMP_RS    = 7'd35, // JUMP Rs          — Rs → PC (bottom 4 bits cleared)
    INSTR_DSJ        = 7'd36, // DSJ Rd, Address  — Rd-1→Rd; if Rd!=0 branch (long form)
    INSTR_DSJEQ      = 7'd37, // DSJEQ Rd, Address — if Z=1: DSJ semantics; else skip
    INSTR_DSJNE      = 7'd38, // DSJNE Rd, Address — if Z=0: DSJ semantics; else skip
    INSTR_JACC       = 7'd39, // JAcc Address      — absolute-form conditional jump
                              //                     (low byte = 0x80; 32-bit abs addr follows)
    INSTR_DSJS       = 7'd40, // DSJS Rd, Address  — short form: 5-bit offset + 1-bit
                              //                     direction; single-word instruction
    INSTR_ABS        = 7'd41, // ABS Rd            — |Rd| → Rd (V on MIN_INT)
    INSTR_NEGB       = 7'd42, // NEGB Rd           — (2s_comp Rd) - C → Rd (borrow-in)
    INSTR_BTST_K     = 7'd43, // BTST K, Rd        — test bit K of Rd; only Z updates
    INSTR_BTST_RR    = 7'd44, // BTST Rs, Rd       — test bit Rs[4:0] of Rd; Z only
    INSTR_CLRC       = 7'd45, // CLRC              — ST.C ← 0; N, Z, V unchanged
    INSTR_SETC       = 7'd46, // SETC              — ST.C ← 1; N, Z, V unchanged
    INSTR_GETST      = 7'd47, // GETST Rd          — Rd ← ST
    INSTR_PUTST      = 7'd48, // PUTST Rs          — ST ← Rs (full 32-bit write)
    INSTR_SLA_RR     = 7'd49, // SLA Rs, Rd        — shift left arithmetic by Rs[4:0]
    INSTR_SLL_RR     = 7'd50, // SLL Rs, Rd        — shift left logical by Rs[4:0]
    INSTR_SRA_RR     = 7'd51, // SRA Rs, Rd        — shift right arithmetic by 2sCmp(Rs[4:0])
    INSTR_SRL_RR     = 7'd52, // SRL Rs, Rd        — shift right logical by 2sCmp(Rs[4:0])
    INSTR_RL_RR      = 7'd53, // RL  Rs, Rd        — rotate left by Rs[4:0]
    INSTR_GETPC      = 7'd54, // GETPC Rd          — Rd ← PC (current bit-addressed PC)
    INSTR_EXGPC      = 7'd55, // EXGPC Rd          — swap PC ↔ Rd (PC's low 4 bits cleared)
    INSTR_REV        = 7'd56, // REV Rd            — Rd ← chip-revision number constant
    INSTR_LMO_RR     = 7'd57, // LMO Rs, Rd        — Rd ← 31 - bit_pos(leftmost-1 in Rs)
                              //                     in bottom 5 bits; upper 27 bits = 0;
                              //                     Z = (Rs == 0); N/C/V unaffected
    INSTR_SETF       = 7'd58, // SETF FS, FE, F    — set field-size params for FS<F>/FE<F>
                              //                     (F bit at instr[9]; FE at instr[5];
                              //                     FS at instr[4:0]). Status unaffected.
    INSTR_SEXT       = 7'd59, // SEXT Rd, F        — sign-extend low FS<F> bits to 32;
                              //                     flags N, Z (C, V unaffected via mask).
    INSTR_ZEXT       = 7'd60, // ZEXT Rd, F        — zero-extend low FS<F> bits to 32;
                              //                     flag Z only (N, C, V unaffected).
    INSTR_EXGF       = 7'd61, // EXGF Rd, F        — atomic swap Rd[5:0] ↔ FE<F>:FS<F>
                              //                     in ST; Rd[31:6] cleared. Status
                              //                     bits all "Unaffected".
    INSTR_DINT       = 7'd62, // DINT              — clear ST.IE  (disable interrupts)
    INSTR_EINT       = 7'd63, // EINT              — set ST.IE    (enable interrupts)
    INSTR_PUSHST     = 7'd64, // PUSHST            — SP -= 32; mem[SP] <- ST (32-bit write)
    INSTR_POPST      = 7'd65, // POPST             — ST <- mem[SP]; SP += 32 (32-bit read)
    INSTR_CALL_RS    = 7'd66, // CALL Rs           — SP -= 32; mem[SP] <- PC'; PC <- Rs
                              //                     (with bottom 4 bits forced to 0).
    INSTR_RETS       = 7'd67, // RETS [N]          — PC <- mem[SP]; SP += 32 + 16*N
                              //                     N at instr[4:0], range 0..31.
    INSTR_CALLA      = 7'd68, // CALLA Address     — SP -= 32; mem[SP] <- PC';
                              //                     PC <- absolute (32-bit) with bottom
                              //                     4 bits forced to 0.
    INSTR_CALLR      = 7'd69, // CALLR Address     — SP -= 32; mem[SP] <- PC';
                              //                     PC <- PC' + sign_ext(disp16)*16.
    INSTR_RETI       = 7'd70, // RETI              — ST <- mem[SP]; SP += 32;
                              //                     PC <- mem[SP]; SP += 32.
                              //                     Two-step pop. Status from popped ST.
    INSTR_TRAP       = 7'd71, // TRAP N            — SP -= 32; mem[SP] <- PC';
                              //                     SP -= 32; mem[SP] <- ST;
                              //                     ST <- 0x00000010; PC <- mem[vec].
                              //                     vec = 0xFFFFFFE0 - N*32. N at instr[4:0]
                              //                     (range 1..31; TRAP 0 deferred).
                              //                     Three-step memory: write, write, read.
    INSTR_MMTM       = 7'd72, // MMTM Rp, list     — For each register Rn in the list
                              //                     (lowest-order first): Rp -= 32; mem[Rp] <- Rn.
                              //                     Second word = 16-bit mask (bit N = Rn). Up
                              //                     to 16 32-bit writes per instruction.
                              //                     N flag set to sign of (0 - initial Rp); see
                              //                     SPVU001A page 12-111 for edge cases (deferred).
    INSTR_MMFM       = 7'd73, // MMFM Rp, list     — For each register Rn in the list
                              //                     (highest-order first): Rn <- mem[Rp]; Rp += 32.
                              //                     Pop counterpart of MMTM; reverses its action.
                              //                     Second word = 16-bit mask (bit N = Rn). Up to
                              //                     16 32-bit reads. Final Rp = initial + 32*count.
                              //                     All flags Unaffected (SPVU001A page 12-109).
    INSTR_MOVE_FIELD_STORE = 7'd74, // MOVE Rs,*Rd  — field in Rs -> mem[*Rd]. Rd is a bit-address
                              //                     pointer (unchanged). Encoding 1000 00FS SSSR DDDD.
                              //                     All flags Unaffected. Task 0059 implements the
                              //                     field-size-32, word-aligned case only.
    INSTR_MOVE_FIELD_LOAD  = 7'd75, // MOVE *Rs,Rd  — field at mem[*Rs] -> Rd, sign/zero-extended.
                              //                     Rs is a bit-address pointer. Encoding
                              //                     1000 01FS SSSR DDDD. Implicit compare-to-0:
                              //                     N=sign, Z=zero, V=0, C Unaffected. Task 0059
                              //                     implements field-size-32, word-aligned only.
    INSTR_MOVE_FIELD_M2M   = 7'd76, // MOVE *Rs,*Rd — field at mem[*Rs] -> mem[*Rd]. Both Rs and
                              //                     Rd are bit-address pointers (unchanged for the
                              //                     plain form). Encoding 1000 10FS SSSR DDDD.
                              //                     Two memory transactions (read then write). All
                              //                     flags Unaffected. Task 0061: plain form only,
                              //                     field-size-32, word-aligned.
    INSTR_MOVE_ABS_STORE   = 7'd77, // MOVE Rs,@DAddr — field in Rs -> mem[DAddr]. DAddr is a
                              //                     32-bit absolute bit-address (2 words follow the
                              //                     opcode). Encoding 0000 01F1 100R SSSS. All flags
                              //                     Unaffected. Task 0063: field-size-32, word-aligned.
    INSTR_MOVE_ABS_LOAD    = 7'd78, // MOVE @SAddr,Rd — field at mem[SAddr] -> Rd, sign/zero-ext.
                              //                     SAddr is a 32-bit absolute bit-address. Encoding
                              //                     0000 01F1 101R DDDD. Implicit compare-to-0:
                              //                     N=sign, Z=zero, V=0, C Unaffected. Task 0063.
    INSTR_MOVE_OFF_STORE   = 7'd79, // MOVE Rs,*Rd(off) — field in Rs -> mem[Rd + sext(off16)].
                              //                     Rd pointer unchanged; off16 is the 2nd word.
                              //                     Encoding 1011 00FS SSSR DDDD. All flags
                              //                     Unaffected. Task 0064: field-size-32, aligned.
    INSTR_MOVE_OFF_LOAD    = 7'd80, // MOVE *Rs(off),Rd — field at mem[Rs + sext(off16)] -> Rd.
                              //                     Rs pointer unchanged. Encoding 1011 01FS SSSR
                              //                     DDDD. Implicit compare-to-0: N=sign, Z=zero,
                              //                     V=0, C Unaffected. Task 0064.
    INSTR_MOVX             = 7'd81, // MOVX Rs,Rd — RsX -> RdX (low 16 bits). Rd's Y half (high 16)
                              //                     unaffected. Encoding 1110 110S SSSR DDDD. All
                              //                     flags Unaffected. Task 0065.
    INSTR_MOVY             = 7'd82, // MOVY Rs,Rd — RsY -> RdY (high 16 bits). Rd's X half (low 16)
                              //                     unaffected. Encoding 1110 111S SSSR DDDD. All
                              //                     flags Unaffected. Task 0065.
    INSTR_ADDXY            = 7'd83, // ADDXY Rs,Rd — RdX += RsX, RdY += RsY (independent 16-bit, no
                              //                     carry between halves). Encoding 1110 000S SSSR
                              //                     DDDD. Status (graphics): N=(Xres==0), V=Xres[15],
                              //                     Z=(Yres==0), C=Yres[15]. Task 0066.
    INSTR_SUBXY            = 7'd84, // SUBXY Rs,Rd — RdX -= RsX, RdY -= RsY (independent 16-bit).
                              //                     Encoding 1110 001S SSSR DDDD. Status (compare):
                              //                     N=(RsX==RdX), V=(RsX>RdX), Z=(RsY==RdY),
                              //                     C=(RsY>RdY) (unsigned). Task 0066.
    INSTR_CMPXY            = 7'd85, // CMPXY Rs,Rd — nondestructive XY compare (Rd unchanged). Sets
                              //                     status as if RdX-RsX / RdY-RsY: N=(Xres==0),
                              //                     V=Xres[15], Z=(Yres==0), C=Yres[15]. Encoding
                              //                     1110 010S SSSR DDDD. Task 0067.
    INSTR_CPW              = 7'd86, // CPW Rs,Rd — compare the XY point in Rs against the window
                              //                     corners WSTART (B5) / WEND (B6); load the 4-bit
                              //                     out-of-window code into Rd[8:5]. V=outside-window.
                              //                     Encoding 1110 011S SSSR DDDD. Task 0070.
    INSTR_MPYS             = 7'd87, // MPYS Rs,Rd — signed 32x32 -> 64-bit. Even Rd: {Rd=hi32,
                              //                     Rd+1=lo32}; odd Rd: lo32 in Rd. N=result<0,
                              //                     Z=result==0. Encoding 0101 110S SSSR DDDD.
                              //                     Task 0071 implements FS1=32 (full 32-bit Rs).
    INSTR_MPYU             = 7'd88, // MPYU Rs,Rd — unsigned 32x32 -> 64-bit (same writeback as
                              //                     MPYS). Z=result==0 (N Unaffected). Encoding
                              //                     0101 111S SSSR DDDD. Task 0071 (FS1=32).
    INSTR_DIVU             = 7'd89, // DIVU Rs,Rd — unsigned divide. Even Rd: {Rd:Rd+1}/Rs ->
                              //                     quotient in Rd, remainder in Rd+1. Odd Rd:
                              //                     Rd/Rs -> quotient in Rd. V=overflow (Rs=0 or
                              //                     quotient>32b; result unchanged), Z=quotient==0,
                              //                     N Unaffected. Encoding 0101 101S SSSR DDDD.
    INSTR_MODU             = 7'd90, // MODU Rs,Rd — unsigned 32-bit modulo: Rd mod Rs -> Rd
                              //                     (remainder). V=(Rs==0; Rd unchanged), Z=remainder
                              //                     ==0 (unaffected if Rs==0), N Unaffected. Encoding
                              //                     0110 111S SSSR DDDD. Reuses the divider.
    INSTR_DIVS             = 7'd91, // DIVS Rs,Rd — signed divide (even Rd: 64-bit {Rd:Rd+1}).
                              //                     Quotient->Rd (+remainder->Rd+1 even); sign-
                              //                     conditioned. N=result sign, Z=quotient==0,
                              //                     V=overflow. Encoding 0101 100S SSSR DDDD.
    INSTR_MODS             = 7'd92, // MODS Rs,Rd — signed 32-bit modulo: Rd mod Rs -> Rd
                              //                     (remainder has dividend's sign). N=remainder
                              //                     sign, Z=remainder==0 (unaffected if Rs=0),
                              //                     V=overflow. Encoding 0110 110S SSSR DDDD.
    INSTR_CVXYL            = 7'd93, // CVXYL Rs,Rd — convert the XY address in Rs to a linear
                              //                     address in Rd: ((Y<<(31-CONVDP)) | (X<<log2
                              //                     PSIZE)) + OFFSET(B4). Flags Unaffected.
                              //                     Encoding 1110 100S SSSR DDDD.
    INSTR_FILL_L           = 7'd94, // FILL L — fill a DY×DX pixel array with COLOR1 (B9).
                              //                     Implied B-regs DADDR(B2)/DPTCH(B3)/DYDX(B7);
                              //                     multi-cycle. DADDR updated. Encoding 0x0FC0.
    INSTR_FILL_XY          = 7'd95, // FILL XY — like FILL L but DADDR (B2) holds an XY value,
                              //                     converted to linear (CONVDP+OFFSET+PSIZE)
                              //                     before the fill. Encoding 0x0FE0.
    INSTR_PIXBLT_LL        = 7'd96, // PIXBLT L,L — transfer a DY×DX source array (SADDR=B0/
                              //                     SPTCH=B1) to a dest array (DADDR=B2/DPTCH=B3),
                              //                     processing each pixel. Encoding 0x0F00.
    INSTR_DRAV             = 7'd97, // DRAV Rs,Rd — draw COLOR1 at Rd's XY (PSIZE pixel, with
                              //                     PPOP/T/PMASK), then Rd += Rs as an XY add
                              //                     (no carry X->Y). Encoding 0xF600.
    INSTR_LINE             = 7'd98, // LINE Z — Bresenham inner loop: draw COUNT pixels of
                              //                     COLOR1 along a line. B-file: d/DADDR/DYDX
                              //                     (b:a)/COUNT/INC1/INC2. Enc 0xDF1A/0xDF9A.
    INSTR_MOVE_ABS_M2M     = 7'd99, // MOVE @SAddr,@DAddr — two 32-bit absolute bit-addresses
                              //                     follow the opcode; read FS bits then write them.
                              //                     Enc 0x05C0/0x07C0 (F selects field 0/1).
    INSTR_MOVE_OFF_M2M     = 7'd100,// MOVE *Rs(SOff),*Rd(DOff) — two signed
                              //                     16-bit bit offsets follow the opcode; pointers
                              //                     and flags are unchanged. Enc 0xB800/0xBA00.
    INSTR_MOVE_OFF_NI      = 7'd101,// MOVE *Rs(SOff),*Rd+ — read field at Rs+sext(off16),
                              //                     write to *Rd, then Rd += FS. Source pointer
                              //                     unchanged; flags Unaffected. Enc 0xD000-0xD3FF
                              //                     (MAME move*_no_ni).
    INSTR_MOVE_ABS_NI      = 7'd102 // MOVE @SAddr,*Rd+ — read FS bits at absolute SAddr,
                              //                     write to *Rd, then Rd += FS. Flags Unaffected.
                              //                     Enc 0xD40X/0xD41X (F=0) and 0xD60X/0xD61X (F=1)
                              //                     (MAME move*_a_ni).
  } instr_class_t;

  // Condition codes used by JRcc / JAcc (and other conditional ops).
  // Source: SPVU001A Table 12-8 ("Condition Codes for JRcc and JAcc
  // Instructions"), as re-extracted cleanly with `pdftotext -layout`
  // from the long-form JRcc page (12-96). The earlier (A0017) hand-
  // guess of EQ=0100 and NE=0111 was WRONG — those codes are actually
  // LT and GT, respectively. Corrected in Task 0030; see A0023.
  parameter logic [3:0] CC_UC = 4'b0000;  // unconditional
  parameter logic [3:0] CC_P  = 4'b0001;  // positive         (result > 0; !N & !Z) — MAME j_P.
                                           // (Unsigned lower-than / borrow is CC_C = 1000, not here.)
  parameter logic [3:0] CC_LS = 4'b0010;  // lower-or-same    (unsigned; C | Z = 1)
  parameter logic [3:0] CC_HI = 4'b0011;  // higher-than      (unsigned; ~C & ~Z = 1)
  parameter logic [3:0] CC_LT = 4'b0100;  // less-than        (signed;   N ^ V = 1)
  parameter logic [3:0] CC_GE = 4'b0101;  // greater-or-equal (signed;   N ^ V = 0; alias "JRZ" in spec when comparing-to-zero? — see A0023)
  parameter logic [3:0] CC_LE = 4'b0110;  // less-or-equal    (signed;   (N ^ V) | Z = 1)
  parameter logic [3:0] CC_GT = 4'b0111;  // greater-than     (signed;   !(N ^ V) & !Z = 1)
  parameter logic [3:0] CC_HS = 4'b1001;  // higher-or-same   (unsigned; C = 0; alias "NC"/"NB")
  parameter logic [3:0] CC_EQ = 4'b1010;  // equal            (Z = 1; alias "JRZ")
  parameter logic [3:0] CC_NE = 4'b1011;  // not-equal        (Z = 0; alias "JRNZ")
  // General-arithmetic single-flag conditions (Table 12-8, page 12-31). These
  // test one ST flag directly; unambiguous single-bit codes from the table.
  parameter logic [3:0] CC_C  = 4'b1000;  // carry set        (C = 1; alias "B" borrow)
  parameter logic [3:0] CC_V  = 4'b1100;  // overflow         (V = 1; also window clip)
  parameter logic [3:0] CC_NV = 4'b1101;  // no overflow      (V = 0)
  parameter logic [3:0] CC_N  = 4'b1110;  // negative         (N = 1)
  parameter logic [3:0] CC_NN = 4'b1111;  // nonnegative      (N = 0)

  // Auto-update addressing mode for the indirect MOVE family. The pointer
  // register steps by the field size (32 bits for the implemented FS=32
  // case): POSTINC uses the pointer then adds; PREDEC subtracts first and
  // uses the new value. NONE leaves the pointer unchanged.
  typedef enum logic [1:0] {
    MV_ADDR_NONE    = 2'b00,
    MV_ADDR_POSTINC = 2'b01,
    MV_ADDR_PREDEC  = 2'b10
  } move_addr_mode_t;

  // What the control FSM needs from decode in order to execute. Fields are
  // populated only when the instruction class uses them; the rest hold safe
  // defaults (REG_FILE_A, idx 0, ALU_OP_PASS_A, etc.) so an undriven path
  // never mis-writes the register file.
  typedef struct packed {
    logic          illegal;     // 1 if the encoding is not recognized
    instr_class_t  iclass;      // dispatch class for the control FSM
    reg_file_t     rd_file;     // destination register file (A or B); also
                                // governs Rs file for MOST reg-reg ops because
                                // they constrain Rs and Rd to the same file
                                // (single R bit in encoding).
    reg_idx_t      rd_idx;      // destination register index
    reg_idx_t      rs_idx;      // source register index (reg-reg ops)
    reg_file_t     rs_file;     // source register file. Equals rd_file for all
                                // same-file ops; the ONLY exception is
                                // MOVE Rs,Rd (the M-bit cross-file move), where
                                // Rs and Rd may be in different files. The core
                                // reads this for rf_rs1_file only on MOVE_RR.
    logic          needs_imm16; // fetch one extra 16-bit word for immediate
    logic          needs_imm32; // fetch two extra 16-bit words; LO first then HI
    logic          imm_sign_extend; // if 1, sign-extend imm16 to 32 bits
    alu_op_t       alu_op;      // ALU op to use in CORE_EXECUTE
    shift_op_t     shift_op;    // shifter op (used when result_source = SHIFTER)
    logic          use_shifter; // 1 ⇒ writeback from shifter, else from ALU
    logic [4:0]    k5;          // K-form 5-bit constant (MOVK, ADDK, SUBK, ...)
    logic [3:0]    branch_cc;   // condition code for JRcc / JAcc / DSJcc
    logic          wb_reg_en;   // 1 ⇒ regfile write in CORE_WRITEBACK
    logic          wb_flags_en; // 1 ⇒ ST flag update in CORE_WRITEBACK
    // Per-flag mask: which of {N,C,Z,V} actually take their new value
    // from `alu_flags` when wb_flags_en is set. All-ones = "full update"
    // (the default for arithmetic). BTST uses {n:0,c:0,z:1,v:0}; ABS
    // uses {n:1,c:0,z:1,v:1} to leave C "Unaffected" per spec.
    alu_flags_t    wb_flag_mask;
    // 1 ⇒ instruction includes a memory transaction (read or write)
    // in the CORE_MEMORY state between EXECUTE and WRITEBACK. PUSHST
    // is the first user; later: POPST, CALL, RETS, MMTM, MMFM, MOVE
    // indirect, MOVB, TRAP.
    logic          needs_memory_op;
    // Pointer auto-update mode for the indirect MOVE family (INSTR_MOVE_
    // FIELD_STORE / _LOAD). MV_ADDR_NONE for every other instruction.
    move_addr_mode_t move_mode;
    // 1 ⇒ MOVB (move byte): force the field size to 8 regardless of ST.FS,
    // and sign-extend on load (MOVB loads are always sign-extended). Reuses
    // the INSTR_MOVE_FIELD/OFF/ABS datapaths with FS forced to 8.
    logic          force_byte;
    // 1 ⇒ PIXT (pixel transfer, linear): force the field size to the PSIZE
    // I/O register value and ZERO-extend on load. Reuses the INSTR_MOVE_
    // FIELD_STORE/LOAD/M2M datapaths. PIXT load also reports V = (pixel != 0).
    logic          force_pixel;
    // 1 ⇒ the pointer register holds an XY address (not a linear one): the
    // core converts it to a linear address (via CONVDP for a destination /
    // CONVSP for a source, OFFSET=B4, PSIZE) before the field access. Used by
    // the XY-addressed PIXT forms (always with force_pixel).
    logic          xy_addr;
    // PIXBLT source/destination XY: the SADDR / DADDR implied register holds an
    // XY value (converted to linear at PBLT_SETUP via CONVSP / CONVDP).
    logic          blt_src_xy;
    logic          blt_dst_xy;
    // PIXBLT binary (B,L / B,XY): the source is a 1-bit-per-pixel bitmap; each
    // bit expands to COLOR1(B9) if 1, COLOR0(B8) if 0.
    logic          blt_binary;
  } decoded_instr_t;

  // ---------------------------------------------------------------------------
  // Pixel-processing operation (PPOP) -- shared by all five graphics engines
  // (FILL / PIXBLT / DRAV / LINE / PIXT store). Returns f(src, dest) per the
  // CONTROL.PPOP code (SPVU001A / MAME 34010gfx.hxx pixel_op00..21): 16 Boolean
  // ops + 6 arithmetic ops on the unsigned PSIZE-bit pixels masked by `fmask`
  // (ADDS/SUBS saturate). Lives in the package so it is a single MAME-exact
  // definition callable by the core and by unit tests.
  // ---------------------------------------------------------------------------
  // Mirrors MAME tms340x0_device::pixel_op00..21 (34010gfx.hxx) verbatim, with
  // arg mapping S=src, D=dest, M=fmask. Codes 0x16-0x1F alias pixel_op00 (replace).
  // Kept byte-for-byte with MAME so the differential model matches, including the
  // quirks: op0C returns M (not all-ones); op0D duplicates op0B (~S&D); op0F is
  // S^M (not ~S); ADDS/SUBS mask only D (not S) before the saturating add/sub.
  function automatic logic [DATA_WIDTH-1:0] ppop_apply(
      input logic [DATA_WIDTH-1:0] src,
      input logic [DATA_WIDTH-1:0] dest,
      input logic [4:0]            ppop,
      input logic [DATA_WIDTH-1:0] fmask);
    logic [DATA_WIDTH-1:0]      dm;      // dest & mask
    logic [DATA_WIDTH:0]        usum;    // S + (D&M), unsigned (+1 guard bit)
    logic signed [DATA_WIDTH:0] sdiff;   // (D&M) - S, signed
    dm    = dest & fmask;
    usum  = {1'b0, src} + {1'b0, dm};
    // MAME raster_op_19 is (oldpix > newpix) ? oldpix - newpix : 0, i.e.
    // (D&M) - S saturated at 0 -- the destination is the minuend, matching
    // op18 SUB (dest - src) directly above. The operands were transposed.
    sdiff = $signed({1'b0, dm}) - $signed({1'b0, src});
    unique case (ppop)
      5'h00:   ppop_apply = src;                              // op00: S
      5'h01:   ppop_apply = src & dest;                       // op01: S & D
      5'h02:   ppop_apply = src & ~dest;                      // op02: S & ~D
      5'h03:   ppop_apply = '0;                               // op03: 0
      5'h04:   ppop_apply = (src | ~dest) & fmask;            // op04: (S | ~D) & M
      5'h05:   ppop_apply = ~(src ^ dest) & fmask;            // op05: ~(S ^ D) & M
      5'h06:   ppop_apply = ~dest & fmask;                    // op06: ~D & M
      5'h07:   ppop_apply = ~(src | dest) & fmask;            // op07: ~(S | D) & M
      5'h08:   ppop_apply = (src | dest) & fmask;             // op08: (S | D) & M
      5'h09:   ppop_apply = dest & fmask;                     // op09: D & M
      5'h0A:   ppop_apply = (src ^ dest) & fmask;             // op10: (S ^ D) & M
      5'h0B:   ppop_apply = (~src & dest) & fmask;            // op11: (~S & D) & M
      5'h0C:   ppop_apply = fmask;                            // op12: M
      5'h0D:   ppop_apply = (~src & dest) & fmask;            // op13: (~S & D) & M  (== op11)
      5'h0E:   ppop_apply = ~(src & dest) & fmask;            // op14: ~(S & D) & M
      5'h0F:   ppop_apply = src ^ fmask;                      // op15: S ^ M
      5'h10:   ppop_apply = (src + dest) & fmask;             // op16 ADD : (S + D) & M
      5'h11:   ppop_apply = (usum > {1'b0, fmask}) ? fmask
                                                  : usum[DATA_WIDTH-1:0];    // op17 ADDS: sat-hi
      5'h12:   ppop_apply = (dest - src) & fmask;             // op18 SUB : (D - S) & M
      5'h13:   ppop_apply = (sdiff < 0) ? '0
                                        : sdiff[DATA_WIDTH-1:0];             // op19 SUBS: (D&M)-S sat-0
      5'h14:   ppop_apply = (src > dm) ? src : dm;            // op20 MAX(S, D&M)
      5'h15:   ppop_apply = (src < dm) ? src : dm;            // op21 MIN(S, D&M)
      default: ppop_apply = src;                              // op00 alias (0x16-0x1F)
    endcase
  endfunction

endpackage : tms34010_pkg
`default_nettype wire
