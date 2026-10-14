//------------------------------------------------------------------------------
// Hitachi H8/300H CPU core (advanced mode, 24-bit addresses, 16-bit bus).
//
// Written against MAME's cpu/h8 (ref/mame/h8.lst, h8.cpp) as the executable
// spec: the same instruction semantics, flag rules and state counts (every bus
// access is 2 states, "internal(n)" is n+1 states, one word of prefetch per
// instruction). Only the H8/300H instruction set is implemented -- the rows of
// h8.lst tagged `h` or untagged -- not the H8S additions.
//
// Bus: level request (bus_rd / bus_wr held with bus_addr until bus_ack), one
// bus_ack pulse per access; bus_word selects a 16-bit access at an even
// address, otherwise a byte access whose lane bus_addr[0] selects ([15:8] for
// an even address, [7:0] for odd; byte writes drive the byte on both lanes).
// The CPU advances one state per `cen`; an access that has been acknowledged
// by the next state costs the nominal 2 states, otherwise it waits.
//
// Interrupts: irq_vector is the interrupt controller's current vector (0 =
// none) after its own priority/mask filtering; the CPU takes it between
// instructions (except after LDC/ANDC/ORC/XORC, as MAME) and pulses irq_ack
// with the vector when it starts the entry sequence.
//
// Debug: dbg_istart pulses (one clock) when an instruction's first word is
// fetched, with dbg_pc = its address; dbg_irq pulses when an interrupt is
// taken, with dbg_npc = the address pushed. The trace-replay bench
// (sim/run_h8.sh) compares these against MAME's trace.
//------------------------------------------------------------------------------
`default_nettype none

module h8300h_core (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,

    // bus requests: a new request each time req_tog changes (h8300h issues it)
    output logic [23:0] nreq_addr,
    output logic        nreq_rd,
    output logic        nreq_wr,
    output logic        nreq_word,
    output logic [15:0] nreq_wdata,
    output logic        req_tog,
    input  logic [15:0] mdata_in,       // last read data (changes on any clock)
    input  logic        bus_done_in,    // the last request was acknowledged

    input  logic  [7:0] irq_vector_in,
    output logic        irq_ack_tog,
    output logic  [7:0] irq_ack_vector,
    output logic  [7:0] ccr_out,

    // divider (runs in h8300h): operands and a start toggle out, results in
    output logic        dv_tog,
    output logic [31:0] dv_n,
    output logic [15:0] dv_d,
    input  logic [31:0] dv_q,
    input  logic [31:0] dv_rem,

    output logic        istart_tog,
    output logic [23:0] dbg_pc,
    output logic        irq_tog,
    output logic [23:0] dbg_npc,
    output logic [31:0] dbg_er0, dbg_er1, dbg_er2, dbg_er3, dbg_er4, dbg_er5, dbg_er6, dbg_er7,
    output logic        dbg_sleep
);
    // ------------------------------------------------------------ state
    logic [31:0] er [8] /* verilator public_flat_rw */;
    logic [23:0] pc /* verilator public_flat_rw */;
    logic  [7:0] ccr /* verilator public_flat_rw */;
    logic [15:0] ir [5];
    logic  [2:0] nw;                 // words of the current instruction fetched
    logic [31:0] tmp1, tmp2;
    logic [23:0] ea;
    logic  [4:0] wait_n;             // internal states still to spend
    logic  [4:0] step;
    logic        noirq;              // the next boundary must not take an interrupt
    logic  [7:0] cur_vec;
    logic  [7:0] irq_vector;        // the controller's vector, sampled on the enable

    localparam F_C = 0, F_V = 1, F_Z = 2, F_N = 3, F_H = 5, F_I = 7;

    assign ccr_out = ccr;
    assign dbg_er0 = er[0]; assign dbg_er1 = er[1]; assign dbg_er2 = er[2]; assign dbg_er3 = er[3];
    assign dbg_er4 = er[4]; assign dbg_er5 = er[5]; assign dbg_er6 = er[6]; assign dbg_er7 = er[7];

    typedef enum logic [3:0] {
        S_RESET0, S_RESET1, S_RESET2, S_FETCH, S_FETCHW, S_EXEC, S_BUS, S_WAIT, S_IRQ, S_SLEEP
    } state_t;
    state_t state /* verilator public_flat_rw */, ret_state;
    logic [4:0] ret_step;

    // ------------------------------------------------------------ register access helpers
    function automatic logic [7:0] r8(input logic [3:0] i);
        r8 = i[3] ? er[i[2:0]][7:0] : er[i[2:0]][15:8];
    endfunction
    function automatic logic [15:0] r16(input logic [3:0] i);
        r16 = i[3] ? er[i[2:0]][31:16] : er[i[2:0]][15:0];
    endfunction
    function automatic logic [31:0] rsz(input logic [1:0] sz, input logic [3:0] i);
        case (sz)
            2'd0: rsz = {24'd0, r8(i)};
            2'd1: rsz = {16'd0, r16(i)};
            default: rsz = er[i[2:0]];
        endcase
    endfunction
    // write-back tasks operate on the register file inside the main process
    task automatic w8(input logic [3:0] i, input logic [7:0] v);
        if (i[3]) er[i[2:0]][7:0] <= v; else er[i[2:0]][15:8] <= v;
    endtask
    task automatic w16(input logic [3:0] i, input logic [15:0] v);
        if (i[3]) er[i[2:0]][31:16] <= v; else er[i[2:0]][15:0] <= v;
    endtask
    task automatic wsz(input logic [1:0] sz, input logic [3:0] i, input logic [31:0] v);
        case (sz)
            2'd0: w8(i, v[7:0]);
            2'd1: w16(i, v[15:0]);
            default: er[i[2:0]] <= v;
        endcase
    endtask

    // ------------------------------------------------------------ decode
    // groups
    typedef enum logic [4:0] {
        G_ALU, G_LOAD, G_STORE, G_BITMEM, G_BCC, G_BSR, G_JMP, G_JSR, G_RTS, G_RTE, G_TRAPA,
        G_LDCM, G_STCM, G_EEPMOV, G_SLEEP, G_NOP, G_ILL
    } grp_t;
    // operations (ALU and bit ops)
    typedef enum logic [5:0] {
        HO_ADD, HO_ADDX, HO_SUB, HO_SUBX, HO_CMP, HO_AND, HO_OR, HO_XOR, HO_MOV, HO_INC, HO_DEC,
        HO_ADDS, HO_SUBS, HO_NEG, HO_NOT, HO_EXTU, HO_EXTS, HO_SHLL, HO_SHLR, HO_SHAL, HO_SHAR,
        HO_ROTL, HO_ROTR, HO_ROTXL, HO_ROTXR, HO_DAA, HO_DAS, HO_MULXU, HO_DIVXU, HO_MULXS, HO_DIVXS,
        HO_LDC, HO_STC, HO_ANDC, HO_ORC, HO_XORC,
        HO_BSET, HO_BNOT, HO_BCLR, HO_BTST, HO_BOR, HO_BIOR, HO_BXOR, HO_BIXOR, HO_BAND, HO_BIAND,
        HO_BLD, HO_BILD, HO_BST, HO_BIST, HO_NONE
    } op_t;
    // effective-address modes
    typedef enum logic [3:0] {
        EA_NONE, EA_IND, EA_INC, EA_DEC, EA_D16, EA_D24, EA_ABS8, EA_ABS16, EA_ABS24, EA_IND8
    } ea_t;

    grp_t        d_grp;
    op_t         d_op;
    logic  [1:0] d_sz;          // 0 byte, 1 word, 2 long
    logic  [3:0] d_rd, d_rs;    // register indices in the size's numbering
    logic        d_imm;         // source is d_ival
    logic [31:0] d_ival;
    ea_t         d_ea;
    logic  [2:0] d_rea;         // base register of the EA
    logic  [2:0] d_words;
    logic  [3:0] d_cc;
    logic  [2:0] d_bit;         // immediate bit number
    logic        d_bitreg;      // bit number from register d_rs (r8)
    logic  [4:0] d_extra;       // internal states (already n+1)

    logic [15:0] ir_eff [5];
    // Everything below is written only on `cen` (at least 5 clocks apart), so the
    // sequencer's paths are 5-cycle paths (projects/ncv1_pocket.sdc). Inputs that
    // change on other clocks are sampled on `cen` and used from the next one.
    logic        bus_done;
    logic [15:0] mdata;
    always_comb begin
        for (int i = 0; i < 5; i++)
            ir_eff[i] = (state == S_BUS && ret_state == S_FETCHW && nw == 3'(i)) ? mdata : ir[i];
    end
    wire [15:0] ir0 = ir_eff[0], ir1 = ir_eff[1], ir2 = ir_eff[2], ir3 = ir_eff[3], ir4 = ir_eff[4];
    wire [7:0]  b0 = ir0[15:8], b1 = ir0[7:0];

    // word count needed, from the first word (and the second for prefixes)
    always_comb begin
        d_words = 3'd1;
        case (b0)
            8'h01: begin
                if (b1[7:4] == 4'h0 || b1[7:4] == 4'h4) begin
                    if (ir1[15:8] == 8'h6b) d_words = ir1[5] ? 3'd4 : 3'd3;
                    else if (ir1[15:8] == 8'h78) d_words = 3'd5;
                    else if (ir1[15:8] == 8'h6f) d_words = 3'd3;
                    else d_words = 3'd2;
                end else if (b1[7:4] == 4'h8) d_words = 3'd1;
                else d_words = 3'd2;
            end
            8'h58, 8'h5a, 8'h5c, 8'h5e, 8'h79, 8'h6e, 8'h6f, 8'h7b, 8'h7c, 8'h7d, 8'h7e, 8'h7f: d_words = 3'd2;
            8'h7a: d_words = 3'd3;
            8'h6a, 8'h6b: d_words = b1[5] ? 3'd3 : 3'd2;
            8'h78: d_words = 3'd4;
            default: d_words = 3'd1;
        endcase
    end

    // sign extension helpers
    function automatic logic [31:0] sx16(input logic [15:0] v); sx16 = {{16{v[15]}}, v}; endfunction

    always_comb begin
        d_grp = G_ILL; d_op = HO_NONE; d_sz = 2'd0; d_rd = 4'd0; d_rs = 4'd0; d_imm = 1'b0;
        d_ival = 32'd0; d_ea = EA_NONE; d_rea = 3'd0; d_cc = 4'd0; d_bit = 3'd0; d_bitreg = 1'b0;
        d_extra = 5'd0;
        case (b0[7:4])
        4'h0: case (b0[3:0])
            4'h0: d_grp = G_NOP;
            4'h1: begin
                case (b1[7:4])
                4'h0: begin // mov.l with memory
                    d_sz = 2'd2;
                    case (ir1[15:8])
                    8'h69: begin d_grp = ir1[7] ? G_STORE : G_LOAD; d_ea = EA_IND; d_rea = ir1[6:4]; d_rd = {1'b0, ir1[2:0]}; end
                    8'h6b: begin d_grp = ir1[7] ? G_STORE : G_LOAD; d_rd = {1'b0, ir1[2:0]};
                                 if (ir1[5]) begin d_ea = EA_ABS24; d_ival = {ir2, ir3}; end
                                 else begin d_ea = EA_ABS16; d_ival = sx16(ir2); end end
                    8'h6d: begin d_grp = ir1[7] ? G_STORE : G_LOAD; d_ea = ir1[7] ? EA_DEC : EA_INC; d_rea = ir1[6:4]; d_rd = {1'b0, ir1[2:0]}; d_extra = 5'd2; end
                    8'h6f: begin d_grp = ir1[7] ? G_STORE : G_LOAD; d_ea = EA_D16; d_rea = ir1[6:4]; d_rd = {1'b0, ir1[2:0]}; d_ival = sx16(ir2); end
                    8'h78: begin d_grp = ir2[7] ? G_STORE : G_LOAD; d_ea = EA_D24; d_rea = ir1[6:4]; d_rd = {1'b0, ir2[2:0]}; d_ival = {ir3, ir4}; end
                    default: d_grp = G_ILL;
                    endcase
                end
                4'h4: begin // ldc/stc memory forms
                    d_sz = 2'd1;
                    case (ir1[15:8])
                    8'h69: begin d_grp = ir1[7] ? G_STCM : G_LDCM; d_ea = EA_IND; d_rea = ir1[6:4]; end
                    8'h6b: begin d_grp = ir1[7] ? G_STCM : G_LDCM;
                                 if (ir1[5]) begin d_ea = EA_ABS24; d_ival = {ir2, ir3}; end
                                 else begin d_ea = EA_ABS16; d_ival = sx16(ir2); end end
                    8'h6d: begin d_grp = ir1[7] ? G_STCM : G_LDCM; d_ea = ir1[7] ? EA_DEC : EA_INC; d_rea = ir1[6:4]; d_extra = 5'd2; end
                    8'h6f: begin d_grp = ir1[7] ? G_STCM : G_LDCM; d_ea = EA_D16; d_rea = ir1[6:4]; d_ival = sx16(ir2); end
                    8'h78: begin d_grp = ir2[7] ? G_STCM : G_LDCM; d_ea = EA_D24; d_rea = ir1[6:4]; d_ival = {ir3, ir4}; end
                    default: d_grp = G_ILL;
                    endcase
                end
                4'h8: d_grp = G_SLEEP;
                4'hc: begin // mulxs
                    d_grp = G_ALU; d_op = HO_MULXS;
                    if (ir1[15:8] == 8'h50) begin d_sz = 2'd0; d_rs = ir1[7:4]; d_rd = ir1[3:0]; d_extra = 5'd12; end
                    else if (ir1[15:8] == 8'h52) begin d_sz = 2'd1; d_rs = ir1[7:4]; d_rd = {1'b0, ir1[2:0]}; d_extra = 5'd20; end
                    else d_grp = G_ILL;
                end
                4'hd: begin // divxs
                    d_grp = G_ALU; d_op = HO_DIVXS;
                    if (ir1[15:8] == 8'h51) begin d_sz = 2'd0; d_rs = ir1[7:4]; d_rd = ir1[3:0]; d_extra = 5'd12; end
                    else if (ir1[15:8] == 8'h53) begin d_sz = 2'd1; d_rs = ir1[7:4]; d_rd = {1'b0, ir1[2:0]}; d_extra = 5'd20; end
                    else d_grp = G_ILL;
                end
                4'hf: begin // or.l/xor.l/and.l rs,rd
                    d_grp = G_ALU; d_sz = 2'd2; d_rs = {1'b0, ir1[6:4]}; d_rd = {1'b0, ir1[2:0]};
                    case (ir1[15:8])
                    8'h64: d_op = HO_OR; 8'h65: d_op = HO_XOR; 8'h66: d_op = HO_AND;
                    default: d_grp = G_ILL;
                    endcase
                end
                default: d_grp = G_ILL;
                endcase
            end
            4'h2: begin d_grp = G_ALU; d_op = HO_STC; d_sz = 2'd0; d_rd = b1[3:0]; end
            4'h3: begin d_grp = G_ALU; d_op = HO_LDC; d_sz = 2'd0; d_rs = b1[3:0]; end
            4'h4: begin d_grp = G_ALU; d_op = HO_ORC;  d_imm = 1'b1; d_ival = {24'd0, b1}; end
            4'h5: begin d_grp = G_ALU; d_op = HO_XORC; d_imm = 1'b1; d_ival = {24'd0, b1}; end
            4'h6: begin d_grp = G_ALU; d_op = HO_ANDC; d_imm = 1'b1; d_ival = {24'd0, b1}; end
            4'h7: begin d_grp = G_ALU; d_op = HO_LDC;  d_imm = 1'b1; d_ival = {24'd0, b1}; end
            4'h8: begin d_grp = G_ALU; d_op = HO_ADD; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h9: begin d_grp = G_ALU; d_op = HO_ADD; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'ha: begin d_grp = G_ALU;
                if (b1[7]) begin d_op = HO_ADD; d_sz = 2'd2; d_rs = {1'b0, b1[6:4]}; d_rd = {1'b0, b1[2:0]}; end
                else if (b1[7:4] == 4'h0) begin d_op = HO_INC; d_sz = 2'd0; d_rd = b1[3:0]; d_ival = 32'd1; d_imm = 1'b1; end
                else d_grp = G_ILL; end
            4'hb: begin d_grp = G_ALU; d_imm = 1'b1;
                case (b1[7:4])
                4'h0: begin d_op = HO_ADDS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd1; end
                4'h5: begin d_op = HO_INC;  d_sz = 2'd1; d_rd = b1[3:0]; d_ival = 32'd1; end
                4'h7: begin d_op = HO_INC;  d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd1; end
                4'h8: begin d_op = HO_ADDS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd2; end
                4'h9: begin d_op = HO_ADDS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd4; end
                4'hd: begin d_op = HO_INC;  d_sz = 2'd1; d_rd = b1[3:0]; d_ival = 32'd2; end
                4'hf: begin d_op = HO_INC;  d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd2; end
                default: d_grp = G_ILL;
                endcase end
            4'hc: begin d_grp = G_ALU; d_op = HO_MOV; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'hd: begin d_grp = G_ALU; d_op = HO_MOV; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'he: begin d_grp = G_ALU; d_op = HO_ADDX; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'hf: begin d_grp = G_ALU;
                if (b1[7]) begin d_op = HO_MOV; d_sz = 2'd2; d_rs = {1'b0, b1[6:4]}; d_rd = {1'b0, b1[2:0]}; end
                else if (b1[7:4] == 4'h0) begin d_op = HO_DAA; d_sz = 2'd0; d_rd = b1[3:0]; end
                else d_grp = G_ILL; end
            endcase
        4'h1: case (b0[3:0])
            4'h0, 4'h1, 4'h2, 4'h3: begin // shifts and rotates
                d_grp = G_ALU;
                case (b1[7:4])
                4'h0: d_sz = 2'd0; 4'h1: d_sz = 2'd1; 4'h3: d_sz = 2'd2;
                4'h8: d_sz = 2'd0; 4'h9: d_sz = 2'd1; 4'hb: d_sz = 2'd2;
                default: d_grp = G_ILL;
                endcase
                d_rd = (d_sz == 2'd2) ? {1'b0, b1[2:0]} : b1[3:0];
                case ({b0[1:0], b1[7]})
                3'b000: d_op = HO_SHLL; 3'b001: d_op = HO_SHAL;
                3'b010: d_op = HO_SHLR; 3'b011: d_op = HO_SHAR;
                3'b100: d_op = HO_ROTXL; 3'b101: d_op = HO_ROTL;
                3'b110: d_op = HO_ROTXR; 3'b111: d_op = HO_ROTR;
                endcase
            end
            4'h4: begin d_grp = G_ALU; d_op = HO_OR;  d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h5: begin d_grp = G_ALU; d_op = HO_XOR; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h6: begin d_grp = G_ALU; d_op = HO_AND; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h7: begin d_grp = G_ALU;
                case (b1[7:4])
                4'h0: begin d_op = HO_NOT;  d_sz = 2'd0; d_rd = b1[3:0]; end
                4'h1: begin d_op = HO_NOT;  d_sz = 2'd1; d_rd = b1[3:0]; end
                4'h3: begin d_op = HO_NOT;  d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; end
                4'h5: begin d_op = HO_EXTU; d_sz = 2'd1; d_rd = b1[3:0]; end
                4'h7: begin d_op = HO_EXTU; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; end
                4'h8: begin d_op = HO_NEG;  d_sz = 2'd0; d_rd = b1[3:0]; end
                4'h9: begin d_op = HO_NEG;  d_sz = 2'd1; d_rd = b1[3:0]; end
                4'hb: begin d_op = HO_NEG;  d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; end
                4'hd: begin d_op = HO_EXTS; d_sz = 2'd1; d_rd = b1[3:0]; end
                4'hf: begin d_op = HO_EXTS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; end
                default: d_grp = G_ILL;
                endcase end
            4'h8: begin d_grp = G_ALU; d_op = HO_SUB; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h9: begin d_grp = G_ALU; d_op = HO_SUB; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'ha: begin d_grp = G_ALU;
                if (b1[7]) begin d_op = HO_SUB; d_sz = 2'd2; d_rs = {1'b0, b1[6:4]}; d_rd = {1'b0, b1[2:0]}; end
                else if (b1[7:4] == 4'h0) begin d_op = HO_DEC; d_sz = 2'd0; d_rd = b1[3:0]; d_ival = 32'd1; d_imm = 1'b1; end
                else d_grp = G_ILL; end
            4'hb: begin d_grp = G_ALU; d_imm = 1'b1;
                case (b1[7:4])
                4'h0: begin d_op = HO_SUBS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd1; end
                4'h5: begin d_op = HO_DEC;  d_sz = 2'd1; d_rd = b1[3:0]; d_ival = 32'd1; end
                4'h7: begin d_op = HO_DEC;  d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd1; end
                4'h8: begin d_op = HO_SUBS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd2; end
                4'h9: begin d_op = HO_SUBS; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd4; end
                4'hd: begin d_op = HO_DEC;  d_sz = 2'd1; d_rd = b1[3:0]; d_ival = 32'd2; end
                4'hf: begin d_op = HO_DEC;  d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_ival = 32'd2; end
                default: d_grp = G_ILL;
                endcase end
            4'hc: begin d_grp = G_ALU; d_op = HO_CMP; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'hd: begin d_grp = G_ALU; d_op = HO_CMP; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'he: begin d_grp = G_ALU; d_op = HO_SUBX; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'hf: begin d_grp = G_ALU;
                if (b1[7]) begin d_op = HO_CMP; d_sz = 2'd2; d_rs = {1'b0, b1[6:4]}; d_rd = {1'b0, b1[2:0]}; end
                else if (b1[7:4] == 4'h0) begin d_op = HO_DAS; d_sz = 2'd0; d_rd = b1[3:0]; end
                else d_grp = G_ILL; end
            endcase
        4'h2: begin d_grp = G_LOAD;  d_sz = 2'd0; d_rd = b0[3:0]; d_ea = EA_ABS8; d_ival = {24'hffffff, b1}; end
        4'h3: begin d_grp = G_STORE; d_sz = 2'd0; d_rd = b0[3:0]; d_ea = EA_ABS8; d_ival = {24'hffffff, b1}; end
        4'h4: begin d_grp = G_BCC; d_cc = b0[3:0]; d_ival = {{24{b1[7]}}, b1}; end
        4'h5: case (b0[3:0])
            4'h0: begin d_grp = G_ALU; d_op = HO_MULXU; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; d_extra = 5'd12; end
            4'h1: begin d_grp = G_ALU; d_op = HO_DIVXU; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; d_extra = 5'd12; end
            4'h2: begin d_grp = G_ALU; d_op = HO_MULXU; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = {1'b0, b1[2:0]}; d_extra = 5'd20; end
            4'h3: begin d_grp = G_ALU; d_op = HO_DIVXU; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = {1'b0, b1[2:0]}; d_extra = 5'd12; end
            4'h4: d_grp = (b1 == 8'h70) ? G_RTS : G_ILL;
            4'h5: begin d_grp = G_BSR; d_ival = {{24{b1[7]}}, b1}; end
            4'h6: d_grp = (b1 == 8'h70) ? G_RTE : G_ILL;
            4'h7: begin d_grp = G_TRAPA; d_ival = {30'd0, b1[5:4]}; end
            4'h8: begin d_grp = G_BCC; d_cc = b1[7:4]; d_ival = sx16(ir1); end
            4'h9: begin d_grp = G_JMP; d_ea = EA_IND; d_rea = b1[6:4]; end
            4'ha: begin d_grp = G_JMP; d_ea = EA_ABS24; d_ival = {8'd0, b1, ir1}; d_extra = 5'd2; end
            4'hb: begin d_grp = G_JMP; d_ea = EA_IND8; d_ival = {24'd0, b1}; d_extra = 5'd2; end
            4'hc: begin d_grp = G_BSR; d_ival = sx16(ir1); d_extra = 5'd2; end
            4'hd: begin d_grp = G_JSR; d_ea = EA_IND; d_rea = b1[6:4]; end
            4'he: begin d_grp = G_JSR; d_ea = EA_ABS24; d_ival = {8'd0, b1, ir1}; d_extra = 5'd2; end
            4'hf: begin d_grp = G_JSR; d_ea = EA_IND8; d_ival = {24'd0, b1}; end
            endcase
        4'h6: case (b0[3:0])
            4'h0: begin d_grp = G_ALU; d_op = HO_BSET; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; d_bitreg = 1'b1; end
            4'h1: begin d_grp = G_ALU; d_op = HO_BNOT; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; d_bitreg = 1'b1; end
            4'h2: begin d_grp = G_ALU; d_op = HO_BCLR; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; d_bitreg = 1'b1; end
            4'h3: begin d_grp = G_ALU; d_op = HO_BTST; d_sz = 2'd0; d_rs = b1[7:4]; d_rd = b1[3:0]; d_bitreg = 1'b1; end
            4'h4: begin d_grp = G_ALU; d_op = HO_OR;  d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h5: begin d_grp = G_ALU; d_op = HO_XOR; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h6: begin d_grp = G_ALU; d_op = HO_AND; d_sz = 2'd1; d_rs = b1[7:4]; d_rd = b1[3:0]; end
            4'h7: begin d_grp = G_ALU; d_op = b1[7] ? HO_BIST : HO_BST; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h8: begin d_grp = b1[7] ? G_STORE : G_LOAD; d_sz = 2'd0; d_ea = EA_IND; d_rea = b1[6:4]; d_rd = b1[3:0]; end
            4'h9: begin d_grp = b1[7] ? G_STORE : G_LOAD; d_sz = 2'd1; d_ea = EA_IND; d_rea = b1[6:4]; d_rd = b1[3:0]; end
            4'ha: begin d_sz = 2'd0; d_rd = b1[3:0];
                case (b1[7:4])
                4'h0: begin d_grp = G_LOAD;  d_ea = EA_ABS16; d_ival = sx16(ir1); end
                4'h2: begin d_grp = G_LOAD;  d_ea = EA_ABS24; d_ival = {ir1, ir2}; end
                4'h4: begin d_grp = G_LOAD;  d_ea = EA_ABS16; d_ival = sx16(ir1); end   // movfpe
                4'h8: begin d_grp = G_STORE; d_ea = EA_ABS16; d_ival = sx16(ir1); end
                4'ha: begin d_grp = G_STORE; d_ea = EA_ABS24; d_ival = {ir1, ir2}; end
                4'hc: begin d_grp = G_STORE; d_ea = EA_ABS16; d_ival = sx16(ir1); end   // movtpe
                default: d_grp = G_ILL;
                endcase end
            4'hb: begin d_sz = 2'd1; d_rd = b1[3:0];
                case (b1[7:4])
                4'h0: begin d_grp = G_LOAD;  d_ea = EA_ABS16; d_ival = sx16(ir1); end
                4'h2: begin d_grp = G_LOAD;  d_ea = EA_ABS24; d_ival = {ir1, ir2}; end
                4'h8: begin d_grp = G_STORE; d_ea = EA_ABS16; d_ival = sx16(ir1); end
                4'ha: begin d_grp = G_STORE; d_ea = EA_ABS24; d_ival = {ir1, ir2}; end
                default: d_grp = G_ILL;
                endcase end
            4'hc: begin d_grp = b1[7] ? G_STORE : G_LOAD; d_sz = 2'd0; d_ea = b1[7] ? EA_DEC : EA_INC; d_rea = b1[6:4]; d_rd = b1[3:0]; d_extra = 5'd2; end
            4'hd: begin d_grp = b1[7] ? G_STORE : G_LOAD; d_sz = 2'd1; d_ea = b1[7] ? EA_DEC : EA_INC; d_rea = b1[6:4]; d_rd = b1[3:0]; d_extra = 5'd2; end
            4'he: begin d_grp = b1[7] ? G_STORE : G_LOAD; d_sz = 2'd0; d_ea = EA_D16; d_rea = b1[6:4]; d_rd = b1[3:0]; d_ival = sx16(ir1); end
            4'hf: begin d_grp = b1[7] ? G_STORE : G_LOAD; d_sz = 2'd1; d_ea = EA_D16; d_rea = b1[6:4]; d_rd = b1[3:0]; d_ival = sx16(ir1); end
            endcase
        4'h7: case (b0[3:0])
            4'h0: begin d_grp = G_ALU; d_op = HO_BSET; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h1: begin d_grp = G_ALU; d_op = HO_BNOT; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h2: begin d_grp = G_ALU; d_op = HO_BCLR; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h3: begin d_grp = G_ALU; d_op = HO_BTST; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h4: begin d_grp = G_ALU; d_op = b1[7] ? HO_BIOR  : HO_BOR;  d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h5: begin d_grp = G_ALU; d_op = b1[7] ? HO_BIXOR : HO_BXOR; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h6: begin d_grp = G_ALU; d_op = b1[7] ? HO_BIAND : HO_BAND; d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h7: begin d_grp = G_ALU; d_op = b1[7] ? HO_BILD  : HO_BLD;  d_sz = 2'd0; d_rd = b1[3:0]; d_bit = b1[6:4]; end
            4'h8: begin // @(d24,ERn) byte/word moves: 78 r0 6A/6B 2d/Ad, disp in ir2:ir3
                d_ea = EA_D24; d_rea = b1[6:4]; d_ival = {ir2, ir3}; d_rd = ir1[3:0];
                d_sz = ir1[8] ? 2'd1 : 2'd0;
                if (ir1[15:9] == 7'b0110101 && ir1[6:4] == 3'b010) d_grp = ir1[7] ? G_STORE : G_LOAD;
                else d_grp = G_ILL;
            end
            4'h9: begin d_grp = G_ALU; d_sz = 2'd1; d_rd = b1[3:0]; d_imm = 1'b1; d_ival = {16'd0, ir1};
                case (b1[7:4])
                4'h0: d_op = HO_MOV; 4'h1: d_op = HO_ADD; 4'h2: d_op = HO_CMP; 4'h3: d_op = HO_SUB;
                4'h4: d_op = HO_OR;  4'h5: d_op = HO_XOR; 4'h6: d_op = HO_AND;
                default: d_grp = G_ILL;
                endcase end
            4'ha: begin d_grp = G_ALU; d_sz = 2'd2; d_rd = {1'b0, b1[2:0]}; d_imm = 1'b1; d_ival = {ir1, ir2};
                case (b1[7:4])
                4'h0: d_op = HO_MOV; 4'h1: d_op = HO_ADD; 4'h2: d_op = HO_CMP; 4'h3: d_op = HO_SUB;
                4'h4: d_op = HO_OR;  4'h5: d_op = HO_XOR; 4'h6: d_op = HO_AND;
                default: d_grp = G_ILL;
                endcase end
            4'hb: begin
                if (ir0 == 16'h7b5c && ir1 == 16'h598f) begin d_grp = G_EEPMOV; d_sz = 2'd0; end
                else if (ir0 == 16'h7bd4 && ir1 == 16'h598f) begin d_grp = G_EEPMOV; d_sz = 2'd1; end
                else d_grp = G_ILL;
            end
            4'hc, 4'hd, 4'he, 4'hf: begin // bit ops on memory
                d_grp = G_BITMEM; d_sz = 2'd0;
                if (b0[1]) begin d_ea = EA_ABS8; d_ival = {24'hffffff, b1}; end
                else begin d_ea = EA_IND; d_rea = b1[6:4]; end
                d_bit = ir1[6:4]; d_rs = ir1[7:4];
                case (ir1[15:8])
                8'h60: begin d_op = HO_BSET; d_bitreg = 1'b1; end
                8'h61: begin d_op = HO_BNOT; d_bitreg = 1'b1; end
                8'h62: begin d_op = HO_BCLR; d_bitreg = 1'b1; end
                8'h63: begin d_op = HO_BTST; d_bitreg = 1'b1; end
                8'h67: d_op = ir1[7] ? HO_BIST : HO_BST;
                8'h70: d_op = HO_BSET; 8'h71: d_op = HO_BNOT; 8'h72: d_op = HO_BCLR; 8'h73: d_op = HO_BTST;
                8'h74: d_op = ir1[7] ? HO_BIOR  : HO_BOR;
                8'h75: d_op = ir1[7] ? HO_BIXOR : HO_BXOR;
                8'h76: d_op = ir1[7] ? HO_BIAND : HO_BAND;
                8'h77: d_op = ir1[7] ? HO_BILD  : HO_BLD;
                default: d_grp = G_ILL;
                endcase
            end
            endcase
        default: begin // 8x-Fx: imm8 ops on r8 (register in b0[3:0])
            d_grp = G_ALU; d_sz = 2'd0; d_rd = b0[3:0]; d_imm = 1'b1; d_ival = {24'd0, b1};
            case (b0[7:4])
            4'h8: d_op = HO_ADD;  4'h9: d_op = HO_ADDX; 4'ha: d_op = HO_CMP; 4'hb: d_op = HO_SUBX;
            4'hc: d_op = HO_OR;   4'hd: d_op = HO_XOR;  4'he: d_op = HO_AND; 4'hf: d_op = HO_MOV;
            default: d_op = HO_NONE;
            endcase
        end
        endcase
    end

    // whether a bit-op / bit-mem op writes its result back
    function automatic logic bit_writes(input op_t o);
        bit_writes = (o == HO_BSET || o == HO_BNOT || o == HO_BCLR || o == HO_BST || o == HO_BIST);
    endfunction

    // ------------------------------------------------------------ ALU
    // res/ccr for op on (a = dest, b = src) at size sz with the current ccr
    logic [31:0] alu_a, alu_b, alu_res;
    logic  [7:0] bitreg_v;
    logic  [7:0] alu_ccr;
    logic  [2:0] alu_bitn;
    op_t         alu_op;
    logic  [1:0] alu_sz;

    function automatic logic [31:0] szmask(input logic [1:0] sz);
        szmask = (sz == 2'd0) ? 32'h000000ff : (sz == 2'd1) ? 32'h0000ffff : 32'hffffffff;
    endfunction
    function automatic logic [31:0] signbit(input logic [1:0] sz);
        signbit = (sz == 2'd0) ? 32'h00000080 : (sz == 2'd1) ? 32'h00008000 : 32'h80000000;
    endfunction

    // 64-bit-ish add/sub with carry out at the size boundary
    always_comb begin
        logic [31:0] m, sb, a, b, r, hmask;
        logic [32:0] wide;
        logic        cin, cout, hc, n, z, v, bitv;
        logic  [7:0] cc;
        logic [7:0]  d8; logic [7:0] byteval;
        logic [15:0] mul16; logic [31:0] mul32;
        n = 1'b0; z = 1'b0; v = 1'b0;
        m  = szmask(alu_sz);
        sb = signbit(alu_sz);
        hmask = (alu_sz == 2'd0) ? 32'h0000000f : (alu_sz == 2'd1) ? 32'h00000fff : 32'h0fffffff;
        a  = alu_a & m;
        b  = alu_b & m;
        cc = ccr;
        r  = 32'd0;
        wide = 33'd0; cin = 1'b0; cout = 1'b0; hc = 1'b0; bitv = 1'b0;
        d8 = 8'd0; byteval = a[7:0];
        mul16 = 16'd0; mul32 = 32'd0;
        case (alu_op)
        HO_ADD, HO_ADDX, HO_INC, HO_ADDS: begin
            cin = (alu_op == HO_ADDX) ? ccr[F_C] : 1'b0;
            wide = {1'b0, a} + {1'b0, b} + {32'd0, cin};
            r = wide[31:0] & m;
            cout = (alu_sz == 2'd0) ? wide[8] : (alu_sz == 2'd1) ? wide[16] : wide[32];
            hc = (((a & hmask) + (b & hmask) + {31'd0, cin}) & (hmask + 1)) != 0;
            n = (r & sb) != 0; z = (r == 0);
            v = ((~(a ^ b)) & (a ^ r) & sb) != 0;
            if (alu_op == HO_ADDS) begin cc = ccr; end
            else if (alu_op == HO_INC) begin cc[F_N] = n; cc[F_Z] = z; cc[F_V] = v; end
            else begin
                cc[F_N] = n; cc[F_V] = v; cc[F_C] = cout; cc[F_H] = hc;
                if (alu_op == HO_ADDX) begin if (!z) cc[F_Z] = 1'b0; end else cc[F_Z] = z;
            end
        end
        HO_SUB, HO_SUBX, HO_CMP, HO_DEC, HO_SUBS, HO_NEG: begin
            if (alu_op == HO_NEG) begin b = a; a = 32'd0; end
            cin = (alu_op == HO_SUBX) ? ccr[F_C] : 1'b0;
            wide = {1'b0, a} - {1'b0, b} - {32'd0, cin};
            r = wide[31:0] & m;
            cout = (alu_sz == 2'd0) ? wide[8] : (alu_sz == 2'd1) ? wide[16] : wide[32];
            hc = (((a & hmask) - (b & hmask) - {31'd0, cin}) & (hmask + 1)) != 0;
            n = (r & sb) != 0; z = (r == 0);
            v = ((a ^ b) & (a ^ r) & sb) != 0;
            if (alu_op == HO_SUBS) begin cc = ccr; end
            else if (alu_op == HO_DEC) begin cc[F_N] = n; cc[F_Z] = z; cc[F_V] = v; end
            else begin
                cc[F_N] = n; cc[F_V] = v; cc[F_C] = cout; cc[F_H] = hc;
                if (alu_op == HO_SUBX) begin if (!z) cc[F_Z] = 1'b0; end else cc[F_Z] = z;
            end
            if (alu_op == HO_CMP) r = a;   // unchanged destination
        end
        HO_AND: begin r = a & b; cc[F_N] = (r & sb) != 0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_OR:  begin r = a | b; cc[F_N] = (r & sb) != 0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_XOR: begin r = a ^ b; cc[F_N] = (r & sb) != 0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_MOV: begin r = b;     cc[F_N] = (r & sb) != 0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_NOT: begin r = ~a & m; cc[F_N] = (r & sb) != 0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_EXTU: begin r = (alu_sz == 2'd1) ? {24'd0, a[7:0]} : {16'd0, a[15:0]};
                 cc[F_N] = 1'b0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_EXTS: begin r = (alu_sz == 2'd1) ? {16'd0, {8{a[7]}}, a[7:0]} : {{16{a[15]}}, a[15:0]};
                 cc[F_N] = (r & sb) != 0; cc[F_Z] = (r == 0); cc[F_V] = 1'b0; end
        HO_SHLL, HO_SHAL: begin
            r = (a << 1) & m;
            cc[F_C] = (a & sb) != 0;
            cc[F_V] = (alu_op == HO_SHAL) ? (((a & sb) != 0) ^ ((a & (sb >> 1)) != 0)) : 1'b0;
            cc[F_Z] = (r == 0); cc[F_N] = (r & sb) != 0;
        end
        HO_SHLR: begin r = a >> 1; cc[F_C] = a[0]; cc[F_V] = 1'b0; cc[F_Z] = (r == 0); cc[F_N] = 1'b0; end
        HO_SHAR: begin r = (a >> 1) | (a & sb); cc[F_C] = a[0]; cc[F_V] = 1'b0; cc[F_Z] = (r == 0); cc[F_N] = (r & sb) != 0; end
        HO_ROTL: begin r = ((a << 1) | {31'd0, (a & sb) != 0}) & m; cc[F_C] = (a & sb) != 0; cc[F_V] = 1'b0; cc[F_Z] = (r == 0); cc[F_N] = (r & sb) != 0; end
        HO_ROTR: begin r = (a >> 1) | (a[0] ? sb : 32'd0); cc[F_C] = a[0]; cc[F_V] = 1'b0; cc[F_Z] = (r == 0); cc[F_N] = (r & sb) != 0; end
        HO_ROTXL: begin r = ((a << 1) | {31'd0, ccr[F_C]}) & m; cc[F_C] = (a & sb) != 0; cc[F_V] = 1'b0; cc[F_Z] = (r == 0); cc[F_N] = (r & sb) != 0; end
        HO_ROTXR: begin r = (a >> 1) | (ccr[F_C] ? sb : 32'd0); cc[F_C] = a[0]; cc[F_V] = 1'b0; cc[F_Z] = (r == 0); cc[F_N] = (r & sb) != 0; end
        HO_DAA: begin
            if (ccr[F_C]) begin
                if (ccr[F_H]) begin if (a[7:4] <= 4'h3 && a[3:0] <= 4'h3) d8 = 8'h66; end
                else begin if (a[7:4] <= 4'h2) d8 = (a[3:0] <= 4'h9) ? 8'h60 : 8'h66; end
            end else begin
                if (ccr[F_H]) begin if (a[3:0] <= 4'h3) d8 = (a[7:4] <= 4'h9) ? 8'h06 : 8'h66; end
                else begin
                    if (a[3:0] <= 4'h9) d8 = (a[7:4] <= 4'h9) ? 8'h00 : 8'h60;
                    else d8 = (a[7:4] <= 4'h8) ? 8'h06 : 8'h66;
                end
            end
            wide = {1'b0, a} + {25'd0, d8};
            r = wide[31:0] & 32'hff;
            cc[F_H] = (((a & 32'hf) + {28'd0, d8[3:0]}) & 32'h10) != 0;
            cc[F_Z] = (r == 0); cc[F_N] = r[7]; cc[F_V] = ((~(a ^ {24'd0, d8})) & (a ^ r) & 32'h80) != 0; cc[F_C] = wide[8];
        end
        HO_DAS: begin
            if (ccr[F_C]) begin
                if (ccr[F_H]) begin if (a[7:4] >= 4'h6 && a[3:0] >= 4'h6) d8 = 8'h9a; end
                else begin if (a[7:4] >= 4'h7 && a[3:0] <= 4'h9) d8 = 8'ha0; end
            end else begin
                if (ccr[F_H]) begin if (a[7:4] <= 4'h8 && a[3:0] >= 4'h6) d8 = 8'hfa; end
            end
            wide = {1'b0, a} + {25'd0, d8};
            r = wide[31:0] & 32'hff;
            cc[F_H] = (((a & 32'hf) + {28'd0, d8[3:0]}) & 32'h10) != 0;
            cc[F_Z] = (r == 0); cc[F_N] = r[7]; cc[F_V] = ((~(a ^ {24'd0, d8})) & (a ^ r) & 32'h80) != 0; cc[F_C] = wide[8];
        end
        HO_MULXU: begin
            // .b: r16 = u8(r16) * r8   .w: r32 = u16(r32) * r16   (no flags)
            if (alu_sz == 2'd0) begin mul16 = alu_a[7:0] * alu_b[7:0]; r = {16'd0, mul16}; end
            else begin mul32 = alu_a[15:0] * alu_b[15:0]; r = mul32; end
        end
        HO_MULXS: begin
            if (alu_sz == 2'd0) begin
                mul16 = $signed(alu_a[7:0]) * $signed(alu_b[7:0]);
                r = {16'd0, mul16}; cc[F_N] = mul16[15]; cc[F_Z] = (mul16 == 0);
            end else begin
                mul32 = $signed(alu_a[15:0]) * $signed(alu_b[15:0]);
                r = mul32; cc[F_N] = mul32[31]; cc[F_Z] = (mul32 == 0);
            end
        end
        HO_LDC:  begin r = a; cc = alu_b[7:0]; end
        HO_STC:  begin r = {24'd0, ccr}; end
        HO_ANDC: begin r = a; cc = ccr & alu_b[7:0]; end
        HO_ORC:  begin r = a; cc = ccr | alu_b[7:0]; end
        HO_XORC: begin r = a; cc = ccr ^ alu_b[7:0]; end
        HO_BSET, HO_BNOT, HO_BCLR, HO_BTST, HO_BOR, HO_BIOR, HO_BXOR, HO_BIXOR, HO_BAND, HO_BIAND,
        HO_BLD, HO_BILD, HO_BST, HO_BIST: begin
            bitv = byteval[alu_bitn];
            r = {24'd0, byteval};
            case (alu_op)
            HO_BSET:  r[{2'b00, alu_bitn}] = 1'b1;
            HO_BNOT:  r[{2'b00, alu_bitn}] = ~bitv;
            HO_BCLR:  r[{2'b00, alu_bitn}] = 1'b0;
            HO_BTST:  cc[F_Z] = ~bitv;
            HO_BOR:   cc[F_C] = ccr[F_C] | bitv;
            HO_BIOR:  cc[F_C] = ccr[F_C] | ~bitv;
            HO_BXOR:  cc[F_C] = ccr[F_C] ^ bitv;
            HO_BIXOR: cc[F_C] = ccr[F_C] ^ ~bitv;
            HO_BAND:  cc[F_C] = ccr[F_C] & bitv;
            HO_BIAND: cc[F_C] = ccr[F_C] & ~bitv;
            HO_BLD:   cc[F_C] = bitv;
            HO_BILD:  cc[F_C] = ~bitv;
            HO_BST:   r[{2'b00, alu_bitn}] = ccr[F_C];
            HO_BIST:  r[{2'b00, alu_bitn}] = ~ccr[F_C];
            default: ;
            endcase
        end
        default: r = a;
        endcase
        alu_res = r;
        alu_ccr = cc;
    end

    // ------------------------------------------------------------ divider (sequential, restoring)
    // DIVXU/DIVXS run at clk rate inside the instruction's internal states.
    logic        div_signed;
    logic        div_neg_q, div_neg_r;
    logic        div_wide;      // 1: 32/16, 0: 16/8

    // ------------------------------------------------------------ branch condition
    function automatic logic cond(input logic [3:0] cc, input logic [7:0] f);
        logic n, z, v, c;
        n = f[F_N]; z = f[F_Z]; v = f[F_V]; c = f[F_C];
        case (cc)
        4'h0: cond = 1'b1; 4'h1: cond = 1'b0;
        4'h2: cond = ~(c | z); 4'h3: cond = c | z;
        4'h4: cond = ~c; 4'h5: cond = c;
        4'h6: cond = ~z; 4'h7: cond = z;
        4'h8: cond = ~v; 4'h9: cond = v;
        4'ha: cond = ~n; 4'hb: cond = n;
        4'hc: cond = ~(n ^ v); 4'hd: cond = n ^ v;
        4'he: cond = ~(z | (n ^ v)); 4'hf: cond = z | (n ^ v);
        endcase
    endfunction

    // ------------------------------------------------------------ bus requests
    // A request is issued the clock after the state that decides it (so the bus
    // sees a one-clock gap between back-to-back accesses, which the one-ack-per-
    // request memories need), completes at the second state after issue at the
    // earliest, and its continuation runs in that completing state -- so every
    // access costs exactly 2 states when the memory answers in time, as in MAME.
    logic        bus_cnt;                     // a state has passed since issue

    task automatic start_read(input logic [23:0] a, input logic word, input state_t rs, input logic [4:0] rstep);
        nreq_addr <= a; nreq_word <= word; nreq_rd <= 1'b1; nreq_wr <= 1'b0; req_tog <= ~req_tog;
        bus_cnt <= 1'b0;
        ret_state <= rs; ret_step <= rstep; state <= S_BUS;
    endtask
    task automatic start_write(input logic [23:0] a, input logic word, input logic [15:0] d, input state_t rs, input logic [4:0] rstep);
        nreq_addr <= a; nreq_word <= word; nreq_wdata <= word ? d : {d[7:0], d[7:0]}; nreq_rd <= 1'b0; nreq_wr <= 1'b1; req_tog <= ~req_tog;
        bus_cnt <= 1'b0;
        ret_state <= rs; ret_step <= rstep; state <= S_BUS;
    endtask
    task automatic go_wait(input logic [4:0] n, input state_t rs, input logic [4:0] rstep);
        wait_n <= n; ret_state <= rs; ret_step <= rstep; state <= S_WAIT;
    endtask

    // byte read from the lane the address selects
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [7:0] lane8(input logic [23:0] a, input logic [15:0] d);
        lane8 = a[0] ? d[7:0] : d[15:8];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // EA calculation (combinational from decode and registers)
    logic [23:0] ea_calc;
    always_comb begin
        case (d_ea)
        EA_IND, EA_INC: ea_calc = er[d_rea][23:0];
        EA_DEC:         ea_calc = er[d_rea][23:0] - ((d_sz == 2'd0) ? 24'd1 : (d_sz == 2'd1) ? 24'd2 : 24'd4);
        EA_D16, EA_D24: ea_calc = er[d_rea][23:0] + d_ival[23:0];
        default:        ea_calc = d_ival[23:0];
        endcase
    end

    // value being stored (register source for G_STORE/STCM)
    wire [31:0] store_val = rsz(d_sz, d_rd);
    wire        ea_word   = (d_sz != 2'd0);

    // ------------------------------------------------------------ instruction boundary
    // p = the address of the next instruction (usually pc; a jump passes its target)
    task automatic finish(input logic [23:0] p);
        if (irq_vector != 8'd0 && !noirq) begin
            cur_vec <= irq_vector; irq_ack_tog <= ~irq_ack_tog; irq_ack_vector <= irq_vector;
            irq_tog <= ~irq_tog; dbg_npc <= p;
            tmp2 <= {8'd0, p};
            pc <= p;
            // MAME has already prefetched the opcode at p (2 states, discarded) when it
            // decides to take the interrupt; then internal(1): 4 states before the pushes
            go_wait(5'd4, S_IRQ, 5'd1);
        end else begin
            noirq <= 1'b0;
            istart_tog <= ~istart_tog; dbg_pc <= p;
            nw <= 3'd0;
            start_read(p, 1'b1, S_FETCHW, 5'd0);
            pc <= p + 24'd2;
        end
    endtask

    // ------------------------------------------------------------ body start (all words fetched)
    task automatic begin_body();
        ea <= ea_calc;
        if (d_ea == EA_INC || d_ea == EA_DEC)
            er[d_rea] <= (d_ea == EA_INC) ? er[d_rea] + ((d_sz == 2'd0) ? 32'd1 : (d_sz == 2'd1) ? 32'd2 : 32'd4) : {8'd0, ea_calc};
        case (d_grp)
        G_ALU: begin
            if (d_op == HO_DIVXU || d_op == HO_DIVXS) begin
                logic [31:0] n; logic [15:0] dd; logic nneg, dneg;
                n = (d_sz == 2'd0) ? {16'd0, r16(d_rd)} : er[d_rd[2:0]];
                dd = (d_sz == 2'd0) ? {8'd0, r8(d_rs)} : r16(d_rs);
                if (d_op == HO_DIVXS) begin
                    if (d_sz == 2'd0) begin nneg = n[15]; n = nneg ? (32'd0 - {{16{n[15]}}, n[15:0]}) : n; end
                    else begin nneg = n[31]; n = nneg ? (32'd0 - n) : n; end
                    if (d_sz == 2'd0) begin dneg = dd[7]; dd = dneg ? (16'd0 - {{8{dd[7]}}, dd[7:0]}) : dd; end
                    else begin dneg = dd[15]; dd = dneg ? (16'd0 - dd) : dd; end
                end else begin nneg = 1'b0; dneg = 1'b0; end
                div_signed <= (d_op == HO_DIVXS);
                dv_n <= n; dv_d <= dd; dv_tog <= ~dv_tog;
                div_neg_q <= nneg ^ dneg; div_neg_r <= nneg;
                div_wide <= (d_sz == 2'd1);
                tmp1 <= {16'd0, dd};
                go_wait(d_extra, S_EXEC, 5'd1);
            end else if (d_extra != 5'd0) begin
                // multiplies: result now, then the internal states
                ccr <= alu_ccr; wsz((d_sz == 2'd0) ? 2'd1 : 2'd2, d_rd, alu_res);
                go_wait(d_extra, S_FETCH, 5'd0);
            end else begin
                ccr <= alu_ccr;
                if (d_op == HO_LDC || d_op == HO_ANDC || d_op == HO_ORC || d_op == HO_XORC) noirq <= 1'b1;
                if (d_op != HO_CMP && d_op != HO_BTST && d_op != HO_BOR && d_op != HO_BIOR &&
                    d_op != HO_BXOR && d_op != HO_BIXOR && d_op != HO_BAND && d_op != HO_BIAND &&
                    d_op != HO_BLD && d_op != HO_BILD && d_op != HO_LDC && d_op != HO_ANDC &&
                    d_op != HO_ORC && d_op != HO_XORC)
                    wsz(d_sz, d_rd, alu_res);
                finish(pc);
            end
        end
        G_NOP, G_ILL: finish(pc);
        G_SLEEP: begin dbg_sleep <= 1'b1; state <= S_SLEEP; end
        G_BCC: begin
            // MAME fetches from the target regardless of the condition (2 states)
            if (cond(d_cc, ccr)) pc <= pc + d_ival[23:0];
            go_wait(5'd2, S_FETCH, 5'd0);
        end
        default: begin
            if (d_extra != 5'd0) go_wait(d_extra, S_EXEC, 5'd0);
            else exec_step(5'd0, ea_calc);
        end
        endcase
    endtask

    // ------------------------------------------------------------ instruction steps
    task automatic exec_step(input logic [4:0] st, input logic [23:0] ea_in);
        case (d_grp)
        // ---- DIVXU / DIVXS write-back after the internal states
        G_ALU: begin
            if (tmp1[15:0] == 16'd0) begin
                ccr[F_Z] <= 1'b1;
                ccr[F_N] <= div_signed ? 1'b0 : tmp1[7];
            end else begin
                logic [15:0] q, rr;
                q  = div_neg_q ? (16'd0 - dv_q[15:0]) : dv_q[15:0];
                rr = div_neg_r ? (16'd0 - dv_rem[15:0]) : dv_rem[15:0];
                ccr[F_Z] <= 1'b0;
                // MAME: DIVXU sets N from bit 7 of the divisor (both sizes); DIVXS from the quotient sign
                ccr[F_N] <= div_signed ? (div_neg_q && dv_q != 32'd0) : tmp1[7];
                if (div_wide) er[d_rd[2:0]] <= {rr, q};
                else w16(d_rd, {rr[7:0], q[7:0]});
            end
            finish(pc);
        end
        // ---- MOV memory -> register
        G_LOAD: case (st)
            5'd0: start_read(ea_in, ea_word, S_EXEC, 5'd1);
            5'd1: begin
                if (d_sz == 2'd2) begin tmp1 <= {mdata, 16'd0}; start_read(ea_in + 24'd2, 1'b1, S_EXEC, 5'd2); end
                else begin
                    logic [31:0] v;
                    v = (d_sz == 2'd0) ? {24'd0, lane8(ea_in, mdata)} : {16'd0, mdata};
                    wsz(d_sz, d_rd, v);
                    ccr[F_N] <= v[(d_sz == 2'd0) ? 7 : 15]; ccr[F_Z] <= (v == 0); ccr[F_V] <= 1'b0;
                    finish(pc);
                end
            end
            default: begin
                logic [31:0] v;
                v = {tmp1[31:16], mdata};
                er[d_rd[2:0]] <= v;
                ccr[F_N] <= v[31]; ccr[F_Z] <= (v == 0); ccr[F_V] <= 1'b0;
                finish(pc);
            end
        endcase
        // ---- MOV register -> memory
        G_STORE: case (st)
            5'd0: begin
                ccr[F_N] <= store_val[(d_sz == 2'd0) ? 7 : (d_sz == 2'd1) ? 15 : 31];
                ccr[F_Z] <= (store_val == 0); ccr[F_V] <= 1'b0;
                if (d_sz == 2'd2) start_write(ea_in, 1'b1, store_val[31:16], S_EXEC, 5'd1);
                else start_write(ea_in, ea_word, store_val[15:0], S_FETCH, 5'd0);
            end
            default: start_write(ea_in + 24'd2, 1'b1, store_val[15:0], S_FETCH, 5'd0);
        endcase
        // ---- bit operations on memory (byte read, optional write back)
        G_BITMEM: case (st)
            5'd0: start_read(ea_in, 1'b0, S_EXEC, 5'd1);
            default: begin
                ccr <= alu_ccr;
                if (bit_writes(d_op)) start_write(ea_in, 1'b0, {8'd0, alu_res[7:0]}, S_FETCH, 5'd0);
                else finish(pc);
            end
        endcase
        // ---- LDC.W @ea, CCR  /  STC.W CCR, @ea
        G_LDCM: case (st)
            5'd0: start_read(ea_in, 1'b1, S_EXEC, 5'd1);
            default: begin ccr <= mdata[15:8]; noirq <= 1'b1; finish(pc); end
        endcase
        G_STCM: start_write(ea_in, 1'b1, {ccr, ccr}, S_FETCH, 5'd0);
        // ---- JMP
        G_JMP: case (st)
            5'd0: begin
                case (d_ea)
                EA_IND:   begin pc <= ea_in; go_wait(5'd2, S_FETCH, 5'd0); end   // dummy fetch
                EA_ABS24: finish(ea_in);                                         // internal states already spent
                default:  go_wait(5'd2, S_EXEC, 5'd1);                           // @@aa:8: dummy fetch first
                endcase
            end
            5'd1: start_read(ea_in, 1'b1, S_EXEC, 5'd2);
            5'd2: begin tmp1 <= {16'd0, mdata}; start_read(ea_in + 24'd2, 1'b1, S_EXEC, 5'd3); end
            default: begin pc <= {tmp1[7:0], mdata}; go_wait(5'd2, S_FETCH, 5'd0); end
        endcase
        // ---- JSR / BSR: (fetch_noinc dummy / memory-indirect target read), push the return
        // address high word then low, then run. MAME's jsr32 prefetches at the target
        // before the pushes; here that fetch is the next instruction's own opcode read,
        // so no state is spent on it (h8.lst: jsr abs24 and bsr rel16 are 10 states, bsr
        // rel8 and jsr @ern 8, jsr @@aa:8 12, each counting its own opcode prefetch).
        G_JSR, G_BSR: case (st)
            5'd0: begin
                tmp2 <= {8'd0, pc};      // return address
                case (d_grp == G_BSR ? EA_NONE : d_ea)
                EA_IND:   begin tmp1 <= {8'd0, ea_in}; go_wait(5'd2, S_EXEC, 5'd3); end          // fetch_noinc dummy
                EA_ABS24: begin                                                                   // internal(1) already spent
                    pc <= ea_in;
                    er[7] <= er[7] - 32'd4; start_write(er[7][23:0] - 24'd4, 1'b1, {8'd0, pc[23:16]}, S_EXEC, 5'd5);
                end
                EA_IND8:  go_wait(5'd2, S_EXEC, 5'd1);                                            // fetch_noinc dummy
                default:  begin // BSR: target = pc + disp
                    if (d_extra == 5'd0) begin tmp1 <= {8'd0, pc + d_ival[23:0]}; go_wait(5'd2, S_EXEC, 5'd3); end   // rel8: fetch_noinc dummy
                    else begin                                                                                        // rel16: internal(1) already spent
                        pc <= pc + d_ival[23:0];
                        er[7] <= er[7] - 32'd4; start_write(er[7][23:0] - 24'd4, 1'b1, {8'd0, pc[23:16]}, S_EXEC, 5'd5);
                    end
                end
                endcase
            end
            5'd1: start_read(ea_in, 1'b1, S_EXEC, 5'd2);
            5'd2: begin tmp1 <= {16'd0, mdata}; start_read(ea_in + 24'd2, 1'b1, S_EXEC, 5'd6); end
            5'd6: begin
                pc <= {tmp1[7:0], mdata};
                er[7] <= er[7] - 32'd4; start_write(er[7][23:0] - 24'd4, 1'b1, {8'd0, tmp2[23:16]}, S_EXEC, 5'd5);
            end
            5'd3: begin
                pc <= tmp1[23:0];
                er[7] <= er[7] - 32'd4; start_write(er[7][23:0] - 24'd4, 1'b1, {8'd0, tmp2[23:16]}, S_EXEC, 5'd5);
            end
            default: start_write(er[7][23:0] + 24'd2, 1'b1, tmp2[15:0], S_FETCH, 5'd0);
        endcase
        // ---- RTS: dummy fetch, pop PC (high word first), internal, prefetch
        G_RTS: case (st)
            5'd0: go_wait(5'd2, S_EXEC, 5'd1);
            5'd1: start_read(er[7][23:0], 1'b1, S_EXEC, 5'd2);
            5'd2: begin tmp1 <= {16'd0, mdata}; start_read(er[7][23:0] + 24'd2, 1'b1, S_EXEC, 5'd3); end
            default: begin pc <= {tmp1[7:0], mdata}; er[7] <= er[7] + 32'd4; go_wait(5'd2, S_FETCH, 5'd0); end
        endcase
        // ---- RTE: dummy fetch, pop CCR:PCH then PCL, internal, prefetch
        G_RTE: case (st)
            5'd0: go_wait(5'd2, S_EXEC, 5'd1);
            5'd1: start_read(er[7][23:0], 1'b1, S_EXEC, 5'd2);
            5'd2: begin tmp1 <= {16'd0, mdata}; start_read(er[7][23:0] + 24'd2, 1'b1, S_EXEC, 5'd3); end
            default: begin ccr <= tmp1[15:8]; pc <= {tmp1[7:0], mdata}; er[7] <= er[7] + 32'd4; go_wait(5'd2, S_FETCH, 5'd0); end
        endcase
        // ---- TRAPA #n: like an interrupt with vector 8+n
        G_TRAPA: begin
            cur_vec <= 8'd8 + {6'd0, d_ival[1:0]};
            tmp2 <= {8'd0, pc};
            go_wait(5'd2, S_IRQ, 5'd1);
        end
        // ---- EEPMOV: copy R4L/R4 bytes from @ER5 to @ER6
        G_EEPMOV: case (st)
            5'd0: begin
                if ((d_sz == 2'd0 && er[4][7:0] == 8'd0) || (d_sz == 2'd1 && er[4][15:0] == 16'd0)) finish(pc);
                else start_read(er[5][23:0], 1'b0, S_EXEC, 5'd1);
            end
            5'd1: begin
                start_write(er[6][23:0], 1'b0, {8'd0, lane8(er[5][23:0], mdata)}, S_EXEC, 5'd0);
                er[5] <= er[5] + 32'd1; er[6] <= er[6] + 32'd1;
                if (d_sz == 2'd0) er[4][7:0] <= er[4][7:0] - 8'd1; else er[4][15:0] <= er[4][15:0] - 16'd1;
            end
            default: finish(pc);
        endcase
        default: finish(pc);
        endcase
    endtask

    // ------------------------------------------------------------ interrupt / trap entry
    // (internal(1) already spent) push NPC low; push CCR:NPC high; read vector; internal(1); prefetch
    task automatic irq_step(input logic [4:0] st);
        case (st)
        5'd1: begin er[7] <= er[7] - 32'd2; start_write(er[7][23:0] - 24'd2, 1'b1, tmp2[15:0], S_IRQ, 5'd2); end
        5'd2: begin er[7] <= er[7] - 32'd2; start_write(er[7][23:0] - 24'd2, 1'b1, {ccr, tmp2[23:16]}, S_IRQ, 5'd3); end
        5'd3: start_read({14'd0, cur_vec, 2'b00}, 1'b1, S_IRQ, 5'd4);
        5'd4: begin tmp1 <= {16'd0, mdata}; start_read({14'd0, cur_vec, 2'b10}, 1'b1, S_IRQ, 5'd5); end
        5'd5: begin
            pc <= {tmp1[7:0], mdata};
            ccr[F_I] <= 1'b1;        // SYSCR UE=1 (reset value): only I is set
            noirq <= 1'b1;
            go_wait(5'd2, S_FETCH, 5'd0);
        end
        default: state <= S_FETCH;
        endcase
    endtask

    // ------------------------------------------------------------ fetched word arrived
    task automatic fetch_word();
        ir[nw] <= mdata;
        nw <= nw + 3'd1;
        if (nw + 3'd1 < d_words) begin       // d_words already sees this word (ir_eff)
            start_read(pc, 1'b1, S_FETCHW, 5'd0);
            pc <= pc + 24'd2;
        end else begin
            begin_body();
        end
    endtask

    // continuation after a bus access or an internal wait
    task automatic dispatch(input state_t rs, input logic [4:0] rstep);
        case (rs)
        S_FETCH:  finish(pc);
        S_FETCHW: fetch_word();
        S_EXEC:   exec_step(rstep, ea);
        S_IRQ:    irq_step(rstep);
        S_RESET1: begin tmp1 <= {16'd0, mdata}; start_read(24'd2, 1'b1, S_RESET2, 5'd0); end
        S_RESET2: begin pc <= {tmp1[7:0], mdata}; noirq <= 1'b1; state <= S_FETCH; end
        default:  state <= S_FETCH;
        endcase
    endtask

    // ------------------------------------------------------------ main sequencer
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= S_RESET0; step <= 5'd0; nw <= 3'd0; noirq <= 1'b0;
            bus_done <= 1'b0; bus_cnt <= 1'b0; mdata <= 16'd0; irq_vector <= 8'd0;
            req_tog <= 1'b0; irq_ack_tog <= 1'b0; irq_ack_vector <= 8'd0; istart_tog <= 1'b0; irq_tog <= 1'b0;
            dv_tog <= 1'b0; dv_n <= 32'd0; dv_d <= 16'd0; dbg_pc <= 24'd0; dbg_npc <= 24'd0;
            div_signed <= 1'b0; div_neg_q <= 1'b0; div_neg_r <= 1'b0; div_wide <= 1'b0;
            nreq_rd <= 1'b0; nreq_wr <= 1'b0; nreq_word <= 1'b0; nreq_addr <= 24'd0; nreq_wdata <= 16'd0;
            pc <= 24'd0; ccr <= 8'h80; dbg_sleep <= 1'b0; wait_n <= 5'd0;
            ret_state <= S_FETCH; ret_step <= 5'd0; cur_vec <= 8'd0; ea <= 24'd0; tmp1 <= 32'd0; tmp2 <= 32'd0;
            for (int i = 0; i < 8; i++) er[i] <= 32'd0;
            for (int i = 0; i < 5; i++) ir[i] <= 16'd0;
        end else if (cen) begin
            // inputs from the per-clock side, used from the next state on
            bus_done <= bus_done_in; mdata <= mdata_in; irq_vector <= irq_vector_in;
            case (state)
            S_BUS: begin
                if (bus_done && bus_cnt) dispatch(ret_state, ret_step);
                else bus_cnt <= 1'b1;
            end
            S_WAIT: begin
                if (wait_n <= 5'd1) dispatch(ret_state, ret_step);
                else wait_n <= wait_n - 5'd1;
            end
            S_RESET0: begin ccr <= ccr | 8'h80; start_read(24'd0, 1'b1, S_RESET1, 5'd0); end
            S_FETCH:  finish(pc);
            S_EXEC:   exec_step(step, ea);
            S_IRQ:    irq_step(step);
            S_SLEEP:  begin if (irq_vector != 8'd0) begin dbg_sleep <= 1'b0; finish(pc); end end
            default:  state <= S_FETCH;
            endcase
        end
    end

    // ALU operand routing
    always_comb begin
        alu_op = d_op; alu_sz = d_sz;
        bitreg_v = r8(d_rs);
        alu_bitn = d_bitreg ? bitreg_v[2:0] : d_bit;
        if (d_grp == G_BITMEM) begin
            alu_a = {24'd0, lane8(ea, mdata)}; alu_b = 32'd0;
        end else if (d_op == HO_MULXU || d_op == HO_MULXS) begin
            // .b: a = r16(rd) low byte, b = r8(rs); .w: a = r32(rd) low word, b = r16(rs)
            alu_a = (d_sz == 2'd0) ? {16'd0, r16(d_rd)} : er[d_rd[2:0]];
            alu_b = (d_sz == 2'd0) ? {24'd0, r8(d_rs)} : {16'd0, r16(d_rs)};
        end else begin
            alu_a = rsz(d_sz, d_rd);
            alu_b = d_imm ? d_ival : rsz(d_sz, d_rs);
        end
    end

    // unused
    wire _unused = &{1'b0, ir4[0], tmp2[31:24], bitreg_v[7:3], dv_rem[31:16]};
endmodule


//------------------------------------------------------------------------------
// h8300h: the core plus everything that runs on every clock -- issuing bus
// requests, capturing acknowledges, the restoring divider and the one-clock
// pulses. Keeping these out of h8300h_core is what makes the core's multicycle
// constraint valid.
//------------------------------------------------------------------------------
module h8300h (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,

    output logic [23:0] bus_addr,
    output logic        bus_rd,
    output logic        bus_wr,
    output logic        bus_word,
    output logic [15:0] bus_wdata,
    input  logic [15:0] bus_rdata,
    input  logic        bus_ack,

    input  logic  [7:0] irq_vector,
    output logic        irq_ack,
    output logic  [7:0] irq_ack_vector,
    output logic  [7:0] ccr_out,

    output logic        dbg_istart,
    output logic [23:0] dbg_pc,
    output logic        dbg_irq,
    output logic [23:0] dbg_npc,
    output logic [31:0] dbg_er0, dbg_er1, dbg_er2, dbg_er3, dbg_er4, dbg_er5, dbg_er6, dbg_er7,
    output logic        dbg_sleep
);
    logic [23:0] nreq_addr;
    logic        nreq_rd, nreq_wr, nreq_word, req_tog, req_tog_d;
    logic [15:0] nreq_wdata, mdata;
    logic        bus_done;
    logic        irq_ack_tog, irq_ack_tog_d, istart_tog, istart_tog_d, irq_tog, irq_tog_d;
    logic        dv_tog, dv_tog_d;
    logic [31:0] dv_n;
    logic [15:0] dv_d;
    logic [31:0] div_q, div_rem, div_n_abs;
    logic [15:0] div_d_abs;
    logic  [5:0] div_cnt;

    h8300h_core core (
        .clk(clk), .reset(reset), .cen(cen),
        .nreq_addr(nreq_addr), .nreq_rd(nreq_rd), .nreq_wr(nreq_wr), .nreq_word(nreq_word), .nreq_wdata(nreq_wdata),
        .req_tog(req_tog), .mdata_in(mdata), .bus_done_in(bus_done),
        .irq_vector_in(irq_vector), .irq_ack_tog(irq_ack_tog), .irq_ack_vector(irq_ack_vector), .ccr_out(ccr_out),
        .dv_tog(dv_tog), .dv_n(dv_n), .dv_d(dv_d), .dv_q(div_q), .dv_rem(div_rem),
        .istart_tog(istart_tog), .dbg_pc(dbg_pc), .irq_tog(irq_tog), .dbg_npc(dbg_npc),
        .dbg_er0(dbg_er0), .dbg_er1(dbg_er1), .dbg_er2(dbg_er2), .dbg_er3(dbg_er3),
        .dbg_er4(dbg_er4), .dbg_er5(dbg_er5), .dbg_er6(dbg_er6), .dbg_er7(dbg_er7),
        .dbg_sleep(dbg_sleep)
    );

    assign dbg_istart = istart_tog ^ istart_tog_d;
    assign dbg_irq    = irq_tog ^ irq_tog_d;
    assign irq_ack    = irq_ack_tog ^ irq_ack_tog_d;

    always_ff @(posedge clk) begin
        if (reset) begin
            bus_addr <= 24'd0; bus_rd <= 1'b0; bus_wr <= 1'b0; bus_word <= 1'b0; bus_wdata <= 16'd0;
            mdata <= 16'd0; bus_done <= 1'b0; req_tog_d <= 1'b0;
            irq_ack_tog_d <= 1'b0; istart_tog_d <= 1'b0; irq_tog_d <= 1'b0;
            dv_tog_d <= 1'b0; div_q <= 32'd0; div_rem <= 32'd0; div_n_abs <= 32'd0; div_d_abs <= 16'd0; div_cnt <= 6'd0;
        end else begin
            irq_ack_tog_d <= irq_ack_tog; istart_tog_d <= istart_tog; irq_tog_d <= irq_tog;
            // acknowledge of the standing request
            if ((bus_rd || bus_wr) && bus_ack) begin bus_done <= 1'b1; mdata <= bus_rdata; bus_rd <= 1'b0; bus_wr <= 1'b0; end
            // a new request from the core
            if (req_tog != req_tog_d) begin
                req_tog_d <= req_tog;
                bus_addr <= nreq_addr; bus_word <= nreq_word; bus_wdata <= nreq_wdata;
                bus_rd <= nreq_rd; bus_wr <= nreq_wr; bus_done <= 1'b0;
            end
            // restoring division, one quotient bit per clock (MSB first); the core reads the
            // result at least a dozen states after starting it
            if (dv_tog != dv_tog_d) begin
                dv_tog_d <= dv_tog;
                div_n_abs <= dv_n; div_d_abs <= dv_d; div_rem <= 32'd0; div_q <= 32'd0; div_cnt <= 6'd32;
            end else if (div_cnt != 6'd0) begin
                logic [32:0] t;
                t = {div_rem[31:0], div_n_abs[31]} - {17'd0, div_d_abs};
                div_n_abs <= {div_n_abs[30:0], 1'b0};
                if (!t[32]) begin div_rem <= t[31:0]; div_q <= {div_q[30:0], 1'b1}; end
                else begin div_rem <= {div_rem[30:0], div_n_abs[31]}; div_q <= {div_q[30:0], 1'b0}; end
                div_cnt <= div_cnt - 6'd1;
            end
        end
    end
endmodule
