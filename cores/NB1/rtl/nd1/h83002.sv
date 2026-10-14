//------------------------------------------------------------------------------
// H8/3002: the H8/300H core with the on-chip peripherals the ND-1 sub program
// touches (docs/hardware.md section 3), modelled on MAME's h83002.cpp,
// h8_intc.cpp (h8h_intc) and h8_timer16.cpp (h8h_timer16_channel):
//   - 512 bytes of RAM at FFFD10-FFFF0F
//   - interrupt controller: ISCR/IER/ISR/ICR at FFFFF4-F9, SYSCR at FFFFF2,
//     external IRQ5 (vector 17) and the internal timer vectors
//   - the ITU: TSTR at FFFF60, five 16-bit channels with TCR/TIER/TSR/TCNT/
//     GRA/GRB (channels 3 and 4 also BRA/BRB), compare-match and overflow
//     interrupts, prescaler phi, phi/2, phi/4, phi/8
//   - ports, SCI, watchdog, ADC and DMA registers as plain storage that reads
//     back what MAME's models return for this board (P7 and PA read FF)
// Everything outside the on-chip map goes out on the external bus.
//------------------------------------------------------------------------------
`default_nettype none

module h83002 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,            // phi = 16.384 MHz

    // external bus (level request, one-cycle ack)
    output logic [23:0] ext_addr,
    output logic        ext_rd,
    output logic        ext_wr,
    output logic        ext_word,
    output logic [15:0] ext_wdata,
    input  logic [15:0] ext_rdata,
    input  logic        ext_ack,

    input  logic        irq5_n,         // external IRQ5 pin (active low)

    output logic        dbg_istart,
    output logic [23:0] dbg_pc,
    output logic        dbg_irq,
    output logic [23:0] dbg_npc,
    output logic        dbg_sleep,
    output logic [23:0] dbg_bus_addr,
    output logic        dbg_bus_rd,
    output logic        dbg_bus_wr,
    output logic        dbg_bus_word,
    output logic [15:0] dbg_bus_wdata,
    output logic [15:0] dbg_bus_rdata,
    output logic        dbg_bus_ack
);
    // ------------------------------------------------------------ CPU
    logic [23:0] bus_addr;
    logic        bus_rd, bus_wr, bus_word, bus_ack;
    logic [15:0] bus_wdata, bus_rdata;
    logic  [7:0] irq_vector, irq_ack_vector, ccr;
    wire _unused_ccr = &{1'b0, ccr[5:0]};
    logic        irq_ack;
    logic [31:0] e0, e1, e2, e3, e4, e5, e6, e7;

    h8300h cpu (
        .clk(clk), .reset(reset), .cen(cen),
        .bus_addr(bus_addr), .bus_rd(bus_rd), .bus_wr(bus_wr), .bus_word(bus_word),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
        .irq_vector(irq_vector), .irq_ack(irq_ack), .irq_ack_vector(irq_ack_vector), .ccr_out(ccr),
        .dbg_istart(dbg_istart), .dbg_pc(dbg_pc), .dbg_irq(dbg_irq), .dbg_npc(dbg_npc),
        .dbg_er0(e0), .dbg_er1(e1), .dbg_er2(e2), .dbg_er3(e3), .dbg_er4(e4), .dbg_er5(e5), .dbg_er6(e6), .dbg_er7(e7),
        .dbg_sleep(dbg_sleep)
    );
    wire _unused_er = &{1'b0, e0, e1, e2, e3, e4, e5, e6, e7};
    assign dbg_bus_addr = bus_addr; assign dbg_bus_rd = bus_rd; assign dbg_bus_wr = bus_wr; assign dbg_bus_word = bus_word;
    assign dbg_bus_wdata = bus_wdata; assign dbg_bus_rdata = bus_rdata; assign dbg_bus_ack = bus_ack;

    // ------------------------------------------------------------ decode
    wire sel_ram = (bus_addr >= 24'hfffd10) && (bus_addr <= 24'hffff0f);
    wire sel_io  = (bus_addr[23:8] == 16'hffff) && (bus_addr[7:0] >= 8'h20);
    wire sel_int = sel_ram | sel_io;
    wire req     = bus_rd | bus_wr;

    // external bus pass-through
    assign ext_addr  = bus_addr;
    assign ext_rd    = bus_rd & ~sel_int;
    assign ext_wr    = bus_wr & ~sel_int;
    assign ext_word  = bus_word;
    assign ext_wdata = bus_wdata;

    // internal accesses: one ack pulse per request, the clock after it rises; a request
    // still standing after its ack (the CPU drops it on its next enable) is not served again
    logic int_busy, int_pulse;
    wire  int_go = req & sel_int & ~int_busy;
    always_ff @(posedge clk) begin
        if (reset) begin int_busy <= 1'b0; int_pulse <= 1'b0; end
        else begin
            int_pulse <= int_go;
            if (int_go) int_busy <= 1'b1; else if (!req) int_busy <= 1'b0;
        end
    end

    assign bus_ack   = sel_int ? int_pulse : ext_ack;
    assign bus_rdata = sel_int ? int_q : ext_rdata;

    // ------------------------------------------------------------ on-chip RAM (256 x 16, byte lanes)
    logic [7:0] ram_hi [256];
    logic [7:0] ram_lo [256];
    wire  [7:0] ram_a  = (bus_addr[8:1] - 8'h88);       // (addr - FFFD10) / 2
    logic [7:0] ram_qh, ram_ql;
    wire        ram_we_h = int_pulse & bus_wr & sel_ram & (bus_word | ~bus_addr[0]);
    wire        ram_we_l = int_pulse & bus_wr & sel_ram & (bus_word |  bus_addr[0]);
    always_ff @(posedge clk) begin
        if (ram_we_h) ram_hi[ram_a] <= bus_wdata[15:8];
        ram_qh <= ram_hi[ram_a];
    end
    always_ff @(posedge clk) begin
        if (ram_we_l) ram_lo[ram_a] <= bus_wdata[7:0];
        ram_ql <= ram_lo[ram_a];
    end

    // ------------------------------------------------------------ I/O registers
    logic  [7:0] io_q;
    logic [15:0] int_q;
    assign int_q = sel_ram ? {ram_qh, ram_ql} : {io_q, io_q};

    // named state
    logic  [7:0] tstr;
    logic  [7:0] syscr, iscr, ier, isr;
    logic  [7:0] ddr4, ddr6, ddr8, ddr9, ddra, ddrb;
    logic  [7:0] adcsr;
    logic [10:0] adc_cnt;
    logic        adc_run;
    logic  [7:0] dr4, dr6, dr8, dr9, dra, drb;
    logic [15:0] icr;
    // timer channels
    logic  [7:0] tcr  [5];
    logic  [7:0] tier [5];
    logic  [2:0] tflag[5];      // IMFA, IMFB, OVF
    logic [15:0] tcnt [5];
    logic [15:0] gra  [5];
    logic [15:0] grb  [5];
    // A store lands later in MAME than here: MAME prefetches the next opcode (2 states)
    // before the write and charges the write's own states before performing it, so a
    // register changes about 3 states after this core writes it. Against that, MAME takes
    // an interrupt in the state the counter overflows while this core needs two more (the
    // registered vector, the core's sampled copy). The two nearly cancel: with a TCNT
    // write staged one state the ITU's interrupt lands within a few states of MAME's in
    // the four trace captures (sim/run_sub.sh reports the skew), with reads forwarded from
    // the staged bytes so nothing sees the old count.
    localparam int TCNT_WR_DELAY = 1;
    logic  [1:0] tw_be  [5];        // staged byte lanes
    logic [15:0] tw_val [5];
    logic  [1:0] tw_cnt [5];        // states still to wait

    // write pulses (byte-lane aware: a word write hits two registers)
    wire io_wr = int_pulse & bus_wr & sel_io;
    wire io_rd = int_pulse & bus_rd & sel_io;
    wire [7:0] io_a_h = bus_addr[7:0] & 8'hfe;     // even address of the pair
    wire [7:0] io_a_l = io_a_h | 8'h01;
    wire       wr_h   = io_wr & (bus_word | ~bus_addr[0]);
    wire       wr_l   = io_wr & (bus_word |  bus_addr[0]);
    wire [7:0] wd_h   = bus_wdata[15:8];
    wire [7:0] wd_l   = bus_wdata[7:0];

    // channel register offsets
    function automatic logic [2:0] ch_of(input logic [7:0] a);
        if (a >= 8'h64 && a <= 8'h6d) ch_of = 3'd0;
        else if (a >= 8'h6e && a <= 8'h77) ch_of = 3'd1;
        else if (a >= 8'h78 && a <= 8'h81) ch_of = 3'd2;
        else if (a >= 8'h82 && a <= 8'h8f) ch_of = 3'd3;
        else if (a >= 8'h92 && a <= 8'h9f) ch_of = 3'd4;
        else ch_of = 3'd7;
    endfunction
    function automatic logic [3:0] ch_reg(input logic [7:0] a);   // 0 TCR 1 TIOR 2 TIER 3 TSR 4/5 TCNT 6/7 GRA 8/9 GRB
        case (ch_of(a))
        3'd0: ch_reg = a[3:0] - 4'h4;
        3'd1: ch_reg = 4'(a - 8'h6e);
        3'd2: ch_reg = 4'(a - 8'h78);
        3'd3: ch_reg = 4'(a - 8'h82);
        3'd4: ch_reg = 4'(a - 8'h92);
        default: ch_reg = 4'hf;
        endcase
    endfunction

    // prescaler for the timers
    logic [2:0] presc;
    function automatic logic count_en(input logic [2:0] t, input logic [2:0] p);
        case (t)
        3'd0: count_en = 1'b1;
        3'd1: count_en = p[0];
        3'd2: count_en = (p[1:0] == 2'b11);
        3'd3: count_en = (p == 3'b111);
        default: count_en = 1'b0;      // external clocks: not connected
        endcase
    endfunction

    // interrupt pending bits (internal sources), indexed by vector
    logic [63:0] pend;

    // one register-write handler: applies a byte write at address a with data d
    // (called twice for word writes: even then odd lane)
    task automatic io_write(input logic [7:0] a, input logic [7:0] d);
        logic [2:0] c; logic [3:0] r;
        c = ch_of(a); r = ch_reg(a);
        case (a)
        8'h60: tstr <= d;
        8'hc5: ddr4 <= d; 8'hc7: dr4 <= d;
        8'hc9: ddr6 <= d; 8'hcb: dr6 <= d;
        8'hcd: ddr8 <= d; 8'hcf: dr8 <= d;
        8'hd0: ddr9 <= d; 8'hd2: dr9 <= d;
        8'hd1: ddra <= d; 8'hd3: dra <= d;
        8'hd4: ddrb <= d; 8'hd6: drb <= d;
        8'he8: begin
            adcsr <= (d & 8'h7f) | (adcsr & d & 8'h80);
            if (!adcsr[5] && d[5]) begin adc_run <= 1'b1; adc_cnt <= 11'd0; end
        end
        8'hf2: syscr <= d;
        8'hf4: iscr <= d;
        8'hf5: ier <= d;
        8'hf6: isr <= isr & d;
        8'hf8: icr[7:0] <= d;                 // MAME h8h_intc: offset 0 is the low byte (ICRA)
        8'hf9: icr[15:8] <= d;
        default: ;
        endcase
        if (c != 3'd7) begin
            case (r)
            4'd0: tcr[c] <= d;
            4'd2: tier[c] <= d;
            4'd3: tflag[c] <= tflag[c] & d[2:0];       // writing 0 clears
            4'd4: begin tw_val[c][15:8] <= d; tw_be[c][1] <= 1'b1; tw_cnt[c] <= 2'(TCNT_WR_DELAY - 1); end
            4'd5: begin tw_val[c][7:0]  <= d; tw_be[c][0] <= 1'b1; tw_cnt[c] <= 2'(TCNT_WR_DELAY - 1); end
            4'd6: gra[c][15:8] <= d;
            4'd7: gra[c][7:0] <= d;
            4'd8: grb[c][15:8] <= d;
            4'd9: grb[c][7:0] <= d;
            default: ;
            endcase
        end
    endtask

    // register read (combinational on the registered address)
    function automatic logic [7:0] io_read(input logic [7:0] a);
        logic [2:0] c; logic [3:0] r;
        c = ch_of(a); r = ch_reg(a);
        io_read = 8'h00;                                       // registers not modelled read 0 (only the ones below are ever read)
        case (a)
        8'h60: io_read = tstr | 8'he0;
        8'h61, 8'h62, 8'h63, 8'h90, 8'h91: io_read = 8'h00;   // TSYR/TMDR/TFCR/TOER/TOCR read 0 in MAME
        // ports (MAME h8_port): DDR reads FF; DR reads mask | (dr & ddr) | (pins & ~ddr), pins read 1
        8'hc5, 8'hc9, 8'hcd, 8'hd0, 8'hd1, 8'hd4: io_read = 8'hff;
        8'hc7: io_read = 8'h00 | (dr4 & ddr4) | ~ddr4;
        8'hcb: io_read = 8'h80 | (dr6 & ddr6) | ~ddr6;
        8'hce: io_read = 8'hff;                                // port 7 input only (mcu_p7_read)
        8'hcf: io_read = 8'he0 | (dr8 & ddr8) | ~ddr8;
        8'hd2: io_read = 8'hc0 | (dr9 & ddr9) | ~ddr9;
        8'hd3: io_read = 8'h00 | (dra & ddra) | ~ddra;
        8'hd6: io_read = 8'h00 | (drb & ddrb) | ~ddrb;
        8'he0, 8'he1, 8'he2, 8'he3, 8'he4, 8'he5, 8'he6, 8'he7: io_read = 8'h00;  // ADC data (inputs tied to 0)
        8'he8: io_read = adcsr;
        8'hf2: io_read = syscr;
        8'hf4: io_read = iscr;
        8'hf5: io_read = ier;
        8'hf6: io_read = isr;
        8'hf8: io_read = icr[7:0];
        8'hf9: io_read = icr[15:8];
        8'had: io_read = 8'h80;                                // RTMCSR: CMF always set
        default: ;
        endcase
        if (c != 3'd7) begin
            case (r)
            4'd0: io_read = tcr[c];
            4'd1: io_read = 8'h00;                               // TIOR reads 0 in MAME
            4'd2: io_read = tier[c] | 8'hf8;
            4'd3: io_read = {5'b11111, tflag[c]};
            4'd4: io_read = tw_be[c][1] ? tw_val[c][15:8] : tcnt[c][15:8];
            4'd5: io_read = tw_be[c][0] ? tw_val[c][7:0]  : tcnt[c][7:0];
            4'd6: io_read = gra[c][15:8];
            4'd7: io_read = gra[c][7:0];
            4'd8: io_read = grb[c][15:8];
            4'd9: io_read = grb[c][7:0];
            default: ;
            endcase
        end
    endfunction

    // timer interrupt vectors: channel c -> IMIA 24+4c, IMIB 25+4c, OVI 26+4c
    // external IRQ5 -> 17
    logic irq5_q;                       // synchronised pin
    logic irq5_prev;

    always_ff @(posedge clk) begin
        if (reset) begin
            tstr <= 8'h00; syscr <= 8'h09; iscr <= 8'h00; ier <= 8'h00; isr <= 8'h00; icr <= 16'h0000;
            ddr4 <= 8'h00; ddr6 <= 8'h80; ddr8 <= 8'hf0; ddr9 <= 8'h00; ddra <= 8'h00; ddrb <= 8'h00;
            dr4 <= 8'h00; dr6 <= 8'h00; dr8 <= 8'h00; dr9 <= 8'h00; dra <= 8'h00; drb <= 8'h00;
            for (int i = 0; i < 5; i++) begin tcr[i] <= 8'h00; tier[i] <= 8'h00; tflag[i] <= 3'b000; tcnt[i] <= 16'h0000; gra[i] <= 16'hffff; grb[i] <= 16'hffff; end
            for (int i = 0; i < 5; i++) begin tw_be[i] <= 2'b00; tw_val[i] <= 16'h0000; tw_cnt[i] <= 2'd0; end
            presc <= 3'd0; pend <= 64'd0; irq5_q <= 1'b1; irq5_prev <= 1'b1;
            adcsr <= 8'h00; adc_cnt <= 11'd0; adc_run <= 1'b0;
        end else begin
            // ---- register writes
            if (wr_h) io_write(io_a_h, wd_h);
            if (wr_l) io_write(io_a_l, wd_l);

            // ---- external IRQ5: edge (ISCR bit 5 = 1) or level (0) sensitive, active low
            irq5_q <= irq5_n; irq5_prev <= irq5_q;
            if (iscr[5]) begin
                if (irq5_prev && !irq5_q) isr[5] <= 1'b1;            // falling edge
            end else begin
                if (!irq5_q) isr[5] <= 1'b1;                          // level low
            end

            // ---- ADC: a conversion pass takes (CKS ? 134 : 266) + 3 x (CKS ? 128 : 256) states in
            // scan mode over channels 0-3, then ADF sets; scan repeats (ADST stays), single clears ADST
            if (cen && adc_run) begin
                adc_cnt <= adc_cnt + 11'd1;
                if (adc_cnt == (adcsr[3] ? 11'd517 : 11'd1033)) begin
                    adcsr[7] <= 1'b1;
                    if (adcsr[4]) adc_cnt <= adcsr[3] ? 11'd6 : 11'd10;
                    else begin adcsr[5] <= 1'b0; adc_run <= 1'b0; end
                end
            end
            // ---- timers
            if (cen) begin
                presc <= presc + 3'd1;
                for (int c = 0; c < 5; c++) begin
                    if (tstr[c] && count_en(tcr[c][2:0], presc)) begin
                        logic ma, mb, ov, clr;
                        ma = (tcnt[c] == gra[c]);
                        mb = (tcnt[c] == grb[c]);
                        ov = (tcnt[c] == 16'hffff);
                        clr = (tcr[c][6:5] == 2'b01 && ma) || (tcr[c][6:5] == 2'b10 && mb) || ov;
                        tcnt[c] <= clr ? 16'h0000 : tcnt[c] + 16'd1;
                        if (ma) begin tflag[c][0] <= 1'b1; if (tier[c][0]) pend[24 + 4*c] <= 1'b1; end
                        if (mb) begin tflag[c][1] <= 1'b1; if (tier[c][1]) pend[25 + 4*c] <= 1'b1; end
                        if (ov) begin tflag[c][2] <= 1'b1; if (tier[c][2]) pend[26 + 4*c] <= 1'b1; end
                    end
                end
            end
            // ---- staged TCNT writes land TCNT_WR_DELAY states after this core writes them,
            // after the counting above so a write on the same state wins (MAME's
            // update_counter runs to the write's time, then loads)
            if (cen) begin
                for (int c = 0; c < 5; c++) begin
                    if (tw_be[c] != 2'b00) begin
                        if (tw_cnt[c] != 2'd0) tw_cnt[c] <= tw_cnt[c] - 2'd1;
                        else begin
                            if (tw_be[c][1]) tcnt[c][15:8] <= tw_val[c][15:8];
                            if (tw_be[c][0]) tcnt[c][7:0]  <= tw_val[c][7:0];
                            tw_be[c] <= 2'b00;
                        end
                    end
                end
            end

            // ---- interrupt taken: clear the pending source (MAME interrupt_taken)
            if (irq_ack) begin
                if (irq_ack_vector >= 8'd12 && irq_ack_vector < 8'd20) begin
                    // external IRQn: clear ISR unless level-sensitive and still asserted
                    logic [2:0] n; n = irq_ack_vector[2:0] - 3'd4;   // 12..19 -> 0..7
                    if (n == 3'd5) begin if (iscr[5] || irq5_q) isr[5] <= 1'b0; end
                end else pend[irq_ack_vector[5:0]] <= 1'b0;
            end
        end
    end

    // ---- vector selection (MAME update_irq_state): among pending vectors that pass the
    // filter, the highest ICR priority wins, then the lowest vector number. ICR slot per
    // vector as h8h_intc's vector_to_slot; the priority bit is icr[slot ^ 7] (slot 0 = ICRA
    // bit 7, slot 7 = ICRA bit 0, slots 8-14 = ICRB bits 15-9).
    function automatic logic [3:0] vec_slot(input int v);
        if (v == 12) vec_slot = 4'd0;
        else if (v == 13) vec_slot = 4'd1;
        else if (v == 14 || v == 15) vec_slot = 4'd2;
        else if (v >= 16 && v <= 63) vec_slot = 4'((v - 16) / 4 + 3);
        else vec_slot = 4'd15;
    endfunction

    // filter (h83002 update_irq_filter): SYSCR UE (bit 3) set: I blocks everything but NMI;
    // UE clear: I&UI block all, I alone blocks priority-0 sources
    logic [1:0] filt;
    always_comb begin
        if (syscr[3]) filt = ccr[7] ? 2'd2 : 2'd0;
        else if (ccr[7] && ccr[6]) filt = 2'd2;
        else if (ccr[7]) filt = 2'd1;
        else filt = 2'd0;
    end

    logic [63:0] pend_all, pri_mask, elig_hi, elig_lo;
    always_comb begin
        pend_all = pend;
        for (int i = 0; i < 8; i++) pend_all[12 + i] = isr[i] & ier[i];
        for (int v = 0; v < 64; v++) begin
            logic [3:0] sl;
            sl = vec_slot(v);
            pri_mask[v] = (sl == 4'd15) ? 1'b0 : icr[sl ^ 4'd7];
        end
        elig_hi = (filt != 2'd2) ? (pend_all & pri_mask) : 64'd0;
        elig_lo = (filt == 2'd0) ? (pend_all & ~pri_mask) : 64'd0;
        elig_hi[0] = 1'b0; elig_lo[0] = 1'b0;
    end
    function automatic logic [6:0] lowest(input logic [63:0] m);   // {found, index}
        lowest = 7'd0;
        for (int v = 63; v >= 0; v--) if (m[v]) lowest = {1'b1, 6'(v)};
    endfunction
    // Registered: the core samples it on its enable, and the two-level priority encoder is
    // too deep for one 96 MHz clock in front of the core's sequencer (a combinational
    // vector was tried for MAME's same-state interrupt recognition; the fitter's register
    // retiming pulled the loop apart and it missed timing by a nanosecond). The cost is one
    // H8 state of interrupt latency, inside the skew sim/tb_sub.cpp bounds.
    always_ff @(posedge clk) begin
        logic [6:0] hi, lo;
        hi = lowest(elig_hi);
        lo = lowest(elig_lo);
        if (reset) irq_vector <= 8'd0;
        else irq_vector <= hi[6] ? {2'b00, hi[5:0]} : lo[6] ? {2'b00, lo[5:0]} : 8'd0;
    end

    // registered read data
    always_ff @(posedge clk) io_q <= io_read(bus_addr[7:0]);
    wire _unused = &{1'b0, io_rd};
endmodule
