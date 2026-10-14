// Viostorm GX main-CPU interrupt boundary.
//
// CPU sheet (schematic): LS148 S33 drives IPL2..0. D6 = INT16 (K053252 INT1),
// D5 = OBJDMA, D4 = LVCDMA, D3 = DMAEND, all other inputs tied high. K053252
// INT2 is not connected. VPA comes from AS (autovector only).
// OBJDMA is a flip-flop on the OBJ sheet, armed by OBJDMAEN (IO latch
// 0x27c001 bit 5): the object DMA sets it and the level-5 handler clears it by
// writing OBJDMAEN low. LVCDMA and DMAEND only reach return stubs in this
// game and are not modelled.
module jtviostorm_irq(
    input  logic       rst,
    input  logic       clk,
    input  logic       k053252_int1,     // cleared by the CCU int1ack register write
    input  logic       sprite_dma_busy,
    input  logic       objdma_en,        // OBJDMAEN latch bit
    input  logic       cpu_asn,
    input  logic [2:0] cpu_fc,
    output logic [2:0] cpu_ipln,
    output logic       cpu_vpa_n,
    output logic       irq1_pending,
    output logic       irq2_pending
);
    wire cpu_iack = !cpu_asn && (cpu_fc == 3'b111);

    // The interrupt is raised when the object DMA finishes.
    jtframe_edge u_objdma(
        .rst    ( rst              ),
        .clk    ( clk              ),
        .edgeof ( !sprite_dma_busy ),
        .clr    ( !objdma_en       ),
        .q      ( irq2_pending     )
    );

    assign irq1_pending = k053252_int1;

    assign cpu_ipln = rst ? 3'b111 :
                      irq1_pending ? 3'b001 :
                      irq2_pending ? 3'b010 : 3'b111;
    assign cpu_vpa_n = !(cpu_iack && !rst);
endmodule
