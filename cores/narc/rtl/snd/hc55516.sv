`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hc55516.sv
//
// HC-55516 continuously-variable-slope-delta (CVSD) decoder, the speech chip on
// the Williams CVSD sound board. Bit-for-bit port of MAME's digital HC55516
// model (src/devices/sound/hc55516.cpp, hc55516_device::process_bit), which is
// integer fixed-point and directly synthesizable.
//
// The 6809 bit-bangs the decoder over two write strobes (williamssound.cpp):
//   write 0x6000 (D0) : clock -> 0, then latch the data bit  (inactive edge)
//   write 0x6800      : clock -> 1                            (active/RISING edge)
// process_bit runs on every clock transition; RISING is the active edge that
// shifts the bit in and updates the syllabic companding filter.
//
// Constants (HC55516 variant): shiftreg_mask=0x7, active edge RISING,
// sylmask=0xfc0, sylshift=6, syladd=0xfc1, intshift=4, sylfilter reset=0x3f.
// /FZ and AGC are unused on this board (fzq pulled high) so the bit is taken
// as-is and AGC is ignored.
//
// One `cvsd_wr` pulse per 6809 CVSD write; `clk_set` = 1 for the 0x6800 strobe
// (RISING), 0 for 0x6000 (with `digit` = the new data bit). `sample` is the
// signed 16-bit speech output, updated on every processed transition.
// -----------------------------------------------------------------------------

`default_nettype none
module hc55516 (
  input  wire               clk,       // sound-board (E) clock domain
  input  wire               rst,
  input  wire               cvsd_wr,   // 1-cycle strobe: a CVSD register was written
  input  wire               clk_set,   // 1 = 0x6800 (clock->1), 0 = 0x6000 (clock->0)
  input  wire               digit,     // data bit latched on the 0x6000 write
  output reg  signed [15:0] sample
);
  // 10-bit signed integrator and 12-bit syllabic filter, held sign/zero as in MAME.
  reg               last_clk;
  reg               buf_bit;
  reg  signed [9:0] intfilter;
  reg        [11:0] sylfilter;
  reg         [2:0] shiftreg;

  // sign-extend the low 10 bits to full width (util::sext(x,10))
  function automatic signed [31:0] sext10(input signed [31:0] x);
    sext10 = $signed({{22{x[9]}}, x[9:0]});
  endfunction

  // combinational next-state for one process_bit(bit, clock_state)
  reg  signed [31:0] sum;
  reg  signed [31:0] nintf;
  reg        [11:0]  nsyl;
  reg         [2:0]  nshift;
  reg                active;
  reg                frozen;
  reg                the_bit;
  reg        [11:0]  syl_step;   // (~sylfilter & 0xfc0) >> 6
  reg        [11:0]  lvl;
  reg        [11:0]  mag;

  always @* begin
    active   = clk_set & ~last_clk;          // RISING transition
    // BOTH transitions process the ALREADY-buffered bit. The board's write
    // handler is clock_w() THEN digit_w() -- williamssound.cpp:450-454 (NARC
    // slave) and :149-153 (CVSD board) -- so the digit written alongside the
    // clock-clear strobe is latched AFTER that transition has been processed,
    // and belongs to the NEXT one.
    //
    // Feeding the new digit in here instead only changes `frozen`, which is the
    // sole consumer of the bit on an inactive transition (the sum comes from
    // shiftreg[0]). `frozen` is what arrests the integrator at +/-0x180, so the
    // error is invisible until the signal reaches the rails -- speech never
    // does, a large explosion does, and there the integrator kept accelerating
    // instead of clamping. Proven by sim/snd/tb_hc55516_narc_diff.cpp.
    the_bit  = buf_bit;
    frozen   = ((intfilter >= 10'sd384) && !the_bit) ||
               ((intfilter <= -10'sd384) && the_bit);   // 0x180 = 384
    syl_step = ((~sylfilter) & 12'hfc0) >> 6;
    nshift   = shiftreg;
    nsyl     = sylfilter;
    sum      = 32'sd0;
    lvl      = sylfilter >> 6;
    mag      = (lvl < 12'd2) ? 12'd2 : lvl;

    if (active) begin
      nshift = {shiftreg[1:0], the_bit};
      if ((nshift == 3'b000) || (nshift == 3'b111)) begin
        if (!frozen) nsyl = sylfilter + syl_step;              // coincidence
      end else begin
        if (!frozen) nsyl = sylfilter + syl_step + 12'hfc1;    // syladd
      end
      // sum = sext(((~intfilter) >> intshift) + 1, 10). MAME's
      // m_intfilter is signed int32_t, so complement after sign extension.
      sum = sext10((~$signed({{22{intfilter[9]}}, intfilter}) >>> 4)
                   + 32'sd1);
    end else begin
      // inactive transition: step from the syllabic level, min magnitude 2
      if (shiftreg[0]) sum = sext10((~$signed({20'd0, mag})) + 32'sd1);
      else             sum = sext10($signed({20'd0, mag}));
    end

    nintf = frozen ? $signed({{22{intfilter[9]}}, intfilter})
                   : sext10($signed({{22{intfilter[9]}}, intfilter}) + sum);
  end

  // MAME forms the output after committing this transition's integrator sum,
  // not from the previous-cycle register value.
  wire signed [9:0] next_intfilter = $signed(nintf[9:0]);
  wire signed [15:0] next_scaled =
       $signed({{6{next_intfilter[9]}}, next_intfilter}) <<< 6;
  wire signed [15:0] next_offset =
       $signed({6'd0, ((next_intfilter[9:0] ^ 10'h200) >> 4)});
  wire signed [15:0] next_sample = next_scaled | next_offset;

  always_ff @(posedge clk) begin
    if (rst) begin
      last_clk  <= 1'b0;
      buf_bit   <= 1'b0;
      intfilter <= 10'sd0;
      sylfilter <= 12'h03f;
      shiftreg  <= 3'd0;
      sample    <= 16'sd0;
    end else if (cvsd_wr) begin
      // only process on an actual clock change (is_clock_changed)
      if (clk_set != last_clk) begin
        intfilter <= $signed(nintf[9:0]);
        sylfilter <= nsyl & 12'hfff;
        shiftreg  <= nshift;
        sample    <= next_sample;
      end
      last_clk <= clk_set;
      // 0x6000 write latches the new data bit AFTER the clock->0 transition
      if (!clk_set) buf_bit <= digit;
    end
  end
endmodule
`default_nettype wire
