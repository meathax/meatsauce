module bwing_core (
  input             reset,
  input             clk_sys,
  input             pause,
  // Hi-score port: while hs_active the CPUs are paused and this port drives the main bus
  input             hs_active,
  input      [15:0] hs_addr,
  input             hs_wr,
  input       [7:0] hs_wdata,
  output      [7:0] hs_rdata,
  input       [7:0] p1,
  input       [7:0] p2,
  input       [7:0] p3,
  input       [7:0] dsw1,
  input       [7:0] dsw2,
  input             tilt,
  input             ioctl_download,
  input      [26:0] ioctl_addr,
  input       [7:0] ioctl_dout,
  input             ioctl_wr,
  output     [15:0] ext_main_addr,
  input       [7:0] ext_main_data,
  output            ext_main_req,
  input             ext_main_ready,
  output     [15:0] ext_sub_addr,
  input       [7:0] ext_sub_data,
  output     [12:0] ext_sound_addr,
  input       [7:0] ext_sound_data,
  output      [3:0] red,
  output      [3:0] green,
  output      [3:0] blue,
  output            hs,
  output            vs,
  output            hb,
  output            vb,
  output            ce_pix,
  output     [15:0] audio_l,
  output     [15:0] audio_r
);

// Hi-score bus inputs are registered locally: keeps the bus-mux select short and close to its loads.
reg        hs_active_q;
reg [15:0] hs_addr_q;
reg        hs_wr_q;
reg  [7:0] hs_wdata_q;
always @(posedge clk_sys) begin
  hs_active_q <= hs_active;
  hs_addr_q   <= hs_addr;
  hs_wr_q     <= hs_wr;
  hs_wdata_q  <= hs_wdata;
end

localparam [26:0] CHAR_BASE = 27'h22000;
localparam [26:0] SPR_BASE  = 27'h23000;

wire ioctl_stb = ioctl_download && ioctl_wr;

wire [15:0] cpu_m_ab, s_ab;
wire [7:0] cpu_m_do, s_do;
reg  [7:0] m_di, s_di;
wire cpu_m_rw, s_rw, cpu_m_stb, s_stb;
wire [15:0] m_ab  = hs_active_q ? hs_addr_q : cpu_m_ab;
wire [7:0]  m_do  = hs_active_q ? hs_wdata_q : cpu_m_do;
wire        m_rw  = hs_active_q ? ~hs_wr_q : cpu_m_rw;
wire        m_stb = hs_active_q ? hs_wr_q : cpu_m_stb;
reg [7:0] hs_rdata_r;
// Only main/shared work RAM is a hi-score target: a reduced mux keeps video/ROM/IO out of this path.
wire [7:0] hs_rd_mux = (hs_addr_q < 16'h0800) ? shared_m_q : (hs_addr_q < 16'h1000) ? mwork_q : 8'hff;
always @(posedge clk_sys) hs_rdata_r <= hs_rd_mux;   // registered: cuts the CPU->bus->hiscore timing path
assign hs_rdata = hs_rdata_r;
wire [111:0] m_regs, s_regs;
reg m_irq_n = 1'b1, m_firq_n = 1'b1, m_nmi_n = 1'b1;
reg s_irq_n = 1'b1, s_firq_n = 1'b1, s_nmi_n = 1'b1;

wire cpu_reset = reset | ioctl_download;
bwing_6809 u_main (
  .clk_sys(clk_sys), .reset(cpu_reset), .ready(ext_main_ready && !pause),
  .din(m_di), .dout(cpu_m_do), .addr(cpu_m_ab),
  .rw(cpu_m_rw), .irq_n(m_irq_n), .firq_n(m_firq_n), .nmi_n(m_nmi_n),
  .cycle_stb(cpu_m_stb), .regs(m_regs)
);
bwing_6809 u_sub (
  .clk_sys(clk_sys), .reset(cpu_reset), .ready(!pause),
  .din(s_di), .dout(s_do), .addr(s_ab),
  .rw(s_rw), .irq_n(s_irq_n), .firq_n(s_firq_n), .nmi_n(s_nmi_n),
  .cycle_stb(s_stb), .regs(s_regs)
);

// Program ROMs
wire [7:0] main_rom_q = ext_main_data;
wire [7:0] sub_rom_q  = ext_sub_data;
assign ext_main_addr = cpu_m_ab;   // ROM fetches never come from the hi-score port
assign ext_main_req  = cpu_m_rw && (cpu_m_ab >= 16'h4000);
assign ext_sub_addr  = s_ab;

// Shared and private RAM
wire [7:0] shared_m_q, shared_s_q, mwork_q, maux_q, swork_q;
bram_tdp #(.DW(8), .AW(11)) u_shared (
  .clk(clk_sys),
  .a_addr(m_ab[10:0]), .a_din(m_do), .a_we(m_stb && !m_rw && m_ab < 16'h0800), .a_dout(shared_m_q),
  .b_addr(s_ab[10:0]), .b_din(s_do), .b_we(s_stb && !s_rw && s_ab < 16'h0800), .b_dout(shared_s_q)
);
bram_sp #(.DW(8), .AW(11)) u_mwork (
  .clk(clk_sys), .addr(m_ab[10:0]), .din(m_do),
  .we(m_stb && !m_rw && m_ab >= 16'h0800 && m_ab < 16'h1000), .dout(mwork_q)
);
bram_sp #(.DW(8), .AW(10)) u_maux (
  .clk(clk_sys), .addr(m_ab[9:0]), .din(m_do),
  .we(m_stb && !m_rw && m_ab >= 16'h1400 && m_ab < 16'h1800), .dout(maux_q)
);
bram_sp #(.DW(8), .AW(11)) u_swork (
  .clk(clk_sys), .addr(s_ab[10:0]), .din(s_do),
  .we(s_stb && !s_rw && s_ab >= 16'h0800 && s_ab < 16'h1000), .dout(swork_q)
);

