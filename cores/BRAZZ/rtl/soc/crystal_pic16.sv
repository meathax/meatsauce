// BrezzaSoft Crystal System MiSTer core -- protection PIC: Microchip PIC16F84A / PIC16F628A (mid-range PIC16).
// Copyright (C) 2026 Kyle Lester. SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour: MAME src/devices/cpu/pic16x8x/pic16x8x.cpp (c2334733) through the reference model
// sim/reference/pic16_ref.h, instruction for instruction: the 35 instructions with MAME's flags and cycle
// counts (1; 2 for CALL/GOTO/RETURN/RETFIE/RETLW; +1 for a taken skip and for a write to PCL), STATUS write
// protection, FSR/INDF indirection (IRP), the 8-level stack, TMR0 with prescaler and write delay, EEPROM with
// the 55/AA unlock, interrupts (T0IF, INTF, RBIF, EEIF on the F84A, PIR1&PIE1 on the F628A) and the two register
// maps (F84A: core registers mirrored at 0x80, RAM 0x0c-0x4f; F628A: MAME's data_map, banks 0-3, the
// peripheral registers MAME keeps as plain storage).
// Not implemented: the watchdog (both Crystal System PICs have WDTE = 0 in their configuration word), SLEEP
// wake-up by the watchdog, T0CKI counting (no pin connected).
//
// Timing: one instruction cycle per `cyc` pulse (3.579545 MHz / 4 = every 96 clk_sys). An instruction executes in
// a few clk_sys right after the pulse that starts it and then occupies its instruction cycles.
// Board hookup (MAME crystal.cpp): port A bit 0 is the data line shared with the CPU's PIO bit 29; port A
// writes report the driven bits (porta_we, porta_val, porta_mask); the CPU holds the PIC in reset with PIO
// bit 30 (hold).
module crystal_pic16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        model_628,       // 0 = PIC16F84A, 1 = PIC16F628A
    input  wire        hold,            // reset held (PIO bit 30)
    input  wire        cyc,             // instruction-cycle tick

    input  wire  [7:0] porta_in,        // pin levels (bit 0 = shared data line)
    output reg         porta_we,        // pulse: port A driven value changed
    output reg   [7:0] porta_val,
    output reg   [7:0] porta_mask,

    // firmware load (MAME image layout, 16-bit words: program at word 0, EEPROM at word 0x2100 + i)
    input  wire        ld_we,
    input  wire [13:0] ld_addr,         // word address in the image
    input  wire [15:0] ld_data,

    output wire [12:0] dbg_pc,
    output wire  [7:0] dbg_w,
    output wire  [7:0] dbg_status,
    output reg         dbg_retire,      // pulse per executed instruction
    output reg  [31:0] dbg_count
);
    // ------------------------------------------------------------------ memories
    wire [13:0] prog_q;
    reg  [10:0] prog_a;
    crystal_sdpram #(.AW(11), .DW(14)) prog (
        .clk(clk), .we(ld_we && ld_addr < 14'h0800), .waddr(ld_addr[10:0]), .wdata(ld_data[13:0]),
        .raddr(prog_a), .rdata(prog_q)
    );
    reg         gpr_we;
    reg   [8:0] gpr_wa, gpr_ra;
    reg   [7:0] gpr_wd;
    wire  [7:0] gpr_q;
    crystal_sdpram #(.AW(9), .DW(8)) gpr (
        .clk(clk), .we(gpr_we), .waddr(gpr_wa), .wdata(gpr_wd), .raddr(gpr_ra), .rdata(gpr_q)
    );
    reg         ee_we;
    reg   [6:0] ee_a;
    reg   [7:0] ee_wd;
    wire  [7:0] ee_q;
    wire  [7:0] ee_q_ld;
    crystal_tdpram #(.AW(7), .DW(8)) eep (
        .clk(clk),
        .a_we(ee_we), .a_addr(ee_a), .a_wdata(ee_wd), .a_rdata(ee_q),
        .b_we(ld_we && ld_addr >= 14'h2100 && ld_addr < 14'h2180), .b_addr(ld_addr[6:0]), .b_wdata(ld_data[7:0]),
        .b_rdata(ee_q_ld)
    );

    // ------------------------------------------------------------------ state
    reg  [12:0] pc;
    reg  [13:0] op;
    reg   [7:0] w, status, fsr, pclath, intcon, option, tmr0, eedata, eeadr, eecon1;
    reg   [7:0] port_data_a, port_data_b, tris_a, tris_b, portb_mm;
    reg   [7:0] pir1, pie1, t1con, t2con, ccp1con, rcsta, cmcon, pcon, txsta, vrcon;
    reg  [12:0] stack [0:7];
    reg   [2:0] sp;
    reg   [7:0] prescaler;
    reg   [2:0] delay_timer;
    reg   [1:0] ee_unlock;
    reg         sleeping;
    reg   [1:0] wait_cyc;           // further instruction cycles of the current instruction

    wire [7:0] status_mask = model_628 ? 8'hff : 8'h3f;
    wire [7:0] porta_msk   = model_628 ? 8'hff : 8'h1f;
    assign dbg_pc = pc; assign dbg_w = w; assign dbg_status = status;

    // ------------------------------------------------------------------ helpers
    // data address of a file-register operand: direct {RP1,RP0,f} or indirect {IRP,FSR}
    function automatic [8:0] faddr(input [6:0] f);
        if (f == 7'd0) return {status[7], fsr};
        return {status[6:5], f};
    endfunction
    // general-purpose RAM: index into the 512-byte array (mirrors folded); valid = it is RAM
    function automatic [9:0] gpr_map(input [8:0] a);    // {valid, index}
        logic [6:0] lo;
        lo = a[6:0];
        if (!model_628) begin
            if (lo >= 7'h0c && lo <= 7'h4f) return {1'b1, 2'b00, lo};
            return 10'd0;
        end
        if (lo >= 7'h70) return {1'b1, 2'b00, lo};                       // common to all banks
        case (a[8:7])
            2'd0: if (lo >= 7'h20) return {1'b1, a};
            2'd1: if (lo >= 7'h20 && lo <= 7'h6f) return {1'b1, a};
            2'd2: if (lo >= 7'h20 && lo <= 7'h4f) return {1'b1, a};
            default: ;
        endcase
        return 10'd0;
    endfunction

    wire [7:0] porta_rd = ((porta_in & tris_a) | (~tris_a & port_data_a)) & porta_msk;
    wire [7:0] portb_rd = (8'h00 & tris_b) | (~tris_b & port_data_b);   // port B pins read 0 (unconnected)

    // special function register read (returns 0 for unimplemented addresses; RAM handled separately)
    function automatic [7:0] sfr_rd(input [8:0] a);
        logic [6:0] lo;
        lo = a[6:0];
        case (lo)
            7'h02: return pc[7:0];
            7'h03: return status;
            7'h04: return fsr;
            7'h0a: return pclath;
            7'h0b: return intcon;
            default: ;
        endcase
        if (!model_628) begin
            if (a[7]) case (lo)
                7'h01: return option; 7'h05: return tris_a; 7'h06: return tris_b; 7'h08: return eecon1;
                default: return 8'd0;
            endcase
            case (lo)
                7'h01: return tmr0; 7'h05: return porta_rd; 7'h06: return portb_rd; 7'h08: return eedata;
                7'h09: return eeadr; default: return 8'd0;
            endcase
        end
        case (a[8:7])
            2'd0: case (lo)
                7'h01: return tmr0; 7'h05: return porta_rd; 7'h06: return portb_rd; 7'h0c: return pir1;
                7'h10: return t1con; 7'h12: return t2con; 7'h17: return ccp1con; 7'h18: return rcsta;
                7'h1f: return cmcon; default: return 8'd0;
            endcase
            2'd1: case (lo)
                7'h01: return option; 7'h05: return tris_a; 7'h06: return tris_b; 7'h0c: return pie1;
                7'h0e: return pcon; 7'h18: return txsta; 7'h1a: return eedata; 7'h1b: return eeadr;
                7'h1c: return eecon1; 7'h1f: return vrcon; default: return 8'd0;
            endcase
            2'd2: case (lo)
                7'h01: return tmr0; 7'h06: return portb_rd; default: return 8'd0;
            endcase
            default: case (lo)
                7'h01: return option; 7'h06: return tris_b; default: return 8'd0;
            endcase
        endcase
    endfunction
    // reading PORTB updates the RB7:RB4 change latch (MAME portb_r); also on a write to PORTB
    function automatic is_portb(input [8:0] a);
        if (!model_628) return !a[7] && a[6:0] == 7'h06;
        return a[6:0] == 7'h06 && !a[7];                  // banks 0 and 2
    endfunction

    // ------------------------------------------------------------------ sequencer
    typedef enum logic [3:0] { P_IDLE, P_FETCH, P_DEC, P_RD, P_OPND, P_EXEC, P_TMR, P_EE, P_EE2 } pst_t;
    reg  [7:0] rv_q;              // operand (registered: timing)
    reg  [2:0] tm_cyc;            // instruction cycles for the TMR0 update
    reg        tm_wr, ee_rd_q;    // the instruction wrote TMR0 / started an EEPROM read
    pst_t st;
    reg  [8:0] fa;               // operand data address
    reg  [9:0] fmap;
    reg  [2:0] icyc;             // instruction cycles of the instruction being executed
    reg        hold_q;

    // decoded fields (from op)
    wire [6:0] g    = op[13:7];
    wire [7:0] k    = op[7:0];
    wire       dst_f = op[7];
    wire [2:0] bpos = op[9:7];

    // interrupt pending (MAME irq_active)
    wire irq_act = |((intcon[5:3]) & intcon[2:0]) ||
                   (!model_628 ? (intcon[6] && eecon1[4]) : (intcon[6] && |(pir1 & pie1)));

    integer i;
    always @(posedge clk) begin
        porta_we   <= 1'b0;
        dbg_retire <= 1'b0;
        gpr_we     <= 1'b0;
        ee_we      <= 1'b0;
        hold_q     <= hold;
        if (!rst_n || hold) begin
            // MAME device_reset (power-on values of the registers MAME initialises at start are 0)
            st <= P_IDLE;
            pc <= 13'd0; status <= 8'h18; pclath <= 8'd0; intcon <= 8'd0; option <= 8'hff; eecon1 <= 8'd0;
            tris_a <= 8'hff; tris_b <= 8'hff; prescaler <= 8'd0; delay_timer <= 3'd0; sp <= 3'd0;
            portb_mm <= 8'hff; sleeping <= 1'b0; ee_unlock <= 2'd0; wait_cyc <= 2'd0;
            pir1 <= 8'd0; t1con <= 8'd0; t2con <= 8'd0; ccp1con <= 8'd0; rcsta <= 8'd0; cmcon <= 8'd0; pie1 <= 8'd0;
            pcon <= 8'h08; txsta <= 8'h02; vrcon <= 8'd0;
            if (!rst_n) begin
                w <= 8'd0; fsr <= 8'd0; tmr0 <= 8'd0; eedata <= 8'd0; eeadr <= 8'd0; port_data_a <= 8'd0;
                port_data_b <= 8'd0; dbg_count <= 32'd0;
            end
        end else begin
            case (st)
            P_IDLE: if (cyc) begin
                if (wait_cyc != 2'd0) wait_cyc <= wait_cyc - 2'd1;
                else begin
                    // MAME check_irqs: port B change detection, wake from sleep, interrupt entry
                    logic [7:0] im;
                    logic [7:0] ic;
                    logic       wake, sl;
                    logic [12:0] npc;
                    im = tris_b & 8'hf0;
                    ic = intcon;
                    if (im != 8'd0 && ((8'h00 & im) != (portb_mm & im))) ic[0] = 1'b1;
                    wake = 1'b0; sl = sleeping; npc = pc;
                    if (|((ic[5:3]) & ic[2:0]) || (!model_628 ? (ic[6] && eecon1[4]) : (ic[6] && |(pir1 & pie1)))) begin
                        if (sl) begin sl = 1'b0; wake = 1'b1; end
                        else if (ic[7]) begin
                            ic[7] = 1'b0;
                            stack[sp] <= pc;
                            sp <= sp + 3'd1;
                            npc = 13'd4;
                        end
                    end
                    intcon <= ic;
                    sleeping <= sl;
                    if (sl) begin
                        icyc <= 3'd1;                       // a sleeping cycle
                    end else begin
                        pc     <= npc;
                        prog_a <= {npc[10] & model_628, npc[9:0]};   // F84A: 1K words, addresses wrap (MAME 10-bit space)
                        st     <= P_FETCH;
                    end
                end
            end
            P_FETCH: st <= P_DEC;                           // program RAM read
            P_DEC: begin
                logic [8:0] a;
                op  <= prog_q;
                pc  <= pc + 13'd1;
                a = (prog_q[6:0] == 7'd0) ? {status[7], fsr} : {status[6:5], prog_q[6:0]};
                if (!model_628) a[8] = 1'b0;
                fa   <= a;
                fmap <= gpr_map(a);
                gpr_ra <= gpr_map(a) >> 0;
                st   <= P_RD;
            end
            P_RD: st <= P_OPND;                             // data RAM read
            P_OPND: begin rv_q <= fmap[9] ? gpr_q : sfr_rd(fa); st <= P_EXEC; end
            P_EXEC: begin
                // ---------------- execute one instruction (MAME pic16x8x_device op_*)
                logic [7:0] rv, alu, st_new, wp, intc;
                logic       ee_rd;
                logic [2:0] cyc_n;
                logic       wr_f, wr_w, skip, alu_fl, pcl_wr;
                logic [7:0] res;
                logic [12:0] npc;
                npc = pc;
                rv = rv_q;
                cyc_n = 3'd1; wr_f = 1'b0; wr_w = 1'b0; skip = 1'b0; alu_fl = 1'b0; res = 8'd0; alu = 8'd0;
                ee_rd = 1'b0;
                st_new = status;
                // helpers on st_new
                if (op[13:7] == 7'd0) begin
                    case (op[6:0])
                        7'h08: begin cyc_n = 3'd2; sp <= sp - 3'd1; npc = stack[sp - 3'd1]; end                         // return
                        7'h09: begin cyc_n = 3'd2; sp <= sp - 3'd1; npc = stack[sp - 3'd1]; intcon[7] <= 1'b1; end    // retfie
                        7'h62: begin option <= w; if ((option ^ w) & 8'h0f) prescaler <= 8'd0; end                   // option
                        7'h63: begin st_new[4] = 1'b1; st_new[3] = 1'b0; sleeping <= 1'b1; end                       // sleep
                        7'h64: begin st_new[4] = 1'b1; st_new[3] = 1'b1; end                                          // clrwdt
                        7'h65: begin                                                                                   // tris porta
                            logic [7:0] t;
                            t = w | ~porta_msk;
                            if (t != tris_a) begin
                                tris_a <= t;
                                porta_we <= 1'b1; porta_val <= port_data_a & ~t & porta_msk; porta_mask <= ~t & porta_msk;
                            end
                        end
                        7'h66: tris_b <= w;                                                                            // tris portb
                        default: ;                                                                                     // nop / illegal
                    endcase
                end else if (g < 7'h20) begin
                    case (g[6:1])
                        6'h00: begin res = w; wr_f = 1'b1; end                                                         // movwf
                        6'h01: begin alu_fl = 1'b1; alu = 8'd0; st_new[2] = 1'b1;
                                     if (g[0]) begin res = 8'd0; wr_f = 1'b1; end else begin res = 8'd0; wr_w = 1'b1; end end  // clrf / clrw
                        6'h02: begin alu_fl = 1'b1; alu = rv - w; res = alu;                                            // subwf
                                     st_new[2] = (alu == 8'd0); st_new[0] = !(rv < alu); st_new[1] = !(rv[3:0] < alu[3:0]); end
                        6'h03: begin alu_fl = 1'b1; alu = rv - 8'd1; res = alu; st_new[2] = (alu == 8'd0); end          // decf
                        6'h04: begin alu_fl = 1'b1; alu = rv | w; res = alu; st_new[2] = (alu == 8'd0); end             // iorwf
                        6'h05: begin alu_fl = 1'b1; alu = rv & w; res = alu; st_new[2] = (alu == 8'd0); end             // andwf
                        6'h06: begin alu_fl = 1'b1; alu = rv ^ w; res = alu; st_new[2] = (alu == 8'd0); end             // xorwf
                        6'h07: begin alu_fl = 1'b1; alu = rv + w; res = alu;                                            // addwf
                                     st_new[2] = (alu == 8'd0); st_new[0] = (rv > alu); st_new[1] = (rv[3:0] > alu[3:0]); end
                        6'h08: begin alu_fl = 1'b1; alu = rv; res = alu; st_new[2] = (alu == 8'd0); end                 // movf
                        6'h09: begin alu_fl = 1'b1; alu = ~rv; res = alu; st_new[2] = (alu == 8'd0); end                // comf
                        6'h0a: begin alu_fl = 1'b1; alu = rv + 8'd1; res = alu; st_new[2] = (alu == 8'd0); end          // incf
                        6'h0b: begin alu = rv - 8'd1; res = alu; skip = (alu == 8'd0); end                              // decfsz
                        6'h0c: begin alu_fl = 1'b1; alu = {status[0], rv[7:1]}; res = alu; st_new[0] = rv[0]; end       // rrf
                        6'h0d: begin alu_fl = 1'b1; alu = {rv[6:0], status[0]}; res = alu; st_new[0] = rv[7]; end       // rlf
                        6'h0e: begin res = {rv[3:0], rv[7:4]}; end                                                      // swapf
                        6'h0f: begin alu = rv + 8'd1; res = alu; skip = (alu == 8'd0); end                              // incfsz
                    endcase
                    if (g[6:1] != 6'h00 && g[6:1] != 6'h01) begin
                        if (dst_f) wr_f = 1'b1; else wr_w = 1'b1;
                    end
                end else if (g < 7'h40) begin
                    case (g[5:3])
                        3'd4: begin res = rv & ~(8'd1 << bpos); wr_f = 1'b1; end                                       // bcf
                        3'd5: begin res = rv | (8'd1 << bpos); wr_f = 1'b1; end                                        // bsf
                        3'd6: skip = !rv[bpos];                                                                        // btfsc
                        default: skip = rv[bpos];                                                                      // btfss
                    endcase
                end else if (g < 7'h50) begin                                                                         // call
                    cyc_n = 3'd2; stack[sp] <= pc; sp <= sp + 3'd1; npc = {pclath[4:3], op[10:0]};
                end else if (g < 7'h60) begin                                                                         // goto
                    cyc_n = 3'd2; npc = {pclath[4:3], op[10:0]};
                end else if (g < 7'h68) begin                                                                         // movlw
                    w <= k;
                end else if (g < 7'h70) begin                                                                         // retlw
                    cyc_n = 3'd2; w <= k; sp <= sp - 3'd1; npc = stack[sp - 3'd1];
                end else begin
                    alu_fl = 1'b1;
                    case (g[3:1])
                        3'd0: begin alu = k | w; st_new[2] = (alu == 8'd0); end                                         // iorlw
                        3'd1: begin alu = k & w; st_new[2] = (alu == 8'd0); end                                         // andlw
                        3'd2, 3'd3: begin alu = w ^ k; st_new[2] = (alu == 8'd0); end                                   // xorlw
                        3'd4, 3'd5: begin alu = k - w; st_new[2] = (alu == 8'd0);                                       // sublw
                                          st_new[0] = !(k < alu); st_new[1] = !(k[3:0] < alu[3:0]); end
                        default: begin alu = k + w; st_new[2] = (alu == 8'd0);                                          // addlw
                                       st_new[0] = (k > alu); st_new[1] = (k[3:0] > alu[3:0]); end
                    endcase
                    w <= alu;
                end
                if (skip) begin npc = npc + 13'd1; cyc_n = cyc_n + 3'd1; end

                // ---------------- register write (file destination); MAME store_regfile, SFR side effects
                pcl_wr = 1'b0;
                wp = alu_fl ? 8'h1f : 8'h18;          // status bits protected from the file write
                if (wr_w) w <= res;
                if (wr_f) begin
                    logic [6:0] lo;
                    lo = fa[6:0];
                    if (fmap[9]) begin
                        gpr_we <= 1'b1; gpr_wa <= fmap[8:0]; gpr_wd <= res;
                    end else if (lo == 7'h00 || lo == 7'h07) begin
                        // not physical
                    end else if (lo == 7'h02) begin
                        npc = {pclath[4:0], res}; cyc_n = cyc_n + 3'd1; pcl_wr = 1'b1;
                    end else if (lo == 7'h03) begin
                        st_new = ((st_new & wp) | (res & ~wp)) & status_mask;
                    end else if (lo == 7'h04) fsr <= res;
                    else if (lo == 7'h0a) pclath <= {3'd0, res[4:0]};
                    else if (lo == 7'h0b) intcon <= res;
                    else begin
                        // banked SFRs
                        logic [1:0] bk;
                        bk = model_628 ? fa[8:7] : {1'b0, fa[7]};
                        case ({bk, lo})
                            {2'd0, 7'h01}, {2'd2, 7'h01}: begin tmr0 <= res; delay_timer <= 3'd2;   // MAME: inst+2, less this instruction
                                                                  if (!option[3]) prescaler <= 8'd0; end
                            {2'd1, 7'h01}, {2'd3, 7'h01}: begin option <= res; if ((option ^ res) & 8'h0f) prescaler <= 8'd0; end
                            {2'd0, 7'h05}: begin port_data_a <= res & porta_msk; porta_we <= 1'b1;
                                                 porta_val <= res & ~tris_a & porta_msk; porta_mask <= ~tris_a & porta_msk; end
                            {2'd1, 7'h05}: begin
                                logic [7:0] t;
                                t = res | ~porta_msk;
                                if (t != tris_a) begin
                                    tris_a <= t;
                                    porta_we <= 1'b1; porta_val <= port_data_a & ~t & porta_msk; porta_mask <= ~t & porta_msk;
                                end
                            end
                            {2'd0, 7'h06}, {2'd2, 7'h06}: begin port_data_b <= res; portb_mm <= portb_rd & 8'hf0; end
                            {2'd1, 7'h06}, {2'd3, 7'h06}: tris_b <= res;
                            default: begin
                                if (!model_628) begin
                                    case ({bk[0], lo})
                                        {1'b0, 7'h08}: eedata <= res;
                                        {1'b0, 7'h09}: eeadr <= res;
                                        {1'b1, 7'h08}: ;                         // EECON1: below
                                        default: ;
                                    endcase
                                end else begin
                                    case ({bk, lo})
                                        {2'd0, 7'h0c}: pir1 <= res & 8'hf7;
                                        {2'd0, 7'h10}: t1con <= res;
                                        {2'd0, 7'h12}: t2con <= res;
                                        {2'd0, 7'h17}: ccp1con <= res;
                                        {2'd0, 7'h18}: rcsta <= res;
                                        {2'd0, 7'h1f}: cmcon <= res;
                                        {2'd1, 7'h0c}: pie1 <= res & 8'hf7;
                                        {2'd1, 7'h0e}: pcon <= res;
                                        {2'd1, 7'h18}: txsta <= res;
                                        {2'd1, 7'h1a}: eedata <= res;
                                        {2'd1, 7'h1b}: eeadr <= res;
                                        {2'd1, 7'h1f}: vrcon <= res;
                                        default: ;
                                    endcase
                                end
                            end
                        endcase
                        // EECON1 / EECON2 (F84A: 0x88/0x89; F628A: 0x9c/0x9d)
                        if ((!model_628 && bk[0] && lo == 7'h08) || (model_628 && bk == 2'd1 && lo == 7'h1c)) begin
                            logic [7:0] e;
                            e = eecon1;
                            e[2] = res[2];
                            e = e & (res | ~8'h18);
                            if (res[1] && e[2] && ee_unlock == 2'd2) begin
                                ee_we <= 1'b1; ee_a <= eeadr[6:0]; ee_wd <= eedata;
                                if (!model_628) e[4] = 1'b1; else pir1[7] <= 1'b1;
                            end
                            eecon1 <= e;
                            ee_unlock <= 2'd0;
                            if (res[0]) begin ee_a <= eeadr[6:0]; ee_rd = 1'b1; end
                        end else if ((!model_628 && bk[0] && lo == 7'h09) || (model_628 && bk == 2'd1 && lo == 7'h1d)) begin
                            ee_unlock <= (ee_unlock == 2'd0 && res == 8'h55) ? 2'd1 : (ee_unlock == 2'd1 && res == 8'haa) ? 2'd2 : 2'd0;
                        end
                    end
                end
                // a read of PORTB (any instruction reading it) updates the change latch
                if (!fmap[9] && is_portb(fa) && !(op[13:7] == 7'd0) && g < 7'h40) portb_mm <= portb_rd & 8'hf0;
                status <= st_new;

                tm_cyc  <= cyc_n;
                tm_wr   <= wr_f && !fmap[9] && fa[6:0] == 7'h01 && !fa[7];
                ee_rd_q <= ee_rd;
                pc <= npc;
                icyc <= cyc_n;
                wait_cyc <= cyc_n[1:0] - 2'd1;
                dbg_retire <= 1'b1;
                dbg_count <= dbg_count + 32'd1;
                st <= P_TMR;
            end
            P_TMR: begin
                // ---------------- TMR0 (MAME update_timer after the instruction, internal clock)
                logic [3:0] cnt;
                logic [8:0] div, ps;
                logic [8:0] nt;
                logic [2:0] dl;
                cnt = option[5] ? 4'd0 : {1'b0, tm_cyc};
                dl = delay_timer;
                if (!tm_wr) begin                       // a TMR0 write set the delay instead
                    if (dl != 3'd0) begin
                        logic signed [4:0] c2;
                        c2 = $signed({1'b0, cnt}) - $signed({2'b0, dl});
                        delay_timer <= (dl > tm_cyc) ? dl - tm_cyc : 3'd0;
                        cnt = (c2 > 0 && dl <= tm_cyc) ? c2[3:0] : 4'd0;
                    end
                    if (cnt != 4'd0) begin
                        if (!option[3]) begin
                            div = 9'd2 << option[2:0];
                            ps = {1'b0, prescaler} + {5'd0, cnt};
                            if (ps >= div) begin
                                nt = {1'b0, tmr0} + 9'd1;     // counts <= 2 < 2 div: at most one increment
                                prescaler <= ps - div;
                                tmr0 <= nt[7:0];
                                if (nt[8]) intcon[2] <= 1'b1;
                            end else prescaler <= ps[7:0];
                        end else begin
                            nt = {1'b0, tmr0} + {5'd0, cnt};
                            tmr0 <= nt[7:0];
                            if (nt[8]) intcon[2] <= 1'b1;
                        end
                    end
                end
                st <= ee_rd_q ? P_EE : P_IDLE;
            end
            P_EE:  st <= P_EE2;                             // EEPROM read (address registered last clock)
            P_EE2: begin eedata <= ee_q; st <= P_IDLE; end
            default: st <= P_IDLE;
            endcase
        end
    end
endmodule
