import s24_pkg::*;

// System 24 timer and interrupt controller at a00000-a00007.
module s24_irq (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce_8m,
    input  logic        hsync_tick,
    input  logic [9:0]  vcount,
    input  logic        ym_irq,
    input  logic        int3_n,
    input  logic        frc_tick,
    input  logic        frc_mode,
    input  logic        frc_ack,
    input  logic        rd_a,
    input  logic        rd_b,
    input  logic        wr,
    input  logic [1:0]  addr,
    input  logic [15:0] din,
    input  logic [1:0]  be,
    output logic [15:0] dout,
    output logic [2:0]  ipl_a_n,
    output logic [2:0]  ipl_b_n
);
    logic [11:0] timer_data, timer_value;
    logic [1:0] timer_mode;
    logic [5:0] allow_a, allow_b;
    logic timer_a, timer_b, vblank_irq, sprite_irq;
    logic frc_a, frc_b;

    function automatic logic [11:0] merge_timer(
        input logic [11:0] old_data,
        input logic [15:0] new_data,
        input logic [1:0] byte_en
    );
        logic [15:0] merged;
        begin
            merged = merge16({4'h0,old_data}, new_data, byte_en);
            merge_timer = merged[11:0];
        end
    endfunction

    function automatic [2:0] encoded_ipl(input [5:0] p);
        if      (p[5]) encoded_ipl = 3'd6;
        else if (p[4]) encoded_ipl = 3'd5;
        else if (p[3]) encoded_ipl = 3'd4;
        else if (p[2]) encoded_ipl = 3'd3;
        else if (p[1]) encoded_ipl = 3'd2;
        else if (p[0]) encoded_ipl = 3'd1;
        else           encoded_ipl = 3'd0;
    endfunction

    wire timer_tick = (timer_mode == 2'd1 && hsync_tick) ||
                      (timer_mode == 2'd3 && ce_8m);

    logic [5:0] pending_a, pending_b;
    always_comb begin
        pending_a = 6'b0;
        pending_b = 6'b0;
        pending_a[IRQ_INT3]   = !int3_n;
        pending_b[IRQ_INT3]   = !int3_n;
        pending_a[IRQ_YM2151] = ym_irq;
        pending_b[IRQ_YM2151] = ym_irq;
        pending_a[IRQ_TIMER]  = timer_a;
        pending_b[IRQ_TIMER]  = timer_b;
        pending_a[IRQ_VBLANK] = vblank_irq;
        pending_b[IRQ_VBLANK] = vblank_irq;
        pending_a[IRQ_SPRITE] = sprite_irq;
        pending_b[IRQ_SPRITE] = sprite_irq;
        pending_a[IRQ_FRC]    = frc_a;
        pending_b[IRQ_FRC]    = frc_b;
        ipl_a_n = ~encoded_ipl(pending_a & allow_a);
        ipl_b_n = ~encoded_ipl(pending_b & allow_b);
        // MAME irq_timer_cb reloads m_irq_tval before asserting pending IRQs;
        // irq_r() then synchronizes and returns that live low-12-bit value.
        // There is no per-CPU retained-zero observation.
        dout = {4'h0, timer_value};
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            timer_data <= 0;
            timer_value <= 0;
            timer_mode <= 0;
            allow_a <= 0;
            allow_b <= 0;
            timer_a <= 0;
            timer_b <= 0;
            vblank_irq <= 0;
            sprite_irq <= 0;
            frc_a <= 0;
            frc_b <= 0;
        end else begin
            // MAME's irq_frc timer is free-running and independent of the
            // readable FRC counter phase.  A tick latches only the CPU lines
            // that are enabled at that instant; later enabling must not
            // resurrect a missed event.  BC/CC0005 acknowledges both CPUs.
            if (frc_tick && frc_mode) begin
                if (allow_a[IRQ_FRC]) frc_a <= 1'b1;
                if (allow_b[IRQ_FRC]) frc_b <= 1'b1;
            end
            // A tick and an ack landing on the same edge must not let the ack
            // win: that would silently drop the freshly-set interrupt (the
            // set below runs earlier in program order, so with plain
            // nonblocking assigns the later ack statement would clobber it).
            // Suppress the clear on exactly the line(s) being set this cycle.
            if (frc_ack) begin
                if (!(frc_tick && frc_mode && allow_a[IRQ_FRC])) frc_a <= 1'b0;
                if (!(frc_tick && frc_mode && allow_b[IRQ_FRC])) frc_b <= 1'b0;
            end

            // hsync_tick is registered at the wrap edge, so vcount still
            // names the line that just ended. Assert at 423->0 and 383->384
            // to match MAME's sprite and vblank scanline callbacks.
            if (hsync_tick) begin
                vblank_irq <= (vcount == 10'd383);
                sprite_irq <= (vcount == 10'd423);
            end

            if (timer_tick) begin
                if (timer_value == 12'hfff) begin
                    timer_value <= timer_data;
                    timer_a <= 1'b1;
                    timer_b <= 1'b1;
                end else timer_value <= timer_value + 1'd1;
            end

            // MAME returns the timer value for every IRQ-controller read;
            // dcclub's wait loop polls A00002 (register 1), not register 2.
            // Same same-edge set-vs-ack hazard as frc above: a reload that
            // lands on the exact cycle its own ack is being processed must
            // not have the ack (later in program order) erase the new flag.
            if (rd_a && addr == 2 && !(timer_tick && timer_value == 12'hfff)) timer_a <= 1'b0;
            if (rd_b && addr == 3 && !(timer_tick && timer_value == 12'hfff)) timer_b <= 1'b0;

            if (wr) begin
                case (addr)
                    2'd0: timer_data <= merge_timer(timer_data, din, be);
                    2'd1: if (be[0]) begin
                        // Changing to stopped mode advances once in MAME.
                        if (timer_mode != 0 && din[1:0] == 0) begin
                            if (timer_value == 12'hfff) begin
                                timer_value <= timer_data;
                                timer_a <= 1'b1;
                                timer_b <= 1'b1;
                            end else timer_value <= timer_value + 1'd1;
                        end
                        timer_mode <= din[1:0];
                    end
                    2'd2: begin
                        allow_a <= din[5:0];
                        if (!(timer_tick && timer_value == 12'hfff)) timer_a <= 1'b0;
                    end
                    2'd3: begin
                        allow_b <= din[5:0];
                        if (!(timer_tick && timer_value == 12'hfff)) timer_b <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule
