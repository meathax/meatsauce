// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation seam for the real pinned V30. External data is supplied by the
// latency-aware test harness; the CPU and its bus adapter are unmodified RTL.
module zero_cpu_top (
    input logic clk,
    input logic reset,
    input logic ce,
    input logic ready,
    input logic irq,
    input logic [7:0] irq_vector,
    input logic [15:0] read_data,
    output wire [19:0] address,
    output wire [1:0] byte_enable,
    output wire [15:0] write_data,
    output wire mem_read,
    output wire mem_write,
    output wire io_read,
    output wire io_write,
    output wire code_fetch,
    output wire int_ack,
    output wire [223:0] registers
);
    ssbus_if state_bus();
    assign state_bus.data = 0;
    assign state_bus.addr = 0;
    assign state_bus.select = 0;
    assign state_bus.write = 0;
    assign state_bus.read = 0;
    assign state_bus.query = 0;
    v30_bus #(.SS_IDX(0)) cpu (
        .clk(clk), .ce(ce), .ce_half(1'b0), .reset(reset), .ready(ready),
        .cpu_addr(address), .cpu_be(byte_enable), .cpu_dout(write_data),
        .cpu_din(read_data), .mem_rd(mem_read), .mem_wr(mem_write),
        .io_rd(io_read), .io_wr(io_write), .code_fetch(code_fetch),
        .int_req(irq), .int_vector(irq_vector), .int_ack(int_ack),
        .dbg_regs(registers), .ssbus(state_bus), .ss_restore_done(1'b0),
        .ss_quiet()
    );
endmodule
