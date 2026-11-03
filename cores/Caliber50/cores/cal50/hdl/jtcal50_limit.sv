// Level boost (x24) followed by a feed-forward peak limiter.
// The gain is shared by both channels so the stereo balance is preserved.
// Attack is immediate (iterated every 4 clocks), release is slow and runs
// once every fourth sample strobe (jtx1010 strobes sample once per voice,
// 16 times per output sample).
module jtcal50_limit #(
    parameter signed [15:0] CEIL = 16'sd24576,  // output ceiling (-2.5 dBFS)
    parameter        [ 7:0] REL  = 8'd1         // release step per 4 strobes (Q15)
)(
    input                    clk,
    input                    sample,
    input  signed [15:0]     l_in, r_in,
    output reg signed [15:0] l_out, r_out
);

localparam [16:0] UNITY = 17'd32768;

reg  signed [20:0] xl, xr;
reg         [16:0] g = UNITY;
reg         [ 1:0] cnt = 0;
reg         [ 1:0] rdiv = 0;
reg                smp_l = 0, rel_pend = 0, over = 0;
reg  signed [38:0] pl, pr;
wire signed [38:0] pl_s = pl >>> 15, pr_s = pr >>> 15;
wire        [38:0] apl  = pl_s[38] ? -pl_s : pl_s;
wire        [38:0] apr  = pr_s[38] ? -pr_s : pr_s;
wire               edge_s = sample & ~smp_l;

function automatic signed [15:0] clamp(input signed [38:0] v);
    clamp = v >  $signed({23'd0,CEIL}) ?  CEIL :
            v < -$signed({23'd0,CEIL}) ? -CEIL : v[15:0];
endfunction

always @(posedge clk) begin
    smp_l <= sample;
    cnt   <= cnt + 2'd1;
    xl    <= (l_in <<< 4) + (l_in <<< 3);    // x24
    xr    <= (r_in <<< 4) + (r_in <<< 3);
    pl    <= xl * $signed({1'b0,g});
    pr    <= xr * $signed({1'b0,g});
    over  <= apl > {23'd0,CEIL} || apr > {23'd0,CEIL};
    l_out <= clamp(pl_s);
    r_out <= clamp(pr_s);
    if( edge_s ) begin
        rdiv <= rdiv + 2'd1;
        if( rdiv==0 ) rel_pend <= 1;
    end
    if( cnt==3 ) begin
        if( over ) begin
            if( g > 17'd64 ) g <= g - (g>>3) - 17'd1;
            rel_pend <= 0;   // no release while limiting
        end else if( rel_pend ) begin
            g <= (g + REL >= UNITY) ? UNITY : g + REL;
            rel_pend <= 0;
        end
    end
end

endmodule
