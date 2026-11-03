// SPDX-License-Identifier: GPL-3.0-or-later
// Air Buster interrupt model (airbustr.cpp scanline/sub_interrupt, HOLD_LINE):
//   main IM2: line 240 -> vector FF (vblank), line 64 -> vector FD (Pandora)
//   sub  IM2: vblank -> vector FD; NMI pulse from main OUT 02
//   sound: IRQ = YM2203 level, NMI = soundlatch pending (bus module)
// HOLD_LINE requests drop on the CPU's interrupt-acknowledge cycle.
module airbustr_irq (
    input logic clk, reset,
    input logic main_event_64, main_event_240, main_ack,
    input logic sub_vblank, sub_ack,
    input logic sub_nmi_request, cpu_cen,
    input logic ym_irq,
    output logic main_irq,
    output logic [7:0] main_vector,
    output logic sub_irq, sub_nmi, sound_irq
);
    assign sound_irq = ym_irq && !reset;
    always_ff @(posedge clk) begin
        if (reset) begin
            main_irq <= 1'b0;
            main_vector <= 8'hff;
            sub_irq <= 1'b0;
            sub_nmi <= 1'b0;
        end else begin
            if (main_ack) main_irq <= 1'b0;
            if (main_event_64) begin main_irq <= 1'b1; main_vector <= 8'hfd; end
            if (main_event_240) begin main_irq <= 1'b1; main_vector <= 8'hff; end
            if (sub_ack) sub_irq <= 1'b0;
            if (sub_vblank) sub_irq <= 1'b1;
            // pulse_input_line(NMI, zero): an edge the Z80 latches; hold one CE.
            if (cpu_cen) sub_nmi <= 1'b0;
            if (sub_nmi_request) sub_nmi <= 1'b1;
        end
    end
endmodule
