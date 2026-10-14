//------------------------------------------------------------------------------
// Namco C352 32-voice PCM sound chip, written from MAME's sound/c352.cpp
// (ref/mame/c352.cpp) as the executable spec: the same per-sample voice
// step (fetch on counter overflow, volume ramp on bits 15/16 of the phase,
// linear interpolation unless FILTER, key-on/off through the 0x202 execute
// word), the same flag bits and the same mu-law table (rtl/data/c352_mulaw.hex,
// tools/gen_c352_tables.py). Only the front left/right outputs are produced.
//
// Every cen_sample (24.576 MHz / 288 = 85.333 kHz), the engine steps the 32
// voices in sequence, about 12 clocks each plus the sample ROM fetch (at most
// one byte per voice) through the level-request / one-cycle-ack port; a step
// waits for its ack, so a slow memory only delays the sample, never corrupts
// it. A pending execute (0x202) is serviced between voice steps, so its
// latency is under one voice step.
//
// Register file: eight 32 x 16 true dual-port RAMs, one per register index
// (vol_f, vol_r, freq, flags, bank, start, end, loop). The CPU port reads and
// writes them directly (read data is valid the clock after reg_rd); the
// engine reads a voice's eight registers in one clock and writes back only
// the flags word. A CPU write to the flags of the voice being stepped is
// merged: the engine re-applies only the bits it changed (BUSY, KEYOFF,
// LOOPHIST, LDIR) on top of the CPU's value; in the single clock where both
// write the RAM the CPU wins. The KEYON/KEYOFF bits are mirrored in on_v /
// off_v so an execute snapshots exactly the flags the CPU had written when it
// issued it, whatever the engine is doing.
//
// MAME behaviours replicated on purpose (a datasheet reading would differ):
//   * `counter * (sample - last) >> 16` is unsigned arithmetic in MAME, but
//     its low 16 bits equal the arithmetic shift, which is what is built;
//   * a voice that ends (no loop) still contributes an interpolated tail in
//     the sample it ended, because BUSY is tested before the fetch;
//   * KEYOFF is applied after KEYON in the same execute, so both set means
//     the voice ends up idle with its position loaded;
//   * the output is s16(sum >> 3), wrapping, not saturating.
// One deliberate difference: a register write or execute that lands while a
// sample pass is in progress affects the voices not yet stepped in that pass,
// so it can take effect one sample (11.7 us) earlier than in MAME, which
// applies writes between samples. tools/c352_model.py (a port of c352.cpp)
// shows this as sample-level differences with no level or timing drift.
//------------------------------------------------------------------------------
`default_nettype none

module c352 #(
    parameter HEXDIR = "rtl/data"
) (
    input  logic        clk,            // 96 MHz
    input  logic        reset,
    input  logic        cen_sample,     // one pulse per output sample (85.333 kHz = 96 MHz / 1125)
    // register bus (from the H8: word index = H8 address offset / 2; the H8 does 16-bit accesses)
    input  logic        reg_wr,         // one-clock pulse
    input  logic        reg_rd,         // one-clock pulse (read data valid the next clock on reg_q)
    input  logic  [9:0] reg_addr,       // 0x000-0x0ff voice regs (voice = addr[7:3], reg = addr[2:0]), 0x200 control, 0x202 key exec
    input  logic [15:0] reg_wdata,
    output logic [15:0] reg_q,
    // sample ROM port (docs/rtl-conventions.md memory request interface: level req, one-cycle ack)
    output logic        rom_req,
    output logic [23:0] rom_addr,       // byte address in the C352's 16 MB space (ncv1 has 2 MB at 0)
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,          // valid on the clock of rom_ack
    // output: front left/right, signed 16-bit, held for one sample period; sample_valid pulses when they update
    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r,
    output logic        sample_valid,
    output logic        dbg_overrun     // sticky: a sample tick arrived before the previous one was finished
);
    // flag bits
    localparam F_BUSY = 15, F_KEYON = 14, F_KEYOFF = 13, F_LOOPHIST = 11,
               F_PHASEFL = 8, F_PHASEFR = 7, F_LDIR = 6, F_LINK = 5, F_NOISE = 4,
               F_MULAW = 3, F_FILTER = 2, F_LOOP = 1, F_REVERSE = 0;

    // ------------------------------------------------------------ mu-law table (registered read)
    logic [15:0] mulaw [256];
    initial $readmemh({HEXDIR, "/c352_mulaw.hex"}, mulaw);
    logic [15:0] mulaw_q;
    always_ff @(posedge clk) mulaw_q <= mulaw[rom_q];

    // ------------------------------------------------------------ register RAMs
    logic [15:0] qa [8];                // CPU port read data
    logic [15:0] qb [8];                // engine port read data
    logic  [4:0] eng_voice;             // engine port address
    logic        eng_flags_we;       // combinational: the flags RAM is written in the S_DONE / S_E2 clock itself
    logic [15:0] eng_flags_d;
    wire         cpu_vreg_wr = reg_wr && reg_addr[9:8] == 2'b00;
    wire   [4:0] cpu_voice = reg_addr[7:3];
    wire   [2:0] cpu_reg   = reg_addr[2:0];
    wire         cpu_flags_wr = cpu_vreg_wr && cpu_reg == 3'd3;
    // the CPU beats the engine on a same-clock write of the same voice's flags
    wire         cpu_flags_hit = cpu_flags_wr && cpu_voice == eng_voice;
    genvar r;
    generate
        for (r = 0; r < 8; r++) begin : g_reg
            logic [15:0] mem [32];
            always_ff @(posedge clk) begin
                if (cpu_vreg_wr && cpu_reg == r[2:0]) begin
                    mem[cpu_voice] <= reg_wdata; qa[r] <= reg_wdata;
                end else qa[r] <= mem[cpu_voice];
                if (r == 3 && eng_flags_we && !cpu_flags_hit) begin
                    mem[eng_voice] <= eng_flags_d; qb[r] <= eng_flags_d;
                end else qb[r] <= mem[eng_voice];
            end
        end
    endgenerate
    wire [15:0] rg_vol_f = qb[0], rg_freq = qb[2], rg_flags = qb[3],
                rg_bank = qb[4], rg_start = qb[5], rg_end = qb[6], rg_loop = qb[7];

    // control word and CPU read mux
    logic [15:0] control;
    logic  [2:0] rd_reg;
    logic  [1:0] rd_sel;                // 0 voice reg, 1 control, 2 zero
    always_ff @(posedge clk) begin
        if (reset) begin control <= 16'd0; rd_reg <= 3'd0; rd_sel <= 2'd2; end
        else begin
            if (reg_wr && reg_addr == 10'h200) control <= reg_wdata;
            if (reg_rd) begin
                rd_reg <= cpu_reg;
                rd_sel <= (reg_addr[9:8] == 2'b00) ? 2'd0 : (reg_addr == 10'h200) ? 2'd1 : 2'd2;
            end
        end
    end
    always_comb begin
        case (rd_sel)
            2'd0: reg_q = qa[rd_reg];
            2'd1: reg_q = control;
            default: reg_q = 16'd0;
        endcase
    end

    // ------------------------------------------------------------ voice state RAM (engine only)
    // {pos[23:0], counter[15:0], sample[15:0], last[15:0], volL[7:0], volR[7:0]} = 88 bits
    logic [87:0] st [32];
    logic [87:0] st_q;
    logic        st_we;
    logic  [4:0] st_wa;
    logic [87:0] st_wd;
    always_ff @(posedge clk) begin
        if (st_we) st[st_wa] <= st_wd;
        st_q <= st[eng_voice];
    end

    // ------------------------------------------------------------ engine
    typedef enum logic [3:0] {
        S_IDLE, S_V0, S_V1, S_V2, S_V3, S_FETCH, S_V4, S_V5, S_V6, S_V7, S_V8, S_V9, S_DONE, S_E0, S_E1, S_E2
    } st_t;
    st_t         state, after_exec;
    logic        pend_sample;
    logic        overrun /* verilator public_flat_rd */;
    assign dbg_overrun = overrun;
    logic  [4:0] resume_voice;
    logic [15:0] random;
    logic [31:0] on_v, off_v, snap_on, snap_off;
    logic        exec_pending;
    wire         exec_write = reg_wr && reg_addr == 10'h202;

    // working copies for the voice being stepped
    logic [15:0] w_freq, w_flags, w_flags_in, w_vol_f, w_bank, w_start, w_end, w_loop;
    logic [23:0] w_pos;
    logic [15:0] w_counter, w_sample, w_last;
    logic  [7:0] w_volL, w_volR;
    logic [16:0] w_next;
    logic        w_busy;
    logic  [7:0] rom_byte;
    logic signed [16:0] w_diff;
    logic signed [33:0] w_prod;
    logic signed [15:0] w_s;
    logic signed [16:0] w_sl, w_sr;     // phase-inverted sample per channel
    logic signed [24:0] w_pl, w_pr;     // sample * volume
    logic signed [23:0] acc_l, acc_r;
    // a CPU write to this voice's flags after the engine latched them
    logic        late_v;
    logic [15:0] late_f;

    function automatic logic [7:0] ramp(input logic [7:0] cur, input logic [7:0] tgt);
        if (cur == tgt) ramp = cur;
        else if (cur > tgt) ramp = cur - 8'd1;
        else ramp = cur + 8'd1;
    endfunction

    // merged flags write-back: the CPU's later value with the engine's changes on top
    function automatic logic [15:0] merge_flags(input logic [15:0] eng_new, input logic [15:0] eng_old,
                                                input logic late, input logic [15:0] late_val);
        logic [15:0] chg;
        chg = eng_new ^ eng_old;
        merge_flags = late ? ((late_val & ~chg) | (eng_new & chg)) : eng_new;
    endfunction

    // flags written back this clock (S_DONE: the stepped voice; S_E2: the executed voice)
    logic [15:0] exec_f;
    always_comb begin
        exec_f = w_flags;
        if (snap_on[eng_voice]) begin exec_f[F_BUSY] = 1'b1; exec_f[F_KEYON] = 1'b0; exec_f[F_LOOPHIST] = 1'b0; end
        if (snap_off[eng_voice]) begin exec_f[F_BUSY] = 1'b0; exec_f[F_KEYOFF] = 1'b0; end
        eng_flags_we = 1'b0; eng_flags_d = 16'd0;
        if (state == S_DONE && w_busy) begin
            eng_flags_we = 1'b1; eng_flags_d = merge_flags(w_flags, w_flags_in, late_v, late_f);
        end else if (state == S_E2 && (snap_on[eng_voice] || snap_off[eng_voice])) begin
            eng_flags_we = 1'b1; eng_flags_d = merge_flags(exec_f, w_flags_in, late_v, late_f);
        end
    end

    // accumulation of the current voice (its products are in w_pl/w_pr at S_DONE)
    wire signed [16:0] w_pl_s = w_pl[24:8];     // product >> 8 (arithmetic)
    wire signed [16:0] w_pr_s = w_pr[24:8];
    wire signed [23:0] acc_l_next = acc_l + 24'($signed(w_pl_s));
    wire signed [23:0] acc_r_next = acc_r + 24'($signed(w_pr_s));

    always_ff @(posedge clk) begin
        sample_valid <= 1'b0;
        st_we <= 1'b0;
        if (reset) begin
            state <= S_IDLE; after_exec <= S_IDLE; pend_sample <= 1'b0; overrun <= 1'b0; resume_voice <= 5'd0;
            random <= 16'h1234; eng_voice <= 5'd0; rom_req <= 1'b0; rom_addr <= 24'd0;
            on_v <= 32'd0; off_v <= 32'd0; snap_on <= 32'd0; snap_off <= 32'd0; exec_pending <= 1'b0;
            acc_l <= 24'd0; acc_r <= 24'd0; out_l <= 16'd0; out_r <= 16'd0;
            st_wa <= 5'd0; st_wd <= 88'd0; rom_byte <= 8'd0;
            w_freq <= 16'd0; w_flags <= 16'd0; w_flags_in <= 16'd0; w_vol_f <= 16'd0; w_bank <= 16'd0; w_start <= 16'd0; w_end <= 16'd0; w_loop <= 16'd0;
            w_pos <= 24'd0; w_counter <= 16'd0; w_sample <= 16'd0; w_last <= 16'd0; w_volL <= 8'd0; w_volR <= 8'd0;
            w_next <= 17'd0; w_busy <= 1'b0; w_diff <= 17'd0; w_prod <= 34'd0; w_s <= 16'd0;
            w_sl <= 17'd0; w_sr <= 17'd0; w_pl <= 25'd0; w_pr <= 25'd0;
            late_v <= 1'b0; late_f <= 16'd0;
        end else begin
            // ---- CPU-side bookkeeping: key-on/off mirrors, the execute request, late flag writes
            if (cpu_flags_wr) begin
                on_v[cpu_voice]  <= reg_wdata[F_KEYON];
                off_v[cpu_voice] <= reg_wdata[F_KEYOFF];
                if (cpu_voice == eng_voice) begin late_v <= 1'b1; late_f <= reg_wdata; end
            end
            if (exec_write) begin
                exec_pending <= 1'b1;
                snap_on  <= on_v;
                snap_off <= off_v;
            end
            if (cen_sample) begin
                if (pend_sample) overrun <= 1'b1;
                pend_sample <= 1'b1;
            end

            case (state)
            // ---------------------------------------------------------- idle
            S_IDLE: begin
                if (exec_pending) begin
                    exec_pending <= 1'b0; eng_voice <= 5'd0; after_exec <= S_IDLE; state <= S_E0;
                end else if (pend_sample) begin
                    pend_sample <= 1'b0; eng_voice <= 5'd0; acc_l <= 24'd0; acc_r <= 24'd0; state <= S_V0;
                end
            end
            // ---------------------------------------------------------- voice step
            S_V0: begin late_v <= 1'b0; state <= S_V1; end          // RAMs read eng_voice this clock
            S_V1: begin                                              // latch the registers and state
                w_freq <= rg_freq; w_flags <= rg_flags; w_flags_in <= rg_flags; w_vol_f <= rg_vol_f; w_bank <= rg_bank;
                w_start <= rg_start; w_end <= rg_end; w_loop <= rg_loop;
                w_pos <= st_q[87:64]; w_counter <= st_q[63:48]; w_sample <= st_q[47:32]; w_last <= st_q[31:16];
                w_volL <= st_q[15:8]; w_volR <= st_q[7:0];
                state <= S_V2;
            end
            S_V2: begin
                w_next <= {1'b0, w_counter} + {1'b0, w_freq};
                w_busy <= w_flags[F_BUSY];
                state <= S_V3;
            end
            S_V3: begin
                if (w_busy && w_next[16] && !w_flags[F_NOISE]) begin
                    rom_req <= 1'b1; rom_addr <= w_pos; state <= S_FETCH;
                end else state <= S_V4;
            end
            S_FETCH: begin
                if (rom_ack) begin rom_req <= 1'b0; rom_byte <= rom_q; state <= S_V4; end
            end
            S_V4: begin
                // fetch_sample, volume ramp, counter update, in MAME's order
                if (w_busy) begin
                    if (w_next[16]) begin
                        w_last <= w_sample;
                        if (w_flags[F_NOISE]) begin
                            logic [15:0] nr;
                            nr = (random >> 1) ^ (random[0] ? 16'hfff6 : 16'h0000);
                            random <= nr;
                            w_sample <= nr;
                        end else begin
                            w_sample <= w_flags[F_MULAW] ? mulaw_q : {rom_byte, 8'd0};
                            if (w_flags[F_LOOP] && w_flags[F_REVERSE]) begin
                                logic ldir;
                                ldir = w_flags[F_LDIR];
                                if (w_flags[F_LDIR] && w_pos[15:0] == w_loop) ldir = 1'b0;
                                else if (!w_flags[F_LDIR] && w_pos[15:0] == w_end) ldir = 1'b1;
                                w_flags[F_LDIR] <= ldir;
                                w_pos <= ldir ? w_pos - 24'd1 : w_pos + 24'd1;
                            end else if (w_pos[15:0] == w_end) begin
                                if (w_flags[F_LINK] && w_flags[F_LOOP]) begin
                                    w_pos <= {w_start[7:0], w_loop}; w_flags[F_LOOPHIST] <= 1'b1;
                                end else if (w_flags[F_LOOP]) begin
                                    w_pos <= {w_pos[23:16], w_loop}; w_flags[F_LOOPHIST] <= 1'b1;
                                end else begin
                                    w_flags[F_KEYOFF] <= 1'b1; w_flags[F_BUSY] <= 1'b0; w_sample <= 16'd0;
                                end
                            end else begin
                                w_pos <= w_flags[F_REVERSE] ? w_pos - 24'd1 : w_pos + 24'd1;
                            end
                        end
                    end
                    if ((w_next[16:15] ^ {1'b0, w_counter[15]}) != 2'b00) begin
                        w_volL <= ramp(w_volL, w_vol_f[15:8]);
                        w_volR <= ramp(w_volR, w_vol_f[7:0]);
                    end
                    w_counter <= w_next[15:0];
                end
                state <= S_V5;
            end
            S_V5: begin
                w_diff <= $signed({w_sample[15], w_sample}) - $signed({w_last[15], w_last});
                state <= S_V6;
            end
            S_V6: begin
                w_prod <= $signed({1'b0, w_counter}) * w_diff;    // 17 x 17 signed
                state <= S_V7;
            end
            S_V7: begin
                if (!w_busy) w_s <= 16'sd0;
                else if (w_flags[F_FILTER]) w_s <= w_sample;
                else w_s <= w_last + w_prod[31:16];
                state <= S_V8;
            end
            S_V8: begin
                w_sl <= w_flags[F_PHASEFL] ? -$signed({w_s[15], w_s}) : $signed({w_s[15], w_s});
                w_sr <= w_flags[F_PHASEFR] ? -$signed({w_s[15], w_s}) : $signed({w_s[15], w_s});
                state <= S_V9;
            end
            S_V9: begin
                w_pl <= w_sl * $signed({1'b0, w_volL});
                w_pr <= w_sr * $signed({1'b0, w_volR});
                state <= S_DONE;
            end
            S_DONE: begin
                // accumulate and write the voice back
                acc_l <= acc_l_next;
                acc_r <= acc_r_next;
                st_we <= 1'b1; st_wa <= eng_voice;
                st_wd <= {w_pos, w_counter, w_sample, w_last, w_volL, w_volR};
                if (w_busy && !cpu_flags_hit) begin
                    on_v[eng_voice] <= eng_flags_d[F_KEYON]; off_v[eng_voice] <= eng_flags_d[F_KEYOFF];
                end
                if (eng_voice == 5'd31) begin
                    out_l <= acc_l_next[18:3];
                    out_r <= acc_r_next[18:3];
                    sample_valid <= 1'b1;
                    state <= S_IDLE;
                end else if (exec_pending) begin
                    exec_pending <= 1'b0; resume_voice <= eng_voice + 5'd1;
                    eng_voice <= 5'd0; after_exec <= S_V0; state <= S_E0;
                end else begin
                    eng_voice <= eng_voice + 5'd1; state <= S_V0;
                end
            end
            // ---------------------------------------------------------- execute pass (one voice per 3 clocks)
            S_E0: begin late_v <= 1'b0; state <= S_E1; end
            S_E1: begin
                w_flags <= rg_flags; w_flags_in <= rg_flags; w_bank <= rg_bank; w_start <= rg_start;
                w_pos <= st_q[87:64]; w_counter <= st_q[63:48]; w_sample <= st_q[47:32]; w_last <= st_q[31:16];
                w_volL <= st_q[15:8]; w_volR <= st_q[7:0];
                state <= S_E2;
            end
            S_E2: begin
                logic [23:0] p; logic [15:0] c, smp, lst; logic [7:0] vl, vr;
                p = w_pos; c = w_counter; smp = w_sample; lst = w_last; vl = w_volL; vr = w_volR;
                if (snap_on[eng_voice]) begin
                    p = {w_bank[7:0], w_start}; smp = 16'd0; lst = 16'd0; c = 16'hffff;
                    vl = 8'd0; vr = 8'd0;
                end
                if (snap_off[eng_voice]) c = 16'hffff;
                if (snap_on[eng_voice] || snap_off[eng_voice]) begin
                    st_we <= 1'b1; st_wa <= eng_voice; st_wd <= {p, c, smp, lst, vl, vr};
                    if (!cpu_flags_hit) begin on_v[eng_voice] <= eng_flags_d[F_KEYON]; off_v[eng_voice] <= eng_flags_d[F_KEYOFF]; end
                end
                if (eng_voice == 5'd31) begin
                    eng_voice <= (after_exec == S_V0) ? resume_voice : 5'd0;
                    state <= after_exec;
                end else begin
                    eng_voice <= eng_voice + 5'd1; state <= S_E0;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{1'b0, w_prod[33:32], w_prod[15:0], qb[1], w_bank[15:8], w_pl[7:0], w_pr[7:0]};
endmodule
