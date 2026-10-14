// TUMBLE's synthesizable T80s bus adapter around the freecores TV80 core.
// This Verilog implementation is shared by Verilator and Quartus so both
// paths exercise the same CPU and bus timing.
`timescale 1ns/1ps

module T80s #(
    parameter Mode    = 0,
    parameter T2Write = 1,
    parameter IOWait  = 1
)(
    input         RESET_n,
    input         CLK,
    input         CEN,
    input         WAIT_n,
    input         INT_n,
    input         NMI_n,
    input         BUSRQ_n,
    output        M1_n,
    output reg    MREQ_n,
    output reg    IORQ_n,
    output reg    RD_n,
    output reg    WR_n,
    output        RFSH_n,
    output        HALT_n,
    output        BUSAK_n,
    input         OUT0,
    output [15:0] A,
    input   [7:0] DI,
    output  [7:0] DO
);

    wire        iorq;
    wire        no_read;
    wire        write;
    wire        intcycle_n;
    wire  [6:0] mcycle;
    wire  [6:0] tstate;
    reg   [7:0] di_reg;

    tv80_core #(Mode, IOWait) u_core (
        .cen(CEN),
        .m1_n(M1_n),
        .iorq(iorq),
        .no_read(no_read),
        .write(write),
        .rfsh_n(RFSH_n),
        .halt_n(HALT_n),
        .wait_n(WAIT_n),
        .int_n(INT_n),
        .nmi_n(NMI_n),
        .reset_n(RESET_n),
        .busrq_n(BUSRQ_n),
        .busak_n(BUSAK_n),
        .clk(CLK),
        .IntE(),
        .stop(),
        .A(A),
        .dinst(DI),
        .di(di_reg),
        .dout(DO),
        .mc(mcycle),
        .ts(tstate),
        .intcycle_n(intcycle_n)
    );

    always @(posedge CLK or negedge RESET_n) begin
        if (!RESET_n) begin
            RD_n   <= 1'b1;
            WR_n   <= 1'b1;
            IORQ_n <= 1'b1;
            MREQ_n <= 1'b1;
            di_reg <= 8'h00;
        end else if (CEN) begin
            RD_n   <= 1'b1;
            WR_n   <= 1'b1;
            IORQ_n <= 1'b1;
            MREQ_n <= 1'b1;
            if (mcycle[0]) begin
                if (tstate[1] || (tstate[2] && WAIT_n == 1'b0)) begin
                    RD_n   <= ~intcycle_n;
                    MREQ_n <= ~intcycle_n;
                    IORQ_n <= intcycle_n;
                end
                if (tstate[3])
                    MREQ_n <= 1'b0;
            end else begin
                if ((tstate[1] || (tstate[2] && WAIT_n == 1'b0)) && no_read == 1'b0 && write == 1'b0) begin
                    RD_n   <= 1'b0;
                    IORQ_n <= ~iorq;
                    MREQ_n <= iorq;
                end
                if (T2Write == 0) begin
                    if (tstate[2] && write == 1'b1) begin
                        WR_n   <= 1'b0;
                        IORQ_n <= ~iorq;
                        MREQ_n <= iorq;
                    end
                end else begin
                    if ((tstate[1] || (tstate[2] && WAIT_n == 1'b0)) && write == 1'b1) begin
                        WR_n   <= 1'b0;
                        IORQ_n <= ~iorq;
                        MREQ_n <= iorq;
                    end
                end
            end
            if (tstate[2] && WAIT_n == 1'b1)
                di_reg <= DI;
        end
    end

endmodule
