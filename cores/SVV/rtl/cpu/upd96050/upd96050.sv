// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  NEC uPD96050 DSP (uPD7725 / uPD77C25 family) -- synthesisable core.
//
//  Used on the Seta SSV protection daughterboard as the "ST010" in Drift Out
//  '94, Storm Blade and Twin Eagle II (ssv.cpp:2468 / :2642 / :2755).
//
//  REFERENCE
//  ---------
//  Bit-for-bit against MAME's portable core (originally byuu's):
//      D:\Arcade\AI\MAMESOURCE\mame\src\devices\cpu\upd7725\upd7725.cpp
//  Every decode field, ALU op, flag rule and register side effect below cites
//  the line range it was taken from. Where MAME's behaviour is questionable
//  (see the DP MODIFY note) this core reproduces MAME rather than guessing,
//  because MAME is the only reference the testbench can be checked against.
//
//  ORGANISATION
//  ------------
//  Harvard: 16K x 24-bit program words, 2K x 16-bit data ROM, 2048 x 16 data
//  RAM. Program and data ROM are EXTERNAL ports -- see the M10K note below.
//  The data RAM lives here, in one true-dual-port M10K group, port B handed
//  out to the host so the $482000 window needs no arbitration.
//
//  WHY PROGRAM MEMORY IS NOT INTERNAL  (measured, not guessed)
//  -----------------------------------------------------------
//  16384 words x 24 bits = 393,216 bits. A Cyclone V M10K holds 10,240 bits
//  but only reaches that in x10/x20/x40 aspect ratios; 24 bits packs as
//  3 x (1024 x 10), i.e. 16 deep x 3 wide = 48 M10K, and no other legal
//  aspect does better (256x40 -> 64, 512x20 -> 64, 512x16 -> 64,
//  1024x8 -> 48, 2048x4 -> 48). 48 is the floor.
//
//  SSV has 43 M10K free (fit.summary: 510/553). The program ROM therefore
//  CANNOT be on-chip, and is exposed as a request/valid fetch port instead.
//  The port stalls cleanly -- the core waits in S_P/S_K until prg_valid -- and
//  that stall path is covered by the ISA bench re-run with +PRGLAT=8.
//
//  Recommended backing, which needs no cache RAM at all: MAME's dspprg region
//  is 32 bits per instruction (4 bytes, 3 used), so four consecutive
//  instructions are exactly one aligned 16-byte SDRAM read on a 128-bit port
//  of the kind ssv_core already uses for graphics rows. A single 16-byte
//  prefetch line plus tag is ~141 flops and ZERO M10K, and turns 2.5 M
//  fetches/s into 0.63 M SDRAM accesses/s. At ce = 2.5 MHz against
//  clk_sys = 48.324 MHz there are ~19 clk_sys per instruction of which the
//  FSM uses 5, so ~14 clk_sys (28 clk_ram) of slack absorbs the miss.
//
//  TIMING
//  ------
//  The real part executes one instruction every 4 clocks (MAME
//  execute_min_cycles/execute_max_cycles both return 4, upd7725.cpp:254-268),
//  so 10 MHz -> 2.5 MIPS. This core runs a fixed 5-state sequence at `clk`
//  and starts an instruction only when `ce` is high, so the instruction rate
//  is the `ce` pulse rate, decoupled from the state count. For MAME parity on
//  SSV (clk_sys = 48.324 MHz) use the same fractional accumulator style as
//  ce_cpu with increment 3391: 3391/65536 * 48.324 MHz = 2.5003 MHz.
//  MAME's own comment on the 10 MHz figure is "// TODO: correct?", so this is
//  not a precise number to begin with.
//
//  NOT IMPLEMENTED (matching MAME, which also omits them)
//  -----------------------------------------------------
//  * Serial port (SI/SO shifting, SCK, SIEN/SOEN, SORQ). SI is never written
//    and SIACK/SOACK are hardwired 0, exactly as in MAME -- so JNSIAK and
//    JNSOAK always branch and JSIAK/JSOAK never do. SO is written and read
//    (JMPSO works) because that costs nothing.
//  * DMA / DACK.
//============================================================================

