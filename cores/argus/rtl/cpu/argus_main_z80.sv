// Clock-enable wrapper derived from the pristine TV80 tv80s bus wrapper.
// Copyright (c) 2004 Guy Hutchison. TV80's permission notice is retained in
// rtl/vendor/cpu/tv80s.v; the CPU implementation there is not modified.
// Both wrapper and CPU advance on the same system-clock enable.
module argus_main_z80 (
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        ce,
    input  logic        wait_n,
    input  logic        int_n,
    input  logic [7:0]  di,
    output wire  [15:0] a,
    output wire  [7:0]  dout,
    output wire         m1_n,
    output logic        mreq_n,
    output logic        iorq_n,
    output logic        rd_n,
    output logic        wr_n,
    output wire         rfsh_n,
    output wire         halt_n
);
    wire intcycle_n, no_read, write_cycle, io_cycle;
    wire [6:0] mcycle, tstate;
    logic [7:0] di_reg;

    tv80_core #(.Mode(0), .IOWait(1)) cpu (
        .clk(clk_sys), .reset_n(~reset), .cen(ce), .wait_n(wait_n),
        .int_n(int_n), .nmi_n(1'b1), .busrq_n(1'b1), .busak_n(),
        .m1_n(m1_n), .iorq(io_cycle), .no_read(no_read),
        .write(write_cycle), .rfsh_n(rfsh_n), .halt_n(halt_n),
        .IntE(), .stop(), .A(a), .dinst(di), .di(di_reg), .\do (dout),
        .mc(mcycle), .ts(tstate), .intcycle_n(intcycle_n)
    );

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            rd_n <= 1'b1;
            wr_n <= 1'b1;
            iorq_n <= 1'b1;
            mreq_n <= 1'b1;
            di_reg <= 8'h00;
        end else if (ce) begin
            rd_n <= 1'b1;
            wr_n <= 1'b1;
            iorq_n <= 1'b1;
            mreq_n <= 1'b1;
            if (mcycle[0]) begin
                if (tstate[1] || (tstate[2] && !wait_n)) begin
                    rd_n <= ~intcycle_n;
                    mreq_n <= ~intcycle_n;
                    iorq_n <= intcycle_n;
                end
`ifdef TV80_REFRESH
                if (tstate[3]) mreq_n <= 1'b0;
`endif
            end else begin
                if (tstate[1] || (tstate[2] && !wait_n)) begin
                    if (!no_read && !write_cycle) begin
                        rd_n <= 1'b0;
                        iorq_n <= ~io_cycle;
                        mreq_n <= io_cycle;
                    end
                    if (write_cycle) begin
                        wr_n <= 1'b0;
                        iorq_n <= ~io_cycle;
                        mreq_n <= io_cycle;
                    end
                end
            end
            if (tstate[2] && wait_n) di_reg <= di;
        end
    end
endmodule
