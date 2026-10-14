// Timing-phase probe of the production generator and real V30 bridge/core.
// Constant NOP bus data is synthetic stimulus; this is not gameplay evidence.
module zero_irq_phase_top (
    input wire clk, reset, pause, mem_rq_active, irq_req,
    output wire cpu_ce, half_capture, irq_sample
);
    ssbus_if ss();
    assign ss.data=0;
    assign ss.addr=0;
    assign ss.select=0;
    assign ss.write=0;
    assign ss.read=0;
    assign ss.query=0;
    raiden2_ce_gen ce_gen (
        .clk(clk), .reset(reset), .pause(pause), .clk_sel(3'd0),
        .ls245_en(1'b0), .cpu_rd(1'b0), .rd_lat(1'b0),
        .mem_rq_active(mem_rq_active), .ce(cpu_ce)
    );
    cpu_v30_bridge #(.IRQ_HALF_CAPTURE(1)) bridge (
        .clk(clk), .ce(cpu_ce), .ce_4x(1'b0), .reset(reset),
        .rom_wait(1'b0), .bus_din(16'h9090),
        .irq_req(irq_req), .irq_vector(10'h0c8),
        .ss(ss), .ss_cpu_reload(1'b0)
    );
    assign half_capture=bridge.ce_half;
    assign irq_sample=bridge.g_irq_half.irq_half_q;
endmodule
