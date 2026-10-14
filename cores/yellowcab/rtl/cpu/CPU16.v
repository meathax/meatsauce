// DECO16 bus controller (ExpressRaider + MAME deco16 / odeco16.lst)
// Yellow Cab: bank enable uses data bit 2 (kamikcab_io_map).
//
// Custom opcodes (MAME odeco16.lst):
//   0x67 vbl_zpg  — A = IO[0] (IN0 / VBLANK); 2-byte (plant LDA #)
//   0x4B u4B_zpg  — A = IO[1] (TILT); 2-byte (plant LDA #)
//   0x8F u8F_zpg  — bank_en <= operand[2]; 2-byte; A and flags unchanged
//                   Plant $80 (Arlet IMM, load_reg=0) — NOT LDA # (clobbers A)
//                   and NOT BIT zp (clobbers NVZ from zp[operand]).
//   other xx11    — same $80 2-byte skip (u13/u0B/… discard operand)
// Vector remap: low nibble XOR 0xD on $FFF0-$FFFF
//
// IMPORTANT: sequential logic must clock on `cen` (same edge as Arlet).
// Plant is registered: FETCH sees bus opcode (SYNC), DECODE sees plant in DI.

module CPU16(
  input             reset,
  input             clk,   // unused (kept for port compatibility)
  input             cen,
  input             SYNC,
  input             VB,
  input             RW,
  input      [15:0] ABI,
  output reg [15:0] ABO,
  input       [7:0] CPU_DBI,
  output reg  [7:0] CPU_DBO,
  input       [7:0] DBI,
  output      [7:0] DBO,

  output reg        bank_en,

  input       [7:0] io0_data,
  input       [7:0] io1_data
);

reg read_io0;
reg read_io1;
reg read_bank;

assign DBO = CPU_DBI;

always @* begin
  ABO = ABI;
  if (ABI[15:4] == 12'hfff) begin
    ABO[15:4] = ABI[15:4];
    ABO[3:0]  = ABI[3:0] ^ 4'hd;
  end
end

always @(posedge cen or posedge reset) begin
  if (reset) begin
    read_io0  <= 1'b0;
    read_io1  <= 1'b0;
    read_bank <= 1'b0;
    bank_en   <= 1'b0;
    CPU_DBO   <= 8'h00;
  end else begin
    CPU_DBO <= DBI;

    if (read_io0) begin
      CPU_DBO  <= io0_data;
      read_io0 <= 1'b0;
    end
    else if (read_io1) begin
      CPU_DBO  <= io1_data;
      read_io1 <= 1'b0;
    end
    else if (read_bank) begin
      CPU_DBO   <= DBI;
      bank_en   <= DBI[2];
      read_bank <= 1'b0;
`ifdef SIM_ODDOP
      // Bank-enable trace, diffed against MAME's deco16_bank_w IO tap.
      $display("BANKW pc=%04x data=%02x en=%0d", ABI, DBI, DBI[2]);
`endif
    end
    else if (SYNC) begin
      // MAME ddeco16.lst defines EXACTLY ten custom opcodes, all 2-byte:
      //   0B 13 23 3F 4B 67 87 8F A3 BB
      // Every other opcode -- including the other 54 with low bits 11 -- is a
      // plain 6502 instruction or ill_non (1 byte) and must pass through
      // untouched. The old `DBI[1:0] == 2'b11` catch-all planted a 2-byte $80
      // over all 64 of them, silently eating a following byte.
      case (DBI)
        8'h67: begin CPU_DBO  <= 8'hA9; read_io0  <= 1'b1; end // vbl_zpg : A = IO[0]
        8'h4B: begin CPU_DBO  <= 8'hA9; read_io1  <= 1'b1; end // u4B_zpg : A = IO[1]
        8'h8F: begin CPU_DBO  <= 8'h80; read_bank <= 1'b1; end // u8F_zpg : IO[0] <= operand
        // u0B/u13/u23/u3F/u87/uA3/uBB: read operand, discard, A/flags untouched.
        // $80 is the NMOS 2-byte NOP #imm (Arlet: IMM with load_reg = 0).
        8'h0B, 8'h13, 8'h23, 8'h3F, 8'h87, 8'hA3, 8'hBB: CPU_DBO <= 8'h80;

        // Every OTHER xx11 opcode is ill_non in ddeco16.lst, which does nothing
        // but prefetch() -- a 1-byte, no-effect instruction. Plant $EA (NOP) so
        // the length matches exactly.
        //
        // This is load-bearing, not pedantry. Yellow Cab branches to $CB09,
        // which is the middle of "STA $635F" at $CB07, so the byte executed
        // there is the operand $63. It relies on that being a 1-byte NOP so
        // execution falls through into $CB0A "LDA #$00 / STA $6365". Planting a
        // 2-byte $80 instead swallows the $A9 and lands on $00 = BRK; passing
        // $63 through raw lets Arlet decode it as an undocumented opcode of
        // unrelated length. Either way the routine that clears $6365 never
        // runs -- which is what left the fuel gauge stuck empty across lives
        // and credits.
        default: CPU_DBO <= (DBI[1:0] == 2'b11) ? 8'hEA : DBI;
      endcase
    end
  end
end

endmodule
