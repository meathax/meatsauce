//============================================================================
//  System 32 palette RAM — one bank (0x4000 x 16), format aliasing per
//  DESIGN.md §6.7:
//    CPU A14=0: xBBBBBGGGGGRRRRR (native storage)
//    CPU A14=1: xBGRBBBBGGGGRRRR (converted on the fly both directions)
//  Mixer blend-pair mirror write when mixer reg 0x4E & 0x0880.
//============================================================================

module s32_palette (
    input             clk,          // CPU write/read clock (clk_sys)
    input             mix_clk,      // mixer read clock (clk_ram)

    // CPU port
    input             cpu_we,
    input      [14:0] cpu_addr,     // word address incl. A14 alias bit
    input      [15:0] cpu_wdata,
    input       [1:0] cpu_be,
    output     [15:0] cpu_rdata,
    input      [15:0] mixer_r4e,    // write-both control

    // mixer read port
    input      [13:0] mix_addr,
    output     [15:0] mix_data
);

wire conv = cpu_addr[14];
wire [13:0] a = cpu_addr[13:0];

// xBBBBBGGGGGRRRRR <-> xBGRBBBBGGGGRRRR
function automatic [15:0] to_alt(input [15:0] v);
    // v = x BBBBB GGGGG RRRRR
    // Alternate format promotes each channel's bit 0, not bit 4:
    //   x B0 G0 R0 B4-1 G4-1 R4-1
    to_alt = {v[15], v[10], v[5], v[0],
              v[14:11], v[9:6], v[4:1]};
endfunction
function automatic [15:0] from_alt(input [15:0] v);
    // v = x B G R BBBB GGGG RRRR
    from_alt = {v[15], v[11:8], v[14],
                v[7:4], v[13],
                v[3:0], v[12]};
endfunction

wire [15:0] rd_native;
assign cpu_rdata = conv ? to_alt(rd_native) : rd_native;

