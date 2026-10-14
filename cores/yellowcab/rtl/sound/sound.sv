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
reg        nmi_r;
assign nmi_n = ~nmi_r;

always @(posedge clk_sys) begin
  if (reset) begin
    nmi_div  <= 16'd0;
    nmi_hold <= 8'd0;
    nmi_r    <= 1'b0;
  end else begin
    if (nmi_hold != 0) begin
      nmi_r    <= 1'b1;
      nmi_hold <= nmi_hold - 8'd1;
    end else begin
      nmi_r <= 1'b0;
      if (nmi_div == 16'd49999) begin
        nmi_div  <= 16'd0;
        nmi_hold <= 8'd96; // ~3 audio cens @ 1.5 MHz / 48 MHz
      end else
        nmi_div <= nmi_div + 16'd1;
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
always @(posedge clk_sys) begin
  if (!rw && sram_cs) sram[cpu_ab[8:0]] <= cpu_dout;
end

// AY clocks ~1.5 MHz
wire cen_ay;
clk_en #(31) ay_cen(clk_sys, cen_ay);

reg [3:0] ay1_addr, ay2_addr;
wire [9:0] ay1_sound, ay2_sound;

always @(posedge clk_sys) begin
  if (!rw && cpu_ab == 16'h4000) ay1_addr <= cpu_dout[3:0];
  if (!rw && cpu_ab == 16'h8000) ay2_addr <= cpu_dout[3:0];
end

jt49 #(.COMP(3'b000)) ay1 (
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

jt49 #(.COMP(3'b000)) ay2 (
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

wire signed [12:0] mix_s;
jt49_dcrm2 #(.sw(13)) u_dcrm (
  .clk  ( clk_sys ),
  .cen  ( cen_ay  ),
  .rst  ( reset   ),
  .din  ( mix_u   ),
  .dout ( mix_s   )
);

assign audio_l = {mix_s, 3'd0};
assign audio_r = audio_l;

always @* begin
  cpu_din = 8'hFF;
  if (cpu_ab[15:9] == 7'd0)
    cpu_din = ram_q;
  else if (cpu_ab == 16'hB000)
    cpu_din = latch;
  else if (cpu_ab >= 16'hE000)
    cpu_din = rom_data;
end

endmodule
