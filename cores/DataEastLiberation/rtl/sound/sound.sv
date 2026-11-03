// Dual jt49 (AY-3-8912) + latch + DECO222 sound CPU bus
// Yellow Cab / Kamikaze Cabbie: liberate_sound_map (MAME liberate_base → boomrang)
//   AY1 data $3000 / addr $4000; AY2 data $7000 / addr $8000
//   latch read $B000; ROM $C000-$FFFF (bp09 at $E000)
// jt49 from https://github.com/jotego/jt49 (GPL)

module sound (
  input             clk_sys,
  input             reset,

  // Main CPU sound latch write
  input             latch_wr,
  input       [7:0] latch_din,

  // Audio CPU bus
  input      [15:0] cpu_ab,
  input       [7:0] cpu_dout,
  output reg  [7:0] cpu_din,
  input             rw,
  output            irq_n,
  output            nmi_n,

  // ROM from SDRAM cache
  input       [7:0] rom_data,

  output     [15:0] audio_l,
  output     [15:0] audio_r
);

reg [7:0] latch;
reg       irq_r;
assign irq_n = ~irq_r;

wire irq_vec_rd = rw && (cpu_ab == 16'hFFFE);

// MAME: set_periodic_int(nmi_line_pulse, from_hz(16*60)) => 960 Hz.
// 48e6 / 960 = 50000 clk_sys. Held for ~3 audio-CPU cycles so the 6502's edge
// detector cannot miss it; NMI_edge latches, so a longer hold is harmless.
//
// The old version gated the first NMI for ~2 ms to stop it corrupting the reset
// clear-loop. That was compensating for the broken DECO222 decrypt (the handler
// was executing garbage); with the decrypt fixed on the IR path the gate is not
// needed and MAME has no such delay.
reg [15:0] nmi_div;
reg [7:0]  nmi_hold;
assign nmi_n = (nmi_hold == 8'd0);

always @(posedge clk_sys) begin
  if (reset) begin
    nmi_div  <= 16'd0;
    nmi_hold <= 8'd0;
  end else begin
    // The 960 Hz scheduler keeps running while the pulse is held. Stopping
    // nmi_div for these 96 clocks stretched each period to 50,096 clocks
    // (~958.16 Hz), unlike MAME's independent periodic pulse source.
    if (nmi_div == 16'd49999) begin
      nmi_div  <= 16'd0;
      nmi_hold <= 8'd96; // ~3 audio CPU enables at 1.5 MHz
    end else begin
      nmi_div <= nmi_div + 16'd1;
      if (nmi_hold != 0)
        nmi_hold <= nmi_hold - 8'd1;
    end
  end
end

always @(posedge clk_sys) begin
  if (reset) begin
    latch <= 8'd0;
    irq_r <= 1'b0;
  end else begin
    // MAME deco16_io_w case 9: soundlatch write + IRQ asserted with HOLD_LINE.
    // HOLD_LINE clears when the CPU *takes* the interrupt, not when the handler
    // reads the latch at $B000 (which it may do zero or several times).
    //
    // "Taken" is detected as the IRQ vector fetch at $FFFE. That is observable
    // on the bus and unambiguous -- NMI vectors through $FFFA. Deriving it from
    // the CPU's decode state instead is wrong: the core evaluates "IRQ pending
    // and unmasked" at every DECODE, so the flag cleared before the CPU had
    // actually vectored, and the handler never ran at all.
    if (irq_vec_rd)
      irq_r <= 1'b0;
    if (latch_wr) begin
      latch <= latch_din;
      irq_r <= 1'b1;
    end
  end
end

// Sound work RAM — combo read for Arlet
reg [7:0] sram [0:511];
wire sram_cs = (cpu_ab[15:9] == 7'd0);
wire [7:0] ram_q = sram_cs ? sram[cpu_ab[8:0]] : 8'h00;
// Register the bus before the distributed RAM's write decoder. CPU bus cycles
// last 32 or 64 system clocks, so the extra system clock is settled before the
// next CPU sample and breaks the long CPU-state -> RAM write-enable path.
reg       sram_wr = 1'b0;
reg [8:0] sram_wr_addr;
reg [7:0] sram_wr_data;
always @(posedge clk_sys) begin
  sram_wr <= !reset && !rw && sram_cs;
  sram_wr_addr <= cpu_ab[8:0];
  sram_wr_data <= cpu_dout;
  if (!reset && sram_wr) sram[sram_wr_addr] <= sram_wr_data;
end

// AY clocks ~1.5 MHz. Keep JT49's internal divider explicit as well: the
// source adapter uses the standalone AY-3-8910 configuration (CLKDIV=3), and
// relying on a library default would let a future JT49 update silently change
// the chip clock while the external enable remains fixed at 48 MHz / 32.
wire cen_ay;
clk_en #(31) ay_cen(clk_sys, cen_ay);

reg [3:0] ay1_addr, ay2_addr;
wire [9:0] ay1_sound, ay2_sound;

always @(posedge clk_sys) begin
  if (reset) begin
    ay1_addr <= 4'd0;
    ay2_addr <= 4'd0;
  end else begin
    if (!rw && cpu_ab == 16'h4000) ay1_addr <= cpu_dout[3:0];
    if (!rw && cpu_ab == 16'h8000) ay2_addr <= cpu_dout[3:0];
  end
end

jt49 #(.COMP(3'b000), .CLKDIV(3)) ay1 (
  .rst_n  ( ~reset ),
  .clk    ( clk_sys ),
  .clk_en ( cen_ay ),
  .addr   ( ay1_addr ),
  .cs_n   ( ~( !rw && cpu_ab == 16'h3000 ) ),
  .wr_n   ( rw ),
  .din    ( cpu_dout ),
  .sel    ( 1'b1 ),
  .dout   ( ),
  .sound  ( ay1_sound ),
  .A(), .B(), .C(), .sample(),
  .IOA_in ( 8'h00 ), .IOA_out(), .IOA_oe(),
  .IOB_in ( 8'h00 ), .IOB_out(), .IOB_oe()
);

jt49 #(.COMP(3'b000), .CLKDIV(3)) ay2 (
  .rst_n  ( ~reset ),
  .clk    ( clk_sys ),
  .clk_en ( cen_ay ),
  .addr   ( ay2_addr ),
  .cs_n   ( ~( !rw && cpu_ab == 16'h7000 ) ),
  .wr_n   ( rw ),
  .din    ( cpu_dout ),
  .sel    ( 1'b1 ),
  .dout   ( ),
  .sound  ( ay2_sound ),
  .A(), .B(), .C(), .sample(),
  .IOA_in ( 8'h00 ), .IOA_out(), .IOA_oe(),
  .IOB_in ( 8'h00 ), .IOB_out(), .IOB_oe()
);

//--------------------------------------------------------------------------
// Mix + output
//
// MAME liberate_base routes ay1 at 0.30 and ay2 at 0.50 into "mono", i.e. 3:5.
// jt49's `sound` is UNSIGNED 0..1023, so the old {mix,4'd0} produced values up
// to 49104 on a port declared signed (AUDIO_S = 1) -- everything above 0x7FFF
// wrapped to a large negative sample.
//
// jt49_dcrm2 takes an unsigned input and returns a signed, DC-free output,
// which is exactly the conversion needed here.
//--------------------------------------------------------------------------
wire [12:0] mix_u = {3'd0, ay1_sound} + {2'd0, ay1_sound, 1'b0}    // ay1 * 3
                  + {1'd0, ay2_sound, 2'b0} + {3'd0, ay2_sound};   // ay2 * 5

// mix_u can reach the full unsigned 13-bit range. Give the DC remover a
// separate sign bit so startup and abrupt level changes cannot wrap before
// its integrator has tracked the unipolar AY offset.
// jt49_dcrm2's integrator moves 2^-10 of the error per enable, so its corner
// is f_cen / (2*pi*1024). On the 1.5 MHz AY enable that is ~233 Hz, which
// stripped the bass from the music. A 48 kHz enable puts it at ~7.5 Hz, the
// AC-coupling behaviour of the board output rather than a tone filter.
wire cen_dc;
clk_en #(999) dc_cen(clk_sys, cen_dc);
wire signed [13:0] mix_s;
jt49_dcrm2 #(.sw(14)) u_dcrm (
  .clk  ( clk_sys ),
  .cen  ( cen_dc  ),
  .rst  ( reset   ),
  .din  ( {1'b0, mix_u} ),
  .dout ( mix_s   )
);

// Preserve the established x8 gain, but saturate transients at the signed
// PCM rails instead of allowing the concatenation to wrap polarity.
wire signed [16:0] mix_scaled = $signed({{3{mix_s[13]}}, mix_s}) <<< 3;
wire signed [15:0] mix_pcm = mix_scaled[16] ^ mix_scaled[15]
                           ? (mix_scaled[16] ? 16'sh8000 : 16'sh7fff)
                           : mix_scaled[15:0];
assign audio_l = mix_pcm;
assign audio_r = mix_pcm;

always @* begin
  cpu_din = 8'hFF;
  if (cpu_ab[15:9] == 7'd0)
    cpu_din = ram_q;
  else if (cpu_ab == 16'hB000)
    cpu_din = latch;
  else if (cpu_ab >= 16'hC000)
    cpu_din = rom_data;
end

endmodule
