// -----------------------------------------------------------------------------
// smashtv_core.sv
//
// Game-level integration of the Smash T.V. (Midway Y-Unit) core: TMS34010 CPU,
// bit-addressed memory, VRAM, the Williams blitter, and the video generator,
// tied together by a bus router that decodes the Y-Unit memory map.
//
// TMS34010 memory map (bit addresses, MAME williams/midyunit.cpp):
//   0x00000000..0x001FFFFF  VRAM window (bank-selected)     -> smashtv_vram cpu
//   0x01000000..0x010FFFFF  main RAM 128 KB                 -> smashtv_mem
//   0x01400000..            CMOS / NVRAM                     -> nvram (stub RAM)
//   0x01800000..            palette RAM 4096                 -> smashtv_video pal
//   0x01A00000 (+0x80000)   blitter DMA registers            -> smashtv_blitter
//   0x01C00000..            input ports                      -> inputs
//   0x01E00000..            sound command (CVSD)             -> sound latch
//   0x01F00000..            control register                 -> control
//   0x02000000..0x05FFFFFF  GFX ROM window (CPU read)        -> gfx
//   0xFFE00000..0xFFFFFFFF  program ROM                      -> smashtv_mem
//   0xC0000000..            on-chip I/O (handled in the CPU)
//
// The router presents the CPU's single req/ack interface and steers each access
// to the right target, translating the bit-addressed field access into each
// peripheral's native interface. prog/main go through smashtv_mem (which owns
// the field extract/insert); the register-like peripherals take/return 16-bit
// values at word granularity, which is how the boot code drives them.
//
// GFX ROM and program/main storage are loaded via the ioctl download port
// (MiSTer) or poked directly in simulation.
// -----------------------------------------------------------------------------

