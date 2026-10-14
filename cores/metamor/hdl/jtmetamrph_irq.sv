// Metamorphic Force interrupt controller.
// MAME mystwarr.cpp: IRQ6 at scanline 24; IRQ5 at scanline 248 when
// K055673/K053246 sprite IRQ enable is set. Both are held until 68000 IACK.
module jtmetamrph_irq(
    input  logic       rst,
    input  logic       clk,
    input  logic [8:0] hpos,
    input  logic [8:0] vpos,
    input  logic       sprite_irq_enabled,
    input  logic       cpu_asn,
    input  logic [2:0] cpu_fc,
    input  logic [2:0] cpu_iack_level,
    output logic [2:0] cpu_ipln,
    output logic       cpu_vpa_n,
    output logic       irq6_pending,
    output logic       irq5_pending
);
    logic [8:0] prev_vpos;
    logic       prev_iack;
    wire line_start = (vpos != prev_vpos);
    wire cpu_iack = !cpu_asn && (cpu_fc == 3'b111);

    always_ff @(posedge clk) begin
        if (rst) begin
            prev_vpos <= vpos;
            irq6_pending <= 1'b0;
            irq5_pending <= 1'b0;
            prev_iack <= 1'b0;
        end else begin
            prev_vpos <= vpos;
            prev_iack <= cpu_iack;
            if (cpu_iack && !prev_iack) begin
                // A[3:1] identifies the level accepted by the 68000. Clear
                // it once: a held IACK must preserve other or newer requests.
                case (cpu_iack_level)
                    3'd6: irq6_pending <= 1'b0;
                    3'd5: irq5_pending <= 1'b0;
                    default: ;
                endcase
            end
            // Game programs VC register pair to 0x107, which MAME interprets
            // as a 264-line frame after the chip's +1 convention. JTCORES VCT
            // loads ~0x107 = 248 and counts through 511, so raw VCT equals
            // (screen_scanline - 264) mod 512. Thus MAME scanline 24 -> 272
            // and scanline 248 -> 496. Detect vpos transitions directly:
            // the exported hpos is only the low 9 bits of the 10-bit HC.
            if (line_start && vpos == 9'd272)
                irq6_pending <= 1'b1;
            if (line_start && vpos == 9'd496 && sprite_irq_enabled)
                irq5_pending <= 1'b1;
        end
    end

    // 68000 IPL inputs are active low: level 6 = 001, level 5 = 010.
    always_comb begin
        if (rst) cpu_ipln = 3'b111;
        else if (irq6_pending) cpu_ipln = 3'b001;
        else if (irq5_pending) cpu_ipln = 3'b010;
        else cpu_ipln = 3'b111;
    end

    // Autovector all interrupt acknowledge cycles, matching the donor bus.
    assign cpu_vpa_n = !(cpu_iack && !rst);
endmodule