reg [7:0] ctrl_ram [0:7];
reg [7:0] mapmask;
wire [7:0] video_cpu_q;

bwing_video u_video (
  .clk_sys(clk_sys), .reset(reset),
  .cpu_ab(cpu_m_ab), .cpu_dout(cpu_m_do), .cpu_rw(cpu_m_rw), .cpu_stb(cpu_m_stb),   // video RAM is never a hi-score target
  .mapmask(mapmask), .cpu_dout_mux(video_cpu_q),
  .ioctl_download(ioctl_download), .ioctl_addr(ioctl_addr),
  .ioctl_dout(ioctl_dout), .ioctl_stb(ioctl_stb),
  .char_base(CHAR_BASE), .sprite_base(SPR_BASE),
  .red(red), .green(green), .blue(blue), .hs(hs), .vs(vs),
  .hb(hb), .vb(vb), .ce_pix(ce_pix)
);

wire sound_req = m_stb && !m_rw && m_ab == 16'h1c05 && (m_do != 8'h80);
wire [12:0] snd_rom_addr;
assign ext_sound_addr = snd_rom_addr;
bwing_sound u_sound (
  .clk_sys(clk_sys), .reset(cpu_reset), .pause(pause), .vblank(vb),
  .latch_wr(sound_req), .latch_data(m_do), .rom_data(ext_sound_data),
  .rom_addr(snd_rom_addr), .audio_l(audio_l), .audio_r(audio_r)
);

// Main/sub control strobes and asynchronous input latches.
reg [7:0] p3_d;
reg tilt_d;
always @(posedge clk_sys) begin
  p3_d <= p3;
  tilt_d <= tilt;
  if (reset) begin
    m_irq_n <= 1'b1; m_firq_n <= 1'b1; m_nmi_n <= 1'b1;
    s_irq_n <= 1'b1; s_firq_n <= 1'b1; s_nmi_n <= 1'b1;
    mapmask <= 8'd0;
    for (int i = 0; i < 8; i++) ctrl_ram[i] <= 8'd0;
  end else begin
    if ((p3_d[1:0] == 2'b11) && (p3[1:0] != 2'b11)) m_nmi_n <= 1'b0;
    if (p3[1:0] == 2'b11) m_nmi_n <= 1'b1;
    if (!tilt_d && tilt) m_firq_n <= 1'b0;
    if (!tilt) m_firq_n <= 1'b1;

    if (m_stb && !m_rw && m_ab >= 16'h1c00 && m_ab <= 16'h1c07) begin
      ctrl_ram[m_ab[2:0]] <= m_do;
      case (m_ab[2:0])
        3'd0: s_irq_n <= 1'b0;
        3'd1: m_irq_n <= 1'b1;
        3'd2: m_firq_n <= 1'b1;
        3'd3: m_nmi_n <= 1'b1;
        3'd5: if (m_do == 8'h80) s_nmi_n <= 1'b0;
        default: ;
      endcase
    end
    if (m_stb && !m_rw && m_ab == 16'h1b07) mapmask <= m_do;

    if (s_stb && !s_rw && s_ab >= 16'h1800 && s_ab <= 16'h1803) begin
      case (s_ab[1:0])
        2'd0: m_irq_n <= 1'b0;
        2'd1: s_firq_n <= 1'b1;
        2'd2: s_irq_n <= 1'b1;
        2'd3: s_nmi_n <= 1'b1;
      endcase
    end
  end
end

// Main-CPU read mux. The CPU sees only its own address (cpu_m_ab); the hi-score port has a
// separate copy on its registered address, so hs_active never sits in the CPU's data path.
function automatic [7:0] m_rdmux(input [15:0] ab);
  reg [7:0] r;
  begin
    r = 8'hff;
    if (ab < 16'h0800) r = shared_m_q;
    else if (ab < 16'h1000) r = mwork_q;
    else if ((ab >= 16'h1000 && ab < 16'h1400) ||
             (ab >= 16'h1800 && ab < 16'h1a80) ||
             (ab >= 16'h2000 && ab < 16'h4000)) r = video_cpu_q;
    else if (ab >= 16'h1400 && ab < 16'h1800) r = maux_q;
    else if (ab == 16'h1b00) r = dsw1;
    else if (ab == 16'h1b01) r = dsw2;
    else if (ab == 16'h1b02) r = p1;
    else if (ab == 16'h1b03) r = p2;
    else if (ab == 16'h1b04) r = {vb, p3[6:0]};
    else if (ab >= 16'h1c00 && ab <= 16'h1c07) r = ctrl_ram[ab[2:0]];
    else if (ab >= 16'h4000) r = main_rom_q;
    m_rdmux = r;
  end
endfunction
always @* m_di = m_rdmux(cpu_m_ab);

always @* begin
  s_di = 8'hff;
  if (s_ab < 16'h0800) s_di = shared_s_q;
  else if (s_ab < 16'h1000) s_di = swork_q;
  else if (s_ab >= 16'ha000) s_di = sub_rom_q;
end

wire _unused = ^m_regs ^ ^s_regs;

endmodule
