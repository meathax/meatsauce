// Port adapter for the exact pinned donor's GHDL-generated T80pa (Mode=0).
// The native implementation is identical in Verilator and Quartus.
module T80pa # (parameter integer Mode = 0) (
    input RESET_n, CLK,
    input tri1 CEN_p, CEN_n, WAIT_n, INT_n, NMI_n, BUSRQ_n,
    output M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n, HALT_n, BUSAK_n,
    input tri0 OUT0,
    output [15:0] A,
    input [7:0] DI,
    output [7:0] DO,
    input tri0 R800_mode,
    output [211:0] REG,
    input tri0 DIRSet,
    input tri0 [211:0] DIR
);
    // Only the Z80 mode used by all three ASO processors is translated.
    generate if (Mode != 0) begin : unsupported_mode
        T80pa_requires_Mode_zero unsupported();
    end endgenerate
    aso_t80pa_native native_cpu (
        .RESET_n(RESET_n), .CLK(CLK), .CEN_p(CEN_p), .CEN_n(CEN_n),
        .WAIT_n(WAIT_n), .INT_n(INT_n), .NMI_n(NMI_n), .BUSRQ_n(BUSRQ_n),
        .M1_n(M1_n), .MREQ_n(MREQ_n), .IORQ_n(IORQ_n), .RD_n(RD_n),
        .WR_n(WR_n), .RFSH_n(RFSH_n), .HALT_n(HALT_n), .BUSAK_n(BUSAK_n),
        .OUT0(OUT0), .A(A), .DI(DI), .DO(DO), .R800_mode(R800_mode),
        .REG(REG), .DIRSet(DIRSet), .DIR(DIR)
    );
endmodule
