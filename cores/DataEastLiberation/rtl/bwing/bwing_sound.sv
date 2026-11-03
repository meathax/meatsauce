module bwing_sound (
  input             clk_sys,
  input             reset,
  input             pause,
  input             vblank,
  input             latch_wr,
  input       [7:0] latch_data,
  input       [7:0] rom_data,
  output     [12:0] rom_addr,
  output     [15:0] audio_l,
  output     [15:0] audio_r
);

wire [15:0] cpu_ab;
wire [7:0] cpu_do;
reg  [7:0] cpu_di;
wire cpu_rw, cpu_sync, bank_unused;
reg irq_n = 1'b1;
reg nmi_n = 1'b1;

mcpu #(.CLK_DIV(31)) u_cpu (
  // nmi_n carries MAME's 1 kHz bwp3 NMI (masked by $D000.7, acked at $1000).
  // The wrapper used to tie NMI inactive, so the NMI-driven music engine
  // never ran: coin/DAC effects played but gameplay AY music stayed silent.
  .clk_sys(clk_sys), .reset(reset), .irq_n(irq_n), .nmi_n(nmi_n), .vblank(vblank),
  .ready(~pause), .opcode_decrypt(1'b0), .bank_bit2(1'b0),
  .io0_data({8{vblank}}), .io1_data(8'h00),
  .cpu_ab(cpu_ab), .cpu_din(cpu_di), .cpu_dout(cpu_do), .rw(cpu_rw),
  .bank_en(bank_unused), .sync(cpu_sync)
);

assign rom_addr = cpu_ab[12:0];

reg [7:0] latch;
reg [7:0] ram [0:511];
reg       nmi_mask;
reg [15:0] nmi_div;

wire ram_cs = (cpu_ab <= 16'h01ff);
always @(posedge clk_sys) begin
  if (reset) begin
    irq_n <= 1'b1;
    nmi_n <= 1'b1;
    nmi_mask <= 1'b0;
    nmi_div <= 16'd0;
    latch <= 8'd0;
  end else begin
    // MAME drives SNDREQ as HOLD_LINE: acknowledging the interrupt clears the
    // request being serviced, but a new latch write in the same system clock
    // must remain pending.  Give the new request set priority, just as the
    // Liberation-family sound latch does.  The previous ordering let the
    // vector read clear a simultaneous command permanently.
    // DECO16 remaps logical IRQ vector $FFFE/$FFFF to physical $FFF3/$FFF2.
    if (cpu_rw && cpu_ab == 16'hfff3) irq_n <= 1'b1;
    if (latch_wr) begin
      latch <= latch_data;
      irq_n <= 1'b0;
    end

    if (nmi_div == 16'd47999) begin
      nmi_div <= 16'd0;
      if (!nmi_mask) nmi_n <= 1'b0;
    end else nmi_div <= nmi_div + 16'd1;

    if (!cpu_rw && cpu_ab == 16'h1000) nmi_n <= 1'b1;
    if (!cpu_rw && cpu_ab == 16'hd000) nmi_mask <= cpu_do[7];
    if (!cpu_rw && ram_cs) ram[cpu_ab[8:0]] <= cpu_do;
  end
end

always @* begin
  cpu_di = 8'hff;
  if (ram_cs) cpu_di = ram[cpu_ab[8:0]];
  else if (cpu_ab == 16'ha000) cpu_di = latch;
  else if (cpu_ab >= 16'he000) cpu_di = rom_data;
end

wire cen_ay;
clk_en #(31) u_ay_cen(clk_sys, cen_ay);
reg [3:0] ay1_addr, ay2_addr;
wire [9:0] ay1_sound, ay2_sound;
reg [7:0] dac_data;

always @(posedge clk_sys) begin
  if (reset) begin
    ay1_addr <= 4'd0;
    ay2_addr <= 4'd0;
    // DAC08 is represented as signed data around $80. Centre it while reset
    // is asserted so ROM loading and board reset cannot emit a full-scale DC
    // sample before the audio program writes the latch.
    dac_data <= 8'h80;
  end else begin
    if (!cpu_rw && cpu_ab == 16'h4000) ay1_addr <= cpu_do[3:0];
    if (!cpu_rw && cpu_ab == 16'h8000) ay2_addr <= cpu_do[3:0];
    if (!cpu_rw && cpu_ab == 16'h0200) dac_data <= cpu_do;
  end
end

jt49 #(.COMP(3'b000)) ay1 (
  .rst_n(~reset), .clk(clk_sys), .clk_en(cen_ay), .addr(ay1_addr),
  .cs_n(~(!cpu_rw && cpu_ab == 16'h2000)), .wr_n(cpu_rw), .din(cpu_do),
  .sel(1'b1), .dout(), .sound(ay1_sound), .A(), .B(), .C(), .sample(),
  .IOA_in(8'h00), .IOA_out(), .IOA_oe(), .IOB_in(8'h00), .IOB_out(), .IOB_oe()
);

jt49 #(.COMP(3'b000)) ay2 (
  .rst_n(~reset), .clk(clk_sys), .clk_en(cen_ay), .addr(ay2_addr),
  .cs_n(~(!cpu_rw && cpu_ab == 16'h6000)), .wr_n(cpu_rw), .din(cpu_do),
  .sel(1'b1), .dout(), .sound(ay2_sound), .A(), .B(), .C(), .sample(),
  .IOA_in(8'h00), .IOA_out(), .IOA_oe(), .IOB_in(8'h00), .IOB_out(), .IOB_oe()
);

wire [11:0] ay_mix = {2'd0, ay1_sound} + {2'd0, ay2_sound};

// MAME routes AY1/AY2 at 0.5 and DAC08 at 0.1 into one speaker; the board
// output is AC-coupled. Sum both sources at their output gains first and run
// one DC blocker over the whole mix, so an idle DAC code (commonly $00) does
// not leave a constant offset on the output.
//
// Gains are calibrated against MAME 0.289 -wavwrite:
//   DAC  x28 per code: the coin effect toggles the DAC $00<->$FF and MAME's
//        wave spans 7260 peak-to-peak (28.5 per code).
//   AY   x48 per jt49 unit: started from the Liberation mixer's 80 per unit
//        of MAME route gain (x40 at this board's 0.5 route); gameplay music
//        seconds then measured a median 1.16-1.2x below MAME, so x48.
localparam integer AY_GAIN  = 48;
localparam integer DAC_GAIN = 28;
wire [17:0] mix_u = ay_mix * AY_GAIN[5:0] + dac_data * DAC_GAIN[4:0];

// DC blocker corner is f_cen / (2*pi*1024): ~7.5 Hz on a 48 kHz enable. The
// 1.5 MHz AY enable put it at ~233 Hz and removed the music's bass.
wire cen_dc;
clk_en #(999) u_dc_cen(clk_sys, cen_dc);
wire signed [18:0] mix_ac;
jt49_dcrm2 #(.sw(19)) u_dcrm (
  .clk(clk_sys), .cen(cen_dc), .rst(reset),
  .din({1'b0, mix_u}), .dout(mix_ac)
);
// Saturate rather than wrap if both AYs peak together.
wire signed [15:0] mix = (mix_ac > 19'sd32767)  ? 16'sh7fff :
                         (mix_ac < -19'sd32768) ? 16'sh8000 :
                                                  mix_ac[15:0];
assign audio_l = mix;
assign audio_r = mix;

wire _unused = cpu_sync ^ bank_unused;

endmodule
