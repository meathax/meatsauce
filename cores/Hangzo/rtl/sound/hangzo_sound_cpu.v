// Hangzo sound CPU boundary. Bus response timing is owned by the outer adapter.
module hangzo_sound_cpu (
    input  wire        clk,
    input  wire        reset,
    input  wire        global_ce,
    input  wire [7:0]  data_in,
    output wire [20:0] address,
    output wire [7:0]  data_out,
    output wire        rd_n,
    output wire        wr_n,
    output wire        sx,
    output wire        ce,
    input  wire        irq1_n,
    input  wire        irq2_n,
    input  wire        wait_n
);
    wire unused_cek_n;
    wire unused_ce7_n;
    wire unused_cer_n;
    wire unused_pre_rd;
    wire unused_pre_wr;
    wire unused_hsm;
    wire [7:0] unused_o;
    wire [23:0] unused_aud_l;
    wire [23:0] unused_aud_r;

    HUC6280 u_huc6280 (
        .CLK       (clk),
        .GLOBAL_CE (global_ce),
        .RST_N     (~reset),
        .WAIT_N    (wait_n),
        .SX        (sx),
        .A         (address),
        .DI        (data_in),
        .DO        (data_out),
        .WR_N      (wr_n),
        .RD_N      (rd_n),
        .RDY       (1'b1),
        .NMI_N     (1'b1),
        .IRQ1_N    (irq1_n),
        .IRQ2_N    (irq2_n),
        .CE        (ce),
        .CEK_N     (unused_cek_n),
        .CE7_N     (unused_ce7_n),
        .CER_N     (unused_cer_n),
        .PRE_RD    (unused_pre_rd),
        .PRE_WR    (unused_pre_wr),
        .HSM       (unused_hsm),
        .O         (unused_o),
        .K         (8'h00),
        .VDCNUM    (1'b0),
        .AUD_LDATA (unused_aud_l),
        .AUD_RDATA (unused_aud_r)
    );
endmodule