`timescale 1ns/1ps

module upd96050 (
    input               clk,
    // Instruction-issue enable. One instruction is started per clk on which
    // `ce` is high while the core is idle. Tie high to run at clk/5.
    input               ce,
    input               rst,       // cold/download reset: device_start state
    input               soft_rst,  // /RESET: MAME device_reset retention

    //------------------------------------------------------------------------
    // Program memory: 16384 x 24. MAME fetches opcode = read_dword(pc) >> 8
    // from a 32-bit big-endian space (upd7725.cpp:315), i.e. for ROM byte
    // offset 4*pc the opcode is {b0, b1, b2} and b3 is discarded.
    // prg_req is held until prg_valid; prg_addr is stable for the whole burst.
    //------------------------------------------------------------------------
    output       [13:0] prg_addr,
    output              prg_req,
    input        [23:0] prg_data,
    input               prg_valid,

    //------------------------------------------------------------------------
    // Data ROM. MAME configures a 12-bit word space (upd7725.cpp:54) of which
    // ssv.cpp:346 maps only 0x000-0x7ff, so reads at addr[11] return 0 there.
    // Synchronous: drom_data must be ROM[drom_addr] one clk after drom_addr.
    //------------------------------------------------------------------------
    output       [11:0] drom_addr,
    input        [15:0] drom_data,

    //------------------------------------------------------------------------
    // Host data port -- the $480000 byte on SSV (necdsp data_r / data_w,
    // upd7725.cpp:578-631).  host_dp_dout is the value a read would return
    // *now* and carries no side effect, mirroring MAME's
    // side_effects_disabled() path; assert host_dp_rd for exactly one clk to
    // apply the SR side effects of a real read.
    //------------------------------------------------------------------------
    input               host_dp_rd,
    input               host_dp_wr,
    input         [7:0] host_dp_din,
    output        [7:0] host_dp_dout,
    // status_r (upd7725.cpp:572) = SR[15:8]. Not mapped anywhere in ssv.cpp,
    // exposed because it costs nothing and other uPD96050 boards do map it.
    output        [7:0] host_sr,

    //------------------------------------------------------------------------
    // Host data-RAM port -- the $482000-$482fff window on SSV. Word-indexed
    // with a byte enable, matching dataram_w(addr, data, mem_mask)
    // (upd7725.h:179). Read latency is one clk: host_ram_dout is the byte for
    // the address presented on the previous clk.
    //------------------------------------------------------------------------
    input        [10:0] host_ram_addr,
    input               host_ram_high,   // 1 = high byte of the 16-bit word
    input               host_ram_wr,
    input         [7:0] host_ram_din,
    output        [7:0] host_ram_dout,

    input               int_req,
    output              p0,
    output              p1
`ifdef SIMULATION
    ,
    // Simulation-only DSP observability.  Release synthesis has no debug
    // mirror outputs or associated fanout.
    output              dbg_retire,
    output       [23:0] dbg_ir,
    output       [13:0] dbg_pc,
    output       [15:0] dbg_a,
    output       [15:0] dbg_b,
    output        [5:0] dbg_flaga,
    output        [5:0] dbg_flagb,
    output       [15:0] dbg_k,
    output       [15:0] dbg_l,
    output       [15:0] dbg_m,
    output       [15:0] dbg_n,
    output       [15:0] dbg_dp,
    output       [15:0] dbg_rp,
    output       [15:0] dbg_tr,
    output       [15:0] dbg_trb,
    output       [15:0] dbg_dr,
    output       [15:0] dbg_sr,
    output       [15:0] dbg_so,
    output       [15:0] dbg_idb,
    output        [3:0] dbg_sp,
    output              dbg_ram_write,
    output       [10:0] dbg_ram_addr,
    output       [15:0] dbg_ram_wdata,
    output       [10:0] dbg_host_ram_addr,
    output              dbg_host_ram_high,
    output       [15:0] dbg_host_ram_q,
    output        [7:0] dbg_host_ram_dout,
    output        [2:0] dbg_state
