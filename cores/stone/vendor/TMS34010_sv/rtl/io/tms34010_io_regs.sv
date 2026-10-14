// -----------------------------------------------------------------------------
// tms34010_io_regs.sv
//
// On-chip memory-mapped I/O register file for the TMS34010.
//
// Per the 1988 User's Guide Figure 6-1 (page 6-3), the GSP has 32 internal
// 16-bit registers occupying the bit-address range 0xC0000000-0xC00001FF.
// Each register sits at a 0x10-bit-aligned address (16 bits apart). The CPU
// (and, on real silicon, the host) reaches them through the ordinary
// bit-addressed memory interface; an address decodes to I/O space when its
// two MSBs are 11 and bits[29:9] are 0. The register index is addr[8:4].
//
// "All I/O registers ... are cleared to 0 at reset" (UG §6, Reset), except
// HSTCTLH.HLT, which samples HCS at reset release: active-low HCS selects
// self-bootstrap (HLT=0), while inactive-high HCS selects host-present halt.
//
// Current scope (Tasks 0081–0158):
//   - Plain read/write storage for ordinary registers. This is exactly correct
//     for the control/graphics registers that the instruction set reads
//     (PSIZE, PMASK, CONVSP, CONVDP, CONTROL, DPYCTL, ...).
//     Defined reserved fields remain zero, and the four reserved register
//     locations ignore writes and return zero.
//   - Dedicated taps drive graphics and interrupt control. Sideband inputs
//     auto-clear HSTCTLH.NMI and set the internal interrupt latches.
//   - INTPEND implements the source-specific semantics from pages 6-41/6-42:
//     synchronized read-only external levels, read-only HSTCTLL.INTIN, and
//     hardware-set/write-zero-to-clear DIP/WVP latches.
//   - REFCNT is the live writable refresh counter driven by CONTROL.RR.
//   - HCOUNT/VCOUNT and DPYADR live in the dedicated VCLK subsystem. Packed
//     MCP mailboxes carry atomic configuration/coalesced writes and return
//     coherent live snapshots; DPYCTL.ENV gates BLANK and DIP.
//   - DPYSTRT/DPYCTL schedule held VCLK screen-refresh requests; a bundled
//     transaction crosses to the memory fabric and returns completion before
//     the address/count update.
//   - The synchronous four-register host boundary implements HSTADR/HSTDATA
//     indirect sequencing plus per-side HSTCTL ownership, HINT, NMI/HLT
//     control, and HCS-selected reset state. Host-indirect accesses to this
//     I/O page return the shared register view and commit writes only after
//     their physical I/O cycle. The integrated host-pin wrapper now owns
//     asynchronous host-bus timing and CDC outside this core-clock block.
//
// Port shape:
//   - Synchronous active-high reset (assumption A0003); all registers -> 0
//     except HSTCTLH.HLT, which samples hcs_n_i.
//   - One completion-qualified processor write port plus the acknowledged
//     host-indirect I/O write path.
//   - One combinational (async) read port. The 32x16 array is tiny (512
//     bits) and async read keeps this composable with the core's existing
//     register-style reads; FPGA maps it to flops + a 32:1 mux.
//   - `is_io` tells the caller whether `addr` decoded as I/O space, so the
//     surrounding memory fabric can route reads/writes here vs. external RAM.
//     The held host client has matching decode/read-data outputs.
//
// Spec source:
//   third_party/TMS34010_Info/docs/ti-official/1988_TI_TMS34010_Users_Guide.pdf
//   Figure 6-1 (I/O Register Memory Map), §6 "I/O Registers".
// -----------------------------------------------------------------------------

