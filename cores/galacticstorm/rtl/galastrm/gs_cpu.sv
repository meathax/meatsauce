// SPDX-License-Identifier: GPL-3.0-or-later
// Board-owned synchronous bus around the unmodified TG68K.C VHDL kernel.
module gs_cpu #(
    parameter integer CPU_TYPE = 3,
    parameter integer SYS_HZ = 32_000_000,
    parameter integer CPU_HZ = 16_000_000,
    parameter bit ACK_BYPASS = (CPU_TYPE == 3),
    parameter bit RECOVER_STALLS = 1'b0,
    parameter integer MAX_RECOVERY_HZ = 32_000_000
)(
    input  logic clk,
    input  logic reset,
    input  logic pause,
    input  logic turbo,
    input  logic [2:0] irq_n,
    input  logic autovector,
    output logic bus_req,
    output logic [31:0] bus_addr,
    output logic [15:0] bus_wdata,
    output logic [1:0] bus_be,
    output logic bus_write,
    output logic bus_fetch,
    output logic [2:0] bus_fc,
    input  logic bus_ack,
    input  logic [15:0] bus_rdata,
    output logic [31:0] debug_addr,
    output logic [1:0] debug_busstate,
    output logic debug_advance,
    output wire bus_idle
);
    logic [15:0] response;
    logic response_ready;
    logic packet_more, transfer_pending;
    wire [31:0] addr;
    wire [15:0] dout;
    wire nwr, nuds, nlds,longword;
    wire [1:0] state;
    wire [2:0] fc;
    wire cpu_step_ready = (state == 2'b01 || response_ready || (ACK_BYPASS && bus_req && bus_ack));
    wire advance, recovery_overflow;

    gs_cpu_recovery_cen #(
        .SYS_HZ(SYS_HZ),.CPU_HZ(CPU_HZ),
        .RECOVER_STALLS(RECOVER_STALLS),.MAX_RECOVERY_HZ(MAX_RECOVERY_HZ)
    ) cpu_cen (
        .clk(clk),.reset(reset),.pause(pause),.step_ready(cpu_step_ready),.turbo(turbo),
        .nominal_ce(),.recovery_ce(),.advance(advance),
        .debt(),.overflow(recovery_overflow)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (!reset && recovery_overflow)
            $fatal(1,"gs_cpu stall-recovery debt overflow");
`endif

    // Specialize the 68000's word multiply/divide datapath at elaboration.
    // The 68020 retains the donor's switchable configuration.
    TG68KdotC_Kernel #(
        .MUL_Mode(CPU_TYPE == 0 ? 0 : 2),
        .DIV_Mode(CPU_TYPE == 0 ? 0 : 2)
    ) cpu (
        .clk(clk), .nReset(!reset), .clkena_in(advance), .data_in(ACK_BYPASS && bus_req && bus_ack ? bus_rdata : response),
        .IPL(irq_n), .IPL_autovector(autovector), .berr(1'b0), .CPU(2'(CPU_TYPE)),
        .addr_out(addr), .data_write(dout), .nWr(nwr), .nUDS(nuds), .nLDS(nlds),
        .busstate(state), .longword(longword), .nResetOut(), .FC(fc), .clr_berr(),
        .skipFetch(), .regin_out(), .CACR_out(), .VBR_out()
    );

    // A whole transfer boundary, including all native 68020 word-pair beats.
    // The kernel can issue consecutive accesses without an internal (01)
    // cycle. Freeze between retired transfers, retaining its native indication
    // that another 16-bit beat belongs to this same multiword access.
    assign bus_idle=!bus_req && !response_ready && !transfer_pending;
    assign debug_addr = addr;
    assign debug_busstate = state;
    assign debug_advance = advance;

    always_ff @(posedge clk) begin
        if (reset) begin
            response <= 0;
            response_ready <= 0;
            packet_more <= 0;
            transfer_pending <= 0;
            bus_req <= 0;
            bus_addr <= 0;
            bus_wdata <= 0;
            bus_be <= 0;
            bus_write <= 0;
            bus_fetch <= 0;
            bus_fc <= 0;
        end else begin
            if (advance) response_ready <= 0;
            if (bus_req && bus_ack) begin
                bus_req <= 0;
                response <= bus_rdata;
                response_ready <= ACK_BYPASS ? !advance : 1;
                transfer_pending <= packet_more;
            end
            if (!pause && !bus_req && !response_ready && state != 2'b01) begin
                bus_req <= 1;
                packet_more <= longword;
                bus_addr <= addr;
                bus_wdata <= dout;
                bus_be <= {~nuds,~nlds};
                bus_write <= state == 2'b11 && !nwr;
                bus_fetch <= state == 2'b00;
                bus_fc <= fc;
            end
        end
    end
endmodule
