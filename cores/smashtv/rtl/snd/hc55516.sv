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
    sext10 = {{22{x[9]}}, x[9:0]};
  endfunction

  wire coincidence = (shiftreg == 3'b000) || (shiftreg == 3'b111);

  // combinational next-state for one process_bit(bit, clock_state)
  reg  signed [31:0] sum;
  reg  signed [31:0] nintf;
  reg        [11:0]  nsyl;
  reg         [2:0]  nshift;
  reg                active;
  reg                frozen;
  reg                the_bit;
  reg        [11:0]  syl_step;   // (~sylfilter & 0xfc0) >> 6

  always @* begin
    active   = clk_set & ~last_clk;          // RISING transition
    the_bit  = clk_set ? buf_bit : digit;    // 0x6800 uses buffered bit; 0x6000 carries new digit
    frozen   = ((intfilter >= 10'sd384) && !the_bit) ||
               ((intfilter <= -10'sd384) && the_bit);   // 0x180 = 384
    syl_step = ((~sylfilter) & 12'hfc0) >> 6;
    nshift   = shiftreg;
    nsyl     = sylfilter;
    sum      = 32'sd0;

    if (active) begin
      nshift = {shiftreg[1:0], the_bit};
      if ((nshift == 3'b000) || (nshift == 3'b111)) begin
        if (!frozen) nsyl = sylfilter + syl_step;              // coincidence
      end else begin
        if (!frozen) nsyl = sylfilter + syl_step + 12'hfc1;    // syladd
      end
      // sum = sext(((~intfilter) >> intshift) + 1, 10)
      sum = sext10(($signed({{22{1'b0}}, ~intfilter}) >>> 4) + 32'sd1);
    end else begin
      // inactive transition: step from the syllabic level, min magnitude 2
      automatic logic [11:0] lvl = (sylfilter >> 6);
      automatic logic [11:0] mag = (lvl < 12'd2) ? 12'd2 : lvl;
      if (shiftreg[0]) sum = sext10((~$signed({20'd0, mag})) + 32'sd1);
      else             sum = sext10($signed({20'd0, mag}));
    end

    nintf = frozen ? $signed({{22{intfilter[9]}}, intfilter})
                   : sext10($signed({{22{intfilter[9]}}, intfilter}) + sum);
  end

  // 16-bit output: (intfilter<<6) | (((intfilter & 0x3ff) ^ 0x200) >> 4)
  wire signed [15:0] out_sample =
       ($signed(intfilter) <<< 6) | (((intfilter & 10'h3ff) ^ 10'h200) >> 4);

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
        intfilter <= nintf[9:0];
        sylfilter <= nsyl & 12'hfff;
        shiftreg  <= nshift;
        sample    <= out_sample;
      end
      last_clk <= clk_set;
      // 0x6000 write latches the new data bit AFTER the clock->0 transition
      if (!clk_set) buf_bit <= digit;
    end
  end
endmodule
`default_nettype wire
