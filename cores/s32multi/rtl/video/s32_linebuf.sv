//============================================================================
//  System 32 shared tile/bitmap line buffers
//
//  The two Multi 32 mixers consume the same tilemap-renderer stream and the
//  current core displays the same six tile/bitmap layers on both screens.
//  Keep one physical 6-layer x 2-parity-bank store and fan its registered
//  pixels out to both independent priority/palette mixers.
//============================================================================

module s32_linebuf (
    input             clk,          // clk_ram

    // renderer write port: 0=TEXT, 1..4=NBG0-3, 5=BITMAP
    input             lb_we,
    input       [2:0] lb_layer,
    input       [8:0] lb_wx,
    input      [13:0] lb_wpix,
    input             lb_bank,

    // display read port; outputs have one clk latency from rd_x
    input       [8:0] rd_x,
    input             rd_bank,
    output     [13:0] px_text,
    output     [13:0] px_nbg0,
    output     [13:0] px_nbg1,
    output     [13:0] px_nbg2,
    output     [13:0] px_nbg3,
    output     [13:0] px_bmp
);

// Each physical layer/bank is an independent one-write/one-read memory.
// Quartus 17 infers twelve 512x14 dual-port altsyncrams from this shape.
reg [13:0] lbuf_text_b0 [0:511];
reg [13:0] lbuf_text_b1 [0:511];
reg [13:0] lbuf_nbg0_b0 [0:511];
reg [13:0] lbuf_nbg0_b1 [0:511];
reg [13:0] lbuf_nbg1_b0 [0:511];
reg [13:0] lbuf_nbg1_b1 [0:511];
reg [13:0] lbuf_nbg2_b0 [0:511];
reg [13:0] lbuf_nbg2_b1 [0:511];
reg [13:0] lbuf_nbg3_b0 [0:511];
reg [13:0] lbuf_nbg3_b1 [0:511];
reg [13:0] lbuf_bmp_b0  [0:511];
reg [13:0] lbuf_bmp_b1  [0:511];

integer __lbi;
initial begin
    for (__lbi=0; __lbi<512; __lbi=__lbi+1) begin
        lbuf_text_b0[__lbi] = 14'd0; lbuf_text_b1[__lbi] = 14'd0;
        lbuf_nbg0_b0[__lbi] = 14'd0; lbuf_nbg0_b1[__lbi] = 14'd0;
        lbuf_nbg1_b0[__lbi] = 14'd0; lbuf_nbg1_b1[__lbi] = 14'd0;
        lbuf_nbg2_b0[__lbi] = 14'd0; lbuf_nbg2_b1[__lbi] = 14'd0;
        lbuf_nbg3_b0[__lbi] = 14'd0; lbuf_nbg3_b1[__lbi] = 14'd0;
        lbuf_bmp_b0 [__lbi] = 14'd0; lbuf_bmp_b1 [__lbi] = 14'd0;
    end
end

reg [13:0] px_text_b0 = 14'd0, px_text_b1 = 14'd0;
reg [13:0] px_nbg0_b0 = 14'd0, px_nbg0_b1 = 14'd0;
reg [13:0] px_nbg1_b0 = 14'd0, px_nbg1_b1 = 14'd0;
reg [13:0] px_nbg2_b0 = 14'd0, px_nbg2_b1 = 14'd0;
reg [13:0] px_nbg3_b0 = 14'd0, px_nbg3_b1 = 14'd0;
reg [13:0] px_bmp_b0  = 14'd0, px_bmp_b1  = 14'd0;

always @(posedge clk) begin
    if (lb_we) begin
        case ({lb_layer, lb_bank})
            4'd0:  lbuf_text_b0[lb_wx] <= lb_wpix;
            4'd1:  lbuf_text_b1[lb_wx] <= lb_wpix;
            4'd2:  lbuf_nbg0_b0[lb_wx] <= lb_wpix;
            4'd3:  lbuf_nbg0_b1[lb_wx] <= lb_wpix;
            4'd4:  lbuf_nbg1_b0[lb_wx] <= lb_wpix;
            4'd5:  lbuf_nbg1_b1[lb_wx] <= lb_wpix;
            4'd6:  lbuf_nbg2_b0[lb_wx] <= lb_wpix;
            4'd7:  lbuf_nbg2_b1[lb_wx] <= lb_wpix;
            4'd8:  lbuf_nbg3_b0[lb_wx] <= lb_wpix;
            4'd9:  lbuf_nbg3_b1[lb_wx] <= lb_wpix;
            4'd10: lbuf_bmp_b0 [lb_wx] <= lb_wpix;
            4'd11: lbuf_bmp_b1 [lb_wx] <= lb_wpix;
            default: ;
        endcase
    end

    px_text_b0 <= lbuf_text_b0[rd_x];
    px_text_b1 <= lbuf_text_b1[rd_x];
    px_nbg0_b0 <= lbuf_nbg0_b0[rd_x];
    px_nbg0_b1 <= lbuf_nbg0_b1[rd_x];
    px_nbg1_b0 <= lbuf_nbg1_b0[rd_x];
    px_nbg1_b1 <= lbuf_nbg1_b1[rd_x];
    px_nbg2_b0 <= lbuf_nbg2_b0[rd_x];
    px_nbg2_b1 <= lbuf_nbg2_b1[rd_x];
    px_nbg3_b0 <= lbuf_nbg3_b0[rd_x];
    px_nbg3_b1 <= lbuf_nbg3_b1[rd_x];
    px_bmp_b0  <= lbuf_bmp_b0 [rd_x];
    px_bmp_b1  <= lbuf_bmp_b1 [rd_x];
end

assign px_text = rd_bank ? px_text_b1 : px_text_b0;
assign px_nbg0 = rd_bank ? px_nbg0_b1 : px_nbg0_b0;
assign px_nbg1 = rd_bank ? px_nbg1_b1 : px_nbg1_b0;
assign px_nbg2 = rd_bank ? px_nbg2_b1 : px_nbg2_b0;
assign px_nbg3 = rd_bank ? px_nbg3_b1 : px_nbg3_b0;
assign px_bmp  = rd_bank ? px_bmp_b1  : px_bmp_b0;

endmodule
