module suna8_main_cpu
(
    input  logic clk,
    input  logic reset,
    input  logic ce_cpu,
    input  logic wait_n,
    input  logic [7:0] data_in,
    input  logic irq_n,
    input  logic nmi_n,

    output logic [15:0] address,
    output logic [7:0] data_out,
    output logic mreq_n,
    output logic iorq,
    output logic rd_n,
    output logic wr_n,
    output logic m1_n
);

    logic iorq_n;
    logic refresh_n;
    logic halt_n;
    logic busak_n;

    // T80s is the synchronous top level in the vendored T80 snapshot.  It
    // exposes the real active-low Z80 bus strobes, avoiding a second, subtly
    // different timing decoder in the SunA core.
    assign iorq = !iorq_n;

    T80s u_t80s (
        .RESET_n(!reset),
        .CLK(clk),
        .CEN(ce_cpu),
        .WAIT_n(wait_n),
        .INT_n(irq_n),
        .NMI_n(nmi_n),
        .BUSRQ_n(1'b1),
        .M1_n(m1_n),
        .MREQ_n(mreq_n),
        .IORQ_n(iorq_n),
        .RD_n(rd_n),
        .WR_n(wr_n),
        .RFSH_n(refresh_n),
        .HALT_n(halt_n),
        .BUSAK_n(busak_n),
        .OUT0(1'b0),
        .A(address),
        .DI(data_in),
        .DO(data_out)
    );

endmodule
