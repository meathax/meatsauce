// -----------------------------------------------------------------------------
// smashtv_field.sv
//
// Bit-addressed field access for the TMS34010, over a 16-bit little-endian
// word memory. The CPU (birdybro/TMS34010_sv) presents a bit address + a field
// size in bits (1..32) and expects the memory to extract/insert that field,
// right-justified. This module is the barrel-shift + mask layer that turns raw
// word storage into the 34010's bit-addressed space.
//
// Field semantics (TMS34010 User's Guide SPVU001A §3, and MAME
// williams/midyunit + tms34010 memory accessors): the 34010 memory is a flat
// little-endian bitstream. A field of S bits at bit address A occupies bits
// [A .. A+S-1], where bit 0 of word W = A>>4 is the LSB. A field spans at most
// three consecutive 16-bit words (a 32-bit field at offset 15 touches W, W+1,
// W+2), so a 48-bit window is sufficient.
//
// This module is combinational (extract/insert over a 48-bit window). The
// caller supplies the three words and, for a write, receives the three modified
// words plus per-word write strobes. Word fetch/store and multi-cycle
// sequencing live in the memory controller that instantiates this.
//
// Verified by sim/mem_check/tb_field.sv against an independent bit-array model.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_field (
  // Access
  input  wire [31:0] bit_addr,     // TMS34010 bit address
  input  wire [5:0]  size,         // field width in bits, 1..32 (0 treated as 32)
  input  wire [31:0] wdata,        // write data, right-justified

  // Three consecutive words read from storage, word[0] = mem[bit_addr>>4]
  input  wire [15:0] rd_w0,
  input  wire [15:0] rd_w1,
  input  wire [15:0] rd_w2,

  // Extracted field, right-justified, zero-extended
  output wire [31:0] rd_field,

  // Modified words to store back, and which of them actually changed
  output wire [15:0] wr_w0,
  output wire [15:0] wr_w1,
  output wire [15:0] wr_w2,
  output wire [2:0]  wr_strobe      // bit i => word i must be written back
);

  // Bit offset within word W. Word index selection is the caller's job.
  wire [3:0] boff = bit_addr[3:0];

  // Effective size: the CPU encodes a 32-bit field as size==32 (MEM_SIZE_32);
  // treat a literal 0 as 32 defensively so an undriven size never masks to 0.
  wire [5:0] esize = (size == 6'd0) ? 6'd32 : size;

  // 48-bit little-endian window across the three words.
  wire [47:0] win = {rd_w2, rd_w1, rd_w0};

  // --- Extract -------------------------------------------------------------
  // Shift the field down to bit 0, then mask to `esize` bits. Shift by a
  // 4-bit offset (0..15); a 48-bit >> 15 still leaves >= 33 valid low bits,
  // enough for any 32-bit field.
  wire [47:0] shifted = win >> boff;
  wire [31:0] mask32  = (esize >= 6'd32) ? 32'hFFFF_FFFF
                                         : ((32'd1 << esize) - 32'd1);
  assign rd_field = shifted[31:0] & mask32;

  // --- Insert --------------------------------------------------------------
  // Build a 48-bit mask for the field at its bit offset, splice wdata in.
  wire [47:0] mask48   = {16'h0, mask32} << boff;
  wire [47:0] wdata48  = {16'h0, (wdata & mask32)} << boff;
  wire [47:0] merged   = (win & ~mask48) | wdata48;

  assign wr_w0 = merged[15:0];
  assign wr_w1 = merged[31:16];
  assign wr_w2 = merged[47:32];

  // A word needs write-back only if the field's mask touches it.
  assign wr_strobe[0] = |mask48[15:0];
  assign wr_strobe[1] = |mask48[31:16];
  assign wr_strobe[2] = |mask48[47:32];

endmodule
`default_nettype wire