wire write_both = |(mixer_r4e & 16'h0880);

// Palette addresses 0x0000 and 0x2000 form the pair affected by the
// hardware write-both control.  Store that address bit as two physical RAM
// banks and keep each colour bit in an independently write-enabled bitplane.
// This has two important properties for Cyclone V synthesis:
//   * every bitplane is a conventional 8K x 1 simple-dual-port RAM
//     (CPU read/write + mixer read), so Quartus can map it to M10Ks;
//   * converted-view byte writes become a permuted per-bit write enable,
//     avoiding the 16K-word asynchronous read/modify/write that made Quartus
//     flatten the palette and exhaust host memory.
//
// A write-both access performs the same masked write independently in each
// half. Disabled bits therefore remain from each half's own old word (MAME
// paletteram_w), rather than being copied from the source half. Both physical
// banks sample the addressed row during the source edge, so the pending edge
// can merge enabled bits with the partner bank's registered old data without
// an asynchronous RAM read.
wire [15:0] cpu_lane_mask = {{8{cpu_be[1]}}, {8{cpu_be[0]}}};
wire [15:0] wr_mask       = conv ? from_alt(cpu_lane_mask) : cpu_lane_mask;
wire [15:0] wr_native     = conv ? from_alt(cpu_wdata)     : cpu_wdata;
wire [12:0] cpu_row       = a[12:0];
wire [12:0] mix_row       = mix_addr[12:0];
reg         mix_bank_q;
initial mix_bank_q = 1'b0;

// Port B is synchronous to the mixer.  Register the physical-bank selector
// on the same edge as the RAM row address so all fourteen address bits refer
// to the same lookup.  The previous implementation clocked the RAM address at
// clk_sys while driving it from clk_ram and selected the bank combinationally;
// that unchecked multi-bit crossing produced stable pixels from wrong palette
// entries on hardware even though single-clock simulation passed.
always @(posedge mix_clk)
    mix_bank_q <= mix_addr[13];

reg         pend_we;
reg         pend_bank;
reg  [12:0] pend_row;
reg  [15:0] pend_mask;
reg  [15:0] pend_native;

initial pend_we = 1'b0;

// As in the original implementation, a new CPU write has priority over an
// outstanding partner copy.  The core bus provides an idle clock after a
// write, so the pending copy normally commits on the immediately next edge.
always @(posedge clk) begin
    pend_we <= 1'b0;
    if (cpu_we && write_both) begin
        pend_we     <= 1'b1;
        pend_bank   <= ~a[13];
        pend_row    <= cpu_row;
        pend_mask   <= wr_mask;
        pend_native <= wr_native;
    end
end

`ifdef SIMULATION
// The write-both mirror copy commits on the cycle after each CPU write, which
// the core bus guarantees by leaving an idle clock.  If a second write-both
// arrived before the copy committed, the mirror write would be silently lost.
// Flag it so a future second bus master (or a pipelined bus change) is caught
// rather than corrupting the palette (audit R20 CG-1).
//
// The core bus holds cpu_we (m_req level) high for several clk_sys edges per
// write, so qualify on the RISING edge of cpu_we: a genuine dropped copy is a
// NEW write-both transaction landing while a prior pend copy is outstanding,
// not the same held write re-sampled (audit R24 — that self-triggered every
// alias/blend write and masked any real drop).
reg cpu_we_d;
initial cpu_we_d = 1'b0;
always @(posedge clk) cpu_we_d <= cpu_we;
always @(posedge clk)
    if (pend_we && cpu_we && !cpu_we_d && write_both)
        $display("WARNING s32_palette: write-both pend copy dropped by a back-to-back write @ %0t", $time);
`endif

`ifdef SIMULATION
// Stable simulation-only observation API for full-core benches.  Keeping a
// native-format shadow avoids coupling tests to the RAM implementation (or to
// generated bitplane hierarchy) and is completely absent from synthesis.
reg [15:0] sim_shadow [0:16383];
integer sim_init;
integer sim_bit;
initial begin
    for (sim_init = 0; sim_init < 16384; sim_init = sim_init + 1)
        sim_shadow[sim_init] = 16'h0000;
end

always @(posedge clk) begin
    if (cpu_we) begin
        for (sim_bit = 0; sim_bit < 16; sim_bit = sim_bit + 1)
            if (wr_mask[sim_bit])
                sim_shadow[a][sim_bit] <= wr_native[sim_bit];
    end
    else if (pend_we) begin
        sim_shadow[{pend_bank, pend_row}] <=
            (sim_shadow[{pend_bank, pend_row}] & ~pend_mask) |
            (pend_native & pend_mask);
    end
end

function automatic [15:0] sim_peek(input [13:0] addr);
    sim_peek = sim_shadow[addr];
endfunction
`endif

genvar pal_bit;
generate
    for (pal_bit = 0; pal_bit < 16; pal_bit = pal_bit + 1) begin : g_pal_bit
        wire bank0_cpu_q;
        wire bank1_cpu_q;
        wire bank0_mix_q;
        wire bank1_mix_q;
        wire copy_cycle = pend_we && !cpu_we;
        wire bank0_copy = copy_cycle && !pend_bank;
        wire bank1_copy = copy_cycle &&  pend_bank;
        wire [12:0] bank0_addr = bank0_copy ? pend_row : cpu_row;
        wire [12:0] bank1_addr = bank1_copy ? pend_row : cpu_row;
        wire bank0_we = (cpu_we && !a[13] && wr_mask[pal_bit]) || bank0_copy;
        wire bank1_we = (cpu_we &&  a[13] && wr_mask[pal_bit]) || bank1_copy;

        // During the pending clock each bank's registered read contains its
        // own pre-write bit captured on the source edge.
        wire bank0_d = bank0_copy
                     ? (pend_mask[pal_bit] ? pend_native[pal_bit]
                                           : bank0_cpu_q)
                     : wr_native[pal_bit];
        wire bank1_d = bank1_copy
                     ? (pend_mask[pal_bit] ? pend_native[pal_bit]
                                           : bank1_cpu_q)
                     : wr_native[pal_bit];

        s32_palette_plane_ram bank0 (
            .clk(clk), .mix_clk(mix_clk),
            .addr_a(bank0_addr), .data_a(bank0_d),
            .wren_a(bank0_we), .q_a(bank0_cpu_q),
            .addr_b(mix_row), .q_b(bank0_mix_q)
        );
        s32_palette_plane_ram bank1 (
            .clk(clk), .mix_clk(mix_clk),
            .addr_a(bank1_addr), .data_a(bank1_d),
            .wren_a(bank1_we), .q_a(bank1_cpu_q),
            .addr_b(mix_row), .q_b(bank1_mix_q)
        );

        assign rd_native[pal_bit] = a[13] ? bank1_cpu_q : bank0_cpu_q;
        assign mix_data[pal_bit] = mix_bank_q ? bank1_mix_q : bank0_mix_q;
    end
endgenerate

endmodule

// Explicit Cyclone V primitive during Quartus integrated synthesis avoids a
// costly inference/elaboration pass over 262,144 individual palette bits.
// The behavioural branch has identical registered, old-data read timing and
// keeps normal RTL simulation independent of Intel simulation libraries.
module s32_palette_plane_ram (
    input         clk,
    input         mix_clk,
    input  [12:0] addr_a,
    input         data_a,
    input         wren_a,
    output        q_a,
    input  [12:0] addr_b,
    output        q_b
);

`ifdef ALTERA_RESERVED_QIS
altsyncram ram (
    .clock0(clk),
    .address_a(addr_a),
    .data_a(data_a),
    .wren_a(wren_a),
    .q_a(q_a),

    .clock1(mix_clk),
    .address_b(addr_b),
    .data_b(1'b0),
    .wren_b(1'b0),
    .q_b(q_b),

    .aclr0(1'b0),
    .aclr1(1'b0),
    .addressstall_a(1'b0),
    .addressstall_b(1'b0),
    .byteena_a(1'b1),
    .byteena_b(1'b1),
    .clocken0(1'b1),
    .clocken1(1'b1),
    .clocken2(1'b1),
    .clocken3(1'b1),
    .eccstatus(),
    .rden_a(1'b1),
    .rden_b(1'b1)
);
defparam
    ram.numwords_a = 8192,
    ram.widthad_a = 13,
    ram.width_a = 1,
    ram.numwords_b = 8192,
    ram.widthad_b = 13,
    ram.width_b = 1,
    ram.address_reg_b = "CLOCK1",
    ram.clock_enable_input_a = "BYPASS",
    ram.clock_enable_input_b = "BYPASS",
    ram.clock_enable_output_a = "BYPASS",
    ram.clock_enable_output_b = "BYPASS",
    ram.indata_reg_b = "CLOCK1",
    ram.intended_device_family = "Cyclone V",
    ram.lpm_type = "altsyncram",
    ram.operation_mode = "BIDIR_DUAL_PORT",
    ram.outdata_aclr_a = "NONE",
    ram.outdata_aclr_b = "NONE",
    ram.outdata_reg_a = "UNREGISTERED",
    ram.outdata_reg_b = "UNREGISTERED",
    ram.power_up_uninitialized = "FALSE",
    // Cyclone V cannot promise old/new ordering when the CPU and mixer ports
    // collide under different clocks.  Games do not rely on the one-pixel
    // collision value; DONT_CARE is the supported dual-clock M10K mode and
    // all non-colliding registered reads remain deterministic.
    ram.read_during_write_mode_mixed_ports = "DONT_CARE",
    // Cyclone V M10Ks use NEW_DATA for a bidirectional port.  This is safe
    // here: written planes take pend_native, while untouched planes have
    // wren_a low and therefore still capture the old source bit.
    ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    ram.width_byteena_a = 1,
    ram.width_byteena_b = 1,
    ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`else
reg mem [0:8191];
reg q_a_r;
reg q_b_r;
assign q_a = q_a_r;
assign q_b = q_b_r;

integer __i_mem;
initial begin
    for (__i_mem = 0; __i_mem < 8192; __i_mem = __i_mem + 1)
        mem[__i_mem] = 1'b0;
end

always @(posedge clk) begin
    q_a_r <= mem[addr_a];
    if (wren_a)
        mem[addr_a] <= data_a;
end

always @(posedge mix_clk)
    q_b_r <= mem[addr_b];
`endif

endmodule
