// Viostorm GX main-CPU interrupt boundary.
//
// MAME's metamrph_interrupt callback raises IRQ6 at scanline 24 and IRQ5 at
// scanline 248 when K053246 register 5 bit 4 is set. The 68000 accepts the
// level until its FC=7 interrupt-acknowledge cycle; VPA then selects the
// autovector path because this address map has no vector source.
module jtviostorm_irq(
    input  logic       rst,
    input  logic       clk,
    input  logic [8:0] vpos,
    input  logic       sprite_dma_enabled,
    input  logic       cpu_asn,
    input  logic [2:0] cpu_fc,
    output logic [2:0] cpu_ipln,
    output logic       cpu_vpa_n,
    output logic       irq6_pending,
    output logic       irq5_pending
);
    wire cpu_iack = !cpu_asn && (cpu_fc == 3'b111);
    wire irq6_event = (vpos == 9'd24);
    wire irq5_event = (vpos == 9'd248) && sprite_dma_enabled;

    jtframe_edge u_irq6(
        .rst    (rst),
        .clk    (clk),
        .edgeof (irq6_event),
        .clr    (cpu_iack && irq6_pending),
        .q      (irq6_pending)
    );
    jtframe_edge u_irq5(
        .rst    (rst),
        .clk    (clk),
        .edgeof (irq5_event),
        .clr    (cpu_iack && !irq6_pending && irq5_pending),
        .q      (irq5_pending)
    );

    // Keep the CPU-facing pins deterministic before the first clock edge.
    // jtframe_edge state is reset synchronously; exposing it during the
    // externally asserted reset phase would feed X into the 68000 core.
    assign cpu_ipln = rst ? 3'b111 :
                      irq6_pending ? 3'b001 :
                      irq5_pending ? 3'b010 : 3'b111;
    assign cpu_vpa_n = rst ? 1'b1 :
                       (cpu_iack && (irq6_pending || irq5_pending)) ?
                       1'b0 : 1'b1;
endmodule
