// Taito F3 sound CPU, DUART timer and sound-chip interfaces

module rf_sound_main #(
    parameter EXTERNAL_ESP = 0,
    parameter SEPARATE_MEMORY_INIT=0
)
(
    input wire memory_init,
    input  logic        clk,            // 53.372 MHz
    input  logic        reset,          // system reset
    input  logic        snd_reset,      // held by the main CPU (C80000/C80100)
    input  logic        pause,          // hold this CPU too (MiSTer Pause button)
    // KIRAMEKI sound-ROM bank for the C20000 window (see the map above)
    input  logic  [2:0] snd_bank,
    input  logic        snd_bank_en,   // low = linear, as every game but Kirameki

    // program ROM via rf_prog_bus on its own SDRAM channel
    input  logic        clk_ram,
    output logic [26:1] ch_addr,
    input  logic [63:0] ch_dout,
    output logic        ch_req,
    input  logic        ch_ready,

    // MB8421 dual-port RAM, this side (byte k of 2 KB at 140000 + 2k)
    output logic  [9:0] dp_addr,
    output logic [15:0] dp_wdata,
    output logic        dp_wren,
    output logic  [1:0] dp_be,
    input  logic [15:0] dp_q,

    // the chips' register writes, for the sampler and friends
    output logic        es_we,          // ES5505: reg es_reg, 16-bit data, lanes
    output logic  [3:0] es_reg,
    output logic [15:0] es_data,
    output logic  [1:0] es_be,
    output logic        bk_we,          // sample bank for voice bk_voice
    output logic  [4:0] bk_voice,
    output logic  [2:0] bk_data,
    output logic        vl_we,          // MB87078 data_w(offset ^ 1, byte)
    output logic        vl_offset,
    output logic  [7:0] vl_data,
    output logic        esp_halt,       // DUART OP6
    output wire         esp_host_we,
    output wire [7:0]   esp_host_addr,
    output wire [7:0]   esp_host_wdata,
    input  wire [7:0]   esp_host_rdata,
    input  wire         esp_host_wait,  // external ESP: a select/memory command is pending
    input  logic  [7:0] es_irqv,        // the sampler's IRQV, read at 0x20001C
    output logic        es_irqv_ack,    // one-cycle pulse on that read
    // ES5505 register reads go to the sampler (rf_es5505 rd_*): the CPU is
    // held until rd_valid, so a read sees every write before it
    output logic        es_rd_req,
    output logic  [3:0] es_rd_reg,
    input  logic [15:0] es_rd_data,
    input  logic        es_rd_valid,

    output logic        running         // out of reset and past the boot copy
);
    localparam int SPEED_DIV = 2;

    // ---- CPU -------------------------------------------------------------
    logic        clkena;
    logic [31:0] cpu_addr;
    logic [15:0] cpu_din, cpu_dout;
    logic        nWr, nUDS, nLDS;
    logic [1:0]  busstate;
    logic [2:0]  fc;
    logic [2:0]  ipl;
    logic        cpu_rst;               // system or sound-board reset, or boot copy

    // A plain 68000: no 68020 multiply/bitfield/extended-addressing/barrel
    // hardware. tools/test_tg68k_config.py proves identical results and SR
    // against the old switchable config (CPU=00). DIV_Mode stays 2 because the
    // 16-bit divider (DIV_Mode=0) corrupts D0 on DIVS overflow.
    TG68KdotC_Kernel #(
        .SR_Read(0), .VBR_Stackframe(0), .extAddr_Mode(0),
        .MUL_Mode(0), .DIV_Mode(2), .BitField(0),
        .BarrelShifter(0), .MUL_Hardware(1)
    ) cpu (
        .clk(clk),
        .nReset(~cpu_rst),
        .clkena_in(clkena),
        .data_in(cpu_din),
        .IPL(ipl),
        .IPL_autovector(1'b0),          // the DUART supplies the vector
        .berr(1'b0),
        .CPU(2'b00),                    // 68000 mode
        .addr_out(cpu_addr),
        .data_write(cpu_dout),
        .nWr(nWr),
        .nUDS(nUDS),
        .nLDS(nLDS),
        .busstate(busstate),
        .longword(),
        .nResetOut(),
        .FC(fc),
        .clr_berr(),
        .skipFetch(),
        .regin_out(),
        .CACR_out(),
        .VBR_out()
    );

    wire [23:0] a      = cpu_addr[23:0];
    wire        cpu_wr = (busstate == 2'b11);
    wire        cpu_rd = (busstate == 2'b10) || (busstate == 2'b00);
    wire [1:0]  be     = {~nUDS, ~nLDS};

    // ---- address decode --------------------------------------------------
    wire sel_ram   = (a[23:18] == 6'b000000) || (a[23:16] == 8'hFF);
    wire sel_dpram = (a[23:12] == 12'h140);
    wire sel_es    = (a[23:5]  == 19'h10000);                   // 200000-20001F
    wire sel_esp   = (a[23:9]  == 15'h1300);                    // 260000-2601FF
    wire sel_duart = (a[23:5]  == 19'h14000);                   // 280000-28001F
    wire sel_bank  = (a[23:6]  == 18'hC000);                    // 300000-30003F
    wire sel_vol   = (a[23:2]  == 22'hD0000);                   // 340000-340003
    wire sel_rom   = (a[23:19] == 5'b11000);                    // C00000-C7FFFF
    // interrupt acknowledge: CPU space (FC[1:0] = 11) at FFFFF0 | level<<1;
    // the address alone is inside the RAM mirror, so both conditions
    wire sel_iack  = (fc[1:0] == 2'b11) && (a[23:4] == 20'hFFFFF);

    // ---- boot copy: ROM 0-7 -> RAM 0-7, then run --------------------------
    // Four word fetches through prog_bus while the CPU is held (prog_bus
    // answers one 16-bit word per request), then four RAM writes.
    typedef enum logic [1:0] { B_HOLD, B_FETCH, B_COPY, B_RUN } bst_t;
    bst_t bst;
    logic [1:0]  boot_i;
    logic [63:0] boot_line;
    logic        boot_take;             // a boot word was consumed

    // ---- program fetch ---------------------------------------------------
    logic        prog_req, prog_valid;
    logic [21:1] prog_addr;
    logic [15:0] prog_data;
    logic        rom_wait, prog_valid_lat;
    logic [15:0] prog_data_lat;

    // SDRAM byte 0x100000 + ROM offset; the loader stores this region raw,
    // so the 16-bit word comes back {d66-22 byte, d66-23 byte} and the
    // 68000's big-endian word is the swap of that
    rf_prog_bus #(.SEPARATE_INIT(SEPARATE_MEMORY_INIT)) prog (
        .clk_cpu(clk),.init(memory_init), .reset(reset | (SEPARATE_MEMORY_INIT && snd_reset)),
        .addr(prog_addr), .req(prog_req), .data(prog_data), .valid(prog_valid),
        .dl_wr(1'b0), .dl_addr(21'd0), .dl_data(16'd0), .dl_busy(), .dl_cnt(),
        .clk_ram(clk_ram),
        .ch_addr(ch_addr), .ch_dout(ch_dout), .ch_din(), .ch_be(),
        .ch_req(ch_req), .ch_rnw(), .ch_ready(ch_ready)
    );
    wire [15:0] rom_word = {prog_data_lat[7:0], prog_data_lat[15:8]};

    // ---- sound RAM 64 KB -------------------------------------------------
    logic [14:0] ram_addr;
    logic [15:0] ram_wdata, ram_q;
    logic        ram_wren;
    logic  [1:0] ram_be;

    rf_bram_tdp #(.AW(15)) u_ram (
        .clk(clk),
        .a_addr(ram_addr), .a_wdata(ram_wdata), .a_wren(ram_wren), .a_be(ram_be), .a_q(ram_q),
        .b_addr(15'd0), .b_wdata(16'd0), .b_wren(1'b0), .b_be(2'b00), .b_q()
    );

    // ---- DUART (timer + vector + OPR) ------------------------------------
    logic  [7:0] du_acr, du_imr, du_ctur, du_ctlr, du_ivr, du_isr, du_opr;
    logic [15:0] du_cnt;
    logic        du_half;
    logic [25:0] du_acc;                // 4 MHz (or /16) tick from clk_sys
    wire  [15:0] du_ctr  = {du_ctur, du_ctlr};
    wire         du_tick_4m  = (du_acc + 26'd4_000_000) >= 26'd53_372_000;
    logic  [3:0] du_div16;
    wire         du_tick = ((du_acr[5:4] == 2'b11) ? (du_tick_4m && du_div16 == 4'd15) : du_tick_4m);
    wire         du_irq  = |(du_isr & du_imr);
    // MC68681 OPR stores the complement of the output pins (manual 4.3.12).
    // Reset OPR=0 therefore asserts ESP HALT; setting OPR6 releases it.
    assign esp_halt = ~du_opr[6];

    // ---- ES5505 / bank / volume / ESP latches ----------------------------
    logic  [6:0] es_page;
    logic  [4:0] es_act;
    logic [15:0] bk_reg [0:31];
    // ES5510 host port: the latches, GPR/instruction memories and select
    // commands, faithfully (rf_es5510_host); the DSP itself does not run
    logic [7:0] esp_rdata;
    logic       esp_we;
    assign esp_host_we = esp_we;
    assign esp_host_addr = a[8:1];
    assign esp_host_wdata = cpu_dout[7:0];
    generate if (EXTERNAL_ESP) begin: external_esp
        assign esp_rdata = esp_host_rdata;
    end else begin: legacy_esp
    rf_es5510_host esp (
        .clk(clk), .reset(reset || snd_reset),
        .reg_a(a[8:1]), .we(esp_we), .wdata(cpu_dout[7:0]), .rdata(esp_rdata)
    );
    end endgenerate
    logic  [7:0] es_mb_ctl, es_mb_dat;

    // ---- wait-state engine (rf_main's, with the speed throttle) ----------
    logic [1:0] spd;
    always_ff @(posedge clk) begin
        if (reset || snd_reset) begin
            clkena   <= 1'b0;
            rom_wait <= 1'b0;
            prog_req <= 1'b0;
            spd      <= 2'd0;
            bst      <= B_HOLD;
            boot_i   <= 2'd0;
        end else begin
            prog_req <= 1'b0;
            clkena   <= 1'b0;
            if (spd != 2'(SPEED_DIV - 1)) spd <= spd + 2'd1;

            boot_take <= 1'b0;
            case (bst)
                // out of reset: fetch ROM words 0-3 first
                B_HOLD: begin
                    prog_addr <= {2'b10, 17'd0, boot_i};       // SDRAM 0x200000 + 2*i
                    prog_req  <= 1'b1;
                    rom_wait  <= 1'b1;
                    bst       <= B_FETCH;
                end
                B_FETCH: if (prog_valid_lat) begin
                    boot_line[16 * boot_i +: 16] <= prog_data_lat;
                    boot_take <= 1'b1;
                    rom_wait  <= 1'b0;
                    boot_i    <= boot_i + 2'd1;
                    bst       <= (boot_i == 2'd3) ? B_COPY : B_HOLD;
                end
                B_COPY: begin
                    // 4 words into RAM 0..3 -- ram_* are driven below
                    boot_i <= boot_i + 2'd1;
                    if (boot_i == 2'd3) bst <= B_RUN;
                end
                B_RUN: begin
                    if (rom_wait) begin
                        if (prog_valid_lat) begin
                            rom_wait <= 1'b0;
                            clkena   <= 1'b1;
                            spd      <= 2'd0;
                        end
                    end else if (!clkena && !pause && spd == 2'(SPEED_DIV - 1)) begin
                        if (sel_rom && cpu_rd) begin
                            // KIRAMEKI: the C20000-C3FFFF window (a[19:17]==1)
                            // reads bank `snd_bank` of the 128 KB entries that
                            // start at audiocpu offset 0x100000, rather than
                            // its linear place. Every other window, and every
                            // other game, is unchanged -- snd_bank powers up 0
                            // and nothing but Kirameki ever writes 0x300000.
                            // word = 0x100000 + bank*0x10000 + a[16:1], which
                            // is exactly {2'b10, bank[2:0], a[16:1]} in the
                            // 21-bit field: bit 20 is the 0x200000 byte base,
                            // bits 18:16 the 128 KB entry, 15:0 the offset.
                            prog_addr <= (snd_bank_en && a[19:17] == 3'd1)
                                       ? {2'b10, snd_bank, a[16:1]}
                                       : {2'b10, a[19:1]};      // SDRAM 0x200000 + offset
                            prog_req  <= 1'b1;
                            rom_wait  <= 1'b1;
                        end else if (sel_es && cpu_rd && !es_rd_valid) begin
                            // ES5505 read: hold the CPU until the sampler answers
                        end else if (EXTERNAL_ESP && sel_esp && esp_host_wait) begin
                            // the ESP commits host commands at END (<= ~17 us):
                            // the driver's next access waits for it, as it would
                            // poll the busy bit on the real board
                        end else begin
                            clkena <= 1'b1;
                            spd    <= 2'd0;
                        end
                    end
                end
            endcase
        end
    end
    assign cpu_rst = reset || snd_reset || (bst != B_RUN);
    assign running = (bst == B_RUN);

    // prog_bus data capture (rf_main's, plus the boot copy's consume)
    always_ff @(posedge clk) begin
        if (reset || clkena || boot_take) prog_valid_lat <= 1'b0;
        else if (prog_valid) begin
            prog_valid_lat <= 1'b1;
            prog_data_lat  <= prog_data;
        end
    end

    // ---- RAM port muxing -------------------------------------------------
    // Boot copy writes; otherwise the CPU. The RAM address is registered by
    // the BRAM, so a read's data is on ram_q the cycle after `a` settles --
    // which the 2-cycle bus op (clkena low for a cycle first) provides,
    // exactly as in rf_main.
    always_comb begin
        if (bst == B_COPY) begin
            ram_addr  = {13'd0, boot_i};
            ram_wdata = {boot_line[16 * boot_i + 7 -: 8], boot_line[16 * boot_i + 15 -: 8]};
            ram_wren  = 1'b1;
            ram_be    = 2'b11;
        end else begin
            ram_addr  = a[15:1];
            ram_wdata = cpu_dout;
            ram_wren  = cpu_wr && sel_ram && !clkena;
            ram_be    = be;
        end
    end

    // ---- dual-port RAM, byte k = word k>>1, lane by k&1 (big-endian) -----
    assign dp_addr  = a[11:2];
    assign dp_be    = a[1] ? 2'b01 : 2'b10;
    assign dp_wdata = {cpu_dout[15:8], cpu_dout[15:8]};
    assign dp_wren  = cpu_wr && sel_dpram && !clkena && be[1];
    wire  [7:0] dp_byte = a[1] ? dp_q[7:0] : dp_q[15:8];

    // ---- writes: chips, DUART, ring --------------------------------------
    // One registered strobe per bus write, on the cycle before clkena
    wire do_write = cpu_wr && !clkena && (bst == B_RUN);
    logic wr_seen;                      // one strobe per bus cycle
    always_ff @(posedge clk) begin
        if (cpu_rst) wr_seen <= 1'b0;
        else if (clkena) wr_seen <= 1'b0;
        else if (do_write) wr_seen <= 1'b1;
    end
    wire wr_strobe = do_write && !wr_seen;

    wire [3:0] du_reg = a[4:1];

    always_ff @(posedge clk) begin
        es_we <= 1'b0; bk_we <= 1'b0; vl_we <= 1'b0; esp_we <= 1'b0;
        if (reset || snd_reset) begin
            du_acr <= 8'd0; du_imr <= 8'd0; du_ctur <= 8'd0; du_ctlr <= 8'd0;
            du_ivr <= 8'h0F; du_isr <= 8'd0; du_opr <= 8'd0;
            du_cnt <= 16'hFFFF; du_half <= 1'b0; du_acc <= 26'd0; du_div16 <= 4'd0;
            es_page <= 7'd0; es_act <= 5'h1F;
            es_mb_ctl <= 8'd0; es_mb_dat <= 8'd0;
        end else begin
            // ---- timer: half period of du_ctr ticks; ISR bit 3 every full one
            du_acc <= du_tick_4m ? (du_acc + 26'd4_000_000 - 26'd53_372_000) : (du_acc + 26'd4_000_000);
            if (du_tick_4m) du_div16 <= du_div16 + 4'd1;
            if (du_tick) begin
                if (du_acr[6]) begin
                    // timer mode: free running
                    if (du_cnt <= 16'd1) begin
                        du_cnt  <= (du_ctr == 16'd0) ? 16'd1 : du_ctr;
                        du_half <= ~du_half;
                        if (du_half) du_isr[3] <= 1'b1;     // half_period returns to 0
                    end else begin
                        du_cnt <= du_cnt - 16'd1;
                    end
                end else begin
                    // counter mode: set ready at zero, restart from FFFF
                    if (du_cnt <= 16'd1) begin
                        du_cnt    <= 16'hFFFF;
                        du_isr[3] <= 1'b1;
                    end else begin
                        du_cnt <= du_cnt - 16'd1;
                    end
                end
            end

            // ---- reads with side effects (DUART commands)
            if (cpu_rd && !clkena && sel_duart && !wr_seen) begin
                case (du_reg)
                    4'hE: begin du_half <= 1'b0; du_cnt <= (du_ctr == 16'd0) ? 16'd1 : du_ctr; end
                    4'hF: du_isr[3] <= 1'b0;
                    default: ;
                endcase
            end

            // ---- writes
            if (wr_strobe) begin
                if (sel_esp && be[0]) esp_we <= 1'b1;
                if (sel_es) begin
                    es_we   <= 1'b1;
                    es_reg  <= a[4:1];
                    es_data <= cpu_dout;
                    es_be   <= be;
                    if (a[4:1] == 4'hF && be[0]) es_page <= cpu_dout[6:0];
                    if (a[4:1] == 4'hD && be[0]) es_act  <= cpu_dout[4:0];
                end
                if (sel_bank) begin
                    bk_we    <= 1'b1;
                    bk_voice <= a[5:1];
                    bk_data  <= cpu_dout[2:0];
                    bk_reg[a[5:1]] <= cpu_dout;
                end
                if (sel_vol && be[1]) begin
                    vl_we     <= 1'b1;
                    vl_offset <= ~a[1];                 // data_w(offset ^ 1, data)
                    vl_data   <= cpu_dout[15:8];
                    if (a[1]) es_mb_ctl <= cpu_dout[15:8]; else es_mb_dat <= cpu_dout[15:8];
                end
                if (sel_duart && be[0]) begin
                    case (du_reg)
                        4'h4: du_acr  <= cpu_dout[7:0];
                        4'h5: du_imr  <= cpu_dout[7:0];
                        4'h6: du_ctur <= cpu_dout[7:0];
                        4'h7: du_ctlr <= cpu_dout[7:0];
                        4'hC: du_ivr  <= cpu_dout[7:0];
                        4'hE: du_opr  <= du_opr |  cpu_dout[7:0];   // set OP bits
                        4'hF: du_opr  <= du_opr & ~cpu_dout[7:0];   // reset OP bits
                        default: ;
                    endcase
                end
            end
        end
    end

    // ---- read mux ----------------------------------------------------------
    always_comb begin
        cpu_din = 16'h0000;
        if (sel_iack)        cpu_din = {8'h00, du_ivr};
        else if (sel_rom)    cpu_din = rom_word;
        else if (sel_ram)    cpu_din = ram_q;
        else if (sel_dpram)  cpu_din = {dp_byte, 8'h00};
        else if (sel_es)     cpu_din = es_rd_data;     // the sampler's live answer (rd_valid gates clkena)
        else if (sel_bank)   cpu_din = bk_reg[a[5:1]];
        else if (sel_vol)    cpu_din = {a[1] ? es_mb_ctl : es_mb_dat, 8'h00};
        else if (sel_esp)    cpu_din = {8'h00, esp_rdata};
        else if (sel_duart) begin
            case (du_reg)
                4'h1, 4'h9: cpu_din = 16'h000C;          // SR: TxRDY | TxEMT
                4'h4:       cpu_din = 16'h0000;          // IPCR
                4'h5:       cpu_din = {8'h00, du_isr};
                4'h6:       cpu_din = {8'h00, du_cnt[15:8]};
                4'h7:       cpu_din = {8'h00, du_cnt[7:0]};
                4'hC:       cpu_din = {8'h00, du_ivr};
                4'hD:       cpu_din = 16'h00FF;          // input port
                default:    cpu_din = 16'h0000;
            endcase
        end
    end

    // level 6 while the enabled ISR bits are set; TG68K takes active-low IPL
    assign ipl = du_irq ? 3'b001 : 3'b111;

    // ES5505 read request: the level of the bus cycle, dropped for one
    // cycle after every CPU step so back-to-back reads are separate requests
    logic es_rd_gap;
    always_ff @(posedge clk) es_rd_gap <= clkena;
    assign es_rd_req = cpu_rd && sel_es && (bst == B_RUN) && !cpu_rst && !es_rd_gap;
    assign es_rd_reg = a[4:1];

    // IRQV read acknowledge: one pulse per bus cycle that reads it, AFTER
    // the sampler has delivered the vector (es5505_device::read returns
    // m_irqv, then update_internal_irq_state clears it)
    logic irqv_rd_seen;
    always_ff @(posedge clk) begin
        es_irqv_ack <= 1'b0;
        if (cpu_rst || clkena) irqv_rd_seen <= 1'b0;
        else if (es_rd_valid && cpu_rd && sel_es && a[4:1] == 4'hE && !irqv_rd_seen) begin
            irqv_rd_seen <= 1'b1;
            es_irqv_ack  <= 1'b1;
        end
    end

endmodule