`endif
);

//==========================================================================
// Register file (upd7725.h:110-134)
//==========================================================================
logic [13:0] pc;
logic [13:0] stack [0:15];
logic  [3:0] sp;
logic [15:0] rp, dp, k, l, m, n, areg, breg, tr, trb, dr, si, so, idb;

// Flag word packing follows MAME's Flag::operator unsigned() (upd7725.h:78):
// bit5 s1, bit4 s0, bit3 c, bit2 z, bit1 ov1, bit0 ov0.
localparam int F_S1 = 5, F_S0 = 4, F_C = 3, F_Z = 2, F_OV1 = 1, F_OV0 = 0;
logic  [5:0] flaga, flagb;

// SR (upd7725.h:90). Bits 6:2 have no storage in MAME's Status struct, so a
// read of SR always returns 0 there and a write to them is discarded.
logic sr_rqm, sr_usf1, sr_usf0, sr_drs, sr_dma, sr_drc, sr_soc, sr_sic, sr_ei,
      sr_p1, sr_p0;
wire [15:0] sr_val = {sr_rqm, sr_usf1, sr_usf0, sr_drs, sr_dma, sr_drc,
                      sr_soc, sr_sic, sr_ei, 5'b00000, sr_p1, sr_p0};

// Serial handshake acks: MAME clears them at reset and never sets them.
wire siack = 1'b0;
wire soack = 1'b0;

assign p0 = sr_p0;
assign p1 = sr_p1;
assign host_sr = sr_val[15:8];

//==========================================================================
// Sequencer
//==========================================================================
localparam logic [2:0] S_IDLE = 3'd0,
                       S_P    = 3'd1,   // capture dataRAM[DP] and dataROM[RP]
                       S_K    = 3'd2,   // capture dataRAM[DP|0x40], await opcode
                       S_EXEC = 3'd3,
                       S_MUL  = 3'd4;
logic  [2:0] state;
logic [23:0] ir;
logic        ir_valid;
logic  [1:0] irq_firing;               // upd7725.cpp:142-146
logic        int_q;

// Captured operands. All three addresses depend only on DP/RP, never on the
// opcode, so they are fetched in parallel with the instruction.
logic [15:0] ram_p;                    // dataRAM[DP & 0x7ff]
logic [15:0] ram_k;                    // dataRAM[(DP & 0x7ff) | 0x40]
logic [15:0] rom_q;                    // dataROM[RP]

// opcode is available this clk if it was latched in S_P or arrives now
wire fetch_now = prg_req && prg_valid;
wire have_ir   = ir_valid || fetch_now;
wire [23:0] ir_cur = ir_valid ? ir : prg_data;

assign prg_req  = (state == S_P || state == S_K) && !ir_valid && (irq_firing == 2'd0);
assign prg_addr = pc;
assign drom_addr = rp[11:0];

//==========================================================================
// Opcode fields (upd7725.cpp:350-358, :482-484, :543-545)
//==========================================================================
wire  [1:0] op_class  = ir_cur[23:22];
wire  [1:0] f_pselect = ir_cur[21:20];
wire  [3:0] f_alu     = ir_cur[19:16];
wire        f_asl     = ir_cur[15];
wire  [1:0] f_dpl     = ir_cur[14:13];
wire  [3:0] f_dphm    = ir_cur[12:9];
wire        f_rpdcr   = ir_cur[8];
wire  [3:0] f_src     = ir_cur[7:4];
wire  [3:0] f_opdst   = ir_cur[3:0];
wire  [8:0] f_brch    = ir_cur[21:13];
wire [10:0] f_na      = ir_cur[12:2];
wire  [1:0] f_bank    = ir_cur[1:0];
wire [15:0] f_id      = ir_cur[21:6];   // uint16_t id = opcode >> 6
wire  [3:0] f_lddst   = ir_cur[3:0];

localparam logic [1:0] C_OP = 2'd0, C_RT = 2'd1, C_JP = 2'd2, C_LD = 2'd3;

function automatic [15:0] bitrev16(input [15:0] v);
    integer i;
    begin
        bitrev16 = 16'h0000;
        for (i = 0; i < 16; i = i + 1) bitrev16[i] = v[15-i];
    end
endfunction

//==========================================================================
// Combinational execute
//==========================================================================
logic [13:0] n_pc;
logic  [3:0] n_sp;
logic [15:0] n_rp, n_dp, n_k, n_l, n_a, n_b, n_tr, n_trb, n_dr, n_so, n_idb;
logic  [5:0] n_flaga, n_flagb;
logic        n_rqm, n_usf1, n_usf0, n_drs, n_dma, n_drc, n_soc, n_sic, n_ei,
             n_p1, n_p0;
logic        stk_push, stk_pop;
logic        ram_we;
logic [15:0] ram_wdata;

// shared LD stage inputs
logic [15:0] ld_id;
logic  [3:0] ld_dst;
logic        ld_en;

// ALU
logic [15:0] alu_p, alu_pv, alu_q, alu_r;
logic        alu_cin;
logic  [5:0] fin;
logic        nf_s0, nf_z, nf_s1, nf_c, nf_ov0, nf_ov1;
logic [15:0] jps, jpl;

always_comb begin
    // ---- hold everything by default
    n_pc    = pc;
    n_sp    = sp;
    n_rp    = rp;   n_dp = dp;   n_k = k;   n_l = l;
    n_a     = areg; n_b  = breg; n_tr = tr; n_trb = trb;
    n_dr    = dr;   n_so = so;   n_idb = idb;
    n_flaga = flaga; n_flagb = flagb;
    n_rqm = sr_rqm; n_usf1 = sr_usf1; n_usf0 = sr_usf0; n_drs = sr_drs;
    n_dma = sr_dma; n_drc  = sr_drc;  n_soc  = sr_soc;  n_sic = sr_sic;
    n_ei  = sr_ei;  n_p1   = sr_p1;   n_p0   = sr_p0;
    stk_push = 1'b0; stk_pop = 1'b0;
    ram_we = 1'b0; ram_wdata = 16'h0000;

    ld_en  = (op_class != C_JP);
    ld_id  = (op_class == C_LD) ? f_id  : n_idb;
    ld_dst = (op_class == C_LD) ? f_lddst : f_opdst;

    alu_p = 16'h0000; alu_pv = 16'h0000; alu_q = 16'h0000; alu_r = 16'h0000;
    alu_cin = 1'b0; fin = 6'h00;
    nf_s0 = 1'b0; nf_z = 1'b0; nf_s1 = 1'b0;
    nf_c = 1'b0; nf_ov0 = 1'b0; nf_ov1 = 1'b0;
    jps = 16'h0000; jpl = 16'h0000;

    //----------------------------------------------------------------------
    // OP / RT source select -> IDB   (upd7725.cpp:360-377)
    //----------------------------------------------------------------------
    if (op_class == C_OP || op_class == C_RT) begin
        case (f_src)
            4'd0:  n_idb = trb;
            4'd1:  n_idb = areg;
            4'd2:  n_idb = breg;
            4'd3:  n_idb = tr;
            4'd4:  n_idb = dp;
            4'd5:  n_idb = rp;
            4'd6:  n_idb = rom_q;
            4'd7:  n_idb = 16'h8000 - {15'd0, flaga[F_S1]};      // SGN
            4'd8:  begin n_idb = dr; n_rqm = 1'b1; end
            4'd9:  n_idb = dr;
            4'd10: n_idb = sr_val;
            4'd11: n_idb = si;
            4'd12: n_idb = bitrev16(si);
            4'd13: n_idb = k;
            4'd14: n_idb = l;
            4'd15: n_idb = ram_p;
        endcase
        ld_id = n_idb;                  // exec_ld((idb << 6) + dst)

        //------------------------------------------------------------------
        // ALU  (upd7725.cpp:379-458).  alu == 0 leaves the accumulator and
        // both flag words completely untouched.
        //------------------------------------------------------------------
        if (f_alu != 4'd0) begin
            case (f_pselect)
                2'd0: alu_p = ram_p;
                2'd1: alu_p = n_idb;
                2'd2: alu_p = m;
                2'd3: alu_p = n;
            endcase
            alu_pv  = alu_p;
            alu_q   = f_asl ? breg  : areg;
            fin     = f_asl ? flagb : flaga;
            alu_cin = f_asl ? flaga[F_C] : flagb[F_C];

            case (f_alu)
                4'h1: alu_r = alu_q | alu_p;                       // OR
                4'h2: alu_r = alu_q & alu_p;                       // AND
                4'h3: alu_r = alu_q ^ alu_p;                       // XOR
                4'h4: alu_r = alu_q - alu_p;                       // SUB
                4'h5: alu_r = alu_q + alu_p;                       // ADD
                4'h6: alu_r = alu_q - alu_p - {15'd0, alu_cin};    // SBB
                4'h7: alu_r = alu_q + alu_p + {15'd0, alu_cin};    // ADC
                4'h8: begin alu_r = alu_q - 16'd1; alu_pv = 16'd1; end  // DEC
                4'h9: begin alu_r = alu_q + 16'd1; alu_pv = 16'd1; end  // INC
                4'ha: alu_r = ~alu_q;                              // CMP
                4'hb: alu_r = {alu_q[15], alu_q[15:1]};            // SHR1/ASR
                4'hc: alu_r = {alu_q[14:0], alu_cin};              // SHL1/ROL
                4'hd: alu_r = {alu_q[13:0], 2'b11};                // SHL2
                4'he: alu_r = {alu_q[11:0], 4'b1111};              // SHL4
                4'hf: alu_r = {alu_q[7:0], alu_q[15:8]};           // XCHG
                default: alu_r = alu_q;
            endcase

            nf_s0 = alu_r[15];
            nf_z  = (alu_r == 16'h0000);
            // if (!flag.ov1) flag.s1 = flag.s0;  -- flag.ov1 is still the OLD
            // ov1 at this point, because MAME's earlier clears are overwritten
            // by "flag = regs.flaga" (upd7725.cpp:384-399).
            nf_s1 = fin[F_OV1] ? fin[F_S1] : nf_s0;

            case (f_alu)
                4'h1, 4'h2, 4'h3, 4'ha, 4'hd, 4'he, 4'hf: begin
                    nf_c = 1'b0; nf_ov0 = 1'b0; nf_ov1 = 1'b0;
                end
                4'hb: begin nf_c = alu_q[0];  nf_ov0 = 1'b0; nf_ov1 = 1'b0; end
                4'hc: begin nf_c = alu_q[15]; nf_ov0 = 1'b0; nf_ov1 = 1'b0; end
                4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9: begin
                    if (f_alu[0]) begin                            // addition
                        nf_ov0 = (alu_q[15] ^ alu_r[15]) &
                                 ~(alu_q[15] ^ alu_pv[15]);
                        nf_c   = (alu_r < alu_q);
                    end
                    else begin                                     // subtraction
                        nf_ov0 = (alu_q[15] ^ alu_r[15]) &
                                 (alu_q[15] ^ alu_pv[15]);
                        nf_c   = (alu_r > alu_q);
                    end
                    nf_ov1 = (nf_ov0 & fin[F_OV1]) ? (nf_s1 == nf_s0)
                                                   : (nf_ov0 | fin[F_OV1]);
                end
                default: begin nf_c = 1'b0; nf_ov0 = 1'b0; nf_ov1 = 1'b0; end
            endcase

            if (!f_asl) begin
                n_a     = alu_r;
                n_flaga = {nf_s1, nf_s0, nf_c, nf_z, nf_ov1, nf_ov0};
            end
            else begin
                n_b     = alu_r;
                n_flagb = {nf_s1, nf_s0, nf_c, nf_z, nf_ov1, nf_ov0};
            end
        end
    end

    //----------------------------------------------------------------------
    // LD stage (upd7725.cpp:543-570). Reached directly by an LD instruction
    // and as the move-destination stage of OP/RT, so a destination write
    // overrides the ALU result for the same accumulator -- MAME's order.
    //----------------------------------------------------------------------
    if (ld_en) begin
        n_idb = ld_id;
        case (ld_dst)
            4'd0:  ;
            4'd1:  n_a  = ld_id;
            4'd2:  n_b  = ld_id;
            4'd3:  n_tr = ld_id;
            4'd4:  n_dp = ld_id;
            4'd5:  n_rp = ld_id;
            4'd6:  begin n_dr = ld_id; n_rqm = 1'b1; end
            4'd7:  begin                                  // SR, mask 0x907c
                n_usf1 = ld_id[14]; n_usf0 = ld_id[13];
                n_dma  = ld_id[11]; n_drc  = ld_id[10];
                n_soc  = ld_id[9];  n_sic  = ld_id[8];
                n_ei   = ld_id[7];
                n_p1   = ld_id[1];  n_p0   = ld_id[0];
            end
            4'd8:  n_so = bitrev16(ld_id);
            4'd9:  n_so = ld_id;
            4'd10: n_k  = ld_id;
            4'd11: begin n_k = ld_id; n_l = rom_q; end
            4'd12: begin n_l = ld_id; n_k = ram_k; end
            4'd13: n_l  = ld_id;
            4'd14: n_trb = ld_id;
            4'd15: begin ram_we = 1'b1; ram_wdata = ld_id; end
        endcase
    end

    //----------------------------------------------------------------------
    // DP / RP modify (upd7725.cpp:462-472).
    //
    // NOTE, deliberately faithful: MAME masks with 0xf0, which discards DP
    // bits 15:8. That is exactly right for the uPD7725 (256-word data RAM,
    // DP = DPH[7:4]:DPL[3:0]) but the uPD96050 has 2048 words and therefore
    // three more DP bits that a DPINC/DPDEC/DPCLR here will zero. It is very
    // likely a MAME bug for this part. It is reproduced rather than "fixed"
    // because MAME is the only oracle the tests can be written against, and
    // MAME is what the three ST010 titles are known to run under. If a title
    // misbehaves on data-RAM addressing above word 0x0ff, this is the first
    // thing to revisit -- see the report accompanying this file.
    //----------------------------------------------------------------------
    if ((op_class == C_OP || op_class == C_RT) && ld_dst != 4'd4) begin
        case (f_dpl)
            2'd1: n_dp = {8'h00, n_dp[7:4], (n_dp[3:0] + 4'd1)};   // DPINC
            2'd2: n_dp = {8'h00, n_dp[7:4], (n_dp[3:0] - 4'd1)};   // DPDEC
            2'd3: n_dp = {8'h00, n_dp[7:4], 4'h0};                 // DPCLR
            default: ;
        endcase
        n_dp = n_dp ^ {8'h00, f_dphm, 4'h0};
    end
    if ((op_class == C_OP || op_class == C_RT) && f_rpdcr && ld_dst != 4'd5)
        n_rp = n_rp - 16'd1;

    //----------------------------------------------------------------------
    // JP (upd7725.cpp:481-541). PC has already been incremented by the fetch,
    // so jps takes its bit 13 from the incremented value.
    //----------------------------------------------------------------------
    jps = {2'b00, pc[13], f_bank, f_na};
    jpl = {2'b00, 1'b0,   f_bank, f_na};
    if (op_class == C_JP) begin
        case (f_brch)
            9'h000: n_pc = so[13:0];                                    // JMPSO
            9'h080: if (!flaga[F_C])   n_pc = jps[13:0];                // JNCA
            9'h082: if ( flaga[F_C])   n_pc = jps[13:0];                // JCA
            9'h084: if (!flagb[F_C])   n_pc = jps[13:0];                // JNCB
            9'h086: if ( flagb[F_C])   n_pc = jps[13:0];                // JCB
            9'h088: if (!flaga[F_Z])   n_pc = jps[13:0];                // JNZA
            9'h08a: if ( flaga[F_Z])   n_pc = jps[13:0];                // JZA
            9'h08c: if (!flagb[F_Z])   n_pc = jps[13:0];                // JNZB
            9'h08e: if ( flagb[F_Z])   n_pc = jps[13:0];                // JZB
            9'h090: if (!flaga[F_OV0]) n_pc = jps[13:0];                // JNOVA0
            9'h092: if ( flaga[F_OV0]) n_pc = jps[13:0];                // JOVA0
            9'h094: if (!flagb[F_OV0]) n_pc = jps[13:0];                // JNOVB0
            9'h096: if ( flagb[F_OV0]) n_pc = jps[13:0];                // JOVB0
            9'h098: if (!flaga[F_OV1]) n_pc = jps[13:0];                // JNOVA1
            9'h09a: if ( flaga[F_OV1]) n_pc = jps[13:0];                // JOVA1
            9'h09c: if (!flagb[F_OV1]) n_pc = jps[13:0];                // JNOVB1
            9'h09e: if ( flagb[F_OV1]) n_pc = jps[13:0];                // JOVB1
            9'h0a0: if (!flaga[F_S0])  n_pc = jps[13:0];                // JNSA0
            9'h0a2: if ( flaga[F_S0])  n_pc = jps[13:0];                // JSA0
            9'h0a4: if (!flagb[F_S0])  n_pc = jps[13:0];                // JNSB0
            9'h0a6: if ( flagb[F_S0])  n_pc = jps[13:0];                // JSB0
            9'h0a8: if (!flaga[F_S1])  n_pc = jps[13:0];                // JNSA1
            9'h0aa: if ( flaga[F_S1])  n_pc = jps[13:0];                // JSA1
            9'h0ac: if (!flagb[F_S1])  n_pc = jps[13:0];                // JNSB1
            9'h0ae: if ( flagb[F_S1])  n_pc = jps[13:0];                // JSB1
            9'h0b0: if ( dp[3:0] == 4'h0) n_pc = jps[13:0];             // JDPL0
            9'h0b1: if ( dp[3:0] != 4'h0) n_pc = jps[13:0];             // JDPLN0
            9'h0b2: if ( dp[3:0] == 4'hf) n_pc = jps[13:0];             // JDPLF
            9'h0b3: if ( dp[3:0] != 4'hf) n_pc = jps[13:0];             // JDPLNF
            9'h0b4: if (!siack) n_pc = jps[13:0];                       // JNSIAK
            9'h0b6: if ( siack) n_pc = jps[13:0];                       // JSIAK
            9'h0b8: if (!soack) n_pc = jps[13:0];                       // JNSOAK
            9'h0ba: if ( soack) n_pc = jps[13:0];                       // JSOAK
            9'h0bc: if (!sr_rqm) n_pc = jps[13:0];                      // JNRQM
            9'h0be: if ( sr_rqm) n_pc = jps[13:0];                      // JRQM
            9'h100: n_pc = {1'b0, jpl[12:0]};                           // LJMP
            9'h101: n_pc = {1'b1, jpl[12:0]};                           // HJMP
            9'h140: begin stk_push = 1'b1; n_sp = sp + 4'd1;
                          n_pc = {1'b0, jpl[12:0]}; end                 // LCALL
            9'h141: begin stk_push = 1'b1; n_sp = sp + 4'd1;
                          n_pc = {1'b1, jpl[12:0]}; end                 // HCALL
            default: ;      // unrecognised branch: fall through, as in MAME
        endcase
    end

    //----------------------------------------------------------------------
    // RT (upd7725.cpp:475-479): the OP body has already run above.
    //----------------------------------------------------------------------
    if (op_class == C_RT) begin
        stk_pop = 1'b1;
        n_sp    = sp - 4'd1;
        n_pc    = stack[sp - 4'd1];
    end
end

//==========================================================================
// Multiplier (upd7725.cpp:341-343) -- runs after EVERY instruction, using the
// values of K and L as they stand at the end of it.
//==========================================================================
wire signed [31:0] prod = $signed(k) * $signed(l);

//==========================================================================
// Data RAM: 2048 x 16, true dual port. Port A is the DSP, port B the host.
//==========================================================================
wire [10:0] dsp_ram_addr = (state == S_P || state == S_K)
                         ? (dp[10:0] | 11'h040)     // dst 12 reads DP|0x40
                         :  dp[10:0];
wire [15:0] dsp_ram_q;
wire [15:0] host_ram_q;
logic       host_ram_high_q;

// The inferred M10Ks have no runtime clear pin. Walk port A once on every
// cold/download reset so a newly selected ST010 descriptor gets MAME's clean
// device-start data RAM. Watchdog soft_rst deliberately does not arm this.
logic        cold_rst_q = 1'b0;
logic        ram_clear_active = 1'b0;
logic [10:0] ram_clear_addr = 11'd0;
always_ff @(posedge clk) begin
    cold_rst_q <= rst;
    if (rst && !cold_rst_q) begin
        ram_clear_active <= 1'b1;
        ram_clear_addr   <= 11'd0;
    end
    else if (ram_clear_active) begin
        if (ram_clear_addr == 11'h7ff)
            ram_clear_active <= 1'b0;
        else
            ram_clear_addr <= ram_clear_addr + 11'd1;
    end
end

wire [10:0] dataram_a_addr = ram_clear_active ? ram_clear_addr
                                               : dsp_ram_addr;
wire [15:0] dataram_a_data = ram_clear_active ? 16'h0000 : ram_wdata;
wire        dataram_a_we   = ram_clear_active ||
                             (ram_we && (state == S_EXEC));

s32_big_dpram #(
    .ADDR_WIDTH(11), .DATA_WIDTH(16), .BE_WIDTH(2), .NUM_WORDS(2048)
) dataram (
    .clock_a(clk),
    .address_a(dataram_a_addr),
    .data_a(dataram_a_data),
    .byteena_a(2'b11),
    .wren_a(dataram_a_we),
    .q_a(dsp_ram_q),

    .clock_b(clk),
    .address_b(host_ram_addr),
    // dsp_w duplicates the byte into both halves and lets the mask pick one
    // (ssv.cpp:359-362), which is exactly a byte enable here.
    .data_b({host_ram_din, host_ram_din}),
    .byteena_b({host_ram_high, ~host_ram_high}),
    .wren_b(host_ram_wr),
    .q_b(host_ram_q)
);

always_ff @(posedge clk) host_ram_high_q <= host_ram_high;
assign host_ram_dout = host_ram_high_q ? host_ram_q[15:8] : host_ram_q[7:0];

//==========================================================================
// Host data port (upd7725.cpp:578-631)
//==========================================================================
// The value a read returns now, without side effects.
assign host_dp_dout = (!sr_drc && sr_drs) ? dr[15:8] : dr[7:0];

//==========================================================================
// Sequential
//==========================================================================
integer i;
// One clk wide, asserted on the first clk after the multiplier has committed,
// so every architectural register (including M and N) is final when it is high.
logic retire_r;
`ifdef SIMULATION
assign dbg_retire = retire_r;
assign dbg_ir = ir;
assign dbg_pc = pc; assign dbg_a = areg; assign dbg_b = breg;
assign dbg_flaga = flaga; assign dbg_flagb = flagb;
assign dbg_k = k; assign dbg_l = l; assign dbg_m = m; assign dbg_n = n;
assign dbg_dp = dp; assign dbg_rp = rp; assign dbg_tr = tr; assign dbg_trb = trb;
assign dbg_dr = dr; assign dbg_sr = sr_val; assign dbg_so = so;
assign dbg_idb = idb; assign dbg_sp = sp;
assign dbg_ram_write = ram_we && (state == S_EXEC) && !ram_clear_active;
assign dbg_ram_addr = dsp_ram_addr;
assign dbg_ram_wdata = ram_wdata;
assign dbg_host_ram_addr = host_ram_addr;
assign dbg_host_ram_high = host_ram_high;
assign dbg_host_ram_q = host_ram_q;
assign dbg_host_ram_dout = host_ram_dout;
assign dbg_state = state;
`endif

always_ff @(posedge clk) begin
    if (rst) begin
        // MAME device_start establishes a completely clean device. Data RAM
        // is cleared by the port-A walker above because inferred M10Ks have no
        // runtime array reset.
        state      <= S_IDLE;
        pc         <= 14'd0;
        sp         <= 4'd0;
        rp         <= 16'd0; dp <= 16'd0;
        k          <= 16'd0; l  <= 16'd0; m <= 16'd0; n <= 16'd0;
        areg       <= 16'd0; breg <= 16'd0;
        tr         <= 16'd0; trb <= 16'd0;
        dr         <= 16'd0; si <= 16'd0; so <= 16'd0; idb <= 16'd0;
        flaga      <= 6'd0;  flagb <= 6'd0;
        sr_rqm     <= 1'b0; sr_usf1 <= 1'b0; sr_usf0 <= 1'b0; sr_drs <= 1'b0;
        sr_dma     <= 1'b0; sr_drc  <= 1'b0; sr_soc  <= 1'b0; sr_sic <= 1'b0;
        sr_ei      <= 1'b0; sr_p1   <= 1'b0; sr_p0   <= 1'b0;
        ir         <= 24'd0;
        ir_valid   <= 1'b0;
        irq_firing <= 2'd0;
        int_q      <= 1'b0;
        retire_r   <= 1'b0;
        ram_p      <= 16'd0; ram_k <= 16'd0; rom_q <= 16'd0;
        for (i = 0; i < 16; i = i + 1) stack[i] <= 14'd0;
    end
    else if (ram_clear_active) begin
        // A one-clock cold pulse can leave the M10K walker running after rst
        // falls. Do not let the DSP observe a partially cleared RAM image.
        state      <= S_IDLE;
        ir_valid   <= 1'b0;
        irq_firing <= 2'd0;
        int_q      <= 1'b0;
        retire_r   <= 1'b0;
    end
    else if (soft_rst) begin
        // MAME necdsp_device::device_reset(): /RESET clears PC, SR, A/B flags
        // and interrupt/serial handshake state. General registers, SP/stack,
        // and all data RAM survive. Abort the RTL's in-flight microsequence so
        // execution restarts cleanly at the retained-state PC zero.
        state      <= S_IDLE;
        pc         <= 14'd0;
        flaga      <= 6'd0;
        flagb      <= 6'd0;
        sr_rqm     <= 1'b0; sr_usf1 <= 1'b0; sr_usf0 <= 1'b0; sr_drs <= 1'b0;
        sr_dma     <= 1'b0; sr_drc  <= 1'b0; sr_soc  <= 1'b0; sr_sic <= 1'b0;
        sr_ei      <= 1'b0; sr_p1   <= 1'b0; sr_p0   <= 1'b0;
        ir         <= 24'd0;
        ir_valid   <= 1'b0;
        irq_firing <= 2'd0;
        int_q      <= 1'b0;
        retire_r   <= 1'b0;
        ram_p      <= 16'd0; ram_k <= 16'd0; rom_q <= 16'd0;
    end
    else begin
        retire_r <= 1'b0;
        case (state)
        //------------------------------------------------------------------
        S_IDLE: begin
            ir_valid <= 1'b0;
            if (ce) state <= S_P;
        end
        //------------------------------------------------------------------
        S_P: begin
            // dsp_ram_addr was DP and drom_addr was RP throughout S_IDLE, so
            // both outputs are settled now.
            ram_p <= dsp_ram_q;
            rom_q <= drom_data;
            if (irq_firing != 2'd0) begin
                // Interrupt entry (upd7725.cpp:318-331): a synthesised NOP,
                // then LCALL 0x100. Neither fetches, so PC is not advanced.
                ir       <= (irq_firing == 2'd1) ? 24'h000000 : 24'hA80400;
                ir_valid <= 1'b1;
                irq_firing <= (irq_firing == 2'd1) ? 2'd2 : 2'd0;
            end
            else if (prg_valid) begin
                ir       <= prg_data;
                ir_valid <= 1'b1;
                pc       <= pc + 14'd1;
            end
            state <= S_K;
        end
        //------------------------------------------------------------------
        S_K: begin
            ram_k <= dsp_ram_q;         // address held at DP|0x40 across stalls
            if (!ir_valid && prg_valid) begin
                ir       <= prg_data;
                ir_valid <= 1'b1;
                pc       <= pc + 14'd1;
            end
            if (have_ir) state <= S_EXEC;
        end
        //------------------------------------------------------------------
        S_EXEC: begin
            pc      <= n_pc;
            sp      <= n_sp;
            rp      <= n_rp;   dp <= n_dp;
            k       <= n_k;    l  <= n_l;
            areg    <= n_a;    breg <= n_b;
            tr      <= n_tr;   trb <= n_trb;
            dr      <= n_dr;   so <= n_so;   idb <= n_idb;
            flaga   <= n_flaga; flagb <= n_flagb;
            sr_rqm  <= n_rqm;  sr_usf1 <= n_usf1; sr_usf0 <= n_usf0;
            sr_drs  <= n_drs;  sr_dma  <= n_dma;  sr_drc  <= n_drc;
            sr_soc  <= n_soc;  sr_sic  <= n_sic;  sr_ei   <= n_ei;
            sr_p1   <= n_p1;   sr_p0   <= n_p0;
            if (stk_push) stack[sp] <= pc;      // PC is the return address
            ir_valid <= 1'b0;
            state    <= S_MUL;
        end
        //------------------------------------------------------------------
        S_MUL: begin
            m        <= prod[30:15];
            n        <= {prod[14:0], 1'b0};
            retire_r <= 1'b1;
            state    <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase

        //------------------------------------------------------------------
        // Host data port. Applied after the execute writes above so that the
        // pathological same-clk collision resolves host-last, matching MAME
        // where a host access is a device call outside the execute step.
        //------------------------------------------------------------------
        if (host_dp_wr) begin
            if (!sr_drc) begin
                if (!sr_drs) begin sr_drs <= 1'b1; dr[7:0]  <= host_dp_din; end
                else begin sr_rqm <= 1'b0; sr_drs <= 1'b0; dr[15:8] <= host_dp_din; end
            end
            else begin sr_rqm <= 1'b0; dr[7:0] <= host_dp_din; end
        end
        else if (host_dp_rd) begin
            if (!sr_drc) begin
                if (!sr_drs) sr_drs <= 1'b1;
                else begin sr_rqm <= 1'b0; sr_drs <= 1'b0; end
            end
            else sr_rqm <= 1'b0;
        end

        //------------------------------------------------------------------
        // INT pin (upd7725.cpp:275-289): rising edge, and only when EI is set.
        //------------------------------------------------------------------
        if (int_req && !int_q && sr_ei) begin
            irq_firing <= 2'd1;
            sr_ei      <= 1'b0;
        end
        int_q <= int_req;
    end
end

endmodule
