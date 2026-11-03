module daikaiju_z80_bus (
    input  logic        clk_sys,
    input  logic        reset_n,
    input  logic        ce,
    input  logic        wait_n,
    input  logic        int_n,
    input  logic        nmi_n,
    input  logic [7:0]  data_in,
    output logic [15:0] address,
    output logic [7:0]  data_out,
    output logic        m1_n,
    output logic        mreq_n,
    output logic        iorq_n,
    output logic        rd_n,
    output logic        wr_n,
    output logic        refresh_n,
    output logic        halt_n,
    output logic        busak_n
);
    T80s cpu (
        .RESET_n(reset_n), .CLK(clk_sys), .CEN(ce), .WAIT_n(wait_n),
        .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1), .OUT0(1'b0),
        .DI(data_in), .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(refresh_n), .HALT_n(halt_n),
        .BUSAK_n(busak_n), .A(address), .DOUT(data_out)
    );
endmodule
