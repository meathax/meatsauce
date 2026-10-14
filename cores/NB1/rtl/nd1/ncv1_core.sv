//------------------------------------------------------------------------------
// Namco ND-1 (Namco Classic Collection Vol.1): the machine, memory-port style.
// Everything platform-specific (SDRAM, bridge, video/audio hand-off) lives in
// target/pocket; this module only knows the docs/rtl-conventions.md request/ack
// ports for the four ROM regions and the EEPROM load/save ports.
//------------------------------------------------------------------------------
`default_nettype none

module ncv1_core #(
    parameter HEXDIR = "rtl/data"      // where the generated tables live (c352_mulaw.hex)
) (
    input  logic        clk,            // 96 MHz
    input  logic        reset,
    input  logic        pix_sync,       // see clk_enables

    // ROM ports (word addresses; big-endian words)
    output logic [19:1] prog_addr,  output logic prog_req,  input logic prog_ack,  input logic [15:0] prog_q,    // 68000 program, 1 MB
    output logic [18:1] sub_addr,   output logic sub_req,   input logic sub_ack,   input logic [15:0] sub_q,     // H8 program, 512 KB
    output logic [20:0] pat_addr,   output logic pat_req,   input logic pat_ack,   input logic [31:0] pat_q,     // pattern ROM, 32-bit units (8 MB space)
    output logic  [6:0] pat_len,    input  logic pat_wr,    input logic  [5:0] pat_idx,                         // burst: units, per-unit strobe and index
    output logic [23:0] pcm_addr,   output logic pcm_req,   input logic pcm_ack,   input logic  [7:0] pcm_q,     // C352 samples, bytes

    // EEPROM load (during reset) and read-out
    input  logic        eep_ld_we,
    input  logic [10:0] eep_ld_addr,
    input  logic  [7:0] eep_ld_data,
    input  logic [10:0] eep_rd_addr,
    output logic  [7:0] eep_rd_q,
    output logic        eep_dirty,

    // MiSTer port (not in the donor): high-score access to the shared RAM, arbitrated
    // onto its H8 side (level request / one-cycle ack; the H8 waits meanwhile)
    input  logic [15:1] hs_addr,
    input  logic        hs_req,
    input  logic  [1:0] hs_we,
    input  logic [15:0] hs_wdata,
    output logic [15:0] hs_q,
    output logic        hs_ack,

    // inputs (active low, as the board's ports)
    input  logic [15:0] dsw,
    input  logic [15:0] p1p2,
    input  logic        screen_flip,    // MiSTer: 180-degree raster flip (ygv608)

    // video (unrotated 288x224 at cen_pix)
    output logic        cen_pix,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic [23:0] rgb,

    // audio (front L/R, held per sample)
    output logic signed [15:0] snd_l,
    output logic signed [15:0] snd_r,
    output logic        snd_valid,

    // diagnostics
    output logic        dbg_68k_halted,
    output logic [23:1] dbg_68k_addr,
    output logic        dbg_h8_run,
    output logic [23:0] dbg_h8_pc,
    output logic        dbg_h8_istart,
    output logic        dbg_h8_irq,
    output logic        dbg_video_unsupported,
    output logic  [3:0] dbg_video_unsup_src,
    output logic  [1:0] dbg_gfxbank,
    output logic        dbg_c352_overrun
);
    // ------------------------------------------------------------ clocks
    logic cen_phi1, cen_phi2, cen_h8, cen_c352;
    clk_enables u_cen (.clk(clk), .reset(reset), .pix_sync(pix_sync), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_h8(cen_h8), .cen_pix(cen_pix), .cen_c352(cen_c352));

    // ------------------------------------------------------------ 68000 side
    logic [19:1] m_rom_addr; logic m_rom_req, m_rom_ack; logic [15:0] m_rom_q;
    logic [15:1] a_sh_addr;  logic a_sh_req, a_sh_ack; logic [1:0] a_sh_we; logic [15:0] a_sh_wdata, a_sh_q;
    logic  [2:0] ygv_port;   logic ygv_wr, ygv_rd; logic [7:0] ygv_wdata, ygv_q;
    logic        irq_vblank, irq_raster;
    logic [10:0] eep_addr;   logic eep_req, eep_we, eep_ack; logic [7:0] eep_wdata, eep_q;
    logic        h8_run;
    logic  [1:0] gfxbank;

    ncv1_main u_main (
        .clk(clk), .reset(reset), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .rom_addr(m_rom_addr), .rom_req(m_rom_req), .rom_q(m_rom_q), .rom_ack(m_rom_ack),
        .sh_addr(a_sh_addr), .sh_req(a_sh_req), .sh_we(a_sh_we), .sh_wdata(a_sh_wdata), .sh_q(a_sh_q), .sh_ack(a_sh_ack),
        .ygv_port(ygv_port), .ygv_wr(ygv_wr), .ygv_rd(ygv_rd), .ygv_wdata(ygv_wdata), .ygv_q(ygv_q),
        .irq_vblank(irq_vblank), .irq_raster(irq_raster),
        .eep_addr(eep_addr), .eep_req(eep_req), .eep_we(eep_we), .eep_wdata(eep_wdata), .eep_q(eep_q), .eep_ack(eep_ack),
        .h8_run(h8_run), .gfxbank(gfxbank),
        .dbg_halted(dbg_68k_halted), .dbg_addr(dbg_68k_addr)
    );
    assign dbg_h8_run = h8_run;
    assign dbg_gfxbank = gfxbank;

    rom_cache #(.IDX_BITS(11), .ADDR_HI(19)) u_mcache (
        .clk(clk), .reset(reset),
        .cpu_addr(m_rom_addr), .cpu_req(m_rom_req), .cpu_q(m_rom_q), .cpu_ack(m_rom_ack),
        .rom_addr(prog_addr), .rom_req(prog_req), .rom_q(prog_q), .rom_ack(prog_ack)
    );

    // ------------------------------------------------------------ H8 side
    logic [18:1] s_rom_addr; logic s_rom_req, s_rom_ack; logic [15:0] s_rom_q;
    logic [15:1] b_sh_addr;  logic b_sh_req, b_sh_ack; logic [1:0] b_sh_we; logic [15:0] b_sh_wdata, b_sh_q;
    logic        c352_wr, c352_rd; logic [9:0] c352_addr; logic [15:0] c352_wdata, c352_q;
    // Registered: it fans out across the H8. Asserted at once and held for thousands of
    // clocks; released on an H8 enable, so every register of the enable-only core sees the
    // release before its next enable, 5-6 clocks on (the multicycle in ncv1_pocket.sdc).
    logic        h8_reset;
    always_ff @(posedge clk) begin
        if (reset | ~h8_run) h8_reset <= 1'b1;
        else if (cen_h8)     h8_reset <= 1'b0;
    end

    // the H8 sees the vblank as IRQ5 while the cuskey enables it (MAME: pulse per vblank when enabled)
    logic vb_d;
    always_ff @(posedge clk) vb_d <= vblank;
    logic irq5_n;
    always_ff @(posedge clk) begin
        if (reset) irq5_n <= 1'b1;
        else if (vblank && !vb_d) irq5_n <= 1'b0;       // falling edge at vblank start
        else if (!vblank) irq5_n <= 1'b1;
    end

    logic [23:0] h8_bus_addr; logic h8_bus_rd, h8_bus_wr, h8_bus_word, h8_bus_ack; logic [15:0] h8_bus_wdata, h8_bus_rdata;
    logic dbg_h8_npc_unused_v; logic [23:0] dbg_h8_npc;
    ncv1_sub u_sub (
        .clk(clk), .reset(h8_reset), .cen_h8(cen_h8),
        .rom_addr(s_rom_addr), .rom_req(s_rom_req), .rom_q(s_rom_q), .rom_ack(s_rom_ack),
        .sh_addr(b_sh_addr), .sh_req(b_sh_req), .sh_we(b_sh_we), .sh_wdata(b_sh_wdata), .sh_q(b_sh_q), .sh_ack(b_sh_ack),
        .c352_wr(c352_wr), .c352_rd(c352_rd), .c352_addr(c352_addr), .c352_wdata(c352_wdata), .c352_q(c352_q),
        .dsw(dsw), .p1p2(p1p2), .irq5_n(irq5_n),
        .dbg_istart(dbg_h8_istart), .dbg_pc(dbg_h8_pc), .dbg_irq(dbg_h8_irq), .dbg_npc(dbg_h8_npc), .dbg_sleep(dbg_h8_npc_unused_v),
        .dbg_bus_addr(h8_bus_addr), .dbg_bus_rd(h8_bus_rd), .dbg_bus_wr(h8_bus_wr), .dbg_bus_word(h8_bus_word),
        .dbg_bus_wdata(h8_bus_wdata), .dbg_bus_rdata(h8_bus_rdata), .dbg_bus_ack(h8_bus_ack)
    );
    wire _unused_dbg = &{1'b0, dbg_h8_npc, dbg_h8_npc_unused_v, h8_bus_addr, h8_bus_rd, h8_bus_wr, h8_bus_word, h8_bus_wdata, h8_bus_rdata, h8_bus_ack};

    rom_cache #(.IDX_BITS(11), .ADDR_HI(18)) u_scache (
        .clk(clk), .reset(reset),
        .cpu_addr(s_rom_addr), .cpu_req(s_rom_req), .cpu_q(s_rom_q), .cpu_ack(s_rom_ack),
        .rom_addr(sub_addr), .rom_req(sub_req), .rom_q(sub_q), .rom_ack(sub_ack)
    );

    // ------------------------------------------------------------ shared RAM and EEPROM
    logic [15:1] pb_addr; logic pb_req, pb_ack; logic [1:0] pb_we; logic [15:0] pb_wdata, pb_q;
    shared_ram u_shared (
        .clk(clk), .reset(reset),
        .a_addr(a_sh_addr), .a_req(a_sh_req), .a_we(a_sh_we), .a_wdata(a_sh_wdata), .a_q(a_sh_q), .a_ack(a_sh_ack),
        .b_addr(pb_addr), .b_req(pb_req), .b_we(pb_we), .b_wdata(pb_wdata), .b_q(pb_q), .b_ack(pb_ack)
    );
    // port B shared with the MiSTer high-score unit (sh_port_arb.sv)
    sh_port_arb u_arb (
        .clk(clk), .reset(reset),
        .h8_addr(b_sh_addr), .h8_req(b_sh_req), .h8_we(b_sh_we), .h8_wdata(b_sh_wdata), .h8_q(b_sh_q), .h8_ack(b_sh_ack),
        .hs_addr(hs_addr), .hs_req(hs_req), .hs_we(hs_we), .hs_wdata(hs_wdata), .hs_q(hs_q), .hs_ack(hs_ack),
        .pb_addr(pb_addr), .pb_req(pb_req), .pb_we(pb_we), .pb_wdata(pb_wdata), .pb_q(pb_q), .pb_ack(pb_ack)
    );
    at28c16 #(.HEXDIR(HEXDIR)) u_eeprom (
        .clk(clk), .reset(reset),
        .addr(eep_addr), .req(eep_req), .we(eep_we), .wdata(eep_wdata), .q(eep_q), .ack(eep_ack),
        .ld_we(eep_ld_we), .ld_addr(eep_ld_addr), .ld_data(eep_ld_data),
        .rd_addr(eep_rd_addr), .rd_q(eep_rd_q), .dirty(eep_dirty)
    );

    // ------------------------------------------------------------ video
    logic [7:0] vr, vg, vb;
    ygv608 u_vdp (
        .clk(clk), .reset(reset), .cen_pix(cen_pix),
        .port_sel(ygv_port), .port_wr(ygv_wr), .port_rd(ygv_rd), .port_wdata(ygv_wdata), .port_q(ygv_q),
        .gfxbank(gfxbank), .screen_flip(screen_flip),
        .pat_req(pat_req), .pat_addr(pat_addr), .pat_len(pat_len), .pat_wr(pat_wr), .pat_idx(pat_idx),
        .pat_ack(pat_ack), .pat_q(pat_q),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .r(vr), .g(vg), .b(vb),
        .irq_vblank(irq_vblank), .irq_raster(irq_raster),
        .unsupported(dbg_video_unsupported), .unsup_src(dbg_video_unsup_src)
    );
    assign rgb = {vr, vg, vb};

    // ------------------------------------------------------------ sound
    c352 #(.HEXDIR(HEXDIR)) u_pcm (
        .clk(clk), .reset(reset), .cen_sample(cen_c352),
        .reg_wr(c352_wr), .reg_rd(c352_rd), .reg_addr(c352_addr), .reg_wdata(c352_wdata), .reg_q(c352_q),
        .rom_req(pcm_req), .rom_addr(pcm_addr), .rom_ack(pcm_ack), .rom_q(pcm_q),
        .out_l(snd_l), .out_r(snd_r), .sample_valid(snd_valid), .dbg_overrun(dbg_c352_overrun)
    );
endmodule
