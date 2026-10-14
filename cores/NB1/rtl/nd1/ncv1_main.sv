//------------------------------------------------------------------------------
// ND-1 main CPU side: fx68k and the 68000 address decode (docs/hardware.md §2).
//   000000-0FFFFF  program ROM           -> rom port (through the cache)
//   400000-40FFFF  shared RAM            -> shared RAM port A
//   800000-80000F  YGV608 ports          -> upper byte, port = A[3:1]
//   A00000-A00FFF  AT28C16 EEPROM        -> upper byte
//   C3FF00-C3FFFF  cuskus (KC001)        -> +0A releases the H8 / enables its IRQ5, +0C gfx bank
// Interrupts: YGV608 vblank = IPL1, raster = IPL2, autovectored.
//------------------------------------------------------------------------------
`default_nettype none

module ncv1_main (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_phi1,
    input  logic        cen_phi2,

    output logic [19:1] rom_addr,
    output logic        rom_req,
    input  logic [15:0] rom_q,
    input  logic        rom_ack,          // level while the request stands

    output logic [15:1] sh_addr,
    output logic        sh_req,
    output logic  [1:0] sh_we,
    output logic [15:0] sh_wdata,
    input  logic [15:0] sh_q,
    input  logic        sh_ack,           // one-clock pulse

    output logic  [2:0] ygv_port,
    output logic        ygv_wr,           // one-clock pulses
    output logic        ygv_rd,
    output logic  [7:0] ygv_wdata,
    input  logic  [7:0] ygv_q,            // valid from the clock after ygv_rd
    input  logic        irq_vblank,
    input  logic        irq_raster,

    output logic [10:0] eep_addr,
    output logic        eep_req,
    output logic        eep_we,
    output logic  [7:0] eep_wdata,
    input  logic  [7:0] eep_q,
    input  logic        eep_ack,          // one-clock pulse

    output logic        h8_run,           // cuskey +0A non-zero: H8 out of reset, IRQ5 enabled
    output logic  [1:0] gfxbank,

    output logic        dbg_halted,
    output logic [23:1] dbg_addr
);
    // ------------------------------------------------------------ CPU
    logic [23:1] cpu_addr;
    logic [15:0] cpu_dout, cpu_din;
    logic        as_n, uds_n, lds_n, rw_n, dtack_n, vpa_n;
    logic        fc0, fc1, fc2;
    logic        ipl0_n, ipl1_n, ipl2_n;
    logic        cpu_haltedn;
    logic        e_unused, vma_unused, bg_unused, rst_unused;
    wire _unused = &{1'b0, e_unused, vma_unused, bg_unused, rst_unused};

    fx68k cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(reset), .pwrUp(reset),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
        .E(e_unused), .VMAn(vma_unused),
        .FC0(fc0), .FC1(fc1), .FC2(fc2),
        .BGn(bg_unused), .oRESETn(rst_unused),
        .DTACKn(dtack_n), .VPAn(vpa_n), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(ipl0_n), .IPL1n(ipl1_n), .IPL2n(ipl2_n),
        .iEdb(cpu_din), .oEdb(cpu_dout), .eab(cpu_addr),
        .oHALTEDn(cpu_haltedn)
    );
    assign dbg_halted = ~cpu_haltedn;
    assign dbg_addr   = cpu_addr;

    // interrupts: level 2 raster, level 1 vblank; autovectored
    wire [2:0] ipl = irq_raster ? 3'd2 : irq_vblank ? 3'd1 : 3'd0;
    assign {ipl2_n, ipl1_n, ipl0_n} = ~ipl;
    wire iack = fc0 & fc1 & fc2 & ~as_n;
    assign vpa_n = ~iack;

    // ------------------------------------------------------------ decode
    wire bus_cycle = ~as_n & (~uds_n | ~lds_n) & ~iack;
    wire wr        = ~rw_n;
    wire sel_rom = bus_cycle & (cpu_addr[23:20] == 4'h0);
    wire sel_sh  = bus_cycle & (cpu_addr[23:16] == 8'h40);
    wire sel_ygv = bus_cycle & (cpu_addr[23:4]  == 20'h80000);
    wire sel_eep = bus_cycle & (cpu_addr[23:12] == 12'ha00);
    wire sel_cus = bus_cycle & (cpu_addr[23:8]  == 16'hc3ff);
    wire sel_oth = bus_cycle & ~(sel_rom | sel_sh | sel_ygv | sel_eep | sel_cus);

    // per-cycle bookkeeping: `started` on the first clock, `done` once the device answered
    logic started, done;
    logic [15:0] din_r;
    wire  first = bus_cycle & ~started;
    always_ff @(posedge clk) begin
        if (reset) begin started <= 1'b0; done <= 1'b0; din_r <= 16'd0; h8_run <= 1'b0; gfxbank <= 2'd0; end
        else begin
            if (!bus_cycle) begin started <= 1'b0; done <= 1'b0; end
            else started <= 1'b1;
            // completions
            if (sel_rom && rom_ack) begin done <= 1'b1; din_r <= rom_q; end
            if (sel_sh && sh_ack)   begin done <= 1'b1; din_r <= sh_q; end
            if (sel_eep && eep_ack) begin done <= 1'b1; din_r <= {eep_q, 8'h00}; end
            if (sel_ygv && ygv_d2)  begin done <= 1'b1; din_r <= {ygv_q, 8'h00}; end
            if ((sel_cus || sel_oth) && started) begin done <= 1'b1; din_r <= 16'h0000; end
            // cuskey writes
            if (sel_cus && first && wr) begin
                if (cpu_addr[7:1] == 7'h05) h8_run  <= (cpu_dout != 16'h0000);   // +0A
                if (cpu_addr[7:1] == 7'h06) gfxbank <= cpu_dout[1:0];             // +0C
            end
        end
    end
    assign dtack_n = ~done;
    assign cpu_din = din_r;

    // ROM: word reads only (the 68000 fetches words; byte reads return the word, the CPU takes its lane)
    assign rom_addr = cpu_addr[19:1];
    assign rom_req  = sel_rom & ~done & ~wr;

    // shared RAM
    assign sh_addr  = cpu_addr[15:1];
    assign sh_req   = sel_sh & ~done;
    assign sh_we    = wr ? {~uds_n, ~lds_n} : 2'b00;
    assign sh_wdata = cpu_dout;

    // YGV608: one strobe on the first clock, read data two clocks later
    logic ygv_d1, ygv_d2;
    assign ygv_port  = cpu_addr[3:1];
    assign ygv_wr    = sel_ygv & first & wr & ~uds_n;
    assign ygv_rd    = sel_ygv & first & ~wr;
    assign ygv_wdata = cpu_dout[15:8];
    always_ff @(posedge clk) begin
        ygv_d1 <= sel_ygv & first;
        ygv_d2 <= ygv_d1;
    end

    // EEPROM: byte at each even address (upper lane)
    assign eep_addr  = cpu_addr[11:1];
    assign eep_req   = sel_eep & ~done & (~uds_n | ~wr);
    assign eep_we    = wr & ~uds_n;
    assign eep_wdata = cpu_dout[15:8];
endmodule