`default_nettype none
module smashtv_core #(
  // GFX pixel-window size backed here in block RAM. The real 8 MB GFX space
  // lives in SDRAM on hardware; this window is for simulation and the first
  // fit/bring-up (blitter source). 2^18 = 256 KB fits the device comfortably.
  parameter int GFX_WORDS    = 262144,
  // Route program-ROM reads to the external SDRAM burst port (hardware) vs the
  // internal BRAM prog[] (simulation/first bring-up).
  parameter bit EXTERNAL_PROG = 1'b0,
  parameter     PROG_HEX      = "",    // sim-only internal-ROM preload
  // Route GFX (blitter source) reads to SDRAM (hardware) vs the internal gfxrom
  // BRAM window (simulation). The 8 MB GFX space cannot share the block RAM that
  // the frame buffer needs, so hardware keeps GFX in SDRAM.
  parameter bit EXTERNAL_GFX  = 1'b0,
  // Route main RAM to SDRAM (hardware) vs the internal mram BRAM (simulation).
  parameter bit EXTERNAL_MAIN = 1'b0,
  // CPU instruction pacing (0 = unpaced; hardware sets ~15 for real speed).
  parameter int unsigned CPU_PACE_CLKS = 0,
  // Total Carnage (Y-Unit + ADPCM + security chip) target. When 0 the core is
  // byte-identical Smash T.V.; when 1 the program ROM base is 0xFFC00000 (512 KB)
  // and the 0x01C00060 security chip (protection_r / cmos_enable_w) is active.
  parameter bit TOTCARN = 1'b0
)(
  input  wire        clk,
  input  wire        rst,             // game/CPU reset (held during ROM load)
  input  wire        video_rst,       // video-timing reset (runs during ROM load)
  input  wire        ce_pix,          // 8 MHz dot-clock enable
  input  wire        pause,           // freeze CPU + autoerase; video keeps running

  // Inputs (active-high here; MRA/wrapper handles polarity). 6 words of ports.
  input  wire [15:0] in0, in1, in2, in_dsw, in_unk0, in_unk1,

  // Per-game config, from the loader/MRA header via the top wrapper.
  input  wire [7:0]  game_id,        // 0 smashtv, 1 trog, 2 hiimpact, 3 shimpact
  input  wire        cfg_4bpp,       // 4bpp GFX/pen (Trog) vs 6bpp (Smash TV)
  input  wire        cfg_has_prot,   // Y-Unit protection chip present

  // ioctl-style ROM load (word granular). region: 0=prog 1=gfx
  input  wire        ld_en,
  input  wire [1:0]  ld_region,
  input  wire [23:0] ld_addr,         // word index within the region
  input  wire [15:0] ld_data,

  // External program-ROM burst port (EXTERNAL_PROG=1 -> SDRAM in the wrapper).
  output wire        prog_ext_req,
  output wire [17:0] prog_ext_addr,
  input  wire [15:0] prog_ext_w0,
  input  wire [15:0] prog_ext_w1,
  input  wire [15:0] prog_ext_w2,
  input  wire        prog_ext_valid,

  // External GFX read port (EXTERNAL_GFX=1 -> SDRAM in the wrapper). Word address
  // into the GFX region; returns a 16-bit word (2 packed gfx bytes).
  output wire        gfx_ext_req,
  output wire [24:1] gfx_ext_addr,
  input  wire [95:0] gfx_ext_dout,   // 6-word GFX burst {w5..w0}
  input  wire        gfx_ext_ack,

  // External main-RAM port (EXTERNAL_MAIN=1 -> SDRAM in the wrapper).
  output wire        main_ext_req,
  output wire        main_ext_we,
  output wire [24:1] main_ext_addr,
  output wire [15:0] main_ext_din,
  output wire [1:0]  main_ext_be,
  input  wire [47:0] main_ext_dout,
  input  wire        main_ext_ack,

  // Video out
  output wire [7:0]  vga_r,
  output wire [7:0]  vga_g,
  output wire [7:0]  vga_b,
  output wire        vga_hs,
  output wire        vga_vs,
  output wire        vga_hb,
  output wire        vga_vb,
  output wire        vga_ce,

  // Sound command latch to the (separate) CVSD board
  output reg  [9:0]  snd_cmd,
  output reg         snd_cmd_stb,

  // debug/observability
  output wire [31:0] dbg_pc
);

  // ==========================================================================
  // CPU
  // ==========================================================================
  wire        mem_req, mem_we, mem_ack;
  wire [31:0] mem_addr, mem_wdata;
  wire [5:0]  mem_size;
  reg  [31:0] mem_rdata;
  reg         mem_ack_r;
  assign mem_ack = mem_ack_r;

  wire [31:0] pc_o;
  assign dbg_pc = pc_o;

  // Display interrupt: fires at the scanline programmed in the DPYINT I/O
  // register. smashtv_video computes the pulse from its hc/vc counters.
  // dpyint_val is forwarded from the TMS34010 I/O register file (below).
  wire [15:0] dpyint_val;   // DPYINT I/O register → video module
  wire [15:0] dpystrt_val;  // DPYSTRT I/O register → video scanout walker (scroll)
  wire [15:0] dpyctl_val;   // DPYCTL  I/O register → DUDATE / origin bit
  wire [15:0] hcount_w;     // live HCOUNT from video → I/O register reads
  wire [15:0] vcount_w;     // live VCOUNT from video → I/O register reads
  wire        dint_pulse;   // display-interrupt pulse (from smashtv_video)

  tms34010_core #(.RESET_VECTOR_FETCH(1'b1), .PACE_CLKS(CPU_PACE_CLKS)) u_cpu (
    .clk(clk), .rst(rst),
    .ext_dint_set(dint_pulse),
    .ext_int1_line(blit_irq_line),   // blitter DMA-done INT1 line (level)
    .ext_int2_line(1'b0),            // INT2 unused on the Y-unit
    .ext_halt(pause_halt),           // OSD pause: freeze at instruction boundary
    .hcount_i(hcount_w), .vcount_i(vcount_w), .dpyint_o(dpyint_val),
    .dpystrt_o(dpystrt_val), .dpyctl_o(dpyctl_val),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_size(mem_size),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .state_o(), .pc_o(pc_o), .instr_word_o(), .illegal_opcode_o());

  // ==========================================================================
  // Region decode (bit address)
  // ==========================================================================
  wire is_vram = (mem_addr < 32'h0020_0000);
  wire is_main = (mem_addr >= 32'h0100_0000) && (mem_addr < 32'h0110_0000);
  wire is_cmos = (mem_addr >= 32'h0140_0000) && (mem_addr < 32'h0141_0000);
  wire is_pal  = (mem_addr >= 32'h0180_0000) && (mem_addr < 32'h0182_0000);
  wire is_blit = (mem_addr >= 32'h01A0_0000) && (mem_addr < 32'h01A9_0000); // incl mirror
  wire is_in   = (mem_addr >= 32'h01C0_0000) && (mem_addr < 32'h01C1_0000);
  wire is_snd  = (mem_addr >= 32'h01E0_0000) && (mem_addr < 32'h01E1_0000);
  wire is_ctrl = (mem_addr >= 32'h01F0_0000) && (mem_addr < 32'h01F1_0000);
  wire is_gfx  = (mem_addr >= 32'h0200_0000) && (mem_addr < 32'h0600_0000);
  wire is_prog = (mem_addr >= (TOTCARN ? 32'hFFC0_0000 : 32'hFFE0_0000));

  // smashtv_mem serves prog + main.
  wire mem_sel = is_prog || is_main;

  // ==========================================================================
  // prog + main RAM  (owns field extract/insert)
  // ==========================================================================
  wire        mm_ack;
  wire [31:0] mm_rdata;
  smashtv_mem #(.EXTERNAL_PROG(EXTERNAL_PROG), .EXTERNAL_MAIN(EXTERNAL_MAIN),
                .PROG_WORDS(TOTCARN ? 262144 : 131072),
                .PROG_BASE(TOTCARN ? 32'hFFC0_0000 : 32'hFFE0_0000),
                .PROG_HEX(PROG_HEX)) u_mem (
    .clk(clk), .rst(rst),
    .req(mem_req && mem_sel), .we(mem_we), .addr(mem_addr), .size(mem_size),
    .wdata(mem_wdata), .rdata(mm_rdata), .ack(mm_ack),
    .ld_prog_en(ld_en && ld_region == 2'd0),
    .ld_prog_addr(ld_addr[17:0]), .ld_prog_data(ld_data),
    .prog_ext_req(prog_ext_req), .prog_ext_addr(prog_ext_addr),
    .prog_ext_w0(prog_ext_w0), .prog_ext_w1(prog_ext_w1), .prog_ext_w2(prog_ext_w2),
    .prog_ext_valid(prog_ext_valid),
    .main_ext_req(main_ext_req), .main_ext_we(main_ext_we), .main_ext_addr(main_ext_addr),
    .main_ext_din(main_ext_din), .main_ext_be(main_ext_be),
    .main_ext_dout(main_ext_dout), .main_ext_ack(main_ext_ack),
    .miss_stb());

  // ==========================================================================
  // Control register (0x1F00000). Y-Unit form: bit5 = video bank select,
  // bits 7:6 = CMOS page. Latched on write.
  // ==========================================================================
  // Single-cycle peripheral write strobe: the 2-cycle handshake holds mem_req
  // across both cycles, so gate every write side-effect to the respond cycle.
  wire pw = periph_busy && mem_we;

  // Wide (32-bit) peripheral writes: the 34010 writes register PAIRS with one
  // 32-bit MOVE (e.g. the game programs the DMA blitter as CMD+ROWBYTES,
  // OFFLO+OFFHI, WIDTH+HEIGHT pairs). MAME's memory system delivers both
  // 16-bit halves (COMBINE_DATA); our 16-bit peripheral path dropped the high
  // half -- so every blit ran with HEIGHT=0 and drew nothing (found via the
  // attract sim's per-blit log). Deliver the high half to the next word
  // address one cycle after the low half. Consumers: blitter, CMOS, palette.
  reg         pw2;
  reg  [31:0] pw2_addr;
  reg  [15:0] pw2_data;
  always_ff @(posedge clk) begin
    pw2 <= 1'b0;
    if (rst) begin
      pw2_addr <= 32'h0; pw2_data <= 16'h0;
    end else if (pw && mem_size > 6'd16) begin
      pw2      <= 1'b1;
      pw2_addr <= mem_addr + 32'd16;
      pw2_data <= mem_wdata[31:16];
    end
  end
  wire pw2_blit = pw2 && (pw2_addr >= 32'h01A0_0000) && (pw2_addr < 32'h01A9_0000);
  wire pw2_cmos = pw2 && (pw2_addr >= 32'h0140_0000) && (pw2_addr < 32'h0141_0000);
  wire pw2_pal  = pw2 && (pw2_addr >= 32'h0180_0000) && (pw2_addr < 32'h0182_0000);

  // Wide peripheral READ machinery (declared here, before its first use by the
  // peripheral read-address derivations; the FSM lives with the handshake).
  reg  [1:0]  periph_phase;
  reg  [15:0] periph_lo_q;
  wire [31:0] paddr = (periph_phase >= 2'd2) ? (mem_addr + 32'd16) : mem_addr;

  reg [15:0] control_reg;
  wire       videobank_select = control_reg[5];
  always_ff @(posedge clk) begin
    if (rst) control_reg <= 16'h0;
    else if (pw && is_ctrl) control_reg <= mem_wdata[15:0];
  end

  // Sound command latch (0x1E00000). data bits [7:0] + bit 9 (see MAME
  // cvsd_sound_w: (data&0xff) | ((data&0x200)>>1)). Reset on bit 8 low.
  // MAME cvsd_sound_w: write value = (data & 0xff) | ((data & 0x200) >> 1),
  // i.e. board data bit 9 folded into bit 8; bit 8 (active-low) is board reset.
  always_ff @(posedge clk) begin
    snd_cmd_stb <= 1'b0;
    if (rst) snd_cmd <= 10'h0;
    else if (pw && is_snd) begin
      snd_cmd     <= {mem_wdata[9], mem_wdata[8], mem_wdata[7:0]};
      snd_cmd_stb <= 1'b1;
    end
  end

  // ==========================================================================
  // Security chip (0x01C00060-7F) -- Total Carnage only. MAME midyunit_m.cpp
  // cmos_enable_w (write) + protection_r (read). A 3-deep FIFO of the masked
  // (& 0x0F00) write data; on the totcarn reset sequence {0F00,0F00,0F00} the
  // read index resets, and on a falling edge of bit 0x0800 across the last two
  // writes ("clock") the next value of the game-specific data sequence is
  // latched and returned by subsequent reads. Inert (result stays 0) when
  // TOTCARN=0, so Smash T.V. is unaffected.
  // ==========================================================================
  wire is_prot_wr = TOTCARN && pw && is_in &&
                    (mem_addr[15:4] == 12'h006 || mem_addr[15:4] == 12'h007);
  reg  [15:0] prot_s0, prot_s1, prot_s2;
  reg  [3:0]  prot_index;
  reg  [15:0] prot_result;

  function automatic [15:0] totcarn_dataseq(input [3:0] i);
    case (i)
      4'd0:  totcarn_dataseq = 16'h4a00;
      4'd1:  totcarn_dataseq = 16'h6a00;
      4'd2:  totcarn_dataseq = 16'hda00;
      4'd3:  totcarn_dataseq = 16'h6a00;
      4'd4:  totcarn_dataseq = 16'h9a00;
      4'd5:  totcarn_dataseq = 16'h4a00;
      4'd6:  totcarn_dataseq = 16'h2a00;
      4'd7:  totcarn_dataseq = 16'h9a00;
      4'd8:  totcarn_dataseq = 16'h1a00;
      4'd9:  totcarn_dataseq = 16'h8a00;
      4'd10: totcarn_dataseq = 16'haa00;
      default: totcarn_dataseq = 16'h0000;
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      prot_s0 <= 16'h0; prot_s1 <= 16'h0; prot_s2 <= 16'h0;
      prot_index <= 4'd0; prot_result <= 16'h0;
    end else if (is_prot_wr) begin
      // shift FIFO (MAME: seq[0]=seq[1]; seq[1]=seq[2]; seq[2]=data & 0x0F00)
      logic [15:0] ns0, ns1, ns2;
      ns0 = prot_s1;
      ns1 = prot_s2;
      ns2 = mem_wdata[15:0] & 16'h0f00;
      prot_s0 <= ns0; prot_s1 <= ns1; prot_s2 <= ns2;
      if (ns0 == 16'h0f00 && ns1 == 16'h0f00 && ns2 == 16'h0f00) begin
        // reset sequence
        prot_index <= 4'd0;
      end else if ((ns1 & 16'h0800) != 16'h0 && (ns2 & 16'h0800) == 16'h0) begin
        // clock: latch next data-sequence value
        prot_result <= totcarn_dataseq(prot_index);
        prot_index  <= prot_index + 4'd1;
      end
    end
  end

  // ==========================================================================
  // CMOS / NVRAM (0x1400000) -- MAME-exact: 16K words total = 4 PAGES of 0x1000
  // words; the CPU window (0x01400000..0x0140FFFF, 0x1000 words) is banked by
  // the CONTROL register's CMOS-page bits [7:6] (midyunit_v.cpp control_w:
  // m_cmos_page = BIT(data,6,2)*0x1000; midyunit_m.cpp cmos_r/w:
  // m_cmos_ram[offset + m_cmos_page]). The game's settings/high-score library
  // keeps DIFFERENT regions on DIFFERENT pages -- without paging they alias and
  // corrupt each other (found via the attract-sim game-code trace diff: the
  // CMOS entry-index bounds check at 0xFFEA9080 read garbage and crashed).
  // ==========================================================================
  (* ramstyle = "M10K" *) reg [15:0] cmosram [0:16383];
  wire [1:0]  cmos_page = control_reg[7:6];
  wire [13:0] cmos_wi   = {cmos_page, paddr[15:4]};  // page*0x1000 + window word (paddr: wide-read high half)
  reg  [15:0] cmos_rd;
  wire [13:0] cmos_wi2 = {cmos_page, pw2_addr[15:4]};   // wide-write high half
  always_ff @(posedge clk) begin
    if (mem_req && is_cmos) cmos_rd <= cmosram[cmos_wi];
    // one write port, muxed: the wide-write second beat (pw2, the cycle after
    // pw -- never coincident with a pw) or the normal low-half/16-bit write.
    if (pw2_cmos)           cmosram[cmos_wi2] <= pw2_data;
    else if (pw && is_cmos) cmosram[cmos_wi]  <= mem_wdata[15:0];
  end

  // ==========================================================================
  // Inputs (0x1C00000). 6 read-only word ports, selected by word offset.
  // ==========================================================================
  wire [2:0] in_sel = paddr[6:4];   // paddr: wide-read high half
  reg [15:0] in_rd;
  always_comb begin
    case (in_sel)
      3'd0: in_rd = in0;
      3'd1: in_rd = in1;
      3'd2: in_rd = in2;
      3'd3: in_rd = in_dsw;
      3'd4: in_rd = in_unk0;
      3'd5: in_rd = in_unk1;
      // 0x01C00060-7F: protection_r. Two protection engines coexist:
      //   - Total Carnage (TOTCARN build param) uses the inline security chip
      //     above (prot_result).
      //   - The multi-game CVSD path (Trog/HiImpact/SuperHiImpact) uses the
      //     game_id-keyed yunit_protection module (yprot_result); it returns 0
      //     for Smash TV (game_id 0) = MAME m_prot_data==nullptr, passing the
      //     "CUSTOM CHIP U99" self-test.
      default: in_rd = TOTCARN ? prot_result : yprot_result;
    endcase
  end

  // Multi-game Y-Unit protection chip (Trog/HiImpact/SuperHiImpact), keyed by
  // game_id. Fed by writes to 0x01C00060-7F (cmos_enable_w). Distinct from the
  // TOTCARN-only inline engine above (different selection: game_id vs build param).
  wire [15:0] yprot_result;
  wire        yprot_we = pw && is_in && (in_sel[2] & in_sel[1]);  // word offset 6/7
  yunit_protection u_yprot (
    .clk(clk), .rst(rst), .game_id(game_id),
    .we(yprot_we), .wdata(mem_wdata[15:0]), .result(yprot_result)
  );

  // ==========================================================================
  // VRAM  (CPU port with vram_w/vram_r semantics + blitter + scan ports)
  // ==========================================================================
  // CPU word offset within the 256 KB VRAM window, and byte-lane select from
  // the field's bit position/size.
  // The CPU accesses VRAM byte-per-pixel: pixel base = bit_addr >> 3, and the
  // field size (bits) gives the pixel-byte count. Boot writes are 32-bit
  // (4 pixels), byte-aligned.
  wire [17:0] vram_pbase  = mem_addr[20:3];
  wire [2:0]  vram_nbytes = (mem_size >= 6'd32) ? 3'd4 :
                            (mem_size >= 6'd24) ? 3'd3 :
                            (mem_size >= 6'd16) ? 3'd2 : 3'd1;
  wire [15:0] dma_palette_reg;   // from the blitter (DMA_PALETTE)
  wire [31:0] vram_cpu_rdata;
  wire        vram_ready;

  // Single-cycle start pulse to the VRAM engine, then wait for vram_ready.
  reg  vram_pending;
  wire vram_start = mem_req && is_vram && !vram_pending && !vram_ready;
  always_ff @(posedge clk) begin
    if (rst) vram_pending <= 1'b0;
    else if (vram_start)  vram_pending <= 1'b1;
    else if (vram_ready)  vram_pending <= 1'b0;
  end

  wire [17:0] blit_idx;
  wire [15:0] blit_pixel;
  wire        blit_we;
  wire [17:0] scan_idx;
  wire [8:0]  rowaddr_w;   // scrolled VRAM row from the DPYADR walker (for autoerase)
  wire [15:0] scan_pixel;
  wire        vb_ae_w;    // untrimmed vblank (autoerase fill window)

  // Autoerase control (driven below, after the video instance provides vcount/vblank).
  // m_autoerase_enable = ~CONTROL bit4. Force OFF while paused so the frozen
  // frame is not blanked to black by the (video-clocked) autoerase engine.
  wire        ae_enable = ~control_reg[4] && !pause;
  reg         ae_erase_trig;
  reg  [8:0]  ae_erase_line;

  // --- Clean pause ----------------------------------------------------------
  // Smash TV is single-buffered: autoerase blanks each line to black and the
  // blitter refills the WHOLE screen every frame. Halting the CPU the instant
  // pause is requested freezes the framebuffer MID-REFILL -> the screenshot
  // shows large black regions the blitter had not reached yet (not a real bug).
  // Instead: disable autoerase immediately (above) and let the game render two
  // more full frames -- the solid-fill floor overwrites cleanly with no
  // blanking -- THEN halt. The frozen frame is complete.
  reg  pause_halt;
  reg  vb_d_pause;
  reg [1:0] pause_frames;
  always_ff @(posedge clk) begin
    vb_d_pause <= vga_vb;
    if (!pause) begin
      pause_halt <= 1'b0; pause_frames <= 2'd0;
    end else if (!pause_halt) begin
      if (vga_vb && !vb_d_pause) begin           // vblank rising edge
        if (pause_frames == 2'd2) pause_halt <= 1'b1;
        else pause_frames <= pause_frames + 2'd1;
      end
    end
  end

  smashtv_vram u_vram (
    .clk(clk),
    .cpu_req(vram_start), .cpu_we(mem_we),
    .cpu_pbase(vram_pbase), .cpu_nbytes(vram_nbytes), .cpu_wdata(mem_wdata),
    .bank_select(videobank_select),
    .dma_palette(dma_palette_reg), .cpu_rdata(vram_cpu_rdata), .cpu_ready(vram_ready),
    .blit_we(blit_we), .blit_idx(blit_idx), .blit_pixel(blit_pixel),
    .scan_idx(scan_idx), .scan_pixel(scan_pixel),
    .ce_pix(ce_pix), .ae_en(ae_enable), .ae_vblank(vb_ae_w),
    .ae_erase_trig(ae_erase_trig), .ae_erase_line(ae_erase_line));

  // ==========================================================================
  // GFX ROM (blitter source + CPU read window). Backed by block RAM here; the
  // real core streams this from SDRAM. 8 M pixel space is large -- for sim/first
  // bring-up we back a 2 MB window (2^21 pixels) and mask.
  // ==========================================================================
  localparam int GFX_AW = $clog2(GFX_WORDS);
  wire [22:0] blit_gfx_addr;          // blitter's GFX byte address
  // CPU GFX read: CPU drives gfx_addr while the blitter is idle. The blitter
  // (and the SDRAM GFX cache) stall correctly waiting for gfx_valid.
  wire        gfx_cpu_active = is_gfx && mem_req && !mem_we;
  // 32-bit GFX read: the wide-read high phase needs gfx_addr = word+1. Compute the
  // base from mem_addr (unchanged, fast) and REGISTER the +1-word (=+2 pixel) high
  // address, so the wide-read mux selects a registered value -- keeps the adder OFF
  // the gfx_addr -> gfx_reader -> SDRAM critical path (an earlier paddr-based version
  // put a 32-bit adder there and blew clk_sys timing to -2.9ns). mem_addr is held
  // stable for the whole wide read, so cpu_gfx_byte_hi is settled by the high phase.
  wire [22:0] cpu_gfx_byte_lo = (mem_addr - 32'h0200_0000) >> 3;
  reg  [22:0] cpu_gfx_byte_hi;
  always_ff @(posedge clk) cpu_gfx_byte_hi <= cpu_gfx_byte_lo + 23'd2;
  wire [22:0] cpu_gfx_byte   = (periph_phase >= 2'd2) ? cpu_gfx_byte_hi : cpu_gfx_byte_lo;
  wire [22:0] gfx_addr       = gfx_cpu_active ? cpu_gfx_byte : blit_gfx_addr;
  logic [7:0]  gfx_data;
  logic [15:0] gfx_word;      // {byte 2n+1, byte 2n} -- MAME gfxrom_r packing
  logic        gfx_valid;

  generate
  if (!EXTERNAL_GFX) begin : g_gfxrom
    // Simulation / stand-alone: internal BRAM window, loaded via ld_region==1.
    // gfx_valid rises the cycle after gfx_addr is stable (matches BRAM latency).
    (* ramstyle = "M10K" *) reg [7:0] gfxrom [0:GFX_WORDS-1];
    reg [22:0] gfx_addr_r;
    always_ff @(posedge clk) begin
      gfx_data   <= gfxrom[gfx_addr[GFX_AW-1:0]];
      // CPU gfxrom_r is BYTE-granular (MAME: gfx[N] | gfx[N+1]<<8), NOT word-
      // aligned: a MOVB from an ODD byte offset must return gfx[N] in the low
      // byte. The old {addr[..:1],1'b1/0} word-aligned pair returned gfx[N&~1]
      // for both bytes of a pair, so odd-byte CPU reads read the even byte (the
      // custom-chip POST DMACHECK trademark self-test caught this as "U99 BAD").
      gfx_word   <= {gfxrom[gfx_addr[GFX_AW-1:0] + 1'b1],
                     gfxrom[gfx_addr[GFX_AW-1:0]]};
      gfx_addr_r <= gfx_addr;
      if (ld_en && ld_region == 2'd1) gfxrom[ld_addr[GFX_AW-1:0]] <= ld_data[7:0];
    end
    assign gfx_valid   = (gfx_addr_r == gfx_addr);
    assign gfx_ext_req  = 1'b0;
    assign gfx_ext_addr = 24'd0;
  end else begin : g_gfxsdram
    // Hardware: read GFX from SDRAM via the burst reader -- 3-word SDRAM bursts
    // (6 packed pixels/transaction) with a one-burst-ahead prefetch, so the
    // blitter is not SDRAM-bandwidth-starved. Byte selection + the ACK_HOLD-safe
    // handshake live in the reader; the SDRAM gfx channel now returns 48 bits.
    // GFX SDRAM word base sits ABOVE the program image: Smash T.V.'s 256 KB
    // program leaves 0x20000 free; Total Carnage's 512 KB program pushes it to
    // 0x40000 (else the 512 KB program at words 0..0x3FFFF would overlap GFX).
    smashtv_gfx_reader #(.GFX_WORD_BASE(TOTCARN ? 24'h40000 : 24'h20000)) u_gfxrd (
      .clk(clk), .rst(rst),
      .gfx_addr(gfx_addr), .gfx_data(gfx_data), .gfx_word(gfx_word),
      .gfx_valid(gfx_valid),
      .gfx_ext_req(gfx_ext_req), .gfx_ext_addr(gfx_ext_addr),
      .gfx_ext_dout(gfx_ext_dout), .gfx_ext_ack(gfx_ext_ack));
  end

  // CPU gfxrom_r (MAME midyunit_v.cpp): 16-bit read = WORD-ALIGNED gfx[2n]|gfx[2n+1]<<8;
  // byte read (MOVB) = the single byte at gfx_addr. The reader gives a byte-granular
  // gfx_word (low byte = requested byte, for the U99 DMACHECK MOVB compare) which is
  // WRONG for 16-bit reads (the GFX-ROM self-test checksum) -> boot-loop. Size-aware:
  // byte read -> gfx_data in both lanes; 16-bit read -> un-swap odd addr = word-aligned.
  wire [15:0] gfx_word_wa = gfx_addr[0] ? {gfx_word[7:0], gfx_word[15:8]} : gfx_word;
  wire [15:0] gfx_rd = cfg_4bpp
      ? {gfx_word[11:8], gfx_word[11:8], gfx_word[3:0], gfx_word[3:0]}
      : (mem_size <= 6'd8) ? {gfx_data, gfx_data}
                           : gfx_word_wa;
  endgenerate

  // ==========================================================================
  // Blitter (register writes from the CPU at 0x1A00000; reg index = word
  // offset & 0xF, mirror at +0x80000 folds to the same regs)
  // ==========================================================================
  wire [3:0] blit_reg_addr = mem_addr[7:4];
  wire [15:0] blit_reg_rdata;
  wire        blit_busy, blit_irq, blit_irq_line;
  smashtv_blitter u_blit (
    .clk(clk), .rst(rst),
    // wide-write second beat (pw2_blit) delivers the high 16 bits to the next
    // register (e.g. HEIGHT of a WIDTH+HEIGHT pair) one cycle after the low half
    .reg_we((pw && is_blit) || pw2_blit),
    .reg_addr(pw2_blit ? pw2_addr[7:4] : blit_reg_addr),
    .reg_data(pw2_blit ? pw2_data : mem_wdata[15:0]),
    .reg_raddr(paddr[7:4]), .reg_rdata(blit_reg_rdata),
    .dma_palette_o(dma_palette_reg),
    .gfx_addr(blit_gfx_addr), .gfx_data(gfx_data), .gfx_valid(gfx_valid),
    .vram_we(blit_we), .vram_idx(blit_idx), .vram_pixel(blit_pixel),
    .irq_set(blit_irq), .irq_line(blit_irq_line), .busy(blit_busy));

  // ==========================================================================
  // Palette write (0x1800000) -> video. offset masked 0xFFF.
  // ==========================================================================
  // wide-write second beat also serves the palette (32-bit = two entries)
  wire        pal_we   = (pw && is_pal) || pw2_pal;
  wire [11:0] pal_addr = pw2_pal ? pw2_addr[15:4] : paddr[15:4];
  wire [15:0] pal_wdat = pw2_pal ? pw2_data : mem_wdata[15:0];
  wire [15:0] pal_cpu_data;                       // palette read-back (registered in u_video)

  // Overscan crop, from MAME real data (midyunit pixperclock=2, totcarn TMS regs
  // HEBLNK=50/HSBLNK=250/VEBLNK=20/VSBLNK=276): MAME visarea = x[100..499] (400 px)
  // y[20..275] (256 lines). Our hardcoded window renders 410x256, so 10 overscan
  // columns on the RIGHT (H_TRIM_R=10); vertical already matches MAME (V_TRIM_B=0).
  smashtv_video #(.H_TRIM_R(TOTCARN ? 10 : 0),
                  .V_TRIM_B(0)) u_video (
    .clk(clk), .rst(video_rst), .ce_pix(ce_pix),   // video runs during ROM load
    .cfg_4bpp(cfg_4bpp),                            // per-game pen map (Trog 4bpp)
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_data(pal_wdat),
    .pal_cpu_addr(pal_addr), .pal_cpu_data(pal_cpu_data),
    .dpyint_line(dpyint_val), .dpystrt(dpystrt_val), .dpyctl(dpyctl_val),
    .hcount_o(hcount_w), .vcount_o(vcount_w),
    .dpyint_pulse_o(dint_pulse),
    .scan_idx(scan_idx), .rowaddr_o(rowaddr_w), .scan_pixel(scan_pixel),
    .r(vga_r), .g(vga_g), .b(vga_b),
    .hsync(vga_hs), .vsync(vga_vs), .hblank(vga_hb), .vblank(vga_vb),
    .vblank_ae(vb_ae_w),
    .ce_pix_o(vga_ce));

  // Autoerase trigger: on entering each new scan line vc in [VEBLNK+1 .. VSBLNK+1),
  // erase the previous display line (vc-VEBLNK-1). VEBLNK=20, VSBLNK=276, so vc in
  // [21,277) erases display lines 0..255 (the last line at the first vblank line).
  reg [15:0] ae_prev_vc;
  always_ff @(posedge clk) begin
    ae_erase_trig <= 1'b0;
    ae_prev_vc    <= vcount_w;
    if ((vcount_w != ae_prev_vc) && (vcount_w >= 16'd21) && (vcount_w < 16'd277)) begin
      ae_erase_trig <= 1'b1;
      // erase the VRAM row displayed one scanline behind. With the DPYADR walker
      // this follows the scroll; for DPYSTRT=0xFFFC rowaddr==row so this equals
      // the previous fixed (vcount-21) line exactly (no regression).
      ae_erase_line <= rowaddr_w - 9'd1;
    end
  end

  // ==========================================================================
  // Bus response mux + ack. prog/main come from smashtv_mem (multi-region field
  // access); peripherals ack in one cycle with their 16-bit read value.
  // ==========================================================================
  // 2-cycle handshake (matching smashtv_mem / sim_memory_model): capture, then
  // respond. Peripheral registered reads (VRAM, CMOS) settle by the respond
  // cycle since the CPU holds req across both.
  // VRAM has its own variable-latency handshake (vram_ready); the 2-cycle
  // peripheral path covers the register-like targets only.
  reg periph_ack, periph_busy;
  reg [15:0] periph_rd;
  // Wide (32-bit) peripheral READS: the symmetric case of the pw2 wide write.
  // A 32-bit MOVE from CMOS/inputs/blitter must return BOTH 16-bit words
  // ({word+1, word}); with only the low word the high half read back 0 (the
  // game's CMOS verify of its just-restored defaults then fails forever).
  // Extra phases: P0 low-addr settle, P1 latch low + flip address, P2 high
  // settle, P3 ack with {high, low}. Non-wide reads ack on P1 as before.
  // (periph_phase / periph_lo_q / paddr are declared up with the pw2 block.)
  // GFX is now INCLUDED: the ROM-self-test checksum (and possibly sprite/collision
  // code) does 32-bit GFX reads (MOVE *A12+,A7 with FS1=32); excluding GFX returned
  // only the low 16 bits (high half = 0) -> checksum fail / boot-loop.
  wire periph_wide_rd = (mem_size > 6'd16) && !mem_we;
  always_ff @(posedge clk) begin
    if (rst) begin
      periph_ack <= 1'b0; periph_busy <= 1'b0;
      periph_phase <= 2'd0; periph_lo_q <= 16'h0;
    end else begin
      periph_ack <= 1'b0;
      if (!periph_busy) begin
        periph_phase <= 2'd0;
        if (mem_req && !mem_sel && !is_vram && !periph_ack) periph_busy <= 1'b1;
      end else begin
        // GFX ROM reads wait for gfx_valid (SDRAM can take many cycles).
        // All other peripheral targets settle within the 1-cycle wait.
        if (is_gfx && !gfx_valid) begin
          // wait
        end else if (periph_wide_rd && periph_phase == 2'd0) begin
          periph_lo_q  <= periph_rd;      // low word settled this cycle
          periph_phase <= 2'd2;           // flip address to word+1
        end else if (periph_wide_rd && periph_phase == 2'd2) begin
          periph_phase <= 2'd3;           // registered readers settle
        end else begin
          periph_busy <= 1'b0;
          periph_ack  <= 1'b1;
        end
      end
    end
  end

  always_comb begin
    // peripheral read value (registered reads settle within the ack window)
    if      (is_cmos) periph_rd = cmos_rd;
    else if (is_pal)  periph_rd = pal_cpu_data;
    else if (is_blit) periph_rd = blit_reg_rdata;
    else if (is_in)   periph_rd = in_rd;
    else if (is_ctrl) periph_rd = control_reg;
    // MAME gfxrom_r: 6bpp returns {byte 2n+1, byte 2n}. 4bpp (Trog) instead
    // duplicates each 4-bit pixel into both nibbles of its byte:
    //   gfx[2n] | gfx[2n]<<4 | gfx[2n+1]<<8 | gfx[2n+1]<<12
    // gfx_word = {gfx[2n+1], gfx[2n]} with each byte holding a 4-bit pixel in
    // its low nibble, so 4bpp = {word[11:8],word[11:8],word[3:0],word[3:0]}.
    else if (is_gfx)  periph_rd = gfx_rd;
    else              periph_rd = 16'h0;
  end

  // ack is combinational (the CPU samples it live).
  always_comb mem_ack_r = mem_sel ? mm_ack : (is_vram ? vram_ready : periph_ack);

  // mem_rdata must be valid ON the ack cycle AND stay held afterwards: the
  // MOVE-load writeback re-reads it a cycle after ack, when mem_addr has moved
  // on. A live mux on mem_addr would switch away from the held source (to
  // periph_rd = 0) and corrupt the load. So: pass the selected value through
  // combinationally on the ack cycle, and hold that value otherwise -- exactly
  // like sim_memory_model's single registered mem_rdata.
  wire [31:0] rd_sel = mem_sel  ? mm_rdata
                     : is_vram   ? vram_cpu_rdata
                                 : (periph_wide_rd ? {periph_rd, periph_lo_q} : {16'h0, periph_rd});
  reg  [31:0] rdata_hold;
  always_ff @(posedge clk) begin
    if (rst)            rdata_hold <= 32'h0;
    else if (mem_ack_r) rdata_hold <= rd_sel;
  end
  always_comb mem_rdata = mem_ack_r ? rd_sel : rdata_hold;

endmodule
`default_nettype wire