`default_nettype none
module tms34010_io_regs
  import tms34010_pkg::*;
(
  input  logic                  clk,
  input  logic                  vclk_i,
  input  logic                  rst,
  input  logic                  vclk_rst_i,
  input  logic                  video_hsync_n_i,
  input  logic                  video_vsync_n_i,

  // Synchronous four-register host boundary. The Task 0153 host-bus wrapper
  // converts physical asynchronous pin cycles into this request/ack port.
  input  logic                  hcs_n_i,          // reset strap: 0=run, 1=halt
  input  logic                  host_req_i,
  input  logic                  host_we_i,
  input  host_reg_sel_t         host_reg_i,
  input  logic [1:0]            host_be_i,
  input  local_word_t           host_wdata_i,
  output local_word_t           host_rdata_o,
  output logic                  host_ack_o,
  output logic                  host_busy_o,
  output logic                  hint_n_o,
  output logic                  hlt_o,

  // Held host-indirect local-word client. tms34010_system connects this to
  // the memory fabric alongside CPU, display, and refresh clients.
  output logic                  host_mem_req_o,
  output logic                  host_mem_we_o,
  output logic [ADDR_WIDTH-1:0] host_mem_addr_o,
  output local_word_t           host_mem_wdata_o,
  output logic                  host_mem_is_io_o,
  output local_word_t           host_mem_io_rdata_o,
  input  local_word_t           host_mem_rdata_i,
  input  logic                  host_mem_ack_i,

  input  logic                  req,      // access strobe
  input  logic                  we,       // 1 = write, 0 = read
  input  logic [ADDR_WIDTH-1:0] addr,     // full 32-bit bit-address
  input  logic [ADDR_WIDTH-1:0] req_addr_i, // held address for req completion
  input  logic [15:0]           wdata,
  input  logic                  req_next_i, // same field crosses next I/O word
  input  logic [ADDR_WIDTH-1:0] req_next_addr_i,
  input  logic [15:0]           wdata_next_i,
  input  logic                  req_third_i, // same field crosses a third word
  input  logic [ADDR_WIDTH-1:0] req_third_addr_i,
  input  logic [15:0]           wdata_third_i,

  output logic [15:0]           rdata,    // selected register (0 if not I/O)
  output logic [15:0]           rdata_next, // following register for wide fields
  output logic [15:0]           rdata_third,
  // Fast field view uses addr independently of the sequenced request mux.
  output logic [47:0]           field_rdata_o,
  output logic                  is_io,    // addr decodes to I/O space

  // Dedicated taps for the graphics datapath (combinational views of the
  // stored registers). More can be added (PMASK/CONTROL) as the graphics ops
  // that need them land.
  output logic [15:0]           psize_o,  // PSIZE: pixel size in bits (1..16)
  output logic [15:0]           convdp_o, // CONVDP: XY->linear dest pitch shift
  output logic [15:0]           convsp_o, // CONVSP: XY->linear source pitch shift
  output logic [15:0]           control_o,// CONTROL: PPOP[14:10], PBV/PBH, W, T(bit5)
  output logic [15:0]           pmask_o,  // PMASK: plane mask (1 bit = plane masked)
  output logic                  pixel_srt_o, // DPYCTL.SRT pixel-cycle conversion
  output logic [15:0]           intenb_o, // INTENB: maskable-interrupt enables
  output logic [15:0]           intpend_o,// INTPEND: maskable-interrupt pending bits
  output logic [15:0]           hstctlh_o,// HSTCTLH: host control (NMI/NMIM in bits 8/9)
  output logic [15:0]           refcnt_o, // REFCNT: live interval/row counter
  output logic                  refresh_req_o, // one cycle at RINTVL underflow
  output logic [7:0]            refresh_row_o, // decremented ROWADR for request
  output logic                  refresh_cbr_o, // CONTROL.RM: 1=CAS-before-RAS
  output logic [15:0]           hcount_o, // live horizontal video counter
  output logic [15:0]           vcount_o, // live vertical video counter
  output logic                  video_hsync_o,
  output logic                  video_vsync_o,
  output logic                  video_hblank_o,
  output logic                  video_vblank_o,
  output logic                  video_blank_o,
  output logic                  video_hsync_oe_o,
  output logic                  video_vsync_oe_o,
  output logic [15:0]           dpyadr_o, // live LNCNT/SRFADR state
  output logic                  screen_refresh_req_o, // held until ack
  input  logic                  screen_refresh_ack_i,
  output logic [13:0]           screen_refresh_srfaddr_o,
  output logic [15:0]           screen_refresh_dpytap_o,
  output logic                  screen_refresh_org_o,
  input  logic                  nmi_clear,     // clear HSTCTLH.NMI after NMI entry
  input  logic                  wvp_set,       // synchronous INTPEND.WVP set pulse
  input  logic                  dpyint_set,    // synchronous INTPEND.DIP set pulse
  input  logic                  lint1_n_i,     // asynchronous, active-low LINT1 pin
  input  logic                  lint2_n_i      // asynchronous, active-low LINT2 pin
);

  // I/O-space decode: two MSBs = 11 and bits[29:9] = 0 (range C0000000-
  // C00001FF). The register index is addr[8:4].
  logic [IO_REG_IDX_W-1:0] idx;
  logic [IO_REG_IDX_W-1:0] req_idx;
  logic [IO_REG_IDX_W-1:0] req_next_idx;
  logic [IO_REG_IDX_W-1:0] req_third_idx;
  logic [IO_REG_IDX_W-1:0] rdata_idx;
  logic [IO_REG_IDX_W-1:0] cpu_access_idx;
  logic                    req_is_io;
  logic                    req_next_is_io;
  logic                    req_third_is_io;
  logic                    rdata_is_io;
  // Keep the exact architectural window, including sequenced words at
  // either boundary. Completion addresses are registered before this mux.
  assign is_io = (addr[ADDR_WIDTH-1:9] == 23'h600000);
  assign idx   = addr[IO_REG_IDX_W+3 : 4];
  assign req_is_io = (req_addr_i[ADDR_WIDTH-1:9] == 23'h600000);
  assign req_next_is_io = (req_next_addr_i[ADDR_WIDTH-1:9] == 23'h600000);
  assign req_third_is_io = (req_third_addr_i[ADDR_WIDTH-1:9] == 23'h600000);
  assign req_idx = req_addr_i[IO_REG_IDX_W+3 : 4];
  assign req_next_idx = req_next_addr_i[IO_REG_IDX_W+3 : 4];
  assign req_third_idx = req_third_addr_i[IO_REG_IDX_W+3 : 4];
  // The core snapshots the request address before sampling this asynchronous
  // read port. Select from that registered address so instruction decode and
  // register-file address generation are not in the same cycle as the 32:1
  // I/O register mux.
  assign rdata_is_io = req_is_io;
  assign rdata_idx = req_idx;
  assign cpu_access_idx = req ? req_idx : rdata_idx;

  // Register storage.
  logic [15:0] io_reg [0:IO_REG_COUNT-1];

  logic lint1_n_sync;
  logic lint2_n_sync;
  logic [15:0] intpend_value;
  logic        refcnt_load;
  logic        hcount_load;
  logic        vcount_load;
  logic        dpyadr_load;
  logic        video_config_write;
  logic        video_dpyint_pulse;
  logic        host_ctl_we;
  logic [1:0]  host_ctl_be;
  local_word_t host_ctl_wdata;
  local_word_t host_ctl_rdata;
  logic        cpu_host_we;
  host_reg_sel_t cpu_host_reg;
  local_word_t cpu_host_rdata;
  logic cpu_host_next_we, cpu_host_third_we;
  host_reg_sel_t cpu_host_next_reg, cpu_host_third_reg;
  local_word_t cpu_host_next_rdata, cpu_host_third_rdata;
  logic [ADDR_WIDTH-1:0] cpu_host_address;
  local_word_t cpu_host_data;
  logic        host_indirect_we;
  logic [IO_REG_IDX_W-1:0] host_mem_idx;
  host_reg_sel_t host_mem_host_reg;
  local_word_t host_mem_host_rdata;
  logic        io_write_commit;
  logic        io_write_from_host;
  logic [IO_REG_IDX_W-1:0] io_write_idx;
  local_word_t io_write_data;
  logic [2:0] io_lane_commit;
  logic [IO_REG_IDX_W-1:0] io_lane_idx [0:2];
  local_word_t io_lane_data [0:2];
  logic [IO_REG_COUNT-1:0] cpu_first_match, cpu_next_match, cpu_third_match;
  logic [IO_REG_COUNT-1:0] host_word_match, io_register_commit;
  local_word_t cpu_register_data [0:IO_REG_COUNT-1];
  local_word_t io_register_data [0:IO_REG_COUNT-1];
  local_word_t refcnt_wdata, hcount_wdata, vcount_wdata, dpyadr_wdata;
  logic processor_hstctll_set, hstctlh_written;

  function automatic host_reg_sel_t host_register_selection(
    input logic [IO_REG_IDX_W-1:0] reg_index
  );
    unique case (reg_index)
      IO_IDX_HSTADRL: return HOST_REG_HSTADRL;
      IO_IDX_HSTADRH: return HOST_REG_HSTADRH;
      default: return HOST_REG_HSTDATA;
    endcase
  endfunction

  // Map the processor's three memory-mapped host registers onto the same
  // storage owned by tms34010_host_if. HSTCTL remains in io_reg because its
  // per-side field ownership and interrupt effects live in this block.
  always_comb begin
    cpu_host_reg = HOST_REG_HSTDATA;
    unique case (cpu_access_idx)
      IO_IDX_HSTADRL: cpu_host_reg = HOST_REG_HSTADRL;
      IO_IDX_HSTADRH: cpu_host_reg = HOST_REG_HSTADRH;
      IO_IDX_HSTDATA: cpu_host_reg = HOST_REG_HSTDATA;
      default: ;
    endcase
  end

  assign cpu_host_we = req && we && req_is_io
                    && ((req_idx == IO_IDX_HSTADRL)
                        || (req_idx == IO_IDX_HSTADRH)
                        || (req_idx == IO_IDX_HSTDATA));

  assign cpu_host_next_reg = host_register_selection(req_next_idx);
  assign cpu_host_third_reg = host_register_selection(req_third_idx);
  assign cpu_host_next_we = req && we && req_is_io
                         && req_next_i && req_next_is_io
                         && ((req_next_idx == IO_IDX_HSTADRL)
                             || (req_next_idx == IO_IDX_HSTADRH)
                             || (req_next_idx == IO_IDX_HSTDATA));
  assign cpu_host_third_we = req && we && req_is_io
                          && req_third_i && req_third_is_io
                          && ((req_third_idx == IO_IDX_HSTADRL)
                              || (req_third_idx == IO_IDX_HSTADRH)
                              || (req_third_idx == IO_IDX_HSTDATA));

  // The held host-indirect address is already a full bit address. Decode it
  // independently of the processor port so both clients retain their own
  // combinational read views while arbitration serializes physical cycles.
  assign host_mem_is_io_o =
      (host_mem_addr_o[ADDR_WIDTH-1:9] == 23'h600000);
  assign host_mem_idx =
      host_mem_addr_o[IO_REG_IDX_W+3:4];

  always_comb begin
    host_mem_host_reg = HOST_REG_HSTDATA;
    unique case (host_mem_idx)
      IO_IDX_HSTADRL: host_mem_host_reg = HOST_REG_HSTADRL;
      IO_IDX_HSTADRH: host_mem_host_reg = HOST_REG_HSTADRH;
      IO_IDX_HSTDATA: host_mem_host_reg = HOST_REG_HSTDATA;
      default: ;
    endcase
  end

  // A host-indirect I/O write changes architectural state only on the
  // returned physical-cycle completion. The arbiter cannot acknowledge a
  // processor and host cycle together; host selection is nevertheless made
  // explicit here for a deterministic shared-port rule.
  assign host_indirect_we =
      host_mem_req_o && host_mem_we_o
      && host_mem_is_io_o && host_mem_ack_i
      && ((host_mem_idx == IO_IDX_HSTADRL)
          || (host_mem_idx == IO_IDX_HSTADRH)
          || (host_mem_idx == IO_IDX_HSTDATA));

  always_comb begin
    io_write_commit    = req && we && req_is_io;
    io_write_from_host = 1'b0;
    io_write_idx       = req_idx;
    io_write_data      = wdata;

    if (host_mem_req_o && host_mem_we_o
        && host_mem_is_io_o && host_mem_ack_i) begin
      io_write_commit    = 1'b1;
      io_write_from_host = 1'b1;
      io_write_idx       = host_mem_idx;
      io_write_data      = host_mem_wdata_o;
    end
  end

  // Every touched word receives the same completed-write semantics. In the
  // integrated fabric processor and host-indirect completions are exclusive;
  // explicit host priority also covers a conflicting standalone request.
  always_comb begin
    io_lane_commit[0] = io_write_commit;
    io_lane_idx[0] = io_write_idx;
    io_lane_data[0] = io_write_data;
    io_lane_commit[1] = req && we && req_is_io && req_next_i && req_next_is_io
        && !(io_write_from_host && (io_write_idx == req_next_idx));
    io_lane_idx[1] = req_next_idx;
    io_lane_data[1] = wdata_next_i;
    io_lane_commit[2] = req && we && req_is_io && req_third_i && req_third_is_io
        && !(io_write_from_host && (io_write_idx == req_third_idx));
    io_lane_idx[2] = req_third_idx;
    io_lane_data[2] = wdata_third_i;
  end

  // Select the processor payload from held addresses before completion. The
  // late ACK only enables the destination register, rather than controlling a
  // shared lane/index mux followed by another register decoder. Preserve the
  // standalone shared-port rule: a host completion replaces processor lane 0,
  // and wins any overlap with lanes 1/2; otherwise the later processor lane wins.
  // Write intent and the first-word page qualify only the commit gate. Payload
  // selection needs the addressed lanes, without another write/decode cone.
  always_comb begin
    for (int unsigned reg_index = 0; reg_index < IO_REG_COUNT; reg_index++) begin
      cpu_first_match[reg_index] = (req_idx == IO_REG_IDX_W'(reg_index));
      cpu_next_match[reg_index] = req_next_i && req_next_is_io
          && (req_next_idx == IO_REG_IDX_W'(reg_index));
      cpu_third_match[reg_index] = req_third_i && req_third_is_io
          && (req_third_idx == IO_REG_IDX_W'(reg_index));
      host_word_match[reg_index] =
          (host_mem_idx == IO_REG_IDX_W'(reg_index));
      cpu_register_data[reg_index] = cpu_third_match[reg_index] ? wdata_third_i
          : cpu_next_match[reg_index] ? wdata_next_i : wdata;
      io_register_data[reg_index] =
          (io_write_from_host && host_word_match[reg_index])
          ? host_mem_wdata_o : cpu_register_data[reg_index];
      io_register_commit[reg_index] =
          (req && we && req_is_io
           && (cpu_next_match[reg_index] || cpu_third_match[reg_index]
                   || (cpu_first_match[reg_index] && !io_write_from_host)))
          || (io_write_from_host && host_word_match[reg_index]);
    end
  end

  tms34010_host_if u_host_if (
    .clk           (clk),
    .rst           (rst),
    .host_req_i    (host_req_i),
    .host_we_i     (host_we_i),
    .host_reg_i    (host_reg_i),
    .host_be_i     (host_be_i),
    .host_wdata_i  (host_wdata_i),
    .host_rdata_o  (host_rdata_o),
    .host_ack_o    (host_ack_o),
    .host_busy_o   (host_busy_o),
    .ctl_we_o      (host_ctl_we),
    .ctl_be_o      (host_ctl_be),
    .ctl_wdata_o   (host_ctl_wdata),
    .ctl_rdata_i   (host_ctl_rdata),
    .hstctlh_i     (io_reg[IO_IDX_HSTCTLH]),
    .cpu_we_i      (cpu_host_we),
    .cpu_reg_i     (cpu_host_reg),
    .cpu_wdata_i   (wdata),
    .cpu_rdata_o   (cpu_host_rdata),
    .cpu_hstadr_o  (cpu_host_address),
    .cpu_hstdata_o (cpu_host_data),
    .cpu_next_we_i (cpu_host_next_we),
    .cpu_next_reg_i(cpu_host_next_reg),
    .cpu_next_wdata_i(wdata_next_i),
    .cpu_next_rdata_o(cpu_host_next_rdata),
    .cpu_third_we_i(cpu_host_third_we),
    .cpu_third_reg_i(cpu_host_third_reg),
    .cpu_third_wdata_i(wdata_third_i),
    .cpu_third_rdata_o(cpu_host_third_rdata),
    .indirect_io_we_i   (host_indirect_we),
    .indirect_io_reg_i  (host_mem_host_reg),
    .indirect_io_wdata_i(host_mem_wdata_o),
    .indirect_io_rdata_o(host_mem_host_rdata),
    .local_req_o   (host_mem_req_o),
    .local_we_o    (host_mem_we_o),
    .local_addr_o  (host_mem_addr_o),
    .local_wdata_o (host_mem_wdata_o),
    .local_rdata_i (host_mem_rdata_i),
    .local_ack_i   (host_mem_ack_i)
  );

  tms34010_sync_bit #(.RESET_VALUE(1'b1)) u_lint1_sync (
    .clk     (clk),
    .rst     (rst),
    .async_i (lint1_n_i),
    .sync_o  (lint1_n_sync)
  );

  tms34010_sync_bit #(.RESET_VALUE(1'b1)) u_lint2_sync (
    .clk     (clk),
    .rst     (rst),
    .async_i (lint2_n_i),
    .sync_o  (lint2_n_sync)
  );

  always_comb begin
    // Live-register owners use the same preselected payload and final commit
    // gate as ordinary storage, avoiding commit-qualified lane payload muxes.
    refcnt_load = io_register_commit[IO_IDX_REFCNT];
    refcnt_wdata = io_register_data[IO_IDX_REFCNT];
    hcount_load = io_register_commit[IO_IDX_HCOUNT];
    hcount_wdata = io_register_data[IO_IDX_HCOUNT];
    vcount_load = io_register_commit[IO_IDX_VCOUNT];
    vcount_wdata = io_register_data[IO_IDX_VCOUNT];
    dpyadr_load = io_register_commit[IO_IDX_DPYADR];
    dpyadr_wdata = io_register_data[IO_IDX_DPYADR];
    video_config_write = 1'b0;
    processor_hstctll_set = 1'b0;
    hstctlh_written = 1'b0;
    for (int lane = 0; lane < 3; lane++) begin
      if (io_lane_commit[lane]) begin
        unique case (io_lane_idx[lane])
          IO_IDX_HSTCTLL:
            if ((lane != 0) || !io_write_from_host)
              processor_hstctll_set = io_lane_data[lane][HSTCTL_INTOUT_BIT];
          IO_IDX_HSTCTLH: hstctlh_written = 1'b1;
          default: ;
        endcase
        unique case (io_lane_idx[lane])
          IO_IDX_HESYNC, IO_IDX_HEBLNK, IO_IDX_HSBLNK, IO_IDX_HTOTAL,
          IO_IDX_VESYNC, IO_IDX_VEBLNK, IO_IDX_VSBLNK, IO_IDX_VTOTAL,
          IO_IDX_DPYINT, IO_IDX_DPYSTRT, IO_IDX_DPYCTL, IO_IDX_DPYTAP:
            video_config_write = 1'b1;
          default: ;
        endcase
      end
    end
  end

  // REFCNT is owned by the refresh block rather than mirrored in io_reg.
  // CONTROL.RR clocks its continuous interval/row counter, while a processor
  // write loads the full value. The integrated arbiter consumes
  // request/row/mode alongside the other local-cycle clients.
  tms34010_refresh u_refresh (
    .clk          (clk),
    .rst          (rst),
    .rr           (io_reg[IO_IDX_CONTROL][CTRL_RR_HI:CTRL_RR_LO]),
    .refcnt_load  (refcnt_load),
    .refcnt_wdata (refcnt_wdata),
    .refcnt       (refcnt_o),
    .refresh_row  (refresh_row_o),
    .refresh_req  (refresh_req_o)
  );

  assign refresh_cbr_o = io_reg[IO_IDX_CONTROL][CTRL_RM_BIT];
  assign pixel_srt_o = io_reg[IO_IDX_DPYCTL][DPYCTL_SRT_BIT];

  // HCOUNT/VCOUNT, all timing compares, DPYADR, and the automatic display
  // scheduler live wholly in VCLK. Configuration, live-register commands,
  // coherent status snapshots, DIP events, and screen requests each use an
  // explicit handshake in tms34010_video_subsystem.
  tms34010_video_subsystem u_video_subsystem (
    .core_clk_i       (clk),
    .core_rst_i       (rst),
    .video_clk_i      (vclk_i),
    .video_rst_i      (vclk_rst_i),
    .hsync_n_i        (video_hsync_n_i),
    .vsync_n_i        (video_vsync_n_i),
    .hesync_i         (io_reg[IO_IDX_HESYNC]),
    .heblnk_i         (io_reg[IO_IDX_HEBLNK]),
    .hsblnk_i         (io_reg[IO_IDX_HSBLNK]),
    .htotal_i         (io_reg[IO_IDX_HTOTAL]),
    .vesync_i         (io_reg[IO_IDX_VESYNC]),
    .veblnk_i         (io_reg[IO_IDX_VEBLNK]),
    .vsblnk_i         (io_reg[IO_IDX_VSBLNK]),
    .vtotal_i         (io_reg[IO_IDX_VTOTAL]),
    .dpyint_i         (io_reg[IO_IDX_DPYINT]),
    .dpystart_i       (io_reg[IO_IDX_DPYSTRT]),
    .dpyctl_i         (io_reg[IO_IDX_DPYCTL]),
    .dpytap_i         (io_reg[IO_IDX_DPYTAP]),
    .config_write_i   (video_config_write),
    .hcount_write_i   (hcount_load),
    .hcount_wdata_i   (hcount_wdata),
    .vcount_write_i   (vcount_load),
    .vcount_wdata_i   (vcount_wdata),
    .dpyadr_write_i   (dpyadr_load),
    .dpyadr_wdata_i   (dpyadr_wdata),
    .hcount_o         (hcount_o),
    .vcount_o         (vcount_o),
    .dpyadr_o         (dpyadr_o),
    .dpyint_pulse_o   (video_dpyint_pulse),
    .hsync_o          (video_hsync_o),
    .vsync_o          (video_vsync_o),
    .hblank_o         (video_hblank_o),
    .vblank_o         (video_vblank_o),
    .blank_o          (video_blank_o),
    .hsync_oe_o       (video_hsync_oe_o),
    .vsync_oe_o       (video_vsync_oe_o),
    .screen_req_o     (screen_refresh_req_o),
    .screen_ack_i     (screen_refresh_ack_i),
    .screen_srfaddr_o (screen_refresh_srfaddr_o),
    .screen_dpytap_o  (screen_refresh_dpytap_o),
    .screen_org_o     (screen_refresh_org_o)
  );

  // INTPEND is a composite view, not general storage. External requests and
  // HIP are read-only levels; only the internal DIP/WVP latches use io_reg.
  always_comb begin
    intpend_value = 16'h0000;
    intpend_value[INT_X1_BIT] = ~lint1_n_sync;
    intpend_value[INT_X2_BIT] = ~lint2_n_sync;
    intpend_value[INT_HI_BIT] =
        io_reg[IO_IDX_HSTCTLL][HSTCTL_INTIN_BIT];
    intpend_value[INT_DI_BIT] =
        io_reg[IO_IDX_INTPEND][INT_DI_BIT];
    intpend_value[INT_WV_BIT] =
        io_reg[IO_IDX_INTPEND][INT_WV_BIT];
  end

  // A fast field is sampled at its qualified bus grant. Keep its held address
  // independent of the mixed-word request selector and use the architectural
  // host storage directly, so request ownership is not a read-data selector.
  function automatic local_word_t read_field_register(
    input logic [IO_REG_IDX_W-1:0] field_idx
  );
    unique case (field_idx)
      5'h17, 5'h18, 5'h19, 5'h1A: read_field_register = '0;
      IO_IDX_INTPEND: read_field_register = intpend_value;
      IO_IDX_REFCNT: read_field_register = refcnt_o;
      IO_IDX_HCOUNT: read_field_register = hcount_o;
      IO_IDX_VCOUNT: read_field_register = vcount_o;
      IO_IDX_DPYADR: read_field_register = dpyadr_o;
      IO_IDX_HSTADRL: read_field_register = cpu_host_address[15:0];
      IO_IDX_HSTADRH: read_field_register = cpu_host_address[31:16];
      IO_IDX_HSTDATA: read_field_register = cpu_host_data;
      default: read_field_register = io_reg[field_idx];
    endcase
  endfunction

  always_comb begin
    field_rdata_o = '0;
    if (is_io) begin
      field_rdata_o[15:0] = read_field_register(idx);
      if (idx != 5'd31)
        field_rdata_o[31:16] = read_field_register(idx + 5'd1);
      if (idx < 5'd30)
        field_rdata_o[47:32] = read_field_register(idx + 5'd2);
    end
  end

  // Async read from the held request address, or 0 when it is not in I/O
  // space. The core registers that request address before this 32:1 mux.
  always_comb begin
    rdata = 16'h0000;
    if (rdata_is_io) begin
      unique case (rdata_idx)
        IO_IDX_RESERVED_17,
        IO_IDX_RESERVED_18,
        IO_IDX_RESERVED_19,
        IO_IDX_RESERVED_1A: rdata = 16'h0000;
        IO_IDX_INTPEND: rdata = intpend_value;
        IO_IDX_REFCNT:  rdata = refcnt_o;
        IO_IDX_HCOUNT:  rdata = hcount_o;
        IO_IDX_VCOUNT:  rdata = vcount_o;
        IO_IDX_DPYADR:  rdata = dpyadr_o;
        IO_IDX_HSTADRL,
        IO_IDX_HSTADRH,
        IO_IDX_HSTDATA: rdata = cpu_host_rdata;
        default:        rdata = io_reg[rdata_idx];
      endcase
    end
  end

  // A processor field may span adjacent 16-bit I/O registers (TI's
  // libraries use a 32-bit MOVE to save/restore CONVDP and PSIZE together).
  // Supply the following word in parallel so the core can apply the same
  // bit-field extraction used by the external memory sequencer.
  always_comb begin
    rdata_next = 16'h0000;
    if (rdata_is_io && (rdata_idx != IO_REG_IDX_W'(IO_REG_COUNT - 1))) begin
      unique case (rdata_idx + IO_REG_IDX_W'(1))
        IO_IDX_RESERVED_17,
        IO_IDX_RESERVED_18,
        IO_IDX_RESERVED_19,
        IO_IDX_RESERVED_1A: rdata_next = 16'h0000;
        IO_IDX_INTPEND: rdata_next = intpend_value;
        IO_IDX_REFCNT:  rdata_next = refcnt_o;
        IO_IDX_HCOUNT:  rdata_next = hcount_o;
        IO_IDX_VCOUNT:  rdata_next = vcount_o;
        IO_IDX_DPYADR:  rdata_next = dpyadr_o;
        IO_IDX_HSTADRL,
        IO_IDX_HSTADRH,
        IO_IDX_HSTDATA: rdata_next = cpu_host_next_rdata;
        default: rdata_next = io_reg[rdata_idx + IO_REG_IDX_W'(1)];
      endcase
    end
  end

  // FS+offset may cover three words (SPVU001 section 6.2). Keep this
  // extra view combinational; the core snapshots all words together.
  always_comb begin
    rdata_third = 16'h0000;
    if (rdata_is_io && (rdata_idx < IO_REG_IDX_W'(IO_REG_COUNT - 2))) begin
      unique case (rdata_idx + IO_REG_IDX_W'(2))
        IO_IDX_RESERVED_17, IO_IDX_RESERVED_18,
        IO_IDX_RESERVED_19, IO_IDX_RESERVED_1A: rdata_third = 16'h0000;
        IO_IDX_INTPEND: rdata_third = intpend_value;
        IO_IDX_REFCNT: rdata_third = refcnt_o;
        IO_IDX_HCOUNT: rdata_third = hcount_o;
        IO_IDX_VCOUNT: rdata_third = vcount_o;
        IO_IDX_DPYADR: rdata_third = dpyadr_o;
        IO_IDX_HSTADRL, IO_IDX_HSTADRH,
        IO_IDX_HSTDATA: rdata_third = cpu_host_third_rdata;
        default: rdata_third = io_reg[rdata_idx + IO_REG_IDX_W'(2)];
      endcase
    end
  end

  // Independent host-indirect read view. The selected word is carried in the
  // coherent local-cycle command and returned during the physical I/O read.
  always_comb begin
    host_mem_io_rdata_o = 16'h0000;
    if (host_mem_is_io_o) begin
      unique case (host_mem_idx)
        IO_IDX_RESERVED_17,
        IO_IDX_RESERVED_18,
        IO_IDX_RESERVED_19,
        IO_IDX_RESERVED_1A: host_mem_io_rdata_o = 16'h0000;
        IO_IDX_INTPEND: host_mem_io_rdata_o = intpend_value;
        IO_IDX_REFCNT:  host_mem_io_rdata_o = refcnt_o;
        IO_IDX_HCOUNT:  host_mem_io_rdata_o = hcount_o;
        IO_IDX_VCOUNT:  host_mem_io_rdata_o = vcount_o;
        IO_IDX_DPYADR:  host_mem_io_rdata_o = dpyadr_o;
        IO_IDX_HSTADRL,
        IO_IDX_HSTADRH,
        IO_IDX_HSTDATA: host_mem_io_rdata_o = host_mem_host_rdata;
        default:        host_mem_io_rdata_o = io_reg[host_mem_idx];
      endcase
    end
  end

  // Dedicated graphics taps.
  assign psize_o   = io_reg[IO_IDX_PSIZE];
  assign convdp_o  = io_reg[IO_IDX_CONVDP];
  assign convsp_o  = io_reg[IO_IDX_CONVSP];
  assign control_o = io_reg[IO_IDX_CONTROL];
  assign pmask_o   = io_reg[IO_IDX_PMASK];
  assign intenb_o  = io_reg[IO_IDX_INTENB];
  assign intpend_o = intpend_value;
  assign hstctlh_o = io_reg[IO_IDX_HSTCTLH];
  assign host_ctl_rdata = {
    io_reg[IO_IDX_HSTCTLH][15:8],
    io_reg[IO_IDX_HSTCTLL][7:0]
  };
  assign hint_n_o = ~io_reg[IO_IDX_HSTCTLL][HSTCTL_INTOUT_BIT];
  assign hlt_o    = io_reg[IO_IDX_HSTCTLH][HSTCTL_HLT_BIT];

  // Synchronous write + reset. The reset loop is bounded (32 iterations) and
  // fully unrollable, so synthesis treats it as parallel resets.
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < IO_REG_COUNT; i++) begin
        io_reg[i] <= 16'h0;
      end
      // HCS is active low: low selects self-bootstrap/run; high selects the
      // host-present state in which vector fetch waits for a host HLT clear.
      io_reg[IO_IDX_HSTCTLH][HSTCTL_HLT_BIT] <= hcs_n_i;
    end else begin
      // Keep array indices unsigned and untruncated for registers 16..31.
      for (int unsigned write_reg = 0; write_reg < IO_REG_COUNT; write_reg++) begin
        if (io_register_commit[write_reg]) begin
          unique case (IO_REG_IDX_W'(write_reg))
            IO_IDX_CONTROL: begin
              // Bits 1:0 are reserved/not used.
              io_reg[IO_IDX_CONTROL] <=
                  io_register_data[write_reg] & CONTROL_WRITABLE_MASK;
            end

            IO_IDX_DPYCTL: begin
              // Bit 1 is reserved.
              io_reg[IO_IDX_DPYCTL] <=
                  io_register_data[write_reg] & DPYCTL_WRITABLE_MASK;
            end

            IO_IDX_INTENB: begin
              // Reserved bits read zero and cannot create interrupt sources.
              io_reg[IO_IDX_INTENB] <= io_register_data[write_reg] & INT_SOURCE_MASK;
            end

            IO_IDX_INTPEND: begin
              // DIP/WVP are cleared only by writing zero. Writing one retains
              // the old latch; X1P/X2P/HIP and reserved bits are read-only.
              io_reg[IO_IDX_INTPEND][INT_DI_BIT] <=
                  io_reg[IO_IDX_INTPEND][INT_DI_BIT]
                  & io_register_data[write_reg][INT_DI_BIT];
              io_reg[IO_IDX_INTPEND][INT_WV_BIT] <=
                  io_reg[IO_IDX_INTPEND][INT_WV_BIT]
                  & io_register_data[write_reg][INT_WV_BIT];
            end

            IO_IDX_HSTCTLL: begin
              // Local memory writes (including indirect HSTDATA writes) use
              // processor-side semantics. Only a direct HSTCTL host access,
              // handled below, uses complementary host ownership. MAME
              // host_w(HOST_DATA) deliberately leaves external_host_access clear.
              // Stone Ball's unmodified boot checks this by writing 0080 to
              // C00000F0 through HSTDATA and polling INTOUT/HINT.
              io_reg[IO_IDX_HSTCTLL][HSTCTL_INTIN_BIT] <=
                  io_reg[IO_IDX_HSTCTLL][HSTCTL_INTIN_BIT]
                  & io_register_data[write_reg][HSTCTL_INTIN_BIT];
              io_reg[IO_IDX_HSTCTLL][6:4] <= io_register_data[write_reg][6:4];
              io_reg[IO_IDX_HSTCTLL][HSTCTL_INTOUT_BIT] <=
                  io_reg[IO_IDX_HSTCTLL][HSTCTL_INTOUT_BIT]
                  | io_register_data[write_reg][HSTCTL_INTOUT_BIT];
            end

            IO_IDX_HSTCTLH: begin
              // Both sides may write all seven defined high-byte fields.
              // Reserved bits 10 and 7:0 always remain zero.
              io_reg[IO_IDX_HSTCTLH] <=
                  io_register_data[write_reg] & HSTCTLH_WRITABLE_MASK;
            end

            IO_IDX_HSTADRL, IO_IDX_HSTADRH, IO_IDX_HSTDATA: begin
              // tms34010_host_if owns these registers. Its completed-access
              // inputs consume processor or host-indirect words without
              // recursively launching another indirect cycle.
            end

            IO_IDX_REFCNT: begin
              // The refresh submodule owns the live counter. Its parallel-load
              // port consumes this write, so no mirror storage is updated.
            end

            IO_IDX_DPYTAP: begin
              // Bits 14-15 are reserved/not used by the display address path.
              io_reg[IO_IDX_DPYTAP] <= io_register_data[write_reg] & DPYTAP_MASK;
            end

            IO_IDX_RESERVED_17,
            IO_IDX_RESERVED_18,
            IO_IDX_RESERVED_19,
            IO_IDX_RESERVED_1A: begin
              // Figure 6-1 reserves these locations. The PMASK description
              // explicitly says the compatibility write at 17h has no effect.
            end

            IO_IDX_HCOUNT, IO_IDX_VCOUNT, IO_IDX_DPYADR: begin
              // Video/display submodules own these live registers. Their load
              // ports consume completed I/O writes, so no mirror is updated.
            end

            default: io_reg[write_reg] <= io_register_data[write_reg];
          endcase
        end

      end

      // Direct host writes obey the complementary HSTCTL ownership table.
      // Host owns MSGIN, may set INTIN with one, and may clear INTOUT with
      // zero. MSGOUT remains processor-owned.
      if (host_ctl_we && host_ctl_be[0]) begin
        io_reg[IO_IDX_HSTCTLL][2:0] <= host_ctl_wdata[2:0];
        if (host_ctl_wdata[HSTCTL_INTIN_BIT])
          io_reg[IO_IDX_HSTCTLL][HSTCTL_INTIN_BIT] <= 1'b1;
        if (!host_ctl_wdata[HSTCTL_INTOUT_BIT])
          io_reg[IO_IDX_HSTCTLL][HSTCTL_INTOUT_BIT] <= 1'b0;
      end

      // Conflicting simultaneous HSTCTLH writes are unpredictable on the
      // original device. This synchronous boundary chooses host priority.
      if (host_ctl_we && host_ctl_be[1])
        io_reg[IO_IDX_HSTCTLH] <=
            host_ctl_wdata & HSTCTLH_WRITABLE_MASK;

      // Internal set pulses are independent of an unrelated processor write.
      // A set after a same-cycle write-zero clear wins, preventing an
      // interrupt event from being lost at the register boundary.
      if (dpyint_set || video_dpyint_pulse)
        io_reg[IO_IDX_INTPEND][INT_DI_BIT] <= 1'b1;
      if (wvp_set)
        io_reg[IO_IDX_INTPEND][INT_WV_BIT] <= 1'b1;

      // The HSTCTLL arbitration guarantees hazard-free simultaneous access.
      // Producer-side sets win consumer-side clears for both interrupt bits.
      if (processor_hstctll_set)
        io_reg[IO_IDX_HSTCTLL][HSTCTL_INTOUT_BIT] <= 1'b1;

      // A same-cycle host or processor high-byte write wins over the
      // automatic NMI clear.
      if (nmi_clear
          && !hstctlh_written
          && !(host_ctl_we && host_ctl_be[1]))
        io_reg[IO_IDX_HSTCTLH][HSTCTL_NMI_BIT] <= 1'b0;
    end
  end

endmodule : tms34010_io_regs

`default_nettype wire
